{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Config
  ( AppConfig(..)
  , loadConfig
  , appWorkDir
  , resolvePath
  , uiPath
  , normalizeBasePath
  ) where

import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.FilePath ((</>), isAbsolute)

import Hostenv.Provider.Service (GitlabSecrets, WebhookConfig(..), readGitlabSecrets)

-- Configuration

data AppConfig = AppConfig
  { appDataDir :: FilePath
  , appRepoSource :: FilePath
  , appFlakeRoot :: FilePath
  , appListenSocket :: FilePath
  , appWebhookSecretFile :: Maybe FilePath
  , appWebhookSecretsDir :: Maybe FilePath
  , appWebhookConfig :: WebhookConfig
  , appUiBasePath :: Text
  , appUiBaseUrl :: Text
  , appWebhookHost :: Text
  , appDbConnString :: Maybe BS.ByteString
  , appGitlabSecrets :: Maybe GitlabSecrets
  , appGitlabHosts :: [Text]
  , appGitConfigPath :: FilePath
  , appGitCredentialsPath :: FilePath
  , appFlakeTemplate :: FilePath
  , appHttpManager :: Maybe Manager
  }

data ProviderConfigFile = ProviderConfigFile
  { dataDir :: FilePath
  , repoSource :: FilePath
  , flakeRoot :: FilePath
  , listenSocket :: FilePath
  , webhookSecretFile :: Maybe FilePath
  , webhookSecretsDir :: Maybe FilePath
  , webhookHost :: Text
  , uiBasePath :: Text
  , uiBaseUrl :: Text
  , dbUri :: String
  , gitlabOAuthSecretsFile :: Maybe FilePath
  , gitlabHosts :: [Text]
  , gitConfigFile :: FilePath
  , gitCredentialsFile :: FilePath
  , flakeTemplate :: FilePath
  } deriving (Eq, Show, Generic)

instance A.FromJSON ProviderConfigFile

appWorkDir :: AppConfig -> FilePath
appWorkDir cfg = cfg.appDataDir </> cfg.appFlakeRoot

resolvePath :: AppConfig -> FilePath -> FilePath
resolvePath cfg path =
  if isAbsolute path then path else appWorkDir cfg </> path

uiPath :: AppConfig -> Text -> Text
uiPath cfg path =
  let base = normalizeBasePath cfg.appUiBasePath
   in case (base, path) of
        ("/", "/") -> "/"
        ("/", _) -> path
        (_, "/") -> base
        _ -> base <> path

normalizeBasePath :: Text -> Text
normalizeBasePath t =
  let withSlash = if T.isPrefixOf "/" t then t else "/" <> t
      trimmed = T.dropWhileEnd (== '/') withSlash
   in if trimmed == "" then "/" else trimmed

loadConfig :: FilePath -> IO AppConfig
loadConfig configPath = do
  providerCfg <- readProviderConfig configPath
  secrets <- case providerCfg.gitlabOAuthSecretsFile of
    Nothing -> pure Nothing
    Just path -> Just <$> readGitlabSecrets path

  manager <- Just <$> newManager tlsManagerSettings

  let workDir = providerCfg.dataDir </> providerCfg.flakeRoot
  let planPath = workDir </> "generated" </> "plan.json"
  let webhookCfg = WebhookConfig workDir planPath

  pure
    AppConfig
      { appDataDir = providerCfg.dataDir
      , appRepoSource = providerCfg.repoSource
      , appFlakeRoot = providerCfg.flakeRoot
      , appListenSocket = providerCfg.listenSocket
      , appWebhookSecretFile = providerCfg.webhookSecretFile
      , appWebhookSecretsDir = providerCfg.webhookSecretsDir
      , appWebhookConfig = webhookCfg
      , appUiBasePath = normalizeBasePath providerCfg.uiBasePath
      , appUiBaseUrl = T.dropWhileEnd (== '/') providerCfg.uiBaseUrl
      , appWebhookHost = providerCfg.webhookHost
      , appDbConnString = Just (BSC.pack providerCfg.dbUri)
      , appGitlabSecrets = secrets
      , appGitlabHosts = if null providerCfg.gitlabHosts then ["gitlab.com"] else providerCfg.gitlabHosts
      , appGitConfigPath = providerCfg.gitConfigFile
      , appGitCredentialsPath = providerCfg.gitCredentialsFile
      , appFlakeTemplate = providerCfg.flakeTemplate
      , appHttpManager = manager
      }

readProviderConfig :: FilePath -> IO ProviderConfigFile
readProviderConfig path = do
  exists <- doesFileExist path
  if not exists
    then dieWith ("Configuration file not found: " <> path)
    else do
      bytes <- BL.readFile path
      case A.eitherDecode' bytes of
        Left err -> dieWith ("Could not read provider configuration file " <> path <> ": " <> err)
        Right cfg -> pure cfg


dieWith :: String -> IO a
dieWith msg = do
  hPutStrLn stderr ("hostenv-provider-service: " <> msg)
  exitFailure
