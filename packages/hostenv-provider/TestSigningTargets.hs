{-# LANGUAGE OverloadedStrings #-}

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Hostenv.Provider.SigningTarget (deployProfilePathInstallable)
import System.Exit (exitFailure)

assertEqual :: Text -> Text -> Text -> IO ()
assertEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            TIO.putStrLn ("expected: " <> expected)
            TIO.putStrLn ("actual:   " <> actual)
            exitFailure

main :: IO ()
main = do
    assertEqual
        "system profile installable"
        "generated/.#deploy.nodes.\"backend05\".profiles.\"system\".path"
        (deployProfilePathInstallable "backend05" "system")

    assertEqual
        "environment profile installable"
        "generated/.#deploy.nodes.\"backend05\".profiles.\"georgina-integration-63f24e9\".path"
        (deployProfilePathInstallable "backend05" "georgina-integration-63f24e9")

    assertEqual
        "quoted path segments are escaped"
        "generated/.#deploy.nodes.\"node\\\"x\\\\y\".profiles.\"profile\\\"z\\\\w\".path"
        (deployProfilePathInstallable "node\"x\\y" "profile\"z\\w")

    TIO.putStrLn "ok"
