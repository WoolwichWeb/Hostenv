{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Command
  ( runCommand
  , runCommandOrDie
  , renderCommand
  , commandErrorText
  , exitCodeToInt
  ) where

import qualified Data.Text as T
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Directory (withCurrentDirectory)
import qualified Turtle as Sh

import Hostenv.Provider.Config (AppConfig)
import Hostenv.Provider.Service (CommandError, CommandOutput(..), CommandRunner, CommandSpec(..))
import qualified Hostenv.Provider.Service as Service

runCommand :: AppConfig -> CommandRunner
runCommand _ spec = do
  let cmd = spec.cmdName
  let args = spec.cmdArgs
  let cwd = spec.cmdCwd
  withCurrentDirectory cwd $ do
    (code, out, err) <- Sh.procStrictWithErr cmd args Sh.empty
    case code of
      ExitSuccess -> pure (Right (CommandOutput out err))
      _ -> pure (Left (Service.CommandError spec code out err))

runCommandOrDie :: AppConfig -> CommandSpec -> IO ()
runCommandOrDie cfg spec = do
  res <- runCommand cfg spec
  case res of
    Right _ -> pure ()
    Left err -> do
      hPutStrLn stderr ("hostenv-provider-service: command failed: " <> T.unpack (renderCommand err.errSpec))
      hPutStrLn stderr (T.unpack err.errStderr)
      exitFailure

renderCommand :: CommandSpec -> T.Text
renderCommand spec = T.unwords (spec.cmdName : spec.cmdArgs)

commandErrorText :: CommandError -> T.Text
commandErrorText cmdErr =
  let stdoutText = T.strip cmdErr.errStdout
      stderrText = T.strip cmdErr.errStderr
      exitStatus =
        case cmdErr.errExit of
          ExitSuccess -> "0"
          ExitFailure code -> T.pack (show code)
      details
        | not (T.null stderrText) = ["Error output:\n" <> stderrText]
        | not (T.null stdoutText) = ["Output:\n" <> stdoutText]
        | otherwise = []
   in T.unlines
        ( [ "Command failed: " <> renderCommand cmdErr.errSpec
          , "Exit status: " <> exitStatus
          ]
            <> details
        )

exitCodeToInt :: ExitCode -> Maybe Int
exitCodeToInt ExitSuccess = Just 0
exitCodeToInt (ExitFailure n) = Just n
