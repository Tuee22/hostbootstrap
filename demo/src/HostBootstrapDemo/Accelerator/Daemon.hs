{-# LANGUAGE OverloadedStrings #-}

{- | Accelerator daemon runtime seams.

The live WebSocket transport is intentionally injected. The daemon loop owns
reconnect, timeout, shutdown, and worker supervision; a concrete WebSocket
client can plug into 'DaemonTransport' without changing the service handler or
unit-tested protocol path.
-}
module HostBootstrapDemo.Accelerator.Daemon (
    DaemonClientConfig (..),
    DaemonConnection (..),
    DaemonEvent (..),
    DaemonTransport (..),
    WorkerSupervisor (..),
    defaultDaemonClientConfig,
    runDaemonClientLoop,
    runWorkerRequest,
    serveAcceleratorDaemon,
    workerSupervisor,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Context as Context
import HostBootstrapDemo.Accelerator (
    WorkerSpec,
    backendName,
    workerArtifactHash,
    workerBackend,
 )
import HostBootstrapDemo.Accelerator.Protocol (
    AcceleratorResponse (..),
 )
import HostBootstrapDemo.Config (ProjectConfig)
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (AcceleratorAddFailure),
    AcceleratorAddRequest (AcceleratorAddRequest),
    AcceleratorAddResult (AcceleratorAddResult),
 )
import System.Exit (die)
import System.Timeout (timeout)

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
        stopping <- shouldShutdown transport
        if stopping
            then do
                closeConnection connection
                pure False
            else do
                received <- timeout (requestTimeoutMicros clientConfig) (receiveRequest connection)
                case received of
                    Nothing -> do
                        closeConnection connection
                        onDaemonEvent transport (DaemonRequestTimedOut "receive")
                        pure True
                    Just Nothing -> do
                        closeConnection connection
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

workerFailure :: WorkerSupervisor -> Text -> Text -> AcceleratorResponse
workerFailure supervisor rid message =
    AcceleratorFailed
        ( AcceleratorAddFailure
            rid
            message
            (supervisedBackend supervisor)
            (supervisedArtifactHash supervisor)
        )

{- | Registered @service run accelerator@ body.

The handler deliberately fails after the normal service-context load until the
live WebSocket transport is wired. That prevents the demo from presenting a fake
daemon while still proving the service variant and context gate exist.
-}
serveAcceleratorDaemon :: IO ()
serveAcceleratorDaemon = do
    _cfg <- loadAcceleratorConfig
    die "accelerator daemon: CBOR WebSocket transport is not wired yet"

loadAcceleratorConfig :: IO ProjectConfig
loadAcceleratorConfig =
    Schema.requireSiblingProjectConfig
        (T.pack "hostbootstrap-demo")
        Context.ServiceCommand
        []
