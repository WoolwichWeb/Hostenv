{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.EnvironmentState
    ( NodeUsers
    , managedUserUidMismatches
    , managedUsersToRetire
    , parsePasswdUsers
    , resolveMigrationSourceNode
    )
where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR

type NodeUsers = Map Text (Map Text Integer)

managedUserUidMismatches ::
    Text ->
    Map Text Text ->
    Map Text Integer ->
    KM.KeyMap A.Value ->
    [(Text, Integer, Integer)]
managedUserUidMismatches nodeName desiredNodes observedUsers =
    sortOn (\(name, _, _) -> name) . mapMaybe mismatchCandidate . KM.toList
  where
    mismatchCandidate (key, A.Object entry) = do
        expectedUid <- lookupInteger (K.fromString "uid") entry
        let userName = fromMaybe (K.toText key) (lookupText (K.fromString "userName") entry)
        observedUid <- M.lookup userName observedUsers
        if observedUid /= expectedUid && M.lookup userName desiredNodes /= Just nodeName
            then Just (userName, expectedUid, observedUid)
            else Nothing
    mismatchCandidate _ = Nothing

managedUsersToRetire ::
    Text ->
    Map Text Text ->
    Map Text Integer ->
    KM.KeyMap A.Value ->
    [(Text, Integer)]
managedUsersToRetire nodeName desiredNodes observedUsers =
    sortOn fst . mapMaybe retireCandidate . KM.toList
  where
    retireCandidate (key, A.Object entry) = do
        uid <- lookupInteger (K.fromString "uid") entry
        let userName = fromMaybe (K.toText key) (lookupText (K.fromString "userName") entry)
        observedUid <- M.lookup userName observedUsers
        if observedUid == uid && M.lookup userName desiredNodes /= Just nodeName
            then Just (userName, uid)
            else Nothing
    retireCandidate _ = Nothing

resolveMigrationSourceNode ::
    Text ->
    Text ->
    Integer ->
    Maybe Text ->
    NodeUsers ->
    Either Text (Maybe Text)
resolveMigrationSourceNode currentNode userName uid explicitSource observedNodes =
    case explicitSource of
        Just sourceNode
            | sourceNode == currentNode -> Right Nothing
            | userPresent sourceNode -> Right (Just sourceNode)
            | otherwise ->
                Left
                    ( "migration source "
                        <> sourceNode
                        <> " does not contain Hostenv user "
                        <> userName
                        <> " with UID "
                        <> T.pack (show uid)
                    )
        Nothing ->
            case matchingSources of
                [] -> Right Nothing
                [sourceNode] -> Right (Just sourceNode)
                sources ->
                    Left
                        ( "Hostenv user "
                            <> userName
                            <> " with UID "
                            <> T.pack (show uid)
                            <> " exists on more than one possible migration source: "
                            <> T.intercalate ", " sources
                            <> ". Set --migration-source "
                            <> userName
                            <> "=<node>."
                        )
  where
    userPresent nodeName =
        case M.lookup nodeName observedNodes >>= M.lookup userName of
            Just observedUid -> observedUid == uid
            Nothing -> False

    matchingSources =
        [ nodeName
        | (nodeName, users) <- M.toList observedNodes
        , nodeName /= currentNode
        , M.lookup userName users == Just uid
        ]

parsePasswdUsers :: Text -> Map Text Integer
parsePasswdUsers =
    M.fromList . mapMaybe parseLine . T.lines
  where
    parseLine line =
        case T.splitOn ":" line of
            name : _password : uidText : _rest ->
                case TR.decimal uidText of
                    Right (uid, trailing) | T.null trailing -> Just (name, uid)
                    _ -> Nothing
            _ -> Nothing

lookupText :: K.Key -> KM.KeyMap A.Value -> Maybe Text
lookupText key object =
    case KM.lookup key object of
        Just (A.String value) -> Just value
        _ -> Nothing

lookupInteger :: K.Key -> KM.KeyMap A.Value -> Maybe Integer
lookupInteger key object =
    case KM.lookup key object of
        Just (A.Number value) ->
            case floatingOrInteger value :: Either Double Integer of
                Right integer -> Just integer
                Left _ -> Nothing
        _ -> Nothing
