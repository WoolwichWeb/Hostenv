{-# LANGUAGE OverloadedStrings #-}

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hostenv.Provider.DnsBackoff (backoffDelays)
import System.Exit (exitFailure)

assertEqual :: (Eq a, Show a) => Text -> a -> a -> IO ()
assertEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            TIO.putStrLn ("expected: " <> T.pack (show expected))
            TIO.putStrLn ("actual:   " <> T.pack (show actual))
            exitFailure

assertTrue :: Text -> Bool -> IO ()
assertTrue label cond =
    if cond
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            exitFailure

main :: IO ()
main = do
    let schedule = backoffDelays 1 30 600
    assertEqual "schedule starts exponential and caps at 30s" [1, 2, 4, 8, 16, 30] (take 6 schedule)
    assertTrue "all delays are capped at 30 seconds" (all (<= 30) schedule)
    assertEqual "total delay matches budget" 600 (sum schedule)
    TIO.putStrLn "ok"
