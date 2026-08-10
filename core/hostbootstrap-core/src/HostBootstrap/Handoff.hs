{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The authenticated cross-frame handoff transport (§ X, § EE, the operator-root-and-command-authority phase).

A parent frame that descends into a VM, container, or pod must give the child
its narrowed config. The mechanism this replaces was a shell writer: the parent
put the rendered payload on the lift's @stdin@ and overrode the container
entrypoint with @sh -c "cat > \<sibling\> && exec \<binary\> …"@. That delivers
bytes, but it authenticates nothing — whatever arrives on @stdin@ becomes the
child's config, and the child cannot tell a parent-rendered projection from
anything else that reached the same pipe.

The transport here is the authenticated peer:

* every handoff is bound to one exact 'HandoffBinding' — installed project,
  spec and config digests, payload kind, scope, plan revision, broker
  generation, parent→child frame edge, verb\/phase, and a commitment to the
  one-time token. Bindings are rendered with length-prefixed fields, so two
  different bindings cannot render to the same bytes;
* the **root** invocation owns the long-lived, independently installed project
  signing identity ('RootBroker'). Immediate parents get only a keyless
  'BrokerRelay': they can carry an offer and relay a grant request, and they
  cannot sign, delegate, or mint one themselves;
* the child's receiver mints a **fresh** 'HandoffChallenge' and the root signs
  over it, the exact framed token, the canonical binding, the signer identity,
  and the protocol domain\/version, so a recorded transcript cannot be replayed
  or spliced into another protocol;
* the offer's one-time token is consumed by a protected compare-and-swap at the
  root before the grant is issued. Child verification is deliberately
  stateless: a child store can never become the authority for a root token;
* verification recomputes the config digest from the bytes **actually
  received**, and takes the verification key as a separate installed input. A
  key carried in the envelope is never consulted.

Nothing here reads or writes @argv@ or the environment, and no value in this
module is representable in Dhall.
-}
module HostBootstrap.Handoff (
    -- * Bounded duplex protocol
    module HostBootstrap.Handoff.Protocol,

    -- * Length-delimited framing
    frameWire,
    unframeWire,
    takeHandoffFrame,
    maxWireBytes,
    handoffProtocolVersion,

    -- * The exact binding a handoff authenticates
    HandoffScope,
    productionHandoffScope,
    harnessHandoffScope,
    handoffScopeProject,
    handoffScopeTag,
    productionScopeTag,
    harnessScopeTagFor,
    HandoffPayloadKind (..),
    HandoffBindingInput (..),
    renderHandoffBindingInput,
    handoffBindingInputFromWire,
    HandoffBinding,
    mkHandoffBinding,
    handoffInstalledProject,
    handoffSpecDigest,
    handoffPayloadKind,
    handoffScope,
    handoffStoreIdentity,
    handoffPlanRevision,
    handoffBrokerGeneration,
    handoffParentFrame,
    handoffChildFrame,
    handoffChildConfigDigest,
    handoffVerb,
    handoffPhase,
    handoffTokenCommitment,
    renderHandoffBinding,
    withHandoffBindingFromWire,
    childConfigDigest,

    -- * Recovery-wire projection
    RecoveryHandoff,
    RecoveryProjectionBindingInput,
    requestedRecoveryPlanDigest,
    requestedRecoveryParentFrame,
    requestedRecoveryChildFrame,
    withRecoveryProjectionBindingInput,
    RecoveryProjectionBinding,
    mkRecoveryProjectionBinding,
    mkRecoveryProjectionBindingFromRoute,
    renderRecoveryProjectionBinding,
    recoveryProjectionBindingFromWire,
    recoveryRequestFields,
    recoveryRequestFromFields,
    RecoveryWireGrant,
    recoveryWireGrantSignature,
    recoveryWireGrantFromSignature,
    recoveryResponseFields,
    recoveryResponseFromFields,
    signRecoveryWire,
    signAdmittedRecoveryWire,
    VerifiedRecoveryWire,
    verifiedRecoveryWireBytes,
    withVerifiedRecoveryWire,
    VerifiedRecoveryHandoff,
    withVerifiedRecoveryHandoff,
    recoveryWireDigest,

    -- * Independently installed project identity
    ProjectSigningKey,
    projectSigningKeyFromBytes,
    installedProjectSigningKey,
    projectSigningVerificationKey,
    ProjectVerificationKey,
    installedVerificationKey,
    verificationKeyBytes,
    verificationKeyDigest,

    -- * The root broker and its keyless relay
    RootBroker,
    withRootBroker,
    rootBrokerVerificationKey,
    BrokerRoute,
    rootBrokerRoute,
    verifiedHandoffRoute,
    brokerRouteVerificationKeyDigest,
    brokerRouteCurrentFrame,
    BrokerRelay,
    brokerRelay,
    brokerRelayFromRouteWire,
    relayBinding,
    registerHandoffEdge,
    registerAdmittedHandoffEdge,

    -- * Offer, challenge, grant
    HandoffToken,
    freshHandoffToken,
    handoffTokenBytes,
    handoffTokenFromBytes,
    HandoffOffer,
    mkHandoffOffer,
    handoffOfferWire,
    handoffOfferFrames,
    handoffOfferBinding,
    HandoffChallenge,
    freshChallenge,
    challengeBytes,
    handoffChallengeFromBytes,
    HandoffGrant,
    grantSignature,
    handoffGrantFromSignature,
    grantHandoff,

    -- * Verified results
    VerifiedHandoff,
    verifiedHandoffBinding,
    verifiedHandoffPayload,
    verifyHandoff,
    AuthenticatedConfigPayload,
    verifiedConfigPayload,
    authenticatedConfigDigest,
    authenticatedConfigBytes,

    -- * Failures
    HandoffError (..),
    handoffErrorMessage,
) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (SomeException, evaluate, finally, try)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray (convert)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb,
    RootInvocationAuthority,
    brokerEpochWord,
    installedProjectName,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
 )
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity)
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    Production,
    harnessRunName,
 )
import HostBootstrap.Handoff.Protocol
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    readProtectedRecord,
    withProtectedEntry,
 )
import System.Directory (doesFileExist)

-- ---------------------------------------------------------------------------
-- Framing

{- | The largest wire a receiver will accept. A declared length beyond this is
refused before any allocation, so a hostile length prefix cannot ask the
receiver to reserve an arbitrary buffer.
-}
maxWireBytes :: Word64
maxWireBytes = 8 * 1024 * 1024

-- | The protocol version included in every grant signature.
handoffProtocolVersion :: Word64
handoffProtocolVersion = 1

handoffGrantDomain :: ByteString
handoffGrantDomain = "hostbootstrap/handoff-grant"

{- | Length-delimit a payload: an 8-byte big-endian length followed by exactly
that many bytes. Framing is what lets the receiver know a message ended rather
than inferring it from a closed pipe.
-}
frameWire :: ByteString -> ByteString
frameWire payload =
    ByteString.pack (word64BigEndian (fromIntegral (ByteString.length payload)))
        <> payload

{- | Read exactly one framed payload, and require the frame to be the whole
input. Truncation, a short header, trailing bytes after the declared length, and
an oversized declared length are each a distinct refusal rather than a partial
read.
-}
unframeWire :: ByteString -> Either HandoffError ByteString
unframeWire raw
    | ByteString.length raw < 8 =
        Left (HandoffWireTruncated 8 (ByteString.length raw))
    | declared > maxWireBytes =
        Left (HandoffWireTooLarge declared maxWireBytes)
    | fromIntegral (ByteString.length body) < declared =
        Left (HandoffWireTruncated (fromIntegral declared) (ByteString.length body))
    | not (ByteString.null trailing) =
        Left (HandoffWireTrailingBytes (ByteString.length trailing))
    | otherwise = Right payload
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)
    (payload, trailing) = ByteString.splitAt (fromIntegral declared) body

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value =
    [fromIntegral ((value `shiftR` shift) .&. 0xff) | shift <- [56, 48, 40, 32, 24, 16, 8, 0]]

bigEndianWord64 :: [Word8] -> Word64
bigEndianWord64 = foldl (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte) 0

-- ---------------------------------------------------------------------------
-- Bindings

{- | Opaque typed evidence for the exact config scope a root may hand off.

Production evidence comes from the installed project identity. Harness
evidence additionally requires the generative authority minted only by the
matching acquired Harness root. Callers never supply a descriptive scope tag.
-}
data HandoffScope scope where
    ProductionHandoffScope ::
        InstalledProjectIdentity projectId ->
        HandoffScope (Production projectId)
    HarnessHandoffScope ::
        InstalledProjectIdentity projectId ->
        HarnessAuthority projectId runId ->
        HandoffScope (Harness projectId runId)

type role HandoffScope nominal

-- | Narrow an installed project identity to Production handoff scope.
productionHandoffScope :: InstalledProjectIdentity projectId -> HandoffScope (Production projectId)
productionHandoffScope = ProductionHandoffScope

-- | Narrow an acquired Harness root's authority to its exact run scope.
harnessHandoffScope ::
    InstalledProjectIdentity projectId ->
    HarnessAuthority projectId runId ->
    HandoffScope (Harness projectId runId)
harnessHandoffScope = HarnessHandoffScope

handoffScopeProject :: HandoffScope scope -> Text
handoffScopeProject (ProductionHandoffScope project) = installedProjectName project
handoffScopeProject (HarnessHandoffScope project _) = installedProjectName project

{- | The descriptive tag a Production binding carries in its scope field.

Exported because a receiving frame states the scope it expects before it has
any config: the tag is what its declaration is compared against, and one
encoding must serve both sides.
-}
productionScopeTag :: Text
productionScopeTag = "Production"

-- | The descriptive tag a Harness binding carries for one named run.
harnessScopeTagFor :: Text -> Text
harnessScopeTagFor runName = "Harness " <> runName

handoffScopeTag :: HandoffScope scope -> Text
handoffScopeTag (ProductionHandoffScope _) = productionScopeTag
handoffScopeTag (HarnessHandoffScope _ authority) = harnessScopeTagFor (harnessRunName authority)

{- | The exact tuple a handoff token and grant are bound to.

Everything that distinguishes one legitimate handoff from another lives here, so
a grant for one edge cannot authorize a different one. In particular the
@parent -> child@ frame pair is part of the signed material: a sibling frame
cannot present a grant minted for its peer.
-}
data HandoffPayloadKind
    = NarrowedProjectConfig
    | RecoveryAdapterWire
    deriving (Eq, Ord, Show)

handoffPayloadKindName :: HandoffPayloadKind -> Text
handoffPayloadKindName NarrowedProjectConfig = "narrowed-project-config"
handoffPayloadKindName RecoveryAdapterWire = "recovery-adapter-wire"

{- | Public, non-authorizing inputs for a handoff binding.

The token commitment is intentionally absent. 'mkHandoffBinding' derives it
from an opaque, freshly minted 'HandoffToken', so callers cannot accidentally
describe one token and transmit another.
-}
data HandoffBindingInput = HandoffBindingInput
    { requestedSpecDigest :: Text
    , requestedPayloadKind :: HandoffPayloadKind
    , requestedPlanRevision :: Text
    , requestedParentFrame :: Text
    , requestedChildFrame :: Text
    , requestedChildConfigDigest :: Text
    , requestedPhase :: Text
    }
    deriving (Eq, Show)

data HandoffBinding scope brokerGeneration = HandoffBinding
    { handoffInstalledProject :: Text
    , handoffSpecDigest :: Text
    , handoffPayloadKind :: HandoffPayloadKind
    , handoffScope :: Text
    -- ^ the descriptive scope tag (@Production@ or @Harness \<runId\>@)
    , handoffStoreIdentity :: Text
    -- ^ the durable protected-store identity that owns the root broker
    , handoffPlanRevision :: Text
    , handoffBrokerGeneration :: Word64
    , handoffParentFrame :: Text
    , handoffChildFrame :: Text
    , handoffChildConfigDigest :: Text
    , handoffVerb :: Text
    , handoffPhase :: Text
    , handoffTokenCommitment :: Text
    }
    deriving (Eq)

type role HandoffBinding nominal nominal

instance Show (HandoffBinding scope brokerGeneration) where
    show binding =
        "HandoffBinding {project = "
            <> show (handoffInstalledProject binding)
            <> ", payloadKind = "
            <> show (handoffPayloadKind binding)
            <> ", store = "
            <> show (handoffStoreIdentity binding)
            <> ", parentFrame = "
            <> show (handoffParentFrame binding)
            <> ", childFrame = "
            <> show (handoffChildFrame binding)
            <> ", verb = "
            <> show (handoffVerb binding)
            <> ", phase = "
            <> show (handoffPhase binding)
            <> ", digests = <redacted>, token = <redacted>}"

-- | Build the canonical binding for one freshly minted token.
mkHandoffBinding ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    HandoffToken ->
    Either HandoffError (HandoffBinding scope brokerGeneration)
mkHandoffBinding broker input token = do
    requireBindingField "spec digest" (requestedSpecDigest input)
    requireBindingField "plan revision" (requestedPlanRevision input)
    requireBindingField "parent frame" (requestedParentFrame input)
    requireBindingField "child frame" (requestedChildFrame input)
    requireBindingField "child config digest" (requestedChildConfigDigest input)
    requireBindingField "phase" (requestedPhase input)
    pure
        HandoffBinding
            { handoffInstalledProject = brokerProjectName broker
            , handoffSpecDigest = requestedSpecDigest input
            , handoffPayloadKind = requestedPayloadKind input
            , handoffScope = brokerScopeTag broker
            , handoffStoreIdentity = brokerStoreIdentity broker
            , handoffPlanRevision = requestedPlanRevision input
            , handoffBrokerGeneration = brokerEpochValue broker
            , handoffParentFrame = requestedParentFrame input
            , handoffChildFrame = requestedChildFrame input
            , handoffChildConfigDigest = requestedChildConfigDigest input
            , handoffVerb = brokerVerbName broker
            , handoffPhase = requestedPhase input
            , handoffTokenCommitment = tokenCommitment token
            }

{- | Canonical bytes for the *request* to open an edge.

A frame that is not the root cannot open one itself, so it describes the edge it
needs and asks upward. That description is public: it names frames, a phase, and
digests, and it carries no token, key, or authority. The root re-derives every
field it owns — project, scope, generation, verb — from its own typed evidence,
so the description can influence only what it is entitled to influence.
-}
renderHandoffBindingInput :: HandoffBindingInput -> ByteString
renderHandoffBindingInput input =
    ByteString.concat
        [ field (requestedSpecDigest input)
        , field (handoffPayloadKindName (requestedPayloadKind input))
        , field (requestedPlanRevision input)
        , field (requestedParentFrame input)
        , field (requestedChildFrame input)
        , field (requestedChildConfigDigest input)
        , field (requestedPhase input)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- | Parse an edge-opening request. The exact inverse of 'renderHandoffBindingInput'.
handoffBindingInputFromWire :: ByteString -> Either HandoffError HandoffBindingInput
handoffBindingInputFromWire raw = do
    (specDigest, afterSpec) <- bindingTextField raw
    (kindName, afterKind) <- bindingTextField afterSpec
    (planRevision, afterRevision) <- bindingTextField afterKind
    (parentFrame, afterParent) <- bindingTextField afterRevision
    (childFrame, afterChild) <- bindingTextField afterParent
    (configDigest, afterConfig) <- bindingTextField afterChild
    (phase, trailing) <- bindingTextField afterConfig
    if not (ByteString.null trailing)
        then Left (HandoffWireTrailingBytes (ByteString.length trailing))
        else do
            kind <- payloadKindFromName kindName
            pure
                HandoffBindingInput
                    { requestedSpecDigest = specDigest
                    , requestedPayloadKind = kind
                    , requestedPlanRevision = planRevision
                    , requestedParentFrame = parentFrame
                    , requestedChildFrame = childFrame
                    , requestedChildConfigDigest = configDigest
                    , requestedPhase = phase
                    }

requireBindingField :: Text -> Text -> Either HandoffError ()
requireBindingField name value
    | Text.null value = Left (HandoffBindingMismatch (name <> " must not be empty"))
    | otherwise = Right ()

{- | Canonical bytes for a binding.

Each field is length-prefixed rather than separator-joined. With a separator, a
parent frame named @"a-b"@ and child @"c"@ would render identically to parent
@"a"@ and child @"b-c"@, and one grant would authenticate two different edges.
Length prefixes make the field boundaries unambiguous.
-}
renderHandoffBinding :: HandoffBinding scope brokerGeneration -> ByteString
renderHandoffBinding binding =
    ByteString.concat
        [ field (handoffInstalledProject binding)
        , field (handoffSpecDigest binding)
        , field (handoffPayloadKindName (handoffPayloadKind binding))
        , field (handoffScope binding)
        , field (handoffStoreIdentity binding)
        , field (handoffPlanRevision binding)
        , frameWire (ByteString.pack (word64BigEndian (handoffBrokerGeneration binding)))
        , field (handoffParentFrame binding)
        , field (handoffChildFrame binding)
        , field (handoffChildConfigDigest binding)
        , field (handoffVerb binding)
        , field (handoffPhase binding)
        , field (handoffTokenCommitment binding)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

{- | Parse canonical binding bytes only under independently obtained scope
evidence.

The broker generation read from the wire is introduced only inside the rank-2
continuation. A caller therefore cannot choose @scope@ or @brokerGeneration@
phantoms for descriptive bytes and then ask 'verifyHandoff' to authenticate
that relabelling. The opaque 'HandoffScope' also fixes the expected installed
project and descriptive scope tag before the parsed value is exposed.
-}
withHandoffBindingFromWire ::
    HandoffScope scope ->
    ByteString ->
    (forall brokerGeneration. HandoffBinding scope brokerGeneration -> result) ->
    Either HandoffError result
withHandoffBindingFromWire scope raw use = do
    binding <- decodeHandoffBinding raw
    if handoffInstalledProject binding /= handoffScopeProject scope
        then Left (HandoffBindingMismatch "the received binding names a different installed project than the fixed handoff scope")
        else
            if handoffScope binding /= handoffScopeTag scope
                then Left (HandoffBindingMismatch "the received binding names a different scope than the fixed handoff scope")
                else Right (use binding)

{- | Structural decoder used only behind a refinement that already fixes the
result's authority indices. Keeping it private is essential: a polymorphic
@ByteString -> HandoffBinding scope brokerGeneration@ would let the caller
select those phantoms.
-}
decodeHandoffBinding ::
    ByteString ->
    Either HandoffError (HandoffBinding scope brokerGeneration)
decodeHandoffBinding raw = do
    (project, afterProject) <- bindingTextField raw
    (specDigest, afterSpec) <- bindingTextField afterProject
    (kindName, afterKind) <- bindingTextField afterSpec
    (scope, afterScope) <- bindingTextField afterKind
    (storeIdentity, afterStore) <- bindingTextField afterScope
    (planRevision, afterRevision) <- bindingTextField afterStore
    (generationBytes, afterGeneration) <- takeFrame afterRevision
    (parentFrame, afterParent) <- bindingTextField afterGeneration
    (childFrame, afterChild) <- bindingTextField afterParent
    (configDigest, afterConfig) <- bindingTextField afterChild
    (verb, afterVerb) <- bindingTextField afterConfig
    (phase, afterPhase) <- bindingTextField afterVerb
    (commitment, trailing) <- bindingTextField afterPhase
    if not (ByteString.null trailing)
        then Left (HandoffWireTrailingBytes (ByteString.length trailing))
        else do
            kind <- payloadKindFromName kindName
            generation <- bindingGenerationField generationBytes
            requireBindingField "installed project" project
            requireBindingField "spec digest" specDigest
            requireBindingField "scope" scope
            requireBindingField "protected store identity" storeIdentity
            requireBindingField "plan revision" planRevision
            requireBindingField "parent frame" parentFrame
            requireBindingField "child frame" childFrame
            requireBindingField "child config digest" configDigest
            requireBindingField "verb" verb
            requireBindingField "phase" phase
            requireBindingField "token commitment" commitment
            pure
                HandoffBinding
                    { handoffInstalledProject = project
                    , handoffSpecDigest = specDigest
                    , handoffPayloadKind = kind
                    , handoffScope = scope
                    , handoffStoreIdentity = storeIdentity
                    , handoffPlanRevision = planRevision
                    , handoffBrokerGeneration = generation
                    , handoffParentFrame = parentFrame
                    , handoffChildFrame = childFrame
                    , handoffChildConfigDigest = configDigest
                    , handoffVerb = verb
                    , handoffPhase = phase
                    , handoffTokenCommitment = commitment
                    }

bindingTextField :: ByteString -> Either HandoffError (Text, ByteString)
bindingTextField raw = do
    (bytes, rest) <- takeFrame raw
    case TextEncoding.decodeUtf8' bytes of
        Left _ -> Left (HandoffBindingMismatch "a binding field is not valid UTF-8")
        Right value -> Right (value, rest)

bindingGenerationField :: ByteString -> Either HandoffError Word64
bindingGenerationField bytes
    | ByteString.length bytes /= 8 =
        Left (HandoffBindingMismatch "the binding's broker generation is not a 64-bit field")
    | otherwise = Right (bigEndianWord64 (ByteString.unpack bytes))

payloadKindFromName :: Text -> Either HandoffError HandoffPayloadKind
payloadKindFromName name
    | name == handoffPayloadKindName NarrowedProjectConfig = Right NarrowedProjectConfig
    | name == handoffPayloadKindName RecoveryAdapterWire = Right RecoveryAdapterWire
    | otherwise = Left (HandoffBindingMismatch ("unknown handoff payload kind " <> name))

-- ---------------------------------------------------------------------------
-- Recovery projection

-- | Constructor-hidden recovery payload discriminator.
data RecoveryHandoff

-- | Public coordinates; project, scope, and wire digest are root-derived.
data RecoveryProjectionBindingInput planDigest parentFrame childFrame = RecoveryProjectionBindingInput
    { requestedRecoveryPlanDigest :: Text
    , requestedRecoveryParentFrame :: Text
    , requestedRecoveryChildFrame :: Text
    }
    deriving (Eq, Show)

type role RecoveryProjectionBindingInput nominal nominal nominal

{- | Introduce descriptive recovery coordinates under fresh, unselectable
plan/frame indices.

The record constructor is private. Text received from a peer therefore cannot
be labelled as a caller-chosen plan or frame; an eventual Phase 17 producer may
add a separate constructor that consumes exact plan-derived evidence, while
this wire-facing bracket remains generative.
-}
withRecoveryProjectionBindingInput ::
    Text ->
    Text ->
    Text ->
    ( forall planDigest parentFrame childFrame.
      RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
      result
    ) ->
    Either HandoffError result
withRecoveryProjectionBindingInput planDigest parentFrame childFrame use = do
    requireBindingField "recovery plan digest" planDigest
    requireBindingField "recovery parent frame" parentFrame
    requireBindingField "recovery child frame" childFrame
    Right
        ( use
            RecoveryProjectionBindingInput
                { requestedRecoveryPlanDigest = planDigest
                , requestedRecoveryParentFrame = parentFrame
                , requestedRecoveryChildFrame = childFrame
                }
        )

-- | Constructor-hidden identity of one parent-to-child recovery wire.
data RecoveryProjectionBinding scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest
    = RecoveryProjectionBinding
    { recoveryProjectionInstalledProject :: Text
    , recoveryProjectionScope :: Text
    , recoveryProjectionStoreIdentity :: Text
    , recoveryProjectionBrokerGeneration :: Word64
    , recoveryProjectionVerb :: Text
    , recoveryProjectionPlanDigest :: Text
    , recoveryProjectionParentFrame :: Text
    , recoveryProjectionChildFrame :: Text
    , recoveryProjectionWireDigest :: Text
    }
    deriving (Eq)

type role RecoveryProjectionBinding nominal nominal nominal nominal nominal nominal nominal

-- | Construct an indexed projection inside a rank-2 scope owned by the root.
mkRecoveryProjectionBinding ::
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
      result
    ) ->
    Either HandoffError result
mkRecoveryProjectionBinding broker input wire use = do
    requireBindingField "recovery plan digest" (requestedRecoveryPlanDigest input)
    requireBindingField "recovery parent frame" (requestedRecoveryParentFrame input)
    requireBindingField "recovery child frame" (requestedRecoveryChildFrame input)
    if ByteString.null wire
        then Left (HandoffBindingMismatch "the recovery adapter wire must not be empty")
        else
            pure
                ( use
                    RecoveryProjectionBinding
                        { recoveryProjectionInstalledProject = brokerProjectName broker
                        , recoveryProjectionScope = brokerScopeTag broker
                        , recoveryProjectionStoreIdentity = brokerStoreIdentity broker
                        , recoveryProjectionBrokerGeneration = brokerEpochValue broker
                        , recoveryProjectionVerb = brokerVerbName broker
                        , recoveryProjectionPlanDigest = requestedRecoveryPlanDigest input
                        , recoveryProjectionParentFrame = requestedRecoveryParentFrame input
                        , recoveryProjectionChildFrame = requestedRecoveryChildFrame input
                        , recoveryProjectionWireDigest = recoveryWireDigest wire
                        }
                )

{- | Construct a descriptive recovery projection from an already authenticated
route rather than from the live root broker.

This is the keyless nested-frame constructor. The opaque route fixes project,
scope, protected-store identity, and broker generation; the closed verb
evidence must name the route's authenticated runtime verb. The result still
authorizes nothing until the root signs it.
-}
mkRecoveryProjectionBindingFromRoute ::
    ProjectVerb verb ->
    BrokerRoute scope brokerGeneration ->
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
      result
    ) ->
    Either HandoffError result
mkRecoveryProjectionBindingFromRoute verb route input wire use = do
    requireBindingField "recovery plan digest" (requestedRecoveryPlanDigest input)
    requireBindingField "recovery parent frame" (requestedRecoveryParentFrame input)
    requireBindingField "recovery child frame" (requestedRecoveryChildFrame input)
    if projectVerbName verb /= routeVerb route
        then
            Left
                ( HandoffBindingMismatch
                    "the recovery verb evidence does not match the authenticated broker route"
                )
        else
            if ByteString.null wire
                then Left (HandoffBindingMismatch "the recovery adapter wire must not be empty")
                else
                    Right
                        ( use
                            RecoveryProjectionBinding
                                { recoveryProjectionInstalledProject = routeInstalledProject route
                                , recoveryProjectionScope = routeScopeTag route
                                , recoveryProjectionStoreIdentity = routeStoreIdentity route
                                , recoveryProjectionBrokerGeneration = routeBrokerGeneration route
                                , recoveryProjectionVerb = routeVerb route
                                , recoveryProjectionPlanDigest = requestedRecoveryPlanDigest input
                                , recoveryProjectionParentFrame = requestedRecoveryParentFrame input
                                , recoveryProjectionChildFrame = requestedRecoveryChildFrame input
                                , recoveryProjectionWireDigest = recoveryWireDigest wire
                                }
                        )

-- | Canonical, length-delimited bytes for the exact recovery projection.
renderRecoveryProjectionBinding ::
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString
renderRecoveryProjectionBinding binding =
    ByteString.concat
        [ field (recoveryProjectionInstalledProject binding)
        , field (recoveryProjectionScope binding)
        , field (recoveryProjectionStoreIdentity binding)
        , frameWire
            ( ByteString.pack
                (word64BigEndian (recoveryProjectionBrokerGeneration binding))
            )
        , field (recoveryProjectionVerb binding)
        , field (recoveryProjectionPlanDigest binding)
        , field (recoveryProjectionParentFrame binding)
        , field (recoveryProjectionChildFrame binding)
        , field (recoveryProjectionWireDigest binding)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- | Parse non-authorizing canonical bytes under the live root's scope.
recoveryProjectionBindingFromWire ::
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
      result
    ) ->
    Either HandoffError result
recoveryProjectionBindingFromWire broker expected raw use = do
    (project, afterProject) <- bindingTextField raw
    (scope, afterScope) <- bindingTextField afterProject
    (storeIdentity, afterStore) <- bindingTextField afterScope
    (generationBytes, afterGeneration) <- takeFrame afterStore
    generation <- bindingGenerationField generationBytes
    (verb, afterVerb) <- bindingTextField afterGeneration
    (planDigest, afterPlan) <- bindingTextField afterVerb
    (parentFrame, afterParent) <- bindingTextField afterPlan
    (childFrame, afterChild) <- bindingTextField afterParent
    (wireDigest, trailing) <- bindingTextField afterChild
    if not (ByteString.null trailing)
        then Left (HandoffWireTrailingBytes (ByteString.length trailing))
        else do
            requireBindingField "recovery installed project" project
            requireBindingField "recovery scope" scope
            requireBindingField "recovery protected store identity" storeIdentity
            requireBindingField "recovery verb" verb
            requireBindingField "recovery plan digest" planDigest
            requireBindingField "recovery parent frame" parentFrame
            requireBindingField "recovery child frame" childFrame
            requireBindingField "recovery wire digest" wireDigest
            if or
                [ project /= brokerProjectName broker
                , scope /= brokerScopeTag broker
                , storeIdentity /= brokerStoreIdentity broker
                , generation /= brokerEpochValue broker
                , verb /= brokerVerbName broker
                , planDigest /= requestedRecoveryPlanDigest expected
                , parentFrame /= requestedRecoveryParentFrame expected
                , childFrame /= requestedRecoveryChildFrame expected
                ]
                then Left (HandoffBindingMismatch "the recovery projection does not match the expected root plan and edge")
                else
                    Right
                        ( use
                            RecoveryProjectionBinding
                                { recoveryProjectionInstalledProject = project
                                , recoveryProjectionScope = scope
                                , recoveryProjectionStoreIdentity = storeIdentity
                                , recoveryProjectionBrokerGeneration = generation
                                , recoveryProjectionVerb = verb
                                , recoveryProjectionPlanDigest = planDigest
                                , recoveryProjectionParentFrame = parentFrame
                                , recoveryProjectionChildFrame = childFrame
                                , recoveryProjectionWireDigest = wireDigest
                                }
                        )

-- | Exact request fields: canonical binding, then adapter wire.
recoveryRequestFields ::
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString ->
    Either HandoffError [ByteString]
recoveryRequestFields binding wire
    | recoveryWireDigest wire /= recoveryProjectionWireDigest binding =
        Left
            ( HandoffPayloadDigestMismatch
                (recoveryProjectionWireDigest binding)
                (recoveryWireDigest wire)
            )
    | otherwise = Right [renderRecoveryProjectionBinding binding, wire]

-- | Decode and validate the exact two fields carried by 'RecoveryRequestTag'.
recoveryRequestFromFields ::
    RootBroker scope brokerGeneration verb ->
    RecoveryProjectionBindingInput planDigest parentFrame childFrame ->
    [ByteString] ->
    ( forall recoveryWireDigest.
      RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
      ByteString ->
      result
    ) ->
    Either HandoffError result
recoveryRequestFromFields broker expected [bindingBytes, wire] use =
    either Left id $
        recoveryProjectionBindingFromWire broker expected bindingBytes $ \binding ->
            recoveryRequestFields binding wire >> Right (use binding wire)
recoveryRequestFromFields _ _ fields _ =
    Left (HandoffRecoveryFieldCount "request" 2 (length fields))

-- ---------------------------------------------------------------------------
-- Keys

{- | The root-only, long-lived project signing identity.

Its constructor and bytes are deliberately hidden. Provisioning code may load
the 32-byte Ed25519 seed from a protected file or validate provisioned bytes;
the receiving binary independently installs only the corresponding public key.
The offer and grant never carry either key.
-}
newtype ProjectSigningKey = ProjectSigningKey Ed25519.SecretKey

instance Show ProjectSigningKey where
    show _ = "ProjectSigningKey <redacted>"

-- | Validate a provisioned 32-byte Ed25519 signing seed.
projectSigningKeyFromBytes :: ByteString -> Either HandoffError ProjectSigningKey
projectSigningKeyFromBytes raw = case Ed25519.secretKey raw of
    CryptoFailed _ -> Left HandoffSigningKeyInvalid
    CryptoPassed key -> Right (ProjectSigningKey key)

{- | Load the root-only signing seed. Missing, unreadable, and malformed files
are typed refusals, and diagnostics never contain the file's contents.
-}
installedProjectSigningKey :: FilePath -> IO (Either HandoffError ProjectSigningKey)
installedProjectSigningKey path = do
    present <- doesFileExist path
    if not present
        then pure (Left (HandoffSigningKeyUnavailable ("no installed signing key at " <> Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
            pure $ case loaded of
                Left err ->
                    Left
                        ( HandoffSigningKeyUnavailable
                            ("failed to read " <> Text.pack path <> ": " <> firstLine (show err))
                        )
                Right raw -> projectSigningKeyFromBytes raw

{- | The project's public verification key, installed alongside the binary and
independent of any config.

It is deliberately *not* reachable from a 'HandoffOffer': a receiver that took
its verification key from the envelope would verify every well-formed forgery.
-}
newtype ProjectVerificationKey = ProjectVerificationKey Ed25519.PublicKey
    deriving (Eq)

instance Show ProjectVerificationKey where
    show _ = "ProjectVerificationKey <installed>"

-- | The raw public key bytes, for writing an installed key file.
verificationKeyBytes :: ProjectVerificationKey -> ByteString
verificationKeyBytes (ProjectVerificationKey key) = convert key

-- | Stable identity of the independently installed public key.
verificationKeyDigest :: ProjectVerificationKey -> Text
verificationKeyDigest = digestBytes . verificationKeyBytes

-- | Derive the public half for independent installation.
projectSigningVerificationKey :: ProjectSigningKey -> ProjectVerificationKey
projectSigningVerificationKey (ProjectSigningKey secret) =
    ProjectVerificationKey (Ed25519.toPublic secret)

{- | Load the installed verification key from an absolute path. A missing,
unreadable, or wrong-length key file is a typed refusal — never a silently
skipped verification.
-}
installedVerificationKey :: FilePath -> IO (Either HandoffError ProjectVerificationKey)
installedVerificationKey path = do
    present <- doesFileExist path
    if not present
        then pure (Left (HandoffVerificationKeyUnavailable ("no installed key at " <> Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
            pure $ case loaded of
                Left err ->
                    Left
                        ( HandoffVerificationKeyUnavailable
                            ("failed to read " <> Text.pack path <> ": " <> firstLine (show err))
                        )
                Right raw -> case Ed25519.publicKey raw of
                    CryptoFailed err ->
                        Left
                            ( HandoffVerificationKeyUnavailable
                                ("malformed key at " <> Text.pack path <> ": " <> Text.pack (show err))
                            )
                    CryptoPassed key -> Right (ProjectVerificationKey key)

{- | The root invocation's signing capability.

Constructed only by 'withRootBroker' from a verified
'RootInvocationAuthority'. The opaque value can be retained by its callback;
its operational lifetime is therefore enforced by the lock-held runtime guard:
every durable/signing operation on a retained broker refuses after the bracket,
and bracket finalization waits for any already-running operation before
expiring it. Its nominal indices prevent cross-scope, cross-generation, or
cross-verb coercion; they are not a claim that the value cannot be retained.
-}
data RootBroker scope brokerGeneration verb = RootBroker
    { brokerSecret :: Ed25519.SecretKey
    , brokerPublic :: Ed25519.PublicKey
    , brokerEpochValue :: Word64
    , brokerVerbName :: Text
    , brokerProjectName :: Text
    , brokerScopeTag :: Text
    , brokerStoreIdentity :: Text
    , brokerProtectedStore :: ProtectedStore
    , brokerLifetime :: MVar BrokerLifetime
    }

data BrokerLifetime
    = BrokerLifetimeActive
    | BrokerLifetimeExpired

type role RootBroker nominal nominal nominal

instance Show (RootBroker scope brokerGeneration verb) where
    show broker = "RootBroker <signing> " <> show (brokerEpochValue broker)

-- | The public half a child binary must have installed to verify this broker.
rootBrokerVerificationKey :: RootBroker scope brokerGeneration verb -> ProjectVerificationKey
rootBrokerVerificationKey = ProjectVerificationKey . brokerPublic

{- | Opaque identity of one route to a live root broker.

It retains only the root-owned coordinates needed to refine bindings returned
over a relay and the digest of the independently provisioned verification key.
It contains neither the signing key nor the protected store. A route can come
only from the live root or from an already verified parent handoff.
-}
data BrokerRoute scope brokerGeneration = BrokerRoute
    { routeInstalledProject :: Text
    , routeScopeTag :: Text
    , routeStoreIdentity :: Text
    , routeBrokerGeneration :: Word64
    , routeVerb :: Text
    , routeVerificationKeyDigest :: ByteString
    , routeCurrentFrame :: Maybe Text
    }

type role BrokerRoute nominal nominal

instance Show (BrokerRoute scope brokerGeneration) where
    show _ = "BrokerRoute <verified root identity>"

-- | Derive the route identity directly from the live root broker.
rootBrokerRoute :: RootBroker scope brokerGeneration verb -> BrokerRoute scope brokerGeneration
rootBrokerRoute broker =
    BrokerRoute
        { routeInstalledProject = brokerProjectName broker
        , routeScopeTag = brokerScopeTag broker
        , routeStoreIdentity = brokerStoreIdentity broker
        , routeBrokerGeneration = brokerEpochValue broker
        , routeVerb = brokerVerbName broker
        , routeVerificationKeyDigest =
            TextEncoding.encodeUtf8
                (verificationKeyDigest (rootBrokerVerificationKey broker))
        , routeCurrentFrame = Nothing
        }

-- | The installed verification-key digest a child offer advertises.
brokerRouteVerificationKeyDigest :: BrokerRoute scope brokerGeneration -> ByteString
brokerRouteVerificationKeyDigest = routeVerificationKeyDigest

-- | The authenticated frame holding a relayed route; absent only at the root.
brokerRouteCurrentFrame :: BrokerRoute scope brokerGeneration -> Maybe Text
brokerRouteCurrentFrame = routeCurrentFrame

{- | Run an action with the independently provisioned project signer, narrowed
to one verified root invocation's project, epoch, and verb.

The resulting broker exists only inside the continuation. Unlike the previous
ephemeral-key design, a child can authenticate it against a public key that was
installed independently of this invocation and its handoff envelope.
-}
withRootBroker ::
    HandoffScope scope ->
    ProtectedStore ->
    ProjectSigningKey ->
    RootInvocationAuthority scope brokerGeneration verb ->
    (RootBroker scope brokerGeneration verb -> IO result) ->
    IO (Either HandoffError result)
withRootBroker scope store (ProjectSigningKey secret) root use
    | handoffScopeProject scope /= rootAuthorityProjectName root =
        pure (Left (HandoffBindingMismatch "the scope evidence names a different installed project than the root authority"))
    | storeIdentity /= rootAuthorityStoreIdentity root =
        pure (Left (HandoffBindingMismatch "the protected store does not belong to the root authority"))
    | otherwise = do
        lifetime <- newMVar BrokerLifetimeActive
        let broker =
                RootBroker
                    { brokerSecret = secret
                    , brokerPublic = Ed25519.toPublic secret
                    , brokerEpochValue = brokerEpochWord (rootAuthorityEpoch root)
                    , brokerVerbName = projectVerbName (rootAuthorityVerb root)
                    , brokerProjectName = rootAuthorityProjectName root
                    , brokerScopeTag = handoffScopeTag scope
                    , brokerStoreIdentity = storeIdentity
                    , brokerProtectedStore = store
                    , brokerLifetime = lifetime
                    }
        result <- use broker `finally` expireRootBroker broker
        pure (Right result)
  where
    storeIdentity = protectedStoreIdentityText (protectedStoreIdentity store)

withActiveRootBroker ::
    RootBroker scope brokerGeneration verb ->
    IO (Either HandoffError result) ->
    IO (Either HandoffError result)
withActiveRootBroker broker action =
    modifyMVar (brokerLifetime broker) $ \lifetime -> case lifetime of
        BrokerLifetimeExpired ->
            pure (BrokerLifetimeExpired, Left HandoffBrokerExpired)
        BrokerLifetimeActive -> do
            result <- action
            pure (BrokerLifetimeActive, result)

expireRootBroker :: RootBroker scope brokerGeneration verb -> IO ()
expireRootBroker broker =
    modifyMVar_ (brokerLifetime broker) (const (pure BrokerLifetimeExpired))

-- ---------------------------------------------------------------------------
-- Recovery-wire signing

recoveryWireDomain :: ByteString
recoveryWireDomain = "hostbootstrap/recovery-wire/v1"

-- | Opaque recovery-domain signature; response bytes are not verification.
newtype RecoveryWireGrant scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest
    = RecoveryWireGrant ByteString
    deriving (Eq)

type role RecoveryWireGrant nominal nominal nominal nominal nominal nominal nominal

-- | Exact signature bytes carried by 'RecoveryResponseTag'.
recoveryWireGrantSignature ::
    RecoveryWireGrant
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString
recoveryWireGrantSignature (RecoveryWireGrant signature) = signature

-- | Structurally adopt a response; cryptographic verification remains separate.
recoveryWireGrantFromSignature ::
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString ->
    Either
        HandoffError
        ( RecoveryWireGrant
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest
        )
recoveryWireGrantFromSignature binding signature
    | ByteString.length signature /= recoverySignatureBytes =
        Left (HandoffRecoverySignatureLength recoverySignatureBytes (ByteString.length signature))
    | otherwise = binding `seq` Right (RecoveryWireGrant signature)

recoverySignatureBytes :: Int
recoverySignatureBytes = 64

-- | The exact one field of 'RecoveryResponseTag'.
recoveryResponseFields ::
    RecoveryWireGrant
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    [ByteString]
recoveryResponseFields grant = [recoveryWireGrantSignature grant]

-- | Decode the exact one field carried by 'RecoveryResponseTag'.
recoveryResponseFromFields ::
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    [ByteString] ->
    Either
        HandoffError
        ( RecoveryWireGrant
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest
        )
recoveryResponseFromFields binding [signature] = recoveryWireGrantFromSignature binding signature
recoveryResponseFromFields _ fields =
    Left (HandoffRecoveryFieldCount "response" 1 (length fields))

-- | Sign under a recovery-only domain after root identity and digest checks.
signRecoveryWire ::
    RootBroker scope brokerGeneration verb ->
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
            HandoffError
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
signRecoveryWire broker binding wire =
    withActiveRootBroker broker (signRecoveryWireActive broker binding wire)

{- | Run a recovery-plan admission decision and, only when it admits, sign
under one uninterrupted broker-lifetime guard.

The nested result keeps a plan refusal distinct from a broker or binding
failure. Most callers use 'signRecoveryWire'; the relay uses this compound
operation so an escaped root link cannot run its admission callback after the
broker bracket has expired.
-}
signAdmittedRecoveryWire ::
    RootBroker scope brokerGeneration verb ->
    IO (Either rejection ()) ->
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
            HandoffError
            ( Either
                rejection
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
        )
signAdmittedRecoveryWire broker admission binding wire =
    withActiveRootBroker broker $ do
        admitted <- admission
        case admitted of
            Left rejection -> pure (Right (Left rejection))
            Right () -> fmap (fmap Right) (signRecoveryWireActive broker binding wire)

signRecoveryWireActive ::
    RootBroker scope brokerGeneration verb ->
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
            HandoffError
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
signRecoveryWireActive broker binding wire
    | brokerVerbName broker /= "down" && brokerVerbName broker /= "destroy" =
        pure (Left (HandoffRecoveryVerbInvalid (brokerVerbName broker)))
    | recoveryProjectionInstalledProject binding /= brokerProjectName broker =
        pure (Left (HandoffBindingMismatch "the recovery projection names a different installed project than the live root broker"))
    | recoveryProjectionScope binding /= brokerScopeTag broker =
        pure (Left (HandoffBindingMismatch "the recovery projection names a different scope than the live root broker"))
    | recoveryProjectionStoreIdentity binding /= brokerStoreIdentity broker =
        pure (Left (HandoffBindingMismatch "the recovery projection names a different protected store than the live root broker"))
    | recoveryProjectionBrokerGeneration binding /= brokerEpochValue broker =
        pure (Left (HandoffBindingMismatch "the recovery projection names a different broker generation than the live root broker"))
    | recoveryProjectionVerb binding /= brokerVerbName broker =
        pure (Left (HandoffBindingMismatch "the recovery projection names a different verb than the live root broker"))
    | recoveryWireDigest wire /= recoveryProjectionWireDigest binding =
        pure
            ( Left
                ( HandoffPayloadDigestMismatch
                    (recoveryProjectionWireDigest binding)
                    (recoveryWireDigest wire)
                )
            )
    | otherwise = do
        let signature =
                convert
                    ( Ed25519.sign
                        (brokerSecret broker)
                        (brokerPublic broker)
                        (recoverySignedMaterial (rootBrokerVerificationKey broker) binding wire)
                    )
        -- Do not let the pure cryptographic thunk escape the lifetime lock.
        _ <- evaluate (ByteString.length signature)
        pure (Right (RecoveryWireGrant signature))

recoverySignedMaterial ::
    ProjectVerificationKey ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    ByteString ->
    ByteString
recoverySignedMaterial key binding wire =
    ByteString.concat
        [ frameWire recoveryWireDomain
        , frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))
        , frameWire (renderRecoveryProjectionBinding binding)
        , frameWire wire
        ]

{- | What an immediate parent is given: the binding it may carry, and nothing
else.

There is deliberately no field here from which a signature can be produced. A
parent relays; the root signs.
-}
newtype BrokerRelay scope brokerGeneration
    = BrokerRelay (HandoffBinding scope brokerGeneration)
    deriving (Eq, Show)

type role BrokerRelay nominal nominal

-- | Hand a parent the relay for one edge.
brokerRelay ::
    RootBroker scope brokerGeneration verb ->
    HandoffBinding scope brokerGeneration ->
    Either HandoffError (BrokerRelay scope brokerGeneration)
brokerRelay broker binding
    | handoffInstalledProject binding /= brokerProjectName broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different installed project than the live root broker"
            )
    | handoffBrokerGeneration binding /= brokerEpochValue broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different broker generation than the live root broker"
            )
    | handoffStoreIdentity binding /= brokerStoreIdentity broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different protected store than the live root broker"
            )
    | handoffScope binding /= brokerScopeTag broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different scope than the live root broker"
            )
    | handoffVerb binding /= brokerVerbName broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different verb than the root invocation authorized"
            )
    | otherwise = Right (BrokerRelay binding)

-- | The binding a relay carries. Descriptive; it authorizes nothing on its own.
relayBinding :: BrokerRelay scope brokerGeneration -> HandoffBinding scope brokerGeneration
relayBinding (BrokerRelay binding) = binding

{- | Refine an edge returned over a relay against the already authenticated
route that carried it.

When an opening request is available, every caller-controlled binding field is
also compared with that exact request before the typed relay is constructed.
For a later grant request, @Nothing@ still checks all root-owned coordinates;
the root's durable registered-edge record then checks the complete binding and
token transcript before signing.
-}
brokerRelayFromRouteWire ::
    BrokerRoute scope brokerGeneration ->
    Maybe HandoffBindingInput ->
    ByteString ->
    Either HandoffError (BrokerRelay scope brokerGeneration)
brokerRelayFromRouteWire route expected raw = do
    binding <- decodeHandoffBinding raw
    requireRouteField
        "installed project"
        (handoffInstalledProject binding == routeInstalledProject route)
    requireRouteField "scope" (handoffScope binding == routeScopeTag route)
    requireRouteField
        "protected store"
        (handoffStoreIdentity binding == routeStoreIdentity route)
    requireRouteField
        "broker generation"
        (handoffBrokerGeneration binding == routeBrokerGeneration route)
    requireRouteField "verb" (handoffVerb binding == routeVerb route)
    case expected of
        Nothing -> pure ()
        Just input -> do
            requireRouteField "specification digest" (handoffSpecDigest binding == requestedSpecDigest input)
            requireRouteField "payload kind" (handoffPayloadKind binding == requestedPayloadKind input)
            requireRouteField "plan revision" (handoffPlanRevision binding == requestedPlanRevision input)
            requireRouteField "parent frame" (handoffParentFrame binding == requestedParentFrame input)
            requireRouteField "child frame" (handoffChildFrame binding == requestedChildFrame input)
            requireRouteField "child config digest" (handoffChildConfigDigest binding == requestedChildConfigDigest input)
            requireRouteField "phase" (handoffPhase binding == requestedPhase input)
    pure (BrokerRelay binding)
  where
    requireRouteField _ True = Right ()
    requireRouteField fieldName False =
        Left
            ( HandoffBindingMismatch
                ("the relayed binding's " <> fieldName <> " does not match its authenticated route or opening request")
            )

{- | Open one edge the root intends to hand off: mint its one-time token,
build its canonical binding, and record the edge durably before anyone can ask
for a grant over it.

This is what makes relaying *weaker* than signing. Without it, a root that
signs any well-formed request it receives has given an intermediate frame the
signer's power one message removed: the intermediary could name an edge the
root never planned — a different child frame, a different phase — and get it
authenticated. With it, 'grantHandoff' answers only for an edge this function
already opened, so a frame that can relay still cannot invent.

The record is written under the store's exclusive entry, keyed by the token
commitment, and expects to be absent — a freshly minted token names a record
that cannot already exist. It carries the canonical binding bytes, so grant
issuance compares what it is asked about against what was planned rather than
against a bare presence.
-}
registerHandoffEdge ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    IO (Either HandoffError (BrokerRelay scope brokerGeneration, HandoffToken))
registerHandoffEdge broker input =
    withActiveRootBroker broker (registerHandoffEdgeActive broker input)

{- | Run an edge-plan admission decision and its durable registration under
one uninterrupted broker-lifetime guard.

The nested result preserves the plan's rejection type. The relay uses this
compound form so an escaped root link refuses before invoking admission IO;
ordinary root callers use 'registerHandoffEdge'.
-}
registerAdmittedHandoffEdge ::
    RootBroker scope brokerGeneration verb ->
    IO (Either rejection ()) ->
    HandoffBindingInput ->
    IO
        ( Either
            HandoffError
            (Either rejection (BrokerRelay scope brokerGeneration, HandoffToken))
        )
registerAdmittedHandoffEdge broker admission input =
    withActiveRootBroker broker $ do
        admitted <- admission
        case admitted of
            Left rejection -> pure (Right (Left rejection))
            Right () -> fmap (fmap Right) (registerHandoffEdgeActive broker input)

registerHandoffEdgeActive ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    IO (Either HandoffError (BrokerRelay scope brokerGeneration, HandoffToken))
registerHandoffEdgeActive broker input = do
    token <- freshHandoffToken
    case mkHandoffBinding broker input token >>= brokerRelay broker of
        Left failure -> pure (Left failure)
        Right relay -> do
            entered <-
                withProtectedEntry (brokerProtectedStore broker) $ \session ->
                    Right <$> recordPlannedEdge session (relayBinding relay)
            pure $ case entered of
                Left failure -> Left (HandoffStoreFailure failure)
                Right (Left failure) -> Left failure
                Right (Right ()) -> Right (relay, token)

recordPlannedEdge ::
    ProtectedSession session ->
    HandoffBinding scope brokerGeneration ->
    IO (Either HandoffError ())
recordPlannedEdge session binding =
    case mkRecordKey (tokenRecordKey binding) of
        Left failure -> pure (Left (HandoffStoreFailure failure))
        Right key -> do
            written <-
                compareAndSwapProtectedRecord
                    session
                    key
                    ExpectAbsent
                    (plannedEdgeRecord binding)
            pure $ case written of
                Right _ -> Right ()
                Left failure -> Left (HandoffStoreFailure failure)

{- | The two states an edge record has, tagged so they cannot be confused.

An untagged encoding would ask a reader to tell a rendered binding from a
transcript digest by their shapes, and "these two byte strings happen not to
collide" is not a property worth depending on.
-}
plannedEdgeRecord :: HandoffBinding scope brokerGeneration -> ByteString
plannedEdgeRecord binding = "planned:" <> renderHandoffBinding binding

grantedEdgeRecord :: ByteString -> ByteString
grantedEdgeRecord transcriptDigest = "granted:" <> transcriptDigest

-- ---------------------------------------------------------------------------
-- Offer, challenge, grant

{- | An unpredictable, fixed-width one-time token minted by the root side.

Its constructor is hidden and its 'Show' instance is permanently redacted.
The public transport accessor and width-checked adopter below intentionally let
an immediate peer carry the token through framed protocol fields. Secrecy of a
Haskell constructor is not the one-use guarantee: the root's registered durable
edge and transcript compare-and-swap enforce that guarantee.
-}
newtype HandoffToken = HandoffToken ByteString
    deriving (Eq)

instance Show HandoffToken where
    show _ = "HandoffToken <redacted>"

-- | Mint a cryptographically fresh protocol-v1 token.
freshHandoffToken :: IO HandoffToken
freshHandoffToken = HandoffToken <$> (getRandomBytes tokenBytesLength :: IO ByteString)

tokenBytesLength :: Int
tokenBytesLength = 32

{- | The token's exact bytes, for a transport that carries fields.

Deliberately narrow: this is the same disclosure 'handoffOfferWire' already
makes to the peer it is being handed to, expressed as a value instead of a
concatenation. It is not a way to *learn* a token — only a holder can call it.
-}
handoffTokenBytes :: HandoffToken -> ByteString
handoffTokenBytes (HandoffToken value) = value

{- | Adopt received bytes as the token they claim to be.

A token is one-use because the root's registered edge says so, not because the
value is hard to build: 'consumeRegisteredEdge' answers for exactly one
transcript per opened edge, and refuses an edge that was never opened. A frame
relaying an edge downward must be able to reconstruct the token it was handed,
so the adoption is explicit and width-checked rather than implicit.
-}
handoffTokenFromBytes :: ByteString -> Either HandoffError HandoffToken
handoffTokenFromBytes raw
    | ByteString.length raw /= tokenBytesLength = Left HandoffTokenInvalid
    | otherwise = Right (HandoffToken raw)

tokenFrame :: HandoffToken -> ByteString
tokenFrame (HandoffToken token) = frameWire token

tokenCommitment :: HandoffToken -> Text
tokenCommitment = digestBytes . tokenFrame

{- | What crosses the boundary: the length-delimited narrowed config wire plus
the one-time token identifying this handoff.

The payload is carried as bytes and the token is a separate framed field, so the
receiver never has to parse config to find where the token starts.
-}
data HandoffOffer scope brokerGeneration = HandoffOffer
    { offerBinding :: HandoffBinding scope brokerGeneration
    , offerPayload :: ByteString
    , offerToken :: HandoffToken
    }
    deriving (Eq)

type role HandoffOffer nominal nominal

instance Show (HandoffOffer scope brokerGeneration) where
    show offer =
        "HandoffOffer {binding = "
            <> show (offerBinding offer)
            <> ", payload = <redacted>, token = <redacted>}"

{- | Build an offer from a relay and the exact child config bytes.

The binding's declared child-config digest must match the bytes being sent. This
is checked here so a parent cannot construct an offer whose digest describes a
different payload than the one it is about to transmit.
-}
mkHandoffOffer ::
    BrokerRelay scope brokerGeneration ->
    -- | the exact narrowed child config bytes
    ByteString ->
    -- | the one-time token identifying this handoff
    HandoffToken ->
    Either HandoffError (HandoffOffer scope brokerGeneration)
mkHandoffOffer (BrokerRelay binding) payload token
    | handoffTokenCommitment binding /= tokenCommitment token =
        Left
            ( HandoffBindingMismatch
                "the binding's token commitment does not describe the offered token"
            )
    | handoffChildConfigDigest binding /= childConfigDigest payload =
        Left
            ( HandoffBindingMismatch
                "the binding's child config digest does not describe the payload being offered"
            )
    | otherwise =
        Right
            HandoffOffer
                { offerBinding = binding
                , offerPayload = payload
                , offerToken = token
                }

{- | The framed bytes an offer transmits: exact config bytes, exact token, then
the canonical binding. Including the binding lets a real receiver compare what
arrived with the edge it independently expects; it need not obtain that binding
from an ambient config or command-line argument.
-}
handoffOfferWire :: HandoffOffer scope brokerGeneration -> ByteString
handoffOfferWire offer =
    frameWire (offerPayload offer)
        <> tokenFrame (offerToken offer)
        <> frameWire (renderHandoffBinding (offerBinding offer))

{- | The three values 'handoffOfferWire' concatenates, as separate fields:
the exact config bytes, the exact token, and the canonical binding.

A transport that carries typed fields rather than one opaque blob needs them
apart, and re-splitting the concatenation at the sender would be a second
parser of the sender's own output. Nothing is disclosed that
'handoffOfferWire' does not already transmit — the receiver reassembles
exactly @frameWire payload <> frameWire token <> frameWire binding@, and that
reassembly is what its signature is checked over.
-}
handoffOfferFrames ::
    HandoffOffer scope brokerGeneration ->
    (ByteString, ByteString, ByteString)
handoffOfferFrames offer =
    ( offerPayload offer
    , tokenBytes (offerToken offer)
    , renderHandoffBinding (offerBinding offer)
    )
  where
    tokenBytes (HandoffToken value) = value

-- | The binding an offer claims. Descriptive until a grant authenticates it.
handoffOfferBinding ::
    HandoffOffer scope brokerGeneration ->
    HandoffBinding scope brokerGeneration
handoffOfferBinding = offerBinding

{- | A receiver-generated nonce.

Freshness is the whole point: because the root signs over the challenge, a
transcript recorded from an earlier handoff carries a signature over a challenge
this receiver did not issue, and fails verification.
-}
newtype HandoffChallenge = HandoffChallenge ByteString
    deriving (Eq)

instance Show HandoffChallenge where
    show _ = "HandoffChallenge <fresh>"

-- | The raw challenge bytes, for transmission back to the root.
challengeBytes :: HandoffChallenge -> ByteString
challengeBytes (HandoffChallenge value) = value

-- | Mint a fresh challenge in the receiving binary.
freshChallenge :: IO HandoffChallenge
freshChallenge = HandoffChallenge <$> (getRandomBytes challengeBytesLength :: IO ByteString)

challengeBytesLength :: Int
challengeBytesLength = 32

{- | Adopt received bytes as the challenge a receiver issued.

A signer cannot answer a challenge it is unable to reconstruct, so the root
side of a real exchange needs this. Adopting a nonce grants nothing: the whole
value of a challenge is that the *receiver* chose it and will compare the
signature against the one it holds, so bytes that arrive here are answered, not
trusted. A width other than the protocol's is refused rather than padded.
-}
handoffChallengeFromBytes :: ByteString -> Either HandoffError HandoffChallenge
handoffChallengeFromBytes raw
    | ByteString.length raw /= challengeBytesLength =
        Left
            ( HandoffBindingMismatch
                ( "a challenge is "
                    <> Text.pack (show challengeBytesLength)
                    <> " bytes, received "
                    <> Text.pack (show (ByteString.length raw))
                )
            )
    | otherwise = Right (HandoffChallenge raw)

{- | The root's signature over one challenge and one binding. Opaque: a
consumer cannot alter which binding a grant speaks for.
-}
newtype HandoffGrant scope brokerGeneration = HandoffGrant ByteString
    deriving (Eq)

type role HandoffGrant nominal nominal

instance Show (HandoffGrant scope brokerGeneration) where
    show _ = "HandoffGrant <signed>"

-- | The raw signature bytes, for transmission.
grantSignature :: HandoffGrant scope brokerGeneration -> ByteString
grantSignature (HandoffGrant value) = value

{- | Adopt received bytes as the grant they claim to be.

This is not a way to mint authority: a grant is exactly a signature, and
'verifyHandoff' is the only thing that decides whether one speaks for an edge.
A receiver must be able to form the value from the bytes that arrived, so the
constructor that admits them is explicit rather than a byte-shaped hole in
'verifyHandoff'.
-}
handoffGrantFromSignature :: ByteString -> HandoffGrant scope brokerGeneration
handoffGrantFromSignature = HandoffGrant

{- | Consume one token at the root and issue its grant.

The broker opens the exact root protected store captured when the typed root
and scope evidence minted it. The first request publishes only a digest of the
signed transcript. Repeating the identical request is idempotent and yields the
same deterministic Ed25519 signature; any other challenge or transcript for
the token is refused. There is intentionally no public pure signing function
and no caller-selected store argument.
-}
grantHandoff ::
    RootBroker scope brokerGeneration verb ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either HandoffError (HandoffGrant scope brokerGeneration))
grantHandoff broker offer challenge = withActiveRootBroker broker $
    case brokerRelay broker binding of
        Left failure -> pure (Left failure)
        Right _ -> do
            entered <-
                withProtectedEntry (brokerProtectedStore broker) $ \session ->
                    Right <$> consumeRegisteredEdge session binding material
            case entered of
                Left failure -> pure (Left (HandoffStoreFailure failure))
                Right (Left failure) -> pure (Left failure)
                Right (Right ()) -> Right <$> issueGrant broker material
  where
    binding = handoffOfferBinding offer
    material =
        signedMaterial
            (rootBrokerVerificationKey broker)
            binding
            (tokenFrame (offerToken offer))
            challenge

issueGrant ::
    RootBroker scope brokerGeneration verb ->
    ByteString ->
    IO (HandoffGrant scope brokerGeneration)
issueGrant broker material = do
    let signature =
            convert
                ( Ed25519.sign
                    (brokerSecret broker)
                    (brokerPublic broker)
                    material
                )
    -- The signature must be fully constructed before the lifetime lock opens.
    _ <- evaluate (ByteString.length signature)
    pure (HandoffGrant signature)

{- | Exactly what a signature covers, in protocol order.

The token argument is already its exact wire frame. Every other variable-width
component is length-framed, and the protocol version is fixed-width. This is
both canonical and domain separated from every other Ed25519 use in the
project.
-}
signedMaterial ::
    ProjectVerificationKey ->
    HandoffBinding scope brokerGeneration ->
    ByteString ->
    HandoffChallenge ->
    ByteString
signedMaterial key binding exactTokenFrame (HandoffChallenge challenge) =
    ByteString.concat
        [ frameWire handoffGrantDomain
        , frameWire (ByteString.pack (word64BigEndian handoffProtocolVersion))
        , frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))
        , frameWire (renderHandoffBinding binding)
        , exactTokenFrame
        , frameWire challenge
        ]

-- ---------------------------------------------------------------------------
-- Verification

{- | An authenticated handoff. Minted only by 'verifyHandoff'; the constructor
is private, so raw wire cannot be promoted into one.
-}
data VerifiedHandoff scope brokerGeneration = VerifiedHandoff
    { verifiedBinding :: HandoffBinding scope brokerGeneration
    , verifiedPayload :: ByteString
    , verifiedProjectKey :: ProjectVerificationKey
    }

type role VerifiedHandoff nominal nominal

instance Show (VerifiedHandoff scope brokerGeneration) where
    show handoff = "VerifiedHandoff " <> show (verifiedBinding handoff)

-- | The authenticated binding.
verifiedHandoffBinding ::
    VerifiedHandoff scope brokerGeneration ->
    HandoffBinding scope brokerGeneration
verifiedHandoffBinding = verifiedBinding

-- | The exact bytes whose digest the signature covered.
verifiedHandoffPayload :: VerifiedHandoff scope brokerGeneration -> ByteString
verifiedHandoffPayload = verifiedPayload

-- | Derive a child frame's root route from the exact handoff it verified.
verifiedHandoffRoute :: VerifiedHandoff scope brokerGeneration -> BrokerRoute scope brokerGeneration
verifiedHandoffRoute handoff =
    BrokerRoute
        { routeInstalledProject = handoffInstalledProject binding
        , routeScopeTag = handoffScope binding
        , routeStoreIdentity = handoffStoreIdentity binding
        , routeBrokerGeneration = handoffBrokerGeneration binding
        , routeVerb = handoffVerb binding
        , routeVerificationKeyDigest =
            TextEncoding.encodeUtf8
                (verificationKeyDigest (verifiedProjectKey handoff))
        , routeCurrentFrame = Just (handoffChildFrame binding)
        }
  where
    binding = verifiedBinding handoff

-- | Opaque verified wire with a rank-2 local @recoveryWireId@.
data VerifiedRecoveryWire scope brokerGeneration verb planDigest frame recoveryWireDigest recoveryWireId where
    VerifiedRecoveryWire ::
        RecoveryProjectionBinding
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            frame
            recoveryWireDigest ->
        ByteString ->
        VerifiedRecoveryWire
            scope
            brokerGeneration
            verb
            planDigest
            frame
            recoveryWireDigest
            recoveryWireId

type role VerifiedRecoveryWire nominal nominal nominal nominal nominal nominal nominal

verifiedRecoveryWireBytes ::
    VerifiedRecoveryWire
        scope
        brokerGeneration
        verb
        planDigest
        frame
        recoveryWireDigest
        recoveryWireId ->
    ByteString
verifiedRecoveryWireBytes (VerifiedRecoveryWire _ wire) = wire

-- | Verify the exact binding and wire against the independent project key.
withVerifiedRecoveryWire ::
    ProjectVerificationKey ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        frame
        recoveryWireDigest ->
    ByteString ->
    RecoveryWireGrant
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        frame
        recoveryWireDigest ->
    ( forall recoveryWireId.
      VerifiedRecoveryWire
        scope
        brokerGeneration
        verb
        planDigest
        frame
        recoveryWireDigest
        recoveryWireId ->
      result
    ) ->
    Either HandoffError result
withVerifiedRecoveryWire installedKey@(ProjectVerificationKey key) binding wire (RecoveryWireGrant signature) use
    | recoveryWireDigest wire /= recoveryProjectionWireDigest binding =
        Left
            ( HandoffPayloadDigestMismatch
                (recoveryProjectionWireDigest binding)
                (recoveryWireDigest wire)
            )
    | otherwise = case Ed25519.signature signature of
        CryptoFailed _ -> Left HandoffRecoverySignatureInvalid
        CryptoPassed parsed
            | not
                ( Ed25519.verify
                    key
                    (recoverySignedMaterial installedKey binding wire)
                    parsed
                ) ->
                Left HandoffRecoverySignatureInvalid
            | otherwise -> Right (use (VerifiedRecoveryWire binding wire))

-- | Opaque join of the one-use edge and independently verified recovery wire.
data VerifiedRecoveryHandoff scope brokerGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb
    = VerifiedRecoveryHandoff
        (VerifiedHandoff scope brokerGeneration)
        ( VerifiedRecoveryWire
            scope
            brokerGeneration
            verb
            planDigest
            childFrame
            recoveryWireDigest
            recoveryWireId
        )

type role VerifiedRecoveryHandoff nominal nominal nominal nominal nominal nominal nominal nominal

-- | Join only an exact recovery-kind, exact-verb teardown edge.
withVerifiedRecoveryHandoff ::
    ProjectVerb verb ->
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
    VerifiedHandoff scope brokerGeneration ->
    ( forall recoveryWireId.
      VerifiedRecoveryHandoff
        scope
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      result
    ) ->
    Either HandoffError result
withVerifiedRecoveryHandoff verb projection grant handoff use
    | handoffPayloadKind binding /= RecoveryAdapterWire =
        Left (HandoffBindingMismatch "the authenticated payload is not a recovery adapter wire")
    | handoffVerb binding /= projectVerbName verb =
        Left (HandoffBindingMismatch "the recovery handoff does not authorize the requested verb")
    | handoffVerb binding /= "down" && handoffVerb binding /= "destroy" =
        Left (HandoffRecoveryVerbInvalid (handoffVerb binding))
    | handoffPhase binding /= "teardown" =
        Left (HandoffBindingMismatch "the recovery handoff is not in the teardown phase")
    | not exactProjection =
        Left (HandoffBindingMismatch "the recovery handoff and projection bindings differ")
    | otherwise =
        withVerifiedRecoveryWire (verifiedProjectKey handoff) projection (verifiedHandoffPayload handoff) grant $
            \wire -> use (VerifiedRecoveryHandoff handoff wire)
  where
    binding = verifiedHandoffBinding handoff
    exactProjection =
        and
            [ handoffInstalledProject binding == recoveryProjectionInstalledProject projection
            , handoffScope binding == recoveryProjectionScope projection
            , handoffStoreIdentity binding == recoveryProjectionStoreIdentity projection
            , handoffBrokerGeneration binding
                == recoveryProjectionBrokerGeneration projection
            , handoffVerb binding == recoveryProjectionVerb projection
            , handoffPlanRevision binding == recoveryProjectionPlanDigest projection
            , handoffParentFrame binding == recoveryProjectionParentFrame projection
            , handoffChildFrame binding == recoveryProjectionChildFrame projection
            , handoffChildConfigDigest binding == recoveryProjectionWireDigest projection
            ]

{- | An opaque witness that exact config bytes were authenticated under a
binding whose payload kind is 'NarrowedProjectConfig'. This is the narrow seam
for config admission: it carries neither the handoff token nor a protected-store
capability.
-}
data AuthenticatedConfigPayload scope brokerGeneration = AuthenticatedConfigPayload
    { authenticatedBinding :: HandoffBinding scope brokerGeneration
    , authenticatedBytes :: ByteString
    }

type role AuthenticatedConfigPayload nominal nominal

instance Show (AuthenticatedConfigPayload scope brokerGeneration) where
    show payload =
        "AuthenticatedConfigPayload {binding = "
            <> show (authenticatedBinding payload)
            <> ", bytes = <redacted>}"

-- | Narrow a verified handoff to the config-admission witness.
verifiedConfigPayload ::
    VerifiedHandoff scope brokerGeneration ->
    Either HandoffError (AuthenticatedConfigPayload scope brokerGeneration)
verifiedConfigPayload handoff
    | handoffPayloadKind binding == NarrowedProjectConfig =
        Right
            AuthenticatedConfigPayload
                { authenticatedBinding = binding
                , authenticatedBytes = verifiedHandoffPayload handoff
                }
    | otherwise = Left (HandoffBindingMismatch "the authenticated payload is not a project config")
  where
    binding = verifiedHandoffBinding handoff

-- | The signed digest of the exact authenticated config bytes.
authenticatedConfigDigest :: AuthenticatedConfigPayload scope brokerGeneration -> Text
authenticatedConfigDigest = handoffChildConfigDigest . authenticatedBinding

-- | The exact authenticated bytes for atomic config admission.
authenticatedConfigBytes :: AuthenticatedConfigPayload scope brokerGeneration -> ByteString
authenticatedConfigBytes = authenticatedBytes

{- | Statelessly verify one received handoff.

The token was authoritatively consumed by 'grantHandoff' in the root protected
store before this grant could exist. The child neither receives nor accepts a
store capability here. It recomputes the config digest and token commitment
from the exact received frames, requires the transmitted canonical binding to
match the independently expected binding, and takes its key as a separate
installed input — never from the message.
-}
verifyHandoff ::
    ProjectVerificationKey ->
    -- | the exact framed bytes received
    ByteString ->
    -- | the binding the receiver expects for its own edge
    HandoffBinding scope brokerGeneration ->
    HandoffChallenge ->
    HandoffGrant scope brokerGeneration ->
    Either HandoffError (VerifiedHandoff scope brokerGeneration)
verifyHandoff installedKey@(ProjectVerificationKey key) received expected challenge (HandoffGrant signature) =
    case decodeOfferWire received of
        Left err -> Left err
        Right (payload, token, receivedBinding)
            | childConfigDigest payload /= handoffChildConfigDigest expected ->
                Left
                    ( HandoffPayloadDigestMismatch
                        (handoffChildConfigDigest expected)
                        (childConfigDigest payload)
                    )
            | tokenCommitment token /= handoffTokenCommitment expected ->
                Left (HandoffBindingMismatch "the received token does not match the bound token commitment")
            | receivedBinding /= renderHandoffBinding expected ->
                Left (HandoffBindingMismatch "the received canonical binding is not the expected edge binding")
            | otherwise -> case Ed25519.signature signature of
                CryptoFailed _ -> Left HandoffSignatureInvalid
                CryptoPassed parsed
                    | not
                        ( Ed25519.verify
                            key
                            (signedMaterial installedKey expected (tokenFrame token) challenge)
                            parsed
                        ) ->
                        Left HandoffSignatureInvalid
                    | otherwise ->
                        Right
                            VerifiedHandoff
                                { verifiedBinding = expected
                                , verifiedPayload = payload
                                , verifiedProjectKey = installedKey
                                }

{- | Split the received wire into its three framed fields. A message with a
missing frame, a non-v1 token width, or trailing bytes is refused.
-}
decodeOfferWire :: ByteString -> Either HandoffError (ByteString, HandoffToken, ByteString)
decodeOfferWire raw = do
    (payload, afterPayload) <- takeFrame raw
    (tokenBytes, afterToken) <- takeFrame afterPayload
    (bindingBytes, trailing) <- takeFrame afterToken
    if ByteString.length tokenBytes /= tokenBytesLength
        then Left HandoffTokenInvalid
        else
            if not (ByteString.null trailing)
                then Left (HandoffWireTrailingBytes (ByteString.length trailing))
                else Right (payload, HandoffToken tokenBytes, bindingBytes)

{- | Split one leading frame off a concatenation, leaving the remainder.

'unframeWire' requires its frame to be the whole input, which is right at a
message boundary and wrong for the three-frame offer wire. This is the reader
that walks such a concatenation, and it is the same one every parser in this
module uses, so no consumer invents a second framing.
-}
takeHandoffFrame :: ByteString -> Either HandoffError (ByteString, ByteString)
takeHandoffFrame = takeFrame

takeFrame :: ByteString -> Either HandoffError (ByteString, ByteString)
takeFrame raw
    | ByteString.length raw < 8 = Left (HandoffWireTruncated 8 (ByteString.length raw))
    | declared > maxWireBytes = Left (HandoffWireTooLarge declared maxWireBytes)
    | fromIntegral (ByteString.length body) < declared =
        Left (HandoffWireTruncated (fromIntegral declared) (ByteString.length body))
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)

{- | Consume the registered edge in the root store.

Three observations, three answers. A record that still holds the planned
binding is this edge's first grant: it moves to the transcript digest, at the
exact version just observed, so a concurrent peer loses the swap rather than
issuing a second first-grant. A record that already holds *this* transcript is
an identical retry — the same challenge, the same material, and therefore the
same deterministic signature — so it succeeds without advancing the version. A
record holding some other transcript is a token being used a second time, for a
challenge it did not authorize, and is refused.

Absence is the fourth case and the important one: no edge was ever opened here,
so there is nothing to authenticate. That is what stops a frame that can relay
from also being able to invent (see 'registerHandoffEdge').
-}
consumeRegisteredEdge ::
    ProtectedSession session ->
    HandoffBinding scope brokerGeneration ->
    ByteString ->
    IO (Either HandoffError ())
consumeRegisteredEdge session binding material =
    case mkRecordKey (tokenRecordKey binding) of
        Left failure -> pure (Left (HandoffStoreFailure failure))
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (HandoffStoreFailure failure))
                Right Nothing -> pure (Left HandoffEdgeUnregistered)
                Right (Just record)
                    | protectedRecordBytes record == granted -> pure (Right ())
                    | protectedRecordBytes record /= plannedEdgeRecord binding ->
                        pure (Left HandoffTokenConsumed)
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                                granted
                        case written of
                            Right _ -> pure (Right ())
                            Left writeFailure -> do
                                raced <- readProtectedRecord session key
                                pure $ case raced of
                                    Right (Just latest)
                                        | protectedRecordBytes latest == granted -> Right ()
                                        | otherwise -> Left HandoffTokenConsumed
                                    Right Nothing -> Left (HandoffStoreFailure writeFailure)
                                    Left readFailure -> Left (HandoffStoreFailure readFailure)
  where
    granted = grantedEdgeRecord (TextEncoding.encodeUtf8 (digestBytes material))

tokenRecordKey :: HandoffBinding scope brokerGeneration -> Text
tokenRecordKey binding = "handoff-token." <> handoffTokenCommitment binding

-- ---------------------------------------------------------------------------
-- Digests and failures

{- | The digest a binding carries for its child config payload.

Exported because a parent must be able to compute it: 'mkHandoffOffer' requires
the binding's declared digest to describe the exact bytes being sent, so a
parent that could not derive this value could not build a legitimate offer at
all.
-}
childConfigDigest :: ByteString -> Text
childConfigDigest = digestBytes

-- | Digest of the exact non-secret recovery adapter bytes.
recoveryWireDigest :: ByteString -> Text
recoveryWireDigest = digestBytes

digestBytes :: ByteString -> Text
digestBytes bytes =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 bytes)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

-- | Every way a handoff can fail to authenticate.
data HandoffError
    = -- | expected at least this many bytes, saw this many
      HandoffWireTruncated Int Int
    | -- | the frame declared more bytes than a receiver will accept
      HandoffWireTooLarge Word64 Word64
    | -- | bytes remained after the last declared frame
      HandoffWireTrailingBytes Int
    | HandoffTokenInvalid
    | -- | this token has already been used
      HandoffTokenConsumed
    | -- | the root never opened this edge, so there is nothing to authenticate
      HandoffEdgeUnregistered
    | -- | the rank-2 broker bracket has already closed
      HandoffBrokerExpired
    | HandoffSignatureInvalid
    | -- | expected digest, then the digest of the bytes received
      HandoffPayloadDigestMismatch Text Text
    | -- | the binding names this frame, but the binary is that one
      HandoffFrameMismatch Text Text
    | HandoffBindingMismatch Text
    | -- | request/response name, exact expected count, observed count
      HandoffRecoveryFieldCount Text Int Int
    | -- | exact expected signature width, observed width
      HandoffRecoverySignatureLength Int Int
    | HandoffRecoverySignatureInvalid
    | HandoffRecoveryVerbInvalid Text
    | HandoffSigningKeyInvalid
    | HandoffSigningKeyUnavailable Text
    | HandoffVerificationKeyUnavailable Text
    | HandoffStoreFailure ProtectedError
    deriving (Eq)

instance Show HandoffError where
    show = handoffErrorMessage

-- | A one-line diagnostic.
handoffErrorMessage :: HandoffError -> String
handoffErrorMessage err = case err of
    HandoffWireTruncated expected actual ->
        "handoff: truncated wire (expected " <> show expected <> " bytes, saw " <> show actual <> ")"
    HandoffWireTooLarge declared limit ->
        "handoff: declared frame of " <> show declared <> " bytes exceeds the " <> show limit <> "-byte limit"
    HandoffWireTrailingBytes count ->
        "handoff: " <> show count <> " unexpected bytes after the last frame"
    HandoffTokenInvalid -> "handoff: invalid one-time token"
    HandoffTokenConsumed -> "handoff: one-time token has already authorized another transcript"
    HandoffEdgeUnregistered -> "handoff: the root opened no such edge"
    HandoffBrokerExpired -> "handoff: the root broker bracket has expired"
    HandoffSignatureInvalid -> "handoff: the grant signature is invalid for this transcript"
    HandoffPayloadDigestMismatch expected actual ->
        "handoff: payload digest " <> Text.unpack actual <> " does not match the bound " <> Text.unpack expected
    HandoffFrameMismatch bound actual ->
        "handoff: the grant binds frame " <> Text.unpack bound <> ", but this binary runs as " <> Text.unpack actual
    HandoffBindingMismatch detail -> "handoff: " <> Text.unpack detail
    HandoffRecoveryFieldCount message expected actual ->
        "handoff: recovery "
            <> Text.unpack message
            <> " expects "
            <> show expected
            <> " fields, saw "
            <> show actual
    HandoffRecoverySignatureLength expected actual ->
        "handoff: recovery response signature must be "
            <> show expected
            <> " bytes, saw "
            <> show actual
    HandoffRecoverySignatureInvalid ->
        "handoff: the recovery response signature is invalid for this projection"
    HandoffRecoveryVerbInvalid verb ->
        "handoff: recovery admits only down or destroy, not " <> Text.unpack verb
    HandoffSigningKeyInvalid -> "handoff: the installed signing key is malformed"
    HandoffSigningKeyUnavailable detail ->
        "handoff: no usable signing key: " <> Text.unpack detail
    HandoffVerificationKeyUnavailable detail ->
        "handoff: no usable verification key: " <> Text.unpack detail
    HandoffStoreFailure failure -> "handoff: " <> Text.unpack (protectedErrorMessage failure)

firstLine :: String -> Text
firstLine = Text.pack . takeWhile (/= '\n')
