{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.DnsTransition
    ( DnsItem (..)
    , collectDnsItems
    , gateTlsForItems
    ) where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

data DnsItem = DnsItem
    { diEnvName :: Text
    , diNodeName :: Maybe Text
    , diVhostName :: Text
    , diDiscoveryHost :: Text
    , diExpectedHost :: Text
    }
    deriving (Eq, Show)

nodeKey :: K.Key
nodeKey = K.fromString "node"

collectDnsItems :: Text -> KM.KeyMap A.Value -> [DnsItem]
collectDnsItems hostenvHostname envs =
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
                             in DnsItem
                                    { diEnvName = envName
                                    , diNodeName = nodeName
                                    , diVhostName = vhName
                                    , diDiscoveryHost = vhName
                                    , diExpectedHost = expectedHostFor vhName
                                    }
                        )
                        (KM.toList vhosts)
            _ -> []

gateTlsForItems :: [DnsItem] -> KM.KeyMap A.Value -> KM.KeyMap A.Value
gateTlsForItems items root =
    foldl (flip gateOne) root items
  where
    gateOne item root =
        let envPath suffix =
                [ K.fromString "environments"
                , K.fromText item.diEnvName
                , K.fromString "virtualHosts"
                , K.fromText item.diVhostName
                , K.fromString suffix
                ]
            withEnvironment =
                setBoolAtKeys (envPath "forceSSL") False $
                    setBoolAtKeys (envPath "enableLetsEncrypt") False root
         in case item.diNodeName of
                Nothing -> withEnvironment
                Just nodeName ->
                    let nodePath suffix =
                            [ K.fromString "nodes"
                            , K.fromText nodeName
                            , K.fromString "services"
                            , K.fromString "nginx"
                            , K.fromString "virtualHosts"
                            , K.fromText item.diVhostName
                            , K.fromString suffix
                            ]
                     in setBoolAtKeys (nodePath "forceSSL") False $
                            setBoolAtKeys (nodePath "enableACME") False withEnvironment

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

setBoolAtKeys :: [K.Key] -> Bool -> KM.KeyMap A.Value -> KM.KeyMap A.Value
setBoolAtKeys path b = modifyAt path (const (A.Bool b))

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
