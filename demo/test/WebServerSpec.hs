{-# LANGUAGE OverloadedStrings #-}

module WebServerSpec (tests) where

import Control.Concurrent (MVar, forkFinally, forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeException, bracket, finally, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import HostBootstrapDemo.Accelerator (AcceleratorBackend (LinuxCpuBackend), workerSpec)
import HostBootstrapDemo.Accelerator.Daemon (DaemonClientConfig (DaemonClientConfig), WebSocketEndpoint (WebSocketEndpoint), runDaemonClientLoop, webSocketDaemonTransportWithShutdown, workerSupervisor)
import HostBootstrapDemo.Accelerator.Protocol (AcceleratorMessage (..), decodeAcceleratorMessage, encodeAcceleratorMessage)
import HostBootstrapDemo.Web.Api (AcceleratorAddResult (AcceleratorAddResult), addRequestId, mkAcceleratorAddRequest)
import HostBootstrapDemo.Web.Server (acceleratorDaemonConnected, acceleratorDispatch, acceleratorIngressApp, app, appAtDurableRoot, newAcceleratorHub, runLinkedListeners)
import Network.HTTP.Types (Method, methodGet, methodPost, methodPut, status200, status404, status405, status503)
import Network.Wai (Application, Response, defaultRequest, pathInfo, requestMethod, responseStatus, responseToStream)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Internal (ResponseReceived (ResponseReceived))
import qualified Network.WebSockets as WS
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "WebServerSpec"
        [ testCase "accelerator dispatch has no in-process fallback" $ do
            hub <- newAcceleratorHub
            response <- acceleratorDispatch hub (mkAcceleratorAddRequest "no-daemon" 1.5 2.25)
            responseStatus response @?= status503
        , testCase "durable marker POST writes on disk and GET reads it" $
            withTemporaryDirectory $ \root -> do
                hub <- newAcceleratorHub
                let durableApp = appAtDurableRoot root "test" hub
                    expected = "hostbootstrap-destroy-up-v1" :: BS.ByteString
                posted <- requestDurableMarker durableApp methodPost
                responseStatus posted @?= status200
                BS.readFile (root </> "marker") >>= (@?= expected)
                fetched <- requestDurableMarker durableApp methodGet
                responseStatus fetched @?= status200
                responseBody fetched >>= (@?= LBS.fromStrict expected)
        , testCase "durable marker returns 404 before write and rejects unsupported methods" $
            withTemporaryDirectory $ \root -> do
                hub <- newAcceleratorHub
                let durableApp = appAtDurableRoot root "test" hub
                missing <- requestDurableMarker durableApp methodGet
                responseStatus missing @?= status404
                rejected <- requestDurableMarker durableApp methodPut
                responseStatus rejected @?= status405
        , testCase "dedicated ingress carries a real WebSocket request" $ do
            hub <- newAcceleratorHub
            testWithApplication (pure (acceleratorIngressApp hub)) $ \port -> do
                ready <- newEmptyMVar
                daemonThread <- forkIO (fakeDaemon ready port)
                ( do
                        takeWithin "fake daemon connection" ready
                        connected <- waitUntil 100 (acceleratorDaemonConnected hub)
                        assertBool "server registered the socket peer" connected
                        response <- acceleratorDispatch hub (mkAcceleratorAddRequest "socket" 1.5 2.25)
                        responseStatus response @?= status200
                    )
                    `finally` killThread daemonThread
        , testCase "busy request does not disconnect the healthy in-flight peer" $ do
            hub <- newAcceleratorHub
            testWithApplication (pure (acceleratorIngressApp hub)) $ \port -> do
                ready <- newEmptyMVar
                received <- newEmptyMVar
                release <- newEmptyMVar
                firstResult <- newEmptyMVar
                daemonThread <- forkIO (blockingDaemon ready received release port)
                ( do
                        takeWithin "blocking daemon connection" ready
                        connected <- waitUntil 100 (acceleratorDaemonConnected hub)
                        assertBool "server registered the socket peer" connected
                        _ <- forkIO (acceleratorDispatch hub (mkAcceleratorAddRequest "first" 1 2) >>= putMVar firstResult)
                        takeWithin "first request delivery" received
                        busy <- acceleratorDispatch hub (mkAcceleratorAddRequest "busy" 10 20)
                        responseStatus busy @?= status503
                        putMVar release ()
                        first <- takeWithin "first request response" firstResult
                        responseStatus first @?= status200
                    )
                    `finally` killThread daemonThread
        , testCase "public HTTP listener rejects daemon WebSocket registration" $ do
            hub <- newAcceleratorHub
            testWithApplication (pure (app "test" hub)) $ \port -> do
                outcome <- try (WS.runClient "127.0.0.1" port "/api/accelerator/daemon" (const (pure ()))) :: IO (Either SomeException ())
                assertBool "the public application must not upgrade daemon connections" (either (const True) (const False) outcome)
        , testCase "real WebSocket transport stays idle past worker timeout and shuts down cleanly" $ do
            hub <- newAcceleratorHub
            testWithApplication (pure (acceleratorIngressApp hub)) $ \port -> do
                shutdown <- newIORef False
                done <- newEmptyMVar
                let endpoint = WebSocketEndpoint "127.0.0.1" port "/api/accelerator/daemon"
                    spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
                    supervisor = workerSupervisor spec (const (pure (Right 0)))
                    transport = webSocketDaemonTransportWithShutdown endpoint (readIORef shutdown)
                clientThread <-
                    forkFinally
                        (runDaemonClientLoop (DaemonClientConfig 0 10000) supervisor transport)
                        (putMVar done)
                ( do
                        connected <- waitUntil 2000 (acceleratorDaemonConnected hub)
                        assertBool "concrete daemon client connected" connected
                        threadDelay 100000
                        stillConnected <- acceleratorDaemonConnected hub
                        assertBool "idle connection outlived its worker timeout" stillConnected
                        writeIORef shutdown True
                        stopped <- takeWithin "concrete daemon shutdown" done
                        case stopped of
                            Left err -> assertFailure ("concrete daemon loop failed: " ++ show err)
                            Right () -> pure ()
                        disconnected <- waitUntil 2000 (not <$> acceleratorDaemonConnected hub)
                        assertBool "server cleared the gracefully closed daemon peer" disconnected
                    )
                    `finally` killThread clientThread
        , testCase "a private-listener bind failure terminates the linked service" $ do
            hub <- newAcceleratorHub
            testWithApplication (pure (app "occupied" hub)) $ \occupiedPort -> do
                outcome <-
                    timeout
                        5000000
                        ( try (runLinkedListeners 0 (app "public" hub) occupiedPort (acceleratorIngressApp hub)) ::
                            IO (Either SomeException ())
                        )
                case outcome of
                    Nothing -> assertFailure "linked listeners did not fail after the private bind failed"
                    Just (Right ()) -> assertFailure "linked listeners returned success after the private bind failed"
                    Just (Left _) -> pure ()
        ]

requestDurableMarker :: Application -> Method -> IO Response
requestDurableMarker application method = do
    response <- newEmptyMVar
    _ <-
        application
            defaultRequest
                { requestMethod = method
                , pathInfo = ["api", "durable", "marker"]
                }
            (\result -> putMVar response result >> pure ResponseReceived)
    takeMVar response

responseBody :: Response -> IO LBS.ByteString
responseBody response = do
    let (_, _, withBody) = responseToStream response
    withBody $ \streamBody -> do
        chunks <- newIORef mempty
        streamBody (\chunk -> modifyIORef' chunks (<> chunk)) (pure ())
        Builder.toLazyByteString <$> readIORef chunks

withTemporaryDirectory :: (FilePath -> IO a) -> IO a
withTemporaryDirectory = bracket create removePathForcibly
  where
    create = do
        tmp <- getTemporaryDirectory
        (path, handle) <- openTempFile tmp "hostbootstrap-durable-marker"
        hClose handle
        removeFile path
        createDirectory path
        pure path

fakeDaemon :: MVar () -> Int -> IO ()
fakeDaemon ready port =
    WS.runClient "127.0.0.1" port "/api/accelerator/daemon" $ \conn -> do
        putMVar ready ()
        raw <- WS.receiveData conn :: IO BS.ByteString
        case decodeAcceleratorMessage raw of
            Right (AcceleratorRequest request) ->
                WS.sendBinaryData
                    conn
                    ( encodeAcceleratorMessage
                        (AcceleratorResult (AcceleratorAddResult (addRequestId request) 3.75 "socket-test" "test-hash"))
                    )
            Right other -> assertFailure ("expected request message, got " ++ show other)
            Left err -> assertFailure ("failed to decode request: " ++ show err)

blockingDaemon :: MVar () -> MVar () -> MVar () -> Int -> IO ()
blockingDaemon ready received release port =
    WS.runClient "127.0.0.1" port "/api/accelerator/daemon" $ \conn -> do
        putMVar ready ()
        raw <- WS.receiveData conn :: IO BS.ByteString
        putMVar received ()
        takeMVar release
        case decodeAcceleratorMessage raw of
            Right (AcceleratorRequest request) ->
                WS.sendBinaryData
                    conn
                    (encodeAcceleratorMessage (AcceleratorResult (AcceleratorAddResult (addRequestId request) 3 "socket-test" "test-hash")))
            Right other -> assertFailure ("expected request message, got " ++ show other)
            Left err -> assertFailure ("failed to decode request: " ++ show err)

waitUntil :: Int -> IO Bool -> IO Bool
waitUntil 0 _ = pure False
waitUntil attempts probe = do
    ready <- probe
    if ready
        then pure True
        else threadDelay 1000 >> waitUntil (attempts - 1) probe

takeWithin :: String -> MVar a -> IO a
takeWithin label value = do
    outcome <- timeout 5000000 (takeMVar value)
    case outcome of
        Just found -> pure found
        Nothing -> assertFailure (label ++ " timed out") >> takeMVar value
