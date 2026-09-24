{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- hostenv-provider CLI: plan | dns-gate | deploy
-- dns-gate ports the legacy scripts/postgen.hs DNS/ACME gate and Cloudflare upsert logic.

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (iparseEither, parseJSON)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Char (isAlphaNum, isHexDigit)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intersect, (\\))
import Data.Map.Strict qualified as M
import Data.Maybe (catMaybes, fromMaybe, isNothing, listToMaybe, mapMaybe)
import Data.Scientific (floatingOrInteger)
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
import Hostenv.Provider.DnsBackoff (backoffDelays)
import Hostenv.Provider.DnsGateFilter (
    DnsGateItem (..),
    collectDnsGateItems,
    disableAcmeOnNode,
    disableLetsEncryptPaths,
    filterEnvironmentsByNode,
 )
import Hostenv.Provider.SigningTarget (deployProfilePathInstallable)
import Options.Applicative qualified as OA
import System.Directory qualified as Dir
import System.Environment qualified as Env
import System.Exit (ExitCode (..))
import System.FilePath qualified as FP
import System.IO (hClose, openTempFile, stderr)
import System.Process (readProcessWithExitCode)
import Turtle (FilePath, (<|>))
import Turtle qualified as Sh
import Prelude hiding (FilePath)

-- -------- CLI --------
data Command
    = CmdPlan {dryRun :: Bool}
    | CmdDnsGate {node :: Maybe Text, token :: Maybe Text, zone :: Maybe Text, withDnsUpdate :: Bool, dryRun :: Bool}
    | CmdDeploy
        { node :: Maybe Text
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
                <> OA.help "Restrict to a specific node"
            )

tokenOpt :: OA.Parser (Maybe Text)
tokenOpt = OA.optional . fmap T.pack $ OA.strOption (OA.long "cf-token" <> OA.metavar "TOKEN" <> OA.help "Cloudflare API token (overrides CF_API_TOKEN env)")

zoneOpt :: OA.Parser (Maybe Text)
zoneOpt = OA.optional . fmap T.pack $ OA.strOption (OA.long "cf-zone" <> OA.metavar "ZONE" <> OA.help "Cloudflare zone id (overrides CF_ZONE_ID env)")

withDnsUpdateOpt :: OA.Parser Bool
withDnsUpdateOpt =
    OA.switch
        ( OA.long "with-dns-update"
            <> OA.help "Allow Cloudflare upserts (otherwise only checks and disables ACME/forceSSL)"
        )

dryRunOpt :: OA.Parser Bool
dryRunOpt =
    OA.switch
        ( OA.long "dry-run"
            <> OA.help "Preview changes without mutating generated files or remote state"
        )

skipMigrationsOpt :: OA.Parser [Text]
skipMigrationsOpt =
    OA.many . fmap T.pack $
        OA.strOption
            ( OA.long "skip-migrations"
                <> OA.metavar "ENV"
                <> OA.help "Skip migrations for an environment (repeatable)"
            )

signingKeyFileOpt :: OA.Parser (Maybe Text)
signingKeyFileOpt =
    OA.optional . fmap T.pack $
        OA.strOption
            ( OA.long "signing-key-file"
                <> OA.metavar "PATH"
                <> OA.help "Path to Nix signing secret key (defaults to HOSTENV_SIGNING_KEY_FILE or secrets/signing/secret.key)"
            )

remoteBuildOpt :: OA.Parser Bool
remoteBuildOpt =
    OA.switch
        ( OA.long "remote-build"
            <> OA.help "Force deploy-rs remote builds for all targets in this run"
        )

skipVerificationOpt :: OA.Parser Bool
skipVerificationOpt =
    OA.switch
        ( OA.long "skip-verification"
            <> OA.help "Skip post-deploy verification checks"
        )

ignoreMigrationErrorsOpt :: OA.Parser Bool
ignoreMigrationErrorsOpt =
    OA.switch
        ( OA.long "ignore-migration-errors"
            <> OA.help "Continue deployment even if migration steps fail (may deploy with stale data)"
        )

migrationSourceOpt :: OA.Parser [Text]
migrationSourceOpt =
    OA.many . fmap T.pack $
        OA.strOption
            ( OA.long "migration-source"
                <> OA.metavar "ENV=NODE"
                <> OA.help "Force migration source node for an environment (repeatable)"
            )

cliParser :: OA.Parser CLI
cliParser =
    CLI
        <$> OA.hsubparser
            ( OA.command "plan" (OA.info (CmdPlan <$> dryRunOpt) (OA.progDesc "Generate plan.json, state.json, and flake.nix"))
                <> OA.command "dns-gate" (OA.info (CmdDnsGate <$> nodeOpt <*> tokenOpt <*> zoneOpt <*> withDnsUpdateOpt <*> dryRunOpt) (OA.progDesc "Disable ACME/forceSSL for vhosts not pointing at node; add --with-dns-update to upsert Cloudflare records"))
                <> OA.command "deploy" (OA.info (CmdDeploy <$> nodeOpt <*> signingKeyFileOpt <*> remoteBuildOpt <*> skipVerificationOpt <*> skipMigrationsOpt <*> migrationSourceOpt <*> ignoreMigrationErrorsOpt <*> dryRunOpt) (OA.progDesc "Deploy via deploy-rs"))
            )

cliOpts :: OA.ParserInfo CLI
cliOpts =
    OA.info
        (cliParser OA.<**> OA.helper)
        ( OA.fullDesc
            <> OA.header "hostenv-provider"
        )

-- -------- DNS helpers (dig) --------
stripDot :: Text -> Text
stripDot = T.dropWhileEnd (== '.')

normalizeDnsName :: Text -> Text
normalizeDnsName = T.toLower . stripDot . T.strip

{- | Cache DNS discovery done while checking whether hostnames resolve to the
expected host.

These checks do more than ask the local resolver for one record. For each
hostname, the code first looks for the authoritative nameservers for that
hostname, then asks those nameservers for CNAME, A, or AAAA records. A single
dns-gate run can ask the same questions repeatedly while comparing many
vhosts, so this value keeps the expensive discovery results for the duration
of that run.

This is intentionally a short-lived cache. Command-level callers such as
dns-gate create one 'DnsLookupCache' near the start of the command and pass
it through every DNS comparison and propagation recheck in that command.
This is not a general DNS cache and it does not persist answers between
commands. It also does not cache CNAME, A, or AAAA answers, so propagation
rechecks still ask nameservers for current record data. The first map stores
the authoritative nameservers selected for a full hostname. The second map
stores NS records found for zone names while walking up a hostname.
-}
data DnsLookupCache
    = DnsLookupCache
        (IORef (M.Map Text [Text]))
        (IORef (M.Map Text [Text]))

newDnsLookupCache :: IO DnsLookupCache
newDnsLookupCache =
    DnsLookupCache
        <$> newIORef M.empty
        <*> newIORef M.empty

cachedLookup :: (Ord k) => IORef (M.Map k v) -> k -> IO v -> IO v
cachedLookup cacheRef key loadValue = do
    cache <- readIORef cacheRef
    case M.lookup key cache of
        Just value -> pure value
        Nothing -> do
            value <- loadValue
            modifyIORef' cacheRef (M.insert key value)
            pure value

tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

mapConcurrentlyIO :: (a -> IO b) -> [a] -> IO [Either SomeException b]
mapConcurrentlyIO action values = do
    resultVars <- forM values $ \value -> do
        resultVar <- newEmptyMVar
        _ <- forkIO $ tryAny (action value) >>= putMVar resultVar
        pure resultVar
    forM resultVars takeMVar

digRRRaw :: Maybe Text -> Text -> Text -> IO [Text]
digRRRaw mNameserver name rr = do
    let serverArgs = maybe [] (\nameserver -> ["@" <> T.unpack nameserver]) mNameserver
    let args = serverArgs <> ["+short", "+time=1", "+tries=1", T.unpack name, T.unpack rr]
    (code, out, _err) <- readProcessWithExitCode "dig" args ""
    case code of
        ExitFailure _ -> pure []
        ExitSuccess ->
            pure $
                filter (not . T.null) $
                    map (stripDot . T.toLower . T.strip . T.pack) $
                        lines out

zoneCandidates :: Text -> [Text]
zoneCandidates name =
    let labels = filter (not . T.null) (T.splitOn "." (normalizeDnsName name))
        labelCount = length labels
        indices =
            if labelCount < 2
                then []
                else [0 .. labelCount - 2]
     in map (\idx -> T.intercalate "." (drop idx labels)) indices

findAuthoritativeNameserversWith :: DnsLookupCache -> Text -> IO [Text]
findAuthoritativeNameserversWith cache@(DnsLookupCache authoritativeCache _) name =
    cachedLookup authoritativeCache (normalizeDnsName name) (go (zoneCandidates name))
  where
    go [] = pure []
    go (candidate : rest) = do
        nameservers <- findZoneNameservers cache candidate
        if null nameservers
            then go rest
            else pure nameservers

findZoneNameservers :: DnsLookupCache -> Text -> IO [Text]
findZoneNameservers (DnsLookupCache _ zoneCache) zone =
    cachedLookup zoneCache (normalizeDnsName zone) (digRRRaw Nothing zone "NS")

digRRWith :: DnsLookupCache -> Text -> Text -> IO [Text]
digRRWith cache name rr = do
    authoritativeNameservers <- findAuthoritativeNameserversWith cache name
    case authoritativeNameservers of
        [] -> digRRRaw Nothing name rr
        nameservers -> do
            queryResults <- mapConcurrentlyIO (\nameserver -> digRRRaw (Just nameserver) name rr) nameservers
            let answersByNameserver = [answers | Right answers <- queryResults]
            let nonEmptyAnswers = filter (not . null) answersByNameserver
            if null nonEmptyAnswers
                then digRRRaw Nothing name rr
                else pure (S.toList (S.fromList (concat nonEmptyAnswers)))

digAddrsWith :: DnsLookupCache -> Text -> IO [Text]
digAddrsWith cache name = do
    a4 <- digRRWith cache name "A"
    a6 <- digRRWith cache name "AAAA"
    pure $ a4 ++ a6

dnsPointsToWith :: DnsLookupCache -> Text -> Text -> IO Bool
dnsPointsToWith cache vhost expectedHost = do
    let expectHostNorm = T.toLower expectedHost
    cn <- digRRWith cache vhost "CNAME"
    if expectHostNorm `elem` cn
        then pure True
        else do
            expIPs <- digAddrsWith cache expectedHost
            vhIPs <- digAddrsWith cache vhost
            pure $ not (null (expIPs `intersect` vhIPs))

-- -------- JSON helpers --------
lookupText :: KM.Key -> KM.KeyMap A.Value -> Maybe Text
lookupText k o = case KM.lookup k o of
    Just (A.String t) -> Just t
    _ -> Nothing

lookupObj :: KM.Key -> KM.KeyMap A.Value -> Maybe (KM.KeyMap A.Value)
lookupObj k o = case KM.lookup k o of
    Just (A.Object x) -> Just x
    _ -> Nothing

lookupInt :: KM.Key -> KM.KeyMap A.Value -> Maybe Integer
lookupInt k o = case KM.lookup k o of
    Just (A.Number n) -> case floatingOrInteger n of
        Right i -> Just i
        Left (_ :: Double) -> Nothing
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
                    printProviderErrLine ("hostenv-provider: warning: failed to render diff for " <> path <> " (exit " <> T.pack (show c) <> ")")
                    when (not (null err)) $
                        printProviderErrLine ("hostenv-provider: diff stderr: " <> T.pack err)
                    pure True

printDiffAgainstFile :: Text -> BL.ByteString -> IO Bool
printDiffAgainstFile path proposedPretty = do
    pathExists <- Dir.doesFileExist (T.unpack path)
    if not pathExists
        then do
            printProviderLine ("hostenv-provider: dry-run: " <> path <> " does not exist; generated content would be:")
            BLC.putStr proposedPretty
            pure True
        else do
            currentRaw <- BL.readFile (T.unpack path)
            currentPretty <- prettyJson currentRaw
            if currentPretty == proposedPretty
                then do
                    printProviderLine ("hostenv-provider: dry-run: no changes for " <> path)
                    pure False
                else printUnifiedDiff path currentPretty proposedPretty

-- -------- Migration helpers --------
data EnvInfo = EnvInfo
    { userName :: Text
    , node :: Text
    , migrateBackups :: [Text]
    , runtimeDir :: Text
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
        node <- o .: "node"
        migrateBackups <- o .:? "migrations" .!= []
        uid <- o .: "uid"
        pure $
            EnvInfo
                { userName = userName
                , node = node
                , migrateBackups = migrateBackups
                , runtimeDir = runtimeDir
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
    let host' = T.toLower (stripDot host)
        zone' = T.toLower (stripDot zone)
     in host' == zone' || T.isSuffixOf ("." <> zone') host'

type DnsGateKey = (Text, Text)

data DnsUpsertEligibility = UpsertEligible | UpsertIneligible Text

data DnsUpsertOutcome
    = UpsertPlanned
    | UpsertSucceeded
    | UpsertFailed Text
    | UpsertUnavailable Text

data DnsGateMismatch = DnsGateMismatch
    { dgmItem :: DnsGateItem
    , dgmOutcome :: DnsUpsertOutcome
    }

dnsGateKey :: DnsGateItem -> DnsGateKey
dnsGateKey item = (item.dgiDiscoveryHost, item.dgiExpectedHost)

uniqueDnsGateItems :: [DnsGateItem] -> [DnsGateItem]
uniqueDnsGateItems =
    reverse . fst . foldl step ([], S.empty)
  where
    step (acc, seen) item =
        let key = dnsGateKey item
         in if S.member key seen
                then (acc, seen)
                else (item : acc, S.insert key seen)

classifyUpsertEligibility :: Bool -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> DnsUpsertEligibility
classifyUpsertEligibility withDnsUpdate mToken mZoneId mZoneName vhName
    | not withDnsUpdate = UpsertIneligible "dns updates are disabled (use --with-dns-update)"
    | isNothing mToken = UpsertIneligible "Cloudflare token was not provided"
    | isNothing mZoneId = UpsertIneligible "Cloudflare zone was not provided"
    | isNothing mZoneName = UpsertIneligible "could not resolve Cloudflare zone name"
    | otherwise =
        case mZoneName of
            Just zoneName ->
                if isSubdomainOf vhName zoneName
                    then UpsertEligible
                    else UpsertIneligible ("host is outside Cloudflare zone " <> zoneName)
            Nothing -> UpsertIneligible "could not resolve Cloudflare zone name"

waitForDnsPropagation :: DnsLookupCache -> [DnsGateItem] -> IO (S.Set DnsGateKey, [DnsGateItem])
waitForDnsPropagation dnsCache items = do
    (resolved0, unresolved0) <- partitionByDns items
    go resolved0 unresolved0 (backoffDelays 1 30 600)
  where
    partitionByDns recs = do
        checks <- forM recs $ \item -> do
            ok <- dnsPointsToWith dnsCache item.dgiDiscoveryHost item.dgiExpectedHost
            pure (item, ok)
        pure
            ( [ item
              | (item, True) <- checks
              ]
            , [ item
              | (item, False) <- checks
              ]
            )
    go resolved unresolved _ | null unresolved = pure (S.fromList (map dnsGateKey resolved), [])
    go resolved unresolved [] = pure (S.fromList (map dnsGateKey resolved), unresolved)
    go resolved unresolved (delaySec : restDelays) = do
        printProviderLine
            ( "hostenv-provider: waiting "
                <> T.pack (show delaySec)
                <> "s before rechecking DNS propagation for "
                <> T.pack (show (length unresolved))
                <> " vhost(s)"
            )
        threadDelay (delaySec * 1000000)
        (resolvedNow, unresolvedNow) <- partitionByDns unresolved
        go (resolved <> resolvedNow) unresolvedNow restDelays

-- -------- DNS gate --------
runDnsGate :: Maybe Text -> Maybe Text -> Maybe Text -> Bool -> Bool -> IO ()
runDnsGate mNode mTok mZone withDnsUpdate dryRun = do
    dnsCache <- newDnsLookupCache
    let dest = "generated"
    let planPath = dest <> "/plan.json"
    planExists <- Sh.testfile (fromString (T.unpack planPath))
    when (not planExists) $ do
        BLC.putStrLn "plan.json not found; dns-gate noop"
        Sh.exitSuccess
    raw <- BL.readFile (T.unpack planPath)
    case A.eitherDecode' raw of
        Left err -> error err
        Right (plan :: KM.KeyMap A.Value) -> do
            let hostenvHostname = fromMaybe "" (lookupText (K.fromString "hostenvHostname") plan)
            let cfPlan = lookupObj (K.fromString "cloudflare") plan
            let envsAll = fromMaybe KM.empty (lookupObj (K.fromString "environments") plan)
            let envs = filterEnvironmentsByNode mNode envsAll
            mCfToken <- case mTok of
                Just t -> pure (Just t)
                Nothing -> case cfPlan >>= lookupText (K.fromString "apiTokenFile") of
                    Just path -> Just . T.pack <$> readFileTrim (T.unpack path)
                    Nothing -> fmap T.pack <$> Env.lookupEnv "CF_API_TOKEN"
            mCfZone <- case mZone of
                Just z -> pure (Just z)
                Nothing -> case cfPlan >>= lookupText (K.fromString "zoneId") of
                    Just z -> pure (Just z)
                    Nothing -> fmap T.pack <$> Env.lookupEnv "CF_ZONE_ID"
            mCfZoneName <- case (mCfToken, mCfZone) of
                (Just t, Just z) -> cfZoneName t z
                _ -> pure Nothing
            let hasCF = isJustPair mCfToken mCfZone
            when (withDnsUpdate && not hasCF) $
                printProviderErrLine $
                    "hostenv-provider: warning: --with-dns-update requested but Cloudflare credentials are missing (set both --cf-token/CF_API_TOKEN and --cf-zone/CF_ZONE_ID). "
                        <> "Continuing in check-only mode without DNS updates."

            let items = collectDnsGateItems hostenvHostname envs
            checked <- forM items $ \item -> do
                ok <- dnsPointsToWith dnsCache item.dgiDiscoveryHost item.dgiExpectedHost
                pure (item, ok)

            let mismatched =
                    [ item
                    | (item, False) <- checked
                    ]

            (mismatchOutcomesRev, cfDryRunCallsRev, _seenUpserts) <- foldlM (processMismatch mCfToken mCfZone mCfZoneName withDnsUpdate dryRun) ([], [], M.empty) mismatched
            let mismatchOutcomes = reverse mismatchOutcomesRev
            let cfDryRunCalls = reverse cfDryRunCallsRev

            let upsertedItems =
                    uniqueDnsGateItems
                        [ mismatch.dgmItem
                        | mismatch <- mismatchOutcomes
                        , case mismatch.dgmOutcome of
                            UpsertSucceeded -> True
                            _ -> False
                        ]

            when (not dryRun && not (null upsertedItems)) $
                printProviderLine
                    ( "hostenv-provider: waiting for DNS propagation for "
                        <> T.pack (show (length upsertedItems))
                        <> " vhost(s) with exponential backoff (max 30s, total 10m)"
                    )

            (propagatedKeys, timedOutItems) <-
                if dryRun
                    then pure (S.empty, [])
                    else waitForDnsPropagation dnsCache upsertedItems

            when dryRun $
                when withDnsUpdate $
                    printProviderLine
                        "hostenv-provider: dry-run: propagation waiting is skipped; real runs wait up to 10 minutes before deciding ACME/SSL changes"

            forM_ timedOutItems $ \item ->
                printProviderErrLine
                    ( "hostenv-provider: warning: DNS did not propagate within 10 minutes for "
                        <> item.dgiDiscoveryHost
                        <> " -> "
                        <> item.dgiExpectedHost
                        <> " (while gating "
                        <> item.dgiVhostName
                        <> ")"
                    )

            let shouldDisable mismatch =
                    case mismatch.dgmOutcome of
                        UpsertPlanned -> False
                        UpsertSucceeded -> S.notMember (dnsGateKey mismatch.dgmItem) propagatedKeys
                        UpsertFailed _ -> True
                        UpsertUnavailable _ -> True

            let disableTargets =
                    [ mismatch
                    | mismatch <- mismatchOutcomes
                    , shouldDisable mismatch
                    ]

            forM_ disableTargets $ \mismatch ->
                case mismatch.dgmOutcome of
                    UpsertUnavailable reason ->
                        printProviderErrLine
                            ( "hostenv-provider: warning: disabling ACME/forceSSL for "
                                <> mismatch.dgmItem.dgiVhostName
                                <> " because DNS host "
                                <> mismatch.dgmItem.dgiDiscoveryHost
                                <> " does not point to "
                                <> mismatch.dgmItem.dgiExpectedHost
                                <> " and remediation is unavailable ("
                                <> reason
                                <> ")"
                            )
                    UpsertFailed reason ->
                        printProviderErrLine
                            ( "hostenv-provider: warning: disabling ACME/forceSSL for "
                                <> mismatch.dgmItem.dgiVhostName
                                <> " because Cloudflare upsert failed ("
                                <> reason
                                <> ")"
                            )
                    UpsertSucceeded ->
                        printProviderErrLine
                            ( "hostenv-provider: warning: disabling ACME/forceSSL for "
                                <> mismatch.dgmItem.dgiVhostName
                                <> " because DNS propagation for host "
                                <> mismatch.dgmItem.dgiDiscoveryHost
                                <> " did not complete in time"
                            )
                    UpsertPlanned -> pure ()

            let applyDisable planAcc mismatch =
                    let item = mismatch.dgmItem
                        plan1 = disableLetsEncryptPaths item.dgiEnvName item.dgiVhostName planAcc
                     in disableAcmeOnNode item.dgiNodeName item.dgiVhostName plan1

            let plan' = foldl applyDisable plan disableTargets
            planPretty <- prettyJson (A.encode plan')
            if dryRun
                then do
                    _ <- printDiffAgainstFile planPath planPretty
                    when withDnsUpdate $
                        if null cfDryRunCalls
                            then printProviderLine "hostenv-provider: dry-run: no Cloudflare DNS API calls would be made"
                            else do
                                printProviderLine "hostenv-provider: dry-run: Cloudflare DNS API calls that would be made:"
                                mapM_ (printProviderLine . ("hostenv-provider:   " <>)) cfDryRunCalls
                    printProviderLine "hostenv-provider: dry-run: generated/plan.json was not modified"
                else do
                    existingPretty <- prettyJson raw
                    if existingPretty == planPretty
                        then printProviderLine "hostenv-provider: dns-gate made no plan changes"
                        else do
                            let tmpPath = dest <> "/plan.json.tmp"
                            BL.writeFile (T.unpack tmpPath) planPretty
                            Sh.mv (fromString (T.unpack tmpPath)) (fromString (T.unpack planPath))
                            BLC.putStrLn "✅ dns-gate updated plan.json"
  where
    isJustPair (Just _) (Just _) = True
    isJustPair _ _ = False
    readFileTrim p = T.unpack . T.strip . T.pack <$> readFile p
    foldlM f z [] = pure z
    foldlM f z (x : xs) = f z x >>= \z' -> foldlM f z' xs
    processMismatch mCfToken mCfZone mCfZoneName withDnsUpdate dryRun (outcomes, cfOps, seenUpserts) item =
        let key = dnsGateKey item
         in case M.lookup key seenUpserts of
                Just cachedOutcome ->
                    pure
                        ( DnsGateMismatch item cachedOutcome : outcomes
                        , cfOps
                        , seenUpserts
                        )
                Nothing ->
                    case classifyUpsertEligibility withDnsUpdate mCfToken mCfZone mCfZoneName item.dgiDiscoveryHost of
                        UpsertIneligible reason ->
                            let outcome = UpsertUnavailable reason
                             in pure
                                    ( DnsGateMismatch item outcome : outcomes
                                    , cfOps
                                    , M.insert key outcome seenUpserts
                                    )
                        UpsertEligible ->
                            case (mCfToken, mCfZone) of
                                (Just token, Just zoneId) ->
                                    if dryRun
                                        then
                                            let outcome = UpsertPlanned
                                             in pure
                                                    ( DnsGateMismatch item outcome : outcomes
                                                    , ("upsert CNAME " <> item.dgiDiscoveryHost <> " -> " <> item.dgiExpectedHost <> " in zone " <> zoneId) : cfOps
                                                    , M.insert key outcome seenUpserts
                                                    )
                                        else do
                                            printProviderLine
                                                ( "hostenv-provider: upserting Cloudflare CNAME "
                                                    <> item.dgiDiscoveryHost
                                                    <> " -> "
                                                    <> item.dgiExpectedHost
                                                )
                                            upsertResult <- cfUpsertCname token zoneId item.dgiDiscoveryHost item.dgiExpectedHost
                                            case upsertResult of
                                                Right () ->
                                                    let outcome = UpsertSucceeded
                                                     in pure
                                                            ( DnsGateMismatch item outcome : outcomes
                                                            , cfOps
                                                            , M.insert key outcome seenUpserts
                                                            )
                                                Left err ->
                                                    let outcome = UpsertFailed err
                                                     in pure
                                                            ( DnsGateMismatch item outcome : outcomes
                                                            , cfOps
                                                            , M.insert key outcome seenUpserts
                                                            )
                                _ ->
                                    let outcome = UpsertUnavailable "Cloudflare credentials are missing"
                                     in pure
                                            ( DnsGateMismatch item outcome : outcomes
                                            , cfOps
                                            , M.insert key outcome seenUpserts
                                            )

runPlan :: Bool -> IO ()
runPlan dryRun = do
    let dest = "generated" :: Text
    let planDest = dest <> "/plan.json"
    let stateDest = dest <> "/state.json"
    let flakeDest = dest <> "/flake.nix"

    unless dryRun $ do
        Sh.mktree (fromString (T.unpack dest))
        stateExists <- Sh.testfile (fromString (T.unpack stateDest))
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
            _ <- printDiffAgainstFile planDest planPretty
            printProviderLine "hostenv-provider: dry-run: generated/plan.json was not modified"
        else do
            stateSource <- nixBuildPath (planAttrBase <> ".state")
            flakeSource <- nixBuildPath (planAttrBase <> ".flake")

            BL.writeFile (T.unpack planDest) planPretty

            stateRaw <- BL.readFile (T.unpack stateSource)
            BL.writeFile (T.unpack stateDest) stateRaw

            flakeRaw <- BL.readFile (T.unpack flakeSource)
            BL.writeFile (T.unpack flakeDest) flakeRaw

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
                    then error "hostenv-provider: failed to derive public signing key (empty output)"
                    else pure pub
        ExitFailure _ ->
            error (T.unpack (localCommandFailure "hostenv-provider: failed to derive public signing key" ["nix", "key", "convert-secret-to-public"] code (T.pack out) (T.pack err)))

chmodPath :: Text -> Text -> IO ()
chmodPath mode path = do
    (code, out, err) <- readProcessWithExitCode "chmod" [T.unpack mode, T.unpack path] ""
    case code of
        ExitSuccess -> pure ()
        ExitFailure _ ->
            error (T.unpack (localCommandFailure "hostenv-provider: failed to set file permissions" ["chmod", mode, path] code (T.pack out) (T.pack err)))

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
                error ("hostenv-provider: signing key exists but is empty: " <> keyPathS)
            pub <- convertSecretToPublic secret
            Dir.createDirectoryIfMissing True keyDirS
            sidecarRes <- try (writeFile pubPathS (T.unpack pub <> "\n") >> chmodPath "0644" pubPath) :: IO (Either SomeException ())
            case sidecarRes of
                Left err ->
                    printProviderLine ("hostenv-provider: warning: could not update public key sidecar at " <> pubPath <> ": " <> T.pack (displayException err))
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
                    error (T.unpack (localCommandFailure "hostenv-provider: failed to generate signing key" ("nix" : generateArgs) genCode (T.pack genOut) (T.pack genErr)))
                ExitSuccess -> do
                    let secret = T.strip (T.pack genOut)
                    when (T.null secret) $
                        error "hostenv-provider: generated signing key is empty"
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
            printProviderLine (localCommandFailure "hostenv-provider: failed to evaluate deployment target for signing" ("nix" : evalArgs) evalCode (T.pack evalOut) (T.pack evalErr))
            pure (ExitFailure 1)
        ExitSuccess -> do
            let outputPath = T.strip (T.pack evalOut)
            if T.null outputPath
                then do
                    printProviderLine ("hostenv-provider: no output path produced while evaluating " <> target)
                    pure (ExitFailure 1)
                else do
                    let buildArgs =
                            [ "build"
                            , "--no-link"
                            , "--print-build-logs"
                            , "--print-out-paths"
                            , installable
                            ]
                    printProviderLine ("hostenv-provider: running nix " <> T.unwords buildArgs)
                    buildCode <- Sh.proc "nix" buildArgs Sh.empty
                    case buildCode of
                        ExitFailure code -> do
                            printProviderLine ("hostenv-provider: failed to realise deployment target for signing " <> target <> " (exit " <> T.pack (show code) <> ")")
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
                            printProviderLine ("hostenv-provider: signing " <> target)
                            Sh.proc "nix" args Sh.empty

printProviderLine :: Text -> IO ()
printProviderLine line =
    BLC.putStrLn (BLC.pack (T.unpack line))

printProviderErrLine :: Text -> IO ()
printProviderErrLine line =
    BLC.hPutStrLn stderr (BLC.pack (T.unpack line))

printProviderLines :: [Text] -> IO ()
printProviderLines =
    mapM_ (printProviderLine . ("hostenv-provider: " <>))

printRemediationBlock :: [Text] -> IO ()
printRemediationBlock =
    mapM_ (printProviderLine . ("hostenv-provider:   " <>))

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

planDeployUser :: KM.KeyMap A.Value -> Text
planDeployUser plan =
    fromMaybe "deploy" (lookupText (K.fromString "deployUser") plan)

planTrustedPublicKeys :: KM.KeyMap A.Value -> [Text]
planTrustedPublicKeys plan =
    case lookupObj (K.fromString "nixSigning") plan of
        Just signingObj -> lookupTextList (K.fromString "trustedPublicKeys") signingObj
        Nothing -> []

planNodeRemoteBuild :: KM.KeyMap A.Value -> KM.KeyMap A.Value
planNodeRemoteBuild plan =
    fromMaybe KM.empty (lookupObj (K.fromString "nodeRemoteBuild") plan)

planSystemTargetNodes :: KM.KeyMap A.Value -> Maybe Text -> [Text]
planSystemTargetNodes plan mNode =
    let nodeNames =
            maybe
                []
                (map K.toText . KM.keys)
                (lookupObj (K.fromString "nodes") plan)
     in case mNode of
            Nothing -> nodeNames
            Just nodeName -> filter (== nodeName) nodeNames

planConnectionNodes :: KM.KeyMap A.Value -> [Text]
planConnectionNodes plan =
    maybe
        []
        (map K.toText . KM.keys)
        (lookupObj (K.fromString "nodeConnections") plan)

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

readNodeUsers ::
    Text ->
    (Text -> NodeConnection) ->
    Text ->
    IO (Either Text (Text, M.Map Text Integer))
readNodeUsers deployUser nodeConnection nodeName = do
    let target = mkSshTarget deployUser (nodeConnection nodeName)
    (code, out, err) <- runRemoteOutput target ["getent", "passwd"]
    case code of
        ExitSuccess ->
            pure (Right (nodeName, EnvironmentState.parsePasswdUsers out))
        ExitFailure exitCode ->
            pure
                ( Left
                    ( "failed to read passwd database on "
                        <> nodeName
                        <> " (exit "
                        <> T.pack (show exitCode)
                        <> "): "
                        <> T.strip err
                    )
                )

cleanupManagedUsersOnNode ::
    Bool ->
    Text ->
    (Text -> NodeConnection) ->
    M.Map Text Text ->
    M.Map Text Integer ->
    KM.KeyMap A.Value ->
    Text ->
    IO (Either Text ())
cleanupManagedUsersOnNode allowMovedCleanup deployUser nodeConnection desiredNodes observedUsers state nodeName = do
    let target = mkSshTarget deployUser (nodeConnection nodeName)
    let uidMismatches =
            EnvironmentState.managedUserUidMismatches
                nodeName
                desiredNodes
                observedUsers
                state
    let retiredUsers =
            EnvironmentState.managedUsersToRetire
                nodeName
                desiredNodes
                observedUsers
                state
    let movedUsers =
            [ userName
            | (userName, _) <- retiredUsers
            , M.member userName desiredNodes
            ]
    if not (null uidMismatches)
        then
            pure
                ( Left
                    ( "Hostenv-managed user UID mismatch on "
                        <> nodeName
                        <> ": "
                        <> T.intercalate
                            ", "
                            [ userName
                                <> " observed="
                                <> T.pack (show observedUid)
                                <> " expected="
                                <> T.pack (show expectedUid)
                            | (userName, expectedUid, observedUid) <- uidMismatches
                            ]
                        <> ". Refusing system deployment until the account drift is resolved."
                    )
                )
        else if not allowMovedCleanup && not (null movedUsers)
            then
                pure
                    ( Left
                        ( "node-filtered deployment would retire moved environment user(s) from "
                            <> nodeName
                            <> " before their destination is deployed: "
                            <> T.intercalate ", " movedUsers
                            <> ". Run an unfiltered deploy to migrate and retire them safely."
                        )
                    )
            else do
            cleanupResults <-
                forM retiredUsers $ \(userName, uid) -> do
                    let lingerPath = "/var/lib/systemd/linger/" <> userName
                    let unit = "user@" <> T.pack (show uid) <> ".service"
                    let cleanupCmd =
                            "set -euo pipefail; "
                                <> "if getent passwd "
                                <> shellEscape userName
                                <> " >/dev/null; then "
                                <> "sudo loginctl disable-linger "
                                <> shellEscape userName
                                <> " || sudo rm -f "
                                <> shellEscape lingerPath
                                <> "; else sudo rm -f "
                                <> shellEscape lingerPath
                                <> "; fi; "
                                <> "if systemctl is-active --quiet "
                                <> shellEscape unit
                                <> "; then sudo systemctl stop "
                                <> shellEscape unit
                                <> "; fi"
                    printProviderLine ("hostenv-provider: retiring Hostenv user " <> userName <> " from " <> nodeName)
                    code <- runRemote target ["bash", "-lc", cleanupCmd]
                    pure (userName, code)
            let failures = [(name, code) | (name, code) <- cleanupResults, code /= ExitSuccess]
            if null failures
                then pure (Right ())
                else
                    pure
                        ( Left
                            ( "failed to retire Hostenv user(s) on "
                                <> nodeName
                                <> ": "
                                <> T.intercalate ", " (map fst failures)
                            )
                        )

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
                                    ( "hostenv: migrate backup unit "
                                        <> unitFor backupName
                                        <> " not found on "
                                        <> sourceHost
                                        <> "; falling back to "
                                        <> baseName
                                    )
                                pure baseName
                            else error ("migration backup unit missing: " <> T.unpack (unitFor backupName) <> " (fallback " <> T.unpack (unitFor baseName) <> " not found)")
                    Nothing -> error ("migration backup unit missing: " <> T.unpack (unitFor backupName))
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
        ExitFailure code -> error ("migration backup failed for " <> T.unpack envInfo.userName <> ":" <> T.unpack backupName <> " (exit " <> show code <> ")")

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
                            printProviderLine
                                ( "hostenv: warning: no tagged restic snapshot found for "
                                    <> effectiveName
                                    <> " on "
                                    <> sourceHost
                                    <> "; using latest untagged snapshot"
                                )
                            pure snap
                        Nothing -> error ("could not parse snapshot id for " <> T.unpack envInfo.userName <> ":" <> T.unpack backupName <> " (tagged or untagged)")
        else do
            printProviderLine ("hostenv: restic wrapper missing for " <> effectiveName <> " on " <> sourceHost <> "; reading snapshot id from journal")
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
                Nothing -> error ("could not parse snapshot id from journal for " <> T.unpack envInfo.userName <> ":" <> T.unpack backupName)

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
            printProviderLine ("hostenv-provider: removed pending restore plan for skipped environment " <> envInfo.userName)
        _ ->
            printProviderLine ("hostenv-provider: no pending restore plan for skipped environment " <> envInfo.userName)

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
        ExitFailure code -> error ("failed to create restore dir on " <> T.unpack deployTarget.targetUserHost <> " (exit " <> show code <> ")")

    fileExit <- runRemote deployTarget ["bash", "-lc", "sudo install -m 0600 /dev/null " <> restorePath <> " && sudo chown " <> ownerSpec <> ":" <> groupSpec <> " " <> restorePath]
    case fileExit of
        ExitSuccess -> pure ()
        ExitFailure code -> error ("failed to create restore plan file on " <> T.unpack deployTarget.targetUserHost <> " (exit " <> show code <> ")")

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
        ExitFailure code -> error ("failed to write restore plan for " <> T.unpack envInfo.userName <> " (exit " <> show code <> ")")

runDeploy :: Maybe Text -> Maybe Text -> Bool -> Bool -> [Text] -> [Text] -> Bool -> Bool -> IO ()
runDeploy mNode mSigningKeyPath forceRemoteBuild skipVerification skipMigrations migrationSourceSpecs ignoreMigrationErrors dryRun = do
    let planPath = "generated/plan.json"
    let statePath = "generated/state.json"
    planExists <- Sh.testfile (fromString (T.unpack planPath))
    when (not planExists) $ do
        BLC.putStrLn "plan.json not found; deploy aborted"
        Sh.exit (ExitFailure 1)

    raw <- BL.readFile (T.unpack planPath)
    case A.eitherDecode' raw of
        Left err -> error err
        Right (plan :: KM.KeyMap A.Value) -> do
            let hostenvHostname = case lookupText (K.fromString "hostenvHostname") plan of
                    Nothing -> error "hostenvHostname missing from plan.json"
                    Just hostname -> hostname
            let resolveNodeConnection = nodeConnectionFor plan hostenvHostname
            let envs = fromMaybe KM.empty (lookupObj (K.fromString "environments") plan)
            migrationSources <-
                forM migrationSourceSpecs $ \raw ->
                    case parseMigrationSource raw of
                        Just parsed -> pure parsed
                        Nothing -> error ("invalid --migration-source value '" <> T.unpack raw <> "' (expected ENV=NODE)")
            let duplicateOverrides = duplicateValues (map fst migrationSources)
            unless (null duplicateOverrides) $
                error ("duplicate --migration-source overrides for: " <> T.unpack (T.intercalate ", " duplicateOverrides))

            -- Gets the @EnvInfo@s and deployment verification specs from JSON.
            envRowsSub <- forM (KM.elems envs) $ \env -> case iparseEither parseJSON env of
                -- Using lists here (so the type becomes @[[(EnvInfo, Verify.EnvVerificationSpec)]]@) as
                -- they're easy to @concat@ later.
                Left err -> printProviderLine ("hostenv-provider: error reading from plan JSON at '" <> T.pack (show $ fst err) <> " - '" <> T.pack (snd err) <> "'") >> pure []
                Right envInfo -> do
                    verificationSpec <- case env of
                        A.Object envObj ->
                            case Verify.parseEnvVerificationSpec envObj of
                                Left parseErr -> do
                                    printProviderLine ("hostenv-provider: warning: invalid deploymentVerification for " <> envInfo.userName <> "; using defaults (" <> parseErr <> ")")
                                    pure Verify.defaultEnvVerificationSpec
                                Right spec -> pure spec
                        _ -> pure Verify.defaultEnvVerificationSpec
                    pure [(envInfo, verificationSpec)]

            let envRows = concat envRowsSub
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
                        planConnectionNodes plan
                            ++ planSystemTargetNodes plan Nothing
                            ++ map snd sourceHits

            -- Perform data migrations if the environment has moved node.
            case mNode of
                Nothing -> pure ()
                Just n -> printProviderLine ("hostenv-provider: deploy filtered to node " <> n)
            printProviderLine ("hostenv-provider: " <> T.pack (show (length envInfosFiltered)) <> " environment(s) considered")
            when (not (null skipHits)) $
                printProviderLine ("hostenv-provider: skipping migrations for: " <> T.intercalate ", " skipHits)
            when (not (null skipMisses)) $
                printProviderLine ("hostenv-provider: warning: skip-migrations targets not found: " <> T.intercalate ", " skipMisses)
            forM_ sourceHits $ \(envName, sourceNode) ->
                printProviderLine ("hostenv-provider: migration source override " <> envName <> " -> " <> sourceNode)
            when (not (null sourceMisses)) $
                printProviderLine ("hostenv-provider: warning: migration-source targets not found: " <> T.intercalate ", " sourceMisses)
            when ignoreMigrationErrors $
                printProviderLine "hostenv-provider: warning: migration errors will be ignored; deployments may proceed with stale data"

            -- System profiles come from plan.nodes, not plan.environments.
            -- A node may intentionally have no current environments while it
            -- receives one final system deployment to retire lingering users.
            let targetNodes = planSystemTargetNodes plan mNode
            stateRaw <- BL.readFile (T.unpack statePath)
            state <- case A.eitherDecode' stateRaw of
                Left err -> error ("failed to parse " <> T.unpack statePath <> ": " <> err)
                Right value -> pure (value :: KM.KeyMap A.Value)

            let deployArgs useCheckSigs useDryActivate deployArgM =
                    let remoteBuildArgs =
                            if forceRemoteBuild then ["--remote-build"] else []
                        targetArgs = case deployArgM of
                            Just dArg -> ["generated/.#" <> quoteDeployTarget dArg]
                            Nothing -> ["generated/"]
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
            let deployGuard res args = when (res /= ExitSuccess) $ printProviderLine ("hostenv-provider: deploying " <> T.unwords args <> " failed")

            when dryRun $ do
                printProviderLine "hostenv-provider: --dry-run enabled; skipping migrations, signing, and deploy preflight checks"
                let dryArgs = deployArgs False True
                systemDeployRes <-
                    forM targetNodes $ \nodeName -> do
                        let target = nodeName <> ".system"
                        let args = dryArgs (Just target)
                        printProviderLine ("hostenv-provider: running nix " <> T.unwords args)
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

                    printProviderLine ("hostenv-provider: running nix " <> T.unwords args)
                    case systemStatus of
                        Left err -> printProviderLine ("hostenv-provider: " <> err) >> pure (envName, ExitFailure 1)
                        Right ExitSuccess -> do
                            res <- Sh.proc "nix" args Sh.empty
                            deployGuard res args
                            pure (envName, res)

                let systemDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) systemDeployRes
                let environmentDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) envDeployRes
                let failures = systemDeploymentFailures || environmentDeploymentFailures
                when failures $ printProviderLine "hostenv-provider: dry-run deployment completed with errors"
                Sh.exitWith $ if failures then ExitFailure 1 else ExitSuccess

            let deployUser = planDeployUser plan
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
                            printProviderLine ("hostenv-provider: generated signing key at " <> keyInfo.secretKeyPath)
                            printProviderLine ("hostenv-provider: wrote corresponding public key to " <> keyInfo.publicKeyPath)
                        pure (Just keyInfo)

            flakeKeyStatus <- forM signingKeyInfo (detectFlakeKeyStatus . (.publicKey))

            forM_ signingKeyInfo $ \keyInfo -> do
                let keyStatus = fromMaybe (FlakeKeyUnknown "signing key flake status unavailable") flakeKeyStatus
                when (null trustedPublicKeys) $ do
                    printProviderLine "hostenv-provider: deployment aborted; provider.nixSigning.trustedPublicKeys is empty in generated/plan.json"
                    printProviderLines (localTrustSetupLines keyStatus keyInfo.publicKey)
                    Sh.exitWith (ExitFailure 1)
                when (keyInfo.publicKey `notElem` trustedPublicKeys) $ do
                    printProviderLine "hostenv-provider: deployment aborted; local signing key is not present in provider.nixSigning.trustedPublicKeys"
                    printProviderLine ("hostenv-provider: signing key public value: " <> keyInfo.publicKey)
                    printProviderLines (localTrustSetupLines keyStatus keyInfo.publicKey)
                    printProviderLine "hostenv-provider: alternatively, pass --signing-key-file with a key that already matches trustedPublicKeys."
                    Sh.exitWith (ExitFailure 1)

            when forceRemoteBuild $
                printProviderLine "hostenv-provider: --remote-build enabled; skipping local signing trust checks for all nodes"
            forM_ targetNodes $ \nodeName ->
                when (not forceRemoteBuild && not (S.member nodeName localPushSet)) $
                    printProviderLine ("hostenv-provider: node " <> nodeName <> " uses remoteBuild=true; skipping local signing trust check")

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
                    printProviderLine ("hostenv-provider: deploy preflight failed on node " <> failure.failureNode <> ": " <> failure.failureReason)
                    let remediationLines =
                            if failure.failureReason == Preflight.signingKeyNotTrustedReason
                                then case (signingKeyInfo, flakeKeyStatus) of
                                    (Just keyInfo, Just keyStatus) -> remoteNodeTrustLines keyStatus keyInfo.publicKey
                                    (Just keyInfo, Nothing) -> remoteNodeTrustLines (FlakeKeyUnknown "signing key flake status unavailable") keyInfo.publicKey
                                    _ -> failure.failureRemediation
                                else failure.failureRemediation
                    printProviderLine ("hostenv-provider: remediation for " <> failure.failureNode <> ":")
                    printRemediationBlock remediationLines
                printProviderLine "hostenv-provider: aborting deployment because one or more preflight checks failed"
                Sh.exitWith (ExitFailure 1)

            let migrationEnvInfos =
                    filter
                        (\envInfo -> envInfo.userName `notElem` skipMigrations && envInfo.migrateBackups /= [])
                        envInfosFiltered
            let observationNodes =
                    S.toList . S.fromList $
                        targetNodes
                            ++ if null migrationEnvInfos then [] else discoveryNodes
            observedResults <-
                forM observationNodes $
                    readNodeUsers deployUser resolveNodeConnection
            let observationErrors = [err | Left err <- observedResults]
            unless (null observationErrors) $ do
                forM_ observationErrors $
                    printProviderErrLine . ("hostenv-provider: error: " <>)
                Sh.exitWith (ExitFailure 1)
            let observedNodeUsers =
                    M.fromList [row | Right row <- observedResults]

            let skippedEnvInfos =
                    filter (\envInfo -> envInfo.userName `elem` skipHits) envInfosFiltered
            forM_ skippedEnvInfos $
                clearRestorePlan deployUser resolveNodeConnection

            migrationResolutions <-
                forM envInfosFiltered $ \envInfo ->
                    if envInfo.userName `elem` skipMigrations || envInfo.migrateBackups == []
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
                                Right (Just sourceNode) ->
                                    case sourceFor envInfo.userName of
                                        Just _ ->
                                            printProviderLine
                                                ("hostenv: migration source for " <> envInfo.userName <> " forced via --migration-source: " <> sourceNode)
                                        Nothing ->
                                            printProviderLine
                                                ("hostenv: migration source for " <> envInfo.userName <> " observed on node: " <> sourceNode)
                                _ -> pure ()
                            pure $ case resolution of
                                Left err -> Left err
                                Right (Just sourceNode) -> Right (Just (envInfo, sourceNode))
                                Right Nothing -> Right Nothing

            let migrationFatalErrors =
                    [ err
                    | Left err <- migrationResolutions
                    ]
            when (not (null migrationFatalErrors)) $ do
                forM_ migrationFatalErrors $
                    printProviderErrLine . ("hostenv-provider: error: " <>)
                Sh.exitWith (ExitFailure 1)

            let migrations =
                    [ migration
                    | Right (Just migration) <- migrationResolutions
                    ]

            if null migrations
                then printProviderLine "hostenv-provider: no migrations required"
                else do
                    printProviderLine ("hostenv-provider: migrations required for " <> T.pack (show (length migrations)) <> " environment(s)")
                    forM_ migrations $ \(envInfo, prevNode) -> do
                        let backups = T.intercalate ", " envInfo.migrateBackups
                        printProviderLine ("hostenv-provider: migrate backups for " <> envInfo.userName <> " from " <> prevNode <> " -> " <> envInfo.node <> " (" <> backups <> ")")
                    let runMigration (envInfo, prevNode) = do
                            snapshots <- forM envInfo.migrateBackups $ \backupName -> do
                                snap <- runMigrationBackup deployUser resolveNodeConnection envInfo prevNode backupName
                                pure (backupName, snap)
                            writeRestorePlan deployUser resolveNodeConnection envInfo prevNode snapshots
                            let snapshotPairs = map (\(name, sid) -> name <> "=" <> sid) snapshots
                            printProviderLine ("hostenv-provider: restore plan written for " <> envInfo.userName <> " (snapshots: " <> T.intercalate ", " snapshotPairs <> ")")
                    if ignoreMigrationErrors
                        then do
                            failures <- fmap catMaybes $
                                forM migrations $ \(envInfo, prevNode) -> do
                                    res <- try (runMigration (envInfo, prevNode)) :: IO (Either SomeException ())
                                    case res of
                                        Right _ -> pure Nothing
                                        Left err -> do
                                            printProviderLine ("hostenv-provider: warning: migration failed for " <> envInfo.userName <> ": " <> T.pack (displayException err))
                                            pure (Just (envInfo.userName, prevNode))
                            let unsafeFailures =
                                    filter
                                        (\(_, sourceNode) -> sourceNode `elem` targetNodes)
                                        failures
                            unless (null unsafeFailures) $ do
                                printProviderErrLine
                                    ( "hostenv-provider: error: cannot ignore migration failure while its source node is being deployed; "
                                        <> "that system deployment could remove the source account: "
                                        <> T.intercalate ", " [envName <> "@" <> sourceNode | (envName, sourceNode) <- unsafeFailures]
                                    )
                                Sh.exitWith (ExitFailure 1)
                            when (not (null failures)) $
                                printProviderLine
                                    ( "hostenv-provider: warning: ignored migration failures for "
                                        <> T.intercalate ", " [envName | (envName, _) <- failures]
                                    )
                        else
                            forM_ migrations runMigration

            cleanupResults <-
                forM targetNodes $ \nodeName ->
                    cleanupManagedUsersOnNode
                        (isNothing mNode)
                        deployUser
                        resolveNodeConnection
                        desiredNodesByUser
                        (M.findWithDefault M.empty nodeName observedNodeUsers)
                        state
                        nodeName
            let cleanupFailures = [err | Left err <- cleanupResults]
            unless (null cleanupFailures) $ do
                forM_ cleanupFailures $
                    printProviderErrLine . ("hostenv-provider: error: " <>)
                Sh.exitWith (ExitFailure 1)

            -- Perform deployment
            --
            -- Start with the system deployment, since deploy-rs tends to
            -- fail deployments where this is not run separately (if there are
            -- new user accounts/environments added to the server).

            -- `--skip-checks` used here as deploy-rs checks fail when the
            -- local and remote architectures differ. For example: when on an
            -- x86 machine deploying to an ARM server.
            -- @todo: we could add a `--skip-checks` parameter to this CLI
            -- and pass it through to deploy-rs.
            let deployArgs' = deployArgs True False

            -- System deployment of each node. Retains results, so we can
            -- cowardly refuse to deploy environments where the system deploy
            -- failed to complete.
            systemDeployRes <-
                forM targetNodes $ \nodeName -> do
                    let target = nodeName <> ".system"
                    let targetInstallable = deployProfilePathInstallable nodeName "system"
                    signRes <-
                        if S.member nodeName localPushSet
                            then case signingKeyInfo of
                                Just keyInfo -> signInstallable keyInfo targetInstallable target
                                Nothing -> do
                                    printProviderLine ("hostenv-provider: signing configuration missing for node " <> nodeName)
                                    pure (ExitFailure 1)
                            else pure ExitSuccess
                    if signRes /= ExitSuccess
                        then do
                            printProviderLine ("hostenv-provider: failed to sign deployment target " <> target)
                            pure (nodeName, signRes)
                        else do
                            let args = deployArgs' (Just target)
                            printProviderLine ("hostenv-provider: running nix " <> T.unwords args)
                            res <- Sh.proc "nix" args Sh.empty
                            deployGuard res args
                            pure (nodeName, res)

            -- Environments deployment for the node.
            envDeployRes <- forM (toNamed envInfosFiltered) $ \(envName, envInfo) -> do
                let target = envInfo.node <> "." <> envInfo.userName
                let targetInstallable = deployProfilePathInstallable envInfo.node envInfo.userName
                let args = deployArgs' (Just target)
                let systemStatus = case filter ((==) envInfo.node . fst) systemDeployRes of
                        [] -> Left "node not in system deployment list"
                        (_, ExitSuccess) : [] -> Right ExitSuccess
                        (_, code) : [] -> Left ("system deployment failed for node " <> envInfo.node <> " (exit " <> T.pack (show code) <> ")")
                        _moreThanOneNode -> Left "multiple matching nodes found in system deployment list"

                printProviderLine ("hostenv-provider: running nix " <> T.unwords args)
                case systemStatus of
                    Left err -> printProviderLine ("hostenv-provider: " <> err) >> pure (envName, ExitFailure 1)
                    Right ExitSuccess -> do
                        signRes <-
                            if S.member envInfo.node localPushSet
                                then case signingKeyInfo of
                                    Just keyInfo -> signInstallable keyInfo targetInstallable target
                                    Nothing -> do
                                        printProviderLine ("hostenv-provider: signing configuration missing for node " <> envInfo.node)
                                        pure (ExitFailure 1)
                                else pure ExitSuccess
                        if signRes /= ExitSuccess
                            then do
                                printProviderLine ("hostenv-provider: failed to sign deployment target " <> target)
                                pure (envName, signRes)
                            else do
                                res <- Sh.proc "nix" args Sh.empty
                                deployGuard res args
                                pure (envName, res)

            verificationFatalFailures <-
                if skipVerification
                    then do
                        printProviderLine "hostenv-provider: --skip-verification enabled; skipping post-deploy verification checks"
                        pure []
                    else do
                        let envInfoByName = toNamed envInfosFiltered
                        let statusSuffix mStatus =
                                case mStatus of
                                    Nothing -> ""
                                    Just status -> " (HTTP " <> T.pack (show status) <> ")"
                        fmap catMaybes $
                            forM envDeployRes $ \(envName, deployCode) ->
                                case deployCode of
                                    ExitFailure _ -> pure Nothing
                                    ExitSuccess ->
                                        case lookup envName envInfoByName of
                                            Nothing -> do
                                                printProviderLine ("hostenv-provider: warning: environment metadata missing for " <> envName <> "; skipping verification")
                                                pure Nothing
                                            Just envInfo -> do
                                                let verificationSpec = verificationSpecFor envName
                                                if not verificationSpec.evEnable
                                                    then pure Nothing
                                                    else
                                                        if null verificationSpec.evChecks
                                                            then pure Nothing
                                                            else do
                                                                let verificationHost = Verify.canonicalNodeHostname hostenvHostname envInfo.node
                                                                printProviderLine ("hostenv-provider: running deployment verification for " <> envName <> " via " <> verificationHost)
                                                                verificationRes <- try (Verify.runEnvVerification verificationHost verificationSpec) :: IO (Either SomeException [Verify.VerificationCheckResult])
                                                                case verificationRes of
                                                                    Left err -> do
                                                                        let message = "verification failed for " <> envName <> ": " <> T.pack (displayException err)
                                                                        if verificationSpec.evEnforce
                                                                            then printProviderErrLine ("hostenv-provider: error: " <> message) >> pure (Just envName)
                                                                            else printProviderLine ("hostenv-provider: warning: " <> message) >> pure Nothing
                                                                    Right checkResults -> do
                                                                        let failedChecks = filter (not . (.vcrPassed)) checkResults
                                                                        forM_ checkResults $ \checkResult ->
                                                                            if checkResult.vcrPassed
                                                                                then
                                                                                    printProviderLine
                                                                                        ( "hostenv-provider: verification check "
                                                                                            <> checkResult.vcrName
                                                                                            <> " passed for "
                                                                                            <> envName
                                                                                            <> statusSuffix checkResult.vcrHttpStatus
                                                                                        )
                                                                                else
                                                                                    printProviderLine
                                                                                        ( "hostenv-provider: warning: verification check "
                                                                                            <> checkResult.vcrName
                                                                                            <> " failed for "
                                                                                            <> envName
                                                                                            <> statusSuffix checkResult.vcrHttpStatus
                                                                                            <> " ("
                                                                                            <> T.intercalate "; " checkResult.vcrFailures
                                                                                            <> ")"
                                                                                        )
                                                                        if null failedChecks
                                                                            then pure Nothing
                                                                            else
                                                                                if verificationSpec.evEnforce
                                                                                    then pure (Just envName)
                                                                                    else do
                                                                                        printProviderLine ("hostenv-provider: warning: verification failures ignored for " <> envName <> " (deploymentVerification.enforce=false)")
                                                                                        pure Nothing

            let systemDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) systemDeployRes
            let environmentDeploymentFailures = any (\(_, code) -> code /= ExitSuccess) envDeployRes
            let deploymentFailures = systemDeploymentFailures || environmentDeploymentFailures
            let verificationFailures = not (null verificationFatalFailures)
            when deploymentFailures $ printProviderLine "hostenv-provider: deployment completed with errors"
            when verificationFailures $
                printProviderErrLine ("hostenv-provider: error: deployment verification failed for: " <> T.intercalate ", " verificationFatalFailures)
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
        CmdDnsGate mNode mTok mZone withDnsUpdate dryRun -> runDnsGate mNode mTok mZone withDnsUpdate dryRun
        CmdDeploy mNode mSigningKeyPath forceRemoteBuild skipVerification skipMigrations migrationSources ignoreMigrationErrors dryRun ->
            runDeploy mNode mSigningKeyPath forceRemoteBuild skipVerification skipMigrations migrationSources ignoreMigrationErrors dryRun
