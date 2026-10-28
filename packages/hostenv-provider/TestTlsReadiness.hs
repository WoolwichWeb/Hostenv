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
            "node-a.hosting.test"
    assert ready "successful strict HTTPS curl should be ready"
    args <- concat <$> readIORef capturedArgs
    assert ("--insecure" `notElem` args) "trusted HTTPS must not disable certificate verification"
    assert ("--head" `elem` args) "readiness should avoid downloading the response body"
    assert ("https://www.example.test/" `elem` args) "readiness should validate the public HTTPS hostname"
    assert
        ("www.example.test:443:node-a.hosting.test:443" `elem` args)
        "readiness must connect to the destination node rather than a cached public DNS answer"

    attempts <- newIORef (0 :: Int)
    waits <- newIORef ([] :: [Int])
    remaining <-
        waitForTrustedHttpsWith
            (\seconds -> modifyIORef' waits (<> [seconds]))
            [1, 2, 4]
            (\_publicHost _destinationHost -> do
                modifyIORef' attempts (+ 1)
                count <- readIORef attempts
                pure (count >= 3)
            )
            [("www.example.test", "node-a.hosting.test")]
    assert (null remaining) "later successful certificate check should complete readiness"
    waitValues <- readIORef waits
    assert (waitValues == [1, 2]) "readiness should stop waiting immediately after success"

    neverReady <-
        waitForTrustedHttpsWith
            (const (pure ()))
            [1]
            (\_ _ -> pure False)
            [("bad.example.test", "node-a.hosting.test")]
    assert
        (neverReady == [("bad.example.test", "node-a.hosting.test")])
        "timeout should report vhosts without trusted HTTPS"

    putStrLn "ok"
