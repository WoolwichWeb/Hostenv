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
    assertTrue (all ((== Just "new-node") . (.diNodeName)) items) "retain destination node"
    assertTrue (all ((== "new-node.hosting.test") . (.diExpectedHost)) items) "target destination node hostname"
    assertTrue
        ( [item.diDiscoveryHost | item <- items, item.diTlsEnabled]
            == ["acme-prod.hosting.test"]
        )
        "retain which vhosts require trusted HTTPS"
    assertTrue
        ( authoritativeCnameConverged
            "new-node.hosting.test"
            [ Right ["new-node.hosting.test"]
            , Right ["new-node.hosting.test."]
            ]
        )
        "all authoritative nameservers agreeing on the destination should be ready"

    assertTrue
        ( not
            ( authoritativeCnameConverged
                "new-node.hosting.test"
                [ Right ["old-node.hosting.test"]
                , Right ["new-node.hosting.test"]
                ]
            )
        )
        "mixed authoritative CNAME answers should not be treated as propagated"

    assertTrue
        ( not
            ( authoritativeCnameConverged
                "new-node.hosting.test"
                [ Right ["new-node.hosting.test"]
                , Left "nameserver timed out"
                ]
            )
        )
        "a failed authoritative lookup should not be treated as propagated"
