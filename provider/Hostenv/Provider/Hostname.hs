{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Hostname (canonicalHostInDomain) where

import Data.Text (Text)
import Data.Text qualified as T

stripDot :: Text -> Text
stripDot = T.dropWhileEnd (== '.')

normalizeHost :: Text -> Text
normalizeHost = T.toLower . stripDot . T.strip

canonicalHostInDomain :: Text -> Text -> Text
canonicalHostInDomain label domain =
    let labelNorm = normalizeHost label
        domainNorm = normalizeHost domain
     in if labelNorm == domainNorm || ("." <> domainNorm) `T.isSuffixOf` labelNorm
            then labelNorm
            else labelNorm <> "." <> domainNorm
