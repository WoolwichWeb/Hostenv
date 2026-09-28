{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.SigningTarget
    ( deployProfilePathInstallable
    , deployProfilePathInstallableAt
    )
where

import Data.Text (Text)
import Data.Text qualified as T

deployProfilePathInstallable :: Text -> Text -> Text
deployProfilePathInstallable =
    deployProfilePathInstallableAt "generated/."

deployProfilePathInstallableAt :: Text -> Text -> Text -> Text
deployProfilePathInstallableAt flakeRef nodeName profileName =
    flakeRef
        <> "#deploy.nodes."
        <> nixAttrToken nodeName
        <> ".profiles."
        <> nixAttrToken profileName
        <> ".path"

nixAttrToken :: Text -> Text
nixAttrToken token =
    "\"" <> escapeAttrToken token <> "\""

escapeAttrToken :: Text -> Text
escapeAttrToken =
    T.concatMap (\c ->
        case c of
            '"' -> "\\\""
            '\\' -> "\\\\"
            _ -> T.singleton c
    )
