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
* at every other frame, 'relayedBrokerLink' is derived from the already verified
  parent edge. It retains that edge's channel, request identity, root-route
  coordinates, and installed public-key digest. It is *structurally* keyless:
  there is no signing key or protected store, and no function from it to a
  'RootBroker'. It forwards, waits, and passes the answer on.

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
    signRecoveryThroughLink,
    withSignedRecoveryThroughLink,
    rootBrokerLink,
    relayedBrokerLink,
    EdgeAdmission,
    RecoveryAdmission,
    openEdgeThroughLink,
    grantThroughLink,

    -- * Handing an edge to a child
    offerHandoffEdge,

    -- * Failures
    RelayError (..),
    relayErrorMessage,
) where

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
import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Handoff (
    BrokerRelay,
    BrokerRoute,
    HandoffBindingInput,
    HandoffChallenge,
    HandoffError (HandoffBindingMismatch, HandoffWireTrailingBytes),
    HandoffGrant,
    HandoffOffer,
    HandoffToken,
    RecoveryProjectionBinding,
    RecoveryProjectionBindingInput,
    RecoveryWireGrant,
    RootBroker,
    brokerRelayFromRouteWire,
    brokerRouteCurrentFrame,
    brokerRouteVerificationKeyDigest,
    challengeBytes,
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
    handoffTokenBytes,
    handoffTokenFromBytes,
    mkHandoffOffer,
    mkRecoveryProjectionBindingFromRoute,
    recoveryRequestFields,
    recoveryRequestFromFields,
    recoveryResponseFields,
    recoveryResponseFromFields,
    registerAdmittedHandoffEdge,
    relayBinding,
    renderHandoffBinding,
    renderHandoffBindingInput,
    requestedParentFrame,
    requestedRecoveryParentFrame,
    rootBrokerRoute,
    signAdmittedRecoveryWire,
    takeHandoffFrame,
    verifiedHandoffBinding,
    verifiedHandoffRoute,
    withRecoveryProjectionBindingInput,
 )
import HostBootstrap.Handoff.Protocol (
    HandoffChannel,
    ProtocolError (ProtocolRequestMismatch, ProtocolZeroRequestId),
    ProtocolMessage,
    ProtocolTag (
        AcceptedTag,
        ActivationSignRequestTag,
        ActivationSignResponseTag,
        ChallengeTag,
        CompletedTag,
        GrantRequestTag,
        GrantResponseTag,
        GrantTag,
        OfferRequestTag,
        OfferResponseTag,
        OfferTag,
        RecoveryRequestTag,
        RecoveryResponseTag,
        RefusedTag
    ),
    channelReceive,
    channelSend,
    protocolErrorMessage,
    protocolMessage,
    protocolMessageFields,
    protocolMessageRequestId,
    protocolMessageTag,
 )
import HostBootstrap.Handoff.Receiver (
    ReceivedEdge,
 )
import HostBootstrap.Handoff.Receiver.Internal (
    receivedEdgeChannel,
    receivedEdgeHandoff,
    receivedEdgeRequestId,
 )

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
broker before this callback runs. The callback sees the plan and edge
coordinates a plan must authorize; project, scope, and wire digest remain
root-derived checks in the recovery codec.
-}
type RecoveryAdmission =
    forall planDigest parentFrame childFrame.
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    IO (Either Text ())

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

{- | A frame's route to the root-owned capabilities.

Opaque, and deliberately so: the two constructors below are the only ways to
build one, and only one of them has a key behind it.
-}
data BrokerLink scope brokerGeneration = BrokerLink
    { linkRoute :: BrokerRoute scope brokerGeneration
    , linkOpenRaw ::
        RequesterPath ->
        HandoffBindingInput ->
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
    , linkRecoveryFieldsRaw ::
        RequesterPath ->
        [ByteString] ->
        IO (Either RelayError [ByteString])
    {- ^ Route the closed recovery request fields to the root. The typed public
    entry below constructs and adopts these fields; relay dispatch uses the
    same raw route because an intermediate has no root broker with which to
    mint a typed projection.
    -}
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
    -- | the activation broker whose key the runtimes verify against
    ActivationBroker scope brokerGeneration verb ->
    EdgeAdmission ->
    RecoveryAdmission ->
    BrokerLink scope brokerGeneration
rootBrokerLink broker activation admits admitsRecovery =
    BrokerLink
        { linkRoute = route
        , linkOpenRaw = \_ input -> do
            opened <- registerAdmittedHandoffEdge broker (admits input) input
            pure $ case opened of
                Left failure -> Left (RelayHandoffFailure failure)
                Right (Left reason) -> Left (RelayEdgeNotPlanned reason)
                Right (Right edge) -> Right edge
        , linkGrantRaw = \_ offer challenge ->
            fmap (either (Left . RelayHandoffFailure) Right) (grantHandoff broker offer challenge)
        , -- The root signs locally, through the ordinary validating signer: a
          -- relayed manifest gets no weaker check than a local one.
          linkSignActivationRaw = \_ manifest ->
            fmap
                (either (Left . RelayActivationRefused) Right)
                (signActivationManifest activation manifest)
        , linkRecoveryFieldsRaw = \_ -> rootSignRecovery broker admitsRecovery
        , linkRejectResponse = const (pure ())
        , linkKeyDigest = brokerRouteVerificationKeyDigest route
        }
  where
    route = rootBrokerRoute broker

{- | Every other frame's link, derived from its already verified parent edge.

The edge supplies the exact route identity, installed public-key digest,
channel, and request id together; none is independently caller-selectable.
There is no signing key here and no path to one. A frame holding this can ask
the root to open or grant an edge and authenticate admitted activation or
recovery material; it cannot do any of those itself.
-}
relayedBrokerLink ::
    ReceivedEdge scope brokerGeneration ->
    BrokerLink scope brokerGeneration
relayedBrokerLink edge =
    BrokerLink
        { linkRoute = route
        , linkOpenRaw = \downstream -> relayOpen route channel request (currentFrame : downstream)
        , linkGrantRaw = \downstream -> relayGrant channel request (currentFrame : downstream)
        , linkSignActivationRaw =
            \downstream -> relaySignActivation channel request (currentFrame : downstream)
        , linkRecoveryFieldsRaw =
            \downstream -> relayRecoveryFields channel request (currentFrame : downstream)
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
relayOpen route channel request path input =
    case renderRequesterEnvelope path (renderHandoffBindingInput input) of
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
    case requireOwnFrame link "handoff parent frame" (requestedParentFrame input) of
        Left failure -> pure (Left failure)
        Right () -> linkOpenRaw link [] input

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
                signAdmittedRecoveryWire
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
            (rawFrame, rest) <- fromHandoff (takeHandoffFrame remaining)
            frame <- case TextEncoding.decodeUtf8' rawFrame of
                Left _ -> requesterMismatch "the relay requester path contains invalid UTF-8"
                Right value
                    | Text.null value ->
                        requesterMismatch "the relay requester path contains an empty frame"
                    | otherwise -> Right value
            go (depth + 1) (frame : frames) rest

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
offerHandoffEdge ::
    BrokerLink scope brokerGeneration ->
    -- | the channel to the child this frame is launching
    HandoffChannel ->
    -- | the request identity for this edge
    Word64 ->
    HandoffBindingInput ->
    -- | the exact narrowed child config bytes
    ByteString ->
    IO (Either RelayError ())
offerHandoffEdge _ _ 0 _ _ =
    pure (Left (RelayProtocolFailure ProtocolZeroRequestId))
offerHandoffEdge link channel request input payload = do
    opened <- openEdgeThroughLink link input
    case opened of
        -- The child has been launched and is already waiting on its first
        -- message, so a failure here is announced rather than left to expire as
        -- a closed pipe: "the plan names no such edge" is a diagnosis, and an
        -- EOF is not.
        Left failure -> refuse channel request failure
        Right (relay, token) -> case mkHandoffOffer relay payload token of
            Left failure -> refuse channel request (RelayHandoffFailure failure)
            Right offer -> do
                sent <-
                    transmit
                        channel
                        OfferTag
                        request
                        (offerFieldsOf offer (linkKeyDigest link))
                case sent of
                    Left failure -> pure (Left failure)
                    Right () -> awaitChallenge link channel request offer

awaitChallenge ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    IO (Either RelayError ())
awaitChallenge link channel request offer = do
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
    IO (Either RelayError ())
serveUntilDone state link channel request = do
    next <- receive channel
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
            | otherwise -> serveMessage state link channel request message

serveMessage ::
    ParentRelayState ->
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveMessage state link channel request message = case (state, protocolMessageTag message) of
    (ParentAwaitingAcceptance expectedDigest childFrame, AcceptedTag) ->
        case protocolMessageFields message of
            [actualDigest]
                | actualDigest == expectedDigest ->
                    serveUntilDone (ParentServingAdmittedChild childFrame) link channel request
                | otherwise ->
                    refuse
                        channel
                        request
                        ( RelayHandoffFailure
                            (HandoffBindingMismatch "the child accepted a different config digest")
                        )
            fields -> refuse channel request (RelayMalformedMessage AcceptedTag (length fields))
    (_, RefusedTag) -> pure (Left (refusalFrom message))
    (ParentServingAdmittedChild _, CompletedTag) ->
        case protocolMessageFields message of
            ["ok"] -> pure (Right ())
            [_] ->
                refuse
                    channel
                    request
                    ( RelayHandoffFailure
                        (HandoffBindingMismatch "the child sent an unknown completion status")
                    )
            fields -> refuse channel request (RelayMalformedMessage CompletedTag (length fields))
    (ParentServingAdmittedChild childFrame, OfferRequestTag) ->
        continueAfter childFrame (serveOpen childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, GrantRequestTag) ->
        continueAfter childFrame (serveGrant childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, ActivationSignRequestTag) ->
        continueAfter childFrame (serveActivationSigning childFrame link channel request message)
    (ParentServingAdmittedChild childFrame, RecoveryRequestTag) ->
        continueAfter childFrame (serveRecoverySigning childFrame link channel request message)
    (_, tag) -> refuse channel request (RelayUnexpectedMessage tag)
  where
    continueAfter childFrame served = do
        outcome <- served
        either
            (pure . Left)
            (const (serveUntilDone (ParentServingAdmittedChild childFrame) link channel request))
            outcome

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
        Right (path, raw) -> case handoffBindingInputFromWire raw of
            Left failure -> refuse channel request (RelayHandoffFailure failure)
            Right input -> case requireServedRequester childFrame (requestedParentFrame input) path of
                Left failure -> refuse channel request failure
                Right () -> do
                    opened <- linkOpenRaw link path input
                    case opened of
                        Left failure -> refuse channel request failure
                        Right (relay, token) ->
                            transmit
                                channel
                                OfferResponseTag
                                request
                                [ frameWire (renderHandoffBinding (relayBinding relay))
                                    <> frameWire (handoffTokenBytes token)
                                ]
    fields -> refuse channel request (RelayMalformedMessage OfferRequestTag (length fields))

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
        Right (path, bindingBytes) -> case recoveryParentFromWire bindingBytes of
            Left failure -> refuse channel request failure
            Right parentFrame -> case requireServedRequester childFrame parentFrame path of
                Left failure -> refuse channel request failure
                Right () -> do
                    signed <- linkRecoveryFieldsRaw link path [bindingBytes, wire]
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
    (payload, afterPayload) <- fromHandoff (takeHandoffFrame offerWire)
    (tokenFrame, afterToken) <- fromHandoff (takeHandoffFrame afterPayload)
    (bindingBytes, trailing) <- fromHandoff (takeHandoffFrame afterToken)
    if not (ByteString.null trailing)
        then Left (RelayMalformedMessage GrantRequestTag 2)
        else do
            relay <- fromHandoff (brokerRelayFromRouteWire route Nothing bindingBytes)
            token <- fromHandoff (handoffTokenFromBytes tokenFrame)
            offer <- fromHandoff (mkHandoffOffer relay payload token)
            challenge <- fromHandoff (handoffChallengeFromBytes challengeRaw)
            pure (offer, challenge)

-- ---------------------------------------------------------------------------
-- Channel plumbing

offerFieldsOf :: HandoffOffer scope brokerGeneration -> ByteString -> [ByteString]
offerFieldsOf offer keyDigest = [payload, token, binding, keyDigest]
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

{- | Receive the exact tag and request identity this exchange expects.

An unexpected, malformed, or cross-request response is actively refused while
the peer is waiting, rather than being reduced to a local return followed by
EOF.
-}
await :: HandoffChannel -> Word64 -> ProtocolTag -> IO (Either RelayError [ByteString])
await channel request expected = do
    received <- receive channel
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

fromHandoff :: Either HandoffError a -> Either RelayError a
fromHandoff = either (Left . RelayHandoffFailure) Right

splitPair :: ByteString -> Either RelayError (ByteString, ByteString)
splitPair raw = do
    (first, rest) <- fromHandoff (takeHandoffFrame raw)
    (second, trailing) <- fromHandoff (takeHandoffFrame rest)
    if ByteString.null trailing
        then Right (first, second)
        else Left (RelayMalformedMessage OfferResponseTag 1)
