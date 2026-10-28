{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.DeployVerification (
    NodeConnection (..),
    defaultNodeConnection,
    nodeConnectionFor,
    TargetHostSource (..),
    TlsMode (..),
    VerificationRequest (..),
    VerificationConstraint (..),
    VerificationCheck (..),
    EnvVerificationSpec (..),
    VerificationCheckResult (..),
    defaultEnvVerificationSpec,
    parseEnvVerificationSpec,
    runEnvVerification,
    runEnvVerificationWith,
    canonicalNodeHostname,
) where

import Control.Monad (forM)
import Data.Aeson ((.!=), (.:), (.:?))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data NodeConnection = NodeConnection
    { hostname :: Text
    , sshOpts :: [Text]
    }
    deriving (Eq, Show)

{- | Hostname for deploy verification only.
  Should not be used to verify DNS record correctness.
-}
canonicalNodeHostname :: Text -> Text -> Text
canonicalNodeHostname hostenvHostname nodeName =
    nodeName <> "." <> hostenvHostname

defaultNodeConnection :: Text -> Text -> NodeConnection
defaultNodeConnection hostenvHostname nodeName =
    let hostname = canonicalNodeHostname hostenvHostname nodeName
     in NodeConnection
            { hostname = hostname
            , sshOpts = []
            }

parseNodeConnection :: Text -> Text -> A.Value -> Parser NodeConnection
parseNodeConnection hostenvHostname nodeName =
    A.withObject "NodeConnection" $ \o ->
        let canonicalHostname = canonicalNodeHostname hostenvHostname nodeName
         in NodeConnection
                <$> o .:? "hostname" .!= canonicalHostname
                <*> o .:? "sshOpts" .!= []

nodeConnectionFor :: KM.KeyMap A.Value -> Text -> Text -> NodeConnection
nodeConnectionFor plan hostenvHostname nodeName =
    fromMaybe
        (defaultNodeConnection hostenvHostname nodeName)
        (lookupNodeConnection plan hostenvHostname nodeName)

lookupNodeConnection :: KM.KeyMap A.Value -> Text -> Text -> Maybe NodeConnection
lookupNodeConnection plan hostenvHostname nodeName = do
    conns <- lookupObj (K.fromString "nodeConnections") plan
    raw <- KM.lookup (K.fromText nodeName) conns
    either (const Nothing) Just (parseEither (parseNodeConnection hostenvHostname nodeName) raw)

lookupObj :: K.Key -> KM.KeyMap A.Value -> Maybe (KM.KeyMap A.Value)
lookupObj key obj = case KM.lookup key obj of
    Just (A.Object o) -> Just o
    _ -> Nothing

data TargetHostSource
    = TargetNodeConnectionHost
    deriving (Eq, Show)

instance A.FromJSON TargetHostSource where
    parseJSON = A.withText "TargetHostSource" $ \value ->
        case value of
            "nodeConnectionHost" -> pure TargetNodeConnectionHost
            _ -> fail ("Unknown targetHostSource value: " <> T.unpack value)

data TlsMode
    = TlsStrict
    | TlsInsecure
    deriving (Eq, Show)

instance A.FromJSON TlsMode where
    parseJSON = A.withText "TlsMode" $ \value ->
        case value of
            "strict" -> pure TlsStrict
            "insecure" -> pure TlsInsecure
            _ -> fail ("Unknown tlsMode value: " <> T.unpack value)

data VerificationRequest = VerificationRequest
    { vrVirtualHost :: Text
    , vrPath :: Text
    , vrMethod :: Text
    , vrTargetHostSource :: TargetHostSource
    , vrFollowRedirects :: Bool
    , vrMaxRedirects :: Int
    , vrTimeoutSeconds :: Int
    , vrTlsMode :: TlsMode
    }
    deriving (Eq, Show)

instance A.FromJSON VerificationRequest where
    parseJSON = A.withObject "VerificationRequest" $ \o -> do
        virtualHost <- o .: "virtualHost"
        path <- o .:? "path" .!= "/"
        method <- o .:? "method" .!= "GET"
        targetHostSource <- o .:? "targetHostSource" .!= TargetNodeConnectionHost
        followRedirects <- o .:? "followRedirects" .!= False
        maxRedirects <- o .:? "maxRedirects" .!= 5
        timeoutSeconds <- o .:? "timeoutSeconds" .!= 15
        tlsMode <- o .:? "tlsMode" .!= TlsStrict
        pure
            VerificationRequest
                { vrVirtualHost = virtualHost
                , vrPath = path
                , vrMethod = method
                , vrTargetHostSource = targetHostSource
                , vrFollowRedirects = followRedirects
                , vrMaxRedirects = maxRedirects
                , vrTimeoutSeconds = timeoutSeconds
                , vrTlsMode = tlsMode
                }

data VerificationConstraint
    = AllowNonZeroExitStatus Bool
    | SkipStdoutRegexOnRedirect Bool
    | StdoutRegexMustMatch Text
    | StderrRegexMustNotMatch Text
    | MinHttpStatus Int
    | MaxHttpStatus Int
    deriving (Eq, Show)

instance A.FromJSON VerificationConstraint where
    parseJSON = A.withObject "VerificationConstraint" $ \o -> do
        rule <- o .: "rule"
        value <- o .: "value"
        case rule of
            "allowNonZeroExitStatus" ->
                case value of
                    A.Bool b -> pure (AllowNonZeroExitStatus b)
                    _ -> fail "allowNonZeroExitStatus must be a Boolean value"
            "skipStdoutRegexOnRedirect" ->
                case value of
                    A.Bool b -> pure (SkipStdoutRegexOnRedirect b)
                    _ -> fail "skipStdoutRegexOnRedirect must be a Boolean value"
            "stdoutRegexMustMatch" ->
                case value of
                    A.String t -> pure (StdoutRegexMustMatch t)
                    _ -> fail "stdoutRegexMustMatch must be a regular-expression string"
            "stderrRegexMustNotMatch" ->
                case value of
                    A.String t -> pure (StderrRegexMustNotMatch t)
                    _ -> fail "stderrRegexMustNotMatch must be a regular-expression string"
            "minHttpStatus" ->
                case value of
                    A.Number n -> case (floatingOrInteger n :: Either Double Int) of
                        Right i -> pure (MinHttpStatus i)
                        Left _ -> fail "minHttpStatus must be an integer"
                    _ -> fail "minHttpStatus must be an integer"
            "maxHttpStatus" ->
                case value of
                    A.Number n -> case (floatingOrInteger n :: Either Double Int) of
                        Right i -> pure (MaxHttpStatus i)
                        Left _ -> fail "maxHttpStatus must be an integer"
                    _ -> fail "maxHttpStatus must be an integer"
            _ -> fail ("Unknown verification constraint: " <> T.unpack rule)

data VerificationCheck = VerificationCheck
    { vcName :: Text
    , vcType :: Text
    , vcRequest :: VerificationRequest
    , vcConstraints :: [VerificationConstraint]
    }
    deriving (Eq, Show)

instance A.FromJSON VerificationCheck where
    parseJSON = A.withObject "VerificationCheck" $ \o -> do
        name <- o .:? "name" .!= "verification-check"
        checkType <- o .:? "type" .!= "httpHostHeaderCurl"
        request <- o .: "request"
        constraints <- o .:? "constraints" .!= []
        pure
            VerificationCheck
                { vcName = name
                , vcType = checkType
                , vcRequest = request
                , vcConstraints = constraints
                }

data EnvVerificationSpec = EnvVerificationSpec
    { evEnable :: Bool
    , evEnforce :: Bool
    , evChecks :: [VerificationCheck]
    }
    deriving (Eq, Show)

instance A.FromJSON EnvVerificationSpec where
    parseJSON = A.withObject "EnvVerificationSpec" $ \o -> do
        enable <- o .:? "enable" .!= True
        enforce <- o .:? "enforce" .!= True
        checks <- o .:? "checks" .!= []
        pure
            EnvVerificationSpec
                { evEnable = enable
                , evEnforce = enforce
                , evChecks = checks
                }

data VerificationCheckResult = VerificationCheckResult
    { vcrName :: Text
    , vcrPassed :: Bool
    , vcrHttpStatus :: Maybe Int
    , vcrFailures :: [Text]
    }
    deriving (Eq, Show)

defaultEnvVerificationSpec :: EnvVerificationSpec
defaultEnvVerificationSpec =
    EnvVerificationSpec
        { evEnable = True
        , evEnforce = True
        , evChecks = []
        }

parseEnvVerificationSpec :: KM.KeyMap A.Value -> Either Text EnvVerificationSpec
parseEnvVerificationSpec envObj =
    case KM.lookup (K.fromString "deploymentVerification") envObj of
        Nothing -> Right defaultEnvVerificationSpec
        Just raw ->
            case A.fromJSON raw of
                A.Error err -> Left (T.pack err)
                A.Success parsed -> Right parsed

type CurlRunner = [String] -> IO (ExitCode, String, String)

runEnvVerification :: Text -> EnvVerificationSpec -> IO [VerificationCheckResult]
runEnvVerification targetHost spec =
    runEnvVerificationWith (\args -> readProcessWithExitCode "curl" args "") targetHost spec

runEnvVerificationWith :: CurlRunner -> Text -> EnvVerificationSpec -> IO [VerificationCheckResult]
runEnvVerificationWith runCurl targetHost spec =
    forM spec.evChecks (runOneCheck runCurl targetHost)

statusMarker :: Text
statusMarker = "__HOSTENV_PROVIDER_HTTP_STATUS__:"

effectiveUrlMarker :: Text
effectiveUrlMarker = "__HOSTENV_PROVIDER_EFFECTIVE_URL__:"

runOneCheck :: CurlRunner -> Text -> VerificationCheck -> IO VerificationCheckResult
runOneCheck runCurl targetHost check =
    if check.vcType /= "httpHostHeaderCurl"
        then
            pure
                VerificationCheckResult
                    { vcrName = check.vcName
                    , vcrPassed = False
                    , vcrHttpStatus = Nothing
                    , vcrFailures = ["Unsupported verification check type: " <> check.vcType]
                    }
        else do
            let request = check.vcRequest
            let curlArgs = buildCurlArgs targetHost request
            (code, out, err) <- runCurl curlArgs
            let (body, mStatus, _effectiveUrl) = parseCurlOutput (T.pack out)
            failures <- evaluateConstraints code mStatus body (T.pack err) check.vcConstraints
            pure
                VerificationCheckResult
                    { vcrName = check.vcName
                    , vcrPassed = null failures
                    , vcrHttpStatus = mStatus
                    , vcrFailures = failures
                    }

buildCurlArgs :: Text -> VerificationRequest -> [String]
buildCurlArgs targetHost request =
    map T.unpack $
        [ "--silent"
        , "--show-error"
        , "--request"
        , T.toUpper request.vrMethod
        , "--header"
        , "Host: " <> request.vrVirtualHost
        , "--connect-timeout"
        , "5"
        , "--max-time"
        , T.pack (show request.vrTimeoutSeconds)
        , "--connect-to"
        , request.vrVirtualHost <> ":80:" <> targetHost <> ":80"
        , "--connect-to"
        , request.vrVirtualHost <> ":443:" <> targetHost <> ":443"
        ]
            <> redirectArgs
            <> tlsArgs
            <> writeOutArgs
            <> [requestUrl]
  where
    requestPath =
        if T.null request.vrPath
            then "/"
            else
                if T.isPrefixOf "/" request.vrPath
                    then request.vrPath
                    else "/" <> request.vrPath
    requestUrl = "http://" <> request.vrVirtualHost <> requestPath
    redirectArgs =
        if request.vrFollowRedirects
            then
                [ "--location"
                , "--max-redirs"
                , T.pack (show request.vrMaxRedirects)
                ]
            else []
    tlsArgs = case request.vrTlsMode of
        TlsStrict -> []
        TlsInsecure -> ["--insecure"]
    writeOutArgs =
        [ "--write-out"
        , "\n"
            <> statusMarker
            <> "%{http_code}\n"
            <> effectiveUrlMarker
            <> "%{url_effective}\n"
        ]

parseCurlOutput :: Text -> (Text, Maybe Int, Maybe Text)
parseCurlOutput output =
    let lines' = T.lines output
        statusText = extractMarker statusMarker lines'
        mStatus = statusText >>= parseStatus
        effectiveUrl = extractMarker effectiveUrlMarker lines'
        bodyLines =
            filter
                (\line -> not (statusMarker `T.isPrefixOf` line || effectiveUrlMarker `T.isPrefixOf` line))
                lines'
        body =
            if null bodyLines
                then ""
                else T.intercalate "\n" bodyLines
     in (body, mStatus, effectiveUrl)
  where
    extractMarker marker lines' =
        fmap (T.drop (T.length marker)) $
            find (T.isPrefixOf marker) (reverse lines')
    parseStatus raw =
        case reads (T.unpack (T.strip raw)) of
            [(value, "")] -> Just value
            _ -> Nothing

evaluateConstraints :: ExitCode -> Maybe Int -> Text -> Text -> [VerificationConstraint] -> IO [Text]
evaluateConstraints exitCode mHttpStatus stdoutText stderrText constraints = do
    let skipStdoutRegex = resolveSkipStdoutRegex constraints && isRedirectStatus mHttpStatus
    regexFailures <- fmap concat $
        forM constraints $ \constraint ->
            case constraint of
                StdoutRegexMustMatch pattern -> do
                    if skipStdoutRegex
                        then pure []
                        else do
                            matched <- regexMatches pattern stdoutText
                            pure $
                                case matched of
                                    Left err -> [err]
                                    Right True -> []
                                    Right False -> ["Standard output did not match the regular expression: " <> pattern]
                StderrRegexMustNotMatch pattern -> do
                    matched <- regexMatches pattern stderrText
                    pure $
                        case matched of
                            Left err -> [err]
                            Right True -> ["Standard error matched a forbidden regular expression: " <> pattern]
                            Right False -> []
                _ -> pure []

    let allowNonZero = resolveAllowNonZero constraints
    let exitFailures =
            case exitCode of
                ExitFailure code
                    | not allowNonZero -> ["curl exited with status " <> T.pack (show code)]
                _ -> []

    let statusFailures = concatMap (checkHttpStatus mHttpStatus) constraints
    pure (exitFailures <> statusFailures <> regexFailures)

resolveAllowNonZero :: [VerificationConstraint] -> Bool
resolveAllowNonZero constraints =
    case [value | AllowNonZeroExitStatus value <- constraints] of
        [] -> False
        values -> last values

resolveSkipStdoutRegex :: [VerificationConstraint] -> Bool
resolveSkipStdoutRegex constraints =
    case [value | SkipStdoutRegexOnRedirect value <- constraints] of
        [] -> False
        values -> last values

isRedirectStatus :: Maybe Int -> Bool
isRedirectStatus mStatus =
    case mStatus of
        Just status -> status >= 300 && status <= 399
        Nothing -> False

checkHttpStatus :: Maybe Int -> VerificationConstraint -> [Text]
checkHttpStatus mHttpStatus constraint =
    case constraint of
        MinHttpStatus minStatus ->
            case mHttpStatus of
                Nothing -> ["No HTTP status was returned for minHttpStatus"]
                Just status ->
                    if status >= minStatus
                        then []
                        else ["HTTP status " <> T.pack (show status) <> " is below minimum " <> T.pack (show minStatus)]
        MaxHttpStatus maxStatus ->
            case mHttpStatus of
                Nothing -> ["No HTTP status was returned for maxHttpStatus"]
                Just status ->
                    if status <= maxStatus
                        then []
                        else ["HTTP status " <> T.pack (show status) <> " is above maximum " <> T.pack (show maxStatus)]
        _ -> []

regexMatches :: Text -> Text -> IO (Either Text Bool)
regexMatches pattern subject = do
    (code, _out, err) <- readProcessWithExitCode "grep" ["-E", "-q", "--", T.unpack pattern] (T.unpack subject)
    pure $ case code of
        ExitSuccess -> Right True
        ExitFailure 1 -> Right False
        ExitFailure _ ->
            Left
                ( "Could not evaluate regular expression '"
                    <> pattern
                    <> "': "
                    <> T.strip (T.pack err)
                )
