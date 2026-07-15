{-# LANGUAGE OverloadedStrings #-}

module AcceleratorRuntimeSpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Control.Monad (void, when)
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import qualified Data.Text as T
import HostBootstrap.HostConfig (buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Clangxx, MsvcCl, Nvcc, Swiftc, Xcrun))
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..), detect)
import HostBootstrapDemo.Accelerator (AcceleratorBackend (..), WorkerSpec, workerArtifactHash, workerSpec)
import HostBootstrapDemo.Accelerator.Daemon (
    DaemonClientConfig (..),
    DaemonConnection (..),
    DaemonEvent (..),
    DaemonTransport (..),
    WebSocketEndpoint (..),
    WorkerSession (..),
    WorkerSupervisor (..),
    acceleratorBackendForSubstrate,
    buildWorkerArtifact,
    parseWebSocketEndpoint,
    persistentWorkerSupervisor,
    runDaemonClientLoop,
    runWorkerRequest,
    startWorkerSession,
    updateDaemonReadiness,
    webSocketDaemonTransportWithShutdown,
    workerSupervisor,
 )
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
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
        , testGroup "real worker build" realWorkerCases
        ]

protocolCases :: [TestTree]
protocolCases =
    [ testCase "request messages round-trip through CBOR" $ do
        let msg = AcceleratorRequest (AcceleratorAddRequest "req-1" 1.25 2.75)
        decodeAcceleratorMessage (encodeAcceleratorMessage msg) @?= Right msg
    , testCase "CBOR carries Float32-quantized values" $ do
        let rounded = realToFrac (16777217 :: Double) :: Float
            msg = AcceleratorRequest (AcceleratorAddRequest "req-f32" rounded 0)
        rounded @?= 16777216
        decodeAcceleratorMessage (encodeAcceleratorMessage msg)
            @?= Right (AcceleratorRequest (AcceleratorAddRequest "req-f32" 16777216 0))
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
    [ testCase "production WebSocket transport consumes its shutdown check" $ do
        let endpoint = WebSocketEndpoint "127.0.0.1" 30081 "/api/accelerator/daemon"
        shouldShutdown (webSocketDaemonTransportWithShutdown endpoint (pure True)) >>= (@?= True)
    , testCase "ws endpoint parser accepts explicit host port and path" $
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
    , testCase "persistent supervisor serves two requests through one session and closes it" $ do
        startsRef <- newIORef (0 :: Int)
        requestsRef <- newIORef []
        stopsRef <- newIORef (0 :: Int)
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            startSession = do
                modifyIORef' startsRef (+ 1)
                pure $
                    Right
                        WorkerSession
                            { sessionAdd = \request@(AcceleratorAddRequest _ leftVal rightVal) -> do
                                modifyIORef' requestsRef (++ [request])
                                pure (Right (leftVal + rightVal))
                            , stopWorkerSession = modifyIORef' stopsRef (+ 1)
                            }
            firstRequest = AcceleratorAddRequest "req-persistent-1" 1.5 2.25
            secondRequest = AcceleratorAddRequest "req-persistent-2" 10 5
        supervisor <- persistentWorkerSupervisor spec startSession
        firstResponse <- runWorkerRequest supervisor firstRequest
        secondResponse <- runWorkerRequest supervisor secondRequest
        firstResponse
            @?= AcceleratorSucceeded
                (AcceleratorAddResult "req-persistent-1" 3.75 "linux-cpu" (workerArtifactHash spec))
        secondResponse
            @?= AcceleratorSucceeded
                (AcceleratorAddResult "req-persistent-2" 15 "linux-cpu" (workerArtifactHash spec))
        readIORef startsRef >>= (@?= 1)
        readIORef requestsRef >>= (@?= [firstRequest, secondRequest])
        stopWorkerSupervisor supervisor
        readIORef stopsRef >>= (@?= 1)
    , testCase "persistent supervisor restarts a crashed session once" $ do
        startsRef <- newIORef (0 :: Int)
        stopsRef <- newIORef (0 :: Int)
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            startSession = do
                startNumber <- readIORef startsRef
                writeIORef startsRef (startNumber + 1)
                pure $
                    Right
                        WorkerSession
                            { sessionAdd = \(AcceleratorAddRequest _ leftVal rightVal) ->
                                if startNumber == 0
                                    then pure (Left "worker pipe closed")
                                    else pure (Right (leftVal + rightVal))
                            , stopWorkerSession = modifyIORef' stopsRef (+ 1)
                            }
        supervisor <- persistentWorkerSupervisor spec startSession
        response <- runWorkerRequest supervisor (AcceleratorAddRequest "req-restart" 4 6)
        response
            @?= AcceleratorSucceeded
                (AcceleratorAddResult "req-restart" 10 "linux-cpu" (workerArtifactHash spec))
        readIORef startsRef >>= (@?= 2)
        readIORef stopsRef >>= (@?= 1)
        stopWorkerSupervisor supervisor
        readIORef stopsRef >>= (@?= 2)
    , testCase "persistent supervisor clears a timed-out session before the next request" $ do
        startsRef <- newIORef (0 :: Int)
        stopsRef <- newIORef (0 :: Int)
        blockedRequest <- newEmptyMVar
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            startSession = do
                startNumber <- readIORef startsRef
                writeIORef startsRef (startNumber + 1)
                pure $
                    Right
                        WorkerSession
                            { sessionAdd = \(AcceleratorAddRequest _ leftVal rightVal) ->
                                if startNumber == 0
                                    then takeMVar blockedRequest
                                    else pure (Right (leftVal + rightVal))
                            , stopWorkerSession = modifyIORef' stopsRef (+ 1)
                            }
            request = AcceleratorAddRequest "req-timeout" 3 7
        supervisor <- persistentWorkerSupervisor spec startSession
        timedOut <- timeout 100000 (workerAdd supervisor request)
        timedOut @?= Nothing
        readIORef stopsRef >>= (@?= 1)
        response <- runWorkerRequest supervisor request
        response
            @?= AcceleratorSucceeded
                (AcceleratorAddResult "req-timeout" 10 "linux-cpu" (workerArtifactHash spec))
        readIORef startsRef >>= (@?= 2)
        stopWorkerSupervisor supervisor
        readIORef stopsRef >>= (@?= 2)
    , testCase "supervisor arithmetic has Float32 rounding semantics" $ do
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
        response <- runWorkerRequest (addSupervisor spec) (AcceleratorAddRequest "req-f32" 16777216 1)
        response
            @?= AcceleratorSucceeded
                (AcceleratorAddResult "req-f32" 16777216 "linux-cpu" (workerArtifactHash spec))
    ]

loopCases :: [TestTree]
loopCases =
    [ testCase "connection events maintain the daemon readiness marker" $ do
        tmp <- getTemporaryDirectory
        (readyPath, handle) <- openTempFile tmp "hostbootstrap-accelerator-ready"
        hClose handle
        removeFile readyPath
        let cleanup = do
                present <- doesFileExist readyPath
                when present (removeFile readyPath)
        ( do
                updateDaemonReadiness (Just readyPath) DaemonConnected
                doesFileExist readyPath >>= (@?= True)
                updateDaemonReadiness (Just readyPath) (DaemonRequestHandled "request")
                doesFileExist readyPath >>= (@?= True)
                updateDaemonReadiness (Just readyPath) DaemonDisconnected
                doesFileExist readyPath >>= (@?= False)
            )
            `finally` cleanup
    , testCase "client loop receives a request, runs the worker, sends a correlated response, and stops" $ do
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
    , testCase "injected shutdown interrupts a blocked receive and closes the connection" $ do
        receiveStarted <- newEmptyMVar
        blockedReceive <- newEmptyMVar
        shutdownRef <- newIORef False
        closedRef <- newIORef False
        eventsRef <- newIORef []
        let spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            connection =
                DaemonConnection
                    { receiveRequest = do
                        putMVar receiveStarted ()
                        takeMVar blockedReceive
                    , sendResponse = \_ -> pure ()
                    , closeConnection = writeIORef closedRef True
                    }
            transport =
                DaemonTransport
                    { connectDaemon = pure (Right connection)
                    , shouldShutdown = readIORef shutdownRef
                    , onDaemonEvent = \event -> modifyIORef' eventsRef (++ [event])
                    }
        void . forkIO $ do
            takeMVar receiveStarted
            writeIORef shutdownRef True
        runDaemonClientLoop (DaemonClientConfig 0 10000000) (addSupervisor spec) transport
        readIORef closedRef >>= (@?= True)
        readIORef eventsRef >>= (@?= [DaemonConnected, DaemonStopping])
    , testCase "idle connection outlives the worker request timeout without reconnecting" $ do
        shutdownRef <- newIORef False
        eventsRef <- newIORef []
        receivedRef <- newIORef False
        let req = AcceleratorAddRequest "req-after-idle" 4 5
            spec = workerSpec "/tmp/accelerator" LinuxCpuBackend
            connection =
                DaemonConnection
                    { receiveRequest = do
                        received <- readIORef receivedRef
                        if received
                            then pure Nothing
                            else do
                                threadDelay 100000
                                writeIORef receivedRef True
                                pure (Just req)
                    , sendResponse = \_ -> writeIORef shutdownRef True
                    , closeConnection = pure ()
                    }
            transport =
                DaemonTransport
                    { connectDaemon = pure (Right connection)
                    , shouldShutdown = readIORef shutdownRef
                    , onDaemonEvent = \event -> modifyIORef' eventsRef (++ [event])
                    }
        runDaemonClientLoop (DaemonClientConfig 0 10000) (addSupervisor spec) transport
        readIORef eventsRef >>= (@?= [DaemonConnected, DaemonRequestHandled "req-after-idle", DaemonStopping])
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

{- | The real per-lane worker gate (accelerator_daemon.md § Tests): on a host whose
detected substrate has an accelerator lane AND whose build toolchain resolves,
generate the worker source, build it with the REAL compiler (@nvcc@ / @clang++@ /
@swiftc@), run the subprocess, and assert it computes @1.5 + 2.25 = 3.75@ with a
real artifact hash. When the toolchain is absent (a host with no compiler for the
lane) the case is a no-op skip — the install/ensure side is Phase 3's gate, this
is the build-and-run side. It builds WITHOUT ensure ('buildWorkerArtifact'), so it
never triggers an install. On this host's detected substrate it exercises the real
lane: e.g. on Windows GPU it builds the CUDA worker with @nvcc -ccbin \<msvc\>@ and
runs it on the GPU; on a Linux CPU host it builds the C++ worker with @clang++@.
Because @detect@ only classifies @linux-gpu@ / @windows-gpu@ when @nvidia-smi@
answers, a GPU lane implies a usable device, so the run is sound.
-}
realWorkerCases :: [TestTree]
realWorkerCases =
    [ testCase "detected-substrate worker builds and computes 1.5 + 2.25 = 3.75 (guarded on toolchain)" $ do
        detected <- detect
        case detected of
            Left _ -> pure ()
            Right sub ->
                case acceleratorBackendForSubstrate sub of
                    Left _ -> pure () -- no accelerator lane on this substrate (windows-cpu)
                    Right lane -> do
                        cfg <- buildHostConfig sub
                        if not (all (\t -> isJust (resolveMaybe cfg t)) (neededTools lane))
                            then pure () -- the lane's compiler is not installed on this host; skip
                            else do
                                tmp <- getTemporaryDirectory
                                let root = tmp </> "hostbootstrap-accelerator-smoke"
                                spec <- buildWorkerArtifact cfg root lane
                                started <- startWorkerSession spec
                                session <- either (assertFailure . T.unpack) pure started
                                (first, second) <-
                                    ( do
                                        first <- sessionAdd session (AcceleratorAddRequest "smoke-1" 1.5 2.25)
                                        second <- sessionAdd session (AcceleratorAddRequest "smoke-2" 16777216 1)
                                        pure (first, second)
                                    )
                                        `finally` stopWorkerSession session
                                first @?= Right 3.75
                                -- Every backend implements Float32 semantics;
                                -- 2^24 + 1 rounds back to 2^24.
                                second @?= Right 16777216
                                assertBool
                                    "worker artifact hash is 16 lowercase hex chars"
                                    (isStableHash (workerArtifactHash spec))
    ]

{- | The compiler(s) each lane's worker build resolves; the smoke runs only when all
of them are present on the host (so it is a skip on a toolchain-less host).
-}
neededTools :: AcceleratorBackend -> [HostTool]
neededTools AppleMetalBackend = [Swiftc, Xcrun]
neededTools LinuxCpuBackend = [Clangxx]
neededTools LinuxGpuBackend = [Nvcc]
neededTools WindowsGpuBackend = [Nvcc, MsvcCl]

isStableHash :: T.Text -> Bool
isStableHash h = T.length h == 16 && T.all (`elem` ("0123456789abcdef" :: String)) h
