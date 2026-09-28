{-# LANGUAGE OverloadedStrings #-}

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Hostenv.Provider.DnsObservationCache
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

    phaseOne <- newDnsObservationCache
    first <- cacheDnsObservation phaseOne lookupRecord "WWW.Example.TEST." "a"
    second <- cacheDnsObservation phaseOne lookupRecord "www.example.test" "A"
    _ <- cacheDnsObservation phaseOne lookupRecord "www.example.test" "AAAA"

    assertEqual "cached answer" first second
    callsAfterPhaseOne <- readIORef callsRef
    assertEqual
        "same normalized name/type is queried once per phase"
        [("WWW.Example.TEST.", "a"), ("www.example.test", "AAAA")]
        callsAfterPhaseOne

    phaseTwo <- newDnsObservationCache
    _ <- cacheDnsObservation phaseTwo lookupRecord "www.example.test" "A"
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
    failurePhase <- newDnsObservationCache
    firstFailure <- cacheDnsObservation failurePhase failingLookup "broken.example.test" "A"
    secondFailure <- cacheDnsObservation failurePhase failingLookup "BROKEN.EXAMPLE.TEST." "a"
    assertEqual "failed lookup is cached within one observation phase" firstFailure secondFailure
    failureCalls <- readIORef failureCallsRef
    assertEqual "failed lookup runs once within one observation phase" 1 failureCalls

    nextFailurePhase <- newDnsObservationCache
    _ <- cacheDnsObservation nextFailurePhase failingLookup "broken.example.test" "A"
    retriedFailureCalls <- readIORef failureCallsRef
    assertEqual "new observation phase retries a failed lookup" 2 retriedFailureCalls

    putStrLn "ok"
