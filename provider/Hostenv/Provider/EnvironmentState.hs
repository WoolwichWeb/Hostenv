{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.EnvironmentState
    ( NodeUsers
    , managedUsersToRetire
    , movedUsersOnNode
    , parsePasswdUsers
    , reconcileObservedNodesInState
    )
where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR

type NodeUsers = Map Text (Map Text Integer)

managedUsersToRetire ::
    Text ->
    Map Text Text ->
    Map Text Integer ->
    KM.KeyMap A.Value ->
    [(Text, Integer)]
managedUsersToRetire nodeName desiredNodes observedUsers =
    mapMaybe retireCandidate . KM.toList
  where
    retireCandidate (key, A.Object entry) = do
        uid <- lookupInteger (K.fromString "uid") entry
        let userName = fromMaybe (K.toText key) (lookupText (K.fromString "userName") entry)
        observedUid <- M.lookup userName observedUsers
        if observedUid == uid && M.lookup userName desiredNodes /= Just nodeName
            then Just (userName, uid)
            else Nothing
    retireCandidate _ = Nothing

movedUsersOnNode ::
    Text ->
    Map Text Text ->
    KM.KeyMap A.Value ->
    [Text]
movedUsersOnNode nodeName desiredNodes =
    mapMaybe movedCandidate . KM.toList
  where
    movedCandidate (key, A.Object entry) = do
        stateNode <- lookupText (K.fromString "node") entry
        let userName = fromMaybe (K.toText key) (lookupText (K.fromString "userName") entry)
        desiredNode <- M.lookup userName desiredNodes
        if stateNode == nodeName && desiredNode /= nodeName
            then Just userName
            else Nothing
    movedCandidate _ = Nothing

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

reconcileObservedNodesInState ::
    Map Text Text ->
    NodeUsers ->
    KM.KeyMap A.Value ->
    KM.KeyMap A.Value
reconcileObservedNodesInState desiredNodes observedNodes =
    KM.mapWithKey reconcileEntry
  where
    nodeKey = K.fromString "node"
    presentKey = K.fromString "present"
    pendingKey = K.fromString "pendingCleanupNodes"
    uidKey = K.fromString "uid"
    userNameKey = K.fromString "userName"

    reconcileEntry key = \case
        A.Object entry ->
            let cleaned = KM.delete pendingKey (KM.delete presentKey entry)
                legacyPending = lookupTextList pendingKey entry
                oldNode =
                    case listToMaybe legacyPending of
                        Just node -> Just node
                        Nothing -> lookupText nodeKey entry
                userName = fromMaybe (K.toText key) (lookupText userNameKey entry)
             in case lookupInteger uidKey entry of
                    Nothing -> A.Object cleaned
                    Just uid ->
                        A.Object (setNode (chooseNode userName uid oldNode) cleaned)
        value -> value

    chooseNode userName uid oldNode =
        case M.lookup userName desiredNodes of
            Nothing ->
                case oldNode of
                    Just node | userPresent node userName uid == Just False -> Nothing
                    _ -> oldNode
            Just desiredNode
                | oldNode == Just desiredNode -> Just desiredNode
                | otherwise ->
                    case userPresent desiredNode userName uid of
                        Just True ->
                            case oldNode of
                                Nothing -> Just desiredNode
                                Just previousNode ->
                                    case userPresent previousNode userName uid of
                                        Just False -> Just desiredNode
                                        _ -> oldNode
                        _ -> oldNode

    userPresent node userName uid =
        fmap
            (\users -> M.lookup userName users == Just uid)
            (M.lookup node observedNodes)

    setNode maybeNode entry =
        case maybeNode of
            Nothing -> KM.delete nodeKey entry
            Just node -> KM.insert nodeKey (A.String node) entry

    lookupText key object =
        case KM.lookup key object of
            Just (A.String value) -> Just value
            _ -> Nothing

    lookupTextList key object =
        case KM.lookup key object of
            Just (A.Array values) -> mapMaybe asText (toList values)
            _ -> []

    lookupInteger key object =
        case KM.lookup key object of
            Just (A.Number value) ->
                case floatingOrInteger value :: Either Double Integer of
                    Right integer -> Just integer
                    Left _ -> Nothing
            _ -> Nothing

    asText (A.String value) = Just value
    asText _ = Nothing
