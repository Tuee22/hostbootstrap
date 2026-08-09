{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The duplex relay: a nested frame obtaining an edge it cannot issue.

The nested group launches a real chain of processes — this test binary is the
root, it launches a middle frame, and that middle frame launches a leaf. The
middle process holds no signing key and no protected store: every edge it hands
downward was opened and signed by the root, reached over the very channel the
middle process was itself admitted on.
-}
module HandoffRelaySpec (tests, runRelayProbe) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import qualified Fixture
import HostBootstrap.Authority (ProjectVerb (ProjectUp), VerbUp, installedProjectFor)
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Handoff (
    HandoffBindingInput (..),
    HandoffError (HandoffTokenConsumed),
    HandoffPayloadKind (NarrowedProjectConfig),
    ProjectVerificationKey,
    RootBroker,
    authenticatedConfigBytes,
    childConfigDigest,
    freshChallenge,
    grantSignature,
    handoffChannel,
    installedVerificationKey,
    mkHandoffOffer,
    productionHandoffScope,
    productionScopeTag,
    projectSigningKeyFromBytes,
    registerHandoffEdge,
    rootBrokerVerificationKey,
    stdioHandoffChannel,
    verificationKeyBytes,
    withRootBroker,
 )
import HostBootstrap.Handoff.Receiver (
    ReceivedEdge,
    ReceiverExpectation (..),
    receivedEdgeChannel,
    receivedEdgeConfig,
    receivedEdgeRequestId,
    receiverErrorMessage,
    withReceivedHandoffEdge,
 )
import HostBootstrap.Activation (
    ActivationBroker,
    ActivationManifest (..),
    activationGrantSignature,
    activationManifestFromWire,
    renderActivationManifest,
    signActivationManifest,
    withActivationBroker,
 )
import HostBootstrap.Handoff.Relay (
    BrokerLink,
    EdgeAdmission,
    RelayError (..),
    grantThroughLink,
    offerHandoffEdge,
    relayErrorMessage,
    relayedBrokerLink,
    rootBrokerLink,
    linkSignActivation,
 )
import HostBootstrap.Lifecycle.Mode (productionRootAuthority, withProductionRoot)
import HostBootstrap.Protected (openProtectedStore)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitSuccess), exitFailure, exitSuccess)
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
        "HandoffRelaySpec"
        [ testGroup "the root's own link" rootLinkTests
        , testGroup "a nested frame relaying to the root" nestedTests
        , testGroup "losing the route to the broker" brokerLossTests
        , testGroup "relayed activation signing" activationSigningTests
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
        withRoot 43 $ \broker activation -> do
            let link = rootBrokerLink broker activation (rootBrokerVerificationKey broker) admitEverything
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
                ( fmap grantSignature first /= fmap grantSignature second
                )
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
    , testCase "an edge the root's plan does not name is refused even when a middle frame asks" $
        withNestedProcesses
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
        withRoot 46 $ \broker activation -> do
            (relay, token) <- expectRight =<< registerHandoffEdge broker middleFrameInput
            offer <- expectRight (mkHandoffOffer relay middlePayload token)
            challenge <- freshChallenge
            severed <- severedLink (rootBrokerVerificationKey broker)
            lost <- grantThroughLink severed offer challenge
            case lost of
                Left (RelayProtocolFailure _) -> pure ()
                other -> assertFailure ("expected a transport failure, got " <> show other)
            -- The loss happened before anything durable, so the opened edge is
            -- still there to be authenticated.
            let live = rootBrokerLink broker activation (rootBrokerVerificationKey broker) admitEverything
            recovered <- grantThroughLink live offer challenge
            assertBool "the opened edge survived the lost link" (isRight recovered)
    , testCase "a lost answer reprobes to the same signature rather than minting a second" $
        withRoot 47 $ \broker activation -> do
            let link = rootBrokerLink broker activation (rootBrokerVerificationKey broker) admitEverything
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
    outcome <- withReceivedHandoffEdge channel key expectation $ \edge -> do
        ByteString.writeFile outPath (authenticatedConfigBytes (receivedEdgeConfig edge))
        case (mode, rest) of
            ("relay", [leafOut]) -> descend key edge keyPath projectName leafOut
            _ -> pure (Right ())
    case outcome of
        Right () -> exitSuccess
        Left failure -> hPutStrLn stderr (receiverErrorMessage failure) >> exitFailure
runRelayProbe args = do
    hPutStrLn stderr ("unexpected relay probe arguments: " <> show args)
    exitFailure

{- | Launch the next frame down and hand it an edge obtained by relaying.

The link here is 'relayedBrokerLink': a channel, a request identity, and the
installed public key whose digest it advertises. There is no signing key in this
process, and no function from what it holds to one.
-}
descend ::
    ProjectVerificationKey ->
    ReceivedEdge scope brokerGeneration ->
    FilePath ->
    String ->
    FilePath ->
    IO (Either Text ())
descend key edge keyPath projectName leafOut = do
    self <- getExecutablePath
    let link = relayedBrokerLink (receivedEdgeChannel edge) (receivedEdgeRequestId edge) key
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
        withRootIn directory seedByte $ \broker activation -> do
            ByteString.writeFile keyPath (verificationKeyBytes (rootBrokerVerificationKey broker))
            let link =
                    rootBrokerLink
                        broker
                        activation
                        (rootBrokerVerificationKey broker)
                        (recordingAdmission requested admits)
            spawned <-
                createProcess
                    ( proc
                        self
                        [ "--hostbootstrap-handoff-relay-probe"
                        , keyPath
                        , "hostbootstrap-demo"
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
        withRootIn directory seedByte $ \broker activation -> do
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
                                childChannel
                                (rootBrokerVerificationKey broker)
                                middleExpectation
                                (\edge -> pure (Right (authenticatedConfigBytes (receivedEdgeConfig edge))))
                        putMVar childVar (either (Left . receiverErrorMessage) Right received)
                    )
            let link = rootBrokerLink broker activation (rootBrokerVerificationKey broker) admits
            opened <- offerHandoffEdge link parentChannel requestId middleFrameInput middlePayload
            admitted <- takeMVar childVar
            hClose toChildWrite
            hClose toParentWrite
            check opened admitted

middleExpectation :: ReceiverExpectation
middleExpectation =
    ReceiverExpectation
        { receiverProject = "hostbootstrap-demo"
        , receiverScopeTag = productionScopeTag
        , receiverVerb = "up"
        , receiverPayloadKind = NarrowedProjectConfig
        }

severedLink :: ProjectVerificationKey -> IO (BrokerLink scope brokerGeneration)
severedLink key = do
    (readEnd, writeEnd) <- createPipe
    channel <- handoffChannel readEnd writeEnd
    hClose writeEnd
    hClose readEnd
    pure (relayedBrokerLink channel requestId key)

{- | The relayed activation-signing edge.

'withActivationBroker' consumes a @RootInvocationAuthority@ only the root frame
mints, so a nested frame has no route to a signature except this one. These cases
cover the round trip, that a relayed signature is the same one a local signer
would produce, and the two ways the root refuses.
-}
activationSigningTests :: [TestTree]
activationSigningTests =
    [ testCase "the root signs a manifest relayed from its own link" $
        withRoot 61 $ \broker activation -> do
            let link = rootBrokerLink broker activation (rootBrokerVerificationKey broker) admitEverything
            signed <- linkSignActivation link sampleManifest
            grant <- expectRight signed
            -- A relayed signature is byte-identical to the local one, so the
            -- relay adds a route rather than a second signing rule.
            local <- expectRight (signActivationManifest activation sampleManifest)
            activationGrantSignature grant @?= activationGrantSignature local
    , testCase "a manifest with no rollout revision is refused rather than signed" $
        withRoot 62 $ \broker activation -> do
            let link = rootBrokerLink broker activation (rootBrokerVerificationKey broker) admitEverything
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
        , manifestSecretDigest = "secret-1"
        , manifestService = "web"
        , manifestRolePlanDigest = "role-plan-1"
        , manifestPermittedEffects = ["listen"]
        , manifestSecretChannel = "file:///run/secrets/web"
        }

withRoot ::
    Word8 ->
    ( forall (brokerGeneration :: Type).
      RootBroker (Production Fixture.FixtureProject) brokerGeneration VerbUp ->
      ActivationBroker (Production Fixture.FixtureProject) brokerGeneration VerbUp ->
      IO ()
    ) ->
    IO ()
withRoot seedByte use =
    withSystemTempDirectory "hostbootstrap-handoff-root" $ \directory ->
        withRootIn directory seedByte use

withRootIn ::
    FilePath ->
    Word8 ->
    ( forall (brokerGeneration :: Type).
      RootBroker (Production Fixture.FixtureProject) brokerGeneration VerbUp ->
      ActivationBroker (Production Fixture.FixtureProject) brokerGeneration VerbUp ->
      IO ()
    ) ->
    IO ()
withRootIn directory seedByte use = do
    signing <- expectRight (projectSigningKeyFromBytes (ByteString.replicate 32 seedByte))
    store <- expectRight =<< openProtectedStore (directory </> "authority")
    project <-
        either (assertFailure . show) pure
            (installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo")
    outcome <- withProductionRoot store project ProjectUp $ \root -> do
        brokered <-
            withRootBroker
                (productionHandoffScope project)
                store
                signing
                (productionRootAuthority root)
                ( \broker ->
                    withActivationBroker (productionRootAuthority root) (use broker)
                )
        _ <- expectRight brokered
        pure (Right ())
    _ <- expectRight outcome
    pure ()

readIfPresent :: FilePath -> IO (Maybe ByteString)
readIfPresent path = do
    present <- doesFileExist path
    if present then Just <$> ByteString.readFile path else pure Nothing

admitEverything :: EdgeAdmission
admitEverything = const (pure (Right ()))

middlePayload :: ByteString
middlePayload = ByteStringChar8.pack "{ message = \"middle frame\" }"

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
