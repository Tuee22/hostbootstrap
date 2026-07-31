{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The phase-indexed role lifecycle engine (Sprint 14.6).

This module replaced a public callback bag — @RoleSpec@ with @roleAcquire@ /
@roleServe@ / @roleDrain@, driven by a @runRole@ that was one @finally@ — with
the engine @development_plan_standards.md@ § AA describes.  The difference is
not cosmetic: the old skeleton let any caller assemble an arbitrary phase
sequence, handed the acquired environment straight to project code, and had no
notion of who was allowed to run at all.

What a runtime role must now pass through, in order:

1. an inseparable 'HostBootstrap.Activation.VerifiedRuntimeRoleActivation' — the
   broker-signed manifest paired with the identity the process measured for
   itself (§ X);
2. 'verifyRolePlanDraft', which checks the project's own non-empty draft against
   the manifest's signed @rolePlanDigest@ and performs **no durable mutation**;
3. 'withRoleLifecycleAdmission', which atomically reserves the instance's
   **one-use** durable admission, or reports that a predecessor invocation left
   recovery owed;
4. 'withRuntimeRolePlan', which linearly compare-and-swap-consumes that exact
   reservation and yields the opaque 'RolePlan', its 'RolePlanDigestBinding'
   back to the parent plan digest, the 'VerifiedServicePlacement' carrying the
   signed effect ceiling, and the sole initial cursor — @Prereq@.

After that 'runRoleLifecycle' privately drives Prereq → Acquire → Ready → Serve
→ Drain → Exit.  Project code supplies typed per-resource callbacks and gets
exactly one value back: 'RoleExitReport'.  No phase cursor, receipt, managed
handle, or generation lease is reachable from a project callback, and there is
no serve-time bind/spawn hatch — Serve sees only the names of handles Acquire
created and Ready probed.

Failure branches carry their only legal successor.  A prerequisite refusal
before any acquisition is the only route to 'exitWithNoRoleResources', which
demands the 'VerifiedNoRoleResources' proof; anything after the first
acquisition can reach Exit only through Drain, and Drain carries every owned and
every unknown resource.  The lease requirement is derived from the signed
ceiling **before** Acquire, so a caller cannot select the cheaper no-lease
branch for a role whose permitted effects include an exclusive one.

Sprint 18.6 consumes 'RolePlan' / 'VerifiedServicePlacement' with the finalized
registry to mint the effect-indexed one-use service command authority; this
module deliberately does not decide which handler runs.
-}
module HostBootstrap.RoleLifecycle (
    -- * The descriptive phase labels
    RolePhase (..),
    rolePhases,

    -- * The phase index
    PrereqPhase,
    AcquirePhase,
    ReadyPhase,
    ServePhase,
    DrainPhase,
    ExitPhase,
    RoleCursor,

    -- * The project-owned draft
    RoleResourceRequest,
    mkRoleResourceRequest,
    roleResourceName,
    roleResourceExclusive,
    RolePlanDraft,
    rolePlanDraft,
    rolePlanDraftDigest,
    VerifiedRolePlanDraft,
    verifyRolePlanDraft,

    -- * Effects and the lease requirement they imply
    RoleEffect (..),
    roleEffectName,
    parseRoleEffect,
    roleEffectExclusive,
    LeaseRequirement (..),

    -- * One-use durable lifecycle admission
    ReservedRoleAdmission,
    reservedRoleAdmissionKey,
    RoleAdmissionOutcome (..),
    withRoleLifecycleAdmission,

    -- * The narrowed role plan
    RolePlan,
    rolePlanFrame,
    rolePlanRevision,
    rolePlanInstance,
    rolePlanResourceNames,
    RolePlanDigestBinding,
    rolePlanDigestBindingPlanDigest,
    rolePlanDigestBindingRolePlanDigest,
    VerifiedServicePlacement,
    placementService,
    placementPermittedEffects,
    placementLeaseRequirement,
    withRuntimeRolePlan,

    -- * What a project supplies to the engine
    RoleEngine (..),
    RolePrereqOutcome (..),
    RoleAcquireOutcome (..),
    RoleProbeOutcome (..),
    RoleServeOutcome (..),
    RoleReleaseOutcome (..),
    ReadyRoleHandles,
    readyRoleHandleNames,

    -- * The engine and its only public result
    VerifiedNoRoleResources,
    RoleExitReport (..),
    roleExitReportOk,
    renderRoleExitReport,
    runRoleLifecycle,

    -- * Failures
    RoleLifecycleError (..),
    roleLifecycleErrorMessage,
) where

import Control.Exception.Safe (SomeException, displayException, mask, try)
import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (group, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Activation (
    VerifiedRuntimeRoleActivation,
    activationFrame,
    activationInstance,
    activationPermittedEffects,
    activationPlanDigest,
    activationRevision,
    activationRolePlanDigest,
    activationService,
    instanceIdentityText,
 )
import HostBootstrap.Handoff (frameWire)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedSession,
    ProtectedStore,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    protectedRecordBytes,
    readProtectedRecord,
    withRunLiveness,
 )

-- ---------------------------------------------------------------------------
-- Descriptive labels

{- | The historical Sprint 14.2 phase labels, retained for rendering and
reporting only.  @Load@ survives as a label: activation, config, secret, and
role-plan verification all happen *before* a cursor exists, and the sole initial
cursor is @Prereq@ (there is no @RoleCursor … LoadPhase@).
-}
data RolePhase = Load | Prereq | Acquire | Ready | Serve | Drain | Exit
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | The labels in order. Pure.
rolePhases :: [RolePhase]
rolePhases = [minBound .. maxBound]

-- ---------------------------------------------------------------------------
-- Phase index

data PrereqPhase
data AcquirePhase
data ReadyPhase
data ServePhase
data DrainPhase
data ExitPhase

{- | The engine's position in the phase machine.

Its constructor is not exported and it has no public eliminator, so project code
cannot fabricate a cursor, retain one past its phase, or serve before Ready.
-}
newtype RoleCursor scope planId frame instanceId phase = RoleCursor RolePhase

instance Show (RoleCursor scope planId frame instanceId phase) where
    show (RoleCursor phase) = "RoleCursor " <> show phase

-- ---------------------------------------------------------------------------
-- The project-owned draft

{- | One resource the role must hold before it can serve.

The @exclusive@ flag is the project's declaration that acquiring this resource
mutates state another instance could also be mutating.  It does not *decide* the
lease requirement — that comes from the signed effect ceiling, which a project
cannot edit — but a draft declaring an exclusive resource under a ceiling that
permits no exclusive effect is refused, so the two cannot disagree silently.
-}
data RoleResourceRequest = RoleResourceRequest Text Bool
    deriving (Eq, Ord, Show)

mkRoleResourceRequest :: Text -> Bool -> Either RoleLifecycleError RoleResourceRequest
mkRoleResourceRequest name exclusive
    | Text.null name = Left (RoleDraftInvalid "a role resource name must not be empty")
    | Text.any (\character -> character == '\n' || character == '\0') name =
        Left (RoleDraftInvalid ("a role resource name must be one plain line: " <> name))
    | otherwise = Right (RoleResourceRequest name exclusive)

roleResourceName :: RoleResourceRequest -> Text
roleResourceName (RoleResourceRequest name _) = name

roleResourceExclusive :: RoleResourceRequest -> Bool
roleResourceExclusive (RoleResourceRequest _ exclusive) = exclusive

{- | A project's declared acquisition plan for one role instance.  Deliberately
unindexed: it is untrusted project description until 'verifyRolePlanDraft'
compares it with the manifest the broker signed.
-}
newtype RolePlanDraft = RolePlanDraft [RoleResourceRequest]
    deriving (Eq, Show)

-- | Build a draft. Refuses an empty draft and duplicate resource names.
rolePlanDraft :: [RoleResourceRequest] -> Either RoleLifecycleError RolePlanDraft
rolePlanDraft requests
    | null requests =
        Left (RoleDraftInvalid "a role plan draft must declare at least one resource")
    | not (null duplicates) =
        Left
            ( RoleDraftInvalid
                ("duplicate role resource names: " <> Text.intercalate ", " duplicates)
            )
    | otherwise = Right (RolePlanDraft requests)
  where
    duplicates = [name | (name : _ : _) <- group (sort (map roleResourceName requests))]

{- | The draft's canonical digest.  A project renders this the same way when it
asks the root broker to sign the manifest, so the runtime comparison is exact
rather than structural.  Fields are length-prefixed, so two resource names
cannot be re-read as one longer name.
-}
rolePlanDraftDigest :: RolePlanDraft -> Text
rolePlanDraftDigest (RolePlanDraft requests) =
    sha256Hex
        ( frameWire "hostbootstrap/role-plan-draft/v1"
            <> ByteString.concat
                [ frameWire (TextEncoding.encodeUtf8 (roleResourceName request))
                    <> frameWire (if roleResourceExclusive request then "exclusive" else "shared")
                | request <- requests
                ]
        )

{- | The draft after it has been proved to be the one the broker signed.

The fresh @rolePlanDigest@ index is minted inside 'verifyRolePlanDraft''s
continuation, so a draft verified for one activation cannot be presented with
another.
-}
data VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest
    = VerifiedRolePlanDraft [RoleResourceRequest] Text

{- | Check a project draft against the activation, with **no durable mutation**.

Refuses an empty signed digest, a draft that does not render to the signed
@rolePlanDigest@, an unparseable entry in the signed effect row, and a draft
declaring an exclusive resource when the ceiling permits no exclusive effect.
-}
verifyRolePlanDraft ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    RolePlanDraft ->
    ( forall rolePlanDigest.
      VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest ->
      result
    ) ->
    Either RoleLifecycleError result
verifyRolePlanDraft activation draft@(RolePlanDraft requests) consume = do
    effects <- parsePermittedEffects (activationPermittedEffects activation)
    let signed = activationRolePlanDigest activation
        computed = rolePlanDraftDigest draft
    if
        | Text.null signed ->
            Left (RoleDraftInvalid "the manifest signs an empty role-plan digest")
        | computed /= signed -> Left (RoleDraftDigestMismatch signed computed)
        | any roleResourceExclusive requests
        , leaseRequirementOf effects == NoExclusiveEffects ->
            Left
                ( RoleDraftInvalid
                    "the draft declares an exclusive resource but the signed effect ceiling permits none"
                )
        | otherwise -> Right (consume (VerifiedRolePlanDraft requests computed))

-- ---------------------------------------------------------------------------
-- Effects and the lease requirement

{- | The closed effect family a signed ceiling may name.  An unparseable entry is
refused rather than assumed harmless, because the ceiling is what decides whether
a live generation lease is required.
-}
data RoleEffect
    = NetworkListen
    | NetworkConnect
    | DurableStore
    | ProcessSpawn
    deriving (Eq, Ord, Show, Enum, Bounded)

roleEffectName :: RoleEffect -> Text
roleEffectName effect = case effect of
    NetworkListen -> "network-listen"
    NetworkConnect -> "network-connect"
    DurableStore -> "durable-store"
    ProcessSpawn -> "process"

parseRoleEffect :: Text -> Maybe RoleEffect
parseRoleEffect raw =
    case [effect | effect <- [minBound .. maxBound], roleEffectName effect == raw] of
        (effect : _) -> Just effect
        [] -> Nothing

-- | Whether an effect mutates state another instance could also be mutating.
roleEffectExclusive :: RoleEffect -> Bool
roleEffectExclusive effect = case effect of
    NetworkListen -> False
    NetworkConnect -> False
    DurableStore -> True
    ProcessSpawn -> True

parsePermittedEffects :: [Text] -> Either RoleLifecycleError [RoleEffect]
parsePermittedEffects = traverse parseOne
  where
    parseOne value = case parseRoleEffect value of
        Just effect -> Right effect
        Nothing -> Left (RoleEffectUnsupported value)

{- | What the run must hold.  Derived from the signed ceiling before Acquire;
never selected by a caller.
-}
data LeaseRequirement
    = -- | the ceiling prohibits every exclusive/mutating effect
      NoExclusiveEffects
    | -- | an exclusive generation lease must be held through Drain
      RequiresGenerationLease
    deriving (Eq, Show)

leaseRequirementOf :: [RoleEffect] -> LeaseRequirement
leaseRequirementOf effects
    | any roleEffectExclusive effects = RequiresGenerationLease
    | otherwise = NoExclusiveEffects

-- ---------------------------------------------------------------------------
-- One-use durable lifecycle admission

{- | Proof that this exact instance reserved — and has not yet consumed — its
single lifecycle admission.  It carries the protected record version it was
observed at, so consumption is a compare-and-swap against that exact version.
-}
data ReservedRoleAdmission scope planDigest frame revision instanceId
    = ReservedRoleAdmission Text Expectation

instance Show (ReservedRoleAdmission scope planDigest frame revision instanceId) where
    show (ReservedRoleAdmission key _) = "ReservedRoleAdmission " <> Text.unpack key

reservedRoleAdmissionKey :: ReservedRoleAdmission scope planDigest frame revision instanceId -> Text
reservedRoleAdmissionKey (ReservedRoleAdmission key _) = key

{- | The total classification of one admission attempt.

A predecessor record for the same instance is never silently overwritten: an
existing record is recovery-required state, and a lost acknowledgement is its own
'RoleAdmissionUnknown' rather than an error.
-}
data RoleAdmissionOutcome scope planDigest frame revision instanceId
    = RoleAdmissionReserved (ReservedRoleAdmission scope planDigest frame revision instanceId)
    | -- | the admission key, then the predecessor record's own text
      RoleAdmissionRecoveryRequired Text Text
    | -- | the reservation write's outcome is not known
      RoleAdmissionUnknown Text

{- | Atomically reserve the instance's one-use lifecycle admission.

The key binds the parent plan digest, the frame, the immutable rollout revision,
and the **measured** instance, so a genuine restart (a different container
restart count, or a fresh host invocation nonce) gets its own admission while a
duplicated activation does not.  The reserved value records the verified
role-plan digest, so a resumption cannot silently change the plan the admission
was taken for.
-}
withRoleLifecycleAdmission ::
    ProtectedSession session ->
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest ->
    IO (RoleAdmissionOutcome scope planDigest frame revision instanceId)
withRoleLifecycleAdmission session activation (VerifiedRolePlanDraft _ digest) =
    case mkRecordKey rawKey of
        Left failure -> pure (RoleAdmissionUnknown (protectedErrorMessage failure))
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (RoleAdmissionUnknown (protectedErrorMessage failure))
                Right (Just record) ->
                    pure
                        ( RoleAdmissionRecoveryRequired
                            rawKey
                            (TextEncoding.decodeUtf8Lenient (protectedRecordBytes record))
                        )
                Right Nothing -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            ExpectAbsent
                            (TextEncoding.encodeUtf8 ("reserved " <> digest))
                    pure $ case written of
                        Left failure ->
                            RoleAdmissionUnknown (rawKey <> ": " <> protectedErrorMessage failure)
                        Right version ->
                            RoleAdmissionReserved
                                (ReservedRoleAdmission rawKey (ExpectVersion version))
  where
    rawKey = roleAdmissionKey activation

roleAdmissionKey ::
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    Text
roleAdmissionKey activation =
    Text.filter legalKeyCharacter $
        "role-admission."
            <> activationPlanDigest activation
            <> "."
            <> activationFrame activation
            <> "."
            <> activationRevision activation
            <> "."
            <> instanceIdentityText (activationInstance activation)

legalKeyCharacter :: Char -> Bool
legalKeyCharacter character =
    character
        `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_." :: String)

-- ---------------------------------------------------------------------------
-- The narrowed role plan

{- | The role's own narrowed plan.  It is **not** a lifecycle @ProjectPlan@: it
has no reverse projection, mints no root authority, and does not claim to
recompute the parent's plan digest.
-}
data RolePlan scope specDigest planId configId secretDigest frame revision instanceId
    = RolePlan Text Text Text [RoleResourceRequest]

rolePlanFrame :: RolePlan scope specDigest planId configId secretDigest frame revision instanceId -> Text
rolePlanFrame (RolePlan frame _ _ _) = frame

rolePlanRevision :: RolePlan scope specDigest planId configId secretDigest frame revision instanceId -> Text
rolePlanRevision (RolePlan _ revision _ _) = revision

rolePlanInstance :: RolePlan scope specDigest planId configId secretDigest frame revision instanceId -> Text
rolePlanInstance (RolePlan _ _ instanceText _) = instanceText

-- | The resource names the plan will acquire, for diagnostics only.
rolePlanResourceNames ::
    RolePlan scope specDigest planId configId secretDigest frame revision instanceId -> [Text]
rolePlanResourceNames (RolePlan _ _ _ requests) = map roleResourceName requests

{- | The proof that this narrowed role plan belongs to the parent lifecycle plan
the broker signed.  It states "my @rolePlanDigest@ was signed under that
@planDigest@" — not "I recomputed the parent plan from my least-authority wire".
-}
data RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId
    = RolePlanDigestBinding Text Text

rolePlanDigestBindingPlanDigest ::
    RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId -> Text
rolePlanDigestBindingPlanDigest (RolePlanDigestBinding value _) = value

rolePlanDigestBindingRolePlanDigest ::
    RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId -> Text
rolePlanDigestBindingRolePlanDigest (RolePlanDigestBinding _ value) = value

{- | The placement Sprint 18.6 revalidates before it mints a service command
authority.  It carries the signed effect ceiling and the lease requirement
derived from it.
-}
data VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects
    = VerifiedServicePlacement Text [RoleEffect] LeaseRequirement

placementService ::
    VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects ->
    Text
placementService (VerifiedServicePlacement service _ _) = service

placementPermittedEffects ::
    VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects ->
    [RoleEffect]
placementPermittedEffects (VerifiedServicePlacement _ effects _) = effects

placementLeaseRequirement ::
    VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects ->
    LeaseRequirement
placementLeaseRequirement (VerifiedServicePlacement _ _ requirement) = requirement

{- | Linearly consume the exact reservation and open the role plan.

The compare-and-swap is against the version the reservation was observed at, so
two holders of the same reservation value have exactly one winner and the loser
sees 'RoleAdmissionAlreadyConsumed'.  The plan, binding, placement, and the sole
@Prereq@ cursor are minted together inside a rank-2 continuation, so a caller
cannot choose the plan identity, keep the cursor, or reserve a second one.
-}
withRuntimeRolePlan ::
    ProtectedSession session ->
    VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId ->
    VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest ->
    ReservedRoleAdmission scope planDigest frame revision instanceId ->
    ( forall planId configId secretDigest service permittedEffects.
      RolePlan scope specDigest planId configId secretDigest frame revision instanceId ->
      RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId ->
      VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects ->
      RoleCursor scope planId frame instanceId PrereqPhase ->
      IO result
    ) ->
    IO (Either RoleLifecycleError result)
withRuntimeRolePlan
    session
    activation
    (VerifiedRolePlanDraft requests digest)
    (ReservedRoleAdmission rawKey expectation)
    use =
        case parsePermittedEffects (activationPermittedEffects activation) of
            Left failure -> pure (Left failure)
            Right effects -> case mkRecordKey rawKey of
                Left failure -> pure (Left (RoleAdmissionStoreFailure failure))
                Right key -> do
                    consumed <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            expectation
                            (TextEncoding.encodeUtf8 ("consumed " <> digest))
                    case consumed of
                        Left _ -> pure (Left (RoleAdmissionAlreadyConsumed rawKey))
                        Right _ ->
                            Right
                                <$> use
                                    ( RolePlan
                                        (activationFrame activation)
                                        (activationRevision activation)
                                        (instanceIdentityText (activationInstance activation))
                                        requests
                                    )
                                    (RolePlanDigestBinding (activationPlanDigest activation) digest)
                                    ( VerifiedServicePlacement
                                        (activationService activation)
                                        effects
                                        (leaseRequirementOf effects)
                                    )
                                    (RoleCursor Prereq)

-- ---------------------------------------------------------------------------
-- Retained resources

{- | An acquired resource the engine owns.  Private: a project callback never
receives one, so it cannot release a resource out from under Drain.
-}
data RoleReceipt = RoleReceipt
    { receiptResource :: RoleResourceRequest
    , receiptState :: ReceiptState
    }

data ReceiptState
    = -- | acquisition was acknowledged
      ReceiptOwned
    | -- | the acquisition call's outcome is not known; Drain must reprobe
      ReceiptUnknown
    deriving (Eq, Show)

{- | Proof that a role reached Exit without acquiring anything.  Only a refusal
that provably precedes the first acquisition produces one, which is what § Y
means by "only a refusal proven to precede every acquisition has an empty
rollback set".
-}
data VerifiedNoRoleResources scope planId frame instanceId
    = VerifiedNoRoleResources

{- | The identities Serve may use.  Read-only, populated only from resources
Acquire created and Ready probed, so there is no serve-time bind/spawn hatch.
-}
newtype ReadyRoleHandles = ReadyRoleHandles [Text]

readyRoleHandleNames :: ReadyRoleHandles -> [Text]
readyRoleHandleNames (ReadyRoleHandles names) = names

-- ---------------------------------------------------------------------------
-- The project's callbacks

-- | The prerequisite check's total outcome.
data RolePrereqOutcome
    = PrereqSatisfied
    | PrereqRefused Text
    deriving (Eq, Show)

{- | One acquisition's total outcome.  @AcquireUnknown@ is not a failure label:
it records that the call's result is unknown, so Drain still reprobes it.
-}
data RoleAcquireOutcome
    = Acquired
    | AcquireFailed Text
    | AcquireUnknown Text
    deriving (Eq, Show)

-- | One readiness probe's total outcome.
data RoleProbeOutcome
    = ProbeReadyNow
    | ProbeNotReady Text
    | ProbeTerminal Text
    deriving (Eq, Show)

-- | Serve's total outcome. A catchable controller shutdown is not a failure.
data RoleServeOutcome
    = ServeCompleted
    | ServeShutdown Text
    | ServeFailed Text
    deriving (Eq, Show)

-- | One release's total outcome.
data RoleReleaseOutcome
    = Released
    | ReleaseFailed Text
    deriving (Eq, Show)

{- | What a project contributes.  Every callback is per-resource or takes only
'ReadyRoleHandles': none can observe a cursor, a receipt, or the lease.
-}
data RoleEngine = RoleEngine
    { enginePrereq :: IO RolePrereqOutcome
    , engineAcquire :: RoleResourceRequest -> IO RoleAcquireOutcome
    , engineProbe :: RoleResourceRequest -> IO RoleProbeOutcome
    , engineServe :: ReadyRoleHandles -> IO RoleServeOutcome
    , engineRelease :: RoleResourceRequest -> IO RoleReleaseOutcome
    }

-- ---------------------------------------------------------------------------
-- The report

{- | The only value project code receives from the engine.  It names where the
role turned around, whether it got there cleanly, and every cleanup failure Drain
aggregated — Drain attempts each independent release even when an earlier one
fails.
-}
data RoleExitReport = RoleExitReport
    { exitTurnedAtPhase :: RolePhase
    , exitReason :: Maybe Text
    , exitDrainFailures :: [Text]
    , exitOwnedResources :: [Text]
    , exitUnknownResources :: [Text]
    }
    deriving (Eq, Show)

roleExitReportOk :: RoleExitReport -> Bool
roleExitReportOk report =
    case exitReason report of
        Just _ -> False
        Nothing -> null (exitDrainFailures report) && null (exitUnknownResources report)

renderRoleExitReport :: RoleExitReport -> String
renderRoleExitReport report =
    Text.unpack
        ( Text.intercalate
            "\n"
            ( ("role exit: turned at " <> Text.pack (show (exitTurnedAtPhase report)))
                : concat
                    [ ["  reason: " <> reason | Just reason <- [exitReason report]]
                    , ["  drain failure: " <> failure | failure <- exitDrainFailures report]
                    , ["  unknown: " <> name | name <- exitUnknownResources report]
                    ]
            )
        )

{- | The only route to Exit with an empty rollback set.  It demands the proof, so
a branch that acquired something cannot report itself as a pre-effect refusal.
-}
exitWithNoRoleResources ::
    VerifiedNoRoleResources scope planId frame instanceId -> Text -> RoleExitReport
exitWithNoRoleResources VerifiedNoRoleResources reason =
    RoleExitReport
        { exitTurnedAtPhase = Prereq
        , exitReason = Just reason
        , exitDrainFailures = []
        , exitOwnedResources = []
        , exitUnknownResources = []
        }

-- ---------------------------------------------------------------------------
-- The engine

{- | Drive Prereq → Acquire → Ready → Serve → Drain → Exit.

The body runs under 'mask', with each project callback restored individually, so
a catchable asynchronous shutdown lands inside a callback and is converted to
that callback's typed branch rather than escaping between Acquire and Drain.  A
callback that throws therefore cannot skip Drain.

When the signed ceiling requires it, the whole Acquire→Drain bracket is held
inside 'withRunLiveness' — the § EE clause-1 primitive, a kernel lock the OS
releases on process death.  A live exclusive predecessor is refused *before* the
first acquisition, so the refusal carries 'VerifiedNoRoleResources'; a dead one
never blocks, because the kernel already released its lock.
-}
runRoleLifecycle ::
    ProtectedStore ->
    RolePlan scope specDigest planId configId secretDigest frame revision instanceId ->
    VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects ->
    RoleCursor scope planId frame instanceId PrereqPhase ->
    RoleEngine ->
    IO RoleExitReport
runRoleLifecycle store plan placement _cursor engine =
    case placementLeaseRequirement placement of
        NoExclusiveEffects -> drive
        RequiresGenerationLease -> do
            held <- withRunLiveness store leaseName drive
            pure $ case held of
                Left failure ->
                    exitWithNoRoleResources
                        (noRoleResources plan)
                        ("the exclusive generation lease is unavailable: " <> protectedErrorMessage failure)
                Right Nothing ->
                    exitWithNoRoleResources
                        (noRoleResources plan)
                        ( "another live instance holds the exclusive generation lease for "
                            <> placementService placement
                            <> " in frame "
                            <> rolePlanFrame plan
                        )
                Right (Just report) -> report
  where
    leaseName =
        Text.filter legalKeyCharacter
            ("role-lease." <> placementService placement <> "." <> rolePlanFrame plan)

    requests = planRequests plan

    drive = mask $ \restoreIO -> do
        let restore = Restore restoreIO
        prereq <- guarded restore (PrereqRefused . exceptionText) (enginePrereq engine)
        case prereq of
            PrereqRefused reason ->
                pure (exitWithNoRoleResources (noRoleResources plan) reason)
            PrereqSatisfied -> acquirePhase restore

    acquirePhase restore = go [] requests
      where
        go held [] = readyPhase restore (reverse held)
        go held (request : rest) = do
            outcome <-
                guarded restore (AcquireUnknown . exceptionText) (engineAcquire engine request)
            case outcome of
                Acquired -> go (RoleReceipt request ReceiptOwned : held) rest
                AcquireUnknown detail ->
                    -- The call may have landed, so the resource is retained for
                    -- Drain and the role does not proceed on partial acquisition.
                    drainPhase
                        restore
                        Acquire
                        ( Just
                            ( "acquiring "
                                <> roleResourceName request
                                <> " has an unknown outcome: "
                                <> detail
                            )
                        )
                        (reverse (RoleReceipt request ReceiptUnknown : held))
                AcquireFailed detail ->
                    drainPhase
                        restore
                        Acquire
                        (Just ("acquiring " <> roleResourceName request <> " failed: " <> detail))
                        (reverse held)

    readyPhase restore held = go [] held
      where
        go probed [] = servePhase restore held (ReadyRoleHandles (reverse probed))
        go probed (receipt : rest) = do
            outcome <-
                guarded
                    restore
                    (ProbeTerminal . exceptionText)
                    (engineProbe engine (receiptResource receipt))
            case outcome of
                ProbeReadyNow -> go (roleResourceName (receiptResource receipt) : probed) rest
                ProbeNotReady detail -> notReady receipt "is not ready" detail
                ProbeTerminal detail -> notReady receipt "failed its readiness probe" detail
        notReady receipt what detail =
            drainPhase
                restore
                Ready
                (Just (roleResourceName (receiptResource receipt) <> " " <> what <> ": " <> detail))
                held

    servePhase restore held ready = do
        outcome <- guarded restore (ServeFailed . exceptionText) (engineServe engine ready)
        case outcome of
            ServeCompleted -> drainPhase restore Serve Nothing held
            ServeShutdown detail -> drainPhase restore Serve (Just ("shutdown: " <> detail)) held
            ServeFailed detail -> drainPhase restore Serve (Just ("serve failed: " <> detail)) held

    -- Drain attempts every independent release regardless of individual failures,
    -- then aggregates. It is the sole producer of Exit once anything is acquired.
    drainPhase restore turnedAt reason held = do
        failures <- traverse release held
        pure
            RoleExitReport
                { exitTurnedAtPhase = turnedAt
                , exitReason = reason
                , exitDrainFailures = concat failures
                , exitOwnedResources = namesWith ReceiptOwned
                , exitUnknownResources = namesWith ReceiptUnknown
                }
      where
        namesWith state =
            [ roleResourceName (receiptResource receipt)
            | receipt <- held
            , receiptState receipt == state
            ]
        release receipt = do
            outcome <-
                guarded
                    restore
                    (ReleaseFailed . exceptionText)
                    (engineRelease engine (receiptResource receipt))
            pure $ case outcome of
                Released -> []
                ReleaseFailed detail ->
                    [roleResourceName (receiptResource receipt) <> ": " <> detail]

    guarded restore toFailure action = do
        outcome <- try (unRestore restore action)
        pure $ case outcome of
            Right value -> value
            Left failure -> toFailure failure

planRequests ::
    RolePlan scope specDigest planId configId secretDigest frame revision instanceId ->
    [RoleResourceRequest]
planRequests (RolePlan _ _ _ requests) = requests

{- | The empty-rollback proof, available only where the engine can show nothing
was acquired.  It is private, so project code cannot manufacture it.
-}
noRoleResources ::
    RolePlan scope specDigest planId configId secretDigest frame revision instanceId ->
    VerifiedNoRoleResources scope planId frame instanceId
noRoleResources _ = VerifiedNoRoleResources

{- | 'mask' hands back a rank-2 @restore@; wrapping it keeps it polymorphic when
the phase functions pass it to one another.
-}
newtype Restore = Restore {unRestore :: forall value. IO value -> IO value}

exceptionText :: SomeException -> Text
exceptionText = Text.pack . displayException

-- ---------------------------------------------------------------------------
-- Failures

data RoleLifecycleError
    = RoleDraftInvalid Text
    | -- | the signed digest, then the one this binary's draft renders to
      RoleDraftDigestMismatch Text Text
    | RoleEffectUnsupported Text
    | RoleAdmissionAlreadyConsumed Text
    | RoleAdmissionStoreFailure ProtectedError
    deriving (Eq, Show)

roleLifecycleErrorMessage :: RoleLifecycleError -> String
roleLifecycleErrorMessage failure = case failure of
    RoleDraftInvalid detail -> "role lifecycle: " <> Text.unpack detail
    RoleDraftDigestMismatch signed computed ->
        "role lifecycle: the manifest signs role plan "
            <> Text.unpack signed
            <> " but this binary's draft renders to "
            <> Text.unpack computed
    RoleEffectUnsupported value ->
        "role lifecycle: the signed effect ceiling names an unsupported effect: "
            <> Text.unpack value
    RoleAdmissionAlreadyConsumed key ->
        "role lifecycle: lifecycle admission " <> Text.unpack key <> " is already consumed"
    RoleAdmissionStoreFailure detail ->
        "role lifecycle: " <> Text.unpack (protectedErrorMessage detail)

-- ---------------------------------------------------------------------------
-- Helpers

sha256Hex :: ByteString -> Text
sha256Hex payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte =
        [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
        , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
        ]
