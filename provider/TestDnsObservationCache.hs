{-# LANGUAGE OverloadedStrings #-}

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Hostenv.Provider.Dns qualified as Dns
import System.Exit (exitFailure)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            putStrLn ("assertion failed (" <> label <> "): expected " <> show expected <> ", got " <> show actual)
            exitFailure

main :: IO ()
main = do
    callsRef <- newIORef ([] :: [(Text, Text)])
    let lookupRecord name rr = do
            modifyIORef' callsRef (<> [(name, rr)])
            pure [name <> "-" <> rr]

    phaseOne <- Dns.newObservationCache
    first <- Dns.cacheObservation phaseOne lookupRecord "WWW.Example.TEST." "a"
    second <- Dns.cacheObservation phaseOne lookupRecord "www.example.test" "A"
    _ <- Dns.cacheObservation phaseOne lookupRecord "www.example.test" "AAAA"

    assertEqual "cached answer" first second
    callsAfterPhaseOne <- readIORef callsRef
    assertEqual
        "same normalized name/type is queried once per phase"
        [("WWW.Example.TEST.", "a"), ("www.example.test", "AAAA")]
        callsAfterPhaseOne

    phaseTwo <- Dns.newObservationCache
    _ <- Dns.cacheObservation phaseTwo lookupRecord "www.example.test" "A"
    callsAfterPhaseTwo <- readIORef callsRef
    assertEqual
        "a new phase performs a fresh lookup"
        [ ("WWW.Example.TEST.", "a")
        , ("www.example.test", "AAAA")
        , ("www.example.test", "A")
        ]
        callsAfterPhaseTwo

    failureCallsRef <- newIORef (0 :: Int)
    let failingLookup _ _ = do
            modifyIORef' failureCallsRef (+ 1)
            pure (Left ("SERVFAIL" :: Text) :: Either Text [Text])
    failurePhase <- Dns.newObservationCache
    firstFailure <- Dns.cacheObservation failurePhase failingLookup "broken.example.test" "A"
    secondFailure <- Dns.cacheObservation failurePhase failingLookup "BROKEN.EXAMPLE.TEST." "a"
    assertEqual "failed lookup is cached within one observation phase" firstFailure secondFailure
    failureCalls <- readIORef failureCallsRef
    assertEqual "failed lookup runs once within one observation phase" 1 failureCalls

    nextFailurePhase <- Dns.newObservationCache
    _ <- Dns.cacheObservation nextFailurePhase failingLookup "broken.example.test" "A"
    retriedFailureCalls <- readIORef failureCallsRef
    assertEqual "new observation phase retries a failed lookup" 2 retriedFailureCalls

    putStrLn "ok"
