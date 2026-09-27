{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.TlsReadiness
    ( trustedHttpsCurlArgs
    , trustedHttpsReady
    , trustedHttpsReadyWith
    , waitForTrustedHttpsWith
    ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

trustedHttpsCurlArgs :: Text -> [String]
trustedHttpsCurlArgs hostname =
    map T.unpack
        [ "--silent"
        , "--show-error"
        , "--head"
        , "--connect-timeout"
        , "5"
        , "--max-time"
        , "10"
        , "--output"
        , "/dev/null"
        , "--proto"
        , "=https"
        , "https://" <> hostname <> "/"
        ]

trustedHttpsReadyWith :: ([String] -> IO ExitCode) -> Text -> IO Bool
trustedHttpsReadyWith runCurl hostname =
    (== ExitSuccess) <$> runCurl (trustedHttpsCurlArgs hostname)

trustedHttpsReady :: Text -> IO Bool
trustedHttpsReady hostname =
    trustedHttpsReadyWith
        (\args -> do
            (code, _out, _err) <- readProcessWithExitCode "curl" args ""
            pure code
        )
        hostname

waitForTrustedHttpsWith ::
    (Int -> IO ()) ->
    [Int] ->
    (Text -> IO Bool) ->
    [Text] ->
    IO [Text]
waitForTrustedHttpsWith wait delays isReady hosts = do
    unresolved <- unresolvedHosts hosts
    go unresolved delays
  where
    unresolvedHosts candidates = do
        checks <-
            mapM
                (\host -> do
                    ready <- isReady host
                    pure (host, ready)
                )
                candidates
        pure [host | (host, False) <- checks]

    go [] _ = pure []
    go unresolved [] = pure unresolved
    go unresolved (delaySeconds : remainingDelays) = do
        wait delaySeconds
        unresolved' <- unresolvedHosts unresolved
        go unresolved' remainingDelays
