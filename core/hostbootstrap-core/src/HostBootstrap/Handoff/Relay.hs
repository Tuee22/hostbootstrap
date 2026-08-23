{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The parent half of the authenticated handoff, and the duplex relay that
lets a frame which cannot sign still hand authority downward
(§ X, § EE, the authenticated-handoff-and-child-admission phase).

The root owns the capabilities reached through this channel: opening an edge,
granting it over the child's challenge, signing an admitted activation
manifest, and signing an exact plan-admitted recovery projection. A
'BrokerLink' is how a frame reaches them:

* at the root, 'rootBrokerLink' holds the live brokers and admission predicates
  naming which handoff edges and recovery projections its plan contains;
* at every other frame, the config/recovery-specific link brackets derive a
  private link from the already classified parent edge. It retains that edge's
  channel, request identity, root-route coordinates, and installed public-key
  digest. It is *structurally* keyless: there is no signing key or protected
  store, and no function from it to a 'RootBroker'. It forwards, waits, and
  passes the answer on.

The recursion is what makes one shape serve every depth. 'offerHandoffEdge'
opens an edge through its link, offers it to the child, and then stays on the
channel serving whatever the child relays upward — which, at an intermediate
frame, it satisfies by relaying further up its own link. So a request raised at
the innermost frame walks outward to the root and its answer walks back, with
each frame in between holding no more than a pipe.
-}
module HostBootstrap.Handoff.Relay (
    -- * Reaching the root
    BrokerLink,
    linkSignActivation,
    receiveRootedLifecycleResponseThroughLink,
    prepareLifecycleAcknowledgementThroughLink,
    adoptLifecycleAcknowledgementThroughLink,
    rootBrokerLink,
    rootForwardBrokerLink,
    rootReverseBrokerLink,
    publishRootedLifecycleReportKernel,
    persistRootedLifecycleCompletionKernel,
    withConfigBrokerLink,
    withRecoveryBrokerLink,
    withNestedRecursiveHandoffRuntimeKernel,
    EdgeAdmission,
    RecoveryAdmission,

    -- * Handing an edge to a child
    offerHandoffEdge,
    offerReverseDescentKernel,
    withReceivedLifecycleAcknowledgementKernel,
    withReceivedRecoveryLifecycleAcknowledgementKernel,

    -- * Opening one rooted frame exchange
    withRootedOpenedResponseKernel,
    withRootedPreparedResponseKernel,
    withRootedPostOpenResponseKernel,

    -- * Confirming one terminal receipt
    withRootedTerminalReceiptKernel,

    -- * Provider dependency reprobe service kernel
    withProviderDependencyReprobeServiceKernel,
    withProviderDependencyReprobeEndpointKernel,

    -- * Failures
    RelayError (..),
    relayErrorMessage,
) where

import Control.Concurrent.MVar (
    modifyMVar,
    modifyMVar_,
    newEmptyMVar,
    newMVar,
    putMVar,
    readMVar,
    takeMVar,
 )
import Control.Exception (
    SomeAsyncException,
    SomeException,
    evaluate,
    finally,
    fromException,
    mask,
    throwIO,
    try,
 )
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Activation (
    ActivationBroker,
    ActivationError,
    ActivationGrant,
    ActivationManifest,
    activationErrorMessage,
    activationGrantSignature,
    activationManifestFromWire,
    adoptRelayedActivationGrant,
    renderActivationManifest,
    signActivationManifest,
 )
import HostBootstrap.Authority (ProjectVerb (ProjectDestroy, ProjectDown))
import HostBootstrap.Handoff (
    AuthenticatedConfigPayload,
    AuthenticatedRootScope,
    BrokerRelay,
    BrokerRoute,
    HandoffBindingInput,
    HandoffChallenge,
    HandoffError (HandoffBindingMismatch, HandoffWireTrailingBytes),
    HandoffGrant,
    HandoffOffer,
    HandoffPayloadKind (NarrowedProjectConfig, RecoveryAdapterWire),
    HandoffScope,
    HandoffToken,
    ProjectVerificationKey,
    RecoveryProjectionBinding,
    RecoveryProjectionBindingInput,
    RecoveryWireGrant,
    RootBroker,
    RootedLifecycleResponse,
    renderRootedLifecycleResponse,
    signRootedLifecycleResponseKernel,
    brokerRelayFromRouteWire,
    brokerRouteCurrentFrame,
    brokerRouteVerificationKeyDigest,
    challengeBytes,
    childConfigDigest,
    frameWire,
    grantHandoff,
    grantSignature,
    handoffBindingInputFromWire,
    handoffChallengeFromBytes,
    handoffChildConfigDigest,
    handoffChildFrame,
    handoffErrorMessage,
    handoffGrantFromSignature,
    handoffOfferBinding,
    handoffOfferFrames,
    handoffParentFrame,
    handoffPayloadKind,
    handoffPhase,
    handoffPlanRevision,
    handoffVerb,
    handoffTokenBytes,
    handoffTokenFromBytes,
    eliminateLifecycleReport,
    mkHandoffOffer,
    mkRecoveryProjectionBindingFromRoute,
    recoveryRequestFields,
    recoveryRequestFromFields,
    recoveryResponseFields,
    recoveryResponseFromFields,
    recoveryWireGrantSignature,
    renderLifecycleAcknowledgement,
    prepareLifecycleAcknowledgementKernel,
    publishLifecycleReportKernel,
    receiveLifecycleAcknowledgementKernel,
    adoptLifecycleAcknowledgementKernel,
    registerAdmittedHandoffEdge,
    registerRecoverableAdmittedHandoffEdgeKernel,
    relayBinding,
    renderAuthenticatedRootScope,
    renderHandoffBinding,
    renderHandoffBindingInput,
    renderRecoveryProjectionBinding,
    renderRootedPayloadBinding,
    requestedChildConfigDigest,
    requestedParentFrame,
    requestedPayloadKind,
    requestedRecoveryParentFrame,
    rootBrokerRoute,
    signAuthenticatedRootScopeKernel,
    signRecoveryChildPackageBindingKernel,
    signRecoveryWireKernel,
    signRootedPayloadBindingKernel,
    takeHandoffFrame,
    verificationKeyDigest,
    verifyLifecycleAcknowledgement,
    verifiedHandoffBinding,
    verifiedHandoffRoute,
    verifiedConfigPayload,
    providerDependencyPackageFields,
    withProviderDependencyReprobeKernel,
    withVerifiedRootedLifecycleResponse,
    withRecoveryProjectionBindingInput,
 )
import HostBootstrap.Handoff.Internal (recoverySigningKernel)
import qualified HostBootstrap.Handoff.Recovery as Recovery
import qualified HostBootstrap.Handoff.Rooted as Rooted
import HostBootstrap.Handoff.Protocol (
    HandoffChannel,
    ProtocolError (ProtocolRequestMismatch, ProtocolZeroRequestId),
    ProtocolMessage,
    ProtocolTag (
        AcceptedTag,
        AcknowledgedTag,
        ActivationSignRequestTag,
        ActivationSignResponseTag,
        ChallengeTag,
        CompletedTag,
        GrantRequestTag,
        GrantResponseTag,
        GrantTag,
        LifecycleAckRequestTag,
        LifecycleAckResponseTag,
        OfferRequestTag,
        OfferResponseTag,
        OfferTag,
        RecoveryRequestTag,
        RecoveryResponseTag,
        RefusedTag,
        ProviderDependencyProbeRequestTag,
        ProviderDependencyProbeResponseTag,
        ProviderDependencyPackageTag,
        RootedLifecycleRequestTag,
        RootedLifecycleResponseTag
    ),
    channelReceive,
    channelSend,
    protocolErrorMessage,
    protocolMessage,
    protocolMessageFields,
    protocolMessageRequestId,
    protocolMessageTag,
 )
import HostBootstrap.Handoff.Runtime (
    RecursiveHandoffRuntime,
    nestedRecursiveHandoffRuntimeKernel,
    withRootArmRecursiveHandoffRuntimeKernel,
 )
import HostBootstrap.Handoff.Receiver.Internal (
    ReceivedEdge,
    ReceivedRecoveryDescent,
    receivedEdgeAuthenticatedRootScope,
    receivedEdgeChannel,
    receivedEdgeHandoff,
    receivedEdgeRequestId,
    rootedLifecycleRequestPathKernel,
    rootedLifecycleResponsePairPathKernel,
    withReceivedRecoveryDescent,
 )
import HostBootstrap.Lifecycle.Rooted (
    RootedFrameSession,
    withRootedFrameOpeningKernel,
    withRootedFrameSessionKernel,
 )
import HostBootstrap.Lifecycle.Prepared.Internal (
    PreparedNodeGrant,
    renderPreparedNodeKeysKernel,
    withPreparedNodeGrantKernel,
 )
import HostBootstrap.Lifecycle.Rooted.Receipt (
    withRootedReceiptConfirmationKernel,
    withRootedTerminalReportKernel,
 )
import HostBootstrap.Protected (ProtectedStore)
import HostBootstrap.Teardown (teardownErrorMessage)
import HostBootstrap.Teardown.Internal (ReverseDescent, withBoundReverseDescentKernel)
import System.Timeout (timeout)

withProviderDependencyReprobeServiceKernel ::
    ByteString ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    IO (Either Text Word64) ->
    (([ByteString] -> IO (Either Text [ByteString])) -> IO result) ->
    IO result
withProviderDependencyReprobeServiceKernel = withProviderDependencyReprobeKernel

-- ---------------------------------------------------------------------------
-- Reaching the root

{- | Which edges a root will open.

The root re-derives project, scope, generation, and verb from its own typed
evidence, so a request can only influence the frames, phase, and digests. Those
still matter: without this predicate a root would sign for any well-formed edge
it was asked about, and relaying would be signing one message removed. The plan
that knows which descents exist supplies the answer.

It answers in @IO@ because the thing that knows is the live plan and its durable
state, not a table a caller can fold into a pure function.
-}
type EdgeAdmission = HandoffBindingInput -> IO (Either Text ())

{- | Which recovery projections a root plan permits.

The relay authenticates the canonical recovery binding against the live root
broker before this callback runs. The callback sees only the plan and edge
coordinates a plan must authorize and returns the exact canonical adapter bytes
that plan expects. It never receives the candidate wire.
-}
type RecoveryAdmission =
    forall planDigest parentFrame childFrame.
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    IO (Either Text ByteString)

{- | Repository-sealed requester ancestry, nearest upstream frame first.

The type and codec stay private. A public operation starts with the current
frame retained by its verified route; a serving parent validates the path
against the exact child it admitted and prepends its own current frame before
forwarding. The root therefore sees provenance for a multi-hop request without
giving an intermediate frame a signer. This is the § HH boundary for ordinary
'BrokerLink' use: it does not cryptographically constrain a caller that
deliberately retained and writes the raw 'HandoffChannel'. Exact root admission
remains the authorization check for every requested edge or recovery projection.
-}
type RequesterPath = [Text]

{- | What a root answers a rooted lifecycle request with.

The shape is the link field's own, so installing a live endpoint changes which
function the root arm runs and nothing about how the route carries the answer.
An outer refusal stays an outer refusal and a signed response stays opaque
bytes: this endpoint decides which of the two a request receives, never what a
relayed hop is allowed to read.

Nothing here is a capability. The one endpoint the repository builds is
'withRootedOpenedResponseKernel', which reaches the fixed signer only through
the hidden recovery signing admission and only after the durable attachment it
answers has been read back.
-}
type RootedLifecycleService =
    RequesterPath ->
    ByteString ->
    IO (Either RelayError (Either (ByteString, ByteString) ByteString))

{- | A frame's route to the root-owned capabilities.

Opaque, and deliberately so: the two constructors below are the only ways to
build one, and only one of them has a key behind it.
-}
data BrokerLink scope brokerGeneration = BrokerLink
    { linkRoute :: BrokerRoute scope brokerGeneration
    , linkAuthenticatedRootScope :: AuthenticatedRootScope scope
    , linkOpenRaw ::
        RequesterPath ->
        HandoffBindingInput ->
        IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
    , linkRecoverableOpenRaw ::
        RequesterPath ->
        HandoffBindingInput ->
        ByteString ->
        IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
    , linkGrantRaw ::
        RequesterPath ->
        HandoffOffer scope brokerGeneration ->
        HandoffChallenge ->
        IO (Either RelayError (HandoffGrant scope brokerGeneration))
    , linkSignActivationRaw ::
        RequesterPath ->
        ActivationManifest ->
        IO (Either RelayError ActivationGrant)
    {- ^ Ask this frame's route to the root to sign one activation manifest.

    The root signs; every other frame relays. That asymmetry is the whole
    point: 'withActivationBroker' consumes a @RootInvocationAuthority@ the
    root alone can mint, and the services that need a signed manifest are
    deployed from nested frames.
    -}
    , linkRootedBindingRaw ::
        RequesterPath ->
        HandoffOffer scope brokerGeneration ->
        IO (Either RelayError ByteString)
    {- ^ Authenticate one already constructed exact offer at the root. -}
    , linkRecoveryFieldsRaw ::
        RequesterPath ->
        [ByteString] ->
        IO (Either RelayError [ByteString])
    {- ^ Route the closed recovery request fields to the root. The typed public
    entry below constructs and adopts these fields; relay dispatch uses the
    same raw route because an intermediate has no root broker with which to
    mint a typed projection.
    -}
    , linkLifecycleAcknowledgementRaw ::
        RequesterPath ->
        ByteString ->
        (ByteString -> IO (Either RelayError ())) ->
        IO (Either RelayError ())
    {- ^ Route one canonical lifecycle request and consume its canonical
    response in a fixed-unit continuation. The raw bytes remain private to
    Relay; root links interpret them and keyless links only carry them.
    -}
    , linkRootedLifecycleRaw ::
        RequesterPath ->
        ByteString ->
        IO (Either RelayError (Either (ByteString, ByteString) ByteString))
    {- ^ Carry one exact rooted lifecycle request. The inner sum keeps an
    upstream outer refusal distinct from a successfully transported signed
    rooted response, without exposing either raw route as a module export.
    -}
    , linkProviderDependencyRaw ::
        [ByteString] -> IO (Either RelayError [ByteString])
    {- ^ Carry one exact provider request to the nearest owning live kernel.
    Root links refuse until Process installs that lexical endpoint; keyless
    links preserve the canonical fields without interpreting them. -}
    , linkProviderDependencyPackage :: Maybe ByteString
    , linkRejectResponse :: RelayError -> IO ()
    {- ^ Best-effort refusal for a malformed response. It is a no-op at the
    root and a protocol refusal on a relayed link.
    -}
    , linkKeyDigest :: ByteString
    }

type role BrokerLink nominal nominal

instance Show (BrokerLink scope brokerGeneration) where
    show _ = "BrokerLink <to root>"

{- | The root frame's own link: it opens edges its plan admits, and signs.

This is the only 'BrokerLink' with a signing capability behind it, and the
'RootBroker' that supplies it is constructed only by @withRootBroker@. The
opaque link can be retained, but every root-backed mutation, admission callback,
or signature then passes through the brokers' runtime lifetime guards and
refuses after the invocation bracket closes.
-}
rootBrokerLink ::
    RootBroker scope brokerGeneration verb ->
    HandoffScope scope ->
    -- | the activation broker whose key the runtimes verify against
    ActivationBroker scope brokerGeneration verb ->
    EdgeAdmission ->
    RecoveryAdmission ->
    -- | the live rooted lifecycle endpoint this root serves
    RootedLifecycleService ->
    IO (Either RelayError (BrokerLink scope brokerGeneration))
rootBrokerLink broker scope activation admits admitsRecovery serveRooted = do
    authenticated <- signAuthenticatedRootScopeKernel recoverySigningKernel broker scope
    pure $ do
        rootScope <- either (Left . RelayHandoffFailure) Right authenticated
        pure
            BrokerLink
                { linkRoute = route
                , linkAuthenticatedRootScope = rootScope
                , linkOpenRaw = \_ input -> case requireConfigOpen input of
                    Left failure -> pure (Left failure)
                    Right () -> registered <$> registerAdmittedHandoffEdge broker (admits input) input
                , linkRecoverableOpenRaw = \_ input adapter ->
                    registered
                        <$> registerRecoverableAdmittedHandoffEdgeKernel
                            recoverySigningKernel broker (admits input) input adapter
                , linkGrantRaw = \_ offer challenge ->
                    fmap (either (Left . RelayHandoffFailure) Right) (grantHandoff broker offer challenge)
                , -- The root signs locally, through the ordinary validating signer: a
                  -- relayed manifest gets no weaker check than a local one.
                  linkSignActivationRaw = \_ manifest ->
                    fmap
                        (either (Left . RelayActivationRefused) Right)
                        (signActivationManifest activation manifest)
                , linkRootedBindingRaw = \_ -> rootSignRootedBinding broker
                , linkRecoveryFieldsRaw = \_ -> rootSignRecovery broker admitsRecovery
                , linkLifecycleAcknowledgementRaw = \_ request respond ->
                    rootLifecycleAcknowledgement broker route request respond
                , linkRootedLifecycleRaw = \path exactRequest ->
                    case rootedRequestPath exactRequest
                        >>= requireRootedRequesterPath True path of
                        Left failure -> pure (Left failure)
                        Right () -> serveRooted path exactRequest
                , linkProviderDependencyRaw = const (pure (Left (RelayEdgeNotPlanned "no provider reprobe endpoint is installed")))
                , linkProviderDependencyPackage = Nothing
                , linkRejectResponse = const (pure ())
                , linkKeyDigest = brokerRouteVerificationKeyDigest route
                }
  where
    route = rootBrokerRoute broker
    registered = either (Left . RelayHandoffFailure) (either (Left . RelayEdgeNotPlanned) Right)

{- | The root link used by the recursive forward coordinator.

It carries exactly the capabilities a forward lifecycle child can exercise.
Activation and recovery signing are closed refusals, so the coordinator does
not need to manufacture unrelated authority merely to own a child process.
-}
rootForwardBrokerLink ::
    RootBroker scope brokerGeneration verb ->
    HandoffScope scope ->
    EdgeAdmission ->
    (HandoffOffer scope brokerGeneration -> IO (Either Text ())) ->
    RootedLifecycleService ->
    IO (Either RelayError (BrokerLink scope brokerGeneration))
rootForwardBrokerLink broker scope admits retainOffer serveRooted = do
    authenticated <- signAuthenticatedRootScopeKernel recoverySigningKernel broker scope
    pure $ do
        rootScope <- either (Left . RelayHandoffFailure) Right authenticated
        pure
            BrokerLink
                { linkRoute = route
                , linkAuthenticatedRootScope = rootScope
                , linkOpenRaw = \_ input -> registered <$> registerAdmittedHandoffEdge broker (admits input) input
                , linkRecoverableOpenRaw = \_ _ _ ->
                    pure (Left (RelayRecoveryNotPlanned "the forward coordinator admits no recovery edge"))
                , linkGrantRaw = \_ offer challenge -> do
                    retained <- retainOffer offer
                    case retained of
                        Left failure -> pure (Left (RelayEdgeNotPlanned failure))
                        Right () -> fmap (either (Left . RelayHandoffFailure) Right) (grantHandoff broker offer challenge)
                , linkSignActivationRaw = \_ _ ->
                    pure (Left (RelayEdgeNotPlanned "the forward coordinator carries no activation signer"))
                , linkRootedBindingRaw = \_ -> rootSignRootedBinding broker
                , linkRecoveryFieldsRaw = \_ _ ->
                    pure (Left (RelayRecoveryNotPlanned "the forward coordinator carries no recovery signer"))
                , linkLifecycleAcknowledgementRaw = \_ request respond ->
                    rootLifecycleAcknowledgement broker route request respond
                , linkRootedLifecycleRaw = \path exactRequest ->
                    case rootedRequestPath exactRequest >>= requireRootedRequesterPath True path of
                        Left failure -> pure (Left failure)
                        Right () -> serveRooted path exactRequest
                , linkProviderDependencyRaw = const (pure (Left (RelayEdgeNotPlanned "no provider reprobe endpoint is installed")))
                , linkProviderDependencyPackage = Nothing
                , linkRejectResponse = const (pure ())
                , linkKeyDigest = brokerRouteVerificationKeyDigest route
                }
  where
    route = rootBrokerRoute broker
    registered = either (Left . RelayHandoffFailure) (either (Left . RelayEdgeNotPlanned) Right)

{- | Root link restricted to prepared reverse edges.

Config opening and activation signing are closed refusals. Recoverable opening,
recovery signing, rooted responses, and lifecycle acknowledgements remain the
exact root-broker operations the prepared reverse exchange requires.
-}
rootReverseBrokerLink ::
    RootBroker scope brokerGeneration verb ->
    HandoffScope scope ->
    EdgeAdmission ->
    RecoveryAdmission ->
    (HandoffOffer scope brokerGeneration -> IO (Either Text ())) ->
    RootedLifecycleService ->
    IO (Either RelayError (BrokerLink scope brokerGeneration))
rootReverseBrokerLink broker scope admits admitsRecovery retainOffer serveRooted = do
    authenticated <- signAuthenticatedRootScopeKernel recoverySigningKernel broker scope
    pure $ do
        rootScope <- either (Left . RelayHandoffFailure) Right authenticated
        pure BrokerLink
            { linkRoute = route
            , linkAuthenticatedRootScope = rootScope
            , linkOpenRaw = \_ _ -> pure (Left (RelayEdgeNotPlanned "the reverse coordinator admits no config edge"))
            , linkRecoverableOpenRaw = \_ input adapter ->
                registered <$> registerRecoverableAdmittedHandoffEdgeKernel
                    recoverySigningKernel broker (admits input) input adapter
            , linkGrantRaw = \_ offer challenge -> do
                retained <- retainOffer offer
                case retained of
                    Left failure -> pure (Left (RelayEdgeNotPlanned failure))
                    Right () -> fmap (either (Left . RelayHandoffFailure) Right) (grantHandoff broker offer challenge)
            , linkSignActivationRaw = \_ _ ->
                pure (Left (RelayEdgeNotPlanned "the reverse coordinator carries no activation signer"))
            , linkRootedBindingRaw = \_ -> rootSignRootedBinding broker
            , linkRecoveryFieldsRaw = \_ -> rootSignRecovery broker admitsRecovery
            , linkLifecycleAcknowledgementRaw = \_ request respond ->
                rootLifecycleAcknowledgement broker route request respond
            , linkRootedLifecycleRaw = \path exactRequest ->
                case rootedRequestPath exactRequest >>= requireRootedRequesterPath True path of
                    Left failure -> pure (Left failure)
                    Right () -> serveRooted path exactRequest
            , linkProviderDependencyRaw = const (pure (Left (RelayEdgeNotPlanned "no provider reprobe endpoint is installed")))
            , linkProviderDependencyPackage = Nothing
            , linkRejectResponse = const (pure ())
            , linkKeyDigest = brokerRouteVerificationKeyDigest route
            }
  where
    route = rootBrokerRoute broker
    registered = either (Left . RelayHandoffFailure) (either (Left . RelayEdgeNotPlanned) Right)

-- | Publish and strictly reread the report carried by one rooted close.
publishRootedLifecycleReportKernel ::
    ProtectedStore -> ByteString -> IO (Either Text ())
publishRootedLifecycleReportKernel store report = do
    published <- publishLifecycleReportKernel recoverySigningKernel store report
    pure $ either (Left . Text.pack . handoffErrorMessage) Right published

-- | Convergently publish and acknowledge the exact rooted terminal report.
persistRootedLifecycleCompletionKernel ::
    ProtectedStore -> ByteString -> ByteString -> IO (Either Text ())
persistRootedLifecycleCompletionKernel store report acknowledgement = do
    published <- publishRootedLifecycleReportKernel store report
    case published of
        Left failure -> pure (Left failure)
        Right () -> do
            received <-
                receiveLifecycleAcknowledgementKernel
                    recoverySigningKernel store report acknowledgement
            pure $ either (Left . Text.pack . handoffErrorMessage) Right received

{- | Every other frame's link, derived from its already verified parent edge.

The edge supplies the exact route identity, installed public-key digest,
channel, and request id together; none is independently caller-selectable.
There is no signing key here and no path to one. A frame holding this can ask
the root to open or grant an edge and authenticate admitted activation or
recovery material; it cannot do any of those itself.
-}
relayedBrokerLinkKernel ::
    ReceivedEdge scope brokerGeneration ->
    BrokerLink scope brokerGeneration
relayedBrokerLinkKernel edge =
    BrokerLink
        { linkRoute = route
        , linkAuthenticatedRootScope = receivedEdgeAuthenticatedRootScope edge
        , linkOpenRaw = \downstream input -> case requireConfigOpen input of
            Left failure -> pure (Left failure)
            Right () -> relayOpen route channel request (currentFrame : downstream) input
        , linkRecoverableOpenRaw = \downstream ->
            relayRecoverableOpen route channel request (currentFrame : downstream)
        , linkGrantRaw = \downstream -> relayGrant channel request (currentFrame : downstream)
        , linkSignActivationRaw =
            \downstream -> relaySignActivation channel request (currentFrame : downstream)
        , linkRootedBindingRaw =
            \downstream -> relayRootedBinding channel request (currentFrame : downstream)
        , linkRecoveryFieldsRaw =
            \downstream -> relayRecoveryFields channel request (currentFrame : downstream)
        , linkLifecycleAcknowledgementRaw =
            \downstream lifecycleRequest ->
                relayLifecycleAcknowledgement
                    route
                    channel
                    request
                    (currentFrame : downstream)
                    lifecycleRequest
        , linkRootedLifecycleRaw =
            \downstream exactRequest ->
                relayRootedLifecycle
                    channel
                    request
                    (currentFrame : downstream)
                    exactRequest
        , linkProviderDependencyRaw = relayProviderDependency channel request
        , linkProviderDependencyPackage = Nothing
        , linkRejectResponse = \failure -> do
            _ <- refuse channel request failure
            pure ()
        , linkKeyDigest = brokerRouteVerificationKeyDigest route
        }
  where
    route = verifiedHandoffRoute (receivedEdgeHandoff edge)
    currentFrame = handoffChildFrame (verifiedHandoffBinding (receivedEdgeHandoff edge))
    channel = receivedEdgeChannel edge
    request = receivedEdgeRequestId edge

{- | Install one bracket-scoped provider endpoint without changing any other
root or relay capability. The handler is data-only and cannot escape the
continuation that owns the Process exchange.
-}
withProviderDependencyReprobeEndpointKernel ::
    BrokerLink scope brokerGeneration ->
    ByteString ->
    ([ByteString] -> IO (Either Text [ByteString])) ->
    (BrokerLink scope brokerGeneration -> IO result) ->
    IO result
withProviderDependencyReprobeEndpointKernel link packageWire endpoint use =
    use link
        { linkProviderDependencyRaw = fmap (either (Left . RelayEdgeNotPlanned) Right) . endpoint
        , linkProviderDependencyPackage = Just packageWire
        }

{- | Open a keyless child route only inside the exact config-kind branch.

The config witness is re-derived from the retained verified handoff rather than
accepted beside it: scope and generation alone do not distinguish two edges
under one broker. The fixed unit result removes the ordinary link-return
channel, and the private importer allowlist owns the remaining callback scope.
-}
withConfigBrokerLink ::
    ReceivedEdge scope brokerGeneration ->
    ( AuthenticatedConfigPayload scope brokerGeneration ->
      BrokerLink scope brokerGeneration ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withConfigBrokerLink edge use =
    case verifiedConfigPayload (receivedEdgeHandoff edge) of
        Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
        Right authenticated ->
            authenticated `seq` use authenticated (relayedBrokerLinkKernel edge)

{- | Open a keyless child route only inside one sealed recovery branch.

The internal fold forces the complete recovery package but supplies this
wrapper only the exact retained edge. The caller receives the original opaque
descent and the derived link, never the edge or its evidence fields.
-}
withRecoveryBrokerLink ::
    ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame childFrame
        recoveryWireDigest recoveryWireId verb ->
    ( ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame childFrame
        recoveryWireDigest recoveryWireId verb ->
      BrokerLink scope brokerGeneration ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withRecoveryBrokerLink descent use =
    withReceivedRecoveryDescent descent $ \edge _recovery _verb _adapter _projection _grant ->
        use descent (relayedBrokerLinkKernel edge)

{- | Install one nested frame's recursive-handoff runtime beside its keyless route.

A nested frame never derives the two independently. The runtime's coordinates
come from the authenticated binding the root opened and the route that edge
carries, and the link handed alongside it is the same keyless one every other
nested capability already uses — so a frame that holds the runtime necessarily
holds a route that cannot sign. The root arm is unreachable here: this route
always names an authenticated current frame, and the root's never does.
-}
withNestedRecursiveHandoffRuntimeKernel ::
    ReceivedEdge scope brokerGeneration ->
    ProjectVerb verb ->
    ( RecursiveHandoffRuntime scope brokerGeneration verb ->
      BrokerLink scope brokerGeneration ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withNestedRecursiveHandoffRuntimeKernel edge verb use =
    case nestedRecursiveHandoffRuntimeKernel route binding verb of
        Left failure -> pure (Left failure)
        Right runtime -> use runtime (relayedBrokerLinkKernel edge)
  where
    route = verifiedHandoffRoute (receivedEdgeHandoff edge)
    binding = verifiedHandoffBinding (receivedEdgeHandoff edge)

{- | Publish, send, and durably receive one exact child lifecycle report. -}
withReceivedLifecycleAcknowledgementKernel ::
    ReceivedEdge scope brokerGeneration ->
    ProtectedStore ->
    ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withReceivedLifecycleAcknowledgementKernel = receiveLifecycleAcknowledgementForEdge

{- | The recovery branch first eliminates its complete sealed package. -}
withReceivedRecoveryLifecycleAcknowledgementKernel ::
    ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame childFrame
        recoveryWireDigest recoveryWireId verb ->
    ProtectedStore ->
    ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withReceivedRecoveryLifecycleAcknowledgementKernel descent store report sender =
    withReceivedRecoveryDescent descent $ \edge _recovery _verb _adapter _projection _grant ->
        receiveLifecycleAcknowledgementForEdge edge store report sender

receiveLifecycleAcknowledgementForEdge ::
    ReceivedEdge scope brokerGeneration ->
    ProtectedStore ->
    ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
receiveLifecycleAcknowledgementForEdge edge store report sender =
    case lifecycleReportBinding report of
        Right binding
            | binding == renderHandoffBinding
                (verifiedHandoffBinding (receivedEdgeHandoff edge)) -> do
                published <- publishLifecycleReportKernel recoverySigningKernel store report
                case published of
                    Left _ -> unavailable
                    Right () -> do
                        sent <- sender report
                        case sent of
                            Left reason -> pure (Left reason)
                            Right () -> do
                                received <- receiveAcknowledgement
                                case received of
                                    Left reason -> pure (Left reason)
                                    Right acknowledgement -> do
                                        recorded <- receiveLifecycleAcknowledgementKernel
                                            recoverySigningKernel store report acknowledgement
                                        case recorded of
                                            Left _ -> unavailable
                                            Right () -> pure (Right ())
        _ -> unavailable
  where
    unavailable = pure (Left lifecycleAcknowledgementUnavailable)
    receiveAcknowledgement = do
        incoming <- channelReceive (receivedEdgeChannel edge)
        pure $ case incoming of
            Right message
                | protocolMessageRequestId message == receivedEdgeRequestId edge
                , protocolMessageTag message == AcknowledgedTag ->
                    case protocolMessageFields message of
                        [acknowledgement]
                            | Right () <- verifyLifecycleAcknowledgement report acknowledgement ->
                                Right acknowledgement
                        _ -> Left lifecycleAcknowledgementUnavailable
            _ -> Left lifecycleAcknowledgementUnavailable

lifecycleAcknowledgementUnavailable :: Text
lifecycleAcknowledgementUnavailable = "lifecycle acknowledgement unavailable"

{- | Answer one frame's 'OpenFrame' with the root's own signed @Opened@.

This is the only place the opening exchange meets the fixed signer, and it is
here for the same reason the terminal receipt is: the signing admission is
hidden behind this module's importer allowlist, so the session owner holds the
join and this call site holds the signature.

The runtime is bound as the root arm before anything else runs, and its
installed verification-key digest must be the one this live broker's own route
advertises. A relayed runtime cannot reach this function at all, and a root
runtime installed against a different key is refused before the session is
read.

Signing is supplied to the owner as a continuation rather than performed around
it, which is what fixes the order. The owner renders the exact nine-field
unsigned @Opened@ from its own root-selected coordinates, this call site signs
it under the live broker against the exact request that arrived, and the owner
then records the complete signed response's digest and reads it back before the
caller may release those bytes. An exact replay re-derives the same signature
over a row that is already attached, so a second @OpenFrame@ under the same
lineage, catalog, envelope, and nonce converges instead of opening again.
-}
withRootedOpenedResponseKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootBroker scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    RequesterPath ->
    ByteString ->
    ( RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      ByteString ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withRootedOpenedResponseKernel runtime broker session store envelope request use =
    withRootArmRecursiveHandoffRuntimeKernel runtime $
        \_project _tag _store _generation _verb keyDigest ->
            if keyDigest /= brokerRouteVerificationKeyDigest (rootBrokerRoute broker)
                then pure (Left (openingFailure "the installed runtime key is not the live root broker's"))
                else withRootedFrameOpeningKernel runtime session store envelope request sign use
  where
    sign unsigned = do
        signed <- signRootedLifecycleResponseKernel recoverySigningKernel broker request unsigned
        pure
            ( either
                (Left . openingFailure . Text.pack . handoffErrorMessage)
                (Right . renderRootedLifecycleResponse)
                signed
            )

openingFailure :: Text -> Text
openingFailure detail = "rooted frame opening: " <> detail

{- | Sign one Prepared only from evidence produced after durable Unknown rows.

The session supplies every conversation coordinate, the exact request supplies
the nonce and transcript digest, and the grant supplies only the four prepared
body fields.  No caller can pass unsigned response bytes.
-}
withRootedPreparedResponseKernel ::
    RootBroker scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ByteString ->
    PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withRootedPreparedResponseKernel broker session request grant use =
    withRootedFrameSessionKernel session $ \attached _verb _lineage _catalog _frame path token _stage ordinal _predecessor ->
        if not attached
            then pure (Left (responseFailure "an unattached session cannot issue Prepared"))
            else case postOpenNonce "prepared" request of
                Left failure -> pure (Left failure)
                Right nonce ->
                    withPreparedNodeGrantKernel grant $ \node dependencies own projected ->
                        signAndUse
                            broker request
                            ( Rooted.rootedPreparedResponseUnsignedKernel
                                (childConfigDigest request) path token "prepared" (ordinal + 1)
                                nonce (TextEncoding.encodeUtf8 node)
                                (renderPreparedNodeKeysKernel dependencies)
                                own projected
                            )
                            use

{- | Sign one closed non-Prepared post-open response family.

The family selector is deliberately closed here. Coordinates come only from
the attached root session and the nonce comes only from the exact paired
request; callers supply at most the opaque semantic body.
-}
withRootedPostOpenResponseKernel ::
    RootBroker scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text ->
    ByteString ->
    ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withRootedPostOpenResponseKernel broker session family request body use =
    withRootedFrameSessionKernel session $ \attached _verb _lineage _catalog _frame path token _stage ordinal _predecessor ->
        if not attached
            then pure (Left (responseFailure "an unattached session cannot issue a post-open response"))
            else case postOpenNonce family request of
                Left failure -> pure (Left failure)
                Right nonce ->
                    signAndUse broker request (build path token ordinal nonce) use
  where
    build path token ordinal nonce = case family of
        "descend" -> opaque Rooted.rootedDescendResponseUnsignedKernel path token ordinal nonce
        "settled" -> opaque Rooted.rootedSettledResponseUnsignedKernel path token ordinal nonce
        "frame-complete" -> opaque Rooted.rootedFrameCompleteResponseUnsignedKernel path token ordinal nonce
        "receipt-recorded" ->
            Rooted.rootedReceiptRecordedResponseUnsignedKernel
                digest path token "receipt-recorded" (ordinal + 1) nonce (TextEncoding.decodeUtf8Lenient body)
        "refused" ->
            Rooted.rootedRefusedResponseUnsignedKernel
                digest path token "refused" (ordinal + 1) nonce (TextEncoding.decodeUtf8Lenient body)
        _ -> Left (responseFailure "the post-open response family is not closed")
      where
        digest = childConfigDigest request
        opaque builder p s o n = builder digest p s family (o + 1) n body

signAndUse ::
    RootBroker scope brokerGeneration verb ->
    ByteString ->
    Either Text ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
signAndUse _ _ (Left failure) _ = pure (Left (responseFailure failure))
signAndUse broker request (Right unsigned) use = do
    signed <- signRootedLifecycleResponseKernel recoverySigningKernel broker request unsigned
    case signed of
        Left failure -> pure (Left (responseFailure (Text.pack (handoffErrorMessage failure))))
        Right response -> use (renderRootedLifecycleResponse response)

postOpenNonce :: Text -> ByteString -> Either Text ByteString
postOpenNonce family request = do
    decoded <- either (Left . responseFailure) Right (Rooted.rootedLifecycleRequestFromWireKernel request)
    Rooted.withRootedLifecycleRequestKernel
        decoded
        (const outside)
        (\_ _ _ _ nonce _ -> require ["prepared", "descend", "refused"] nonce)
        (\_ _ _ _ nonce _ _ -> require ["settled", "refused"] nonce)
        (\_ _ _ _ nonce _ _ -> require ["settled", "refused"] nonce)
        (\_ _ _ _ nonce _ -> require ["frame-complete", "refused"] nonce)
        (\_ _ _ _ nonce _ -> require ["receipt-recorded", "refused"] nonce)
  where
    require expected nonce
        | family `elem` expected = Right nonce
        | otherwise = outside
    outside = Left (responseFailure "the response family does not pair with the request")

responseFailure :: Text -> Text
responseFailure detail = "rooted response: " <> detail

{- | Confirm one frame's terminal receipt in the root-owned store.

This is the only place the two terminal rooted exchanges meet the durable
transition that records them, and it is here rather than beside the session
because the Published-to-Received row is reached through the hidden recovery
signing admission this module already holds. The receipt owner therefore checks
the join and derives the digests, and this call site supplies the two durable
steps as the continuations it asks for.

The order is fixed by that owner: the exact canonical report the signed
@FrameComplete@ carries is published and read back first, and only the digest
of those complete signed bytes can be the report a @ReceiptConfirm@ names. The
acknowledgement is the canonical one rendered from the report itself rather
than anything a requester supplied, so the compare-and-swap advances Published
to Received for exactly the report that was published.

Both durable steps are already convergent, so an exact retry of either exchange
re-derives the same digest over a row that is already where it belongs. A child
therefore persists no receipt state and reopens none.
-}
withRootedTerminalReceiptKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString ->
    (Text -> IO (Either Text ())) ->
    IO (Either Text ())
withRootedTerminalReceiptKernel runtime session store close signedComplete confirm signedReceipt use =
    withRootedTerminalReportKernel runtime session close signedComplete publish $ \report completion ->
        withRootedReceiptConfirmationKernel
            runtime session confirm completion signedReceipt (advance report) use
  where
    publish report = do
        published <- publishLifecycleReportKernel recoverySigningKernel store report
        pure (durable "publish" published)
    advance report = case renderLifecycleAcknowledgement report of
        Left failure -> pure (durable "acknowledge" (Left failure))
        Right acknowledgement -> do
            received <-
                receiveLifecycleAcknowledgementKernel
                    recoverySigningKernel store report acknowledgement
            pure (durable "receive" received)
    durable stage =
        either
            (\failure -> Left ("rooted terminal receipt: cannot " <> stage <> " the terminal report: " <> Text.pack (handoffErrorMessage failure)))
            Right

{- | Ask this frame's route to sign one activation manifest.

The closed activation policy remains the target authorization. For a relayed
link, the private request envelope additionally originates the authenticated
current-frame path so every serving hop can prove the request came through an
admitted child before forwarding it.
-}
linkSignActivation ::
    BrokerLink scope brokerGeneration ->
    ActivationManifest ->
    IO (Either RelayError ActivationGrant)
linkSignActivation link = linkSignActivationRaw link []

{- | Send one exact rooted lifecycle request through this frame's sealed route.

Only the independently installed key can turn the returned signed bytes into
the descriptive response value. An outer refusal remains a relay failure; a
signed rooted @Refused@ remains an ordinary verified response.
-}
receiveRootedLifecycleResponseThroughLink ::
    ProjectVerificationKey ->
    BrokerLink scope brokerGeneration ->
    ByteString ->
    IO (Either RelayError RootedLifecycleResponse)
receiveRootedLifecycleResponseThroughLink key link exactRequest =
    case rootedRequestPath exactRequest of
        Left failure -> pure (Left failure)
        Right _
            | TextEncoding.encodeUtf8 (verificationKeyDigest key) /= linkKeyDigest link ->
                pure
                    ( requesterMismatch
                        "the installed rooted lifecycle key differs from the admitted route"
                    )
            | otherwise -> do
                routed <- linkRootedLifecycleRaw link [] exactRequest
                case routed of
                    Left failure -> pure (Left failure)
                    Right (Left (code, detail)) ->
                        pure
                            ( Left
                                ( RelayRefusedByPeer
                                    (TextEncoding.decodeUtf8Lenient code)
                                    (TextEncoding.decodeUtf8Lenient detail)
                                )
                            )
                    Right (Right signedResponse) ->
                        case withVerifiedRootedLifecycleResponse
                            key
                            exactRequest
                            signedResponse
                            id of
                            Left failure -> do
                                let relayFailure = RelayHandoffFailure failure
                                linkRejectResponse link relayFailure
                                pure (Left relayFailure)
                            Right response -> pure (Right response)

rootedSigningDomain, rootedSigningVersion :: ByteString
rootedSigningDomain = "hostbootstrap/rooted-offer-signing"
rootedSigningVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]

rootedSigningKindName :: HandoffPayloadKind -> ByteString
rootedSigningKindName NarrowedProjectConfig = "config"
rootedSigningKindName RecoveryAdapterWire = "recovery-package"

renderRootedSigningHeader :: HandoffOffer scope brokerGeneration -> ByteString
renderRootedSigningHeader offer =
    frameWire rootedSigningDomain
        <> frameWire rootedSigningVersion
        <> frameWire (rootedSigningKindName (handoffPayloadKind (handoffOfferBinding offer)))

rootedSigningKind :: ByteString -> Either RelayError (Maybe HandoffPayloadKind)
rootedSigningKind raw = do
    (domain, afterDomain) <- fromHandoff (takeHandoffFrame raw)
    if domain /= rootedSigningDomain
        then Right Nothing
        else do
            (version, afterVersion) <- fromHandoff (takeHandoffFrame afterDomain)
            (kind, trailing) <- fromHandoff (takeHandoffFrame afterVersion)
            if version /= rootedSigningVersion || not (ByteString.null trailing)
                then requesterMismatch "the rooted signing header is not canonical"
                else case kind of
                    "config" -> Right (Just NarrowedProjectConfig)
                    "recovery-package" -> Right (Just RecoveryAdapterWire)
                    _ -> requesterMismatch "the rooted signing kind is not closed"

{- | Route rooted signing for the exact offer already held by this frame. -}
rootedBindingThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    IO (Either RelayError ByteString)
rootedBindingThroughLink link offer =
    case requireOwnFrame link "rooted offer parent frame" parentFrame of
        Left failure -> pure (Left failure)
        Right () -> linkRootedBindingRaw link [] offer
  where
    parentFrame = handoffParentFrame (handoffOfferBinding offer)

rootSignRootedBinding ::
    RootBroker scope brokerGeneration verb ->
    HandoffOffer scope brokerGeneration ->
    IO (Either RelayError ByteString)
rootSignRootedBinding broker offer = case handoffPayloadKind (handoffOfferBinding offer) of
    NarrowedProjectConfig ->
        renderSigned
            (signRootedPayloadBindingKernel recoverySigningKernel broker offer payload)
    RecoveryAdapterWire -> case Recovery.recoveryChildPackageFromWireKernel payload of
        Left detail ->
            pure
                ( Left
                    ( RelayHandoffFailure
                        (HandoffBindingMismatch ("recovery child package " <> detail))
                    )
                )
        Right package ->
            renderSigned
                (signRecoveryChildPackageBindingKernel recoverySigningKernel broker offer package)
  where
    (payload, _, _) = handoffOfferFrames offer
    renderSigned action = do
        signed <- action
        pure (either (Left . RelayHandoffFailure) (Right . renderRootedPayloadBinding) signed)

relayRootedBinding ::
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    HandoffOffer scope brokerGeneration ->
    IO (Either RelayError ByteString)
relayRootedBinding channel request path offer =
    case renderRequesterEnvelope path (renderRootedSigningHeader offer) of
        Left failure -> pure (Left failure)
        Right enveloped -> do
            sent <- transmit channel RecoveryRequestTag request [enveloped, offerWireOf offer]
            case sent of
                Left failure -> pure (Left failure)
                Right () -> do
                    answer <- await channel request RecoveryResponseTag
                    case answer of
                        Left failure -> pure (Left failure)
                        Right [rooted] -> pure (Right rooted)
                        Right fields ->
                            refuse channel request
                                (RelayMalformedMessage RecoveryResponseTag (length fields))

{- | Route the exact first acknowledgement stage and consume its closed result.

The two continuations mirror the root kernel's pending/already-Adopted branches.
They receive only the response's stored acknowledgement, after it has been
matched byte-for-byte to the canonical request.
-}
prepareLifecycleAcknowledgementThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ByteString ->
    ByteString ->
    (ByteString -> IO (Either RelayError ())) ->
    (ByteString -> IO (Either RelayError ())) ->
    IO (Either RelayError ())
prepareLifecycleAcknowledgementThroughLink
    link offer challenge report acknowledgement pending alreadyAdopted =
        routeLifecycleAcknowledgementThroughLink
            link offer challenge report acknowledgement lifecyclePrepareStage
            lifecyclePending (pending acknowledgement)
            lifecycleAlreadyAdopted (alreadyAdopted acknowledgement)

{- | Route the exact second acknowledgement stage and consume fresh/replay.

Neither branch returns a disposition value. The caller can run its fixed local
continuation only in the fresh branch and make replay acknowledgement-only.
-}
adoptLifecycleAcknowledgementThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ByteString ->
    ByteString ->
    IO (Either RelayError ()) ->
    IO (Either RelayError ()) ->
    IO (Either RelayError ())
adoptLifecycleAcknowledgementThroughLink
    link offer challenge report acknowledgement fresh replay =
        routeLifecycleAcknowledgementThroughLink
            link offer challenge report acknowledgement lifecycleAdoptStage
            lifecycleFresh fresh lifecycleReplay replay

routeLifecycleAcknowledgementThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString ->
    IO (Either RelayError ()) ->
    ByteString ->
    IO (Either RelayError ()) ->
    IO (Either RelayError ())
routeLifecycleAcknowledgementThroughLink
    link offer challenge report acknowledgement stage firstDisposition first secondDisposition second =
        case requireOwnFrame link "lifecycle parent frame" parentFrame
            >> renderLifecycleAcknowledgementRequest stage offer challenge report acknowledgement of
            Left failure -> pure (Left failure)
            Right request ->
                linkLifecycleAcknowledgementRaw link [] request $ \response ->
                    withLifecycleAcknowledgementResponse
                        stage report acknowledgement response
                        firstDisposition first secondDisposition second
  where
    parentFrame = handoffParentFrame (handoffOfferBinding offer)

{- | Ask this frame's route to the root to authenticate an exact recovery wire.

At the root this revalidates the canonical binding against the live broker,
checks the plan-derived 'RecoveryAdmission', and signs under the recovery-only
domain. At every nested frame the exact two request fields travel upward and
the one signature field travels back.
-}
signRecoveryThroughLink ::
    BrokerLink scope brokerGeneration ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString ->
    IO
        ( Either
            RelayError
            ( RecoveryWireGrant
                scope
                brokerGeneration
                verb
                planDigest
                parentFrame
                childFrame
                recoveryWireDigest
            )
        )
signRecoveryThroughLink link binding wire = case recoveryRequestFields binding wire of
    Left failure -> pure (Left (RelayHandoffFailure failure))
    Right fields@[bindingBytes, _] -> case recoveryParentFromWire bindingBytes of
        Left failure -> pure (Left failure)
        Right parentFrame -> case requireOwnFrame link "recovery parent frame" parentFrame of
            Left failure -> pure (Left failure)
            Right () -> do
                answered <- linkRecoveryFieldsRaw link [] fields
                case answered of
                    Left failure -> pure (Left failure)
                    Right response -> case recoveryResponseFromFields binding response of
                        Left failure -> do
                            let relayFailure = RelayHandoffFailure failure
                            linkRejectResponse link relayFailure
                            pure (Left relayFailure)
                        Right grant -> pure (Right grant)
    Right fields -> pure (Left (RelayMalformedMessage RecoveryRequestTag (length fields)))

{- | Build and sign one recovery projection through an authenticated route.

The rank-2 continuation keeps the route-derived wire-digest identity local
while giving a nested frame both values it needs for immediate verification or
installation. The route supplies the exact root project/store/generation and
the closed verb evidence must agree with its authenticated verb.
-}
withSignedRecoveryThroughLink ::
    ProjectVerb verb ->
    BrokerLink scope brokerGeneration ->
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
      RecoveryWireGrant
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
      IO result
    ) ->
    IO (Either RelayError result)
withSignedRecoveryThroughLink verb link input wire use =
    case mkRecoveryProjectionBindingFromRoute
        verb
        (linkRoute link)
        input
        wire
        ( \binding -> do
            signed <- signRecoveryThroughLink link binding wire
            case signed of
                Left failure -> pure (Left failure)
                Right grant -> Right <$> use binding grant
        ) of
        Left failure -> pure (Left (RelayHandoffFailure failure))
        Right action -> action

recoveryParentFromWire :: ByteString -> Either RelayError Text
recoveryParentFromWire raw =
    withRecoveryInputFromWire raw requestedRecoveryParentFrame

requireOwnFrame ::
    BrokerLink scope brokerGeneration ->
    Text ->
    Text ->
    Either RelayError ()
requireOwnFrame link label requested = case brokerRouteCurrentFrame (linkRoute link) of
    Nothing -> Right ()
    Just current
        | requested == current -> Right ()
        | otherwise -> requesterMismatch ("the " <> label <> " does not name this authenticated frame")

{- | Relay one activation-signing request outward and adopt the answer.

What travels is the manifest's canonical bytes, not a signature request the
intermediate frame composed: an intermediate cannot alter what is signed without
altering the bytes it forwards, and the root rebuilds the manifest from those
bytes and validates it before signing.
-}
relaySignActivation ::
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    ActivationManifest ->
    IO (Either RelayError ActivationGrant)
relaySignActivation channel request path manifest =
    case renderRequesterEnvelope path (renderActivationManifest manifest) of
        Left failure -> pure (Left failure)
        Right enveloped -> do
            sent <-
                transmit
                    channel
                    ActivationSignRequestTag
                    request
                    [enveloped]
            case sent of
                Left failure -> pure (Left failure)
                Right () -> do
                    answer <- await channel request ActivationSignResponseTag
                    case answer of
                        Left failure -> pure (Left failure)
                        Right fields -> case adoptActivationGrant fields of
                            Left failure -> refuse channel request failure
                            Right grant -> pure (Right grant)

adoptActivationGrant :: [ByteString] -> Either RelayError ActivationGrant
adoptActivationGrant [signature] = Right (adoptRelayedActivationGrant signature)
adoptActivationGrant fields =
    Left (RelayMalformedMessage ActivationSignResponseTag (length fields))

relayOpen ::
    BrokerRoute scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    HandoffBindingInput ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
relayOpen route channel request path input = case requireConfigOpen input of
    Left failure -> pure (Left failure)
    Right () -> relayOpenPayload route channel request path input (renderHandoffBindingInput input)

relayRecoverableOpen ::
    BrokerRoute scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    HandoffBindingInput ->
    ByteString ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
relayRecoverableOpen route channel request path input adapter =
    relayOpenPayload route channel request path input (renderRecoverableOpen input adapter)

relayOpenPayload ::
    BrokerRoute scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    HandoffBindingInput ->
    ByteString ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
relayOpenPayload route channel request path input payload =
    case renderRequesterEnvelope path payload of
        Left failure -> pure (Left failure)
        Right enveloped -> do
            sent <- transmit channel OfferRequestTag request [enveloped]
            case sent of
                Left failure -> pure (Left failure)
                Right () -> do
                    answer <- await channel request OfferResponseTag
                    case answer of
                        Left failure -> pure (Left failure)
                        Right fields -> case adoptOpenedEdge route input fields of
                            Left failure -> refuse channel request failure
                            Right opened -> pure (Right opened)

recoverableOpenDomain, recoverableOpenVersion :: ByteString
recoverableOpenDomain = "hostbootstrap/recoverable-open"
recoverableOpenVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]

renderRecoverableOpen :: HandoffBindingInput -> ByteString -> ByteString
renderRecoverableOpen input adapter =
    frameWire recoverableOpenDomain
        <> frameWire recoverableOpenVersion
        <> frameWire (renderHandoffBindingInput input)
        <> frameWire adapter

parseRecoverableOpen :: ByteString -> Either RelayError (Maybe (HandoffBindingInput, ByteString))
parseRecoverableOpen raw = do
    (domain, afterDomain) <- fromHandoff (takeHandoffFrame raw)
    if domain /= recoverableOpenDomain
        then Right Nothing
        else do
            (version, afterVersion) <- fromHandoff (takeHandoffFrame afterDomain)
            if version /= recoverableOpenVersion
                then requesterMismatch "the recoverable-open request has the wrong version"
                else do
                    (inputBytes, afterInput) <- fromHandoff (takeHandoffFrame afterVersion)
                    (adapter, trailing) <- fromHandoff (takeHandoffFrame afterInput)
                    input <- fromHandoff (handoffBindingInputFromWire inputBytes)
                    if not (ByteString.null trailing)
                        || requestedPayloadKind input /= RecoveryAdapterWire
                        || requestedChildConfigDigest input /= childConfigDigest adapter
                        || ByteString.null adapter
                        || renderHandoffBindingInput input /= inputBytes
                        || renderRecoverableOpen input adapter /= raw
                        then requesterMismatch "the recoverable-open request is not canonical"
                        else Right (Just (input, adapter))

adoptOpenedEdge ::
    BrokerRoute scope brokerGeneration ->
    HandoffBindingInput ->
    [ByteString] ->
    Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken)
adoptOpenedEdge route input [payload] = do
    (bindingBytes, tokenFrame) <- splitPair payload
    relay <- fromHandoff (brokerRelayFromRouteWire route (Just input) bindingBytes)
    token <- fromHandoff (handoffTokenFromBytes tokenFrame)
    pure (relay, token)
adoptOpenedEdge _ _ fields = Left (RelayMalformedMessage OfferResponseTag (length fields))

{- | Ask this frame's route to the root to open one edge.

At the root this registers it durably; anywhere else it is a request that walks
outward. The two are the same operation from the caller's side, which is what
makes one descent implementation serve every frame.
-}
openEdgeThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffBindingInput ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
openEdgeThroughLink link input =
    case requireConfigOpen input >> requireOwnFrame link "handoff parent frame" (requestedParentFrame input) of
        Left failure -> pure (Left failure)
        Right () -> linkOpenRaw link [] input

requireConfigOpen :: HandoffBindingInput -> Either RelayError ()
requireConfigOpen input
    | requestedPayloadKind input == NarrowedProjectConfig = Right ()
    | otherwise = requesterMismatch "ordinary edge opening requires narrowed-project-config"

{- | Ask this frame's route to the root to open one recoverable reverse edge.

The payload is the complete canonical recovery child package the durable
prepared descent already owns, never an adapter this frame composed. At the
root the recoverable opener consults its durable open map first, so a repeated
attempt recovers the exact binding and token it minted before; anywhere else
the same two terms travel outward unchanged.
-}
openRecoverableEdgeThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffBindingInput ->
    ByteString ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
openRecoverableEdgeThroughLink link input package =
    case requireRecoveryOpen input >> requireOwnFrame link "recovery parent frame" (requestedParentFrame input) of
        Left failure -> pure (Left failure)
        Right () -> linkRecoverableOpenRaw link [] input package

requireRecoveryOpen :: HandoffBindingInput -> Either RelayError ()
requireRecoveryOpen input
    | requestedPayloadKind input == RecoveryAdapterWire = Right ()
    | otherwise = requesterMismatch "reverse-descent opening requires recovery-adapter-wire"

{- | Ask this frame's route to the root to authenticate one offer against one
challenge.

Only the root signs. Everywhere else this is a message with a reply, and the
reply's signature was produced by a key this frame never had.
-}
grantThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either RelayError (HandoffGrant scope brokerGeneration))
grantThroughLink link offer challenge =
    case requireOwnFrame link "handoff parent frame" parentFrame of
        Left failure -> pure (Left failure)
        Right () -> linkGrantRaw link [] offer challenge
  where
    parentFrame = handoffParentFrame (handoffOfferBinding offer)

relayGrant ::
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either RelayError (HandoffGrant scope brokerGeneration))
relayGrant channel request path offer challenge =
    case renderRequesterEnvelope path (offerWireOf offer) of
        Left failure -> pure (Left failure)
        Right enveloped -> do
            sent <-
                transmit
                    channel
                    GrantRequestTag
                    request
                    [enveloped, challengeBytes challenge]
            case sent of
                Left failure -> pure (Left failure)
                Right () -> do
                    answer <- await channel request GrantResponseTag
                    case answer of
                        Left failure -> pure (Left failure)
                        Right [signature] -> pure (Right (handoffGrantFromSignature signature))
                        Right fields -> refuse channel request (RelayMalformedMessage GrantResponseTag (length fields))

{- | Validate and answer one recovery request at the root.

The binding is decoded twice for two deliberately different jobs. The small
relay decoder extracts only the plan-owned coordinates for 'RecoveryAdmission';
'recoveryRequestFromFields' then authenticates every canonical coordinate
against the live broker and exact wire before the admission callback can run.
Only an admitted request reaches the recovery signer.
-}
rootSignRecovery ::
    RootBroker scope brokerGeneration verb ->
    RecoveryAdmission ->
    [ByteString] ->
    IO (Either RelayError [ByteString])
rootSignRecovery broker admits fields@[bindingBytes, _] =
    case withRecoveryInputFromWire bindingBytes $ \input ->
        recoveryRequestFromFields broker input fields $ \binding wire -> do
            signed <-
                signRecoveryWireKernel
                    recoverySigningKernel
                    broker
                    (admits input)
                    binding
                    wire
            pure $ case signed of
                Left failure -> Left (RelayHandoffFailure failure)
                Right (Left reason) -> Left (RelayRecoveryNotPlanned reason)
                Right (Right grant) -> Right (recoveryResponseFields grant) of
        Left failure -> pure (Left failure)
        Right (Left failure) -> pure (Left (RelayHandoffFailure failure))
        Right (Right answer) -> answer
rootSignRecovery _ _ fields =
    pure (Left (RelayMalformedMessage RecoveryRequestTag (length fields)))

-- | Forward the protocol's exact recovery pair over a relayed link.
relayRecoveryFields ::
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    [ByteString] ->
    IO (Either RelayError [ByteString])
relayRecoveryFields channel request path [bindingBytes, wire] =
    case renderRequesterEnvelope path bindingBytes of
        Left failure -> pure (Left failure)
        Right enveloped -> do
            sent <- transmit channel RecoveryRequestTag request [enveloped, wire]
            case sent of
                Left failure -> pure (Left failure)
                Right () -> await channel request RecoveryResponseTag
relayRecoveryFields _ _ _ fields =
    pure (Left (RelayMalformedMessage RecoveryRequestTag (length fields)))

-- ---------------------------------------------------------------------------
-- Routed lifecycle acknowledgement

lifecycleAcknowledgementRequestDomain, lifecycleAcknowledgementResponseDomain :: ByteString
lifecycleAcknowledgementRequestDomain = "hostbootstrap/lifecycle-ack-request"
lifecycleAcknowledgementResponseDomain = "hostbootstrap/lifecycle-ack-response"

lifecycleAcknowledgementVersion, lifecyclePrepareStage, lifecycleAdoptStage :: ByteString
lifecycleAcknowledgementVersion = ByteString.pack [0, 0, 0, 0, 0, 0, 0, 1]
lifecyclePrepareStage = "prepare"
lifecycleAdoptStage = "adopt"

lifecyclePending, lifecycleAlreadyAdopted, lifecycleFresh, lifecycleReplay :: ByteString
lifecyclePending = "pending"
lifecycleAlreadyAdopted = "already-adopted"
lifecycleFresh = "fresh"
lifecycleReplay = "replay"

renderLifecycleAcknowledgementRequest ::
    ByteString ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ByteString ->
    ByteString ->
    Either RelayError ByteString
renderLifecycleAcknowledgementRequest stage offer challenge report acknowledgement = do
    requireLifecycleStage stage
    binding <- lifecycleReportBinding report
    requireLifecycleRelay
        (binding == renderHandoffBinding (handoffOfferBinding offer))
        "the lifecycle report does not name the exact offered edge"
    fromHandoff (verifyLifecycleAcknowledgement report acknowledgement)
    boundedLifecycleField LifecycleAckRequestTag wire
    pure wire
  where
    wire =
        ByteString.concat
            ( map
                frameWire
                [ lifecycleAcknowledgementRequestDomain
                , lifecycleAcknowledgementVersion
                , stage
                , offerWireOf offer
                , challengeBytes challenge
                , report
                , acknowledgement
                ]
            )

withLifecycleAcknowledgementRequest ::
    BrokerRoute scope brokerGeneration ->
    ByteString ->
    ( HandoffOffer scope brokerGeneration ->
      HandoffChallenge ->
      ByteString ->
      ByteString ->
      IO (Either RelayError ())
    ) ->
    ( HandoffOffer scope brokerGeneration ->
      HandoffChallenge ->
      ByteString ->
      ByteString ->
      IO (Either RelayError ())
    ) ->
    IO (Either RelayError ())
withLifecycleAcknowledgementRequest route raw prepare adopt =
    case parse of
        Left failure -> pure (Left failure)
        Right (stage, offer, challenge, report, acknowledgement)
            | stage == lifecyclePrepareStage -> prepare offer challenge report acknowledgement
            | otherwise -> adopt offer challenge report acknowledgement
  where
    parse = do
        boundedLifecycleField LifecycleAckRequestTag raw
        fields <- exactLifecycleFrames 7 raw
        case fields of
            [domain, version, stage, offerWire, challengeWire, report, acknowledgement] -> do
                requireLifecycleRelay
                    ( domain == lifecycleAcknowledgementRequestDomain
                        && version == lifecycleAcknowledgementVersion
                    )
                    "the lifecycle request domain or version differs"
                requireLifecycleStage stage
                (offer, challenge) <- adoptRelayedRequest route offerWire challengeWire
                binding <- lifecycleReportBinding report
                requireLifecycleRelay
                    (binding == renderHandoffBinding (handoffOfferBinding offer))
                    "the lifecycle request report names another edge"
                fromHandoff (verifyLifecycleAcknowledgement report acknowledgement)
                canonical <-
                    renderLifecycleAcknowledgementRequest
                        stage offer challenge report acknowledgement
                requireLifecycleRelay
                    (canonical == raw)
                    "the lifecycle request is not canonical"
                pure (stage, offer, challenge, report, acknowledgement)
            _ -> lifecycleRelayMismatch "the lifecycle request field count differs"

renderLifecycleAcknowledgementResponse ::
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString ->
    Either RelayError ByteString
renderLifecycleAcknowledgementResponse stage disposition report acknowledgement = do
    requireLifecycleDisposition stage disposition
    fromHandoff (verifyLifecycleAcknowledgement report acknowledgement)
    boundedLifecycleField LifecycleAckResponseTag wire
    pure wire
  where
    wire =
        ByteString.concat
            ( map
                frameWire
                [ lifecycleAcknowledgementResponseDomain
                , lifecycleAcknowledgementVersion
                , stage
                , disposition
                , acknowledgement
                ]
            )

withLifecycleAcknowledgementResponse ::
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString ->
    IO (Either RelayError ()) ->
    ByteString ->
    IO (Either RelayError ()) ->
    IO (Either RelayError ())
withLifecycleAcknowledgementResponse
    expectedStage report expectedAcknowledgement raw firstDisposition first secondDisposition second =
        case parse of
            Left failure -> pure (Left failure)
            Right disposition
                | disposition == firstDisposition -> first
                | otherwise -> second
      where
        parse = do
            boundedLifecycleField LifecycleAckResponseTag raw
            fields <- exactLifecycleFrames 5 raw
            case fields of
                [domain, version, stage, disposition, acknowledgement] -> do
                    requireLifecycleRelay
                        ( domain == lifecycleAcknowledgementResponseDomain
                            && version == lifecycleAcknowledgementVersion
                            && stage == expectedStage
                            && acknowledgement == expectedAcknowledgement
                            && disposition `elem` [firstDisposition, secondDisposition]
                        )
                        "the lifecycle response differs from the exact request"
                    canonical <-
                        renderLifecycleAcknowledgementResponse
                            stage disposition report acknowledgement
                    requireLifecycleRelay
                        (canonical == raw)
                        "the lifecycle response is not canonical"
                    pure disposition
                _ -> lifecycleRelayMismatch "the lifecycle response field count differs"

rootLifecycleAcknowledgement ::
    RootBroker scope brokerGeneration verb ->
    BrokerRoute scope brokerGeneration ->
    ByteString ->
    (ByteString -> IO (Either RelayError ())) ->
    IO (Either RelayError ())
rootLifecycleAcknowledgement broker route raw respond =
    withLifecycleAcknowledgementRequest route raw prepare adopt
  where
    prepare offer challenge report acknowledgement =
        flattenLifecycleKernel
            ( prepareLifecycleAcknowledgementKernel
                recoverySigningKernel broker offer challenge report acknowledgement
                (respondWith lifecyclePrepareStage lifecyclePending report)
                (respondWith lifecyclePrepareStage lifecycleAlreadyAdopted report)
            )
    adopt offer challenge report acknowledgement =
        flattenLifecycleKernel
            ( adoptLifecycleAcknowledgementKernel
                recoverySigningKernel broker offer challenge report acknowledgement
                (respondWith lifecycleAdoptStage lifecycleFresh report acknowledgement)
                (respondWith lifecycleAdoptStage lifecycleReplay report acknowledgement)
            )
    respondWith stage disposition report acknowledgement =
        case renderLifecycleAcknowledgementResponse stage disposition report acknowledgement of
            Left failure -> pure (Left failure)
            Right response -> respond response

flattenLifecycleKernel ::
    IO (Either HandoffError (Either RelayError ())) ->
    IO (Either RelayError ())
flattenLifecycleKernel action = do
    result <- action
    pure (either (Left . RelayHandoffFailure) id result)

relayLifecycleAcknowledgement ::
    BrokerRoute scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    ByteString ->
    (ByteString -> IO (Either RelayError ())) ->
    IO (Either RelayError ())
relayLifecycleAcknowledgement route channel request path raw respond =
    withLifecycleAcknowledgementRequest route raw
        (relay lifecyclePrepareStage lifecyclePending lifecycleAlreadyAdopted)
        (relay lifecycleAdoptStage lifecycleFresh lifecycleReplay)
  where
    relay stage firstDisposition secondDisposition _ _ report acknowledgement =
        case renderRequesterEnvelope path raw of
            Left failure -> pure (Left failure)
            Right enveloped -> do
                sent <- transmit channel LifecycleAckRequestTag request [enveloped]
                case sent of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        answer <- await channel request LifecycleAckResponseTag
                        case answer of
                            Left failure -> pure (Left failure)
                            Right [response] ->
                                withLifecycleAcknowledgementResponse
                                    stage report acknowledgement response
                                    firstDisposition (respond response)
                                    secondDisposition (respond response)
                            Right fields ->
                                pure
                                    ( Left
                                        (RelayMalformedMessage LifecycleAckResponseTag (length fields))
                                    )

{- | Carry one rooted request outward without interpreting lifecycle fields.

The private envelope is reconstructed at each hop while the exact inner bytes
are left untouched. A response is decoded only far enough to prove that it is
the structurally paired closed response and that its echoed path still contains
this authenticated suffix. Signature verification is reserved for the
originating typed operation above.
-}
relayRootedLifecycle ::
    HandoffChannel ->
    Word64 ->
    RequesterPath ->
    ByteString ->
    IO (Either RelayError (Either (ByteString, ByteString) ByteString))
relayRootedLifecycle channel request path exactRequest =
    case rootedRequestPath exactRequest
        >>= requireRootedRequesterPath False path of
        Left failure -> pure (Left failure)
        Right () -> case renderRequesterEnvelope path exactRequest of
            Left failure -> pure (Left failure)
            Right enveloped -> do
                sent <- transmit channel RootedLifecycleRequestTag request [enveloped]
                case sent of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        received <- receive channel
                        case received of
                            Left failure -> pure (Left failure)
                            Right message
                                | protocolMessageRequestId message /= request ->
                                    refuse
                                        channel
                                        request
                                        ( RelayProtocolFailure
                                            ( ProtocolRequestMismatch
                                                request
                                                (protocolMessageRequestId message)
                                            )
                                        )
                                | protocolMessageTag message == RootedLifecycleResponseTag ->
                                    case protocolMessageFields message of
                                        [signedResponse] ->
                                            case rootedResponsePath exactRequest signedResponse
                                                >>= requireRootedRequesterPath False path . Just of
                                                Left failure -> refuse channel request failure
                                                Right () -> pure (Right (Right signedResponse))
                                        fields ->
                                            refuse
                                                channel
                                                request
                                                ( RelayMalformedMessage
                                                    RootedLifecycleResponseTag
                                                    (length fields)
                                                )
                                | protocolMessageTag message == RefusedTag ->
                                    case protocolMessageFields message of
                                        [code, detail] -> pure (Right (Left (code, detail)))
                                        fields ->
                                            refuse
                                                channel
                                                request
                                                (RelayMalformedMessage RefusedTag (length fields))
                                | otherwise ->
                                    refuse
                                        channel
                                        request
                                        (RelayUnexpectedMessage (protocolMessageTag message))

exactLifecycleFrames :: Int -> ByteString -> Either RelayError [ByteString]
exactLifecycleFrames count = go count []
  where
    go 0 frames trailing
        | ByteString.null trailing = Right (reverse frames)
        | otherwise = lifecycleRelayMismatch "the lifecycle envelope has trailing bytes"
    go remaining frames wire = do
        (field, trailing) <- fromHandoff (takeHandoffFrame wire)
        go (remaining - 1) (field : frames) trailing

boundedLifecycleField :: ProtocolTag -> ByteString -> Either RelayError ()
boundedLifecycleField tag raw =
    either (Left . RelayProtocolFailure) (const (Right ())) (protocolMessage tag 1 [raw])

lifecycleReportBinding :: ByteString -> Either RelayError ByteString
lifecycleReportBinding report =
    fromHandoff (eliminateLifecycleReport report binding binding binding binding binding binding)
  where
    binding value _ _ _ _ = value

requireLifecycleStage :: ByteString -> Either RelayError ()
requireLifecycleStage stage =
    requireLifecycleRelay
        (stage == lifecyclePrepareStage || stage == lifecycleAdoptStage)
        "the lifecycle request stage is unknown"

requireLifecycleDisposition :: ByteString -> ByteString -> Either RelayError ()
requireLifecycleDisposition stage disposition =
    requireLifecycleRelay
        ( (stage == lifecyclePrepareStage && disposition `elem` [lifecyclePending, lifecycleAlreadyAdopted])
            || (stage == lifecycleAdoptStage && disposition `elem` [lifecycleFresh, lifecycleReplay])
        )
        "the lifecycle response disposition is illegal for its stage"

requireLifecycleRelay :: Bool -> Text -> Either RelayError ()
requireLifecycleRelay True _ = Right ()
requireLifecycleRelay False detail = lifecycleRelayMismatch detail

lifecycleRelayMismatch :: Text -> Either RelayError value
lifecycleRelayMismatch = Left . RelayHandoffFailure . HandoffBindingMismatch

{- | Extract the three plan-owned coordinates from a canonical recovery
binding without granting them authority.

The returned input is consumed only by the root codec above, which rechecks
project, scope, all three coordinates, and wire digest before admission or
signing. Keeping this decoder continuation-scoped prevents its phantom indices
from escaping as if parsing bytes had authenticated them.
-}
withRecoveryInputFromWire ::
    ByteString ->
    ( forall planDigest parentFrame childFrame.
      RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
      result
    ) ->
    Either RelayError result
withRecoveryInputFromWire raw use = do
    (_, afterProject) <- recoveryTextFrame "installed project" raw
    (_, afterScope) <- recoveryTextFrame "scope" afterProject
    (_, afterStore) <- recoveryTextFrame "protected store identity" afterScope
    (_, afterGeneration) <- fromHandoff (takeHandoffFrame afterStore)
    (_, afterVerb) <- recoveryTextFrame "verb" afterGeneration
    (planDigest, afterPlan) <- recoveryTextFrame "plan digest" afterVerb
    (parentFrame, afterParent) <- recoveryTextFrame "parent frame" afterPlan
    (childFrame, afterChild) <- recoveryTextFrame "child frame" afterParent
    (_, trailing) <- recoveryTextFrame "wire digest" afterChild
    if ByteString.null trailing
        then
            fromHandoff
                ( withRecoveryProjectionBindingInput
                    planDigest
                    parentFrame
                    childFrame
                    use
                )
        else
            Left
                ( RelayHandoffFailure
                    (HandoffWireTrailingBytes (ByteString.length trailing))
                )

recoveryTextFrame :: Text -> ByteString -> Either RelayError (Text, ByteString)
recoveryTextFrame label raw = do
    (value, rest) <- fromHandoff (takeHandoffFrame raw)
    case TextEncoding.decodeUtf8' value of
        Left _ ->
            Left
                ( RelayHandoffFailure
                    (HandoffBindingMismatch ("the recovery " <> label <> " is not valid UTF-8"))
                )
        Right decoded -> Right (decoded, rest)

-- ---------------------------------------------------------------------------
-- Sealed requester provenance

requesterEnvelopeDomain :: ByteString
requesterEnvelopeDomain = "hostbootstrap-relay-requester-path-v1"

maxRequesterPathDepth :: Int
maxRequesterPathDepth = 256

maxRequesterPathComponentBytes :: Int
maxRequesterPathComponentBytes = 4096

{- | Frame one private requester path inside an existing protocol field.

The outer protocol tag field count is unchanged. The domain frame prevents an
old bare binding/manifest from being treated as provenance, the nested path
frame preserves arbitrary frame-name boundaries, and the final frame carries
the request material the root operation already validates.
-}
renderRequesterEnvelope :: RequesterPath -> ByteString -> Either RelayError ByteString
renderRequesterEnvelope path payload
    | null path = requesterMismatch "the relay requester path is empty"
    | length path > maxRequesterPathDepth =
        requesterMismatch "the relay requester path exceeds the protocol depth limit"
    | any Text.null path = requesterMismatch "the relay requester path contains an empty frame"
    | any ((> maxRequesterPathComponentBytes) . ByteString.length . TextEncoding.encodeUtf8) path =
        requesterMismatch "the relay requester path contains an oversized frame"
    | otherwise =
        Right
            ( frameWire requesterEnvelopeDomain
                <> frameWire
                    ( ByteString.concat
                        (map (frameWire . TextEncoding.encodeUtf8) path)
                    )
                <> frameWire payload
            )

parseRequesterEnvelope :: ByteString -> Either RelayError (RequesterPath, ByteString)
parseRequesterEnvelope raw = do
    (domain, afterDomain) <- fromHandoff (takeHandoffFrame raw)
    if domain /= requesterEnvelopeDomain
        then requesterMismatch "the relay requester envelope has the wrong domain"
        else do
            (pathWire, afterPath) <- fromHandoff (takeHandoffFrame afterDomain)
            (payload, trailing) <- fromHandoff (takeHandoffFrame afterPath)
            if ByteString.null trailing
                then do
                    path <- parseRequesterPath pathWire
                    pure (path, payload)
                else
                    Left
                        ( RelayHandoffFailure
                            (HandoffWireTrailingBytes (ByteString.length trailing))
                        )

parseRequesterPath :: ByteString -> Either RelayError RequesterPath
parseRequesterPath = go 0 []
  where
    go depth frames remaining
        | ByteString.null remaining = case reverse frames of
            [] -> requesterMismatch "the relay requester path is empty"
            path -> Right path
        | depth >= maxRequesterPathDepth =
            requesterMismatch "the relay requester path exceeds the protocol depth limit"
        | otherwise = do
            (rawFrame, rest) <- takeRequesterPathFrame remaining
            frame <- case TextEncoding.decodeUtf8' rawFrame of
                Left _ -> requesterMismatch "the relay requester path contains invalid UTF-8"
                Right value
                    | Text.null value ->
                        requesterMismatch "the relay requester path contains an empty frame"
                    | otherwise -> Right value
            go (depth + 1) (frame : frames) rest

{- | Take one requester component after rejecting its declared width.

This deliberately does not reuse the generic 8 MiB handoff frame reader: a
component's 4,096-byte limit must be enforced before splitting or decoding the
attacker-controlled body.
-}
takeRequesterPathFrame :: ByteString -> Either RelayError (ByteString, ByteString)
takeRequesterPathFrame raw
    | ByteString.length raw < 8 =
        requesterMismatch "the relay requester path has a truncated frame header"
    | declared > fromIntegral maxRequesterPathComponentBytes =
        requesterMismatch "the relay requester path declares an oversized frame"
    | fromIntegral (ByteString.length body) < declared =
        requesterMismatch "the relay requester path has a truncated frame body"
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared :: Word64
    declared = ByteString.foldl' decodeLengthByte 0 header
    decodeLengthByte value byte = (value `shiftL` 8) .|. fromIntegral byte

rootedRequestPath :: ByteString -> Either RelayError (Maybe RequesterPath)
rootedRequestPath =
    either
        (requesterMismatch . ("the rooted lifecycle request " <>))
        Right
        . rootedLifecycleRequestPathKernel

rootedResponsePath :: ByteString -> ByteString -> Either RelayError RequesterPath
rootedResponsePath exactRequest =
    either
        (requesterMismatch . ("the rooted lifecycle response " <>))
        Right
        . rootedLifecycleResponsePairPathKernel exactRequest

{- | Match one route-derived envelope to the closed inner path.

At the root the complete external path must equal every post-open inner path.
At an intermediate it must be the exact leaf suffix because upstream hops have
not yet prepended their own authenticated components. 'OpenFrame' has no inner
path and therefore relies solely on the non-empty sealed envelope.
-}
requireRootedRequesterPath ::
    Bool ->
    RequesterPath ->
    Maybe RequesterPath ->
    Either RelayError ()
requireRootedRequesterPath atRoot envelope inner = do
    _ <- renderRequesterEnvelope envelope ByteString.empty
    case inner of
        Nothing -> Right ()
        Just complete
            | atRoot && complete == envelope -> Right ()
            | not atRoot && envelope `isPathSuffixOf` complete -> Right ()
            | atRoot ->
                requesterMismatch
                    "the rooted lifecycle request path differs from the complete relay envelope"
            | otherwise ->
                requesterMismatch
                    "the relay requester envelope is not the exact rooted lifecycle path suffix"
  where
    suffix `isPathSuffixOf` complete =
        length suffix <= length complete
            && drop (length complete - length suffix) complete == suffix

requireServedProvenance :: Text -> RequesterPath -> Either RelayError ()
requireServedProvenance childFrame path = case path of
    firstFrame : _
        | firstFrame == childFrame -> Right ()
        | otherwise ->
            requesterMismatch
                "the relay requester path does not begin at the exact admitted child"
    [] -> requesterMismatch "the relay requester path is empty"

requireServedRequester :: Text -> Text -> RequesterPath -> Either RelayError ()
requireServedRequester childFrame requestedParent path = do
    requireServedProvenance childFrame path
    case reverse path of
        originFrame : _
            | originFrame == requestedParent -> Right ()
            | otherwise ->
                requesterMismatch
                    "the requested parent frame is not the authenticated path origin"
        [] -> requesterMismatch "the relay requester path is empty"

requesterMismatch :: Text -> Either RelayError value
requesterMismatch = Left . RelayHandoffFailure . HandoffBindingMismatch

-- ---------------------------------------------------------------------------
-- Handing an edge to a child

{- | Open one edge through this frame's link, offer it to the child on
@channel@, and stay on the channel until the child is done.

The tail of this function is the duplex half. After the child accepts, it keeps
the channel and may relay requests of its own — it is the parent of the next
frame — so this loop answers them through the *same* link that opened this edge.
At the root that means signing; at an intermediate frame it means relaying one
hop further up. Either way the frame in the middle only ever moves messages.
-}
maxEmbeddedOfferPayloadBytes :: Int
maxEmbeddedOfferPayloadBytes = 7 * 1024 * 1024

offerHandoffEdge ::
    BrokerLink scope brokerGeneration ->
    -- | the channel to the child this frame is launching
    HandoffChannel ->
    -- | the request identity for this edge
    Word64 ->
    HandoffBindingInput ->
    -- | the exact narrowed config or recovery-adapter bytes
    ByteString ->
    ( HandoffOffer scope brokerGeneration ->
      ByteString ->
      (ByteString -> ByteString -> IO (Either Text ())) ->
      IO (Either Text ())
    ) ->
    IO (Either RelayError ())
offerHandoffEdge _ _ 0 _ _ _ =
    pure (Left (RelayProtocolFailure ProtocolZeroRequestId))
offerHandoffEdge link channel request input payload terminal = case requireOfferPayloadBound payload >> requireConfigOpen input of
    Left failure -> refuse channel request failure
    Right () -> do
        opened <- openEdgeThroughLink link input
        case opened of
            Left failure -> refuse channel request failure
            Right (relay, token) -> case mkHandoffOffer relay payload token of
                Left failure -> refuse channel request (RelayHandoffFailure failure)
                Right offer -> do
                    authenticated <- offerAuthentication link offer
                    case authenticated of
                        Left failure -> refuse channel request failure
                        Right authentication -> do
                            sent <- transmit channel OfferTag request (offerFieldsOf offer authentication)
                            case sent of
                                Left failure -> pure (Left failure)
                                Right () ->
                                    awaitChallenge link channel request offer (terminal offer)

{- | Recoverably bind one prepared reverse edge before signing or sending it.

This kernel is transport only. The payload is the complete canonical recovery
child package the durable prepared descent already derived from its catalog
edge and plan-owned projection: nothing here selects, rebuilds, or narrows it,
and there is no way to hand this function an adapter instead. The durable
transition owns the ordering — it reauthorizes the command and rechecks the
exact Prepared-or-Bound row before the edge is opened, revalidates the returned
offer against the retained package, and only then compare-and-swaps the Bound
row whose canonical binding bytes the reverse completion later rehydrates.

Retransmission is therefore the same exchange rather than a second edge. The
root's recoverable open map answers a repeated attempt with the binding and
token it already minted, 'mkHandoffOffer' rebuilds the identical offer, and the
Bound compare-and-swap converges on the row already present.

Signing stays where it always was: 'offerAuthentication' routes the exact
constructed Offer through this frame's existing link, which is a signer only at
the root and a keyless carrier everywhere else.
-}
offerReverseDescentKernel ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ( ReverseDescent (HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
      ByteString ->
      (ByteString -> ByteString -> IO (Either Text ())) ->
      IO (Either Text ())
    ) ->
    IO (Either RelayError ())
offerReverseDescentKernel _ _ 0 _ _ = pure (Left (RelayProtocolFailure ProtocolZeroRequestId))
offerReverseDescentKernel link channel request descent terminal = do
    bound <- withBoundReverseDescentKernel recoverySigningKernel descent open serve
    case bound of
        Left (failure, _) ->
            refuse
                channel
                request
                (RelayRecoveryNotPlanned (Text.pack (teardownErrorMessage failure)))
        Right transported -> pure transported
  where
    open input package = case requireOfferPayloadBound package of
        Left failure -> refuse channel request failure
        Right () -> do
            opened <- openRecoverableEdgeThroughLink link input package
            case opened of
                Left failure -> refuse channel request failure
                Right (relay, token) -> case mkHandoffOffer relay package token of
                    Left failure -> refuse channel request (RelayHandoffFailure failure)
                    Right offer -> pure (Right offer)

    serve bound offer = do
        authenticated <- offerAuthentication link offer
        case authenticated of
            Left failure -> refuse channel request failure
            Right authentication -> do
                sent <- transmit channel OfferTag request (offerFieldsOf offer authentication)
                case sent of
                    Left failure -> pure (Left failure)
                    Right () -> awaitChallenge link channel request offer (terminal bound)

{- | Build the fourth Offer field from the exact validated offer.

    The root-issued scope capsule is always the first frame, followed by the
    existing installed-key digest and kind-specific evidence. A relayed link
    copies the typed capsule retained by its received edge; it cannot mint or
    replace one. Config carries no trailing evidence. Recovery carries the
    independently signed canonical projection and grant, produced through the
    offering parent's existing route only after 'mkHandoffOffer' has proved the
    payload, token, and opened binding agree.
-}
offerAuthentication ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    IO (Either RelayError ByteString)
offerAuthentication link offer =
    do
        rootedResult <- rootedBindingThroughLink link offer
        case rootedResult of
            Left failure -> pure (Left failure)
            Right rooted -> case handoffPayloadKind binding of
                NarrowedProjectConfig ->
                    pure (Right (authenticationPrelude <> frameWire rooted))
                RecoveryAdapterWire ->
                    case (handoffVerb binding, handoffPhase binding) of
                        ("down", "teardown") -> recoveryAuthentication rooted ProjectDown
                        ("destroy", "teardown") -> recoveryAuthentication rooted ProjectDestroy
                        (verb, phase) ->
                            pure
                                ( Left
                                    ( RelayHandoffFailure
                                        ( HandoffBindingMismatch
                                            ( "a recovery offer must be Down/Destroy Teardown, received "
                                                <> verb
                                                <> " "
                                                <> phase
                                            )
                                        )
                                    )
                                )
  where
    binding = handoffOfferBinding offer
    (payload, _, _) = handoffOfferFrames offer
    authenticationPrelude =
        frameWire (renderAuthenticatedRootScope (linkAuthenticatedRootScope link))
            <> frameWire (linkKeyDigest link)

    recoveryAuthentication rooted verb = case Recovery.recoveryChildPackageFromWireKernel payload of
        Left detail ->
            pure
                ( Left
                    ( RelayHandoffFailure
                        (HandoffBindingMismatch ("recovery child package " <> detail))
                    )
                )
        Right package -> Recovery.withRecoveryChildPackageKernel package $ \_ adapter ->
            case
                withRecoveryProjectionBindingInput
                    (handoffPlanRevision binding)
                    (handoffParentFrame binding)
                    (handoffChildFrame binding)
                    ( \input ->
                        withSignedRecoveryThroughLink verb link input adapter $ \projection grant ->
                            pure
                                ( authenticationPrelude
                                    <> frameWire rooted
                                    <> frameWire (renderRecoveryProjectionBinding projection)
                                    <> frameWire (recoveryWireGrantSignature grant)
                                )
                    )
            of
                Left failure -> pure (Left (RelayHandoffFailure failure))
                Right signed -> signed

requireOfferPayloadBound :: ByteString -> Either RelayError ()
requireOfferPayloadBound payload
    | ByteString.length payload <= maxEmbeddedOfferPayloadBytes = Right ()
    | otherwise =
        requesterMismatch
            "the embedded Offer payload exceeds its strict sub-ceiling"

awaitChallenge ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    ( ByteString ->
      (ByteString -> ByteString -> IO (Either Text ())) ->
      IO (Either Text ())
    ) ->
    IO (Either RelayError ())
awaitChallenge link channel request offer terminal = do
    answer <- await channel request ChallengeTag
    case answer of
        Left failure -> pure (Left failure)
        Right [raw] -> case handoffChallengeFromBytes raw of
            Left failure -> refuse channel request (RelayHandoffFailure failure)
            Right challenge -> do
                granted <- grantThroughLink link offer challenge
                case granted of
                    Left failure -> do
                        -- The child is waiting on an answer it will never get,
                        -- so tell it rather than letting its read block until
                        -- the pipe closes.
                        _ <- refuse channel request failure
                        pure (Left failure)
                    Right grant -> do
                        sent <-
                            transmit
                                channel
                                GrantTag
                                request
                                [grantSignature grant, linkKeyDigest link]
                        case sent of
                            Left failure -> pure (Left failure)
                            Right () ->
                                serveUntilDone
                                    ( ParentAwaitingAcceptance
                                        ( TextEncoding.encodeUtf8
                                            (handoffChildConfigDigest (handoffOfferBinding offer))
                                        )
                                        (handoffChildFrame (handoffOfferBinding offer))
                                    )
                                    link
                                    channel
                                    request
                                    offer
                                    challenge
                                    terminal
        Right fields -> refuse channel request (RelayMalformedMessage ChallengeTag (length fields))

-- | The state retained by the parent after it sends the grant.
data ParentRelayState
    = ParentAwaitingAcceptance ByteString Text
    | ParentServingAdmittedChild Text
    deriving (Eq, Show)

{- | Require the child's acceptance and then serve it until it completes.

A child that refuses at any point ends the exchange with its own cause, which is
returned rather than turned into a generic transport failure: "the child
declined" and "the pipe broke" are different facts.

The post-grant barrier is explicit. Until one exact 'AcceptedTag' arrives, no
open, grant, activation, or recovery capability can be reached and completion
is premature. Once accepted, a second acceptance is an invalid transition.
-}
serveUntilDone ::
    ParentRelayState ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ( ByteString ->
      (ByteString -> ByteString -> IO (Either Text ())) ->
      IO (Either Text ())
    ) ->
    IO (Either RelayError ())
serveUntilDone state link channel request offer challenge terminal = do
    next <- case state of
        ParentAwaitingAcceptance _ _ -> receiveControlFrame channel
        ParentServingAdmittedChild _ -> receive channel
    case next of
        Left failure -> refuse channel request failure
        Right message
            | protocolMessageRequestId message /= request ->
                refuse
                    channel
                    request
                    ( RelayProtocolFailure
                        (ProtocolRequestMismatch request (protocolMessageRequestId message))
                    )
            | otherwise ->
                serveMessage state link channel request offer challenge terminal message

serveMessage ::
    ParentRelayState ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ( ByteString ->
      (ByteString -> ByteString -> IO (Either Text ())) ->
      IO (Either Text ())
    ) ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveMessage state link channel request offer challenge terminal message =
    case (state, protocolMessageTag message) of
    (ParentAwaitingAcceptance expectedDigest childFrame, AcceptedTag) ->
        case protocolMessageFields message of
            [actualDigest]
                | actualDigest == expectedDigest ->
                    serveUntilDone
                        (ParentServingAdmittedChild childFrame)
                        link channel request offer challenge terminal
                | otherwise ->
                    refuse
                        channel
                        request
                        ( RelayHandoffFailure
                            (HandoffBindingMismatch "the child accepted a different payload digest")
                        )
            fields -> refuse channel request (RelayMalformedMessage AcceptedTag (length fields))
    (_, RefusedTag) -> pure (Left (refusalFrom message))
    (ParentServingAdmittedChild _, CompletedTag) ->
        case protocolMessageFields message of
            [report] ->
                runLifecycleTerminal
                    link channel request offer challenge report terminal
            _ -> refuse channel request RelayLifecycleFailure
    (ParentServingAdmittedChild childFrame, OfferRequestTag) ->
        continueAfter childFrame (serveOpen childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, GrantRequestTag) ->
        continueAfter childFrame (serveGrant childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, ActivationSignRequestTag) ->
        continueAfter childFrame (serveActivationSigning childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, RecoveryRequestTag) ->
        continueAfter childFrame (serveRecoverySigning childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, LifecycleAckRequestTag) ->
        continueAfter childFrame
            (serveLifecycleAcknowledgement childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, RootedLifecycleRequestTag) ->
        continueAfter childFrame
            (serveRootedLifecycle childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, ProviderDependencyProbeRequestTag) ->
        continueAfter childFrame
            (serveProviderDependency link channel request message)
    (ParentServingAdmittedChild childFrame, ProviderDependencyPackageTag) ->
        continueAfter childFrame
            (serveProviderDependencyPackage link channel request message)
    (_, tag) -> refuse channel request (RelayUnexpectedMessage tag)
  where
    continueAfter childFrame served = do
        outcome <- served
        either
            (pure . Left)
            ( const
                ( serveUntilDone
                    (ParentServingAdmittedChild childFrame)
                    link channel request offer challenge terminal
                )
            )
            outcome

serveProviderDependency ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveProviderDependency link channel request message = do
    answered <- linkProviderDependencyRaw link (protocolMessageFields message)
    case answered of
        Left failure -> refuse channel request failure
        Right fields -> transmit channel ProviderDependencyProbeResponseTag request fields

relayProviderDependency ::
    HandoffChannel ->
    Word64 ->
    [ByteString] ->
    IO (Either RelayError [ByteString])
relayProviderDependency channel request fields = do
    sent <- transmit channel ProviderDependencyProbeRequestTag request fields
    case sent of
        Left failure -> pure (Left failure)
        Right () -> do
            answered <- timeout providerRelayMicros (await channel request ProviderDependencyProbeResponseTag)
            pure (maybe (Left RelayControlFrameTimeout) id answered)

providerRelayMicros :: Int
providerRelayMicros = 1000000

serveProviderDependencyPackage ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveProviderDependencyPackage link channel request message =
    case protocolMessageFields message of
        [requestField]
            | ByteString.null requestField ->
                case linkProviderDependencyPackage link of
                    Nothing -> transmit channel ProviderDependencyPackageTag request [ByteString.empty]
                    Just packageWire -> case providerDependencyPackageFields packageWire of
                        Left failure -> refuse channel request (RelayEdgeNotPlanned failure)
                        Right fields -> transmit channel ProviderDependencyPackageTag request fields
        fields -> refuse channel request (RelayMalformedMessage ProviderDependencyPackageTag (length fields))

{- | Run one fixed terminal callback before acknowledging its exact report.

The lexical persist closure is one-shot and closes when the callback returns.
If a claimed call is still running, closure waits for its masked completion
signal before classifying the callback.  No callback text reaches a Relay
failure, and once acknowledgement I/O is attempted no refusal is sent.
-}
runLifecycleTerminal ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    ByteString ->
    ( ByteString ->
      (ByteString -> ByteString -> IO (Either Text ())) ->
      IO (Either Text ())
    ) ->
    IO (Either RelayError ())
runLifecycleTerminal link channel request offer challenge report terminal =
    case canonicalTerminal of
        Left _ -> refuse channel request RelayLifecycleFailure
        Right acknowledgement -> mask $ \restore -> do
            gate <- newMVar (False, False, False, Nothing :: Maybe Bool)
            completed <- newEmptyMVar
            let fixedPersistFailure = Left lifecycleAcknowledgementUnavailable
                fixedReplay = Left "lifecycle acknowledgement replay"

                persist observedReport observedAcknowledgement = mask $ \restorePersist -> do
                    claimed <- modifyMVar gate $ \state@(closed, entered, attempted, fresh) ->
                        if closed || entered
                            then pure (state, False)
                            else pure ((closed, True, attempted, fresh), True)
                    if not claimed
                        then pure fixedPersistFailure
                        else
                            restorePersist
                                (persistClaim observedReport observedAcknowledgement)
                                `finally` putMVar completed ()

                persistClaim observedReport observedAcknowledgement
                    | observedReport /= report || observedAcknowledgement /= acknowledgement =
                        pure fixedPersistFailure
                    | otherwise = do
                        prepared <-
                            prepareLifecycleAcknowledgementThroughLink
                                link offer challenge report acknowledgement
                                pending alreadyAdopted
                        case prepared of
                            Left _ -> pure fixedPersistFailure
                            Right () -> do
                                (_, _, _, disposition) <- readMVar gate
                                pure $ case disposition of
                                    Just True -> Right ()
                                    Just False -> fixedReplay
                                    Nothing -> fixedPersistFailure

                pending storedAcknowledgement =
                    do
                        adopted <-
                            adoptLifecycleAcknowledgementThroughLink
                                link offer challenge report acknowledgement
                                (recordDisposition True)
                                (recordDisposition False)
                        case adopted of
                            Left _ -> pure (Left RelayLifecycleFailure)
                            Right () -> sendAcknowledgement storedAcknowledgement (pure (Right ()))

                alreadyAdopted storedAcknowledgement =
                    sendAcknowledgement storedAcknowledgement (recordDisposition False)

                sendAcknowledgement storedAcknowledgement after
                    | storedAcknowledgement /= acknowledgement =
                        pure (Left RelayLifecycleFailure)
                    | otherwise = do
                        modifyMVar_ gate $ \(closed, entered, _, fresh) ->
                            pure (closed, entered, True, fresh)
                        sent <- transmit channel AcknowledgedTag request [acknowledgement]
                        case sent of
                            Left _ -> pure (Left RelayLifecycleFailure)
                            Right () -> after

                recordDisposition fresh = do
                    modifyMVar_ gate $ \(closed, entered, attempted, _) ->
                        pure (closed, entered, attempted, Just fresh)
                    pure (Right ())

                closeGate retained = do
                    closed <- try
                        ( modifyMVar gate $ \(_, wasEntered, attempted, fresh) ->
                            pure ((True, wasEntered, attempted, fresh), wasEntered)
                        ) :: IO (Either SomeException Bool)
                    case closed of
                        Left failure -> closeGate (retainException retained failure)
                        Right entered ->
                            if entered then waitForCompletion retained else pure retained

                waitForCompletion retained = do
                    waited <- try (takeMVar completed) :: IO (Either SomeException ())
                    case waited of
                        Right () -> pure retained
                        Left failure -> waitForCompletion (retainException retained failure)

                retainException retained failure = case retained of
                    Nothing -> Just failure
                    existing -> existing

                fixedResult attempted =
                    if attempted
                        then pure (Left RelayLifecycleFailure)
                        else refuse channel request RelayLifecycleFailure

            callbackResult <- try (restore (do
                terminalResult <- terminal report persist
                case terminalResult of
                    Left reason -> pure (Left reason)
                    Right value -> evaluate value >> pure (Right ())))
                    :: IO (Either SomeException (Either Text ()))
            closeException <- closeGate Nothing
            (_, _, acknowledgementAttempted, disposition) <- readMVar gate
            classified <- case (callbackResult, disposition) of
                (Right _, Just False) -> pure (Right ())
                (Right (Right ()), Just True) -> pure (Right ())
                _ -> fixedResult acknowledgementAttempted
            case deferredAsync callbackResult closeException of
                Nothing -> pure classified
                Just failure -> throwIO failure
  where
    canonicalTerminal = do
        binding <- lifecycleReportBinding report
        requireLifecycleRelay
            (binding == renderHandoffBinding (handoffOfferBinding offer))
            "the terminal report names another edge"
        fromHandoff (renderLifecycleAcknowledgement report)

    deferredAsync callbackResult closeException = case closeException of
        Just failure -> Just failure
        Nothing -> case callbackResult of
            Left failure -> case fromException failure :: Maybe SomeAsyncException of
                Just _ -> Just failure
                Nothing -> Nothing
            Right _ -> Nothing

serveLifecycleAcknowledgement ::
    Text ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveLifecycleAcknowledgement childFrame link channel request message =
    case protocolMessageFields message of
        [enveloped] -> case parseRequesterEnvelope enveloped of
            Left failure -> refuse channel request failure
            Right (path, raw) ->
                withLifecycleAcknowledgementRequest
                    (linkRoute link)
                    raw
                    (forward path raw)
                    (forward path raw)
        fields -> refuse channel request (RelayMalformedMessage LifecycleAckRequestTag (length fields))
  where
    forward path raw offer _ _ _ =
        case requireServedRequester
            childFrame
            (handoffParentFrame (handoffOfferBinding offer))
            path of
            Left failure -> refuse channel request failure
            Right () -> do
                routed <-
                    linkLifecycleAcknowledgementRaw link path raw $ \response ->
                        transmit channel LifecycleAckResponseTag request [response]
                case routed of
                    Left failure -> refuse channel request failure
                    Right () -> pure (Right ())

{- | Carry one admitted child's rooted request through this frame's route.

The child-facing envelope is checked against the exact admitted child before
the route is used. This hop decodes only the closed structural family and path
relationship. It neither verifies nor creates a signature and preserves an
upstream outer refusal byte-for-byte.
-}
serveRootedLifecycle ::
    Text ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveRootedLifecycle childFrame link channel request message =
    case protocolMessageFields message of
        [enveloped] -> case parseRequesterEnvelope enveloped of
            Left failure -> refuse channel request failure
            Right (path, exactRequest) -> case requireServedProvenance childFrame path of
                Left failure -> refuse channel request failure
                Right () -> case rootedRequestPath exactRequest
                    >>= requireRootedRequesterPath False path of
                    Left failure -> refuse channel request failure
                    Right () -> do
                        routed <- linkRootedLifecycleRaw link path exactRequest
                        case routed of
                            Left failure -> refuse channel request failure
                            Right (Left (code, detail)) -> do
                                sent <- transmit channel RefusedTag request [code, detail]
                                pure $ case sent of
                                    Left failure -> Left failure
                                    Right () ->
                                        Left
                                            ( RelayRefusedByPeer
                                                (TextEncoding.decodeUtf8Lenient code)
                                                (TextEncoding.decodeUtf8Lenient detail)
                                            )
                            Right (Right signedResponse) ->
                                case rootedResponsePath exactRequest signedResponse
                                    >>= requireRootedRequesterPath False path . Just of
                                    Left failure -> refuse channel request failure
                                    Right () ->
                                        transmit
                                            channel
                                            RootedLifecycleResponseTag
                                            request
                                            [signedResponse]
        fields ->
            refuse
                channel
                request
                (RelayMalformedMessage RootedLifecycleRequestTag (length fields))

-- | Answer a child's request to open an edge, through this frame's own link.
serveOpen ::
    Text ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveOpen childFrame link channel request message = case protocolMessageFields message of
    [enveloped] -> case parseRequesterEnvelope enveloped of
        Left failure -> refuse channel request failure
        Right (path, raw) -> case parseRecoverableOpen raw of
            Left failure -> refuse channel request failure
            Right (Just (input, adapter)) ->
                answerOpen childFrame channel request path input
                    (linkRecoverableOpenRaw link path input adapter)
            Right Nothing -> case handoffBindingInputFromWire raw of
                Left failure -> refuse channel request (RelayHandoffFailure failure)
                Right input -> case requireConfigOpen input of
                    Left failure -> refuse channel request failure
                    Right () -> answerOpen childFrame channel request path input (linkOpenRaw link path input)
    fields -> refuse channel request (RelayMalformedMessage OfferRequestTag (length fields))

answerOpen ::
    Text -> HandoffChannel -> Word64 -> RequesterPath -> HandoffBindingInput ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken)) ->
    IO (Either RelayError ())
answerOpen childFrame channel request path input opened =
    case requireServedRequester childFrame (requestedParentFrame input) path of
        Left failure -> refuse channel request failure
        Right () -> do
            result <- opened
            case result of
                Left failure -> refuse channel request failure
                Right (relay, token) ->
                    transmit channel OfferResponseTag request
                        [frameWire (renderHandoffBinding (relayBinding relay)) <> frameWire (handoffTokenBytes token)]

-- | Answer a child's request for a grant, through this frame's own link.
serveGrant ::
    Text ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveGrant childFrame link channel request message = case protocolMessageFields message of
    [enveloped, challengeRaw] -> case parseRequesterEnvelope enveloped of
        Left failure -> refuse channel request failure
        Right (path, offerWire) ->
            case adoptRelayedRequest (linkRoute link) offerWire challengeRaw of
                Left failure -> refuse channel request failure
                Right (offer, challenge) ->
                    case requireServedRequester
                        childFrame
                        (handoffParentFrame (handoffOfferBinding offer))
                        path of
                        Left failure -> refuse channel request failure
                        Right () -> do
                            granted <- linkGrantRaw link path offer challenge
                            case granted of
                                Left failure -> refuse channel request failure
                                Right grant ->
                                    transmit channel GrantResponseTag request [grantSignature grant]
    fields -> refuse channel request (RelayMalformedMessage GrantRequestTag (length fields))

{- | Answer a child's request to sign an activation manifest.

The manifest is rebuilt from the bytes that arrived and then signed through the
link, so the signer sees a value it decoded rather than an opaque blob. A
manifest that does not decode is refused before the broker is reached at all —
signing is an authorization, and a broker that signed bytes it could not read
would be an oracle rather than an authority.
-}
serveActivationSigning ::
    Text ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveActivationSigning childFrame link channel request message = case protocolMessageFields message of
    [enveloped] -> case parseRequesterEnvelope enveloped of
        Left failure -> refuse channel request failure
        Right (path, raw) -> case requireServedProvenance childFrame path of
            Left failure -> refuse channel request failure
            Right () -> case activationManifestFromWire raw of
                Left failure -> refuse channel request (RelayActivationRefused failure)
                Right manifest -> do
                    signed <- linkSignActivationRaw link path manifest
                    case signed of
                        Left failure -> refuse channel request failure
                        Right grant ->
                            transmit
                                channel
                                ActivationSignResponseTag
                                request
                                [activationGrantSignature grant]
    fields -> refuse channel request (RelayMalformedMessage ActivationSignRequestTag (length fields))

-- | Answer one admitted child's recovery request through the root route.
serveRecoverySigning ::
    Text ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveRecoverySigning childFrame link channel request message = case protocolMessageFields message of
    [enveloped, wire] -> case parseRequesterEnvelope enveloped of
        Left failure -> refuse channel request failure
        Right (path, requestHeader) -> case rootedSigningKind requestHeader of
            Left failure -> refuse channel request failure
            Right (Just kind) -> case adoptRelayedOffer (linkRoute link) wire of
                Left failure -> refuse channel request failure
                Right offer ->
                    if handoffPayloadKind (handoffOfferBinding offer) /= kind
                        then refuse channel request
                            (RelayHandoffFailure (HandoffBindingMismatch "the rooted signing kind differs from the exact offer"))
                        else case requireServedRequester
                            childFrame
                            (handoffParentFrame (handoffOfferBinding offer))
                            path of
                            Left failure -> refuse channel request failure
                            Right () -> do
                                signed <- linkRootedBindingRaw link path offer
                                case signed of
                                    Left failure -> refuse channel request failure
                                    Right response -> transmit channel RecoveryResponseTag request [response]
            Right Nothing -> case recoveryParentFromWire requestHeader of
                Left failure -> refuse channel request failure
                Right parentFrame -> case requireServedRequester childFrame parentFrame path of
                    Left failure -> refuse channel request failure
                    Right () -> do
                        signed <- linkRecoveryFieldsRaw link path [requestHeader, wire]
                        case signed of
                            Left failure -> refuse channel request failure
                            Right response -> transmit channel RecoveryResponseTag request response
    fields -> refuse channel request (RelayMalformedMessage RecoveryRequestTag (length fields))

{- | Rebuild the offer and challenge a relayed request describes.

The binding is adopted as a relay and then re-paired with the exact payload and
token that travelled with it, so what this frame passes upward is the same edge
the requester holds and not a re-description of it. Whether that edge is one the
root opened is the root's question, answered where the durable record lives.
-}
adoptRelayedRequest ::
    BrokerRoute scope brokerGeneration ->
    ByteString ->
    ByteString ->
    Either RelayError (HandoffOffer scope brokerGeneration, HandoffChallenge)
adoptRelayedRequest route offerWire challengeRaw = do
    offer <- adoptRelayedOffer route offerWire
    challenge <- fromHandoff (handoffChallengeFromBytes challengeRaw)
    pure (offer, challenge)

adoptRelayedOffer ::
    BrokerRoute scope brokerGeneration ->
    ByteString ->
    Either RelayError (HandoffOffer scope brokerGeneration)
adoptRelayedOffer route offerWire = do
    (payload, afterPayload) <- fromHandoff (takeHandoffFrame offerWire)
    requireOfferPayloadBound payload
    (tokenFrame, afterToken) <- fromHandoff (takeHandoffFrame afterPayload)
    (bindingBytes, trailing) <- fromHandoff (takeHandoffFrame afterToken)
    if not (ByteString.null trailing)
        then Left (RelayMalformedMessage GrantRequestTag 2)
        else do
            relay <- fromHandoff (brokerRelayFromRouteWire route Nothing bindingBytes)
            token <- fromHandoff (handoffTokenFromBytes tokenFrame)
            fromHandoff (mkHandoffOffer relay payload token)

-- ---------------------------------------------------------------------------
-- Channel plumbing

offerFieldsOf :: HandoffOffer scope brokerGeneration -> ByteString -> [ByteString]
offerFieldsOf offer authentication = [payload, token, binding, authentication]
  where
    (payload, token, binding) = handoffOfferFrames offer

offerWireOf :: HandoffOffer scope brokerGeneration -> ByteString
offerWireOf offer = frameWire payload <> frameWire token <> frameWire binding
  where
    (payload, token, binding) = handoffOfferFrames offer

transmit :: HandoffChannel -> ProtocolTag -> Word64 -> [ByteString] -> IO (Either RelayError ())
transmit channel tag request fields = case protocolMessage tag request fields of
    Left failure -> pure (Left (RelayProtocolFailure failure))
    Right message -> do
        sent <- channelSend channel message
        pure (either (Left . RelayProtocolFailure) Right sent)

receive :: HandoffChannel -> IO (Either RelayError ProtocolMessage)
receive channel = do
    received <- channelReceive channel
    pure (either (Left . RelayProtocolFailure) Right received)

{- | How long a parent waits for a frame the child owes it immediately.

A control frame is one the peer can produce without doing any of the work the
edge is about: its challenge, and its acceptance of the offered digest. Nothing
in the protocol makes a peer that has stopped talking distinguishable from one
that is slow, so an unbounded wait for a frame that requires no work is an
unbounded wait for a peer that may already be gone.

This bound deliberately does not cover the wait that follows admission. Once a
child is serving, the next frame it owes is its completed report, and the time
until that arrives is the time the admitted backend effect takes — which has
its own closed policy and is not this module's to second-guess. Putting one
wall-clock deadline over that wait would make every long provisioning step a
protocol failure.
-}
controlFrameMicros :: Int
controlFrameMicros = 120 * 1000000

{- | Receive one control frame, or fail rather than wait forever. -}
receiveControlFrame :: HandoffChannel -> IO (Either RelayError ProtocolMessage)
receiveControlFrame channel = do
    answered <- timeout controlFrameMicros (receive channel)
    pure (maybe (Left RelayControlFrameTimeout) id answered)

{- | Receive the exact tag and request identity this exchange expects.

An unexpected, malformed, or cross-request response is actively refused while
the peer is waiting, rather than being reduced to a local return followed by
EOF.
-}
await :: HandoffChannel -> Word64 -> ProtocolTag -> IO (Either RelayError [ByteString])
await channel request expected = do
    received <- receiveControlFrame channel
    case received of
        Left failure -> refuse channel request failure
        Right message
            | protocolMessageRequestId message /= request ->
                refuse
                    channel
                    request
                    ( RelayProtocolFailure
                        (ProtocolRequestMismatch request (protocolMessageRequestId message))
                    )
            | protocolMessageTag message == expected ->
                pure (Right (protocolMessageFields message))
            | protocolMessageTag message == RefusedTag ->
                pure (Left (refusalFrom message))
            | otherwise ->
                refuse channel request (RelayUnexpectedMessage (protocolMessageTag message))

-- | Tell the peer why this frame stopped, and keep the original cause.
refuse :: HandoffChannel -> Word64 -> RelayError -> IO (Either RelayError result)
refuse channel request failure = do
    _ <- transmit channel RefusedTag request [refusalCode failure, refusalDetail failure]
    pure (Left failure)

refusalFrom :: ProtocolMessage -> RelayError
refusalFrom message = case protocolMessageFields message of
    [code, detail] ->
        RelayRefusedByPeer
            (TextEncoding.decodeUtf8Lenient code)
            (TextEncoding.decodeUtf8Lenient detail)
    _ -> RelayRefusedByPeer "unspecified" ""

refusalCode :: RelayError -> ByteString
refusalCode failure = case failure of
    RelayProtocolFailure _ -> "protocol"
    RelayHandoffFailure _ -> "unauthenticated"
    RelayEdgeNotPlanned _ -> "edge-not-planned"
    RelayMalformedMessage _ _ -> "malformed-message"
    RelayUnexpectedMessage _ -> "unexpected-message"
    RelayRefusedByPeer _ _ -> "peer-refused"
    RelayActivationRefused _ -> "activation-refused"
    RelayRecoveryNotPlanned _ -> "recovery-not-planned"
    RelayLifecycleFailure -> "lifecycle-failed"
    RelayControlFrameTimeout -> "control-frame-timeout"

refusalDetail :: RelayError -> ByteString
refusalDetail = TextEncoding.encodeUtf8 . Text.pack . relayErrorMessage

-- ---------------------------------------------------------------------------
-- Failures

-- | Every way a relayed exchange stops.
data RelayError
    = RelayProtocolFailure ProtocolError
    | RelayHandoffFailure HandoffError
    | -- | the root's plan names no such edge
      RelayEdgeNotPlanned Text
    | RelayMalformedMessage ProtocolTag Int
    | RelayUnexpectedMessage ProtocolTag
    | -- | the peer declined: code, then detail
      RelayRefusedByPeer Text Text
    | -- | the manifest did not decode, or the signer refused to sign it
      RelayActivationRefused ActivationError
    | -- | the root plan does not admit this recovery projection
      RelayRecoveryNotPlanned Text
    | -- | fixed/redacted terminal acknowledgement failure
      RelayLifecycleFailure
    | -- | a frame the peer owed immediately never arrived
      RelayControlFrameTimeout
    deriving (Eq, Show)

-- | A one-line diagnostic.
relayErrorMessage :: RelayError -> String
relayErrorMessage failure = case failure of
    RelayProtocolFailure detail -> protocolErrorMessage detail
    RelayHandoffFailure detail -> handoffErrorMessage detail
    RelayEdgeNotPlanned reason -> "handoff relay: the plan names no such edge: " <> Text.unpack reason
    RelayMalformedMessage tag actual ->
        "handoff relay: " <> show tag <> " arrived with " <> show actual <> " fields"
    RelayUnexpectedMessage tag -> "handoff relay: unexpected " <> show tag
    RelayRefusedByPeer code detail ->
        "handoff relay: the peer refused (" <> Text.unpack code <> "): " <> Text.unpack detail
    RelayActivationRefused detail ->
        "handoff relay: activation signing refused: " <> activationErrorMessage detail
    RelayRecoveryNotPlanned reason ->
        "handoff relay: the plan names no such recovery projection: " <> Text.unpack reason
    RelayLifecycleFailure -> "handoff relay: lifecycle acknowledgement failed"
    RelayControlFrameTimeout -> "handoff relay: the peer owed a control frame and sent none"

fromHandoff :: Either HandoffError a -> Either RelayError a
fromHandoff = either (Left . RelayHandoffFailure) Right

splitPair :: ByteString -> Either RelayError (ByteString, ByteString)
splitPair raw = do
    (first, rest) <- fromHandoff (takeHandoffFrame raw)
    (second, trailing) <- fromHandoff (takeHandoffFrame rest)
    if ByteString.null trailing
        then Right (first, second)
        else Left (RelayMalformedMessage OfferResponseTag 1)
