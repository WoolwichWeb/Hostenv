{-# LANGUAGE OverloadedStrings #-}

import Data.IORef (modifyIORef', newIORef, readIORef)
import Hostenv.Provider.TlsReadiness
import System.Exit (ExitCode (..), exitFailure)

assert :: Bool -> String -> IO ()
assert ok message =
    if ok then pure () else putStrLn ("assertion failed: " <> message) >> exitFailure

main :: IO ()
main = do
    capturedArgs <- newIORef []
    ready <-
        trustedHttpsReadyWith
            (\args -> do
                modifyIORef' capturedArgs (<> [args])
                pure ExitSuccess
            )
            "www.example.test"
    assert ready "successful strict HTTPS curl should be ready"
    args <- concat <$> readIORef capturedArgs
    assert ("--insecure" `notElem` args) "trusted HTTPS must not disable certificate verification"
    assert ("--head" `elem` args) "readiness should avoid downloading the response body"
    assert ("https://www.example.test/" `elem` args) "readiness should check the public HTTPS hostname"

    attempts <- newIORef (0 :: Int)
    waits <- newIORef ([] :: [Int])
    remaining <-
        waitForTrustedHttpsWith
            (\seconds -> modifyIORef' waits (<> [seconds]))
            [1, 2, 4]
            (\_ -> do
                modifyIORef' attempts (+ 1)
                count <- readIORef attempts
                pure (count >= 3)
            )
            ["www.example.test"]
    assert (null remaining) "later successful certificate check should complete readiness"
    waitValues <- readIORef waits
    assert (waitValues == [1, 2]) "readiness should stop waiting immediately after success"

    neverReady <-
        waitForTrustedHttpsWith
            (const (pure ()))
            [1]
            (const (pure False))
            ["bad.example.test"]
    assert (neverReady == ["bad.example.test"]) "timeout should report hosts without trusted HTTPS"

    putStrLn "ok"
