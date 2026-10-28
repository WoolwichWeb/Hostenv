{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Repo
  ( ensureProviderRepo
  , ensureGitConfig
  , openUnixSocket
  ) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeFile)
import System.Environment (setEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (setFileMode)
import Network.Socket (Family (AF_UNIX), Socket, SocketType (Stream), SockAddr (SockAddrUnix), bind, defaultProtocol, listen, socket)

import Hostenv.Provider.Command (runCommandOrDie)
import Hostenv.Provider.Config (AppConfig(..), appWorkDir)
import Hostenv.Provider.Service (CommandSpec(..))

ensureProviderRepo :: AppConfig -> IO ()
ensureProviderRepo cfg = do
  let AppConfig { appDataDir = dataDir, appRepoSource = repoSource } = cfg
  createDirectoryIfMissing True dataDir
  createDirectoryIfMissing True (appWorkDir cfg </> "generated")
  let flakePath = appWorkDir cfg </> "flake.nix"
  let statePath = appWorkDir cfg </> "generated" </> "state.json"
  hasFlake <- doesFileExist flakePath
  if hasFlake
    then pure ()
    else do
      srcExists <- doesDirectoryExist repoSource
      if srcExists
        then do
          let srcContents = repoSource </> "."
          runCommandOrDie cfg (CommandSpec "cp" ["-a", "-n", T.pack srcContents, T.pack dataDir] dataDir)
        else do
          hPutStrLn stderr ("hostenv-provider-service: provider repository source not found: " <> repoSource)
          exitFailure
  hasState <- doesFileExist statePath
  if hasState
    then pure ()
    else BL.writeFile statePath "{}\n"

ensureGitConfig :: AppConfig -> IO ()
ensureGitConfig cfg = do
  let AppConfig { appGitConfigPath = gitConfigPath, appGitCredentialsPath = credsPath } = cfg
  createDirectoryIfMissing True (takeDirectory gitConfigPath)
  let content = unlines
        [ "[credential]"
        , "\thelper = store --file " <> credsPath
        ]
  writeFile gitConfigPath content
  setEnv "GIT_CONFIG_GLOBAL" gitConfigPath
  setEnv "GIT_TERMINAL_PROMPT" "0"

openUnixSocket :: FilePath -> IO Socket
openUnixSocket path = do
  createDirectoryIfMissing True (takeDirectory path)
  exists <- doesFileExist path
  if exists
    then removeFile path
    else pure ()
  sock <- socket AF_UNIX Stream defaultProtocol
  bind sock (SockAddrUnix path)
  listen sock 1024
  setFileMode path 0o660
  pure sock
