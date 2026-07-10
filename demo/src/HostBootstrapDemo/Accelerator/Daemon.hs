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
    WorkerSupervisor (..),
    acceleratorBackendForSubstrate,
    buildWorkerWithHostConfig,
    defaultDaemonClientConfig,
    parseWebSocketEndpoint,
    runDaemonClientLoop,
    runWorkerProcess,
    runWorkerRequest,
    serveAcceleratorDaemon,
    webSocketDaemonTransport,
    webSocketEndpointFromEnv,
    workerSupervisor,
)
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, try)
import Control.Monad (unless, void)
import Data.List (stripPrefix)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified HostBootstrap.Ensure.AppleMetal as AppleMetal
import qualified HostBootstrap.Ensure.CudaWin as CudaWin
import HostBootstrap.Ensure (runEnsure, runTool)
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Context as Context
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
import HostBootstrapDemo.Config (ProjectConfig (context))
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (AcceleratorAddFailure),
    AcceleratorAddRequest (AcceleratorAddRequest),
    AcceleratorAddResult (AcceleratorAddResult),
 )
import qualified Network.WebSockets as WS
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), die)
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcessWithExitCode)
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

data WorkerSupervisor = WorkerSupervisor
    { supervisedBackend :: Text
    , supervisedArtifactHash :: Text
    , workerAdd :: AcceleratorAddRequest -> IO (Either Text Double)
    }

workerSupervisor :: WorkerSpec -> (AcceleratorAddRequest -> IO (Either Text Double)) -> WorkerSupervisor
workerSupervisor spec action =
    WorkerSupervisor
        { supervisedBackend = backendName (workerBackend spec)
        , supervisedArtifactHash = workerArtifactHash spec
        , workerAdd = action
        }

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
    case parseWebSocketEndpoint (maybe defaultEndpoint id raw) of
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
    let spec = workerSpec root backend
    createDirectoryIfMissing True (takeDirectory (workerSourcePath spec))
    TIO.writeFile (workerSourcePath spec) (workerSourceText spec)
    alreadyBuilt <- doesFileExist (workerExecutablePath spec)
    unless alreadyBuilt $ buildWorker cfg spec
    pure spec

ensureBackend :: HostConfig -> AcceleratorBackend -> IO HostConfig
ensureBackend cfg backend =
    case backend of
        AppleMetalBackend -> runEnsure AppleMetal.reconciler >> buildHostConfig (hcSubstrate cfg)
        WindowsGpuBackend -> runEnsure CudaWin.reconciler >> buildHostConfig (hcSubstrate cfg)
        LinuxCpuBackend -> pure cfg
        LinuxGpuBackend -> pure cfg

buildWorker :: HostConfig -> WorkerSpec -> IO ()
buildWorker cfg spec =
    case workerBackend spec of
        AppleMetalBackend -> do
            sdk <- macosSdkPathOrDie cfg
            runBuild cfg Swiftc (swiftMetalBuildArgs sdk (workerSourcePath spec) (workerExecutablePath spec))
        LinuxCpuBackend ->
            runBuild cfg Clangxx (cppBuildArgs (workerSourcePath spec) (workerExecutablePath spec))
        LinuxGpuBackend ->
            runBuild cfg Nvcc (cudaBuildArgs (workerSourcePath spec) (workerExecutablePath spec))
        WindowsGpuBackend ->
            case resolveMaybe cfg MsvcCl of
                Nothing -> die "accelerator worker: cl.exe not resolved after ensure-cudawin"
                Just clExe ->
                    runBuild
                        cfg
                        Nvcc
                        ( "-ccbin"
                            : takeDirectory (absExePath clExe)
                            : cudaBuildArgs (workerSourcePath spec) (workerExecutablePath spec)
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

runWorkerProcess :: WorkerSpec -> AcceleratorAddRequest -> IO (Either Text Double)
runWorkerProcess spec (AcceleratorAddRequest _ leftVal rightVal) = do
    result <- try (readProcessWithExitCode (workerExecutablePath spec) [] (show leftVal ++ " " ++ show rightVal ++ "\n"))
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
    workerResult <- try (workerAdd supervisor request) :: IO (Either SomeException (Either Text Double))
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
runDaemonClientLoop clientConfig supervisor transport = loop
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
        outcome <- try (serveConnectionOnce connection) :: IO (Either SomeException Bool)
        case outcome of
            Right shouldReconnect -> pure shouldReconnect
            Left _ -> do
                closeQuiet connection
                onDaemonEvent transport DaemonDisconnected
                pure True

    serveConnectionOnce connection = do
        stopping <- shouldShutdown transport
        if stopping
            then do
                closeQuiet connection
                pure False
            else do
                received <- timeout (requestTimeoutMicros clientConfig) (receiveRequest connection)
                case received of
                    Nothing -> do
                        closeQuiet connection
                        onDaemonEvent transport (DaemonRequestTimedOut "receive")
                        pure True
                    Just Nothing -> do
                        closeQuiet connection
                        onDaemonEvent transport DaemonDisconnected
                        pure True
                    Just (Just request@(AcceleratorAddRequest rid _ _)) -> do
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
                        serveConnection connection

    closeQuiet connection =
        void (try (closeConnection connection) :: IO (Either SomeException ()))

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
    DaemonTransport
        { connectDaemon = connectWebSocket endpoint
        , shouldShutdown = pure False
        , onDaemonEvent = print
        }

connectWebSocket :: WebSocketEndpoint -> IO (Either Text DaemonConnection)
connectWebSocket endpoint = do
    resultVar <- newEmptyMVar
    doneVar <- newEmptyMVar
    void . forkIO $ do
        outcome <-
            try $
                WS.runClient (endpointHost endpoint) (endpointPort endpoint) (endpointPath endpoint) $ \conn -> do
                    let connection =
                            DaemonConnection
                                { receiveRequest = receiveWebSocketRequest conn
                                , sendResponse = sendWebSocketResponse conn
                                , closeConnection = do
                                    _ <- try (WS.sendClose conn ("daemon stopping" :: Text)) :: IO (Either SomeException ())
                                    void (tryPutMVar doneVar ())
                                }
                    void (tryPutMVar resultVar (Right connection))
                    takeMVar doneVar
        case outcome of
            Right _ -> pure ()
            Left (err :: SomeException) ->
                void (tryPutMVar resultVar (Left (T.pack (show err))))
    takeMVar resultVar

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

{- | Registered @service run accelerator@ body.

The handler loads its daemon context, builds or reuses the substrate-specific
worker, then connects to the web service's accelerator ingress over CBOR
WebSocket.
-}
serveAcceleratorDaemon :: IO ()
serveAcceleratorDaemon = do
    cfg <- loadAcceleratorConfig
    detected <- detect
    sub <- either die pure detected
    backend <- either (die . T.unpack) pure (acceleratorBackendForSubstrate sub)
    hostCfg <- buildHostConfig sub
    let workerRoot = T.unpack (Context.sourceRoot (context cfg)) </> ".build" </> "accelerator"
    spec <- buildWorkerWithHostConfig hostCfg workerRoot backend
    endpoint <- webSocketEndpointFromEnv
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
    runDaemonClientLoop
        defaultDaemonClientConfig
        (workerSupervisor spec (runWorkerProcess spec))
        (webSocketDaemonTransport endpoint)

loadAcceleratorConfig :: IO ProjectConfig
loadAcceleratorConfig =
    Schema.requireSiblingProjectConfig
        (T.pack "hostbootstrap-demo")
        Context.ServiceCommand
        []
