{-# LANGUAGE ForeignFunctionInterface #-}
module Hostenv.System.Lock
  ( LockMode (..)
  , withLockFile
  , tryLock
  , unlock
  ) where

import Control.Exception (bracket, throwIO)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Foreign.C.Error (eAGAIN, eWOULDBLOCK, getErrno, throwErrno)
import Foreign.C.Types (CInt (..))
import System.Directory (doesDirectoryExist)
import System.FilePath (takeDirectory)
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.Posix.Files
  ( fileMode, fileOwner, getFdStatus, getSymbolicLinkStatus, isDirectory
  , isRegularFile, isSymbolicLink, linkCount
  )
import System.Posix.IO
  ( OpenFileFlags (creat, nofollow), OpenMode (ReadOnly, ReadWrite)
  , closeFd, defaultFileFlags, openFd
  )
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)

-- Linux flock locks are attached to an open file description. A child that
-- inherits the descriptor keeps the lock if its parent is killed. POSIX
-- record locks do not provide that guarantee and must not replace flock.
foreign import ccall unsafe "flock" c_flock :: CInt -> CInt -> IO CInt

data LockMode = Shared | Exclusive deriving (Eq, Show)

-- LOCK_SH=1, LOCK_EX=2, LOCK_NB=4 and LOCK_UN=8 on Linux.
tryLock :: Fd -> LockMode -> IO Bool
tryLock (Fd fd) mode = do
  result <- c_flock fd (if mode == Shared then 5 else 6)
  if result == 0
    then pure True
    else do
      errno <- getErrno
      if errno == eWOULDBLOCK || errno == eAGAIN
        then pure False
        else throwErrno "flock"

unlock :: Fd -> IO ()
unlock (Fd fd) = do
  result <- c_flock fd 8
  when (result /= 0) (throwErrno "flock unlock")

-- The directory is owned by the process and inaccessible to other users.
-- Never replace a symlink, directory or multiply-linked lock file.
withLockFile :: FilePath -> Bool -> (Maybe Fd -> IO a) -> IO a
withLockFile path create action = do
  let directory = takeDirectory path
  exists <- doesDirectoryExist directory
  if not exists
    then if create
      then throwIO (userError ("ACME lock directory is not initialised by systemd-tmpfiles: " ++ directory))
      else action Nothing
    else do
      uid <- getEffectiveUserID
      dirStatus <- getSymbolicLinkStatus directory
      unless (isDirectory dirStatus && fileOwner dirStatus == uid
              && fileMode dirStatus .&. 0o077 == 0) $
        throwIO (userError ("ACME lock directory must be private and owned by the caller: " ++ directory))
      link <- tryIOError (getSymbolicLinkStatus path)
      case link of
        Right status | isSymbolicLink status ->
          throwIO (userError ("ACME lock path is a symlink: " ++ path))
        Left err | not (isDoesNotExistError err) -> throwIO err
        Left _ | not create -> action Nothing
        _ -> do
          -- unix >= 2.8 moved creation mode into OpenFileFlags. O_NOFOLLOW
          -- also closes the symlink race between lstat and openFd.
          let flags = defaultFileFlags
                { creat = if create then Just 0o600 else Nothing
                , nofollow = True
                }
          opened <- tryIOError (openFd path (if create then ReadWrite else ReadOnly) flags)
          case opened of
            Left err | not create && isDoesNotExistError err -> action Nothing
            Left err -> throwIO err
            Right fd -> bracket (pure fd) closeFd $ \handle -> do
              status <- getFdStatus handle
              when (not (isRegularFile status) || fileOwner status /= uid
                    || linkCount status /= 1 || fileMode status .&. 0o077 /= 0) $
                throwIO (userError ("ACME lock must be a private regular file owned by the caller: " ++ path))
              action (Just handle)
