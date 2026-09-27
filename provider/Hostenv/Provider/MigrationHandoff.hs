{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.MigrationHandoff
    ( MigrationHandoff (..)
    , MigrationHandoffPhase (..)
    , clearCommand
    , handoffPhase
    , handoffSourceNode
    , markerPath
    , parseHandoffListing
    , parseMigrationHandoff
    , phaseText
    , listCommand
    , readCommand
    , renderMigrationHandoff
    , writeAtomicCommand
    )
where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR

data MigrationHandoffPhase
    = HandoffAccepted
    | HandoffQuiesced
    deriving (Eq, Show)

data MigrationHandoff
    = MigrationHandoff Text MigrationHandoffPhase
    deriving (Eq, Show)

handoffSourceNode :: MigrationHandoff -> Text
handoffSourceNode (MigrationHandoff sourceNode _) = sourceNode

handoffPhase :: MigrationHandoff -> MigrationHandoffPhase
handoffPhase (MigrationHandoff _ phase) = phase

phaseText :: MigrationHandoffPhase -> Text
phaseText HandoffAccepted = "accepted"
phaseText HandoffQuiesced = "quiesced"

markerDirectory :: Text
markerDirectory = "/var/lib/hostenv/provider/migration-handoffs"

-- UIDs are stable provider identities and, unlike tenant-controlled usernames,
-- are safe path components for root-owned provider state.
markerPath :: Integer -> Text
markerPath uid = markerDirectory <> "/" <> T.pack (show uid)

renderMigrationHandoff :: MigrationHandoff -> Text
renderMigrationHandoff (MigrationHandoff sourceNode phase) =
    phaseText phase <> " " <> sourceNode

parseMigrationHandoff :: Text -> Either Text (Maybe MigrationHandoff)
parseMigrationHandoff raw =
    case T.words (T.strip raw) of
        [] -> Right Nothing
        -- Pre-two-phase markers meant that source cleanup had completed.
        [sourceNode] -> Right (Just (MigrationHandoff sourceNode HandoffQuiesced))
        ["accepted", sourceNode] -> Right (Just (MigrationHandoff sourceNode HandoffAccepted))
        ["quiesced", sourceNode] -> Right (Just (MigrationHandoff sourceNode HandoffQuiesced))
        _ -> Left ("invalid migration handoff marker: " <> T.strip raw)

parseHandoffListing :: Text -> Either Text [(Integer, MigrationHandoff)]
parseHandoffListing raw =
    mapM parseLine (filter (not . T.null) (T.lines raw))
  where
    parseLine line =
        let (uidText, payloadWithTab) = T.breakOn "\t" line
         in case TR.decimal uidText of
                Left _ -> Left ("invalid migration handoff UID in listing: " <> uidText)
                Right (uid, trailing)
                    | not (T.null trailing) -> Left ("invalid migration handoff UID in listing: " <> uidText)
                    | T.null payloadWithTab -> Left ("missing migration handoff payload for UID " <> uidText)
                    | otherwise ->
                        case parseMigrationHandoff (T.drop 1 payloadWithTab) of
                            Left err -> Left err
                            Right Nothing -> Left ("empty migration handoff payload for UID " <> uidText)
                            Right (Just handoff) -> Right (uid, handoff)

listCommand :: Text
listCommand =
    T.unlines
        [ "set -euo pipefail"
        , "marker_dir=" <> shellQuote markerDirectory
        , "if sudo test -L \"$marker_dir\"; then"
        , "  echo \"migration handoff directory must not be a symlink: $marker_dir\" >&2"
        , "  exit 94"
        , "fi"
        , "if sudo test -e \"$marker_dir\"; then"
        , "  if ! sudo test -d \"$marker_dir\"; then"
        , "    echo \"migration handoff path is not a directory: $marker_dir\" >&2"
        , "    exit 94"
        , "  fi"
        , "  for marker in \"$marker_dir\"/*; do"
        , "    sudo test -e \"$marker\" || continue"
        , "    if sudo test -L \"$marker\" || ! sudo test -f \"$marker\"; then"
        , "      echo \"invalid migration handoff marker: $marker\" >&2"
        , "      exit 94"
        , "    fi"
        , "    uid=${marker##*/}"
        , "    printf '%s\\t' \"$uid\""
        , "    sudo cat \"$marker\""
        , "  done"
        , "fi"
        ]

readCommand :: Integer -> Text
readCommand uid =
    let path = markerPath uid
     in T.unlines
            [ "set -euo pipefail"
            , "marker_path=" <> shellQuote path
            , "if sudo test -L \"$marker_path\"; then"
            , "  echo \"migration handoff marker must not be a symlink: $marker_path\" >&2"
            , "  exit 94"
            , "fi"
            , "if sudo test -e \"$marker_path\"; then"
            , "  if ! sudo test -f \"$marker_path\"; then"
            , "    echo \"migration handoff marker is not a regular file: $marker_path\" >&2"
            , "    exit 94"
            , "  fi"
            , "  sudo cat \"$marker_path\""
            , "fi"
            ]

writeAtomicCommand :: Integer -> MigrationHandoff -> Text
writeAtomicCommand uid handoff =
    let path = markerPath uid
        payload = renderMigrationHandoff handoff
     in T.unlines
            [ "set -euo pipefail"
            , "marker_dir=" <> shellQuote markerDirectory
            , "marker_path=" <> shellQuote path
            , "sudo install -d -m 0700 -o root -g root \"$marker_dir\""
            , "if sudo test -L \"$marker_path\"; then"
            , "  echo \"migration handoff marker must not be a symlink: $marker_path\" >&2"
            , "  exit 94"
            , "fi"
            , "tmp=$(sudo mktemp \"$marker_dir/.handoff.XXXXXX\")"
            , "cleanup_tmp() { sudo rm -f -- \"$tmp\"; }"
            , "trap cleanup_tmp EXIT HUP INT TERM"
            , "printf '%s\\n' " <> shellQuote payload <> " | sudo tee \"$tmp\" >/dev/null"
            , "sudo chown root:root \"$tmp\""
            , "sudo chmod 0600 \"$tmp\""
            , "sudo mv -f -- \"$tmp\" \"$marker_path\""
            , "trap - EXIT HUP INT TERM"
            ]

clearCommand :: Integer -> Text
clearCommand uid =
    let path = markerPath uid
     in T.unlines
            [ "set -euo pipefail"
            , "marker_path=" <> shellQuote path
            , "sudo rm -f -- \"$marker_path\""
            ]

shellQuote :: Text -> Text
shellQuote value =
    "'" <> T.replace "'" "'\"'\"'" value <> "'"
