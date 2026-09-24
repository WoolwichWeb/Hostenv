{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.PrevNodeDiscovery (
    Hostname (..),
    NodeName (..),
    Probe (..),
    ProbeSkip (..),
    ProbeOutcome (..),
    DiscoverySkip (..),
    DiscoveryOutcome (..),
    DeclaredPrevNodeSource (..),
    DeclaredPrevNodeResolution (..),
    canonicalHostInDomain,
    discoveryNodeNames,
    previousNodeCandidates,
    resolveDeclaredPrevNode,
    probeHosts,
    probeHost,
    classifyProbe,
    chooseDiscoveryOutcome,
) where

import Control.Monad (filterM)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (nub, sort)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T

normalizeHost :: Text -> Text
normalizeHost = T.toLower . stripDot . T.strip
  where
    stripDot = T.dropWhileEnd (== '.')

{- | Normalize a label into a hostname within the hostenv domain.
  If the label already ends with that domain, keep it as-is.
TODO: Give this a typed hostname/domain API.
Today it still returns raw Text because other callers outside previous-node
discovery, such as dns-gate code, have not moved to Hostname/NodeName yet.
-}
canonicalHostInDomain :: Text -> Text -> Text
canonicalHostInDomain label hostenvHostname =
    let domain = normalizeHost hostenvHostname
        labelNorm = normalizeHost label
        suffix = "." <> domain
     in if T.null labelNorm
            then labelNorm
            else
                if T.null domain
                    then labelNorm
                    else
                        if T.isSuffixOf suffix labelNorm
                            then labelNorm
                            else labelNorm <> suffix

-- | A normalized hostname used while probing DNS for a previous node.
newtype Hostname = Hostname Text
    deriving (Eq, Ord, Show)

-- | A normalized node name used during previous-node discovery.
newtype NodeName = NodeName Text
    deriving (Eq, Ord, Show)

-- | One DNS probe: a hostname we checked and the candidate nodes it matched.
data Probe = Probe
    { probedHost :: Hostname
    -- ^ The hostname we checked in DNS.
    , matchingNodes :: [NodeName]
    -- ^ Normalized candidate node names that hostname matched.
    }
    deriving (Eq, Show)

-- | Why one probe did not resolve a previous node.
data ProbeSkip
    = -- | The probed hostname did not match any candidate node.
      ProbeNoMatches
    | {- | The probed hostname matched the current node, so migration discovery
      should skip rather than picking a previous node.
      -}
      ProbeMatchedCurrent [NodeName]
    deriving (Eq, Show)

-- | Result of classifying a single DNS probe against the current node.
data ProbeOutcome
    = -- | Exactly one possible previous node matched.
      ProbeResolved NodeName
    | -- | The probe did not yield a usable previous node.
      ProbeSkipped ProbeSkip
    | -- | More than one possible previous node matched, so the caller must choose.
      ProbeAmbiguous [NodeName]
    deriving (Eq, Show)

-- | Why the full ordered probe sequence did not resolve a previous node.
data DiscoverySkip
    = -- | None of the probed hostnames matched any candidate node.
      DiscoveryNoMatches
    | {- | One probed hostname matched the current node. Carries the hostname we
      checked and the normalized candidate node matches it returned.
      -}
      DiscoveryMatchedCurrent Hostname [NodeName]
    deriving (Eq, Show)

-- | Result of choosing an overall previous-node outcome from several probes.
data DiscoveryOutcome
    = -- | A probed hostname found a unique previous node.
      DiscoveryResolved Hostname NodeName
    | -- | None of the probes found a usable previous node.
      DiscoverySkipped DiscoverySkip
    | -- | A probed hostname matched more than one possible previous node.
      DiscoveryAmbiguous Hostname [NodeName]
    deriving (Eq, Show)

{- | Identifies where a declared previous-node value came from.
A declared previous node is the machine from which data should be copied or
migrated.
-}
data DeclaredPrevNodeSource
    = -- | The value came from a migration-source override supplied by the caller.
      MigrationSourceOverride
    | -- | The value came from the previousNode field in the evaluated plan.
      PlanPreviousNode
    deriving (Eq, Show)

-- | Describes what a declared previous-node value means for migration.
data DeclaredPrevNodeResolution
    = -- | No previous-node value was declared.
      NoDeclaredPrevNode
    | {- | A declared previous-node value names the current node, so there is no
      previous node to migrate from.
      -}
      DeclaredCurrentNode DeclaredPrevNodeSource Text
    | {- | A declared previous-node value names another node that can be used as
      the migration source.
      -}
      DeclaredPreviousNode DeclaredPrevNodeSource Text
    deriving (Eq, Show)

mkHostname :: Text -> Hostname
mkHostname = Hostname . normalizeHost

mkNodeName :: Text -> NodeName
mkNodeName = NodeName . normalizeHost

hostnameText :: Hostname -> Text
hostnameText (Hostname t) = t

nodeNameText :: NodeName -> Text
nodeNameText (NodeName t) = t

normalizeNodeNames :: [NodeName] -> [NodeName]
normalizeNodeNames =
    sort
        . nub
        . filter (not . T.null . nodeNameText)
        . map (mkNodeName . nodeNameText)

{- | Return possible previous nodes, excluding the current node.
A previous node is a different machine that may have hosted the environment
before this deployment. The result is normalized and deduplicated.
-}
previousNodeCandidates :: NodeName -> [NodeName] -> [NodeName]
previousNodeCandidates currentNode =
    filter (/= mkNodeName (nodeNameText currentNode)) . normalizeNodeNames

{- | Resolve a previous-node value declared by the caller or in the plan.
A caller-supplied migration source takes precedence over the previousNode field
in the evaluated plan. The result distinguishes a missing value, the current
node, and another node that can serve as the migration source.
-}
resolveDeclaredPrevNode :: Text -> Maybe Text -> Maybe Text -> DeclaredPrevNodeResolution
resolveDeclaredPrevNode currentNode explicitSource configuredPrevNode =
    case pickSource of
        Nothing -> NoDeclaredPrevNode
        Just (source, sourceNode)
            | mkNodeName sourceNode == mkNodeName currentNode ->
                DeclaredCurrentNode source sourceNode
            | otherwise ->
                DeclaredPreviousNode source sourceNode
  where
    pickSource =
        case explicitSource of
            Just sourceNode -> Just (MigrationSourceOverride, sourceNode)
            Nothing ->
                case configuredPrevNode of
                    Just sourceNode -> Just (PlanPreviousNode, sourceNode)
                    Nothing -> Nothing

{- | Build the candidate node list for previous-node discovery.
  This includes current plan nodes, persisted nodeConnections from state,
  and any nodes attached to the currently parsed environments.
-}
discoveryNodeNames :: KM.KeyMap A.Value -> [Text] -> [Text]
discoveryNodeNames plan envNodes =
    S.toList . S.fromList . filter (not . T.null) $
        objectKeys (K.fromString "nodes") plan
            <> objectKeys (K.fromString "nodeConnections") plan
            <> envNodes
  where
    objectKeys key obj = case KM.lookup key obj of
        Just (A.Object sub) -> map (K.toText . fst) (KM.toList sub)
        _ -> []

{- | Build the ordered hostnames to probe for one environment:
  the canonical hostenv hostname first, then configured vhosts.
TODO: Replace the Text env/domain inputs with typed values once the
surrounding plan/env models stop using raw Text.
-}
probeHosts :: Text -> Text -> [Text] -> [Hostname]
probeHosts hostenvHostname envName vhosts =
    nub (filter (not . T.null . hostnameText) (map mkHostname (canonicalHostInDomain envName hostenvHostname : vhosts)))

{- | Probe one hostname against the candidate nodes, returning the nodes whose
  canonical hostnames that probed hostname currently points at.
TODO: Remove the raw hostenvHostname Text here.
It still exists only because canonicalHostInDomain and the DNS callback
still operate on Text at the module boundary.
-}
probeHost :: (Text -> Text -> IO Bool) -> Text -> Hostname -> [NodeName] -> IO Probe
probeHost pointsTo hostenvHostname host candidateNodes = do
    let normalizedHost = mkHostname (hostnameText host)
    let normalizedNodes = normalizeNodeNames candidateNodes
    matchedNodes <- filterM (\node -> pointsTo (hostnameText normalizedHost) (canonicalHostInDomain (nodeNameText node) hostenvHostname)) normalizedNodes
    pure Probe{probedHost = normalizedHost, matchingNodes = matchedNodes}

-- | Classify one DNS probe against the environment's current node.
classifyProbe :: NodeName -> Probe -> ProbeOutcome
classifyProbe currentNode (Probe _ rawMatches) =
    let currentNodeNorm = mkNodeName (nodeNameText currentNode)
        uniqueMatches = normalizeNodeNames rawMatches
     in case uniqueMatches of
            [] -> ProbeSkipped ProbeNoMatches
            [node] ->
                if node == currentNodeNorm
                    then ProbeSkipped (ProbeMatchedCurrent [node])
                    else ProbeResolved node
            many ->
                if currentNodeNorm `elem` many
                    then ProbeSkipped (ProbeMatchedCurrent many)
                    else ProbeAmbiguous many

{- | Choose the overall discovery result from an ordered list of probes.
  The first unique previous-node match wins immediately. Otherwise the first
  ambiguous probe is reported; if none were ambiguous, the first probe that
  matched the current node is remembered; if neither happened, discovery had
  no matches at all.
-}
chooseDiscoveryOutcome :: NodeName -> [Probe] -> DiscoveryOutcome
chooseDiscoveryOutcome currentNode =
    go Nothing Nothing
  where
    go firstAmbiguous firstCurrent [] =
        case firstAmbiguous of
            Just (host, nodes) -> DiscoveryAmbiguous host nodes
            Nothing ->
                case firstCurrent of
                    Just (host, nodes) -> DiscoverySkipped (DiscoveryMatchedCurrent host nodes)
                    Nothing -> DiscoverySkipped DiscoveryNoMatches
    go firstAmbiguous firstCurrent (probe@(Probe host _) : rest) =
        case classifyProbe currentNode probe of
            ProbeResolved node -> DiscoveryResolved host node
            ProbeSkipped ProbeNoMatches -> go firstAmbiguous firstCurrent rest
            ProbeSkipped (ProbeMatchedCurrent nodes) ->
                let firstCurrent' =
                        case firstCurrent of
                            Just existing -> Just existing
                            Nothing -> Just (host, nodes)
                 in go firstAmbiguous firstCurrent' rest
            ProbeAmbiguous nodes ->
                let firstAmbiguous' =
                        case firstAmbiguous of
                            Just existing -> Just existing
                            Nothing -> Just (host, nodes)
                 in go firstAmbiguous' firstCurrent rest
