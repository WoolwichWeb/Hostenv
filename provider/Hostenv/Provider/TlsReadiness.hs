{-# LANGUAGE ImportQualifiedPost #-}
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

trustedHttpsCurlArgs :: Text -> Text -> [String]
trustedHttpsCurlArgs publicHost destinationHost =
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
        , "--connect-to"
        , publicHost <> ":443:" <> destinationHost <> ":443"
        , "https://" <> publicHost <> "/"
        ]

trustedHttpsReadyWith :: ([String] -> IO ExitCode) -> Text -> Text -> IO Bool
trustedHttpsReadyWith runCurl publicHost destinationHost =
    (== ExitSuccess) <$> runCurl (trustedHttpsCurlArgs publicHost destinationHost)

trustedHttpsReady :: Text -> Text -> IO Bool
trustedHttpsReady publicHost destinationHost =
    trustedHttpsReadyWith
        (\args -> do
            (code, _out, _err) <- readProcessWithExitCode "curl" args ""
            pure code
        )
        publicHost
        destinationHost

waitForTrustedHttpsWith ::
    (Int -> IO ()) ->
    [Int] ->
    (Text -> Text -> IO Bool) ->
    [(Text, Text)] ->
    IO [(Text, Text)]
waitForTrustedHttpsWith wait delays isReady targets = do
    unresolved <- unresolvedTargets targets
    go unresolved delays
  where
    unresolvedTargets candidates = do
        checks <-
            mapM
                (\target@(publicHost, destinationHost) -> do
                    ready <- isReady publicHost destinationHost
                    pure (target, ready)
                )
                candidates
        pure [target | (target, False) <- checks]

    go [] _ = pure []
    go unresolved [] = pure unresolved
    go unresolved (delaySeconds : remainingDelays) = do
        wait delaySeconds
        unresolved' <- unresolvedTargets unresolved
        go unresolved' remainingDelays
