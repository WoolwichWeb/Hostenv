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

main :: IO ()
main = do
    let envs =
            KM.fromList
                [ ( K.fromString "acme-prod"
                  , A.object
                        [ "node" A..= ("new-node" :: Text)
                        , "virtualHosts" A..=
                            A.object
                                [ "www.example.test" A..=
                                    A.object ["enableLetsEncrypt" A..= False]
                                , "acme-prod.hosting.test" A..=
                                    A.object ["enableLetsEncrypt" A..= True]
                                ]
                        ]
                  )
                ]
    let items = collectDnsItems "hosting.test" envs
    assertTrue (length items == 2) "collect every environment vhost"
    assertTrue (all ((== "new-node.hosting.test") . (.diExpectedHost)) items) "target destination node hostname"
    assertTrue
        ( [item.diDiscoveryHost | item <- items, item.diTlsEnabled]
            == ["acme-prod.hosting.test"]
        )
        "retain which vhosts require trusted HTTPS"
    assertTrue
        ( authoritativeDnsTargetConverged
            "new-node.hosting.test"
            []
            [ (["new-node.hosting.test"], [])
            , (["new-node.hosting.test."], [])
            ]
        )
        "all authoritative nameservers agreeing on the destination CNAME should be ready"

    assertTrue
        ( not
            ( authoritativeDnsTargetConverged
                "new-node.hosting.test"
                []
                [ (["old-node.hosting.test"], [])
                , (["new-node.hosting.test"], [])
                ]
            )
        )
        "mixed authoritative CNAME answers should not be treated as propagated"

    assertTrue
        ( authoritativeDnsTargetConverged
            "new-node.hosting.test"
            ["192.0.2.20", "2001:db8::20"]
            [ ([], ["192.0.2.20"])
            , ([], ["2001:db8::20"])
            ]
        )
        "direct address records that all belong to the destination should be ready"

    assertTrue
        ( not
            ( authoritativeDnsTargetConverged
                "new-node.hosting.test"
                ["192.0.2.20"]
                [ ([], ["192.0.2.10"])
                , ([], ["192.0.2.20"])
                ]
            )
        )
        "mixed authoritative address answers should not be treated as propagated"

    assertTrue
        ( not
            ( authoritativeDnsTargetConverged
                "new-node.hosting.test"
                []
                []
            )
        )
        "no authoritative observations should not be treated as propagated"
