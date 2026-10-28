{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Project
  ( addProjectFlow
  , ensureWebhook
  , regenerateFlake
  , syncFlakeFromDb
  , writeGitCredentials
  ) where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Char8 as BSC
import Database.PostgreSQL.Simple (Connection, Only (..), execute, query, query_)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)
import System.Posix.Files (setFileMode)

import Hostenv.Provider.Command (commandErrorText, runCommand)
import Hostenv.Provider.Config (AppConfig(..), appWorkDir, resolvePath)
import Hostenv.Provider.DB (ProjectRow(..), SessionInfo(..), User(..), loadProjects, withDb)
import Hostenv.Provider.Gitlab (GitlabHook(..), GitlabProject(..), createGitlabWebhook, fetchGitlabProject, updateGitlabWebhook)
import Hostenv.Provider.Service (CommandSpec(..), projectHashFor, renderFlakeTemplate, renderGitCredentials, renderProjectInputs)
import Hostenv.Provider.Util (randomToken, sanitizeName, splitNamespace)
import Hostenv.Provider.Webhook (loadPlan)


syncFlakeFromDb :: AppConfig -> IO ()
syncFlakeFromDb cfg = do
  projects <- withDb cfg loadProjects
  _ <- regenerateFlake cfg projects
  writeGitCredentials cfg
  pure ()

addProjectFlow :: AppConfig -> SessionInfo -> Int64 -> Maybe Text -> Maybe Text -> IO (Either Text Text)
addProjectFlow cfg sess repoId orgInput projectInput = withDb cfg $ \conn -> do
  let SessionInfo { sessionUser = User { userId = userIdVal } } = sess
  tokenRows <- query conn "SELECT git_host, token FROM gitlab_tokens WHERE user_id = ? AND project_id IS NULL ORDER BY created_at DESC LIMIT 1" (Only userIdVal)
  case tokenRows of
    [] -> pure (Left "No GitLab access token is available. Sign out, then sign in again.")
    ((host, token):_) -> do
      projectInfo <- fetchGitlabProject cfg host token repoId
      case projectInfo of
        Left msg -> pure (Left msg)
        Right repo -> do
          let (defaultOrg, defaultProject) = splitNamespace repo.glProjectPath
          let orgCandidate = fromMaybe defaultOrg orgInput
          let projCandidate = fromMaybe defaultProject projectInput
          let org = if T.strip orgCandidate == "" then sanitizeName defaultOrg else sanitizeName orgCandidate
          let proj = if T.strip projCandidate == "" then sanitizeName defaultProject else sanitizeName projCandidate
          if org == "" || proj == ""
            then pure (Left "Hostenv could not determine a valid organisation and project name. Enter both values and try again.")
            else do
              let flakeInput = org <> "__" <> proj
              [projectRow] <- query conn
                "INSERT INTO projects (org, project, git_host, repo_id, repo_url, repo_path, flake_input) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (git_host, repo_id) DO UPDATE SET org = EXCLUDED.org, project = EXCLUDED.project, repo_url = EXCLUDED.repo_url, repo_path = EXCLUDED.repo_path, flake_input = EXCLUDED.flake_input, updated_at = now() RETURNING id, org, project, git_host, repo_id, repo_url, repo_path, flake_input, default_env_hash"
                (org, proj, host, repo.glProjectId, repo.glProjectHttpUrl, repo.glProjectPath, flakeInput)
              let ProjectRow { projectId = projectIdVal } = projectRow
              _ <- execute conn "DELETE FROM gitlab_tokens WHERE project_id = ?" (Only projectIdVal)
              _ <- execute conn "INSERT INTO gitlab_tokens (user_id, project_id, git_host, token, scopes) VALUES (?, ?, ?, ?, ?)" (userIdVal, projectIdVal, host, token, ("api read_repository" :: Text))
              writeGitCredentials cfg
              regenResult <- regenerateFlake cfg =<< loadProjects conn
              case regenResult of
                Left msg -> pure (Left msg)
                Right _ -> do
                  cmdRes <- runCommand cfg (CommandSpec "nix" ["flake", "update", flakeInput] (appWorkDir cfg))
                  case cmdRes of
                    Left err -> pure (Left (commandErrorText err))
                    Right _ -> do
                      planRes <- runCommand cfg (CommandSpec "nix" ["run", ".#hostenv-provider", "--", "plan"] (appWorkDir cfg))
                      case planRes of
                        Left err -> pure (Left (commandErrorText err))
                        Right _ -> do
                          planRaw <- loadPlan cfg
                          case projectHashFor org proj planRaw of
                            Left err -> pure (Left err)
                            Right projHash -> do
                              _ <- execute conn "UPDATE projects SET default_env_hash = ?, updated_at = now() WHERE id = ?" (projHash, projectIdVal)
                              webhookResult <- ensureWebhook cfg conn host token repoId projectRow projHash
                              case webhookResult of
                                Left msg -> pure (Left msg)
                                Right (secret, _) -> do
                                  maybeWriteSecret cfg projHash org proj secret
                                  let AppConfig { appWebhookHost = webhookHost } = cfg
                                  let hookUrl = "https://" <> webhookHost <> "/webhook/" <> projHash
                                  pure (Right ("GitLab webhook configured at " <> hookUrl))

ensureWebhook :: AppConfig -> Connection -> Text -> Text -> Int64 -> ProjectRow -> Text -> IO (Either Text (Text, Maybe Int64))
ensureWebhook cfg conn host token repoId projectRow projHash = do
  let ProjectRow { projectId = projectIdVal } = projectRow
  existing <- query conn "SELECT secret, webhook_id FROM webhooks WHERE project_id = ?" (Only projectIdVal)
  (secret, hookId) <- case existing of
    ((s, mId):_) -> pure (s, mId)
    [] -> do
      s <- randomToken 24
      pure (s, Nothing)
  let AppConfig { appWebhookHost = webhookHost } = cfg
  let url = "https://" <> webhookHost <> "/webhook/" <> projHash
  hookResult <- case hookId of
    Just hid -> do
      updated <- updateGitlabWebhook cfg host token repoId hid url secret
      case updated of
        Left _ -> createGitlabWebhook cfg host token repoId url secret
        Right hook -> pure (Right hook)
    Nothing -> createGitlabWebhook cfg host token repoId url secret
  case hookResult of
    Left msg -> pure (Left msg)
    Right hook -> do
      _ <- execute conn "INSERT INTO webhooks (project_id, secret, webhook_id, webhook_url) VALUES (?, ?, ?, ?) ON CONFLICT (project_id) DO UPDATE SET secret = EXCLUDED.secret, webhook_id = EXCLUDED.webhook_id, webhook_url = EXCLUDED.webhook_url, updated_at = now()" (projectIdVal, secret, hook.glHookId, hook.glHookUrl)
      pure (Right (secret, Just hook.glHookId))

regenerateFlake :: AppConfig -> [ProjectRow] -> IO (Either Text ())
regenerateFlake cfg projects = do
  let AppConfig { appFlakeTemplate = flakeTemplate } = cfg
  let templatePath = resolvePath cfg flakeTemplate
  exists <- doesFileExist templatePath
  if not exists
    then pure (Left ("Flake template not found: " <> T.pack templatePath <> ". Check the provider-service configuration."))
    else do
      templateText <- T.pack <$> readFile templatePath
      let inputs = [ (input, projectInputUrl p) | p@ProjectRow { projectFlakeInput = input } <- projects ]
      let inputBlock = renderProjectInputs inputs
      case renderFlakeTemplate templateText inputBlock of
        Left err -> pure (Left err)
        Right flakeText -> do
          let flakePath = appWorkDir cfg </> "flake.nix"
          writeFile flakePath (T.unpack flakeText)
          pure (Right ())

writeGitCredentials :: AppConfig -> IO ()
writeGitCredentials cfg =
  let AppConfig { appDbConnString = dbConn } = cfg
   in case dbConn of
    Nothing -> pure ()
    Just _ -> do
      entries <- withDb cfg $ \conn -> do
        rows <- query_ conn "SELECT projects.repo_url, gitlab_tokens.token FROM gitlab_tokens JOIN projects ON gitlab_tokens.project_id = projects.id WHERE gitlab_tokens.project_id IS NOT NULL ORDER BY projects.repo_url"
        pure rows
      let credsText = renderGitCredentials entries
      let AppConfig { appGitCredentialsPath = credsPath } = cfg
      createDirectoryIfMissing True (takeDirectory credsPath)
      writeFile credsPath (T.unpack credsText)
      setFileMode credsPath 0o640

projectInputUrl :: ProjectRow -> Text
projectInputUrl p =
  let ProjectRow { projectGitHost = gitHost, projectRepoPath = repoPath } = p
      base = if gitHost == "gitlab.com" then "gitlab:" else "gitlab:" <> gitHost <> "/"
   in base <> repoPath <> "?dir=.hostenv"

maybeWriteSecret :: AppConfig -> Text -> Text -> Text -> Text -> IO ()
maybeWriteSecret cfg hash org proj secret =
  let AppConfig { appWebhookSecretsDir = secretsDir } = cfg
   in case secretsDir of
    Nothing -> pure ()
    Just dir -> do
      createDirectoryIfMissing True dir
      let byHash = dir </> T.unpack hash
      let byProject = dir </> T.unpack (org <> "__" <> proj)
      writeSecretFile byHash secret
      writeSecretFile byProject secret

writeSecretFile :: FilePath -> Text -> IO ()
writeSecretFile path secret = do
  BSC.writeFile path (TE.encodeUtf8 secret)
  setFileMode path 0o640
