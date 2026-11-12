{-# LANGUAGE ScopedTypeVariables #-}

{- | The private process entry used by the cluster exposure relay.

The public cluster backend is the only producer of this argument shape.  Keeping
the listener here means a derived project image needs no shell fragment or
ambient proxy executable: every binary assembled with 'HostBootstrap.CLI.runCLI'
already carries the same bounded TCP relay.
-}
module HostBootstrap.Cluster.Exposure.Internal (
    AcceptDisposition (..),
    classifyAcceptFailure,
    exposureRelayMarker,
    runExposureRelay,
    runExposureRelayEntry,
) where

import Control.Concurrent (ThreadId, forkFinally, killThread, myThreadId, threadDelay)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (IOException, SomeException, bracket, bracketOnError, catch, finally, mask, onException, throwIO, uninterruptibleMask_)
import Control.Monad (forever, unless, void)
import qualified Data.ByteString as ByteString
import Foreign.C.Error (Errno (..), eBADF, eCONNABORTED, eINTR, eINVAL, eMFILE, eNFILE, eNOTSOCK)
import GHC.IO.Exception (IOException (ioe_errno))
import Network.Socket (
    AddrInfo (addrAddress, addrFamily, addrProtocol, addrSocketType),
    Family (AF_INET),
    ShutdownCmd (ShutdownBoth, ShutdownSend),
    SockAddr (SockAddrInet),
    Socket,
    SocketOption (ReuseAddr),
    SocketType (Stream),
    accept,
    bind,
    close,
    connect,
    defaultHints,
    defaultProtocol,
    getAddrInfo,
    listen,
    setSocketOption,
    shutdown,
    socket,
    tupleToHostAddress,
    withSocketsDo,
 )
import qualified Network.Socket.ByteString as SocketByteString
import Text.Read (readMaybe)

-- | Marker reserved for the backend-created relay container.
exposureRelayMarker :: String
exposureRelayMarker = "__hostbootstrap-exposure-relay-v1"

data RelayTarget = RelayTarget
    { relayService :: String
    , relayListenPort :: Int
    , relayTargetHost :: String
    , relayTargetPort :: Int
    }

{- | Recognize and run the private relay entry.  'Nothing' means the invocation
belongs to the ordinary command parser; malformed marker-bearing input is a
refusing action rather than a fall-through to public commands.
-}
runExposureRelayEntry :: [String] -> Maybe (IO ())
runExposureRelayEntry (marker : arguments)
    | marker == exposureRelayMarker = Just (runExposureRelay arguments)
runExposureRelayEntry _ = Nothing

-- | Run the same validated relay body in the owning process or package tests.
runExposureRelay :: [String] -> IO ()
runExposureRelay arguments = either fail runRelay (parseTargets arguments)

data AcceptDisposition = RetryAccept | RetryAcceptAfterBackoff | StopAccept
    deriving (Eq, Show)

-- | Only an invalid listener ends its loop; unknown failures back off as well.
classifyAcceptFailure :: IOException -> AcceptDisposition
classifyAcceptFailure failure = case Errno <$> ioe_errno failure of
    Just code
        | code == eCONNABORTED || code == eINTR -> RetryAccept
        | code == eBADF || code == eINVAL || code == eNOTSOCK -> StopAccept
        | code == eMFILE || code == eNFILE -> RetryAcceptAfterBackoff
    _ -> RetryAcceptAfterBackoff

parseTargets :: [String] -> Either String [RelayTarget]
parseTargets [] = Left "exposure relay: at least one target is required"
parseTargets arguments = do
    targets <- groups arguments
    unless (distinct (map relayService targets)) (Left "exposure relay: service identities must be distinct")
    unless (distinct (map relayListenPort targets)) (Left "exposure relay: listener ports must be distinct")
    pure targets
  where
    groups [] = Right []
    groups (service : listenPort : targetHost : targetPort : rest) = do
        listener <- parsePort "listener" listenPort
        target <- parsePort "target" targetPort
        unless (not (null service) && not (null targetHost)) (Left "exposure relay: service and target host must be non-empty")
        (RelayTarget service listener targetHost target :) <$> groups rest
    groups _ = Left "exposure relay: malformed target tuple"

    parsePort label raw = case readMaybe raw of
        Just port | port > 0 && port < 65536 -> Right port
        _ -> Left ("exposure relay: invalid " <> label <> " port")

    distinct values = length values == length (unique values)
    unique [] = []
    unique (value : values) = value : unique (filter (/= value) values)

-- Each worker group closes admission before cancellation and joins every child.
-- Registration holds the same lock its child's finalizer uses, so a child cannot
-- finish and disappear before its parent has recorded its completion cell.
newtype WorkerGroup = WorkerGroup (MVar (Bool, [(ThreadId, MVar (), IO ())]))

withWorkers :: (WorkerGroup -> IO value) -> IO value
withWorkers = bracket (WorkerGroup <$> newMVar (False, [])) stopWorkers

spawnWorker :: WorkerGroup -> IO () -> IO () -> (Either SomeException () -> IO ()) -> IO ()
spawnWorker (WorkerGroup state) abort action onFinish = mask $ \restore ->
    modifyMVar_ state $ \(closed, workers) ->
        if closed
            then fail "exposure relay: worker group is closed"
            else do
                finished <- newEmptyMVar
                thread <- forkFinally (restore action) $ \outcome ->
                    (onFinish outcome `finally` forgetSelf) `finally` putMVar finished ()
                pure (False, (thread, finished, abort) : workers)
  where
    forgetSelf = do
        self <- myThreadId
        modifyMVar_ state $ \(closed, workers) ->
            pure (closed, filter (\(thread, _, _) -> thread /= self) workers)

stopWorkers :: WorkerGroup -> IO ()
stopWorkers (WorkerGroup state) = uninterruptibleMask_ $ do
    workers <- modifyMVar state $ \(_, current) -> pure ((True, []), current)
    mapM_ (\(_, _, abort) -> abort) workers
    mapM_ (\(thread, _, _) -> killThread thread) workers
    mapM_ (\(_, finished, _) -> readMVar finished) workers

runRelay :: [RelayTarget] -> IO ()
runRelay targets = withSocketsDo $
    bracket (openListeners targets) (mapM_ close) $ \listeners ->
        withWorkers $ \workers -> do
            failure <- newEmptyMVar
            mapM_
                (\(target, listener) ->
                    spawnWorker workers (close listener) (acceptForever target listener) (void . tryPutMVar failure))
                (zip targets listeners)
            outcome <- takeMVar failure
            either throwIO (const (fail "exposure relay: a listener stopped unexpectedly")) outcome

openListeners :: [RelayTarget] -> IO [Socket]
openListeners [] = pure []
openListeners (target : rest) =
    bracketOnError (openListener target) close $ \listener ->
        (listener :) <$> openListeners rest

openListener :: RelayTarget -> IO Socket
openListener target =
    bracketOnError (socket AF_INET Stream defaultProtocol) close $ \listener -> do
        setSocketOption listener ReuseAddr 1
        bind listener (SockAddrInet (fromIntegral (relayListenPort target)) (tupleToHostAddress (0, 0, 0, 0)))
        listen listener 128
        pure listener

acceptForever :: RelayTarget -> Socket -> IO ()
acceptForever target listener = withWorkers $ \workers -> mask $ \restore -> forever $ do
    (client, _) <- restore acceptNext
    connection <- RelayConnection client <$> newMVar (False, Nothing)
    spawnWorker workers (closeConnection connection)
        (restore (relayConnection target connection) `finally` closeConnection connection) (const (pure ()))
        `onException` closeConnection connection
  where
    acceptNext = accept listener `catchIOException` \failure -> case classifyAcceptFailure failure of
        RetryAccept -> acceptNext
        RetryAcceptAfterBackoff -> threadDelay 100000 >> acceptNext
        StopAccept -> throwIO failure

data RelayConnection = RelayConnection Socket (MVar (Bool, Maybe Socket))

-- Close before cancellation: a native Windows socket call may be a safe foreign
-- call that cannot receive ThreadKilled until closing its socket wakes it.
closeConnection :: RelayConnection -> IO ()
closeConnection (RelayConnection client state) = do
    upstream <- modifyMVar state $ \(_, current) -> pure ((True, Nothing), current)
    ignoreShutdown client ShutdownBoth
    mapM_ (\connected -> ignoreShutdown connected ShutdownBoth) upstream
    close client
    mapM_ close upstream

relayConnection :: RelayTarget -> RelayConnection -> IO ()
relayConnection target connection@(RelayConnection client _) =
    bracket (connectTarget target connection) close $ \upstream -> withWorkers $ \workers -> do
        completed <- newChan
        spawnWorker workers (closeConnection connection) (copySocket client upstream) (writeChan completed)
        spawnWorker workers (closeConnection connection) (copySocket upstream client) (writeChan completed)
        -- EOF half-closes only the destination's send direction. Both clean
        -- completions are required; either exception releases the whole group.
        firstOutcome <- readChan completed
        either throwIO (const (readChan completed >>= either throwIO pure)) firstOutcome

connectTarget :: RelayTarget -> RelayConnection -> IO Socket
connectTarget target (RelayConnection _ state) = do
    addresses <-
        getAddrInfo
            (Just defaultHints{addrSocketType = Stream})
            (Just (relayTargetHost target))
            (Just (show (relayTargetPort target)))
    connectFirst addresses
  where
    connectFirst [] = fail ("exposure relay: cannot resolve target for " <> relayService target)
    connectFirst (address : rest) =
        ( do
            bracketOnError
                (socket (addrFamily address) (addrSocketType address) (addrProtocol address))
                close
                (\connected -> do
                    modifyMVar_ state $ \(closed, _) ->
                        if closed
                            then fail "exposure relay: connection is closing"
                            else pure (False, Just connected)
                    connect connected (addrAddress address)
                    pure connected)
        )
            `catchIOException` const (connectFirst rest)

copySocket :: Socket -> Socket -> IO ()
copySocket source destination = do
    chunk <- SocketByteString.recv source 32768
    if ByteString.null chunk
        then ignoreShutdown destination ShutdownSend
        else SocketByteString.sendAll destination chunk >> copySocket source destination

ignoreShutdown :: Socket -> ShutdownCmd -> IO ()
ignoreShutdown connection direction = shutdown connection direction `catchIOException` const (pure ())

catchIOException :: IO value -> (IOException -> IO value) -> IO value
catchIOException = catch
