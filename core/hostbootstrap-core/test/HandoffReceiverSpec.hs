{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The in-binary receiver, driven over real pipes.

Every case here runs the receiver against a live root broker: real Ed25519
signatures, a real protected store consuming the one-time token, and a real
duplex channel. The cross-process group additionally launches this test binary
again as the child, so the exchange crosses a process boundary the way it
crosses a container one — @stdin@ inbound, @stdout@ outbound, diagnostics on
@stderr@.
-}
module HandoffReceiverSpec (tests, runReceiverProbe) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Kind (Type)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import qualified Fixture
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectDestroy, ProjectUp),
    installedProjectName,
    withInstalledProjectIdentity,
 )
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Handoff (
    HandoffBindingInput (..),
    HandoffChallenge,
    HandoffChannel,
    HandoffOffer,
    HandoffPayloadKind (NarrowedProjectConfig),
    ProtocolMessage,
    ProtocolTag (AcceptedTag, ChallengeTag, CompletedTag, GrantTag, OfferTag, RefusedTag),
    RootBroker,
    authenticatedConfigBytes,
    challengeBytes,
    channelReceive,
    channelSend,
    childConfigDigest,
    freshChallenge,
    grantHandoff,
    grantSignature,
    handoffChallengeFromBytes,
    handoffChannel,
    handoffOfferFrames,
    installedVerificationKey,
    mkHandoffOffer,
    productionHandoffScope,
    productionScopeTag,
    projectSigningKeyFromBytes,
    protocolErrorMessage,
    protocolMessage,
    protocolMessageFields,
    protocolMessageTag,
    registerHandoffEdge,
    rootBrokerVerificationKey,
    stdioHandoffChannel,
    verificationKeyBytes,
    verificationKeyDigest,
    withRootBroker,
 )
import HostBootstrap.Handoff.Receiver (
    ReceiverError (..),
    ReceiverExpectation (..),
    receivedEdgeConfig,
    receiverErrorMessage,
    withReceivedHandoffEdge,
 )
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Protected (openProtectedStore)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents, hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (
    CreateProcess (std_err, std_in, std_out),
    StdStream (CreatePipe),
    createPipe,
    createProcess,
    proc,
    waitForProcess,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HandoffReceiverSpec"
        [ testGroup "the exchange over a duplex channel" exchangeTests
        , testGroup "across a real process boundary" crossProcessTests
        ]

-- ---------------------------------------------------------------------------
-- The exchange

exchangeTests :: [TestTree]
exchangeTests =
    [ testCase "a real exchange authenticates the child's config and reports completion" $
        withPipedExchange 21 ProjectUp id honestParent $ \received parent -> do
            case received of
                Right payload -> payload @?= childPayload
                other -> assertFailure ("expected an authenticated payload, got " <> show other)
            map fst parent @?= [ChallengeTag, AcceptedTag, CompletedTag]
            case parent of
                (_ : (_, [digest]) : _) ->
                    digest @?= TextEncoding.encodeUtf8 (childConfigDigest childPayload)
                _ -> assertFailure "the acceptance did not name the admitted config digest"
    , testCase "the challenge is the receiver's, so a recorded transcript does not authenticate" $
        withPipedExchange 22 ProjectUp id replayingParent $ \received parent -> do
            expectReceiverFailure "an unauthenticated grant" received $ \failure ->
                case failure of
                    ReceiverHandoffFailure _ -> pure ()
                    other -> assertFailure ("expected a handoff refusal, got " <> show other)
            assertBool
                ("the parent was told the child refused, saw " <> show (map fst parent))
                (RefusedTag `elem` map fst parent)
    , testCase "an offer naming another installed key is refused before any verification" $
        withPipedExchange 23 ProjectUp id wrongKeyParent $ \received parent -> do
            expectReceiverFailure "an installed-key mismatch" received $ \failure ->
                failure @?= ReceiverKeyMismatch
            -- The receiver never answered, so the only thing the parent hears
            -- back is the refusal — not a challenge it could have signed.
            map fst parent @?= [RefusedTag]
    , testCase "an edge for another project is refused as a wrong edge" $
        withPipedExchange 24 ProjectUp (\e -> e{receiverProject = "another-project"}) honestParent $
            \received _ ->
                expectReceiverFailure "a wrong-edge refusal" received $ \failure ->
                    case failure of
                        ReceiverWrongEdge _ -> pure ()
                        other -> assertFailure ("expected a wrong-edge refusal, got " <> show other)
    , testCase "an edge for another verb is refused even though it would verify" $
        withPipedExchange 25 ProjectUp (\e -> e{receiverVerb = "destroy"}) honestParent $
            \received _ ->
                expectReceiverFailure "a wrong-verb refusal" received $ \failure ->
                    case failure of
                        ReceiverWrongEdge detail ->
                            assertBool
                                ("the refusal names the offered verb, saw " <> Text.unpack detail)
                                ("up" `Text.isInfixOf` detail)
                        other -> assertFailure ("expected a wrong-edge refusal, got " <> show other)
    , testCase "an edge for another scope is refused before verification" $
        withPipedExchange 26 ProjectUp (\e -> e{receiverScopeTag = "Harness run-9"}) honestParent $
            \received _ ->
                expectReceiverFailure "a wrong-scope refusal" received $ \failure ->
                    case failure of
                        ReceiverWrongEdge _ -> pure ()
                        other -> assertFailure ("expected a wrong-edge refusal, got " <> show other)
    , testCase "a parent that refuses is reported as a refusal, not as a closed pipe" $
        withPipedExchange 27 ProjectUp id refusingParent $ \received _ ->
            expectReceiverFailure "the parent's refusal" received $ \failure ->
                case failure of
                    ReceiverRefusedByParent code detail -> do
                        code @?= "no-grant"
                        detail @?= "the root declined this edge"
                    other -> assertFailure ("expected a parent refusal, got " <> show other)
    , testCase "a destroy edge authenticates under a destroy receiver" $
        withPipedExchange 28 ProjectDestroy (\e -> e{receiverVerb = "destroy"}) honestParent $
            \received parent -> do
                case received of
                    Right payload -> payload @?= childPayload
                    other -> assertFailure ("expected an authenticated payload, got " <> show other)
                map fst parent @?= [ChallengeTag, AcceptedTag, CompletedTag]
    ]

-- ---------------------------------------------------------------------------
-- Across a real process boundary

crossProcessTests :: [TestTree]
crossProcessTests =
    [ testCase "a child process authenticates its config over stdin/stdout" $
        withChildProcess 31 "accept" $ \code parent childErrors admitted -> do
            code @?= ExitSuccess
            admitted @?= Just childPayload
            map fst parent @?= [ChallengeTag, AcceptedTag, CompletedTag]
            childErrors @?= ""
    , testCase "a child process that declines answers a refusal and fails" $
        withChildProcess 32 "decline" $ \code parent childErrors admitted -> do
            code @?= ExitFailure 1
            -- It saw the exact bytes, and declined under them: a decline is a
            -- decision taken after authentication, not a failure to authenticate.
            admitted @?= Just childPayload
            map fst parent @?= [ChallengeTag, AcceptedTag, RefusedTag]
            case [fields | (RefusedTag, fields) <- parent] of
                [[code', _]] -> code' @?= "child-declined"
                other -> assertFailure ("expected one refusal, got " <> show other)
            assertBool
                ("the child's diagnostics reached stderr, saw " <> show childErrors)
                ("declined the edge" `Text.isInfixOf` Text.pack childErrors)
    ]

{- | The child half of the cross-process fixture: a real process whose only
inbound stream is the exchange and whose only outbound stream is its frames.

It writes the admitted bytes to a file so the parent can compare them, and its
own diagnostics to @stderr@ — which is the point. @stdout@ belongs to the
protocol, so a receiving binary that printed progress there would corrupt its
own handoff.
-}
runReceiverProbe :: [String] -> IO ()
runReceiverProbe [keyPath, projectName, verb, mode, outPath] = do
    loaded <- installedVerificationKey keyPath
    key <- case loaded of
        Left failure -> hPutStrLn stderr (show failure) >> exitFailure
        Right value -> pure value
    channel <- stdioHandoffChannel
    let expectation =
            ReceiverExpectation
                { receiverProject = Text.pack projectName
                , receiverScopeTag = productionScopeTag
                , receiverVerb = Text.pack verb
                , receiverPayloadKind = NarrowedProjectConfig
                }
    admitted <-
        withInstalledProjectIdentity (Text.pack projectName) $ \project ->
            withReceivedHandoffEdge (productionHandoffScope project) channel key expectation $ \edge -> do
                ByteString.writeFile outPath (authenticatedConfigBytes (receivedEdgeConfig edge))
                pure (if mode == "decline" then Left "the probe was asked to decline" else Right ())
    outcome <- case admitted of
        Left failure -> hPutStrLn stderr (show failure) >> exitFailure
        Right value -> pure value
    case outcome of
        Right () -> exitSuccess
        Left failure -> hPutStrLn stderr (receiverErrorMessage failure) >> exitFailure
runReceiverProbe args = do
    hPutStrLn stderr ("unexpected receiver probe arguments: " <> show args)
    exitFailure

withChildProcess ::
    Word8 ->
    String ->
    (ExitCode -> [(ProtocolTag, [ByteString])] -> String -> Maybe ByteString -> IO ()) ->
    IO ()
withChildProcess seedByte mode check =
    withSystemTempDirectory "hostbootstrap-handoff-child" $ \directory -> do
        self <- getExecutablePath
        let keyPath = directory </> "project.pub"
            outPath = directory </> "admitted.bytes"
        withRoot seedByte directory ProjectUp $ \project broker -> do
            ByteString.writeFile keyPath (verificationKeyBytes (rootBrokerVerificationKey broker))
            offer <- newOffer broker childPayload
            spawned <-
                createProcess
                    ( proc
                        self
                        [ "--hostbootstrap-handoff-receiver-probe"
                        , keyPath
                        , Text.unpack (installedProjectName project)
                        , "up"
                        , mode
                        , outPath
                        ]
                    )
                        { std_in = CreatePipe
                        , std_out = CreatePipe
                        , std_err = CreatePipe
                        }
            case spawned of
                (Just childIn, Just childOut, Just childErr, process) -> do
                    channel <- handoffChannel childOut childIn
                    errorsVar <- newEmptyMVar
                    _ <-
                        forkIO
                            ( do
                                text <- hGetContents childErr
                                length text `seq` putMVar errorsVar text
                            )
                    parent <- honestParent broker channel offer
                    hClose childIn
                    errors <- takeMVar errorsVar
                    code <- waitForProcess process
                    admitted <- readIfPresent outPath
                    check code parent errors admitted
                _ -> assertFailure "the child process was launched without its pipes"

readIfPresent :: FilePath -> IO (Maybe ByteString)
readIfPresent path = do
    present <- doesFileExist path
    if present then Just <$> ByteString.readFile path else pure Nothing

-- ---------------------------------------------------------------------------
-- Parent scripts

{- | The honest parent: offer, sign the challenge the child issued, and read
the child's answers to the end of the exchange.

A child that refuses the offer outright never issues a challenge, so the first
answer is checked rather than assumed.
-}
honestParent ::
    RootBroker scope brokerGeneration verb ->
    HandoffChannel ->
    HandoffOffer scope brokerGeneration ->
    IO [(ProtocolTag, [ByteString])]
honestParent broker channel offer = do
    sendOffer channel offer (keyDigestOf broker)
    answer <- receive channel
    case protocolMessageTag answer of
        RefusedTag -> pure [summarize answer]
        _ -> do
            challenge <- challengeFrom answer
            grant <- grantHandoff broker offer challenge >>= expectRight
            send channel GrantTag [grantSignature grant, keyDigestOf broker]
            rest <- drain channel
            pure (summarize answer : rest)

{- | Replay a transcript: sign a challenge recorded from an earlier exchange
and present it against the one the child just minted.
-}
replayingParent ::
    RootBroker scope brokerGeneration verb ->
    HandoffChannel ->
    HandoffOffer scope brokerGeneration ->
    IO [(ProtocolTag, [ByteString])]
replayingParent broker channel offer = do
    recorded <- freshChallenge
    grant <- grantHandoff broker offer recorded >>= expectRight
    sendOffer channel offer (keyDigestOf broker)
    answer <- receive channel
    challenge <- challengeFrom answer
    assertBool
        "the receiver minted a challenge of its own"
        (challengeBytes challenge /= challengeBytes recorded)
    send channel GrantTag [grantSignature grant, keyDigestOf broker]
    rest <- drain channel
    pure (summarize answer : rest)

-- | Advertise a key digest the child did not install.
wrongKeyParent ::
    RootBroker scope brokerGeneration verb ->
    HandoffChannel ->
    HandoffOffer scope brokerGeneration ->
    IO [(ProtocolTag, [ByteString])]
wrongKeyParent _ channel offer = do
    sendOffer channel offer (ByteStringChar8.replicate 64 '0')
    drain channel

-- | Refuse the edge rather than answering its challenge with a grant.
refusingParent ::
    RootBroker scope brokerGeneration verb ->
    HandoffChannel ->
    HandoffOffer scope brokerGeneration ->
    IO [(ProtocolTag, [ByteString])]
refusingParent broker channel offer = do
    sendOffer channel offer (keyDigestOf broker)
    answer <- receive channel
    send channel RefusedTag ["no-grant", "the root declined this edge"]
    pure [summarize answer]

-- ---------------------------------------------------------------------------
-- Channel helpers

sendOffer :: HandoffChannel -> HandoffOffer scope brokerGeneration -> ByteString -> IO ()
sendOffer channel offer keyDigest =
    send channel OfferTag [payload, token, binding, keyDigest]
  where
    (payload, token, binding) = handoffOfferFrames offer

send :: HandoffChannel -> ProtocolTag -> [ByteString] -> IO ()
send channel tag fields =
    case protocolMessage tag requestId fields of
        Left failure -> assertFailure (protocolErrorMessage failure)
        Right message ->
            channelSend channel message
                >>= either (assertFailure . protocolErrorMessage) pure

receive :: HandoffChannel -> IO ProtocolMessage
receive channel =
    channelReceive channel >>= either (assertFailure . protocolErrorMessage) pure

{- | Read whatever the child says next until it stops.

The child ends every path with a terminal message — 'CompletedTag' or
'RefusedTag' — so this terminates on the protocol rather than on a count.
-}
drain :: HandoffChannel -> IO [(ProtocolTag, [ByteString])]
drain channel = do
    next <- channelReceive channel
    case next of
        Left _ -> pure []
        Right message ->
            let entry = summarize message
             in if fst entry `elem` [CompletedTag, RefusedTag]
                    then pure [entry]
                    else (entry :) <$> drain channel

summarize :: ProtocolMessage -> (ProtocolTag, [ByteString])
summarize message = (protocolMessageTag message, protocolMessageFields message)

challengeFrom :: ProtocolMessage -> IO HandoffChallenge
challengeFrom message = case protocolMessageFields message of
    [raw] -> expectRight (handoffChallengeFromBytes raw)
    other -> assertFailure ("expected one challenge field, got " <> show (length other))

-- ---------------------------------------------------------------------------
-- Fixtures

{- | Run a receiver and a parent script against each other over two real pipes.

The receiver runs on its own thread holding the child's ends, exactly as a
descending binary holds its @stdin@ and @stdout@; the parent script runs here.
-}
withPipedExchange ::
    Word8 ->
    ProjectVerb verb ->
    (ReceiverExpectation -> ReceiverExpectation) ->
    ( forall projectId (brokerGeneration :: Type).
      RootBroker (Production projectId) brokerGeneration verb ->
      HandoffChannel ->
      HandoffOffer (Production projectId) brokerGeneration ->
      IO [(ProtocolTag, [ByteString])]
    ) ->
    (Either ReceiverError ByteString -> [(ProtocolTag, [ByteString])] -> IO ()) ->
    IO ()
withPipedExchange seedByte verb adjust parentScript check =
    withSystemTempDirectory "hostbootstrap-handoff-receiver" $ \directory ->
        withRoot seedByte directory verb $ \project broker -> do
            (toChildRead, toChildWrite) <- createPipe
            (toParentRead, toParentWrite) <- createPipe
            childChannel <- handoffChannel toChildRead toParentWrite
            parentChannel <- handoffChannel toParentRead toChildWrite
            offer <- newOffer broker childPayload
            receivedVar <- newEmptyMVar
            _ <-
                forkIO
                    ( withReceivedHandoffEdge
                        (productionHandoffScope project)
                        childChannel
                        (rootBrokerVerificationKey broker)
                        (adjust (baseExpectation project))
                        (\edge -> pure (Right (authenticatedConfigBytes (receivedEdgeConfig edge))))
                        >>= putMVar receivedVar
                    )
            parent <- parentScript broker parentChannel offer
            received <- takeMVar receivedVar
            hClose toChildWrite
            hClose toParentWrite
            check received parent

baseExpectation :: InstalledProjectIdentity projectId -> ReceiverExpectation
baseExpectation project =
    ReceiverExpectation
        { receiverProject = installedProjectName project
        , receiverScopeTag = productionScopeTag
        , receiverVerb = "up"
        , receiverPayloadKind = NarrowedProjectConfig
        }

withRoot ::
    Word8 ->
    FilePath ->
    ProjectVerb verb ->
    ( forall projectId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) brokerGeneration verb ->
      IO ()
    ) ->
    IO ()
withRoot seedByte directory verb use = do
    signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
    store <- openProtectedStore (directory </> "authority") >>= expectRight
    outcome <- Fixture.withFixtureInstalledProject $ \project ->
        withProductionRoot store project verb $ \root -> do
            brokered <-
                withRootBroker
                    (productionHandoffScope project)
                    store
                    signing
                    (productionRootAuthority root)
                    (use project)
            _ <- expectRight brokered
            pure (Right ())
    _ <- expectRight outcome
    pure ()

newOffer ::
    RootBroker scope brokerGeneration verb ->
    ByteString ->
    IO (HandoffOffer scope brokerGeneration)
newOffer broker payload = do
    registered <- registerHandoffEdge broker (bindingInputFor payload)
    (relay, token) <- expectRight registered
    expectRight (mkHandoffOffer relay payload token)

bindingInputFor :: ByteString -> HandoffBindingInput
bindingInputFor payload =
    HandoffBindingInput
        { requestedSpecDigest = "spec-digest-1"
        , requestedPayloadKind = NarrowedProjectConfig
        , requestedPlanRevision = "rev-1"
        , requestedParentFrame = "vm-orchestrator-1"
        , requestedChildFrame = "vm-project-container-2"
        , requestedChildConfigDigest = childConfigDigest payload
        , requestedPhase = "execute"
        }

keyDigestOf :: RootBroker scope brokerGeneration verb -> ByteString
keyDigestOf = TextEncoding.encodeUtf8 . verificationKeyDigest . rootBrokerVerificationKey

childPayload :: ByteString
childPayload = ByteStringChar8.pack "{ message = \"Hello, world!\" }"

-- | One request identity for the whole fixture exchange.
requestId :: Word64
requestId = 4242

expectReceiverFailure ::
    String ->
    Either ReceiverError ByteString ->
    (ReceiverError -> IO ()) ->
    IO ()
expectReceiverFailure what outcome check = case outcome of
    Left failure -> check failure
    Right value ->
        assertFailure ("expected " <> what <> ", but the receiver admitted " <> show value)

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)
