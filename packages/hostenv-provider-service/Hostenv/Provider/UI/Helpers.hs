{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.UI.Helpers
  ( respondHtml
  , respondHtmlWithHeaders
  , respondRedirect
  ) where

import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Lucid (Html, renderBS)
import Network.HTTP.Types (Status, hLocation, status302)
import qualified Network.HTTP.Types.Header as HTTPHeader
import qualified Network.Wai as Wai
import Network.Wai (responseLBS)

import Hostenv.Provider.Config (AppConfig, uiPath)

respondHtml :: (Wai.Response -> IO a) -> Status -> Html () -> IO a
respondHtml respond status body =
  respond (responseLBS status [("Content-Type", "text/html; charset=utf-8")] (renderBS body))

respondHtmlWithHeaders :: (Wai.Response -> IO a) -> Status -> [HTTPHeader.Header] -> Html () -> IO a
respondHtmlWithHeaders respond status headers body =
  respond (responseLBS status (("Content-Type", "text/html; charset=utf-8") : headers) (renderBS body))

respondRedirect :: (Wai.Response -> IO a) -> AppConfig -> Text -> IO a
respondRedirect respond cfg path =
  respondHtmlWithHeaders respond status302 [(hLocation, TE.encodeUtf8 (uiPath cfg path))] mempty
