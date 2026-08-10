{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The broker-signed runtime role activation (§ X, the operator-root-and-command-authority phase).

A restartable service or daemon leaf cannot re-enter through the recursive
lifecycle handoff: the parent that would relay a grant is long gone by the time
a controller restarts a pod. Its authority instead comes from a manifest the
**root broker signed while the plan was still being validated**, paired at
startup with an identity the running process measures for itself.

The split matters. The broker signs an immutable rollout revision and every
pre-instantiation index — plan, spec, binary, frame, config, secret, service,
role plan, and the permitted effect row — but it deliberately does **not** sign
an instance identity, because the pod does not exist yet and a broker that
claimed to know its UID would be lying. Startup supplies the missing half by
measuring the concrete instance (a pod UID plus its container restart count, or
a protected OS invocation nonce for a host daemon) and hashing the wire and
private-channel bytes actually mounted.

Verification therefore refuses a changed ConfigMap or private bundle, a wrong
independently provisioned activation key, a stale revision, a different binary
or spec, and — because the measured instance is bound into the result — a value
retained from one instance cannot run as another.  The dedicated private-bundle
field is an opaque canonical SHA-256 digest computed from bytes.  The remaining
@Text@ fields are descriptive identities and locators supplied by later typed
projections; they are not a blanket type-level proof that arbitrary text is
secret-free.

The composition-and-network-algebra phase consumes
'VerifiedRuntimeRoleActivation', validates that its durable session has the
same protected-store origin, and owns the sole one-use lifecycle admission,
role plan, cursor, and phase machine built on top.
-}
module HostBootstrap.Activation (
    -- * The signed manifest
    ActivationSecretDigest,
    activationSecretDigestFromBytes,
    activationSecretDigestText,
    ActivationManifest (..),
    renderActivationManifest,
    activationManifestFromWire,

    -- * Independently provisioned activation identity
    ActivationSigningKey,
    activationSigningKeyFromBytes,
    ActivationVerificationKey,
    activationVerificationKeyFromBytes,
    activationSigningVerificationKey,
    activationVerificationKeyBytes,

    -- * The broker that signs it
    ActivationSigningPolicy,
    activationSigningPolicy,
    ActivationBroker,
    withActivationBroker,
    ActivationGrant,
    activationGrantSignature,
    signActivationManifest,
    adoptRelayedActivationGrant,

    -- * What startup measures for itself
    MeasuredInstance (..),
    instanceIdentityText,
    RuntimeMeasurement (..),

    -- * The verified package
    VerifiedRuntimeRoleActivation,
    activationRevision,
    activationInstance,
    activationService,
    activationPermittedEffects,
    activationSecretChannel,
    activationPlanDigest,
    activationSpecDigest,
    activationFrame,
    activationConfigDigest,
    activationSecretDigest,
    activationRolePlanDigest,
    validateActivationStoreOrigin,
    verifyRuntimeRoleActivation,

    -- * Failures
    ActivationError (..),
    activationErrorMessage,
) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (bracket, evaluate)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.Bits (shiftR, (.&.))
import Data.ByteArray (convert)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (RootInvocationAuthority)
import HostBootstrap.Handoff (
    frameWire,
    takeHandoffFrame,
 )
import HostBootstrap.Protected (
    ProtectedSession,
    ProtectedStore,
    ProtectedStoreIdentity,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    sessionStoreIdentity,
 )

-- ---------------------------------------------------------------------------
-- The manifest

{- | Canonical identity of the exact private-bundle bytes.

The constructor is hidden.  Local measurements enter only through
'activationSecretDigestFromBytes'; the wire decoder accepts only the one
lower-case 64-hex SHA-256 spelling.  This excludes a cleartext password or an
arbitrary descriptive label from the manifest's dedicated secret-content
coordinate without pretending that every other descriptive @Text@ is a secret
type.
-}
newtype ActivationSecretDigest = ActivationSecretDigest Text
    deriving (Eq, Ord)

instance Show ActivationSecretDigest where
    show _ = "ActivationSecretDigest <sha256>"

-- | Measure the exact private-bundle bytes.
activationSecretDigestFromBytes :: ByteString -> ActivationSecretDigest
activationSecretDigestFromBytes = ActivationSecretDigest . sha256Hex

-- | The canonical, non-secret SHA-256 identity.
activationSecretDigestText :: ActivationSecretDigest -> Text
activationSecretDigestText (ActivationSecretDigest digest) = digest

{- | Everything the root broker can honestly bind before a workload exists.

Note what is absent: there is no instance identity here. The broker signs the
immutable rollout revision and the controller-template-level indices; the
concrete pod UID or invocation nonce is measured at startup and paired with this
manifest by 'verifyRuntimeRoleActivation'.

The private bundle itself is absent.  Its dedicated field is an opaque digest,
so cleartext bundle bytes cannot be placed there.  Other descriptive fields
remain ordinary identifiers and locators whose typed production belongs to the
later runtime phases.
-}
data ActivationManifest = ActivationManifest
    { manifestScope :: Text
    , manifestPlanDigest :: Text
    , manifestSpecDigest :: Text
    , manifestBinaryDigest :: Text
    , manifestFrame :: Text
    , manifestRevision :: Text
    , manifestConfigDigest :: Text
    , manifestSecretDigest :: ActivationSecretDigest
    , manifestService :: Text
    , manifestRolePlanDigest :: Text
    , manifestPermittedEffects :: [Text]
    , -- | where the runtime reads its private bundle; a locator, never bytes
      manifestSecretChannel :: Text
    }
    deriving (Eq, Show)

-- | Canonical bytes, length-prefixed per field, with the effect row itself
-- length-prefixed so a row of two entries cannot be read as one longer entry.
renderActivationManifest :: ActivationManifest -> ByteString
renderActivationManifest manifest =
    ByteString.concat
        [ field (manifestScope manifest)
        , field (manifestPlanDigest manifest)
        , field (manifestSpecDigest manifest)
        , field (manifestBinaryDigest manifest)
        , field (manifestFrame manifest)
        , field (manifestRevision manifest)
        , field (manifestConfigDigest manifest)
        , field (activationSecretDigestText (manifestSecretDigest manifest))
        , field (manifestService manifest)
        , field (manifestRolePlanDigest manifest)
        , frameWire (ByteString.concat (map field (manifestPermittedEffects manifest)))
        , field (manifestSecretChannel manifest)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- The broker

{- | Long-lived activation signer provisioned at the root.

This is deliberately distinct from the handoff and build signing identities.
The constructor and seed bytes are hidden; provisioning validates the seed
before a root invocation can construct a broker.
-}
newtype ActivationSigningKey = ActivationSigningKey Ed25519.SecretKey

instance Show ActivationSigningKey where
    show _ = "ActivationSigningKey <redacted>"

-- | Validate a provisioned 32-byte Ed25519 activation-signing seed.
activationSigningKeyFromBytes :: ByteString -> Either ActivationError ActivationSigningKey
activationSigningKeyFromBytes raw = case Ed25519.secretKey raw of
    CryptoFailed err -> Left (ActivationSigningKeyInvalid (Text.pack (show err)))
    CryptoPassed key -> Right (ActivationSigningKey key)

{- | Long-lived activation verifier installed independently at each runtime.

It is selected before broker construction and never obtained from an
'ActivationBroker', manifest, grant, or relay response.
-}
newtype ActivationVerificationKey = ActivationVerificationKey Ed25519.PublicKey
    deriving (Eq)

instance Show ActivationVerificationKey where
    show _ = "ActivationVerificationKey <installed>"

-- | Validate independently provisioned Ed25519 public-key bytes.
activationVerificationKeyFromBytes :: ByteString -> Either ActivationError ActivationVerificationKey
activationVerificationKeyFromBytes raw = case Ed25519.publicKey raw of
    CryptoFailed err -> Left (ActivationVerificationKeyInvalid (Text.pack (show err)))
    CryptoPassed key -> Right (ActivationVerificationKey key)

-- | Derive the public half during trusted provisioning, before a broker exists.
activationSigningVerificationKey :: ActivationSigningKey -> ActivationVerificationKey
activationSigningVerificationKey (ActivationSigningKey secret) =
    ActivationVerificationKey (Ed25519.toPublic secret)

-- | Canonical public bytes for independent runtime installation.
activationVerificationKeyBytes :: ActivationVerificationKey -> ByteString
activationVerificationKeyBytes (ActivationVerificationKey key) = convert key

{- | The exact manifests one root invocation has admitted for signing.

The policy is intentionally a closed canonical-byte allowlist, not a predicate:
there is no permissive callback a caller can accidentally install.  The root
constructs it from the role projections it is about to deploy, and the broker
will sign no other value.  The role-plan/project-plan integration that produces
those projections remains owned by the later runtime phases; this type does not
pretend that 'ActivationManifest' fields already live in a @ProjectPlan@.
-}
newtype ActivationSigningPolicy = ActivationSigningPolicy [ByteString]

instance Show ActivationSigningPolicy where
    show (ActivationSigningPolicy manifests) =
        "ActivationSigningPolicy " <> show (length manifests) <> " manifests"

-- | Validate and close a non-empty exact-manifest signing policy.
activationSigningPolicy :: [ActivationManifest] -> Either ActivationError ActivationSigningPolicy
activationSigningPolicy manifests = do
    if null manifests
        then Left (ActivationManifestInvalid "the signing policy is empty")
        else pure ()
    traverse_ validateManifest manifests
    let rendered = map renderActivationManifest manifests
    if hasDuplicate rendered
        then Left (ActivationManifestInvalid "the signing policy contains a duplicate manifest")
        else Right (ActivationSigningPolicy rendered)
  where
    hasDuplicate [] = False
    hasDuplicate (value : rest) = value `elem` rest || hasDuplicate rest

    traverse_ _ [] = Right ()
    traverse_ action (value : rest) = action value >> traverse_ action rest

{- | The root broker's activation-signing capability.

The provisioned activation identity is separate from the cross-frame handoff
identity, and the signature also has its own domain.  The broker is usable only
while 'withActivationBroker' is active: every signer holds the live-state lock
through signature construction, and the bracket finalizer acquires that same
lock before expiring the broker.  An escaped value therefore yields only
'ActivationBrokerExpired'.
-}
data ActivationBroker scope brokerGeneration verb = ActivationBroker
    { brokerSecret :: Ed25519.SecretKey
    , brokerPublic :: Ed25519.PublicKey
    , brokerSigningPolicy :: ActivationSigningPolicy
    , brokerLive :: MVar Bool
    }

type role ActivationBroker nominal nominal nominal

instance Show (ActivationBroker scope brokerGeneration verb) where
    show _ = "ActivationBroker <signing>"

{- | Narrow one provisioned signer to a verified root invocation and a closed
manifest policy.

The callback may retain the opaque value, but the finalizer expires its only
public signing operation before this function returns or propagates an
exception.
-}
withActivationBroker ::
    ActivationSigningKey ->
    RootInvocationAuthority scope brokerGeneration verb ->
    ActivationSigningPolicy ->
    (ActivationBroker scope brokerGeneration verb -> IO result) ->
    IO result
withActivationBroker (ActivationSigningKey secret) root policy use = do
    root `seq` pure ()
    live <- newMVar True
    bracket
        ( pure
            ActivationBroker
                { brokerSecret = secret
                , brokerPublic = Ed25519.toPublic secret
                , brokerSigningPolicy = policy
                , brokerLive = live
                }
        )
        (\_ -> modifyMVar_ live (const (pure False)))
        use

-- | The broker's signature over one manifest.
newtype ActivationGrant = ActivationGrant ByteString
    deriving (Eq)

instance Show ActivationGrant where
    show _ = "ActivationGrant <signed>"

activationGrantSignature :: ActivationGrant -> ByteString
activationGrantSignature (ActivationGrant value) = value

{- | Adopt a signature that arrived over the relay as this frame's grant.

This exists because a nested frame's signature is produced by the root and
travels back as bytes; without it the relayed half could not hold its own answer.
It is safe for the same reason the wire is: __an 'ActivationGrant' is not
authority__. It is a signature, and the only thing that consumes one is
'verifyRuntimeRoleActivation', which checks it against the independently
installed activation verification key over the manifest's own domain-separated
material. Adopting arbitrary bytes here therefore yields a grant that fails
verification, not a grant that authorizes anything.
-}
adoptRelayedActivationGrant :: ByteString -> ActivationGrant
adoptRelayedActivationGrant = ActivationGrant

{- | Sign an activation manifest only when the root's closed policy admitted
the exact canonical bytes.  This is an authorization decision, so validation
alone is deliberately insufficient.
-}
signActivationManifest ::
    ActivationBroker scope brokerGeneration verb ->
    ActivationManifest ->
    IO (Either ActivationError ActivationGrant)
signActivationManifest broker manifest =
    withMVar (brokerLive broker) $ \live ->
        if not live
            then pure (Left ActivationBrokerExpired)
            else case validateManifest manifest of
                Left failure -> pure (Left failure)
                Right () ->
                    if renderActivationManifest manifest `notElem` admitted
                        then pure (Left ActivationManifestNotAdmitted)
                        else Right <$> signManifest broker manifest
  where
    ActivationSigningPolicy admitted = brokerSigningPolicy broker

signManifest ::
    ActivationBroker scope brokerGeneration verb ->
    ActivationManifest ->
    IO ActivationGrant
signManifest broker manifest = do
    let signature =
            convert
                ( Ed25519.sign
                    (brokerSecret broker)
                    (brokerPublic broker)
                    (signedMaterial manifest)
                )
    -- Force the strict signature bytes while the live-state MVar is held.
    -- Otherwise the pure cryptographic thunk could be evaluated after cleanup.
    _ <- evaluate (ByteString.length signature)
    pure (ActivationGrant signature)

validateManifest :: ActivationManifest -> Either ActivationError ()
validateManifest manifest = do
    require "scope" (manifestScope manifest)
    require "plan digest" (manifestPlanDigest manifest)
    require "spec digest" (manifestSpecDigest manifest)
    require "binary digest" (manifestBinaryDigest manifest)
    require "frame" (manifestFrame manifest)
    require "rollout revision" (manifestRevision manifest)
    require "config digest" (manifestConfigDigest manifest)
    require "service identity" (manifestService manifest)
    require "role-plan digest" (manifestRolePlanDigest manifest)
    require "secret channel" (manifestSecretChannel manifest)
    if any Text.null (manifestPermittedEffects manifest)
        then Left (ActivationManifestInvalid "an effect identity is empty")
        else pure ()
    if hasDuplicate (manifestPermittedEffects manifest)
        then Left (ActivationManifestInvalid "the effect row contains a duplicate identity")
        else pure ()
  where
    require fieldName value
        | Text.null value = Left (ActivationManifestInvalid ("the " <> fieldName <> " is empty"))
        | otherwise = Right ()
    hasDuplicate [] = False
    hasDuplicate (value : rest) = value `elem` rest || hasDuplicate rest

-- | Domain-separated signing material.
signedMaterial :: ActivationManifest -> ByteString
signedMaterial manifest =
    frameWire "hostbootstrap/activation/v1" <> frameWire (renderActivationManifest manifest)

{- | Read a manifest back out of its canonical bytes.

This is what makes a __relayed__ signature possible. A nested frame cannot reach
'withActivationBroker' — it consumes a @RootInvocationAuthority@ only the root
mints — so it sends the manifest to the root instead. The root must not sign
opaque bytes: signing is an authorization, and authorizing something it cannot
read would make the broker a blind oracle. So it rebuilds the value and puts it
back through the same 'signActivationManifest' validation a local caller faces.

The decoder is total and every failure is named. Trailing bytes are refused
rather than ignored, because a manifest that renders to a prefix of the received
bytes is not the manifest that was sent.
-}
activationManifestFromWire :: ByteString -> Either ActivationError ActivationManifest
activationManifestFromWire raw = do
    (scope, afterScope) <- textField raw
    (planDigest, afterPlan) <- textField afterScope
    (specDigest, afterSpec) <- textField afterPlan
    (binaryDigest, afterBinary) <- textField afterSpec
    (frame, afterFrame) <- textField afterBinary
    (revision, afterRevision) <- textField afterFrame
    (configDigest, afterConfig) <- textField afterRevision
    (secretDigestText, afterSecret) <- textField afterConfig
    secretDigest <- canonicalSecretDigest secretDigestText
    (service, afterService) <- textField afterSecret
    (rolePlanDigest, afterRolePlan) <- textField afterService
    (effectRow, afterEffects) <- frameField afterRolePlan
    (secretChannel, afterChannel) <- textField afterEffects
    effects <- effectList effectRow
    if ByteString.null afterChannel
        then
            Right
                ActivationManifest
                    { manifestScope = scope
                    , manifestPlanDigest = planDigest
                    , manifestSpecDigest = specDigest
                    , manifestBinaryDigest = binaryDigest
                    , manifestFrame = frame
                    , manifestRevision = revision
                    , manifestConfigDigest = configDigest
                    , manifestSecretDigest = secretDigest
                    , manifestService = service
                    , manifestRolePlanDigest = rolePlanDigest
                    , manifestPermittedEffects = effects
                    , manifestSecretChannel = secretChannel
                    }
        else Left (ActivationManifestInvalid "the manifest wire has trailing bytes")
  where
    frameField bytes =
        either
            (const (Left (ActivationManifestInvalid "the manifest wire is truncated")))
            Right
            (takeHandoffFrame bytes)

    textField bytes = do
        (value, rest) <- frameField bytes
        case TextEncoding.decodeUtf8' value of
            Left _ -> Left (ActivationManifestInvalid "a manifest field is not valid UTF-8")
            Right decoded -> Right (decoded, rest)

    -- The row is itself length-prefixed, so a row of two entries cannot be read
    -- as one longer entry; this walks the inner frames to exhaustion.
    effectList bytes
        | ByteString.null bytes = Right []
        | otherwise = do
            (value, rest) <- textField bytes
            fmap (value :) (effectList rest)

canonicalSecretDigest :: Text -> Either ActivationError ActivationSecretDigest
canonicalSecretDigest digest
    | Text.length digest == 64 && Text.all isLowerHex digest =
        Right (ActivationSecretDigest digest)
    | otherwise =
        Left
            ( ActivationManifestInvalid
                "the secret digest is not canonical lower-case SHA-256 hex"
            )
  where
    isLowerHex character =
        ('0' <= character && character <= '9')
            || ('a' <= character && character <= 'f')

-- ---------------------------------------------------------------------------
-- Measurement

{- | The instance identity a starting process can measure about itself.

A Kubernetes pod's UID alone is not enough: a container that crash-loops keeps
its UID and increments its restart count, so the count is part of the identity.
A host daemon has no platform UID and instead mints a protected invocation nonce
when its revision pointer is switched.
-}
data MeasuredInstance
    = KubernetesInstance
        { podUid :: Text
        , containerRestartCount :: Word64
        }
    | HostServiceInstance
        { invocationNonce :: Text
        }
    deriving (Eq, Show)

-- | The instance's stable textual identity.
instanceIdentityText :: MeasuredInstance -> Text
instanceIdentityText (KubernetesInstance uid restarts) =
    "pod:" <> uid <> "/" <> Text.pack (show restarts)
instanceIdentityText (HostServiceInstance nonce) = "host:" <> nonce

{- | What startup measures for itself, independent of anything the manifest
claims.
-}
data RuntimeMeasurement = RuntimeMeasurement
    { measuredBinaryDigest :: Text
    , -- | the hash of the role-wire bytes actually mounted
      measuredConfigDigest :: Text
    , -- | the canonical hash computed from private-channel bytes actually read
      measuredSecretDigest :: ActivationSecretDigest
    , measuredInstance :: MeasuredInstance
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The verified package

{- | The inseparable activation package the composition-and-network-algebra phase consumes.

Opaque and produced only by 'verifyRuntimeRoleActivation'. It carries the signed
manifest, the measured instance it was paired with, and the protected
secret-channel locator and protected-store origin as one value: a caller cannot
take the effect row from one activation and the instance from another, cannot
obtain the locator without the activation that authorized it, and cannot move a
verified activation to a second durable store.

It confers no lifecycle authority on its own. It cannot construct a
`ProjectPlan`, a generic command authority, or a root authority.
-}
data VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
    = VerifiedRuntimeRoleActivation ActivationManifest MeasuredInstance ProtectedStoreIdentity

type role VerifiedRuntimeRoleActivation nominal nominal nominal nominal nominal nominal nominal

instance Show (VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId) where
    show (VerifiedRuntimeRoleActivation manifest instance' _) =
        "VerifiedRuntimeRoleActivation "
            <> Text.unpack (manifestRevision manifest)
            <> " "
            <> Text.unpack (instanceIdentityText instance')

activationRevision ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationRevision (VerifiedRuntimeRoleActivation manifest _ _) = manifestRevision manifest

activationInstance ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    MeasuredInstance
activationInstance (VerifiedRuntimeRoleActivation _ instance' _) = instance'

activationService ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationService (VerifiedRuntimeRoleActivation manifest _ _) = manifestService manifest

-- | The effect row this activation permits. the service-runtime phase revalidates it before
-- minting the service command authority; it is not itself effect authority.
activationPermittedEffects ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> [Text]
activationPermittedEffects (VerifiedRuntimeRoleActivation manifest _ _) =
    manifestPermittedEffects manifest

-- | The protected locator for the run-private bundle, reachable only through a
-- verified activation.
activationSecretChannel ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationSecretChannel (VerifiedRuntimeRoleActivation manifest _ _) = manifestSecretChannel manifest

{- | The signed parent lifecycle-plan digest. the composition-and-network-algebra phase keys the role's durable
lifecycle admission on it and binds the narrowed role plan back to it; the child
never recomputes it from its least-authority wire.
-}
activationPlanDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationPlanDigest (VerifiedRuntimeRoleActivation manifest _ _) = manifestPlanDigest manifest

activationSpecDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationSpecDigest (VerifiedRuntimeRoleActivation manifest _ _) = manifestSpecDigest manifest

activationFrame ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationFrame (VerifiedRuntimeRoleActivation manifest _ _) = manifestFrame manifest

activationConfigDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationConfigDigest (VerifiedRuntimeRoleActivation manifest _ _) = manifestConfigDigest manifest

activationSecretDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationSecretDigest (VerifiedRuntimeRoleActivation manifest _ _) =
    activationSecretDigestText (manifestSecretDigest manifest)

{- | The signed digest of the narrowed role-plan projection. 'verifyRolePlanDraft'
compares the project's own draft against it before any durable mutation.
-}
activationRolePlanDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationRolePlanDigest (VerifiedRuntimeRoleActivation manifest _ _) = manifestRolePlanDigest manifest

{- | Confirm that a protected session belongs to the same durable store that
participated in activation verification.

The activation constructor and retained origin remain hidden.  Lifecycle code
can therefore perform this check without accepting a caller-supplied identity
or gaining a way to forge or inspect the verified package.
-}
validateActivationStoreOrigin ::
    ProtectedSession session ->
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    Either ActivationError ()
validateActivationStoreOrigin session (VerifiedRuntimeRoleActivation _ _ origin)
    | sessionStoreIdentity session == origin = Right ()
    | otherwise =
        Left
            ( ActivationStoreOriginMismatch
                (protectedStoreIdentityText origin)
                (protectedStoreIdentityText (sessionStoreIdentity session))
            )

{- | Verify a signed manifest against an independently selected exact manifest,
locally measured reality, and the protected store that will own its admission.

The continuation is rank-2: none of the seven activation identities is selected
by the caller or can escape the verification that generated it.  The expected
manifest comes from the workload/controller projection, not from the received
grant; exact comparison prevents replaying a different admitted service, frame,
effect row, or secret channel merely because its measured digests happen to
match.  The verification key and protected-store origin are also installed
independently of the manifest.
-}
verifyRuntimeRoleActivation ::
    -- | the independently installed activation key
    ActivationVerificationKey ->
    -- | the protected store that must later own lifecycle admission
    ProtectedStore ->
    -- | the exact independently selected workload manifest
    ActivationManifest ->
    -- | the received signed manifest
    ActivationManifest ->
    ActivationGrant ->
    RuntimeMeasurement ->
    ( forall scope planDigest specDigest binaryDigest frame revision instanceId.
      VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
      IO result
    ) ->
    IO (Either ActivationError result)
verifyRuntimeRoleActivation
    (ActivationVerificationKey key)
    store
    expected
    manifest
    (ActivationGrant signature)
    measurement
    use
    | Left failure <- validateManifest manifest = pure (Left failure)
    | Left failure <- validateMeasuredInstance (measuredInstance measurement) = pure (Left failure)
    | manifestRevision manifest /= manifestRevision expected =
        pure (Left (ActivationRevisionStale (manifestRevision manifest) (manifestRevision expected)))
    | Just (fieldName, signed, selected) <- firstManifestMismatch expected manifest =
        pure (Left (ActivationManifestMismatch fieldName signed selected))
    | manifestBinaryDigest manifest /= measuredBinaryDigest measurement =
        pure
            ( Left
                ( ActivationMeasurementMismatch
                    "binary"
                    (manifestBinaryDigest manifest)
                    (measuredBinaryDigest measurement)
                )
            )
    | manifestConfigDigest manifest /= measuredConfigDigest measurement =
        pure
            ( Left
                ( ActivationMeasurementMismatch
                    "config"
                    (manifestConfigDigest manifest)
                    (measuredConfigDigest measurement)
                )
            )
    | manifestSecretDigest manifest /= measuredSecretDigest measurement =
        pure
            ( Left
                ( ActivationMeasurementMismatch
                    "secret"
                    (activationSecretDigestText (manifestSecretDigest manifest))
                    (activationSecretDigestText (measuredSecretDigest measurement))
                )
            )
    | otherwise = case Ed25519.signature signature of
        CryptoFailed err -> pure (Left (ActivationSignatureInvalid (Text.pack (show err))))
        CryptoPassed parsedSignature
            | not (Ed25519.verify key (signedMaterial manifest) parsedSignature) ->
                pure
                    ( Left
                        ( ActivationSignatureInvalid
                            "the grant does not authenticate this manifest"
                        )
                    )
            | otherwise ->
                Right
                    <$> use
                        ( VerifiedRuntimeRoleActivation
                            manifest
                            (measuredInstance measurement)
                            (protectedStoreIdentity store)
                        )

validateMeasuredInstance :: MeasuredInstance -> Either ActivationError ()
validateMeasuredInstance instance' = case instance' of
    KubernetesInstance measuredPodUid _
        | Text.null measuredPodUid ->
            Left (ActivationInstanceInvalid "the measured Kubernetes pod UID is empty")
    HostServiceInstance nonce
        | Text.null nonce ->
            Left (ActivationInstanceInvalid "the measured host invocation nonce is empty")
    _ -> Right ()

firstManifestMismatch ::
    ActivationManifest ->
    ActivationManifest ->
    Maybe (Text, Text, Text)
firstManifestMismatch expected signed = firstDifferent fields
  where
    fields =
        [ ("scope", manifestScope signed, manifestScope expected)
        , ("plan digest", manifestPlanDigest signed, manifestPlanDigest expected)
        , ("spec digest", manifestSpecDigest signed, manifestSpecDigest expected)
        , ("binary digest", manifestBinaryDigest signed, manifestBinaryDigest expected)
        , ("frame", manifestFrame signed, manifestFrame expected)
        , ("revision", manifestRevision signed, manifestRevision expected)
        , ("config digest", manifestConfigDigest signed, manifestConfigDigest expected)
        , ( "secret digest"
          , activationSecretDigestText (manifestSecretDigest signed)
          , activationSecretDigestText (manifestSecretDigest expected)
          )
        , ("service", manifestService signed, manifestService expected)
        , ("role-plan digest", manifestRolePlanDigest signed, manifestRolePlanDigest expected)
        , ( "permitted effects"
          , Text.intercalate "," (manifestPermittedEffects signed)
          , Text.intercalate "," (manifestPermittedEffects expected)
          )
        , ("secret channel", manifestSecretChannel signed, manifestSecretChannel expected)
        ]
    firstDifferent [] = Nothing
    firstDifferent (candidate@(_, actual, wanted) : rest)
        | actual /= wanted = Just candidate
        | otherwise = firstDifferent rest

-- ---------------------------------------------------------------------------
-- Failures

sha256Hex :: ByteString -> Text
sha256Hex payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

data ActivationError
    = ActivationManifestInvalid Text
    | ActivationManifestNotAdmitted
    | ActivationBrokerExpired
    | ActivationSigningKeyInvalid Text
    | ActivationVerificationKeyInvalid Text
    | -- | the signed revision, then the one this process was started for
      ActivationRevisionStale Text Text
    | -- | field, the signed value, then the independently selected value
      ActivationManifestMismatch Text Text Text
    | -- | what, the signed value, then the measured one
      ActivationMeasurementMismatch Text Text Text
    | ActivationInstanceInvalid Text
    | ActivationSignatureInvalid Text
    | -- | the verification store identity, then the supplied session store
      ActivationStoreOriginMismatch Text Text
    deriving (Eq, Show)

activationErrorMessage :: ActivationError -> String
activationErrorMessage err = case err of
    ActivationManifestInvalid detail -> "activation: " <> Text.unpack detail
    ActivationManifestNotAdmitted ->
        "activation: the root signing policy did not admit this exact manifest"
    ActivationBrokerExpired ->
        "activation: the root signing broker has left its active bracket"
    ActivationSigningKeyInvalid detail ->
        "activation: the provisioned signing key is invalid: " <> Text.unpack detail
    ActivationVerificationKeyInvalid detail ->
        "activation: the provisioned verification key is invalid: " <> Text.unpack detail
    ActivationRevisionStale signed expected ->
        "activation: manifest revision "
            <> Text.unpack signed
            <> " is not the started revision "
            <> Text.unpack expected
    ActivationManifestMismatch fieldName signed expected ->
        "activation: signed "
            <> Text.unpack fieldName
            <> " "
            <> show (Text.unpack signed)
            <> " is not the selected value "
            <> show (Text.unpack expected)
    ActivationMeasurementMismatch what signed measured ->
        "activation: "
            <> Text.unpack what
            <> " mismatch (manifest says "
            <> Text.unpack signed
            <> ", measured "
            <> Text.unpack measured
            <> ")"
    ActivationInstanceInvalid detail -> "activation: " <> Text.unpack detail
    ActivationSignatureInvalid detail -> "activation: " <> Text.unpack detail
    ActivationStoreOriginMismatch expected actual ->
        "activation: verified package belongs to protected store "
            <> Text.unpack expected
            <> ", not "
            <> Text.unpack actual
