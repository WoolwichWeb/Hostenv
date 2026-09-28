{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

module Hostenv.Provider.Service
  ( verifyGitHubSignature
  , verifyGitLabToken
  , projectForHash
  , projectHashFor
  , renderProjectInputs
  , renderFlakeTemplate
  , renderGitCredentials
  , GitlabSecrets(..)
  , readGitlabSecrets
  , WebhookConfig(..)
  , ProjectRef(..)
  , CommandSpec(..)
  , CommandOutput(..)
  , CommandError(..)
  , WebhookResult(..)
  , WebhookError(..)
  , CommandRunner
  , runWebhookWith
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Char (toLower)
import Data.List (nub, sort, sortOn)
import Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (..), die)

import "cryptonite" Crypto.Hash (SHA256)
import "cryptonite" Crypto.MAC.HMAC (HMAC (..), hmac)


constantTimeEq :: BS.ByteString -> BS.ByteString -> Bool
constantTimeEq a b = BA.constEq a b

verifyGitHubSignature :: BS.ByteString -> BL.ByteString -> BS.ByteString -> Bool
verifyGitHubSignature secret rawBody header =
  let headerLower = BSC.map toLower header
      prefix = "sha256="
   in case BSC.stripPrefix prefix headerLower of
        Nothing -> False
        Just sigHex ->
          let digest = hmac secret (BL.toStrict rawBody) :: HMAC SHA256
              expected = BAE.convertToBase BAE.Base16 (BA.convert digest :: BS.ByteString)
           in constantTimeEq expected sigHex

verifyGitLabToken :: BS.ByteString -> BS.ByteString -> Bool
verifyGitLabToken secret token = constantTimeEq secret token

lookupText :: KM.Key -> KM.KeyMap Value -> Maybe Text
lookupText key obj = case KM.lookup key obj of
  Just (String t) -> Just t
  _ -> Nothing

lookupObj :: KM.Key -> KM.KeyMap Value -> Maybe (KM.KeyMap Value)
lookupObj key obj = case KM.lookup key obj of
  Just (Object o) -> Just o
  _ -> Nothing

projectEnvironmentPlacements :: Text -> Text -> BL.ByteString -> Either Text [(Text, Text)]
projectEnvironmentPlacements org project raw = do
  envs <- decodeEnvironments raw
  pure . sortOn fst . mapMaybe extractEnvironment $ KM.toList envs
  where
    extractEnvironment (kEnv, vEnv) = case vEnv of
      Object envObj -> do
        hostenvObj <- lookupObj (K.fromString "hostenv") envObj
        org' <- lookupText (K.fromString "organisation") hostenvObj
        project' <- lookupText (K.fromString "project") hostenvObj
        if org' == org && project' == project
          then do
            node <- lookupText (K.fromString "node") envObj
            pure (K.toText kEnv, node)
          else Nothing
      _ -> Nothing

projectForHash :: Text -> BL.ByteString -> Either Text ProjectRef
projectForHash hash raw = do
  envs <- decodeEnvironments raw
  let matches =
        [ ProjectRef org project
        | (_kEnv, vEnv) <- KM.toList envs
        , Just (org, project, projHash) <- [extractHostenv vEnv]
        , projHash == hash
        ]
      uniqueMatches = nub matches
  case uniqueMatches of
    [] -> Left "webhook hash not found in plan.json"
    [ref] -> Right ref
    _ -> Left "webhook hash maps to multiple projects"
  where
    extractHostenv (Object envObj) = do
      hostenvObj <- lookupObj (K.fromString "hostenv") envObj
      org <- lookupText (K.fromString "organisation") hostenvObj
      project <- lookupText (K.fromString "project") hostenvObj
      projHash <- lookupText (K.fromString "projectNameHash") hostenvObj
      pure (org, project, projHash)
    extractHostenv _ = Nothing

projectHashFor :: Text -> Text -> BL.ByteString -> Either Text Text
projectHashFor org project raw = do
  envs <- decodeEnvironments raw
  let matches =
        [ ProjectCandidate envName envType projHash
        | (kEnv, vEnv) <- KM.toList envs
        , let envName = K.toText kEnv
        , Just (envOrg, envProject, projHash, envType) <- [extractCandidate vEnv]
        , envOrg == org
        , envProject == project
        ]
  case chooseCandidate matches of
    Nothing -> Left "project not found in plan.json"
    Just candidate -> Right candidate.candidateHash
  where
    extractCandidate (Object envObj) = do
      hostenvObj <- lookupObj (K.fromString "hostenv") envObj
      envOrg <- lookupText (K.fromString "organisation") hostenvObj
      envProject <- lookupText (K.fromString "project") hostenvObj
      projHash <- lookupText (K.fromString "projectNameHash") hostenvObj
      let envType = lookupText (K.fromString "type") envObj
      pure (envOrg, envProject, projHash, envType)
    extractCandidate _ = Nothing

data ProjectCandidate = ProjectCandidate
  { candidateEnvName :: Text
  , candidateEnvType :: Maybe Text
  , candidateHash :: Text
  } deriving (Eq, Show)

chooseCandidate :: [ProjectCandidate] -> Maybe ProjectCandidate
chooseCandidate [] = Nothing
chooseCandidate candidates =
  let production = filter (\c -> c.candidateEnvType == Just "production") candidates
      mainEnv = filter (\c -> c.candidateEnvName == "main") candidates
      masterEnv = filter (\c -> c.candidateEnvName == "master") candidates
      pick :: [ProjectCandidate] -> Maybe ProjectCandidate
      pick xs = case sortOn (\c -> c.candidateEnvName) xs of
        [] -> Nothing
        (c:_) -> Just c
   in case () of
        _ | not (null production) -> pick production
          | not (null mainEnv) -> pick mainEnv
          | not (null masterEnv) -> pick masterEnv
          | otherwise -> pick candidates

decodeEnvironments :: BL.ByteString -> Either Text (KM.KeyMap Value)
decodeEnvironments raw = do
  root <- decodePlanRoot raw
  decodeEnvironmentsFromRoot root

decodePlanRoot :: BL.ByteString -> Either Text (KM.KeyMap Value)
decodePlanRoot raw =
  case A.eitherDecode' raw of
    Left err -> Left (T.pack err)
    Right (Object root) -> Right root
    Right _ -> Left "plan.json root is not an object"

decodeEnvironmentsFromRoot :: KM.KeyMap Value -> Either Text (KM.KeyMap Value)
decodeEnvironmentsFromRoot root =
  case lookupObj (K.fromString "environments") root of
    Nothing -> Left "plan.json missing environments object"
    Just envs -> Right envs

renderProjectInputs :: [(Text, Text)] -> Text
renderProjectInputs inputs =
  if null inputs
    then "    # (no client projects)"
    else T.intercalate "\n" (map renderInput inputs)
  where
    renderInput (name, url) =
      T.concat ["    ", name, ".url = \"", url, "\";"]

renderFlakeTemplate :: Text -> Text -> Either Text Text
renderFlakeTemplate template inputBlock =
  let marker = "{{HOSTENV_PROJECT_INPUTS}}"
   in if T.isInfixOf marker template
        then Right (T.replace marker inputBlock template)
        else Left "flake template missing {{HOSTENV_PROJECT_INPUTS}} marker"

renderGitCredentials :: [(Text, Text)] -> Text
renderGitCredentials entries =
  let lines' = map (uncurry injectToken) entries
   in T.intercalate "\n" lines' <> "\n"

injectToken :: Text -> Text -> Text
injectToken url token =
  case T.stripPrefix "https://" url of
    Just rest -> "https://oauth2:" <> token <> "@" <> rest
    Nothing ->
      case T.stripPrefix "http://" url of
        Just rest -> "http://oauth2:" <> token <> "@" <> rest
        Nothing -> url


data GitlabSecrets = GitlabSecrets
  { gitlabClientId :: Text
  , gitlabClientSecret :: Text
  } deriving (Eq, Show)

readGitlabSecrets :: FilePath -> IO GitlabSecrets
readGitlabSecrets path = do
  raw <- T.pack <$> readFile path
  let pairs = map parseLine (T.lines raw)
  let kvs = catMaybes pairs
  let lookupKey keys = listToMaybe [ v | (k, v) <- kvs, k `elem` keys ]
  case (lookupKey ["client_id", "GITLAB_CLIENT_ID"], lookupKey ["client_secret", "GITLAB_CLIENT_SECRET"]) of
    (Just cid, Just secret) -> pure (GitlabSecrets cid secret)
    _ -> die "GitLab secrets file missing client_id/client_secret"
  where
    parseLine line =
      let trimmed = T.strip line
       in if trimmed == "" || T.isPrefixOf "#" trimmed
            then Nothing
            else case T.breakOn "=" trimmed of
              (k, v) | v /= "" -> Just (T.strip k, T.strip (T.drop 1 v))
              _ -> Nothing


data WebhookConfig = WebhookConfig
  { whWorkDir :: FilePath
  , whPlanPath :: FilePath
  } deriving (Eq, Show)

data ProjectRef = ProjectRef
  { prOrg :: Text
  , prProject :: Text
  } deriving (Eq, Show)


data CommandSpec = CommandSpec
  { cmdName :: Text
  , cmdArgs :: [Text]
  , cmdCwd :: FilePath
  } deriving (Eq, Show)


data CommandOutput = CommandOutput
  { outStdout :: Text
  , outStderr :: Text
  } deriving (Eq, Show)


data CommandError = CommandError
  { errSpec :: CommandSpec
  , errExit :: ExitCode
  , errStdout :: Text
  , errStderr :: Text
  } deriving (Eq, Show)


data DeployResult = DeployResult
  { deployNode :: Text
  , deploySuccess :: Bool
  , deployStdout :: Text
  , deployStderr :: Text
  } deriving (Eq, Show)

instance A.ToJSON DeployResult where
  toJSON d =
    A.object
      [ "node" A..= d.deployNode
      , "success" A..= d.deploySuccess
      , "stdout" A..= d.deployStdout
      , "stderr" A..= d.deployStderr
      ]


data WebhookResult = WebhookResult
  { webhookNodes :: [Text]
  , webhookDeploys :: [DeployResult]
  , webhookOk :: Bool
  } deriving (Eq, Show)

instance A.ToJSON WebhookResult where
  toJSON r =
    A.object
      [ "ok" A..= r.webhookOk
      , "nodes" A..= r.webhookNodes
      , "deployments" A..= r.webhookDeploys
      ]


data WebhookError
  = WebhookCommandError CommandError
  | WebhookPlanError Text
  deriving (Eq, Show)


type CommandRunner = CommandSpec -> IO (Either CommandError CommandOutput)

runWebhookWith :: CommandRunner -> IO BL.ByteString -> WebhookConfig -> ProjectRef -> IO (Either WebhookError WebhookResult)
runWebhookWith runner loadPlan cfg ref = do
  previousPlanRaw <- loadPlan
  case projectEnvironmentPlacements ref.prOrg ref.prProject previousPlanRaw of
    Left err -> pure (Left (WebhookPlanError err))
    Right previousEnvironments -> do
      let inputName = ref.prOrg <> "__" <> ref.prProject
      step runner (CommandSpec "nix" ["flake", "update", inputName] (cfg.whWorkDir)) >>= \case
        Left err -> pure (Left err)
        Right _ ->
          step runner (CommandSpec "nix" ["run", ".#hostenv-provider", "--", "plan"] (cfg.whWorkDir)) >>= \case
            Left err -> pure (Left err)
            Right _ -> do
              currentPlanRaw <- loadPlan
              case projectEnvironmentPlacements ref.prOrg ref.prProject currentPlanRaw of
                Left err -> pure (Left (WebhookPlanError err))
                Right currentEnvironments -> do
                  let currentNames = map fst currentEnvironments
                  let removedNames =
                        [ envName
                        | (envName, _) <- previousEnvironments
                        , envName `notElem` currentNames
                        ]
                  if not (null removedNames)
                    then
                      -- Known provider-service limitation:
                      --
                      -- provider-service is still in development. Removing an
                      -- environment through a webhook is intentionally not fully
                      -- automated yet. This check only compares the plan from
                      -- before this webhook with the newly generated plan. The
                      -- new plan is published before this error is returned, so a
                      -- later webhook delivery may no longer be able to see that
                      -- an environment was removed.
                      --
                      -- Do not try to infer the missing environment's live node
                      -- here from DNS or old plan data. A partially completed
                      -- migration may still exist on a different node. Future
                      -- provider-service work should make removals durable until
                      -- an unfiltered provider deploy has reconciled all live
                      -- nodes. For now, the operator must run the unfiltered
                      -- deploy requested by the error below.
                      pure
                        ( Left
                            ( WebhookPlanError
                                ( "automatic webhook deployment cannot safely remove environment(s): "
                                    <> T.intercalate ", " removedNames
                                    <> ". Run `nix run .#hostenv-provider -- deploy` from the provider repository to reconcile live placement."
                                )
                            )
                        )
                    else do
                      let nodes = sort . nub $ map snd currentEnvironments
                      -- The service deliberately does not infer migrations from
                      -- DNS. The provider CLI observes live state and refuses an
                      -- unsafe node-scoped move before activation.
                      deploys <- foldM (deployNode runner cfg) [] nodes
                      let ok = all (\d -> d.deploySuccess) deploys
                      pure (Right (WebhookResult nodes deploys ok))
  where
    step :: CommandRunner -> CommandSpec -> IO (Either WebhookError ())
    step run spec = do
      res <- run spec
      case res of
        Left e -> pure (Left (WebhookCommandError e))
        Right _ -> pure (Right ())

    deployNode :: CommandRunner -> WebhookConfig -> [DeployResult] -> Text -> IO [DeployResult]
    deployNode run config acc node = do
      res <- run (CommandSpec "nix" ["run", ".#hostenv-provider", "--", "deploy", "--node", node] (config.whWorkDir))
      case res of
        Right out ->
          pure (acc ++ [DeployResult node True out.outStdout out.outStderr])
        Left err ->
          pure (acc ++ [DeployResult node False err.errStdout err.errStderr])
