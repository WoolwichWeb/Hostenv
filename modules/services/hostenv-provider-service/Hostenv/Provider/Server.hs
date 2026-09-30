{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Hostenv.Provider.Server
  ( runServer
  , app
  ) where

import Control.Concurrent.MVar (MVar, newMVar)
import qualified Data.ByteString.Lazy as BL
import Data.Tagged (Tagged (..))
import Data.Text (Text)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (defaultSettings, runSettingsSocket, setBeforeMainLoop)
import Servant

import Hostenv.Provider.Config (AppConfig(..))
import Hostenv.Provider.Repo (openUnixSocket)
import Hostenv.Provider.UI.Router (uiApp)
import Hostenv.Provider.Service (WebhookResult)
import Hostenv.Provider.Webhook (webhookHandler)


type API =
  "webhook"
    :> Capture "hash" Text
    :> Header "X-Hub-Signature-256" Text
    :> Header "X-Gitlab-Token" Text
    :> ReqBody '[OctetStream] BL.ByteString
    :> Post '[JSON] WebhookResult
    :<|> Raw

api :: Proxy API
api = Proxy

runServer :: AppConfig -> IO ()
runServer cfg = do
  let AppConfig { appListenSocket = listenSocket } = cfg
  webhookLock <- newMVar ()
  sock <- openUnixSocket listenSocket
  let settings = setBeforeMainLoop (putStrLn ("hostenv-provider-service: listening on " <> listenSocket)) defaultSettings
  runSettingsSocket settings sock (app webhookLock cfg)

app :: MVar () -> AppConfig -> Application
app webhookLock cfg = serve api (server webhookLock cfg)

server :: MVar () -> AppConfig -> Server API
server webhookLock cfg = webhookHandler webhookLock cfg :<|> Tagged (uiApp cfg)
