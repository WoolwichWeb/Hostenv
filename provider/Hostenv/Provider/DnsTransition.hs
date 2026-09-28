{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.DnsTransition
    ( DnsItem (..)
    , authoritativeDnsTargetConverged
    , collectDnsItems
    ) where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (fromMaybe)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T

data DnsItem = DnsItem
    { diDiscoveryHost :: Text
    , diExpectedHost :: Text
    , diTlsEnabled :: Bool
    }
    deriving (Eq, Show)

authoritativeDnsTargetConverged ::
    Text ->
    [Text] ->
    [([Text], [Text])] ->
    Bool
authoritativeDnsTargetConverged expectedHost expectedAddresses answersByNameserver =
    not (null answersByNameserver) && all matchesExpected answersByNameserver
  where
    expectedHostName = normalizeDnsName expectedHost
    expectedAddressSet = S.fromList (map normalizeDnsName expectedAddresses)
    matchesExpected (cnames, addresses)
        | not (S.null cnameSet) =
            cnameSet == S.singleton expectedHostName
        | otherwise =
            not (S.null addressSet)
                && addressSet `S.isSubsetOf` expectedAddressSet
      where
        cnameSet = S.fromList (map normalizeDnsName cnames)
        addressSet = S.fromList (map normalizeDnsName addresses)

normalizeDnsName :: Text -> Text
normalizeDnsName =
    T.toLower . T.dropWhileEnd (== '.') . T.strip

collectDnsItems :: Text -> KM.KeyMap A.Value -> [DnsItem]
collectDnsItems hostenvHostname envs =
    concatMap collectEnv (KM.toList envs)
  where
    collectEnv (_kEnv, vEnv) =
        case vEnv of
            A.Object envObj ->
                let nodeName = lookupText (K.fromString "node") envObj
                    expectedHostFor vh = maybe vh (`canonicalHostInDomain` hostenvHostname) nodeName
                    vhosts = fromMaybe KM.empty (lookupObj (K.fromString "virtualHosts") envObj)
                 in map
                        (\(vhKey, vhostValue) ->
                            let
                                vhName = K.toText vhKey
                                tlsEnabled =
                                    case vhostValue of
                                        A.Object vhostObj ->
                                            fromMaybe False (lookupBool (K.fromString "enableLetsEncrypt") vhostObj)
                                        _ -> False
                             in
                                DnsItem
                                    { diDiscoveryHost = vhName
                                    , diExpectedHost = expectedHostFor vhName
                                    , diTlsEnabled = tlsEnabled
                                    }
                        )
                        (KM.toList vhosts)
            _ -> []

lookupText :: K.Key -> KM.KeyMap A.Value -> Maybe Text
lookupText key obj =
    case KM.lookup key obj of
        Just (A.String t) -> Just t
        _ -> Nothing

lookupBool :: K.Key -> KM.KeyMap A.Value -> Maybe Bool
lookupBool key obj =
    case KM.lookup key obj of
        Just (A.Bool b) -> Just b
        _ -> Nothing

lookupObj :: K.Key -> KM.KeyMap A.Value -> Maybe (KM.KeyMap A.Value)
lookupObj key obj =
    case KM.lookup key obj of
        Just (A.Object o) -> Just o
        _ -> Nothing

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
