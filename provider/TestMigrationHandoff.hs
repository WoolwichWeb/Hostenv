{-# LANGUAGE OverloadedStrings #-}

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Hostenv.Provider.MigrationHandoff
import System.Exit (exitFailure)

assertEqual :: (Eq a, Show a) => Text -> a -> a -> IO ()
assertEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            print expected
            print actual
            exitFailure

assertContains :: Text -> Text -> Text -> IO ()
assertContains label needle haystack =
    if needle `T.isInfixOf` haystack
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> "): missing " <> needle)
            TIO.putStrLn haystack
            exitFailure

assertNotContains :: Text -> Text -> Text -> IO ()
assertNotContains label needle haystack =
    if needle `T.isInfixOf` haystack
        then do
            TIO.putStrLn ("assertion failed (" <> label <> "): unexpectedly found " <> needle)
            TIO.putStrLn haystack
            exitFailure
        else pure ()

main :: IO ()
main = do
    let accepted = MigrationHandoff "old-node" HandoffAccepted
    let quiesced = MigrationHandoff "old-node" HandoffQuiesced

    assertEqual
        "root-owned marker path"
        "/var/lib/hostenv/provider/migration-handoffs/2000"
        (markerPath 2000)

    assertEqual "accepted render" "accepted old-node" (renderMigrationHandoff accepted)
    assertEqual "quiesced render" "quiesced old-node" (renderMigrationHandoff quiesced)
    assertEqual "accepted parse" (Right (Just accepted)) (parseMigrationHandoff "accepted old-node\n")
    assertEqual "quiesced parse" (Right (Just quiesced)) (parseMigrationHandoff "quiesced old-node\n")
    assertEqual
        "legacy completed parse"
        (Right (Just quiesced))
        (parseMigrationHandoff "old-node\n")
    assertEqual "empty parse" (Right Nothing) (parseMigrationHandoff "")
    assertEqual
        "handoff listing parse"
        (Right [(2000, quiesced), (2001, MigrationHandoff "older-node" HandoffAccepted)])
        (parseHandoffListing "2000\tquiesced old-node\n2001\taccepted older-node\n")
    case parseHandoffListing "not-a-uid\tquiesced old-node\n" of
        Left _ -> pure ()
        Right parsed -> do
            TIO.putStrLn ("assertion failed (invalid handoff listing accepted): " <> T.pack (show parsed))
            exitFailure

    assertContains
        "handoff listing is provider-rooted"
        "/var/lib/hostenv/provider/migration-handoffs"
        listCommand

    let writeScript = writeAtomicCommand 2000 quiesced
    assertContains "provider root" "/var/lib/hostenv/provider/migration-handoffs" writeScript
    assertContains "root-owned directory" "install -d -m 0700 -o root -g root" writeScript
    assertContains "same-directory temporary file" "mktemp \"$marker_dir/.handoff.XXXXXX\"" writeScript
    assertContains "write temporary file" "sudo tee \"$tmp\"" writeScript
    assertContains "root ownership" "chown root:root \"$tmp\"" writeScript
    assertContains "atomic rename" "mv -f -- \"$tmp\" \"$marker_path\"" writeScript
    assertNotContains "never tenant home" "/home/" writeScript

    TIO.putStrLn "ok"
