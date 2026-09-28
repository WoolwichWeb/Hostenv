{-# LANGUAGE ImportQualifiedPost #-}

module Hostenv.Provider.DnsObservationCache
    ( DnsObservationCache
    , cacheDnsObservation
    , newDnsObservationCache
    )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified as T

newtype DnsObservationCache a =
    DnsObservationCache (IORef (M.Map (Text, Text) a))

newDnsObservationCache :: IO (DnsObservationCache a)
newDnsObservationCache =
    DnsObservationCache <$> newIORef M.empty

cacheDnsObservation ::
    DnsObservationCache a ->
    (Text -> Text -> IO a) ->
    Text ->
    Text ->
    IO a
cacheDnsObservation (DnsObservationCache cacheRef) lookupRecord name rr = do
    let key = (normalizeDnsName name, T.toUpper (T.strip rr))
    cache <- readIORef cacheRef
    case M.lookup key cache of
        Just answers -> pure answers
        Nothing -> do
            answers <- lookupRecord name rr
            modifyIORef' cacheRef (M.insert key answers)
            pure answers

normalizeDnsName :: Text -> Text
normalizeDnsName =
    T.toLower . T.dropWhileEnd (== '.') . T.strip
