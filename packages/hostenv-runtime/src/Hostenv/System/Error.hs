module Hostenv.System.Error
  ( HostenvM
  , HostenvError (..)
  , ErrorContext (..)
  , ErrorCause (..)
  , at
  , withContext
  , checkedIO
  , renderError
  ) where

import Control.Exception (IOException, displayException)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, throwE, withExceptT)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import System.Exit (ExitCode)
import System.IO.Error (tryIOError)

-- Every failure has an origin. Callers prepend context without changing the
-- underlying cause, so rendering and exit-status decisions stay at the CLI.
data HostenvError = HostenvError
  { contexts :: NonEmpty ErrorContext
  , cause :: ErrorCause
  }

data ErrorContext
  = While String
  | ForResource FilePath
  | RunningCommand FilePath [String]

data ErrorCause
  = InvalidInput String
  | InvalidData String
  | Unavailable String
  | LockBusy String
  | InvalidState String
  | CommandFailed ExitCode T.Text
  | TimedOut
  | IOErrorFailure IOException

type HostenvM = ExceptT HostenvError IO

at :: ErrorContext -> ErrorCause -> HostenvM a
at context reason = throwE (HostenvError (context :| []) reason)

withContext :: ErrorContext -> HostenvM a -> HostenvM a
withContext context = withExceptT $ \err ->
  err { contexts = context NE.<| contexts err }

-- Catch only synchronous I/O failures. In particular, cancellation and
-- ThreadKilled must not become ordinary operational errors.
checkedIO :: ErrorContext -> IO a -> HostenvM a
checkedIO context operation = do
  result <- liftIO (tryIOError operation)
  either (at context . IOErrorFailure) pure result

renderError :: HostenvError -> String
renderError (HostenvError stack reason) =
  unlines $
    ["Hostenv operation failed:"]
    ++ map (("  " ++) . renderContext) (NE.toList stack)
    ++ ["  " ++ renderCause reason]
  where
    renderContext (While operation) = "While " ++ operation
    renderContext (ForResource path) = "Resource: " ++ path
    renderContext (RunningCommand program arguments) =
      "Running: " ++ unwords (program : arguments)

    renderCause (InvalidInput message) = "Invalid input: " ++ message
    renderCause (InvalidData message) = "Invalid data: " ++ message
    renderCause (Unavailable message) = message
    renderCause (LockBusy message) = message
    renderCause (InvalidState message) = message
    renderCause (CommandFailed exitCode details) =
      "Command failed (" ++ show exitCode ++ "): " ++ T.unpack (T.strip details)
    renderCause TimedOut = "The operation timed out."
    renderCause (IOErrorFailure err) = displayException err
