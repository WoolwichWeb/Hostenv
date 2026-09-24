{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.DnsGateFilter
    ( DnsGateItem (..)
    , collectDnsGateItems
    , disableAcmeOnNode
    , disableLetsEncryptPaths
    , filterEnvironmentsByNode
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
