{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The duplex relay: a nested frame obtaining an edge it cannot issue.

The nested group launches a real chain of processes — this test binary is the
root, it launches a middle frame, and that middle frame launches a leaf. The
middle process holds no signing key and no protected store: every edge it hands
downward was opened and signed by the root, reached over the very channel the
middle process was itself admitted on.
-}
module HandoffRelaySpec (tests, runRelayProbe) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import qualified Fixture
import HostBootstrap.Activation (
    ActivationBroker,
    ActivationManifest (..),
    ActivationSigningKey,
    ActivationSigningPolicy,
    activationGrantSignature,
    activationManifestFromWire,
    activationSecretDigestFromBytes,
    activationSigningKeyFromBytes,
    activationSigningPolicy,
    renderActivationManifest,
    signActivationManifest,
    withActivationBroker,
 )
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectDown, ProjectUp),
    VerbDown,
    VerbUp,
    installedProjectName,
    withInstalledProjectIdentity,
 )
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Handoff (
    HandoffBindingInput (..),
    HandoffChannel,
    HandoffError (HandoffBindingMismatch, HandoffBrokerExpired, HandoffTokenConsumed),
    HandoffOffer,
    HandoffPayloadKind (NarrowedProjectConfig),
    ProjectVerificationKey,
    ProtocolError (ProtocolRequestMismatch, ProtocolWrongFieldCount, ProtocolZeroRequestId),
    ProtocolMessage,
    ProtocolTag (..),
    RecoveryProjectionBinding,
    RecoveryProjectionBindingInput,
    RootBroker,
    authenticatedConfigBytes,
    brokerRelayFromRouteWire,
    challengeBytes,
    channelReceive,
    channelSend,
    childConfigDigest,
    encodeProtocolMessage,
    frameWire,
    freshChallenge,
    grantHandoff,
    grantSignature,
    handoffChallengeFromBytes,
    handoffChannel,
    handoffOfferFrames,
    handoffTokenBytes,
    handoffTokenFromBytes,
    installedVerificationKey,
    mkHandoffOffer,
    mkRecoveryProjectionBinding,
    productionHandoffScope,
    productionScopeTag,
    projectSigningKeyFromBytes,
    protocolMessage,
    protocolMessageFields,
    protocolMessageRequestId,
    protocolMessageTag,
    recoveryRequestFields,
    registerHandoffEdge,
    relayBinding,
    renderHandoffBinding,
    renderHandoffBindingInput,
    requestedRecoveryChildFrame,
    requestedRecoveryParentFrame,
    requestedRecoveryPlanDigest,
    rootBrokerRoute,
    rootBrokerVerificationKey,
    stdioHandoffChannel,
    takeHandoffFrame,
    unframeWire,
    verificationKeyBytes,
    verificationKeyDigest,
    withRecoveryProjectionBindingInput,
    withRootBroker,
    withVerifiedRecoveryWire,
 )
import HostBootstrap.Handoff.Receiver (
    ReceivedEdge,
    ReceiverExpectation (..),
    receivedEdgeConfig,
    receiverErrorMessage,
    withReceivedHandoffEdge,
 )
import HostBootstrap.Handoff.Relay (
    BrokerLink,
    EdgeAdmission,
    RecoveryAdmission,
    RelayError (..),
    grantThroughLink,
    linkSignActivation,
    offerHandoffEdge,
    openEdgeThroughLink,
    relayErrorMessage,
    relayedBrokerLink,
    rootBrokerLink,
    signRecoveryThroughLink,
    withSignedRecoveryThroughLink,
 )
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Protected (openProtectedStore)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitSuccess), exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO (Handle, hClose, hFlush, hGetContents, hPutStrLn, stderr)
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
        "HandoffRelaySpec"
        [ testGroup "the root's own link" rootLinkTests
        , testGroup "a nested frame relaying to the root" nestedTests
        , testGroup "losing the route to the broker" brokerLossTests
        , testGroup "relayed activation signing" activationSigningTests
        , testGroup "the parent's accepted barrier" parentProtocolTests
        , testGroup "relayed recovery signing" recoverySigningTests
        ]

-- ---------------------------------------------------------------------------
-- The root's own link

rootLinkTests :: [TestTree]
rootLinkTests =
    [ testCase "the root opens, offers, and signs one edge for its child" $
        withRootAndChildThread 41 admitEverything $ \opened admitted -> do
            opened @?= Right ()
            admitted @?= Right middlePayload
    , testCase "the root refuses an edge its plan does not name, and tells the child" $
        withRootAndChildThread 42 (const (pure (Left "not a planned descent"))) $ \opened admitted -> do
            case opened of
                Left (RelayEdgeNotPlanned reason) -> reason @?= "not a planned descent"
                other -> assertFailure ("expected a not-planned refusal, got " <> show other)
            case admitted of
                Left detail ->
                    assertBool
                        ("the child was told rather than left waiting, saw " <> detail)
                        ("refused" `Text.isInfixOf` Text.pack detail)
                Right value -> assertFailure ("the child admitted " <> show value)
    , testCase "each opened edge authenticates exactly once through the link" $
        withRoot 43 $ \_ broker activation -> do
            let link =
                    rootBrokerLink
                        broker
                        activation
                        admitEverything
                        admitEveryRecovery
            (relay, token) <- expectRight =<< registerHandoffEdge broker middleFrameInput
            offer <- expectRight (mkHandoffOffer relay middlePayload token)
            challenge <- freshChallenge
            first <- grantThroughLink link offer challenge
            assertBool "the opened edge authenticates" (isRight first)
            -- A second, separately opened edge is its own one-use identity.
            (other, otherToken) <- expectRight =<< registerHandoffEdge broker middleFrameInput
            otherOffer <- expectRight (mkHandoffOffer other middlePayload otherToken)
            otherChallenge <- freshChallenge
            second <- grantThroughLink link otherOffer otherChallenge
            assertBool "a separately opened edge authenticates too" (isRight second)
            assertBool
                "and the two are different transcripts"
                (fmap grantSignature first /= fmap grantSignature second)
    , testCase "an escaped root link refuses before either admission callback runs" $ do
        edgeAdmissions <- newIORef (0 :: Int)
        recoveryAdmissions <- newIORef (0 :: Int)
        (openAfterClose, recoveryAfterClose) <-
            withRecoveryRoot 98 $ \_ broker activation ->
                withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                    withRecoveryProjection broker recoveryInput recoveryWire $ \binding -> do
                        let admitEdge input = do
                                atomicModifyIORef' edgeAdmissions (\count -> (count + 1, ()))
                                admitEverything input
                            admitRecovery input = do
                                atomicModifyIORef' recoveryAdmissions (\count -> (count + 1, ()))
                                admitEveryRecovery input
                            link = rootBrokerLink broker activation admitEdge admitRecovery
                        pure
                            ( fmap
                                (fmap (const ()))
                                (openEdgeThroughLink link middleFrameInput)
                            , fmap
                                (fmap (const ()))
                                (signRecoveryThroughLink link binding recoveryWire)
                            )
        openAfterClose >>= (@?= Left (RelayHandoffFailure HandoffBrokerExpired))
        recoveryAfterClose >>= (@?= Left (RelayHandoffFailure HandoffBrokerExpired))
        readIORef edgeAdmissions >>= (@?= 0)
        readIORef recoveryAdmissions >>= (@?= 0)
    , testCase "broker finalization waits for an admitted operation already holding its lifetime guard" $ do
        admissionEntered <- newEmptyMVar
        releaseAdmission <- newEmptyMVar
        callbackReturned <- newEmptyMVar
        operationDone <- newEmptyMVar
        bracketDone <- newEmptyMVar
        _ <-
            forkIO
                ( withRoot
                    99
                    ( \_ broker activation -> do
                        let admits _ = do
                                putMVar admissionEntered ()
                                takeMVar releaseAdmission
                                pure (Left "blocked admission")
                            link = rootBrokerLink broker activation admits admitEveryRecovery
                        _ <-
                            forkIO
                                ( fmap
                                    (fmap (const ()))
                                    (openEdgeThroughLink link middleFrameInput)
                                    >>= putMVar operationDone
                                )
                        takeMVar admissionEntered
                        putMVar callbackReturned ()
                    )
                    >> putMVar bracketDone ()
                )
        takeMVar callbackReturned
        tryTakeMVar bracketDone >>= (@?= Nothing)
        putMVar releaseAdmission ()
        takeMVar operationDone >>= (@?= Left (RelayEdgeNotPlanned "blocked admission"))
        takeMVar bracketDone
    ]

-- ---------------------------------------------------------------------------
-- Nested relay, across real processes

nestedTests :: [TestTree]
nestedTests =
    [ testCase "a middle process relays its child's edge to the root" $
        withNestedProcesses 44 admitEverything $ \code opened requested middle leaf errors -> do
            opened @?= Right ()
            code @?= ExitSuccess
            -- Both edges were opened at the root: the middle frame asked for
            -- the one below it, it did not mint it. The order is descent order.
            requested @?= ["vm-project-container-2", "pod-3"]
            middle @?= Just middlePayload
            leaf @?= Just leafPayload
            errors @?= ""
    , testCase "an edge the root's plan does not name is refused even when a middle frame asks"
        $ withNestedProcesses
            45
            (\input -> pure (if requestedChildFrame input == "pod-3" then Left "no such descent" else Right ()))
        $ \code opened requested middle leaf errors -> do
            -- The root opened the middle frame's edge and refused the one
            -- below it, so no leaf frame was ever admitted.
            requested @?= ["vm-project-container-2", "pod-3"]
            middle @?= Just middlePayload
            leaf @?= Nothing
            assertBool ("the middle frame failed, saw " <> show code) (code /= ExitSuccess)
            assertBool ("the root's exchange ends in a refusal, saw " <> show opened) (isLeft opened)
            assertBool
                ("the middle frame reported why, saw " <> errors)
                ("no such descent" `Text.isInfixOf` Text.pack errors)
    ]

-- ---------------------------------------------------------------------------
-- Losing the route to the broker

brokerLossTests :: [TestTree]
brokerLossTests =
    [ testCase "a relayed link whose channel is gone refuses, and the edge survives it" $
        withRoot 46 $ \project broker activation -> do
            let rootLink = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            staged <-
                withSeveredAdmittedLink
                    project
                    (rootBrokerVerificationKey broker)
                    rootLink
                    ( \relayed -> do
                        (opened, token) <- expectRight =<< openEdgeThroughLink relayed leafFrameInput
                        offer <- expectRight (mkHandoffOffer opened leafPayload token)
                        challenge <- freshChallenge
                        let bindingBytes = renderHandoffBinding (relayBinding opened)
                            tokenBytes = handoffTokenBytes token
                        pure $ do
                            lost <-
                                fmap
                                    (fmap (const ()))
                                    (grantThroughLink relayed offer challenge)
                            pure (Right (lost, bindingBytes, tokenBytes, challenge))
                    )
            (lost, bindingBytes, tokenBytes, challenge) <- expectRight staged
            case lost of
                Left (RelayProtocolFailure _) -> pure ()
                other -> assertFailure ("expected a transport failure, got " <> show other)
            -- The loss happened before the grant reached the root and consumed
            -- the durable opened edge, so that edge is still authenticatable.
            relay <-
                expectRight
                    ( brokerRelayFromRouteWire
                        (rootBrokerRoute broker)
                        (Just leafFrameInput)
                        bindingBytes
                    )
            token <- expectRight (handoffTokenFromBytes tokenBytes)
            offer <- expectRight (mkHandoffOffer relay leafPayload token)
            recovered <- grantThroughLink rootLink offer challenge
            assertBool "the opened edge survived the lost link" (isRight recovered)
    , testCase "a lost answer reprobes to the same signature rather than minting a second" $
        withRoot 47 $ \_ broker activation -> do
            let link =
                    rootBrokerLink
                        broker
                        activation
                        admitEverything
                        admitEveryRecovery
            (relay, token) <- expectRight =<< registerHandoffEdge broker middleFrameInput
            offer <- expectRight (mkHandoffOffer relay middlePayload token)
            challenge <- freshChallenge
            -- The root consumed the edge; the answer never reached the asker.
            first <- expectRight =<< grantThroughLink link offer challenge
            -- The retry presents the identical transcript and observes the
            -- settled outcome. It does not consume a second edge.
            retry <- expectRight =<< grantThroughLink link offer challenge
            grantSignature retry @?= grantSignature first
            -- A different challenge is a different transcript, and this edge is
            -- spent — which is a reuse refusal, not an unopened one.
            other <- freshChallenge
            replayed <- grantThroughLink link offer other
            replayed `shouldRefuseWith` HandoffTokenConsumed
    ]

shouldRefuseWith :: (Show value) => Either RelayError value -> HandoffError -> IO ()
shouldRefuseWith outcome expected = case outcome of
    Left (RelayHandoffFailure actual) -> actual @?= expected
    other -> assertFailure ("expected " <> show expected <> ", got " <> show other)

-- ---------------------------------------------------------------------------
-- Parent-side protocol enforcement

parentProtocolTests :: [TestTree]
parentProtocolTests =
    [ prematureRelayRequestTest
        71
        "an edge-open request"
        OfferRequestTag
        [renderHandoffBindingInput leafFrameInput]
    , prematureRelayRequestTest
        72
        "a grant request"
        GrantRequestTag
        ["not-an-offer", ByteString.replicate 32 1]
    , prematureRelayRequestTest
        73
        "an activation request"
        ActivationSignRequestTag
        [renderActivationManifest sampleManifest]
    , prematureRelayRequestTest
        74
        "a recovery request"
        RecoveryRequestTag
        ["not-a-binding", "not-a-wire"]
    , testCase "Completed before Accepted is refused as premature" $
        withRoot 75 $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child CompletedTag requestId ["too-early"]
                expectRefused child requestId
            outcome `shouldFailWithUnexpected` CompletedTag
    , testCase "Accepted is a one-way barrier and a duplicate is refused" $
        withRoot 76 $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId [middleConfigDigest]
                sendProtocol child AcceptedTag requestId ["duplicate"]
                expectRefused child requestId
            outcome `shouldFailWithUnexpected` AcceptedTag
    , testCase "Completed accepts only the receiver's closed success marker" $
        withRoot 97 $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId [middleConfigDigest]
                sendProtocol child CompletedTag requestId ["caller-chosen-success"]
                expectRefused child requestId
            case outcome of
                Left (RelayHandoffFailure (HandoffBindingMismatch detail)) ->
                    assertBool
                        ("the refusal names completion status, saw " <> Text.unpack detail)
                        ("completion status" `Text.isInfixOf` detail)
                other -> assertFailure ("expected an unknown-completion refusal, got " <> show other)
    , testCase "Accepted must carry the exact offered config digest before broker dispatch" $
        withRoot 87 $ \_ broker activation -> do
            opens <- newIORef (0 :: Int)
            let admits input = do
                    atomicModifyIORef' opens (\count -> (count + 1, ()))
                    admitEverything input
                link = ordinaryRootLink broker activation admits admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId ["wrong-config-digest"]
                expectRefused child requestId
            count <- readIORef opens
            count @?= 1
            expectRouteRefusal outcome
    , testCase "malformed Accepted fields refuse before broker dispatch" $
        withRoot 88 $ \_ broker activation -> do
            opens <- newIORef (0 :: Int)
            let admits input = do
                    atomicModifyIORef' opens (\count -> (count + 1, ()))
                    admitEverything input
                link = ordinaryRootLink broker activation admits admitEveryRecovery
            outcome <- withRawManualChild link $ \child rawOutbound -> do
                beginPostGrant child
                writeAcceptedWithoutFields rawOutbound
                expectRefused child requestId
            count <- readIORef opens
            count @?= 1
            case outcome of
                Left (RelayProtocolFailure (ProtocolWrongFieldCount AcceptedTag 1 0)) -> pure ()
                other -> assertFailure ("expected malformed Accepted refusal, got " <> show other)
    , testCase "request id zero refuses before edge admission or durable opening" $
        withRoot 89 $ \_ broker activation -> do
            opens <- newIORef (0 :: Int)
            let admits input = do
                    atomicModifyIORef' opens (\count -> (count + 1, ()))
                    admitEverything input
                link = ordinaryRootLink broker activation admits admitEveryRecovery
            outcome <- withChannelPair $ \parentChannel _ ->
                offerHandoffEdge link parentChannel 0 middleFrameInput middlePayload
            count <- readIORef opens
            count @?= 0
            outcome @?= Left (RelayProtocolFailure ProtocolZeroRequestId)
    , testCase "a wrong request id is refused before the admitted child's open capability" $
        withRoot 77 $ \_ broker activation -> do
            opens <- newIORef (0 :: Int)
            let admits input = do
                    atomicModifyIORef' opens (\count -> (count + 1, ()))
                    admitEverything input
                link = ordinaryRootLink broker activation admits admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId [middleConfigDigest]
                sendProtocol
                    child
                    OfferRequestTag
                    (requestId + 1)
                    [renderHandoffBindingInput leafFrameInput]
                expectRefused child requestId
            opened <- readIORef opens
            opened @?= 1
            outcome `shouldFailWithRequestMismatch` (requestId + 1)
    , testCase "a wrong challenge request id is refused before the grant capability" $
        withRoot 78 $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                _ <- expectProtocol child OfferTag requestId
                challenge <- freshChallenge
                sendProtocol child ChallengeTag (requestId + 1) [challengeBytes challenge]
                expectRefused child requestId
            outcome `shouldFailWithRequestMismatch` (requestId + 1)
    , testCase "a malformed challenge is refused while the child is waiting" $
        withRoot 79 $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                _ <- expectProtocol child OfferTag requestId
                sendProtocol child ChallengeTag requestId ["short"]
                expectRefused child requestId
            case outcome of
                Left (RelayHandoffFailure _) -> pure ()
                other -> assertFailure ("expected a malformed-challenge refusal, got " <> show other)
    , testCase "a relayed response with the wrong request id is refused" $
        withRoot 80 $ \project broker _ -> do
            admitted <-
                withManualUpstream
                    project
                    broker
                    "up"
                    middleFrameInput
                    middlePayload
                    ( \edge -> do
                        outcome <-
                            fmap
                                (fmap (const ()))
                                (openEdgeThroughLink (relayedBrokerLink edge) leafFrameInput)
                        pure (Right outcome)
                    )
                    ( \peerChannel -> do
                        _ <- expectProtocol peerChannel OfferRequestTag requestId
                        sendProtocol peerChannel RefusedTag (requestId + 1) ["wrong", "request"]
                        expectRefused peerChannel requestId
                        _ <- expectProtocol peerChannel CompletedTag requestId
                        pure ()
                    )
            outcome <- expectRight admitted
            outcome `shouldFailWithRequestMismatch` (requestId + 1)
    , testCase "a relayed open response cannot substitute another requested edge" $
        withRoot 85 $ \project broker _ -> do
            admitted <-
                withManualUpstream
                    project
                    broker
                    "up"
                    middleFrameInput
                    middlePayload
                    ( \edge -> do
                        outcome <-
                            fmap
                                (fmap (const ()))
                                (openEdgeThroughLink (relayedBrokerLink edge) leafFrameInput)
                        pure (Right outcome)
                    )
                    ( \peerChannel -> do
                        _ <- expectProtocol peerChannel OfferRequestTag requestId
                        let substitutedInput = leafFrameInput{requestedChildFrame = "substituted-child"}
                        (substituted, token) <- expectRight =<< registerHandoffEdge broker substitutedInput
                        sendProtocol
                            peerChannel
                            OfferResponseTag
                            requestId
                            [ frameWire (renderHandoffBinding (relayBinding substituted))
                                <> frameWire (handoffTokenBytes token)
                            ]
                        expectRefused peerChannel requestId
                        _ <- expectProtocol peerChannel CompletedTag requestId
                        pure ()
                    )
            expectRight admitted >>= expectRouteRefusal
    , testCase "a relayed open response cannot change its authenticated root route" $
        withRoot 86 $ \project broker _ -> do
            admitted <-
                withManualUpstream
                    project
                    broker
                    "up"
                    middleFrameInput
                    middlePayload
                    ( \edge -> do
                        outcome <-
                            fmap
                                (fmap (const ()))
                                (openEdgeThroughLink (relayedBrokerLink edge) leafFrameInput)
                        pure (Right outcome)
                    )
                    ( \peerChannel -> do
                        _ <- expectProtocol peerChannel OfferRequestTag requestId
                        (opened, token) <- expectRight =<< registerHandoffEdge broker leafFrameInput
                        let wrongScope = replaceFramedField 3 "Harness attacker" (renderHandoffBinding (relayBinding opened))
                        sendProtocol
                            peerChannel
                            OfferResponseTag
                            requestId
                            [frameWire wrongScope <> frameWire (handoffTokenBytes token)]
                        expectRefused peerChannel requestId
                        _ <- expectProtocol peerChannel CompletedTag requestId
                        pure ()
                    )
            expectRight admitted >>= expectRouteRefusal
    , requesterSpliceTest
        90
        "a sibling requester path"
        "sibling-frame"
    , requesterSpliceTest
        91
        "an ancestor requester path"
        "vm-orchestrator-1"
    , malformedRequesterPathTest
        92
        "an empty requester path"
        ""
    , malformedRequesterPathTest
        93
        "a non-UTF-8 requester path"
        (frameWire (ByteString.pack [0xff]))
    , testCase "a grant for an ancestor edge refuses before token consumption" $
        withRoot 94 $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            (relay, token) <- expectRight =<< registerHandoffEdge broker middleFrameInput
            offer <- expectRight (mkHandoffOffer relay middlePayload token)
            challenge <- freshChallenge
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId [middleConfigDigest]
                sendProtocol
                    child
                    GrantRequestTag
                    requestId
                    [ relayRequesterEnvelope
                        [requestedChildFrame middleFrameInput]
                        (offerWireForTest offer)
                    , challengeBytes challenge
                    ]
                expectRefused child requestId
            expectRouteRefusal outcome
            -- A dispatched grant would have consumed the registered token.
            recovered <- grantThroughLink link offer challenge
            assertBool "the mismatched grant never reached the broker" (isRight recovered)
    ]

prematureRelayRequestTest :: Word8 -> String -> ProtocolTag -> [ByteString] -> TestTree
prematureRelayRequestTest seedByte description tag fields =
    testCase (description <> " before Accepted is refused") $
        withRoot seedByte $ \_ broker activation -> do
            let link = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child tag requestId fields
                expectRefused child requestId
            outcome `shouldFailWithUnexpected` tag

requesterSpliceTest :: Word8 -> String -> Text -> TestTree
requesterSpliceTest seedByte description substitutedParent =
    testCase (description <> " refuses before edge admission") $
        withRoot seedByte $ \_ broker activation -> do
            opens <- newIORef (0 :: Int)
            let admits input = do
                    atomicModifyIORef' opens (\count -> (count + 1, ()))
                    admitEverything input
                link = ordinaryRootLink broker activation admits admitEveryRecovery
                substituted = leafFrameInput{requestedParentFrame = substitutedParent}
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId [middleConfigDigest]
                sendProtocol
                    child
                    OfferRequestTag
                    requestId
                    [ relayRequesterEnvelope
                        [requestedChildFrame middleFrameInput]
                        (renderHandoffBindingInput substituted)
                    ]
                expectRefused child requestId
            readIORef opens >>= (@?= 1)
            expectRouteRefusal outcome

malformedRequesterPathTest :: Word8 -> String -> ByteString -> TestTree
malformedRequesterPathTest seedByte description pathWire =
    testCase (description <> " refuses before edge admission") $
        withRoot seedByte $ \_ broker activation -> do
            opens <- newIORef (0 :: Int)
            let admits input = do
                    atomicModifyIORef' opens (\count -> (count + 1, ()))
                    admitEverything input
                link = ordinaryRootLink broker activation admits admitEveryRecovery
            outcome <- withManualChild link $ \child -> do
                beginPostGrant child
                sendProtocol child AcceptedTag requestId [middleConfigDigest]
                sendProtocol
                    child
                    OfferRequestTag
                    requestId
                    [relayRequesterEnvelopeRaw pathWire (renderHandoffBindingInput leafFrameInput)]
                expectRefused child requestId
            readIORef opens >>= (@?= 1)
            expectRouteRefusal outcome

ordinaryRootLink ::
    RootBroker scope brokerGeneration verb ->
    ActivationBroker scope brokerGeneration verb ->
    EdgeAdmission ->
    RecoveryAdmission ->
    BrokerLink scope brokerGeneration
ordinaryRootLink broker activation =
    rootBrokerLink broker activation

withManualChild ::
    BrokerLink scope brokerGeneration ->
    (HandoffChannel -> IO ()) ->
    IO (Either RelayError ())
withManualChild link speak =
    withChannelPair $ \parentChannel childChannel -> do
        outcomeVar <- newEmptyMVar
        _ <-
            forkIO
                ( offerHandoffEdge link parentChannel requestId middleFrameInput middlePayload
                    >>= putMVar outcomeVar
                )
        speak childChannel
        takeMVar outcomeVar

withRawManualChild ::
    BrokerLink scope brokerGeneration ->
    (HandoffChannel -> Handle -> IO ()) ->
    IO (Either RelayError ())
withRawManualChild link speak = do
    (toParentRead, toParentWrite) <- createPipe
    (toChildRead, toChildWrite) <- createPipe
    parentChannel <- handoffChannel toParentRead toChildWrite
    childChannel <- handoffChannel toChildRead toParentWrite
    outcomeVar <- newEmptyMVar
    _ <-
        forkIO
            ( offerHandoffEdge link parentChannel requestId middleFrameInput middlePayload
                >>= putMVar outcomeVar
            )
    speak childChannel toParentWrite
    outcome <- takeMVar outcomeVar
    hClose toParentRead
    hClose toParentWrite
    hClose toChildRead
    hClose toChildWrite
    pure outcome

writeAcceptedWithoutFields :: Handle -> IO ()
writeAcceptedWithoutFields outbound = do
    valid <- expectRight (protocolMessage AcceptedTag requestId ["accepted"])
    body <- expectRight (unframeWire (encodeProtocolMessage valid))
    let fieldBytes = ByteString.length (frameWire "accepted")
        malformed = frameWire (ByteString.take (ByteString.length body - fieldBytes) body)
    ByteString.hPut outbound malformed
    hFlush outbound

withChannelPair :: (HandoffChannel -> HandoffChannel -> IO result) -> IO result
withChannelPair use = do
    (toFirstRead, toFirstWrite) <- createPipe
    (toSecondRead, toSecondWrite) <- createPipe
    first <- handoffChannel toFirstRead toSecondWrite
    second <- handoffChannel toSecondRead toFirstWrite
    result <- use first second
    hClose toFirstRead
    hClose toFirstWrite
    hClose toSecondRead
    hClose toSecondWrite
    pure result

beginPostGrant :: HandoffChannel -> IO ()
beginPostGrant child = do
    _ <- expectProtocol child OfferTag requestId
    challenge <- freshChallenge
    sendProtocol child ChallengeTag requestId [challengeBytes challenge]
    _ <- expectProtocol child GrantTag requestId
    pure ()

sendProtocol :: HandoffChannel -> ProtocolTag -> Word64 -> [ByteString] -> IO ()
sendProtocol channel tag request fields = do
    message <- expectRight (protocolMessage tag request fields)
    _ <- expectRight =<< channelSend channel message
    pure ()

expectProtocol :: HandoffChannel -> ProtocolTag -> Word64 -> IO ProtocolMessage
expectProtocol channel expectedTag expectedRequest = do
    message <- expectRight =<< channelReceive channel
    protocolMessageTag message @?= expectedTag
    protocolMessageRequestId message @?= expectedRequest
    pure message

expectRefused :: HandoffChannel -> Word64 -> IO ()
expectRefused channel expectedRequest = do
    message <- expectProtocol channel RefusedTag expectedRequest
    length (protocolMessageFields message) @?= 2

shouldFailWithUnexpected :: Either RelayError value -> ProtocolTag -> IO ()
shouldFailWithUnexpected outcome expected = case outcome of
    Left (RelayUnexpectedMessage actual) -> actual @?= expected
    Left other -> assertFailure ("expected an unexpected-message refusal, got " <> show other)
    Right _ -> assertFailure "expected an unexpected-message refusal, got success"

shouldFailWithRequestMismatch :: Either RelayError value -> Word64 -> IO ()
shouldFailWithRequestMismatch outcome actual = case outcome of
    Left (RelayProtocolFailure (ProtocolRequestMismatch expected seen)) -> do
        expected @?= requestId
        seen @?= actual
    Left other -> assertFailure ("expected a request-id refusal, got " <> show other)
    Right _ -> assertFailure "expected a request-id refusal, got success"

expectRouteRefusal :: (Show value) => Either RelayError value -> IO ()
expectRouteRefusal outcome = case outcome of
    Left (RelayHandoffFailure (HandoffBindingMismatch _)) -> pure ()
    other -> assertFailure ("expected a route-binding refusal, got " <> show other)

replaceFramedField :: Int -> ByteString -> ByteString -> ByteString
replaceFramedField index replacement raw
    | index < 0 = error "replaceFramedField: negative index"
    | otherwise = go index raw
  where
    go 0 remaining = case takeHandoffFrame remaining of
        Left failure -> error (show failure)
        Right (_, rest) -> frameWire replacement <> rest
    go remainingIndex remaining = case takeHandoffFrame remaining of
        Left failure -> error (show failure)
        Right (field, rest) -> frameWire field <> go (remainingIndex - 1) rest

relayRequesterEnvelope :: [Text] -> ByteString -> ByteString
relayRequesterEnvelope path =
    relayRequesterEnvelopeRaw
        (ByteString.concat (map (frameWire . TextEncoding.encodeUtf8) path))

relayRequesterEnvelopeRaw :: ByteString -> ByteString -> ByteString
relayRequesterEnvelopeRaw pathWire payload =
    frameWire "hostbootstrap-relay-requester-path-v1"
        <> frameWire pathWire
        <> frameWire payload

offerWireForTest :: HandoffOffer scope brokerGeneration -> ByteString
offerWireForTest offer =
    frameWire payload <> frameWire token <> frameWire binding
  where
    (payload, token, binding) = handoffOfferFrames offer

-- ---------------------------------------------------------------------------
-- The nested probe

{- | One frame of the nested fixture.

In @leaf@ mode it admits its edge and stops. In @relay@ mode it admits its edge
and then launches another copy of itself, handing that copy an edge it obtains
by relaying up the channel it was admitted on — which is the only route it has,
because this process holds no signing key and no protected store.
-}
runRelayProbe :: [String] -> IO ()
runRelayProbe (keyPath : projectName : mode : outPath : rest) = do
    loaded <- installedVerificationKey keyPath
    key <- case loaded of
        Left failure -> hPutStrLn stderr (show failure) >> exitFailure
        Right value -> pure value
    channel <- stdioHandoffChannel
    let expectation =
            ReceiverExpectation
                { receiverProject = Text.pack projectName
                , receiverScopeTag = productionScopeTag
                , receiverVerb = "up"
                , receiverPayloadKind = NarrowedProjectConfig
                }
    admitted <-
        withInstalledProjectIdentity (Text.pack projectName) $ \project ->
            withReceivedHandoffEdge (productionHandoffScope project) channel key expectation $ \edge -> do
                ByteString.writeFile outPath (authenticatedConfigBytes (receivedEdgeConfig edge))
                case (mode, rest) of
                    ("relay", [leafOut]) -> descend edge keyPath projectName leafOut
                    _ -> pure (Right ())
    outcome <- case admitted of
        Left failure -> hPutStrLn stderr (show failure) >> exitFailure
        Right value -> pure value
    case outcome of
        Right () -> exitSuccess
        Left failure -> hPutStrLn stderr (receiverErrorMessage failure) >> exitFailure
runRelayProbe args = do
    hPutStrLn stderr ("unexpected relay probe arguments: " <> show args)
    exitFailure

{- | Launch the next frame down and hand it an edge obtained by relaying.

The link here is 'relayedBrokerLink', derived from the already verified parent
edge. There is no signing key in this process, and no function from what it
holds to one.
-}
descend ::
    ReceivedEdge scope brokerGeneration ->
    FilePath ->
    String ->
    FilePath ->
    IO (Either Text ())
descend edge keyPath projectName leafOut = do
    self <- getExecutablePath
    let link = relayedBrokerLink edge
    spawned <-
        createProcess
            (proc self ["--hostbootstrap-handoff-relay-probe", keyPath, projectName, "leaf", leafOut])
                { std_in = CreatePipe
                , std_out = CreatePipe
                , std_err = CreatePipe
                }
    case spawned of
        (Just leafIn, Just leafOutHandle, Just leafErr, process) -> do
            channel <- handoffChannel leafOutHandle leafIn
            errorsVar <- newEmptyMVar
            _ <- forkIO (hGetContents leafErr >>= \text -> length text `seq` putMVar errorsVar text)
            offered <- offerHandoffEdge link channel requestId leafFrameInput leafPayload
            hClose leafIn
            errors <- takeMVar errorsVar
            code <- waitForProcess process
            pure $ case offered of
                Left failure -> Left (Text.pack (relayErrorMessage failure <> " | leaf: " <> errors))
                Right ()
                    | code == ExitSuccess -> Right ()
                    | otherwise -> Left (Text.pack ("the leaf frame exited " <> show code <> ": " <> errors))
        _ -> pure (Left "the leaf frame was launched without its pipes")

-- ---------------------------------------------------------------------------
-- Fixtures

withNestedProcesses ::
    Word8 ->
    EdgeAdmission ->
    ( ExitCode ->
      Either RelayError () ->
      [Text] ->
      Maybe ByteString ->
      Maybe ByteString ->
      String ->
      IO ()
    ) ->
    IO ()
withNestedProcesses seedByte admits check =
    withSystemTempDirectory "hostbootstrap-handoff-relay" $ \directory -> do
        self <- getExecutablePath
        requested <- newIORef []
        let keyPath = directory </> "project.pub"
            middleOut = directory </> "middle.bytes"
            leafOut = directory </> "leaf.bytes"
        withRootIn directory seedByte $ \project broker activation -> do
            ByteString.writeFile keyPath (verificationKeyBytes (rootBrokerVerificationKey broker))
            let link =
                    rootBrokerLink
                        broker
                        activation
                        (recordingAdmission requested admits)
                        admitEveryRecovery
            spawned <-
                createProcess
                    ( proc
                        self
                        [ "--hostbootstrap-handoff-relay-probe"
                        , keyPath
                        , Text.unpack (installedProjectName project)
                        , "relay"
                        , middleOut
                        , leafOut
                        ]
                    )
                        { std_in = CreatePipe
                        , std_out = CreatePipe
                        , std_err = CreatePipe
                        }
            case spawned of
                (Just middleIn, Just middleOutHandle, Just middleErr, process) -> do
                    channel <- handoffChannel middleOutHandle middleIn
                    errorsVar <- newEmptyMVar
                    _ <-
                        forkIO
                            ( do
                                text <- hGetContents middleErr
                                length text `seq` putMVar errorsVar text
                            )
                    opened <- offerHandoffEdge link channel requestId middleFrameInput middlePayload
                    hClose middleIn
                    errors <- takeMVar errorsVar
                    code <- waitForProcess process
                    asked <- reverse <$> readIORef requested
                    middle <- readIfPresent middleOut
                    leaf <- readIfPresent leafOut
                    check code opened asked middle leaf errors
                _ -> assertFailure "the middle frame was launched without its pipes"

{- | Record which edges the root was asked to open, then answer as the plan
would.

The record is the evidence that a relayed edge reached the root at all: a middle
frame able to open its own would never appear here.
-}
recordingAdmission :: IORef [Text] -> EdgeAdmission -> EdgeAdmission
recordingAdmission requested admits input = do
    atomicModifyIORef' requested (\seen -> (requestedChildFrame input : seen, ()))
    admits input

withRootAndChildThread ::
    Word8 ->
    EdgeAdmission ->
    (Either RelayError () -> Either String ByteString -> IO ()) ->
    IO ()
withRootAndChildThread seedByte admits check =
    withSystemTempDirectory "hostbootstrap-handoff-link" $ \directory ->
        withRootIn directory seedByte $ \project broker activation -> do
            (toChildRead, toChildWrite) <- createPipe
            (toParentRead, toParentWrite) <- createPipe
            childChannel <- handoffChannel toChildRead toParentWrite
            parentChannel <- handoffChannel toParentRead toChildWrite
            childVar <- newEmptyMVar
            _ <-
                forkIO
                    ( do
                        received <-
                            withReceivedHandoffEdge
                                (productionHandoffScope project)
                                childChannel
                                (rootBrokerVerificationKey broker)
                                (middleExpectation project)
                                (\edge -> pure (Right (authenticatedConfigBytes (receivedEdgeConfig edge))))
                        putMVar childVar (either (Left . receiverErrorMessage) Right received)
                    )
            let link =
                    rootBrokerLink
                        broker
                        activation
                        admits
                        admitEveryRecovery
            opened <- offerHandoffEdge link parentChannel requestId middleFrameInput middlePayload
            admitted <- takeMVar childVar
            hClose toChildWrite
            hClose toParentWrite
            check opened admitted

{- | Admit one child over real pipes and let its continuation use the exact
verified edge as its only route back to the parent.
-}
withAdmittedChild ::
    InstalledProjectIdentity projectId ->
    ProjectVerificationKey ->
    Text ->
    BrokerLink (Production projectId) parentGeneration ->
    HandoffBindingInput ->
    ByteString ->
    ( forall childGeneration.
      ReceivedEdge (Production projectId) childGeneration ->
      IO (Either Text result)
    ) ->
    IO (Either RelayError (), Either String result)
withAdmittedChild project key verb parentLink input payload use = do
    (toChildRead, toChildWrite) <- createPipe
    (toParentRead, toParentWrite) <- createPipe
    childChannel <- handoffChannel toChildRead toParentWrite
    parentChannel <- handoffChannel toParentRead toChildWrite
    childVar <- newEmptyMVar
    _ <-
        forkIO
            ( do
                received <-
                    withReceivedHandoffEdge
                        (productionHandoffScope project)
                        childChannel
                        key
                        ReceiverExpectation
                            { receiverProject = installedProjectName project
                            , receiverScopeTag = productionScopeTag
                            , receiverVerb = verb
                            , receiverPayloadKind = NarrowedProjectConfig
                            }
                        use
                putMVar childVar (either (Left . receiverErrorMessage) Right received)
            )
    opened <- offerHandoffEdge parentLink parentChannel requestId input payload
    admitted <- takeMVar childVar
    hClose toChildWrite
    hClose toParentWrite
    pure (opened, admitted)

{- | Admit a real child, let it finish any durable open while the route is
live, then sever both parent handles before it performs the staged action.
-}
withSeveredAdmittedLink ::
    InstalledProjectIdentity projectId ->
    ProjectVerificationKey ->
    BrokerLink (Production projectId) parentGeneration ->
    ( forall childGeneration.
      BrokerLink (Production projectId) childGeneration ->
      IO (IO (Either RelayError result))
    ) ->
    IO (Either RelayError result)
withSeveredAdmittedLink project key parentLink prepare = do
    (toParentRead, toParentWrite) <- createPipe
    (toChildRead, toChildWrite) <- createPipe
    parentChannel <- handoffChannel toParentRead toChildWrite
    childChannel <- handoffChannel toChildRead toParentWrite
    ready <- newEmptyMVar
    proceed <- newEmptyMVar
    actionVar <- newEmptyMVar
    parentVar <- newEmptyMVar
    receiverVar <- newEmptyMVar
    _ <-
        forkIO
            ( offerHandoffEdge parentLink parentChannel requestId middleFrameInput middlePayload
                >>= putMVar parentVar
            )
    _ <-
        forkIO
            ( do
                received <-
                    withReceivedHandoffEdge
                        (productionHandoffScope project)
                        childChannel
                        key
                        (middleExpectation project)
                        ( \edge -> do
                            staged <- prepare (relayedBrokerLink edge)
                            putMVar ready ()
                            takeMVar proceed
                            outcome <- staged
                            putMVar actionVar outcome
                            pure (Right ())
                        )
                putMVar receiverVar received
            )
    takeMVar ready
    -- Sever the paused child's outbound half. Its staged grant will fail on
    -- that closed handle, while the parent concurrently observes EOF and can
    -- leave its receive loop. Closing the parent-owned read handle here would
    -- race its blocked read and can wait forever on the Handle lock.
    hClose toParentWrite
    putMVar proceed ()
    outcome <- takeMVar actionVar
    _ <- takeMVar parentVar
    _ <- takeMVar receiverVar
    hClose toParentRead
    hClose toChildWrite
    hClose toChildRead
    pure outcome

{- | Admit a receiver with a genuine root grant, then let a test peer control
the admitted side of the channel. This is used to prove that malformed
upstream responses cannot be promoted through 'relayedBrokerLink'.
-}
withManualUpstream ::
    InstalledProjectIdentity projectId ->
    RootBroker (Production projectId) rootGeneration verb ->
    Text ->
    HandoffBindingInput ->
    ByteString ->
    ( forall childGeneration.
      ReceivedEdge (Production projectId) childGeneration ->
      IO (Either Text result)
    ) ->
    (HandoffChannel -> IO ()) ->
    IO (Either String result)
withManualUpstream project broker verb input payload use serve =
    withChannelPair $ \parentChannel childChannel -> do
        childVar <- newEmptyMVar
        _ <-
            forkIO
                ( do
                    received <-
                        withReceivedHandoffEdge
                            (productionHandoffScope project)
                            childChannel
                            (rootBrokerVerificationKey broker)
                            ReceiverExpectation
                                { receiverProject = installedProjectName project
                                , receiverScopeTag = productionScopeTag
                                , receiverVerb = verb
                                , receiverPayloadKind = NarrowedProjectConfig
                                }
                            use
                    putMVar childVar (either (Left . receiverErrorMessage) Right received)
                )
        (relay, token) <- expectRight =<< registerHandoffEdge broker input
        offer <- expectRight (mkHandoffOffer relay payload token)
        let (offeredPayload, offeredToken, offeredBinding) = handoffOfferFrames offer
            keyDigest = TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker))
        sendProtocol
            parentChannel
            OfferTag
            requestId
            [offeredPayload, offeredToken, offeredBinding, keyDigest]
        challengeMessage <- expectProtocol parentChannel ChallengeTag requestId
        challenge <- case protocolMessageFields challengeMessage of
            [raw] -> expectRight (handoffChallengeFromBytes raw)
            fields -> assertFailure ("expected one challenge field, got " <> show (length fields))
        grant <- expectRight =<< grantHandoff broker offer challenge
        sendProtocol parentChannel GrantTag requestId [grantSignature grant, keyDigest]
        accepted <- expectProtocol parentChannel AcceptedTag requestId
        protocolMessageFields accepted
            @?= [TextEncoding.encodeUtf8 (childConfigDigest payload)]
        serve parentChannel
        takeMVar childVar

middleExpectation :: InstalledProjectIdentity projectId -> ReceiverExpectation
middleExpectation project =
    ReceiverExpectation
        { receiverProject = installedProjectName project
        , receiverScopeTag = productionScopeTag
        , receiverVerb = "up"
        , receiverPayloadKind = NarrowedProjectConfig
        }

{- | The relayed activation-signing edge.

'withActivationBroker' consumes a @RootInvocationAuthority@ only the root frame
mints, so a nested frame has no route to a signature except this one. These cases
cover the round trip, that a relayed signature is the same one a local signer
would produce, and the two ways the root refuses.
-}
activationSigningTests :: [TestTree]
activationSigningTests =
    [ testCase "an admitted child signs activation through an actual relayed link" $
        withRoot 61 $ \project broker activation -> do
            let rootLink = ordinaryRootLink broker activation admitEverything admitEveryRecovery
            (opened, admitted) <-
                withAdmittedChild
                    project
                    (rootBrokerVerificationKey broker)
                    "up"
                    rootLink
                    middleFrameInput
                    middlePayload
                    ( \edge -> do
                        signed <- linkSignActivation (relayedBrokerLink edge) sampleManifest
                        pure (Right signed)
                    )
            opened @?= Right ()
            signed <- expectRight admitted >>= expectRight
            -- A relayed signature is byte-identical to the local one, so the
            -- relay adds a route rather than a second signing rule.
            local <- expectRight =<< signActivationManifest activation sampleManifest
            activationGrantSignature signed @?= activationGrantSignature local
    , testCase "a manifest with no rollout revision is refused rather than signed" $
        withRoot 62 $ \_ broker activation -> do
            let link =
                    rootBrokerLink
                        broker
                        activation
                        admitEverything
                        admitEveryRecovery
            signed <- linkSignActivation link sampleManifest{manifestRevision = ""}
            case signed of
                Left (RelayActivationRefused _) -> pure ()
                other -> assertFailure ("expected an activation refusal, got " <> show other)
    , testCase "a manifest round-trips through its wire form exactly" $ do
        let wire = renderActivationManifest sampleManifest
        decoded <- expectRight (activationManifestFromWire wire)
        decoded @?= sampleManifest
    , testCase "a truncated or trailing manifest wire is refused, not partially read" $ do
        let wire = renderActivationManifest sampleManifest
        case activationManifestFromWire (ByteString.take (ByteString.length wire - 1) wire) of
            Left _ -> pure ()
            Right value -> assertFailure ("a truncated wire decoded to " <> show value)
        case activationManifestFromWire (wire <> "extra") of
            Left _ -> pure ()
            Right value -> assertFailure ("a wire with trailing bytes decoded to " <> show value)
    , testCase "the effect row survives the wire as a row, not one joined entry" $ do
        let manifest = sampleManifest{manifestPermittedEffects = ["listen", "durable-store"]}
        decoded <- expectRight (activationManifestFromWire (renderActivationManifest manifest))
        manifestPermittedEffects decoded @?= ["listen", "durable-store"]
    ]

-- ---------------------------------------------------------------------------
-- Recovery signing through root and relayed links

recoverySigningTests :: [TestTree]
recoverySigningTests =
    [ testCase "the root signs only a plan-admitted recovery projection" $
        withRecoveryRoot 81 $ \_ broker activation -> do
            requested <- newIORef []
            let admits = recordingRecoveryAdmission requested (admitsRecoveryCoordinates baseRecoveryCoordinates)
                link = ordinaryRootLink broker activation admitEverything admits
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryProjection broker recoveryInput recoveryWire $ \binding -> do
                    grant <- expectRight =<< signRecoveryThroughLink link binding recoveryWire
                    _ <-
                        expectRight
                            ( withVerifiedRecoveryWire
                                (rootBrokerVerificationKey broker)
                                binding
                                recoveryWire
                                grant
                                (const ())
                            )
                    pure ()
            withRecoveryInput refusedRecoveryCoordinates $ \recoveryInput ->
                withRecoveryProjection broker recoveryInput recoveryWire $ \binding -> do
                    refused <- signRecoveryThroughLink link binding recoveryWire
                    case refused of
                        Left (RelayRecoveryNotPlanned reason) -> reason @?= "not a planned recovery edge"
                        Left other -> assertFailure ("expected recovery-plan refusal, got " <> show other)
                        Right _ -> assertFailure "expected recovery-plan refusal, got a grant"
            seen <- readIORef requested
            seen
                @?= [ recoveryCoordinatesTuple baseRecoveryCoordinates
                    , recoveryCoordinatesTuple refusedRecoveryCoordinates
                    ]
    , testCase "a leaf recovery request crosses two actual relayed links to the root" $
        withRecoveryRoot 82 $ \project broker activation ->
            withRecoveryInput leafRecoveryCoordinates $ \recoveryInput -> do
                let key = rootBrokerVerificationKey broker
                    rootLink =
                        ordinaryRootLink
                            broker
                            activation
                            admitEverything
                            (admitsRecoveryCoordinates leafRecoveryCoordinates)
                (rootOpened, middleAdmitted) <-
                    withAdmittedChild
                        project
                        key
                        "down"
                        rootLink
                        middleFrameInput
                        middlePayload
                        ( \middleEdge -> do
                            let middleLink = relayedBrokerLink middleEdge
                            nested <-
                                withAdmittedChild
                                    project
                                    key
                                    "down"
                                    middleLink
                                    leafFrameInput
                                    leafPayload
                                    ( \leafEdge -> do
                                        signed <-
                                            withSignedRecoveryThroughLink
                                                ProjectDown
                                                (relayedBrokerLink leafEdge)
                                                recoveryInput
                                                recoveryWire
                                                ( \binding grant ->
                                                    pure
                                                        ( withVerifiedRecoveryWire
                                                            key
                                                            binding
                                                            recoveryWire
                                                            grant
                                                            (const ())
                                                        )
                                                )
                                        pure (Right signed)
                                    )
                            pure (Right nested)
                        )
                rootOpened @?= Right ()
                (middleOpened, leafAdmitted) <- expectRight middleAdmitted
                middleOpened @?= Right ()
                signed <- expectRight leafAdmitted
                verified <- expectRight signed
                _ <- expectRight verified
                pure ()
    , testCase "recovery cannot reach its admission capability before Accepted" $
        withRecoveryRoot 84 $ \_ broker activation ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryProjection broker recoveryInput recoveryWire $ \binding -> do
                    admissions <- newIORef (0 :: Int)
                    let admits input = do
                            atomicModifyIORef' admissions (\count -> (count + 1, ()))
                            admitsRecoveryCoordinates baseRecoveryCoordinates input
                        link = ordinaryRootLink broker activation admitEverything admits
                    fields <- expectRight (recoveryRequestFields binding recoveryWire)
                    outcome <- withManualChild link $ \child -> do
                        beginPostGrant child
                        sendProtocol child RecoveryRequestTag requestId fields
                        expectRefused child requestId
                    count <- readIORef admissions
                    count @?= 0
                    outcome `shouldFailWithUnexpected` RecoveryRequestTag
    , testCase "recovery for an ancestor edge refuses before plan admission" $
        withRecoveryRoot 96 $ \_ broker activation ->
            withRecoveryInput baseRecoveryCoordinates $ \recoveryInput ->
                withRecoveryProjection broker recoveryInput recoveryWire $ \binding -> do
                    admissions <- newIORef (0 :: Int)
                    let admits input = do
                            atomicModifyIORef' admissions (\count -> (count + 1, ()))
                            admitsRecoveryCoordinates baseRecoveryCoordinates input
                        link = ordinaryRootLink broker activation admitEverything admits
                    fields <- expectRight (recoveryRequestFields binding recoveryWire)
                    outcome <- withManualChild link $ \child -> do
                        beginPostGrant child
                        sendProtocol child AcceptedTag requestId [middleConfigDigest]
                        case fields of
                            [bindingBytes, wire] ->
                                sendProtocol
                                    child
                                    RecoveryRequestTag
                                    requestId
                                    [ relayRequesterEnvelope
                                        [requestedChildFrame middleFrameInput]
                                        bindingBytes
                                    , wire
                                    ]
                            other -> assertFailure ("expected two recovery fields, got " <> show other)
                        expectRefused child requestId
                    readIORef admissions >>= (@?= 0)
                    expectRouteRefusal outcome
    ]

withRecoveryProjection ::
    RootBroker scope brokerGeneration verb ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    ByteString ->
    ( forall recoveryWireDigest.
      RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
      IO result
    ) ->
    IO result
withRecoveryProjection broker input wire use =
    expectRight (mkRecoveryProjectionBinding broker input wire use) >>= id

recordingRecoveryAdmission ::
    IORef [(Text, Text, Text)] ->
    RecoveryAdmission ->
    RecoveryAdmission
recordingRecoveryAdmission requested admits input = do
    atomicModifyIORef' requested (\seen -> (seen <> [recoveryCoordinates input], ()))
    admits input

admitsRecoveryCoordinates :: RecoveryCoordinates -> RecoveryAdmission
admitsRecoveryCoordinates expected actual
    | recoveryCoordinatesTuple expected == recoveryCoordinates actual = pure (Right ())
    | otherwise = pure (Left "not a planned recovery edge")

recoveryCoordinates ::
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    (Text, Text, Text)
recoveryCoordinates input =
    ( requestedRecoveryPlanDigest input
    , requestedRecoveryParentFrame input
    , requestedRecoveryChildFrame input
    )

data RecoveryCoordinates = RecoveryCoordinates
    { recoveryPlanCoordinate :: Text
    , recoveryParentCoordinate :: Text
    , recoveryChildCoordinate :: Text
    }

baseRecoveryCoordinates :: RecoveryCoordinates
baseRecoveryCoordinates =
    RecoveryCoordinates
        { recoveryPlanCoordinate = "plan-digest-1"
        , recoveryParentCoordinate = "vm-orchestrator-1"
        , recoveryChildCoordinate = "vm-project-container-2"
        }

refusedRecoveryCoordinates :: RecoveryCoordinates
refusedRecoveryCoordinates =
    baseRecoveryCoordinates{recoveryChildCoordinate = "unplanned-container"}

leafRecoveryCoordinates :: RecoveryCoordinates
leafRecoveryCoordinates =
    baseRecoveryCoordinates
        { recoveryParentCoordinate = "pod-3"
        , recoveryChildCoordinate = "recovery-child"
        }

recoveryCoordinatesTuple :: RecoveryCoordinates -> (Text, Text, Text)
recoveryCoordinatesTuple coordinates =
    ( recoveryPlanCoordinate coordinates
    , recoveryParentCoordinate coordinates
    , recoveryChildCoordinate coordinates
    )

withRecoveryInput ::
    RecoveryCoordinates ->
    ( forall planDigest parentFrame childFrame.
      RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
      IO result
    ) ->
    IO result
withRecoveryInput coordinates use =
    expectRight
        ( withRecoveryProjectionBindingInput
            (recoveryPlanCoordinate coordinates)
            (recoveryParentCoordinate coordinates)
            (recoveryChildCoordinate coordinates)
            use
        )
        >>= id

recoveryWire :: ByteString
recoveryWire = "recovery-adapter-wire"

-- | A structurally complete manifest; individual cases vary one field.
sampleManifest :: ActivationManifest
sampleManifest =
    ActivationManifest
        { manifestScope = "production"
        , manifestPlanDigest = "plan-1"
        , manifestSpecDigest = "spec-1"
        , manifestBinaryDigest = "binary-1"
        , manifestFrame = "runtime-container"
        , manifestRevision = "revision-1"
        , manifestConfigDigest = "config-1"
        , manifestSecretDigest = activationSecretDigestFromBytes "secret-1"
        , manifestService = "web"
        , manifestRolePlanDigest = "role-plan-1"
        , manifestPermittedEffects = ["listen"]
        , manifestSecretChannel = "file:///run/secrets/web"
        }

withRoot ::
    Word8 ->
    ( forall projectId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) brokerGeneration VerbUp ->
      ActivationBroker (Production projectId) brokerGeneration VerbUp ->
      IO result
    ) ->
    IO result
withRoot seedByte use =
    withSystemTempDirectory "hostbootstrap-handoff-root" $ \directory ->
        withRootIn directory seedByte use

withRootIn ::
    FilePath ->
    Word8 ->
    ( forall projectId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) brokerGeneration VerbUp ->
      ActivationBroker (Production projectId) brokerGeneration VerbUp ->
      IO result
    ) ->
    IO result
withRootIn directory seedByte use = do
    signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
    activationSigning <- activationSigningKey seedByte
    store <- expectRight =<< openProtectedStore (directory </> "authority")
    outcome <- Fixture.withFixtureInstalledProject $ \project ->
        withProductionRoot store project ProjectUp $ \root -> do
            brokered <-
                withRootBroker
                    (productionHandoffScope project)
                    store
                    signing
                    (productionRootAuthority root)
                    ( \broker ->
                        withActivationBroker
                            activationSigning
                            (productionRootAuthority root)
                            (expectActivationPolicy [sampleManifest])
                            (use project broker)
                    )
            result <- expectRight brokered
            pure (Right result)
    expectRight outcome

withRecoveryRoot ::
    Word8 ->
    ( forall projectId (brokerGeneration :: Type).
      InstalledProjectIdentity projectId ->
      RootBroker (Production projectId) brokerGeneration VerbDown ->
      ActivationBroker (Production projectId) brokerGeneration VerbDown ->
      IO result
    ) ->
    IO result
withRecoveryRoot seedByte use =
    withSystemTempDirectory "hostbootstrap-handoff-recovery-root" $ \directory -> do
        signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
        activationSigning <- activationSigningKey seedByte
        store <- expectRight =<< openProtectedStore (directory </> "authority")
        outcome <- Fixture.withFixtureInstalledProject $ \project ->
            withProductionRoot store project ProjectDown $ \root -> do
                brokered <-
                    withRootBroker
                        (productionHandoffScope project)
                        store
                        signing
                        (productionRootAuthority root)
                        ( \broker ->
                            withActivationBroker
                                activationSigning
                                (productionRootAuthority root)
                                (expectActivationPolicy [sampleManifest])
                                (use project broker)
                        )
                result <- expectRight brokered
                pure (Right result)
        expectRight outcome

activationSigningKey :: Word8 -> IO ActivationSigningKey
activationSigningKey seedByte =
    expectRight (activationSigningKeyFromBytes (ByteString.replicate 32 seedByte))

readIfPresent :: FilePath -> IO (Maybe ByteString)
readIfPresent path = do
    present <- doesFileExist path
    if present then Just <$> ByteString.readFile path else pure Nothing

admitEverything :: EdgeAdmission
admitEverything = const (pure (Right ()))

admitEveryRecovery :: RecoveryAdmission
admitEveryRecovery = const (pure (Right ()))

expectActivationPolicy :: [ActivationManifest] -> ActivationSigningPolicy
expectActivationPolicy manifests =
    either (error . show) id (activationSigningPolicy manifests)

middlePayload :: ByteString
middlePayload = ByteStringChar8.pack "{ message = \"middle frame\" }"

middleConfigDigest :: ByteString
middleConfigDigest = TextEncoding.encodeUtf8 (childConfigDigest middlePayload)

leafPayload :: ByteString
leafPayload = ByteStringChar8.pack "{ message = \"leaf frame\" }"

middleFrameInput :: HandoffBindingInput
middleFrameInput = bindingInputFor "vm-orchestrator-1" "vm-project-container-2" middlePayload

leafFrameInput :: HandoffBindingInput
leafFrameInput = bindingInputFor "vm-project-container-2" "pod-3" leafPayload

bindingInputFor :: Text -> Text -> ByteString -> HandoffBindingInput
bindingInputFor parentFrame childFrame payload =
    HandoffBindingInput
        { requestedSpecDigest = "spec-digest-1"
        , requestedPayloadKind = NarrowedProjectConfig
        , requestedPlanRevision = "rev-1"
        , requestedParentFrame = parentFrame
        , requestedChildFrame = childFrame
        , requestedChildConfigDigest = childConfigDigest payload
        , requestedPhase = "execute"
        }

requestId :: Word64
requestId = 909

expectRight :: (Show err) => Either err value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
