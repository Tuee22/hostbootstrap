{-# LANGUAGE ScopedTypeVariables #-}

module ExposureRelaySpec (tests) where

import Control.Concurrent (MVar, ThreadId, forkFinally, killThread, newEmptyMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, bracket, bracketOnError, catch, mask, onException, throwIO, try)
import Control.Monad (forM_, void)
import qualified Data.ByteString as ByteString
import Foreign.C.Error (eACCES, eBADF, eCONNABORTED, eINTR, eINVAL, eMFILE, eNFILE, eNOTSOCK, errnoToIOError)
import HostBootstrap.Cluster.Exposure.Internal (AcceptDisposition (..), classifyAcceptFailure, runExposureRelay)
import Network.Socket (
    Family (AF_INET),
    ShutdownCmd (ShutdownSend),
    SockAddr (SockAddrInet),
    Socket,
    SocketOption (ReuseAddr),
    SocketType (Stream),
    accept,
    bind,
    close,
    connect,
    defaultProtocol,
    getSocketName,
    listen,
    setSocketOption,
    shutdown,
    socket,
    tupleToHostAddress,
    withSocketsDo,
 )
import qualified Network.Socket.ByteString as SocketByteString
import System.IO.Error (ioeGetLocation, ioeSetLocation, modifyIOError)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "ExposureRelaySpec" $
    [ testCase "half-close retains the complete upstream response" $ networkCase $
        withListener $ \upstream upstreamPort -> do
            relayPort <- freshPort
            let request = ByteString.replicate 1024 113
                response = ByteString.replicate 98304 114
                server = bracket (fst <$> accept upstream) close $ \connected -> do
                    receiveAll connected >>= (@?= request)
                    SocketByteString.sendAll connected response
            withWorker server $ \serverWorker ->
                withWorker (runExposureRelay (target "web" relayPort upstreamPort)) $ \_ ->
                    bracket (connectEventually relayPort) close $ \client -> do
                        SocketByteString.sendAll client request
                        shutdown client ShutdownSend
                        bounded "half-close response" (receiveAll client) >>= (@?= response)
                        awaitWorker serverWorker
    , testCase "a later bind failure releases every earlier listener" $ networkCase $
        withListenerAt (\port -> SockAddrInet (fromIntegral port) (tupleToHostAddress (0, 0, 0, 0))) $ \_ occupiedPort -> do
            relayPort <- freshPort
            let arguments = target "first" relayPort occupiedPort <> target "second" occupiedPort occupiedPort
            outcome <- try (runExposureRelay arguments) :: IO (Either IOException ())
            case outcome of
                Left _ -> pure ()
                Right () -> assertFailure "the occupied second listener was admitted"
            assertNotListening relayPort
            assertBindable relayPort
    , testCase "cancellation joins connections and releases all listeners" $ networkCase $
        withListener $ \upstream upstreamPort -> do
            (firstPort, secondPort) <- freshPortPair
            connected <- newEmptyMVar
            let server =
                    bracket (fst <$> accept upstream) close $ \first ->
                        bracket (fst <$> accept upstream) close $ \second -> do
                            putMVar connected ()
                            bounded "upstream first EOF" (receiveAll first) >>= (@?= ByteString.empty)
                            bounded "upstream second EOF" (receiveAll second) >>= (@?= ByteString.empty)
                arguments = target "first" firstPort upstreamPort <> target "second" secondPort upstreamPort
            withWorker server $ \serverWorker ->
                withWorker (runExposureRelay arguments) $ \relayWorker ->
                    bracket (connectEventually firstPort) close $ \first ->
                        bracket (connectEventually secondPort) close $ \second -> do
                            bounded "both upstream connections" (takeMVar connected)
                            stopWorker relayWorker
                            forM_ [first, second] $ \client ->
                                bounded "client EOF after cancellation" (SocketByteString.recv client 1)
                                    >>= (@?= ByteString.empty)
                            awaitWorker serverWorker
                            forM_ [firstPort, secondPort] $ \port -> do
                                assertNotListening port
                                assertBindable port
    , testCase "an error without errno backs off" $
        classifyAcceptFailure (userError "unspecified socket error") @?= RetryAcceptAfterBackoff
    ]
        <> [ testCase label $
                classifyAcceptFailure (errnoToIOError "accept" code Nothing Nothing) @?= expected
           | (label, code, expected) <-
                [ ("ECONNABORTED retries", eCONNABORTED, RetryAccept)
                , ("EINTR retries", eINTR, RetryAccept)
                , ("EMFILE backs off", eMFILE, RetryAcceptAfterBackoff)
                , ("ENFILE backs off", eNFILE, RetryAcceptAfterBackoff)
                , ("EBADF stops", eBADF, StopAccept)
                , ("EINVAL stops", eINVAL, StopAccept)
                , ("ENOTSOCK stops", eNOTSOCK, StopAccept)
                , ("other errors back off", eACCES, RetryAcceptAfterBackoff)
                ]
           ]

networkCase :: IO () -> IO ()
networkCase action = withSocketsDo (bounded "relay case" action)

bounded :: String -> IO value -> IO value
bounded label action = do
    result <- timeout 10000000 (modifyIOError (\failure -> ioeSetLocation failure (label <> ": " <> ioeGetLocation failure)) action)
    maybe (assertFailure (label <> " timed out")) pure result

target :: String -> Int -> Int -> [String]
target service listener upstream = [service, show listener, "127.0.0.1", show upstream]

withListener :: (Socket -> Int -> IO value) -> IO value
withListener = withListenerAt loopback

withListenerAt :: (Int -> SockAddr) -> (Socket -> Int -> IO value) -> IO value
withListenerAt addressFor consume = bracket acquire close $ \listener -> do
    address <- getSocketName listener
    case address of
        SockAddrInet port _ -> consume listener (fromIntegral port)
        _ -> assertFailure "the IPv4 fixture returned another address family"
  where
    acquire = bracketOnError (socket AF_INET Stream defaultProtocol) close $ \listener -> do
        bind listener (addressFor 0)
        listen listener 16
        pure listener

freshPort :: IO Int
freshPort = withListener (const pure)

freshPortPair :: IO (Int, Int)
freshPortPair = withListener $ \_ first -> withListener $ \_ second -> pure (first, second)

loopback :: Int -> SockAddr
loopback port = SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1))

connectOnce :: Int -> IO Socket
connectOnce port =
    bracketOnError (socket AF_INET Stream defaultProtocol) close $ \client ->
        connect client (loopback port) >> pure client

connectEventually :: Int -> IO Socket
connectEventually port = bounded "relay listener readiness" retry
  where
    retry = catch (connectOnce port) $ \(_ :: IOException) -> threadDelay 10000 >> retry

assertNotListening :: Int -> IO ()
assertNotListening port = do
    outcome <- try (bounded "closed listener probe" (connectOnce port)) :: IO (Either IOException Socket)
    case outcome of
        Left _ -> pure ()
        Right unexpected -> close unexpected >> assertFailure "a relay listener survived cleanup"

assertBindable :: Int -> IO ()
assertBindable port =
    bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
        setSocketOption listener ReuseAddr 1
        bind listener (loopback port)
        listen listener 1

receiveAll :: Socket -> IO ByteString.ByteString
receiveAll connected = ByteString.concat . reverse <$> chunks []
  where
    chunks accumulated = do
        chunk <- SocketByteString.recv connected 32768
        if ByteString.null chunk
            then pure accumulated
            else chunks (chunk : accumulated)

data Worker = Worker ThreadId (MVar (Either SomeException ()))

withWorker :: IO () -> (Worker -> IO value) -> IO value
withWorker action consume = mask $ \restore -> do
    completed <- newEmptyMVar
    worker <- forkFinally (restore action) (putMVar completed)
    let owned = Worker worker completed
    onException (restore (consume owned) <* stopWorker owned) (stopWorker owned)

stopWorker :: Worker -> IO ()
stopWorker (Worker thread completed) = do
    killThread thread
    void (bounded "worker cancellation" (readMVar completed))

awaitWorker :: Worker -> IO ()
awaitWorker (Worker _ completed) =
    bounded "worker completion" (readMVar completed) >>= either throwIO pure
