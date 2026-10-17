module Hostenv.System.Acme (run) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, catch, displayException, finally)
import Control.Monad (forM, forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Aeson (FromJSON (..), (.:), withObject)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isAscii)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, mapMaybe)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)
import Hostenv.System.Error
  ( ErrorCause (..), ErrorContext (..), HostenvError (..), HostenvM
  , at, checkedIO, renderError, withContext
  )
import Hostenv.System.Lock (LockMode (..), tryLock, unlock, withLockFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.Posix.IO (FdOption (CloseOnExec), setFdOption)
import System.Posix.Process (executeFile)
import System.Posix.Signals
  ( Handler (Catch), Signal, installHandler, sigHUP, sigINT, sigTERM
  , signalProcessGroup
  )
import System.Posix.Types (Fd, ProcessID)
import System.Process
  ( CreateProcess (close_fds, create_group), createProcess, getPid
  , proc, waitForProcess
  )
import System.Timeout (timeout)
import qualified Turtle

data Options = Options
  { manifestPath :: FilePath
  , installedPath :: FilePath
  , lockPath :: FilePath
  , systemctlPath :: FilePath
  }

data Action = Condition (Maybe String) | Activate [String] | Retry [String]

defaults :: Options
defaults = Options
  { manifestPath = ""
  , installedPath = "/etc/hostenv/acme-manifest.json"
  , lockPath = "/run/hostenv/acme/activation.lock"
  , systemctlPath = "systemctl"
  }

parseArgs :: [String] -> Either ErrorCause (Options, Action)
parseArgs = go defaults
  where
    go opts ("--manifest" : value : rest) = go (opts { manifestPath = value }) rest
    go opts ("--installed-manifest" : value : rest) = go (opts { installedPath = value }) rest
    go opts ("--lock-file" : value : rest) = go (opts { lockPath = value }) rest
    go opts ("--systemctl" : value : rest) = go (opts { systemctlPath = value }) rest
    go opts ("condition" : rest) =
      case rest of
        [] -> finish opts (Condition Nothing)
        [name] -> finish opts (Condition (Just name))
        _ -> Left (InvalidInput "condition accepts at most one ACME order unit")
    go opts ("run" : "--" : command) = finish opts (Activate command)
    go opts ("run" : command) = finish opts (Activate command)
    go opts ("retry" : "--" : hosts) = finish opts (Retry hosts)
    go opts ("retry" : hosts) = finish opts (Retry hosts)
    go _ _ = Left (InvalidInput "Usage: hostenv-system acme --manifest FILE [--systemctl FILE] condition [UNIT] | run -- COMMAND | retry HOST ...")

    finish opts action
      | null (manifestPath opts) = Left (InvalidInput "--manifest is required")
      | otherwise = Right (opts, action)

data Manifest = Manifest
  { units :: [T.Text]
  , unitsByHost :: Map.Map T.Text [T.Text]
  } deriving (Show)

instance FromJSON Manifest where
  parseJSON = withObject "ACME manifest" $ \obj -> do
    version <- obj .: "version"
    when (version /= (1 :: Int)) (fail "unsupported ACME manifest version")
    listed <- obj .: "units"
    mapped <- obj .: "unitsByHost"
    unless (all validUnit listed) (fail "invalid ACME order unit")
    unless (all (all (flip elem listed)) (Map.elems mapped)) (fail "invalid ACME host mapping")
    pure (Manifest listed mapped)

validUnit :: T.Text -> Bool
validUnit unit =
  case T.stripPrefix "acme-order-renew-" unit >>= T.stripSuffix ".service" of
    Nothing -> False
    Just name -> not (T.null name) && T.all validChar name
  where
    validChar c = isAscii c && (isAlphaNum c || c `elem` ("_.:@-" :: String))

emptyManifest :: Manifest
emptyManifest = Manifest [] Map.empty

readManifest :: FilePath -> Bool -> HostenvM Manifest
readManifest path optional =
  withContext (While "reading the ACME manifest") $ do
    contents <- liftIO (tryIOError (BS.readFile path))
    case contents of
      Left err
        | optional && isDoesNotExistError err -> pure emptyManifest
        | otherwise -> at (ForResource path) (IOErrorFailure err)
      Right bytes ->
        case A.eitherDecodeStrict' bytes of
          Left err -> at (ForResource path) (InvalidData err)
          Right manifest -> pure manifest

data UnitState = UnitState
  { active :: T.Text
  , substate :: T.Text
  }

systemctl :: Options -> [String] -> HostenvM T.Text
systemctl opts arguments = do
  let context = RunningCommand (systemctlPath opts) arguments
  result <- checkedIO context $ timeout 30000000 $
    Turtle.procStrictWithErr
      (T.pack (systemctlPath opts))
      (map T.pack arguments)
      Turtle.empty
  case result of
    Nothing -> at context TimedOut
    Just (ExitSuccess, stdoutText, _) -> pure stdoutText
    Just (code, stdoutText, stderrText) ->
      at context (CommandFailed code (T.strip (stderrText <> "\n" <> stdoutText)))

unitState :: Options -> T.Text -> HostenvM (Maybe UnitState)
unitState opts unit =
  withContext (While ("inspecting ACME order " ++ T.unpack unit)) $ do
    output <- systemctl opts
      ["show", "--property=LoadState,ActiveState,SubState", "--", T.unpack unit]
    let properties = Map.fromList (mapMaybe property (T.lines output))
        property line =
          case T.breakOn "=" line of
            (key, value) | not (T.null value) -> Just (key, T.drop 1 value)
            _ -> Nothing
    case Map.lookup "LoadState" properties of
      Just "not-found" -> pure Nothing
      Just "masked" -> pure Nothing
      Just "loaded" ->
        case (Map.lookup "ActiveState" properties, Map.lookup "SubState" properties) of
          (Just a, Just s) | not (T.null a) && not (T.null s) ->
            pure (Just (UnitState a s))
          _ -> at (While "reading the ACME unit state")
                  (InvalidState ("Could not read the state of " ++ T.unpack unit))
      _ -> at (While "reading the ACME unit load state")
              (InvalidState ("Could not read the load state of " ++ T.unpack unit))

stopDelayed :: UnitState -> Bool
stopDelayed state =
  active state == "failed" || substate state == "auto-restart"

stopAndReset :: Options -> T.Text -> HostenvM ()
stopAndReset opts unit =
  withContext (While ("stopping a delayed ACME retry for " ++ T.unpack unit)) $ do
    void $ systemctl opts ["stop", "--", T.unpack unit]
    void $ systemctl opts ["reset-failed", "--", T.unpack unit]

startOrders :: Options -> [T.Text] -> HostenvM ()
startOrders opts names =
  unless (null names) $
    withContext (While "requesting ACME certificate orders") $
      void $ systemctl opts
        (["--no-block", "start", "--"] ++ map T.unpack (sort (nub names)))

pauseOrders :: Options -> [T.Text] -> IORef (Maybe Signal) -> HostenvM ()
pauseOrders opts names interrupted =
  withContext (While "waiting for outstanding ACME orders") $ do
    start <- liftIO getMonotonicTimeNSec
    let deadline = start + 120000000000
        loop [] = pure ()
        loop pending = do
          signal <- liftIO (readIORef interrupted)
          when (signal /= Nothing) $
            at (While "preparing system activation")
              (Unavailable "System activation was interrupted before it started")
          remaining <- fmap catMaybes $ forM pending $ \unit -> do
            state <- unitState opts unit
            case state of
              Nothing -> pure Nothing
              Just current | active current == "inactive" -> pure Nothing
              Just current | stopDelayed current -> stopAndReset opts unit >> pure Nothing
              Just _ -> pure (Just unit)
          unless (null remaining) $ do
            now <- liftIO getMonotonicTimeNSec
            when (now >= deadline) $
              at (While "waiting for ACME orders to finish")
                (TimedOut)
            liftIO (threadDelay 100000)
            loop remaining
    loop (nub names)

unitLockPath :: FilePath -> T.Text -> FilePath
unitLockPath lock unit = takeDirectory lock </> (T.unpack unit ++ ".lock")

retryLockPath :: FilePath -> FilePath
retryLockPath path = takeDirectory path </> "retry.lock"

-- Resource acquisition remains bracketed by the low-level IO helper. Returning
-- Either from the callback ensures that Left values also close the descriptor.
withLockFileM :: FilePath -> Bool -> (Maybe Fd -> HostenvM a) -> HostenvM a
withLockFileM path create action =
  withContext (ForResource path) $ do
    outcome <- checkedIO (While "opening or closing the ACME lock") $
      withLockFile path create (runExceptT . action)
    either throwE pure outcome

requireLock :: FilePath -> Maybe Fd -> HostenvM Fd
requireLock path Nothing =
  at (ForResource path) (Unavailable "Could not create the ACME lock file")
requireLock _ (Just fd) = pure fd

takeLock :: FilePath -> Fd -> LockMode -> String -> HostenvM ()
takeLock path fd mode message = do
  acquired <- checkedIO (While ("acquiring the ACME lock " ++ path)) (tryLock fd mode)
  unless acquired $ at (ForResource path) (LockBusy message)

withUnitLocks :: FilePath -> [T.Text] -> HostenvM a -> HostenvM a
withUnitLocks _ [] action = action
withUnitLocks path (unit : rest) action = do
  let unitPath = unitLockPath path unit
  withLockFileM unitPath True $ \maybeFd -> do
    fd <- requireLock unitPath maybeFd
    takeLock unitPath fd Exclusive
      ("Certificate order is already being changed: " ++ T.unpack unit)
    withUnitLocks path rest action

retryCertificates :: Options -> [String] -> HostenvM ExitCode
retryCertificates opts requested =
  withContext (While ("retrying ACME certificates for " ++ unwords requested)) $ do
    when (null requested) $
      at (While "validating the requested certificate hostnames")
        (InvalidInput "Specify at least one certificate hostname")
    manifest <- readManifest (manifestPath opts) False
    names <- fmap (sort . nub . concat) $ forM requested $ \raw -> do
      let hostname = T.dropWhileEnd (== '.') (T.toLower (T.pack raw))
      case Map.lookup hostname (unitsByHost manifest) of
        Nothing -> at (While ("resolving the certificate hostname " ++ raw))
                     (Unavailable ("No managed ACME certificate was found for " ++ raw))
        Just found -> pure found
    withLockFileM (lockPath opts) True $ \maybeFd -> do
      fd <- requireLock (lockPath opts) maybeFd
      takeLock (lockPath opts) fd Shared
        "A system activation is still running; retry certificates afterwards"
      let retryPath = retryLockPath (lockPath opts)
      withLockFileM retryPath True $ \maybeRetry -> do
        retryFd <- requireLock retryPath maybeRetry
        takeLock retryPath retryFd Exclusive
          "Another certificate retry is already being prepared"
        withUnitLocks (lockPath opts) names $ do
          forM_ names $ \unit -> do
            state <- unitState opts unit
            case state of
              Nothing -> at (While ("preparing the ACME order " ++ T.unpack unit))
                         (Unavailable ("The managed ACME order unit is unavailable: " ++ T.unpack unit))
              Just current | stopDelayed current -> stopAndReset opts unit
              Just _ -> pure ()
        -- Per-unit condition gates must be released before systemctl start:
        -- otherwise the services' ExecCondition skips the retry itself. Keep
        -- the shared activation lock and retry lock through dispatch instead.
        startOrders opts names
    pure ExitSuccess

condition :: Options -> Maybe String -> HostenvM ExitCode
condition opts maybeName =
  withContext (While "checking whether an ACME order may run") $ do
    extra <- case maybeName of
      Nothing -> pure []
      Just name
        | validUnit (T.pack name) -> pure [unitLockPath (lockPath opts) (T.pack name)]
        | otherwise -> at (While "validating the ACME order unit")
                         (InvalidInput ("Invalid ACME order unit: " ++ name))
    check (lockPath opts : extra)
  where
    check [] = pure ExitSuccess
    check (path : rest) =
      withLockFileM path False $ \maybeFd ->
        case maybeFd of
          Nothing -> check rest
          Just fd -> do
            ok <- checkedIO (While ("checking the ACME lock " ++ path)) (tryLock fd Shared)
            if ok then check rest else pure (ExitFailure 1)

-- The child may have already exited by the time a pending signal is sent.
-- Suppress only that race, not arbitrary exceptions or cancellation.
forwardGroup :: Signal -> ProcessID -> IO ()
forwardGroup signal pid =
  signalProcessGroup signal pid `catch` \(err :: IOException) ->
    unless (isDoesNotExistError err) (ioError err)

withForwardedSignals :: IORef (Maybe Signal) -> IORef (Maybe ProcessID) -> IO a -> IO a
withForwardedSignals interrupted child action =
  bracket install restore (const action)
  where
    watched = [sigINT, sigTERM, sigHUP]
    forward signal = do
      writeIORef interrupted (Just signal)
      current <- readIORef child
      forM_ current $ \pid ->
        forwardGroup signal pid `catch` \(err :: IOException) ->
          hPutStrLn stderr ("Warning: could not forward activation signal: " ++ displayException err)
    install = forM watched $ \signal -> do
      previous <- installHandler signal (Catch (forward signal)) Nothing
      pure (signal, previous)
    restore old = forM_ old $ \(signal, previous) ->
      void $ installHandler signal previous Nothing

withForwardedSignalsM :: IORef (Maybe Signal) -> IORef (Maybe ProcessID) -> HostenvM a -> HostenvM a
withForwardedSignalsM interrupted child action = do
  outcome <- checkedIO (While "managing activation signal handlers") $
    withForwardedSignals interrupted child (runExceptT action)
  either throwE pure outcome

-- finally must run even on async exceptions, while an ordinary Left remains a
-- value and cannot bypass cleanup.
withFinalizer :: HostenvM a -> IO () -> HostenvM a
withFinalizer action cleanup = do
  outcome <- liftIO (runExceptT action `finally` cleanup)
  either throwE pure outcome

normaliseExit :: ExitCode -> ExitCode
normaliseExit (ExitFailure code) | code < 0 = ExitFailure (128 - code)
normaliseExit code = code

activate :: Options -> [String] -> HostenvM ExitCode
activate _ [] =
  at (While "validating the activation command")
    (InvalidInput "An activation command is required")
activate opts (program : arguments) =
  withContext (While "coordinating NixOS system activation") $ do
    dry <- checkedIO (While "reading DRY_ACTIVATE") (lookupEnv "DRY_ACTIVATE")
    boot <- checkedIO (While "reading BOOT") (lookupEnv "BOOT")
    if dry == Just "1" || boot == Just "1"
      then checkedIO (RunningCommand program arguments)
             (executeFile program True arguments Nothing)
      else do
        interrupted <- liftIO (newIORef Nothing)
        child <- liftIO (newIORef Nothing)
        withForwardedSignalsM interrupted child $
          withLockFileM (lockPath opts) True $ \maybeFd -> do
            fd <- requireLock (lockPath opts) maybeFd
            takeLock (lockPath opts) fd Exclusive
              "Another system activation is already running on this node"
            let resume = do
                  -- A child inherits the file description, so unlocking must
                  -- precede the attempt to resume background certificate work.
                  unlock fd
                  result <- tryIOError $ runExceptT $
                    withContext (While "resuming ACME orders after activation") $ do
                      installed <- readManifest (installedPath opts) True
                      startOrders opts (units installed)
                  case result of
                    Left err ->
                      hPutStrLn stderr
                        ("Warning: could not resume ACME orders: " ++ displayException err)
                    Right (Left err) ->
                      hPutStrLn stderr ("Warning: could not resume ACME orders:\n" ++ renderError err)
                    Right (Right ()) -> pure ()
            withFinalizer (do
              -- Older generations have no manifest. Their failed units are
              -- deliberately left alone and can be repaired by the operator.
              installed <- readManifest (installedPath opts) True
              pauseOrders opts (units installed) interrupted
              signal <- liftIO (readIORef interrupted)
              when (signal /= Nothing) $
                at (While "preparing system activation")
                  (Unavailable "System activation was interrupted")
              let childProcess = (proc program arguments)
                    { create_group = True, close_fds = False }
              -- The switch inherits the lock. If this supervisor is killed,
              -- renewal stays paused until the switch itself exits.
              checkedIO (While "making the activation lock inheritable") $
                setFdOption fd CloseOnExec False
              (_, _, _, process) <- checkedIO (RunningCommand program arguments) $
                createProcess childProcess
                  `finally` setFdOption fd CloseOnExec True
              pid <- checkedIO (While "reading the activation process ID") (getPid process)
              liftIO (writeIORef child pid)
              pending <- liftIO (readIORef interrupted)
              forM_ pending $ \sig ->
                forM_ pid $ \group ->
                  checkedIO (While "forwarding the pending activation signal") $
                    forwardGroup sig group
              result <- checkedIO (While "waiting for system activation") (waitForProcess process)
              liftIO (writeIORef child Nothing)
              pure (normaliseExit result)
              ) resume

-- The one command boundary converts typed errors to user output and chooses
-- status codes. ExecCondition needs 1 for a held lock and 255 for an error.
run :: [String] -> IO ExitCode
run args =
  case parseArgs args of
    Left reason -> do
      hPutStrLn stderr $
        renderError (HostenvError (While "parsing ACME arguments" :| []) reason)
      pure (ExitFailure 1)
    Right (opts, action) -> do
      result <- runExceptT $ case action of
        Condition unit -> condition opts unit
        Activate command -> activate opts command
        Retry hostnames -> retryCertificates opts hostnames
      case result of
        Right exitCode -> pure exitCode
        Left err -> do
          hPutStrLn stderr (renderError err)
          pure (ExitFailure (case action of Condition _ -> 255; _ -> 1))
