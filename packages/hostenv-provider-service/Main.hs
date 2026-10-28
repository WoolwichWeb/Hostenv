{-# LANGUAGE OverloadedStrings #-}

module Main where

import Hostenv.Provider.Command (runCommandOrDie)
import Hostenv.Provider.Config (appWorkDir, loadConfig)
import Hostenv.Provider.DB (ensureSchema)
import Hostenv.Provider.Project (syncFlakeFromDb)
import Hostenv.Provider.Repo (ensureGitConfig, ensureProviderRepo)
import Hostenv.Provider.Server (runServer)
import Hostenv.Provider.Service (CommandSpec (..))
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    configPath <- case args of
      ["--config", path] -> pure path
      _ -> dieWithUsage
    cfg <- loadConfig configPath
    ensureProviderRepo cfg
    ensureGitConfig cfg
    ensureSchema cfg
    syncFlakeFromDb cfg
    runCommandOrDie cfg (CommandSpec "nix" ["flake", "update"] (appWorkDir cfg))
    runServer cfg

dieWithUsage :: IO a
dieWithUsage = do
  hPutStrLn stderr "Usage: hostenv-provider-service --config PATH"
  exitFailure
