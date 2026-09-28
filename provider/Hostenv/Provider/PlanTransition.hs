{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Validation for transitions between provider plans. This module owns the
-- safeguards around node removal, managed-user state, pending migration
-- handoffs, and the DNS fallback used when plan history is unavailable.
module Hostenv.Provider.PlanTransition
    ( Ops (..)
    , planConnectionNodes
    , planDeployUser
    , planSystemTargetNodes
    , validatePlanTransition
    ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.List ((\\))
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Hostenv.Provider.DeployVerification (NodeConnection, nodeConnectionFor)
import Hostenv.Provider.Dns qualified as Dns
import Hostenv.Provider.EnvironmentState qualified as EnvironmentState
import Hostenv.Provider.MigrationHandoff qualified as MigrationHandoff
import Hostenv.Provider.UserLifecycle qualified as UserLifecycle
import System.Directory qualified as Dir

data Ops = Ops
    { makeUserLifecycleOps :: Text -> (Text -> NodeConnection) -> UserLifecycle.Ops
    , printLine :: Text -> IO ()
    }

lookupText :: K.Key -> KM.KeyMap A.Value -> Maybe Text
lookupText key object =
    case KM.lookup key object of
        Just (A.String value) -> Just value
        _ -> Nothing

lookupObj :: K.Key -> KM.KeyMap A.Value -> Maybe (KM.KeyMap A.Value)
lookupObj key object =
    case KM.lookup key object of
        Just (A.Object value) -> Just value
        _ -> Nothing

queryPlanSafetyCnames :: Text -> IO (Either Text [Text])
queryPlanSafetyCnames name = do
    result <- Dns.queryRecursiveRecord 2 name "CNAME"
    pure $
        case result of
            Left err -> Left (Dns.renderLookupFailure err)
            Right answers -> Right answers

planDeployUser :: KM.KeyMap A.Value -> Text
planDeployUser plan =
    fromMaybe "deploy" (lookupText (K.fromString "deployUser") plan)

planSystemTargetNodes :: KM.KeyMap A.Value -> Maybe Text -> [Text]
planSystemTargetNodes plan mNode =
    let nodeNames =
            maybe
                []
                (map K.toText . KM.keys)
                (lookupObj (K.fromString "nodes") plan)
     in case mNode of
            Nothing -> nodeNames
            Just nodeName -> filter (== nodeName) nodeNames

planConnectionNodes :: KM.KeyMap A.Value -> [Text]
planConnectionNodes plan =
    maybe
        []
        (map K.toText . KM.keys)
        (lookupObj (K.fromString "nodeConnections") plan)

planNodeStatus :: KM.KeyMap A.Value -> Text -> Text
planNodeStatus plan nodeName =
    fromMaybe "active" $ do
        statuses <- lookupObj (K.fromString "nodeStatus") plan
        lookupText (K.fromText nodeName) statuses

planEnvironmentAssignments :: KM.KeyMap A.Value -> [(Text, Text)]
planEnvironmentAssignments plan =
    case lookupObj (K.fromString "environments") plan of
        Nothing -> []
        Just environments ->
            mapMaybe assignment (KM.toList environments)
  where
    assignment (key, A.Object envObj) = do
        nodeName <- lookupText (K.fromString "node") envObj
        pure (K.toText key, nodeName)
    assignment _ = Nothing

planEnvironmentHostnames :: KM.KeyMap A.Value -> [Text]
planEnvironmentHostnames plan =
    case lookupObj (K.fromString "environments") plan of
        Nothing -> []
        Just environments ->
            mapMaybe hostnameFor (KM.elems environments)
  where
    hostnameFor (A.Object envObj) = do
        hostenvObj <- lookupObj (K.fromString "hostenv") envObj
        lookupText (K.fromString "hostname") hostenvObj
    hostnameFor _ = Nothing

loadProviderState :: Text -> IO (KM.KeyMap A.Value)
loadProviderState statePath = do
    stateExists <- Dir.doesFileExist (T.unpack statePath)
    if not stateExists
        then pure KM.empty
        else do
            stateRaw <- BL.readFile (T.unpack statePath)
            case A.eitherDecode' stateRaw of
                Left err ->
                    error ("hostenv-provider: cannot read " <> T.unpack statePath <> ": " <> err)
                Right value -> pure value

validatePlanDnsSafety ::
    Ops ->
    Maybe (KM.KeyMap A.Value) ->
    KM.KeyMap A.Value ->
    IO ()
validatePlanDnsSafety ops previousPlan newPlan = do
    let hostenvHostname =
            fromMaybe
                (error "hostenv-provider: generated plan is missing hostenvHostname")
                (lookupText (K.fromString "hostenvHostname") newPlan)
    let inventory = S.fromList (map Dns.normalizeName (planSystemTargetNodes newPlan Nothing))
    let hostnames =
            S.toList . S.fromList $
                planEnvironmentHostnames newPlan
                    ++ maybe [] planEnvironmentHostnames previousPlan

    lookupResults <-
        forM hostnames $ \hostname -> do
            result <- queryPlanSafetyCnames hostname
            pure (hostname, result)

    let lookupFailures =
            [ hostname <> ": " <> err
            | (hostname, Left err) <- lookupResults
            ]
    unless (null lookupFailures) $
        error
            ( "hostenv-provider: refusing provider plan because Hostenv DNS could not be verified: "
                <> T.unpack (T.intercalate "; " lookupFailures)
            )

    let domain = Dns.normalizeName hostenvHostname
    let suffix = "." <> domain
    let violations =
            [ (hostname, nodeName)
            | (hostname, Right cnames) <- lookupResults
            , cname <- cnames
            , let normalizedTarget = Dns.normalizeName cname
            , Just nodeName <- [T.stripSuffix suffix normalizedTarget]
            , not (T.null nodeName)
            , not (S.member nodeName inventory)
            ]

    unless (null violations) $
        error
            ( "hostenv-provider: refusing provider plan because Hostenv DNS still points at node(s) missing from provider.nodeSystems: "
                <> T.unpack
                    ( T.intercalate
                        ", "
                        [ hostname <> " -> " <> nodeName
                        | (hostname, nodeName) <- violations
                        ]
                    )
                <> ". Restore the node to inventory, migrate/retire the environment, and run plan again before changing DNS."
            )

validatePendingMigrationHandoffs ::
    Ops ->
    KM.KeyMap A.Value ->
    [Text] ->
    IO ()
validatePendingMigrationHandoffs ops plan inventoryNodes = do
    let hostenvHostname =
            fromMaybe
                (error "hostenv-provider: generated plan is missing hostenvHostname")
                (lookupText (K.fromString "hostenvHostname") plan)
    let deployUser = planDeployUser plan
    let resolveConnection = nodeConnectionFor plan hostenvHostname
    let lifecycleOps = ops.makeUserLifecycleOps deployUser resolveConnection
    handoffResults <-
        forM inventoryNodes $
            UserLifecycle.readNodeMigrationHandoffs lifecycleOps
    let handoffErrors = [err | Left err <- handoffResults]
    unless (null handoffErrors) $
        error
            ( "hostenv-provider: refusing provider plan because pending migration handoffs could not be verified: "
                <> T.unpack (T.intercalate "; " handoffErrors)
            )
    let pendingRemovedSources =
            [ (destinationNode, uid, MigrationHandoff.handoffSourceNode handoff)
            | (destinationNode, Right handoffs) <- zip inventoryNodes handoffResults
            , (uid, handoff) <- handoffs
            , MigrationHandoff.handoffSourceNode handoff `notElem` inventoryNodes
            ]
    unless (null pendingRemovedSources) $
        error
            ( "hostenv-provider: refusing provider plan because pending migration finalization still references node(s) missing from provider.nodeSystems: "
                <> T.unpack
                    ( T.intercalate
                        ", "
                        [ "uid "
                            <> T.pack (show uid)
                            <> " on "
                            <> destinationNode
                            <> " -> "
                            <> sourceNode
                        | (destinationNode, uid, sourceNode) <- pendingRemovedSources
                        ]
                    )
                <> ". Keep each source node in inventory until deploy removes its old account and clears the handoff."
            )

validatePlanTransition :: Ops -> Text -> Text -> BL.ByteString -> IO ()
validatePlanTransition ops planPath statePath newPlanRaw = do
    newPlan <-
        case A.eitherDecode' newPlanRaw of
            Left err ->
                error ("hostenv-provider: generated plan is invalid JSON: " <> err)
            Right value -> pure (value :: KM.KeyMap A.Value)

    state <- loadProviderState statePath

    previousPlanExists <- Dir.doesFileExist (T.unpack planPath)
    previousPlan <-
        if not previousPlanExists
            then pure Nothing
            else do
                previousRaw <- BL.readFile (T.unpack planPath)
                case A.eitherDecode' previousRaw of
                    Left err -> do
                        ops.printLine
                            ( "hostenv-provider: warning: existing "
                                <> planPath
                                <> " is invalid; skipping previous-plan comparison and relying on the DNS safety check ("
                                <> T.pack err
                                <> ")"
                            )
                        pure Nothing
                    Right value -> pure (Just (value :: KM.KeyMap A.Value))

    let newNodes = planSystemTargetNodes newPlan Nothing
    let removedNodes =
            maybe
                []
                (\oldPlan -> planSystemTargetNodes oldPlan Nothing \\ newNodes)
                previousPlan

    let validateRemovedNode nodeName status lifecycleOps managedIdentityState = do
            unless (status == "retiring") $
                error
                    ( "hostenv-provider: refusing to remove provider node "
                        <> T.unpack nodeName
                        <> " directly from inventory. Mark provider.nodeStatus."
                        <> T.unpack nodeName
                        <> " = \"retiring\", move/retire its environments, deploy the cleanup, then run plan again."
                    )

            observedResult <- UserLifecycle.readNodeUsers lifecycleOps nodeName
            observedUsers <-
                case observedResult of
                    Left err ->
                        error
                            ( "hostenv-provider: refusing to remove retiring node "
                                <> T.unpack nodeName
                                <> " because Hostenv could not verify that it is clean: "
                                <> T.unpack err
                            )
                    Right (_, users) -> pure users

            let identities = EnvironmentState.managedIdentities managedIdentityState
            runtimeResult <-
                UserLifecycle.readNodeRuntimeUsers
                    lifecycleOps
                    identities
                    nodeName
            runtimeUsers <-
                case runtimeResult of
                    Left err ->
                        error
                            ( "hostenv-provider: refusing to remove retiring node "
                                <> T.unpack nodeName
                                <> " because Hostenv could not verify its user runtime state: "
                                <> T.unpack err
                            )
                    Right (_, users) -> pure users

            let managedUsers =
                    EnvironmentState.managedUsersToRetire
                        nodeName
                        M.empty
                        observedUsers
                        runtimeUsers
                        managedIdentityState
            let uidMismatches =
                    EnvironmentState.managedUserUidMismatches
                        observedUsers
                        managedIdentityState
            let uidOwnerConflicts =
                    EnvironmentState.managedReservedUidConflicts
                        observedUsers
                        managedIdentityState
            unless (null managedUsers && null uidMismatches && null uidOwnerConflicts) $
                error
                    ( "hostenv-provider: refusing to remove retiring node "
                        <> T.unpack nodeName
                        <> " from inventory because it still contains Hostenv-managed account/runtime state: "
                        <> T.unpack
                            ( T.intercalate
                                ", "
                                ( map fst managedUsers
                                    ++ [ userName <> " (UID drift)" | (userName, _, _) <- uidMismatches ]
                                    ++ [ userName <> " (reserved UID " <> T.pack (show expectedUid) <> " owned by " <> owner <> ")"
                                       | (userName, expectedUid, owner) <- uidOwnerConflicts
                                       ]
                                )
                            )
                        <> ". Deploy migrations/retirements until the node is clean, then run plan again."
                    )

    case previousPlan of
        Just oldPlan -> do
            let removedSet = S.fromList removedNodes
            let removedAssignments =
                    [ (envName, nodeName)
                    | (envName, nodeName) <- planEnvironmentAssignments oldPlan
                    , S.member nodeName removedSet
                    ]

            unless (null removedAssignments) $
                error
                    ( "hostenv-provider: refusing provider plan because environment(s) were assigned to node(s) removed from provider.nodeSystems: "
                        <> T.unpack
                            ( T.intercalate
                                ", "
                                [ envName <> "@" <> nodeName
                                | (envName, nodeName) <- removedAssignments
                                ]
                            )
                        <> ". Keep each source node in inventory, move its environments, mark it retiring, deploy the cleanup, then remove it in a later plan."
                    )

            unless (null removedNodes) $ do
                let previousEnvironments =
                        fromMaybe KM.empty (lookupObj (K.fromString "environments") oldPlan)
                let managedIdentityState = KM.union state previousEnvironments
                let deployUser = planDeployUser oldPlan
                let oldHostname =
                        fromMaybe
                            (error ("hostenv-provider: hostenvHostname missing from existing " <> T.unpack planPath))
                            (lookupText (K.fromString "hostenvHostname") oldPlan)
                let resolveOldConnection = nodeConnectionFor oldPlan oldHostname
                let lifecycleOps = ops.makeUserLifecycleOps deployUser resolveOldConnection
                forM_ removedNodes $ \nodeName ->
                    validateRemovedNode
                        nodeName
                        (planNodeStatus oldPlan nodeName)
                        lifecycleOps
                        managedIdentityState
        Nothing -> pure ()

    -- Check handoff markers only when the previous plan proves that a node is
    -- being removed. When plan history is missing, do not probe every proposed
    -- node for handoffs: a new provider may not have working SSH access until
    -- its first deployment. This intentionally means that deleting plan.json
    -- also loses the handoff-based removal warning. DNS remains the best-effort
    -- warning in that case, and provider inventory is still the source of truth.
    when (not (null removedNodes)) $
        validatePendingMigrationHandoffs ops newPlan newNodes

    when (isNothing previousPlan || not (null removedNodes)) $
        validatePlanDnsSafety ops previousPlan newPlan
