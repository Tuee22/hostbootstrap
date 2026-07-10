{-# LANGUAGE OverloadedStrings #-}

module AcceleratorRuntimeSpec (tests) where

import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import HostBootstrapDemo.Accelerator (AcceleratorBackend (..), WorkerSpec, workerArtifactHash, workerSpec)
import HostBootstrapDemo.Accelerator.Daemon (
    DaemonClientConfig (..),
    DaemonConnection (..),
    DaemonEvent (..),
    DaemonTransport (..),
    WorkerSupervisor,
    WebSocketEndpoint (..),
    acceleratorBackendForSubstrate,
    parseWebSocketEndpoint,
    runDaemonClientLoop,
    runWorkerRequest,
    workerSupervisor,
 )
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import HostBootstrapDemo.Accelerator.Protocol (
    AcceleratorMessage (..),
    AcceleratorResponse (..),
    correlateResponse,
    decodeAcceleratorMessage,
    encodeAcceleratorMessage,
 )
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (..),
    AcceleratorAddRequest (..),
    AcceleratorAddResult (..),
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "AcceleratorRuntimeSpec"
        [ testGroup "CBOR protocol" protocolCases
        , testGroup "request correlation" correlationCases
        , testGroup "endpoint parsing" endpointCases
        , testGroup "backend selection" backendCases
        , testGroup "worker supervision" workerCases
        , testGroup "daemon client loop" loopCases
        ]

protocolCases :: [TestTree]
protocolCases =
    [ testCase "request messages round-trip through CBOR" $ do
        let msg = AcceleratorRequest (AcceleratorAddRequest "req-1" 1.25 2.75)
        decodeAcceleratorMessage (encodeAcceleratorMessage msg) @?= Right msg
    , testCase "result messages round-trip through CBOR" $ do
        let msg = AcceleratorResult (AcceleratorAddResult "req-2" 4.0 "linux-cpu" "abc123")
        decodeAcceleratorMessage (encodeAcceleratorMessage msg) @?= Right msg
    , testCase "failure messages round-trip through CBOR" $ do
        let msg = AcceleratorFailure (AcceleratorAddFailure "req-3" "worker failed" "linux-cpu" "abc123")
        decodeAcceleratorMessage (encodeAcceleratorMessage msg) @?= Right msg
    , testCase "invalid CBOR payload is rejected" $
        assertBool "invalid payload should fail to decode" (isLeft (decodeAcceleratorMessage "\255"))
    ]

correlationCases :: [TestTree]
correlationCases =
    [ testCase "matching response id is accepted" $ do
        let response = AcceleratorSucceeded (AcceleratorAddResult "req-1" 3.0 "linux-cpu" "hash")
        correlateResponse "req-1" response @?= Right response
    , testCase "mismatched response id is rejected" $ do
        let response = AcceleratorFailed (AcceleratorAddFailure "req-2" "boom" "linux-cpu" "hash")
        assertBool "mismatched request ids should fail" (isLeft (correlateResponse "req-1" response))
    ]

endpointCases :: [TestTree]
endpointCases =
    [ testCase "ws endpoint parser accepts explicit host port and path" $
        parseWebSocketEndpoint "ws://127.0.0.1:30081/api/accelerator/daemon"
            @?= Right (WebSocketEndpoint "127.0.0.1" 30081 "/api/accelerator/daemon")
    , testCase "ws endpoint parser defaults the port" $
        parseWebSocketEndpoint "ws://hostbootstrap-demo-web/api/accelerator/daemon"
            @?= Right (WebSocketEndpoint "hostbootstrap-demo-web" 80 "/api/accelerator/daemon")
    , testCase "ws endpoint parser rejects non-ws schemes" $
        assertBool "https is rejected" (isLeft (parseWebSocketEndpoint "https://example.test/daemon"))
    ]

backendCases :: [TestTree]
backendCases =
    [ testCase "substrates select the expected accelerator backend" $ do
        acceleratorBackendForSubstrate (Substrate AppleSilicon Arm64) @?= Right AppleMetalBackend
        acceleratorBackendForSubstrate (Substrate LinuxCpu Amd64) @?= Right LinuxCpuBackend
        acceleratorBackendForSubstrate (Substrate LinuxGpu Amd64) @?= Right LinuxGpuBackend
        acceleratorBackendForSubstrate (Substrate WindowsGpu Amd64) @?= Right WindowsGpuBackend
        assertBool "windows-cpu is not an accelerator lane" (isLeft (acceleratorBackendForSubstrate (Substrate WindowsCpu Amd64)))
    ]

workerCases :: [TestTree]
workerCases =
    [ testCase "worker supervisor wraps successful worker output with metadata" $ do
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            supervisor = addSupervisor spec
            req = AcceleratorAddRequest "req-1" 1.5 2.25
        response <- runWorkerRequest supervisor req
        response @?= AcceleratorSucceeded (AcceleratorAddResult "req-1" 3.75 "linux-cpu" (workerArtifactHash spec))
    , testCase "worker supervisor turns worker failure into daemon failure" $ do
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            supervisor =
                workerSupervisor spec $
                    \_ -> pure (Left "worker rejected input")
        response <- runWorkerRequest supervisor (AcceleratorAddRequest "req-2" 0 0)
        response @?= AcceleratorFailed (AcceleratorAddFailure "req-2" "worker rejected input" "linux-cpu" (workerArtifactHash spec))
    ]

loopCases :: [TestTree]
loopCases =
    [ testCase "client loop receives a request, runs the worker, sends a correlated response, and stops" $ do
        sentRef <- newIORef []
        eventsRef <- newIORef []
        receivedRef <- newIORef False
        shutdownRef <- newIORef False
        let req = AcceleratorAddRequest "req-loop" 10 5
            spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            supervisor = addSupervisor spec
            recordEvent event = modifyIORef' eventsRef (++ [event])
            connection =
                DaemonConnection
                    { receiveRequest = do
                        alreadyReceived <- readIORef receivedRef
                        if alreadyReceived
                            then pure Nothing
                            else do
                                writeIORef receivedRef True
                                pure (Just req)
                    , sendResponse = \response -> do
                        modifyIORef' sentRef (++ [response])
                        writeIORef shutdownRef True
                    , closeConnection = pure ()
                    }
            transport =
                DaemonTransport
                    { connectDaemon = pure (Right connection)
                    , shouldShutdown = readIORef shutdownRef
                    , onDaemonEvent = recordEvent
                    }
        runDaemonClientLoop (DaemonClientConfig 0 1000000) supervisor transport
        sent <- readIORef sentRef
        sent @?= [AcceleratorSucceeded (AcceleratorAddResult "req-loop" 15 "linux-cpu" (workerArtifactHash spec))]
        events <- readIORef eventsRef
        events @?= [DaemonConnected, DaemonRequestHandled "req-loop", DaemonStopping]
    , testCase "client loop reconnects after a connection exception" $ do
        attemptsRef <- newIORef (0 :: Int)
        sentRef <- newIORef []
        eventsRef <- newIORef []
        shutdownRef <- newIORef False
        let req = AcceleratorAddRequest "req-reconnect" 2 8
            spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            supervisor = addSupervisor spec
            recordEvent event = modifyIORef' eventsRef (++ [event])
            brokenConnection =
                DaemonConnection
                    { receiveRequest = ioError (userError "socket closed")
                    , sendResponse = \_ -> pure ()
                    , closeConnection = pure ()
                    }
            healthyConnection =
                DaemonConnection
                    { receiveRequest = pure (Just req)
                    , sendResponse = \response -> do
                        modifyIORef' sentRef (++ [response])
                        writeIORef shutdownRef True
                    , closeConnection = pure ()
                    }
            transport =
                DaemonTransport
                    { connectDaemon = do
                        attempts <- readIORef attemptsRef
                        writeIORef attemptsRef (attempts + 1)
                        pure (Right (if attempts == 0 then brokenConnection else healthyConnection))
                    , shouldShutdown = readIORef shutdownRef
                    , onDaemonEvent = recordEvent
                    }
        runDaemonClientLoop (DaemonClientConfig 0 1000000) supervisor transport
        sent <- readIORef sentRef
        sent @?= [AcceleratorSucceeded (AcceleratorAddResult "req-reconnect" 10 "linux-cpu" (workerArtifactHash spec))]
        events <- readIORef eventsRef
        events @?= [DaemonConnected, DaemonDisconnected, DaemonConnected, DaemonRequestHandled "req-reconnect", DaemonStopping]
    ]

addSupervisor :: WorkerSpec -> WorkerSupervisor
addSupervisor spec =
    workerSupervisor spec $
        \(AcceleratorAddRequest _ leftVal rightVal) -> pure (Right (leftVal + rightVal))
