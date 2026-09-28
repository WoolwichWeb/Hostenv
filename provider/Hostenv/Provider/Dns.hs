{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- DNS observation for the provider. This module reports what DNS could be
-- observed, including typed failure reasons. Deployment policy stays in the
-- provider CLI: callers decide whether a failed observation is repairable,
-- retryable, or fatal at the current transaction boundary.
module Hostenv.Provider.Dns
    ( DnsLookupFailure
    , LookupCache
    , ObservationCache
    , cacheObservation
    , checkAuthoritativeTarget
    , newLookupCache
    , newObservationCache
    , normalizeName
    , pointsToObservedHost
    , queryRecursiveRecord
    , renderLookupFailure
    ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intersect)
import Data.Map.Strict qualified as M
import Data.Maybe (listToMaybe)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Hostenv.Provider.DnsTransition qualified as DnsTransition
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data DnsQueryFailureReason
    = DnsQueryExecutionFailure Text
    | DnsQueryExitFailure Int Text
    | DnsQueryResponseFailure Text
    | DnsQueryStatusMissing
    deriving (Eq, Show)

data DnsLookupFailure
    = DnsQueryFailed (Maybe Text) Text Text DnsQueryFailureReason
    | DnsAuthoritativeDiscoveryFailed Text Text DnsLookupFailure
    | DnsAuthoritativeNameserversNotFound Text
    | DnsAuthoritativeQueriesFailed Text Text [(Text, DnsLookupFailure)]
    | DnsUnexpectedLookupFailure Text
    deriving (Eq, Show)

renderLookupFailure :: DnsLookupFailure -> Text
renderLookupFailure = \case
    DnsQueryFailed mNameserver name rr reason ->
        "DNS "
            <> rr
            <> " lookup for "
            <> name
            <> maybe "" (" via " <>) mNameserver
            <> " failed: "
            <> renderQueryFailureReason reason
    DnsAuthoritativeDiscoveryFailed name candidate failure ->
        "authoritative nameserver discovery for "
            <> name
            <> " failed while checking "
            <> candidate
            <> ": "
            <> renderLookupFailure failure
    DnsAuthoritativeNameserversNotFound name ->
        "no authoritative nameservers could be found for " <> name
    DnsAuthoritativeQueriesFailed name rr failures ->
        "authoritative "
            <> rr
            <> " lookup for "
            <> name
            <> " failed: "
            <> T.intercalate
                "; "
                [ nameserver <> ": " <> renderLookupFailure failure
                | (nameserver, failure) <- failures
                ]
    DnsUnexpectedLookupFailure message ->
        "unexpected DNS lookup failure: " <> message

renderQueryFailureReason :: DnsQueryFailureReason -> Text
renderQueryFailureReason = \case
    DnsQueryExecutionFailure message -> "could not execute dig (" <> message <> ")"
    DnsQueryExitFailure code stderrText ->
        "dig exited "
            <> T.pack (show code)
            <> if T.null stderrText then "" else " (" <> stderrText <> ")"
    DnsQueryResponseFailure status -> "DNS server returned " <> status
    DnsQueryStatusMissing -> "dig returned no parseable DNS status"

{- | Cache successful DNS infrastructure discovery for the duration of a
command. Failed discovery is deliberately not cached so a later observation
phase can recover from a transient DNS failure.
-}
data LookupCache
    = LookupCache
        (IORef (M.Map Text [Text]))
        (IORef (M.Map Text [Text]))

newLookupCache :: IO LookupCache
newLookupCache =
    LookupCache
        <$> newIORef M.empty
        <*> newIORef M.empty

{- | Cache record observations for one logical DNS observation phase. Values
are generic so callers can cache the typed result of a DNS lookup rather than
losing the distinction between an empty answer and a failed lookup.
-}
newtype ObservationCache a =
    ObservationCache (IORef (M.Map (Text, Text) a))

newObservationCache :: IO (ObservationCache a)
newObservationCache =
    ObservationCache <$> newIORef M.empty

cacheObservation ::
    ObservationCache a ->
    (Text -> Text -> IO a) ->
    Text ->
    Text ->
    IO a
cacheObservation (ObservationCache cacheRef) lookupRecord name rr = do
    let key = (normalizeName name, T.toUpper (T.strip rr))
    cache <- readIORef cacheRef
    case M.lookup key cache of
        Just value -> pure value
        Nothing -> do
            value <- lookupRecord name rr
            modifyIORef' cacheRef (M.insert key value)
            pure value

cachedSuccessfulLookup ::
    (Ord k) =>
    IORef (M.Map k v) ->
    k ->
    IO (Either e v) ->
    IO (Either e v)
cachedSuccessfulLookup cacheRef key loadValue = do
    cache <- readIORef cacheRef
    case M.lookup key cache of
        Just value -> pure (Right value)
        Nothing ->
            loadValue >>= \case
                Left err -> pure (Left err)
                Right value -> do
                    modifyIORef' cacheRef (M.insert key value)
                    pure (Right value)

tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

mapConcurrentlyIO :: (a -> IO b) -> [a] -> IO [Either SomeException b]
mapConcurrentlyIO action values = do
    resultVars <- forM values $ \value -> do
        resultVar <- newEmptyMVar
        _ <- forkIO $ tryAny (action value) >>= putMVar resultVar
        pure resultVar
    forM resultVars takeMVar

normalizeName :: Text -> Text
normalizeName =
    T.toLower . T.dropWhileEnd (== '.') . T.strip

queryRecord ::
    Int ->
    Maybe Text ->
    Text ->
    Text ->
    IO (Either DnsLookupFailure [Text])
queryRecord timeoutSeconds mNameserver name rr = do
    let serverArgs = maybe [] (\nameserver -> ["@" <> T.unpack nameserver]) mNameserver
    let args =
            serverArgs
                <> [ "+time=" <> show timeoutSeconds
                   , "+tries=1"
                   , "+noall"
                   , "+comments"
                   , "+answer"
                   , T.unpack name
                   , T.unpack rr
                   ]
    result <- tryAny (readProcessWithExitCode "dig" args "")
    pure $
        case result of
            Left err ->
                Left
                    ( DnsQueryFailed
                        mNameserver
                        name
                        rr
                        (DnsQueryExecutionFailure (T.pack (displayException err)))
                    )
            Right (ExitFailure code, _out, err) ->
                Left
                    ( DnsQueryFailed
                        mNameserver
                        name
                        rr
                        (DnsQueryExitFailure code (T.strip (T.pack err)))
                    )
            Right (ExitSuccess, out, _err) ->
                let output = T.pack out
                    responseStatus =
                        listToMaybe
                            [ status
                            | line <- T.lines output
                            , let (_, suffix) = T.breakOn "status:" line
                            , not (T.null suffix)
                            , let statusText = T.strip (T.drop (T.length ("status:" :: Text)) suffix)
                            , let status = T.takeWhile (\c -> c /= ',' && c /= ' ' && c /= '\t') statusText
                            , not (T.null status)
                            ]
                    answers =
                        [ normalizeName target
                        | line <- T.lines output
                        , let stripped = T.strip line
                        , not (T.null stripped)
                        , not (";" `T.isPrefixOf` stripped)
                        , _owner : _ttl : _class : answerType : rdata <- [T.words stripped]
                        , T.toUpper answerType == T.toUpper rr
                        , target : _ <- [reverse rdata]
                        ]
                 in case responseStatus of
                        Just "NOERROR" -> Right answers
                        Just "NXDOMAIN" -> Right []
                        Just status ->
                            Left
                                ( DnsQueryFailed
                                    mNameserver
                                    name
                                    rr
                                    (DnsQueryResponseFailure status)
                                )
                        Nothing ->
                            Left
                                ( DnsQueryFailed
                                    mNameserver
                                    name
                                    rr
                                    DnsQueryStatusMissing
                                )

queryRecursiveRecord ::
    Int ->
    Text ->
    Text ->
    IO (Either DnsLookupFailure [Text])
queryRecursiveRecord timeoutSeconds name rr =
    queryRecord timeoutSeconds Nothing name rr

zoneCandidates :: Text -> [Text]
zoneCandidates name =
    let labels = filter (not . T.null) (T.splitOn "." (normalizeName name))
        labelCount = length labels
        indices =
            if labelCount < 2
                then []
                else [0 .. labelCount - 2]
     in map (\idx -> T.intercalate "." (drop idx labels)) indices

findZoneNameservers :: LookupCache -> Text -> IO (Either DnsLookupFailure [Text])
findZoneNameservers (LookupCache _ zoneCache) zone =
    cachedSuccessfulLookup
        zoneCache
        (normalizeName zone)
        (queryRecursiveRecord 1 zone "NS")

findAuthoritativeNameservers :: LookupCache -> Text -> IO (Either DnsLookupFailure [Text])
findAuthoritativeNameservers cache@(LookupCache authoritativeCache _) name =
    cachedSuccessfulLookup authoritativeCache (normalizeName name) (go (zoneCandidates name))
  where
    go [] =
        pure (Left (DnsAuthoritativeNameserversNotFound name))
    go (candidate : rest) =
        findZoneNameservers cache candidate >>= \case
            Right [] -> go rest
            Right nameservers -> pure (Right nameservers)
            Left err ->
                pure
                    ( Left
                        (DnsAuthoritativeDiscoveryFailed name candidate err)
                    )

concurrentDnsResults ::
    [Text] ->
    (Text -> IO (Either DnsLookupFailure a)) ->
    IO [(Text, Either DnsLookupFailure a)]
concurrentDnsResults nameservers action = do
    rawResults <- mapConcurrentlyIO action nameservers
    pure $
        zipWith
            (\nameserver result ->
                ( nameserver
                , case result of
                    Left err ->
                        Left
                            ( DnsUnexpectedLookupFailure
                                ( "query worker for "
                                    <> nameserver
                                    <> " failed: "
                                    <> T.pack (displayException err)
                                )
                            )
                    Right value -> value
                )
            )
            nameservers
            rawResults

lookupAuthoritativeRecords ::
    LookupCache ->
    Text ->
    Text ->
    IO (Either DnsLookupFailure [Text])
lookupAuthoritativeRecords cache name rr =
    findAuthoritativeNameservers cache name >>= \case
        Left err -> pure (Left err)
        Right nameservers -> do
            queryResults <-
                concurrentDnsResults
                    nameservers
                    (\nameserver -> queryRecord 1 (Just nameserver) name rr)
            let failures =
                    [ (nameserver, err)
                    | (nameserver, Left err) <- queryResults
                    ]
            if null failures
                then
                    pure
                        ( Right
                            ( S.toList
                                ( S.fromList
                                    ( concat
                                        [ answers
                                        | (_, Right answers) <- queryResults
                                        ]
                                    )
                                )
                            )
                        )
                else pure (Left (DnsAuthoritativeQueriesFailed name rr failures))

queryDnsTargetAt ::
    Text ->
    Text ->
    IO (Either DnsLookupFailure ([Text], [Text]))
queryDnsTargetAt nameserver name =
    queryRecord 1 (Just nameserver) name "CNAME" >>= \case
        Left err -> pure (Left err)
        Right cnames
            | not (null cnames) -> pure (Right (cnames, []))
            | otherwise -> do
                aResult <- queryRecord 1 (Just nameserver) name "A"
                aaaaResult <- queryRecord 1 (Just nameserver) name "AAAA"
                pure $ (\a4 a6 -> ([], a4 ++ a6)) <$> aResult <*> aaaaResult

checkAuthoritativeTarget ::
    LookupCache ->
    Text ->
    Text ->
    IO (Either DnsLookupFailure Bool)
checkAuthoritativeTarget cache name expectedHost =
    findAuthoritativeNameservers cache name >>= \case
        Left err -> pure (Left err)
        Right nameservers -> do
            queryResults <-
                concurrentDnsResults
                    nameservers
                    (\nameserver -> queryDnsTargetAt nameserver name)
            let failures =
                    [ (nameserver, err)
                    | (nameserver, Left err) <- queryResults
                    ]
            if not (null failures)
                then pure (Left (DnsAuthoritativeQueriesFailed name "CNAME/A/AAAA" failures))
                else do
                    let answersByNameserver =
                            [ answers
                            | (_, Right answers) <- queryResults
                            ]
                    let needsExpectedAddresses =
                            any (null . fst) answersByNameserver
                    expectedAddressesResult <-
                        if needsExpectedAddresses
                            then do
                                aResult <- lookupAuthoritativeRecords cache expectedHost "A"
                                aaaaResult <- lookupAuthoritativeRecords cache expectedHost "AAAA"
                                pure $ (++) <$> aResult <*> aaaaResult
                            else pure (Right [])
                    pure $
                        DnsTransition.authoritativeDnsTargetConverged
                            expectedHost
                            <$> expectedAddressesResult
                            <*> pure answersByNameserver

lookupObservedRecord ::
    LookupCache ->
    ObservationCache (Either DnsLookupFailure [Text]) ->
    Text ->
    Text ->
    IO (Either DnsLookupFailure [Text])
lookupObservedRecord lookupCache observationCache =
    cacheObservation observationCache (lookupAuthoritativeRecords lookupCache)

lookupObservedAddresses ::
    LookupCache ->
    ObservationCache (Either DnsLookupFailure [Text]) ->
    Text ->
    IO (Either DnsLookupFailure [Text])
lookupObservedAddresses lookupCache observationCache name = do
    a4 <- lookupObservedRecord lookupCache observationCache name "A"
    a6 <- lookupObservedRecord lookupCache observationCache name "AAAA"
    pure $ (++) <$> a4 <*> a6

pointsToObservedHost ::
    LookupCache ->
    ObservationCache (Either DnsLookupFailure [Text]) ->
    Text ->
    Text ->
    IO (Either DnsLookupFailure Bool)
pointsToObservedHost lookupCache observationCache vhost expectedHost = do
    let expectedHostNormalized = normalizeName expectedHost
    lookupObservedRecord lookupCache observationCache vhost "CNAME" >>= \case
        Left err -> pure (Left err)
        Right cnames
            | expectedHostNormalized `elem` cnames -> pure (Right True)
            | otherwise -> do
                expectedAddresses <- lookupObservedAddresses lookupCache observationCache expectedHost
                vhostAddresses <- lookupObservedAddresses lookupCache observationCache vhost
                pure $
                    (\expected actual -> not (null (expected `intersect` actual)))
                        <$> expectedAddresses
                        <*> vhostAddresses
