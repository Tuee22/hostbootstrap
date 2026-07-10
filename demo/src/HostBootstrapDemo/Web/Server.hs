{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The hostbootstrap-demo webservice: a thin @wai@ application served by @warp@.

Routes: @GET /api/budget@ returns the 'BudgetView' as JSON (the e2e target and
the SPA's data source); @GET /@ serves the SPA shell that loads the
@esbuild@-bundled Halogen app. Kept on the warm @warp@/@wai@/@aeson@ stack (no
servant) so a derived project's container build hits the base-image warm store.
-}
module HostBootstrapDemo.Web.Server (
    AcceleratorHub,
    app,
    serveWeb,
    newAcceleratorHub,
    indexHtml,
)
where

import Control.Concurrent (MVar, ThreadId, killThread, myThreadId, newMVar, threadDelay, withMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, finally, try)
import Control.Monad (forever)
import Data.Aeson (encode)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Context as Context
import HostBootstrapDemo.Config (ProjectConfig (message))
import HostBootstrapDemo.Accelerator.Protocol (
    AcceleratorMessage (..),
    AcceleratorResponse (..),
    correlateResponse,
    decodeAcceleratorMessage,
    encodeAcceleratorMessage,
 )
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (..),
    AcceleratorAddRequest,
    acceleratorBadRequest,
    acceleratorUnavailable,
    addRequestId,
    budgetView,
    mkAcceleratorAddRequest,
 )
import Network.HTTP.Types (Status, hContentType, status200, status400, status404, status503)
import Network.Wai (Application, Request, Response, pathInfo, queryString, responseFile, responseLBS)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import qualified Network.WebSockets as WS
import System.Timeout (timeout)
import Text.Read (readMaybe)

{- | The @esbuild@ bundle path, relative to the directory @service run web@ runs from
(the project root, where @web/public/app.js@ is produced by build #3).
-}
bundlePath :: FilePath
bundlePath = "web/public/app.js"

{- | The @wai@ application, parameterized by the config-driven served @message@
(Sprint 20.1): the budget JSON endpoint (which carries the message), the SPA
shell, the bundled Halogen app, and a 404.
-}
data AcceleratorHub = AcceleratorHub
    { connectedDaemon :: TVar (Maybe DaemonPeer)
    }

data DaemonPeer = DaemonPeer
    { peerConnection :: WS.Connection
    , peerLock :: MVar ()
    , peerThread :: ThreadId
    }

acceleratorDispatchTimeoutMicros :: Int
acceleratorDispatchTimeoutMicros = 30000000

newAcceleratorHub :: IO AcceleratorHub
newAcceleratorHub =
    AcceleratorHub <$> newTVarIO Nothing

app :: Text -> AcceleratorHub -> Application
app msg hub =
    websocketsOr WS.defaultConnectionOptions (acceleratorDaemonServer hub) (httpApp msg hub)

httpApp :: Text -> AcceleratorHub -> Application
httpApp msg hub req respond = case pathInfo req of
    ["api", "budget"] ->
        respond (responseLBS status200 [(hContentType, "application/json")] (encode (budgetView msg)))
    ["api", "accelerator", "add"] ->
        acceleratorAddResponse hub req >>= respond
    ["app.js"] ->
        respond (responseFile status200 [(hContentType, "application/javascript")] bundlePath Nothing)
    [] ->
        respond (responseLBS status200 [(hContentType, "text/html; charset=utf-8")] indexHtml)
    _ ->
        respond (responseLBS status404 [(hContentType, "text/plain")] "not found")

acceleratorDaemonServer :: AcceleratorHub -> WS.ServerApp
acceleratorDaemonServer hub pending
    | WS.requestPath (WS.pendingRequest pending) == "/api/accelerator/daemon" = do
        conn <- WS.acceptRequest pending
        tid <- myThreadId
        lock <- newMVar ()
        let peer = DaemonPeer conn lock tid
        ( registerPeer hub peer
            >> forever (threadDelay maxBound)
            )
            `finally` clearPeerIfCurrent hub peer
    | otherwise =
        WS.rejectRequest pending "unknown accelerator websocket endpoint"

acceleratorAddResponse :: AcceleratorHub -> Request -> IO Response
acceleratorAddResponse hub req =
    case parseAcceleratorAddRequest req of
        Left failure ->
            pure (responseLBS status400 [(hContentType, "application/json")] (encode failure))
        Right addReq ->
            acceleratorDispatch hub addReq

acceleratorDispatch :: AcceleratorHub -> AcceleratorAddRequest -> IO Response
acceleratorDispatch hub addReq = do
    peer <- readTVarIO (connectedDaemon hub)
    case peer of
        Nothing ->
            pure (failureResponse status503 (acceleratorUnavailable (addRequestId addReq)))
        Just daemon ->
            dispatchToPeer hub daemon addReq

dispatchToPeer :: AcceleratorHub -> DaemonPeer -> AcceleratorAddRequest -> IO Response
dispatchToPeer hub peer addReq =
    withMVar (peerLock peer) $ \_ -> do
        sent <- try (WS.sendBinaryData (peerConnection peer) (encodeAcceleratorMessage (AcceleratorRequest addReq))) :: IO (Either SomeException ())
        case sent of
            Left err -> do
                clearPeer hub peer
                pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) (T.pack (show err))))
            Right _ -> do
                received <- timeout acceleratorDispatchTimeoutMicros (try (WS.receiveData (peerConnection peer)) :: IO (Either SomeException BS8.ByteString))
                case received of
                    Nothing -> do
                        clearPeer hub peer
                        pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) "daemon response timeout"))
                    Just (Left err) -> do
                        clearPeer hub peer
                        pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) (T.pack (show err))))
                    Just (Right raw) ->
                        pure (responseFromDaemon addReq raw)

responseFromDaemon :: AcceleratorAddRequest -> BS8.ByteString -> Response
responseFromDaemon addReq raw =
    case decodeAcceleratorMessage raw of
        Right (AcceleratorResult result) ->
            correlatedResponse (AcceleratorSucceeded result)
        Right (AcceleratorFailure failure) ->
            correlatedResponse (AcceleratorFailed failure)
        Right _ ->
            failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) "daemon returned a request message")
        Left err ->
            failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) err)
  where
    correlatedResponse response =
        case correlateResponse (addRequestId addReq) response of
            Left err ->
                failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) err)
            Right (AcceleratorSucceeded result) ->
                responseLBS status200 [(hContentType, "application/json")] (encode result)
            Right (AcceleratorFailed failure) ->
                failureResponse status503 failure

failureResponse :: Status -> AcceleratorAddFailure -> Response
failureResponse status failure =
    responseLBS status [(hContentType, "application/json")] (encode failure)

acceleratorUnavailableWith :: Text -> Text -> AcceleratorAddFailure
acceleratorUnavailableWith rid err =
    (acceleratorUnavailable rid){failureMessage = "accelerator daemon unavailable: " <> err}

clearPeer :: AcceleratorHub -> DaemonPeer -> IO ()
clearPeer hub peer = do
    clearPeerIfCurrent hub peer
    killThread (peerThread peer)

registerPeer :: AcceleratorHub -> DaemonPeer -> IO ()
registerPeer hub peer = do
    previous <-
        atomically $ do
            old <- readTVar (connectedDaemon hub)
            writeTVar (connectedDaemon hub) (Just peer)
            pure old
    case previous of
        Nothing -> pure ()
        Just oldPeer -> killThread (peerThread oldPeer)

clearPeerIfCurrent :: AcceleratorHub -> DaemonPeer -> IO ()
clearPeerIfCurrent hub peer =
    atomically $ do
        current <- readTVar (connectedDaemon hub)
        case current of
            Just active | peerThread active == peerThread peer -> writeTVar (connectedDaemon hub) Nothing
            _ -> pure ()

parseAcceleratorAddRequest :: Request -> Either AcceleratorAddFailure AcceleratorAddRequest
parseAcceleratorAddRequest req = do
    rid <- Right (T.pack (maybe "web-ui" BS8.unpack (lookupQuery "requestId")))
    leftRaw <- required "left" rid
    rightRaw <- required "right" rid
    leftVal <- number "left" rid leftRaw
    rightVal <- number "right" rid rightRaw
    Right (mkAcceleratorAddRequest rid leftVal rightVal)
  where
    pairs = queryString req
    lookupQuery key = lookup key pairs >>= id
    required key rid =
        maybe
            (Left (acceleratorBadRequest rid ("missing query parameter: " <> T.pack (BS8.unpack key))))
            Right
            (lookupQuery key)
    number key rid raw =
        maybe
            (Left (acceleratorBadRequest rid ("invalid numeric query parameter: " <> T.pack (BS8.unpack key))))
            Right
            (readMaybe (BS8.unpack raw))

{- | The SPA shell: a minimal HTML document that mounts the @esbuild@ bundle the
@web bridge@ + @spago build@ + @esbuild@ steps produce (served from @/app.js@).
The Playwright e2e drives the rendered tabs; the bundle is built in the project
container (build #3).
-}
indexHtml :: LBS.ByteString
indexHtml =
    LBS.fromStrict
        "<!doctype html>\n\
        \<html lang=\"en\">\n\
        \<head><meta charset=\"utf-8\"><title>hostbootstrap-demo</title></head>\n\
        \<body>\n\
        \  <div id=\"app\"></div>\n\
        \  <script src=\"/app.js\"></script>\n\
        \</body>\n\
        \</html>\n"

{- | Serve the webservice as the @web@ cluster-service pod, bound on @0.0.0.0:8080@
and reached through the @30080@ NodePort (the Playwright @baseURL@). Binding all
interfaces lets the in-cluster Playwright run reach it. Reads its own mounted
@<project>.dhall@ via the core generic loader (the cluster-service config the
ConfigMap delivers) and serves the config-driven @message@ from it (Sprint 20.1),
so the served value is whatever the active config carries.
-}
serveWeb :: Int -> IO ()
serveWeb port = do
    cfg <-
        Schema.requireSiblingProjectConfig
            (T.pack "hostbootstrap-demo")
            Context.ServiceCommand
            [] ::
            IO ProjectConfig
    let msg = message cfg
    putStrLn ("web serve: listening on http://0.0.0.0:" ++ show port ++ " (GET /api/budget, GET /); message=" ++ T.unpack msg)
    hub <- newAcceleratorHub
    run port (app msg hub)
