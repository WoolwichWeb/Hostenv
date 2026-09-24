{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

module Hostenv.Provider.Service
  ( verifyGitHubSignature
  , verifyGitLabToken
  , nodesForProject
  , projectForHash
  , projectHashFor
  , nodesForProjectWithDnsWith
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
  , DeployResult(..)
  , WebhookResult(..)
  , WebhookError(..)
  , CommandRunner
  , PlanLoader
  , runWebhookWith
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, try)
import Control.Monad (foldM, forM)
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
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (foldl', intersect, nub, sort, sortOn)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (..), die)
import System.Process (readProcessWithExitCode)

import "cryptonite" Crypto.Hash (SHA256)
import "cryptonite" Crypto.MAC.HMAC (HMAC (..), hmac)
import Hostenv.Provider.DnsPointsToCache (cacheDnsPointsTo, newDnsPointsToCache)
import Hostenv.Provider.PrevNodeDiscovery qualified as PrevNode


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

lookupTextList :: KM.Key -> KM.KeyMap Value -> [Text]
lookupTextList key obj = case KM.lookup key obj of
  Just (Array arr) -> mapMaybe asText (toList arr)
  _ -> []
  where
    asText (String t) = Just t
    asText _ = Nothing

nodesForProject :: Text -> Text -> BL.ByteString -> Either Text [Text]
nodesForProject org project raw = do
  envs <- decodeEnvironments raw
  let matches =
        mapMaybe extractEnv (KM.toList envs)
      nodes = sort (nub (map envNode matches))
      deps =
        [ (envNode info, prev)
        | info <- matches
        , Just prev <- [info.envPrevNode]
        , prev /= info.envNode
        ]
  Right (orderNodes nodes deps)
  where
    extractEnv (_kEnv, vEnv) = case vEnv of
      Object envObj -> do
        hostenvObj <- lookupObj (K.fromString "hostenv") envObj
        org' <- lookupText (K.fromString "organisation") hostenvObj
        project' <- lookupText (K.fromString "project") hostenvObj
        if org' == org && project' == project
          then do
            node <- lookupText (K.fromString "node") envObj
            let prevNode = lookupText (K.fromString "previousNode") envObj
            pure (EnvNodeInfo node prevNode)
          else Nothing
      _ -> Nothing

nodesForProjectWithDns :: Text -> Text -> BL.ByteString -> IO (Either Text [Text])
nodesForProjectWithDns org project raw = do
  dnsCache <- newDnsLookupCache
  nodesForProjectWithDnsWith (dnsPointsToWith dnsCache) org project raw

-- | Like 'nodesForProject', but for migrating environments where it can infer
--   a missing previous node from DNS before calculating deploy order.
nodesForProjectWithDnsWith :: (Text -> Text -> IO Bool) -> Text -> Text -> BL.ByteString -> IO (Either Text [Text])
nodesForProjectWithDnsWith pointsTo org project raw = do
  dnsPointsToCache <- newDnsPointsToCache
  let cachedPointsTo = cacheDnsPointsTo dnsPointsToCache pointsTo
  case decodePlanRoot raw of
    Left err -> pure (Left err)
    Right root ->
      case decodeEnvironmentsFromRoot root of
        Left err -> pure (Left err)
        Right envs -> do
          let hostenvHostname = lookupText (K.fromString "hostenvHostname") root
          matches <- fmap catMaybes $ forM (KM.toList envs) $ \(kEnv, vEnv) ->
            case vEnv of
              Object envObj -> do
                hostenvObj <- pure (lookupObj (K.fromString "hostenv") envObj)
                let envName = K.toText kEnv
                -- Generated plans key environments by hostenv.userName, so the
                -- attr name and userName should identify the same environment.
                let envUserName = fromMaybe envName (hostenvObj >>= lookupText (K.fromString "userName"))
                case hostenvObj of
                  Just hostenvObj' -> do
                    case (lookupText (K.fromString "organisation") hostenvObj', lookupText (K.fromString "project") hostenvObj') of
                      (Just org', Just project') | org' == org && project' == project -> do
                        case lookupText (K.fromString "node") envObj of
                          Just node -> do
                            let prevNode = lookupText (K.fromString "previousNode") envObj
                            let migrateBackups = lookupTextList (K.fromString "migrations") envObj
                            -- Previous-node discovery probes the canonical
                            -- hostenv hostname first, then these vhosts.
                            let vhostsObj = fromMaybe KM.empty (lookupObj (K.fromString "virtualHosts") envObj)
                            let vhosts = map (K.toText . fst) (KM.toList vhostsObj)
                            pure (Just (envUserName, node, prevNode, migrateBackups, vhosts))
                          Nothing -> pure Nothing
                      _ -> pure Nothing
                  Nothing -> pure Nothing
              _ -> pure Nothing
          let discoveryNodes = PrevNode.discoveryNodeNames root (map (\(_, node, _, _, _) -> node) matches)

          resolvedMatches <- forM matches $ \(envUserName, node, prevNode, migrateBackups, vhosts) -> do
            resolvedPrev <-
              -- Only migrating environments need previous-node discovery.
              if null migrateBackups
                then pure (Right prevNode)
                else resolvePrevNodeFromDns cachedPointsTo hostenvHostname discoveryNodes envUserName vhosts node prevNode
            pure ((\prev -> EnvNodeInfo node prev) <$> resolvedPrev)

          case sequence resolvedMatches of
            Left err -> pure (Left err)
            Right resolvedInfos -> do
              let nodes = sort (nub (map envNode resolvedInfos <> mapMaybe envPrevNode resolvedInfos))
              -- A migrating environment depends on its previous node staying
              -- available long enough to pull data from it.
              let deps =
                    [ (envNode info, prev)
                    | info <- resolvedInfos
                    , Just prev <- [info.envPrevNode]
                    , prev /= info.envNode
                    ]
              pure (Right (orderNodes nodes deps))
  where
    -- Resolve the previous node for one environment. If the plan already set
    -- previousNode, keep it. Otherwise, probe the canonical hostenv hostname
    -- first and then the environment's configured vhosts for a match.
    resolvePrevNodeFromDns :: (Text -> Text -> IO Bool) -> Maybe Text -> [Text] -> Text -> [Text] -> Text -> Maybe Text -> IO (Either Text (Maybe Text))
    resolvePrevNodeFromDns pointsTo' hostenvHostname discoveryNodes envName vhosts currentNode prevNode =
      case PrevNode.resolveDeclaredPrevNode currentNode Nothing prevNode of
        PrevNode.NoDeclaredPrevNode ->
          case hostenvHostname of
            -- Without the hostenv domain we cannot build the canonical probe
            -- hostname or canonical node hostnames to compare against.
            Nothing -> pure (Right Nothing)
            Just host -> do
              -- TODO: Finish the refactor by typing plan-derived node/env data
              -- before it reaches this helper instead of wrapping raw Text here.
              let candidateNodes = map PrevNode.NodeName discoveryNodes
              let currentNodeName = PrevNode.NodeName currentNode
              let previousNodeCandidates = PrevNode.previousNodeCandidates currentNodeName candidateNodes
              if null previousNodeCandidates
                then pure (Right Nothing)
                else do
                  -- Probe the canonical env hostname first, then fall back to
                  -- configured customer-facing vhosts when that is inconclusive.
                  let probedHosts = PrevNode.probeHosts host envName vhosts
                  probes <-
                    forM probedHosts $ \probedHost -> do
                      PrevNode.probeHost pointsTo' host probedHost candidateNodes
                  let resolution = PrevNode.chooseDiscoveryOutcome currentNodeName probes
                  case resolution of
                    PrevNode.DiscoveryResolved _probedHost (PrevNode.NodeName node) -> pure (Right (Just node))
                    PrevNode.DiscoverySkipped _ -> pure (Right Nothing)
                    PrevNode.DiscoveryAmbiguous (PrevNode.Hostname probedHost) nodes ->
                      pure
                        ( Left
                            ( "DNS for "
                                <> probedHost
                                <> " matches more than one possible previous node for "
                                <> envName
                                <> ": "
                                <> T.intercalate ", " [ nodeName | PrevNode.NodeName nodeName <- nodes ]
                                <> ". Set previousNode explicitly."
                            )
                        )
        PrevNode.DeclaredCurrentNode _source _sourceNode -> pure (Right Nothing)
        PrevNode.DeclaredPreviousNode _source sourceNode -> pure (Right (Just sourceNode))

data EnvNodeInfo = EnvNodeInfo
  { envNode :: Text
  , envPrevNode :: Maybe Text
  }

orderNodes :: [Text] -> [(Text, Text)] -> [Text]
orderNodes nodes deps =
  let uniqueNodes = sort (nub nodes)
      nodeSet = S.fromList uniqueNodes
      deps' =
        nub
          [ (a, b)
          | (a, b) <- deps
          , a /= b
          , S.member a nodeSet
          , S.member b nodeSet
          ]
      outgoing = M.fromListWith (<>) [ (a, [b]) | (a, b) <- deps' ]
      indeg0 = M.fromList [ (n, 0 :: Int) | n <- uniqueNodes ]
      indeg = foldl' (\m (_a, b) -> M.adjust (+ 1) b m) indeg0 deps'
      zeros0 = S.fromList [ n | n <- uniqueNodes, M.findWithDefault 0 n indeg == 0 ]
      (ordered, _indegFinal) = topo outgoing indeg zeros0 []
      orderedSet = S.fromList ordered
      remaining = [ n | n <- uniqueNodes, S.notMember n orderedSet ]
   in if length ordered == length uniqueNodes
        then ordered
        else ordered <> remaining
  where
    topo outMap indegMap zeros acc =
      case S.minView zeros of
        Nothing -> (acc, indegMap)
        Just (n, zeros') ->
          let outs = M.findWithDefault [] n outMap
              (zeros'', indeg') = foldl' step (zeros', indegMap) outs
           in topo outMap indeg' zeros'' (acc <> [n])
    step (z, m) dest =
      let newVal = (M.findWithDefault 0 dest m) - 1
          m' = M.insert dest newVal m
          z' = if newVal == 0 then S.insert dest z else z
       in (z', m')

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

stripDot :: Text -> Text
stripDot = T.dropWhileEnd (== '.')

normalizeDnsName :: Text -> Text
normalizeDnsName = T.toLower . stripDot . T.strip

-- | Cache DNS discovery done while checking whether hostnames resolve to the
-- expected host.
--
-- These checks do more than ask the local resolver for one record. For each
-- hostname, the code first looks for the authoritative nameservers for that
-- hostname, then asks those nameservers for CNAME, A, or AAAA records. A single
-- provider-service operation can ask the same questions repeatedly while
-- comparing many vhosts, so this value keeps the expensive discovery results
-- for the duration of that operation.
--
-- This is intentionally a short-lived cache. Provider-service entry points
-- create one 'DnsLookupCache' near the start of an operation and pass it
-- through every DNS comparison in that operation. This is not a general DNS
-- cache and it does not persist answers between commands. It also does not
-- cache CNAME, A, or AAAA answers, so each comparison still asks nameservers
-- for current record data. The first map stores the authoritative nameservers
-- selected for a full hostname. The second map stores NS records found for zone
-- names while walking up a hostname.
data DnsLookupCache = DnsLookupCache
  (IORef (M.Map Text [Text]))
  (IORef (M.Map Text [Text]))

newDnsLookupCache :: IO DnsLookupCache
newDnsLookupCache =
  DnsLookupCache
    <$> newIORef M.empty
    <*> newIORef M.empty

cachedLookup :: (Ord k) => IORef (M.Map k v) -> k -> IO v -> IO v
cachedLookup cacheRef key loadValue = do
  cache <- readIORef cacheRef
  case M.lookup key cache of
    Just value -> pure value
    Nothing -> do
      value <- loadValue
      modifyIORef' cacheRef (M.insert key value)
      pure value

tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

mapConcurrentlyIO :: (a -> IO b) -> [a] -> IO [Either SomeException b]
mapConcurrentlyIO action values = do
  resultVars <- forM values $ \value -> do
    resultVar <- newEmptyMVar
    _ <- forkIO $ tryAny (action value) >>= putMVar resultVar
    pure resultVar
  forM resultVars takeMVar

digRRRaw :: Maybe Text -> Text -> Text -> IO [Text]
digRRRaw mNameserver name rr = do
  let serverArgs = maybe [] (\nameserver -> ["@" <> T.unpack nameserver]) mNameserver
  let args = serverArgs <> ["+short", "+time=1", "+tries=1", T.unpack name, T.unpack rr]
  res <- try (readProcessWithExitCode "dig" args "") :: IO (Either IOException (ExitCode, String, String))
  case res of
    Left _ -> pure []
    Right (ExitSuccess, out, _) ->
      let toLine = stripDot . T.toLower . T.strip . T.pack
       in pure (filter (not . T.null) (map toLine (lines out)))
    Right _ -> pure []

zoneCandidates :: Text -> [Text]
zoneCandidates name =
  let labels = filter (not . T.null) (T.splitOn "." (normalizeDnsName name))
      labelCount = length labels
      indices =
        if labelCount < 2
          then []
          else [0 .. labelCount - 2]
   in map (\idx -> T.intercalate "." (drop idx labels)) indices

findAuthoritativeNameserversWith :: DnsLookupCache -> Text -> IO [Text]
findAuthoritativeNameserversWith cache@(DnsLookupCache authoritativeCache _) name =
  cachedLookup authoritativeCache (normalizeDnsName name) (go (zoneCandidates name))
  where
    go [] = pure []
    go (candidate:rest) = do
      nameservers <- findZoneNameservers cache candidate
      if null nameservers
        then go rest
        else pure nameservers

findZoneNameservers :: DnsLookupCache -> Text -> IO [Text]
findZoneNameservers (DnsLookupCache _ zoneCache) zone =
  cachedLookup zoneCache (normalizeDnsName zone) (digRRRaw Nothing zone "NS")

digRRWith :: DnsLookupCache -> Text -> Text -> IO [Text]
digRRWith cache name rr = do
  authoritativeNameservers <- findAuthoritativeNameserversWith cache name
  case authoritativeNameservers of
    [] -> digRRRaw Nothing name rr
    nameservers -> do
      queryResults <- mapConcurrentlyIO (\nameserver -> digRRRaw (Just nameserver) name rr) nameservers
      let answersByNameserver = [answers | Right answers <- queryResults]
      let nonEmptyAnswers = filter (not . null) answersByNameserver
      if null nonEmptyAnswers
        then digRRRaw Nothing name rr
        else pure (S.toList (S.fromList (concat nonEmptyAnswers)))

digAddrsWith :: DnsLookupCache -> Text -> IO [Text]
digAddrsWith cache name = do
  a4 <- digRRWith cache name "A"
  a6 <- digRRWith cache name "AAAA"
  pure (a4 <> a6)

dnsPointsToWith :: DnsLookupCache -> Text -> Text -> IO Bool
dnsPointsToWith cache vhost expectedHost = do
  let expectHostNorm = T.toLower expectedHost
  cn <- digRRWith cache vhost "CNAME"
  if expectHostNorm `elem` cn
    then pure True
    else do
      expIPs <- digAddrsWith cache expectedHost
      vhIPs <- digAddrsWith cache vhost
      pure (not (null (expIPs `intersect` vhIPs)))

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

type PlanLoader = IO BL.ByteString

runWebhookWith :: CommandRunner -> PlanLoader -> WebhookConfig -> ProjectRef -> IO (Either WebhookError WebhookResult)
runWebhookWith runner loadPlan cfg ref = do
  let inputName = ref.prOrg <> "__" <> ref.prProject
  step runner (CommandSpec "nix" ["flake", "update", inputName] (cfg.whWorkDir)) >>= \case
    Left err -> pure (Left err)
    Right _ ->
      step runner (CommandSpec "nix" ["run", ".#hostenv-provider", "--", "plan"] (cfg.whWorkDir)) >>= \case
        Left err -> pure (Left err)
        Right _ ->
          step runner (CommandSpec "nix" ["run", ".#hostenv-provider", "--", "dns-gate"] (cfg.whWorkDir)) >>= \case
            Left err -> pure (Left err)
            Right _ -> do
              planRaw <- loadPlan
              nodesForProjectWithDns ref.prOrg ref.prProject planRaw >>= \case
                Left err -> pure (Left (WebhookPlanError err))
                Right nodes -> do
                  deploys <- foldM (deployNode runner cfg) [] nodes
                  let ok = all (\d -> d.deploySuccess) deploys
                  pure (Right (WebhookResult nodes deploys ok))
  where
    step run spec = do
      res <- run spec
      case res of
        Left e -> pure (Left (WebhookCommandError e))
        Right _ -> pure (Right ())

    deployNode run config acc node = do
      res <- run (CommandSpec "nix" ["run", ".#hostenv-provider", "--", "deploy", "--node", node] (config.whWorkDir))
      case res of
        Right out ->
          pure (acc ++ [DeployResult node True out.outStdout out.outStderr])
        Left err ->
          pure (acc ++ [DeployResult node False err.errStdout err.errStderr])
