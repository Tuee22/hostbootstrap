{-# LANGUAGE ScopedTypeVariables #-}

{- | The private process entry used by the cluster exposure relay.

The public cluster backend is the only producer of this argument shape.  Keeping
the listener here means a derived project image needs no shell fragment or
ambient proxy executable: every binary assembled with 'HostBootstrap.CLI.runCLI'
already carries the same bounded TCP relay.
-}
module HostBootstrap.Cluster.Exposure.Internal (
    exposureRelayMarker,
    runExposureRelayEntry,
) where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, bracket, bracketOnError, catch, throwIO)
import Control.Monad (forever, unless, void)
import qualified Data.ByteString as ByteString
import Network.Socket
    ( AddrInfo (addrAddress, addrFamily, addrProtocol, addrSocketType)
    , Family (AF_INET)
    , ShutdownCmd (ShutdownReceive, ShutdownSend)
    , Socket
    , SocketOption (ReuseAddr)
    , SocketType (Stream)
    , accept
    , bind
    , close
    , connect
    , defaultHints
    , defaultProtocol
    , getAddrInfo
    , listen
    , setSocketOption
    , shutdown
    , socket
    , tupleToHostAddress
    , SockAddr (SockAddrInet)
    , withSocketsDo
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
    | marker == exposureRelayMarker = Just $ case parseTargets arguments of
        Left refusal -> fail refusal
        Right targets -> runRelay targets
runExposureRelayEntry _ = Nothing

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

runRelay :: [RelayTarget] -> IO ()
runRelay targets = withSocketsDo $ do
    listeners <- mapM openListener targets
    failure <- newEmptyMVar
    threads <-
        mapM
            (\(target, listener) -> forkFinally (acceptForever target listener) (putMVar failure))
            (zip targets listeners)
    outcome <- takeMVar failure
    mapM_ killThread threads
    mapM_ close listeners
    either throwIO (const (fail "exposure relay: a listener stopped unexpectedly")) outcome

openListener :: RelayTarget -> IO Socket
openListener target =
    bracketOnError (socket AF_INET Stream defaultProtocol) close $ \listener -> do
        setSocketOption listener ReuseAddr 1
        bind listener (SockAddrInet (fromIntegral (relayListenPort target)) (tupleToHostAddress (0, 0, 0, 0)))
        listen listener 128
        pure listener

acceptForever :: RelayTarget -> Socket -> IO ()
acceptForever target listener = forever $ do
    (client, _) <- accept listener
    void (forkFinally (relayConnection target client) (const (close client)))

relayConnection :: RelayTarget -> Socket -> IO ()
relayConnection target client =
    bracket (connectTarget target) close $ \upstream -> do
        completed <- newEmptyMVar
        clientToUpstream <- forkFinally (copySocket client upstream) (putMVar completed)
        upstreamToClient <- forkFinally (copySocket upstream client) (putMVar completed)
        _ <- takeMVar completed
        ignoreShutdown client ShutdownReceive
        ignoreShutdown upstream ShutdownReceive
        ignoreShutdown client ShutdownSend
        ignoreShutdown upstream ShutdownSend
        killThread clientToUpstream
        killThread upstreamToClient

connectTarget :: RelayTarget -> IO Socket
connectTarget target = do
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
                (\connected -> connect connected (addrAddress address) >> pure connected)
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
