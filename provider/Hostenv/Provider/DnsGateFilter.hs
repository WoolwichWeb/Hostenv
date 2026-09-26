{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.DnsGateFilter
    ( DnsGateItem (..)
    , collectDnsGateItems
    , disableAcmeOnNode
    , disableLetsEncryptPaths
    , filterEnvironmentsByNode
    , clearDnsGateOriginalForEnvironment
    , rememberDnsGateOriginal
    , restoreDnsGateOriginalForEnvironment
    ) where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

data DnsGateItem = DnsGateItem
    { dgiEnvName :: Text
    , dgiNodeName :: Maybe Text
    , dgiVhostName :: Text
    , dgiDiscoveryHost :: Text
    , dgiExpectedHost :: Text
    }

nodeKey :: K.Key
nodeKey = K.fromString "node"

filterEnvironmentsByNode :: Maybe Text -> KM.KeyMap A.Value -> KM.KeyMap A.Value
filterEnvironmentsByNode Nothing envs = envs
filterEnvironmentsByNode (Just selectedNode) envs =
    KM.filter (matchesSelectedNode selectedNode) envs
  where
    matchesSelectedNode nodeName (A.Object envObj) =
        case KM.lookup nodeKey envObj of
            Just (A.String envNode) -> envNode == nodeName
            _ -> False
    matchesSelectedNode _ _ = False

collectDnsGateItems :: Text -> KM.KeyMap A.Value -> [DnsGateItem]
collectDnsGateItems hostenvHostname envs =
    concatMap collectEnv (KM.toList envs)
  where
    collectEnv (kEnv, vEnv) =
        case vEnv of
            A.Object envObj ->
                let envName = K.toText kEnv
                    nodeName = lookupText nodeKey envObj
                    expectedHostFor vh = maybe vh (`canonicalHostInDomain` hostenvHostname) nodeName
                    vhosts = fromMaybe KM.empty (lookupObj (K.fromString "virtualHosts") envObj)
                 in map
                        (\(vhKey, _) ->
                            let vhName = K.toText vhKey
                             in DnsGateItem
                                    { dgiEnvName = envName
                                    , dgiNodeName = nodeName
                                    , dgiVhostName = vhName
                                    , dgiDiscoveryHost = vhName
                                    , dgiExpectedHost = expectedHostFor vhName
                                    }
                        )
                        (KM.toList vhosts)
            _ -> []

lookupText :: K.Key -> KM.KeyMap A.Value -> Maybe Text
lookupText key obj =
    case KM.lookup key obj of
        Just (A.String t) -> Just t
        _ -> Nothing

lookupObj :: K.Key -> KM.KeyMap A.Value -> Maybe (KM.KeyMap A.Value)
lookupObj key obj =
    case KM.lookup key obj of
        Just (A.Object o) -> Just o
        _ -> Nothing

modifyAt :: [K.Key] -> (A.Value -> A.Value) -> KM.KeyMap A.Value -> KM.KeyMap A.Value
modifyAt [] _ obj = obj
modifyAt [k] f obj = maybe obj (\v -> KM.insert k (f v) obj) (KM.lookup k obj)
modifyAt (k : ks) f obj =
    case KM.lookup k obj of
        Just (A.Object sub) -> KM.insert k (A.Object (modifyAt ks f sub)) obj
        _ -> obj

setBoolAt :: [Text] -> Bool -> KM.KeyMap A.Value -> KM.KeyMap A.Value
setBoolAt path b = modifyAt (map K.fromText path) (const (A.Bool b))


dnsGateOriginalKey :: K.Key
dnsGateOriginalKey = K.fromString "_dnsGateOriginalVhosts"

lookupAt :: [K.Key] -> KM.KeyMap A.Value -> Maybe A.Value
lookupAt [] _ = Nothing
lookupAt [k] obj = KM.lookup k obj
lookupAt (k : ks) obj =
    case KM.lookup k obj of
        Just (A.Object sub) -> lookupAt ks sub
        _ -> Nothing

setAt :: [K.Key] -> A.Value -> KM.KeyMap A.Value -> KM.KeyMap A.Value
setAt [] _ obj = obj
setAt [k] value obj = KM.insert k value obj
setAt (k : ks) value obj =
    let sub =
            case KM.lookup k obj of
                Just (A.Object existing) -> existing
                _ -> KM.empty
     in KM.insert k (A.Object (setAt ks value sub)) obj

deleteAt :: [K.Key] -> KM.KeyMap A.Value -> KM.KeyMap A.Value
deleteAt [] obj = obj
deleteAt [k] obj = KM.delete k obj
deleteAt (k : ks) obj =
    case KM.lookup k obj of
        Just (A.Object sub) -> KM.insert k (A.Object (deleteAt ks sub)) obj
        _ -> obj

rememberDnsGateOriginal :: KM.KeyMap A.Value -> DnsGateItem -> KM.KeyMap A.Value -> KM.KeyMap A.Value
rememberDnsGateOriginal original item root =
    let envKey = K.fromText item.dgiEnvName
        vhostKey = K.fromText item.dgiVhostName
        savedBase = [dnsGateOriginalKey, envKey, vhostKey]
        alreadySaved = lookupAt (savedBase ++ [K.fromString "environment"]) root
        envPath = [K.fromString "environments", envKey, K.fromString "virtualHosts", vhostKey]
        nodePath =
            case item.dgiNodeName of
                Nothing -> Nothing
                Just nodeName ->
                    Just
                        [ K.fromString "nodes"
                        , K.fromText nodeName
                        , K.fromString "services"
                        , K.fromString "nginx"
                        , K.fromString "virtualHosts"
                        , vhostKey
                        ]
     in case alreadySaved of
            Just _ -> root
            Nothing ->
                let withEnv =
                        case lookupAt envPath original of
                            Nothing -> root
                            Just value -> setAt (savedBase ++ [K.fromString "environment"]) value root
                 in case nodePath >>= (\path -> lookupAt path original) of
                        Nothing -> withEnv
                        Just value -> setAt (savedBase ++ [K.fromString "node"]) value withEnv

restoreDnsGateOriginalForEnvironment :: Text -> KM.KeyMap A.Value -> (KM.KeyMap A.Value, Bool)
restoreDnsGateOriginalForEnvironment envName root =
    let envKey = K.fromText envName
        savedPath = [dnsGateOriginalKey, envKey]
        savedVhosts =
            case lookupAt savedPath root of
                Just (A.Object value) -> value
                _ -> KM.empty
        nodeName =
            case lookupAt [K.fromString "environments", envKey, nodeKey] root of
                Just (A.String value) -> Just value
                _ -> Nothing
        restoreOne acc (vhostKey, A.Object saved) =
            let envPath = [K.fromString "environments", envKey, K.fromString "virtualHosts", vhostKey]
                withEnv =
                    case KM.lookup (K.fromString "environment") saved of
                        Just value -> setAt envPath value acc
                        Nothing -> acc
                nodePath =
                    case nodeName of
                        Nothing -> Nothing
                        Just name ->
                            Just
                                [ K.fromString "nodes"
                                , K.fromText name
                                , K.fromString "services"
                                , K.fromString "nginx"
                                , K.fromString "virtualHosts"
                                , vhostKey
                                ]
             in case (nodePath, KM.lookup (K.fromString "node") saved) of
                    (Just path, Just value) -> setAt path value withEnv
                    _ -> withEnv
        restoreOne acc _ = acc
        restored = foldl restoreOne root (KM.toList savedVhosts)
     in (restored, not (KM.null savedVhosts))

clearDnsGateOriginalForEnvironment :: Text -> KM.KeyMap A.Value -> KM.KeyMap A.Value
clearDnsGateOriginalForEnvironment envName root =
    let savedPath = [dnsGateOriginalKey, K.fromText envName]
        withoutEnvMetadata = deleteAt savedPath root
     in case KM.lookup dnsGateOriginalKey withoutEnvMetadata of
            Just (A.Object remaining) | KM.null remaining -> KM.delete dnsGateOriginalKey withoutEnvMetadata
            _ -> withoutEnvMetadata

disableLetsEncryptPaths :: Text -> Text -> KM.KeyMap A.Value -> KM.KeyMap A.Value
disableLetsEncryptPaths name vhostName root =
    let pEnvEnable = ["environments", name, "virtualHosts", vhostName, "enableLetsEncrypt"]
        pEnvSSL = ["environments", name, "virtualHosts", vhostName, "forceSSL"]
     in setBoolAt pEnvSSL False $
            setBoolAt pEnvEnable False root

disableAcmeOnNode :: Maybe Text -> Text -> KM.KeyMap A.Value -> KM.KeyMap A.Value
disableAcmeOnNode Nothing _ root = root
disableAcmeOnNode (Just nodeName) vhostName root =
    let pNodeEnable = ["nodes", nodeName, "services", "nginx", "virtualHosts", vhostName, "enableACME"]
        pNodeSSL = ["nodes", nodeName, "services", "nginx", "virtualHosts", vhostName, "forceSSL"]
     in setBoolAt pNodeSSL False $
            setBoolAt pNodeEnable False root

canonicalHostInDomain :: Text -> Text -> Text
canonicalHostInDomain label hostenvHostname =
    let normalize = T.toLower . T.dropWhileEnd (== '.') . T.strip
        domain = normalize hostenvHostname
        labelNorm = normalize label
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
