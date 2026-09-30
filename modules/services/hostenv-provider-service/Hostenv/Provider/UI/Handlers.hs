{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.UI.Handlers
  ( handleLogin
  , handleLogout
  , handleIndex
  , handleAddProjectGet
  , handleAddProjectPost
  , handleOauthStart
  , handleOauthCallback
  ) where

import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (hLocation, methodGet, methodPost, status200, status302, status400, status403, status500)
import Network.HTTP.Types.URI (renderSimpleQuery)
import qualified Network.Wai as Wai
import Network.Wai (strictRequestBody)

import Hostenv.Provider.Config (AppConfig(..), uiPath)
import Hostenv.Provider.DB (SessionInfo(..), User(..), getSessionInfo, loadProjects, logoutCookie, renderSessionCookie, withDb)
import Hostenv.Provider.Gitlab (GitlabTokenResponse(..), consumeOauthState, createOauthState, exchangeOAuthCode, fetchGitlabUser, loadUserProjects, oauthRedirectUri, requireSecrets, selectGitlabHost, upsertUserSession)
import Hostenv.Provider.Project (addProjectFlow)
import Hostenv.Provider.Service (GitlabSecrets(..))
import Hostenv.Provider.UI.Helpers (respondHtml, respondHtmlWithHeaders, respondRedirect)
import Hostenv.Provider.UI.Views (accessDeniedPage, addProjectPage, errorPage, indexPage, loginPage, successPage)
import Hostenv.Provider.Util (lookupParam, parseForm, readInt64)


csrfFieldName :: BSC.ByteString
csrfFieldName = "csrf"

handleLogin :: AppConfig -> Wai.Request -> (Wai.Response -> IO a) -> IO a
handleLogin cfg _ respond =
  respondHtml respond status200 (loginPage cfg Nothing)

handleLogout :: AppConfig -> (Wai.Response -> IO a) -> IO a
handleLogout cfg respond =
  respondHtmlWithHeaders respond status302 [(hLocation, TE.encodeUtf8 (uiPath cfg "/login")), ("Set-Cookie", logoutCookie)] mempty

handleIndex :: AppConfig -> Wai.Request -> (Wai.Response -> IO a) -> IO a
handleIndex cfg req respond = do
  mSession <- getSessionInfo cfg req
  case mSession of
    Nothing -> respondRedirect respond cfg "/login"
    Just sess ->
      let SessionInfo { sessionUser = User { userRole = role } } = sess
       in if role /= "admin"
        then respondHtml respond status403 (accessDeniedPage cfg)
        else do
          projects <- withDb cfg (\conn -> loadProjects conn)
          respondHtml respond status200 (indexPage cfg sess projects)

handleAddProjectGet :: AppConfig -> Wai.Request -> (Wai.Response -> IO a) -> IO a
handleAddProjectGet cfg req respond = do
  mSession <- getSessionInfo cfg req
  case mSession of
    Nothing -> respondRedirect respond cfg "/login"
    Just sess ->
      let SessionInfo { sessionUser = User { userRole = role } } = sess
       in if role /= "admin"
        then respondHtml respond status403 (accessDeniedPage cfg)
        else do
          result <- loadUserProjects cfg sess
          case result of
            Left msg -> respondHtml respond status500 (errorPage cfg msg)
            Right repos -> respondHtml respond status200 (addProjectPage cfg sess repos)

handleAddProjectPost :: AppConfig -> Wai.Request -> (Wai.Response -> IO a) -> IO a
handleAddProjectPost cfg req respond = do
  mSession <- getSessionInfo cfg req
  case mSession of
    Nothing -> respondRedirect respond cfg "/login"
    Just sess ->
      let SessionInfo { sessionUser = User { userRole = role }, sessionCsrf = csrf } = sess
       in if role /= "admin"
        then respondHtml respond status403 (accessDeniedPage cfg)
        else do
          body <- strictRequestBody req
          let params = parseForm body
          case lookupParam csrfFieldName params of
            Nothing -> respondHtml respond status400 (errorPage cfg "This form is no longer valid. Go back and try again.")
            Just csrfToken ->
              if csrfToken /= csrf
                then respondHtml respond status403 (errorPage cfg "This form is no longer valid. Go back and try again.")
                else do
                  let mRepoId = lookupParam "repo_id" params >>= readInt64
                  let orgInput = lookupParam "org" params
                  let projectInput = lookupParam "project" params
                  case mRepoId of
                    Nothing -> respondHtml respond status400 (errorPage cfg "Select a repository.")
                    Just repoId -> do
                      result <- addProjectFlow cfg sess repoId orgInput projectInput
                      case result of
                        Left msg -> respondHtml respond status500 (errorPage cfg msg)
                        Right successMsg -> respondHtml respond status200 (successPage cfg successMsg)

handleOauthStart :: AppConfig -> Wai.Request -> (Wai.Response -> IO a) -> IO a
handleOauthStart cfg req respond = do
  case requireSecrets cfg of
    Left err -> respondHtml respond status400 (errorPage cfg err)
    Right GitlabSecrets { gitlabClientId = clientId } -> do
      let host = selectGitlabHost cfg req
      case host of
        Nothing -> respondHtml respond status400 (errorPage cfg "No GitLab host is configured for this provider.")
        Just glHost -> do
          state <- createOauthState cfg glHost
          let redirectUri = oauthRedirectUri cfg
          let params =
                [ ("client_id", TE.encodeUtf8 clientId)
                , ("redirect_uri", TE.encodeUtf8 redirectUri)
                , ("response_type", "code")
                , ("scope", "api read_repository")
                , ("state", TE.encodeUtf8 state)
                ]
          let url = T.concat
                [ "https://"
                , glHost
                , "/oauth/authorize?"
                , TE.decodeUtf8 (renderSimpleQuery False params)
                ]
          respondHtmlWithHeaders respond status302 [(hLocation, TE.encodeUtf8 url)] mempty

handleOauthCallback :: AppConfig -> Wai.Request -> (Wai.Response -> IO a) -> IO a
handleOauthCallback cfg req respond = do
  let params = Wai.queryString req
  let mCode = lookup "code" params >>= id
  let mState = lookup "state" params >>= id
  case (mCode, mState) of
    (Just codeRaw, Just stateRaw) -> do
      let code = TE.decodeUtf8 codeRaw
      let state = TE.decodeUtf8 stateRaw
      mHost <- consumeOauthState cfg state
      case mHost of
        Nothing -> respondHtml respond status400 (errorPage cfg "This GitLab sign-in request has expired or is invalid. Start again.")
        Just glHost -> do
          tokenResp <- exchangeOAuthCode cfg glHost code
          case tokenResp of
            Left msg -> respondHtml respond status500 (errorPage cfg msg)
            Right token -> do
              let GitlabTokenResponse { tokenAccessToken = accessToken } = token
              mUser <- fetchGitlabUser cfg glHost accessToken
              case mUser of
                Left msg -> respondHtml respond status500 (errorPage cfg msg)
                Right glUser -> do
                  session <- upsertUserSession cfg glHost glUser token
                  let cookieHeader = ("Set-Cookie", renderSessionCookie session)
                  respondHtmlWithHeaders respond status302 [(hLocation, TE.encodeUtf8 (uiPath cfg "/")), cookieHeader] mempty
    _ -> respondHtml respond status400 (errorPage cfg "GitLab did not return the information needed to sign in. Start again.")
