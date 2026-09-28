{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Webhook
  ( webhookHandler
  , loadPlan
  ) where

import Control.Concurrent.MVar (MVar, withMVar)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.PostgreSQL.Simple (Only (..), fromOnly, query)
import System.FilePath ((</>))
import Servant

import Hostenv.Provider.Command (exitCodeToInt, renderCommand, runCommand)
import Hostenv.Provider.Config (AppConfig(..))
import Hostenv.Provider.DB (withDb)
import Hostenv.Provider.Http (ErrorResponse(..), errorWithBody)
import Hostenv.Provider.Service
  ( CommandError(..)
  , CommandOutput(..)
  , ProjectRef(..)
  , WebhookConfig(..)
  , WebhookError(..)
  , WebhookResult(..)
  , projectForHash
  , runWebhookWith
  , verifyGitHubSignature
  , verifyGitLabToken
  )
import Hostenv.Provider.Util (pickFirstExisting, readSecret)


loadPlan :: AppConfig -> IO BL.ByteString
loadPlan cfg =
  let AppConfig { appWebhookConfig = WebhookConfig { whPlanPath = planPath } } = cfg
   in BL.readFile planPath

webhookHandler :: MVar () -> AppConfig -> Text -> Maybe Text -> Maybe Text -> BL.ByteString -> Handler WebhookResult
webhookHandler webhookLock cfg hash mHubSig mGitlabToken rawBody = do
  -- Known provider-service limitation:
  --
  -- provider-service is still in development. Webhook URLs currently use an
  -- environment-specific projectNameHash, and this handler resolves that hash
  -- by looking for the environment in the current generated plan. If the
  -- environment whose hash was chosen for the webhook is later removed, the
  -- existing webhook URL can stop resolving even when the project still has
  -- other environments.
  --
  -- Future provider-service work should give projects a stable webhook
  -- identity, or resolve the stored webhook hash through provider-service's
  -- project database instead of requiring the environment to remain in
  -- plan.json. This is accepted follow-up work and is not part of MR 36.
  planRaw <- liftIO (loadPlan cfg)
  projectRef <-
    case projectForHash hash planRaw of
      Left msg ->
        if msg == "webhook hash not found in plan.json"
          then throwError err404
          else throwError (errorWithBody err500 (ErrorResponse msg Nothing Nothing Nothing Nothing))
      Right ref -> pure ref
  secretInfo <- liftIO (resolveSecret cfg hash projectRef)
  verifyWebhook secretInfo mHubSig mGitlabToken rawBody
  let AppConfig { appWebhookConfig = webhookCfg } = cfg
  result <- liftIO $ withMVar webhookLock (\_ -> runWebhookWith (runCommand cfg) (loadPlan cfg) webhookCfg projectRef)
  case result of
    Left err -> throwError (serverError err)
    Right okResult ->
      let WebhookResult { webhookOk = ok } = okResult
       in if ok
            then pure okResult
            else throwError (errorWithBody err500 okResult)


-- Webhook signature resolution

data SecretInfo = SecretInfo
  { secretConfigured :: Bool
  , secretValue :: Maybe BS.ByteString
  }

verifyWebhook :: SecretInfo -> Maybe Text -> Maybe Text -> BL.ByteString -> Handler ()
verifyWebhook secretInfo mHubSig mGitlabToken rawBody = do
  let hasGitHub = mHubSig /= Nothing
  let hasGitLab = mGitlabToken /= Nothing
  case secretInfo.secretValue of
    Nothing ->
      if secretInfo.secretConfigured && (hasGitHub || hasGitLab)
        then throwError (errorWithBody err401 (ErrorResponse "webhook secret not configured" Nothing Nothing Nothing Nothing))
        else if secretInfo.secretConfigured
          then throwError (errorWithBody err401 (ErrorResponse "missing webhook signature" Nothing Nothing Nothing Nothing))
          else pure ()
    Just secret ->
      case (mHubSig, mGitlabToken) of
        (Nothing, Nothing) ->
          throwError (errorWithBody err401 (ErrorResponse "missing webhook signature" Nothing Nothing Nothing Nothing))
        _ -> do
          let githubOk = maybe False (\sigText -> verifyGitHubSignature secret rawBody (TE.encodeUtf8 sigText)) mHubSig
          let gitlabOk = maybe False (\tokText -> verifyGitLabToken secret (TE.encodeUtf8 tokText)) mGitlabToken
          unless (githubOk || gitlabOk) $
            throwError (errorWithBody err401 (ErrorResponse "invalid webhook signature" Nothing Nothing Nothing Nothing))

resolveSecret :: AppConfig -> Text -> ProjectRef -> IO SecretInfo
resolveSecret cfg hash ref = do
  let AppConfig
        { appDbConnString = dbConn
        , appWebhookSecretsDir = secretsDir
        , appWebhookSecretFile = secretFile
        } = cfg
  let configured = True
  dbSecret <- case dbConn of
    Nothing -> pure Nothing
    Just _ -> withDb cfg $ \conn -> do
      rows <- query conn "SELECT secret FROM webhooks JOIN projects ON webhooks.project_id = projects.id WHERE projects.default_env_hash = ?" (Only hash)
      pure (listToMaybe (map fromOnly rows))
  case dbSecret of
    Just secret -> pure (SecretInfo configured (Just (TE.encodeUtf8 secret)))
    Nothing -> do
      fromDir <- case secretsDir of
        Nothing -> pure Nothing
        Just dir -> do
          let ProjectRef { prOrg = org, prProject = project } = ref
          let byHash = dir </> T.unpack hash
          let byProject = dir </> T.unpack (org <> "__" <> project)
          pickFirstExisting [byHash, byProject]
      case fromDir of
        Just secret -> pure (SecretInfo configured (Just secret))
        Nothing ->
          case secretFile of
            Nothing -> pure (SecretInfo configured Nothing)
            Just path -> do
              secret <- readSecret path
              pure (SecretInfo configured (Just secret))


-- Webhook error -> HTTP

serverError :: WebhookError -> ServerError
serverError err =
  case err of
    WebhookPlanError msg -> errorWithBody err500 (ErrorResponse msg Nothing Nothing Nothing Nothing)
    WebhookCommandError cmdErr ->
      let CommandError spec exitCodeRaw stdoutText stderrText = cmdErr
          cmd = renderCommand spec
          exitCode = exitCodeToInt exitCodeRaw
          response = ErrorResponse "command failed" (Just cmd) exitCode (Just stdoutText) (Just stderrText)
       in errorWithBody err500 response
