{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- hostenv-provider CLI: plan | deploy

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (iparseEither, parseJSON)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Char (isAlphaNum, isHexDigit, toUpper)
import Data.Foldable (toList)
import Data.List ((\\))
import Data.Map.Strict qualified as M
import Data.Maybe (catMaybes, fromMaybe, isNothing, listToMaybe, mapMaybe)
import Data.Set qualified as S
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Conversions (convertText)
import Data.Text.Encoding qualified as TE
import Distribution.Compat.Prelude qualified as Sh
import Hostenv.Provider.DeployGuidance (FlakeKeyStatus (..), localTrustSetupLines, remoteNodeTrustLines)
import Hostenv.Provider.DeployPreflight qualified as Preflight
import Hostenv.Provider.DeployVerification (NodeConnection (..), nodeConnectionFor)
import Hostenv.Provider.DeployVerification qualified as Verify
import Hostenv.Provider.EnvironmentState qualified as EnvironmentState
import Hostenv.Provider.MigrationHandoff qualified as MigrationHandoff
import Hostenv.Provider.PlanTransition qualified as PlanTransition
import Hostenv.Provider.Dns qualified as Dns
import Hostenv.Provider.DnsBackoff (backoffDelays)
import Hostenv.Provider.DnsTransition (
    DnsItem (..),
    collectDnsItems,
 )
import Hostenv.Provider.SigningTarget (deployProfilePathInstallableAt)
import Hostenv.Provider.TlsReadiness qualified as TlsReadiness
import Hostenv.Provider.UserLifecycle qualified as UserLifecycle
import Options.Applicative qualified as OA
import System.Directory qualified as Dir
import System.Environment qualified as Env
import System.Exit (ExitCode (..))
import System.FilePath qualified as FP
import System.IO (hClose, openBinaryTempFile, openTempFile, stderr)
import System.Process (readProcessWithExitCode)
import Turtle (FilePath, (<|>))
import Turtle qualified as Sh
import Prelude hiding (FilePath)

-- -------- CLI --------
data Command
    = CmdPlan {dryRun :: Bool}
    | CmdDeploy
        { node :: Maybe Text
        , token :: Maybe Text
        , zone :: Maybe Text
        , signingKeyFile :: Maybe Text
        , remoteBuild :: Bool
        , skipVerification :: Bool
        , skipMigrations :: [Text]
        , migrationSources :: [Text]
        , ignoreMigrationErrors :: Bool
        , dryRun :: Bool
        }

data CLI = CLI {cliCmd :: Command}

nodeOpt :: OA.Parser (Maybe Text)
nodeOpt =
    OA.optional . fmap T.pack $
        OA.strOption
            ( OA.long "node"
                <> OA.short 'n'
                <> OA.metavar "NODE"
                <> OA.help "Deploy only to this node"
            )

tokenOpt :: OA.Parser (Maybe Text)
tokenOpt = OA.optional . fmap T.pack $ OA.strOption (OA.long "cf-token" <> OA.metavar "TOKEN" <> OA.help "Cloudflare API token (overrides CF_API_TOKEN)")

zoneOpt :: OA.Parser (Maybe Text)
zoneOpt = OA.optional . fmap T.pack $ OA.strOption (OA.long "cf-zone" <> OA.metavar "ZONE" <> OA.help "Cloudflare zone ID (overrides CF_ZONE_ID)")

dryRunOpt :: OA.Parser Bool
dryRunOpt =
    OA.switch
        ( OA.long "dry-run"
            <> OA.help "Preview changes without changing generated files or remote systems"
        )

skipMigrationsOpt :: OA.Parser [Text]
skipMigrationsOpt =
    OA.many . fmap T.pack $
        OA.strOption
            ( OA.long "skip-migrations"
                <> OA.metavar "ENV"
                <> OA.help "Skip migration for an environment (may be repeated)"
            )

signingKeyFileOpt :: OA.Parser (Maybe Text)
signingKeyFileOpt =
    OA.optional . fmap T.pack $
        OA.strOption
            ( OA.long "signing-key-file"
                <> OA.metavar "PATH"
                <> OA.help "Path to the Nix secret signing key (defaults to HOSTENV_SIGNING_KEY_FILE or secrets/signing/secret.key)"
            )

remoteBuildOpt :: OA.Parser Bool
remoteBuildOpt =
    OA.switch
        ( OA.long "remote-build"
            <> OA.help "Build all deployment targets on their remote nodes"
        )

skipVerificationOpt :: OA.Parser Bool
skipVerificationOpt =
    OA.switch
        ( OA.long "skip-verification"
            <> OA.help "Skip post-deployment verification checks"
        )

ignoreMigrationErrorsOpt :: OA.Parser Bool
ignoreMigrationErrorsOpt =
    OA.switch
        ( OA.long "ignore-migration-errors"
            <> OA.help "Continue after migration errors; destination data may be stale"
        )

migrationSourceOpt :: OA.Parser [Text]
migrationSourceOpt =
    OA.many . fmap T.pack $
        OA.strOption
            ( OA.long "migration-source"
                <> OA.metavar "ENV=NODE"
                <> OA.help "Set the migration source node for an environment (may be repeated)"
            )

cliParser :: OA.Parser CLI
cliParser =
    CLI
        <$> OA.hsubparser
            ( OA.command "plan" (OA.info (CmdPlan <$> dryRunOpt) (OA.progDesc "Generate the provider plan, state, and deployment flake"))
                <> OA.command "deploy" (OA.info (CmdDeploy <$> nodeOpt <*> tokenOpt <*> zoneOpt <*> signingKeyFileOpt <*> remoteBuildOpt <*> skipVerificationOpt <*> skipMigrationsOpt <*> migrationSourceOpt <*> ignoreMigrationErrorsOpt <*> dryRunOpt) (OA.progDesc "Deploy provider nodes and environments"))
            )

cliOpts :: OA.ParserInfo CLI
cliOpts =
    OA.info
        (cliParser OA.<**> OA.helper)
        ( OA.fullDesc
            <> OA.header "hostenv-provider"
        )

-- -------- Shared helpers --------
tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

lookupText :: KM.Key -> KM.KeyMap A.Value -> Maybe Text
lookupText k o = case KM.lookup k o of
    Just (A.String t) -> Just t
    _ -> Nothing

lookupObj :: KM.Key -> KM.KeyMap A.Value -> Maybe (KM.KeyMap A.Value)
lookupObj k o = case KM.lookup k o of
    Just (A.Object x) -> Just x
    _ -> Nothing

lookupTextList :: KM.Key -> KM.KeyMap A.Value -> [Text]
lookupTextList k o = case KM.lookup k o of
    Just (A.Array arr) -> mapMaybe asText (toList arr)
    _ -> []
  where
    asText (A.String t) = Just t
    asText _ = Nothing

lookupBool :: KM.Key -> KM.KeyMap A.Value -> Maybe Bool
lookupBool k o = case KM.lookup k o of
    Just (A.Bool b) -> Just b
    _ -> Nothing

prettyJson :: BL.ByteString -> IO BL.ByteString
prettyJson raw = do
    (code, out, err) <- readProcessWithExitCode "jq" ["-S", "."] (T.unpack (TE.decodeUtf8 (BL.toStrict raw)))
    case code of
        ExitSuccess -> pure (BL.fromStrict (TE.encodeUtf8 (T.pack out)))
        ExitFailure c ->
            error ("jq failed while formatting JSON (exit " <> show c <> "): " <> err)

withSameDirectoryTempFile :: Text -> BL.ByteString -> (String -> IO a) -> IO a
withSameDirectoryTempFile destination content action = do
    let destinationPath = T.unpack destination
    let directory = FP.takeDirectory destinationPath
    let template = "." <> FP.takeFileName destinationPath <> ".tmp-"
    Dir.createDirectoryIfMissing True directory
    (tmpPath, handle) <- openBinaryTempFile directory template
    let cleanup = do
            _ <- tryAny (hClose handle)
            _ <- tryAny (Dir.removeFile tmpPath)
            pure ()
    (do
        BL.hPut handle content
        hClose handle
        action tmpPath
      )
        `finally` cleanup

withTempBytesFile :: String -> BL.ByteString -> (FilePath -> IO a) -> IO a
withTempBytesFile template content action = do
    tmpDir <- Dir.getTemporaryDirectory
    (tmpPath, handle) <- openTempFile tmpDir template
    BL.hPut handle content
    hClose handle
    action tmpPath
        `finally` do
            _ <- try (Dir.removeFile tmpPath) :: IO (Either SomeException ())
            pure ()

printUnifiedDiff :: Text -> BL.ByteString -> BL.ByteString -> IO Bool
printUnifiedDiff path oldContent newContent =
    withTempBytesFile "hostenv-provider-old-XXXXXX.json" oldContent $ \oldPath ->
        withTempBytesFile "hostenv-provider-new-XXXXXX.json" newContent $ \newPath -> do
            let oldLabel = T.unpack (path <> " (current)")
            let newLabel = T.unpack (path <> " (proposed)")
            (code, out, err) <- readProcessWithExitCode "diff" ["-u", "--label", oldLabel, "--label", newLabel, oldPath, newPath] ""
            case code of
                ExitSuccess -> pure False
                ExitFailure 1 -> do
                    BLC.putStr (BLC.pack out)
                    pure True
                ExitFailure c -> do
                    printProviderErrLine ("Warning: could not render diff for " <> path <> " (exit " <> T.pack (show c) <> ")")
                    when (not (null err)) $
                        printProviderErrLine ("diff error output: " <> T.pack err)
                    pure True

printDiffAgainstFile :: Text -> BL.ByteString -> IO Bool
printDiffAgainstFile path proposedPretty = do
    pathExists <- Dir.doesFileExist (T.unpack path)
    if not pathExists
        then do
            printProviderLine ("Dry run: " <> path <> " does not exist; generated content would be:")
            BLC.putStr proposedPretty
            pure True
        else do
            currentRaw <- BL.readFile (T.unpack path)
            currentPrettyResult <- tryAny (prettyJson currentRaw)
            case currentPrettyResult of
                Right currentPretty ->
                    if currentPretty == proposedPretty
                        then do
                            printProviderLine ("Dry run: no changes for " <> path)
                            pure False
                        else printUnifiedDiff path currentPretty proposedPretty
                Left _ -> do
                    printProviderLine
                        ( "Dry run: current "
                            <> path
                            <> " is not valid JSON; showing raw current content against the proposed plan"
                        )
                    printUnifiedDiff path currentRaw proposedPretty

-- -------- Migration helpers --------
data EnvInfo = EnvInfo
    { userName :: Text
    , node :: Text
    , migrateBackups :: [Text]
    , runtimeDir :: Text
    , hostname :: Text
    , uid :: Integer
    }

-- Note: check the nix code that generates plan.json
-- (modules/entrypoints/provider/plan.nix)
-- The name key is always == userName. So, it's okay to use
-- userName here as the environment name/identifier.
toNamed :: [EnvInfo] -> [(Text, EnvInfo)]
toNamed = map (\e -> (e.userName, e))

instance A.FromJSON EnvInfo where
    parseJSON = A.withObject "EnvInfo" $ \o -> do
        hostenvObj <- o .: "hostenv"
        userName <- hostenvObj .: "userName"
        runtimeDir <- hostenvObj .: "runtimeDir"
        hostname <- hostenvObj .: "hostname"
        node <- o .: "node"
        migrateBackups <- o .:? "migrations" .!= []
        uid <- o .: "uid"
        pure $
            EnvInfo
                { userName = userName
                , node = node
                , migrateBackups = migrateBackups
                , runtimeDir = runtimeDir
                , hostname = hostname
                , uid = uid
                }

data Snapshot = Snapshot {snapId :: Text}

instance A.FromJSON Snapshot where
    parseJSON = A.withObject "Snapshot" $ \v -> Snapshot <$> v .: "id"

parseSnapshotId :: Text -> Maybe Text
parseSnapshotId out =
    case A.eitherDecode' (BL.fromStrict (TE.encodeUtf8 out)) of
        Right (snaps :: [Snapshot]) ->
            case snaps of
                (s : _) -> Just s.snapId
                _ -> Nothing
        Left _ -> Nothing

parseSnapshotIdFromJournal :: Text -> Maybe Text
parseSnapshotIdFromJournal out =
    let parseLine line =
            let ws = T.words line
             in case dropWhile (/= "snapshot") ws of
                    ("snapshot" : snap : rest)
                        | "saved" `elem` rest ->
                            let snapId = T.takeWhile isHexDigit snap
                             in if T.null snapId then Nothing else Just snapId
                    _ -> Nothing
     in listToMaybe (mapMaybe parseLine (reverse (T.lines out)))

parseMigrationSource :: Text -> Maybe (Text, Text)
parseMigrationSource raw =
    let (envName, rest) = T.breakOn "=" raw
        nodeName = T.drop 1 rest
     in if T.null envName || T.null rest || T.null nodeName
            then Nothing
            else Just (envName, nodeName)

duplicateValues :: [Text] -> [Text]
duplicateValues =
    S.toList . snd . foldl step (S.empty, S.empty)
  where
    step (seen, dups) value =
        if S.member value seen
            then (seen, S.insert value dups)
            else (S.insert value seen, dups)

-- -------- Cloudflare helpers --------
data CFRecord = CFRecord
    { id :: Text
    , rType :: Text
    , name :: Text
    , content :: Text
    , proxied :: Maybe Bool
    }

instance A.FromJSON CFRecord where
    parseJSON = A.withObject "CFRecord" $ \v ->
        CFRecord
            <$> v .: "id"
            <*> v .: "type"
            <*> v .: "name"
            <*> v .: "content"
            <*> v .:? "proxied"

data CFList = CFList {lSuccess :: Bool, lResult :: [CFRecord]}
instance A.FromJSON CFList where
    parseJSON = A.withObject "CFList" $ \v ->
        CFList
            <$> v .: "success"
            <*> v .: "result"

data CFError = CFError
    { cfErrorCode :: Maybe Int
    , cfErrorMessage :: Text
    }

instance A.FromJSON CFError where
    parseJSON = A.withObject "CFError" $ \v ->
        CFError
            <$> v .:? "code"
            <*> v .:? "message" .!= "unknown error"

data CFWrite = CFWrite
    { wSuccess :: Bool
    , wErrors :: [CFError]
    }

instance A.FromJSON CFWrite where
    parseJSON = A.withObject "CFWrite" $ \v ->
        CFWrite
            <$> v .: "success"
            <*> v .:? "errors" .!= []

formatCFError :: CFError -> Text
formatCFError cfErr =
    case cfErr.cfErrorCode of
        Just code -> "[" <> T.pack (show code) <> "] " <> cfErr.cfErrorMessage
        Nothing -> cfErr.cfErrorMessage

cfWriteFailureReason :: CFWrite -> Text
cfWriteFailureReason resp =
    if null resp.wErrors
        then "Cloudflare API reported success=false with no error details"
        else "Cloudflare API reported success=false: " <> T.intercalate "; " (map formatCFError resp.wErrors)

data CFZoneInfo = CFZoneInfo {zName :: Text}
instance A.FromJSON CFZoneInfo where
    parseJSON = A.withObject "CFZoneInfo" $ \v ->
        CFZoneInfo <$> v .: "name"

data CFZoneResp = CFZoneResp {zSuccess :: Bool, zResult :: CFZoneInfo}
instance A.FromJSON CFZoneResp where
    parseJSON = A.withObject "CFZoneResp" $ \v ->
        CFZoneResp
            <$> v .: "success"
            <*> v .: "result"

cfListByName :: Text -> Text -> Text -> IO [CFRecord]
cfListByName token zoneId name = do
    let url = "https://api.cloudflare.com/client/v4/zones/" <> zoneId <> "/dns_records?per_page=1000&name=" <> name
    out <-
        Sh.strict $
            Sh.inproc
                "curl"
                [ "-sS"
                , "-H"
                , "Authorization: Bearer " <> token
                , "-H"
                , "Content-Type: application/json"
                , url
                ]
                Sh.empty
    let bs = BL.fromStrict (TE.encodeUtf8 out)
    case A.eitherDecode' bs of
        Left _ -> pure []
        Right (lst :: CFList) -> if lst.lSuccess then pure lst.lResult else pure []

cfWriteCall :: [String] -> IO (Either Text ())
cfWriteCall curlArgs = do
    (code, out, err) <- readProcessWithExitCode "curl" curlArgs ""
    case code of
        ExitFailure c ->
            pure (Left ("curl failed with exit " <> T.pack (show c) <> ": " <> T.pack err))
        ExitSuccess ->
            let outBs = BL.fromStrict (TE.encodeUtf8 (T.pack out))
             in case A.eitherDecode' outBs of
                    Left decodeErr ->
                        pure (Left ("invalid Cloudflare response: " <> T.pack decodeErr))
                    Right (resp :: CFWrite) ->
                        if resp.wSuccess
                            then pure (Right ())
                            else pure (Left (cfWriteFailureReason resp))

cfDeleteRecord :: Text -> Text -> Text -> IO (Either Text ())
cfDeleteRecord token zoneId rid = do
    let url = "https://api.cloudflare.com/client/v4/zones/" <> zoneId <> "/dns_records/" <> rid
    let curlArgs =
            [ "-sS"
            , "-X"
            , "DELETE"
            , "-H"
            , "Authorization: Bearer " <> T.unpack token
            , "-H"
            , "Content-Type: application/json"
            , T.unpack url
            ]
    cfWriteCall curlArgs

cfUpsertCname :: Text -> Text -> Text -> Text -> IO (Either Text ())
cfUpsertCname token zoneId name target = do
    existingRes <- try (cfListByName token zoneId name) :: IO (Either SomeException [CFRecord])
    existing <- case existingRes of
        Left err ->
            pure (Left ("failed to list existing DNS records: " <> T.pack (displayException err)))
        Right rows ->
            pure (Right rows)
    case existing of
        Left err -> pure (Left err)
        Right rows -> do
            let isConflictType rec = rec.rType `elem` ["A", "AAAA", "CNAME"]
            let conflicts = filter isConflictType rows
            let mAnchor =
                    case filter ((== "CNAME") . (.rType)) conflicts of
                        (c : _) -> Just c
                        [] ->
                            case conflicts of
                                (rec : _) -> Just rec
                                [] -> Nothing
            let staleConflicts =
                    case mAnchor of
                        Just anchor -> filter (\rec -> rec.id /= anchor.id) conflicts
                        Nothing -> []
            deleteResult <- foldlM deleteConflict (Right ()) staleConflicts
            case deleteResult of
                Left err ->
                    pure (Left err)
                Right () -> do
                    let (method, url) =
                            case mAnchor of
                                Just anchor ->
                                    ("PUT", "https://api.cloudflare.com/client/v4/zones/" <> zoneId <> "/dns_records/" <> anchor.id)
                                Nothing ->
                                    ("POST", "https://api.cloudflare.com/client/v4/zones/" <> zoneId <> "/dns_records")
                    let body = "{\"type\":\"CNAME\",\"name\":\"" <> name <> "\",\"content\":\"" <> target <> "\",\"proxied\":false}"
                    let curlArgs =
                            [ "-sS"
                            , "-X"
                            , T.unpack method
                            , "-H"
                            , "Authorization: Bearer " <> T.unpack token
                            , "-H"
                            , "Content-Type: application/json"
                            , "--data"
                            , T.unpack body
                            , T.unpack url
                            ]
                    cfWriteCall curlArgs
  where
    foldlM f z [] = pure z
    foldlM f z (x : xs) = f z x >>= \z' -> foldlM f z' xs
    deleteConflict acc rec =
        case acc of
            Left err -> pure (Left err)
            Right () -> do
                deleteResp <- cfDeleteRecord token zoneId rec.id
                case deleteResp of
                    Left err ->
                        pure
                            ( Left
                                ( "failed to delete conflicting "
                                    <> rec.rType
                                    <> " record (id "
                                    <> rec.id
                                    <> ") before CNAME upsert: "
                                    <> err
                                )
                            )
                    Right () -> pure (Right ())

cfZoneName :: Text -> Text -> IO (Maybe Text)
cfZoneName token zoneId = do
    let url = "https://api.cloudflare.com/client/v4/zones/" <> zoneId
    out <-
        Sh.strict $
            Sh.inproc
                "curl"
                [ "-sS"
                , "-H"
                , "Authorization: Bearer " <> token
                , "-H"
                , "Content-Type: application/json"
                , url
                ]
                Sh.empty
    let bs = BL.fromStrict (TE.encodeUtf8 out)
    case A.eitherDecode' bs of
        Left _ -> pure Nothing
        Right (resp :: CFZoneResp) ->
            if resp.zSuccess
                then pure (Just resp.zResult.zName)
                else pure Nothing

isSubdomainOf :: Text -> Text -> Bool
isSubdomainOf host zone =
    let host' = Dns.normalizeName host
        zone' = Dns.normalizeName zone
     in host' == zone' || T.isSuffixOf ("." <> zone') host'

type DnsKey = (Text, Text)

data DnsUpsertEligibility = UpsertEligible | UpsertIneligible Text

dnsKey :: DnsItem -> DnsKey
dnsKey item = (item.diDiscoveryHost, item.diExpectedHost)

uniqueDnsItems :: [DnsItem] -> [DnsItem]
uniqueDnsItems =
    reverse . fst . foldl step ([], S.empty)
  where
    step (acc, seen) item =
        let key = dnsKey item
         in if S.member key seen
                then (acc, seen)
                else (item : acc, S.insert key seen)

classifyUpsertEligibility :: Maybe Text -> Maybe Text -> Maybe Text -> Text -> DnsUpsertEligibility
classifyUpsertEligibility mToken mZoneId mZoneName vhName
    | isNothing mToken = UpsertIneligible "Cloudflare token was not provided"
    | isNothing mZoneId = UpsertIneligible "Cloudflare zone was not provided"
    | isNothing mZoneName = UpsertIneligible "could not determine the Cloudflare zone name"
    | otherwise =
        case mZoneName of
            Just zoneName ->
                if isSubdomainOf vhName zoneName
                    then UpsertEligible
                    else UpsertIneligible ("host is outside Cloudflare zone " <> zoneName)
            Nothing -> UpsertIneligible "could not determine the Cloudflare zone name"

waitForDnsPropagationBy ::
    IO (DnsItem -> IO (Either Dns.DnsLookupFailure Bool)) ->
    [DnsItem] ->
    IO (Either Dns.DnsLookupFailure (S.Set DnsKey, [DnsItem]))
waitForDnsPropagationBy newPhaseCheck items =
    -- Propagation can wait for a known mismatch, but an indeterminate lookup
    -- is different: return its typed cause immediately. Callers can safely
    -- abort and retry without pretending the DNS state was observed.
    partitionByDns items >>= \case
        Left err -> pure (Left err)
        Right (resolved0, unresolved0) ->
            go resolved0 unresolved0 (backoffDelays 1 30 600)
  where
    partitionByDns recs = do
        pointsToExpected <- newPhaseCheck
        checks <- forM recs $ \item -> do
            result <- pointsToExpected item
            pure (item, result)
        case [err | (_, Left err) <- checks] of
            err : _ -> pure (Left err)
            [] ->
                pure
                    ( Right
                        ( [ item
                          | (item, Right True) <- checks
                          ]
                        , [ item
                          | (item, Right False) <- checks
                          ]
                        )
                    )
    go resolved [] _ =
        pure (Right (S.fromList (map dnsKey resolved), []))
    go resolved unresolved [] =
        pure (Right (S.fromList (map dnsKey resolved), unresolved))
    go resolved unresolved (delaySec : restDelays) = do
        printProviderLine
            ( "Waiting "
                <> T.pack (show delaySec)
                <> "s before rechecking DNS propagation; unresolved hostnames: "
                <> T.pack (show (length unresolved))
            )
        threadDelay (delaySec * 1000000)
        partitionByDns unresolved >>= \case
            Left err -> pure (Left err)
            Right (resolvedNow, unresolvedNow) ->
                go (resolved <> resolvedNow) unresolvedNow restDelays

waitForAuthoritativeDnsPropagation ::
    Dns.LookupCache ->
    [DnsItem] ->
    IO (Either Dns.DnsLookupFailure (S.Set DnsKey, [DnsItem]))
waitForAuthoritativeDnsPropagation dnsCache =
    waitForDnsPropagationBy $
        pure $ \item ->
            Dns.checkAuthoritativeTarget dnsCache item.diDiscoveryHost item.diExpectedHost

loadPlanCloudflareContext ::
    Maybe Text ->
    Maybe Text ->
    KM.KeyMap A.Value ->
    IO (Maybe Text, Maybe Text, Maybe Text)
loadPlanCloudflareContext mTokenOverride mZoneOverride plan = do
    let cfPlan = lookupObj (K.fromString "cloudflare") plan
    mToken <-
        case mTokenOverride of
            Just token -> pure (Just token)
            Nothing ->
                case cfPlan >>= lookupText (K.fromString "apiTokenFile") of
                    Just path -> Just . T.strip . T.pack <$> readFile (T.unpack path)
                    Nothing -> fmap T.pack <$> Env.lookupEnv "CF_API_TOKEN"
    mZone <-
        case mZoneOverride of
            Just zoneId -> pure (Just zoneId)
            Nothing ->
                case cfPlan >>= lookupText (K.fromString "zoneId") of
                    Just zoneId -> pure (Just zoneId)
                    Nothing -> fmap T.pack <$> Env.lookupEnv "CF_ZONE_ID"
    mZoneName <-
        case (mToken, mZone) of
            (Just token, Just zoneId) -> cfZoneName token zoneId
            _ -> pure Nothing
    pure (mToken, mZone, mZoneName)

environmentDnsItems :: Text -> KM.KeyMap A.Value -> EnvInfo -> [DnsItem]
environmentDnsItems hostenvHostname envs envInfo =
    case KM.lookup (K.fromText envInfo.userName) envs of
        Nothing -> []
        Just envValue ->
            uniqueDnsItems $
                collectDnsItems
                    hostenvHostname
                    (KM.singleton (K.fromText envInfo.userName) envValue)

checkDnsItems ::
    Dns.LookupCache ->
    Dns.ObservationCache (Either Dns.DnsLookupFailure [Text]) ->
    [DnsItem] ->
    IO [(DnsItem, Either Dns.DnsLookupFailure Bool)]
checkDnsItems dnsCache observationCache items =
    forM items $ \item -> do
        pointsToDestination <-
            Dns.pointsToObservedHost
                dnsCache
                observationCache
                item.diDiscoveryHost
                item.diExpectedHost
        pure (item, pointsToDestination)

ensureEnvironmentDns ::
    Dns.LookupCache ->
    Maybe Text ->
    Maybe Text ->
    KM.KeyMap A.Value ->
    EnvInfo ->
    [DnsItem] ->
    IO (Either Text ())
ensureEnvironmentDns dnsCache mTokenOverride mZoneOverride plan envInfo items = do
    observationCache <- Dns.newObservationCache
    checks <- checkDnsItems dnsCache observationCache items
    let pending =
            [ (item, lookupFailure)
            | (item, result) <- checks
            , lookupFailure <-
                case result of
                    Right True -> []
                    Right False -> [Nothing]
                    Left err -> [Just err]
            ]
    if null pending
        then do
            when (not (null items)) $
                printProviderLine
                    ( "DNS already points to "
                        <> envInfo.node
                        <> " for "
                        <> envInfo.userName
                    )
            pure (Right ())
        else do
            cloudflareContext <- tryAny (loadPlanCloudflareContext mTokenOverride mZoneOverride plan)
            case cloudflareContext of
                Left err ->
                    pure
                        ( Left
                            ( "automatic DNS update could not be prepared: "
                                <> T.pack (displayException err)
                            )
                        )
                Right (mToken, mZone, mZoneName) -> do
                    upsertResults <-
                        forM pending $ \(item, lookupFailure) ->
                            case classifyUpsertEligibility mToken mZone mZoneName item.diDiscoveryHost of
                                UpsertIneligible reason ->
                                    pure
                                        ( Left
                                            ( case lookupFailure of
                                                Nothing ->
                                                    item.diDiscoveryHost
                                                        <> " must point to "
                                                        <> item.diExpectedHost
                                                        <> " (automatic DNS update unavailable: "
                                                        <> reason
                                                        <> ")"
                                                Just dnsFailure ->
                                                    "could not verify DNS for "
                                                        <> item.diDiscoveryHost
                                                        <> ": "
                                                        <> Dns.renderLookupFailure dnsFailure
                                                        <> " (automatic DNS update unavailable: "
                                                        <> reason
                                                        <> ")"
                                            )
                                        )
                                UpsertEligible ->
                                    case (mToken, mZone) of
                                        (Just token, Just zoneId) -> do
                                            forM_ lookupFailure $ \dnsFailure ->
                                                printProviderErrLine
                                                    ( "Warning: could not verify current DNS for "
                                                        <> item.diDiscoveryHost
                                                        <> " ("
                                                        <> Dns.renderLookupFailure dnsFailure
                                                        <> "); attempting the configured Cloudflare update"
                                                    )
                                            printProviderLine
                                                ( "Updating DNS "
                                                    <> item.diDiscoveryHost
                                                    <> " -> "
                                                    <> item.diExpectedHost
                                                )
                                            result <- cfUpsertCname token zoneId item.diDiscoveryHost item.diExpectedHost
                                            pure $
                                                case result of
                                                    Right () -> Right item
                                                    Left err ->
                                                        Left
                                                            ( "Cloudflare update failed for "
                                                                <> item.diDiscoveryHost
                                                                <> ": "
                                                                <> err
                                                            )
                                        _ ->
                                            pure
                                                ( Left
                                                    ( item.diDiscoveryHost
                                                        <> " must point to "
                                                        <> item.diExpectedHost
                                                        <> " (Cloudflare credentials are missing)"
                                                    )
                                                )
                    let failures = [err | Left err <- upsertResults]
                    if not (null failures)
                        then pure (Left (T.intercalate "; " failures))
                        else do
                            let updatedItems = [item | Right item <- upsertResults]
                            printProviderLine
                                ( "Waiting for DNS propagation for "
                                    <> envInfo.userName
                                )
                            waitForAuthoritativeDnsPropagation dnsCache updatedItems >>= \case
                                Left err ->
                                    pure
                                        ( Left
                                            ( "DNS propagation could not be verified: "
                                                <> Dns.renderLookupFailure err
                                            )
                                        )
                                Right (_, timedOutItems) ->
                                    if null timedOutItems
                                        then pure (Right ())
                                        else
                                            pure
                                                ( Left
                                                    ( "DNS did not propagate to the destination for: "
                                                        <> T.intercalate
                                                            ", "
                                                            [ item.diDiscoveryHost <> " -> " <> item.diExpectedHost
                                                            | item <- timedOutItems
                                                            ]
                                                    )
                                                )

-- -------- Plan --------
runPlan :: Bool -> IO ()
runPlan dryRun = do
    let dest = "generated" :: Text
    let planDest = dest <> "/plan.json"
    let stateDest = dest <> "/state.json"
    let flakeDest = dest <> "/flake.nix"

    unless dryRun $ do
        Sh.mktree (fromString (T.unpack dest))
        previousPlanExists <- Dir.doesFileExist (T.unpack planDest)
        stateExists <- Sh.testfile (fromString (T.unpack stateDest))
        when (previousPlanExists && not stateExists) $
            error
                ( ""
                    <> T.unpack stateDest
                    <> " is missing while "
                    <> T.unpack planDest
                    <> " already exists. Restore " <> T.unpack stateDest <> " from version control before running plan"
                )
        unless stateExists $ do
            BLC.writeFile (T.unpack stateDest) "{}\n"
            _ <- Sh.procs "git" ["add", stateDest] Sh.empty
            pure ()

    system <- nixEvalRaw ["eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]
    let planAttrBase = ".#lib.provider.planPaths." <> T.strip system
    planSource <- nixBuildPath (planAttrBase <> ".plan")

    planRaw <- BL.readFile (T.unpack planSource)
    planPretty <- prettyJson planRaw
    if dryRun
        then do
            PlanTransition.validatePlanTransition planTransitionOps planDest stateDest planPretty
            _ <- printDiffAgainstFile planDest planPretty
            printProviderLine "Dry run: generated/plan.json was not modified"
        else
            withSameDirectoryTempFile planDest planPretty $ \candidatePlanPath -> do
                candidatePlanRaw <- BL.readFile candidatePlanPath
                PlanTransition.validatePlanTransition planTransitionOps planDest stateDest candidatePlanRaw

                stateSource <- nixBuildPath (planAttrBase <> ".state")
                flakeSource <- nixBuildPath (planAttrBase <> ".flake")

                stateRaw <- BL.readFile (T.unpack stateSource)
                BL.writeFile (T.unpack stateDest) stateRaw

                flakeRaw <- BL.readFile (T.unpack flakeSource)
                BL.writeFile (T.unpack flakeDest) flakeRaw

                -- Publish the validated plan last. candidatePlanPath lives in
                -- generated/, so POSIX rename replaces plan.json atomically.
                Dir.renameFile candidatePlanPath (T.unpack planDest)

                _ <- Sh.procs "git" ["add", dest] Sh.empty
                _ <- Sh.procs "nix" (nixCommonArgs ++ ["flake", "update", "--flake", "./" <> dest]) Sh.empty
                _ <- Sh.procs "git" ["add", dest] Sh.empty
                BLC.putStrLn ("✅ Infrastructure configuration written to " <> BLC.pack (T.unpack dest))
  where
    nixCommonArgs :: [Text]
    nixCommonArgs = ["--extra-experimental-features", "nix-command flakes"]

    nixEvalRaw :: [Text] -> IO Text
    nixEvalRaw args = T.strip <$> Sh.strict (Sh.inproc "nix" (nixCommonArgs ++ args) Sh.empty)

    nixBuildPath :: Text -> IO Text
    nixBuildPath attr =
        T.strip <$> Sh.strict (Sh.inproc "nix" (nixCommonArgs ++ ["build", "--no-link", "--print-out-paths", attr]) Sh.empty)


-- -------- Deploy wrapper --------
shellEscape :: Text -> Text
shellEscape t =
    if T.null t
        then "''"
        else "'" <> T.replace "'" "'\\''" t <> "'"

pickTag :: Text -> Text -> Text
pickTag base body =
    let go n =
            let tag =
                    if n == 0
                        then base
                        else base <> "_" <> T.pack (show n)
             in if T.isInfixOf tag body then go (n + 1) else tag
     in go 0

heredocSubst :: Text -> Text -> Text
heredocSubst tag body =
    let body' = if T.isSuffixOf "\n" body then body else body <> "\n"
     in "\"$(cat <<'" <> tag <> "'\n" <> body' <> tag <> "\n)\""

bashLcCommand :: Text -> Text
bashLcCommand cmd =
    let tag = pickTag "HOSTENV_CMD" cmd
     in "bash -lc " <> heredocSubst tag cmd

sudoBashLcCommand :: Text -> Text -> Text
sudoBashLcCommand user cmd =
    "sudo -u " <> shellEscape user <> " -H -- " <> bashLcCommand cmd

scriptForArgs :: [Text] -> Text
scriptForArgs args =
    let header = "#!/usr/bin/env bash\nset -euo pipefail\n"
     in case args of
            ["bash", "-lc", cmd] ->
                header <> bashLcCommand cmd <> "\n"
            ["sudo", "-u", user, "-H", "--", "bash", "-lc", cmd] ->
                header <> sudoBashLcCommand user cmd <> "\n"
            _ ->
                header <> "exec " <> T.intercalate " " (map shellEscape args) <> "\n"

data SshTarget = SshTarget
    { targetUserHost :: Text
    , targetHost :: Text
    , targetSshOpts :: [Text]
    }

mkSshTarget :: Text -> NodeConnection -> SshTarget
mkSshTarget user conn =
    SshTarget
        { targetUserHost = user <> "@" <> conn.hostname
        , targetHost = conn.hostname
        , targetSshOpts = conn.sshOpts
        }

runRemoteScript :: SshTarget -> Text -> IO ExitCode
runRemoteScript target script = do
    let runner =
            "tmp=$(mktemp /tmp/hostenv-provider-XXXXXX.sh); "
                <> "cat > \"$tmp\"; "
                <> "bash \"$tmp\"; "
                <> "status=$?; "
                <> "rm -f \"$tmp\"; "
                <> "exit $status"
    let sshArgs = ["-o", "BatchMode=yes"] ++ target.targetSshOpts ++ [target.targetUserHost, runner]
    (code, _out, _err) <- readProcessWithExitCode "ssh" (map T.unpack sshArgs) (T.unpack script)
    pure code

runRemoteScriptOutput :: SshTarget -> Text -> IO (ExitCode, Text, Text)
runRemoteScriptOutput target script = do
    let runner =
            "tmp=$(mktemp /tmp/hostenv-provider-XXXXXX.sh); "
                <> "cat > \"$tmp\"; "
                <> "bash \"$tmp\"; "
                <> "status=$?; "
                <> "rm -f \"$tmp\"; "
                <> "exit $status"
    let sshArgs = ["-o", "BatchMode=yes"] ++ target.targetSshOpts ++ [target.targetUserHost, runner]
    (code, out, err) <- readProcessWithExitCode "ssh" (map T.unpack sshArgs) (T.unpack script)
    pure (code, T.pack out, T.pack err)

runRemoteScriptStrict :: SshTarget -> Text -> IO Text
runRemoteScriptStrict target script = do
    let runner =
            "tmp=$(mktemp /tmp/hostenv-provider-XXXXXX.sh); "
                <> "cat > \"$tmp\"; "
                <> "bash \"$tmp\"; "
                <> "status=$?; "
                <> "rm -f \"$tmp\"; "
                <> "exit $status"
    let sshArgs = ["-o", "BatchMode=yes"] ++ target.targetSshOpts ++ [target.targetUserHost, runner]
    (code, out, err) <- readProcessWithExitCode "ssh" (map T.unpack sshArgs) (T.unpack script)
    case code of
        ExitSuccess -> pure (T.pack out)
        ExitFailure c ->
            error
                ( "ssh failed for "
                    <> T.unpack target.targetUserHost
                    <> " (exit "
                    <> show c
                    <> "): "
                    <> err
                )

runRemote :: SshTarget -> [Text] -> IO ExitCode
runRemote target args =
    runRemoteScript target (scriptForArgs args)

runRemoteStrict :: SshTarget -> [Text] -> IO Text
runRemoteStrict target args =
    runRemoteScriptStrict target (scriptForArgs args)

runRemoteOutput :: SshTarget -> [Text] -> IO (ExitCode, Text, Text)
runRemoteOutput target args =
    runRemoteScriptOutput target (scriptForArgs args)

mkUserLifecycleOps :: Text -> (Text -> NodeConnection) -> UserLifecycle.Ops
mkUserLifecycleOps deployUser resolveNodeConnection =
    UserLifecycle.Ops
        { runRemote = \nodeName args ->
            runRemote (mkSshTarget deployUser (resolveNodeConnection nodeName)) args
        , runRemoteOutput = \nodeName args ->
            runRemoteOutput (mkSshTarget deployUser (resolveNodeConnection nodeName)) args
        , runRemoteScriptOutput = \nodeName script ->
            runRemoteScriptOutput (mkSshTarget deployUser (resolveNodeConnection nodeName)) script
        , runRemoteStrict = \nodeName args ->
            runRemoteStrict (mkSshTarget deployUser (resolveNodeConnection nodeName)) args
        , printLine = printProviderLine
        , printErrLine = printProviderErrLine
        }

planTransitionOps :: PlanTransition.Ops
planTransitionOps =
    PlanTransition.Ops
        { makeUserLifecycleOps = mkUserLifecycleOps
        , printLine = printProviderErrLine
        }

data SigningKeyInfo = SigningKeyInfo
    { secretKeyPath :: Text
    , publicKeyPath :: Text
    , publicKey :: Text
    , wasGenerated :: Bool
    }

defaultSigningKeyPath :: Text
defaultSigningKeyPath = "secrets/signing/secret.key"

resolveSigningKeyPath :: Maybe Text -> IO Text
resolveSigningKeyPath mArg = do
    envPath <- Env.lookupEnv "HOSTENV_SIGNING_KEY_FILE"
    pure $
        fromMaybe
            defaultSigningKeyPath
            (mArg <|> (T.pack <$> envPath))

sanitizeKeyName :: Text -> Text
sanitizeKeyName =
    T.map (\c -> if isAlphaNum c || c `elem` ['.', '-', '_'] then c else '-')

signingKeyNameFor :: Text -> Text
signingKeyNameFor hostenvHostname =
    let normalized = sanitizeKeyName (T.toLower (T.strip hostenvHostname))
     in if T.null normalized
            then "hostenv-provider-1"
            else normalized <> "-hostenv-provider-1"

localCommandFailure :: Text -> [Text] -> ExitCode -> Text -> Text -> Text
localCommandFailure context args code out err =
    let out' = T.strip out
        err' = T.strip err
        detail =
            if T.null err'
                then out'
                else err'
     in context
            <> ": "
            <> T.unwords (map shellEscape args)
            <> " (exit "
            <> T.pack (show code)
            <> ")"
            <> if T.null detail then "" else " - " <> detail

convertSecretToPublic :: Text -> IO Text
convertSecretToPublic secret = do
    (code, out, err) <- readProcessWithExitCode "nix" ["key", "convert-secret-to-public"] (T.unpack secret <> "\n")
    case code of
        ExitSuccess ->
            let pub = T.strip (T.pack out)
             in if T.null pub
                    then error "Could not derive the public signing key because Nix returned no output"
                    else pure pub
        ExitFailure _ ->
            error (T.unpack (localCommandFailure "Could not derive the public signing key" ["nix", "key", "convert-secret-to-public"] code (T.pack out) (T.pack err)))

chmodPath :: Text -> Text -> IO ()
chmodPath mode path = do
    (code, out, err) <- readProcessWithExitCode "chmod" [T.unpack mode, T.unpack path] ""
    case code of
        ExitSuccess -> pure ()
        ExitFailure _ ->
            error (T.unpack (localCommandFailure "Could not set file permissions" ["chmod", mode, path] code (T.pack out) (T.pack err)))

ensureSigningKeyInfo :: Text -> Maybe Text -> IO SigningKeyInfo
ensureSigningKeyInfo hostenvHostname mKeyPath = do
    keyPath <- resolveSigningKeyPath mKeyPath
    let keyPathS = T.unpack keyPath
    let keyDirS = FP.takeDirectory keyPathS
    let pubPathS = keyDirS FP.</> "public.key"
    let pubPath = T.pack pubPathS
    keyExists <- Dir.doesFileExist keyPathS
    if keyExists
        then do
            secret <- T.strip . T.pack <$> readFile keyPathS
            when (T.null secret) $
                error ("Signing key exists but is empty: " <> keyPathS)
            pub <- convertSecretToPublic secret
            Dir.createDirectoryIfMissing True keyDirS
            sidecarRes <- try (writeFile pubPathS (T.unpack pub <> "\n") >> chmodPath "0644" pubPath) :: IO (Either SomeException ())
            case sidecarRes of
                Left err ->
                    printProviderErrLine ("Warning: could not update the public key file at " <> pubPath <> ": " <> T.pack (displayException err))
                Right _ -> pure ()
            pure
                SigningKeyInfo
                    { secretKeyPath = keyPath
                    , publicKeyPath = pubPath
                    , publicKey = pub
                    , wasGenerated = False
                    }
        else do
            Dir.createDirectoryIfMissing True keyDirS
            when (keyDirS /= "." && keyDirS /= "") $
                chmodPath "0700" (T.pack keyDirS)
            let keyName = signingKeyNameFor hostenvHostname
            let generateArgs = ["key", "generate-secret", "--key-name", keyName]
            (genCode, genOut, genErr) <- readProcessWithExitCode "nix" (map T.unpack generateArgs) ""
            case genCode of
                ExitFailure _ ->
                    error (T.unpack (localCommandFailure "Could not generate the signing key" ("nix" : generateArgs) genCode (T.pack genOut) (T.pack genErr)))
                ExitSuccess -> do
                    let secret = T.strip (T.pack genOut)
                    when (T.null secret) $
                        error "Generated signing key is empty"
                    writeFile keyPathS (T.unpack secret <> "\n")
                    chmodPath "0600" keyPath
                    pub <- convertSecretToPublic secret
                    writeFile pubPathS (T.unpack pub <> "\n")
                    chmodPath "0644" pubPath
                    pure
                        SigningKeyInfo
                            { secretKeyPath = keyPath
                            , publicKeyPath = pubPath
                            , publicKey = pub
                            , wasGenerated = True
                            }

signInstallable :: SigningKeyInfo -> Text -> Text -> IO ExitCode
signInstallable keyInfo installable target = do
    let evalArgs =
            [ "eval"
            , "--raw"
            , installable
            ]
    (evalCode, evalOut, evalErr) <- readProcessWithExitCode "nix" (map T.unpack evalArgs) ""
    case evalCode of
        ExitFailure _ -> do
            printProviderErrLine (localCommandFailure "Could not evaluate the deployment target for signing" ("nix" : evalArgs) evalCode (T.pack evalOut) (T.pack evalErr))
            pure (ExitFailure 1)
        ExitSuccess -> do
            let outputPath = T.strip (T.pack evalOut)
            if T.null outputPath
                then do
                    printProviderErrLine ("Nix produced no output path for " <> target)
                    pure (ExitFailure 1)
                else do
                    let buildArgs =
                            [ "build"
                            , "--no-link"
                            , "--print-build-logs"
                            , "--print-out-paths"
                            , installable
                            ]
                    printProviderLine ("Running nix " <> T.unwords buildArgs)
                    buildCode <- Sh.proc "nix" buildArgs Sh.empty
                    case buildCode of
                        ExitFailure code -> do
                            printProviderErrLine ("Could not realise deployment target for signing " <> target <> " (exit " <> T.pack (show code) <> ")")
                            pure (ExitFailure 1)
                        ExitSuccess -> do
                            let args =
                                    [ "store"
                                    , "sign"
                                    , "-r"
                                    , "-k"
                                    , keyInfo.secretKeyPath
                                    , outputPath
                                    ]
                            printProviderLine ("Signing " <> target)
                            Sh.proc "nix" args Sh.empty

printProviderLine :: Text -> IO ()
printProviderLine line =
    BLC.putStrLn (BLC.pack (T.unpack line))

printProviderErrLine :: Text -> IO ()
printProviderErrLine line =
    BLC.hPutStrLn stderr (BLC.pack (T.unpack line))

sentenceCase :: Text -> Text
sentenceCase value =
    case T.uncons value of
        Nothing -> value
        Just (first, rest) -> T.cons (toUpper first) rest

printProviderLines :: [Text] -> IO ()
printProviderLines =
    mapM_ printProviderErrLine

printRemediationBlock :: [Text] -> IO ()
printRemediationBlock =
    mapM_ (printProviderErrLine . ("  " <>))

detectFlakeKeyStatus :: Text -> IO FlakeKeyStatus
detectFlakeKeyStatus key = do
    let flakePath = "flake.nix"
    flakeExists <- Dir.doesFileExist flakePath
    if not flakeExists
        then pure (FlakeKeyUnknown "flake.nix not found in current working directory")
        else do
            flakeRead <- try (readFile flakePath) :: IO (Either SomeException String)
            pure $ case flakeRead of
                Left err ->
                    FlakeKeyUnknown (T.pack (displayException err))
                Right contents ->
                    if key `T.isInfixOf` T.pack contents
                        then FlakeKeyPresent
                        else FlakeKeyMissing

planTrustedPublicKeys :: KM.KeyMap A.Value -> [Text]
planTrustedPublicKeys plan =
    case lookupObj (K.fromString "nixSigning") plan of
        Just signingObj -> lookupTextList (K.fromString "trustedPublicKeys") signingObj
        Nothing -> []

planNodeRemoteBuild :: KM.KeyMap A.Value -> KM.KeyMap A.Value
planNodeRemoteBuild plan =
    fromMaybe KM.empty (lookupObj (K.fromString "nodeRemoteBuild") plan)

dnsRemovedInventoryHint :: Text -> [Text] -> EnvInfo -> IO (Either Dns.DnsLookupFailure (Maybe Text))
dnsRemovedInventoryHint hostenvHostname inventoryNodes envInfo = do
    -- This lookup decides whether an apparently fresh environment may actually
    -- live on a node that was removed from provider inventory. A lookup failure
    -- is therefore indeterminate and must propagate to the caller; treating it
    -- like an empty CNAME answer could skip a required migration.
    cnameResult <- Dns.queryRecursiveRecord 1 envInfo.hostname "CNAME"
    pure $ do
        cnames <- cnameResult
        let domain = Dns.normalizeName hostenvHostname
        let suffix = "." <> domain
        let inventory = S.fromList (map Dns.normalizeName inventoryNodes)
        let nodeFromTarget target =
                let normalized = Dns.normalizeName target
                 in case T.stripSuffix suffix normalized of
                        Just nodeName
                            | not (T.null nodeName)
                            , not (S.member nodeName inventory) -> Just nodeName
                        _ -> Nothing
        pure (listToMaybe (mapMaybe nodeFromTarget cnames))

nodeUsesRemoteBuild :: KM.KeyMap A.Value -> Text -> Bool
nodeUsesRemoteBuild remoteBuildMap nodeName =
    fromMaybe False (lookupBool (K.fromText nodeName) remoteBuildMap)

runNodeDeployPreflight :: (Text -> NodeConnection) -> Text -> Text -> Bool -> Maybe Text -> IO (Maybe Preflight.PreflightFailure)
runNodeDeployPreflight resolveNodeConnection deployUser nodeName requiresTrustedKey signingPublicKey = do
    let target = mkSshTarget deployUser (resolveNodeConnection nodeName)
    Preflight.runPreflight
        Preflight.DeployPreflightConfig
            { nodeName = nodeName
            , deployUser = deployUser
            , requiresTrustedKey = requiresTrustedKey
            , signingPublicKey = signingPublicKey
            , runRemote = runRemoteOutput target
            }

runMigrationBackup :: Text -> (Text -> NodeConnection) -> EnvInfo -> Text -> Text -> IO Text
runMigrationBackup deployUser nodeConnection envInfo prevNode backupName = do
    let sourceTarget = mkSshTarget deployUser (nodeConnection prevNode)
    let sourceHost = sourceTarget.targetHost
    let sudoArgs cmd =
            [ "sudo"
            , "-u"
            , envInfo.userName
            , "-H"
            , "--"
            , "bash"
            , "-lc"
            , cmd
            ]
    let unitFor name = "restic-backups-" <> name <> ".service"
    let userBusPrefix = "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
    let loadStateCmd unit =
            userBusPrefix
                <> "systemctl --user show -p LoadState "
                <> unit
                <> " 2>/dev/null || echo \"LoadState=not-found\""
    let parseState t =
            let trimmed = T.strip t
             in fromMaybe trimmed (T.stripPrefix "LoadState=" trimmed)
    let chooseBackupName = do
            state <- fmap parseState (runRemoteStrict sourceTarget (sudoArgs (loadStateCmd (unitFor backupName))))
            if state == "loaded"
                then pure backupName
                else case T.stripSuffix "-migrate" backupName of
                    Just baseName -> do
                        baseState <- fmap parseState (runRemoteStrict sourceTarget (sudoArgs (loadStateCmd (unitFor baseName))))
                        if baseState == "loaded"
                            then do
                                printProviderLine
                                    ( "Migration backup unit "
                                        <> unitFor backupName
                                        <> " was not found on "
                                        <> sourceHost
                                        <> "; using "
                                        <> baseName
                                    )
                                pure baseName
                            else error ("Migration backup unit " <> T.unpack (unitFor backupName) <> " was not found, and fallback unit " <> T.unpack (unitFor baseName) <> " was also missing.")
                    Nothing -> error ("Migration backup unit was not found: " <> T.unpack (unitFor backupName))
    effectiveName <- chooseBackupName
    let unit = unitFor effectiveName
    let startCmd =
            "set -euo pipefail; "
                <> userBusPrefix
                <> "systemctl --user start --wait "
                <> unit
    startExit <- runRemote sourceTarget (sudoArgs startCmd)
    case startExit of
        ExitSuccess -> pure ()
        ExitFailure code -> error ("Migration backup failed for " <> T.unpack envInfo.userName <> ":" <> T.unpack backupName <> " (exit " <> show code <> ")")

    let wrapperPath = "~/.local/bin/restic-" <> effectiveName
    let wrapperCheckCmd = "test -x " <> wrapperPath
    wrapperExit <- runRemote sourceTarget (sudoArgs wrapperCheckCmd)
    if wrapperExit == ExitSuccess
        then do
            let snapshotCmdTagged =
                    "set -euo pipefail; "
                        <> wrapperPath
                        <> " snapshots --latest 1 --tag "
                        <> effectiveName
                        <> " --json"
            snapOutTagged <- runRemoteStrict sourceTarget (sudoArgs snapshotCmdTagged)
            case parseSnapshotId snapOutTagged of
                Just snap -> pure snap
                Nothing -> do
                    let snapshotCmdUntagged =
                            "set -euo pipefail; "
                                <> wrapperPath
                                <> " snapshots --latest 1 --json"
                    snapOutUntagged <- runRemoteStrict sourceTarget (sudoArgs snapshotCmdUntagged)
                    case parseSnapshotId snapOutUntagged of
                        Just snap -> do
                            printProviderErrLine
                                ( "Warning: no tagged Restic snapshot found for "
                                    <> effectiveName
                                    <> " on "
                                    <> sourceHost
                                    <> "; using latest untagged snapshot"
                                )
                            pure snap
                        Nothing -> error ("Could not find a snapshot ID for " <> T.unpack envInfo.userName <> ":" <> T.unpack backupName <> " (tagged or untagged).")
        else do
            printProviderLine ("Restic wrapper not found for " <> effectiveName <> " on " <> sourceHost <> "; reading the snapshot ID from the journal")
            let invocationCmd = userBusPrefix <> "systemctl --user show -p InvocationID --value " <> unit
            invOut <- runRemoteStrict sourceTarget (sudoArgs invocationCmd)
            let invocation = T.strip invOut
            let journalCmd =
                    userBusPrefix
                        <> if T.null invocation
                            then "journalctl --user -u " <> unit <> " -n 200 -o cat --no-pager || true"
                            else "journalctl --user _SYSTEMD_INVOCATION_ID=" <> invocation <> " -o cat --no-pager || true"
            logOut <- runRemoteStrict sourceTarget (sudoArgs journalCmd)
            case parseSnapshotIdFromJournal logOut of
                Just snap -> pure snap
                Nothing -> error ("Could not find a snapshot ID in the journal for " <> T.unpack envInfo.userName <> ":" <> T.unpack backupName <> ".")

clearRestorePlan :: Text -> (Text -> NodeConnection) -> EnvInfo -> IO ()
clearRestorePlan deployUser nodeConnection envInfo = do
    let target = mkSshTarget deployUser (nodeConnection envInfo.node)
    let restorePath = envInfo.runtimeDir <> "/restore/plan.json"
    let clearCmd =
            "if sudo test -f "
                <> shellEscape restorePath
                <> "; then sudo rm -f "
                <> shellEscape restorePath
                <> "; echo removed; else echo absent; fi"
    status <- T.strip <$> runRemoteStrict target ["bash", "-lc", clearCmd]
    case status of
        "removed" ->
            printProviderLine ("Removed pending restore plan for skipped environment " <> envInfo.userName)
        _ ->
            printProviderLine ("No pending restore plan for skipped environment " <> envInfo.userName)

writeRestorePlan :: Text -> (Text -> NodeConnection) -> EnvInfo -> Text -> [(Text, Text)] -> IO ()
writeRestorePlan deployUser nodeConnection envInfo prevNode snapshots = do
    let deployTarget = mkSshTarget deployUser (nodeConnection envInfo.node)
    let runtimeDir = envInfo.runtimeDir
    let restoreDir = runtimeDir <> "/restore"
    let restorePath = restoreDir <> "/plan.json"
    let ownerSpec = T.pack (show envInfo.uid)
    let runtimeGroup = "users"
    let groupSpec = ownerSpec
    let snapObj = KM.fromList (map (\(name, sid) -> (K.fromText name, A.String sid)) snapshots)
    let payload =
            A.object
                [ "sourceNode" .= prevNode
                , "snapshots" .= A.Object snapObj
                ]

    let dirCmd =
            let
                args :: (Monoid a) => a -> [a] -> a
                args x ys = x <> mconcat ys
             in
                T.intercalate
                    " && "
                    [ "sudo mkdir -p " <> runtimeDir
                    , "sudo chmod 2700 " <> runtimeDir
                    , "sudo chown " `args` [ownerSpec, ":", runtimeGroup, " ", runtimeDir]
                    , "sudo mkdir -p " <> restoreDir
                    , "sudo chmod 0700 " <> restoreDir
                    , "sudo chown " `args` [ownerSpec, ":", groupSpec, " ", restoreDir]
                    ]
    dirExit <-
        runRemote
            deployTarget
            [ "bash"
            , "-lc"
            , dirCmd
            ]
    case dirExit of
        ExitSuccess -> pure ()
        ExitFailure code -> error ("Could not create the restore directory on " <> T.unpack deployTarget.targetUserHost <> " (exit " <> show code <> ").")

    fileExit <- runRemote deployTarget ["bash", "-lc", "sudo install -m 0600 /dev/null " <> restorePath <> " && sudo chown " <> ownerSpec <> ":" <> groupSpec <> " " <> restorePath]
    case fileExit of
        ExitSuccess -> pure ()
        ExitFailure code -> error ("Could not create the restore-plan file on " <> T.unpack deployTarget.targetUserHost <> " (exit " <> show code <> ").")

    let payloadText = TE.decodeUtf8 (BL.toStrict (A.encode payload))
    let payloadTag = pickTag "HOSTENV_JSON" payloadText
    let writeCmd =
            T.unlines
                [ "sudo tee " <> shellEscape restorePath <> " >/dev/null <<'" <> payloadTag <> "'"
                , payloadText
                , payloadTag
                ]
    writeExit <- runRemote deployTarget ["bash", "-lc", writeCmd]
    case writeExit of
        ExitSuccess -> pure ()
        ExitFailure code -> error ("Could not write the restore plan for " <> T.unpack envInfo.userName <> " (exit " <> show code <> ").")

runDeploy :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Bool -> Bool -> [Text] -> [Text] -> Bool -> Bool -> IO ()
runDeploy mNode mCfTokenOverride mCfZoneOverride mSigningKeyPath forceRemoteBuild skipVerification skipMigrations migrationSourceSpecs ignoreMigrationErrors dryRun = do
    let planPath = "generated/plan.json"
    let statePath = "generated/state.json"
    planExists <- Sh.testfile (fromString (T.unpack planPath))
    when (not planExists) $ do
        BLC.hPutStrLn stderr "generated/plan.json was not found. Run 'nix run .#hostenv-provider -- plan' before deploying."
        Sh.exit (ExitFailure 1)

    raw <- BL.readFile (T.unpack planPath)
    case A.eitherDecode' raw of
        Left err -> error err
        Right (plan :: KM.KeyMap A.Value) -> do
            let hostenvHostname = case lookupText (K.fromString "hostenvHostname") plan of
                    Nothing -> error "generated/plan.json is missing hostenvHostname"
                    Just hostname -> hostname
            let resolveNodeConnection = nodeConnectionFor plan hostenvHostname
            let envs = fromMaybe KM.empty (lookupObj (K.fromString "environments") plan)
            migrationSources <-
                forM migrationSourceSpecs $ \raw ->
                    case parseMigrationSource raw of
                        Just parsed -> pure parsed
                        Nothing -> error ("Invalid --migration-source value '" <> T.unpack raw <> "'. Expected ENV=NODE.")
            let duplicateOverrides = duplicateValues (map fst migrationSources)
            unless (null duplicateOverrides) $
                error ("Duplicate --migration-source values for: " <> T.unpack (T.intercalate ", " duplicateOverrides))

            -- Reconciliation is destructive: the desired environment set must
            -- decode atomically before any node observation or cleanup begins.
            envRowsParsed <- forM (KM.elems envs) $ \env ->
                case iparseEither parseJSON env of
                    Left err ->
                        pure
                            ( Left
                                ( "error reading from plan JSON at '"
                                    <> T.pack (show $ fst err)
                                    <> " - '"
                                    <> T.pack (snd err)
                                    <> "'"
                                )
                            )
                    Right envInfo ->
                        case env of
                            A.Object envObj ->
                                case Verify.parseEnvVerificationSpec envObj of
                                    Left parseErr ->
                                        pure
                                            ( Left
                                                ( "Invalid deploymentVerification for "
                                                    <> envInfo.userName
                                                    <> " ("
                                                    <> parseErr
                                                    <> ")"
                                                )
                                            )
                                    Right spec -> pure (Right (envInfo, spec))
                            _ -> pure (Right (envInfo, Verify.defaultEnvVerificationSpec))

            let envParseErrors = [err | Left err <- envRowsParsed]
            unless (null envParseErrors) $ do
                forM_ envParseErrors $
                    printProviderErrLine . sentenceCase
                printProviderErrLine "Cannot deploy because generated/plan.json is incomplete or invalid"
                Sh.exitWith (ExitFailure 1)

            let envRows = [row | Right row <- envRowsParsed]
            let desiredNodesByUser = M.fromList [(envInfo.userName, envInfo.node) | (envInfo, _) <- envRows]

            -- Filter environments to node requested by the user.
            let envRowsFiltered =
                    case mNode of
                        Nothing -> envRows
                        Just n -> filter (\(e, _) -> e.node == n) envRows
            let envInfosFiltered = map fst envRowsFiltered
            let envVerificationSpecs = map (\(e, spec) -> (e.userName, spec)) envRowsFiltered
            let verificationSpecFor envName = fromMaybe Verify.defaultEnvVerificationSpec (lookup envName envVerificationSpecs)

            let skipHits =
                    filter
                        (\s -> any (\e -> e.userName == s) envInfosFiltered)
                        skipMigrations
            let skipMisses = skipMigrations \\ skipHits
            let sourceHits = filter (\(envName, _) -> any (\e -> e.userName == envName) envInfosFiltered) migrationSources
            let sourceMisses = map fst migrationSources \\ map fst sourceHits
            let sourceFor envName = lookup envName migrationSources
            let discoveryNodes =
                    S.toList . S.fromList $
                        PlanTransition.planConnectionNodes plan
                            ++ PlanTransition.planSystemTargetNodes plan Nothing
                            ++ map snd sourceHits

            -- Perform data migrations if the environment has moved node.
            case mNode of
                Nothing -> pure ()
                Just n -> printProviderLine ("Deploying only node " <> n)
            printProviderLine ("Selected environments: " <> T.pack (show (length envInfosFiltered)))
            when (not (null skipHits)) $
                printProviderLine ("Skipping migration for: " <> T.intercalate ", " skipHits)
            when (not (null skipMisses)) $
                printProviderErrLine ("Warning: --skip-migrations did not match: " <> T.intercalate ", " skipMisses)
            forM_ sourceHits $ \(envName, sourceNode) ->
                printProviderLine ("Migration source set: " <> envName <> " -> " <> sourceNode)
            when (not (null sourceMisses)) $
                printProviderErrLine ("Warning: --migration-source did not match: " <> T.intercalate ", " sourceMisses)
            when ignoreMigrationErrors $
                printProviderErrLine "Warning: migration errors will be ignored; destination data may be stale"

            -- System profiles come from plan.nodes, not plan.environments.
            -- A node may intentionally have no current environments while it
            -- receives one final system deployment to retire lingering users.
            let targetNodes = PlanTransition.planSystemTargetNodes plan mNode
            stateRaw <- BL.readFile (T.unpack statePath)
            state <- case A.eitherDecode' stateRaw of
                Left err -> error ("Could not parse " <> T.unpack statePath <> ": " <> err)
                Right value -> pure (value :: KM.KeyMap A.Value)

            let deployArgs flakeRef useCheckSigs useDryActivate deployArgM =
                    let remoteBuildArgs =
                            if forceRemoteBuild then ["--remote-build"] else []
                        targetArgs = case deployArgM of
                            Just dArg -> [flakeRef <> "#" <> quoteDeployTarget dArg]
                            Nothing -> [flakeRef]
                        sigArgs = if useCheckSigs then ["--checksigs"] else []
                        dryActivateArgs = if useDryActivate then ["--dry-activate"] else []
                     in [ "run"
                        , "nixpkgs#deploy-rs"
                        , "--"
                        , "--skip-checks"
                        ]
                            <> sigArgs
                            <> dryActivateArgs
                            <> remoteBuildArgs
                            <> targetArgs
            let deployGuard res args = when (res /= ExitSuccess) $ printProviderErrLine ("Command failed: nix " <> T.unwords args)

            when dryRun $ do
                printProviderLine "Dry run: skipping migrations, signing, and deployment preflight checks"
                let dryArgs = deployArgs "generated/." False True
                systemDeployRes <-
                    forM targetNodes $ \nodeName -> do
                        let target = nodeName <> ".system"
                        let args = dryArgs (Just target)
                        printProviderLine ("Running nix " <> T.unwords args)
                        res <- Sh.proc "nix" args Sh.empty
                        deployGuard res args
                        pure (nodeName, res)

                envDeployRes <- forM (toNamed envInfosFiltered) $ \(envName, envInfo) -> do
                    let target = envInfo.node <> "." <> envInfo.userName
                    let args = dryArgs (Just target)
                    let systemStatus = case filter ((==) envInfo.node . fst) systemDeployRes of
                            [] -> Left "node not in system deployment list"
                            (_, ExitSuccess) : [] -> Right ExitSuccess
                            (_, code) : [] -> Left ("system deployment failed for node " <> envInfo.node <> " (exit " <> T.pack (show code) <> ")")
                            _moreThanOneNode -> Left "multiple matching nodes found in system deployment list"

                    printProviderLine ("Running nix " <> T.unwords args)
                    case systemStatus of
                        Left err -> printProviderErrLine err >> pure (envName, ExitFailure 1)
                        Right ExitSuccess -> do
                            res <- Sh.proc "nix" args Sh.empty
                            deployGuard res args
                            pure (envName, res)

                let systemDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) systemDeployRes
                let environmentDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) envDeployRes
                let failures = systemDeploymentFailures || environmentDeploymentFailures
                when failures $ printProviderErrLine "Dry-run deployment finished with errors"
                Sh.exitWith $ if failures then ExitFailure 1 else ExitSuccess

            let deployUser = PlanTransition.planDeployUser plan
            let userLifecycleOps = mkUserLifecycleOps deployUser resolveNodeConnection
            let remoteBuildMap = planNodeRemoteBuild plan
            let usesRemoteBuild nodeName = forceRemoteBuild || nodeUsesRemoteBuild remoteBuildMap nodeName
            let requiresLocalPush nodeName = not (usesRemoteBuild nodeName)
            let nodesRequiringLocalPush = filter requiresLocalPush targetNodes
            let trustedPublicKeys = planTrustedPublicKeys plan
            let localPushSet = S.fromList nodesRequiringLocalPush

            signingKeyInfo <-
                if null nodesRequiringLocalPush
                    then pure Nothing
                    else do
                        keyInfo <- ensureSigningKeyInfo hostenvHostname mSigningKeyPath
                        when keyInfo.wasGenerated $ do
                            printProviderLine ("Generated signing key at " <> keyInfo.secretKeyPath)
                            printProviderLine ("Wrote corresponding public key to " <> keyInfo.publicKeyPath)
                        pure (Just keyInfo)

            flakeKeyStatus <- forM signingKeyInfo (detectFlakeKeyStatus . (.publicKey))

            forM_ signingKeyInfo $ \keyInfo -> do
                let keyStatus = fromMaybe (FlakeKeyUnknown "signing key flake status unavailable") flakeKeyStatus
                when (null trustedPublicKeys) $ do
                    printProviderErrLine "Cannot deploy: provider.nixSigning.trustedPublicKeys is empty in generated/plan.json"
                    printProviderLines (localTrustSetupLines keyStatus keyInfo.publicKey)
                    Sh.exitWith (ExitFailure 1)
                when (keyInfo.publicKey `notElem` trustedPublicKeys) $ do
                    printProviderErrLine "Cannot deploy: the local signing key is not listed in provider.nixSigning.trustedPublicKeys"
                    printProviderErrLine ("Signing key public value: " <> keyInfo.publicKey)
                    printProviderLines (localTrustSetupLines keyStatus keyInfo.publicKey)
                    printProviderErrLine "Alternatively, pass --signing-key-file with a key already listed in trustedPublicKeys."
                    Sh.exitWith (ExitFailure 1)

            when forceRemoteBuild $
                printProviderLine "--remote-build is enabled; local signing trust checks are not required"
            forM_ targetNodes $ \nodeName ->
                when (not forceRemoteBuild && not (S.member nodeName localPushSet)) $
                    printProviderLine ("Node " <> nodeName <> " builds remotely; skipping the local signing trust check")

            preflightFailures <- fmap catMaybes $
                forM targetNodes $ \nodeName -> do
                    let requiresTrustedKey = S.member nodeName localPushSet
                    runNodeDeployPreflight
                        resolveNodeConnection
                        deployUser
                        nodeName
                        requiresTrustedKey
                        ((.publicKey) <$> signingKeyInfo)

            when (not (null preflightFailures)) $ do
                forM_ preflightFailures $ \failure -> do
                    printProviderErrLine ("Preflight check failed on node " <> failure.failureNode <> ": " <> failure.failureReason)
                    let remediationLines =
                            if failure.failureReason == Preflight.signingKeyNotTrustedReason
                                then case (signingKeyInfo, flakeKeyStatus) of
                                    (Just keyInfo, Just keyStatus) -> remoteNodeTrustLines keyStatus keyInfo.publicKey
                                    (Just keyInfo, Nothing) -> remoteNodeTrustLines (FlakeKeyUnknown "signing key flake status unavailable") keyInfo.publicKey
                                    _ -> failure.failureRemediation
                                else failure.failureRemediation
                    printProviderErrLine ("To fix " <> failure.failureNode <> ":")
                    printRemediationBlock remediationLines
                printProviderErrLine "Deployment stopped because one or more preflight checks failed"
                Sh.exitWith (ExitFailure 1)

            let inventoryNodes = PlanTransition.planSystemTargetNodes plan Nothing

            let lifecycleEnvInfos =
                    filter
                        (\envInfo -> envInfo.userName `notElem` skipMigrations)
                        envInfosFiltered
            let observationNodes =
                    S.toList . S.fromList $
                        targetNodes
                            ++ if null lifecycleEnvInfos then [] else discoveryNodes
            observedResults <-
                forM observationNodes $
                    UserLifecycle.readNodeUsers userLifecycleOps
            let observationErrors = [err | Left err <- observedResults]
            unless (null observationErrors) $ do
                forM_ observationErrors $
                    printProviderErrLine . sentenceCase
                Sh.exitWith (ExitFailure 1)
            let observedNodeUsers =
                    M.fromList [row | Right row <- observedResults]

            let managedIdentities = EnvironmentState.managedIdentities state
            runtimeResults <-
                forM observationNodes $
                    UserLifecycle.readNodeRuntimeUsers
                        userLifecycleOps
                        managedIdentities
            let runtimeErrors = [err | Left err <- runtimeResults]
            unless (null runtimeErrors) $ do
                forM_ runtimeErrors $
                    printProviderErrLine . sentenceCase
                Sh.exitWith (ExitFailure 1)
            let observedNodeRuntimeUsers =
                    M.fromList [row | Right row <- runtimeResults]

            let observedUidDrift =
                    [ (nodeName, userName, expectedUid, observedUid)
                    | (nodeName, users) <- M.toList observedNodeUsers
                    , (userName, expectedUid, observedUid) <-
                        EnvironmentState.managedUserUidMismatches
                            users
                            state
                    ]
            let observedUidOwnerConflicts =
                    [ (nodeName, userName, expectedUid, owner)
                    | (nodeName, users) <- M.toList observedNodeUsers
                    , (userName, expectedUid, owner) <-
                        EnvironmentState.managedReservedUidConflicts
                            users
                            state
                    ]
            unless (null observedUidDrift && null observedUidOwnerConflicts) $ do
                forM_ observedUidDrift $ \(nodeName, userName, expectedUid, observedUid) ->
                    printProviderErrLine
                        ( "Hostenv account UID mismatch on "
                            <> nodeName
                            <> ": "
                            <> userName
                            <> " observed="
                            <> T.pack (show observedUid)
                            <> " expected="
                            <> T.pack (show expectedUid)
                        )
                forM_ observedUidOwnerConflicts $ \(nodeName, userName, expectedUid, owner) ->
                    printProviderErrLine
                        ( "Reserved Hostenv UID conflict on "
                            <> nodeName
                            <> ": "
                            <> userName
                            <> " expects UID "
                            <> T.pack (show expectedUid)
                            <> ", which is owned by "
                            <> owner
                        )
                printProviderErrLine "Deployment stopped because Hostenv account UIDs do not match generated/state.json. Restore the expected UIDs before deploying."
                Sh.exitWith (ExitFailure 1)

            -- A handoff can survive a crash after the source system has already
            -- removed the old account. Remember markers whose source is still
            -- part of this deployment and has no account or runtime left. The
            -- marker is cleared only after that source system deploy succeeds,
            -- so a failed reconciliation remains recoverable.
            completedMigrationHandoffs <-
                fmap catMaybes $
                    forM lifecycleEnvInfos $ \envInfo -> do
                        existingHandoff <-
                            UserLifecycle.readMigrationHandoff
                                userLifecycleOps
                                envInfo.userName
                                envInfo.uid
                                envInfo.node
                        pure $
                            case existingHandoff of
                                Nothing -> Nothing
                                Just handoff ->
                                    let sourceNode = MigrationHandoff.handoffSourceNode handoff
                                        sourceAccountPresent =
                                            (M.lookup sourceNode observedNodeUsers >>= M.lookup envInfo.userName)
                                                == Just envInfo.uid
                                        sourceRuntimePresent =
                                            S.member
                                                envInfo.userName
                                                (M.findWithDefault S.empty sourceNode observedNodeRuntimeUsers)
                                     in if
                                            sourceNode `elem` inventoryNodes
                                                && sourceNode `elem` targetNodes
                                                && not sourceAccountPresent
                                                && not sourceRuntimePresent
                                            then Just (sourceNode, envInfo)
                                            else Nothing

            let skippedEnvInfos =
                    filter (\envInfo -> envInfo.userName `elem` skipHits) envInfosFiltered
            forM_ skippedEnvInfos $
                clearRestorePlan deployUser resolveNodeConnection

            migrationResolutions <-
                forM envInfosFiltered $ \envInfo ->
                    if envInfo.userName `elem` skipMigrations
                        then pure (Right Nothing)
                        else do
                            let resolution =
                                    EnvironmentState.resolveMigrationSourceNode
                                        envInfo.node
                                        envInfo.userName
                                        envInfo.uid
                                        (sourceFor envInfo.userName)
                                        observedNodeUsers
                            case resolution of
                                Right (Just sourceNode)
                                    | sourceNode `notElem` inventoryNodes ->
                                        pure
                                            ( Left
                                                ( "migration source "
                                                    <> sourceNode
                                                    <> " for "
                                                    <> envInfo.userName
                                                    <> " is reachable but is not in provider.nodeSystems. "
                                                    <> "Keep source nodes in provider.nodeSystems until migration and retirement are complete."
                                                )
                                            )
                                Right (Just sourceNode) -> do
                                    case sourceFor envInfo.userName of
                                        Just _ ->
                                            printProviderLine
                                                ("Migration source for " <> envInfo.userName <> " set by --migration-source: " <> sourceNode)
                                        Nothing ->
                                            printProviderLine
                                                ("Migration source for " <> envInfo.userName <> " found on node: " <> sourceNode)
                                    pure (Right (Just (envInfo, sourceNode)))
                                Right Nothing -> do
                                    let orphanRuntimeSources =
                                            [ nodeName
                                            | (nodeName, runtimeUsers) <- M.toList observedNodeRuntimeUsers
                                            , nodeName /= envInfo.node
                                            , S.member envInfo.userName runtimeUsers
                                            ]
                                    case orphanRuntimeSources of
                                        [] -> do
                                            removedNodeHint <-
                                                dnsRemovedInventoryHint
                                                    hostenvHostname
                                                    inventoryNodes
                                                    envInfo
                                            pure $ case removedNodeHint of
                                                Left dnsFailure ->
                                                    Left
                                                        ( "could not determine whether "
                                                            <> envInfo.hostname
                                                            <> " still points to a removed provider node: "
                                                            <> Dns.renderLookupFailure dnsFailure
                                                            <> ". Cannot treat the environment as new until DNS can be verified."
                                                        )
                                                Right (Just removedNode) ->
                                                    Left
                                                        ( "DNS for "
                                                            <> envInfo.hostname
                                                            <> " points to provider node "
                                                            <> removedNode
                                                            <> ", but that node is not in provider.nodeSystems. "
                                                            <> "Restore the source node to provider.nodeSystems until migration and retirement are complete."
                                                        )
                                                Right Nothing -> Right Nothing
                                        [sourceNode] -> do
                                            completedHandoff <-
                                                UserLifecycle.readMigrationHandoff
                                                    userLifecycleOps
                                                    envInfo.userName
                                                    envInfo.uid
                                                    envInfo.node
                                            if null envInfo.migrateBackups
                                                then do
                                                    printProviderLine
                                                        ( "Hostenv runtime for "
                                                            <> envInfo.userName
                                                            <> " remains on "
                                                            <> sourceNode
                                                            <> " without a Unix account; no migration backups are configured, so source clean-up can resume after the destination is accepted"
                                                        )
                                                    pure (Right (Just (envInfo, sourceNode)))
                                                else
                                                    if maybe False ((== sourceNode) . MigrationHandoff.handoffSourceNode) completedHandoff
                                                        then do
                                                            printProviderLine
                                                                ( "Hostenv runtime for "
                                                                    <> envInfo.userName
                                                                    <> " remains on "
                                                                    <> sourceNode
                                                                    <> " without a Unix account, but the destination records completed migration progress; resuming source clean-up"
                                                                )
                                                            pure (Right (Just (envInfo, sourceNode)))
                                                        else
                                                            pure
                                                                ( Left
                                                                    ( "Hostenv runtime for "
                                                                        <> envInfo.userName
                                                                        <> " remains on "
                                                                        <> sourceNode
                                                                        <> " but the Unix account is missing. Cannot treat the destination as new because the migration data cannot be recovered safely.\n\n"
                                                                        <> "Restore the source Unix account and runtime state, or resolve the environment manually."
                                                                    )
                                                                )
                                        sources ->
                                            pure
                                                ( Left
                                                    ( "Hostenv runtime for "
                                                        <> envInfo.userName
                                                        <> " remains on multiple possible source nodes without a matching Unix account: "
                                                        <> T.intercalate ", " sources
                                                        <> ". Migration cannot continue until the remaining runtime state is cleaned up."
                                                    )
                                                )
                                Left err -> pure (Left err)

            let migrationFatalErrors =
                    [ err
                    | Left err <- migrationResolutions
                    ]
            when (not (null migrationFatalErrors)) $ do
                forM_ migrationFatalErrors $
                    printProviderErrLine . sentenceCase
                Sh.exitWith (ExitFailure 1)

            let migrations =
                    [ migration
                    | Right (Just migration) <- migrationResolutions
                    ]

            case mNode of
                Nothing -> pure ()
                Just selectedNode -> do
                    let externalMigrationSources =
                            [ (envInfo.userName, sourceNode)
                            | (envInfo, sourceNode) <- migrations
                            , sourceNode /= selectedNode
                            ]
                    unless (null externalMigrationSources) $ do
                        forM_ externalMigrationSources $ \(userName, sourceNode) ->
                            printProviderErrLine
                                ( "Cannot complete migration "
                                    <> userName
                                    <> " with --node "
                                    <> selectedNode
                                    <> ": source "
                                    <> sourceNode
                                    <> " also needs to be finalised; run an unfiltered deploy"
                                )
                        Sh.exitWith (ExitFailure 1)

            deployDnsCache <- Dns.newLookupCache
            preflightDnsObservation <- Dns.newObservationCache
            dnsStateRows <-
                forM envInfosFiltered $ \envInfo -> do
                    let items = environmentDnsItems hostenvHostname envs envInfo
                    -- Preflight is informational and happens before deployment.
                    -- A failed observation is not evidence that DNS is wrong,
                    -- but it is also not "ready": carry it forward so the
                    -- reconciliation step can either repair it via Cloudflare or
                    -- return the typed lookup failure.
                    dnsChecks <- checkDnsItems deployDnsCache preflightDnsObservation items
                    let mismatched =
                            [ item
                            | (item, Right False) <- dnsChecks
                            ]
                    let lookupFailures =
                            [ (item, dnsFailure)
                            | (item, Left dnsFailure) <- dnsChecks
                            ]
                    forM_ lookupFailures $ \(item, dnsFailure) ->
                        printProviderErrLine
                            ( "Warning: could not check DNS for "
                                <> item.diDiscoveryHost
                                <> ": "
                                <> Dns.renderLookupFailure dnsFailure
                                <> "; deployment will try to reconcile DNS after activation"
                            )
                    let destinationPresent =
                            (M.lookup envInfo.node observedNodeUsers >>= M.lookup envInfo.userName)
                                == Just envInfo.uid
                    let migrationSource =
                            lookup envInfo.userName
                                [ (migrationEnv.userName, sourceNode)
                                | (migrationEnv, sourceNode) <- migrations
                                ]
                    let lifecycleText =
                            case migrationSource of
                                Just sourceNode -> "migration " <> sourceNode <> " -> " <> envInfo.node
                                Nothing ->
                                    if destinationPresent
                                        then "existing environment on " <> envInfo.node
                                        else "fresh environment on " <> envInfo.node
                    printProviderLine
                        ( "DNS preflight for "
                            <> envInfo.userName
                            <> " ("
                            <> lifecycleText
                            <> "): "
                            <> let pendingCount = length mismatched + length lookupFailures
                                in if pendingCount == 0
                                    then "ready"
                                    else "DNS reconciliation needed after deployment; hostnames: " <> T.pack (show pendingCount)
                        )
                    pure (envInfo.userName, items)
            let dnsItemsByUser = M.fromList dnsStateRows

            migrationHandoffStates <-
                forM migrations $ \migration@(envInfo, prevNode) -> do
                    completedHandoff <-
                        UserLifecycle.readMigrationHandoff
                            userLifecycleOps
                            envInfo.userName
                            envInfo.uid
                            envInfo.node
                    alreadyQuiesced <-
                        case completedHandoff of
                            Nothing -> pure False
                            Just handoff
                                | MigrationHandoff.handoffSourceNode handoff /= prevNode -> do
                                    printProviderErrLine
                                        ( "Warning: ignoring stale migration recovery state for "
                                            <> envInfo.userName
                                            <> " from "
                                            <> MigrationHandoff.handoffSourceNode handoff
                                            <> "; current source is "
                                            <> prevNode
                                        )
                                    UserLifecycle.clearMigrationHandoffOnNode
                                        userLifecycleOps
                                        envInfo.userName
                                        envInfo.uid
                                        envInfo.node
                                    pure False
                                | otherwise -> do
                                    let sourceAccountPresent =
                                            (M.lookup prevNode observedNodeUsers >>= M.lookup envInfo.userName)
                                                == Just envInfo.uid
                                    if not sourceAccountPresent
                                        then do
                                            printProviderLine
                                                ( "Migration recovery for "
                                                    <> envInfo.userName
                                                    <> " from "
                                                    <> prevNode
                                                    <> " has no remaining Unix account; resuming source clean-up without another backup"
                                                )
                                            pure True
                                        else do
                                            sourceQuiesced <-
                                                UserLifecycle.managedUserIsQuiescedOnNode
                                                    userLifecycleOps
                                                    envInfo.userName
                                                    envInfo.uid
                                                    prevNode
                                            if sourceQuiesced
                                                then do
                                                    when (MigrationHandoff.handoffPhase handoff == MigrationHandoff.HandoffAccepted) $
                                                        UserLifecycle.writeMigrationHandoffQuiesced
                                                            userLifecycleOps
                                                            envInfo.userName
                                                            envInfo.uid
                                                            envInfo.node
                                                            prevNode
                                                    printProviderLine
                                                        ( "Migration recovery for "
                                                            <> envInfo.userName
                                                            <> " from "
                                                            <> prevNode
                                                            <> " already has stopped source services; resuming without another backup"
                                                        )
                                                    pure True
                                                else do
                                                    when (MigrationHandoff.handoffPhase handoff == MigrationHandoff.HandoffQuiesced) $ do
                                                        printProviderErrLine
                                                            ( "Warning: migration recovery state says the source is stopped for "
                                                                <> envInfo.userName
                                                                <> " from "
                                                                <> prevNode
                                                                <> ", but the source is running; taking a new migration backup"
                                                            )
                                                        UserLifecycle.clearMigrationHandoffOnNode
                                                            userLifecycleOps
                                                            envInfo.userName
                                                            envInfo.uid
                                                            envInfo.node
                                                    pure False
                    pure (migration, alreadyQuiesced)

            let migrationsToRun =
                    [ migration
                    | (migration@(envInfo, _), alreadyQuiesced) <- migrationHandoffStates
                    , not alreadyQuiesced
                    , not (null envInfo.migrateBackups)
                    ]

            let runMigration (envInfo, prevNode) = do
                    snapshots <- forM envInfo.migrateBackups $ \backupName -> do
                        snap <- runMigrationBackup deployUser resolveNodeConnection envInfo prevNode backupName
                        pure (backupName, snap)
                    writeRestorePlan deployUser resolveNodeConnection envInfo prevNode snapshots
                    let snapshotPairs = map (\(name, sid) -> name <> "=" <> sid) snapshots
                    printProviderLine ("Prepared restore data for " <> envInfo.userName <> " (snapshots: " <> T.intercalate ", " snapshotPairs <> ")")

            ignoredMigrationFailures <-
                if null migrationsToRun
                    then do
                        printProviderLine "No migration backups required"
                        pure []
                    else do
                        printProviderLine ("Environments needing migration backups: " <> T.pack (show (length migrationsToRun)))
                        forM_ migrationsToRun $ \(envInfo, prevNode) -> do
                            let backups = T.intercalate ", " envInfo.migrateBackups
                            printProviderLine ("Migration backup for " <> envInfo.userName <> " from " <> prevNode <> " -> " <> envInfo.node <> " (" <> backups <> ")")
                        if ignoreMigrationErrors
                            then do
                                failures <- fmap catMaybes $
                                    forM migrationsToRun $ \(envInfo, prevNode) -> do
                                        res <- try (runMigration (envInfo, prevNode)) :: IO (Either SomeException ())
                                        case res of
                                            Right _ -> pure Nothing
                                            Left err -> do
                                                printProviderErrLine ("Warning: migration failed for " <> envInfo.userName <> ": " <> T.pack (displayException err))
                                                pure (Just envInfo.userName)
                                when (not (null failures)) $
                                    printProviderErrLine
                                        ( "Warning: keeping migration source nodes after ignored failures for "
                                            <> T.intercalate ", " failures
                                        )
                                pure failures
                            else do
                                forM_ migrationsToRun runMigration
                                pure []

            let acceptedMigrationSources =
                    M.fromList
                        [ (envInfo.userName, prevNode)
                        | (envInfo, prevNode) <- migrations
                        , envInfo.userName `notElem` ignoredMigrationFailures
                        ]

            let protectedSourceUsers =
                    S.fromList (skipHits ++ ignoredMigrationFailures)

            let retirementsForNode nodeName =
                    EnvironmentState.managedUsersToRetire
                        nodeName
                        desiredNodesByUser
                        (M.findWithDefault M.empty nodeName observedNodeUsers)
                        (M.findWithDefault S.empty nodeName observedNodeRuntimeUsers)
                        state
            let movedSourceUsers nodeName =
                    [ userName
                    | (userName, _) <- retirementsForNode nodeName
                    , M.member userName desiredNodesByUser
                    ]
            let envsForNode nodeName =
                    filter (\envInfo -> envInfo.node == nodeName) envInfosFiltered
            let envInfoByUser =
                    M.fromList [(envInfo.userName, envInfo) | envInfo <- envInfosFiltered]

            let rollbackRetiredCleanedUsers nodeName cleanedUsers = do
                    let rollbackUsers =
                            filter
                                (\(userName, _) -> M.notMember userName desiredNodesByUser)
                                cleanedUsers
                    UserLifecycle.rollbackManagedUserCleanupOnNode
                        userLifecycleOps
                        nodeName
                        rollbackUsers

            let generatedFlake = "generated/."

            let deploySystemNode nodeName = do
                    let target = nodeName <> ".system"
                    let targetInstallable = deployProfilePathInstallableAt generatedFlake nodeName "system"
                    signRes <-
                        if S.member nodeName localPushSet
                            then case signingKeyInfo of
                                Just keyInfo -> signInstallable keyInfo targetInstallable target
                                Nothing -> do
                                    printProviderErrLine ("Signing configuration is missing for node " <> nodeName)
                                    pure (ExitFailure 1)
                            else pure ExitSuccess
                    if signRes /= ExitSuccess
                        then do
                            printProviderErrLine ("Could not sign deployment target " <> target)
                            pure signRes
                        else do
                            let args = deployArgs generatedFlake True False (Just target)
                            printProviderLine ("Running nix " <> T.unwords args)
                            res <- Sh.proc "nix" args Sh.empty
                            deployGuard res args
                            pure res

            let deployEnvironment envInfo = do
                    let envName = envInfo.userName
                    let target = envInfo.node <> "." <> envInfo.userName
                    let targetInstallable = deployProfilePathInstallableAt generatedFlake envInfo.node envInfo.userName
                    let args = deployArgs generatedFlake True False (Just target)
                    printProviderLine ("Running nix " <> T.unwords args)
                    signRes <-
                        if S.member envInfo.node localPushSet
                            then case signingKeyInfo of
                                Just keyInfo -> signInstallable keyInfo targetInstallable target
                                Nothing -> do
                                    printProviderErrLine ("Signing configuration is missing for node " <> envInfo.node)
                                    pure (ExitFailure 1)
                            else pure ExitSuccess
                    if signRes /= ExitSuccess
                        then do
                            printProviderErrLine ("Could not sign deployment target " <> target)
                            pure (envName, signRes)
                        else do
                            res <- Sh.proc "nix" args Sh.empty
                            deployGuard res args
                            pure (envName, res)

            let reconcileDnsAfterDeployment envInfo =
                    ensureEnvironmentDns
                        deployDnsCache
                        mCfTokenOverride
                        mCfZoneOverride
                        plan
                        envInfo
                        (M.findWithDefault [] envInfo.userName dnsItemsByUser)

            let waitForTrustedHttps envInfo = do
                    let tlsTargets =
                            S.toList . S.fromList $
                                [ (item.diDiscoveryHost, item.diExpectedHost)
                                | item <- M.findWithDefault [] envInfo.userName dnsItemsByUser
                                , item.diTlsEnabled
                                ]
                    if null tlsTargets
                        then pure (Right ())
                        else do
                            printProviderLine
                                ( "Waiting for trusted HTTPS for "
                                    <> envInfo.userName
                                    <> " on the destination after the DNS change"
                                )
                            unresolved <-
                                TlsReadiness.waitForTrustedHttpsWith
                                    (\delaySeconds -> do
                                        printProviderLine
                                            ( "Waiting "
                                                <> T.pack (show delaySeconds)
                                                <> "s before rechecking trusted HTTPS for "
                                                <> envInfo.userName
                                            )
                                        threadDelay (delaySeconds * 1000000)
                                    )
                                    (backoffDelays 1 30 1200)
                                    TlsReadiness.trustedHttpsReady
                                    tlsTargets
                            pure $
                                if null unresolved
                                    then Right ()
                                    else
                                        Left
                                            ( "trusted HTTPS did not become available on the destination for "
                                                <> T.intercalate
                                                    ", "
                                                    [ publicHost <> " -> " <> destinationHost
                                                    | (publicHost, destinationHost) <- unresolved
                                                    ]
                                                <> " within 20 minutes"
                                            )

            when skipVerification $
                printProviderLine "--skip-verification is enabled; skipping post-deployment verification checks"

            let verifyDeployedEnvironment envInfo =
                    if skipVerification
                        then pure (True, Nothing)
                        else do
                            let envName = envInfo.userName
                            let verificationSpec = verificationSpecFor envName
                            if not verificationSpec.evEnable || null verificationSpec.evChecks
                                then pure (True, Nothing)
                                else do
                                    let verificationHost = Verify.canonicalNodeHostname hostenvHostname envInfo.node
                                    let statusSuffix mStatus =
                                            case mStatus of
                                                Nothing -> ""
                                                Just status -> " (HTTP " <> T.pack (show status) <> ")"
                                    printProviderLine ("Verifying deployment for " <> envName <> " via " <> verificationHost)
                                    verificationRes <- try (Verify.runEnvVerification verificationHost verificationSpec) :: IO (Either SomeException [Verify.VerificationCheckResult])
                                    case verificationRes of
                                        Left err -> do
                                            let message = "verification failed for " <> envName <> ": " <> T.pack (displayException err)
                                            if verificationSpec.evEnforce
                                                then do
                                                    printProviderErrLine (sentenceCase message)
                                                    pure (False, Just envName)
                                                else do
                                                    printProviderErrLine ("Warning: " <> message)
                                                    pure (True, Nothing)
                                        Right checkResults -> do
                                            let failedChecks = filter (not . (.vcrPassed)) checkResults
                                            forM_ checkResults $ \checkResult ->
                                                if checkResult.vcrPassed
                                                    then
                                                        printProviderLine
                                                            ( "Verification check "
                                                                <> checkResult.vcrName
                                                                <> " passed for "
                                                                <> envName
                                                                <> statusSuffix checkResult.vcrHttpStatus
                                                            )
                                                    else
                                                        printProviderErrLine
                                                            ( "Warning: verification check "
                                                                <> checkResult.vcrName
                                                                <> " failed for "
                                                                <> envName
                                                                <> statusSuffix checkResult.vcrHttpStatus
                                                                <> " ("
                                                                <> T.intercalate "; " checkResult.vcrFailures
                                                                <> ")"
                                                            )
                                            if null failedChecks
                                                then pure (True, Nothing)
                                                else
                                                    if verificationSpec.evEnforce
                                                        then pure (False, Just envName)
                                                        else do
                                                            printProviderErrLine ("Warning: verification failures ignored for " <> envName <> " (deploymentVerification.enforce=false)")
                                                            pure (True, Nothing)

            let deployEnvironmentAndVerify envInfo = do
                    envResult@(envName, deployCode) <- deployEnvironment envInfo
                    case deployCode of
                        ExitFailure _ -> pure (envResult, False, Nothing)
                        ExitSuccess -> do
                            (accepted, verificationFailure) <- verifyDeployedEnvironment envInfo
                            if not accepted
                                then pure (envResult, False, verificationFailure)
                                else
                                    case M.lookup envName acceptedMigrationSources of
                                        Just sourceNode -> do
                                            UserLifecycle.writeMigrationHandoffAccepted
                                                userLifecycleOps
                                                envInfo.userName
                                                envInfo.uid
                                                envInfo.node
                                                sourceNode
                                            pure (envResult, True, verificationFailure)
                                        Nothing ->
                                            if envName `S.member` protectedSourceUsers
                                                then pure (envResult, True, verificationFailure)
                                                else do
                                                    dnsResult <- reconcileDnsAfterDeployment envInfo
                                                    case dnsResult of
                                                        Right () -> pure (envResult, True, verificationFailure)
                                                        Left err -> do
                                                            printProviderErrLine
                                                                ( "DNS reconciliation failed for "
                                                                    <> envName
                                                                    <> " after deployment: "
                                                                    <> err
                                                                    <> ". Update DNS if necessary and rerun deploy."
                                                                )
                                                            pure ((envName, ExitFailure 1), False, verificationFailure)

            let deployReadyNodes pendingNodes systemResults envResults successfulEnvironments verificationFailures =
                    let ready nodeName =
                            let movedUsers = movedSourceUsers nodeName
                                hasProtectedSource = any (`S.member` protectedSourceUsers) movedUsers
                                destinationsSucceeded =
                                    all (`S.member` successfulEnvironments) movedUsers
                             in not hasProtectedSource && destinationsSucceeded
                        readyNodes = filter ready pendingNodes
                     in if null readyNodes
                            then pure (pendingNodes, systemResults, envResults, successfulEnvironments, verificationFailures)
                            else do
                                roundResults <-
                                    forM readyNodes $ \nodeName -> do
                                        let onCleaned userName uid =
                                                case M.lookup userName desiredNodesByUser of
                                                    Nothing ->
                                                        UserLifecycle.clearMigrationHandoffOnNode
                                                            userLifecycleOps
                                                            userName
                                                            uid
                                                            nodeName
                                                    Just _ ->
                                                        forM_ (M.lookup userName envInfoByUser) $ \envInfo -> do
                                                            UserLifecycle.clearMigrationHandoffOnNode
                                                                userLifecycleOps
                                                                envInfo.userName
                                                                envInfo.uid
                                                                nodeName
                                                            case M.lookup userName acceptedMigrationSources of
                                                                Just sourceNode
                                                                    | sourceNode == nodeName ->
                                                                        UserLifecycle.writeMigrationHandoffQuiesced
                                                                            userLifecycleOps
                                                                            envInfo.userName
                                                                            envInfo.uid
                                                                            envInfo.node
                                                                            sourceNode
                                                                Just sourceNode ->
                                                                    error
                                                                        ( "Migration source mismatch for "
                                                                            <> T.unpack userName
                                                                            <> ": Hostenv is cleaning "
                                                                            <> T.unpack nodeName
                                                                            <> ", but the recorded source is "
                                                                            <> T.unpack sourceNode
                                                                            <> ".\n\nKeep both nodes in provider.nodeSystems and rerun an unfiltered deploy."
                                                                        )
                                                                Nothing ->
                                                                    error
                                                                        ( "Missing migration source for "
                                                                            <> T.unpack userName
                                                                            <> " while cleaning "
                                                                            <> T.unpack nodeName
                                                                            <> ".\n\nKeep both nodes in provider.nodeSystems and rerun an unfiltered deploy."
                                                                        )
                                        prepared <-
                                            UserLifecycle.prepareManagedUserCleanupOnNode
                                                userLifecycleOps
                                                desiredNodesByUser
                                                (M.findWithDefault M.empty nodeName observedNodeUsers)
                                                (M.findWithDefault S.empty nodeName observedNodeRuntimeUsers)
                                                state
                                                nodeName
                                                onCleaned
                                        case prepared of
                                            Left err -> do
                                                printProviderErrLine (sentenceCase err)
                                                let failedEnvs =
                                                        [ ((envInfo.userName, ExitFailure 1), False, Nothing)
                                                        | envInfo <- envsForNode nodeName
                                                        ]
                                                pure (nodeName, ExitFailure 1, failedEnvs)
                                            Right (cleanedUsers, cleanupFailures) -> do
                                                if null cleanupFailures
                                                    then do
                                                        let movedCleanedUsers =
                                                                [ userName
                                                                | (userName, _) <- cleanedUsers
                                                                , M.member userName desiredNodesByUser
                                                                ]
                                                        dnsFailures <-
                                                            fmap catMaybes $
                                                                forM movedCleanedUsers $ \userName ->
                                                                    case M.lookup userName envInfoByUser of
                                                                        Nothing ->
                                                                            pure
                                                                                ( Just
                                                                                    ( userName
                                                                                        <> ": destination environment metadata is missing"
                                                                                    )
                                                                                )
                                                                        Just envInfo -> do
                                                                            let allItems = M.findWithDefault [] userName dnsItemsByUser
                                                                            result <-
                                                                                ensureEnvironmentDns
                                                                                    deployDnsCache
                                                                                    mCfTokenOverride
                                                                                    mCfZoneOverride
                                                                                    plan
                                                                                    envInfo
                                                                                    allItems
                                                                            case result of
                                                                                Left err -> pure (Just (userName <> ": " <> err))
                                                                                Right () -> do
                                                                                    waitForAuthoritativeDnsPropagation deployDnsCache allItems >>= \case
                                                                                        Left dnsFailure ->
                                                                                            pure
                                                                                                ( Just
                                                                                                    ( userName
                                                                                                        <> ": authoritative DNS propagation could not be verified: "
                                                                                                        <> Dns.renderLookupFailure dnsFailure
                                                                                                    )
                                                                                                )
                                                                                        Right (_, pendingDns) ->
                                                                                            if not (null pendingDns)
                                                                                                then
                                                                                                    pure
                                                                                                        ( Just
                                                                                                            ( userName
                                                                                                                <> ": DNS has not converged on every authoritative nameserver for "
                                                                                                                <> T.intercalate ", " (map (.diDiscoveryHost) pendingDns)
                                                                                                            )
                                                                                                        )
                                                                                                else do
                                                                                                    httpsResult <- waitForTrustedHttps envInfo
                                                                                                    pure $
                                                                                                        case httpsResult of
                                                                                                            Right () -> Nothing
                                                                                                            Left err -> Just (userName <> ": " <> err)
                                                        if not (null dnsFailures)
                                                            then do
                                                                forM_ dnsFailures $ \err ->
                                                                    printProviderErrLine
                                                                        ( "Migration cannot finish after the source was stopped: "
                                                                            <> err
                                                                            <> ". The source remains stopped.\n\nFix DNS or HTTPS, then run deploy again."
                                                                        )
                                                                rollbackRetiredCleanedUsers nodeName cleanedUsers
                                                                let failedEnvs =
                                                                        [ ((envInfo.userName, ExitFailure 1), False, Nothing)
                                                                        | envInfo <- envsForNode nodeName
                                                                        ]
                                                                pure (nodeName, ExitFailure 1, failedEnvs)
                                                            else do
                                                                systemCode <- deploySystemNode nodeName
                                                                when (systemCode /= ExitSuccess && not (null cleanedUsers)) $
                                                                    rollbackRetiredCleanedUsers nodeName cleanedUsers
                                                                when (systemCode == ExitSuccess) $ do
                                                                    forM_ movedCleanedUsers $ \userName ->
                                                                        forM_ (M.lookup userName envInfoByUser) $ \envInfo ->
                                                                            UserLifecycle.clearMigrationHandoffOnNode
                                                                                userLifecycleOps
                                                                                envInfo.userName
                                                                                envInfo.uid
                                                                                envInfo.node
                                                                    forM_
                                                                        [ envInfo
                                                                        | (sourceNode, envInfo) <- completedMigrationHandoffs
                                                                        , sourceNode == nodeName
                                                                        ]
                                                                        $ \envInfo -> do
                                                                            printProviderLine
                                                                                ( "Clearing completed migration recovery state for "
                                                                                    <> envInfo.userName
                                                                                    <> " after reconciling source node "
                                                                                    <> nodeName
                                                                                )
                                                                            UserLifecycle.clearMigrationHandoffOnNode
                                                                                userLifecycleOps
                                                                                envInfo.userName
                                                                                envInfo.uid
                                                                                envInfo.node
                                                                nodeEnvResults <-
                                                                    if systemCode == ExitSuccess
                                                                        then forM (envsForNode nodeName) deployEnvironmentAndVerify
                                                                        else do
                                                                            forM_ (envsForNode nodeName) $ \envInfo ->
                                                                                printProviderErrLine
                                                                                    ( "System deployment failed for node "
                                                                                        <> nodeName
                                                                                        <> "; skipping environment "
                                                                                        <> envInfo.userName
                                                                                    )
                                                                            pure
                                                                                [ ((envInfo.userName, ExitFailure 1), False, Nothing)
                                                                                | envInfo <- envsForNode nodeName
                                                                                ]
                                                                pure (nodeName, systemCode, nodeEnvResults)
                                                    else do
                                                        printProviderErrLine
                                                            ( "Could not prepare Hostenv account retirement on "
                                                                <> nodeName
                                                                <> ": "
                                                                <> T.intercalate ", " cleanupFailures
                                                            )
                                                        let failedEnvs =
                                                                [ ((envInfo.userName, ExitFailure 1), False, Nothing)
                                                                | envInfo <- envsForNode nodeName
                                                                ]
                                                        pure (nodeName, ExitFailure 1, failedEnvs)
                                let roundSystemResults =
                                        [(nodeName, code) | (nodeName, code, _) <- roundResults]
                                let roundEnvOutcomes = concat [results | (_, _, results) <- roundResults]
                                let roundEnvResults = [envResult | (envResult, _, _) <- roundEnvOutcomes]
                                let roundSuccessful =
                                        S.fromList
                                            [ envName
                                            | ((envName, ExitSuccess), True, _) <- roundEnvOutcomes
                                            ]
                                let roundVerificationFailures =
                                        catMaybes [failure | (_, _, failure) <- roundEnvOutcomes]
                                deployReadyNodes
                                    (pendingNodes \\ readyNodes)
                                    (systemResults ++ roundSystemResults)
                                    (envResults ++ roundEnvResults)
                                    (successfulEnvironments `S.union` roundSuccessful)
                                    (verificationFailures ++ roundVerificationFailures)

            (pendingNodes, systemDeployRes, envDeployRes, successfulEnvironments, verificationFatalFailures) <-
                deployReadyNodes targetNodes [] [] S.empty []

            let pendingNodeDetails =
                    [ ( nodeName
                      , movedSourceUsers nodeName
                      , filter (`S.member` protectedSourceUsers) (movedSourceUsers nodeName)
                      , filter
                            (\userName ->
                                not (S.member userName protectedSourceUsers)
                                    && not (S.member userName successfulEnvironments)
                            )
                            (movedSourceUsers nodeName)
                      )
                    | nodeName <- pendingNodes
                    ]
            let deferredOnly =
                    [ (nodeName, protected)
                    | (nodeName, movedUsers, protected, blocked) <- pendingNodeDetails
                    , null blocked
                    , not (null movedUsers)
                    , not (null protected)
                    ]
            let unsafePending =
                    [ (nodeName, blocked)
                    | (nodeName, _, _, blocked) <- pendingNodeDetails
                    , not (null blocked)
                    ]
            forM_ deferredOnly $ \(nodeName, protected) ->
                printProviderErrLine
                    ( "Warning: deferred source clean-up on "
                        <> nodeName
                        <> " to preserve migration sources: "
                        <> T.intercalate ", " protected
                    )
            forM_ unsafePending $ \(nodeName, blocked) ->
                printProviderErrLine
                    ( "Cannot safely clean up source node "
                        <> nodeName
                        <> "; destination deployment or verification failed for: "
                        <> T.intercalate ", " blocked
                    )

            let systemDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) systemDeployRes
            let environmentDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) envDeployRes
            let finalizationFailures = not (null unsafePending)
            let deploymentFailures = systemDeploymentFailures || environmentDeploymentFailures || finalizationFailures
            let verificationFailures = not (null verificationFatalFailures)
            when deploymentFailures $ printProviderErrLine "Deployment finished with errors"
            when verificationFailures $
                printProviderErrLine ("Deployment verification failed for: " <> T.intercalate ", " verificationFatalFailures)
            let failures = deploymentFailures || verificationFailures
            Sh.exitWith $ if failures then ExitFailure 1 else ExitSuccess

quoteDeployTarget :: Text -> Text
quoteDeployTarget deployTarget =
    case T.breakOn "." deployTarget of
        (nodeName, profileWithDot)
            | not (T.null profileWithDot) ->
                let profileName = T.drop 1 profileWithDot
                 in quoteDeployToken nodeName <> "." <> quoteDeployToken profileName
        _ -> deployTarget
  where
    quoteDeployToken token =
        "\"" <> T.replace "\"" "\\\"" token <> "\""

-- -------- Main --------
main :: IO ()
main = do
    CLI cmd <- OA.execParser cliOpts
    case cmd of
        CmdPlan dryRun -> runPlan dryRun
        CmdDeploy mNode mTok mZone mSigningKeyPath forceRemoteBuild skipVerification skipMigrations migrationSources ignoreMigrationErrors dryRun ->
            runDeploy mNode mTok mZone mSigningKeyPath forceRemoteBuild skipVerification skipMigrations migrationSources ignoreMigrationErrors dryRun
