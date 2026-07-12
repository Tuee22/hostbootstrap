{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Accelerator daemon runtime seams.

The daemon loop owns reconnect, timeout, shutdown, and worker supervision. The
concrete WebSocket client is expressed through 'DaemonTransport' so the protocol
path stays unit-testable without opening a socket.
-}
module HostBootstrapDemo.Accelerator.Daemon (
    DaemonClientConfig (..),
    DaemonConnection (..),
    DaemonEvent (..),
    DaemonTransport (..),
    WebSocketEndpoint (..),
    WorkerSession (..),
    WorkerSupervisor (..),
    acceleratorBackendForSubstrate,
    buildWorkerArtifact,
    buildWorkerWithHostConfig,
    defaultDaemonClientConfig,
    parseWebSocketEndpoint,
    persistentWorkerSupervisor,
    runDaemonClientLoop,
    runWorkerProcess,
    runWorkerRequest,
    serveAcceleratorDaemon,
    startWorkerSession,
    webSocketDaemonTransport,
    webSocketDaemonTransportWithShutdown,
    webSocketEndpointFromEnv,
    workerSupervisor,
)
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, newMVar, takeMVar, tryPutMVar, withMVar)
import Control.Exception (IOException, SomeAsyncException, SomeException, finally, fromException, mask, onException, throwIO, try, tryJust)
import Control.Monad (unless, void, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure (runEnsure, runTool)
import qualified HostBootstrap.Ensure.AppleMetal as AppleMetal
import qualified HostBootstrap.Ensure.CudaWin as CudaWin
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Clangxx, MsvcCl, Nvcc, Swiftc, Xcrun), absExePath)
import HostBootstrap.Substrate (Substrate, SubstrateName (..), detect, substrateName)
import HostBootstrapDemo.Accelerator (
    AcceleratorBackend (..),
    WorkerSpec,
    backendName,
    cppBuildArgs,
    cudaBuildArgs,
    swiftMetalBuildArgs,
    workerArtifactHash,
    workerBackend,
    workerExecutablePath,
    workerSourcePath,
    workerSourceText,
    workerSpec,
 )
import HostBootstrapDemo.Accelerator.Protocol (
    AcceleratorMessage (..),
    AcceleratorResponse (..),
    decodeAcceleratorMessage,
    encodeAcceleratorMessage,
 )
import HostBootstrapDemo.Config (AcceleratorServiceConfig (requestTimeoutSeconds), ProjectConfig (context, service), ServiceType (Accelerator))
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (AcceleratorAddFailure),
    AcceleratorAddRequest (AcceleratorAddRequest),
    AcceleratorAddResult (AcceleratorAddResult),
 )
import qualified Network.WebSockets as WS
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), die)
import System.FilePath (takeDirectory, takeExtension, (<.>), (</>))
import System.IO (BufferMode (LineBuffering), Handle, hClose, hFlush, hGetLine, hPutStrLn, hSetBuffering, openTempFile)
import System.Process (
    ProcessHandle,
    StdStream (CreatePipe, Inherit),
    createProcess,
    proc,
    readProcessWithExitCode,
    std_err,
    std_in,
    std_out,
    terminateProcess,
    waitForProcess,
 )
import System.Timeout (timeout)
import Text.Read (readMaybe)

data DaemonClientConfig = DaemonClientConfig
    { reconnectDelayMicros :: Int
    , requestTimeoutMicros :: Int
    }
    deriving (Eq, Show)

defaultDaemonClientConfig :: DaemonClientConfig
defaultDaemonClientConfig =
    DaemonClientConfig
        { reconnectDelayMicros = 1000000
        , requestTimeoutMicros = 30000000
        }

data DaemonConnection = DaemonConnection
    { receiveRequest :: IO (Maybe AcceleratorAddRequest)
    , sendResponse :: AcceleratorResponse -> IO ()
    , closeConnection :: IO ()
    }

data DaemonTransport = DaemonTransport
    { connectDaemon :: IO (Either Text DaemonConnection)
    , shouldShutdown :: IO Bool
    , onDaemonEvent :: DaemonEvent -> IO ()
    }

data DaemonEvent
    = DaemonConnected
    | DaemonConnectFailed Text
    | DaemonDisconnected
    | DaemonRequestHandled Text
    | DaemonRequestTimedOut Text
    | DaemonRequestFailed Text Text
    | DaemonStopping
    deriving (Eq, Show)

data ReceiveOutcome
    = ReceiveCompleted (Maybe AcceleratorAddRequest)
    | ReceiveFailed SomeException
    | ReceiveShutdown

data WorkerSupervisor = WorkerSupervisor
    { supervisedBackend :: Text
    , supervisedArtifactHash :: Text
    , workerAdd :: AcceleratorAddRequest -> IO (Either Text Float)
    , stopWorkerSupervisor :: IO ()
    }

data WorkerSession = WorkerSession
    { sessionAdd :: AcceleratorAddRequest -> IO (Either Text Float)
    , stopWorkerSession :: IO ()
    }

workerSupervisor :: WorkerSpec -> (AcceleratorAddRequest -> IO (Either Text Float)) -> WorkerSupervisor
workerSupervisor spec action =
    WorkerSupervisor
        { supervisedBackend = backendName (workerBackend spec)
        , supervisedArtifactHash = workerArtifactHash spec
        , workerAdd = action
        , stopWorkerSupervisor = pure ()
        }

{- | Serialize requests through one long-lived worker process. A failed session is
closed and the same request is retried once in a freshly started session. The
supervisor owns the cached session and must be stopped when the daemon exits.
-}
persistentWorkerSupervisor :: WorkerSpec -> IO (Either Text WorkerSession) -> IO WorkerSupervisor
persistentWorkerSupervisor spec startSession = do
    sessionLock <- newMVar ()
    sessionRef <- newIORef Nothing
    let closeCurrentSession = do
            session <- readIORef sessionRef
            writeIORef sessionRef Nothing
            closeSessionQuiet session
        stop = withMVar sessionLock (const closeCurrentSession)
        add request = withMVar sessionLock $ \_ ->
            handleRequest request
                `onException` closeCurrentSession
        handleRequest request = do
            firstResult <- runSessionAttempt startSession sessionRef request
            case firstResult of
                Right value -> pure (Right value)
                Left firstError -> do
                    closeCurrentSession
                    retryResult <- runSessionAttempt startSession sessionRef request
                    case retryResult of
                        Right value -> pure (Right value)
                        Left retryError -> do
                            closeCurrentSession
                            pure
                                ( Left
                                    ( "accelerator worker failed after one restart: "
                                        <> retryError
                                        <> " (initial failure: "
                                        <> firstError
                                        <> ")"
                                    )
                                )
    pure
        WorkerSupervisor
            { supervisedBackend = backendName (workerBackend spec)
            , supervisedArtifactHash = workerArtifactHash spec
            , workerAdd = add
            , stopWorkerSupervisor = stop
            }

runSessionAttempt :: IO (Either Text WorkerSession) -> IORef (Maybe WorkerSession) -> AcceleratorAddRequest -> IO (Either Text Float)
runSessionAttempt startSession sessionRef request = do
    existing <- readIORef sessionRef
    sessionResult <-
        case existing of
            Just session -> pure (Right session)
            Nothing ->
                mask $ \restore -> do
                    started <- restore (try startSession)
                    case (started :: Either IOException (Either Text WorkerSession)) of
                        Left err -> pure (Left (T.pack (show err)))
                        Right (Left err) -> pure (Left err)
                        Right (Right session) -> do
                            writeIORef sessionRef (Just session)
                            pure (Right session)
    case sessionResult of
        Left err -> pure (Left err)
        Right session -> do
            result <- try (sessionAdd session request)
            pure
                ( case (result :: Either IOException (Either Text Float)) of
                    Left err -> Left (T.pack (show err))
                    Right value -> value
                )

closeSessionQuiet :: Maybe WorkerSession -> IO ()
closeSessionQuiet Nothing = pure ()
closeSessionQuiet (Just session) =
    void (try (stopWorkerSession session) :: IO (Either SomeException ()))

data WebSocketEndpoint = WebSocketEndpoint
    { endpointHost :: String
    , endpointPort :: Int
    , endpointPath :: String
    }
    deriving (Eq, Show)

parseWebSocketEndpoint :: String -> Either Text WebSocketEndpoint
parseWebSocketEndpoint raw = do
    withoutScheme <-
        maybe
            (Left "accelerator daemon endpoint must use ws://")
            Right
            (stripPrefix "ws://" raw)
    let (hostPort, pathPart) = break (== '/') withoutScheme
        path = if null pathPart then "/" else pathPart
        (hostPart, portPart0) = break (== ':') hostPort
    if null hostPart
        then Left "accelerator daemon endpoint host is empty"
        else do
            port <-
                case portPart0 of
                    "" -> Right 80
                    ':' : portText ->
                        maybe
                            (Left ("accelerator daemon endpoint port is invalid: " <> T.pack portText))
                            Right
                            (readMaybe portText)
                    _ -> Left "accelerator daemon endpoint is malformed"
            Right (WebSocketEndpoint hostPart port path)

webSocketEndpointFromEnv :: IO WebSocketEndpoint
webSocketEndpointFromEnv = do
    raw <- lookupEnv "HOSTBOOTSTRAP_ACCELERATOR_WS_URL"
    case parseWebSocketEndpoint (fromMaybe defaultEndpoint raw) of
        Left err -> die (T.unpack err)
        Right endpoint -> pure endpoint
  where
    defaultEndpoint = "ws://127.0.0.1:30081/api/accelerator/daemon"

acceleratorBackendForSubstrate :: Substrate -> Either Text AcceleratorBackend
acceleratorBackendForSubstrate sub =
    case substrateName sub of
        AppleSilicon -> Right AppleMetalBackend
        LinuxCpu -> Right LinuxCpuBackend
        LinuxGpu -> Right LinuxGpuBackend
        WindowsGpu -> Right WindowsGpuBackend
        WindowsCpu -> Left "the accelerator demo has no windows-cpu worker lane"

buildWorkerWithHostConfig :: HostConfig -> FilePath -> AcceleratorBackend -> IO WorkerSpec
buildWorkerWithHostConfig cfg0 root backend = do
    cfg <- ensureBackend cfg0 backend
    buildWorkerArtifact cfg root backend

{- | Generate the worker source and build it, WITHOUT running the substrate
build-stack ensure. 'buildWorkerWithHostConfig' runs 'ensureBackend' first (the
host-daemon startup path); this is the pure-build seam a caller uses when the
toolchain is already known present (the guarded worker smoke test), so it never
triggers a @winget@/Homebrew install. Idempotent: an already-built artifact is
reused.
-}
buildWorkerArtifact :: HostConfig -> FilePath -> AcceleratorBackend -> IO WorkerSpec
buildWorkerArtifact cfg root backend = do
    let spec = workerSpec root backend
    createDirectoryIfMissing True (takeDirectory (workerSourcePath spec))
    TIO.writeFile (workerSourcePath spec) (workerSourceText spec)
    existing <- firstExisting (workerBinaryCandidates spec)
    maybe (buildWorkerAtomically cfg spec) (const (pure ())) existing
    pure spec

buildWorkerAtomically :: HostConfig -> WorkerSpec -> IO ()
buildWorkerAtomically cfg spec = do
    let finalBase = workerExecutablePath spec
    (temporaryBase, temporaryHandle) <- openTempFile (takeDirectory finalBase) "accelerator-worker-building"
    hClose temporaryHandle
    removeFile temporaryBase
    let temporaryCandidates = [temporaryBase, temporaryBase <.> "exe"]
        cleanupTemporary = mapM_ removeWhenPresent temporaryCandidates
    buildWorker cfg spec temporaryBase `onException` cleanupTemporary
    built <- firstExisting temporaryCandidates
    case built of
        Nothing -> cleanupTemporary >> die "accelerator worker build succeeded without producing an executable"
        Just temporaryExecutable -> do
            let finalExecutable =
                    if takeExtension temporaryExecutable == ".exe"
                        then finalBase <.> "exe"
                        else finalBase
            alreadyBuilt <- doesFileExist finalExecutable
            if alreadyBuilt
                then cleanupTemporary
                else renameFile temporaryExecutable finalExecutable `onException` cleanupTemporary
  where
    removeWhenPresent path = do
        present <- doesFileExist path
        when present (removeFile path)

{- | The on-disk executable a build may have produced. The pure 'workerSpec' names
the LOGICAL build target @accelerator-worker@ (no extension), but the host linker
appends the platform extension — on Windows @nvcc -o accelerator-worker@ actually
writes @accelerator-worker.exe@. So the daemon must probe both forms both for the
build-cache check and for running the worker; the platform extension is the
daemon's OWN host's (where the worker is built and run), not baked into the pure
spec (which the unit suite asserts is extension-free and platform-independent).
-}
workerBinaryCandidates :: WorkerSpec -> [FilePath]
workerBinaryCandidates spec =
    [workerExecutablePath spec, workerExecutablePath spec <.> "exe"]

firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting [] = pure Nothing
firstExisting (p : ps) = do
    here <- doesFileExist p
    if here then pure (Just p) else firstExisting ps

ensureBackend :: HostConfig -> AcceleratorBackend -> IO HostConfig
ensureBackend cfg backend =
    case backend of
        AppleMetalBackend -> runEnsure AppleMetal.reconciler >> buildHostConfig (hcSubstrate cfg)
        WindowsGpuBackend -> runEnsure CudaWin.reconciler >> buildHostConfig (hcSubstrate cfg)
        LinuxCpuBackend -> pure cfg
        LinuxGpuBackend -> pure cfg

buildWorker :: HostConfig -> WorkerSpec -> FilePath -> IO ()
buildWorker cfg spec outputPath =
    case workerBackend spec of
        AppleMetalBackend -> do
            sdk <- macosSdkPathOrDie cfg
            runBuild cfg Swiftc (swiftMetalBuildArgs sdk (workerSourcePath spec) outputPath)
        LinuxCpuBackend ->
            runBuild cfg Clangxx (cppBuildArgs (workerSourcePath spec) outputPath)
        LinuxGpuBackend ->
            runBuild cfg Nvcc (cudaBuildArgs (workerSourcePath spec) outputPath)
        WindowsGpuBackend ->
            case resolveMaybe cfg MsvcCl of
                Nothing -> die "accelerator worker: cl.exe not resolved after ensure-cudawin"
                Just clExe ->
                    runBuild
                        cfg
                        Nvcc
                        ( "-ccbin"
                            : takeDirectory (absExePath clExe)
                            : cudaBuildArgs (workerSourcePath spec) outputPath
                        )

macosSdkPathOrDie :: HostConfig -> IO FilePath
macosSdkPathOrDie cfg = do
    result <- runTool cfg Xcrun ["--sdk", "macosx", "--show-sdk-path"]
    case result of
        Right (_, out, _) | sdk : _ <- lines out, not (null sdk) -> pure sdk
        Right (_, _, err) -> die ("accelerator worker: xcrun did not return a macOS SDK path: " ++ err)
        Left err -> die ("accelerator worker: " ++ err)

runBuild :: HostConfig -> HostTool -> [String] -> IO ()
runBuild cfg tool args = do
    result <- runTool cfg tool args
    case result of
        Right (code, out, err) ->
            case code of
                ExitSuccess -> unless (null out) (putStr out)
                ExitFailure n -> die ("accelerator worker build failed (exit " ++ show n ++ ")\n" ++ out ++ err)
        Left err -> die ("accelerator worker build could not run: " ++ err)

{- | Start one persistent newline-delimited worker session. Requests are written
and responses are read synchronously; 'persistentWorkerSupervisor' supplies the
serialization and restart policy around this process-level session.
-}
startWorkerSession :: WorkerSpec -> IO (Either Text WorkerSession)
startWorkerSession spec = do
    mExe <- firstExisting (workerBinaryCandidates spec)
    case mExe of
        Nothing ->
            pure (Left ("accelerator worker executable not found near " <> T.pack (workerExecutablePath spec)))
        Just exe ->
            mask $ \restore -> do
                started <-
                    restore
                        ( try
                            ( createProcess
                                (proc exe [])
                                    { std_in = CreatePipe
                                    , std_out = CreatePipe
                                    , std_err = Inherit
                                    }
                            )
                        )
                case (started :: Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)) of
                    Left err -> pure (Left (T.pack (show err)))
                    Right (Just inputHandle, Just outputHandle, _, processHandle) -> do
                        let cleanup = stopProcessSession inputHandle outputHandle processHandle
                        prepared <-
                            restore
                                ( try $ do
                                    hSetBuffering inputHandle LineBuffering
                                    hSetBuffering outputHandle LineBuffering
                                )
                                `onException` cleanup
                        case (prepared :: Either IOException ()) of
                            Left err -> cleanup >> pure (Left (T.pack (show err)))
                            Right () ->
                                pure
                                    ( Right
                                        WorkerSession
                                            { sessionAdd = runSessionRequest inputHandle outputHandle
                                            , stopWorkerSession = cleanup
                                            }
                                    )
                    Right (_, _, _, processHandle) -> do
                        terminateQuiet processHandle
                        pure (Left "accelerator worker process did not expose stdin and stdout pipes")

runSessionRequest :: Handle -> Handle -> AcceleratorAddRequest -> IO (Either Text Float)
runSessionRequest inputHandle outputHandle (AcceleratorAddRequest _ leftVal rightVal) = do
    result <-
        try $ do
            hPutStrLn inputHandle (show leftVal ++ " " ++ show rightVal)
            hFlush inputHandle
            hGetLine outputHandle
    pure $
        case (result :: Either IOException String) of
            Left err -> Left (T.pack (show err))
            Right output ->
                maybe
                    (Left ("accelerator worker returned non-numeric output: " <> T.pack output))
                    Right
                    (readMaybe output)

stopProcessSession :: Handle -> Handle -> ProcessHandle -> IO ()
stopProcessSession inputHandle outputHandle processHandle = do
    void (try (hClose inputHandle) :: IO (Either SomeException ()))
    graceful <- timeout 1000000 (waitForProcess processHandle)
    case graceful of
        Just _ -> pure ()
        Nothing -> terminateQuiet processHandle
    void (try (hClose outputHandle) :: IO (Either SomeException ()))

terminateQuiet :: ProcessHandle -> IO ()
terminateQuiet processHandle = do
    void (try (terminateProcess processHandle) :: IO (Either SomeException ()))
    void (timeout 5000000 (try (waitForProcess processHandle) :: IO (Either SomeException ExitCode)))

runWorkerProcess :: WorkerSpec -> AcceleratorAddRequest -> IO (Either Text Float)
runWorkerProcess spec (AcceleratorAddRequest _ leftVal rightVal) = do
    mExe <- firstExisting (workerBinaryCandidates spec)
    case mExe of
        Nothing ->
            pure (Left ("accelerator worker executable not found near " <> T.pack (workerExecutablePath spec)))
        Just exe -> do
            result <- try (readProcessWithExitCode exe [] (show leftVal ++ " " ++ show rightVal ++ "\n"))
            pure $ case (result :: Either SomeException (ExitCode, String, String)) of
                Left err -> Left (T.pack (show err))
                Right (ExitSuccess, out, _) ->
                    maybe
                        (Left ("accelerator worker returned non-numeric output: " <> T.pack out))
                        Right
                        (readMaybe (headDef "" (words out)))
                Right (ExitFailure n, out, err) ->
                    Left ("accelerator worker failed (exit " <> T.pack (show n) <> "): " <> T.pack (out <> err))
  where
    headDef def [] = def
    headDef _ (x : _) = x

runWorkerRequest :: WorkerSupervisor -> AcceleratorAddRequest -> IO AcceleratorResponse
runWorkerRequest supervisor request@(AcceleratorAddRequest rid _ _) = do
    workerResult <- try (workerAdd supervisor request) :: IO (Either IOException (Either Text Float))
    pure $
        case workerResult of
            Right (Right value) ->
                AcceleratorSucceeded
                    ( AcceleratorAddResult
                        rid
                        value
                        (supervisedBackend supervisor)
                        (supervisedArtifactHash supervisor)
                    )
            Right (Left message) ->
                workerFailure supervisor rid message
            Left err ->
                workerFailure supervisor rid (T.pack (show err))

runDaemonClientLoop :: DaemonClientConfig -> WorkerSupervisor -> DaemonTransport -> IO ()
runDaemonClientLoop clientConfig supervisor transport =
    loop `finally` stopWorkerSupervisor supervisor
  where
    loop = do
        stopping <- shouldShutdown transport
        if stopping
            then onDaemonEvent transport DaemonStopping
            else do
                connected <- connectDaemon transport
                case connected of
                    Left err -> do
                        onDaemonEvent transport (DaemonConnectFailed err)
                        threadDelay (reconnectDelayMicros clientConfig)
                        loop
                    Right connection -> do
                        onDaemonEvent transport DaemonConnected
                        shouldReconnect <- serveConnection connection
                        if shouldReconnect
                            then do
                                threadDelay (reconnectDelayMicros clientConfig)
                                loop
                            else onDaemonEvent transport DaemonStopping

    serveConnection connection = do
        let loopConnection = do
                outcome <- trySynchronous (serveConnectionOnce connection)
                case outcome of
                    Right Nothing -> loopConnection
                    Right (Just shouldReconnect) -> pure shouldReconnect
                    Left _ -> do
                        closeQuiet connection
                        onDaemonEvent transport DaemonDisconnected
                        pure True
        loopConnection

    serveConnectionOnce connection = do
        stopping <- shouldShutdown transport
        if stopping
            then do
                closeQuiet connection
                pure (Just False)
            else do
                received <- receiveDaemonRequest transport connection
                case received of
                    ReceiveShutdown -> do
                        closeQuiet connection
                        pure (Just False)
                    ReceiveFailed err -> throwIO err
                    ReceiveCompleted Nothing -> do
                        closeQuiet connection
                        onDaemonEvent transport DaemonDisconnected
                        pure (Just True)
                    ReceiveCompleted (Just request@(AcceleratorAddRequest rid _ _)) -> do
                        response <- timeout (requestTimeoutMicros clientConfig) (runWorkerRequest supervisor request)
                        case response of
                            Nothing -> do
                                let failure = workerFailure supervisor rid "accelerator worker timeout"
                                sendResponse connection failure
                                onDaemonEvent transport (DaemonRequestTimedOut rid)
                            Just failure@(AcceleratorFailed (AcceleratorAddFailure _ message _ _)) -> do
                                sendResponse connection failure
                                onDaemonEvent transport (DaemonRequestFailed rid message)
                            Just success -> do
                                sendResponse connection success
                                onDaemonEvent transport (DaemonRequestHandled rid)
                        pure Nothing

    closeQuiet connection =
        void (trySynchronous (closeConnection connection))

receiveDaemonRequest :: DaemonTransport -> DaemonConnection -> IO ReceiveOutcome
receiveDaemonRequest transport connection = do
    resultVar <- newEmptyMVar
    receiverThread <- forkIO $ do
        result <- trySynchronous (receiveRequest connection)
        void . tryPutMVar resultVar $
            case (result :: Either SomeException (Maybe AcceleratorAddRequest)) of
                Left err -> ReceiveFailed err
                Right received -> ReceiveCompleted received
    shutdownThread <- forkIO (watchForShutdown resultVar)
    takeMVar resultVar
        `finally` do
            killThread receiverThread
            killThread shutdownThread
  where
    watchForShutdown resultVar = do
        result <- trySynchronous (shouldShutdown transport)
        case (result :: Either SomeException Bool) of
            Left err -> void (tryPutMVar resultVar (ReceiveFailed err))
            Right True -> void (tryPutMVar resultVar ReceiveShutdown)
            Right False -> do
                threadDelay 100000
                watchForShutdown resultVar

workerFailure :: WorkerSupervisor -> Text -> Text -> AcceleratorResponse
workerFailure supervisor rid message =
    AcceleratorFailed
        ( AcceleratorAddFailure
            rid
            message
            (supervisedBackend supervisor)
            (supervisedArtifactHash supervisor)
        )

webSocketDaemonTransport :: WebSocketEndpoint -> DaemonTransport
webSocketDaemonTransport endpoint =
    webSocketDaemonTransportWithShutdown endpoint (pure False)

webSocketDaemonTransportWithShutdown :: WebSocketEndpoint -> IO Bool -> DaemonTransport
webSocketDaemonTransportWithShutdown endpoint shutdownCheck =
    DaemonTransport
        { connectDaemon = connectWebSocket endpoint
        , shouldShutdown = shutdownCheck
        , onDaemonEvent = print
        }

connectWebSocket :: WebSocketEndpoint -> IO (Either Text DaemonConnection)
connectWebSocket endpoint = do
    resultVar <- newEmptyMVar
    doneVar <- newEmptyMVar
    clientThread <- forkIO $ do
        outcome <-
            trySynchronous $
                WS.runClient (endpointHost endpoint) (endpointPort endpoint) (endpointPath endpoint) $ \conn -> do
                    let connection =
                            DaemonConnection
                                { receiveRequest = receiveWebSocketRequest conn
                                , sendResponse = sendWebSocketResponse conn
                                , closeConnection =
                                    void (trySynchronous (WS.sendClose conn ("daemon stopping" :: Text)))
                                        `finally` void (tryPutMVar doneVar ())
                                }
                    void (tryPutMVar resultVar (Right connection))
                    takeMVar doneVar
        case outcome of
            Right _ -> pure ()
            Left (err :: SomeException) ->
                void (tryPutMVar resultVar (Left (T.pack (show err))))
    takeMVar resultVar `onException` killThread clientThread

trySynchronous :: IO a -> IO (Either SomeException a)
trySynchronous = tryJust $ \err ->
    case fromException err :: Maybe SomeAsyncException of
        Just _ -> Nothing
        Nothing -> Just err

receiveWebSocketRequest :: WS.Connection -> IO (Maybe AcceleratorAddRequest)
receiveWebSocketRequest conn = do
    raw <- WS.receiveData conn
    case decodeAcceleratorMessage raw of
        Right (AcceleratorRequest request) -> pure (Just request)
        Right _ -> pure Nothing
        Left _ -> pure Nothing

sendWebSocketResponse :: WS.Connection -> AcceleratorResponse -> IO ()
sendWebSocketResponse conn response =
    WS.sendBinaryData conn (encodeAcceleratorMessage (responseMessage response))

responseMessage :: AcceleratorResponse -> AcceleratorMessage
responseMessage (AcceleratorSucceeded result) = AcceleratorResult result
responseMessage (AcceleratorFailed failure) = AcceleratorFailure failure

{- | Registered accelerator-handler body selected by config-driven @service run@.

The handler loads its daemon context, builds or reuses the substrate-specific
worker, then connects to the web service's accelerator ingress over CBOR
WebSocket.
-}
serveAcceleratorDaemon :: IO ()
serveAcceleratorDaemon = do
    cfg <- loadAcceleratorConfig
    timeoutSeconds <- case service cfg of
        Just (Accelerator params) -> pure (requestTimeoutSeconds params)
        _ -> die "service run: accelerator handler requires the Accelerator ServiceType variant"
    detected <- detect
    sub <- either die pure detected
    backend <- either (die . T.unpack) pure (acceleratorBackendForSubstrate sub)
    hostCfg <- buildHostConfig sub
    let workerRoot = T.unpack (Context.sourceRoot (context cfg)) </> ".build" </> "accelerator"
    spec <- buildWorkerWithHostConfig hostCfg workerRoot backend
    endpoint <- webSocketEndpointFromEnv
    shutdownFile <- lookupEnv "HOSTBOOTSTRAP_ACCELERATOR_SHUTDOWN_FILE"
    let shutdownCheck = maybe (pure False) doesFileExist shutdownFile
    putStrLn
        ( "accelerator daemon: connecting to ws://"
            ++ endpointHost endpoint
            ++ ":"
            ++ show (endpointPort endpoint)
            ++ endpointPath endpoint
            ++ " as "
            ++ T.unpack (backendName backend)
            ++ " artifact "
            ++ T.unpack (workerArtifactHash spec)
        )
    supervisor <- persistentWorkerSupervisor spec (startWorkerSession spec)
    let clientConfig =
            defaultDaemonClientConfig
                { requestTimeoutMicros = fromIntegral timeoutSeconds * 1000000
                }
    runDaemonClientLoop
        clientConfig
        supervisor
        (webSocketDaemonTransportWithShutdown endpoint shutdownCheck)

loadAcceleratorConfig :: IO ProjectConfig
loadAcceleratorConfig =
    Schema.requireSiblingProjectConfig
        (T.pack "hostbootstrap-demo")
        Context.ServiceCommand
        []
