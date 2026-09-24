{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.RetiredUserState
    ( clearPendingCleanupNodesInState
    )
where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Maybe (mapMaybe)
import Data.Set qualified as S
import Data.Text (Text)

clearPendingCleanupNodesInState :: [Text] -> KM.KeyMap A.Value -> KM.KeyMap A.Value
clearPendingCleanupNodesInState successfulNodes =
    KM.map clearEntry
  where
    successful = S.fromList successfulNodes

    clearEntry = \case
        A.Object entry ->
            let pending =
                    filter
                        (`S.notMember` successful)
                        (lookupTextList (K.fromString "pendingCleanupNodes") entry)
             in A.Object (KM.insert (K.fromString "pendingCleanupNodes") (A.toJSON pending) entry)
        value -> value

    lookupTextList key object =
        case KM.lookup key object of
            Just (A.Array values) -> mapMaybe asText (toList values)
            _ -> []

    asText (A.String value) = Just value
    asText _ = Nothing
