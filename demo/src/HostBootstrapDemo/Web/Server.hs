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
    appAtDurableRoot,
    acceleratorIngressApp,
    serveWeb,
    newAcceleratorHub,
    acceleratorDaemonConnected,
    acceleratorDispatch,
    runLinkedListeners,
    indexHtml,
)
where

import Control.Concurrent (MVar, ThreadId, forkFinally, killThread, myThreadId, newEmptyMVar, newMVar, putMVar, takeMVar, tryPutMVar, tryTakeMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeAsyncException, SomeException, finally, fromException, mask, onException, throwIO, tryJust)
import Control.Monad (join, unless, void, when)
import Data.Aeson (encode)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Context as Context
import HostBootstrapDemo.Accelerator.Protocol (
    AcceleratorMessage (..),
    AcceleratorResponse (..),
    correlateResponse,
    decodeAcceleratorMessage,
    encodeAcceleratorMessage,
 )
import HostBootstrapDemo.Config (ProjectConfig (message, service), ServiceType (Web), WebServiceConfig (WebServiceConfig), maxAcceleratorRequestTimeoutSeconds)
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (..),
    AcceleratorAddRequest,
    acceleratorBadRequest,
    acceleratorUnavailable,
    addRequestId,
    budgetView,
    mkAcceleratorAddRequest,
 )
import Network.HTTP.Types (Status, hContentType, hOrigin, methodGet, methodPost, status200, status400, status404, status405, status503)
import Network.Wai (Application, Request, Response, pathInfo, queryString, requestMethod, responseFile, responseLBS)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import qualified Network.WebSockets as WS
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.Timeout (timeout)
import Text.Read (readMaybe)

{- | The @esbuild@ bundle path, relative to the directory the @Web@ handler's
config-selected @service run@ runs from
(the project root, where @web/public/app.js@ is produced by build #3).
-}
bundlePath :: FilePath
bundlePath = "web/public/app.js"

-- | The pod-visible root backed by the kind-node host mount.
durableRoot :: FilePath
durableRoot = "/var/lib/hostbootstrap-demo-data/web"

durableMarkerToken :: BS8.ByteString
durableMarkerToken = "hostbootstrap-destroy-up-v1"

durableMarkerPath :: FilePath -> FilePath
durableMarkerPath root = root </> "marker"

{- | The @wai@ application, parameterized by the config-driven served @message@
(Sprint 20.1): the budget JSON endpoint (which carries the message), the SPA
shell, the bundled Halogen app, and a 404.
-}
newtype AcceleratorHub = AcceleratorHub
    { connectedDaemon :: TVar (Maybe DaemonPeer)
    }

data DaemonPeer = DaemonPeer
    { peerConnection :: WS.Connection
    , peerLock :: MVar ()
    , peerResponses :: MVar (Either Text BS8.ByteString)
    , peerThread :: ThreadId
    }

acceleratorDispatchTimeoutMicros :: Int
acceleratorDispatchTimeoutMicros =
    fromIntegral (maxAcceleratorRequestTimeoutSeconds + 10) * 1000000

newAcceleratorHub :: IO AcceleratorHub
newAcceleratorHub =
    AcceleratorHub <$> newTVarIO Nothing

acceleratorDaemonConnected :: AcceleratorHub -> IO Bool
acceleratorDaemonConnected hub = isJust <$> readTVarIO (connectedDaemon hub)

app :: Text -> AcceleratorHub -> Application
app = appAtDurableRoot durableRoot

-- | The public application with an injectable durable root for on-disk tests.
appAtDurableRoot :: FilePath -> Text -> AcceleratorHub -> Application
appAtDurableRoot = httpApp

{- | The daemon-registration listener. It is deliberately a different WAI
application and TCP port from 'app': the public web NodePort can never upgrade
a request into the trusted daemon channel.
-}
acceleratorIngressApp :: AcceleratorHub -> Application
acceleratorIngressApp hub =
    websocketsOr WS.defaultConnectionOptions (acceleratorDaemonServer hub) privateNotFound
  where
    privateNotFound _ respond =
        respond (responseLBS status404 [(hContentType, "text/plain")] "not found")

httpApp :: FilePath -> Text -> AcceleratorHub -> Application
httpApp durableRoot' msg hub req respond = case pathInfo req of
    ["api", "budget"] ->
        respond (responseLBS status200 [(hContentType, "application/json")] (encode (budgetView msg)))
    ["api", "accelerator", "add"] ->
        acceleratorAddResponse hub req >>= respond
    ["api", "durable", "marker"] ->
        durableMarkerResponse durableRoot' req >>= respond
    ["app.js"] ->
        respond (responseFile status200 [(hContentType, "application/javascript")] bundlePath Nothing)
    [] ->
        respond (responseLBS status200 [(hContentType, "text/html; charset=utf-8")] indexHtml)
    _ ->
        respond (responseLBS status404 [(hContentType, "text/plain")] "not found")

durableMarkerResponse :: FilePath -> Request -> IO Response
durableMarkerResponse root req
    | requestMethod req == methodPost = do
        BS8.writeFile (durableMarkerPath root) durableMarkerToken
        pure (markerResponse status200 (LBS.fromStrict durableMarkerToken))
    | requestMethod req == methodGet = do
        result <- tryIOError (BS8.readFile (durableMarkerPath root))
        case result of
            Right marker -> pure (markerResponse status200 (LBS.fromStrict marker))
            Left err
                | isDoesNotExistError err -> pure (markerResponse status404 "not found")
                | otherwise -> ioError err
    | otherwise =
        pure
            ( responseLBS
                status405
                [(hContentType, "text/plain"), ("Allow", "GET, POST")]
                "method not allowed"
            )

markerResponse :: Status -> LBS.ByteString -> Response
markerResponse status =
    responseLBS status [(hContentType, "text/plain; charset=utf-8")]

acceleratorDaemonServer :: AcceleratorHub -> WS.ServerApp
acceleratorDaemonServer hub pending
    | any ((== hOrigin) . fst) (WS.requestHeaders (WS.pendingRequest pending)) =
        WS.rejectRequest pending "browser-origin WebSocket connections are not accepted"
    | WS.requestPath (WS.pendingRequest pending) == "/api/accelerator/daemon" = do
        conn <- WS.acceptRequest pending
        tid <- myThreadId
        lock <- newMVar ()
        responses <- newEmptyMVar
        let peer = DaemonPeer conn lock responses tid
            disconnected = do
                void (tryPutMVar responses (Left "daemon disconnected"))
                clearPeerIfCurrent hub peer
        (registerPeer hub peer >> receiveDaemonResponses peer)
            `finally` disconnected
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
dispatchToPeer hub peer addReq = do
    -- One daemon connection is intentionally single-flight. A concurrent caller
    -- gets an immediate busy response; it must never time out in the lock queue
    -- and disconnect the healthy request that currently owns the peer.
    acquired <- tryTakeMVar (peerLock peer)
    case acquired of
        Nothing ->
            pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) "daemon is busy"))
        Just () ->
            (dispatch `onException` clearPeer hub peer)
                `finally` putMVar (peerLock peer) ()
  where
    dispatch = do
        sent <- trySynchronous (WS.sendBinaryData (peerConnection peer) (encodeAcceleratorMessage (AcceleratorRequest addReq)))
        case sent of
            Left err -> do
                clearPeer hub peer
                pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) (T.pack (show err))))
            Right _ -> do
                received <- timeout acceleratorDispatchTimeoutMicros (takeMVar (peerResponses peer))
                case received of
                    Just (Left err) -> do
                        clearPeer hub peer
                        pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) err))
                    Nothing -> do
                        clearPeer hub peer
                        pure (failureResponse status503 (acceleratorUnavailableWith (addRequestId addReq) "daemon response timeout"))
                    Just (Right raw) ->
                        pure (responseFromDaemon addReq raw)

receiveDaemonResponses :: DaemonPeer -> IO ()
receiveDaemonResponses peer = do
    received <- trySynchronous (WS.receiveData (peerConnection peer) :: IO BS8.ByteString)
    case received of
        Left err ->
            void (tryPutMVar (peerResponses peer) (Left (T.pack (show err))))
        Right raw -> do
            delivered <- tryPutMVar (peerResponses peer) (Right raw)
            when delivered (receiveDaemonResponses peer)

trySynchronous :: IO a -> IO (Either SomeException a)
trySynchronous = tryJust $ \err ->
    case fromException err :: Maybe SomeAsyncException of
        Just _ -> Nothing
        Nothing -> Just err

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
    lookupQuery key = join (lookup key pairs)
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

{- | Serve the webservice as the @web@ cluster-service pod, with the public HTTP
application on the supplied port (normally @8080@) and the daemon-only WebSocket
ingress on its separate supplied port (normally @8081@). The two listeners share one hub, but only the
dedicated accelerator Service targets the private port; public NodePort @30080@ therefore cannot
register a daemon. Binding all interfaces lets the in-cluster Playwright run reach
the public listener. Reads its own mounted
@<project>.dhall@ via the core generic loader (the cluster-service config the
ConfigMap delivers) and serves the config-driven @message@ from it (Sprint 20.1),
so the served value is whatever the active config carries.
-}
serveWeb :: IO ()
serveWeb = do
    cfg <-
        Schema.requireSiblingProjectConfig
            (T.pack "hostbootstrap-demo")
            Context.ServiceCommand
            [Context.DurableStore] ::
            IO ProjectConfig
    WebServiceConfig publicPort' acceleratorPort' <-
        case service cfg of
            Just (Web params) -> pure params
            _ -> ioError (userError "service run: Web handler requires the Web ServiceType variant")
    createDirectoryIfMissing True durableRoot
    durableRootExists <- doesDirectoryExist durableRoot
    unless durableRootExists $
        ioError (userError ("service run: durable root is not a directory: " ++ durableRoot))
    let msg = message cfg
        publicPort = fromIntegral publicPort'
        acceleratorPort = fromIntegral acceleratorPort'
    hub <- newAcceleratorHub
    putStrLn ("web serve: public HTTP on http://0.0.0.0:" ++ show publicPort ++ "; daemon ingress on ws://0.0.0.0:" ++ show acceleratorPort ++ "/api/accelerator/daemon; message=" ++ T.unpack msg)
    runLinkedListeners publicPort (app msg hub) acceleratorPort (acceleratorIngressApp hub)

{- | Run both listeners as one service lifetime. A bind/runtime failure in either
listener terminates the other and fails the handler, so Kubernetes can never
keep a public-ready pod whose private accelerator ingress died silently.
-}
runLinkedListeners :: Int -> Application -> Int -> Application -> IO ()
runLinkedListeners publicPort publicApp acceleratorPort ingressApp =
    mask $ \restore -> do
        finished <- newEmptyMVar
        publicThread <- forkFinally (run publicPort publicApp) (\outcome -> putMVar finished ("public", outcome))
        ingressThread <-
            forkFinally (run acceleratorPort ingressApp) (\outcome -> putMVar finished ("accelerator", outcome))
                `onException` killThread publicThread
        let stop = killThread publicThread >> killThread ingressThread
        (label, outcome) <- restore (takeMVar finished) `finally` stop
        case outcome of
            Left err -> throwIO err
            Right () -> ioError (userError (label ++ " web listener stopped unexpectedly"))
