{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hostenv.Provider.DnsGateFilter
    ( DnsGateItem (..)
    , collectDnsGateItems
    , disableAcmeOnNode
    , disableLetsEncryptPaths
    , filterEnvironmentsByNode
    , rememberDnsGateOriginal
    , restoreDnsGateOriginalForEnvironment
    )
import System.Exit (exitFailure)

mkEnv :: Maybe Text -> A.Value
mkEnv mNode =
    A.Object $
        KM.fromList
            [ (K.fromString "node", maybe A.Null A.String mNode)
            ]

mkDnsEnv :: Maybe Text -> [Text] -> A.Value
mkDnsEnv mNode vhosts =
    A.Object $
        KM.fromList
            [ (K.fromString "node", maybe A.Null A.String mNode)
            , ( K.fromString "virtualHosts"
              , A.Object $
                    KM.fromList
                        [ (K.fromText vhost, A.Object KM.empty)
                        | vhost <- vhosts
                        ]
              )
            ]

mkTlsVhost :: A.Value
mkTlsVhost =
    A.Object $
        KM.fromList
            [ (K.fromString "enableLetsEncrypt", A.Bool True)
            , (K.fromString "forceSSL", A.Bool True)
            ]

mkAcmeVhost :: A.Value
mkAcmeVhost =
    A.Object $
        KM.fromList
            [ (K.fromString "enableACME", A.Bool True)
            , (K.fromString "forceSSL", A.Bool True)
            ]

mkGatePlan :: KM.KeyMap A.Value
mkGatePlan =
    KM.fromList
        [ ( K.fromString "environments"
          , A.Object $
                KM.fromList
                    [ ( K.fromString "envA"
                      , A.Object $
                            KM.fromList
                                [ (K.fromString "node", A.String "backend05")
                                , ( K.fromString "virtualHosts"
                                  , A.Object $
                                        KM.fromList
                                            [ (K.fromString "www.customer.com", mkTlsVhost)
                                            ]
                                  )
                                ]
                      )
                    ]
          )
        , ( K.fromString "nodes"
          , A.Object $
                KM.fromList
                    [ ( K.fromString "backend05"
                      , A.Object $
                            KM.fromList
                                [ ( K.fromString "services"
                                  , A.Object $
                                        KM.fromList
                                            [ ( K.fromString "nginx"
                                              , A.Object $
                                                    KM.fromList
                                                        [ ( K.fromString "virtualHosts"
                                                          , A.Object $
                                                                KM.fromList
                                                                    [ (K.fromString "www.customer.com", mkAcmeVhost)
                                                                    ]
                                                          )
                                                        ]
                                              )
                                            ]
                                  )
                                ]
                      )
                    ]
          )
        ]

keysSet :: KM.KeyMap A.Value -> S.Set Text
keysSet =
    S.fromList . map (K.toText . fst) . KM.toList

assertSetEqual :: Text -> S.Set Text -> S.Set Text -> IO ()
assertSetEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            TIO.putStrLn ("expected: " <> tShow expected)
            TIO.putStrLn ("actual:   " <> tShow actual)
            exitFailure

tShow :: Show a => a -> Text
tShow = T.pack . show

assertHostMapEqual :: Text -> M.Map Text (Text, Text) -> M.Map Text (Text, Text) -> IO ()
assertHostMapEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            TIO.putStrLn ("expected: " <> tShow expected)
            TIO.putStrLn ("actual:   " <> tShow actual)
            exitFailure

assertBoolAt :: Text -> Bool -> [Text] -> KM.KeyMap A.Value -> IO ()
assertBoolAt label expected path obj =
    if lookupBoolAt path obj == Just expected
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            TIO.putStrLn ("path:     " <> T.intercalate "." path)
            TIO.putStrLn ("expected: " <> tShow (Just expected))
            TIO.putStrLn ("actual:   " <> tShow (lookupBoolAt path obj))
            exitFailure

assertMissingAt :: Text -> [Text] -> KM.KeyMap A.Value -> IO ()
assertMissingAt label path obj =
    if lookupAt path obj == Nothing
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            TIO.putStrLn ("path:     " <> T.intercalate "." path)
            TIO.putStrLn ("expected: missing")
            TIO.putStrLn ("actual:   " <> tShow (lookupAt path obj))
            exitFailure

lookupBoolAt :: [Text] -> KM.KeyMap A.Value -> Maybe Bool
lookupBoolAt path obj =
    case lookupAt path obj of
        Just (A.Bool value) -> Just value
        _ -> Nothing

lookupAt :: [Text] -> KM.KeyMap A.Value -> Maybe A.Value
lookupAt [] _ = Nothing
lookupAt [key] obj = KM.lookup (K.fromText key) obj
lookupAt (key : rest) obj =
    case KM.lookup (K.fromText key) obj of
        Just (A.Object next) -> lookupAt rest next
        _ -> Nothing

hostMap :: [DnsGateItem] -> M.Map Text (Text, Text)
hostMap items =
    M.fromList
        [ (item.dgiVhostName, (item.dgiDiscoveryHost, item.dgiExpectedHost))
        | item <- items
        ]

main :: IO ()
main = do
    let envs =
            KM.fromList
                [ (K.fromString "envA", mkEnv (Just "backend01"))
                , (K.fromString "envB", mkEnv (Just "backend05"))
                , (K.fromString "envC", mkEnv Nothing)
                , (K.fromString "broken", A.String "not-an-object")
                ]

    assertSetEqual
        "no node filter keeps all environments"
        (S.fromList ["envA", "envB", "envC", "broken"])
        (keysSet (filterEnvironmentsByNode Nothing envs))

    assertSetEqual
        "node filter keeps only matching node"
        (S.fromList ["envB"])
        (keysSet (filterEnvironmentsByNode (Just "backend05") envs))

    assertSetEqual
        "node filter keeps nothing when no environment matches"
        S.empty
        (keysSet (filterEnvironmentsByNode (Just "backend99") envs))

    let dnsItems =
            collectDnsGateItems
                "hosting.test"
                ( KM.fromList
                    [ ( K.fromString "envA"
                      , mkDnsEnv
                            (Just "backend05")
                            [ "env-user.hosting.test"
                            , "www.customer.com"
                            ]
                      )
                    ]
                )

    assertHostMapEqual
        "dns-gate should validate each gated vhost directly"
        ( M.fromList
            [ ("env-user.hosting.test", ("env-user.hosting.test", "backend05.hosting.test"))
            , ("www.customer.com", ("www.customer.com", "backend05.hosting.test"))
            ]
        )
        (hostMap dnsItems)

    let gatedPlan =
            disableAcmeOnNode (Just "backend05") "www.customer.com" $
                disableLetsEncryptPaths "envA" "www.customer.com" mkGatePlan

    assertBoolAt
        "dns-gate should disable environment enableLetsEncrypt"
        False
        ["environments", "envA", "virtualHosts", "www.customer.com", "enableLetsEncrypt"]
        gatedPlan

    assertBoolAt
        "dns-gate should disable environment forceSSL"
        False
        ["environments", "envA", "virtualHosts", "www.customer.com", "forceSSL"]
        gatedPlan

    assertBoolAt
        "dns-gate should disable node enableACME"
        False
        ["nodes", "backend05", "services", "nginx", "virtualHosts", "www.customer.com", "enableACME"]
        gatedPlan

    assertBoolAt
        "dns-gate should disable node forceSSL"
        False
        ["nodes", "backend05", "services", "nginx", "virtualHosts", "www.customer.com", "forceSSL"]
        gatedPlan

    assertMissingAt
        "dns-gate should not write node enableLetsEncrypt"
        [ "nodes"
        , "backend05"
        , "services"
        , "nginx"
        , "virtualHosts"
        , "www.customer.com"
        , "enableLetsEncrypt"
        ]
        gatedPlan

    let migrationItem =
            DnsGateItem
                { dgiEnvName = "envA"
                , dgiNodeName = Just "backend05"
                , dgiVhostName = "www.customer.com"
                , dgiDiscoveryHost = "www.customer.com"
                , dgiExpectedHost = "backend05.hosting.test"
                }
    let rememberedPlan = rememberDnsGateOriginal mkGatePlan migrationItem mkGatePlan
    let gatedWithOriginal =
            disableAcmeOnNode (Just "backend05") "www.customer.com" $
                disableLetsEncryptPaths "envA" "www.customer.com" rememberedPlan

    assertBoolAt
        "dns-gate should remember desired environment TLS"
        True
        ["_dnsGateOriginalVhosts", "envA", "www.customer.com", "environment", "enableLetsEncrypt"]
        gatedWithOriginal
    assertBoolAt
        "dns-gate should remember desired node ACME"
        True
        ["_dnsGateOriginalVhosts", "envA", "www.customer.com", "node", "enableACME"]
        gatedWithOriginal

    let (restoredPlan, restored) =
            restoreDnsGateOriginalForEnvironment "envA" gatedWithOriginal
    if restored
        then pure ()
        else do
            TIO.putStrLn "assertion failed (dns-gate original settings should be restorable)"
            exitFailure

    assertBoolAt
        "restored environment TLS should be enabled"
        True
        ["environments", "envA", "virtualHosts", "www.customer.com", "enableLetsEncrypt"]
        restoredPlan
    assertBoolAt
        "restored node ACME should be enabled"
        True
        ["nodes", "backend05", "services", "nginx", "virtualHosts", "www.customer.com", "enableACME"]
        restoredPlan
    assertMissingAt
        "restoring an environment should clear its dns-gate metadata"
        ["_dnsGateOriginalVhosts", "envA"]
        restoredPlan

    TIO.putStrLn "ok"
