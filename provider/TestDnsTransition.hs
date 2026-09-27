{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Hostenv.Provider.DnsTransition
import System.Exit (exitFailure)

assertTrue :: Bool -> String -> IO ()
assertTrue ok message =
    if ok then pure () else putStrLn ("assertion failed: " <> message) >> exitFailure

lookupAt :: [Text] -> KM.KeyMap A.Value -> Maybe A.Value
lookupAt [] _ = Nothing
lookupAt [key] obj = KM.lookup (K.fromText key) obj
lookupAt (key : rest) obj =
    case KM.lookup (K.fromText key) obj of
        Just (A.Object nested) -> lookupAt rest nested
        _ -> Nothing

isFalseAt :: [Text] -> KM.KeyMap A.Value -> Bool
isFalseAt path obj = lookupAt path obj == Just (A.Bool False)

main :: IO ()
main = do
    let envs =
            KM.fromList
                [ ( K.fromString "acme-prod"
                  , A.object
                        [ "node" A..= ("new-node" :: Text)
                        , "virtualHosts" A..=
                            A.object
                                [ "www.example.test" A..= A.object []
                                , "acme-prod.hosting.test" A..= A.object []
                                ]
                        ]
                  )
                ]
    let items = collectDnsItems "hosting.test" envs
    assertTrue (length items == 2) "collect every environment vhost"
    assertTrue (all ((== Just "new-node") . (.diNodeName)) items) "retain destination node"
    assertTrue (all ((== "new-node.hosting.test") . (.diExpectedHost)) items) "target destination node hostname"

    let plan =
            KM.fromList
                [ (K.fromString "environments", A.Object envs)
                , ( K.fromString "nodes"
                  , A.object
                        [ "new-node" A..=
                            A.object
                                [ "services" A..=
                                    A.object
                                        [ "nginx" A..=
                                            A.object
                                                [ "virtualHosts" A..=
                                                    A.object
                                                        [ "www.example.test" A..=
                                                            A.object
                                                                [ "enableACME" A..= True
                                                                , "forceSSL" A..= True
                                                                ]
                                                        , "acme-prod.hosting.test" A..=
                                                            A.object
                                                                [ "enableACME" A..= True
                                                                , "forceSSL" A..= True
                                                                ]
                                                        ]
                                                ]
                                        ]
                                ]
                        ]
                  )
                ]
    let gated = gateTlsForItems items plan
    assertTrue
        (isFalseAt ["nodes","new-node","services","nginx","virtualHosts","www.example.test","enableACME"] gated)
        "disable ACME in transient plan"
    assertTrue
        (isFalseAt ["nodes","new-node","services","nginx","virtualHosts","www.example.test","forceSSL"] gated)
        "disable forceSSL in transient plan"
