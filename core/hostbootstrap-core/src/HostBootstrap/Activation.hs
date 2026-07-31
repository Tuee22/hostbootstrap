{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The broker-signed runtime role activation (§ X, Sprint 15.9).

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

Verification therefore refuses a changed ConfigMap or Secret, another project's
key, a stale revision, a different binary or spec, and — because the measured
instance is bound into the result — a value retained from one instance cannot
run as another. The manifest carries only *digests*: no cleartext secret is
representable in it.

Sprint 14.6 consumes 'VerifiedRuntimeRoleActivation' together with the one-use
'LifecycleAdmission' this module reserves, and owns the role plan, cursor, and
phase machine built on top.
-}
module HostBootstrap.Activation (
    -- * The signed manifest
    ActivationManifest (..),
    renderActivationManifest,

    -- * The broker that signs it
    ActivationBroker,
    withActivationBroker,
    activationBrokerKey,
    ActivationGrant,
    activationGrantSignature,
    signActivationManifest,

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
    verifyRuntimeRoleActivation,

    -- * One-use lifecycle admission
    LifecycleAdmission,
    lifecycleAdmissionKey,
    reserveLifecycleAdmission,

    -- * Failures
    ActivationError (..),
    activationErrorMessage,
) where

import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Crypto.Random (getRandomBytes)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (RootInvocationAuthority)
import HostBootstrap.Handoff (
    ProjectVerificationKey,
    frameWire,
    verificationKeyBytes,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedError,
    ProtectedSession,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
 )

-- ---------------------------------------------------------------------------
-- The manifest

{- | Everything the root broker can honestly bind before a workload exists.

Note what is absent: there is no instance identity here. The broker signs the
immutable rollout revision and the controller-template-level indices; the
concrete pod UID or invocation nonce is measured at startup and paired with this
manifest by 'verifyRuntimeRoleActivation'.

Every secret-shaped field is a **digest**. A cleartext secret is not
representable in this type, so it cannot reach a manifest, a pod template, or a
diagnostic rendering of one.
-}
data ActivationManifest = ActivationManifest
    { manifestScope :: Text
    , manifestPlanDigest :: Text
    , manifestSpecDigest :: Text
    , manifestBinaryDigest :: Text
    , manifestFrame :: Text
    , manifestRevision :: Text
    , manifestConfigDigest :: Text
    , manifestSecretDigest :: Text
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
        , field (manifestSecretDigest manifest)
        , field (manifestService manifest)
        , field (manifestRolePlanDigest manifest)
        , frameWire (ByteString.concat (map field (manifestPermittedEffects manifest)))
        , field (manifestSecretChannel manifest)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- The broker

{- | The root broker's activation-signing capability.

A separate keypair from the cross-frame handoff broker, minted from the same
verified root invocation. Keeping the two apart means a captured handoff grant
can never be presented as an activation manifest, and vice versa, without
relying on the two protocols' canonical encodings never colliding.
-}
data ActivationBroker scope brokerGeneration verb = ActivationBroker
    { brokerSecret :: Ed25519.SecretKey
    , brokerPublic :: Ed25519.PublicKey
    }

instance Show (ActivationBroker scope brokerGeneration verb) where
    show _ = "ActivationBroker <signing>"

-- | The public half a runtime must have installed to verify this broker.
activationBrokerKey :: ActivationBroker scope brokerGeneration verb -> ByteString
activationBrokerKey = convert . brokerPublic

{- | Run an action with a fresh activation-signing keypair, minted from a
verified root invocation and never returned from the continuation.
-}
withActivationBroker ::
    RootInvocationAuthority scope brokerGeneration verb ->
    (ActivationBroker scope brokerGeneration verb -> IO result) ->
    IO result
withActivationBroker root use = do
    root `seq` pure ()
    seed <- getRandomBytes 32 :: IO ByteString
    secret <- case Ed25519.secretKey seed of
        CryptoFailed err -> ioError (userError ("activation key generation failed: " <> show err))
        CryptoPassed value -> pure value
    use ActivationBroker{brokerSecret = secret, brokerPublic = Ed25519.toPublic secret}

-- | The broker's signature over one manifest.
newtype ActivationGrant = ActivationGrant ByteString
    deriving (Eq)

instance Show ActivationGrant where
    show _ = "ActivationGrant <signed>"

activationGrantSignature :: ActivationGrant -> ByteString
activationGrantSignature (ActivationGrant value) = value

{- | Sign an activation manifest. Refuses a manifest with an empty revision or
an empty effect row identity, so an unbound rollout cannot be signed.
-}
signActivationManifest ::
    ActivationBroker scope brokerGeneration verb ->
    ActivationManifest ->
    Either ActivationError ActivationGrant
signActivationManifest broker manifest
    | Text.null (manifestRevision manifest) =
        Left (ActivationManifestInvalid "the rollout revision is empty")
    | Text.null (manifestService manifest) =
        Left (ActivationManifestInvalid "the service identity is empty")
    | otherwise =
        Right
            ( ActivationGrant
                ( convert
                    ( Ed25519.sign
                        (brokerSecret broker)
                        (brokerPublic broker)
                        (signedMaterial manifest)
                    )
                )
            )

-- | Domain-separated signing material.
signedMaterial :: ActivationManifest -> ByteString
signedMaterial manifest =
    frameWire "hostbootstrap/activation/v1" <> frameWire (renderActivationManifest manifest)

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
    , -- | the hash of the private-channel bytes actually read
      measuredSecretDigest :: Text
    , measuredInstance :: MeasuredInstance
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The verified package

{- | The inseparable activation package Sprint 14.6 consumes.

Opaque and produced only by 'verifyRuntimeRoleActivation'. It carries the signed
manifest, the measured instance it was paired with, and the protected
secret-channel locator as one value: a caller cannot take the effect row from
one activation and the instance from another, and cannot obtain the locator
without the activation that authorized it.

It confers no lifecycle authority on its own. It cannot construct a
`ProjectPlan`, a generic command authority, or a root authority.
-}
data VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
    = VerifiedRuntimeRoleActivation ActivationManifest MeasuredInstance

instance Show (VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId) where
    show (VerifiedRuntimeRoleActivation manifest instance') =
        "VerifiedRuntimeRoleActivation "
            <> Text.unpack (manifestRevision manifest)
            <> " "
            <> Text.unpack (instanceIdentityText instance')

activationRevision ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationRevision (VerifiedRuntimeRoleActivation manifest _) = manifestRevision manifest

activationInstance ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    MeasuredInstance
activationInstance (VerifiedRuntimeRoleActivation _ instance') = instance'

activationService ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationService (VerifiedRuntimeRoleActivation manifest _) = manifestService manifest

-- | The effect row this activation permits. Sprint 18.6 revalidates it before
-- minting the service command authority; it is not itself effect authority.
activationPermittedEffects ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> [Text]
activationPermittedEffects (VerifiedRuntimeRoleActivation manifest _) =
    manifestPermittedEffects manifest

-- | The protected locator for the run-private bundle, reachable only through a
-- verified activation.
activationSecretChannel ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationSecretChannel (VerifiedRuntimeRoleActivation manifest _) = manifestSecretChannel manifest

{- | The signed parent lifecycle-plan digest. Sprint 14.6 keys the role's durable
lifecycle admission on it and binds the narrowed role plan back to it; the child
never recomputes it from its least-authority wire.
-}
activationPlanDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationPlanDigest (VerifiedRuntimeRoleActivation manifest _) = manifestPlanDigest manifest

activationSpecDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationSpecDigest (VerifiedRuntimeRoleActivation manifest _) = manifestSpecDigest manifest

activationFrame ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationFrame (VerifiedRuntimeRoleActivation manifest _) = manifestFrame manifest

activationConfigDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationConfigDigest (VerifiedRuntimeRoleActivation manifest _) = manifestConfigDigest manifest

activationSecretDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationSecretDigest (VerifiedRuntimeRoleActivation manifest _) = manifestSecretDigest manifest

{- | The signed digest of the narrowed role-plan projection. 'verifyRolePlanDraft'
compares the project's own draft against it before any durable mutation.
-}
activationRolePlanDigest ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId -> Text
activationRolePlanDigest (VerifiedRuntimeRoleActivation manifest _) = manifestRolePlanDigest manifest

{- | Verify a signed manifest against locally measured reality.

The expected revision is supplied by the caller from the controller/pointer it
actually read, so a manifest for a superseded rollout is refused rather than
silently accepted. The verification key is installed independently of the
manifest.
-}
verifyRuntimeRoleActivation ::
    -- | the independently installed project key
    ProjectVerificationKey ->
    -- | the rollout revision this process was started for
    Text ->
    ActivationManifest ->
    ActivationGrant ->
    RuntimeMeasurement ->
    Either
        ActivationError
        (VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId)
verifyRuntimeRoleActivation key expectedRevision manifest (ActivationGrant signature) measurement
    | manifestRevision manifest /= expectedRevision =
        Left (ActivationRevisionStale (manifestRevision manifest) expectedRevision)
    | manifestBinaryDigest manifest /= measuredBinaryDigest measurement =
        Left
            ( ActivationMeasurementMismatch
                "binary"
                (manifestBinaryDigest manifest)
                (measuredBinaryDigest measurement)
            )
    | manifestConfigDigest manifest /= measuredConfigDigest measurement =
        Left
            ( ActivationMeasurementMismatch
                "config"
                (manifestConfigDigest manifest)
                (measuredConfigDigest measurement)
            )
    | manifestSecretDigest manifest /= measuredSecretDigest measurement =
        Left
            ( ActivationMeasurementMismatch
                "secret"
                (manifestSecretDigest manifest)
                (measuredSecretDigest measurement)
            )
    | otherwise = case Ed25519.publicKey (verificationKeyBytes key) of
        CryptoFailed err -> Left (ActivationKeyUnusable (Text.pack (show err)))
        CryptoPassed parsedKey -> case Ed25519.signature signature of
            CryptoFailed err -> Left (ActivationSignatureInvalid (Text.pack (show err)))
            CryptoPassed parsedSignature
                | not (Ed25519.verify parsedKey (signedMaterial manifest) parsedSignature) ->
                    Left
                        ( ActivationSignatureInvalid
                            "the grant does not authenticate this manifest"
                        )
                | otherwise ->
                    Right
                        ( VerifiedRuntimeRoleActivation manifest (measuredInstance measurement)
                        )

-- ---------------------------------------------------------------------------
-- One-use lifecycle admission

{- | Proof that this exact instance reserved its single lifecycle admission.

Sprint 14.6 requires one before Prereq/acquisition, so a duplicated activation
or request cannot open two lifecycle admissions or acquire the same resources
twice.
-}
newtype LifecycleAdmission scope planDigest frame revision instanceId
    = LifecycleAdmission Text

instance Show (LifecycleAdmission scope planDigest frame revision instanceId) where
    show (LifecycleAdmission key) = "LifecycleAdmission " <> Text.unpack key

-- | The durable key this admission was reserved under.
lifecycleAdmissionKey :: LifecycleAdmission scope planDigest frame revision instanceId -> Text
lifecycleAdmissionKey (LifecycleAdmission key) = key

{- | Reserve the one-use admission for a verified activation.

The reservation is a compare-and-swap against absence, keyed on the plan, frame,
revision, and **measured instance**. A second attempt by the same instance is
'ActivationAdmissionConsumed'; a genuinely new instance — a restart, which has a
different restart count — gets its own key and its own admission.
-}
reserveLifecycleAdmission ::
    ProtectedSession session ->
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    IO
        ( Either
            ActivationError
            (LifecycleAdmission scope planDigest frame revision instanceId)
        )
reserveLifecycleAdmission session (VerifiedRuntimeRoleActivation manifest instance') =
    case mkRecordKey rawKey of
        Left failure -> pure (Left (ActivationStoreFailure failure))
        Right key -> do
            written <-
                compareAndSwapProtectedRecord
                    session
                    key
                    ExpectAbsent
                    (renderActivationManifest manifest)
            pure $ case written of
                Left _ -> Left (ActivationAdmissionConsumed rawKey)
                Right _ -> Right (LifecycleAdmission rawKey)
  where
    rawKey =
        Text.filter legal $
            "admission."
                <> manifestPlanDigest manifest
                <> "."
                <> manifestFrame manifest
                <> "."
                <> manifestRevision manifest
                <> "."
                <> instanceIdentityText instance'
    legal character =
        character `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_." :: String)

-- ---------------------------------------------------------------------------
-- Failures

data ActivationError
    = ActivationManifestInvalid Text
    | -- | the signed revision, then the one this process was started for
      ActivationRevisionStale Text Text
    | -- | what, the signed value, then the measured one
      ActivationMeasurementMismatch Text Text Text
    | ActivationSignatureInvalid Text
    | ActivationKeyUnusable Text
    | ActivationAdmissionConsumed Text
    | ActivationStoreFailure ProtectedError
    deriving (Eq, Show)

activationErrorMessage :: ActivationError -> String
activationErrorMessage err = case err of
    ActivationManifestInvalid detail -> "activation: " <> Text.unpack detail
    ActivationRevisionStale signed expected ->
        "activation: manifest revision "
            <> Text.unpack signed
            <> " is not the started revision "
            <> Text.unpack expected
    ActivationMeasurementMismatch what signed measured ->
        "activation: "
            <> Text.unpack what
            <> " mismatch (manifest says "
            <> Text.unpack signed
            <> ", measured "
            <> Text.unpack measured
            <> ")"
    ActivationSignatureInvalid detail -> "activation: " <> Text.unpack detail
    ActivationKeyUnusable detail ->
        "activation: the installed verification key is unusable: " <> Text.unpack detail
    ActivationAdmissionConsumed key ->
        "activation: lifecycle admission " <> Text.unpack key <> " is already reserved"
    ActivationStoreFailure failure -> "activation: " <> Text.unpack (protectedErrorMessage failure)
