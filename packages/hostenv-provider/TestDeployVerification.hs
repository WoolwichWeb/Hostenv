{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

import Control.Monad (unless)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Hostenv.Provider.DeployVerification
import System.Exit (exitFailure)
import System.Exit qualified as Exit

assert :: Bool -> Text -> IO ()
assert cond msg =
    unless cond $ do
        putStrLn ("FAIL: " <> show msg)
        exitFailure

mkRequest :: VerificationRequest
mkRequest =
    VerificationRequest
        { vrVirtualHost = "www.example.test"
        , vrPath = "/"
        , vrMethod = "GET"
        , vrTargetHostSource = TargetNodeConnectionHost
        , vrFollowRedirects = False
        , vrMaxRedirects = 5
        , vrTimeoutSeconds = 10
        , vrTlsMode = TlsStrict
        }

mkSpec :: [VerificationConstraint] -> EnvVerificationSpec
mkSpec constraints =
    EnvVerificationSpec
        { evEnable = True
        , evEnforce = True
        , evChecks =
            [ VerificationCheck
                { vcName = "drupal-homepage"
                , vcType = "httpHostHeaderCurl"
                , vcRequest = mkRequest
                , vcConstraints = constraints
                }
            ]
        }

mkSpecWithRequest :: VerificationRequest -> [VerificationConstraint] -> EnvVerificationSpec
mkSpecWithRequest request constraints =
    EnvVerificationSpec
        { evEnable = True
        , evEnforce = True
        , evChecks =
            [ VerificationCheck
                { vcName = "drupal-homepage"
                , vcType = "httpHostHeaderCurl"
                , vcRequest = request
                , vcConstraints = constraints
                }
            ]
        }

mkCurlOutput :: Text -> Int -> Text
mkCurlOutput body status =
    body
        <> "\n__HOSTENV_PROVIDER_HTTP_STATUS__:"
        <> fromInt status
        <> "\n__HOSTENV_PROVIDER_EFFECTIVE_URL__:http://www.example.test/\n"
  where
    fromInt = T.pack . show

main :: IO ()
main = do
    assert
        (parseEnvVerificationSpec KM.empty == Right defaultEnvVerificationSpec)
        "missing deploymentVerification should use defaults"

    let legacyConnPlan =
            asObject $
                A.object
                    [ "nodeConnections"
                        .= A.object
                            [ "node-a"
                                .= A.object
                                    [ "hostname" .= ("bastion.example.test" :: Text)
                                    , "sshOpts" .= ["-J" :: Text, "jump.example.test"]
                                    ]
                            ]
                    ]
    let legacyConn = nodeConnectionFor legacyConnPlan "hosting.test" "node-a"

    assert
        (legacyConn.hostname == "bastion.example.test")
        "node connections should keep SSH hostname overrides"

    assert
        (canonicalNodeHostname "hosting.test" "node-a" == "node-a.hosting.test")
        "deployment verification should derive the canonical public node hostname"

    assert
        (legacyConn.sshOpts == ["-J", "jump.example.test"])
        "node connections should preserve SSH options"

    let oldConnPlan =
            asObject $
                A.object
                    [ "nodeConnections"
                        .= A.object
                            [ "node-a"
                                .= A.object
                                    [ "hostname" .= ("bastion.example.test" :: Text)
                                    , "verificationHostname" .= ("frontend.node-a.hosting.test" :: Text)
                                    , "sshOpts" .= ["-J" :: Text, "jump.example.test"]
                                    ]
                            ]
                    ]

    let oldConn = nodeConnectionFor oldConnPlan "hosting.test" "node-a"

    assert
        (oldConn.hostname == "bastion.example.test")
        "old verificationHostname fields should be ignored without changing the SSH hostname"

    assert
        (oldConn.sshOpts == ["-J", "jump.example.test"])
        "old verificationHostname fields should be ignored without changing SSH options"

    resultsPass <-
        runEnvVerificationWith
            (\_ -> pure (Exit.ExitSuccess, showText (mkCurlOutput "<meta name=\"Generator\" content=\"Drupal 11\" />" 200), ""))
            "backend04.hostenv.sh"
            (mkSpec [AllowNonZeroExitStatus False, MinHttpStatus 200, MaxHttpStatus 299, StdoutRegexMustMatch "Generator"])
    let passResult = case firstResult resultsPass of
            VerificationCheckResult{vcrPassed = passed} -> passed
    assert passResult "200 response with generator should pass"

    capturedArgs <- newIORef ([] :: [String])
    _followResults <-
        runEnvVerificationWith
            ( \args -> do
                writeIORef capturedArgs args
                pure (Exit.ExitSuccess, showText (mkCurlOutput "<meta name=\"Generator\" content=\"Drupal 11\" />" 200), "")
            )
            "backend04.hostenv.sh"
            ( mkSpecWithRequest
                (mkRequest{vrFollowRedirects = True})
                [AllowNonZeroExitStatus False, MinHttpStatus 200, MaxHttpStatus 299, StdoutRegexMustMatch "Generator"]
            )
    followArgs <- readIORef capturedArgs
    assert ("--location" `elem` followArgs) "followRedirects should add --location to curl args"
    assert
        ("www.example.test:80:backend04.hostenv.sh:80" `elem` followArgs)
        "curl args should pin HTTP target host to deployment node"
    assert
        ("www.example.test:443:backend04.hostenv.sh:443" `elem` followArgs)
        "curl args should pin HTTPS redirect target host to deployment node"

    resultsFail <-
        runEnvVerificationWith
            (\_ -> pure (Exit.ExitSuccess, showText (mkCurlOutput "Moved Permanently" 301), ""))
            "backend04.hostenv.sh"
            (mkSpec [AllowNonZeroExitStatus False, MinHttpStatus 200, MaxHttpStatus 399, StdoutRegexMustMatch "Generator"])
    let failResult = case firstResult resultsFail of
            VerificationCheckResult{vcrPassed = passed} -> passed
    assert (not failResult) "301 response without generator should fail by default"

    resultsRedirectOk <-
        runEnvVerificationWith
            (\_ -> pure (Exit.ExitSuccess, showText (mkCurlOutput "Moved Permanently" 301), ""))
            "backend04.hostenv.sh"
            ( mkSpec
                [ AllowNonZeroExitStatus False
                , MinHttpStatus 200
                , MaxHttpStatus 399
                , SkipStdoutRegexOnRedirect True
                , StdoutRegexMustMatch "Generator"
                ]
            )
    let redirectOkResult = firstResult resultsRedirectOk
    let redirectOkPassed = case redirectOkResult of
            VerificationCheckResult{vcrPassed = passed} -> passed
    assert redirectOkPassed "301 response should pass when skipStdoutRegexOnRedirect=true"

    putStrLn "ok"

showText :: Text -> String
showText = T.unpack

firstResult :: [a] -> a
firstResult results =
    case results of
        (x : _) -> x
        [] -> error "expected at least one verification result"

asObject :: A.Value -> KM.KeyMap A.Value
asObject value =
    case value of
        A.Object obj -> obj
        _ -> error "expected JSON object"
