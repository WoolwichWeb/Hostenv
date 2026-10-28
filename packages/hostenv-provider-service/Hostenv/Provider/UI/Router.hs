{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.UI.Router
  ( uiApp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Types (methodGet, methodPost, status404)
import qualified Network.Wai as Wai
import Network.Wai (Application, responseLBS)

import Hostenv.Provider.Config (AppConfig(..), normalizeBasePath)
import Hostenv.Provider.UI.Handlers
  ( handleAddProjectGet
  , handleAddProjectPost
  , handleIndex
  , handleLogin
  , handleLogout
  , handleOauthCallback
  , handleOauthStart
  )


uiApp :: AppConfig -> Application
uiApp cfg req respond = do
  let AppConfig { appUiBasePath = basePath } = cfg
  case stripBasePath basePath (Wai.pathInfo req) of
    Nothing -> respond (responseLBS status404 [] "")
    Just rest -> routeUi cfg rest req respond

stripBasePath :: Text -> [Text] -> Maybe [Text]
stripBasePath base segments =
  let baseSegs = filter (/= "") (T.splitOn "/" (normalizeBasePath base))
   in if baseSegs == []
        then Just segments
        else case splitAt (length baseSegs) segments of
          (prefix, remainder) | prefix == baseSegs -> Just remainder
          _ -> Nothing

routeUi :: AppConfig -> [Text] -> Application
routeUi cfg segments req respond =
  case segments of
    [] ->
      case Wai.requestMethod req of
        m | m == methodGet -> handleIndex cfg req respond
        _ -> respond (responseLBS status404 [] "")
    ["login"] ->
      case Wai.requestMethod req of
        m | m == methodGet -> handleLogin cfg req respond
        _ -> respond (responseLBS status404 [] "")
    ["logout"] ->
      case Wai.requestMethod req of
        m | m == methodGet -> handleLogout cfg respond
        _ -> respond (responseLBS status404 [] "")
    ["oauth", "gitlab", "start"] ->
      case Wai.requestMethod req of
        m | m == methodGet -> handleOauthStart cfg req respond
        _ -> respond (responseLBS status404 [] "")
    ["oauth", "gitlab", "callback"] ->
      case Wai.requestMethod req of
        m | m == methodGet -> handleOauthCallback cfg req respond
        _ -> respond (responseLBS status404 [] "")
    ["add-project"] ->
      case Wai.requestMethod req of
        m | m == methodPost -> handleAddProjectPost cfg req respond
        m | m == methodGet -> handleAddProjectGet cfg req respond
        _ -> respond (responseLBS status404 [] "")
    _ -> respond (responseLBS status404 [] "")
