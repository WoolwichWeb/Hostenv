{-# LANGUAGE ForeignFunctionInterface #-}
module Hostenv.System.Endpoint (run) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, catch, displayException, finally)
import Control.Monad (unless, void, when)
import Data.Aeson (FromJSON (..), (.:), withObject)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import Data.Char (isAscii, isAlphaNum, isSpace)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Foreign.C.Error (eEXIST, eSRCH, getErrno, throwErrno, throwErrnoIfMinus1Retry)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (readHex)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (deviceID, fileID, getFdStatus)
import System.Posix.IO (FdOption (CloseOnExec), closeFd, setFdOption)
import System.Posix.Process
  (executeFile, exitImmediately, forkProcess, getProcessID, getProcessStatus)
import System.Posix.Signals
  (Handler (Catch), Signal, installHandler, sigINT, sigKILL, sigTERM, signalProcess)
import System.Posix.Types (Fd (..), ProcessID)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- The C shim contains only Linux ABI calls. The namespace and process
-- lifecycle live here, alongside the other hostenv-system subcommands.
foreign import ccall unsafe "hostenv_endpoint_open_directory"
  c_openDirectory :: CInt -> CString -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_open_namespace"
  c_openNamespace :: CString -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_make_directory"
  c_makeDirectory :: CInt -> CString -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_object_exists"
  c_objectExists :: CInt -> CString -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_socket_matches"
  c_socketMatches :: CInt -> CString -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_pidfd_open"
  c_pidfdOpen :: CInt -> IO CInt
foreign import ccall safe "hostenv_endpoint_pidfd_exited"
  c_pidfdExited :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_pidfd_signal"
  c_pidfdSignal :: CInt -> CInt -> IO CInt

-- Parsed once when reading the manifest; prepare needs components rather
-- than having to split and inspect the socket path again.
data SocketLocation = SocketLocation
  { runtimeComponents :: [FilePath]
  , socketDirectories :: [FilePath]
  , socketFilename :: FilePath
  } deriving (Show)

data Settings = Settings
  { owner :: String
  , socketPath :: FilePath
  , socketLocation :: SocketLocation
  , descriptor :: String
  , port :: Int
  , systemctl :: FilePath
  , nsenter :: FilePath
  , setpriv :: FilePath
  , proxy :: FilePath
  } deriving (Show)

invalid :: String -> IO a
invalid = ioError . userError

validName :: String -> Bool
validName value =
  case value of
    first : rest -> asciiAlphaNum first && all safeChar rest
    [] -> False
  where
    asciiAlphaNum c = isAscii c && isAlphaNum c
    safeChar c = asciiAlphaNum c || c `elem` ("_.-" :: String)

validExecutablePath :: FilePath -> Bool
validExecutablePath ('/' : rest) = '\NUL' `notElem` rest
validExecutablePath _ = False

absoluteParts :: FilePath -> Either String [String]
absoluteParts path =
  case T.splitOn "/" (T.pack path) of
    "" : parts
      | not (null parts) && all (validName . T.unpack) parts ->
          Right (map T.unpack parts)
    _ -> Left "socket and runtime paths must be absolute, normalised and contain safe components"

parseSocketLocation :: FilePath -> FilePath -> Either String SocketLocation
parseSocketLocation runtime path = do
  root <- absoluteParts runtime
  socket <- absoluteParts path
  relative <- maybe (Left "the export must be inside the environment's runtime directory")
                    Right (stripPrefix root socket)
  case reverse relative of
    filename : directories -> do
      -- absoluteParts admits only ASCII, so characters and bytes agree here.
      unless (length path < 108) $
        Left "the Unix socket path must be at most 107 bytes"
      pure SocketLocation
        { runtimeComponents = root
        , socketDirectories = reverse directories
        , socketFilename = filename
        }
    [] -> Left "the export must be inside the environment's runtime directory"

instance FromJSON Settings where
  parseJSON = withObject "Hostenv endpoint manifest" $ \obj -> do
    ownerName <- obj .: "owner"
    name <- obj .: "name"
    runtime <- obj .: "runtime_dir"
    path <- obj .: "socket"
    descriptorName <- obj .: "descriptor"
    privatePort <- obj .: "port"
    systemctlPath <- obj .: "systemctl"
    nsenterPath <- obj .: "nsenter"
    setprivPath <- obj .: "setpriv"
    proxyPath <- obj .: "proxy"

    unless (maybe False (validName . T.unpack)
              (T.stripSuffix ".service" (T.pack ownerName))) $
      fail "invalid owning unit name"
    unless (validName name) $
      fail "invalid endpoint name"
    unless (not (null descriptorName) && length descriptorName <= 255 &&
            all (\c -> isAscii c && (isAlphaNum c || c `elem` ("_.-" :: String)))
                descriptorName) $
      fail "invalid activation descriptor name"
    unless (privatePort >= 1 && privatePort <= 65535) $
      fail "the private TCP port must be between 1 and 65535"
    location <- either fail pure (parseSocketLocation runtime path)
    unless (all validExecutablePath
              [systemctlPath, nsenterPath, setprivPath, proxyPath]) $
      fail "helper executable paths must be absolute"

    pure Settings
      { owner = ownerName
      , socketPath = path
      , socketLocation = location
      , descriptor = descriptorName
      , port = privatePort
      , systemctl = systemctlPath
      , nsenter = nsenterPath
      , setpriv = setprivPath
      , proxy = proxyPath
      }

loadSettings :: FilePath -> IO Settings
loadSettings manifest = do
  bytes <- BS.readFile manifest
  either (invalid . ("invalid endpoint manifest: " ++)) pure
    (A.eitherDecodeStrict' bytes)

openDirectory :: Fd -> FilePath -> IO Fd
openDirectory (Fd parent) name = withCString name $ \raw ->
  Fd <$> throwErrnoIfMinus1Retry "openat(endpoint directory)" (c_openDirectory parent raw)

openNamespace :: FilePath -> IO Fd
openNamespace path = withCString path $ \raw ->
  Fd <$> throwErrnoIfMinus1Retry "open(namespace)" (c_openNamespace raw)

makeDirectory :: Fd -> FilePath -> IO ()
makeDirectory (Fd parent) name = withCString name $ \raw -> do
  result <- c_makeDirectory parent raw
  when (result == -1) $ do
    errno <- getErrno
    unless (errno == eEXIST) $ throwErrno "mkdirat(endpoint directory)"

withDirectories :: Fd -> [String] -> (Fd -> IO a) -> IO a
withDirectories current [] action = action current
withDirectories current (part : rest) action =
  bracket (openDirectory current part) closeFd $ \next ->
    withDirectories next rest action

withEndpointDirectories :: Fd -> [String] -> (Fd -> IO a) -> IO a
withEndpointDirectories current [] action = action current
withEndpointDirectories current (part : rest) action = do
  makeDirectory current part
  bracket (openDirectory current part) closeFd $ \next ->
    withEndpointDirectories next rest action

prepare :: Settings -> IO ()
prepare settings = do
  let location = socketLocation settings
  bracket (openDirectory (Fd (-100)) "/") closeFd $ \top ->
    withDirectories top (runtimeComponents location) $ \runtime ->
      withEndpointDirectories runtime (socketDirectories location) $ \parent ->
        withCString (socketFilename location) $ \name -> do
          let Fd raw = parent
          result <- c_objectExists raw name
          case result of
            0 -> pure ()
            1 -> invalid ("refusing to replace existing object " ++ socketPath settings ++
                          "; stop its owning unit and inspect it before removing it")
            _ -> throwErrno "openat(endpoint preflight)"

validateActivation :: Settings -> IO ()
validateActivation settings = do
  myself <- getProcessID
  actualPid <- lookupEnv "LISTEN_PID"
  unless (actualPid == Just (show myself)) $
    invalid "socket activation belongs to another process"
  fds <- lookupEnv "LISTEN_FDS"
  unless (fds == Just "1") $
    invalid "expected exactly one inherited listening descriptor"
  names <- lookupEnv "LISTEN_FDNAMES"
  unless (names == Just (descriptor settings)) $
    invalid "unexpected listening descriptor name"
  matched <- withCString (socketPath settings) $ \path ->
    throwErrnoIfMinus1Retry "inspect socket activation fd 3" (c_socketMatches 3 path)
  unless (matched == 1) $
    invalid "descriptor 3 is not the declared Unix stream listener"

pidfdOpen :: ProcessID -> IO Fd
pidfdOpen pid = Fd <$> throwErrnoIfMinus1Retry "pidfd_open"
  (c_pidfdOpen (fromIntegral pid))

pidfdExited :: Fd -> Int -> IO Bool
pidfdExited (Fd fd) milliseconds = do
  state <- throwErrnoIfMinus1Retry "poll(pidfd)" (c_pidfdExited fd (fromIntegral milliseconds))
  pure (state /= 0)

sameNamespace :: Fd -> Fd -> IO Bool
sameNamespace first second = do
  a <- getFdStatus first
  b <- getFdStatus second
  pure (deviceID a == deviceID b && fileID a == fileID b)

ownerState :: Settings -> IO (Map.Map String String)
ownerState settings = do
  environment <- getEnvironment
  let unsafeKeys = ["LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES",
                    "LISTEN_PIDFDID", "NOTIFY_SOCKET"]
      clean = filter (\(key, _) -> key `notElem` unsafeKeys) environment
      process = (proc (systemctl settings)
        ["--user", "show", owner settings, "--property=MainPID", "--property=ActiveState"])
        { env = Just clean, close_fds = True }
  reply <- timeout 5000000 (readCreateProcessWithExitCode process "")
  case reply of
    Nothing -> invalid "timed out querying the owning service"
    Just (ExitFailure _, _, details) -> invalid ("cannot query owner state: " ++ details)
    Just (ExitSuccess, output, _) ->
      pure (Map.fromList [ (key, contents)
                          | line <- lines output,
                            let (key, value) = break (== '=') line,
                            '=' : contents <- [value]])

attachReady :: Settings -> FilePath -> IO Bool
attachReady settings manifest = do
  state <- ownerState settings
  let pid = Map.lookup "MainPID" state >>= (readMaybe :: String -> Maybe Int)
  case (Map.lookup "ActiveState" state, pid) of
    (Just active, Just number)
      | active `elem` ["active", "reloading"] && number > 0 ->
          withOwner (fromIntegral number)
    _ -> pure False
  where
    withOwner pid =
      bracket (pidfdOpen pid) closeFd $ \ownerFd -> do
        bracket (openNamespace ("/proc/" ++ show pid ++ "/ns/user")) closeFd $ \userFd ->
          bracket (openNamespace ("/proc/" ++ show pid ++ "/ns/net")) closeFd $ \netFd ->
            bracket (openNamespace "/proc/self/ns/net") closeFd $ \hostFd -> do
              isolated <- not <$> sameNamespace netFd hostFd
              unless isolated $
                invalid "the owning service has not entered a private network namespace"
              dead <- pidfdExited ownerFd 0
              updated <- ownerState settings
              unless (not dead && Map.lookup "MainPID" updated == Just (show pid)) $
                invalid "the owning service changed during namespace setup"
              let descriptors = [ownerFd, userFd, netFd, hostFd]
              mapM_ (\fd -> setFdOption fd CloseOnExec False) descriptors
              binary <- getExecutablePath
              let arguments =
                    [ "--user=/proc/self/fd/" ++ showFd userFd
                    , "--net=/proc/self/fd/" ++ showFd netFd
                    , "--preserve-credentials", "--keep-caps"
                    , setpriv settings, "--bounding-set=-all", "--inh-caps=-all"
                    , "--ambient-caps=-all", binary, "endpoint", "joined", manifest
                    ] ++ map showFd descriptors
              executeFile (nsenter settings) False arguments Nothing
    showFd (Fd fd) = show fd

attach :: IORef Bool -> Settings -> FilePath -> Double -> IO ExitCode
attach interrupted settings manifest duration = do
  start <- getMonotonicTimeNSec
  let deadline = start + floor (duration * 1000000000)
      loop lastProblem = do
        stopped <- readIORef interrupted
        if stopped
          then pure ExitSuccess
          else do
            now <- getMonotonicTimeNSec
            if now >= deadline
              then invalid ("cannot enter " ++ owner settings ++
                            "'s private namespace: " ++ lastProblem)
              else do
                outcome <- (Right <$> attachReady settings manifest)
                  `catch` (\(err :: IOException) -> pure (Left (displayException err)))
                let problem = case outcome of
                      Left message -> message
                      Right _ -> "the owning service is not ready"
                threadDelay 100000
                loop problem
  validateActivation settings
  loop "the owning service is not ready"

requireCapabilitiesDropped :: IO ()
requireCapabilitiesDropped = do
  status <- readFile "/proc/self/status"
  let properties = Map.fromList
        [ (key, drop 1 remainder)
        | line <- lines status,
          let (key, remainder) = break (== ':') line,
          not (null remainder) ]
      zero key = case Map.lookup key properties of
        Nothing -> False
        Just value ->
          case readHex (dropWhile isSpace value) :: [(Integer, String)] of
            [(number, rest)] -> number == 0 && all isSpace rest
            _ -> False
  unless (all zero ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"]) $
    invalid "namespace setup capabilities were not dropped"

sendPidfd :: Fd -> Signal -> IO ()
sendPidfd (Fd fd) number = do
  result <- c_pidfdSignal fd (fromIntegral number)
  when (result == -1) $ do
    errno <- getErrno
    unless (errno == eSRCH) $
      throwErrno "pidfd_send_signal(endpoint proxy)"

terminateChild :: ProcessID -> Fd -> IO ()
terminateChild child childFd = do
  dead <- pidfdExited childFd 0
  unless dead $ do
    sendPidfd childFd sigTERM
    stopped <- pidfdExited childFd 5000
    unless stopped $ do
      sendPidfd childFd sigKILL
      void (pidfdExited childFd 1000)
  -- Never block unboundedly or signal the numeric PID after reaping.
  void (getProcessStatus False False child `catch`
        (\(_ :: IOException) -> pure Nothing))

startProxy :: Settings -> [Fd] -> IO (ProcessID, Fd)
startProxy settings descriptors = do
  child <- forkProcess $ do
    result <- (Right <$> do
      mapM_ closeFd descriptors
      environment <- getEnvironment
      myself <- getProcessID
      setFdOption (Fd 3) CloseOnExec False
      let clean = filter (\(name, _) ->
            name `notElem` ["LISTEN_PID", "LISTEN_PIDFDID", "NOTIFY_SOCKET"])
            environment
          inherited = ("LISTEN_PID", show myself) : clean
      executeFile (proxy settings) False
        ["127.0.0.1:" ++ show (port settings)] (Just inherited))
      `catch` (\(err :: IOException) -> pure (Left err))
    case result of
      Left err -> hPutStrLn stderr ("Cannot start endpoint proxy: " ++ displayException err)
      Right (_ :: ()) -> hPutStrLn stderr "Endpoint proxy unexpectedly returned"
    exitImmediately (ExitFailure 127)
  closeFd (Fd 3)
  childFd <- pidfdOpen child `catch` \(err :: IOException) -> do
    signalProcess sigTERM child
    invalid ("cannot pin the endpoint proxy: " ++ displayException err)
  pure (child, childFd)

joined :: IORef Bool -> Settings -> [Fd] -> IO ExitCode
joined interrupted settings handles = do
  let raw = map (\(Fd fd) -> fd) handles
  (ownerFd, userFd, netFd, hostFd) <-
    case handles of
      [ownerFd, userFd, netFd, hostFd]
        | all (> 3) raw && length (Map.fromList [(fd, ()) | fd <- raw]) == 4 ->
            pure (ownerFd, userFd, netFd, hostFd)
      _ -> invalid "invalid private namespace handles"
  validateActivation settings
  requireCapabilitiesDropped
  bracket (openNamespace "/proc/self/ns/net") closeFd $ \currentNet -> do
    expected <- sameNamespace currentNet netFd
    host <- sameNamespace hostFd netFd
    unless (expected && not host) $
      invalid "refusing to forward outside the intended private network namespace"
  bracket (openNamespace "/proc/self/ns/user") closeFd $ \currentUser -> do
    expected <- sameNamespace currentUser userFd
    unless expected $ invalid "wrong user namespace"
  stopped <- pidfdExited ownerFd 0
  when stopped $ invalid "the owning service exited before forwarding started"
  finally
    (bracket (startProxy settings handles)
      (\(pid, childFd) -> terminateChild pid childFd `finally` closeFd childFd)
      (\(_, childFd) -> watch childFd ownerFd))
    (mapM_ (\fd -> closeFd fd `catch` (\(_ :: IOException) -> pure ())) handles)
  where
    watch childFd ownerFd = do
      requested <- readIORef interrupted
      if requested
        then pure ExitSuccess
        else do
          ownerGone <- pidfdExited ownerFd 0
          if ownerGone
            then pure ExitSuccess
            else do
              proxyGone <- pidfdExited childFd 0
              if proxyGone
                then pure (ExitFailure 1)
                else threadDelay 200000 >> watch childFd ownerFd

withSignals :: (IORef Bool -> IO a) -> IO a
withSignals action = do
  requested <- newIORef False
  let handler = Catch (writeIORef requested True)
  bracket
    (do oldTerm <- installHandler sigTERM handler Nothing
        oldInt <- installHandler sigINT handler Nothing
        pure (oldTerm, oldInt))
    (\(oldTerm, oldInt) -> do
        void (installHandler sigINT oldInt Nothing)
        void (installHandler sigTERM oldTerm Nothing))
    (const (action requested))

usage :: String
usage = "Usage: hostenv-system endpoint prepare MANIFEST | serve MANIFEST [--timeout=SECONDS] | joined MANIFEST OWNERFD USERFD NETFD HOSTFD"

dispatch :: IORef Bool -> [String] -> IO ExitCode
dispatch _ ["prepare", manifest] = loadSettings manifest >>= prepare >> pure ExitSuccess
dispatch stop ["serve", manifest] = do
  settings <- loadSettings manifest
  attach stop settings manifest 120
dispatch stop ["serve", manifest, option]
  | Just duration <- stripTimeout option = do
      settings <- loadSettings manifest
      attach stop settings manifest duration
dispatch stop ("joined" : manifest : raw) | length raw == 4 = do
  settings <- loadSettings manifest
  fds <- maybe (invalid "invalid namespace descriptor numbers") pure
    (traverse (readMaybe :: String -> Maybe CInt) raw)
  joined stop settings (map Fd fds)
dispatch _ _ = invalid usage

stripTimeout :: String -> Maybe Double
stripTimeout option = do
  raw <- T.stripPrefix "--timeout=" (T.pack option)
  seconds <- readMaybe (T.unpack raw)
  if seconds > 0 && seconds <= 3600 && not (isNaN seconds || isInfinite seconds)
    then Just seconds
    else Nothing

run :: [String] -> IO ExitCode
run arguments = withSignals $ \interrupted ->
  dispatch interrupted arguments `catch` \(err :: IOException) -> do
    hPutStrLn stderr ("Cannot export endpoint: " ++ displayException err)
    pure (ExitFailure 1)
