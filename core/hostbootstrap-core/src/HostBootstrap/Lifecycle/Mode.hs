{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Project-wide lifecycle mode, run leases, and the lifecycle-profile openers
(§ EE and the lifecycle-modes-and-run-leases phase).

A project is in exactly one mode at a time — Production or one Harness run — and
that exclusion is a single protected record both openers contend on.  Production
retains its mode across @down@; a Harness run releases its mode only after
terminal close.  Neither profile can slip between a precondition check and
ownership, because the check is re-run inside the same compare-and-swap that
takes the mode.

The run lease is the second half. An opener records an 'UnboundRunLease' before
it has a plan; only after the plan snapshot is persisted and verified can the
fresh-only 'bindRunLease' produce the 'BoundRunLease' that every later effect
requires. Existing Production admission is read-only and is exposed only by
@withBoundPlanSnapshot@ in "HostBootstrap.ProjectPlan.Snapshot"; abandoned
Harness leases are classified by the sweep. A crash therefore always leaves a
durable, classifiable lease rather than an opaque lock directory:

* an unbound incomplete lease can be closed by the sweep once
  'verifyUnboundLeaseHasNoEffects' proves it recorded no effect;
* a bound incomplete lease is reopened through 'withAbandonedHarnessRun', which
  rechecks it, reads back its snapshot, classifies its durable invocation record,
  and yields @destroy@-only recovery and close authority on a fresh broker
  generation. A new run is not allocated until every old lease closes.

That is the direct replacement for the bare @createDirectory@ ownership claim
whose crash left @.test_data@ and @.test_data.hostbootstrap-run-owner@ behind
with no way to tell a dead predecessor from a live one.

This module is also the public plan-bound lifecycle facade. It exposes the
opaque 'AcquisitionJournal' and 'LifecycleCursor', current-phase discovery, and
the two legal cursor successors. "HostBootstrap.Lifecycle.Session" owns their
protected keys, canonical codecs, exact-source checks, and compare-and-swap
implementation; callers do not assemble those durable bindings here.
-}
module HostBootstrap.Lifecycle.Mode (
    -- * Run identity
    RunId,
    runIdText,

    -- * Modes
    ProductionMode,
    HarnessMode,
    ProjectModeLease,
    projectModeLeaseName,
    projectModeLeaseEpoch,
    ActiveProjectMode,
    activeProjectModeEpoch,
    productionActiveMode,
    harnessActiveMode,

    -- * Plan snapshots
    VerifiedPlanSnapshot,
    planSnapshotRunText,
    planSnapshotProjectName,
    planSnapshotStoreIdentity,
    planSnapshotRevision,
    planSnapshotSpecDigest,
    planSnapshotPlanDigest,
    planSnapshotConfigDigest,
    planSnapshotCanonicalBytes,
    PlanSnapshotView,
    planSnapshotViewRevision,
    planSnapshotViewSpecDigest,
    planSnapshotViewPlanDigest,
    planSnapshotViewConfigDigest,
    planSnapshotViewCanonicalBytes,
    inspectPlanSnapshot,
    persistPlanSnapshot,
    persistCanonicalPlanSnapshot,
    verifyPlanSnapshot,
    verifyIndexedPlanSnapshot,
    validateFreshPlanSnapshotEvidence,
    persistAndVerifyIndexedPlanSnapshotKernel,

    -- * Run leases
    UnboundRunLease,
    unboundRunLeaseRunText,
    BoundRunLease,
    boundRunLeaseRunText,
    boundRunLeaseSpecDigest,
    boundRunLeasePlanDigest,
    AcquisitionJournal,
    acquisitionJournalStableScope,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalRunLease,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    withAcquisitionJournalPhase,
    withAcquisitionJournal,
    reopenAuthenticatedChildCursorKernel,
    reopenAuthenticatedRecoveryChildCursorKernel,
    validateBoundRunLeaseAcquisitionJournal,
    LifecycleCursor,
    lifecycleCursorFrame,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    lifecycleCursorPhase,
    lifecycleCursorMatchesCommandAuthority,
    validateCurrentLifecycleCursor,
    withLifecycleCursor,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withTeardownLifecycleCursor,
    NormalActiveRecovery,
    normalActiveRecoveryRunText,
    bindRunLease,
    bindRunLeaseWithPlanRecovery,
    LeaseConflict,
    leaseConflictMessage,

    -- * Bound-invocation recovery
    BoundInvocationRecovery,
    boundInvocationRecoveryRunText,
    boundInvocationRecoveryRevisionKind,
    withBoundPlanSnapshotKernel,
    withFreshExistingBoundReverseRootKernel,
    withResumedExistingBoundReverseRootKernel,
    OpenRevisionRecovery,
    openRevisionRecoveryRunText,
    OpenRevisionKind (..),
    openRevisionKind,
    HarnessBoundRecovery (..),
    classifyAbandonedBoundRun,
    InvocationCloseKey,
    mkInvocationCloseKey,
    invocationCloseKeyText,
    recordProductionInvocationAcknowledgment,
    recordHarnessClosingEpoch,
    recordOpenRevisionMigration,
    readRecordedOpenRevisionKind,

    -- * Lifecycle profiles
    LifecycleProfile,
    lifecycleProfileName,
    lifecycleProfileEpoch,
    lifecycleProfileProjectName,
    lifecycleProfileStoreIdentity,
    withProductionLifecycleProfile,
    withHarnessLifecycleProfile,
    RecoveredProductionLifecycleProfile,
    recoveredProductionProfileRunText,
    recoveredProductionProfileProjectName,
    recoveredProductionProfileStoreIdentity,
    recoveredProductionProfileRevision,
    recoveredProductionProfileSpecDigest,
    recoveredProductionProfilePlanDigest,
    recoveredProductionProfileConfigDigest,
    recoveredProductionProfileCanonicalBytes,
    recoveredProductionProfileEpoch,
    recoveredProductionProfileRevisionKind,
    withRecoveredProductionLifecycleProfile,

    -- * Plan migration
    StableMigrationKey,
    stableMigrationKeyText,
    ProspectivePlanSnapshot,
    prospectiveSnapshotKey,
    prospectiveSnapshotSpecDigest,
    prospectiveSnapshotPlanDigest,
    ProjectUpMigrationProfile,
    migrationProfileRun,
    migrationProfileOldSpecDigest,
    migrationProfileOldPlanDigest,
    migrationProfileEpoch,
    withProjectUpMigrationProfile,
    withProspectiveMigrationPlan,
    FrozenMigrationRunLease,
    frozenMigrationKey,
    frozenMigrationRun,
    withPlanMigration,
    PlanMigrationBarrier,
    migrationBarrierKey,
    migrationBarrierOldPlanDigest,
    migrationBarrierNewPlanDigest,
    commitMigrationActivation,
    activateMigratedPlan,
    withCompletedMigrationRecovery,

    -- * Composite root brackets
    ProductionRoot,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withProductionRoot,
    HarnessRoot,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    harnessRootRunId,
    harnessRootModeLease,
    harnessRootUnboundLease,
    withHarnessRoot,

    -- * Harness safety preconditions
    HarnessPreconditions,
    harnessPreconditions,
    harnessPreconditionProbe,
    HarnessPreconditionFailure (..),

    -- * Production invocation close
    ProductionInvocationCompleted,
    productionInvocationCompletedRun,
    completeProductionInvocation,
    ProductionInvocationClose (..),
    ProductionInvocationClosed,
    productionInvocationClosedRun,
    closeCompletedProductionInvocation,

    -- * Harness terminal close
    HarnessCloseOrigin (..),
    HarnessCloseRoot,
    currentHarnessCloseRoot,
    harnessCloseRootRun,
    harnessCloseRootOrigin,
    HarnessCloseAuthorization,
    harnessCloseEpoch,
    harnessCloseRun,
    harnessCloseOrigin,
    authorizeHarnessClose,
    resumeHarnessClose,
    ClosedHarnessProject,
    closedHarnessProjectRun,
    finalizeHarnessClose,

    -- * Closure
    ProjectClosureEvidence,
    projectClosureEvidenceKind,
    verifyNoProjectResourcesAcquired,
    verifyBoundRunHasNoProjectResourcesAcquired,
    destroySettledClosure,
    verifyUnboundLeaseHasNoEffects,
    VerifiedUnboundLeaseHasNoEffects,
    releaseProductionMode,
    closeHarnessRun,

    -- * Abandoned-run recovery
    VerifiedIncompleteRunLease,
    incompleteRunLeaseRunText,
    incompleteRunLeaseKind,
    IncompleteLeaseKind (..),
    ClosedAbandonedHarnessRuns,
    closedAbandonedHarnessRunsCount,
    recoverAbandonedHarnessRuns,
    AbandonedHarnessRun,
    abandonedHarnessRunId,
    abandonedHarnessSnapshot,
    abandonedHarnessBoundLease,
    abandonedHarnessModeLease,
    abandonedHarnessDestroyRoot,
    abandonedHarnessRecovery,
    abandonedHarnessCloseRoot,
    abandonedHarnessBroker,
    abandonedHarnessFencedPermits,
    abandonedHarnessManifest,
    abandonedHarnessInterpretation,
    abandonedHarnessAdmission,
    withAbandonedHarnessRun,

    -- * Failures
    ModeError (..),
    modeErrorMessage,
    LifecycleError,
    lifecycleErrorMessage,
) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isAlphaNum)
import Data.Kind (Type)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import HostBootstrap.Authority (
    AuthorityError (..),
    BrokerEpoch,
    InstalledProjectIdentity,
    LifecyclePhase,
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    RootInvocationAuthority,
    RootScopeAuthority,
    TeardownPhase,
    VerbDestroy,
    VerbDown,
    VerbUp,
    authorityErrorMessage,
    brokerEpochWord,
    installedProjectName,
    lifecyclePhaseName,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
 )
import HostBootstrap.Authority.Kernel (
    RootScopeWitness (HarnessRootScope, ProductionRootScope),
    VerifiedOsPrincipal,
    rootScopeEpochWord,
    rootScopeProjectName,
    rootScopeStoreIdentity,
    rootAuthorityStoreIdentity,
    verifyOsPrincipal,
    withFreshBrokerEpochKernel,
    withReifiedAllocatedBrokerEpochKernel,
    withExistingVerifiedRootInvocationKernel,
    withVerifiedRootInvocationKernel,
 )
import HostBootstrap.Config.Authority.Internal (
    HarnessAuthority,
    harnessRunName,
    mintHarnessAuthority,
 )
import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Handoff (
    HandoffBinding,
    HandoffPayloadKind (NarrowedProjectConfig, RecoveryAdapterWire),
    handoffBrokerGeneration,
    handoffChildConfigDigest,
    handoffChildFrame,
    handoffInstalledProject,
    handoffPayloadKind,
    handoffParentFrame,
    handoffPhase,
    handoffPlanRevision,
    handoffScope,
    handoffSpecDigest,
    handoffStoreIdentity,
    handoffTokenCommitment,
    handoffVerb,
 )
import HostBootstrap.Lifecycle.Plan (
    AcquisitionJournalAdmission,
    BoundPlanSnapshot,
    CanonicalPlanSnapshot,
    ExistingBoundSnapshotAdmission,
    IndexedPlanSnapshot,
    PlanDigestBinding,
    ProjectPlan,
    admitPersistedCanonicalPlanSnapshotKernel,
    boundPlanSnapshotBytesKernel,
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotConfigDigest,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotSpecDigest,
    acquisitionJournalAdmissionKernel,
    consumeAcquisitionJournalAdmissionKernel,
    consumeExistingBoundSnapshotAdmissionKernel,
    indexedPlanSnapshotCanonicalKernel,
    planDigestBindingDigestKernel,
    projectPlanProfileEpochKernel,
    projectPlanProfileNameKernel,
    projectPlanProfileProjectNameKernel,
    projectPlanProfileStoreIdentityKernel,
    projectPlanIndexedSnapshotKernel,
    projectPlanCanonicalSnapshotKernel,
    withPersistedBoundPlanSnapshotKernel,
 )
import HostBootstrap.Lifecycle.Context (
    ValidatedLifecycleContext,
    lifecycleContextErrorMessage,
 )
import HostBootstrap.Lifecycle.Context.Internal (
    withValidatedRootLifecycleContext,
 )
import HostBootstrap.Lifecycle.Closure (
    ProductionCloseKind (PreEffectRefusalClose, SettledDestroyClose),
    ProductionCloseRoot,
    productionCloseRootVerb,
 )
import HostBootstrap.Lifecycle.Session (
    AcquisitionJournal,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    acquisitionJournalRunLease,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalStableScope,
    CurrentBrokerSessionAdmission,
    InterpretedRecovery,
    LifecycleCursor,
    LifecycleError,
    OldPermitsFenced,
    ProjectPermit,
    SessionError (..),
    VerifiedAllSessionsClosed,
    VerifiedSessionManifest,
    admitCurrentBroker,
    allSessionsClosedCount,
    allSessionsClosedPlanDigest,
    fenceOldPermits,
    interpretRecordedSessions,
    lifecycleCursorFrame,
    lifecycleCursorMatchesCommandAuthority,
    lifecycleCursorPhase,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    validateCurrentLifecycleCursor,
    verifyAllSessionsClosed,
    openProjectJournal,
    openAcquisitionJournalKernel,
    reopenExistingAcquisitionCursorKernel,
    reopenExistingReverseAcquisitionJournalKernel,
    sessionErrorMessage,
    validateAcquisitionJournalBindingKernel,
    lifecycleErrorMessage,
    verifySessionManifest,
    withAcquisitionJournalPhase,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withLifecycleCursor,
    withTeardownLifecycleCursor,
    withReverseRootTargetLifecycleCursorKernel,
    withReverseRootSourceRecordsKernel,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    RecordVersion,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    protectedErrorMessage,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    readProtectedRecord,
    recordVersionWord,
    recordKeyText,
    sessionStoreIdentity,
    withProtectedEntry,
 )
import HostBootstrap.ProjectPlan
    ( renderSnapshot
    , stablePlanSnapshotRoot
    , topology
    , topologyParentEdges
    )
import HostBootstrap.ProjectPlan.Frame (ProjectFrame, projectFrameId)
import HostBootstrap.ProjectRoot (canonicalProjectRootPath)
import HostBootstrap.Teardown (
    DestroySettled,
    destroySettledPlanDigest,
 )
import System.Directory (doesFileExist)
import System.FilePath ((<.>), (</>))

-- Run identity -----------------------------------------------------------------

-- | Stable durable key material. This never crosses the public boundary.
newtype RunKey = RunKey Text
    deriving (Eq, Ord)

instance Show RunKey where
    show (RunKey value) = "RunKey " <> show value

{- | A generative Harness run identifier. Its constructor and parser are
private; the only public operation is the non-authorizing text projection.
-}
type role RunId nominal
newtype RunId (runId :: Type) = RunId RunKey

instance Show (RunId runId) where
    show run = "RunId " <> show (runIdText run)

runIdText :: RunId runId -> Text
runIdText (RunId (RunKey value)) = value

runKeyText :: RunKey -> Text
runKeyText (RunKey value) = value

parseRunKey :: Text -> Either ModeError RunKey
parseRunKey raw
    | Text.null raw = Left (ModeInvalidIdentity "a run id must not be empty")
    | Text.length raw > 48 = Left (ModeInvalidIdentity "a run id must be at most 48 characters")
    | not (Text.all legal raw) =
        Left (ModeInvalidIdentity ("a run id may contain only alphanumerics and '-': " <> raw))
    | otherwise = Right (RunKey raw)
  where
    legal character = isAlphaNum character || character == '-'

withFreshRunId :: (forall runId. RunId runId -> IO result) -> IO result
withFreshRunId use = do
    stamp <- getMonotonicTimeNSec
    use (RunId (RunKey (Text.pack ("run-" <> showHexWord stamp))))

-- | Reify durable Harness key material behind a fresh local phantom. This is
-- package-private and is used only by abandoned-run recovery; it never accepts
-- caller text and never returns the generative witness outside the rank-2
-- continuation.
withReifiedRunId :: RunKey -> (forall runId. RunId runId -> result) -> result
withReifiedRunId run use = use (RunId run)

showHexWord :: Word64 -> String
showHexWord value = go value ""
  where
    go remaining acc
        | remaining < 16 = digit remaining : acc
        | otherwise = go (remaining `div` 16) (digit (remaining `mod` 16) : acc)
    digit d
        | d < 10 = toEnum (fromEnum '0' + fromIntegral d)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral d - 10)

-- Modes -------------------------------------------------------------------------

-- | Public opaque type tag for the Production branch.
data ProductionMode

-- | Public opaque type tag for one exact generative Harness run.
type role HarnessMode nominal
data HarnessMode runId

-- | Private stable representation persisted in the mode record.
data ModeWire
    = WireProduction
    | WireHarness RunKey
    deriving (Eq, Show)

modeWireName :: ModeWire -> Text
modeWireName WireProduction = "production"
modeWireName (WireHarness run) = "harness:" <> runKeyText run

-- | Private lifecycle identity shared by a lease and its verified snapshot.
type role RunIdentity nominal
data RunIdentity scope where
    ProductionRunIdentity :: RunKey -> RunIdentity (Production projectId)
    HarnessRunIdentity :: RunId runId -> RunIdentity (Harness projectId runId)

runIdentityKey :: RunIdentity scope -> RunKey
runIdentityKey (ProductionRunIdentity run) = run
runIdentityKey (HarnessRunIdentity (RunId run)) = run

runIdentityText :: RunIdentity scope -> Text
runIdentityText = runKeyText . runIdentityKey

runIdentityMode :: RunIdentity scope -> ModeWire
runIdentityMode (ProductionRunIdentity _) = WireProduction
runIdentityMode (HarnessRunIdentity (RunId run)) = WireHarness run

{- | The held project-wide mode lease. The mode index is nominal and its
constructor is private: only a successful protected mode transition can mint
one.
-}
type role ProjectModeLease nominal nominal nominal
data ProjectModeLease projectId mode brokerGeneration
    = ProjectModeLease ModeWire Text Text (BrokerEpoch brokerGeneration)

instance Show (ProjectModeLease projectId mode brokerGeneration) where
    show (ProjectModeLease mode _project _store epoch) =
        "ProjectModeLease " <> Text.unpack (modeWireName mode) <> " " <> show epoch

projectModeLeaseName :: ProjectModeLease projectId mode brokerGeneration -> Text
projectModeLeaseName (ProjectModeLease mode _ _ _) = modeWireName mode

projectModeLeaseEpoch ::
    ProjectModeLease projectId mode brokerGeneration -> BrokerEpoch brokerGeneration
projectModeLeaseEpoch (ProjectModeLease _ _ _ epoch) = epoch

-- | Scope-narrowed active-mode evidence. The constructor is private and the
-- two functions below are its only producers.
type role ActiveProjectMode nominal nominal
data ActiveProjectMode scope brokerGeneration
    = ActiveProjectMode ModeWire Text Text (BrokerEpoch brokerGeneration)

instance Show (ActiveProjectMode scope brokerGeneration) where
    show (ActiveProjectMode mode _project _store epoch) =
        "ActiveProjectMode " <> Text.unpack (modeWireName mode) <> " " <> show epoch

activeProjectModeEpoch ::
    ActiveProjectMode scope brokerGeneration -> BrokerEpoch brokerGeneration
activeProjectModeEpoch (ActiveProjectMode _ _ _ epoch) = epoch

productionActiveMode ::
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    ActiveProjectMode (Production projectId) brokerGeneration
productionActiveMode (ProjectModeLease mode project store epoch) =
    ActiveProjectMode mode project store epoch

harnessActiveMode ::
    ProjectModeLease projectId (HarnessMode runId) brokerGeneration ->
    ActiveProjectMode (Harness projectId runId) brokerGeneration
harnessActiveMode (ProjectModeLease mode project store epoch) =
    ActiveProjectMode mode project store epoch

-- Plan snapshots -----------------------------------------------------------------

{- | A plan snapshot that was read back out of the protected store.

Its constructor is private and its two digest indices are bound by
'verifyPlanSnapshot'\'s rank-2 continuation, so a caller cannot pair a lease with
digests it merely believes are current. This is the value 'bindRunLease'
consumes, which is how "the lease is bound to a persisted, verified snapshot"
becomes a type-level fact instead of a comment.

The canonical branch carries the exact non-secret stable plan bytes and config
digest needed by configless teardown or recovery. Legacy digest-only records
remain readable while callers migrate; they expose 'Nothing' through the two
canonical accessors and cannot be mistaken for a reconstructible snapshot.
-}
type role VerifiedPlanSnapshot nominal nominal nominal
data VerifiedPlanSnapshot scope (specDigest :: Type) (planDigest :: Type)
    = VerifiedPlanSnapshot
        (RunIdentity scope)
        Text
        Text
        Word64
        Text
        Text
        (Maybe Text)
        (Maybe ByteString)

instance Show (VerifiedPlanSnapshot scope specDigest planDigest) where
    show (VerifiedPlanSnapshot run _project _store revision spec plan config canonicalBytes) =
        "VerifiedPlanSnapshot "
            <> show (runIdentityText run)
            <> " "
            <> show revision
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> maybe " <digest-only>" (const " <canonical>") config
            <> maybe "" (\bytes -> " <" <> show (ByteString.length bytes) <> " bytes>") canonicalBytes

planSnapshotRunText :: VerifiedPlanSnapshot scope specDigest planDigest -> Text
planSnapshotRunText (VerifiedPlanSnapshot run _ _ _ _ _ _ _) = runIdentityText run

planSnapshotRunKey :: VerifiedPlanSnapshot scope specDigest planDigest -> RunKey
planSnapshotRunKey (VerifiedPlanSnapshot run _ _ _ _ _ _ _) = runIdentityKey run

-- | The installed project retained by the protected snapshot read.
planSnapshotProjectName :: VerifiedPlanSnapshot scope specDigest planDigest -> Text
planSnapshotProjectName (VerifiedPlanSnapshot _ project _ _ _ _ _ _) = project

-- | The durable protected-store identity retained by the snapshot read.
planSnapshotStoreIdentity :: VerifiedPlanSnapshot scope specDigest planDigest -> Text
planSnapshotStoreIdentity (VerifiedPlanSnapshot _ _ storeIdentity _ _ _ _ _) = storeIdentity

-- | The active plan revision. Positive by construction.
planSnapshotRevision :: VerifiedPlanSnapshot scope specDigest planDigest -> Word64
planSnapshotRevision (VerifiedPlanSnapshot _ _ _ revision _ _ _ _) = revision

planSnapshotSpecDigest :: VerifiedPlanSnapshot scope specDigest planDigest -> Text
planSnapshotSpecDigest (VerifiedPlanSnapshot _ _ _ _ spec _ _ _) = spec

planSnapshotPlanDigest :: VerifiedPlanSnapshot scope specDigest planDigest -> Text
planSnapshotPlanDigest (VerifiedPlanSnapshot _ _ _ _ _ plan _ _) = plan

-- | The exact admitted config digest, present only on a canonical snapshot.
planSnapshotConfigDigest :: VerifiedPlanSnapshot scope specDigest planDigest -> Maybe Text
planSnapshotConfigDigest (VerifiedPlanSnapshot _ _ _ _ _ _ config _) = config

-- | The exact stable plan bytes, present only on a canonical snapshot.
planSnapshotCanonicalBytes :: VerifiedPlanSnapshot scope specDigest planDigest -> Maybe ByteString
planSnapshotCanonicalBytes (VerifiedPlanSnapshot _ _ _ _ _ _ _ bytes) = bytes

data PlanSnapshotRecord = PlanSnapshotRecord
    { snapshotRecordRevision :: Word64
    , snapshotRecordSpecDigest :: Text
    , snapshotRecordPlanDigest :: Text
    , snapshotRecordConfigDigest :: Maybe Text
    , snapshotRecordCanonicalBytes :: Maybe ByteString
    }

{- | A non-authorizing read-only view of durable snapshot bytes. Unlike
'VerifiedPlanSnapshot', this value carries no lifecycle scope or digest
indices and cannot be used to bind a lease. It exists for diagnostics and
tests that need to inspect a stable run name without reconstructing a
generative 'RunId'.
-}
data PlanSnapshotView = PlanSnapshotView Word64 Text Text (Maybe Text) (Maybe ByteString)
    deriving (Eq, Show)

planSnapshotViewRevision :: PlanSnapshotView -> Word64
planSnapshotViewRevision (PlanSnapshotView revision _ _ _ _) = revision

planSnapshotViewSpecDigest :: PlanSnapshotView -> Text
planSnapshotViewSpecDigest (PlanSnapshotView _ spec _ _ _) = spec

planSnapshotViewPlanDigest :: PlanSnapshotView -> Text
planSnapshotViewPlanDigest (PlanSnapshotView _ _ plan _ _) = plan

planSnapshotViewConfigDigest :: PlanSnapshotView -> Maybe Text
planSnapshotViewConfigDigest (PlanSnapshotView _ _ _ config _) = config

planSnapshotViewCanonicalBytes :: PlanSnapshotView -> Maybe ByteString
planSnapshotViewCanonicalBytes (PlanSnapshotView _ _ _ _ bytes) = bytes

{- | Inspect a snapshot by stable run text without minting run or lifecycle
authority. The text is validated with the private wire parser and used only to
locate and decode the immutable record.
-}
inspectPlanSnapshot ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    Text ->
    IO (Either ModeError PlanSnapshotView)
inspectPlanSnapshot session project rawRun = case parseRunKey rawRun of
    Left failure -> pure (Left failure)
    Right run -> withRecordKey (snapshotKeyForRunKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Left (ModeSnapshotMissing rawRun)
            Right (Just record) -> case decodePlanSnapshotRecord (protectedRecordBytes record) of
                Nothing -> Left (ModeMalformedRecord (recordKeyText key))
                Just snapshot ->
                    Right
                        ( PlanSnapshotView
                            (snapshotRecordRevision snapshot)
                            (snapshotRecordSpecDigest snapshot)
                            (snapshotRecordPlanDigest snapshot)
                            (snapshotRecordConfigDigest snapshot)
                            (snapshotRecordCanonicalBytes snapshot)
                        )

snapshotRecordVersion :: Word64
snapshotRecordVersion = 1

-- | The first active revision written by fresh project-plan admission.
initialPlanSnapshotRevision :: Word64
initialPlanSnapshotRevision = 1

snapshotRecordMagic :: ByteString
snapshotRecordMagic = "HOSTBOOTSTRAP-SNAPSHOT"

-- Decoder and persistence ceilings are part of the wire contract. In
-- particular, an attacker-controlled 64-bit frame length is rejected before
-- it reaches 'ByteString.splitAt' or text decoding.
maxSnapshotRecordBytes :: Int
maxSnapshotRecordBytes = 32 * 1024 * 1024

maxSnapshotTextBytes :: Int
maxSnapshotTextBytes = 1024 * 1024

maxCanonicalPlanBytes :: Int
maxCanonicalPlanBytes = 16 * 1024 * 1024

{- | Persist one run\'s immutable plan snapshot. This must happen before the
lease can be bound, so a bound lease always names a snapshot that exists
durably. Repeating the exact bytes is idempotent and does not advance the record
version; any attempted replacement is refused.
-}
persistPlanSnapshot ::
    UnboundRunLease scope brokerGeneration ->
    -- | active plan revision; must be positive
    Word64 ->
    -- | spec digest
    Text ->
    -- | plan digest
    Text ->
    IO (Either ModeError ())
persistPlanSnapshot unbound revision spec plan
    | revision == 0 =
        pure (Left (ModeInvalidIdentity "a plan revision must be positive"))
    | Text.null spec || Text.null plan =
        pure (Left (ModeInvalidIdentity "a plan snapshot needs both digests"))
    | not (snapshotTextWithinBound spec) || not (snapshotTextWithinBound plan) =
        pure (Left (ModeInvalidIdentity "a plan snapshot digest exceeds the wire bound"))
    | otherwise =
        withUnboundLeaseEntry unbound $ \session ->
            persistSnapshotRecordAt
                session
                (leaseLocationSnapshotKey (unboundRunLeaseLocation unbound))
                (PlanSnapshotRecord revision spec plan Nothing Nothing)

{- | Persist the exact canonical plan bytes together with their revision and
spec/config/plan digests. Every identity is derived from the opaque canonical
snapshot rather than accepted as an independently supplied string.
-}
persistCanonicalPlanSnapshot ::
    UnboundRunLease scope brokerGeneration ->
    Word64 ->
    CanonicalPlanSnapshot ->
    IO (Either ModeError ())
persistCanonicalPlanSnapshot unbound revision snapshot =
    case canonicalSnapshotRecord revision snapshot of
        Left failure -> pure (Left failure)
        Right proposed ->
            withUnboundLeaseEntry unbound $ \session ->
                persistSnapshotRecordAt
                    session
                    (leaseLocationSnapshotKey (unboundRunLeaseLocation unbound))
                    proposed

canonicalSnapshotRecord ::
    Word64 ->
    CanonicalPlanSnapshot ->
    Either ModeError PlanSnapshotRecord
canonicalSnapshotRecord revision snapshot
    | revision == 0 =
        Left (ModeInvalidIdentity "a plan revision must be positive")
    | Text.null spec || Text.null config || Text.null plan || ByteString.null canonicalBytes =
        Left (ModeInvalidIdentity "a canonical plan snapshot needs non-empty identities and bytes")
    | any (not . snapshotTextWithinBound) [spec, config, plan] =
        Left (ModeInvalidIdentity "a canonical plan snapshot identity exceeds the wire bound")
    | ByteString.length canonicalBytes > maxCanonicalPlanBytes =
        Left (ModeInvalidIdentity "a canonical plan snapshot exceeds the wire bound")
    | otherwise = Right (PlanSnapshotRecord revision spec plan (Just config) (Just canonicalBytes))
  where
    spec = canonicalPlanSnapshotSpecDigest snapshot
    config = canonicalPlanSnapshotConfigDigest snapshot
    plan = canonicalPlanSnapshotDigest snapshot
    canonicalBytes = canonicalPlanSnapshotBytes snapshot

persistSnapshotRecordAt ::
    ProtectedSession session ->
    RecordKey ->
    PlanSnapshotRecord ->
    IO (Either ModeError ())
persistSnapshotRecordAt session key proposed = do
        let payload = encodePlanSnapshotRecord proposed
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right (Just existing) -> pure (checkExistingSnapshot key proposed payload existing)
            Right Nothing -> do
                written <-
                    compareAndSwapProtectedRecord
                        session
                        key
                        ExpectAbsent
                        payload
                case written of
                    Right _ -> pure (Right ())
                    Left failure -> do
                        -- A competing identical creator is still the same
                        -- idempotent snapshot. A different winner is immutable
                        -- substitution, while a vanished/failed write retains
                        -- the protected-store error that caused this CAS to lose.
                        raced <- readProtectedRecord session key
                        pure $ case raced of
                            Left readFailure -> Left (ModeStoreFailure readFailure)
                            Right (Just existing) ->
                                checkExistingSnapshot key proposed payload existing
                            Right Nothing -> Left (ModeStoreFailure failure)
  where
    checkExistingSnapshot existingKey candidate payload existing
        | protectedRecordBytes existing == payload = Right ()
        | otherwise = case decodePlanSnapshotRecord (protectedRecordBytes existing) of
            Just recorded ->
                Left
                    ( ModeSnapshotMismatch
                        (snapshotDescription candidate)
                        (snapshotDescription recorded)
                    )
            _ -> Left (ModeMalformedRecord (recordKeyText existingKey))

snapshotDescription :: PlanSnapshotRecord -> Text
snapshotDescription record =
    "revision "
        <> showWord (snapshotRecordRevision record)
        <> ", spec "
        <> snapshotRecordSpecDigest record
        <> ", plan "
        <> snapshotRecordPlanDigest record
        <> maybe "" (", config " <>) (snapshotRecordConfigDigest record)

{- | Read a run\'s persisted plan snapshot back and bind its digests. A missing
snapshot is refused rather than defaulted: without one there is nothing a lease
could legitimately be bound to.
-}
verifyPlanSnapshot ::
    UnboundRunLease scope brokerGeneration ->
    ( forall (specDigest :: Type) (planDigest :: Type).
      VerifiedPlanSnapshot scope specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
verifyPlanSnapshot unbound use = do
    loaded <-
        withUnboundLeaseEntry unbound $ \session ->
            readVerifiedPlanSnapshotAt
                session
                (leaseLocationSnapshotKey location)
                (unboundRunLeaseIdentity unbound)
                (leaseLocationProjectName location)
                (leaseLocationStoreIdentity location)
    case loaded of
        Left failure -> pure (Left failure)
        Right (SomeVerifiedPlanSnapshot snapshot) -> use snapshot
  where
    location = unboundRunLeaseLocation unbound

{- | Restricted same-package verification for an exact indexed project plan.

Unlike 'verifyPlanSnapshot', this seam preserves the specification identity
already carried by the private 'IndexedPlanSnapshot' and quantifies only the
stable @planDigest@ read from the protected record.  The indexed input has no
public producer or projection, so downstream clients cannot invoke this
refinement independently of an admitted 'ProjectPlan'.

All stable material must agree exactly: specification digest, configuration
digest, canonical bytes, and the content-derived plan digest.  Only then is the
verified value reconstructed under the indexed snapshot's existing
@specDigest@ phantom.
-}
verifyIndexedPlanSnapshot ::
    UnboundRunLease scope brokerGeneration ->
    IndexedPlanSnapshot scope specDigest planId configId ->
    ( forall (planDigest :: Type).
      VerifiedPlanSnapshot scope specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
verifyIndexedPlanSnapshot unbound indexed use = do
    loaded <-
        withUnboundLeaseEntry unbound $ \session ->
            readVerifiedPlanSnapshotAt
                session
                (leaseLocationSnapshotKey location)
                (unboundRunLeaseIdentity unbound)
                (leaseLocationProjectName location)
                (leaseLocationStoreIdentity location)
    case loaded of
        Left failure -> pure (Left failure)
        Right (SomeVerifiedPlanSnapshot observed) ->
            case refineVerifiedPlanSnapshot indexed observed of
                Left failure -> pure (Left failure)
                Right verified -> use verified
  where
    location = unboundRunLeaseLocation unbound

{- | Check all retained admission origins before the fresh snapshot protocol
can enter the protected store.

The plan is deliberately not broker-indexed, so its project, store, profile,
and epoch are retained in the hidden plan kernel and compared here.  The
root/lease checks remain explicit as a fail-closed runtime backstop to their
shared nominal indices.
-}
validateFreshPlanSnapshotEvidence ::
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    UnboundRunLease scope brokerGeneration ->
    ProjectPlan scope specDigest planId configId cfg ->
    Either ModeError ()
validateFreshPlanSnapshotEvidence root unbound plan = do
    match "root project" leaseProject (rootAuthorityProjectName root)
    match "root store" leaseStore (rootAuthorityStoreIdentity root)
    matchWord
        "root epoch"
        retainedEpochWord
        (brokerEpochWord (rootAuthorityEpoch root))
    match "plan profile" leaseProfile (projectPlanProfileNameKernel plan)
    matchWord "plan epoch" retainedEpochWord (projectPlanProfileEpochKernel plan)
    match "plan project" leaseProject (projectPlanProfileProjectNameKernel plan)
    match "plan store" leaseStore (projectPlanProfileStoreIdentityKernel plan)
  where
    location = unboundRunLeaseLocation unbound
    leaseProject = leaseLocationProjectName location
    leaseStore = leaseLocationStoreIdentity location
    retainedEpochWord = brokerEpochWord (unboundRunLeaseEpoch unbound)
    leaseProfile = modeWireName (runIdentityMode (unboundRunLeaseIdentity unbound))
    match subject expected observed
        | expected == observed = Right ()
        | otherwise = Left (ModeEvidenceMismatch subject expected observed)
    matchWord subject expected observed =
        match subject (showWord expected) (showWord observed)

data SomeRefinedPlanSnapshot scope specDigest
    = forall planDigest.
        SomeRefinedPlanSnapshot
            (VerifiedPlanSnapshot scope specDigest planDigest)

readRefinedIndexedPlanSnapshotAt ::
    ProtectedSession session ->
    UnboundRunLease scope brokerGeneration ->
    IndexedPlanSnapshot scope specDigest planId configId ->
    IO (Either ModeError (SomeRefinedPlanSnapshot scope specDigest))
readRefinedIndexedPlanSnapshotAt session unbound indexed = do
    observed <-
        readVerifiedPlanSnapshotAt
            session
            (leaseLocationSnapshotKey location)
            (unboundRunLeaseIdentity unbound)
            (leaseLocationProjectName location)
            (leaseLocationStoreIdentity location)
    pure $ case observed of
        Left failure -> Left failure
        Right (SomeVerifiedPlanSnapshot snapshot) ->
            SomeRefinedPlanSnapshot <$> refineVerifiedPlanSnapshot indexed snapshot
  where
    location = unboundRunLeaseLocation unbound

{- | Persist and authoritatively read back one exact indexed plan snapshot in
one protected entry.

The retained unbound lease is revalidated before the immutable write.  The
continuation runs only after the protected entry has closed, so later lease or
journal work cannot re-enter the store while its lock is held.
-}
persistAndVerifyIndexedPlanSnapshotKernel ::
    UnboundRunLease scope brokerGeneration ->
    IndexedPlanSnapshot scope specDigest planId configId ->
    ( forall (planDigest :: Type).
      VerifiedPlanSnapshot scope specDigest planDigest ->
      IO result
    ) ->
    IO (Either ModeError result)
persistAndVerifyIndexedPlanSnapshotKernel unbound indexed use = do
    loaded <-
        withUnboundLeaseEntry unbound $ \session -> do
            retained <- readRetainedUnboundLeaseAt session unbound
            case retained of
                Left failure -> pure (Left failure)
                Right _ ->
                    case
                        canonicalSnapshotRecord
                            initialPlanSnapshotRevision
                            (indexedPlanSnapshotCanonicalKernel indexed)
                    of
                        Left failure -> pure (Left failure)
                        Right proposed -> do
                            persisted <-
                                persistSnapshotRecordAt
                                    session
                                    (leaseLocationSnapshotKey (unboundRunLeaseLocation unbound))
                                    proposed
                            case persisted of
                                Left failure -> pure (Left failure)
                                Right () ->
                                    readRefinedIndexedPlanSnapshotAt session unbound indexed
    case loaded of
        Left failure -> pure (Left failure)
        Right (SomeRefinedPlanSnapshot snapshot) -> Right <$> use snapshot

refineVerifiedPlanSnapshot ::
    IndexedPlanSnapshot scope specDigest planId configId ->
    VerifiedPlanSnapshot scope observedSpecDigest planDigest ->
    Either ModeError (VerifiedPlanSnapshot scope specDigest planDigest)
refineVerifiedPlanSnapshot indexed observed
    | planSnapshotSpecDigest observed /= expectedSpec =
        mismatch expectedSpec (planSnapshotSpecDigest observed)
    | planSnapshotConfigDigest observed /= Just expectedConfig =
        mismatch
            expectedConfig
            (maybe "<absent>" id (planSnapshotConfigDigest observed))
    | planSnapshotCanonicalBytes observed /= Just expectedBytes =
        mismatch
            "the indexed plan's exact canonical bytes"
            ( case planSnapshotCanonicalBytes observed of
                Nothing -> "<absent>"
                Just _ -> "different canonical bytes"
            )
    | planSnapshotPlanDigest observed /= expectedPlan =
        mismatch expectedPlan (planSnapshotPlanDigest observed)
    | otherwise = Right (reindexSpec observed)
  where
    canonical = indexedPlanSnapshotCanonicalKernel indexed
    expectedSpec = canonicalPlanSnapshotSpecDigest canonical
    expectedConfig = canonicalPlanSnapshotConfigDigest canonical
    expectedBytes = canonicalPlanSnapshotBytes canonical
    expectedPlan = canonicalPlanSnapshotDigest canonical
    mismatch expected actual = Left (ModeSnapshotMismatch expected actual)
    reindexSpec
        (VerifiedPlanSnapshot run project store revision _ plan config bytes) =
            VerifiedPlanSnapshot
                run
                project
                store
                revision
                expectedSpec
                plan
                config
                bytes

data SomeVerifiedPlanSnapshot scope
    = forall specDigest planDigest.
        SomeVerifiedPlanSnapshot (VerifiedPlanSnapshot scope specDigest planDigest)

readVerifiedPlanSnapshotAt ::
    ProtectedSession session ->
    RecordKey ->
    RunIdentity scope ->
    Text ->
    Text ->
    IO (Either ModeError (SomeVerifiedPlanSnapshot scope))
readVerifiedPlanSnapshotAt session key run projectName storeIdentity = do
    observed <- readProtectedRecord session key
    pure $ case observed of
        Left failure -> Left (ModeStoreFailure failure)
        Right Nothing -> Left (ModeSnapshotMissing (runIdentityText run))
        Right (Just record) -> case decodePlanSnapshotRecord (protectedRecordBytes record) of
            Just snapshot ->
                Right
                    ( SomeVerifiedPlanSnapshot
                        ( VerifiedPlanSnapshot
                            run
                            projectName
                            storeIdentity
                            (snapshotRecordRevision snapshot)
                            (snapshotRecordSpecDigest snapshot)
                            (snapshotRecordPlanDigest snapshot)
                            (snapshotRecordConfigDigest snapshot)
                            (snapshotRecordCanonicalBytes snapshot)
                        )
                    )
            Nothing -> Left (ModeMalformedRecord (recordKeyText key))

verifyPlanSnapshotInSession ::
    ProtectedSession session ->
    RecordKey ->
    RunIdentity scope ->
    Text ->
    Text ->
    ( forall (specDigest :: Type) (planDigest :: Type).
      VerifiedPlanSnapshot scope specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
verifyPlanSnapshotInSession session key run projectName storeIdentity use = do
    loaded <- readVerifiedPlanSnapshotAt session key run projectName storeIdentity
    case loaded of
        Left failure -> pure (Left failure)
        Right (SomeVerifiedPlanSnapshot snapshot) -> use snapshot

encodePlanSnapshotRecord :: PlanSnapshotRecord -> ByteString
encodePlanSnapshotRecord record =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString snapshotRecordMagic
                <> Builder.word64BE snapshotRecordVersion
                <> Builder.word64BE (snapshotRecordRevision record)
                <> encodeSnapshotText (snapshotRecordSpecDigest record)
                <> encodeSnapshotText (snapshotRecordPlanDigest record)
                <> case
                    ( snapshotRecordConfigDigest record
                    , snapshotRecordCanonicalBytes record
                    )
                  of
                    (Nothing, Nothing) -> Builder.word8 0
                    (Just config, Just canonicalBytes) ->
                        Builder.word8 1
                            <> encodeSnapshotText config
                            <> encodeSnapshotBytes canonicalBytes
                    _ -> Builder.word8 2
            )
        )

decodePlanSnapshotRecord :: ByteString -> Maybe PlanSnapshotRecord
decodePlanSnapshotRecord payload
    | ByteString.length payload > maxSnapshotRecordBytes = Nothing
    | otherwise =
        decodeCanonicalSnapshotRecord payload <|> decodeLegacySnapshotRecord payload

decodeCanonicalSnapshotRecord :: ByteString -> Maybe PlanSnapshotRecord
decodeCanonicalSnapshotRecord payload = do
    remainingAfterMagic <- ByteString.stripPrefix snapshotRecordMagic payload
    (version, afterVersion) <- takeSnapshotWord remainingAfterMagic
    if version /= snapshotRecordVersion then Nothing else pure ()
    (revision, afterRevision) <- takeSnapshotWord afterVersion
    (spec, afterSpec) <- takeSnapshotText afterRevision
    (plan, afterPlan) <- takeSnapshotText afterSpec
    (canonicalTag, afterTag) <- ByteString.uncons afterPlan
    (config, canonicalBytes, trailing) <-
        case canonicalTag of
            0 -> pure (Nothing, Nothing, afterTag)
            1 -> do
                (configDigest, afterConfig) <- takeSnapshotText afterTag
                (bytes, afterBytes) <- takeSnapshotBytesBounded maxCanonicalPlanBytes afterConfig
                pure (Just configDigest, Just bytes, afterBytes)
            _ -> Nothing
    if revision == 0
        || Text.null spec
        || Text.null plan
        || maybe False Text.null config
        || maybe False ByteString.null canonicalBytes
        || not (ByteString.null trailing)
        then Nothing
        else
            Just
                (PlanSnapshotRecord revision spec plan config canonicalBytes)

decodeLegacySnapshotRecord :: ByteString -> Maybe PlanSnapshotRecord
decodeLegacySnapshotRecord payload =
    case decodeFields payload of
        [rawRevision, spec, plan]
            | Just revision <- readWord rawRevision
            , revision > 0
            , not (Text.null spec)
            , not (Text.null plan) ->
                Just (PlanSnapshotRecord revision spec plan Nothing Nothing)
        _ -> Nothing

encodeSnapshotText :: Text -> Builder.Builder
encodeSnapshotText = encodeSnapshotBytes . TextEncoding.encodeUtf8

encodeSnapshotBytes :: ByteString -> Builder.Builder
encodeSnapshotBytes bytes =
    Builder.word64BE (fromIntegral (ByteString.length bytes))
        <> Builder.byteString bytes

takeSnapshotText :: ByteString -> Maybe (Text, ByteString)
takeSnapshotText input = do
    (bytes, remaining) <- takeSnapshotBytesBounded maxSnapshotTextBytes input
    value <- either (const Nothing) Just (TextEncoding.decodeUtf8' bytes)
    pure (value, remaining)

takeSnapshotBytesBounded :: Int -> ByteString -> Maybe (ByteString, ByteString)
takeSnapshotBytesBounded limit input = do
    (rawLength, remaining) <- takeSnapshotWord input
    if rawLength > fromIntegral limit
        then Nothing
        else do
            let requested = fromIntegral rawLength
                (value, trailing) = ByteString.splitAt requested remaining
            if ByteString.length value == requested
                then Just (value, trailing)
                else Nothing

takeSnapshotWord :: ByteString -> Maybe (Word64, ByteString)
takeSnapshotWord input =
    let (rawWord, remaining) = ByteString.splitAt 8 input
     in if ByteString.length rawWord /= 8
            then Nothing
            else
                Just
                    ( ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 rawWord
                    , remaining
                    )

snapshotTextWithinBound :: Text -> Bool
snapshotTextWithinBound =
    (<= maxSnapshotTextBytes) . ByteString.length . TextEncoding.encodeUtf8

-- Run leases ---------------------------------------------------------------------

{- | A recorded run lease that has no plan snapshot yet. It authorizes no
effect; its only powers are to be bound or to be closed by the sweep after
proving it recorded none.
-}
data LeaseLocation = LeaseLocation
    { leaseLocationStore :: ProtectedStore
    , leaseLocationProjectName :: Text
    , leaseLocationStoreIdentity :: Text
    , leaseLocationLeaseKey :: RecordKey
    , leaseLocationSnapshotKey :: RecordKey
    , leaseLocationInvocationKey :: RecordKey
    , leaseLocationMigrationKey :: RecordKey
    , leaseLocationProfileKey :: RecordKey
    }

type role UnboundRunLease nominal nominal
data UnboundRunLease scope brokerGeneration
    = UnboundRunLease
        (RunIdentity scope)
        LeaseLocation
        (BrokerEpoch brokerGeneration)
        Word64

instance Show (UnboundRunLease scope brokerGeneration) where
    show (UnboundRunLease run _ epoch _) =
        "UnboundRunLease " <> Text.unpack (runIdentityText run) <> " " <> show epoch

unboundRunLeaseRunText :: UnboundRunLease scope brokerGeneration -> Text
unboundRunLeaseRunText (UnboundRunLease run _ _ _) = runIdentityText run

unboundRunLeaseIdentity :: UnboundRunLease scope brokerGeneration -> RunIdentity scope
unboundRunLeaseIdentity (UnboundRunLease run _ _ _) = run

unboundRunLeaseLocation :: UnboundRunLease scope brokerGeneration -> LeaseLocation
unboundRunLeaseLocation (UnboundRunLease _ location _ _) = location

unboundRunLeaseEpoch ::
    UnboundRunLease scope brokerGeneration -> BrokerEpoch brokerGeneration
unboundRunLeaseEpoch (UnboundRunLease _ _ epoch _) = epoch

unboundRunLeaseRecordVersion :: UnboundRunLease scope brokerGeneration -> Word64
unboundRunLeaseRecordVersion (UnboundRunLease _ _ _ version) = version

withUnboundLeaseEntry ::
    UnboundRunLease scope brokerGeneration ->
    (forall session. ProtectedSession session -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
withUnboundLeaseEntry unbound action = do
    entered <- withProtectedEntry (leaseLocationStore location) $ \session -> do
        clear <- refuseReverseRootIntentForName session (leaseLocationProjectName location)
        case clear of
            Left failure -> pure (Right (Left failure))
            Right () -> Right <$> action session
    pure $ case entered of
        Left failure -> Left (ModeStoreFailure failure)
        Right result -> result
  where
    location = unboundRunLeaseLocation unbound

{- | A lease bound to one verified plan snapshot. Every prepared operation
requires it, so an effect cannot precede the snapshot it claims to belong to.
-}
data BindingOrigin = FreshBinding | ExistingBinding | MigratedBinding
    deriving (Eq)

type role BoundRunLease nominal nominal nominal nominal
data BoundRunLease scope specDigest planDigest brokerGeneration
    = BoundRunLease
        (RunIdentity scope)
        LeaseLocation
        Text
        Text
        (BrokerEpoch brokerGeneration)
        RecordVersion
        BindingOrigin

instance Show (BoundRunLease scope specDigest planDigest brokerGeneration) where
    show (BoundRunLease run _ spec plan epoch _ _) =
        "BoundRunLease "
            <> Text.unpack (runIdentityText run)
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch

boundRunLeaseRunText :: BoundRunLease scope specDigest planDigest brokerGeneration -> Text
boundRunLeaseRunText (BoundRunLease run _ _ _ _ _ _) = runIdentityText run

boundRunLeaseIdentity ::
    BoundRunLease scope specDigest planDigest brokerGeneration -> RunIdentity scope
boundRunLeaseIdentity (BoundRunLease run _ _ _ _ _ _) = run

harnessBoundRunId ::
    BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration ->
    RunId runId
harnessBoundRunId bound = case boundRunLeaseIdentity bound of
    HarnessRunIdentity run -> run

boundRunLeaseLocation ::
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    LeaseLocation
boundRunLeaseLocation (BoundRunLease _ location _ _ _ _ _) = location

boundRunLeaseSpecDigest ::
    BoundRunLease scope specDigest planDigest brokerGeneration -> Text
boundRunLeaseSpecDigest (BoundRunLease _ _ spec _ _ _ _) = spec

boundRunLeasePlanDigest ::
    BoundRunLease scope specDigest planDigest brokerGeneration -> Text
boundRunLeasePlanDigest (BoundRunLease _ _ _ plan _ _ _) = plan

boundRunLeaseEpoch ::
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    BrokerEpoch brokerGeneration
boundRunLeaseEpoch (BoundRunLease _ _ _ _ epoch _ _) = epoch

boundRunLeaseRecordVersion ::
    BoundRunLease scope specDigest planDigest brokerGeneration -> RecordVersion
boundRunLeaseRecordVersion (BoundRunLease _ _ _ _ _ version _) = version

{- | The sole public plan-bound acquisition-journal opener.

The hidden witness is forced before any store access. All in-memory evidence is
compared first. One entry in the store retained by the opaque bound lease then
revalidates the live project mode/epoch, exact bound-lease record key/version
and bytes, and protected canonical snapshot. Only after every comparison does
Session open or resume the dedicated acquisition record. The caller callback is
invoked after that protected entry has closed.
-}
withAcquisitionJournal ::
    forall scope brokerGeneration verb specDigest planDigest planId configId cfg result.
    RootInvocationAuthority scope brokerGeneration verb ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ProjectPlan scope specDigest planId configId cfg ->
    (AcquisitionJournal scope planId brokerGeneration -> IO result) ->
    IO (Either LifecycleError result)
withAcquisitionJournal root bound boundSnapshot binding plan use =
    case consumeAcquisitionJournalAdmissionKernel admission of
        () ->
            case validateRetainedEvidence of
                Left failure -> pure (Left failure)
                Right () -> do
                    entered <-
                        withProtectedEntry store $ \session -> do
                            admitted <- validateLiveEvidence session
                            pure (Right admitted)
                    case entered of
                        Left failure -> pure (Left (SessionStoreFailure failure))
                        Right (Left failure) -> pure (Left failure)
                        Right (Right journal) -> Right <$> use journal
  where
    admission = acquisitionJournalAdmissionKernel
    runIdentity = boundRunLeaseIdentity bound
    location = boundRunLeaseLocation bound
    store = leaseLocationStore location
    project = leaseLocationProjectName location
    storeIdentity = leaseLocationStoreIdentity location
    run = boundRunLeaseRunText bound
    specDigest = boundRunLeaseSpecDigest bound
    planDigest = boundRunLeasePlanDigest bound
    epoch = boundRunLeaseEpoch bound
    epochWord = brokerEpochWord epoch
    leaseKey = leaseLocationLeaseKey location
    leaseVersion = boundRunLeaseRecordVersion bound
    profileName = projectPlanProfileNameKernel plan
    expectedProfileName = modeWireName (runIdentityMode runIdentity)
    indexed = projectPlanIndexedSnapshotKernel plan
    canonical = indexedPlanSnapshotCanonicalKernel indexed
    canonicalSpec = canonicalPlanSnapshotSpecDigest canonical
    canonicalPlan = canonicalPlanSnapshotDigest canonical
    canonicalConfig = canonicalPlanSnapshotConfigDigest canonical
    canonicalBytes = canonicalPlanSnapshotBytes canonical
    rootVerb = projectVerbName (rootAuthorityVerb root)

    validateRetainedEvidence = do
        requirePositive "broker epoch" epochWord
        requirePositive "lease record version" (recordVersionWord leaseVersion)
        requireText "root project" project (rootAuthorityProjectName root)
        requireText "root store" storeIdentity (rootAuthorityStoreIdentity root)
        requireWord "root broker epoch" epochWord (brokerEpochWord (rootAuthorityEpoch root))
        requireText "plan project" project (projectPlanProfileProjectNameKernel plan)
        requireText "plan store" storeIdentity (projectPlanProfileStoreIdentityKernel plan)
        requireWord "plan broker epoch" epochWord (projectPlanProfileEpochKernel plan)
        requireText "plan stable scope" expectedProfileName profileName
        requireText "plan specification digest" specDigest canonicalSpec
        requireText "plan digest" planDigest canonicalPlan
        requireText "digest binding" planDigest (planDigestBindingDigestKernel binding)
        requireBytes "bound snapshot bytes" canonicalBytes (boundPlanSnapshotBytesKernel boundSnapshot)
        requireNonempty "run" run
        requireNonempty "root verb" rootVerb

    validateLiveEvidence ::
        forall session.
        ProtectedSession session ->
        IO (Either LifecycleError (AcquisitionJournal scope planId brokerGeneration))
    validateLiveEvidence session = do
        liveResult <- validateLiveBinding session
        case liveResult of
            Left failure -> pure (Left failure)
            Right () ->
                openAcquisitionJournalKernel
                    admission
                    store
                    session
                    validateLiveBinding
                    profileName
                    project
                    storeIdentity
                    planDigest
                    (recordKeyText leaseKey)
                    (recordVersionWord leaseVersion)
                    run
                    specDigest
                    planDigest
                    epochWord
                    rootVerb

    validateLiveBinding ::
        forall session.
        ProtectedSession session ->
        IO (Either LifecycleError ())
    validateLiveBinding session = do
        modeResult <- validateLiveMode session
        case modeResult of
            Left failure -> pure (Left failure)
            Right () -> do
                leaseResult <- validateLiveLease session
                case leaseResult of
                    Left failure -> pure (Left failure)
                    Right () -> validateLiveSnapshot session

    validateLiveMode :: forall session. ProtectedSession session -> IO (Either LifecycleError ())
    validateLiveMode session =
        case storeKey ("mode." <> project) of
            Left failure -> pure (Left (modeFailure "mode record key" failure))
            Right key -> do
                observed <- readProtectedRecord session key
                pure $ case observed of
                    Left failure -> Left (SessionStoreFailure failure)
                    Right Nothing ->
                        Left (SessionAcquisitionBindingMismatch "live mode" expectedProfileName "absent")
                    Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                        Nothing -> Left (SessionRecordCorrupt "project mode")
                        Just (liveMode, liveEpoch) -> do
                            requireText "live mode" expectedProfileName (modeWireName liveMode)
                            requireWord "live mode broker epoch" epochWord liveEpoch

    validateLiveLease :: forall session. ProtectedSession session -> IO (Either LifecycleError ())
    validateLiveLease session = do
        observed <- readProtectedRecord session leaseKey
        pure $ case observed of
            Left failure -> Left (SessionStoreFailure failure)
            Right Nothing ->
                Left (SessionAcquisitionBindingMismatch "live lease record" (recordKeyText leaseKey) "absent")
            Right (Just record) -> do
                requireWord
                    "live lease record version"
                    (recordVersionWord leaseVersion)
                    (recordVersionWord (protectedRecordVersion record))
                case decodeLease (protectedRecordBytes record) of
                    Just (LeaseBound liveEpoch liveSpec livePlan) -> do
                        requireWord "live lease broker epoch" epochWord liveEpoch
                        requireText "live lease specification digest" specDigest liveSpec
                        requireText "live lease plan digest" planDigest livePlan
                        requireBytes
                            "live lease bytes"
                            (encodeLease (LeaseBound epochWord specDigest planDigest))
                            (protectedRecordBytes record)
                    Just other ->
                        Left
                            ( SessionAcquisitionBindingMismatch
                                "live lease state"
                                "bound"
                                (leaseStateName other)
                            )
                    Nothing -> Left (SessionRecordCorrupt "run lease")

    validateLiveSnapshot :: forall session. ProtectedSession session -> IO (Either LifecycleError ())
    validateLiveSnapshot session = do
        observed <-
            readVerifiedPlanSnapshotAt
                session
                (leaseLocationSnapshotKey location)
                runIdentity
                project
                storeIdentity
        pure $ case observed of
            Left failure -> Left (modeFailure "protected snapshot" failure)
            Right (SomeVerifiedPlanSnapshot snapshot) -> do
                requireText "live snapshot specification digest" specDigest (planSnapshotSpecDigest snapshot)
                requireText "live snapshot plan digest" planDigest (planSnapshotPlanDigest snapshot)
                requireMaybeText
                    "live snapshot configuration digest"
                    canonicalConfig
                    (planSnapshotConfigDigest snapshot)
                requireMaybeBytes
                    "live snapshot canonical bytes"
                    canonicalBytes
                    (planSnapshotCanonicalBytes snapshot)

    requireNonempty field value
        | Text.null value = Left (SessionAcquisitionBindingInvalid field)
        | otherwise = Right ()
    requirePositive field value
        | value == 0 = Left (SessionAcquisitionBindingInvalid field)
        | otherwise = Right ()
    requireText field expected observed
        | expected == observed = Right ()
        | otherwise = Left (SessionAcquisitionBindingMismatch field expected observed)
    requireWord field expected observed =
        requireText field (showWord expected) (showWord observed)
    requireBytes field expected observed
        | expected == observed = Right ()
        | otherwise = Left (SessionAcquisitionBindingMismatch field "exact bytes" "different bytes")
    requireMaybeText field expected observed = case observed of
        Just actual -> requireText field expected actual
        Nothing -> Left (SessionAcquisitionBindingMismatch field expected "absent")
    requireMaybeBytes field expected observed = case observed of
        Just actual -> requireBytes field expected actual
        Nothing -> Left (SessionAcquisitionBindingMismatch field "exact bytes" "absent")
    modeFailure field failure = case failure of
        ModeStoreFailure storeFailure -> SessionStoreFailure storeFailure
        _ ->
            SessionAcquisitionBindingMismatch
                field
                "valid retained evidence"
                (modeErrorMessage failure)

{- | Sealed config-origin child recovery.  The hidden admission token is
forced before any evidence, key, or store is inspected; the callback runs only
after the single protected entry has closed.
-}
reopenAuthenticatedChildCursorKernel ::
    AcquisitionJournalAdmission ->
    ProtectedStore ->
    HandoffBinding scope brokerGeneration ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ProjectFrame scope specDigest planId configId frame ->
    LifecyclePhase phase ->
    ( AcquisitionJournal scope planId brokerGeneration ->
      LifecycleCursor scope planId frame brokerGeneration VerbUp phase ->
      IO result
    ) ->
    IO (Either LifecycleError result)
reopenAuthenticatedChildCursorKernel admission store signed plan binding frame phase use =
    case consumeAcquisitionJournalAdmissionKernel admission of
        () -> case retainedEvidence of
            Left failure -> pure (Left failure)
            Right (run, expectedMode) -> do
                entered <- withProtectedEntry store $ \session -> do
                    reopened <-
                        reopenExistingAcquisitionCursorKernel
                            admission store session (validateLive run expectedMode)
                            profile project storeIdentity planDigest run specDigest epoch frame phase
                    pure (Right reopened)
                case entered of
                    Left failure -> pure (Left (SessionStoreFailure failure))
                    Right (Left failure) -> pure (Left failure)
                    Right (Right (journal, cursor)) -> Right <$> use journal cursor
  where
    profile = projectPlanProfileNameKernel plan
    project = projectPlanProfileProjectNameKernel plan
    storeIdentity = projectPlanProfileStoreIdentityKernel plan
    epoch = projectPlanProfileEpochKernel plan
    canonical = indexedPlanSnapshotCanonicalKernel (projectPlanIndexedSnapshotKernel plan)
    specDigest = canonicalPlanSnapshotSpecDigest canonical
    configDigest = canonicalPlanSnapshotConfigDigest canonical
    planDigest = canonicalPlanSnapshotDigest canonical
    canonicalBytes = canonicalPlanSnapshotBytes canonical

    retainedEvidence = do
        (run, mode) <- childRun profile (handoffScope signed)
        require "payload kind" (handoffPayloadKind signed == NarrowedProjectConfig)
        requireText "project" project (handoffInstalledProject signed)
        requireText "store" storeIdentity (handoffStoreIdentity signed)
        requireText "specification digest" specDigest (handoffSpecDigest signed)
        requireText "configuration digest" configDigest (handoffChildConfigDigest signed)
        requireText "plan digest" planDigest (handoffPlanRevision signed)
        requireText "digest binding" planDigest (planDigestBindingDigestKernel binding)
        requireWord "broker epoch" epoch (handoffBrokerGeneration signed)
        requireText "child frame" (projectFrameId frame) (handoffChildFrame signed)
        requireText "verb" (projectVerbName ProjectUp) (handoffVerb signed)
        requireText "phase" (lifecyclePhaseName phase) (handoffPhase signed)
        require "token commitment" (not (Text.null (handoffTokenCommitment signed)))
        requireText
            "retained store"
            storeIdentity
            (protectedStoreIdentityText (protectedStoreIdentity store))
        pure (run, mode)

    childRun planProfile signedScope
        | planProfile == "production", signedScope == "Production" =
            Right ("production", WireProduction)
        | Just run <- Text.stripPrefix "harness:" planProfile
        , signedScope == "Harness " <> run = do
            runKey <- either (Left . modeAsSession "run") Right (parseRunKey run)
            Right (run, WireHarness runKey)
        | otherwise = mismatch "lifecycle scope" planProfile signedScope

    validateLive ::
        Text ->
        ModeWire ->
        (forall liveSession. ProtectedSession liveSession -> Text -> Word64 -> IO (Either SessionError ()))
    validateLive run expectedMode session leaseText leaseVersion = do
        case requireText "lease key" canonicalLease leaseText of
            Left failure -> pure (Left failure)
            Right () -> do
                modeResult <- readRequired session ("mode." <> project) "project mode"
                leaseResult <- readRequired session canonicalLease "run lease"
                snapshotResult <- readRequired session ("snapshot." <> project <> "." <> run) "plan snapshot"
                pure $ do
                    modeRecord <- modeResult
                    (liveMode, modeEpoch) <- maybe (Left (SessionRecordCorrupt "project mode")) Right (decodeMode (protectedRecordBytes modeRecord))
                    require "project mode bytes" (protectedRecordBytes modeRecord == encodeMode liveMode modeEpoch)
                    requireText "live mode" (modeWireName expectedMode) (modeWireName liveMode)
                    requireWord "live mode broker epoch" epoch modeEpoch
                    leaseRecord <- leaseResult
                    requireWord "lease version" leaseVersion (recordVersionWord (protectedRecordVersion leaseRecord))
                    leaseState <- maybe (Left (SessionRecordCorrupt "run lease")) Right (decodeLease (protectedRecordBytes leaseRecord))
                    require "lease bytes" (protectedRecordBytes leaseRecord == encodeLease leaseState)
                    case leaseState of
                        LeaseBound recordedLeaseEpoch liveSpec livePlan -> do
                            requireWord "lease broker epoch" epoch recordedLeaseEpoch
                            requireText "lease specification digest" specDigest liveSpec
                            requireText "lease plan digest" planDigest livePlan
                        _ -> mismatch "lease state" "bound" (leaseStateName leaseState)
                    snapshotRecord <- snapshotResult
                    persisted <- maybe (Left (SessionRecordCorrupt "plan snapshot")) Right (decodePlanSnapshotRecord (protectedRecordBytes snapshotRecord))
                    require "snapshot bytes" (protectedRecordBytes snapshotRecord == encodePlanSnapshotRecord persisted)
                    requireText "snapshot specification digest" specDigest (snapshotRecordSpecDigest persisted)
                    requireText "snapshot plan digest" planDigest (snapshotRecordPlanDigest persisted)
                    requireText "snapshot configuration digest" configDigest (maybe "absent" id (snapshotRecordConfigDigest persisted))
                    require "snapshot canonical bytes" (snapshotRecordCanonicalBytes persisted == Just canonicalBytes)
      where
        canonicalLease = "lease." <> project <> "." <> run

    readRequired session raw subject = case mkRecordKey raw of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right key -> do
            observed <- readProtectedRecord session key
            pure $ case observed of
                Left failure -> Left (SessionStoreFailure failure)
                Right Nothing -> Left (SessionAcquisitionBindingMismatch subject "present" "absent")
                Right (Just record) -> Right record
    require field condition
        | condition = Right ()
        | otherwise = Left (SessionAcquisitionBindingMismatch field "exact" "different")
    requireText field expected observed
        | expected == observed = Right ()
        | otherwise = mismatch field expected observed
    requireWord field expected observed = requireText field (showWord expected) (showWord observed)
    mismatch field expected observed = Left (SessionAcquisitionBindingMismatch field expected observed)
    modeAsSession field failure =
        SessionAcquisitionBindingMismatch field "valid" (modeErrorMessage failure)

{- | Reopen one authenticated recovery child's existing reverse cursor.

The hidden admission is forced before the binding or store. This layer checks
only the authenticated adapter-digest coordinate; exact adapter bytes remain
owned by the later sealed child-entry verifier.
-}
reopenAuthenticatedRecoveryChildCursorKernel ::
    AcquisitionJournalAdmission ->
    ProtectedStore ->
    HandoffBinding scope brokerGeneration ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    ( AcquisitionJournal scope planId brokerGeneration ->
      LifecycleCursor scope planId frame brokerGeneration verb TeardownPhase ->
      IO result
    ) ->
    IO (Either LifecycleError result)
{-# OPAQUE reopenAuthenticatedRecoveryChildCursorKernel #-}
reopenAuthenticatedRecoveryChildCursorKernel admission =
    case consumeAcquisitionJournalAdmissionKernel admission of
        () -> \store signed plan binding frame verb use ->
            let profile = projectPlanProfileNameKernel plan
                project = projectPlanProfileProjectNameKernel plan
                storeIdentity = projectPlanProfileStoreIdentityKernel plan
                actualStore = protectedStoreIdentityText (protectedStoreIdentity store)
                epoch = projectPlanProfileEpochKernel plan
                canonical = projectPlanCanonicalSnapshotKernel plan
                specDigest = canonicalPlanSnapshotSpecDigest canonical
                configDigest = canonicalPlanSnapshotConfigDigest canonical
                planDigest = canonicalPlanSnapshotDigest canonical
                canonicalBytes = canonicalPlanSnapshotBytes canonical
                child = projectFrameId frame
                parent = handoffParentFrame signed
                adapterDigest = handoffChildConfigDigest signed
                run = runKeyText productionRunKey
                canonicalLease = "lease." <> project <> "." <> run

                retainedEvidence = do
                    require "payload kind" (handoffPayloadKind signed == RecoveryAdapterWire)
                    requireText "plan profile" "production" profile
                    requireText "handoff scope" "Production" (handoffScope signed)
                    requireText "project" project (handoffInstalledProject signed)
                    requireText "plan store" actualStore storeIdentity
                    requireText "handoff store" storeIdentity (handoffStoreIdentity signed)
                    requireText "specification digest" specDigest (handoffSpecDigest signed)
                    requireText "plan digest" planDigest (handoffPlanRevision signed)
                    requireText "digest binding" planDigest (planDigestBindingDigestKernel binding)
                    requireWord "broker generation" epoch (handoffBrokerGeneration signed)
                    requireText "child frame" child (handoffChildFrame signed)
                    requireText "verb" (projectVerbName verb) (handoffVerb signed)
                    requireText "phase" "teardown" (handoffPhase signed)
                    require "token commitment" (not (Text.null (handoffTokenCommitment signed)))
                    require "adapter digest coordinate" $
                        Text.length adapterDigest == 64 && Text.all lowerHex adapterDigest
                    require "topology edge" $
                        [ edge
                        | edge@(_, edgeChild) <- topologyParentEdges (topology plan)
                        , edgeChild == child
                        ]
                            == [(parent, child)]

                reopen = case retainedEvidence of
                    Left failure -> pure (Left failure)
                    Right () -> case reverseRootIntentKeyForName project of
                        Left failure -> pure (Left (modeAsSession "reverse-root intent key" failure))
                        Right intentKey -> do
                            entered <- withProtectedEntry store $ \session -> do
                                let admitCommitted intentRecord common target
                                        nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes =
                                            case validateDescriptor common target nextModeVersion nextModeBytes
                                                nextLeaseVersion nextLeaseBytes of
                                                Left failure -> pure (Left failure)
                                                Right () -> do
                                                    let (_, _, _, intentRevision, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = common
                                                        validateRowsAt :: forall liveSession.
                                                            ProtectedSession liveSession -> IO (Either SessionError ())
                                                        validateRowsAt live = do
                                                            let readRequired key subject = do
                                                                    observed <- readProtectedRecord live key
                                                                    pure $ case observed of
                                                                        Left failure -> Left (SessionStoreFailure failure)
                                                                        Right Nothing -> mismatch subject "present" "absent"
                                                                        Right (Just record) -> Right record
                                                                readNamed raw subject = case mkRecordKey raw of
                                                                    Left failure -> pure (Left (SessionStoreFailure failure))
                                                                    Right key -> readRequired key subject
                                                            intentResult <- readRequired intentKey "reverse-root intent"
                                                            modeResult <- readNamed ("mode." <> project) "project mode"
                                                            leaseResult <- readNamed canonicalLease "run lease"
                                                            snapshotResult <- readNamed
                                                                ("snapshot." <> project <> "." <> run) "plan snapshot"
                                                            pure $ do
                                                                requireText "live session store" storeIdentity
                                                                    (protectedStoreIdentityText (sessionStoreIdentity live))
                                                                currentIntent <- intentResult
                                                                requireWord "live intent version" 2
                                                                    (recordVersionWord (protectedRecordVersion currentIntent))
                                                                requireBytes "live intent bytes"
                                                                    (protectedRecordBytes intentRecord)
                                                                    (protectedRecordBytes currentIntent)
                                                                modeRecord <- modeResult
                                                                requireWord "live mode version" nextModeVersion
                                                                    (recordVersionWord (protectedRecordVersion modeRecord))
                                                                requireBytes "live mode bytes" nextModeBytes
                                                                    (protectedRecordBytes modeRecord)
                                                                leaseRecord <- leaseResult
                                                                requireWord "live lease version" nextLeaseVersion
                                                                    (recordVersionWord (protectedRecordVersion leaseRecord))
                                                                requireBytes "live lease bytes" nextLeaseBytes
                                                                    (protectedRecordBytes leaseRecord)
                                                                snapshotRecord <- snapshotResult
                                                                persisted <- maybe (Left (SessionRecordCorrupt "plan snapshot")) Right
                                                                    (decodePlanSnapshotRecord (protectedRecordBytes snapshotRecord))
                                                                requireBytes "live snapshot bytes"
                                                                    (encodePlanSnapshotRecord persisted)
                                                                    (protectedRecordBytes snapshotRecord)
                                                                requireWord "live snapshot revision" intentRevision
                                                                    (snapshotRecordRevision persisted)
                                                                requireText "live snapshot specification" specDigest
                                                                    (snapshotRecordSpecDigest persisted)
                                                                requireText "live snapshot plan" planDigest
                                                                    (snapshotRecordPlanDigest persisted)
                                                                requireText "live snapshot configuration" configDigest
                                                                    (maybe "absent" id (snapshotRecordConfigDigest persisted))
                                                                require "live snapshot canonical plan" $
                                                                    snapshotRecordCanonicalBytes persisted == Just canonicalBytes
                                                    rows <- validateRowsAt session
                                                    case rows of
                                                        Left failure -> pure (Left failure)
                                                        Right () ->
                                                            reopenExistingReverseAcquisitionJournalKernel
                                                                admission store session
                                                                ( \live leaseText leaseVersion ->
                                                                    case do
                                                                        requireText "journal lease key" canonicalLease leaseText
                                                                        requireWord "journal lease version" nextLeaseVersion leaseVersion
                                                                    of
                                                                        Left failure -> pure (Left failure)
                                                                        Right () -> validateRowsAt live
                                                                )
                                                                profile project storeIdentity planDigest run specDigest epoch frame verb
                                observed <- readProtectedRecord session intentKey
                                journal <- case observed of
                                    Left failure -> pure (Left (SessionStoreFailure failure))
                                    Right Nothing -> pure (mismatch "reverse-root intent" "committed" "absent")
                                    Right (Just record)
                                        | recordVersionWord (protectedRecordVersion record) /= 2 ->
                                            pure (mismatch "reverse-root intent version" "2"
                                                (showWord (recordVersionWord (protectedRecordVersion record))))
                                        | otherwise -> case decodeReverseRootIntent verb (protectedRecordBytes record) of
                                            Just (ReverseRootDownCommitted common target modeVersion modeBytes leaseVersion leaseBytes) ->
                                                admitCommitted record common target modeVersion modeBytes leaseVersion leaseBytes
                                            Just (ReverseRootDestroyCommitted common target modeVersion modeBytes leaseVersion leaseBytes) ->
                                                admitCommitted record common target modeVersion modeBytes leaseVersion leaseBytes
                                            Just ReverseRootDownPending{} ->
                                                pure (mismatch "reverse-root intent state" "committed" "pending")
                                            Just ReverseRootDestroyPending{} ->
                                                pure (mismatch "reverse-root intent state" "committed" "pending")
                                            Nothing
                                                | oppositeIntent (protectedRecordBytes record) ->
                                                    pure (mismatch "reverse-root intent verb" (projectVerbName verb) "opposite")
                                                | otherwise -> pure (Left (SessionRecordCorrupt "reverse-root intent"))
                                pure (Right journal)
                            case entered of
                                Left failure -> pure (Left (SessionStoreFailure failure))
                                Right (Left failure) -> pure (Left failure)
                                Right (Right journal) ->
                                    withReverseRootTargetLifecycleCursorKernel
                                        admission journal frame verb (use journal)

                validateDescriptor common target nextModeVersion nextModeBytes
                    nextLeaseVersion nextLeaseBytes = do
                        requireText "intent project" project intentProject
                        requireText "intent store" storeIdentity intentStore
                        requireText "intent run" run intentRun
                        requireText "intent specification" specDigest intentSpec
                        requireText "intent configuration" configDigest intentConfig
                        requireText "intent plan" planDigest intentPlan
                        requireBytes "intent canonical plan" canonicalBytes intentCanonical
                        requireWord "intent target generation" epoch target
                        require "intent target successor" (target > source)
                        require "old mode version" (oldModeVersion < maxBound)
                        require "old lease version" (oldLeaseVersion < maxBound)
                        requireBytes "old mode bytes" (encodeMode WireProduction source) oldModeBytes
                        requireBytes "old lease bytes"
                            (encodeLease (LeaseBound source specDigest planDigest)) oldLeaseBytes
                        requireWord "target mode version" (oldModeVersion + 1) nextModeVersion
                        requireBytes "target mode bytes" (encodeMode WireProduction target) nextModeBytes
                        requireWord "target lease version" (oldLeaseVersion + 1) nextLeaseVersion
                        requireBytes "target lease bytes"
                            (encodeLease (LeaseBound target specDigest planDigest)) nextLeaseBytes
                  where
                    (intentProject, intentStore, intentRun, _, intentSpec, intentConfig, intentPlan,
                        intentCanonical, source, _, _, _, _, _, _, _, _, oldModeVersion, oldModeBytes,
                        oldLeaseVersion, oldLeaseBytes) = common

                oppositeIntent bytes = case verb of
                    ProjectDown -> maybe False (const True) (decodeReverseRootIntent ProjectDestroy bytes)
                    ProjectDestroy -> maybe False (const True) (decodeReverseRootIntent ProjectDown bytes)
                    ProjectUp -> False
                lowerHex character = ('0' <= character && character <= '9')
                    || ('a' <= character && character <= 'f')
                require field condition
                    | condition = Right ()
                    | otherwise = mismatch field "exact" "different"
                requireText field expected observed
                    | expected == observed = Right ()
                    | otherwise = mismatch field expected observed
                requireWord field expected observed = requireText field (showWord expected) (showWord observed)
                requireBytes field expected observed
                    | expected == observed = Right ()
                    | otherwise = mismatch field "exact bytes" "different bytes"
                mismatch field expected observed =
                    Left (SessionAcquisitionBindingMismatch field expected observed)
                modeAsSession field failure = case failure of
                    ModeStoreFailure storeFailure -> SessionStoreFailure storeFailure
                    _ -> SessionAcquisitionBindingMismatch field "valid" (modeErrorMessage failure)
             in case verb of
                    ProjectUp -> pure (Left (SessionCursorVerbMismatch "down/destroy" "up"))
                    ProjectDown -> reopen
                    ProjectDestroy -> reopen

{- | Purely prove that a later authority gate was given the exact bound lease
whose full protected origin was retained by an acquisition journal.

The public lease projections intentionally omit its store, project, record
key/version, and broker evidence.  Keeping this comparison beside the opaque
'BoundRunLease' representation lets the specialized authority facade reject a
hostile phantom substitution without exposing those members individually.
-}
validateBoundRunLeaseAcquisitionJournal ::
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    AcquisitionJournal scope planId brokerGeneration ->
    Either LifecycleError ()
validateBoundRunLeaseAcquisitionJournal bound journal =
    validateAcquisitionJournalBindingKernel
        journal
        (modeWireName (runIdentityMode runIdentity))
        (leaseLocationProjectName location)
        (leaseLocationStoreIdentity location)
        (boundRunLeasePlanDigest bound)
        (recordKeyText (leaseLocationLeaseKey location))
        (recordVersionWord (boundRunLeaseRecordVersion bound))
        (boundRunLeaseRunText bound)
        (boundRunLeaseSpecDigest bound)
        (boundRunLeasePlanDigest bound)
        (brokerEpochWord (boundRunLeaseEpoch bound))
  where
    runIdentity = boundRunLeaseIdentity bound
    location = boundRunLeaseLocation bound

{- | Proof that one exact plan binding was fresh, so no recovery is owed.

The constructor is private and all five indices are nominal.  In particular,
generic lease binding cannot invent the local @planId@; only the fresh
project-plan snapshot leaf can supply the hidden matching digest binding.
-}
type role NormalActiveRecovery nominal nominal nominal nominal nominal
data NormalActiveRecovery scope specDigest planDigest planId brokerGeneration
    = NormalActiveRecovery
        (RunIdentity scope)
        Text
        Text
        (BrokerEpoch brokerGeneration)

instance Show (NormalActiveRecovery scope specDigest planDigest planId brokerGeneration) where
    show (NormalActiveRecovery run spec plan epoch) =
        "NormalActiveRecovery "
            <> Text.unpack (runIdentityText run)
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch

normalActiveRecoveryRunText ::
    NormalActiveRecovery scope specDigest planDigest planId brokerGeneration ->
    Text
normalActiveRecoveryRunText (NormalActiveRecovery run _ _ _) = runIdentityText run

newtype LeaseConflict = LeaseConflict ModeError
    deriving (Eq, Show)

leaseConflictMessage :: LeaseConflict -> Text
leaseConflictMessage (LeaseConflict failure) = modeErrorMessage failure

{- | Bind a lease to the exact verified plan snapshot, in one protected
compare-and-swap over the recorded lease.

The digests are the snapshot's, not a caller's: they are carried by
'VerifiedPlanSnapshot', which exists only where 'verifyPlanSnapshot' read them
back out of the protected store. That is what makes "the lease is bound to a
snapshot that was persisted and verified" structural rather than a convention,
and it is why the successor lease record can classify an abandoned run without a
config.

This fresh transition accepts only the exact retained unbound record version.
An already-bound lease is a 'LeaseConflict' and yields no authority; recovery
must enter through the separate existing-bound admission, which cannot mint
'NormalActiveRecovery'.
-}
bindRunLease ::
    UnboundRunLease scope brokerGeneration ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    (BoundRunLease scope specDigest planDigest brokerGeneration -> IO result) ->
    IO (Either LeaseConflict result)
bindRunLease unbound snapshot use =
    do
        bound <- bindFreshRunLease unbound snapshot
        case bound of
            Left failure -> pure (Left (LeaseConflict failure))
            Right lease -> Right <$> use lease

{- | Fresh-only binding for the exact locally admitted plan identity.

The private indexed snapshot makes this seam unavailable to external callers;
the opaque digest binding then pins @planId@ and @planDigest@ to that same
snapshot.  A failed or already-completed lease CAS yields no normal-active
evidence.
-}
bindRunLeaseWithPlanRecovery ::
    UnboundRunLease scope brokerGeneration ->
    IndexedPlanSnapshot scope specDigest planId configId ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ( BoundRunLease scope specDigest planDigest brokerGeneration ->
      NormalActiveRecovery scope specDigest planDigest planId brokerGeneration ->
      IO result
    ) ->
    IO (Either LeaseConflict result)
bindRunLeaseWithPlanRecovery unbound indexed snapshot binding use =
    case refineVerifiedPlanSnapshot indexed snapshot of
        Left failure -> pure (Left (LeaseConflict failure))
        Right exact
            | planDigestBindingDigestKernel binding /= planSnapshotPlanDigest exact ->
                pure
                    ( Left
                        ( LeaseConflict
                            ( ModeSnapshotMismatch
                                (planSnapshotPlanDigest exact)
                                (planDigestBindingDigestKernel binding)
                            )
                        )
                    )
            | otherwise -> do
                bound <- bindFreshRunLease unbound exact
                case bound of
                    Left failure -> pure (Left (LeaseConflict failure))
                    Right lease ->
                        Right
                            <$> use
                                lease
                                ( NormalActiveRecovery
                                    (unboundRunLeaseIdentity unbound)
                                    (planSnapshotSpecDigest exact)
                                    (planSnapshotPlanDigest exact)
                                    (unboundRunLeaseEpoch unbound)
                                )

bindFreshRunLease ::
    UnboundRunLease scope brokerGeneration ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    IO (Either ModeError (BoundRunLease scope specDigest planDigest brokerGeneration))
bindFreshRunLease unbound snapshot =
    case validateLeaseSnapshot unbound snapshot of
        Left failure -> pure (Left failure)
        Right () -> withUnboundLeaseEntry unbound $ \session -> do
            let location = unboundRunLeaseLocation unbound
                run = unboundRunLeaseIdentity unbound
                epoch = unboundRunLeaseEpoch unbound
                specDigest = planSnapshotSpecDigest snapshot
                planDigest = planSnapshotPlanDigest snapshot
            retained <- readRetainedUnboundLeaseAt session unbound
            case retained of
                Left failure -> pure (Left failure)
                Right record -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            (leaseLocationLeaseKey location)
                            (ExpectVersion (protectedRecordVersion record))
                            ( encodeLease
                                ( LeaseBound
                                    (brokerEpochWord epoch)
                                    specDigest
                                    planDigest
                                )
                            )
                    pure $ case written of
                        Left failure -> Left (ModeStoreFailure failure)
                        Right version ->
                            Right
                                (BoundRunLease run location specDigest planDigest epoch version FreshBinding)

readRetainedUnboundLeaseAt ::
    ProtectedSession session ->
    UnboundRunLease scope brokerGeneration ->
    IO (Either ModeError ProtectedRecord)
readRetainedUnboundLeaseAt session unbound = do
    observed <- readProtectedRecord session (leaseLocationLeaseKey location)
    pure $ case observed of
        Left failure -> Left (ModeStoreFailure failure)
        Right Nothing -> Left (ModeLeaseMissing (runIdentityText run))
        Right (Just record) -> case decodeLease (protectedRecordBytes record) of
            Just (LeaseUnbound recordedEpoch)
                | recordedEpoch /= brokerEpochWord epoch ->
                    Left (ModeEpochMismatch recordedEpoch (brokerEpochWord epoch))
                | recordVersionWord (protectedRecordVersion record)
                    /= unboundRunLeaseRecordVersion unbound ->
                    Left
                        ( ModeLeaseNotBindable
                            (runIdentityText run)
                            "the retained unbound lease version is stale"
                        )
                | otherwise -> Right record
            Just other ->
                Left (ModeLeaseNotBindable (runIdentityText run) (leaseStateName other))
            Nothing ->
                Left (ModeMalformedRecord (recordKeyText (leaseLocationLeaseKey location)))
  where
    location = unboundRunLeaseLocation unbound
    run = unboundRunLeaseIdentity unbound
    epoch = unboundRunLeaseEpoch unbound

validateLeaseSnapshot ::
    UnboundRunLease scope brokerGeneration ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    Either ModeError ()
validateLeaseSnapshot unbound snapshot
    | runIdentityKey (unboundRunLeaseIdentity unbound) /= planSnapshotRunKey snapshot = mismatch runName snapshotRun
    | leaseLocationProjectName location /= planSnapshotProjectName snapshot =
        mismatch (leaseLocationProjectName location) (planSnapshotProjectName snapshot)
    | leaseLocationStoreIdentity location /= planSnapshotStoreIdentity snapshot =
        mismatch (leaseLocationStoreIdentity location) (planSnapshotStoreIdentity snapshot)
    | otherwise = Right ()
  where
    location = unboundRunLeaseLocation unbound
    runName = unboundRunLeaseRunText unbound
    snapshotRun = planSnapshotRunText snapshot
    mismatch expected observed = Left (ModeSnapshotMismatch expected observed)

-- Bound-invocation recovery -------------------------------------------------------

{- | The stable, idempotent key a terminal Production acknowledgment was
recorded under. Recovery may only /resume/ this exact key; it cannot invent a
new close.
-}
newtype InvocationCloseKey = InvocationCloseKey Text
    deriving (Eq, Ord)

instance Show InvocationCloseKey where
    show (InvocationCloseKey value) = "InvocationCloseKey " <> show value

{- | The only constructor. The key must be stable and record-safe: a caller
derives it from the run and verb it closes, and an empty or separator-bearing
value is refused so a key can never shift the meaning of the fields after it.
-}
mkInvocationCloseKey :: Text -> Either ModeError InvocationCloseKey
mkInvocationCloseKey raw
    | Text.null raw =
        Left (ModeInvalidIdentity "an invocation close key must not be empty")
    | Text.length raw > 64 =
        Left (ModeInvalidIdentity "an invocation close key must be at most 64 characters")
    | not (Text.all legal raw) =
        Left
            ( ModeInvalidIdentity
                ("an invocation close key may contain only alphanumerics, '-' and '.': " <> raw)
            )
    | otherwise = Right (InvocationCloseKey raw)
  where
    legal character = isAlphaNum character || character == '-' || character == '.'

invocationCloseKeyText :: InvocationCloseKey -> Text
invocationCloseKeyText (InvocationCloseKey value) = value

{- | What the durable invocation record says about a bound lease that did not
settle. This is the /whole/ closed set of dispositions: there is no "unknown"
default, because an absent record is itself the definite Open observation.
-}
data InvocationDisposition
    = -- | No terminal record: the invocation was still operating.
      InvocationOpen
    | {- | An ordinary Production @up@\/@down@ recorded its terminal
      acknowledgment and did not finish closing its lease.
      -}
      InvocationAcknowledged InvocationCloseKey
    | -- | A Harness run persisted its Closing epoch and did not finish.
      InvocationClosing Word64
    deriving (Eq, Show)

{- | Package-private scope-only observation used while classifying an abandoned
Harness invocation that reached a plan. Its constructor is private and its
sole producer starts from a sweep-verified bound lease, so a caller cannot
claim recovery authority for a run that never bound one.

The value itself authorizes nothing. Harness classification refuses a
Production terminal acknowledgment rather than treating it as a Harness
revision.
-}
type role ObservedBoundInvocationRecovery nominal
data ObservedBoundInvocationRecovery scope
    = ObservedBoundInvocationRecovery (RunIdentity scope) Text Text InvocationDisposition

instance Show (ObservedBoundInvocationRecovery scope) where
    show (ObservedBoundInvocationRecovery run spec plan disposition) =
        "ObservedBoundInvocationRecovery "
            <> Text.unpack (runIdentityText run)
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show disposition

{- | An exact existing-bound Production admission.

All five parameters are nominal.  The hidden representation retains the run,
project and protected-store origin, both stable digests, exact recorded broker
generation, and the already classified durable Open revision.  It carries no
journal, cursor, migration policy, replay, or effect authority.
-}
type role BoundInvocationRecovery nominal nominal nominal nominal nominal
data BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration
    = BoundInvocationRecovery
        (RunIdentity scope)
        Text
        Text
        Text
        Text
        (BrokerEpoch brokerGeneration)
        OpenRevisionKind

instance
    Show
        ( BoundInvocationRecovery
            scope
            specDigest
            planDigest
            planId
            brokerGeneration
        )
    where
    show (BoundInvocationRecovery run project _store spec plan epoch kind) =
        "BoundInvocationRecovery "
            <> Text.unpack (runIdentityText run)
            <> " "
            <> show project
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch
            <> " "
            <> show kind

boundInvocationRecoveryRunText ::
    BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration ->
    Text
boundInvocationRecoveryRunText (BoundInvocationRecovery run _ _ _ _ _ _) = runIdentityText run

boundInvocationRecoveryRevisionKind ::
    BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration ->
    OpenRevisionKind
boundInvocationRecoveryRevisionKind (BoundInvocationRecovery _ _ _ _ _ _ kind) = kind

-- Existing-bound reverse-root reauthorization ---------------------------------

{- | Private write-ahead state for one successful Production @up@ lineage.

Pending contains no target generation.  Committed adds the sole allocated
target and the complete predicted mode/lease successor records, so recovery
never has to infer whether either independent suffix write committed.
-}
data ReverseRootIntent projectId sourceBrokerGeneration verb where
    ReverseRootDownPending ::
        ( Text, Text, Text, Word64, Text, Text, Text, ByteString, Word64
        , RecordKey, Word64, ByteString, RecordKey, Word64, ByteString, Text, Word64
        , Word64, ByteString, Word64, ByteString
        ) -> ReverseRootIntent projectId sourceBrokerGeneration VerbDown
    ReverseRootDestroyPending ::
        ( Text, Text, Text, Word64, Text, Text, Text, ByteString, Word64
        , RecordKey, Word64, ByteString, RecordKey, Word64, ByteString, Text, Word64
        , Word64, ByteString, Word64, ByteString
        ) -> ReverseRootIntent projectId sourceBrokerGeneration VerbDestroy
    ReverseRootDownCommitted ::
        ( Text, Text, Text, Word64, Text, Text, Text, ByteString, Word64
        , RecordKey, Word64, ByteString, RecordKey, Word64, ByteString, Text, Word64
        , Word64, ByteString, Word64, ByteString
        ) -> Word64 -> Word64 -> ByteString -> Word64 -> ByteString ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDown
    ReverseRootDestroyCommitted ::
        ( Text, Text, Text, Word64, Text, Text, Text, ByteString, Word64
        , RecordKey, Word64, ByteString, RecordKey, Word64, ByteString, Text, Word64
        , Word64, ByteString, Word64, ByteString
        ) -> Word64 -> Word64 -> ByteString -> Word64 -> ByteString ->
        ReverseRootIntent projectId sourceBrokerGeneration VerbDestroy

type role ReverseRootIntent nominal nominal nominal

reverseRootIntentMagic :: ByteString
reverseRootIntentMagic = "HOSTBOOTSTRAP-REVERSE-ROOT"

reverseRootIntentVersion :: Word64
reverseRootIntentVersion = 1

encodeReverseRootIntent :: ReverseRootIntent projectId sourceBrokerGeneration verb -> ByteString
encodeReverseRootIntent intent =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString reverseRootIntentMagic
                <> Builder.word64BE reverseRootIntentVersion
                <> Builder.word64BE (fromIntegral (length fields))
                <> foldMap encodeSnapshotBytes fields
            )
        )
  where
    fields = case intent of
        ReverseRootDownPending values -> common "pending" "down" values
        ReverseRootDestroyPending values -> common "pending" "destroy" values
        ReverseRootDownCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes ->
            committed "down" values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
        ReverseRootDestroyCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes ->
            committed "destroy" values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
    committed verb values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes =
        common "committed" verb values
            <> [word target, word nextModeVersion, nextModeBytes, word nextLeaseVersion, nextLeaseBytes]
    common state verb (project, store, run, revision, spec, config, plan, canonical, source,
        acquisitionKey, acquisitionVersion, acquisitionBytes, cursorKey, cursorVersion, cursorBytes,
        rootFrame, sessions, modeVersion, modeBytes, leaseVersion, leaseBytes) =
            [ text state, text verb, text project, text store, text run
            , word revision, text spec, text config, text plan, canonical, word source
            , text (recordKeyText acquisitionKey), word acquisitionVersion, acquisitionBytes
            , text (recordKeyText cursorKey), word cursorVersion, cursorBytes, text rootFrame
            , word sessions, word modeVersion, modeBytes, word leaseVersion, leaseBytes
            ]
    text = TextEncoding.encodeUtf8
    word = ByteStringChar8.pack . show

decodeReverseRootIntent ::
    forall projectId sourceBrokerGeneration verb.
    ProjectVerb verb ->
    ByteString ->
    Maybe (ReverseRootIntent projectId sourceBrokerGeneration verb)
decodeReverseRootIntent expected raw = do
    case expected of
        ProjectUp -> Nothing
        ProjectDown -> pure ()
        ProjectDestroy -> pure ()
    fields <- decodeIntentFields raw
    case fields of
        state : verb : commonFields -> do
            stateText <- asText state
            verbText <- asText verb
            if verbText /= projectVerbName expected then Nothing else pure ()
            case (stateText, commonFields) of
                ("pending", commonValues) -> do
                    (project, store, run, revision, spec, config, plan, canonical, source,
                        acquisitionKey, acquisitionVersion, acquisitionBytes,
                        cursorKey, cursorVersion, cursorBytes, rootFrame, sessions,
                        modeVersion, modeBytes, leaseVersion, leaseBytes) <- parseCommon commonValues
                    let values = (project, store, run, revision, spec, config, plan, canonical, source,
                            acquisitionKey, acquisitionVersion, acquisitionBytes, cursorKey, cursorVersion,
                            cursorBytes, rootFrame, sessions, modeVersion, modeBytes, leaseVersion, leaseBytes)
                    case expected of
                        ProjectDown -> canonicalIntent (ReverseRootDownPending values)
                        ProjectDestroy -> canonicalIntent (ReverseRootDestroyPending values)
                        ProjectUp -> Nothing
                ("committed", commonValues) -> case splitAt 21 commonValues of
                    (base, [targetRaw, nextModeVersionRaw, nextModeBytes, nextLeaseVersionRaw, nextLeaseBytes]) -> do
                        (project, store, run, revision, spec, config, plan, canonical, source,
                            acquisitionKey, acquisitionVersion, acquisitionBytes,
                            cursorKey, cursorVersion, cursorBytes, rootFrame, sessions,
                            modeVersion, modeBytes, leaseVersion, leaseBytes) <- parseCommon base
                        target <- positive targetRaw
                        nextModeVersion <- positive nextModeVersionRaw
                        nextLeaseVersion <- positive nextLeaseVersionRaw
                        let values = (project, store, run, revision, spec, config, plan, canonical, source,
                                acquisitionKey, acquisitionVersion, acquisitionBytes, cursorKey, cursorVersion,
                                cursorBytes, rootFrame, sessions, modeVersion, modeBytes, leaseVersion, leaseBytes)
                        case expected of
                            ProjectDown -> canonicalIntent (ReverseRootDownCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes)
                            ProjectDestroy -> canonicalIntent (ReverseRootDestroyCommitted values target nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes)
                            ProjectUp -> Nothing
                    _ -> Nothing
                _ -> Nothing
        _ -> Nothing
  where
    canonicalIntent ::
        ReverseRootIntent projectId sourceBrokerGeneration verb ->
        Maybe (ReverseRootIntent projectId sourceBrokerGeneration verb)
    canonicalIntent intent
        | encodeReverseRootIntent intent == raw = Just intent
        | otherwise = Nothing
    parseCommon values = case values of
        [projectRaw, storeRaw, runRaw, revisionRaw, specRaw, configRaw, planRaw, canonical,
            sourceRaw, acquisitionKeyRaw, acquisitionVersionRaw, acquisitionBytes,
            cursorKeyRaw, cursorVersionRaw, cursorBytes, rootFrameRaw, sessionsRaw,
            modeVersionRaw, modeBytes, leaseVersionRaw, leaseBytes] -> do
                project <- nonempty projectRaw
                store <- nonempty storeRaw
                run <- nonempty runRaw
                revision <- positive revisionRaw
                spec <- nonempty specRaw
                config <- nonempty configRaw
                plan <- nonempty planRaw
                if ByteString.null canonical || ByteString.length canonical > maxCanonicalPlanBytes
                    then Nothing
                    else pure ()
                source <- positive sourceRaw
                acquisitionKey <- asText acquisitionKeyRaw >>= either (const Nothing) Just . mkRecordKey
                acquisitionVersion <- positive acquisitionVersionRaw
                if ByteString.null acquisitionBytes then Nothing else pure ()
                cursorKey <- asText cursorKeyRaw >>= either (const Nothing) Just . mkRecordKey
                cursorVersion <- positive cursorVersionRaw
                if ByteString.null cursorBytes then Nothing else pure ()
                rootFrame <- nonempty rootFrameRaw
                sessions <- number sessionsRaw
                modeVersion <- positive modeVersionRaw
                if ByteString.null modeBytes then Nothing else pure ()
                leaseVersion <- positive leaseVersionRaw
                if ByteString.null leaseBytes then Nothing else pure ()
                pure (project, store, run, revision, spec, config, plan, canonical, source,
                    acquisitionKey, acquisitionVersion, acquisitionBytes, cursorKey, cursorVersion,
                    cursorBytes, rootFrame, sessions, modeVersion, modeBytes, leaseVersion, leaseBytes)
        _ -> Nothing
    asText bytes
        | ByteString.length bytes > maxSnapshotTextBytes = Nothing
        | otherwise = either (const Nothing) Just (TextEncoding.decodeUtf8' bytes)
    nonempty bytes = asText bytes >>= \value -> if Text.null value then Nothing else Just value
    number bytes = asText bytes >>= readWord
    positive bytes = number bytes >>= \value -> if value == 0 then Nothing else Just value

decodeIntentFields :: ByteString -> Maybe [ByteString]
decodeIntentFields raw
    | ByteString.length raw > maxSnapshotRecordBytes = Nothing
    | otherwise = do
        afterMagic <- ByteString.stripPrefix reverseRootIntentMagic raw
        (version, afterVersion) <- takeSnapshotWord afterMagic
        if version /= reverseRootIntentVersion then Nothing else pure ()
        (count, payload) <- takeSnapshotWord afterVersion
        if count > 32 then Nothing else collect count payload []
  where
    collect 0 trailing fields
        | ByteString.null trailing = Just (reverse fields)
        | otherwise = Nothing
    collect remaining payload fields = do
        (field, trailing) <- takeSnapshotBytesBounded maxSnapshotRecordBytes payload
        collect (remaining - 1) trailing (field : fields)

{- | The Open branch: the invocation was still operating, so its /revision/ has
to be recovered. Its constructor is private, and it is reached only after the
terminal dispositions have been ruled out.
-}
type role OpenRevisionRecovery nominal
data OpenRevisionRecovery scope
    = OpenRevisionRecovery (RunIdentity scope) Text Text OpenRevisionKind

instance Show (OpenRevisionRecovery scope) where
    show (OpenRevisionRecovery run spec plan kind) =
        "OpenRevisionRecovery "
            <> Text.unpack (runIdentityText run)
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show kind

openRevisionRecoveryRunText :: OpenRevisionRecovery scope -> Text
openRevisionRecoveryRunText (OpenRevisionRecovery run _ _ _) = runIdentityText run

{- | Which revision recovery the Open branch selects (§ EE). A recorded
migration key distinguishes a staging that never activated from one whose
activation compare-and-swap already committed, so a restart resumes the correct
side of that barrier instead of guessing from the current config.
-}
data OpenRevisionKind
    = NormalRevision
    | IncompleteMigration Text
    | CompletedMigration Text
    deriving (Eq, Show)

openRevisionKind :: OpenRevisionRecovery scope -> OpenRevisionKind
openRevisionKind (OpenRevisionRecovery _ _ _ kind) = kind

data ExistingBoundSnapshotObservation projectId
    = ExistingBoundSnapshotTerminal InvocationCloseKey
    | forall brokerGeneration specDigest planDigest.
      ExistingBoundSnapshotOpen
        (RootInvocationAuthority (Production projectId) brokerGeneration VerbUp)
        (ProjectModeLease projectId ProductionMode brokerGeneration)
        (BoundRunLease (Production projectId) specDigest planDigest brokerGeneration)
        (VerifiedPlanSnapshot (Production projectId) specDigest planDigest)
        CanonicalPlanSnapshot
        OpenRevisionKind

{- | Package-gated kernel for the sole public existing-Production snapshot
admission in "HostBootstrap.ProjectPlan.Snapshot".

The hidden admission witness is forced before store access.  One protected
entry then reads and cross-checks the existing Production mode, exact allocated
broker generation, authority binding, bound lease, canonical snapshot, and
invocation disposition.  It performs no protected mutation.  Both user
callbacks run only after that entry has closed; only Open reaches the hidden
rank-2 local-plan binder.
-}
withBoundPlanSnapshotKernel ::
    ExistingBoundSnapshotAdmission ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    (InvocationCloseKey -> IO result) ->
    ( forall
        (brokerGeneration :: Type)
        (specDigest :: Type)
        (planDigest :: Type)
        (planId :: Type).
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      ProjectModeLease projectId ProductionMode brokerGeneration ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      BoundInvocationRecovery
        (Production projectId)
        specDigest
        planDigest
        planId
        brokerGeneration ->
      IO result
    ) ->
    IO (Either ModeError result)
withBoundPlanSnapshotKernel admission store project terminal useOpen =
    case consumeExistingBoundSnapshotAdmissionKernel admission of
        () ->
            case makeLeaseLocation store project productionRunKey of
                Left failure -> pure (Left failure)
                Right location -> do
                    prepared <-
                        runProtected store $ \session -> do
                            clear <- refuseReverseRootIntent session project
                            case clear of
                                Left failure -> pure (Left failure)
                                Right () -> prepareExistingBoundSnapshotAt session location project
                    case prepared of
                        Left failure -> pure (Left failure)
                        Right (ExistingBoundSnapshotTerminal key) -> Right <$> terminal key
                        Right
                            ( ExistingBoundSnapshotOpen
                                root
                                modeLease
                                boundLease
                                verified
                                canonical
                                revisionKind
                                ) ->
                                Right
                                    <$> withPersistedBoundPlanSnapshotKernel canonical
                                        ( \boundSnapshot binding ->
                                            useOpen
                                                root
                                                modeLease
                                                boundLease
                                                verified
                                                boundSnapshot
                                                binding
                                                ( BoundInvocationRecovery
                                                    (ProductionRunIdentity productionRunKey)
                                                    (rootAuthorityProjectName root)
                                                    (rootAuthorityStoreIdentity root)
                                                    (planSnapshotSpecDigest verified)
                                                    (planSnapshotPlanDigest verified)
                                                    (rootAuthorityEpoch root)
                                                    revisionKind
                                                )
                                        )

prepareExistingBoundSnapshotAt ::
    ProtectedSession session ->
    LeaseLocation ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError (ExistingBoundSnapshotObservation projectId))
prepareExistingBoundSnapshotAt session location project = do
    observedMode <- readExistingProductionModeEpochAt session project
    case observedMode of
        Left failure -> pure (Left failure)
        Right recordedEpoch ->
            withRecordedEpoch session project recordedEpoch $ \epoch -> do
                operator <- verifyOsPrincipal session
                case operator of
                    Left failure -> pure (Left (ModeAuthorityFailure failure))
                    Right authorized ->
                        withExistingVerifiedRoot
                            ProductionRootScope
                            session
                            project
                            authorized
                            epoch
                            ProjectUp
                            $ \root -> do
                                let modeLease =
                                        ProjectModeLease
                                            WireProduction
                                            (installedProjectName project)
                                            (protectedStoreIdentityText (sessionStoreIdentity session))
                                            epoch
                                withExistingProductionBoundSnapshotAt
                                    session
                                    location
                                    epoch
                                    $ \boundLease verified canonical disposition ->
                                        case disposition of
                                            InvocationAcknowledged key ->
                                                pure
                                                    ( Right
                                                        (ExistingBoundSnapshotTerminal key)
                                                    )
                                            InvocationClosing closingEpoch ->
                                                pure
                                                    ( Left
                                                        ( ModeWrongRecoveryScope
                                                            "production"
                                                            ( "harness closing epoch "
                                                                <> showWord closingEpoch
                                                            )
                                                        )
                                                    )
                                            InvocationOpen -> do
                                                revision <-
                                                    readOpenRevisionKindForKey
                                                        session
                                                        project
                                                        productionRunKey
                                                pure
                                                    ( fmap
                                                        ( ExistingBoundSnapshotOpen
                                                            root
                                                            modeLease
                                                            boundLease
                                                            verified
                                                            canonical
                                                        )
                                                        revision
                                                    )

readExistingProductionModeEpochAt ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError Word64)
readExistingProductionModeEpochAt session project =
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Left (ModeWrongMode "production" "absent")
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> Left (ModeMalformedRecord (recordKeyText key))
                Just (WireProduction, epoch)
                    | epoch == 0 -> Left (ModeMalformedRecord (recordKeyText key))
                    | otherwise -> Right epoch
                Just (other, _) -> Left (ModeWrongMode "production" (modeWireName other))

withExistingProductionBoundSnapshotAt ::
    ProtectedSession session ->
    LeaseLocation ->
    BrokerEpoch brokerGeneration ->
    ( forall (specDigest :: Type) (planDigest :: Type).
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      CanonicalPlanSnapshot ->
      InvocationDisposition ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withExistingProductionBoundSnapshotAt session location epoch use = do
    let leaseKey = leaseLocationLeaseKey location
        run = ProductionRunIdentity productionRunKey
    observedLease <- readProtectedRecord session leaseKey
    case observedLease of
        Left failure -> pure (Left (ModeStoreFailure failure))
        Right Nothing -> pure (Left (ModeLeaseMissing (runIdentityText run)))
        Right (Just leaseRecord) -> case decodeLease (protectedRecordBytes leaseRecord) of
            Nothing -> pure (Left (ModeMalformedRecord (recordKeyText leaseKey)))
            Just (LeaseBound recordedEpoch recordedSpec recordedPlan)
                | recordedEpoch == 0 ->
                    pure (Left (ModeMalformedRecord (recordKeyText leaseKey)))
                | Text.null recordedSpec || Text.null recordedPlan ->
                    pure (Left (ModeMalformedRecord (recordKeyText leaseKey)))
                | recordedEpoch /= brokerEpochWord epoch ->
                    pure (Left (ModeEpochMismatch recordedEpoch (brokerEpochWord epoch)))
                | otherwise -> do
                    observedSnapshot <-
                        readVerifiedPlanSnapshotAt
                            session
                            (leaseLocationSnapshotKey location)
                            run
                            (leaseLocationProjectName location)
                            (leaseLocationStoreIdentity location)
                    case observedSnapshot of
                        Left failure -> pure (Left failure)
                        Right (SomeVerifiedPlanSnapshot verified)
                            | recordedSpec /= planSnapshotSpecDigest verified ->
                                pure
                                    ( Left
                                        ( ModeSnapshotMismatch
                                            recordedSpec
                                            (planSnapshotSpecDigest verified)
                                        )
                                    )
                            | recordedPlan /= planSnapshotPlanDigest verified ->
                                pure
                                    ( Left
                                        ( ModeSnapshotMismatch
                                            recordedPlan
                                            (planSnapshotPlanDigest verified)
                                        )
                                    )
                            | otherwise ->
                                case
                                    admitPersistedCanonicalPlanSnapshotKernel
                                        (planSnapshotSpecDigest verified)
                                        (planSnapshotPlanDigest verified)
                                        (planSnapshotConfigDigest verified)
                                        (planSnapshotCanonicalBytes verified)
                                of
                                    Left _ ->
                                        pure
                                            ( Left
                                                ( ModeMalformedRecord
                                                    ( recordKeyText
                                                        (leaseLocationSnapshotKey location)
                                                    )
                                                )
                                            )
                                    Right canonical -> do
                                        disposition <-
                                            readInvocationDispositionAt
                                                session
                                                (leaseLocationInvocationKey location)
                                        case disposition of
                                            Left failure -> pure (Left failure)
                                            Right recorded ->
                                                use
                                                    ( BoundRunLease
                                                        run
                                                        location
                                                        (planSnapshotSpecDigest verified)
                                                        (planSnapshotPlanDigest verified)
                                                        epoch
                                                        (protectedRecordVersion leaseRecord)
                                                        ExistingBinding
                                                    )
                                                    verified
                                                    canonical
                                                    recorded
            Just other ->
                pure
                    ( Left
                        ( ModeLeaseNotBindable
                            (runIdentityText run)
                            (leaseStateName other)
                        )
                    )

-- Reverse-root transition kernels ----------------------------------------------

{- | Publish the sole fresh Pending intent from an exact existing-bound source,
then enter the same resume/redo engine used after a crash.
-}
withFreshExistingBoundReverseRootKernel ::
    forall projectId sourceBrokerGeneration sourceSpecDigest sourcePlanDigest
        sourcePlanId configId cfg frame verb result.
    ExistingBoundSnapshotAdmission ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    RootInvocationAuthority (Production projectId) sourceBrokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode sourceBrokerGeneration ->
    BoundRunLease
        (Production projectId) sourceSpecDigest sourcePlanDigest sourceBrokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) sourceSpecDigest sourcePlanDigest ->
    BoundPlanSnapshot
        (Production projectId) sourceSpecDigest sourcePlanDigest sourcePlanId ->
    PlanDigestBinding
        (Production projectId) sourceSpecDigest sourcePlanDigest sourcePlanId ->
    BoundInvocationRecovery
        (Production projectId)
        sourceSpecDigest
        sourcePlanDigest
        sourcePlanId
        sourceBrokerGeneration ->
    ProjectPlan
        (Production projectId) sourceSpecDigest sourcePlanId configId cfg ->
    ValidatedLifecycleContext
        (Production projectId) sourceSpecDigest sourcePlanId configId frame ->
    AcquisitionJournal (Production projectId) sourcePlanId sourceBrokerGeneration ->
    LifecycleCursor
        (Production projectId)
        sourcePlanId
        frame
        sourceBrokerGeneration
        VerbUp
        TeardownPhase ->
    ( forall targetBrokerGeneration targetSpecDigest targetPlanDigest targetPlanId.
      ProjectVerb verb ->
      RootInvocationAuthority (Production projectId) targetBrokerGeneration verb ->
      ProjectModeLease projectId ProductionMode targetBrokerGeneration ->
      BoundRunLease
        (Production projectId) targetSpecDigest targetPlanDigest targetBrokerGeneration ->
      VerifiedPlanSnapshot (Production projectId) targetSpecDigest targetPlanDigest ->
      BoundPlanSnapshot
        (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->
      PlanDigestBinding
        (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->
      RecoveredProductionLifecycleProfile
        projectId targetSpecDigest targetPlanDigest targetPlanId targetBrokerGeneration ->
      IO result
    ) ->
    IO (Either ModeError result)
{-# OPAQUE withFreshExistingBoundReverseRootKernel #-}
withFreshExistingBoundReverseRootKernel admission =
    case consumeExistingBoundSnapshotAdmissionKernel admission of
        () -> \store project verb sourceRoot sourceMode sourceBound sourceVerified
            sourceBoundSnapshot sourceBinding sourceRecovery sourcePlan lifecycleContext
            sourceJournal sourceCursor use ->
                let start encodePending =
                        withExistingBoundReverseRootTransition store project verb
                            (\session location intentKey ->
                                admitFresh session location intentKey encodePending
                            )
                            use

                    admitFresh ::
                        forall session.
                        ProtectedSession session ->
                        LeaseLocation ->
                        RecordKey ->
                        ( ( Text, Text, Text, Word64, Text, Text, Text, ByteString, Word64
                          , RecordKey, Word64, ByteString, RecordKey, Word64, ByteString
                          , Text, Word64, Word64, ByteString, Word64, ByteString
                          ) ->
                          ByteString
                        ) ->
                        IO (Either ModeError ProtectedRecord)
                    admitFresh session location intentKey encodePending =
                        case
                            validateRecoveredProductionLifecycleProfile
                                sourceRoot
                                sourceMode
                                sourceBound
                                sourceVerified
                                sourceBoundSnapshot
                                sourceBinding
                                sourceRecovery
                        of
                            Left failure -> pure (Left failure)
                            Right profile ->
                                case recoveredProductionProfileRevisionKind profile of
                                    NormalRevision ->
                                        admitRootContext profile
                                    other ->
                                        mismatchIO
                                            "source revision"
                                            "normal revision"
                                            (revisionName other)
                      where

                        admitRootContext profile =
                                case
                                    withValidatedRootLifecycleContext lifecycleContext $ \root contextStore
                                        _current rootFrame _validated ->
                                            ( Text.pack (canonicalProjectRootPath root)
                                            , protectedStoreIdentityText (protectedStoreIdentity contextStore)
                                            , projectFrameId rootFrame
                                            )
                                of
                                    Left failure ->
                                        mismatchIO
                                            "root lifecycle context"
                                            "valid root"
                                            (Text.pack (lifecycleContextErrorMessage failure))
                                    Right (contextRoot, contextStoreIdentity, rootFrameName) ->
                                        case
                                            validateRetained profile contextRoot contextStoreIdentity
                                                rootFrameName
                                        of
                                            Left failure -> pure (Left failure)
                                            Right () ->
                                                case validateBoundRunLeaseAcquisitionJournal sourceBound sourceJournal of
                                                    Left failure -> pure (Left (ModeSessionFailure failure))
                                                    Right () ->
                                                        case
                                                            withReverseRootSourceRecordsKernel
                                                                acquisitionJournalAdmissionKernel
                                                                sourceJournal
                                                                sourceCursor
                                                                (,,,,,)
                                                        of
                                                            Left failure -> pure (Left (ModeSessionFailure failure))
                                                            Right sourceRecords ->
                                                                validateLiveSource profile rootFrameName sourceRecords

                        validateRetained profile contextRoot contextStoreIdentity rootFrameName = do
                                let RecoveredProductionLifecycleProfile
                                        _ projectName storeIdentity _ specDigest planDigest configDigest
                                        canonicalBytes sourceEpoch _ = profile
                                    planCanonical = projectPlanCanonicalSnapshotKernel sourcePlan
                                requireText "installed project" (installedProjectName project) projectName
                                requireText "input store"
                                    (protectedStoreIdentityText (protectedStoreIdentity store)) storeIdentity
                                requireText "context store" storeIdentity contextStoreIdentity
                                requireText "context root"
                                    (Text.pack (stablePlanSnapshotRoot (renderSnapshot sourcePlan)))
                                    contextRoot
                                requireText "context frame" rootFrameName (lifecycleCursorFrame sourceCursor)
                                requireText "plan profile" "production"
                                    (projectPlanProfileNameKernel sourcePlan)
                                requireText "plan project" projectName
                                    (projectPlanProfileProjectNameKernel sourcePlan)
                                requireText "plan store" storeIdentity
                                    (projectPlanProfileStoreIdentityKernel sourcePlan)
                                requireWord "plan broker generation"
                                    (brokerEpochWord sourceEpoch)
                                    (projectPlanProfileEpochKernel sourcePlan)
                                requireText "plan specification" specDigest
                                    (canonicalPlanSnapshotSpecDigest planCanonical)
                                requireText "plan configuration" configDigest
                                    (canonicalPlanSnapshotConfigDigest planCanonical)
                                requireText "plan digest" planDigest
                                    (canonicalPlanSnapshotDigest planCanonical)
                                requireBytes "plan canonical bytes" canonicalBytes
                                    (canonicalPlanSnapshotBytes planCanonical)

                        validateLiveSource profile rootFrameName sourceRecords = do
                                let projectName = recoveredProductionProfileProjectName profile
                                    storeIdentity = recoveredProductionProfileStoreIdentity profile
                                    ( acquisitionKey
                                        , acquisitionVersion
                                        , acquisitionBytes
                                        , cursorKey
                                        , cursorVersion
                                        , cursorBytes
                                        ) = sourceRecords
                                cursorCurrent <- validateCurrentLifecycleCursor session sourceCursor
                                case cursorCurrent of
                                    Left failure -> pure (Left (ModeSessionFailure failure))
                                    Right () -> do
                                        acquisitionCurrent <- exactSourceRecord acquisitionKey
                                            acquisitionVersion acquisitionBytes
                                        cursorCurrentRecord <- exactSourceRecord cursorKey
                                            cursorVersion cursorBytes
                                        modeCurrent <- requiredRecord (modeKey project)
                                        leaseCurrent <- requiredRecord
                                            (Right (leaseLocationLeaseKey location))
                                        snapshotCurrent <- readVerifiedPlanSnapshotAt session
                                            (leaseLocationSnapshotKey location)
                                            (ProductionRunIdentity productionRunKey)
                                            projectName
                                            storeIdentity
                                        dispositionCurrent <- readInvocationDispositionAt session
                                            (leaseLocationInvocationKey location)
                                        revisionCurrent <- readOpenRevisionKindForKey
                                            session project productionRunKey
                                        case validateLiveRows
                                            acquisitionCurrent
                                            cursorCurrentRecord
                                            modeCurrent
                                            leaseCurrent
                                            snapshotCurrent
                                            dispositionCurrent
                                            revisionCurrent
                                            profile of
                                            Left failure -> pure (Left failure)
                                            Right (modeRecord, leaseRecord) -> do
                                                operator <- verifyOsPrincipal session
                                                case operator of
                                                    Left failure -> pure (Left (ModeAuthorityFailure failure))
                                                    Right authorized ->
                                                        withExistingVerifiedRoot
                                                            ProductionRootScope
                                                            session
                                                            project
                                                            authorized
                                                            (projectModeLeaseEpoch sourceMode)
                                                            ProjectUp
                                                            $ \_verifiedRoot -> do
                                                                closed <- verifyAllSessionsClosed session
                                                                    (recoveredProductionProfilePlanDigest profile)
                                                                case closed of
                                                                    Left failure ->
                                                                        pure (Left (ModeSessionFailure failure))
                                                                    Right proof
                                                                        | allSessionsClosedPlanDigest proof
                                                                            /= recoveredProductionProfilePlanDigest profile ->
                                                                            mismatchIO
                                                                                "closed-session plan"
                                                                                (recoveredProductionProfilePlanDigest profile)
                                                                                (allSessionsClosedPlanDigest proof)
                                                                        | otherwise ->
                                                                            publishPending profile rootFrameName
                                                                                sourceRecords proof modeRecord leaseRecord

                        validateLiveRows acquisitionCurrent cursorCurrent modeCurrent leaseCurrent
                            snapshotCurrent dispositionCurrent revisionCurrent profile = do
                                let RecoveredProductionLifecycleProfile
                                        _ _ _ revision specDigest planDigest configDigest canonicalBytes
                                        sourceEpoch _ = profile
                                    sourceEpochWord = brokerEpochWord sourceEpoch
                                _ <- acquisitionCurrent
                                _ <- cursorCurrent
                                modeRecord <- modeCurrent
                                leaseRecord <- leaseCurrent
                                requireWord "mode broker generation" sourceEpochWord
                                    =<< modeEpoch modeRecord
                                requireBytes "mode bytes"
                                    (encodeMode WireProduction sourceEpochWord)
                                    (protectedRecordBytes modeRecord)
                                requireBelowMax "mode record version"
                                    (recordVersionWord (protectedRecordVersion modeRecord))
                                requireWord "lease record version"
                                    (recordVersionWord (boundRunLeaseRecordVersion sourceBound))
                                    (recordVersionWord (protectedRecordVersion leaseRecord))
                                requireBytes "lease bytes"
                                    (encodeLease (LeaseBound sourceEpochWord specDigest planDigest))
                                    (protectedRecordBytes leaseRecord)
                                requireBelowMax "lease record version"
                                    (recordVersionWord (protectedRecordVersion leaseRecord))
                                case snapshotCurrent of
                                    Left failure -> Left failure
                                    Right (SomeVerifiedPlanSnapshot observed) -> do
                                        requireWord "snapshot revision" revision
                                            (planSnapshotRevision observed)
                                        requireText "snapshot specification" specDigest
                                            (planSnapshotSpecDigest observed)
                                        requireText "snapshot plan" planDigest
                                            (planSnapshotPlanDigest observed)
                                        requireText "snapshot configuration" configDigest
                                            (maybe "absent" id (planSnapshotConfigDigest observed))
                                        requireBytes "snapshot canonical bytes" canonicalBytes
                                            (maybe ByteString.empty id (planSnapshotCanonicalBytes observed))
                                case dispositionCurrent of
                                    Left failure -> Left failure
                                    Right InvocationOpen -> Right ()
                                    Right other -> mismatch "source invocation" "open" (dispositionName other)
                                case revisionCurrent of
                                    Left failure -> Left failure
                                    Right NormalRevision -> Right ()
                                    Right other -> mismatch "source revision" "normal revision" (revisionName other)
                                Right (modeRecord, leaseRecord)
                          where
                            modeEpoch record = case decodeMode (protectedRecordBytes record) of
                                Just (WireProduction, epoch) -> Right epoch
                                Just (other, _) ->
                                    Left (ModeWrongMode "production" (modeWireName other))
                                Nothing -> Left (ModeMalformedRecord "reverse-root source mode")

                        publishPending profile rootFrameName sourceRecords proof modeRecord leaseRecord = do
                                let RecoveredProductionLifecycleProfile
                                        _ projectName storeIdentity revision specDigest planDigest configDigest
                                        canonicalBytes sourceEpoch _ = profile
                                    ( acquisitionKey
                                        , acquisitionVersion
                                        , acquisitionBytes
                                        , cursorKey
                                        , cursorVersion
                                        , cursorBytes
                                        ) = sourceRecords
                                    common =
                                        ( projectName
                                        , storeIdentity
                                        , runKeyText productionRunKey
                                        , revision
                                        , specDigest
                                        , configDigest
                                        , planDigest
                                        , canonicalBytes
                                        , brokerEpochWord sourceEpoch
                                        , acquisitionKey
                                        , recordVersionWord acquisitionVersion
                                        , acquisitionBytes
                                        , cursorKey
                                        , recordVersionWord cursorVersion
                                        , cursorBytes
                                        , rootFrameName
                                        , fromIntegral (allSessionsClosedCount proof)
                                        , recordVersionWord (protectedRecordVersion modeRecord)
                                        , protectedRecordBytes modeRecord
                                        , recordVersionWord (protectedRecordVersion leaseRecord)
                                        , protectedRecordBytes leaseRecord
                                        )
                                    pendingBytes = encodePending common
                                written <- compareAndSwapProtectedRecord
                                    session intentKey ExpectAbsent pendingBytes
                                case written of
                                    Left failure -> pure (Left (ModeStoreFailure failure))
                                    Right version
                                        | recordVersionWord version /= 1 ->
                                            mismatchIO "pending intent version" "1"
                                                (showWord (recordVersionWord version))
                                        | otherwise -> do
                                            observed <- readProtectedRecord session intentKey
                                            pure $ case observed of
                                                Left failure -> Left (ModeStoreFailure failure)
                                                Right (Just record)
                                                    | recordVersionWord (protectedRecordVersion record) == 1
                                                    , protectedRecordBytes record == pendingBytes -> Right record
                                                Right _ ->
                                                    mismatch
                                                        "pending intent readback"
                                                        "exact version/bytes"
                                                        "different"

                        exactSourceRecord key version bytes = do
                            observed <- readProtectedRecord session key
                            pure $ case observed of
                                Left failure -> Left (ModeStoreFailure failure)
                                Right (Just record)
                                    | protectedRecordVersion record == version
                                    , protectedRecordBytes record == bytes -> Right ()
                                Right _ ->
                                    mismatch "source record" "exact version/bytes" "different"

                        requiredRecord keyResult = withRecordKey keyResult $ \key -> do
                            observed <- readProtectedRecord session key
                            pure $ case observed of
                                Left failure -> Left (ModeStoreFailure failure)
                                Right Nothing -> mismatch "source record" "present" "absent"
                                Right (Just record) -> Right record

                        requireText subject expected observed
                            | expected == observed = Right ()
                            | otherwise = mismatch subject expected observed
                        requireWord subject expected observed =
                            requireText subject (showWord expected) (showWord observed)
                        requireBytes subject expected observed
                            | expected == observed = Right ()
                            | otherwise = mismatch subject "exact bytes" "different bytes"
                        requireBelowMax subject observed
                            | observed < maxBound = Right ()
                            | otherwise = mismatch subject "below maxBound" "maxBound"
                        mismatch subject expected observed =
                            Left (ModeEvidenceMismatch subject expected observed)
                        mismatchIO subject expected observed =
                            pure (mismatch subject expected observed)
                        dispositionName InvocationOpen = "open"
                        dispositionName (InvocationAcknowledged _) = "acknowledged"
                        dispositionName (InvocationClosing _) = "closing"
                        revisionName NormalRevision = "normal revision"
                        revisionName (IncompleteMigration _) = "incomplete migration"
                        revisionName (CompletedMigration _) = "completed migration"

                 in case verb of
                        ProjectUp -> pure (Left (ModeWrongRecoveryScope "reverse root" "up"))
                        ProjectDown ->
                            start (encodeReverseRootIntent . ReverseRootDownPending)
                        ProjectDestroy ->
                            start (encodeReverseRootIntent . ReverseRootDestroyPending)

{- | Resume only the exact same-verb Pending or Committed intent.  There is no
absent branch: selection belongs to the later Snapshot facade.
-}
withResumedExistingBoundReverseRootKernel ::
    ExistingBoundSnapshotAdmission ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    ( forall targetBrokerGeneration targetSpecDigest targetPlanDigest targetPlanId.
      ProjectVerb verb ->
      RootInvocationAuthority (Production projectId) targetBrokerGeneration verb ->
      ProjectModeLease projectId ProductionMode targetBrokerGeneration ->
      BoundRunLease
        (Production projectId) targetSpecDigest targetPlanDigest targetBrokerGeneration ->
      VerifiedPlanSnapshot (Production projectId) targetSpecDigest targetPlanDigest ->
      BoundPlanSnapshot
        (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->
      PlanDigestBinding
        (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->
      RecoveredProductionLifecycleProfile
        projectId targetSpecDigest targetPlanDigest targetPlanId targetBrokerGeneration ->
      IO result
    ) ->
    IO (Either ModeError result)
{-# OPAQUE withResumedExistingBoundReverseRootKernel #-}
withResumedExistingBoundReverseRootKernel admission =
    case consumeExistingBoundSnapshotAdmissionKernel admission of
        () -> \store project verb use ->
            withExistingBoundReverseRootTransition store project verb
                (\_ _ _ -> pure (Left ModeReverseRootInProgress)) use

withExistingBoundReverseRootTransition ::
    forall projectId verb result.
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    (forall session. ProtectedSession session -> LeaseLocation -> RecordKey -> IO (Either ModeError ProtectedRecord)) ->
    ( forall targetBrokerGeneration targetSpecDigest targetPlanDigest targetPlanId.
      ProjectVerb verb ->
      RootInvocationAuthority (Production projectId) targetBrokerGeneration verb ->
      ProjectModeLease projectId ProductionMode targetBrokerGeneration ->
      BoundRunLease
        (Production projectId) targetSpecDigest targetPlanDigest targetBrokerGeneration ->
      VerifiedPlanSnapshot (Production projectId) targetSpecDigest targetPlanDigest ->
      BoundPlanSnapshot
        (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->
      PlanDigestBinding
        (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->
      RecoveredProductionLifecycleProfile
        projectId targetSpecDigest targetPlanDigest targetPlanId targetBrokerGeneration ->
      IO result
    ) ->
    IO (Either ModeError result)
withExistingBoundReverseRootTransition store project verb admit use = case verb of
    ProjectUp -> pure (Left (ModeWrongRecoveryScope "reverse root" "up"))
    ProjectDown -> transition
    ProjectDestroy -> transition
  where
    transition = case (makeLeaseLocation store project productionRunKey, reverseRootIntentKey project) of
        (Left failure, _) -> pure (Left failure)
        (_, Left failure) -> pure (Left failure)
        (Right location, Right intentKey) -> do
            prepared <- runProtected store $ \session -> do
                observed <- readProtectedRecord session intentKey
                case observed of
                    Left failure -> pure (Left (ModeStoreFailure failure))
                    Right current -> do
                        record <- maybe (admit session location intentKey) (pure . Right) current
                        case record of
                            Left failure -> pure (Left failure)
                            Right retained -> case decodeReverseRootIntent verb (protectedRecordBytes retained) of
                                Just intent -> drive session location intentKey retained intent
                                Nothing -> case oppositeIntent (protectedRecordBytes retained) of
                                    True -> pure (Left ModeReverseRootInProgress)
                                    False -> pure (Left (ModeMalformedRecord (recordKeyText intentKey)))
            case prepared of
                Left failure -> pure (Left failure)
                Right deliver -> Right <$> deliver

    oppositeIntent bytes = case verb of
        ProjectDown -> maybe False (const True) (decodeReverseRootIntent ProjectDestroy bytes)
        ProjectDestroy -> maybe False (const True) (decodeReverseRootIntent ProjectDown bytes)
        ProjectUp -> False

    drive ::
        forall session sourceBrokerGeneration.
        ProtectedSession session ->
        LeaseLocation ->
        RecordKey ->
        ProtectedRecord ->
        ReverseRootIntent projectId sourceBrokerGeneration verb ->
        IO (Either ModeError (IO result))
    drive session location intentKey intentRecord intent = case intent of
        ReverseRootDownPending common ->
            commitPending common $ \target modeVersion modeBytes leaseVersion leaseBytes ->
                encodeReverseRootIntent
                    (ReverseRootDownCommitted common target modeVersion modeBytes leaseVersion leaseBytes)
        ReverseRootDestroyPending common ->
            commitPending common $ \target modeVersion modeBytes leaseVersion leaseBytes ->
                encodeReverseRootIntent
                    (ReverseRootDestroyCommitted common target modeVersion modeBytes leaseVersion leaseBytes)
        ReverseRootDownCommitted common target modeVersion modeBytes leaseVersion leaseBytes ->
            finishCommitted common target modeVersion modeBytes leaseVersion leaseBytes intentRecord
        ReverseRootDestroyCommitted common target modeVersion modeBytes leaseVersion leaseBytes ->
            finishCommitted common target modeVersion modeBytes leaseVersion leaseBytes intentRecord
      where
        commitPending common encodeCommitted
            | recordVersionWord (protectedRecordVersion intentRecord) /= 1 =
                mismatchIO "pending intent version" "1"
                    (showWord (recordVersionWord (protectedRecordVersion intentRecord)))
            | oldModeVersion == maxBound =
                mismatchIO "mode record version" "below maxBound" "maxBound"
            | oldLeaseVersion == maxBound =
                mismatchIO "lease record version" "below maxBound" "maxBound"
            | otherwise = validateCommon session location common $ \_ _ -> do
                oldMode <- withRecordKey (modeKey project) $ \key ->
                    exactWordRecord session key oldModeVersion oldModeBytes
                oldLease <- exactWordRecord session (leaseLocationLeaseKey location)
                    oldLeaseVersion oldLeaseBytes
                case (oldMode, oldLease) of
                    (Right _, Right _) -> do
                        allocated <- withFreshBrokerEpochKernel session project $ \epoch ->
                            pure (Right (commitAllocated epoch))
                        case allocated of
                            Left failure -> pure (Left (ModeAuthorityFailure failure))
                            Right continue -> continue
                    (Left failure, _) -> pure (Left failure)
                    (_, Left failure) -> pure (Left failure)
          where
            (_, _, _, _, spec, _, plan, _, source, _, _, _, _, _, _, _, _,
                oldModeVersion, oldModeBytes, oldLeaseVersion, oldLeaseBytes) = common

            commitAllocated ::
                forall targetBrokerGeneration.
                BrokerEpoch targetBrokerGeneration ->
                IO (Either ModeError (IO result))
            commitAllocated epoch
                | target <= source =
                    mismatchIO "reverse-root broker successor" "greater than source" (showWord target)
                | otherwise = do
                    written <- compareAndSwapProtectedRecord session intentKey
                        (ExpectVersion (protectedRecordVersion intentRecord)) bytes
                    case written of
                        Left failure -> pure (Left (ModeStoreFailure failure))
                        Right version
                            | recordVersionWord version == 2 -> do
                                readback <- exactWordRecord session intentKey 2 bytes
                                case readback of
                                    Left failure -> pure (Left failure)
                                    Right committedRecord ->
                                        finishCommitted common target nextModeVersion nextModeBytes
                                            nextLeaseVersion nextLeaseBytes committedRecord
                            | otherwise ->
                                mismatchIO "committed intent version" "2"
                                    (showWord (recordVersionWord version))
              where
                target = brokerEpochWord epoch
                nextModeVersion = oldModeVersion + 1
                nextLeaseVersion = oldLeaseVersion + 1
                nextModeBytes = encodeMode WireProduction target
                nextLeaseBytes = encodeLease (LeaseBound target spec plan)
                bytes = encodeCommitted target nextModeVersion nextModeBytes
                    nextLeaseVersion nextLeaseBytes

        finishCommitted common target nextModeVersion nextModeBytes
            nextLeaseVersion nextLeaseBytes retainedIntent
                | recordVersionWord (protectedRecordVersion retainedIntent) /= 2 =
                    mismatchIO "committed intent version" "2"
                        (showWord (recordVersionWord (protectedRecordVersion retainedIntent)))
                | oldModeVersion == maxBound || nextModeVersion /= oldModeVersion + 1 =
                    mismatchIO "committed mode successor" "old version + 1" (showWord nextModeVersion)
                | oldLeaseVersion == maxBound || nextLeaseVersion /= oldLeaseVersion + 1 =
                    mismatchIO "committed lease successor" "old version + 1" (showWord nextLeaseVersion)
                | nextModeBytes /= encodeMode WireProduction target =
                    mismatchIO "committed mode bytes" "derived target mode" "different"
                | nextLeaseBytes /= encodeLease (LeaseBound target spec plan) =
                    mismatchIO "committed lease bytes" "derived target lease" "different"
                | target <= source =
                    mismatchIO "committed broker generation" "greater than source" (showWord target)
                | otherwise = validateCommon session location common $ \verified canonical -> do
                    reified <- withReifiedAllocatedBrokerEpochKernel session project target $ \epoch ->
                        pure (Right (converge verified canonical epoch))
                    case reified of
                        Left failure -> pure (Left (ModeAuthorityFailure failure))
                        Right continue -> continue
          where
            (_, _, _, _, spec, config, plan, canonicalBytes, source, _, _, _, _, _, _, _, _,
                oldModeVersion, oldModeBytes, oldLeaseVersion, oldLeaseBytes) = common

            converge ::
                forall targetSpecDigest targetPlanDigest targetBrokerGeneration.
                VerifiedPlanSnapshot
                    (Production projectId) targetSpecDigest targetPlanDigest ->
                CanonicalPlanSnapshot ->
                BrokerEpoch targetBrokerGeneration ->
                IO (Either ModeError (IO result))
            converge verified canonical epoch = do
                suffix <- readSuffix session location
                    oldModeVersion oldModeBytes oldLeaseVersion oldLeaseBytes
                    nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes
                case suffix of
                    Left failure -> pure (Left failure)
                    Right (False, False, modeRecord, leaseRecord) -> do
                        modeWritten <- writeSuffix session (modeKey project) modeRecord
                            nextModeVersion nextModeBytes
                        case modeWritten of
                            Left failure -> pure (Left failure)
                            Right () -> do
                                leaseWritten <- writeSuffix session
                                    (Right (leaseLocationLeaseKey location)) leaseRecord
                                    nextLeaseVersion nextLeaseBytes
                                case leaseWritten of
                                    Left failure -> pure (Left failure)
                                    Right () -> deliver verified canonical epoch
                    Right (True, False, _, leaseRecord) -> do
                        leaseWritten <- writeSuffix session
                            (Right (leaseLocationLeaseKey location)) leaseRecord
                            nextLeaseVersion nextLeaseBytes
                        case leaseWritten of
                            Left failure -> pure (Left failure)
                            Right () -> deliver verified canonical epoch
                    Right (True, True, _, _) -> deliver verified canonical epoch
                    Right (False, True, _, _) ->
                        mismatchIO "reverse-root suffix" "mode before lease" "old mode/new lease"

            deliver ::
                forall targetSpecDigest targetPlanDigest targetBrokerGeneration.
                VerifiedPlanSnapshot
                    (Production projectId) targetSpecDigest targetPlanDigest ->
                CanonicalPlanSnapshot ->
                BrokerEpoch targetBrokerGeneration ->
                IO (Either ModeError (IO result))
            deliver verified canonical epoch = do
                intentRead <- exactWordRecord session intentKey 2
                    (protectedRecordBytes retainedIntent)
                modeRead <- withRecordKey (modeKey project) $ \key ->
                    exactWordRecord session key nextModeVersion nextModeBytes
                leaseRead <- exactWordRecord session (leaseLocationLeaseKey location)
                    nextLeaseVersion nextLeaseBytes
                case (intentRead, modeRead, leaseRead) of
                    (Right _, Right _, Right leaseRecord) -> do
                        operator <- verifyOsPrincipal session
                        case operator of
                            Left failure -> pure (Left (ModeAuthorityFailure failure))
                            Right authorized ->
                                withExistingVerifiedRoot ProductionRootScope session project
                                    authorized epoch verb $ \root ->
                                        pure
                                            ( Right
                                                ( withPersistedBoundPlanSnapshotKernel canonical $ \bound binding ->
                                                    use verb root
                                                        (ProjectModeLease WireProduction projectName storeIdentity epoch)
                                                        (BoundRunLease
                                                            (ProductionRunIdentity productionRunKey)
                                                            location spec plan epoch
                                                            (protectedRecordVersion leaseRecord) ExistingBinding)
                                                        verified bound binding
                                                        (RecoveredProductionLifecycleProfile
                                                            (ProductionRunIdentity productionRunKey)
                                                            projectName storeIdentity revision spec plan
                                                            config canonicalBytes epoch NormalRevision)
                                                )
                                            )
                    (Left failure, _, _) -> pure (Left failure)
                    (_, Left failure, _) -> pure (Left failure)
                    (_, _, Left failure) -> pure (Left failure)
              where
                (projectName, storeIdentity, _, revision, _, _, _, _, _, _, _, _, _, _, _, _, _,
                    _, _, _, _) = common

    validateCommon ::
        forall session answer.
        ProtectedSession session ->
        LeaseLocation ->
        ( Text, Text, Text, Word64, Text, Text, Text, ByteString, Word64
        , RecordKey, Word64, ByteString, RecordKey, Word64, ByteString, Text, Word64
        , Word64, ByteString, Word64, ByteString
        ) ->
        ( forall sourceSpecDigest sourcePlanDigest.
          VerifiedPlanSnapshot
            (Production projectId) sourceSpecDigest sourcePlanDigest ->
          CanonicalPlanSnapshot ->
          IO (Either ModeError answer)
        ) ->
        IO (Either ModeError answer)
    validateCommon session location common useCommon = do
        disposition <- readInvocationDispositionAt session (leaseLocationInvocationKey location)
        revisionKind <- readOpenRevisionKindForKey session project productionRunKey
        sourceAcquisition <- exactWordRecord session acquisitionKey acquisitionVersion acquisitionBytes
        sourceCursor <- exactWordRecord session cursorKey cursorVersion cursorBytes
        closed <- verifyAllSessionsClosed session plan
        snapshot <- readVerifiedPlanSnapshotAt session (leaseLocationSnapshotKey location)
            (ProductionRunIdentity productionRunKey) projectName storeIdentity
        case (disposition, revisionKind, sourceAcquisition, sourceCursor, closed, snapshot) of
            (Right InvocationOpen, Right NormalRevision, Right _, Right _, Right sessionProof,
                Right (SomeVerifiedPlanSnapshot verified)) -> case do
                    requireText "intent project" (installedProjectName project) projectName
                    requireText "intent store"
                        (protectedStoreIdentityText (protectedStoreIdentity store)) storeIdentity
                    requireText "intent run" (runKeyText productionRunKey) run
                    requireWord "snapshot revision" revision (planSnapshotRevision verified)
                    requireText "snapshot specification" spec (planSnapshotSpecDigest verified)
                    requireText "snapshot plan" plan (planSnapshotPlanDigest verified)
                    requireText "snapshot configuration" config
                        (maybe "absent" id (planSnapshotConfigDigest verified))
                    requireBytes "snapshot canonical bytes" canonicalBytes
                        (maybe ByteString.empty id (planSnapshotCanonicalBytes verified))
                    requireText "closed-session plan" plan (allSessionsClosedPlanDigest sessionProof)
                    requireWord "closed-session count" sessions
                        (fromIntegral (allSessionsClosedCount sessionProof))
                    either (const (mismatch "canonical snapshot" "valid" "malformed")) Right
                        (admitPersistedCanonicalPlanSnapshotKernel
                            spec plan (Just config) (Just canonicalBytes))
                of
                    Left failure -> pure (Left failure)
                    Right canonical -> useCommon verified canonical
            (Left failure, _, _, _, _, _) -> pure (Left failure)
            (_, Left failure, _, _, _, _) -> pure (Left failure)
            (_, _, Left failure, _, _, _) -> pure (Left failure)
            (_, _, _, Left failure, _, _) -> pure (Left failure)
            (_, _, _, _, Left failure, _) -> pure (Left (ModeSessionFailure failure))
            (_, _, _, _, _, Left failure) -> pure (Left failure)
            (Right InvocationOpen, Right other, _, _, _, _) ->
                mismatchIO "source revision" "normal revision" (revisionName other)
            (Right other, _, _, _, _, _) ->
                mismatchIO "source invocation" "open" (dispositionName other)
      where
        (projectName, storeIdentity, run, revision, spec, config, plan, canonicalBytes, _,
            acquisitionKey, acquisitionVersion, acquisitionBytes,
            cursorKey, cursorVersion, cursorBytes, _, sessions, _, _, _, _) = common

    readSuffix ::
        forall session.
        ProtectedSession session ->
        LeaseLocation ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        Word64 ->
        ByteString ->
        IO (Either ModeError (Bool, Bool, ProtectedRecord, ProtectedRecord))
    readSuffix session location oldModeVersion oldModeBytes oldLeaseVersion oldLeaseBytes
        nextModeVersion nextModeBytes nextLeaseVersion nextLeaseBytes = do
        modeRecord <- requiredRecord session (modeKey project)
        leaseRecord <- requiredRecord session (Right (leaseLocationLeaseKey location))
        pure $ do
            observedMode <- modeRecord
            observedLease <- leaseRecord
            modeNew <- classify "mode" observedMode oldModeVersion oldModeBytes nextModeVersion nextModeBytes
            leaseNew <- classify "lease" observedLease oldLeaseVersion oldLeaseBytes nextLeaseVersion nextLeaseBytes
            Right (modeNew, leaseNew, observedMode, observedLease)
      where
        classify subject record oldVersion oldBytes newVersion newBytes
            | version == oldVersion && bytes == oldBytes = Right False
            | version == newVersion && bytes == newBytes = Right True
            | otherwise = mismatch ("reverse-root " <> subject) "exact old or new row" "different"
          where
            version = recordVersionWord (protectedRecordVersion record)
            bytes = protectedRecordBytes record

    writeSuffix session keyResult oldRecord expectedVersion bytes = withRecordKey keyResult $ \key -> do
        written <- compareAndSwapProtectedRecord session key
            (ExpectVersion (protectedRecordVersion oldRecord)) bytes
        pure $ case written of
            Left failure -> Left (ModeStoreFailure failure)
            Right version
                | recordVersionWord version == expectedVersion -> Right ()
                | otherwise -> Left (ModeEvidenceMismatch "suffix version" (showWord expectedVersion) (showWord (recordVersionWord version)))

    exactWordRecord session key expectedVersion expectedBytes = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right (Just record)
                | recordVersionWord (protectedRecordVersion record) == expectedVersion
                , protectedRecordBytes record == expectedBytes -> Right record
            Right _ -> Left (ModeEvidenceMismatch "durable record" "exact version/bytes" (recordKeyText key))

    requiredRecord session keyResult = withRecordKey keyResult $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Left (ModeEvidenceMismatch "durable record" "present" (recordKeyText key))
            Right (Just record) -> Right record

    requireText subject expected observed
        | expected == observed = Right ()
        | otherwise = mismatch subject expected observed
    requireWord subject expected observed = requireText subject (showWord expected) (showWord observed)
    requireBytes subject expected observed
        | expected == observed = Right ()
        | otherwise = mismatch subject "exact bytes" "different bytes"
    mismatch subject expected observed = Left (ModeEvidenceMismatch subject expected observed)
    mismatchIO subject expected observed = pure (mismatch subject expected observed)
    dispositionName InvocationOpen = "open"
    dispositionName (InvocationAcknowledged _) = "acknowledged"
    dispositionName (InvocationClosing _) = "closing"
    revisionName NormalRevision = "normal revision"
    revisionName (IncompleteMigration _) = "incomplete migration"
    revisionName (CompletedMigration _) = "completed migration"

-- End reverse-root transition kernels ------------------------------------------

{- | The Harness eliminator. It distinguishes an exact persisted Closing epoch
from Open before the Open branch selects its revision recovery.
-}
data HarnessBoundRecovery projectId runId
    = HarnessPersistedClosing Word64
    | HarnessOpenRevisionRecovery (OpenRevisionRecovery (Harness projectId runId))
    deriving (Show)

type role HarnessBoundRecovery nominal nominal

eliminateHarnessBoundRecovery ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ObservedBoundInvocationRecovery (Harness projectId runId) ->
    IO (Either ModeError (HarnessBoundRecovery projectId runId))
eliminateHarnessBoundRecovery session project (ObservedBoundInvocationRecovery run spec plan disposition) =
    case disposition of
        InvocationClosing epoch -> pure (Right (HarnessPersistedClosing epoch))
        InvocationAcknowledged key ->
            pure
                ( Left
                    ( ModeWrongRecoveryScope
                        "harness"
                        ("production terminal acknowledgment " <> invocationCloseKeyText key)
                    )
                )
        InvocationOpen -> do
            kind <- readOpenRevisionKindForKey session project (runIdentityKey run)
            pure (fmap (HarnessOpenRevisionRecovery . OpenRevisionRecovery run spec plan) kind)

{- | Classify an abandoned __bound__ Harness lease so the sweep can act on it.

The ordinary fresh lease API cannot produce this package-private scope-only
durable observation for a run that no longer has an 'UnboundRunLease'. Without
the sweep route, a bound lease could only be /reported/: the
sweep named the run and refused every variant, and the sole way forward was to
delete the run's protected records by hand — exactly the hand cleanup the
recoverable reservation exists to eliminate, moved from a lock directory into
the store.

The only route in is a 'VerifiedIncompleteRunLease' the sweep itself minted, and
only its 'IncompleteBound' kind, so a caller cannot claim recovery authority for
a run that never bound a plan. The digests come from the lease record rather
than the caller, so a substituted snapshot cannot be presented as this run's.
-}
classifyAbandonedBoundRun ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    VerifiedIncompleteRunLease projectId ->
    ( forall runId.
      RunId runId ->
      HarnessBoundRecovery projectId runId ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
classifyAbandonedBoundRun session project (VerifiedIncompleteRunLease runKey kind) use =
    withReifiedRunId runKey $ \run ->
        classifyHarnessBoundRunFor session project run kind (use run)

classifyHarnessBoundRunFor ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    IncompleteLeaseKind ->
    (HarnessBoundRecovery projectId runId -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
classifyHarnessBoundRunFor session project run kind use =
  withOrdinaryProjectAdmission session project $
    case kind of
        IncompleteUnbound ->
            pure (Left (ModeLeaseNotBindable (runIdText run) "unbound"))
        IncompleteBound spec plan -> do
            disposition <-
                readInvocationDispositionForKey
                    session
                    project
                    (runIdentityKey (HarnessRunIdentity run))
            case disposition of
                Left failure -> pure (Left failure)
                Right recorded -> do
                    eliminated <-
                        eliminateHarnessBoundRecovery
                        session
                        project
                        (ObservedBoundInvocationRecovery (HarnessRunIdentity run) spec plan recorded)
                    case eliminated of
                        Left failure -> pure (Left failure)
                        Right recovery -> use recovery

{- | Record an ordinary Production invocation's terminal acknowledgment under a
stable, idempotent close key, /before/ the lease close it authorizes. A crash
between the two therefore leaves the acknowledgment visible, which is exactly
what lets bound recovery resume the same close instead of reopening work.
-}
recordProductionInvocationAcknowledgment ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    InvocationCloseKey ->
    IO (Either ModeError ())
recordProductionInvocationAcknowledgment session project bound key =
    writeInvocationDispositionForKey
        session
        project
        (runIdentityKey (boundRunLeaseIdentity bound))
        (InvocationAcknowledged key)

{- | Record a Harness run's Closing epoch after settled destroy and immediately
before terminal finalization, so a persisted Closing run resumes only its own
close journal.
-}
recordHarnessClosingEpoch ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    Word64 ->
    IO (Either ModeError ())
recordHarnessClosingEpoch session project run epoch
    | epoch == 0 =
        pure (Left (ModeInvalidIdentity "a closing epoch must be positive"))
    | otherwise =
        writeInvocationDispositionForKey session project (runIdentityKey (HarnessRunIdentity run)) (InvocationClosing epoch)

{- | Record which side of the migration activation barrier a revision is on, so
the Open branch's classification is a durable observation rather than an
inference from the current config.
-}
recordOpenRevisionMigration ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    OpenRevisionKind ->
    IO (Either ModeError ())
recordOpenRevisionMigration session project run =
    recordOpenRevisionMigrationForKey session project (runIdentityKey (HarnessRunIdentity run))

recordOpenRevisionMigrationForKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    OpenRevisionKind ->
    IO (Either ModeError ())
recordOpenRevisionMigrationForKey session project run kind =
  withOrdinaryProjectAdmission session project $
    withRecordKey (migrationKeyForRunKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right existing -> do
                let expectation =
                        maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) existing
                written <-
                    compareAndSwapProtectedRecord
                        session
                        key
                        expectation
                        (encodeRevisionKind kind)
                pure (either (Left . ModeStoreFailure) (const (Right ())) written)

readInvocationDispositionForKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    IO (Either ModeError InvocationDisposition)
readInvocationDispositionForKey session project run =
    withRecordKey (invocationKeyForRunKey project run) (readInvocationDispositionAt session)

readInvocationDispositionAt ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ModeError InvocationDisposition)
readInvocationDispositionAt session key = do
    observed <- readProtectedRecord session key
    pure $ case observed of
        Left failure -> Left (ModeStoreFailure failure)
        Right Nothing -> Right InvocationOpen
        Right (Just record) ->
            maybe
                (Left (ModeMalformedRecord (recordKeyText key)))
                Right
                (decodeDisposition (protectedRecordBytes record))

writeInvocationDispositionForKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    InvocationDisposition ->
    IO (Either ModeError ())
writeInvocationDispositionForKey session project run disposition =
  withOrdinaryProjectAdmission session project $
    withRecordKey (invocationKeyForRunKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right existing -> do
                let expectation =
                        maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) existing
                written <-
                    compareAndSwapProtectedRecord
                        session
                        key
                        expectation
                        (encodeDisposition disposition)
                pure (either (Left . ModeStoreFailure) (const (Right ())) written)

{- | Read the recorded migration side of the activation barrier for a run.

The classification itself is internal — it is reached through the two bound
eliminators — but the recorded kind is an ordinary durable observation, and the
migration protocol's own callers need to be able to assert on it.
-}
readRecordedOpenRevisionKind ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    IO (Either ModeError OpenRevisionKind)
readRecordedOpenRevisionKind session project bound =
    withOrdinaryProjectAdmission session project $
        readOpenRevisionKindForKey
            session
            project
            (runIdentityKey (boundRunLeaseIdentity bound))

readOpenRevisionKindForKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    IO (Either ModeError OpenRevisionKind)
readOpenRevisionKindForKey session project run =
    withRecordKey (migrationKeyForRunKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Right NormalRevision
            Right (Just record) ->
                maybe
                    (Left (ModeMalformedRecord (recordKeyText key)))
                    Right
                    (decodeRevisionKind (protectedRecordBytes record))

-- Lifecycle profiles ----------------------------------------------------------------

{- | The scope-indexed lifecycle profile plan construction consumes. Only the
openers below mint one, and only from the exact active mode plus a still-unbound
lease; a caller cannot choose a scope and then look for evidence.
-}
type role LifecycleProfile nominal
data LifecycleProfile scope
    = LifecycleProfile ModeWire Text Text Word64

instance Show (LifecycleProfile scope) where
    show (LifecycleProfile mode _project _store epoch) =
        "LifecycleProfile " <> Text.unpack (modeWireName mode) <> " " <> show epoch

lifecycleProfileName :: LifecycleProfile scope -> Text
lifecycleProfileName (LifecycleProfile mode _ _ _) = modeWireName mode

lifecycleProfileEpoch :: LifecycleProfile scope -> Word64
lifecycleProfileEpoch (LifecycleProfile _ _ _ epoch) = epoch

-- | The installed project whose protected profile slot was consumed.
lifecycleProfileProjectName :: LifecycleProfile scope -> Text
lifecycleProfileProjectName (LifecycleProfile _ project _ _) = project

-- | The durable protected-store identity that owned the consumed slot.
lifecycleProfileStoreIdentity :: LifecycleProfile scope -> Text
lifecycleProfileStoreIdentity (LifecycleProfile _ _ storeIdentity _) = storeIdentity

{- | Open the fresh Production profile. It requires the exact Production mode
lease and the still-unbound run lease minted under the same broker generation.
-}
withProductionLifecycleProfile ::
    RootScopeAuthority (Production projectId) ->
    ActiveProjectMode (Production projectId) brokerGeneration ->
    UnboundRunLease (Production projectId) brokerGeneration ->
    (LifecycleProfile (Production projectId) -> result) ->
    IO (Either AuthorityError result)
withProductionLifecycleProfile root active unbound use = do
    opened <- consumeLifecycleProfileSlot root WireProduction active unbound
    pure (fmap use opened)

{- | Open the fresh Harness profile for one run. A 'TestComponent' is given only
this opener, so there is no route from harness code to a Production profile.
-}
withHarnessLifecycleProfile ::
    RootScopeAuthority (Harness projectId runId) ->
    HarnessAuthority projectId runId ->
    RunId runId ->
    ActiveProjectMode (Harness projectId runId) brokerGeneration ->
    UnboundRunLease (Harness projectId runId) brokerGeneration ->
    (LifecycleProfile (Harness projectId runId) -> result) ->
    IO (Either AuthorityError result)
withHarnessLifecycleProfile root authority run active unbound use
    | harnessRunName authority /= runIdText run =
        pure
            ( Left
                ( AuthorityMalformedBinding
                    "the Harness authority and generative run witness disagree"
                )
            )
    | runIdText run /= unboundRunLeaseRunText unbound =
        pure
            ( Left
                ( AuthorityMalformedBinding
                    "the Harness run witness and unbound lease disagree"
                )
            )
    | otherwise = do
        opened <- consumeLifecycleProfileSlot root (WireHarness (runIdentityKey (HarnessRunIdentity run))) active unbound
        pure (fmap use opened)

{- | The exact recovered Production profile named by one already-admitted Open
invocation.

All five indices are nominal and the constructor is hidden.  The retained
runtime identity is deliberately complete enough for the later recovered-plan
builder to compare rather than infer: Production run, project and protected
store origin, positive snapshot revision, specification/configuration/plan
digests, exact canonical bytes, broker epoch, and the already classified Open
revision kind.  The profile itself opens no journal and grants no effect
authority.
-}
type role RecoveredProductionLifecycleProfile nominal nominal nominal nominal nominal
data RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration
    = RecoveredProductionLifecycleProfile
        (RunIdentity (Production projectId))
        Text
        Text
        Word64
        Text
        Text
        Text
        ByteString
        (BrokerEpoch brokerGeneration)
        OpenRevisionKind

instance
    Show
        ( RecoveredProductionLifecycleProfile
            projectId
            specDigest
            planDigest
            planId
            brokerGeneration
        )
    where
    show
        ( RecoveredProductionLifecycleProfile
                run
                project
                _store
                revision
                spec
                plan
                _config
                canonicalBytes
                epoch
                revisionKind
            ) =
            "RecoveredProductionLifecycleProfile "
                <> show (runIdentityText run)
                <> " "
                <> show project
                <> " "
                <> show revision
                <> " "
                <> show spec
                <> " "
                <> show plan
                <> " <"
                <> show (ByteString.length canonicalBytes)
                <> " canonical bytes> "
                <> show epoch
                <> " "
                <> show revisionKind

recoveredProductionProfileRunText ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfileRunText
    (RecoveredProductionLifecycleProfile run _ _ _ _ _ _ _ _ _) = runIdentityText run

recoveredProductionProfileProjectName ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfileProjectName
    (RecoveredProductionLifecycleProfile _ project _ _ _ _ _ _ _ _) = project

recoveredProductionProfileStoreIdentity ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfileStoreIdentity
    (RecoveredProductionLifecycleProfile _ _ storeIdentity _ _ _ _ _ _ _) = storeIdentity

recoveredProductionProfileRevision ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Word64
recoveredProductionProfileRevision
    (RecoveredProductionLifecycleProfile _ _ _ revision _ _ _ _ _ _) = revision

recoveredProductionProfileSpecDigest ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfileSpecDigest
    (RecoveredProductionLifecycleProfile _ _ _ _ spec _ _ _ _ _) = spec

recoveredProductionProfilePlanDigest ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfilePlanDigest
    (RecoveredProductionLifecycleProfile _ _ _ _ _ plan _ _ _ _) = plan

recoveredProductionProfileConfigDigest ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfileConfigDigest
    (RecoveredProductionLifecycleProfile _ _ _ _ _ _ config _ _ _) = config

recoveredProductionProfileCanonicalBytes ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    ByteString
recoveredProductionProfileCanonicalBytes
    (RecoveredProductionLifecycleProfile _ _ _ _ _ _ _ canonicalBytes _ _) = canonicalBytes

recoveredProductionProfileEpoch ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    Word64
recoveredProductionProfileEpoch
    (RecoveredProductionLifecycleProfile _ _ _ _ _ _ _ _ epoch _) = brokerEpochWord epoch

recoveredProductionProfileRevisionKind ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    OpenRevisionKind
recoveredProductionProfileRevisionKind
    (RecoveredProductionLifecycleProfile _ _ _ _ _ _ _ _ _ revisionKind) = revisionKind

{- | Refine the seven values yielded together by the Open branch of
@withBoundPlanSnapshot@ into their one recovered Production profile.

This is a pure runtime cross-check, not another protected transition.  The
admission-generated @planId@ is fixed by the bound snapshot, digest binding,
and recovery evidence in the argument types; this function has no
local-identity quantifier and cannot mint or select a replacement.  Success
yields only the opaque profile to the continuation.
-}
withRecoveredProductionLifecycleProfile ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId) specDigest planDigest planId brokerGeneration ->
    ( RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
      result
    ) ->
    Either ModeError result
withRecoveredProductionLifecycleProfile
    root
    modeLease
    boundLease
    verifiedSnapshot
    boundSnapshot
    digestBinding
    recovery
    use = do
        profile <-
            validateRecoveredProductionLifecycleProfile
                root
                modeLease
                boundLease
                verifiedSnapshot
                boundSnapshot
                digestBinding
                recovery
        Right (use profile)

validateRecoveredProductionLifecycleProfile ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId) specDigest planDigest planId brokerGeneration ->
    Either
        ModeError
        ( RecoveredProductionLifecycleProfile
            projectId specDigest planDigest planId brokerGeneration
        )
validateRecoveredProductionLifecycleProfile
    root
    modeLease
    boundLease
    verifiedSnapshot
    boundSnapshot
    digestBinding
    recovery = do
        requireVerb (rootAuthorityVerb root)
        requireMode modeWire
        requirePositiveEpoch retainedLeaseEpoch
        requireEpoch retainedLeaseEpoch (rootAuthorityEpoch root)
        requireEpoch retainedLeaseEpoch modeEpoch
        requireEpoch retainedLeaseEpoch recoveryEpoch
        requireRun "lease run" productionRunKey leaseRun
        requireNonempty "project identity" leaseProject
        requireNonempty "protected-store identity" leaseStore
        requireNonempty "specification digest" leaseSpec
        requireNonempty "plan digest" leasePlan
        requireText "root project" leaseProject (rootAuthorityProjectName root)
        requireText "mode project" leaseProject modeProject
        requireText "snapshot project" leaseProject (planSnapshotProjectName verifiedSnapshot)
        requireText "recovery project" leaseProject recoveryProject
        requireText "root store" leaseStore (rootAuthorityStoreIdentity root)
        requireText "mode store" leaseStore modeStore
        requireText "snapshot store" leaseStore (planSnapshotStoreIdentity verifiedSnapshot)
        requireText "recovery store" leaseStore recoveryStore
        requireRun "snapshot run" leaseRun (planSnapshotRunKey verifiedSnapshot)
        requireRun "recovery run" leaseRun recoveryRun
        requireText "snapshot specification" leaseSpec (planSnapshotSpecDigest verifiedSnapshot)
        requireText "recovery specification" leaseSpec recoverySpec
        requireText "snapshot plan" leasePlan (planSnapshotPlanDigest verifiedSnapshot)
        requireText "digest binding" leasePlan (planDigestBindingDigestKernel digestBinding)
        requireText "recovery plan" leasePlan recoveryPlan
        requireBindingOrigin bindingOrigin
        configDigest <-
            maybe
                (evidenceMismatch "canonical configuration" "present" "absent")
                Right
                (planSnapshotConfigDigest verifiedSnapshot)
        canonicalBytes <-
            maybe
                (evidenceMismatch "canonical bytes" "present" "absent")
                Right
                (planSnapshotCanonicalBytes verifiedSnapshot)
        requireNonempty "canonical configuration" configDigest
        requireNonemptyBytes canonicalBytes
        requireCanonicalBytes canonicalBytes (boundPlanSnapshotBytesKernel boundSnapshot)
        if snapshotRevision == 0
            then evidenceMismatch "snapshot revision" "positive" "zero"
            else
                Right
                    ( RecoveredProductionLifecycleProfile
                        leaseRunIdentity
                        leaseProject
                        leaseStore
                        snapshotRevision
                        leaseSpec
                        leasePlan
                        configDigest
                        canonicalBytes
                        retainedLeaseEpoch
                        revisionKind
                    )
  where
    ProjectModeLease modeWire modeProject modeStore modeEpoch = modeLease
    BoundRunLease leaseRunIdentity location leaseSpec leasePlan retainedLeaseEpoch _leaseVersion bindingOrigin =
        boundLease
    BoundInvocationRecovery
        recoveryRunIdentity
        recoveryProject
        recoveryStore
        recoverySpec
        recoveryPlan
        recoveryEpoch
        revisionKind = recovery
    leaseRun = runIdentityKey leaseRunIdentity
    recoveryRun = runIdentityKey recoveryRunIdentity
    leaseProject = leaseLocationProjectName location
    leaseStore = leaseLocationStoreIdentity location
    snapshotRevision = planSnapshotRevision verifiedSnapshot

    evidenceMismatch subject expected observed =
        Left (ModeEvidenceMismatch subject expected observed)

    requireText subject expected observed
        | expected == observed = Right ()
        | otherwise = evidenceMismatch subject expected observed

    requireRun subject expected observed =
        requireText subject (runKeyText expected) (runKeyText observed)

    requireMode observed
        | observed == WireProduction = Right ()
        | otherwise =
            Left (ModeWrongMode "production" (modeWireName observed))

    requireVerb :: ProjectVerb VerbUp -> Either ModeError ()
    requireVerb ProjectUp = Right ()

    requireEpoch expected observed
        | brokerEpochWord expected == brokerEpochWord observed = Right ()
        | otherwise =
            Left
                ( ModeEpochMismatch
                    (brokerEpochWord expected)
                    (brokerEpochWord observed)
                )

    requirePositiveEpoch epoch
        | brokerEpochWord epoch > 0 = Right ()
        | otherwise = evidenceMismatch "broker generation" "positive" "zero"

    requireBindingOrigin origin =
        case origin of
            ExistingBinding -> Right ()
            FreshBinding -> evidenceMismatch "lease binding origin" "existing" "fresh"
            MigratedBinding -> evidenceMismatch "lease binding origin" "existing" "migrated"

    requireNonempty subject value
        | Text.null value = evidenceMismatch subject "nonempty" "empty"
        | otherwise = Right ()

    requireNonemptyBytes bytes
        | ByteString.null bytes = evidenceMismatch "canonical bytes" "nonempty" "empty"
        | otherwise = Right ()

    requireCanonicalBytes expected observed
        | expected == observed = Right ()
        | otherwise = evidenceMismatch "canonical bytes" "exact verified bytes" "different bytes"

consumeLifecycleProfileSlot ::
    forall scope brokerGeneration.
    RootScopeAuthority scope ->
    ModeWire ->
    ActiveProjectMode scope brokerGeneration ->
    UnboundRunLease scope brokerGeneration ->
    IO (Either AuthorityError (LifecycleProfile scope))
consumeLifecycleProfileSlot root expectedMode active unbound =
    case validateLifecycleProfileEvidence root expectedMode active unbound of
        Left failure -> pure (Left failure)
        Right () -> do
            entered <-
                withProtectedEntry (leaseLocationStore location) $ \session -> do
                    clear <- refuseReverseRootIntentForName session projectName
                    case clear of
                        Left (ModeStoreFailure failure) ->
                            pure (Right (Left (AuthorityStoreFailure failure)))
                        Left _ ->
                            pure
                                ( Right
                                    ( Left
                                        ( AuthorityMalformedBinding
                                            "ordinary lifecycle admission is unavailable"
                                        )
                                    )
                                )
                        Right () -> do
                            consumed <- consumeProfileRecord session
                            pure (Right consumed)
            pure $ case entered of
                Left failure -> Left (AuthorityStoreFailure failure)
                Right result -> result
  where
    location = unboundRunLeaseLocation unbound
    projectName = leaseLocationProjectName location
    storeIdentity = leaseLocationStoreIdentity location
    expectedEpoch = brokerEpochWord (unboundRunLeaseEpoch unbound)
    expectedLeaseVersion = unboundRunLeaseRecordVersion unbound
    key = leaseLocationProfileKey location
    invocationName =
        "lifecycle-profile:"
            <> leaseLocationProjectName location
            <> ":"
            <> unboundRunLeaseRunText unbound

    consumeProfileRecord ::
        forall session.
        ProtectedSession session ->
        IO (Either AuthorityError (LifecycleProfile scope))
    consumeProfileRecord session = do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (AuthorityStoreFailure failure))
            Right Nothing ->
                pure (Left (AuthorityMalformedBinding "the lifecycle profile slot is missing"))
            Right (Just record) -> case decodeProfileSlot (protectedRecordBytes record) of
                Nothing ->
                    pure (Left (AuthorityMalformedBinding "the lifecycle profile slot is malformed"))
                Just (ProfileAvailable epoch leaseVersion)
                    | epoch /= expectedEpoch || leaseVersion /= expectedLeaseVersion ->
                        pure
                            ( Left
                                ( AuthorityMalformedBinding
                                    "the lifecycle profile slot does not match the lease epoch and version"
                                )
                            )
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeProfileSlot (ProfileConsumed epoch leaseVersion))
                        case written of
                            Right _ ->
                                pure
                                    ( Right
                                        ( LifecycleProfile
                                            expectedMode
                                            projectName
                                            storeIdentity
                                            epoch
                                        )
                                    )
                            Left failure -> do
                                raced <- readProtectedRecord session key
                                pure $ case raced of
                                    Right (Just latest)
                                        | Just (ProfileConsumed racedEpoch racedVersion) <-
                                            decodeProfileSlot (protectedRecordBytes latest)
                                        , racedEpoch == epoch
                                        , racedVersion == leaseVersion ->
                                            Left (AuthorityInvocationConsumed invocationName)
                                    Left readFailure -> Left (AuthorityStoreFailure readFailure)
                                    _ -> Left (AuthorityStoreFailure failure)
                Just (ProfileConsumed epoch leaseVersion)
                    | epoch == expectedEpoch && leaseVersion == expectedLeaseVersion ->
                        pure (Left (AuthorityInvocationConsumed invocationName))
                    | otherwise ->
                        pure
                            ( Left
                                ( AuthorityMalformedBinding
                                    "the consumed lifecycle profile slot belongs to another lease epoch or version"
                                )
                            )

validateLifecycleProfileEvidence ::
    RootScopeAuthority scope ->
    ModeWire ->
    ActiveProjectMode scope brokerGeneration ->
    UnboundRunLease scope brokerGeneration ->
    Either AuthorityError ()
validateLifecycleProfileEvidence root expectedMode (ActiveProjectMode activeMode activeProject activeStore activeEpoch) unbound
    | rootScopeProjectName root /= projectName = mismatch "root scope project"
    | activeProject /= projectName = mismatch "active mode project"
    | rootScopeStoreIdentity root /= storeIdentity =
        Left (AuthorityWrongStore storeIdentity (rootScopeStoreIdentity root))
    | activeStore /= storeIdentity = Left (AuthorityWrongStore storeIdentity activeStore)
    | rootScopeEpochWord root /= expectedEpoch = mismatch "root scope epoch"
    | brokerEpochWord activeEpoch /= expectedEpoch = mismatch "active mode epoch"
    | activeMode /= expectedMode = mismatch "active mode tag"
    | runIdentityMode (unboundRunLeaseIdentity unbound) /= expectedMode = mismatch "lease mode tag"
    | otherwise = Right ()
  where
    location = unboundRunLeaseLocation unbound
    projectName = leaseLocationProjectName location
    storeIdentity = leaseLocationStoreIdentity location
    expectedEpoch = brokerEpochWord (unboundRunLeaseEpoch unbound)
    mismatch subject =
        Left (AuthorityMalformedBinding (subject <> " does not match the lifecycle profile slot"))

data ProfileSlot
    = ProfileAvailable Word64 Word64
    | ProfileConsumed Word64 Word64

encodeProfileSlot :: ProfileSlot -> ByteString
encodeProfileSlot slot = case slot of
    ProfileAvailable epoch leaseVersion ->
        encodeFields ["available", showWord epoch, showWord leaseVersion]
    ProfileConsumed epoch leaseVersion ->
        encodeFields ["consumed", showWord epoch, showWord leaseVersion]

decodeProfileSlot :: ByteString -> Maybe ProfileSlot
decodeProfileSlot raw = case decodeFields raw of
    ["available", epoch, leaseVersion] ->
        ProfileAvailable <$> readWord epoch <*> readWord leaseVersion
    ["consumed", epoch, leaseVersion] ->
        ProfileConsumed <$> readWord epoch <*> readWord leaseVersion
    _ -> Nothing

-- Plan migration --------------------------------------------------------------------

{- | The stable key one migration is named by, for its whole life.

Everything a migration persists hangs off this key, and every later step reads
the key back rather than recomputing a digest from the current config. That is
what § EE means by "Both paths first load and verify the exact prospective
snapshot named by the durable @stableMigrationKey@, never a digest inferred from
current config": an operator who edits the config between the freeze and the
activation must not thereby change which candidate is activated.
-}
newtype StableMigrationKey = StableMigrationKey Text
    deriving (Eq, Ord)

instance Show StableMigrationKey where
    show (StableMigrationKey value) = "StableMigrationKey " <> show value

stableMigrationKeyText :: StableMigrationKey -> Text
stableMigrationKeyText (StableMigrationKey value) = value

{- | The pure, non-authorizing snapshot of a migration candidate.

It is deliberately /not/ a 'VerifiedPlanSnapshot': a candidate authorizes
nothing. No prepared operation, no lease binding, and no effect can be reached
from one — § EE's "prospective, frozen, and staged records authorize no effect".
It exists so the freeze has something exact to persist and the activation has
something exact to compare against.
-}
data ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest
    = ProspectivePlanSnapshot StableMigrationKey Text Text

type role ProspectivePlanSnapshot nominal nominal nominal

instance Show (ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest) where
    show (ProspectivePlanSnapshot key spec plan) =
        "ProspectivePlanSnapshot " <> show key <> " " <> show spec <> " " <> show plan

prospectiveSnapshotKey ::
    ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest -> StableMigrationKey
prospectiveSnapshotKey (ProspectivePlanSnapshot key _ _) = key

prospectiveSnapshotSpecDigest ::
    ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest -> Text
prospectiveSnapshotSpecDigest (ProspectivePlanSnapshot _ spec _) = spec

prospectiveSnapshotPlanDigest ::
    ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest -> Text
prospectiveSnapshotPlanDigest (ProspectivePlanSnapshot _ _ plan) = plan

{- | The migration profile: the sole route from a live Production @up@ to a
revision carry.

§ EE names 'withProjectUpMigrationProfile' as its sole producer, and every input
is revalidated rather than trusted:

* the root must be the exact Production @ProjectUp@ authority. A @down@ or
  @destroy@ root cannot migrate a revision;
* the mode lease must currently hold Production under the same broker
  generation;
* the old bound lease and the verified snapshot must agree on both digests;
* the recovery evidence must be 'NormalActiveRecovery'. This is the one that
  rules out the dangerous case: a migration may only be started from a binding
  that was /fresh/, because an abandoned invocation's revision has to be
  recovered before anything may be carried forward from it.

It carries no plan. § EE: "Compatible revision carry first uses the sole
'withProjectUpMigrationProfile' producer to revalidate ... without a new plan."
-}
data ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration
    = ProjectUpMigrationProfile
        (RunIdentity (Production projectId))
        LeaseLocation
        Text
        Text
        Word64

type role ProjectUpMigrationProfile nominal nominal nominal nominal

instance
    Show
        (ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration)
    where
    show (ProjectUpMigrationProfile run _ spec plan epoch) =
        "ProjectUpMigrationProfile "
            <> show (runIdentityText run)
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch

migrationProfileRun ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Text
migrationProfileRun (ProjectUpMigrationProfile run _ _ _ _) = runIdentityText run

migrationProfileRunIdentity ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration ->
    RunIdentity (Production projectId)
migrationProfileRunIdentity (ProjectUpMigrationProfile run _ _ _ _) = run

migrationProfileLocation ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration ->
    LeaseLocation
migrationProfileLocation (ProjectUpMigrationProfile _ location _ _ _) = location

migrationProfileOldSpecDigest ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Text
migrationProfileOldSpecDigest (ProjectUpMigrationProfile _ _ spec _ _) = spec

migrationProfileOldPlanDigest ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Text
migrationProfileOldPlanDigest (ProjectUpMigrationProfile _ _ _ plan _) = plan

migrationProfileEpoch ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Word64
migrationProfileEpoch (ProjectUpMigrationProfile _ _ _ _ epoch) = epoch

-- | Mint the migration profile, or refuse. See 'ProjectUpMigrationProfile'.
withProjectUpMigrationProfile ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) oldSpecDigest oldPlanDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) oldSpecDigest oldPlanDigest ->
    Either
        ModeError
        (ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration)
withProjectUpMigrationProfile root modeLease bound snapshot
    | brokerEpochWord (rootAuthorityEpoch root)
        /= brokerEpochWord (projectModeLeaseEpoch modeLease) =
        Left
            ( ModeEpochMismatch
                (brokerEpochWord (projectModeLeaseEpoch modeLease))
                (brokerEpochWord (rootAuthorityEpoch root))
            )
    | run /= planSnapshotRunKey snapshot =
        Left
            ( ModeSnapshotMismatch
                (runKeyText run)
                (planSnapshotRunText snapshot)
            )
    | bindingOrigin /= FreshBinding =
        Left
            ( ModeSnapshotMismatch
                "fresh lease binding"
                "recovered or migrated lease binding"
            )
    | boundRunLeaseSpecDigest bound /= planSnapshotSpecDigest snapshot =
        Left
            ( ModeSnapshotMismatch
                (boundRunLeaseSpecDigest bound)
                (planSnapshotSpecDigest snapshot)
            )
    | boundRunLeasePlanDigest bound /= planSnapshotPlanDigest snapshot =
        Left
            ( ModeSnapshotMismatch
                (boundRunLeasePlanDigest bound)
                (planSnapshotPlanDigest snapshot)
            )
    | otherwise =
        Right
            ( ProjectUpMigrationProfile
                (boundRunLeaseIdentity bound)
                location
                (planSnapshotSpecDigest snapshot)
                (planSnapshotPlanDigest snapshot)
                (brokerEpochWord (rootAuthorityEpoch root))
            )
  where
    BoundRunLease _ location _ _ _ _ bindingOrigin = bound
    run = runIdentityKey (boundRunLeaseIdentity bound)

{- | Build one migration candidate and persist it under a fresh stable key,
before anything is frozen.

This is the pre-freeze half, and its whole point is that a crash here is
harmless. § EE: "failed/unknown persistence leaves admission unchanged, and a
pre-freeze crash leaves only a non-authorizing unreferenced record." Nothing
about the live revision changes; the store simply gains a candidate record
nobody references.

The candidate is persisted and then __authoritatively read back__ before the
continuation sees it, so what the freeze will later act on is bytes the store
actually holds rather than bytes this process believes it wrote.

A migration to the same plan digest is refused. Carrying a revision forward onto
itself has no meaning, and admitting it would let a caller freeze the live
revision against a candidate that cannot supersede it.

The rank-2 continuation binds fresh @newSpecDigest@\/@newPlanDigest@ indices, so
the candidate cannot be confused with the old revision's.
-}
withProspectiveMigrationPlan ::
    forall session projectId oldSpecDigest oldPlanDigest brokerGeneration result.
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration ->
    -- | the candidate's spec digest
    Text ->
    -- | the candidate's plan digest
    Text ->
    ( forall newSpecDigest newPlanDigest.
      ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withProspectiveMigrationPlan session project profile newSpec newPlan use =
    withOrdinaryProjectAdmission session project proceed
  where
    proceed
      | Text.null newSpec || Text.null newPlan =
        pure (Left (ModeInvalidIdentity "a migration candidate needs both digests"))
      | newPlan == migrationProfileOldPlanDigest profile =
        pure
            ( Left
                ( ModeSnapshotMismatch
                    (migrationProfileOldPlanDigest profile)
                    newPlan
                )
            )
      | otherwise = withRecordKey (prospectiveKey project key) $ \recordKey -> do
        observed <- readProtectedRecord session recordKey
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right existing -> do
                let expectation =
                        maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) existing
                written <-
                    compareAndSwapProtectedRecord
                        session
                        recordKey
                        expectation
                        (encodeFields ["prospective", newSpec, newPlan])
                case written of
                    Left failure -> pure (Left (ModeStoreFailure failure))
                    Right _ -> do
                        -- Read the candidate back authoritatively: the freeze
                        -- must act on what the store holds, not on what this
                        -- process just claimed to write.
                        readBack <- readProspectiveSnapshot session project key
                        case readBack of
                            Left failure -> pure (Left failure)
                            Right (spec, plan)
                                | spec /= newSpec -> pure (Left (ModeSnapshotMismatch newSpec spec))
                                | plan /= newPlan -> pure (Left (ModeSnapshotMismatch newPlan plan))
                                | otherwise ->
                                    use (ProspectivePlanSnapshot key spec plan)
    key = stableMigrationKeyFor profile newPlan

{- | The stable key a migration is named by: the old plan digest, the candidate's
plan digest, and the run.

It is a pure function of the three, so a retried migration of the same candidate
resumes the same key rather than proposing a second one — which is what makes
the whole protocol idempotent under a crash.
-}
stableMigrationKeyFor ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration ->
    Text ->
    StableMigrationKey
stableMigrationKeyFor profile newPlan =
    StableMigrationKey
        ( migrationProfileRun profile
            <> "."
            <> migrationProfileOldPlanDigest profile
            <> "."
            <> newPlan
        )

readProspectiveSnapshot ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    StableMigrationKey ->
    IO (Either ModeError (Text, Text))
readProspectiveSnapshot session project key =
    withRecordKey (prospectiveKey project key) $ \recordKey -> do
        observed <- readProtectedRecord session recordKey
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Left (ModeSnapshotMissing (stableMigrationKeyText key))
            Right (Just record) -> case decodeFields (protectedRecordBytes record) of
                ["prospective", spec, plan] -> Right (spec, plan)
                _ -> Left (ModeMalformedRecord (recordKeyText recordKey))

{- | The old revision's lease, frozen under one stable migration key.

Freezing is what makes old- and new-bound authority unable to coexist (§ EE):
the lease record is no longer @bound@, so 'bindRunLease' refuses it and no
prepared operation can be issued against the old revision. The only thing that
can consume this capability is the activation compare-and-swap, and consuming it
is what produces the new bound lease.
-}
data FrozenMigrationRunLease
    projectId
    oldSpecDigest
    oldPlanDigest
    newSpecDigest
    newPlanDigest
    brokerGeneration
    = FrozenMigrationRunLease
        (RunIdentity (Production projectId))
        LeaseLocation
        StableMigrationKey
        Text
        Text
        Text
        Text
        Word64

type role FrozenMigrationRunLease nominal nominal nominal nominal nominal nominal

instance
    Show
        ( FrozenMigrationRunLease
            projectId
            oldSpecDigest
            oldPlanDigest
            newSpecDigest
            newPlanDigest
            brokerGeneration
        )
    where
    show (FrozenMigrationRunLease run _ key oldSpec oldPlan newSpec newPlan epoch) =
        "FrozenMigrationRunLease "
            <> show (runIdentityText run)
            <> " "
            <> show key
            <> " "
            <> show oldSpec
            <> " "
            <> show oldPlan
            <> " -> "
            <> show newSpec
            <> " "
            <> show newPlan
            <> " "
            <> show epoch

frozenMigrationKey ::
    FrozenMigrationRunLease
        projectId
        oldSpecDigest
        oldPlanDigest
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    StableMigrationKey
frozenMigrationKey (FrozenMigrationRunLease _ _ key _ _ _ _ _) = key

frozenMigrationRun ::
    FrozenMigrationRunLease
        projectId
        oldSpecDigest
        oldPlanDigest
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    Text
frozenMigrationRun (FrozenMigrationRunLease run _ _ _ _ _ _ _) = runIdentityText run

frozenMigrationRunIdentity ::
    FrozenMigrationRunLease
        projectId
        oldSpecDigest
        oldPlanDigest
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    RunIdentity (Production projectId)
frozenMigrationRunIdentity (FrozenMigrationRunLease run _ _ _ _ _ _ _) = run

frozenMigrationLocation ::
    FrozenMigrationRunLease
        projectId
        oldSpecDigest
        oldPlanDigest
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    LeaseLocation
frozenMigrationLocation (FrozenMigrationRunLease _ location _ _ _ _ _ _) = location

{- | Freeze the old revision against a persisted candidate.

The order is § EE's, and each step is durable before the one after it can be
observed:

1. the candidate is loaded back under its own stable key. A caller cannot pass a
   candidate that was never persisted, and cannot substitute one, because the
   key is derived from the profile and the digests are compared against the
   record;
2. the migration is recorded as an __incomplete__ revision on the run, which is
   the durable observation the recovery classifier later reads. Recording it
   before the freeze is what makes the window recoverable: a crash between here
   and the freeze leaves a run whose recorded kind says the barrier was not
   crossed, and 'resolveBoundRun' discards the staging;
3. only then is the lease compare-and-swapped from @bound@ to @frozen@. That is
   the point at which old-revision preparation stops: the lease is no longer
   bindable and no new prepared operation can be issued under it.

Freezing an already-frozen lease under the same key is idempotent and returns
the same capability, so a retried migration converges rather than refusing.
-}
withPlanMigration ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration ->
    ProspectivePlanSnapshot projectId newSpecDigest newPlanDigest ->
    IO
        ( Either
            ModeError
            ( FrozenMigrationRunLease
                projectId
                oldSpecDigest
                oldPlanDigest
                newSpecDigest
                newPlanDigest
                brokerGeneration
            )
        )
withPlanMigration session project profile candidate =
  withOrdinaryProjectAdmission session project $ do
    loaded <- readProspectiveSnapshot session project key
    case loaded of
        Left failure -> pure (Left failure)
        Right (spec, plan)
            | spec /= prospectiveSnapshotSpecDigest candidate ->
                pure (Left (ModeSnapshotMismatch (prospectiveSnapshotSpecDigest candidate) spec))
            | plan /= prospectiveSnapshotPlanDigest candidate ->
                pure (Left (ModeSnapshotMismatch (prospectiveSnapshotPlanDigest candidate) plan))
            | otherwise -> do
                recorded <-
                    recordOpenRevisionMigrationForKey
                        session
                        project
                        (runIdentityKey run)
                        (IncompleteMigration (stableMigrationKeyText key))
                case recorded of
                    Left failure -> pure (Left failure)
                    Right () -> freezeLease session project profile key spec plan
  where
    key = prospectiveSnapshotKey candidate
    run = migrationProfileRunIdentity profile

freezeLease ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration ->
    StableMigrationKey ->
    Text ->
    Text ->
    IO
        ( Either
            ModeError
            ( FrozenMigrationRunLease
                projectId
                oldSpecDigest
                oldPlanDigest
                newSpecDigest
                newPlanDigest
                brokerGeneration
            )
        )
freezeLease session _project profile key newSpec newPlan =
    let recordKey = leaseLocationLeaseKey location
     in do
        observed <- readProtectedRecord session recordKey
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeLeaseMissing (runIdentityText run)))
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText recordKey)))
                -- Already frozen under this exact key: idempotent resume.
                Just (LeaseFrozen _ recorded oldSpec oldPlan recordedSpec recordedPlan)
                    | recorded /= stableMigrationKeyText key ->
                        pure
                            ( Left
                                ( ModeSnapshotMismatch
                                    (stableMigrationKeyText key)
                                    recorded
                                )
                            )
                    | otherwise ->
                        pure
                            ( Right
                                ( FrozenMigrationRunLease
                                    run
                                    location
                                    key
                                    oldSpec
                                    oldPlan
                                    recordedSpec
                                    recordedPlan
                                    (migrationProfileEpoch profile)
                                )
                            )
                Just (LeaseBound epoch recordedSpec recordedPlan)
                    | recordedSpec /= migrationProfileOldSpecDigest profile ->
                        pure
                            ( Left
                                ( ModeSnapshotMismatch
                                    (migrationProfileOldSpecDigest profile)
                                    recordedSpec
                                )
                            )
                    | recordedPlan /= migrationProfileOldPlanDigest profile ->
                        pure
                            ( Left
                                ( ModeSnapshotMismatch
                                    (migrationProfileOldPlanDigest profile)
                                    recordedPlan
                                )
                            )
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                recordKey
                                (ExpectVersion (protectedRecordVersion record))
                                ( encodeLease
                                    ( LeaseFrozen
                                        epoch
                                        (stableMigrationKeyText key)
                                        recordedSpec
                                        recordedPlan
                                        newSpec
                                        newPlan
                                    )
                                )
                        pure $ case written of
                            Left failure -> Left (ModeStoreFailure failure)
                            Right _ ->
                                Right
                                    ( FrozenMigrationRunLease
                                        run
                                        location
                                        key
                                        recordedSpec
                                        recordedPlan
                                        newSpec
                                        newPlan
                                        (migrationProfileEpoch profile)
                                    )
                Just other ->
                    pure (Left (ModeLeaseNotBindable (runIdentityText run) (leaseStateName other)))
  where
    run = migrationProfileRunIdentity profile
    location = migrationProfileLocation profile

{- | The activation barrier: proof that the lineage switch committed.

It is indexed by /both/ plan digests, so a barrier minted for one migration
cannot authorize another's activation. Its constructor is private and
'commitMigrationActivation' is its sole producer.
-}
data PlanMigrationBarrier projectId oldPlanDigest newPlanDigest
    = PlanMigrationBarrier StableMigrationKey RunKey Text Text

type role PlanMigrationBarrier nominal nominal nominal

instance Show (PlanMigrationBarrier projectId oldPlanDigest newPlanDigest) where
    show (PlanMigrationBarrier key run old new) =
        "PlanMigrationBarrier "
            <> show key
            <> " "
            <> show run
            <> " "
            <> show old
            <> " -> "
            <> show new

migrationBarrierKey ::
    PlanMigrationBarrier projectId oldPlanDigest newPlanDigest -> StableMigrationKey
migrationBarrierKey (PlanMigrationBarrier key _ _ _) = key

migrationBarrierOldPlanDigest ::
    PlanMigrationBarrier projectId oldPlanDigest newPlanDigest -> Text
migrationBarrierOldPlanDigest (PlanMigrationBarrier _ _ old _) = old

migrationBarrierNewPlanDigest ::
    PlanMigrationBarrier projectId oldPlanDigest newPlanDigest -> Text
migrationBarrierNewPlanDigest (PlanMigrationBarrier _ _ _ new) = new

{- | The activation compare-and-swap: switch the lineage old → new.

This is the barrier the whole recovery classification is about. It consumes the
frozen capability and, in one compare-and-swap over the lease record, replaces
the frozen state with a lease bound to the __candidate's__ digests. Only after
that succeeds is the run recorded as a __completed__ migration.

That ordering is the one a restart depends on. A crash before the swap leaves a
frozen lease and an @IncompleteMigration@ record, so recovery discards the
staging; a crash after it leaves a new-bound lease and a @CompletedMigration@
record, so recovery resumes activation. There is no window in which the lease
says one thing and the recorded kind says the other in the dangerous direction:
the lease commits first, and a lease that committed with the record still
saying incomplete is repaired by re-running this function, which observes the
already-bound candidate and completes the record.
-}
commitMigrationActivation ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    FrozenMigrationRunLease
        projectId
        oldSpecDigest
        oldPlanDigest
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    BrokerEpoch brokerGeneration ->
    IO
        ( Either
            ModeError
            ( BoundRunLease (Production projectId) newSpecDigest newPlanDigest brokerGeneration
            , PlanMigrationBarrier projectId oldPlanDigest newPlanDigest
            )
        )
commitMigrationActivation session project frozen epoch =
    withOrdinaryProjectAdmission session project $
        let recordKey = leaseLocationLeaseKey location
         in do
        observed <- readProtectedRecord session recordKey
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeLeaseMissing (runIdentityText run)))
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText recordKey)))
                Just (LeaseFrozen _ recorded _oldSpec oldPlan newSpec newPlan)
                    | recorded /= stableMigrationKeyText key ->
                        pure (Left (ModeSnapshotMismatch (stableMigrationKeyText key) recorded))
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                recordKey
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeLease (LeaseBound (brokerEpochWord epoch) newSpec newPlan))
                        case written of
                            Left failure -> pure (Left (ModeStoreFailure failure))
                            Right leaseVersion -> complete leaseVersion oldPlan newSpec newPlan
                -- The swap already committed and the record write did not: the
                -- lease is bound to the candidate, so finish the record rather
                -- than refusing a migration that is in fact activated.
                Just (LeaseBound _ recordedSpec recordedPlan)
                    | (recordedSpec, recordedPlan) == candidateDigests ->
                        complete (protectedRecordVersion record) oldPlanOf recordedSpec recordedPlan
                Just other ->
                    pure (Left (ModeLeaseNotBindable (runIdentityText run) (leaseStateName other)))
  where
    FrozenMigrationRunLease _ _ key _oldSpecOf oldPlanOf newSpecOf newPlanOf _ = frozen
    run = frozenMigrationRunIdentity frozen
    location = frozenMigrationLocation frozen
    candidateDigests = (newSpecOf, newPlanOf)

    complete leaseVersion oldPlan newSpec newPlan = do
        recorded <-
            recordOpenRevisionMigrationForKey
                session
                project
                (runIdentityKey run)
                (CompletedMigration (stableMigrationKeyText key))
        pure $ case recorded of
            Left failure -> Left failure
            Right () ->
                Right
                    ( BoundRunLease run location newSpec newPlan epoch leaseVersion MigratedBinding
                    , PlanMigrationBarrier key (runIdentityKey run) oldPlan newPlan
                    )

{- | Activate the migrated plan: the last gate before the new revision may open
a session.

§ EE: "'activateMigratedPlan' must consume that barrier, the exact new-bound
lease\/active revision, local plan\/binding, and complete set before exposing a
journal or preparation authority. It rechecks that no old session remains Open
and jointly yields the new revision's 'CurrentBrokerSessionAdmission'."

So it takes the barrier and the new lease, checks they name the same candidate,
and then — the load-bearing recheck — runs the recorded-session interpreter over
the __old__ revision's plan digest. An old session still Open is exactly the
state that must not be able to reach the new revision's admission, and the
interpreter is what both proves and settles it. The admission it returns is the
new revision's, minted from the new plan's own complete sets.
-}
activateMigratedPlan ::
    ProtectedSession session ->
    PlanMigrationBarrier projectId oldPlanDigest newPlanDigest ->
    BoundRunLease scope newSpecDigest newPlanDigest brokerGeneration ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (CurrentBrokerSessionAdmission scope newPlanDigest brokerGeneration))
activateMigratedPlan session barrier bound epoch =
    withOrdinaryProjectAdmissionForName session project proceed
  where
    project = leaseLocationProjectName (boundRunLeaseLocation bound)
    proceed
      | boundRunLeasePlanDigest bound /= migrationBarrierNewPlanDigest barrier =
        pure
            ( Left
                ( ModeSnapshotMismatch
                    (migrationBarrierNewPlanDigest barrier)
                    (boundRunLeasePlanDigest bound)
                )
            )
      | otherwise = do
        -- Settle the old revision's sessions first. Until this succeeds there
        -- is no admission for the new revision at all.
        oldSettled <- settleRevision session epoch (migrationBarrierOldPlanDigest barrier)
        case oldSettled of
            Left failure -> pure (Left failure)
            Right () -> settleAndAdmit session epoch (migrationBarrierNewPlanDigest barrier)

{- | Drive one revision's recorded sessions to Closed, discarding the admission.

Used for the __old__ revision at activation: what matters there is that nothing
of it is still Open, not that it can be admitted. The admission it necessarily
produces on the way is dropped rather than returned, so there is no value a
caller could present as the old revision's authority.
-}
settleRevision ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    Text ->
    IO (Either ModeError ())
settleRevision session epoch planDigest = do
    admitted <- settleAndAdmit session epoch planDigest
    pure (fmap discard admitted)
  where
    -- The indices are irrelevant here precisely because the value is dropped;
    -- naming them keeps the ambiguity from leaking into the caller.
    discard ::
        CurrentBrokerSessionAdmission (Production ()) () brokerGeneration -> ()
    discard _ = ()

{- | The fence → manifest → interpret → admit chain over one plan digest.

It is the same chain 'withAbandonedHarnessRun' runs, factored out because the
activation transition needs it for two different revisions.
-}
settleAndAdmit ::
    forall session scope planId brokerGeneration.
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    Text ->
    IO (Either ModeError (CurrentBrokerSessionAdmission scope planId brokerGeneration))
settleAndAdmit session epoch planDigest = do
    fenced <- fenceOldPermits session planDigest
    case fenced of
        Left failure -> pure (Left (ModeSessionFailure failure))
        Right fencedPermits -> do
            manifested <- verifySessionManifest session planDigest
            case manifested of
                Left failure -> pure (Left (ModeSessionFailure failure))
                Right manifest -> do
                    journal <- openProjectJournal session planDigest
                    case journal of
                        Left failure -> pure (Left (ModeSessionFailure failure))
                        Right (permit :: ProjectPermit scope planId) -> do
                            driven <-
                                interpretRecordedSessions session epoch manifest fencedPermits permit
                            case driven of
                                Left failure -> pure (Left (ModeSessionFailure failure))
                                Right (interpreted, _spent) -> do
                                    admitted <-
                                        admitCurrentBroker session epoch manifest fencedPermits interpreted
                                    pure (either (Left . ModeSessionFailure) Right admitted)

{- | The configless post-CAS recovery path.

§ EE: "A post-CAS restart selects completed recovery ... 'withCompletedMigrationRecovery'
uses the same non-secret protected snapshot data for configless teardown."

It is reachable only from a run whose recorded kind is 'CompletedMigration', and
it loads the candidate back under the durable stable key named by that record —
never a digest inferred from the current config, which may have been edited or
removed. What it yields is the barrier, so the caller can drive the activation
through with the destroy-only authority a recovery holds; it yields no profile,
no plan, and no route to @up@.

Only @oldPlanDigest@ is bound generatively, and the asymmetry is deliberate. The
superseded revision is the one recovery can name from /nothing but/ the durable
key, so nothing the caller holds may be substituted for it. The new revision is
the caller's own bound lease — it is what recovery is activating /towards/ — so
its index is the caller's, and 'activateMigratedPlan' still compares the two
digests at the term level before admitting anything.
-}
withCompletedMigrationRecovery ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BoundRunLease
        scope
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    ( forall oldPlanDigest.
      PlanMigrationBarrier projectId oldPlanDigest newPlanDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withCompletedMigrationRecovery session project bound use =
  withOrdinaryProjectAdmission session project $ do
    if leaseLocationProjectName location /= installedProjectName project
        then
            pure
                ( Left
                    ( ModeSnapshotMismatch
                        (leaseLocationProjectName location)
                        (installedProjectName project)
                    )
                )
        else
            if leaseLocationStoreIdentity location /= observedStoreIdentity
                then
                    pure
                        ( Left
                            ( ModeSnapshotMismatch
                                (leaseLocationStoreIdentity location)
                                observedStoreIdentity
                            )
                        )
                else do
                    kind <- readOpenRevisionKindForKey session project runKey
                    case kind of
                        Left failure -> pure (Left failure)
                        Right (CompletedMigration key) ->
                            withRecordKey (leaseKeyForRunKey project runKey) $ \recordKey -> do
                                observed <- readProtectedRecord session recordKey
                                case observed of
                                    Left failure -> pure (Left (ModeStoreFailure failure))
                                    Right Nothing ->
                                        pure (Left (ModeLeaseMissing (runKeyText runKey)))
                                    Right (Just record) ->
                                        case decodeLease (protectedRecordBytes record) of
                                            Nothing ->
                                                pure
                                                    ( Left
                                                        (ModeMalformedRecord (recordKeyText recordKey))
                                                    )
                                            -- The lease is bound to the candidate, so the old plan
                                            -- digest is recovered from the stable key rather than from
                                            -- any config.
                                            Just (LeaseBound _ _ recordedPlan) ->
                                                case oldPlanFromStableKey key of
                                                    Nothing ->
                                                        pure (Left (ModeMalformedRecord key))
                                                    Just oldPlan ->
                                                        use
                                                            ( PlanMigrationBarrier
                                                                (StableMigrationKey key)
                                                                runKey
                                                                oldPlan
                                                                recordedPlan
                                                            )
                                            Just other ->
                                                pure
                                                    ( Left
                                                        ( ModeLeaseNotBindable
                                                            (runKeyText runKey)
                                                            (leaseStateName other)
                                                        )
                                                    )
                        Right other ->
                            pure
                                ( Left
                                    ( ModeWrongRecoveryScope
                                        "completed-migration"
                                        (openRevisionKindName other)
                                    )
                                )
  where
    location = boundRunLeaseLocation bound
    runKey = runIdentityKey (boundRunLeaseIdentity bound)
    observedStoreIdentity = protectedStoreIdentityText (sessionStoreIdentity session)

-- | The old plan digest a stable migration key names: @\<run\>.\<old\>.\<new\>@.
oldPlanFromStableKey :: Text -> Maybe Text
oldPlanFromStableKey raw = case Text.splitOn "." raw of
    [_run, old, _new] | not (Text.null old) -> Just old
    _ -> Nothing

openRevisionKindName :: OpenRevisionKind -> Text
openRevisionKindName kind = case kind of
    NormalRevision -> "normal revision"
    IncompleteMigration key -> "incomplete migration " <> key
    CompletedMigration key -> "completed migration " <> key

prospectiveKey :: InstalledProjectIdentity projectId -> StableMigrationKey -> Either ModeError RecordKey
prospectiveKey project key =
    storeKey
        ( "prospective."
            <> installedProjectName project
            <> "."
            <> stableMigrationKeyText key
        )

-- Composite root brackets --------------------------------------------------------------

{- | Everything the Production bracket established: the the operator-root-and-command-authority phase root authority,
the held project-wide mode, and the recorded unbound lease.
-}
data ProductionRoot projectId brokerGeneration verb = ProductionRoot
    { productionRootAuthority ::
        RootInvocationAuthority (Production projectId) brokerGeneration verb
    , productionRootModeLease :: ProjectModeLease projectId ProductionMode brokerGeneration
    , productionRootUnboundLease :: UnboundRunLease (Production projectId) brokerGeneration
    }

type role ProductionRoot nominal nominal nominal

{- | The composite Production root bracket: it runs the the operator-root-and-command-authority phase verifier
*inside* the protected mode transaction, so no intermediate state is exposed and
a Harness opener cannot interleave.

Production mode is acquired if absent and **retained** if already held by this
project — that is what makes @down@ keep the exclusion — and it is refused when a
harness run holds the mode.
-}
withProductionRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    ( forall (brokerGeneration :: Type).
      ProductionRoot projectId brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withProductionRoot store project verb use = do
    -- The transaction runs under the exclusive entry and then releases it: the
    -- entry protects the mode/lease decision, not the whole lifecycle run.
    prepared <-
        runProtected store $ \session -> do
            withOrdinaryProjectAdmission session project $ do
                operator <- verifyOsPrincipal session
                case operator of
                    Left failure -> pure (Left (ModeAuthorityFailure failure))
                    Right authorized ->
                        withFreshEpoch session project $ \epoch ->
                            withVerifiedRoot
                                ProductionRootScope
                                session
                                project
                                authorized
                                epoch
                                verb
                                $ \root -> do
                                acquired <- acquireProductionMode session project epoch
                                case acquired of
                                    Left failure -> pure (Left failure)
                                    Right modeLease -> do
                                        recorded <-
                                            recordUnboundLease
                                                store
                                                session
                                                project
                                                (ProductionRunIdentity productionRunKey)
                                                epoch
                                        case recorded of
                                            Left failure -> pure (Left failure)
                                            Right unbound ->
                                                pure
                                                    ( Right
                                                        ( SomeProductionRoot
                                                            (ProductionRoot root modeLease unbound)
                                                        )
                                                    )
    case prepared of
        Left failure -> pure (Left failure)
        Right (SomeProductionRoot root) -> use root

{- | A production root whose broker generation index is hidden, so the
transaction that mints it can complete before the continuation runs.
-}
data SomeProductionRoot projectId verb
    = forall brokerGeneration. SomeProductionRoot (ProductionRoot projectId brokerGeneration verb)

{- | Production's lease name. Production has one logical invocation lease per
broker generation rather than a generated run identity.
-}
productionRunKey :: RunKey
productionRunKey = RunKey "production"

{- | Is this the reserved Production invocation lease rather than a harness run?

'withFreshRunId' only ever mints @run-\<hex\>@, so the reserved name cannot collide
with a generated run identity, and the distinction is structural rather than a
naming convention two call sites could disagree about.
-}
isProductionRunKey :: RunKey -> Bool
isProductionRunKey = (== productionRunKey)

-- | Everything the Harness bracket established for one fresh run.
data HarnessRoot projectId runId brokerGeneration verb = HarnessRoot
    { harnessRootAuthority ::
        RootInvocationAuthority (Harness projectId runId) brokerGeneration verb
    , harnessRootHarnessAuthority :: HarnessAuthority projectId runId
    , harnessRootRunId :: RunId runId
    , harnessRootModeLease :: ProjectModeLease projectId (HarnessMode runId) brokerGeneration
    , harnessRootUnboundLease ::
        UnboundRunLease (Harness projectId runId) brokerGeneration
    }

type role HarnessRoot nominal nominal nominal nominal

{- | The composite Harness root bracket.

In order, inside one exclusive entry: recover every abandoned run, re-check the
safety preconditions, and only then compare-and-swap the project-wide mode to
this run.  Because the recheck happens in the same protected entry as the
acquisition, a Production opener cannot slip between the check and ownership.
The generative @runId@ index is bound by the rank-2 continuation, so a value
from one run cannot be presented in another.
-}
withHarnessRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectVerb verb ->
    HarnessPreconditions ->
    ClosedAbandonedHarnessRuns projectId ->
    ( forall (runId :: Type) (brokerGeneration :: Type).
      HarnessRoot projectId runId brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withHarnessRoot store project verb preconditions swept use = do
    prepared <-
        runProtected store $ \session -> do
            withOrdinaryProjectAdmission session project $ do
                operator <- verifyOsPrincipal session
                case operator of
                    Left failure -> pure (Left (ModeAuthorityFailure failure))
                    Right authorized -> do
                        -- Re-run the preconditions inside the same entry that takes
                        -- the mode, so nothing can slip between check and ownership.
                        rechecked <- harnessPreconditionProbe preconditions
                        case rechecked of
                            Left obstacle -> pure (Left (ModeHarnessRefused obstacle))
                            Right () -> do
                                stillSwept <- sweptSetStillEmpty session project swept
                                case stillSwept of
                                    Left failure -> pure (Left failure)
                                    Right () -> do
                                        withFreshRunId $ \run ->
                                            withFreshEpoch session project $ \epoch ->
                                                withVerifiedRoot
                                                    HarnessRootScope
                                                    session
                                                    project
                                                    authorized
                                                    epoch
                                                    verb
                                                    $ \root -> do
                                                    acquired <- acquireHarnessMode session project run epoch
                                                    case acquired of
                                                        Left failure -> pure (Left failure)
                                                        Right modeLease -> do
                                                            recorded <-
                                                                recordUnboundLease
                                                                    store
                                                                    session
                                                                    project
                                                                    (HarnessRunIdentity run)
                                                                    epoch
                                                            case recorded of
                                                                Left failure -> pure (Left failure)
                                                                Right unbound ->
                                                                    pure
                                                                        ( Right
                                                                            ( SomeHarnessRoot
                                                                                ( HarnessRoot
                                                                                    root
                                                                                    (mintHarnessAuthority (runIdText run))
                                                                                    run
                                                                                    modeLease
                                                                                    unbound
                                                                                )
                                                                            )
                                                                        )
    case prepared of
        Left failure -> pure (Left failure)
        Right (SomeHarnessRoot root) -> use root

-- | A harness root whose run and broker generation indices are hidden.
data SomeHarnessRoot projectId verb
    = forall runId brokerGeneration.
        SomeHarnessRoot (HarnessRoot projectId runId brokerGeneration verb)

-- Harness safety preconditions ----------------------------------------------------------

{- | The two hard safety preconditions, derived from installed project identity
rather than supplied by a caller: a sibling production config must not exist, and
a production cluster must not be running. The probe is held privately so a
caller cannot inject a successful observation.
-}
newtype HarnessPreconditions = HarnessPreconditions
    {harnessPreconditionProbe :: IO (Either HarnessPreconditionFailure ())}

data HarnessPreconditionFailure
    = ProductionConfigPresent FilePath
    | ProductionClusterRunning
    deriving (Eq, Show)

{- | Build the precondition verifier. The sibling-config half is derived here
from the installed project identity and the directory the binary sits in, so a
caller cannot claim a config is absent; the project supplies only its own
cluster-liveness probe, which core cannot know how to perform.
-}
harnessPreconditions ::
    InstalledProjectIdentity projectId ->
    -- | the directory a sibling production config would occupy
    FilePath ->
    -- | the project's production-cluster liveness probe
    IO Bool ->
    HarnessPreconditions
harnessPreconditions project directory productionClusterRunning =
    HarnessPreconditions $ do
        let configPath = directory </> Text.unpack (installedProjectName project) <.> "dhall"
        present <- doesFileExist configPath
        if present
            then pure (Left (ProductionConfigPresent configPath))
            else do
                running <- productionClusterRunning
                pure (if running then Left ProductionClusterRunning else Right ())

-- Closure -------------------------------------------------------------------------------

{- | Proof that a project reached a closable state. Only the two verifiers below
mint one, and each records which closed way it was reached.
-}
data ProjectClosureEvidence scope
    = ProjectClosureEvidence ProductionCloseKind

type role ProjectClosureEvidence nominal

instance Show (ProjectClosureEvidence scope) where
    show (ProjectClosureEvidence kind) = "ProjectClosureEvidence " <> show kind

projectClosureEvidenceKind :: ProjectClosureEvidence scope -> ProductionCloseKind
projectClosureEvidenceKind (ProjectClosureEvidence kind) = kind

{- | The true-pre-effect verifier: the unbound run's records must contain no
effect of any shape and no same-run acquisition row. A single matching key
refuses without decoding its payload, so partial @up@/@down@ work or impossible
acquisition ownership under an unbound lease cannot be relabelled as a refusal
that preceded acquisition.
-}
verifyNoProjectResourcesAcquired ::
    UnboundRunLease scope brokerGeneration ->
    IO (Either ModeError (ProjectClosureEvidence scope))
verifyNoProjectResourcesAcquired unbound =
    verifyLeaseLocationHasNoUnboundOwnership
        (unboundRunLeaseLocation unbound)
        (runIdentityKey (unboundRunLeaseIdentity unbound))

{- | The corresponding no-effect verifier for a lease that was already bound
before recovery. It is separate from the unbound producer so neither lease
state can be substituted for the other at call sites.
-}
verifyBoundRunHasNoProjectResourcesAcquired ::
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    IO (Either ModeError (ProjectClosureEvidence scope))
verifyBoundRunHasNoProjectResourcesAcquired bound =
    verifyLeaseLocationHasNoEffects
        (boundRunLeaseLocation bound)
        (runIdentityKey (boundRunLeaseIdentity bound))

verifyLeaseLocationHasNoUnboundOwnership ::
    LeaseLocation ->
    RunKey ->
    IO (Either ModeError (ProjectClosureEvidence scope))
verifyLeaseLocationHasNoUnboundOwnership =
    verifyLeaseLocationHasNoRecords isUnboundOwnershipKeyForLease

verifyLeaseLocationHasNoEffects ::
    LeaseLocation ->
    RunKey ->
    IO (Either ModeError (ProjectClosureEvidence scope))
verifyLeaseLocationHasNoEffects =
    verifyLeaseLocationHasNoRecords isEffectKeyForLease

verifyLeaseLocationHasNoRecords ::
    (LeaseLocation -> RunKey -> RecordKey -> Bool) ->
    LeaseLocation ->
    RunKey ->
    IO (Either ModeError (ProjectClosureEvidence scope))
verifyLeaseLocationHasNoRecords isOwned location runKey = do
    entered <-
        withProtectedEntry (leaseLocationStore location) $ \session -> do
            checked <- withOrdinaryProjectAdmissionForName session (leaseLocationProjectName location) $ do
                keys <- listProtectedRecords session
                pure $ case keys of
                    Left failure -> Left (ModeStoreFailure failure)
                    Right present -> case filter (isOwned location runKey) present of
                        [] -> Right (ProjectClosureEvidence PreEffectRefusalClose)
                        record : _ -> Left (ModeEffectsRecorded (recordKeyText record))
            pure (Right checked)
    pure $ case entered of
        Left failure -> Left (ModeStoreFailure failure)
        Right result -> result

isUnboundOwnershipKeyForLease :: LeaseLocation -> RunKey -> RecordKey -> Bool
isUnboundOwnershipKeyForLease location run key =
    isEffectKeyForLease location run key || isAcquisitionKeyForLease location run key

isEffectKeyForLease :: LeaseLocation -> RunKey -> RecordKey -> Bool
isEffectKeyForLease location =
    hasRunRecordPrefix "effect." (leaseLocationProjectName location)

isAcquisitionKeyForLease :: LeaseLocation -> RunKey -> RecordKey -> Bool
isAcquisitionKeyForLease location =
    hasRunRecordPrefix "acquisition." (leaseLocationProjectName location)

{- | The settled-destroy half of 'ProjectClosureEvidence' (the recursive-lifecycle-command phase).

'verifyNoProjectResourcesAcquired' has always been the only producer, which
meant the @SettledDestroyClose@ branch had none: a Production project could be
closed after a true pre-effect refusal but never after an actual @destroy@.
This is that missing producer, and it is deliberately not a verifier of its own
— it is a **conversion**, and it accepts only proofs the two owning modules
already minted:

* @HostBootstrap.Teardown.verifySubtreeSettled@ proves the exact frame-bound
  forest completed with its ordered terminal observations, and
  @HostBootstrap.Teardown.verifyDestroySettled@ promotes it only after the
  exact plan/current-frame package proves it is the unique-root destroy;
* 'verifyAllSessionsClosed' proves the independently enumerated session set is
  complete and every member Closed, including a zero-operation Open session.

Both are compared against the bound lease's own plan digest, because the phantom
indices alone would let a proof taken over one plan be presented for another.
-}
destroySettledClosure ::
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    VerifiedAllSessionsClosed scope planId ->
    DestroySettled scope planId ->
    Either ModeError (ProjectClosureEvidence scope)
destroySettledClosure lease sessions settled
    | allSessionsClosedPlanDigest sessions /= bound =
        Left (ModeSnapshotMismatch bound (allSessionsClosedPlanDigest sessions))
    | destroySettledPlanDigest settled /= bound =
        Left (ModeSnapshotMismatch bound (destroySettledPlanDigest settled))
    | otherwise = Right (ProjectClosureEvidence SettledDestroyClose)
  where
    bound = boundRunLeasePlanDigest lease

{- | Exact-version proof that an unbound lease recorded neither an effect nor a
plan-bound acquisition. The sweep cannot close an unbound lease without it.

The acquisition check is key-shaped deliberately: once a same-run
@acquisition.<project>.<run>.@ row exists, even a malformed payload or unknown
epoch is durable evidence that acquisition started and must not be swept as a
pre-effect refusal. Such ownership is impossible in the valid unbound flow but
must be treated conservatively if found. The historical
@VerifiedUnboundLeaseHasNoEffects@ name is retained for API continuity; its
proof now also means "no same-run acquisition row".
-}
data VerifiedUnboundLeaseHasNoEffects projectId
    = VerifiedUnboundLeaseHasNoEffects RunKey

type role VerifiedUnboundLeaseHasNoEffects nominal

instance Show (VerifiedUnboundLeaseHasNoEffects projectId) where
    show (VerifiedUnboundLeaseHasNoEffects run) =
        "VerifiedUnboundLeaseHasNoEffects " <> show (runKeyText run)

{- | Mint the historical no-effects proof only when neither effect-shaped nor
same-run acquisition-shaped ownership exists for the exact Harness run.

Acquisition payload and epoch validity are irrelevant here: any matching key is
impossible unbound ownership evidence and refuses the proof.
-}
verifyUnboundLeaseHasNoEffects ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    IO (Either ModeError (VerifiedUnboundLeaseHasNoEffects projectId))
verifyUnboundLeaseHasNoEffects session project run = do
    verifyUnboundLeaseHasNoEffectsForKey
        session
        project
        (runIdentityKey (HarnessRunIdentity run))

verifyUnboundLeaseHasNoEffectsForKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    IO (Either ModeError (VerifiedUnboundLeaseHasNoEffects projectId))
verifyUnboundLeaseHasNoEffectsForKey session project run = do
    withOrdinaryProjectAdmission session project $ do
        owned <- unboundOwnershipRecordsFor session project run
        pure $ case owned of
            Left failure -> Left failure
            Right [] -> Right (VerifiedUnboundLeaseHasNoEffects run)
            Right (record : _) -> Left (ModeEffectsRecorded (recordKeyText record))

{- | Release Production mode. This is the only path, and it requires both the
root/verb side (a settled @destroy@ root, or any Production verb on the
true-pre-effect branch) and the matching closure evidence. The two must agree:
a settled-destroy root cannot be paired with pre-effect evidence.
-}
releaseProductionMode ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ProductionCloseRoot (Production projectId) brokerGeneration ->
    ProjectClosureEvidence (Production projectId) ->
    IO (Either ModeError ())
releaseProductionMode session project root evidence
    | productionCloseRootVerb root == SettledDestroyClose
        && projectClosureEvidenceKind evidence /= SettledDestroyClose =
        pure (Left (ModeClosureMismatch "settled destroy" "pre-effect refusal"))
    | productionCloseRootVerb root == PreEffectRefusalClose
        && projectClosureEvidenceKind evidence /= PreEffectRefusalClose =
        pure (Left (ModeClosureMismatch "pre-effect refusal" "settled destroy"))
    | otherwise = do
        closed <- closeLeaseForKey session project productionRunKey
        case closed of
            Left failure -> pure (Left failure)
            Right () -> releaseMode session project WireProduction

-- Production invocation close ------------------------------------------------------

{- | Proof that one ordinary Production @up@\/@down@ invocation finished: every
session for the plan was observed Closed at one store version.

This is *not* project closure. It ends an invocation while the project keeps its
mode, its resources, and its Open journal — which is exactly what makes
@down@ retain Production mode (§ Y). Only `ProjectDestroy` or a verified
true-pre-effect refusal can release the mode, and neither goes through here.
-}
data ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration
    = ProductionInvocationCompleted
        (BoundRunLease (Production projectId) specDigest planDigest brokerGeneration)
        Int

type role ProductionInvocationCompleted nominal nominal nominal nominal

instance Show (ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration) where
    show (ProductionInvocationCompleted run sessions) =
        "ProductionInvocationCompleted " <> show run <> " " <> show sessions

productionInvocationCompletedRun ::
    ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration -> Text
productionInvocationCompletedRun (ProductionInvocationCompleted bound _) =
    boundRunLeaseRunText bound

{- | Mint the completion proof from the bound lease and the independently derived
complete-session set. The session proof is the load-bearing argument: it is
produced by enumerating every session record for the plan, so an invocation
cannot be declared complete while a zero-operation session it opened is still
Open.
-}
completeProductionInvocation ::
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedAllSessionsClosed (Production projectId) planId ->
    Either
        ModeError
        (ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration)
completeProductionInvocation bound closed
    -- The proof must have been taken over THIS plan: phantom indices alone
    -- would admit a proof from another plan's journal.
    | allSessionsClosedPlanDigest closed /= boundRunLeasePlanDigest bound =
        Left
            ( ModeSnapshotMismatch
                (boundRunLeasePlanDigest bound)
                (allSessionsClosedPlanDigest closed)
            )
    | otherwise =
        Right
            ( ProductionInvocationCompleted
                bound
                (allSessionsClosedCount closed)
            )

{- | Proof that the invocation\'s lease is closed while the project remains open.
Deliberately carries no lease, admission, or permit: this value authorizes
nothing further.
-}
data ProductionInvocationClosed projectId specDigest planDigest brokerGeneration
    = ProductionInvocationClosed RunKey

type role ProductionInvocationClosed nominal nominal nominal nominal

instance Show (ProductionInvocationClosed projectId specDigest planDigest brokerGeneration) where
    show (ProductionInvocationClosed run) = "ProductionInvocationClosed " <> show run

productionInvocationClosedRun ::
    ProductionInvocationClosed projectId specDigest planDigest brokerGeneration -> Text
productionInvocationClosedRun (ProductionInvocationClosed run) = runKeyText run

{- | The outcome of the close transaction. An uncertain acknowledgment is its own
constructor, not an error: the close may in fact have committed, so the only
sound continuation is to resume the same stable key rather than retry blindly.
-}
data ProductionInvocationClose projectId specDigest planDigest brokerGeneration
    = ProductionInvocationCloseCommitted
        (ProductionInvocationClosed projectId specDigest planDigest brokerGeneration)
    | ProductionInvocationCloseUnknown InvocationCloseKey
    deriving (Show)

type role ProductionInvocationClose nominal nominal nominal nominal

{- | Close a completed ordinary Production invocation.

The order is what makes a crash recoverable: the terminal acknowledgment is
recorded under a stable close key /before/ the lease is closed, so an
interruption between the two leaves evidence bound recovery can classify (it
reaches 'ProductionTerminalAcknowledgment' and resumes this same key) instead of
an ambiguous half-closed lease.

It revalidates that Production mode is still held under the same broker
generation, and it does **not** release the mode, mark the project closed, or
release any resource.
-}
closeCompletedProductionInvocation ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration ->
    InvocationCloseKey ->
    IO
        ( Either
            ModeError
            (ProductionInvocationClose projectId specDigest planDigest brokerGeneration)
        )
closeCompletedProductionInvocation session project modeLease completed key
    | brokerEpochWord (projectModeLeaseEpoch modeLease)
        /= brokerEpochWord (boundRunLeaseEpoch bound) =
        pure
            ( Left
                ( ModeEpochMismatch
                    (brokerEpochWord (boundRunLeaseEpoch bound))
                    (brokerEpochWord (projectModeLeaseEpoch modeLease))
                )
            )
    | otherwise = do
        held <- currentMode session project
        case held of
            Left failure -> pure (Left failure)
            Right (Just WireProduction) -> do
                acknowledged <-
                    recordProductionInvocationAcknowledgment session project bound key
                case acknowledged of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        closed <- closeLeaseForKey session project run
                        pure $ case closed of
                            -- The acknowledgment is durable, so an uncertain
                            -- lease close resumes this exact key.
                            Left _ -> Right (ProductionInvocationCloseUnknown key)
                            Right () ->
                                Right
                                    ( ProductionInvocationCloseCommitted
                                        (ProductionInvocationClosed run)
                                    )
            Right observed ->
                pure
                    ( Left
                        ( ModeHeldByAnother
                            (maybe "none" modeWireName observed)
                            "production"
                        )
                    )
  where
    ProductionInvocationCompleted bound _ = completed
    run = runIdentityKey (boundRunLeaseIdentity bound)

-- Harness terminal close -----------------------------------------------------------

{- | Which of the two ways a harness close root was reached.

Both authorize the same close, but they are not the same evidence, so the origin
is retained rather than erased: it travels onto the close authorization, so a
report or an operator message can say whether a close belongs to the run that is
still executing or to a recovery that reopened an abandoned one.
-}
data HarnessCloseOrigin
    = -- | The live run\'s own root authority is closing it.
      LiveHarnessClose
    | {- | The sweep reopened an abandoned run through 'withAbandonedHarnessRun'
      and recovery is closing it under a fresh broker generation.
      -}
      RecoveredHarnessClose
    deriving (Eq, Show)

{- | The root\/verb half of harness terminal close — the Harness counterpart of
"HostBootstrap.Authority"\'s 'Authority.ProductionCloseRoot'.

Closing a harness run used to need only the mode lease, the bound lease and the
session proof. All three are reachable from the live run, so there was no value
that distinguished "the live root is closing itself" from "recovery is closing an
abandoned run", and § EE\'s requirement that the close root be /derived from the
live root or abandoned-run recovery authority/ had no representation at all: any
holder of a run identity could close it.

The constructor is private and there are exactly two producers, so a third
cannot be written: 'currentHarnessCloseRoot' consumes a live 'HarnessRoot', and
'withAbandonedHarnessRun' mints the recovered one. The @runId@ index is
generative, so a close root minted for one run cannot be presented for another
even when the run names coincide.
-}
data HarnessCloseRoot projectId runId brokerGeneration
    = HarnessCloseRoot
        HarnessCloseOrigin
        (RunId runId)
        Text
        (BrokerEpoch brokerGeneration)

type role HarnessCloseRoot nominal nominal nominal

instance Show (HarnessCloseRoot projectId runId brokerGeneration) where
    show (HarnessCloseRoot origin run project epoch) =
        "HarnessCloseRoot "
            <> show origin
            <> " "
            <> show run
            <> " "
            <> show project
            <> " "
            <> show epoch

harnessCloseRootRun :: HarnessCloseRoot projectId runId brokerGeneration -> RunId runId
harnessCloseRootRun (HarnessCloseRoot _ run _ _) = run

harnessCloseRootOrigin :: HarnessCloseRoot projectId runId brokerGeneration -> HarnessCloseOrigin
harnessCloseRootOrigin (HarnessCloseRoot origin _ _ _) = origin

{- | The live producer: the run that is still executing closes itself. Every
field is read off the root\'s own verified authority, so the project name, run,
and broker generation cannot be supplied independently of it.
-}
currentHarnessCloseRoot ::
    HarnessRoot projectId runId brokerGeneration verb ->
    HarnessCloseRoot projectId runId brokerGeneration
currentHarnessCloseRoot root =
    HarnessCloseRoot
        LiveHarnessClose
        (harnessRootRunId root)
        (rootAuthorityProjectName authority)
        (rootAuthorityEpoch authority)
  where
    authority = harnessRootAuthority root

{- | Authorization to run one harness run\'s terminal close projection, carrying
the fresh Closing epoch the project journal was moved to.

Its constructor is private and it is minted only after every session was proved
Closed, so a close cannot be authorized while operations are outstanding.
-}
data HarnessCloseAuthorization projectId runId
    = HarnessCloseAuthorization HarnessCloseOrigin (RunId runId) Word64

type role HarnessCloseAuthorization nominal nominal

instance Show (HarnessCloseAuthorization projectId runId) where
    show (HarnessCloseAuthorization origin run epoch) =
        "HarnessCloseAuthorization " <> show origin <> " " <> show run <> " " <> show epoch

harnessCloseRun :: HarnessCloseAuthorization projectId runId -> RunId runId
harnessCloseRun (HarnessCloseAuthorization _ run _) = run

harnessCloseEpoch :: HarnessCloseAuthorization projectId runId -> Word64
harnessCloseEpoch (HarnessCloseAuthorization _ _ epoch) = epoch

-- | Which way the close that this authorization ends was reached.
harnessCloseOrigin :: HarnessCloseAuthorization projectId runId -> HarnessCloseOrigin
harnessCloseOrigin (HarnessCloseAuthorization origin _ _) = origin

{- | Authorize terminal close for one harness run.

It requires the close root — the live run\'s or recovery\'s, and nothing a caller
can build — the exact Harness mode lease for this run, the bound lease, the
complete-session proof, and settled-destroy closure evidence for this exact
Harness scope. A true-pre-effect proof is deliberately rejected: only after
ordinary destroy has settled may this function persist the Closing epoch, so
recovery can finish terminal cleanup without abandoning live project resources.
Moving the project journal itself to @ClosingProject@ is
"HostBootstrap.Lifecycle.Session"\'s 'Session.beginClosingProject', which
contends on the same version session-opening advances.

The close root is checked against the bound lease and the mode lease rather than
trusted: the shared @runId@ and @brokerGeneration@ indices already rule out most
substitutions, but a root and a lease can still be minted for two /different/
projects under the same indices, and the epochs can disagree when a caller
retains a root across a generation boundary.
-}
authorizeHarnessClose ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId (HarnessMode runId) brokerGeneration ->
    BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration ->
    VerifiedAllSessionsClosed (Harness projectId runId) planId ->
    ProjectClosureEvidence (Harness projectId runId) ->
    -- | the fresh closing epoch; must be positive
    Word64 ->
    IO (Either ModeError (HarnessCloseAuthorization projectId runId))
authorizeHarnessClose session project closeRoot modeLease bound closed closure epoch
    | epoch == 0 =
        pure (Left (ModeInvalidIdentity "a closing epoch must be positive"))
    | otherwise = case checkHarnessCloseRoot project closeRoot modeLease run of
        Left failure -> pure (Left failure)
        Right ()
            | allSessionsClosedPlanDigest closed /= boundRunLeasePlanDigest bound ->
                pure
                    ( Left
                        ( ModeSnapshotMismatch
                            (boundRunLeasePlanDigest bound)
                            (allSessionsClosedPlanDigest closed)
                        )
                    )
            | projectClosureEvidenceKind closure /= SettledDestroyClose ->
                pure (Left (ModeClosureMismatch "settled destroy" "pre-effect refusal"))
            | otherwise -> do
                recorded <- recordHarnessClosingEpoch session project run epoch
                pure
                    ( fmap
                        (const (HarnessCloseAuthorization origin run epoch))
                        recorded
                    )
  where
    run = harnessBoundRunId bound
    origin = harnessCloseRootOrigin closeRoot

{- | The checks shared by every consumer of a 'HarnessCloseRoot': the root must
name this project, this exact run, and the same broker generation the held mode
lease does, and the mode must actually be this run\'s Harness mode.
-}
checkHarnessCloseRoot ::
    InstalledProjectIdentity projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId (HarnessMode runId) brokerGeneration ->
    RunId runId ->
    Either ModeError ()
checkHarnessCloseRoot project (HarnessCloseRoot _ rootRun rootProject rootEpoch) modeLease run
    | rootProject /= installedProjectName project =
        Left (ModeClosureMismatch (installedProjectName project) rootProject)
    | runIdentityKey (HarnessRunIdentity rootRun)
        /= runIdentityKey (HarnessRunIdentity run) =
        Left
            ( ModeClosureMismatch
                ("harness:" <> runIdText run)
                ("harness:" <> runIdText rootRun)
            )
    | brokerEpochWord rootEpoch /= brokerEpochWord (projectModeLeaseEpoch modeLease) =
        Left
            ( ModeEpochMismatch
                (brokerEpochWord (projectModeLeaseEpoch modeLease))
                (brokerEpochWord rootEpoch)
            )
    | mode /= WireHarness (runIdentityKey (HarnessRunIdentity run)) =
        Left
            ( ModeWrongMode
                ("harness:" <> runIdText run)
                (modeWireName mode)
            )
    | otherwise = Right ()
  where
    ProjectModeLease mode _ _ _ = modeLease

{- | Resume a close that was already authorized and never finished.

'authorizeHarnessClose' consumes settled-destroy evidence and then persists the
Closing epoch **before** terminal finalization, exactly so a crash between those
two operations is resumable rather than indistinguishable from a live run. This
is that resumption, and it is the only route to a 'HarnessCloseAuthorization'
that does not persist a new epoch.

It cannot invent a close. The durable disposition is re-read inside the caller's
entry and must be exactly the @Closing@ epoch the recovery classification
observed; an Open or acknowledged record — a run that never reached its close —
is refused. It also needs no fresh 'VerifiedAllSessionsClosed': the close it
resumes already consumed one, and manufacturing a second proof for a dead run's
sessions is precisely what recovery must not do.

The close root is the recovery's, so what finishes the close is the reopening's
own authority under its fresh broker generation.
-}
resumeHarnessClose ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId (HarnessMode runId) brokerGeneration ->
    BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration ->
    -- | the epoch the abandoned run persisted; must be positive
    Word64 ->
    IO (Either ModeError (HarnessCloseAuthorization projectId runId))
resumeHarnessClose session project closeRoot modeLease bound epoch
    | epoch == 0 =
        pure (Left (ModeInvalidIdentity "a closing epoch must be positive"))
    | otherwise = case checkHarnessCloseRoot project closeRoot modeLease run of
        Left failure -> pure (Left failure)
        Right () -> do
            recorded <-
                readInvocationDispositionForKey
                    session
                    project
                    (runIdentityKey (HarnessRunIdentity run))
            pure $ case recorded of
                Left failure -> Left failure
                Right (InvocationClosing persisted)
                    | persisted == epoch ->
                        Right (HarnessCloseAuthorization origin run epoch)
                    | otherwise -> Left (ModeEpochMismatch persisted epoch)
                Right InvocationOpen ->
                    Left (ModeRecoveryRequired (runIdText run <> " has no persisted close to resume"))
                Right (InvocationAcknowledged key) ->
                    Left
                        ( ModeClosureMismatch
                            ("harness closing epoch " <> Text.pack (show epoch))
                            ("production acknowledgment " <> invocationCloseKeyText key)
                        )
  where
    run = harnessBoundRunId bound
    origin = harnessCloseRootOrigin closeRoot

{- | Proof that a harness run reached terminal @ClosedProject@ and gave its mode
back.
-}
data ClosedHarnessProject projectId runId = ClosedHarnessProject (RunId runId)

type role ClosedHarnessProject nominal nominal

instance Show (ClosedHarnessProject projectId runId) where
    show (ClosedHarnessProject run) = "ClosedHarnessProject " <> show run

closedHarnessProjectRun :: ClosedHarnessProject projectId runId -> RunId runId
closedHarnessProjectRun (ClosedHarnessProject run) = run

{- | The terminal finalizer: close the run\'s lease, then release the exact
Harness mode epoch **last**.

Mode is never released before the lease, so a crash between the two leaves the
mode held and the run recoverable rather than the mode cleared with work
outstanding (§ Y).
-}
finalizeHarnessClose ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    HarnessCloseAuthorization projectId runId ->
    IO (Either ModeError (ClosedHarnessProject projectId runId))
finalizeHarnessClose session project authorization = do
    closed <- closeLeaseForKey session project runKey
    case closed of
        Left failure -> pure (Left failure)
        Right () -> do
            released <- releaseMode session project (WireHarness runKey)
            pure (fmap (const (ClosedHarnessProject run)) released)
  where
    run = harnessCloseRun authorization
    runKey = runIdentityKey (HarnessRunIdentity run)

{- | Terminal harness close for a run that provably acquired nothing: record the
run\'s lease Closed, then release the exact Harness mode epoch last. Mode is never
released before the lease, so a crash between the two leaves the mode held and
the run recoverable rather than the mode cleared with work outstanding.

This is the __short__ close, and it is deliberately restricted to the
'PreEffectRefusalClose' branch of 'ProjectClosureEvidence'. A settled destroy
released real resources, so its close has to persist a Closing epoch before the
terminal projection runs and resume it after a crash — that is
'authorizeHarnessClose' followed by 'finalizeHarnessClose', and routing settled
evidence through here would skip the epoch entirely and leave a half-finished
close indistinguishable from a live run. The evidence argument was previously
ignored, so nothing enforced that.

Both halves of the close root pair are required rather than a bare 'RunId': the
run identity is read off the close root, so a caller cannot close a run it holds
no close authority for.
-}
closeHarnessRun ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId (HarnessMode runId) brokerGeneration ->
    ProjectClosureEvidence (Harness projectId runId) ->
    IO (Either ModeError ())
closeHarnessRun session project closeRoot modeLease evidence =
    case checkHarnessCloseRoot project closeRoot modeLease run of
        Left failure -> pure (Left failure)
        Right () -> case projectClosureEvidenceKind evidence of
            SettledDestroyClose ->
                pure (Left (ModeClosureMismatch "pre-effect refusal" "settled destroy"))
            PreEffectRefusalClose -> do
                closed <- closeLeaseForKey session project runKey
                case closed of
                    Left failure -> pure (Left failure)
                    Right () -> releaseMode session project (WireHarness runKey)
  where
    run = harnessCloseRootRun closeRoot
    runKey = runIdentityKey (HarnessRunIdentity run)

-- Abandoned-run recovery -------------------------------------------------------------------

data IncompleteLeaseKind
    = -- | Recorded before any plan snapshot existed.
      IncompleteUnbound
    | -- | Bound to a plan snapshot; its spec and plan digests are recorded.
      IncompleteBound Text Text
    deriving (Eq, Show)

{- | An abandoned lease the sweep observed at one store version. Its constructor
is private: a caller cannot manufacture a run to skip.
-}
data VerifiedIncompleteRunLease projectId
    = VerifiedIncompleteRunLease RunKey IncompleteLeaseKind

type role VerifiedIncompleteRunLease nominal

instance Show (VerifiedIncompleteRunLease projectId) where
    show (VerifiedIncompleteRunLease run kind) =
        "VerifiedIncompleteRunLease " <> show (runKeyText run) <> " " <> show kind

incompleteRunLeaseRunText :: VerifiedIncompleteRunLease projectId -> Text
incompleteRunLeaseRunText (VerifiedIncompleteRunLease run _) = runKeyText run

incompleteRunLeaseRunKey :: VerifiedIncompleteRunLease projectId -> RunKey
incompleteRunLeaseRunKey (VerifiedIncompleteRunLease run _) = run

incompleteRunLeaseKind :: VerifiedIncompleteRunLease projectId -> IncompleteLeaseKind
incompleteRunLeaseKind (VerifiedIncompleteRunLease _ kind) = kind

{- | Proof that the sweep observed an empty incomplete-lease set. 'withHarnessRoot'
consumes it and re-verifies emptiness inside its own entry, so racing the sweep
cannot bypass unresolved ownership.
-}
data ClosedAbandonedHarnessRuns projectId
    = ClosedAbandonedHarnessRuns Int

type role ClosedAbandonedHarnessRuns nominal

instance Show (ClosedAbandonedHarnessRuns projectId) where
    show (ClosedAbandonedHarnessRuns closed) =
        "ClosedAbandonedHarnessRuns " <> show closed

closedAbandonedHarnessRunsCount :: ClosedAbandonedHarnessRuns projectId -> Int
closedAbandonedHarnessRunsCount (ClosedAbandonedHarnessRuns closed) = closed

{- | Enumerate every incomplete lease at one store version and settle it.

Both kinds reach a fold callback, because both can own durable state. An
unbound member's callback runs /before/ the sweep closes its lease, so whatever
that run acquired outside the lease — its @.test_data@ generation, for instance
— is reclaimed while the run is still identifiable; only then is the lease
closed, and only behind 'verifyUnboundLeaseHasNoEffects'. A bound member is
handed to its own callback, which must resolve it. The sweep then re-reads the
leases and refuses to finish while any is still incomplete, so neither callback
can return a no-op success. Only an empty final set mints
'ClosedAbandonedHarnessRuns'.
-}
recoverAbandonedHarnessRuns ::
    forall projectId.
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    -- | reclaim an unbound run's owned state, before its lease is closed
    ( VerifiedIncompleteRunLease projectId ->
      IO (Either ModeError ())
    ) ->
    -- | resolve a bound run, which may own real lifecycle resources
    ( VerifiedIncompleteRunLease projectId ->
      IO (Either ModeError ())
    ) ->
    IO (Either ModeError (ClosedAbandonedHarnessRuns projectId))
recoverAbandonedHarnessRuns store project reclaimUnbound resolveBound = do
    observed <- runProtected store (\session -> abandonedHarnessLeases session project)
    case observed of
        Left failure -> pure (Left failure)
        Right leases -> do
            settled <- traverseEither settleOne leases
            case settled of
                Left failure -> pure (Left failure)
                Right () -> do
                    -- Recheck after the callbacks: a fold that resolved nothing
                    -- cannot report a vacuous success.
                    remaining <- runProtected store (\session -> abandonedHarnessLeases session project)
                    case remaining of
                        Left failure -> pure (Left failure)
                        Right [] -> pure (Right (ClosedAbandonedHarnessRuns (length leases)))
                        Right (unresolved : _) ->
                            pure
                                ( Left
                                    ( ModeRecoveryRequired
                                        (incompleteRunLeaseRunText unresolved)
                                    )
                                )
  where
    settleOne :: VerifiedIncompleteRunLease projectId -> IO (Either ModeError ())
    settleOne lease = case incompleteRunLeaseKind lease of
        IncompleteUnbound -> do
            reclaimed <- reclaimUnbound lease
            case reclaimed of
                Left failure -> pure (Left failure)
                Right () -> runProtected store $ \session -> do
                    proof <-
                        verifyUnboundLeaseHasNoEffectsForKey
                            session
                            project
                            (incompleteRunLeaseRunKey lease)
                    case proof of
                        Left failure -> pure (Left failure)
                        Right _ -> do
                            closed <-
                                closeLeaseForKey
                                    session
                                    project
                                    (incompleteRunLeaseRunKey lease)
                            case closed of
                                Left failure -> pure (Left failure)
                                Right () ->
                                    releaseModeIfRunKey
                                        session
                                        project
                                        (incompleteRunLeaseRunKey lease)
        IncompleteBound _ _ -> resolveBound lease

-- Reopening an abandoned bound run ----------------------------------------------------------

{- | Everything reopening one abandoned __bound__ harness run establishes.

Read the field list as the boundary, because it is the whole of what recovery
gets. There is no 'HarnessAuthority', no fresh 'LifecycleProfile', no
'UnboundRunLease' to bind to a different snapshot, and the root authority is
@VerbDestroy@ — never @VerbUp@. So a reopened run can settle what its
predecessor left behind and nothing else: it cannot mint a normal config, start
new lifecycle work, or hand harness planning authority to a project.

The four indices are all generative and shared across the fields, so the
snapshot, the lease, the destroy root and the close root are pinned to /this/
reopening: none of them can be mixed with a value from the live run or from a
second reopening.
-}
data AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration
    = AbandonedHarnessRun
    { abandonedHarnessRunId :: RunId oldRunId
    -- ^ the abandoned run this reopening belongs to
    , abandonedHarnessSnapshot ::
        VerifiedPlanSnapshot (Harness projectId oldRunId) specDigest planDigest
    -- ^ the exact plan snapshot the old lease was bound to, read back durably
    , abandonedHarnessBoundLease ::
        BoundRunLease (Harness projectId oldRunId) specDigest planDigest brokerGeneration
    -- ^ the /already-bound/ lease, retained on the fresh broker generation
    , abandonedHarnessModeLease ::
        ProjectModeLease projectId (HarnessMode oldRunId) brokerGeneration
    -- ^ the old run's own project-wide Harness mode, likewise retained
    , abandonedHarnessDestroyRoot ::
        RootInvocationAuthority (Harness projectId oldRunId) brokerGeneration VerbDestroy
    -- ^ recovery's only root authority: @destroy@, so it can release and not acquire
    , abandonedHarnessRecovery :: HarnessBoundRecovery projectId oldRunId
    -- ^ the exhaustive first branch: a persisted Closing epoch, or Open revision recovery
    , abandonedHarnessCloseRoot :: HarnessCloseRoot projectId oldRunId brokerGeneration
    -- ^ the narrow close authority, marked 'RecoveredHarnessClose'
    , abandonedHarnessBroker :: BrokerEpoch brokerGeneration
    -- ^ the fresh authority broker every retained record was rebound onto
    , abandonedHarnessFencedPermits ::
        OldPermitsFenced (Harness projectId oldRunId) planId
    -- ^ the exact set of old permits this reopening superseded
    , abandonedHarnessManifest ::
        VerifiedSessionManifest (Harness projectId oldRunId) planId
    -- ^ the paired complete session and operation sets
    , abandonedHarnessInterpretation ::
        InterpretedRecovery (Harness projectId oldRunId) planId
    -- ^ what the recorded-session interpreter did to each of them
    , abandonedHarnessAdmission ::
        CurrentBrokerSessionAdmission (Harness projectId oldRunId) planId brokerGeneration
    -- ^ the admission only both complete sets can mint
    }

type role AbandonedHarnessRun nominal nominal nominal nominal nominal nominal

{- | A reopening whose generative indices are hidden, so the protected
transaction that mints it can complete before the continuation runs.
-}
data SomeAbandonedHarnessRun projectId
    = forall oldRunId specDigest planDigest planId brokerGeneration.
        SomeAbandonedHarnessRun
            (AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration)

{- | Reopen one abandoned __bound__ harness run under a fresh broker generation.

This is the opener the sweep's bound-lease callback needs. Before it existed, a
bound abandoned run could be classified ('classifyAbandonedBoundRun') and the one
provably-nothing-acquired branch could be closed, but the close went through a
bare 'RunId' — so every other branch could only be /named/ in a refusal string,
and even the branch that did resolve carried no authority saying who was allowed
to resolve it.

Every step is ordered so a crash leaves the store no worse than it found it:

1. the lease must still be recorded @bound@ to the same two digests the sweep
   observed. The sweep read it at an earlier store version, so this is a
   recheck, not a repetition — a lease that closed or was rebound in between is
   refused rather than reopened;
2. the persisted plan snapshot is read back and its digests must equal the
   lease's. That is what makes the yielded snapshot /the old run's/ rather than
   whatever is currently persisted, so a substituted snapshot cannot be presented
   as this run's;
3. the durable invocation record is classified __before__ any authority is
   minted, so the exhaustive Closing-versus-Open branch is decided from the dead
   run's own state;
4. a fresh broker generation is allocated and the @destroy@ root verified under
   it. Recovery never resumes the old generation: the old generation's tokens,
   permits and admissions must all be fenced out, and reusing its epoch would
   make a delayed one from the dead run indistinguishable from a live one;
5. the old run's Harness mode and bound lease are retained onto that fresh
   generation. Neither identity changes — same mode, same run, same snapshot
   digests — only the generation they are recorded under.

Retaining is not inert, and it is worth being explicit about: a reopening that
then refuses (a persisted Closing epoch, either migration branch) leaves the mode
and lease recorded under the new generation. Nothing reads a retained record's
generation to resume — 'bindRunLease' compares generations only for an /unbound/
lease, 'releaseMode' compares the mode alone, and a close journal is keyed by its
Closing epoch — so a second reopening reads exactly the same state and reaches
exactly the same branch. The records that must not change across a reopening are
the snapshot and the invocation disposition, and this opener writes neither.

The continuation runs /outside/ the protected entry, exactly as
'withHarnessRoot''s does, because resolving a run needs many further protected
transactions.
-}
withAbandonedHarnessRun ::
    forall projectId result.
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    -- | the bound lease the sweep minted; an unbound one is refused
    VerifiedIncompleteRunLease projectId ->
    ( forall
        (oldRunId :: Type)
        (specDigest :: Type)
        (planDigest :: Type)
        (planId :: Type)
        (brokerGeneration :: Type).
      AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withAbandonedHarnessRun store project lease use = case incompleteRunLeaseKind lease of
    IncompleteUnbound ->
        -- An unbound lease has no snapshot, so there is nothing to reopen: the
        -- sweep closes it behind 'verifyUnboundLeaseHasNoEffects' instead.
        pure (Left (ModeLeaseNotBindable (runKeyText runKey) "unbound"))
    IncompleteBound recordedSpec recordedPlan ->
        withReifiedRunId runKey $ \run -> do
            prepared <- runProtected store (reopen run recordedSpec recordedPlan)
            case prepared of
                Left failure -> pure (Left failure)
                Right (SomeAbandonedHarnessRun reopened) -> use reopened
  where
    runKey = incompleteRunLeaseRunKey lease

    reopen ::
        RunId oldRunId ->
        Text ->
        Text ->
        ProtectedSession session ->
        IO (Either ModeError (SomeAbandonedHarnessRun projectId))
    reopen run recordedSpec recordedPlan session =
      withOrdinaryProjectAdmission session project $ do
        stillBound <- leaseStillBoundTo session project runKey recordedSpec recordedPlan
        case stillBound of
            Left failure -> pure (Left failure)
            Right () -> do
                classifyHarnessBoundRunFor session project run (incompleteRunLeaseKind lease) $ \recovery ->
                    case makeLeaseLocation store project runKey of
                        Left failure -> pure (Left failure)
                        Right location ->
                            verifyPlanSnapshotInSession
                                session
                                (leaseLocationSnapshotKey location)
                                (HarnessRunIdentity run)
                                (installedProjectName project)
                                (leaseLocationStoreIdentity location)
                                $ \snapshot ->
                                    case checkSnapshotDigests recovery snapshot recordedSpec recordedPlan of
                                        Left failure -> pure (Left failure)
                                        Right () -> do
                                            operator <- verifyOsPrincipal session
                                            case operator of
                                                Left failure ->
                                                    pure (Left (ModeAuthorityFailure failure))
                                                Right authorized ->
                                                    withFreshEpoch session project $ \epoch ->
                                                        withVerifiedRoot
                                                            HarnessRootScope
                                                            session
                                                            project
                                                            authorized
                                                            epoch
                                                            ProjectDestroy
                                                            ( retain
                                                                run
                                                                session
                                                                snapshot
                                                                (recordedSpec, recordedPlan)
                                                                recovery
                                                                epoch
                                                            )

    retain ::
        RunId oldRunId ->
        ProtectedSession session ->
        VerifiedPlanSnapshot (Harness projectId oldRunId) specDigest planDigest ->
        (Text, Text) ->
        HarnessBoundRecovery projectId oldRunId ->
        BrokerEpoch brokerGeneration ->
        RootInvocationAuthority (Harness projectId oldRunId) brokerGeneration VerbDestroy ->
        IO (Either ModeError (SomeAbandonedHarnessRun projectId))
    retain run session snapshot recordedDigests recovery epoch root = do
        retained <- retainAbandonedHarnessMode session project run epoch
        case retained of
            Left failure -> pure (Left failure)
            Right modeLease -> do
                rebound <-
                    retainBoundLeaseGeneration
                        store
                        session
                        project
                        run
                        snapshot
                        recordedDigests
                        epoch
                case rebound of
                    Left failure -> pure (Left failure)
                    Right bound -> do
                        admitted <- readmitSessions session snapshot epoch
                        pure $ case admitted of
                            Left failure -> Left failure
                            Right (fenced, manifest, interpreted, admission) ->
                                Right
                                    ( SomeAbandonedHarnessRun
                                        AbandonedHarnessRun
                                            { abandonedHarnessRunId = run
                                            , abandonedHarnessSnapshot = snapshot
                                            , abandonedHarnessBoundLease = bound
                                            , abandonedHarnessModeLease = modeLease
                                            , abandonedHarnessDestroyRoot = root
                                            , abandonedHarnessRecovery = recovery
                                            , abandonedHarnessCloseRoot =
                                                HarnessCloseRoot
                                                    RecoveredHarnessClose
                                                    run
                                                    (installedProjectName project)
                                                    epoch
                                            , abandonedHarnessBroker = epoch
                                            , abandonedHarnessFencedPermits = fenced
                                            , abandonedHarnessManifest = manifest
                                            , abandonedHarnessInterpretation = interpreted
                                            , abandonedHarnessAdmission = admission
                                            }
                                    )

    {- Fence the dead generation's permits, verify the paired complete session
    and operation sets, run the recorded-session interpreter over them, and mint
    the admission the three of them together authorize.

    The order is § EE's and each step depends on the one before it: the fence
    must be rotated before the interpreter settles anything, because the phase it
    writes records the epoch under which the operation was abandoned; the
    manifest must be verified before the interpreter runs, because the
    interpreter drives the manifest's members rather than re-enumerating; and the
    admission is minted last from all three, so no partial evidence can produce
    one.

    All four run inside the reopening's own protected entry, so a concurrent
    holder cannot open a session between the interpretation and the admission. -}
    readmitSessions ::
        forall session oldRunId planId brokerGeneration specDigest planDigest.
        ProtectedSession session ->
        VerifiedPlanSnapshot (Harness projectId oldRunId) specDigest planDigest ->
        BrokerEpoch brokerGeneration ->
        IO
            ( Either
                ModeError
                ( OldPermitsFenced (Harness projectId oldRunId) planId
                , VerifiedSessionManifest (Harness projectId oldRunId) planId
                , InterpretedRecovery (Harness projectId oldRunId) planId
                , CurrentBrokerSessionAdmission (Harness projectId oldRunId) planId brokerGeneration
                )
            )
    readmitSessions session snapshot epoch = do
        let planDigest = planSnapshotPlanDigest snapshot
        fenced <- fenceOldPermits session planDigest
        case fenced of
            Left failure -> pure (Left (ModeSessionFailure failure))
            Right fencedPermits -> do
                manifested <- verifySessionManifest session planDigest
                case manifested of
                    Left failure -> pure (Left (ModeSessionFailure failure))
                    Right manifest -> do
                        journal <- openProjectJournal session planDigest
                        case journal of
                            Left failure -> pure (Left (ModeSessionFailure failure))
                            Right (permit :: ProjectPermit (Harness projectId oldRunId) planId) -> do
                                driven <-
                                    interpretRecordedSessions
                                        session
                                        epoch
                                        manifest
                                        fencedPermits
                                        permit
                                case driven of
                                    Left failure -> pure (Left (ModeSessionFailure failure))
                                    Right (interpreted, _spent) -> do
                                        admitted <-
                                            admitCurrentBroker
                                                session
                                                epoch
                                                manifest
                                                fencedPermits
                                                interpreted
                                        pure $ case admitted of
                                            Left failure -> Left (ModeSessionFailure failure)
                                            Right admission ->
                                                Right
                                                    ( fencedPermits
                                                    , manifest
                                                    , interpreted
                                                    , admission
                                                    )

    {- The lease and the persisted snapshot must name the same revision — except
    across a committed activation barrier, where they are *supposed* to differ.

    A completed migration bound the lease to the candidate and could not rewrite
    the immutable snapshot record, so the divergence there is the evidence that
    the barrier was crossed rather than a substitution. The snapshot the
    reopening yields stays the old revision's, which is what teardown of the
    superseded revision needs. -}
    checkSnapshotDigests ::
        HarnessBoundRecovery projectId oldRunId ->
        VerifiedPlanSnapshot (Harness projectId oldRunId) specDigest planDigest ->
        Text ->
        Text ->
        Either ModeError ()
    checkSnapshotDigests recovery snapshot recordedSpec recordedPlan
        | crossedActivationBarrier recovery = Right ()
        | planSnapshotSpecDigest snapshot /= recordedSpec =
            Left (ModeSnapshotMismatch recordedSpec (planSnapshotSpecDigest snapshot))
        | planSnapshotPlanDigest snapshot /= recordedPlan =
            Left (ModeSnapshotMismatch recordedPlan (planSnapshotPlanDigest snapshot))
        | otherwise = Right ()

    crossedActivationBarrier recovery = case recovery of
        HarnessOpenRevisionRecovery revision -> case openRevisionKind revision of
            CompletedMigration _ -> True
            _ -> False
        HarnessPersistedClosing _ -> False

{- | Recheck that the lease is still recorded @bound@ to the digests the sweep
observed. The sweep's observation was taken at an earlier store version, so
between it and this entry the lease may have been closed by a competing resolver
or bound to a different snapshot; neither is a run this opener may reopen.
-}
leaseStillBoundTo ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    Text ->
    Text ->
    IO (Either ModeError ())
leaseStillBoundTo session project run expectedSpec expectedPlan =
    withRecordKey (leaseKeyForRunKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Left (ModeLeaseMissing (runKeyText run))
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> Left (ModeMalformedRecord (recordKeyText key))
                Just (LeaseBound _ spec plan)
                    | spec /= expectedSpec -> Left (ModeSnapshotMismatch expectedSpec spec)
                    | plan /= expectedPlan -> Left (ModeSnapshotMismatch expectedPlan plan)
                    | otherwise -> Right ()
                Just other ->
                    Left (ModeLeaseNotBindable (runKeyText run) (leaseStateName other))

{- | Retain an abandoned run's own Harness mode onto a fresh broker generation.

This is deliberately /not/ a branch of 'acquireMode'. 'acquireMode' refuses every
harness re-take, and that refusal is what the four-process reservation race
exists to guarantee: if a starting run could re-take a harness mode, it could
steal a live run's project. Recovery is admitted here only because its single
route in is a 'VerifiedIncompleteRunLease' the sweep minted, and the sweep runs
under the run-liveness lock that proves the holder is dead.

The mode must be exactly this run's. A Production mode, another run's mode, or an
absent record all refuse: an absent mode under a still-bound lease is a torn
store, not an invitation to claim one.
-}
retainAbandonedHarnessMode ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    BrokerEpoch brokerGeneration ->
    IO
        ( Either
            ModeError
            (ProjectModeLease projectId (HarnessMode runId) brokerGeneration)
        )
retainAbandonedHarnessMode session project run epoch =
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeHeldByAnother "none" wanted))
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (held, _)
                    | held /= wantedMode ->
                        pure (Left (ModeHeldByAnother (modeWireName held) wanted))
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeMode held (brokerEpochWord epoch))
                        pure $ case written of
                            Left failure -> Left (ModeStoreFailure failure)
                            Right _ ->
                                Right
                                    ( ProjectModeLease
                                        held
                                        (installedProjectName project)
                                        (protectedStoreIdentityText (sessionStoreIdentity session))
                                        epoch
                                    )
  where
    wantedMode = WireHarness (runIdentityKey (HarnessRunIdentity run))
    wanted = modeWireName wantedMode

{- | Retain an already-bound lease onto a fresh broker generation without
touching the snapshot it names.

The digests are the /verified snapshot's/, not a caller's, so this cannot rebind
a lease to a different plan: it writes back the same two digests it read out of
the durable snapshot record and refuses if the lease disagrees with them.
-}
{- | Retain the already-bound lease onto the fresh generation.

The digests it retains are the ones the __lease record__ holds, not the
snapshot's, and the two are allowed to differ in exactly one case: a completed
migration. Its activation compare-and-swap bound the lease to the candidate
while the run's persisted snapshot still names the superseded revision — the
snapshot record is immutable by construction, so the activation could not have
rewritten it even in principle. Comparing the lease against the snapshot there
would refuse a correctly-activated run for the one reason that is not a fault.

Every other divergence is still a substitution and still refuses, because the
caller passes the digests it expects and this compares against them.
-}
retainBoundLeaseGeneration ::
    ProtectedStore ->
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    VerifiedPlanSnapshot (Harness projectId runId) specDigest planDigest ->
    -- | the digests the lease record must currently hold
    (Text, Text) ->
    BrokerEpoch brokerGeneration ->
    IO
        ( Either
            ModeError
            (BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration)
        )
retainBoundLeaseGeneration store session project run snapshot (spec, plan) epoch =
    case makeLeaseLocation store project runKey of
        Left failure -> pure (Left failure)
        Right location -> do
            observed <- readProtectedRecord session (leaseLocationLeaseKey location)
            case observed of
                Left failure -> pure (Left (ModeStoreFailure failure))
                Right Nothing -> pure (Left (ModeLeaseMissing (runIdText run)))
                Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                    Nothing ->
                        pure
                            ( Left
                                (ModeMalformedRecord (recordKeyText (leaseLocationLeaseKey location)))
                            )
                    Just (LeaseBound _ recordedSpec recordedPlan)
                        | planSnapshotRunKey snapshot /= runKey ->
                            pure
                                ( Left
                                    ( ModeSnapshotMismatch
                                        (runIdText run)
                                        (planSnapshotRunText snapshot)
                                    )
                                )
                        | recordedSpec /= spec ->
                            pure (Left (ModeSnapshotMismatch spec recordedSpec))
                        | recordedPlan /= plan ->
                            pure (Left (ModeSnapshotMismatch plan recordedPlan))
                        | otherwise -> do
                            written <-
                                compareAndSwapProtectedRecord
                                    session
                                    (leaseLocationLeaseKey location)
                                    (ExpectVersion (protectedRecordVersion record))
                                    (encodeLease (LeaseBound (brokerEpochWord epoch) spec plan))
                            pure $ case written of
                                Left failure -> Left (ModeStoreFailure failure)
                                Right leaseVersion ->
                                    Right
                                        ( BoundRunLease
                                            (HarnessRunIdentity run)
                                            location
                                            spec
                                            plan
                                            epoch
                                            leaseVersion
                                            ExistingBinding
                                        )
                    Just other ->
                        pure (Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other)))
  where
    runKey = runIdentityKey (HarnessRunIdentity run)

{- | Release the project-wide mode when it is held by this exact abandoned run.
A Production mode, or another run's mode, is left untouched.
-}
releaseModeIfRunKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    IO (Either ModeError ())
releaseModeIfRunKey session project run = do
    held <- currentMode session project
    case held of
        Left failure -> pure (Left failure)
        Right (Just (WireHarness active))
            | active == run -> releaseMode session project (WireHarness run)
        Right _ -> pure (Right ())

-- The protected record layer -------------------------------------------------------------------

data LeaseState
    = LeaseUnbound Word64
    | LeaseBound Word64 Text Text
    | -- | The old revision, frozen by a migration under one stable key. The
      -- candidate's digests travel with it, so the activation compare-and-swap
      -- reads which revision it is switching to off the frozen record rather
      -- than off a caller's argument.
      LeaseFrozen Word64 Text Text Text Text Text
    | LeaseClosed Word64
    deriving (Eq, Show)

leaseStateName :: LeaseState -> Text
leaseStateName (LeaseUnbound _) = "unbound"
leaseStateName LeaseBound{} = "bound"
leaseStateName LeaseFrozen{} = "frozen"
leaseStateName (LeaseClosed _) = "closed"

encodeLease :: LeaseState -> ByteString
encodeLease state = case state of
    LeaseUnbound epoch -> encodeFields ["unbound", showWord epoch]
    LeaseBound epoch spec plan -> encodeFields ["bound", showWord epoch, spec, plan]
    LeaseFrozen epoch key oldSpec oldPlan newSpec newPlan ->
        encodeFields ["frozen", showWord epoch, key, oldSpec, oldPlan, newSpec, newPlan]
    LeaseClosed epoch -> encodeFields ["closed", showWord epoch]

decodeLease :: ByteString -> Maybe LeaseState
decodeLease raw = case decodeFields raw of
    ["unbound", epoch] -> LeaseUnbound <$> readWord epoch
    ["bound", epoch, spec, plan]
        | not (Text.null spec) && not (Text.null plan) ->
            (\value -> LeaseBound value spec plan) <$> readWord epoch
    ["frozen", epoch, key, oldSpec, oldPlan, newSpec, newPlan]
        | not (Text.null key) ->
            (\value -> LeaseFrozen value key oldSpec oldPlan newSpec newPlan) <$> readWord epoch
    ["closed", epoch] -> LeaseClosed <$> readWord epoch
    _ -> Nothing

encodeDisposition :: InvocationDisposition -> ByteString
encodeDisposition disposition = case disposition of
    InvocationOpen -> encodeFields ["open"]
    InvocationAcknowledged (InvocationCloseKey key) -> encodeFields ["ack", key]
    InvocationClosing epoch -> encodeFields ["closing", showWord epoch]

decodeDisposition :: ByteString -> Maybe InvocationDisposition
decodeDisposition raw = case exactFields raw of
    ["open"] -> Just InvocationOpen
    ["ack", key] ->
        either (const Nothing) (Just . InvocationAcknowledged) (mkInvocationCloseKey key)
    ["closing", epoch] -> do
        value <- readWord epoch
        if value == 0 then Nothing else Just (InvocationClosing value)
    _ -> Nothing

exactFields :: ByteString -> [Text]
exactFields = Text.splitOn "\t" . Text.pack . ByteStringChar8.unpack

encodeRevisionKind :: OpenRevisionKind -> ByteString
encodeRevisionKind kind = case kind of
    NormalRevision -> encodeFields ["normal"]
    IncompleteMigration key -> encodeFields ["incomplete", key]
    CompletedMigration key -> encodeFields ["completed", key]

decodeRevisionKind :: ByteString -> Maybe OpenRevisionKind
decodeRevisionKind raw = case decodeFields raw of
    ["normal"] -> Just NormalRevision
    ["incomplete", key] | not (Text.null key) -> Just (IncompleteMigration key)
    ["completed", key] | not (Text.null key) -> Just (CompletedMigration key)
    _ -> Nothing

encodeMode :: ModeWire -> Word64 -> ByteString
encodeMode WireProduction epoch = encodeFields ["production", showWord epoch]
encodeMode (WireHarness run) epoch =
    encodeFields ["harness", showWord epoch, runKeyText run]

decodeMode :: ByteString -> Maybe (ModeWire, Word64)
decodeMode raw = case decodeFields raw of
    ["production", epoch] -> (\value -> (WireProduction, value)) <$> readWord epoch
    ["harness", epoch, run] -> do
        value <- readWord epoch
        parsed <- either (const Nothing) Just (parseRunKey run)
        pure (WireHarness parsed, value)
    _ -> Nothing

encodeFields :: [Text] -> ByteString
encodeFields = ByteStringChar8.pack . Text.unpack . Text.intercalate "\t"

decodeFields :: ByteString -> [Text]
decodeFields = Text.splitOn "\t" . Text.strip . Text.pack . ByteStringChar8.unpack

showWord :: Word64 -> Text
showWord = Text.pack . show

readWord :: Text -> Maybe Word64
readWord raw = case reads (Text.unpack raw) of
    [(value, "")] -> Just value
    _ -> Nothing

{- | Take or retain the project-wide mode.

Production retains an already-held Production mode (this is what @down@ relies
on) and refuses while a harness run holds it. A harness run may take the mode
only when it is absent: two harness runs, or a harness run against live
Production, contend on this exact record and exactly one wins.
-}
acquireModeWire ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ModeWire ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError ())
acquireModeWire session project requested epoch =
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> take_ key ExpectAbsent
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (held, _)
                    | held == requested && requested == WireProduction ->
                        take_ key (ExpectVersion (protectedRecordVersion record))
                    | otherwise ->
                        pure
                            ( Left
                                ( ModeHeldByAnother
                                    (modeWireName held)
                                    (modeWireName requested)
                                )
                            )
  where
    take_ key expectation = do
        written <-
            compareAndSwapProtectedRecord
                session
                key
                expectation
                (encodeMode requested (brokerEpochWord epoch))
        pure $ case written of
            Left failure -> Left (ModeStoreFailure failure)
            Right _ -> Right ()

acquireProductionMode ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (ProjectModeLease projectId ProductionMode brokerGeneration))
acquireProductionMode session project epoch = do
    acquired <- acquireModeWire session project WireProduction epoch
    pure
        ( fmap
            ( const
                ( ProjectModeLease
                    WireProduction
                    (installedProjectName project)
                    (protectedStoreIdentityText (sessionStoreIdentity session))
                    epoch
                )
            )
            acquired
        )

acquireHarnessMode ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunId runId ->
    BrokerEpoch brokerGeneration ->
    IO
        ( Either
            ModeError
            (ProjectModeLease projectId (HarnessMode runId) brokerGeneration)
        )
acquireHarnessMode session project run epoch = do
    let mode = WireHarness (runIdentityKey (HarnessRunIdentity run))
    acquired <- acquireModeWire session project mode epoch
    pure
        ( fmap
            ( const
                ( ProjectModeLease
                    mode
                    (installedProjectName project)
                    (protectedStoreIdentityText (sessionStoreIdentity session))
                    epoch
                )
            )
            acquired
        )

-- | The mode currently recorded, if any.
currentMode ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError (Maybe ModeWire))
currentMode session project =
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Right Nothing
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> Left (ModeMalformedRecord (recordKeyText key))
                Just (held, _) -> Right (Just held)

releaseMode ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ModeWire ->
    IO (Either ModeError ())
releaseMode session project expected =
  withOrdinaryProjectAdmission session project $
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Right ())
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (held, _)
                    | held /= expected ->
                        pure
                            ( Left
                                ( ModeHeldByAnother
                                    (modeWireName held)
                                    (modeWireName expected)
                                )
                            )
                    | otherwise -> do
                        deleted <-
                            compareAndDeleteProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                        pure (either (Left . ModeStoreFailure) Right deleted)

recordUnboundLease ::
    ProtectedStore ->
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunIdentity scope ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (UnboundRunLease scope brokerGeneration))
recordUnboundLease store session project run epoch =
    case makeLeaseLocation store project (runIdentityKey run) of
        Left failure -> pure (Left failure)
        Right location -> do
            let key = leaseLocationLeaseKey location
                writeUnbound expectation = do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            expectation
                            (encodeLease (LeaseUnbound (brokerEpochWord epoch)))
                    case written of
                        Left failure -> pure (Left (ModeStoreFailure failure))
                        Right version -> do
                            let leaseVersion = recordVersionWord version
                            initialized <- initializeProfileSlot session location epoch leaseVersion
                            pure
                                ( fmap
                                    (const (UnboundRunLease run location epoch leaseVersion))
                                    initialized
                                )
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (ModeStoreFailure failure))
                Right Nothing -> writeUnbound ExpectAbsent
                Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                    Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                    Just LeaseUnbound{} ->
                        writeUnbound (ExpectVersion (protectedRecordVersion record))
                    Just other ->
                        pure (Left (ModeLeaseNotBindable (runIdentityText run) (leaseStateName other)))

initializeProfileSlot ::
    ProtectedSession session ->
    LeaseLocation ->
    BrokerEpoch brokerGeneration ->
    Word64 ->
    IO (Either ModeError ())
initializeProfileSlot session location epoch leaseVersion = do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left (ModeStoreFailure failure))
        Right existing -> do
            let expectation = maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) existing
            written <-
                compareAndSwapProtectedRecord
                    session
                    key
                    expectation
                    (encodeProfileSlot (ProfileAvailable (brokerEpochWord epoch) leaseVersion))
            pure (either (Left . ModeStoreFailure) (const (Right ())) written)
  where
    key = leaseLocationProfileKey location

makeLeaseLocation ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    Either ModeError LeaseLocation
makeLeaseLocation store project run = do
    leaseRecordKey <- leaseKeyForRunKey project run
    snapshotRecordKey <- snapshotKeyForRunKey project run
    invocationRecordKey <- invocationKeyForRunKey project run
    migrationRecordKey <- migrationKeyForRunKey project run
    profileRecordKey <- profileKeyForRunKey project run
    pure
        LeaseLocation
            { leaseLocationStore = store
            , leaseLocationProjectName = installedProjectName project
            , leaseLocationStoreIdentity =
                protectedStoreIdentityText (protectedStoreIdentity store)
            , leaseLocationLeaseKey = leaseRecordKey
            , leaseLocationSnapshotKey = snapshotRecordKey
            , leaseLocationInvocationKey = invocationRecordKey
            , leaseLocationMigrationKey = migrationRecordKey
            , leaseLocationProfileKey = profileRecordKey
            }

closeLeaseForKey ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    IO (Either ModeError ())
closeLeaseForKey session project run =
  withOrdinaryProjectAdmission session project $
    withRecordKey (leaseKeyForRunKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Right ())
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just state -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            (ExpectVersion (protectedRecordVersion record))
                            (encodeLease (LeaseClosed (leaseEpoch state)))
                    pure (either (Left . ModeStoreFailure) (const (Right ())) written)

leaseEpoch :: LeaseState -> Word64
leaseEpoch (LeaseUnbound epoch) = epoch
leaseEpoch (LeaseBound epoch _ _) = epoch
leaseEpoch (LeaseFrozen epoch _ _ _ _ _) = epoch
leaseEpoch (LeaseClosed epoch) = epoch

{- | The incomplete leases the harness sweep may resolve: every one except the
reserved Production invocation lease.

Production's lease is shaped exactly like an abandoned harness run's — unbound,
open, and carrying no generative identity — but it belongs to the /other/
profile's snapshot admission and stable 'InvocationCloseKey' recovery.
Reading it as abandoned closed a __live__ invocation's lease: the same shape as
the four-process reservation defect, across profiles instead of within one, and
it also discarded the evidence Production's own recovery reads.

Skipping it opens no hole, because Production always closes its lease /before/
releasing its mode ('releaseProductionMode',
'closeCompletedProductionInvocation'). An open Production lease therefore
implies the Production mode is still held, so 'acquireMode' refuses the harness
with the stated 'ModeHeldByAnother' exclusion § Z requires — rather than a sweep
quietly resolving another profile's state and then refusing for a different
reason.
-}
abandonedHarnessLeases ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError [VerifiedIncompleteRunLease projectId])
abandonedHarnessLeases session project =
    withOrdinaryProjectAdmission session project $
        fmap
            (fmap (filter (not . isProductionRunKey . incompleteRunLeaseRunKey)))
            (incompleteLeases session project)

incompleteLeases ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError [VerifiedIncompleteRunLease projectId])
incompleteLeases session project = do
    keys <- listProtectedRecords session
    case keys of
        Left failure -> pure (Left (ModeStoreFailure failure))
        Right present -> collect (sort (filter (isLeaseKey project) present))
  where
    collect [] = pure (Right [])
    collect (key : rest) = do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> collect rest
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (LeaseClosed _) -> collect rest
                Just state -> case runOfLeaseKey project key of
                    Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                    Just run -> do
                        rest' <- collect rest
                        pure (fmap (VerifiedIncompleteRunLease run (kindOf state) :) rest')
    kindOf (LeaseUnbound _) = IncompleteUnbound
    kindOf (LeaseBound _ spec plan) = IncompleteBound spec plan
    -- A frozen lease reached a plan — the *old* one, which is the revision an
    -- interrupted migration must be recovered against. Classifying it by the
    -- old digests is what sends it down the bound branch, where the recorded
    -- migration kind then selects which side of the activation barrier it is
    -- on. Classifying it as unbound would let the sweep close it behind the
    -- no-effect proof, discarding a revision that may hold real resources.
    kindOf (LeaseFrozen _ _ oldSpec oldPlan _ _) = IncompleteBound oldSpec oldPlan
    kindOf (LeaseClosed _) = IncompleteUnbound

sweptSetStillEmpty ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ClosedAbandonedHarnessRuns projectId ->
    IO (Either ModeError ())
sweptSetStillEmpty session project _ = do
    remaining <- abandonedHarnessLeases session project
    pure $ case remaining of
        Left failure -> Left failure
        Right [] -> Right ()
        Right (unresolved : _) ->
            Left (ModeRecoveryRequired (incompleteRunLeaseRunText unresolved))

unboundOwnershipRecordsFor ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    RunKey ->
    IO (Either ModeError [RecordKey])
unboundOwnershipRecordsFor session project run = do
    keys <- listProtectedRecords session
    pure $ case keys of
        Left failure -> Left (ModeStoreFailure failure)
        Right present -> Right (filter ownedByRun present)
  where
    ownedByRun key =
        isEffectKey project run key || isAcquisitionKey project run key

-- Record keys ------------------------------------------------------------------------------------

modeKey :: InstalledProjectIdentity projectId -> Either ModeError RecordKey
modeKey project = storeKey ("mode." <> installedProjectName project)

reverseRootIntentKey :: InstalledProjectIdentity projectId -> Either ModeError RecordKey
reverseRootIntentKey = reverseRootIntentKeyForName . installedProjectName

reverseRootIntentKeyForName :: Text -> Either ModeError RecordKey
reverseRootIntentKeyForName project = storeKey ("reverse-root." <> project <> ".production")

refuseReverseRootIntent ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError ())
refuseReverseRootIntent session project =
    refuseReverseRootIntentAt session (reverseRootIntentKey project)

refuseReverseRootIntentForName ::
    ProtectedSession session ->
    Text ->
    IO (Either ModeError ())
refuseReverseRootIntentForName session project =
    refuseReverseRootIntentAt session (reverseRootIntentKeyForName project)

refuseReverseRootIntentAt ::
    ProtectedSession session ->
    Either ModeError RecordKey ->
    IO (Either ModeError ())
refuseReverseRootIntentAt session keyResult =
    withRecordKey keyResult $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Right ()
            Right (Just record) ->
                case decodeReverseRootIntent ProjectDown (protectedRecordBytes record) of
                    Just _ -> Left ModeReverseRootInProgress
                    Nothing -> case decodeReverseRootIntent ProjectDestroy (protectedRecordBytes record) of
                        Just _ -> Left ModeReverseRootInProgress
                        Nothing -> Left (ModeMalformedRecord (recordKeyText key))

withOrdinaryProjectAdmission ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    IO (Either ModeError result) ->
    IO (Either ModeError result)
withOrdinaryProjectAdmission session project =
    withOrdinaryProjectAdmissionForName session (installedProjectName project)

withOrdinaryProjectAdmissionForName ::
    ProtectedSession session ->
    Text ->
    IO (Either ModeError result) ->
    IO (Either ModeError result)
withOrdinaryProjectAdmissionForName session project action = do
    clear <- refuseReverseRootIntentForName session project
    case clear of
        Left failure -> pure (Left failure)
        Right () -> action

snapshotKeyForRunKey :: InstalledProjectIdentity projectId -> RunKey -> Either ModeError RecordKey
snapshotKeyForRunKey project run =
    storeKey ("snapshot." <> installedProjectName project <> "." <> runKeyText run)

invocationKeyForRunKey :: InstalledProjectIdentity projectId -> RunKey -> Either ModeError RecordKey
invocationKeyForRunKey project run =
    storeKey ("invocation." <> installedProjectName project <> "." <> runKeyText run)

migrationKeyForRunKey :: InstalledProjectIdentity projectId -> RunKey -> Either ModeError RecordKey
migrationKeyForRunKey project run =
    storeKey ("migration." <> installedProjectName project <> "." <> runKeyText run)

leaseKeyForRunKey :: InstalledProjectIdentity projectId -> RunKey -> Either ModeError RecordKey
leaseKeyForRunKey project run =
    storeKey (leasePrefix project <> runKeyText run)

profileKeyForRunKey :: InstalledProjectIdentity projectId -> RunKey -> Either ModeError RecordKey
profileKeyForRunKey project run =
    storeKey ("profile." <> installedProjectName project <> "." <> runKeyText run)

leasePrefix :: InstalledProjectIdentity projectId -> Text
leasePrefix project = "lease." <> installedProjectName project <> "."

isLeaseKey :: InstalledProjectIdentity projectId -> RecordKey -> Bool
isLeaseKey project key = leasePrefix project `Text.isPrefixOf` recordKeyText key

runOfLeaseKey :: InstalledProjectIdentity projectId -> RecordKey -> Maybe RunKey
runOfLeaseKey project key =
    either
        (const Nothing)
        Just
        (parseRunKey (Text.drop (Text.length (leasePrefix project)) (recordKeyText key)))

{- | Effect-shaped records for a run. Every durable record a lifecycle effect
writes uses this prefix, so "did this run touch anything" is a set membership
question rather than an inference.
-}
isEffectKey :: InstalledProjectIdentity projectId -> RunKey -> RecordKey -> Bool
isEffectKey project run key =
    hasRunRecordPrefix "effect." (installedProjectName project) run key

-- The payload and epoch suffix are intentionally not decoded here. Any row
-- under this exact run prefix proves that acquisition began, while the
-- trailing dot keeps a different run whose text merely shares a prefix out.
isAcquisitionKey :: InstalledProjectIdentity projectId -> RunKey -> RecordKey -> Bool
isAcquisitionKey project run key =
    hasRunRecordPrefix "acquisition." (installedProjectName project) run key

hasRunRecordPrefix :: Text -> Text -> RunKey -> RecordKey -> Bool
hasRunRecordPrefix namespace project run key =
    (namespace <> project <> "." <> runKeyText run <> ".")
        `Text.isPrefixOf` recordKeyText key

storeKey :: Text -> Either ModeError RecordKey
storeKey raw = case mkRecordKey raw of
    Left failure -> Left (ModeStoreFailure failure)
    Right key -> Right key

-- Small plumbing ------------------------------------------------------------------------------------

runProtected ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
runProtected store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . ModeStoreFailure) id outcome)

withRecordKey ::
    Either ModeError RecordKey ->
    (RecordKey -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
withRecordKey (Left failure) _ = pure (Left failure)
withRecordKey (Right key) use = use key

withFreshEpoch ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withFreshEpoch session project use = do
    clear <- refuseReverseRootIntent session project
    case clear of
        Left failure -> pure (Left failure)
        Right () -> do
            outcome <- withFreshBrokerEpochKernel session project (fmap Right . use)
            pure (either (Left . ModeAuthorityFailure) id outcome)

withRecordedEpoch ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    Word64 ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withRecordedEpoch session project recorded use = do
    outcome <-
        withReifiedAllocatedBrokerEpochKernel
            session
            project
            recorded
            (fmap Right . use)
    pure (either (Left . ModeAuthorityFailure) id outcome)

withVerifiedRoot ::
    RootScopeWitness projectId scope ->
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    VerifiedOsPrincipal ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    ( RootInvocationAuthority scope brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withVerifiedRoot scope session project operator epoch verb use = do
    outcome <-
        withVerifiedRootInvocationKernel
            scope
            session
            project
            operator
            epoch
            verb
            (fmap Right . use)
    pure (either (Left . ModeAuthorityFailure) id outcome)

withExistingVerifiedRoot ::
    RootScopeWitness projectId scope ->
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    VerifiedOsPrincipal ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    ( RootInvocationAuthority scope brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withExistingVerifiedRoot scope session project operator epoch verb use = do
    outcome <-
        withExistingVerifiedRootInvocationKernel
            scope
            session
            project
            operator
            epoch
            verb
            (fmap Right . use)
    pure (either (Left . ModeAuthorityFailure) id outcome)

traverseEither :: (a -> IO (Either e ())) -> [a] -> IO (Either e ())
traverseEither _ [] = pure (Right ())
traverseEither action (value : rest) = do
    outcome <- action value
    case outcome of
        Left failure -> pure (Left failure)
        Right () -> traverseEither action rest

-- Failures ----------------------------------------------------------------------------------------------

data ModeError
    = ModeInvalidIdentity Text
    | -- | Another mode holds the project: held, then requested.
      ModeHeldByAnother Text Text
    | -- | A profile was requested for a mode the lease does not hold.
      ModeWrongMode Text Text
    | -- | The lease record is missing.
      ModeLeaseMissing Text
    | -- | The lease is not in a bindable state: run, then observed state.
      ModeLeaseNotBindable Text Text
    | -- | A recorded epoch did not match the presented one.
      ModeEpochMismatch Word64 Word64
    | -- | A durable record could not be decoded. Never silently ignored.
      ModeMalformedRecord Text
    | -- | The harness safety preconditions refused.
      ModeHarnessRefused HarnessPreconditionFailure
    | -- | An effect- or acquisition-shaped record exists, so this is not a pre-effect state.
      ModeEffectsRecorded Text
    | -- | An abandoned run must be resolved before a new run may start.
      ModeRecoveryRequired Text
    | -- | A sweep callback could not settle a run's owned state: run, then reason.
      ModeOwnershipUnresolved Text Text
    | -- | The closure root and closure evidence disagree.
      ModeClosureMismatch Text Text
    | -- | No plan snapshot is persisted for a run that needs one.
      ModeSnapshotMissing Text
    | -- | A presented identity/digest did not match the persisted one.
      ModeSnapshotMismatch Text Text
    | -- | Fresh snapshot evidence disagreed before any protected mutation.
      ModeEvidenceMismatch Text Text Text
    | -- | A recovery record belongs to the other lifecycle scope.
      ModeWrongRecoveryScope Text Text
    | -- | A durable reverse root owns admission until its later terminal protocol.
      ModeReverseRootInProgress
    | ModeAuthorityFailure AuthorityError
    | -- | The recorded-session interpreter, the manifest, or the fence set refused.
      ModeSessionFailure SessionError
    | ModeStoreFailure ProtectedError
    deriving (Eq, Show)

modeErrorMessage :: ModeError -> Text
modeErrorMessage failure = case failure of
    ModeInvalidIdentity reason -> reason
    ModeHeldByAnother held requested ->
        "the project is already in " <> held <> " mode; refusing to enter " <> requested
    ModeWrongMode expected observed ->
        "expected " <> expected <> " mode, observed " <> observed
    ModeLeaseMissing run -> "no run lease is recorded for " <> run
    ModeLeaseNotBindable run state ->
        "the run lease for " <> run <> " is " <> state <> " and cannot be bound"
    ModeEpochMismatch recorded presented ->
        "broker generation "
            <> Text.pack (show presented)
            <> " does not match the recorded generation "
            <> Text.pack (show recorded)
    ModeMalformedRecord key -> "durable record " <> key <> " is malformed"
    ModeHarnessRefused obstacle -> case obstacle of
        ProductionConfigPresent path ->
            "a production config already exists at "
                <> Text.pack path
                <> "; refusing to overwrite it"
        ProductionClusterRunning ->
            "a production cluster is already running; refusing to touch production state"
    ModeEffectsRecorded key ->
        "effect or acquisition record " <> key <> " exists, so no pre-effect proof can be made"
    ModeRecoveryRequired run ->
        "the abandoned run " <> run <> " must be recovered before a new run starts"
    ModeOwnershipUnresolved run reason ->
        "the abandoned run " <> run <> " still owns state: " <> reason
    ModeClosureMismatch expected observed ->
        "closure authorization is " <> expected <> " but the evidence is " <> observed
    ModeSnapshotMissing run ->
        "no plan snapshot is persisted for " <> run <> "; a lease cannot be bound without one"
    ModeSnapshotMismatch expected observed ->
        "expected " <> expected <> " but the persisted record says " <> observed
    ModeEvidenceMismatch subject expected observed ->
        "snapshot admission "
            <> subject
            <> " expected "
            <> expected
            <> " but observed "
            <> observed
    ModeWrongRecoveryScope scope observed ->
        scope <> " recovery cannot consume " <> observed
    ModeReverseRootInProgress ->
        "a durable reverse-root intent owns ordinary lifecycle admission"
    ModeAuthorityFailure inner -> authorityErrorMessage inner
    ModeSessionFailure inner -> Text.pack (sessionErrorMessage inner)
    ModeStoreFailure inner -> protectedErrorMessage inner
