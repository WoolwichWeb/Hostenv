{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Runtime lifecycle for Hostenv-managed Unix users. This module owns
-- observation, quiescence/rollback, and durable migration handoff operations.
-- The CLI supplies the node transport so this module does not also become a
-- generic SSH abstraction.
module Hostenv.Provider.UserLifecycle
    ( Ops (..)
    , clearMigrationHandoffOnNode
    , managedUserIsQuiescedOnNode
    , prepareManagedUserCleanupOnNode
    , readMigrationHandoff
    , readNodeMigrationHandoffs
    , readNodeRuntimeUsers
    , readNodeUsers
    , rollbackManagedUserCleanupOnNode
    , writeMigrationHandoffAccepted
    , writeMigrationHandoffQuiesced
    ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Hostenv.Provider.EnvironmentState qualified as EnvironmentState
import Hostenv.Provider.MigrationHandoff qualified as MigrationHandoff
import System.Exit (ExitCode (..))

data Ops = Ops
    { runRemote :: Text -> [Text] -> IO ExitCode
    , runRemoteOutput :: Text -> [Text] -> IO (ExitCode, Text, Text)
    , runRemoteScriptOutput :: Text -> Text -> IO (ExitCode, Text, Text)
    , runRemoteStrict :: Text -> [Text] -> IO Text
    , printLine :: Text -> IO ()
    , printErrLine :: Text -> IO ()
    }

shellEscape :: Text -> Text
shellEscape value =
    if T.null value
        then "''"
        else "'" <> T.replace "'" "'\\''" value <> "'"

readNodeUsers ::
    Ops ->
    Text ->
    IO (Either Text (Text, M.Map Text Integer))
readNodeUsers ops nodeName = do
    (code, out, err) <- ops.runRemoteOutput nodeName ["getent", "passwd"]
    case code of
        ExitSuccess ->
            pure (Right (nodeName, EnvironmentState.parsePasswdUsers out))
        ExitFailure exitCode ->
            pure
                ( Left
                    ( "failed to read passwd database on "
                        <> nodeName
                        <> " (exit "
                        <> T.pack (show exitCode)
                        <> "): "
                        <> T.strip err
                    )
                )

readNodeRuntimeUsers ::
    Ops ->
    [(Text, Integer)] ->
    Text ->
    IO (Either Text (Text, S.Set Text))
readNodeRuntimeUsers ops identities nodeName = do
    let probeFor (userName, uid) =
            let lingerPath = "/var/lib/systemd/linger/" <> userName
                unit = "user@" <> T.pack (show uid) <> ".service"
                runtimeDir = "/run/user/" <> T.pack (show uid)
             in T.unlines
                    [ "set +e"
                    , "unit_row=$(systemctl list-units --all --full --plain --no-legend " <> shellEscape unit <> ")"
                    , "unit_status=$?"
                    , "set -e"
                    , "if [ \"$unit_status\" -ne 0 ]; then"
                    , "  echo \"failed to inspect " <> unit <> " (systemctl exit $unit_status)\" >&2"
                    , "  exit \"$unit_status\""
                    , "fi"
                    , "if [ -z \"$unit_row\" ]; then"
                    , "  unit_active=0"
                    , "else"
                    , "  read -r _unit _load unit_state _rest <<< \"$unit_row\""
                    , "  case \"$unit_state\" in"
                    , "    active|reloading|activating|deactivating) unit_active=1 ;;"
                    , "    inactive|failed) unit_active=0 ;;"
                    , "    *) echo \"unexpected ActiveState for " <> unit <> ": $unit_state\" >&2; exit 92 ;;"
                    , "  esac"
                    , "fi"
                    , "if [ -e " <> shellEscape lingerPath <> " ]"
                        <> " || [ \"$unit_active\" -eq 1 ]"
                        <> " || [ -e "
                        <> shellEscape runtimeDir
                        <> " ]; then"
                    , "  printf '%s\\n' " <> shellEscape userName
                    , "fi"
                    ]
    let probeScript =
            T.unlines
                ( [ "set -euo pipefail"
                  , "# HOSTENV_RUNTIME_PROBE"
                  ]
                    ++ map probeFor identities
                )
    (code, out, err) <- ops.runRemoteScriptOutput nodeName probeScript
    case code of
        ExitSuccess ->
            pure
                ( Right
                    ( nodeName
                    , S.fromList (filter (not . T.null) (map T.strip (T.lines out)))
                    )
                )
        ExitFailure exitCode ->
            pure
                ( Left
                    ( "failed to inspect Hostenv user runtime state on "
                        <> nodeName
                        <> " (exit "
                        <> T.pack (show exitCode)
                        <> "): "
                        <> T.strip err
                    )
                )

prepareManagedUserCleanupOnNode ::
    Ops ->
    M.Map Text Text ->
    M.Map Text Integer ->
    S.Set Text ->
    KM.KeyMap A.Value ->
    Text ->
    (Text -> Integer -> IO ()) ->
    IO (Either Text ([(Text, Integer)], [Text]))
prepareManagedUserCleanupOnNode ops desiredNodes observedUsers runtimeUsers state nodeName onCleaned = do
    let uidMismatches =
            EnvironmentState.managedUserUidMismatches
                observedUsers
                state
    let uidOwnerConflicts =
            EnvironmentState.managedReservedUidConflicts
                observedUsers
                state
    let retiredUsers =
            EnvironmentState.managedUsersToRetire
                nodeName
                desiredNodes
                observedUsers
                runtimeUsers
                state
    if not (null uidMismatches) || not (null uidOwnerConflicts)
        then
            pure
                ( Left
                    ( "Hostenv-managed user UID mismatch on "
                        <> nodeName
                        <> ": "
                        <> T.intercalate
                            ", "
                            [ userName
                                <> " observed="
                                <> T.pack (show observedUid)
                                <> " expected="
                                <> T.pack (show expectedUid)
                            | (userName, expectedUid, observedUid) <- uidMismatches
                            ]
                        <> ( if null uidOwnerConflicts
                                then ""
                                else
                                    "; reserved UID conflict(s): "
                                        <> T.intercalate
                                            ", "
                                            [ userName
                                                <> " expected UID "
                                                <> T.pack (show expectedUid)
                                                <> " is owned by "
                                                <> owner
                                            | (userName, expectedUid, owner) <- uidOwnerConflicts
                                            ]
                           )
                        <> ". Refusing system deployment until the account drift is resolved."
                    )
                )
        else do
            cleanupResults <-
                forM retiredUsers $ \(userName, uid) -> do
                    let lingerPath = "/var/lib/systemd/linger/" <> userName
                    let unit = "user@" <> T.pack (show uid) <> ".service"
                    let runtimeDir = "/run/user/" <> T.pack (show uid)
                    let cleanupCmd =
                            "set -euo pipefail; "
                                <> "if getent passwd "
                                <> shellEscape userName
                                <> " >/dev/null; then "
                                <> "sudo loginctl disable-linger "
                                <> shellEscape userName
                                <> " || sudo rm -f "
                                <> shellEscape lingerPath
                                <> "; else sudo rm -f "
                                <> shellEscape lingerPath
                                <> "; fi; "
                                <> "set +e; unit_row=$(systemctl list-units --all --full --plain --no-legend "
                                <> shellEscape unit
                                <> "); unit_status=$?; set -e; "
                                <> "if [ \"$unit_status\" -ne 0 ]; then echo \"failed to inspect "
                                <> unit
                                <> " (systemctl exit $unit_status)\" >&2; exit \"$unit_status\"; fi; "
                                <> "stop_status=0; "
                                <> "if [ -n \"$unit_row\" ]; then "
                                <> "read -r _unit _load unit_state _rest <<< \"$unit_row\"; "
                                <> "case \"$unit_state\" in "
                                <> "active|reloading|activating|deactivating) sudo systemctl stop "
                                <> shellEscape unit
                                <> " || stop_status=$? ;; "
                                <> "inactive|failed) ;; "
                                <> "*) echo \"unexpected ActiveState for "
                                <> unit
                                <> ": $unit_state\" >&2; exit 92 ;; "
                                <> "esac; fi; "
                                <> "set +e; unit_row=$(systemctl list-units --all --full --plain --no-legend "
                                <> shellEscape unit
                                <> "); unit_status=$?; set -e; "
                                <> "if [ \"$unit_status\" -ne 0 ]; then echo \"failed to verify "
                                <> unit
                                <> " after cleanup (systemctl exit $unit_status)\" >&2; exit \"$unit_status\"; fi; "
                                <> "if [ -n \"$unit_row\" ]; then "
                                <> "read -r _unit _load unit_state _rest <<< \"$unit_row\"; "
                                <> "case \"$unit_state\" in "
                                <> "inactive|failed) ;; "
                                <> "active|reloading|activating|deactivating) echo \""
                                <> unit
                                <> " is still active after cleanup ($unit_state; stop exit $stop_status)\" >&2; exit 90 ;; "
                                <> "*) echo \"unexpected ActiveState for "
                                <> unit
                                <> " after cleanup: $unit_state\" >&2; exit 92 ;; "
                                <> "esac; fi; "
                                <> "if [ -e "
                                <> shellEscape lingerPath
                                <> " ]; then echo \"linger remains for "
                                <> userName
                                <> " after cleanup\" >&2; exit 91; fi; "
                                <> "if ! getent passwd "
                                <> shellEscape userName
                                <> " >/dev/null; then "
                                <> "runtime_unit=user-runtime-dir@"
                                <> T.pack (show uid)
                                <> ".service; "
                                <> "sudo systemctl stop \"$runtime_unit\" >/dev/null 2>&1 || true; "
                                <> "if [ -e "
                                <> shellEscape runtimeDir
                                <> " ]; then echo \"runtime directory remains after cleanup: "
                                <> runtimeDir
                                <> "\" >&2; exit 93; fi; "
                                <> "fi"
                    ops.printLine ("hostenv-provider: preparing retirement of Hostenv user " <> userName <> " from " <> nodeName)
                    (code, cleanupOut, cleanupErr) <- ops.runRemoteOutput nodeName ["bash", "-lc", cleanupCmd]
                    when (code /= ExitSuccess) $ do
                        let detail =
                                T.strip $
                                    if T.null (T.strip cleanupErr)
                                        then cleanupOut
                                        else cleanupErr
                        ops.printErrLine
                            ( "hostenv-provider: error: cleanup command failed for "
                                <> userName
                                <> " on "
                                <> nodeName
                                <> if T.null detail then "" else ": " <> detail
                            )
                    when (code == ExitSuccess) (onCleaned userName uid)
                    pure ((userName, uid), code)
            let cleanedUsers = [user | (user, code) <- cleanupResults, code == ExitSuccess]
            let failures = [userName | ((userName, _), code) <- cleanupResults, code /= ExitSuccess]
            unless (null failures) $ do
                let rollbackUsers =
                        filter
                            (\(userName, _) -> M.notMember userName desiredNodes)
                            (map fst cleanupResults)
                rollbackManagedUserCleanupOnNode ops nodeName rollbackUsers
            pure (Right (cleanedUsers, failures))

rollbackManagedUserCleanupOnNode ::
    Ops ->
    Text ->
    [(Text, Integer)] ->
    IO ()
rollbackManagedUserCleanupOnNode ops nodeName users =
    forM_ users $ \(userName, uid) -> do
        let unit = "user@" <> T.pack (show uid) <> ".service"
        let rollbackCmd =
                "if getent passwd "
                    <> shellEscape userName
                    <> " >/dev/null; then "
                    <> "sudo loginctl enable-linger "
                    <> shellEscape userName
                    <> " >/dev/null 2>&1 || true; "
                    <> "sudo systemctl start "
                    <> shellEscape unit
                    <> " >/dev/null 2>&1 || true; "
                    <> "fi"
        ops.printLine ("hostenv-provider: restoring Hostenv user manager after failed system deployment: " <> userName <> " on " <> nodeName)
        _ <- ops.runRemote nodeName ["bash", "-lc", rollbackCmd]
        pure ()

managedUserIsQuiescedOnNode ::
    Ops ->
    Text ->
    Integer ->
    Text ->
    IO Bool
managedUserIsQuiescedOnNode ops userName uid nodeName = do
    let unit = "user@" <> T.pack (show uid) <> ".service"
    let probeScript =
            T.unlines
                [ "set -euo pipefail"
                , "# HOSTENV_USER_MANAGER_PROBE " <> userName
                , "set +e"
                , "unit_row=$(systemctl list-units --all --full --plain --no-legend " <> shellEscape unit <> ")"
                , "unit_status=$?"
                , "set -e"
                , "if [ \"$unit_status\" -ne 0 ]; then"
                , "  echo \"failed to inspect " <> unit <> " (systemctl exit $unit_status)\" >&2"
                , "  exit \"$unit_status\""
                , "fi"
                , "if [ -z \"$unit_row\" ]; then"
                , "  printf 'quiesced\\n'"
                , "else"
                , "  read -r _unit _load unit_state _rest <<< \"$unit_row\""
                , "  case \"$unit_state\" in"
                , "    inactive|failed) printf 'quiesced\\n' ;;"
                , "    active|reloading|activating|deactivating) printf 'active\\n' ;;"
                , "    *) echo \"unexpected ActiveState for " <> unit <> ": $unit_state\" >&2; exit 92 ;;"
                , "  esac"
                , "fi"
                ]
    (code, out, err) <- ops.runRemoteScriptOutput nodeName probeScript
    case code of
        ExitFailure exitCode ->
            error
                ( "failed to inspect Hostenv user manager for "
                    <> T.unpack userName
                    <> " on "
                    <> T.unpack nodeName
                    <> " (exit "
                    <> show exitCode
                    <> "): "
                    <> T.unpack (T.strip err)
                )
        ExitSuccess ->
            case T.strip out of
                "quiesced" -> pure True
                "active" -> pure False
                other ->
                    error
                        ( "unexpected Hostenv user-manager probe result for "
                            <> T.unpack userName
                            <> " on "
                            <> T.unpack nodeName
                            <> ": "
                            <> T.unpack other
                        )

readMigrationHandoff ::
    Ops ->
    Text ->
    Integer ->
    Text ->
    IO (Maybe MigrationHandoff.MigrationHandoff)
readMigrationHandoff ops userName uid destinationNode = do
    raw <- ops.runRemoteStrict destinationNode ["bash", "-lc", MigrationHandoff.readCommand uid]
    case MigrationHandoff.parseMigrationHandoff raw of
        Left err ->
            error
                ( "invalid migration handoff state for "
                    <> T.unpack userName
                    <> ": "
                    <> T.unpack err
                )
        Right handoff -> pure handoff

readNodeMigrationHandoffs ::
    Ops ->
    Text ->
    IO (Either Text [(Integer, MigrationHandoff.MigrationHandoff)])
readNodeMigrationHandoffs ops nodeName = do
    (code, out, err) <- ops.runRemoteScriptOutput nodeName MigrationHandoff.listCommand
    case code of
        ExitFailure exitCode ->
            pure
                ( Left
                    ( "failed to inspect migration handoffs on "
                        <> nodeName
                        <> " (exit "
                        <> T.pack (show exitCode)
                        <> "): "
                        <> T.strip err
                    )
                )
        ExitSuccess ->
            pure $
                case MigrationHandoff.parseHandoffListing out of
                    Left parseErr ->
                        Left
                            ( "invalid migration handoff state on "
                                <> nodeName
                                <> ": "
                                <> parseErr
                            )
                    Right handoffs -> Right handoffs

writeMigrationHandoff ::
    Ops ->
    Text ->
    Integer ->
    Text ->
    Text ->
    MigrationHandoff.MigrationHandoffPhase ->
    IO ()
writeMigrationHandoff ops userName uid destinationNode sourceNode phase = do
    let handoff = MigrationHandoff.MigrationHandoff sourceNode phase
    let phaseName = MigrationHandoff.phaseText phase
    result <-
        ops.runRemote
            destinationNode
            [ "bash"
            , "-lc"
            , MigrationHandoff.writeAtomicCommand uid handoff
            ]
    case result of
        ExitSuccess ->
            ops.printLine
                ( "hostenv-provider: recorded migration handoff "
                    <> phaseName
                    <> " for "
                    <> userName
                    <> " from "
                    <> sourceNode
                )
        ExitFailure code ->
            error
                ( "failed to record migration handoff "
                    <> T.unpack phaseName
                    <> " for "
                    <> T.unpack userName
                    <> " (exit "
                    <> show code
                    <> ")"
                )

writeMigrationHandoffAccepted ::
    Ops ->
    Text ->
    Integer ->
    Text ->
    Text ->
    IO ()
writeMigrationHandoffAccepted ops userName uid destinationNode sourceNode = do
    existing <- readMigrationHandoff ops userName uid destinationNode
    case existing of
        Just handoff
            | MigrationHandoff.handoffSourceNode handoff == sourceNode
            , MigrationHandoff.handoffPhase handoff == MigrationHandoff.HandoffQuiesced ->
                pure ()
        _ ->
            writeMigrationHandoff
                ops
                userName
                uid
                destinationNode
                sourceNode
                MigrationHandoff.HandoffAccepted

writeMigrationHandoffQuiesced ::
    Ops ->
    Text ->
    Integer ->
    Text ->
    Text ->
    IO ()
writeMigrationHandoffQuiesced ops userName uid destinationNode sourceNode =
    writeMigrationHandoff
        ops
        userName
        uid
        destinationNode
        sourceNode
        MigrationHandoff.HandoffQuiesced

clearMigrationHandoffOnNode ::
    Ops ->
    Text ->
    Integer ->
    Text ->
    IO ()
clearMigrationHandoffOnNode ops userName uid nodeName = do
    result <-
        ops.runRemote
            nodeName
            [ "bash"
            , "-lc"
            , MigrationHandoff.clearCommand uid
            ]
    case result of
        ExitSuccess -> pure ()
        ExitFailure code ->
            error
                ( "failed to clear migration handoff marker for "
                    <> T.unpack userName
                    <> " on "
                    <> T.unpack nodeName
                    <> " (exit "
                    <> show code
                    <> ")"
                )
