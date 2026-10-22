{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Forward connections from systemd Unix sockets to TCP listeners in
-- private network namespaces, and supervise the forwarding processes.
module Hostenv.System.Endpoint (run) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, catch, displayException, finally)
import Control.Monad (unless, void, when)
import Data.Aeson (FromJSON (..), (.:), withObject)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import Data.Char (isSpace)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Foreign.C.Error (eEXIST, eSRCH, getErrno, throwErrno, throwErrnoIfMinus1Retry)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (readHex)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( deviceID, fileID, getExtendedFileStatus, getFdStatus
  , pattern StatxType, pattern SymlinkNoFollow
  )
import System.Posix.IO
  ( FdOption (CloseOnExec), OpenFileFlags (cloexec, directory, nofollow)
  , OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd, openFdAt, setFdOption
  )
import System.Posix.Process
  (executeFile, exitImmediately, forkProcess, getProcessID, getProcessStatus)
import System.Posix.Signals
  (Handler (Catch), Signal, installHandler, sigINT, sigKILL, sigTERM, signalProcess)
import System.Posix.Types (Fd (..), ProcessID)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- These C helpers create directories relative to an open descriptor,
-- validate socket activation and monitor processes on Linux.
foreign import ccall unsafe "hostenv_endpoint_make_directory"
  c_makeDirectory :: CInt -> CString -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_socket_matches"
  c_socketMatches :: CInt -> CString -> IO CInt
foreign import ccall safe "hostenv_endpoint_ipv6_accepts_ipv4"
  c_ipv6AcceptsIPv4 :: CInt -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_pidfd_open"
  c_pidfdOpen :: CInt -> IO CInt
foreign import ccall safe "hostenv_endpoint_pidfd_exited"
  c_pidfdExited :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "hostenv_endpoint_pidfd_signal"
  c_pidfdSignal :: CInt -> CInt -> IO CInt

-- | A socket path split into components for safe directory traversal.
-- The runtime components locate the environment's runtime directory;
-- the socket directories lead from there to the socket's parent.
data SocketLocation = SocketLocation
  { runtimeComponents :: [FilePath]
  , socketDirectories :: [FilePath]
  , socketFilename :: FilePath
  } deriving (Show)

-- | One endpoint's systemd service, Unix socket, activation descriptor and
-- destination TCP port, read from the generated JSON manifest.
data Settings = Settings
  { owner :: String
  , socketPath :: FilePath
  , socketLocation :: SocketLocation
  , descriptor :: String
  , port :: Int
  } deriving (Show)

invalid :: String -> IO a
invalid = ioError . userError

-- | Split an absolute path into components, rejecting empty components,
-- "." and "..", and embedded NUL bytes.
absoluteParts :: FilePath -> Either String [String]
absoluteParts path =
  case T.splitOn "/" (T.pack path) of
    "" : parts
      | not (null parts) && all validPart parts ->
          Right (map T.unpack parts)
    _ -> Left "socket and runtime paths must be absolute, normalised and contain no NUL bytes"
  where
    validPart part = not (T.null part) && part /= "." && part /= ".."
      && not (T.any (== '\NUL') part)

-- | Check that the socket is inside the environment's runtime directory and
-- short enough for a Unix socket address, then split it for safe traversal.
parseSocketLocation :: FilePath -> FilePath -> Either String SocketLocation
parseSocketLocation runtime path = do
  root <- absoluteParts runtime
  socket <- absoluteParts path
  relative <- maybe (Left "the export must be inside the environment's runtime directory")
                    Right (stripPrefix root socket)
  case reverse relative of
    filename : directories -> do
      -- Unix socket path limits are measured in bytes, not characters.
      unless (BS.length (TE.encodeUtf8 (T.pack path)) < 108) $
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
    runtime <- obj .: "runtime_dir"
    path <- obj .: "socket"
    descriptorName <- obj .: "descriptor"
    privatePort <- obj .: "port"

    location <- either fail pure (parseSocketLocation runtime path)

    pure Settings
      { owner = ownerName
      , socketPath = path
      , socketLocation = location
      , descriptor = descriptorName
      , port = privatePort
      }

-- | Read an endpoint manifest and validate the paths it contains.
loadSettings :: FilePath -> IO Settings
loadSettings manifest = do
  bytes <- BS.readFile manifest
  either (invalid . ("invalid endpoint manifest: " ++)) pure
    (A.eitherDecodeStrict' bytes)

directoryFlags :: OpenFileFlags
directoryFlags = defaultFileFlags
  { nofollow = True
  , directory = True
  , cloexec = True
  }

-- | Open a directory relative to an open parent, refusing symlinks.
openDirectory :: Fd -> FilePath -> IO Fd
openDirectory parent name =
  openFdAt (Just parent) name ReadOnly directoryFlags

-- | Hold a namespace open even if the process that created it exits.
openNamespace :: FilePath -> IO Fd
openNamespace path =
  openFd path ReadOnly (defaultFileFlags { cloexec = True })

makeDirectory :: Fd -> FilePath -> IO ()
makeDirectory (Fd parent) name = withCString name $ \raw -> do
  result <- c_makeDirectory parent raw
  when (result == -1) $ do
    errno <- getErrno
    unless (errno == eEXIST) $ throwErrno "mkdirat(endpoint directory)"

-- | Walk existing directories without following symlinks, closing the
-- directory handles when the action finishes.
withDirectories :: Fd -> [String] -> (Fd -> IO a) -> IO a
withDirectories current [] action = action current
withDirectories current (part : rest) action =
  bracket (openDirectory current part) closeFd $ \next ->
    withDirectories next rest action

-- | Create missing endpoint directories and safely open each one.
withEndpointDirectories :: Fd -> [String] -> (Fd -> IO a) -> IO a
withEndpointDirectories current [] action = action current
withEndpointDirectories current (part : rest) action = do
  makeDirectory current part
  bracket (openDirectory current part) closeFd $ \next ->
    withEndpointDirectories next rest action

-- | Check the final path component relative to its opened parent directory.
-- A dangling symlink counts as an existing object.
socketObjectExists :: Fd -> FilePath -> IO Bool
socketObjectExists parent name =
  (getExtendedFileStatus (Just parent) name SymlinkNoFollow StatxType >> pure True)
    `catch` \(err :: IOException) ->
      if isDoesNotExistError err then pure False else ioError err

-- | Create the socket's parent directories, refusing all existing objects.
-- An abandoned socket cannot reliably be distinguished from a live socket
-- that has bound its pathname but has not started listening.
prepare :: Settings -> IO ()
prepare settings = do
  let location = socketLocation settings
  bracket (openFd "/" ReadOnly directoryFlags) closeFd $ \top ->
    withDirectories top (runtimeComponents location) $ \runtime ->
      withEndpointDirectories runtime (socketDirectories location) $ \parent -> do
        exists <- socketObjectExists parent (socketFilename location)
        when exists $
          invalid ("refusing to replace existing object " ++ socketPath settings ++
                   "; stop its owning unit and inspect it before removing it")

-- | Check that systemd passed exactly the Unix listening socket named in
-- the manifest before forwarding any connections.
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

-- | Hold a reference to a particular process even if its numeric PID is
-- later reused by another process.
pidfdOpen :: ProcessID -> IO Fd
pidfdOpen pid = Fd <$> throwErrnoIfMinus1Retry "pidfd_open"
  (c_pidfdOpen (fromIntegral pid))

-- | Check whether a pinned process has exited, waiting at most the given
-- number of milliseconds.
pidfdExited :: Fd -> Int -> IO Bool
pidfdExited (Fd fd) milliseconds = do
  state <- throwErrnoIfMinus1Retry "poll(pidfd)" (c_pidfdExited fd (fromIntegral milliseconds))
  pure (state /= 0)

-- | Check whether two open descriptors refer to the same kernel namespace.
sameNamespace :: Fd -> Fd -> IO Bool
sameNamespace first second = do
  a <- getFdStatus first
  b <- getFdStatus second
  pure (deviceID a == deviceID b && fileID a == fileID b)

-- | Read the owning service's main PID and state from the user systemd
-- manager. Remove inherited socket-activation variables before calling
-- systemctl.
ownerState :: Settings -> IO (Map.Map String String)
ownerState settings = do
  environment <- getEnvironment
  let unsafeKeys = ["LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES",
                    "LISTEN_PIDFDID", "NOTIFY_SOCKET"]
      clean = filter (\(key, _) -> key `notElem` unsafeKeys) environment
      process = (proc "systemctl"
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

-- | Check for a TCP listener on IPv4 loopback in the owner's network
-- namespace. Reading the kernel's socket table avoids making a dummy
-- connection to the application.
tcpListening :: ProcessID -> Int -> IO Bool
tcpListening pid destination = do
  ipv4 <- B8.readFile ("/proc/" ++ show pid ++ "/net/tcp")
  if any (listensAt ["0100007F", "00000000"]) (B8.lines ipv4) then
    pure True
  else do
    -- An IPv6 socket table may be unavailable when IPv6 is disabled.
    ipv6 <- B8.readFile ("/proc/" ++ show pid ++ "/net/tcp6")
      `catch` \(err :: IOException) ->
        if isDoesNotExistError err then pure B8.empty else ioError err
    pure (any (listensAt ["00000000000000000000000000000000"]) (B8.lines ipv6))
  where
    listensAt addresses row =
      case B8.words row of
        _ : local : _ : state : _
          | state == "0A" ->
              let (address, encodedPort) = B8.break (== ':') local
              in address `elem` addresses &&
                 (case readHex (B8.unpack (B8.drop 1 encodedPort)) of
                    [(number, "")] -> number == destination
                    _ -> False)
        _ -> False

-- | Enter the owner's namespaces once systemd considers it ready and its
-- TCP listener is open. Otherwise return a reason to keep waiting.
attachReady :: Settings -> FilePath -> Word64 -> IO String
attachReady settings manifest deadline = do
  state <- ownerState settings
  let pid = Map.lookup "MainPID" state >>= (readMaybe :: String -> Maybe Int)
  case (Map.lookup "ActiveState" state, pid) of
    (Just active, Just number)
      | active `elem` ["active", "reloading"] && number > 0 ->
          withOwner (fromIntegral number)
    _ -> pure "the owning service is not active"
  where
    withOwner pid =
      bracket (pidfdOpen pid) closeFd $ \ownerFd -> do
        bracket (openNamespace ("/proc/" ++ show pid ++ "/ns/user")) closeFd $ \userFd ->
          bracket (openNamespace ("/proc/" ++ show pid ++ "/ns/net")) closeFd $ \netFd -> do
            bracket (openNamespace "/proc/self/ns/net") closeFd $ \hostFd -> do
              isolated <- not <$> sameNamespace netFd hostFd
              unless isolated $
                invalid "the owning service has not entered a private network namespace"
            dead <- pidfdExited ownerFd 0
            updated <- ownerState settings
            unless (not dead && Map.lookup "MainPID" updated == Just (show pid)) $
              invalid "the owning service changed during namespace setup"
            listening <- tcpListening pid (port settings)
            if not listening then
              pure ("TCP listener on 127.0.0.1:" ++ show (port settings) ++ " is not ready")
            else do
              -- Keep these handles open across exec so the next process can
              -- verify its namespaces and detect when the owner exits.
              let descriptors = [ownerFd, userFd, netFd]
              mapM_ (\fd -> setFdOption fd CloseOnExec False) descriptors
              binary <- getExecutablePath
              let arguments =
                    [ "--user=/proc/self/fd/" ++ showFd userFd
                    , "--net=/proc/self/fd/" ++ showFd netFd
                    , "--preserve-credentials", "--keep-caps"
                    , "setpriv", "--bounding-set=-all", "--inh-caps=-all"
                    , "--ambient-caps=-all", binary, "endpoint", "joined", manifest
                    ] ++ map showFd descriptors ++ [show deadline]
              executeFile "nsenter" True arguments Nothing
    showFd (Fd fd) = show fd

-- | Keep the socket-activated process alive while waiting for the owning
-- service to become ready, up to the requested timeout.
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
              then invalid ("cannot start forwarding to " ++ owner settings ++
                            ": " ++ lastProblem)
              else do
                problem <- attachReady settings manifest deadline
                  `catch` (\(err :: IOException) -> pure (displayException err))
                threadDelay 100000
                loop problem
  validateActivation settings
  loop "the owning service is not active"

-- | Check that no Linux capabilities remain before starting the forwarder.
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

-- | Signal the pinned process, avoiding the risk of signalling a reused PID.
sendPidfd :: Fd -> Signal -> IO ()
sendPidfd (Fd fd) number = do
  result <- c_pidfdSignal fd (fromIntegral number)
  when (result == -1) $ do
    errno <- getErrno
    unless (errno == eSRCH) $
      throwErrno "pidfd_send_signal(endpoint proxy)"

-- | Request a clean stop of the forwarding process, escalate to SIGKILL if
-- necessary, and reap the child.
terminateChild :: ProcessID -> Fd -> IO ()
terminateChild child childFd = do
  dead <- pidfdExited childFd 0
  unless dead $ do
    sendPidfd childFd sigTERM
    stopped <- pidfdExited childFd 5000
    unless stopped $ do
      sendPidfd childFd sigKILL
      void (pidfdExited childFd 1000)
  -- Every signal uses the pidfd so a reused numeric PID cannot be signalled.
  void (getProcessStatus False False child `catch`
        (\(_ :: IOException) -> pure Nothing))

-- | Launch systemd-socket-proxyd with systemd's listening socket, and keep a
-- process handle for monitoring and cleanup.
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
      executeFile "systemd-socket-proxyd" True
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

-- | Check whether an IPv4 listener is present on loopback or all addresses.
ipv4Listening :: Int -> B8.ByteString -> Bool
ipv4Listening destination row =
  case B8.words row of
    _ : local : _ : state : _
      | state == "0A" ->
          let (address, encodedPort) = B8.break (== ':') local
          in address `elem` ["0100007F", "00000000"] &&
             (case readHex (B8.unpack (B8.drop 1 encodedPort)) of
                [(number, "")] -> number == destination
                _ -> False)
    _ -> False

-- | Confirm that the helper entered the owning service's private namespaces,
-- then wait for an IPv4-reachable TCP listener and supervise the forwarder.
-- Keep the original deadline across the namespace hand-off.
joined :: IORef Bool -> Settings -> [Fd] -> Word64 -> IO ExitCode
joined interrupted settings handles deadline = do
  let raw = map (\(Fd fd) -> fd) handles
  (ownerFd, userFd, netFd) <-
    case handles of
      [ownerFd, userFd, netFd]
        | all (> 3) raw && length (Map.fromList [(fd, ()) | fd <- raw]) == 3 ->
            pure (ownerFd, userFd, netFd)
      _ -> invalid "invalid private namespace handles"
  validateActivation settings
  requireCapabilitiesDropped
  bracket (openNamespace "/proc/self/ns/net") closeFd $ \currentNet -> do
    expected <- sameNamespace currentNet netFd
    unless expected $
      invalid "refusing to forward outside the intended private network namespace"
  bracket (openNamespace "/proc/self/ns/user") closeFd $ \currentUser -> do
    expected <- sameNamespace currentUser userFd
    unless expected $ invalid "wrong user namespace"
  finally
    (do ready <- waitForListener ownerFd
        if ready
          then bracket (startProxy settings handles)
            (\(pid, childFd) -> terminateChild pid childFd `finally` closeFd childFd)
            (\(_, childFd) -> watch childFd ownerFd)
          else pure ExitSuccess)
    (mapM_ (\fd -> closeFd fd `catch` (\(_ :: IOException) -> pure ())) handles)
  where
    -- An IPv6 wildcard listener may be IPv6-only. Keep the helper and its
    -- pinned namespace alive until an IPv4 listener or a dual-stack listener
    -- becomes available. Never open a connection to the application.
    waitForListener ownerFd = do
      requested <- readIORef interrupted
      if requested
        then pure False
        else do
          ownerGone <- pidfdExited ownerFd 0
          if ownerGone
            then pure False
            else do
              now <- getMonotonicTimeNSec
              if now >= deadline
                then invalid ("cannot start forwarding to " ++ owner settings ++
                              ": TCP listener on 127.0.0.1:" ++
                              show (port settings) ++ " is not ready")
                else do
                  ipv4 <- B8.readFile "/proc/self/net/tcp"
                  if any (ipv4Listening (port settings)) (B8.lines ipv4)
                    then pure True
                    else do
                      -- Inet-diag reports IPV6_V6ONLY without consuming a
                      -- connection that belongs to a real client.
                      compatible <- throwErrnoIfMinus1Retry "inspect IPv6 listener" $
                        c_ipv6AcceptsIPv4 (fromIntegral (port settings))
                      if compatible == 1
                        then pure True
                        else threadDelay 100000 >> waitForListener ownerFd

    -- A proxy exit while its owner is running is a failure, so systemd can
    -- restart the forwarding service.
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

-- | Record termination requests so the forwarder can be stopped and cleaned
-- up before the helper exits.
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
usage = "Usage: hostenv-system endpoint prepare MANIFEST | serve MANIFEST [--timeout=SECONDS] | joined MANIFEST OWNERFD USERFD NETFD DEADLINE_NS"

-- | Prepare the socket path, serve an activated socket, or resume forwarding
-- after joining the owning service's namespaces.
dispatch :: IORef Bool -> [String] -> IO ExitCode
dispatch _ ["prepare", manifest] = loadSettings manifest >>= prepare >> pure ExitSuccess
dispatch stop ["serve", manifest] = do
  settings <- loadSettings manifest
  attach stop settings manifest 120
dispatch stop ["serve", manifest, option]
  | Just duration <- stripTimeout option = do
      settings <- loadSettings manifest
      attach stop settings manifest duration
dispatch stop ["joined", manifest, ownerRaw, userRaw, netRaw, deadlineRaw] = do
  settings <- loadSettings manifest
  fds <- maybe (invalid "invalid namespace descriptor numbers") pure
    (traverse (readMaybe :: String -> Maybe CInt) [ownerRaw, userRaw, netRaw])
  deadline <- maybe (invalid "invalid forwarding deadline") pure
    (readMaybe deadlineRaw :: Maybe Word64)
  joined stop settings (map Fd fds) deadline
dispatch _ _ = invalid usage

-- | Parse a positive, finite timeout of at most one hour.
stripTimeout :: String -> Maybe Double
stripTimeout option = do
  raw <- T.stripPrefix "--timeout=" (T.pack option)
  seconds <- readMaybe (T.unpack raw)
  if seconds > 0 && seconds <= 3600 && not (isNaN seconds || isInfinite seconds)
    then Just seconds
    else Nothing

-- | Run an endpoint command and report operating-system errors as readable
-- messages with a failed exit status.
run :: [String] -> IO ExitCode
run arguments = withSignals $ \interrupted ->
  dispatch interrupted arguments `catch` \(err :: IOException) -> do
    hPutStrLn stderr ("Cannot export endpoint: " ++ displayException err)
    pure (ExitFailure 1)
