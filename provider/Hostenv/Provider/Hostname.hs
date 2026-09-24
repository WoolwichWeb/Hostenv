{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Hostname (canonicalHostInDomain) where

import Data.Text (Text)
import Data.Text qualified as T

normalizeHost :: Text -> Text
normalizeHost = T.toLower . T.dropWhileEnd (== '.') . T.strip

canonicalHostInDomain :: Text -> Text -> Text
canonicalHostInDomain label hostenvHostname =
    let domain = normalizeHost hostenvHostname
        labelNorm = normalizeHost label
        suffix = "." <> domain
     in if T.null labelNorm
            then labelNorm
            else
                if T.null domain
                    then labelNorm
                    else
                        if T.isSuffixOf suffix labelNorm
                            then labelNorm
                            else labelNorm <> suffix
