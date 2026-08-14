{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The protected operation session, fence rotation, and the prepare
compare-and-swap (§ EE, the operator-root-and-command-authority phase).

the canonical-quantities-and-reconcile-results phase landed the *pure* journal algebra in "HostBootstrap.Reconcile":
'Reconcile.withPreparedOperation' validates a dependency set and mints the
'Reconcile.PreparedOperation' \/ 'Reconcile.PreparedPreconditions' pair an
adapter needs. It originally took the journal version as an ordinary 'Word64'
the caller supplied, so nothing proved that version was ever observed, that it
was still current, or that any session was open — two concurrent invocations
could each pass @7@ and each receive a prepared pair for the same operation.
It now takes a 'PreparedGate' instead, whose sole producer is the durable
unknown-phase write this module performs
("HostBootstrap.Lifecycle.Prepared").

This module is the durable half that makes those indices real. Every state
transition here is a compare-and-swap in the protected store
("HostBootstrap.Protected"), so:

* a session opens only against the live broker generation and only when no older
  session is still Open, and opening advances the shared project-journal
  version;
* an operation's initial intent is added to one exact session atomically with
  the version advance, so neither an orphan intent nor a session member without
  a record can exist;
* a prepare re-reads the journal under the exclusive entry, revalidates the
  broker epoch, session, project state, current fence, and recorded phase,
  durably records the operation-specific *unknown* phase **before** returning,
  and consumes the journal version it observed. The consumed version cannot
  authorize a second prepare or a close;
* a terminal observation returns 'OperationAdvance', whose eliminator yields the
  adapter's result only together with the sole successor permit;
* closing proves every registered operation settled before the session record
  moves to Closed, so a close cannot race a prepare.

The fence protocol (@FenceIntentRecorded -> FenceOutcomeUnknown ->
FenceObserved@) is durable and idempotent: a crash between any two records
resumes the same proposed epoch rather than proposing a new one, and a permit
issued under a superseded fence is rejected.
-}
module HostBootstrap.Lifecycle.Session (
    -- * Plan-bound acquisition admission
    AcquisitionJournal,
    acquisitionJournalStableScope,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalRunLease,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    validateAcquisitionJournalBindingKernel,
    withAcquisitionJournalPhase,
    openAcquisitionJournalKernel,
    reopenExistingAcquisitionCursorKernel,
    reopenExistingReverseAcquisitionJournalKernel,

    -- * Same-broker frame cursors
    LifecycleCursor,
    lifecycleCursorFrame,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    lifecycleCursorPhase,
    lifecycleCursorMatchesCommandAuthority,
    validateCurrentLifecycleCursor,
    withReverseRootSourceRecordsKernel,
    withReverseRootTargetLifecycleCursorKernel,
    withLifecycleCursor,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withTeardownLifecycleCursor,
    reserveCurrentLifecycleCommandKernel,

    -- * The project journal
    ProjectJournalState (..),
    ProjectPermit,
    ClosingProjectPermit,
    ClosedProjectPermit,
    projectPermitVersion,
    openProjectJournal,
    readProjectJournalState,
    beginClosingProject,
    recordClosedProject,

    -- * Completeness proofs
    VerifiedAllSessionsClosed,
    allSessionsClosedCount,
    allSessionsClosedPlanDigest,
    verifyAllSessionsClosed,

    -- * Operation sessions
    SessionId,
    sessionIdText,
    OperationSession,
    operationSessionId,
    openOperationSession,
    closeOperationSession,

    -- * Rooted frame session rows
    rootedFrameSessionKeyKernel,
    openRootedFrameSessionRecordKernel,
    attachRootedFrameSessionRecordKernel,
    rootedNodeUnknownKeyKernel,
    rootedSettlementKeyKernel,
    publishRootedUnknownRowKernel,

    -- * Fences
    FencePhase (..),
    FenceEpoch,
    fenceEpochWord,
    establishInitialFence,
    rotateFence,
    currentFence,

    -- * Operation intent
    IntentOrigin (..),
    registerOperationIntent,

    -- * The prepare compare-and-swap
    PreparedGate,
    preparedGatePlan,
    preparedGateOperation,
    preparedGateFence,
    preparedGateAttempt,
    preparedGateJournalVersion,
    withPreparedGate,
    withStepPreparedGate,

    -- * Terminal acknowledgment
    OperationAdvance,
    acknowledgeOutcome,
    withOperationAdvance,

    -- * Recovery
    OperationDisposition (..),
    classifyRecordedPhase,
    RecoveredSessions,
    recoveredSessionCount,
    recoveredContinuableCount,
    recoverAbandonedSessions,

    -- * The old-permit fence set
    OldPermitsFenced,
    oldPermitsFencedPlanDigest,
    oldPermitsFencedFrom,
    oldPermitsFencedTo,
    oldPermitsFencedOperations,
    fenceOldPermits,

    -- * The session\/operation manifest
    ManifestSession,
    manifestSessionId,
    manifestSessionIsOpen,
    manifestSessionOperations,
    VerifiedSessionManifest,
    manifestPlanDigest,
    manifestSessions,
    manifestOperationCount,
    verifySessionManifest,

    -- * The recorded-session interpreter
    RecoveredOperation (..),
    InterpretedRecovery,
    interpretedRecoveryPlanDigest,
    interpretedRecoverySessions,
    interpretedRecoveryOperations,
    interpretRecordedSessions,

    -- * Current-broker admission
    CurrentBrokerSessionAdmission,
    admissionPlanDigest,
    admissionBrokerGeneration,
    admissionSessionCount,
    admissionOperationCount,
    admitCurrentBroker,

    -- * Failures
    LifecycleError,
    lifecycleErrorMessage,
    SessionError (..),
    sessionErrorMessage,
) where

import Control.Monad (foldM)
import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (
    AuthorityError (AuthorityMalformedBinding, AuthorityStoreFailure),
    BrokerEpoch,
    CommandAuthority,
    ExecutePhase,
    LifecyclePhase (..),
    PreparePhase,
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    TeardownPhase,
    VerbUp,
    brokerEpochWord,
    lifecyclePhaseName,
    projectVerbName,
 )
import HostBootstrap.Authority.Kernel (
    CommandReservation,
    commandAuthorityOriginMatchesKernel,
    reserveCommandInvocationKernel,
    withInstalledProjectKernel,
 )
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
 )
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    decodeFields,
    encodeFields,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
 )
import HostBootstrap.Lifecycle.Prepared.Internal (
    mintPreparedGate,
 )
import HostBootstrap.Lifecycle.Plan (
    AcquisitionJournalAdmission,
    consumeAcquisitionJournalAdmissionKernel,
 )
import HostBootstrap.Lifecycle.Transaction (
    TransactionError (..),
    TransactionPermit,
    TransactionRecord,
    TransactionTarget,
    TxnKind (..),
    ensureTransactionCoordinator,
    operationTransactionTarget,
    projectTransactionTarget,
    readTransactionRecord,
    runLifecycleTransaction,
    sessionTransactionTarget,
    transactionErrorMessage,
    transactionPermitVersion,
    transactionRecordPayload,
    transactionRecordVersion,
 )
import HostBootstrap.ProjectPlan.Frame (
    ProjectFrame,
    projectFrameId,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    RecordVersion,
    recordKeyText,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    mkRecordName,
    protectedErrorMessage,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    readProtectedRecord,
    recordNameIdentity,
    recordVersionWord,
    sessionStoreIdentity,
    withProtectedEntry,
 )

-- ---------------------------------------------------------------------------
-- The project journal

{- | Whether the plan's journal is accepting new work. A closed project cannot
open a session, and a session cannot be opened and then discover the project was
closed underneath it, because both contend on the same record version.
-}
data ProjectJournalState
    = OpenProject
    | -- | Terminal close is under way, under this exact epoch. A run that
      -- crashed here resumes /this/ close rather than reopening work, so the
      -- epoch is part of the state and not a separate flag.
      ClosingProject Word64
    | ClosedProject
    deriving (Eq, Show)

{- | The immutable binding persisted in one dedicated acquisition record.

The local @planId@ is deliberately absent. It is generated afresh when an
existing snapshot is admitted and exists only as the nominal index on
'AcquisitionJournal'. The lease record key/version are included as well as its
decoded content, so a same-content compare-and-swap cannot revive an admission
made with stale lease evidence.
-}
data AcquisitionJournalBinding = AcquisitionJournalBinding
    { acquisitionBindingStableScope :: Text
    , acquisitionBindingProject :: Text
    , acquisitionBindingStore :: Text
    , acquisitionBindingSnapshotDigest :: Text
    , acquisitionBindingLeaseRecord :: Text
    , acquisitionBindingLeaseVersion :: Word64
    , acquisitionBindingRun :: Text
    , acquisitionBindingSpecDigest :: Text
    , acquisitionBindingLeasePlanDigest :: Text
    , acquisitionBindingBrokerEpoch :: Word64
    , acquisitionBindingRootVerb :: Text
    }
    deriving (Eq, Show)

-- The existential closed 'LifecyclePhase' retained below is intentionally
-- separate from 'ProjectJournalState'. Fresh acquisition starts at 'Prepare'.
{- | One exact local view of the durable acquisition journal.

The constructor is hidden and all three indices are nominal.  The retained
store is the store owned by the admitted bound lease, and the retained rank-2
validator can recheck the exact live mode, lease, and snapshot in any later
entry into that store. Neither is projected publicly, while the descriptive
projections below remain non-authorizing.
-}
data AcquisitionJournal scope planId brokerGeneration where
    AcquisitionJournal ::
        ProtectedStore ->
        (forall session. ProtectedSession session -> IO (Either SessionError ())) ->
        RecordKey ->
        RecordVersion ->
        AcquisitionJournalBinding ->
        LifecyclePhase phase ->
        AcquisitionJournal scope planId brokerGeneration

type role AcquisitionJournal nominal nominal nominal

instance Show (AcquisitionJournal scope planId brokerGeneration) where
    show (AcquisitionJournal _ _ _ _ binding phase) =
        "AcquisitionJournal "
            <> show (acquisitionBindingStableScope binding)
            <> " "
            <> show (acquisitionBindingSnapshotDigest binding)
            <> " "
            <> show (acquisitionBindingBrokerEpoch binding)
            <> " "
            <> Text.unpack (lifecyclePhaseName phase)

-- | Stable scope identity retained by the protected binding.
acquisitionJournalStableScope :: AcquisitionJournal scope planId brokerGeneration -> Text
acquisitionJournalStableScope (AcquisitionJournal _ _ _ _ binding _) =
    acquisitionBindingStableScope binding

-- | Exact stable snapshot digest bound inside the acquisition record.
acquisitionJournalSnapshotDigest :: AcquisitionJournal scope planId brokerGeneration -> Text
acquisitionJournalSnapshotDigest (AcquisitionJournal _ _ _ _ binding _) =
    acquisitionBindingSnapshotDigest binding

-- | Stable run identity retained from the exact bound run lease.
acquisitionJournalRunLease :: AcquisitionJournal scope planId brokerGeneration -> Text
acquisitionJournalRunLease (AcquisitionJournal _ _ _ _ binding _) =
    acquisitionBindingRun binding

-- | Durable broker epoch retained by the journal binding.
acquisitionJournalBrokerGeneration :: AcquisitionJournal scope planId brokerGeneration -> Word64
acquisitionJournalBrokerGeneration (AcquisitionJournal _ _ _ _ binding _) =
    acquisitionBindingBrokerEpoch binding

-- | Descriptive version of the exact acquisition source retained for every cursor check.
acquisitionJournalRecordVersion :: AcquisitionJournal scope planId brokerGeneration -> Word64
acquisitionJournalRecordVersion (AcquisitionJournal _ _ _ version _ _) = recordVersionWord version

-- | Closed root verb retained by the protected acquisition record.
acquisitionJournalRootVerb :: AcquisitionJournal scope planId brokerGeneration -> Text
acquisitionJournalRootVerb (AcquisitionJournal _ _ _ _ binding _) =
    acquisitionBindingRootVerb binding

{- | Package-level pure comparison between a journal's retained acquisition
binding and the complete origin of the bound lease presented by a later
authority gate.

The individual protected location and record-key members remain private.  This
helper grants no authority and performs no store access; it only prevents an
@unsafeCoerce@-substituted lease with coincident public run/digest fields from
being treated as the lease that originally opened the journal.
-}
validateAcquisitionJournalBindingKernel ::
    AcquisitionJournal scope planId brokerGeneration ->
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
    Either SessionError ()
validateAcquisitionJournalBindingKernel
    (AcquisitionJournal store _ _ _ binding _)
    stableScope
    project
    storeIdentity
    snapshotDigest
    leaseRecord
    leaseVersion
    run
    specDigest
    leasePlanDigest
    brokerEpoch = do
        require "stable scope" stableScope (acquisitionBindingStableScope binding)
        require "project" project (acquisitionBindingProject binding)
        require "protected store" storeIdentity (acquisitionBindingStore binding)
        require
            "journal store"
            storeIdentity
            (protectedStoreIdentityText (protectedStoreIdentity store))
        require "snapshot digest" snapshotDigest (acquisitionBindingSnapshotDigest binding)
        require "lease record" leaseRecord (acquisitionBindingLeaseRecord binding)
        requireWord
            "lease record version"
            leaseVersion
            (acquisitionBindingLeaseVersion binding)
        require "run" run (acquisitionBindingRun binding)
        require "specification digest" specDigest (acquisitionBindingSpecDigest binding)
        require "lease plan digest" leasePlanDigest (acquisitionBindingLeasePlanDigest binding)
        requireWord "broker epoch" brokerEpoch (acquisitionBindingBrokerEpoch binding)
  where
    require field expected observed
        | expected == observed = Right ()
        | otherwise = Left (SessionAcquisitionBindingMismatch field expected observed)
    requireWord field expected observed =
        require field (showWord expected) (showWord observed)

{- | Eliminate the exact closed lifecycle seed decoded from the protected
acquisition record.

The phase phantom is generated by matching the closed 'LifecyclePhase'
vocabulary; callers can inspect it but cannot choose or relabel it.  Before a
frame's cursor row exists this is its initial phase.  After the atomic handoff,
the acquisition-v1 value remains unchanged and 'withCurrentLifecycleCursor'
discovers that frame's authoritative current phase instead.
-}
withAcquisitionJournalPhase ::
    AcquisitionJournal scope planId brokerGeneration ->
    (forall phase. LifecyclePhase phase -> result) ->
    result
withAcquisitionJournalPhase (AcquisitionJournal _ _ _ _ _ phase) use = use phase

{- | The sole successor permit for one Open project-journal version.

Every operation that advances the journal returns exactly one of these, and the
version inside it is the version the *next* operation must present. A retained
older permit therefore cannot authorize a second advance — the compare-and-swap
against its version fails.
-}
newtype ProjectPermit scope planId = ProjectPermit TransactionPermit

instance Show (ProjectPermit scope planId) where
    show (ProjectPermit permit) = "ProjectPermit " <> show (transactionPermitVersion permit)

{- | The sole permit for a project journal in its terminal Closing epoch.

This is deliberately a different type from 'ProjectPermit': close recovery may
resume with it, but no Open-state operation accepts it and therefore it cannot
reopen the project journal.
-}
newtype ClosingProjectPermit scope planId = ClosingProjectPermit TransactionPermit

instance Show (ClosingProjectPermit scope planId) where
    show (ClosingProjectPermit permit) =
        "ClosingProjectPermit " <> show (transactionPermitVersion permit)

-- | Proof that the project journal reached its terminal Closed state.
newtype ClosedProjectPermit scope planId = ClosedProjectPermit TransactionPermit

instance Show (ClosedProjectPermit scope planId) where
    show (ClosedProjectPermit permit) =
        "ClosedProjectPermit " <> show (transactionPermitVersion permit)

-- | The journal version this permit authorizes the next transition against.
projectPermitVersion :: ProjectPermit scope planId -> Word64
projectPermitVersion (ProjectPermit permit) = transactionPermitVersion permit

projectKey :: Text -> Either SessionError RecordKey
projectKey planDigest = do
    digest <- recordName planDigest
    keyFor ("project." <> digest)

keyFor :: Text -> Either SessionError RecordKey
keyFor raw = either (Left . SessionStoreFailure) Right (mkRecordKey raw)

-- | 'mkRecordName' in this module's failure type.
recordName :: Text -> Either SessionError Text
recordName raw = either (Left . SessionStoreFailure) Right (mkRecordName raw)

-- | The identity a record-name component denotes ('recordNameIdentity').
recordIdentity :: Text -> Text
recordIdentity = recordNameIdentity

transactionFailure :: TransactionError -> SessionError
transactionFailure failure = case failure of
    TransactionStoreFailure storeFailure -> SessionStoreFailure storeFailure
    TransactionStalePermit version -> SessionStaleProjectPermit version
    _ -> SessionTransactionFailure (transactionErrorMessage failure)

ensureCoordinator ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError TransactionPermit)
ensureCoordinator session planDigest =
    fmap (either (Left . transactionFailure) Right) (ensureTransactionCoordinator session planDigest)

runTransaction ::
    ProtectedSession session ->
    Text ->
    TransactionPermit ->
    TxnKind ->
    [TransactionTarget] ->
    IO (Either SessionError TransactionPermit)
runTransaction session planDigest permit kind targets =
    fmap
        (either (Left . transactionFailure) Right)
        (runLifecycleTransaction session planDigest permit kind targets)

{- | Open or resume the dedicated acquisition record after Mode has verified
the live lease. Its store-local key covers project/run/broker; the strict
13-field payload collision-checks the full binding and mutable phase.
Fresh state is 'Prepare', and the exact record key/version and decoded phase are
retained for the next CAS. No user callback runs in this entry.
-}
openAcquisitionJournalKernel ::
    AcquisitionJournalAdmission ->
    ProtectedStore ->
    ProtectedSession session ->
    (forall liveSession. ProtectedSession liveSession -> IO (Either SessionError ())) ->
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
    Text ->
    IO (Either SessionError (AcquisitionJournal scope planId brokerGeneration))
openAcquisitionJournalKernel admission store session validateLive scope project storeId snapshot leaseKey leaseVersion run spec leasePlan epoch verb =
    case consumeAcquisitionJournalAdmissionKernel admission of
        ()
            | not (validAcquisitionBinding expected) -> invalid "binding"
            | storeId /= actualStore -> mismatch "protected store" storeId actualStore
            | storeId /= actualSessionStore -> mismatch "protected session store" storeId actualSessionStore
            | otherwise -> either (pure . Left) openKey (acquisitionKey expected)
  where
    expected =
        AcquisitionJournalBinding scope project storeId snapshot leaseKey leaseVersion run spec leasePlan epoch verb
    actualStore = protectedStoreIdentityText (protectedStoreIdentity store)
    actualSessionStore = protectedStoreIdentityText (sessionStoreIdentity session)
    invalid field = pure (Left (SessionAcquisitionBindingInvalid field))
    mismatch field wanted actual =
        pure (Left (SessionAcquisitionBindingMismatch field wanted actual))
    openKey key = do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (SessionStoreFailure failure))
            Right Nothing -> do
                written <- compareAndSwapProtectedRecord session key ExpectAbsent (encodeAcquisitionRecord expected Prepare)
                pure
                    ( either
                        (Left . SessionStoreFailure)
                        (\version -> Right (AcquisitionJournal store validateLive key version expected Prepare))
                        written
                    )
            Right (Just record) -> case decodeAcquisitionRecord (protectedRecordBytes record) of
                Nothing -> pure (Left (SessionRecordCorrupt "acquisition journal"))
                Just (recorded, SomeLifecyclePhase phase)
                    | protectedRecordBytes record /= encodeAcquisitionRecord recorded phase ->
                        pure (Left (SessionRecordCorrupt "acquisition journal"))
                    | recorded /= expected -> mismatch "durable binding" "exact binding" "different binding"
                    | otherwise ->
                        pure
                            ( Right
                                ( AcquisitionJournal
                                    store
                                    validateLive
                                    key
                                    (protectedRecordVersion record)
                                    recorded
                                    phase
                                )
                            )

-- | Existing-only child acquisition recovery; only Prepare may seed a cursor.
reopenExistingAcquisitionCursorKernel ::
    AcquisitionJournalAdmission ->
    ProtectedStore ->
    ProtectedSession session ->
    ( forall liveSession.
      ProtectedSession liveSession ->
      Text ->
      Word64 ->
      IO (Either SessionError ())
    ) ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    ProjectFrame scope specDigest planId configId frame ->
    LifecyclePhase phase ->
    IO
        ( Either
            SessionError
            ( AcquisitionJournal scope planId brokerGeneration
            , LifecycleCursor
                scope planId frame brokerGeneration VerbUp phase
            )
        )
reopenExistingAcquisitionCursorKernel
    admission store session validateLive stableScope project storeId snapshot run spec epoch frame phase =
        case consumeAcquisitionJournalAdmissionKernel admission of
            () -> do
                reopened <-
                    reopenExistingAcquisitionJournalInEntry
                        store
                        session
                        validateLive
                        stableScope
                        project
                        storeId
                        snapshot
                        run
                        spec
                        epoch
                        (projectVerbName ProjectUp)
                        Nothing
                case reopened of
                    Left failure -> pure (Left failure)
                    Right journal -> case validateLifecycleCursorRequest journal frame ProjectUp of
                        Left failure -> pure (Left failure)
                        Right () -> do
                            present <- requireChildCursorPresence session journal frame phase
                            case present of
                                Left failure -> pure (Left failure)
                                Right () -> do
                                    cursor <-
                                        openLifecycleCursorInEntry session journal frame ProjectUp phase
                                    pure ((\value -> (journal, value)) <$> cursor)

{- | Strict existing-only admission for one authenticated reverse child.

The hidden admission is consumed before the store, session, coordinates,
frame, or requested verb can be inspected.  Only an existing Down or Destroy
record with its original version-one Prepare seed can yield a journal.
-}
reopenExistingReverseAcquisitionJournalKernel ::
    AcquisitionJournalAdmission ->
    ProtectedStore ->
    ProtectedSession session ->
    ( forall liveSession.
      ProtectedSession liveSession ->
      Text ->
      Word64 ->
      IO (Either SessionError ())
    ) ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    IO (Either SessionError (AcquisitionJournal scope planId brokerGeneration))
{-# OPAQUE reopenExistingReverseAcquisitionJournalKernel #-}
reopenExistingReverseAcquisitionJournalKernel admission =
    case consumeAcquisitionJournalAdmissionKernel admission of
        () -> \store session validateLive stableScope project storeId snapshot run spec epoch frame verb ->
            let reopen verbName =
                    reopenExistingAcquisitionJournalInEntry
                        store session validateLive stableScope project storeId snapshot
                        run spec epoch verbName (Just ("prepare", 1))
             in case verb of
                    ProjectUp -> pure (Left (SessionCursorVerbMismatch "down or destroy" "up"))
                    ProjectDown -> do
                        opened <- reopen (projectVerbName verb)
                        pure $ opened >>= \journal -> journal <$ validateLifecycleCursorRequest journal frame verb
                    ProjectDestroy -> do
                        opened <- reopen (projectVerbName verb)
                        pure $ opened >>= \journal -> journal <$ validateLifecycleCursorRequest journal frame verb

reopenExistingAcquisitionJournalInEntry ::
    ProtectedStore ->
    ProtectedSession session ->
    ( forall liveSession.
      ProtectedSession liveSession ->
      Text ->
      Word64 ->
      IO (Either SessionError ())
    ) ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    Maybe (Text, Word64) ->
    IO (Either SessionError (AcquisitionJournal scope planId brokerGeneration))
reopenExistingAcquisitionJournalInEntry
    store session validateLive stableScope project storeId snapshot run spec epoch verbName required
        | storeId /= storeIdentity = mismatch "protected store" storeId storeIdentity
        | storeId /= sessionIdentity =
            mismatch "protected session store" storeId sessionIdentity
        | otherwise = either (pure . Left) reopen (childAcquisitionKey project run epoch)
      where
        storeIdentity = protectedStoreIdentityText (protectedStoreIdentity store)
        sessionIdentity = protectedStoreIdentityText (sessionStoreIdentity session)
        mismatch field wanted observed =
            pure (Left (SessionAcquisitionBindingMismatch field wanted observed))
        reopen recordKey = do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionAcquisitionMissing (recordKeyText recordKey)))
                Right (Just record) -> case decodeAcquisitionRecord (protectedRecordBytes record) of
                    Just (binding, SomeLifecyclePhase seed)
                        | protectedRecordBytes record /= encodeAcquisitionRecord binding seed ->
                            pure (Left (SessionRecordCorrupt "acquisition journal"))
                        | acquisitionBindingRootVerb binding /= verbName ->
                            pure
                                ( Left
                                    ( SessionCursorVerbMismatch
                                        (acquisitionBindingRootVerb binding)
                                        verbName
                                    )
                                )
                        | binding /= expectedBinding binding ->
                            mismatch "durable binding" "exact binding" "different binding"
                        | Just (requiredSeed, _) <- required
                        , acquisitionPhaseText seed /= requiredSeed ->
                            mismatch "seed phase" requiredSeed (acquisitionPhaseText seed)
                        | Just (_, requiredVersion) <- required
                        , recordVersionWord (protectedRecordVersion record) /= requiredVersion ->
                            mismatch
                                "record version"
                                (showWord requiredVersion)
                                (showWord (recordVersionWord (protectedRecordVersion record)))
                        | otherwise -> do
                            let check :: forall liveSession. ProtectedSession liveSession -> IO (Either SessionError ())
                                check live =
                                    validateLive live
                                        (acquisitionBindingLeaseRecord binding)
                                        (acquisitionBindingLeaseVersion binding)
                            valid <- check session
                            pure $ case valid of
                                Left failure -> Left failure
                                Right () ->
                                    Right
                                        ( AcquisitionJournal
                                            store
                                            check
                                            recordKey
                                            (protectedRecordVersion record)
                                            binding
                                            seed
                                        )
                    _ -> pure (Left (SessionRecordCorrupt "acquisition journal"))
        expectedBinding binding =
            AcquisitionJournalBinding
                stableScope project storeId snapshot
                (acquisitionBindingLeaseRecord binding)
                (acquisitionBindingLeaseVersion binding)
                run spec snapshot epoch verbName

requireChildCursorPresence ::
    ProtectedSession session ->
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    LifecyclePhase phase ->
    IO (Either SessionError ())
requireChildCursorPresence
    session
    (AcquisitionJournal _ _ sourceKey sourceVersion sourceBinding sourcePhase)
    frame
    requestedPhase
        | lifecyclePhaseName requestedPhase == lifecyclePhaseName Prepare = pure (Right ())
        | otherwise =
            case lifecycleCursorKey binding of
                Left failure -> pure (Left failure)
                Right key -> do
                    observed <- readProtectedRecord session key
                    pure $ case observed of
                        Left failure -> Left (SessionStoreFailure failure)
                        Right Nothing -> Left (SessionCursorMissing (projectFrameId frame))
                        Right (Just _) -> Right ()
      where
        binding = lifecycleCursorBinding sourceKey sourceVersion sourceBinding sourcePhase frame

childAcquisitionKey :: Text -> Text -> Word64 -> Either SessionError RecordKey
childAcquisitionKey project run brokerEpoch =
    keyFor
        ( "acquisition."
            <> project
            <> "."
            <> run
            <> "."
            <> showWord brokerEpoch
        )

acquisitionSchema :: Text
acquisitionSchema = "acquisition-journal-v1"

acquisitionKey :: AcquisitionJournalBinding -> Either SessionError RecordKey
acquisitionKey binding =
    keyFor
        ( "acquisition."
            <> acquisitionBindingProject binding
            <> "."
            <> acquisitionBindingRun binding
            <> "."
            <> showWord (acquisitionBindingBrokerEpoch binding)
        )

encodeAcquisitionRecord :: AcquisitionJournalBinding -> LifecyclePhase phase -> ByteString
encodeAcquisitionRecord binding phase =
    encodeFields
        [ acquisitionSchema
        , acquisitionBindingStableScope binding
        , acquisitionBindingProject binding
        , acquisitionBindingStore binding
        , acquisitionBindingSnapshotDigest binding
        , acquisitionBindingLeaseRecord binding
        , showWord (acquisitionBindingLeaseVersion binding)
        , acquisitionBindingRun binding
        , acquisitionBindingSpecDigest binding
        , acquisitionBindingLeasePlanDigest binding
        , showWord (acquisitionBindingBrokerEpoch binding)
        , acquisitionBindingRootVerb binding
        , acquisitionPhaseText phase
        ]

decodeAcquisitionRecord :: ByteString -> Maybe (AcquisitionJournalBinding, SomeLifecyclePhase)
decodeAcquisitionRecord raw = case decodeFields raw of
    [schema, scope, project, storeId, snapshot, leaseKey, leaseVersion, run, spec, leasePlan, epoch, verb, phase]
            | schema == acquisitionSchema -> do
                version <- readPositiveWord leaseVersion
                generation <- readPositiveWord epoch
                parsedPhase <- parseAcquisitionPhase phase
                let binding = AcquisitionJournalBinding scope project storeId snapshot leaseKey version run spec leasePlan generation verb
                if validAcquisitionBinding binding then Just (binding, parsedPhase) else Nothing
    _ -> Nothing

validAcquisitionBinding :: AcquisitionJournalBinding -> Bool
validAcquisitionBinding binding =
    acquisitionBindingLeaseVersion binding > 0
        && acquisitionBindingBrokerEpoch binding > 0
        && acquisitionBindingSnapshotDigest binding == acquisitionBindingLeasePlanDigest binding
        && isAcquisitionRootVerb (acquisitionBindingRootVerb binding)
        && all (not . Text.null) textFields
  where
    textFields =
        [ acquisitionBindingStableScope binding, acquisitionBindingProject binding
        , acquisitionBindingStore binding, acquisitionBindingSnapshotDigest binding
        , acquisitionBindingLeaseRecord binding, acquisitionBindingRun binding
        , acquisitionBindingSpecDigest binding, acquisitionBindingLeasePlanDigest binding
        ]

isAcquisitionRootVerb :: Text -> Bool
isAcquisitionRootVerb raw = raw == "up" || raw == "down" || raw == "destroy"

acquisitionPhaseText :: LifecyclePhase phase -> Text
acquisitionPhaseText = lifecyclePhaseName

data SomeLifecyclePhase where
    SomeLifecyclePhase :: LifecyclePhase phase -> SomeLifecyclePhase

parseAcquisitionPhase :: Text -> Maybe SomeLifecyclePhase
parseAcquisitionPhase raw = case raw of
    "prepare" -> Just (SomeLifecyclePhase Prepare)
    "execute" -> Just (SomeLifecyclePhase Execute)
    "teardown" -> Just (SomeLifecyclePhase Teardown)
    _ -> Nothing

showWord :: Word64 -> Text
showWord = Text.pack . show

readPositiveWord :: Text -> Maybe Word64
readPositiveWord raw = readWord raw >>= \value -> if value == 0 then Nothing else Just value

-- ---------------------------------------------------------------------------
-- Same-broker frame cursors

{- | The immutable durable binding of one frame-local cursor row.

The source acquisition bytes are retained whole, rather than projected into a
second copy of their fields.  Every open and successor can therefore require
the exact source key, version, and canonical bytes that originally handed the
phase to this frame.  The frame is kept out of the record key's filesystem
alphabet by hashing a length-framed identity, while the full value remains in
the payload for collision checking.
-}
data LifecycleCursorBinding = LifecycleCursorBinding
    { cursorBindingAcquisitionKey :: RecordKey
    , cursorBindingAcquisitionVersion :: Word64
    , cursorBindingAcquisitionBytes :: ByteString
    , cursorBindingFrame :: Text
    , cursorBindingVerb :: Text
    }
    deriving (Eq, Show)

{- | One exact frame-local lifecycle position under the broker generation that
opened its source acquisition journal.

The constructor is hidden and all six roles are nominal.  The retained record
version is the one and only predecessor version accepted by a phase successor;
an older cursor can therefore lose a race but cannot replay its transition.
-}
data LifecycleCursor scope planId frame brokerGeneration verb phase where
    LifecycleCursor ::
        ProtectedStore ->
        RecordKey ->
        RecordVersion ->
        ByteString ->
        LifecycleCursorBinding ->
        ProjectVerb verb ->
        LifecyclePhase phase ->
        LifecycleCursor scope planId frame brokerGeneration verb phase

type role LifecycleCursor nominal nominal nominal nominal nominal nominal

data SomeLifecycleCursor scope planId frame brokerGeneration verb where
    SomeLifecycleCursor ::
        LifecyclePhase phase ->
        LifecycleCursor scope planId frame brokerGeneration verb phase ->
        SomeLifecycleCursor scope planId frame brokerGeneration verb

instance Show (LifecycleCursor scope planId frame brokerGeneration verb phase) where
    show (LifecycleCursor _ _ version _ binding verb phase) =
        "LifecycleCursor "
            <> show (cursorBindingFrame binding)
            <> " "
            <> Text.unpack (projectVerbName verb)
            <> " "
            <> Text.unpack (lifecyclePhaseName phase)
            <> " "
            <> show (recordVersionWord version)

-- | Descriptive current-frame identity retained by the cursor.
lifecycleCursorFrame ::
    LifecycleCursor scope planId frame brokerGeneration verb phase -> Text
lifecycleCursorFrame (LifecycleCursor _ _ _ _ binding _ _) = cursorBindingFrame binding

-- | Exact protected cursor-row version retained for the next legal successor.
lifecycleCursorRecordVersion ::
    LifecycleCursor scope planId frame brokerGeneration verb phase -> Word64
lifecycleCursorRecordVersion (LifecycleCursor _ _ version _ _ _ _) = recordVersionWord version

-- | Closed root verb retained unchanged throughout this cursor lineage.
lifecycleCursorVerb ::
    LifecycleCursor scope planId frame brokerGeneration verb phase -> ProjectVerb verb
lifecycleCursorVerb (LifecycleCursor _ _ _ _ _ verb _) = verb

-- | Current frame-local phase retained by the exact cursor row.
lifecycleCursorPhase ::
    LifecycleCursor scope planId frame brokerGeneration verb phase -> LifecyclePhase phase
lifecycleCursorPhase (LifecycleCursor _ _ _ _ _ _ phase) = phase

{- | Compare the complete retained broker origin of a cursor and command
authority.

Nominal indices make an ordinary cross-origin substitution ill typed.  This
term check additionally refuses a hostile package substitution before an
effectful interpreter opens any durable state.
-}
lifecycleCursorMatchesCommandAuthority ::
    CommandAuthority scope planId frame brokerGeneration verb phase ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    Bool
lifecycleCursorMatchesCommandAuthority
    authority
    (LifecycleCursor cursorStore _ _ _ binding _ _) =
        case decodeAcquisitionRecord (cursorBindingAcquisitionBytes binding) of
            Nothing -> False
            Just (source, SomeLifecyclePhase _) ->
                let retainedStore = acquisitionBindingStore source
                    actualCursorStore =
                        protectedStoreIdentityText (protectedStoreIdentity cursorStore)
                 in retainedStore == actualCursorStore
                        && commandAuthorityOriginMatchesKernel
                            authority
                            (acquisitionBindingProject source)
                            retainedStore
                            (acquisitionBindingBrokerEpoch source)

{- | Revalidate a cursor's exact acquisition source and current durable row
inside the protected entry that is about to make a dependent transition.

This is deliberately an entry-scoped check: reading the row before acquiring
the lock and then opening a session afterwards would leave a revocation race.
-}
validateCurrentLifecycleCursor ::
    ProtectedSession session ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    IO (Either SessionError ())
validateCurrentLifecycleCursor session cursor = do
    source <- requireExactCursorSource session (cursorBinding cursor)
    case source of
        Left failure -> pure (Left failure)
        Right () -> requireExactCurrentLifecycleCursor session cursor

{- | Package-private exact durable coordinates for a successful @up@ source.

The hidden admission is consumed before either opaque value is inspected.  The
callback receives only the already-retained acquisition and current-cursor
records after their complete source binding has been compared; it grants no
transition, reservation, or mutation authority.
-}
withReverseRootSourceRecordsKernel ::
    AcquisitionJournalAdmission ->
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp TeardownPhase ->
    ( RecordKey ->
      RecordVersion ->
      ByteString ->
      RecordKey ->
      RecordVersion ->
      ByteString ->
      result
    ) ->
    Either SessionError result
{-# OPAQUE withReverseRootSourceRecordsKernel #-}
withReverseRootSourceRecordsKernel admission =
    admission `seq` consumeReverseRootSourceAdmission admission eliminate
  where
    eliminate journal cursor use =
        case validateJournalCursorSource journal cursor of
            Left failure -> Left failure
            Right () ->
                case (journal, cursor) of
                    ( AcquisitionJournal _ _ journalKey journalVersion binding seed
                        , LifecycleCursor _ cursorKey cursorVersion cursorBytes _ verb phase
                        )
                            | projectVerbName verb == projectVerbName ProjectUp
                            , lifecyclePhaseName phase == lifecyclePhaseName Teardown ->
                                Right
                                    ( use
                                        journalKey
                                        journalVersion
                                        (encodeAcquisitionRecord binding seed)
                                        cursorKey
                                        cursorVersion
                                        cursorBytes
                                    )
                            | otherwise ->
                                Left
                                    ( SessionCursorBindingMismatch
                                        "reverse root source"
                                        "up/teardown"
                                        (projectVerbName verb <> "/" <> lifecyclePhaseName phase)
                                    )

consumeReverseRootSourceAdmission :: AcquisitionJournalAdmission -> result -> result
{-# OPAQUE consumeReverseRootSourceAdmission #-}
consumeReverseRootSourceAdmission admission result =
    case consumeAcquisitionJournalAdmissionKernel admission of
        () -> result

{- | Open or resume only one reverse root target and deliver its exact
Teardown cursor after monotonically advancing any retained predecessor.

The hidden admission is forced before the journal, frame, or verb is
inspected.  Up is a total refusal, and the closed phase cases provide no
generic transition or phase callback to the caller.
-}
withReverseRootTargetLifecycleCursorKernel ::
    AcquisitionJournalAdmission ->
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    (LifecycleCursor scope planId frame brokerGeneration verb TeardownPhase -> IO result) ->
    IO (Either LifecycleError result)
{-# OPAQUE withReverseRootTargetLifecycleCursorKernel #-}
withReverseRootTargetLifecycleCursorKernel admission =
    case consumeAcquisitionJournalAdmissionKernel admission of
        () -> \journal@(AcquisitionJournal store validateLive _ sourceVersion _ seedPhase) frame verb use ->
            let advance = case seedPhase of
                    Prepare
                        | recordVersionWord sourceVersion == 1 -> case validateLifecycleCursorRequest journal frame verb of
                            Left failure -> pure (Left failure)
                            Right () -> do
                                terminal <-
                                    inLifecycleCursorEntry store $ \session -> do
                                        live <- validateLive session
                                        case live of
                                            Left failure -> pure (Left failure)
                                            Right () -> do
                                                current <-
                                                    openCurrentLifecycleCursorInEntry session Nothing journal frame verb
                                                case current of
                                                    Left failure -> pure (Left failure)
                                                    Right (SomeLifecycleCursor phase cursor) -> case phase of
                                                        Prepare -> case checkedVersion 1 cursor of
                                                            Left failure -> pure (Left failure)
                                                            Right prepareCursor -> do
                                                                executed <- advanceLifecycleCursorInEntry session prepareCursor Execute
                                                                case executed >>= checkedVersion 2 of
                                                                    Left failure -> pure (Left failure)
                                                                    Right executeCursor -> do
                                                                        teardown <- advanceLifecycleCursorInEntry session executeCursor Teardown
                                                                        pure (teardown >>= checkedVersion 3)
                                                        Execute -> case checkedVersion 2 cursor of
                                                            Left failure -> pure (Left failure)
                                                            Right executeCursor -> do
                                                                teardown <- advanceLifecycleCursorInEntry session executeCursor Teardown
                                                                pure (teardown >>= checkedVersion 3)
                                                        Teardown -> pure (checkedVersion 3 cursor)
                                either (pure . Left) (fmap Right . use) terminal
                        | otherwise -> refuseAcquisition "record version" "1" (showWord (recordVersionWord sourceVersion))
                    Execute -> refuseAcquisition "seed phase" "prepare" "execute"
                    Teardown -> refuseAcquisition "seed phase" "prepare" "teardown"
                refuseAcquisition field expected observed = pure (Left (SessionAcquisitionBindingMismatch field expected observed))
             in case verb of
                ProjectUp -> pure (Left (SessionCursorVerbMismatch "down or destroy" "up"))
                ProjectDown -> advance
                ProjectDestroy -> advance
  where
    checkedVersion expected cursor
        = cursor
            <$ requireCursorBindingWord
                "reverse root target cursor version"
                expected
                (lifecycleCursorRecordVersion cursor)

{- | Open or exactly resume one frame-local cursor.

There is one atomic authority handoff.  While the derived cursor row is absent,
the unchanged acquisition-v1 phase is the initial seed and the absent-to-present
compare-and-swap copies it into the full frame binding.  Once the row exists,
its phase is authoritative for that frame; the acquisition phase is no longer
consulted as a current-position field.  A crash before the compare-and-swap
therefore resumes from acquisition, and a crash after it resumes from the
cursor row.  No two-record update or torn phase is possible.

Every path still rereads the exact source acquisition key, version, and
canonical bytes.  The root verb remains immutable, an existing exact row is
resumed without a write, and the continuation runs only after the protected
entry has closed.  Compare-and-swap reservation is at most once; callback
delivery is deliberately at least once.  An exact retry, a concurrent
current-row reader, or a retry after the callback throws can receive the same
durable current cursor again.
-}
withLifecycleCursor ::
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    LifecyclePhase phase ->
    (LifecycleCursor scope planId frame brokerGeneration verb phase -> IO result) ->
    IO (Either LifecycleError result)
withLifecycleCursor
    journal@(AcquisitionJournal store _ _ _ _ _)
    frame
    verb
    phase
    use =
        case validateLifecycleCursorRequest journal frame verb of
            Left failure -> pure (Left failure)
            Right () -> do
                opened <-
                    inLifecycleCursorEntry store $ \session ->
                        openLifecycleCursorInEntry
                            session
                            journal
                            frame
                            verb
                            phase
                case opened of
                    Left failure -> pure (Left failure)
                    Right cursor -> Right <$> use cursor

{- | Discover and resume the authoritative current phase for one exact frame.

Before the first cursor row this reports the acquisition seed; afterwards it
reports the phase decoded from the exact per-frame row.  The existential phase
is generated by the closed decoder and delivered with its matching cursor only
after the protected entry closes, so recovery never has to guess or probe an
expected phase.
-}
withCurrentLifecycleCursor ::
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    ( forall phase.
      LifecyclePhase phase ->
      LifecycleCursor scope planId frame brokerGeneration verb phase ->
      IO result
    ) ->
    IO (Either LifecycleError result)
withCurrentLifecycleCursor
    journal@(AcquisitionJournal store _ _ _ _ _)
    frame
    verb
    use =
        case validateLifecycleCursorRequest journal frame verb of
            Left failure -> pure (Left failure)
            Right () -> do
                opened <-
                    inLifecycleCursorEntry store $ \session ->
                        openCurrentLifecycleCursorInEntry session Nothing journal frame verb
                case opened of
                    Left failure -> pure (Left failure)
                    Right (SomeLifecycleCursor phase cursor) -> Right <$> use phase cursor

{- | Consume exactly one Prepare cursor version and yield its Execute successor.

The successor is written and read back under one protected entry before the
entry is released. Callback delivery is at least once: if it throws, recovery
rediscovers the already-durable Execute row rather than replaying this CAS.
-}
withExecuteLifecycleCursor ::
    LifecycleCursor scope planId frame brokerGeneration verb PreparePhase ->
    (LifecycleCursor scope planId frame brokerGeneration verb ExecutePhase -> IO result) ->
    IO (Either LifecycleError result)
withExecuteLifecycleCursor cursor use =
    withLifecycleCursorSuccessor cursor Execute use

{- | Consume exactly one Execute cursor version and yield its Teardown successor.

There is intentionally no successor eliminator for Teardown and no
verb-changing edge within one acquisition invocation.
-}
withTeardownLifecycleCursor ::
    LifecycleCursor scope planId frame brokerGeneration verb ExecutePhase ->
    (LifecycleCursor scope planId frame brokerGeneration verb TeardownPhase -> IO result) ->
    IO (Either LifecycleError result)
withTeardownLifecycleCursor cursor use =
    withLifecycleCursorSuccessor cursor Teardown use

{- | Atomically reserve one command invocation from an exact, still-current
frame cursor.

The 'CommandReservation' argument is deliberately type-sealed at this exposed
module boundary: its type and sole producer remain package-private in
"HostBootstrap.Authority.Kernel".  The lifecycle authority facade can therefore
join its plan, root, frame, and context checks before entering this narrow
bridge, while public callers cannot manufacture the stable reservation
members.

One protected entry revalidates the live mode, bound lease, and canonical
snapshot retained by the acquisition opener; proves that the journal is the
cursor's exact source; rereads the exact current cursor key, version, bytes,
binding, verb, and phase; and only then consumes the one-use reservation.  A
stale cursor or any live-evidence drift therefore returns before the invocation
record can be written.
-}
reserveCurrentLifecycleCommandKernel ::
    forall scope planId frame brokerGeneration verb phase.
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    CommandReservation scope planId frame brokerGeneration verb phase ->
    IO
        ( Either
            AuthorityError
            (CommandAuthority scope planId frame brokerGeneration verb phase)
        )
reserveCurrentLifecycleCommandKernel
    journal@(AcquisitionJournal store validateLive _ _ binding _)
    cursor
    reservation = do
        entered <-
            withProtectedEntry store $ \session -> do
                outcome <- reserveInEntry session
                pure (Right outcome)
        pure $ case entered of
            Left failure -> Left (AuthorityStoreFailure failure)
            Right outcome -> outcome
  where
    reserveInEntry ::
        forall session.
        ProtectedSession session ->
        IO
            ( Either
                AuthorityError
                (CommandAuthority scope planId frame brokerGeneration verb phase)
            )
    reserveInEntry session = do
        live <- validateLive session
        case live of
            Left failure -> pure (Left (sessionAuthorityFailure failure))
            Right () -> case validateJournalCursorSource journal cursor of
                Left failure -> pure (Left (sessionAuthorityFailure failure))
                Right () -> do
                    source <- requireExactCursorSource session (cursorBinding cursor)
                    case source of
                        Left failure -> pure (Left (sessionAuthorityFailure failure))
                        Right () -> do
                            current <- requireExactCurrentLifecycleCursor session cursor
                            case current of
                                Left failure -> pure (Left (sessionAuthorityFailure failure))
                                Right () ->
                                    case
                                        withInstalledProjectKernel
                                            (acquisitionBindingProject binding)
                                            ( \project ->
                                                reserveCommandInvocationKernel
                                                    session
                                                    project
                                                    reservation
                                                    (pure . Right)
                                            )
                                    of
                                        Left failure -> pure (Left failure)
                                        Right reserve -> reserve

cursorBinding ::
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    LifecycleCursorBinding
cursorBinding (LifecycleCursor _ _ _ _ binding _ _) = binding

validateJournalCursorSource ::
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    Either SessionError ()
validateJournalCursorSource
    (AcquisitionJournal journalStore _ sourceKey sourceVersion sourceBinding sourcePhase)
    (LifecycleCursor cursorStore cursorKey _ retainedBytes binding verb phase) = do
        requireCursorBindingText
            "protected store"
            (protectedStoreIdentityText (protectedStoreIdentity journalStore))
            (protectedStoreIdentityText (protectedStoreIdentity cursorStore))
        requireCursorBindingText
            "source acquisition key"
            (recordKeyText sourceKey)
            (recordKeyText (cursorBindingAcquisitionKey binding))
        requireCursorBindingWord
            "source acquisition version"
            (recordVersionWord sourceVersion)
            (cursorBindingAcquisitionVersion binding)
        requireCursorBindingBytes
            "source acquisition bytes"
            (encodeAcquisitionRecord sourceBinding sourcePhase)
            (cursorBindingAcquisitionBytes binding)
        requireCursorBindingText
            "source protected store"
            (acquisitionBindingStore sourceBinding)
            (protectedStoreIdentityText (protectedStoreIdentity journalStore))
        requireCursorBindingText
            "cursor verb"
            (cursorBindingVerb binding)
            (projectVerbName verb)
        expectedKey <- lifecycleCursorKey binding
        requireCursorBindingText
            "cursor key"
            (recordKeyText expectedKey)
            (recordKeyText cursorKey)
        requireCursorBindingBytes
            "retained cursor bytes"
            (encodeLifecycleCursorRecord binding phase)
            retainedBytes

requireExactCurrentLifecycleCursor ::
    ProtectedSession session ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    IO (Either SessionError ())
requireExactCurrentLifecycleCursor
    session
    (LifecycleCursor _ key retainedVersion retainedBytes retainedBinding retainedVerb retainedPhase) = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (SessionStoreFailure failure)
            Right Nothing ->
                Left
                    ( SessionCursorBindingMismatch
                        "cursor row"
                        (recordKeyText key)
                        "absent"
                    )
            Right (Just record)
                | protectedRecordVersion record /= retainedVersion ->
                    Left
                        ( SessionStaleCursorVersion
                            (recordVersionWord retainedVersion)
                            (recordVersionWord (protectedRecordVersion record))
                        )
                | protectedRecordBytes record /= retainedBytes ->
                    Left
                        ( SessionCursorBindingMismatch
                            "cursor row bytes"
                            "exact retained bytes"
                            "different bytes"
                        )
                | otherwise ->
                    case decodeLifecycleCursorRecord (protectedRecordBytes record) of
                        Nothing -> Left (SessionRecordCorrupt "lifecycle cursor")
                        Just (recordedBinding, SomeLifecyclePhase recordedPhase)
                            | protectedRecordBytes record
                                /= encodeLifecycleCursorRecord recordedBinding recordedPhase ->
                                Left (SessionRecordCorrupt "lifecycle cursor")
                            | recordedBinding /= retainedBinding ->
                                Left
                                    ( SessionCursorBindingMismatch
                                        "durable binding"
                                        "exact acquisition and frame binding"
                                        "different binding"
                                    )
                            | cursorBindingVerb recordedBinding
                                /= projectVerbName retainedVerb ->
                                Left
                                    ( SessionCursorVerbMismatch
                                        (cursorBindingVerb recordedBinding)
                                        (projectVerbName retainedVerb)
                                    )
                            | lifecyclePhaseName recordedPhase
                                /= lifecyclePhaseName retainedPhase ->
                                Left
                                    ( SessionCursorPhaseMismatch
                                        (lifecyclePhaseName recordedPhase)
                                        (lifecyclePhaseName retainedPhase)
                                    )
                            | otherwise -> Right ()

requireCursorBindingText :: Text -> Text -> Text -> Either SessionError ()
requireCursorBindingText field expected observed
    | expected == observed = Right ()
    | otherwise = Left (SessionCursorBindingMismatch field expected observed)

requireCursorBindingWord :: Text -> Word64 -> Word64 -> Either SessionError ()
requireCursorBindingWord field expected observed =
    requireCursorBindingText field (showWord expected) (showWord observed)

requireCursorBindingBytes :: Text -> ByteString -> ByteString -> Either SessionError ()
requireCursorBindingBytes field expected observed
    | expected == observed = Right ()
    | otherwise =
        Left
            ( SessionCursorBindingMismatch
                field
                "exact canonical bytes"
                "different bytes"
            )

sessionAuthorityFailure :: SessionError -> AuthorityError
sessionAuthorityFailure failure = case failure of
    SessionStoreFailure storeFailure -> AuthorityStoreFailure storeFailure
    _ -> AuthorityMalformedBinding (Text.pack (sessionErrorMessage failure))

withLifecycleCursorSuccessor ::
    LifecycleCursor scope planId frame brokerGeneration verb from ->
    LifecyclePhase to ->
    (LifecycleCursor scope planId frame brokerGeneration verb to -> IO result) ->
    IO (Either LifecycleError result)
withLifecycleCursorSuccessor
    cursor@(LifecycleCursor store _ _ _ _ _ _)
    successorPhase
    use = do
        advanced <-
            inLifecycleCursorEntry store $ \session ->
                advanceLifecycleCursorInEntry session cursor successorPhase
        case advanced of
            Left failure -> pure (Left failure)
            Right successor -> Right <$> use successor

inLifecycleCursorEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either SessionError result)) ->
    IO (Either SessionError result)
inLifecycleCursorEntry store action = do
    entered <- withProtectedEntry store (fmap Right . action)
    pure $ case entered of
        Left failure -> Left (SessionStoreFailure failure)
        Right result -> result

openLifecycleCursorInEntry ::
    ProtectedSession session ->
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    LifecyclePhase phase ->
    IO (Either SessionError (LifecycleCursor scope planId frame brokerGeneration verb phase))
openLifecycleCursorInEntry
    session
    journal
    frame
    verb
    requestedPhase = do
        opened <-
            openCurrentLifecycleCursorInEntry
                session
                (Just (lifecyclePhaseName requestedPhase))
                journal
                frame
                verb
        pure $ case opened of
            Left failure -> Left failure
            Right
                ( SomeLifecycleCursor
                    recordedPhase
                    (LifecycleCursor store key version bytes binding recordedVerb _)
                    )
                    | lifecyclePhaseName recordedPhase
                        /= lifecyclePhaseName requestedPhase ->
                        Left
                            ( SessionCursorPhaseMismatch
                                (lifecyclePhaseName recordedPhase)
                                (lifecyclePhaseName requestedPhase)
                            )
                    | otherwise ->
                        Right
                            ( LifecycleCursor
                                store
                                key
                                version
                                bytes
                                binding
                                recordedVerb
                                requestedPhase
                            )

openCurrentLifecycleCursorInEntry ::
    ProtectedSession session ->
    Maybe Text ->
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    IO
        ( Either
            SessionError
            (SomeLifecycleCursor scope planId frame brokerGeneration verb)
        )
openCurrentLifecycleCursorInEntry
    session
    expectedPhase
    (AcquisitionJournal store _ sourceKey sourceVersion sourceBinding sourcePhase)
    frame
    verb
        | projectVerbName verb /= acquisitionBindingRootVerb sourceBinding =
            pure
                ( Left
                    ( SessionCursorVerbMismatch
                        (acquisitionBindingRootVerb sourceBinding)
                        (projectVerbName verb)
                    )
                )
        | otherwise = do
            let binding = lifecycleCursorBinding sourceKey sourceVersion sourceBinding sourcePhase frame
            source <- requireExactCursorSource session binding
            case source of
                Left failure -> pure (Left failure)
                Right () -> case lifecycleCursorKey binding of
                    Left failure -> pure (Left failure)
                    Right cursorKey -> do
                        observed <- readProtectedRecord session cursorKey
                        case observed of
                            Left failure -> pure (Left (SessionStoreFailure failure))
                            Right Nothing
                                | Just requested <- expectedPhase
                                , requested /= lifecyclePhaseName sourcePhase ->
                                    pure
                                        ( Left
                                            ( SessionCursorPhaseMismatch
                                                (lifecyclePhaseName sourcePhase)
                                                requested
                                            )
                                        )
                                | otherwise -> do
                                    let desiredBytes =
                                            encodeLifecycleCursorRecord binding sourcePhase
                                    written <-
                                        compareAndSwapProtectedRecord
                                            session
                                            cursorKey
                                            ExpectAbsent
                                            desiredBytes
                                    case written of
                                        Left failure -> pure (Left (SessionStoreFailure failure))
                                        Right version -> do
                                            verified <-
                                                verifyLifecycleCursorWrite
                                                    session
                                                    cursorKey
                                                    version
                                                    desiredBytes
                                            pure
                                                ( ( \record ->
                                                        SomeLifecycleCursor
                                                            sourcePhase
                                                            ( LifecycleCursor
                                                                store
                                                                cursorKey
                                                                (protectedRecordVersion record)
                                                                (protectedRecordBytes record)
                                                                binding
                                                                verb
                                                                sourcePhase
                                                            )
                                                  )
                                                    <$> verified
                                                )
                            Right (Just record) ->
                                resumeCurrentLifecycleCursor
                                    store
                                    cursorKey
                                    record
                                    binding
                                    verb

resumeCurrentLifecycleCursor ::
    ProtectedStore ->
    RecordKey ->
    ProtectedRecord ->
    LifecycleCursorBinding ->
    ProjectVerb verb ->
    IO
        ( Either
            SessionError
            (SomeLifecycleCursor scope planId frame brokerGeneration verb)
        )
resumeCurrentLifecycleCursor store key record expected verb =
    pure $ case decodeLifecycleCursorRecord (protectedRecordBytes record) of
        Nothing -> Left (SessionRecordCorrupt "lifecycle cursor")
        Just (recorded, SomeLifecyclePhase recordedPhase)
            | protectedRecordBytes record
                /= encodeLifecycleCursorRecord recorded recordedPhase ->
                Left (SessionRecordCorrupt "lifecycle cursor")
            | recorded /= expected ->
                Left
                    ( SessionCursorBindingMismatch
                        "durable binding"
                        "exact acquisition and frame binding"
                        "different binding"
                    )
            | otherwise ->
                Right
                    ( SomeLifecycleCursor
                        recordedPhase
                        ( LifecycleCursor
                            store
                            key
                            (protectedRecordVersion record)
                            (protectedRecordBytes record)
                            recorded
                            verb
                            recordedPhase
                        )
                    )

lifecycleCursorBinding ::
    RecordKey ->
    RecordVersion ->
    AcquisitionJournalBinding ->
    LifecyclePhase phase ->
    ProjectFrame scope specDigest planId configId frame ->
    LifecycleCursorBinding
lifecycleCursorBinding sourceKey sourceVersion sourceBinding sourcePhase frame =
    LifecycleCursorBinding
        { cursorBindingAcquisitionKey = sourceKey
        , cursorBindingAcquisitionVersion = recordVersionWord sourceVersion
        , cursorBindingAcquisitionBytes = encodeAcquisitionRecord sourceBinding sourcePhase
        , cursorBindingFrame = projectFrameId frame
        , cursorBindingVerb = acquisitionBindingRootVerb sourceBinding
        }

maxLifecycleCursorFrameBytes :: Int
maxLifecycleCursorFrameBytes = 4096

maxLifecycleCursorPayloadBytes :: Int
maxLifecycleCursorPayloadBytes = 65536

validateLifecycleCursorRequest ::
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    ProjectVerb verb ->
    Either SessionError ()
validateLifecycleCursorRequest
    (AcquisitionJournal _ _ sourceKey sourceVersion sourceBinding sourcePhase)
    frame
    verb
        | projectVerbName verb /= acquisitionBindingRootVerb sourceBinding =
            Left
                ( SessionCursorVerbMismatch
                    (acquisitionBindingRootVerb sourceBinding)
                    (projectVerbName verb)
                )
        | Text.null frameName = Left (SessionCursorBindingInvalid "frame")
        | ByteString.length frameBytes > maxLifecycleCursorFrameBytes =
            Left (SessionCursorBindingInvalid "frame length")
        | maximum (map ByteString.length phasePayloads)
            > maxLifecycleCursorPayloadBytes =
            Left (SessionCursorBindingInvalid "payload length")
        | otherwise = () <$ lifecycleCursorKey binding
  where
    binding = lifecycleCursorBinding sourceKey sourceVersion sourceBinding sourcePhase frame
    frameName = cursorBindingFrame binding
    frameBytes = TextEncoding.encodeUtf8 frameName
    phasePayloads =
        [ encodeLifecycleCursorRecord binding Prepare
        , encodeLifecycleCursorRecord binding Execute
        , encodeLifecycleCursorRecord binding Teardown
        ]

advanceLifecycleCursorInEntry ::
    ProtectedSession session ->
    LifecycleCursor scope planId frame brokerGeneration verb from ->
    LifecyclePhase to ->
    IO (Either SessionError (LifecycleCursor scope planId frame brokerGeneration verb to))
advanceLifecycleCursorInEntry
    session
    (LifecycleCursor store key retainedVersion retainedBytes binding verb retainedPhase)
    successorPhase = do
        source <- requireExactCursorSource session binding
        case source of
            Left failure -> pure (Left failure)
            Right () -> do
                observed <- readProtectedRecord session key
                case observed of
                    Left failure -> pure (Left (SessionStoreFailure failure))
                    Right Nothing ->
                        pure
                            ( Left
                                ( SessionCursorBindingMismatch
                                    "cursor row"
                                    (recordKeyText key)
                                    "absent"
                                )
                            )
                    Right (Just record)
                        | protectedRecordVersion record /= retainedVersion ->
                            pure
                                ( Left
                                    ( SessionStaleCursorVersion
                                        (recordVersionWord retainedVersion)
                                        (recordVersionWord (protectedRecordVersion record))
                                    )
                                )
                        | protectedRecordBytes record /= retainedBytes ->
                            pure
                                ( Left
                                    ( SessionCursorBindingMismatch
                                        "cursor row bytes"
                                        "exact retained bytes"
                                        "different bytes"
                                    )
                                )
                        | otherwise ->
                            case decodeLifecycleCursorRecord (protectedRecordBytes record) of
                                Nothing -> pure (Left (SessionRecordCorrupt "lifecycle cursor"))
                                Just (recorded, SomeLifecyclePhase recordedPhase)
                                    | protectedRecordBytes record
                                        /= encodeLifecycleCursorRecord recorded recordedPhase ->
                                        pure (Left (SessionRecordCorrupt "lifecycle cursor"))
                                    | recorded /= binding ->
                                        pure
                                            ( Left
                                                ( SessionCursorBindingMismatch
                                                    "durable binding"
                                                    "exact acquisition and frame binding"
                                                    "different binding"
                                                )
                                            )
                                    | lifecyclePhaseName recordedPhase
                                        /= lifecyclePhaseName retainedPhase ->
                                        pure
                                            ( Left
                                                ( SessionCursorPhaseMismatch
                                                    (lifecyclePhaseName recordedPhase)
                                                    (lifecyclePhaseName retainedPhase)
                                                )
                                            )
                                    | otherwise -> do
                                        let desiredBytes =
                                                encodeLifecycleCursorRecord binding successorPhase
                                        written <-
                                            compareAndSwapProtectedRecord
                                                session
                                                key
                                                (ExpectVersion retainedVersion)
                                                desiredBytes
                                        case written of
                                            Left failure -> pure (Left (SessionStoreFailure failure))
                                            Right version -> do
                                                verified <-
                                                    verifyLifecycleCursorWrite
                                                        session
                                                        key
                                                        version
                                                        desiredBytes
                                                pure
                                                    ( ( \successorRecord ->
                                                            LifecycleCursor
                                                                store
                                                                key
                                                                (protectedRecordVersion successorRecord)
                                                                (protectedRecordBytes successorRecord)
                                                                binding
                                                                verb
                                                                successorPhase
                                                      )
                                                        <$> verified
                                                    )

verifyLifecycleCursorWrite ::
    ProtectedSession session ->
    RecordKey ->
    RecordVersion ->
    ByteString ->
    IO (Either SessionError ProtectedRecord)
verifyLifecycleCursorWrite session key expectedVersion expectedBytes = do
    observed <- readProtectedRecord session key
    pure $ case observed of
        Left failure -> Left (SessionStoreFailure failure)
        Right Nothing ->
            Left
                ( SessionCursorBindingMismatch
                    "cursor write readback"
                    (recordKeyText key)
                    "absent"
                )
        Right (Just record)
            | protectedRecordVersion record /= expectedVersion ->
                Left
                    ( SessionStaleCursorVersion
                        (recordVersionWord expectedVersion)
                        (recordVersionWord (protectedRecordVersion record))
                    )
            | protectedRecordBytes record /= expectedBytes ->
                Left
                    ( SessionCursorBindingMismatch
                        "cursor write readback bytes"
                        "exact canonical successor bytes"
                        "different bytes"
                    )
            | otherwise -> Right record

requireExactCursorSource ::
    ProtectedSession session ->
    LifecycleCursorBinding ->
    IO (Either SessionError ())
requireExactCursorSource session binding = do
    observed <- readProtectedRecord session (cursorBindingAcquisitionKey binding)
    pure $ case observed of
        Left failure -> Left (SessionStoreFailure failure)
        Right Nothing ->
            Left
                ( SessionCursorBindingMismatch
                    "source acquisition record"
                    (recordKeyText (cursorBindingAcquisitionKey binding))
                    "absent"
                )
        Right (Just record)
            | recordVersionWord (protectedRecordVersion record)
                /= cursorBindingAcquisitionVersion binding ->
                Left
                    ( SessionCursorBindingMismatch
                        "source acquisition version"
                        (showWord (cursorBindingAcquisitionVersion binding))
                        (showWord (recordVersionWord (protectedRecordVersion record)))
                    )
            | protectedRecordBytes record /= cursorBindingAcquisitionBytes binding ->
                Left
                    ( SessionCursorBindingMismatch
                        "source acquisition bytes"
                        "exact canonical bytes"
                        "different bytes"
                    )
            | not (canonicalAcquisitionRecord (protectedRecordBytes record)) ->
                Left (SessionRecordCorrupt "source acquisition journal")
            | otherwise -> Right ()

canonicalAcquisitionRecord :: ByteString -> Bool
canonicalAcquisitionRecord raw = case decodeAcquisitionRecord raw of
    Just (binding, SomeLifecyclePhase phase) -> raw == encodeAcquisitionRecord binding phase
    Nothing -> False

lifecycleCursorSchema :: Text
lifecycleCursorSchema = "lifecycle-cursor-v1"

lifecycleCursorKey :: LifecycleCursorBinding -> Either SessionError RecordKey
lifecycleCursorKey binding =
    keyFor
        ( "cursor."
            <> sha256Hex
                ( encodeLengthFramed
                    [ TextEncoding.encodeUtf8 "lifecycle-cursor-key-v1"
                    , TextEncoding.encodeUtf8
                        (recordKeyText (cursorBindingAcquisitionKey binding))
                    , TextEncoding.encodeUtf8 (cursorBindingFrame binding)
                    ]
                )
        )

encodeLifecycleCursorRecord ::
    LifecycleCursorBinding ->
    LifecyclePhase phase ->
    ByteString
encodeLifecycleCursorRecord binding phase =
    encodeLengthFramed
        [ TextEncoding.encodeUtf8 lifecycleCursorSchema
        , TextEncoding.encodeUtf8
            (recordKeyText (cursorBindingAcquisitionKey binding))
        , TextEncoding.encodeUtf8
            (showWord (cursorBindingAcquisitionVersion binding))
        , cursorBindingAcquisitionBytes binding
        , TextEncoding.encodeUtf8 (cursorBindingFrame binding)
        , TextEncoding.encodeUtf8 (cursorBindingVerb binding)
        , TextEncoding.encodeUtf8 (lifecyclePhaseName phase)
        ]

decodeLifecycleCursorRecord ::
    ByteString ->
    Maybe (LifecycleCursorBinding, SomeLifecyclePhase)
decodeLifecycleCursorRecord raw
    | ByteString.length raw > maxLifecycleCursorPayloadBytes = Nothing
    | otherwise = do
        fields <- decodeLengthFramedExactly 7 raw
        case fields of
            [schemaRaw, sourceKeyRaw, sourceVersionRaw, sourceBytes, frameRaw, verbRaw, phaseRaw] -> do
                schema <- decodeCursorText schemaRaw
                if schema /= lifecycleCursorSchema then Nothing else do
                    sourceKeyText <- decodeCursorText sourceKeyRaw
                    sourceKey <- either (const Nothing) Just (mkRecordKey sourceKeyText)
                    sourceVersionText <- decodeCursorText sourceVersionRaw
                    sourceVersionWord <- readPositiveWord sourceVersionText
                    frame <- decodeCursorText frameRaw
                    verb <- decodeCursorText verbRaw
                    phaseText <- decodeCursorText phaseRaw
                    phase <- parseAcquisitionPhase phaseText
                    let binding =
                            LifecycleCursorBinding
                                { cursorBindingAcquisitionKey = sourceKey
                                , cursorBindingAcquisitionVersion = sourceVersionWord
                                , cursorBindingAcquisitionBytes = sourceBytes
                                , cursorBindingFrame = frame
                                , cursorBindingVerb = verb
                                }
                    if validLifecycleCursorBinding binding
                        then Just (binding, phase)
                        else Nothing
            _ -> Nothing

validLifecycleCursorBinding :: LifecycleCursorBinding -> Bool
validLifecycleCursorBinding binding =
    not (Text.null (cursorBindingFrame binding))
        && ByteString.length (TextEncoding.encodeUtf8 (cursorBindingFrame binding))
            <= maxLifecycleCursorFrameBytes
        && ByteString.length (cursorBindingAcquisitionBytes binding)
            <= maxLifecycleCursorPayloadBytes
        && isAcquisitionRootVerb (cursorBindingVerb binding)
        && case decodeAcquisitionRecord (cursorBindingAcquisitionBytes binding) of
            Just (sourceBinding, SomeLifecyclePhase sourcePhase) ->
                cursorBindingAcquisitionBytes binding
                    == encodeAcquisitionRecord sourceBinding sourcePhase
                    && cursorBindingVerb binding == acquisitionBindingRootVerb sourceBinding
            Nothing -> False

encodeLengthFramed :: [ByteString] -> ByteString
encodeLengthFramed =
    ByteString.concat
        . map
            ( \field ->
                ByteStringChar8.pack (show (ByteString.length field))
                    <> ":"
                    <> field
            )

decodeLengthFramedExactly :: Int -> ByteString -> Maybe [ByteString]
decodeLengthFramedExactly expected raw = go expected raw []
  where
    go remaining rest fields
        | remaining == 0 =
            if ByteString.null rest then Just (reverse fields) else Nothing
        | ByteString.null rest = Nothing
        | otherwise = do
            let (lengthRaw, separatorAndRest) = ByteStringChar8.break (== ':') rest
            if ByteString.null lengthRaw
                || ByteString.null separatorAndRest
                || not (ByteString.all isAsciiDigit lengthRaw)
                then Nothing
                else do
                    fieldLength <- parseFieldLength lengthRaw
                    let afterSeparator = ByteString.drop 1 separatorAndRest
                    if ByteString.length afterSeparator < fieldLength
                        then Nothing
                        else do
                            let (field, trailing) =
                                    ByteString.splitAt fieldLength afterSeparator
                            go (remaining - 1) trailing (field : fields)
    isAsciiDigit byte = byte >= 48 && byte <= 57
    parseFieldLength bytes = case ByteStringChar8.readInteger bytes of
        Just (value, trailing)
            | ByteString.null trailing
                && value >= 0
                && value <= toInteger (maxBound :: Int) ->
                Just (fromInteger value)
        _ -> Nothing

decodeCursorText :: ByteString -> Maybe Text
decodeCursorText raw = either (const Nothing) Just (TextEncoding.decodeUtf8' raw)

sha256Hex :: ByteString -> Text
sha256Hex bytes =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 bytes)))
  where
    hex byte =
        [ ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `div` 16))
        , ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `mod` 16))
        ]

{- | Open (or resume) the plan's project journal, returning the permit for its
current version. Idempotent: an already-open journal is observed, not
republished, so a re-invocation after a crash does not reset the version other
holders are contending on.
-}
openProjectJournal ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (ProjectPermit scope planId))
openProjectJournal session planDigest =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right permit -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right (Just record) -> case decodeJournalState (transactionRecordPayload record) of
                            Just OpenProject -> pure (Right (ProjectPermit permit))
                            -- A closing or closed project accepts no new work:
                            -- the distinction matters to recovery, not to this
                            -- opener.
                            Just (ClosingProject _) -> pure (Left (SessionProjectClosing planDigest))
                            Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                            Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                        Right Nothing -> do
                            advanced <-
                                runTransaction
                                    session
                                    planDigest
                                    permit
                                    TxnOpenProject
                                    [projectTransactionTarget key Nothing (encodeJournalState OpenProject)]
                            pure (ProjectPermit <$> advanced)

-- | Read the journal state without advancing it.
readProjectJournalState ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError ProjectJournalState)
readProjectJournalState session planDigest =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right _ -> do
                    observed <- readTransactionRecord session key
                    pure $ case observed of
                        Left failure -> Left (transactionFailure failure)
                        Right Nothing -> Left (SessionProjectMissing planDigest)
                        Right (Just record) ->
                            maybe
                                (Left (SessionRecordCorrupt "project journal"))
                                Right
                                (decodeJournalState (transactionRecordPayload record))

{- | Revalidate an Open-state permit before mutating any operation or session
record.

The protected entry excludes other store holders for the lifetime of the
caller, so this read establishes that the later operation-record write is not
being driven by an already-consumed or Closing permit. In particular, a stale
prepare returns before 'recordDurableUnknown' can change the operation phase.
-}
withCurrentOpenPermit ::
    ProtectedSession session ->
    Text ->
    TransactionPermit ->
    IO (Either SessionError result) ->
    IO (Either SessionError result)
withCurrentOpenPermit session planDigest presented action =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right live -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                        Right (Just record) ->
                            case decodeJournalState (transactionRecordPayload record) of
                                Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                                Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                                Just (ClosingProject _) -> pure (Left (SessionProjectClosing planDigest))
                                Just OpenProject
                                    | transactionPermitVersion live /= transactionPermitVersion presented ->
                                        pure
                                            ( Left
                                                ( SessionStaleProjectPermit
                                                    (transactionPermitVersion presented)
                                                )
                                            )
                                    | otherwise -> action

encodeJournalState :: ProjectJournalState -> ByteString
encodeJournalState state = case state of
    OpenProject -> encodeFields ["open"]
    ClosingProject epoch -> encodeFields ["closing", Text.pack (show epoch)]
    ClosedProject -> encodeFields ["closed"]

decodeJournalState :: ByteString -> Maybe ProjectJournalState
decodeJournalState raw = case decodeFields raw of
    ["open"] -> Just OpenProject
    ["closed"] -> Just ClosedProject
    ["closing", epoch] -> do
        value <- readWord epoch
        if value == 0 then Nothing else Just (ClosingProject value)
    _ -> Nothing

{- | Move the project journal from Open to a fresh Closing epoch, against the
caller's exact permit version.

Session opening advances that same record, so a close and a concurrent
session-open contend on one version and exactly one wins. That is what makes
"a prepare cannot slip in after close was authorized" a compare-and-swap result
rather than an ordering hope.
-}
beginClosingProject ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    -- | the closing epoch; must be positive
    Word64 ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ClosingProjectPermit scope planId))
beginClosingProject session planDigest epoch (ProjectPermit presented)
    | epoch == 0 = pure (Left (SessionRecordCorrupt "closing epoch must be positive"))
    | otherwise = case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right live -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                        Right (Just record) -> case decodeJournalState (transactionRecordPayload record) of
                            Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                            Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                            -- Resuming the same persisted Closing epoch is
                            -- idempotent; a different one is a second close.
                            Just (ClosingProject persisted)
                                | persisted == epoch -> pure (Right (ClosingProjectPermit live))
                                | otherwise -> pure (Left (SessionProjectClosing planDigest))
                            Just OpenProject
                                | transactionPermitVersion live /= transactionPermitVersion presented ->
                                    pure (Left (SessionStaleProjectPermit (transactionPermitVersion presented)))
                                | otherwise -> do
                                    advanced <-
                                        runTransaction
                                            session
                                            planDigest
                                            presented
                                            TxnBeginProjectClose
                                            [ projectTransactionTarget
                                                key
                                                (Just record)
                                                (encodeJournalState (ClosingProject epoch))
                                            ]
                                    pure (ClosingProjectPermit <$> advanced)

{- | Record the terminal @ClosedProject@ state, only from the exact Closing
epoch that authorized it. An Open journal cannot jump straight to Closed.
-}
recordClosedProject ::
    ProtectedSession session ->
    Text ->
    -- | the closing epoch recorded by 'beginClosingProject'
    Word64 ->
    ClosingProjectPermit scope planId ->
    IO (Either SessionError (ClosedProjectPermit scope planId))
recordClosedProject session planDigest epoch (ClosingProjectPermit presented) =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right live -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                        Right (Just record) -> case decodeJournalState (transactionRecordPayload record) of
                            Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                            Just ClosedProject -> pure (Right (ClosedProjectPermit live))
                            Just OpenProject -> pure (Left (SessionRecordCorrupt "project is not closing"))
                            Just (ClosingProject persisted)
                                | persisted /= epoch -> pure (Left (SessionProjectClosing planDigest))
                                | transactionPermitVersion live /= transactionPermitVersion presented ->
                                    pure (Left (SessionStaleProjectPermit (transactionPermitVersion presented)))
                                | otherwise -> do
                                    advanced <-
                                        runTransaction
                                            session
                                            planDigest
                                            presented
                                            TxnRecordProjectClosed
                                            [ projectTransactionTarget
                                                key
                                                (Just record)
                                                (encodeJournalState ClosedProject)
                                            ]
                                    pure (ClosedProjectPermit <$> advanced)

{- | Proof that every session for a plan was observed Closed at one store
version, with the count it covered.

Its constructor is private, and it enumerates the complete set rather than
accepting one the caller supplies: a zero-operation Open session is still a
member, which is exactly the state an invocation killed right after opening
leaves behind.
-}
data VerifiedAllSessionsClosed scope planId
    = VerifiedAllSessionsClosed Text Int

instance Show (VerifiedAllSessionsClosed scope planId) where
    show (VerifiedAllSessionsClosed plan n) =
        "VerifiedAllSessionsClosed " <> show plan <> " " <> show n

allSessionsClosedCount :: VerifiedAllSessionsClosed scope planId -> Int
allSessionsClosedCount (VerifiedAllSessionsClosed _ n) = n

{- | The plan digest this proof was taken over. The phantom indices alone would
let a proof taken for one plan be presented for another, so consumers compare
this against the bound lease's digest.
-}
allSessionsClosedPlanDigest :: VerifiedAllSessionsClosed scope planId -> Text
allSessionsClosedPlanDigest (VerifiedAllSessionsClosed plan _) = plan

verifyAllSessionsClosed ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (VerifiedAllSessionsClosed scope planId))
verifyAllSessionsClosed session planDigest = do
    coordinator <- ensureCoordinator session planDigest
    case coordinator of
        Left failure -> pure (Left failure)
        Right _ -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right keys -> case sessionKeyPrefixFor planDigest of
                  Left failure -> pure (Left failure)
                  Right prefix -> do
                    let members =
                            [ SessionId (recordIdentity (Text.drop (Text.length prefix) raw))
                            | raw <- map recordKeyText keys
                            , prefix `Text.isPrefixOf` raw
                            ]
                    open <- foldM step (Right []) members
                    pure $ case open of
                        Left failure -> Left failure
                        Right (still : _) -> Left (SessionStillOpen still)
                        Right [] -> Right (VerifiedAllSessionsClosed planDigest (length members))
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        state <- readSessionState session planDigest sid
        pure $ case state of
            Left failure -> Left failure
            Right True -> Right (sid : acc)
            Right False -> Right acc

-- ---------------------------------------------------------------------------
-- Sessions

-- | A session's durable identifier.
newtype SessionId = SessionId Text
    deriving (Eq, Ord, Show)

sessionIdText :: SessionId -> Text
sessionIdText (SessionId value) = value

{- | One open operation session. Opaque: it exists only as the result of
'openOperationSession', which proved the broker generation current and no older
session Open.
-}
data OperationSession scope planId = OperationSession
    { sessionRecordId :: SessionId
    , sessionPlanDigest :: Text
    , sessionBrokerGeneration :: Word64
    }

instance Show (OperationSession scope planId) where
    show sess = "OperationSession " <> show (sessionRecordId sess)

operationSessionId :: OperationSession scope planId -> SessionId
operationSessionId = sessionRecordId

sessionKey :: Text -> SessionId -> Either SessionError RecordKey
sessionKey planDigest (SessionId sid) = do
    prefix <- sessionKeyPrefixFor planDigest
    name <- recordName sid
    keyFor (prefix <> name)

sessionKeyPrefixFor :: Text -> Either SessionError Text
sessionKeyPrefixFor planDigest = do
    digest <- recordName planDigest
    pure ("session." <> digest <> ".")

data SessionRecordState = SessionRecordState
    { sessionRecordIsOpen :: Bool
    , sessionRecordMarker :: Text
    , sessionRecordMembers :: [Text]
    , sessionRecordHasExactMembership :: Bool
    }
    deriving (Eq, Show)

encodeSessionRecord :: Bool -> Text -> [Text] -> ByteString
encodeSessionRecord isOpen marker members =
    encodeFields
        ( (if isOpen then "open" else "closed")
            : marker
            : "members"
            : sort members
        )

decodeSessionRecord :: ByteString -> Maybe SessionRecordState
decodeSessionRecord raw = case decodeFields raw of
    [phase, marker]
        | phase == "open" || phase == "closed" ->
            Just
                SessionRecordState
                    { sessionRecordIsOpen = phase == "open"
                    , sessionRecordMarker = marker
                    , sessionRecordMembers = []
                    , sessionRecordHasExactMembership = False
                    }
    (phase : marker : "members" : members)
        | phase == "open" || phase == "closed" ->
            Just
                SessionRecordState
                    { sessionRecordIsOpen = phase == "open"
                    , sessionRecordMarker = marker
                    , sessionRecordMembers = sort members
                    , sessionRecordHasExactMembership = True
                    }
    _ -> Nothing

readSessionRecord ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError (Maybe (TransactionRecord, SessionRecordState)))
readSessionRecord session planDigest sid =
    case sessionKey planDigest sid of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readTransactionRecord session key
            pure $ case observed of
                Left failure -> Left (transactionFailure failure)
                Right Nothing -> Right Nothing
                Right (Just record) ->
                    case decodeSessionRecord (transactionRecordPayload record) of
                        Nothing -> Left (SessionRecordCorrupt "session")
                        Just state -> Right (Just (record, state))

legacyOperationNames ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError [Text])
legacyOperationNames session planDigest sid = do
    listed <- listProtectedRecords session
    pure $ case (listed, operationPrefixFor planDigest sid) of
        (Left failure, _) -> Left (SessionStoreFailure failure)
        (_, Left failure) -> Left failure
        (Right keys, Right prefix) ->
            Right
                ( sort
                    [ recordIdentity (Text.drop (Text.length prefix) raw)
                    | raw <- map recordKeyText keys
                    , prefix `Text.isPrefixOf` raw
                    ]
                )

sessionOperationNames ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    SessionRecordState ->
    IO (Either SessionError [Text])
sessionOperationNames session planDigest sid state
    | sessionRecordHasExactMembership state = pure (Right (sessionRecordMembers state))
    | otherwise = legacyOperationNames session planDigest sid

{- | Derive the durable record key one rooted frame session is addressed by.

The key is a function of root lineage, catalog identity, and frame alone, so a
second invocation lineage never addresses the row a live one owns, and no part
of a request can select which row is opened.
-}
rootedFrameSessionKeyKernel :: Text -> Text -> Text -> Either SessionError RecordKey
rootedFrameSessionKeyKernel rootPlanDigest catalogIdentity frame = do
    lineage <- recordName rootPlanDigest
    catalog <- recordName catalogIdentity
    named <- recordName frame
    keyFor ("rooted-frame-session." <> lineage <> "." <> catalog <> "." <> named)

{- | Publish one root-opened rooted frame session row, or converge on it.

The bytes are the caller's exact canonical rendering; this operation supplies
only the durable transition and interprets no framing of its own. A freshly
opened row expects to be absent, and the decision comes from the strict
readback rather than from who won the swap, so an exact retry converges on the
record already present.

What comes back is the version and the exact bytes the store actually holds,
never a claim that they are the ones presented. A row already advanced to its
attached successor is returned as it stands; only the caller's own codec can
say whether that successor nests this opening, so only the caller decides.
-}
openRootedFrameSessionRecordKernel ::
    ProtectedSession session ->
    RecordKey ->
    ByteString ->
    IO (Either SessionError (RecordVersion, ByteString))
openRootedFrameSessionRecordKernel session key opened = do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right (Just record) -> pure (Right (present record))
        Right Nothing -> do
            written <- compareAndSwapProtectedRecord session key ExpectAbsent opened
            case written of
                Left _ -> reread
                Right version
                    | recordVersionWord version /= 1 -> pure conflict
                    | otherwise -> reread
  where
    present record = (protectedRecordVersion record, protectedRecordBytes record)
    reread = do
        readback <- readProtectedRecord session key
        pure $ case readback of
            Right (Just record) -> Right (present record)
            _ -> Left (SessionRecordCorrupt "rooted frame session readback differs")
    conflict = Left (SessionRecordCorrupt "a conflicting rooted frame session row exists")

{- | Advance one exact opened row to its attached successor, or replay it.

The opened bytes and version presented are the ones the caller read back, so
the compare-and-swap consumes exactly that row and nothing else. An exact
replay returns the attached version already present without a second mutation;
anything that is neither the exact opened row nor the exact attached row
refuses.
-}
attachRootedFrameSessionRecordKernel ::
    ProtectedSession session ->
    RecordKey ->
    RecordVersion ->
    ByteString ->
    ByteString ->
    IO (Either SessionError RecordVersion)
attachRootedFrameSessionRecordKernel session key openedVersion opened attached = do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right Nothing -> pure conflict
        Right (Just record)
            | exactRootedFrameSessionRow 2 attached record ->
                pure (Right (protectedRecordVersion record))
            | exactRootedFrameSessionRow 1 opened record
            , protectedRecordVersion record == openedVersion -> do
                written <- compareAndSwapProtectedRecord session key (ExpectVersion openedVersion) attached
                case written of
                    Left _ -> rereadAttached
                    Right version
                        | recordVersionWord version /= 2 -> pure conflict
                        | otherwise -> rereadAttached
            | otherwise -> pure conflict
  where
    rereadAttached = do
        readback <- readProtectedRecord session key
        pure $ case readback of
            Right (Just record)
                | exactRootedFrameSessionRow 2 attached record ->
                    Right (protectedRecordVersion record)
            _ -> Left (SessionRecordCorrupt "rooted frame session attachment readback differs")
    conflict = Left (SessionRecordCorrupt "the rooted frame session row conflicts")

{- | Derive the durable key one rooted node's unknown row is addressed by.

The key is a function of root lineage, catalog identity, frame, and the
operation itself, so the root's own catalog selects which rows exist and a
request cannot name one.
-}
rootedNodeUnknownKeyKernel ::
    Text -> Text -> Text -> Text -> Either SessionError RecordKey
rootedNodeUnknownKeyKernel rootPlanDigest catalogIdentity frame operation = do
    lineage <- recordName rootPlanDigest
    catalog <- recordName catalogIdentity
    named <- recordName frame
    op <- recordName operation
    keyFor ("rooted-node-unknown." <> lineage <> "." <> catalog <> "." <> named <> "." <> op)

{- | Derive the durable key one rooted node settlement is addressed by.

The ordinal is part of the key, so one node settled at two different session
ordinals addresses two different rows and neither can overwrite the other.
-}
rootedSettlementKeyKernel ::
    Text -> Text -> Text -> Text -> Word64 -> Either SessionError RecordKey
rootedSettlementKeyKernel rootPlanDigest catalogIdentity frame node ordinal = do
    lineage <- recordName rootPlanDigest
    catalog <- recordName catalogIdentity
    named <- recordName frame
    settled <- recordName node
    at <- recordName (Text.pack (show ordinal))
    keyFor
        ( "rooted-node-settlement." <> lineage <> "." <> catalog <> "." <> named
            <> "." <> settled <> "." <> at
        )

{- | Publish one exact rooted unknown row and read back what the store holds.

This is the same absent-then-strict-readback transition the rooted frame
session opens with, and it interprets no framing of its own: the bytes are the
caller's canonical rendering, and what comes back is the version and the bytes
actually present rather than a claim they are the ones presented. An exact
retry converges on the record already there, so publishing the same unknown row
twice is one preparation rather than two.
-}
publishRootedUnknownRowKernel ::
    ProtectedSession session ->
    RecordKey ->
    ByteString ->
    IO (Either SessionError (RecordVersion, ByteString))
publishRootedUnknownRowKernel = openRootedFrameSessionRecordKernel

exactRootedFrameSessionRow :: Word64 -> ByteString -> ProtectedRecord -> Bool
exactRootedFrameSessionRow version bytes record =
    recordVersionWord (protectedRecordVersion record) == version
        && protectedRecordBytes record == bytes

{- | Open a session for this plan against the live broker generation.

Refuses when the project journal is closed, when the caller's permit is not the
current journal version (someone else advanced it first), or when any older
session for this plan is still Open — including a session that registered no
operations at all, which is exactly the state an invocation killed immediately
after opening leaves behind.
-}
openOperationSession ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    -- | plan digest
    Text ->
    -- | this session's identifier
    Text ->
    ProjectPermit scope planId ->
    IO (Either SessionError (OperationSession scope planId, ProjectPermit scope planId))
openOperationSession session epoch planDigest rawSessionId (ProjectPermit presented) = do
    let sid = SessionId rawSessionId
    recovered <- ensureCoordinator session planDigest
    case recovered of
        Left failure -> pure (Left failure)
        Right _ -> do
            stale <- openSessionsFor session planDigest
            case stale of
                Left failure -> pure (Left failure)
                Right (older : _) -> pure (Left (SessionOlderStillOpen older))
                Right [] -> case sessionKey planDigest sid of
                    Left failure -> pure (Left failure)
                    Right sKey ->
                        withCurrentOpenPermit session planDigest presented $ do
                            observed <- readTransactionRecord session sKey
                            case observed of
                                Left failure -> pure (Left (transactionFailure failure))
                                Right (Just _) -> pure (Left (SessionNotOpen sid))
                                Right Nothing -> do
                                    advanced <-
                                        runTransaction
                                            session
                                            planDigest
                                            presented
                                            TxnOpenSession
                                            [ sessionTransactionTarget
                                                sKey
                                                Nothing
                                                ( encodeSessionRecord
                                                    True
                                                    (Text.pack (show (brokerEpochWord epoch)))
                                                    []
                                                )
                                            ]
                                    pure $ do
                                        next <- advanced
                                        Right
                                            ( OperationSession
                                                { sessionRecordId = sid
                                                , sessionPlanDigest = planDigest
                                                , sessionBrokerGeneration = brokerEpochWord epoch
                                                }
                                            , ProjectPermit next
                                            )

-- | Every session record for this plan that is still Open.
openSessionsFor ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError [SessionId])
openSessionsFor session planDigest = do
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> case sessionKeyPrefixFor planDigest of
          Left failure -> pure (Left failure)
          Right prefix -> do
            let candidates =
                    [ SessionId (recordIdentity (Text.drop (Text.length prefix) raw))
                    | raw <- map recordKeyText keys
                    , prefix `Text.isPrefixOf` raw
                    ]
            foldM step (Right []) candidates
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        state <- readSessionState session planDigest sid
        pure $ case state of
            Left failure -> Left failure
            Right True -> Right (sid : acc)
            Right False -> Right acc

readSessionState ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError Bool)
readSessionState session planDigest sid =
    fmap
        (fmap (maybe False (sessionRecordIsOpen . snd)))
        (readSessionRecord session planDigest sid)

{- | Close a session, proving first that every operation it registered has
settled.

Closing contends on the same session record version a prepare would, so a close
and a concurrent prepare have exactly one winner: whichever loses the
compare-and-swap sees a stale version and refuses.
-}
closeOperationSession ::
    ProtectedSession session ->
    OperationSession scope planId ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ProjectPermit scope planId))
closeOperationSession session sess (ProjectPermit presented) =
    withCurrentOpenPermit session (sessionPlanDigest sess) presented $ do
        unsettled <- unsettledOperations session sess
        case unsettled of
            Left failure -> pure (Left failure)
            Right (pending : _) -> pure (Left (SessionOperationUnsettled pending))
            Right [] -> case sessionKey (sessionPlanDigest sess) (sessionRecordId sess) of
                Left failure -> pure (Left failure)
                Right sKey -> do
                    observed <- readSessionRecord session (sessionPlanDigest sess) (sessionRecordId sess)
                    case observed of
                        Left failure -> pure (Left failure)
                        Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
                        Right (Just (record, state))
                            | not (sessionRecordIsOpen state) ->
                                pure (Left (SessionNotOpen (sessionRecordId sess)))
                            | otherwise -> do
                                members <-
                                    sessionOperationNames
                                        session
                                        (sessionPlanDigest sess)
                                        (sessionRecordId sess)
                                        state
                                case members of
                                    Left failure -> pure (Left failure)
                                    Right names -> do
                                        advanced <-
                                            runTransaction
                                                session
                                                (sessionPlanDigest sess)
                                                presented
                                                TxnCloseSession
                                                [ sessionTransactionTarget
                                                    sKey
                                                    (Just record)
                                                    (encodeSessionRecord False (sessionRecordMarker state) names)
                                                ]
                                        pure (ProjectPermit <$> advanced)

-- ---------------------------------------------------------------------------
-- Operation records

operationKeyFor :: Text -> SessionId -> Text -> Either SessionError RecordKey
operationKeyFor planDigest (SessionId sid) opKey = do
    prefix <- operationPrefixFor planDigest (SessionId sid)
    name <- recordName opKey
    keyFor (prefix <> name)

operationPrefixFor :: Text -> SessionId -> Either SessionError Text
operationPrefixFor planDigest (SessionId sid) = do
    digest <- recordName planDigest
    name <- recordName sid
    pure ("op." <> digest <> "." <> name <> ".")

{- | Where an operation's first intent may legitimately come from: no prior
history at all, or a previous generation that was explicitly released.

An operation that already has a live record cannot re-register an initial
intent; it must continue from the phase it is in.
-}
data IntentOrigin
    = NoHistory
    | ReleasedReacquisition
    deriving (Eq, Show)

{- | Register an operation's initial intent, atomically joining it to this exact
session and advancing the project journal.

The two writes are ordered so neither an orphan intent (a record belonging to no
session) nor a recordless session member can exist: the operation record names
its session, and the journal advance is what makes the pair visible to the next
holder.
-}
registerOperationIntent ::
    ProtectedSession session ->
    OperationSession scope planId ->
    -- | the operation key
    Text ->
    IntentOrigin ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ProjectPermit scope planId))
registerOperationIntent session sess opKey origin (ProjectPermit presented) =
    case (operationKeyFor plan (sessionRecordId sess) opKey, sessionKey plan (sessionRecordId sess)) of
        (Left failure, _) -> pure (Left failure)
        (_, Left failure) -> pure (Left failure)
        (Right oKey, Right sKey) ->
            withCurrentOpenPermit session plan presented $ do
                sessionObserved <- readSessionRecord session plan (sessionRecordId sess)
                case sessionObserved of
                    Left failure -> pure (Left failure)
                    Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
                    Right (Just (_, state))
                        | not (sessionRecordIsOpen state) ->
                            pure (Left (SessionNotOpen (sessionRecordId sess)))
                    Right (Just (sessionRecord, state)) -> do
                        observed <- readTransactionRecord session oKey
                        case observed of
                            Left failure -> pure (Left (transactionFailure failure))
                            Right (Just record)
                                | origin == NoHistory ->
                                    pure
                                        ( Left
                                            ( SessionIntentAlreadyRecorded
                                                opKey
                                                (phaseTextOf (transactionRecordPayload record))
                                            )
                                        )
                                | phaseTextOf (transactionRecordPayload record) /= "Released" ->
                                    pure
                                        ( Left
                                            ( SessionIntentOriginRefused
                                                opKey
                                                (phaseTextOf (transactionRecordPayload record))
                                            )
                                        )
                            Right operationRecord -> do
                                existingMembers <-
                                    sessionOperationNames session plan (sessionRecordId sess) state
                                case existingMembers of
                                    Left failure -> pure (Left failure)
                                    Right members -> do
                                        let exactMembers =
                                                sort
                                                    ( if opKey `elem` members
                                                        then members
                                                        else opKey : members
                                                    )
                                        advanced <-
                                            runTransaction
                                                session
                                                plan
                                                presented
                                                TxnRegisterIntent
                                                [ operationTransactionTarget
                                                    oKey
                                                    operationRecord
                                                    ( encodeFields
                                                        [ "IntentRecorded"
                                                        , sessionIdText (sessionRecordId sess)
                                                        , "0"
                                                        ]
                                                    )
                                                , sessionTransactionTarget
                                                    sKey
                                                    (Just sessionRecord)
                                                    ( encodeSessionRecord
                                                        True
                                                        (sessionRecordMarker state)
                                                        exactMembers
                                                    )
                                                ]
                                        pure (ProjectPermit <$> advanced)
  where
    plan = sessionPlanDigest sess

phaseTextOf :: ByteString -> Text
phaseTextOf raw = case decodeFields raw of
    (phase : _) -> phase
    [] -> ""

recordedFenceOf :: ByteString -> Word64
recordedFenceOf raw = case decodeFields raw of
    (_ : _ : fence : _) -> maybe 0 id (readWord fence)
    _ -> 0

readWord :: Text -> Maybe Word64
readWord raw = case reads (Text.unpack raw) of
    [(value, "")] -> Just value
    _ -> Nothing

{- | Every operation in this session that has not reached a settled phase. Used
by 'closeOperationSession' to refuse a close that would strand work.
-}
unsettledOperations ::
    ProtectedSession session ->
    OperationSession scope planId ->
    IO (Either SessionError [Text])
unsettledOperations session sess = do
    sessionObserved <- readSessionRecord session (sessionPlanDigest sess) (sessionRecordId sess)
    case sessionObserved of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
        Right (Just (_, state)) -> do
            names <-
                sessionOperationNames
                    session
                    (sessionPlanDigest sess)
                    (sessionRecordId sess)
                    state
            case names of
                Left failure -> pure (Left failure)
                Right operationNames -> foldM step (Right []) operationNames
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) name =
        case operationKeyFor (sessionPlanDigest sess) (sessionRecordId sess) name of
            Left failure -> pure (Left failure)
            Right key -> do
                observed <- readTransactionRecord session key
                pure $ case observed of
                    Left failure -> Left (transactionFailure failure)
                    Right Nothing -> Right acc
                    Right (Just record) ->
                        case classifyRecordedPhase (phaseTextOf (transactionRecordPayload record)) of
                            Settled -> Right acc
                            TerminalDisposition -> Right acc
                            _ -> Right (name : acc)

-- ---------------------------------------------------------------------------
-- Fences

{- | The durable fence-rotation protocol.

A fence is proposed, then its outcome is unknown, then it is observed. The
middle state is the load-bearing one: a crash there must resume the *same*
proposed epoch rather than proposing a new one, because a delayed permit issued
under the proposal may still be in flight.
-}
data FencePhase
    = FenceIntentRecorded
    | FenceOutcomeUnknown
    | FenceObserved
    deriving (Eq, Show)

-- | An observed fence epoch. Only a 'FenceObserved' record produces one.
newtype FenceEpoch scope planId = FenceEpoch Word64

instance Show (FenceEpoch scope planId) where
    show (FenceEpoch value) = "FenceEpoch " <> show value

fenceEpochWord :: FenceEpoch scope planId -> Word64
fenceEpochWord (FenceEpoch value) = value

fenceKey :: Text -> Either SessionError RecordKey
fenceKey planDigest = do
    digest <- recordName planDigest
    keyFor ("fence." <> digest)

{- | Establish the plan's initial fence, or resume an interrupted establishment.

Idempotent by construction: the proposed epoch is written before it is used, so
a resume reads the proposal back rather than choosing a different one. An
interrupted run therefore converges on one epoch no matter how many times it is
restarted.
-}
establishInitialFence ::
    ProtectedSession session ->
    Text ->
    -- | the proposed epoch
    Word64
    ->
    IO (Either SessionError (FenceEpoch scope planId))
establishInitialFence session planDigest proposed
    | proposed == 0 = pure (Left (SessionFenceInvalid "a fence epoch must be positive"))
    | otherwise = case fenceKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> do
                    -- Record the intent first; the epoch is durable before any
                    -- permit can be issued under it.
                    intent <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            ExpectAbsent
                            (fenceRecord FenceIntentRecorded proposed)
                    case intent of
                        Left failure -> pure (Left (SessionStoreFailure failure))
                        Right version -> settleFence session key version proposed
                Right (Just record) ->
                    case decodeFenceRecord (protectedRecordBytes record) of
                        Nothing -> pure (Left (SessionRecordCorrupt "fence"))
                        -- Resume the persisted proposal, never the caller's.
                        Just (FenceIntentRecorded, persisted) ->
                            settleFence session key (protectedRecordVersion record) persisted
                        Just (FenceOutcomeUnknown, persisted) ->
                            settleFence session key (protectedRecordVersion record) persisted
                        Just (FenceObserved, persisted) -> pure (Right (FenceEpoch persisted))

settleFence ::
    ProtectedSession session ->
    RecordKey ->
    RecordVersion ->
    Word64 ->
    IO (Either SessionError (FenceEpoch scope planId))
settleFence session key version epoch = do
    unknown <-
        compareAndSwapProtectedRecord
            session
            key
            (ExpectVersion version)
            (fenceRecord FenceOutcomeUnknown epoch)
    case unknown of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right nextVersion -> do
            settled <-
                compareAndSwapProtectedRecord
                    session
                    key
                    (ExpectVersion nextVersion)
                    (fenceRecord FenceObserved epoch)
            pure $ case settled of
                Left failure -> Left (SessionStoreFailure failure)
                Right _ -> Right (FenceEpoch epoch)

{- | Rotate to a strictly greater fence epoch. A rotation to the same or a lower
epoch is refused, so a replayed rotation cannot reopen a superseded epoch.
-}
rotateFence ::
    ProtectedSession session ->
    Text ->
    FenceEpoch scope planId ->
    IO (Either SessionError (FenceEpoch scope planId))
rotateFence session planDigest (FenceEpoch previous) =
    case fenceKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionFenceMissing planDigest))
                Right (Just record) -> case decodeFenceRecord (protectedRecordBytes record) of
                    Nothing -> pure (Left (SessionRecordCorrupt "fence"))
                    Just (_, persisted)
                        | persisted /= previous ->
                            pure (Left (SessionFenceSuperseded previous persisted))
                        | otherwise -> do
                            intent <-
                                compareAndSwapProtectedRecord
                                    session
                                    key
                                    (ExpectVersion (protectedRecordVersion record))
                                    (fenceRecord FenceIntentRecorded (previous + 1))
                            case intent of
                                Left failure -> pure (Left (SessionStoreFailure failure))
                                Right version -> settleFence session key version (previous + 1)

-- | Read the current observed fence, if the protocol has settled one.
currentFence ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError (FenceEpoch scope planId))
currentFence session planDigest =
    case fenceKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            pure $ case observed of
                Left failure -> Left (SessionStoreFailure failure)
                Right Nothing -> Left (SessionFenceMissing planDigest)
                Right (Just record) -> case decodeFenceRecord (protectedRecordBytes record) of
                    Just (FenceObserved, epoch) -> Right (FenceEpoch epoch)
                    Just (phase, _) -> Left (SessionFenceUnsettled phase)
                    Nothing -> Left (SessionRecordCorrupt "fence")

fenceRecord :: FencePhase -> Word64 -> ByteString
fenceRecord phase epoch = encodeFields [fencePhaseText phase, Text.pack (show epoch)]

fencePhaseText :: FencePhase -> Text
fencePhaseText FenceIntentRecorded = "FenceIntentRecorded"
fencePhaseText FenceOutcomeUnknown = "FenceOutcomeUnknown"
fencePhaseText FenceObserved = "FenceObserved"

decodeFenceRecord :: ByteString -> Maybe (FencePhase, Word64)
decodeFenceRecord raw = case decodeFields raw of
    [phase, epoch] -> (,) <$> parsePhase phase <*> readWord epoch
    _ -> Nothing
  where
    parsePhase "FenceIntentRecorded" = Just FenceIntentRecorded
    parsePhase "FenceOutcomeUnknown" = Just FenceOutcomeUnknown
    parsePhase "FenceObserved" = Just FenceObserved
    parsePhase _ = Nothing

-- ---------------------------------------------------------------------------
-- Recovery classification

{- | The total discriminator every recorded operation phase falls into.

Totality is the point: recovery must decide something for every phase the
journal can hold, including a phase it does not recognise, and the decision
determines whether that operation may receive effect authority again.
-}
data OperationDisposition
    = -- | no record, or a phase this binary does not recognise
      UnknownDisposition
    | -- | a pre-call phase; may receive current-fence prepare authority
      Continuable
    | -- | an already-observed phase on the closed retry whitelist; may receive
      -- fenced same-key retry authority only
      FencedRetryable
    | -- | committed work; no further effect authority
      Settled
    | -- | a terminal branch (foreign, refused, unexpected); no effect authority
      TerminalDisposition
    deriving (Eq, Show)

{- | Classify a recorded phase name.

The five **continuable** pre-call phases are the ones where no effect has been
attempted yet, so re-preparing them under the current fence is safe. The
**fenced-retryable** set is the closed whitelist § EE names: an authoritative
absence of a reservation or effect, an ordinary or adopted same-identity
teardown observation, an adoption absence, a repair original, and a phase
observed *from* — each of which may retry only after crossing an explicit fenced
state. Everything committed is 'Settled', every foreign/refused/unexpected
branch is 'TerminalDisposition', and anything unrecognised is
'UnknownDisposition' rather than being optimistically treated as safe.
-}
classifyRecordedPhase :: Text -> OperationDisposition
classifyRecordedPhase phase
    | phase `elem` continuablePhases = Continuable
    | phase `elem` fencedRetryablePhases = FencedRetryable
    | phase `elem` settledPhases = Settled
    | phase `elem` terminalPhases = TerminalDisposition
    | otherwise = UnknownDisposition

continuablePhases :: [Text]
continuablePhases =
    [ "IntentRecorded"
    , "AdoptionIntentRecorded"
    , "RepairIntentRecorded"
    , "PhaseIntentRecorded"
    , "ReservationRetryFenced"
    ]

fencedRetryablePhases :: [Text]
fencedRetryablePhases =
    [ "ReservationAbsent"
    , "EffectAbsent"
    , "AdoptionObservedAbsent"
    , "RepairObservedOriginal"
    , "PhaseObservedFrom"
    , "EffectRetryFenced"
    , "AdoptionRetryFenced"
    , "RepairRetryFenced"
    , "PhaseRetryFenced"
    ]

settledPhases :: [Text]
settledPhases =
    [ "Committed"
    , "AdoptionCommitted"
    , "RepairCommitted"
    , "PhaseCommitted"
    , "Released"
    , "AdoptionReleased"
    ]

terminalPhases :: [Text]
terminalPhases =
    [ -- A chain node that returned a definite non-success observation: a
      -- conflict, an unsupported backend, or a safety refusal. All three are
      -- terminal for recovery in the same way — an operator resolves them, a
      -- successor may not retry them — so they settle at one phase. Which of the
      -- three it was is carried by the interpreter's row, not by the record,
      -- because the record's only job here is the recovery classification.
      "StepObservedTerminal"
    , -- What the recorded-session interpreter writes over an operation whose
      -- owning run was abandoned. It is terminal rather than continuable
      -- because the run that registered it is gone: a successor is a different
      -- run with its own session, and letting it inherit this operation's
      -- authority is exactly the replay the fence set exists to prevent. It is
      -- distinct from the other terminal phases so the journal still says *why*
      -- the operation stopped.
      "RecoveryAbandoned"
    , "ObservedForeign"
    , "TeardownObservedForeign"
    , "AdoptionObservedForeign"
    , "AdoptionRefused"
    , "RepairObservedForeign"
    , "RepairObservedUnexpected"
    , "PhaseObservedForeign"
    , "PhaseObservedUnexpected"
    ]

-- | What a recovery sweep settled.
data RecoveredSessions = RecoveredSessions
    { recoveredSessionCount :: Int
    , recoveredContinuableCount :: Int
    }
    deriving (Eq, Show)

{- | Close every Open session for this plan, classifying each of its operations.

This is what a new invocation runs before it may open its own session. It is
deliberately total over recorded phases: an operation whose phase this binary
does not recognise is 'UnknownDisposition' and blocks admission rather than
being swept as though it were finished.
-}
recoverAbandonedSessions ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError RecoveredSessions)
recoverAbandonedSessions session planDigest = do
    coordinator <- ensureCoordinator session planDigest
    case coordinator of
        Left failure -> pure (Left failure)
        Right initialPermit -> do
            listed <- openSessionsFor session planDigest
            case listed of
                Left failure -> pure (Left failure)
                Right sessions -> do
                    recovered <-
                        foldM
                            step
                            (Right (RecoveredSessions 0 0, initialPermit))
                            (sort sessions)
                    pure (fst <$> recovered)
  where
    step (Left failure) _ = pure (Left failure)
    step (Right (acc, permit)) sid = do
        counted <- classifySessionOperations session planDigest sid
        case counted of
            Left failure -> pure (Left failure)
            Right continuable -> case sessionKey planDigest sid of
                Left failure -> pure (Left failure)
                Right key -> do
                    observed <- readSessionRecord session planDigest sid
                    case observed of
                        Left failure -> pure (Left failure)
                        Right Nothing -> pure (Right (acc, permit))
                        Right (Just (record, state))
                            | not (sessionRecordIsOpen state) -> pure (Right (acc, permit))
                            | otherwise -> do
                                members <- sessionOperationNames session planDigest sid state
                                case members of
                                    Left failure -> pure (Left failure)
                                    Right names -> do
                                        closed <-
                                            runTransaction
                                                session
                                                planDigest
                                                permit
                                                TxnCloseSession
                                                [ sessionTransactionTarget
                                                    key
                                                    (Just record)
                                                    (encodeSessionRecord False "recovered" names)
                                                ]
                                        pure $ case closed of
                                            Left failure -> Left failure
                                            Right nextPermit ->
                                                Right
                                                    ( RecoveredSessions
                                                        { recoveredSessionCount =
                                                            recoveredSessionCount acc + 1
                                                        , recoveredContinuableCount =
                                                            recoveredContinuableCount acc + continuable
                                                        }
                                                    , nextPermit
                                                    )

classifySessionOperations ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError Int)
classifySessionOperations session planDigest sid = do
    observedSession <- readSessionRecord session planDigest sid
    case observedSession of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right 0)
        Right (Just (_, state)) -> do
            names <- sessionOperationNames session planDigest sid state
            case names of
                Left failure -> pure (Left failure)
                Right operationNames -> foldM step (Right 0) operationNames
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) name = case operationKeyFor planDigest sid name of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readTransactionRecord session key
            pure $ case observed of
                Left failure -> Left (transactionFailure failure)
                Right Nothing -> Right acc
                Right (Just record) ->
                    case classifyRecordedPhase (phaseTextOf (transactionRecordPayload record)) of
                        UnknownDisposition ->
                            Left
                                ( SessionUnclassifiedPhase
                                    name
                                    (phaseTextOf (transactionRecordPayload record))
                                )
                        Continuable -> Right (acc + 1)
                        _ -> Right acc

-- ---------------------------------------------------------------------------
-- Abandoned-run recovery admission

{- | The exact set of permits the old broker generation could still be holding,
proved fenced out.

Its constructor is private and it carries the /enumerated/ operation keys rather
than a count, because § EE requires recovery to consume "the exact old-permit
fence set in a protected exact-set fold". A caller cannot present a set it chose:
'fenceOldPermits' reads the set out of the store and rotates the fence in the
same protected entry, so the set named here is exactly the set the rotation
superseded.

The two epochs are both retained. @from@ is what a delayed permit would carry and
@to@ is what the prepare gate will now demand, so the proof states the window it
closed instead of asserting that one was closed.
-}
data OldPermitsFenced scope planId
    = OldPermitsFenced Text Word64 Word64 [Text]

instance Show (OldPermitsFenced scope planId) where
    show (OldPermitsFenced plan from to keys) =
        "OldPermitsFenced "
            <> show plan
            <> " "
            <> show from
            <> " -> "
            <> show to
            <> " "
            <> show keys

-- | The plan digest this fencing was taken over.
oldPermitsFencedPlanDigest :: OldPermitsFenced scope planId -> Text
oldPermitsFencedPlanDigest (OldPermitsFenced plan _ _ _) = plan

-- | The superseded epoch — what a delayed old permit carries.
oldPermitsFencedFrom :: OldPermitsFenced scope planId -> Word64
oldPermitsFencedFrom (OldPermitsFenced _ from _ _) = from

-- | The epoch the prepare gate now demands.
oldPermitsFencedTo :: OldPermitsFenced scope planId -> Word64
oldPermitsFencedTo (OldPermitsFenced _ _ to _) = to

{- | The exact operation keys that were still able to receive authority under the
superseded epoch, in sorted order.
-}
oldPermitsFencedOperations :: OldPermitsFenced scope planId -> [Text]
oldPermitsFencedOperations (OldPermitsFenced _ _ _ keys) = keys

{- | Fence out every permit the abandoned generation could still be holding.

The order is the whole of the guarantee:

1. the fence protocol is /settled/ first. A run killed between proposing an epoch
   and observing it leaves @FenceIntentRecorded@ or @FenceOutcomeUnknown@, and
   § EE names that "an explicit recovery state" whose stable protocol recovery
   completes idempotently rather than proposing a fresh epoch beside it.
   'establishInitialFence' is exactly that completion: it resumes the persisted
   proposal, and only an absent record starts at 1;
2. the outstanding set is enumerated /before/ the rotation, so it is the set
   issued under the epoch being superseded rather than whatever survives it;
3. only then is the fence rotated. A permit minted under @from@ now fails
   'withPreparedGate''s equality check against the live epoch, so a delayed
   backend call from the dead run cannot land as though it were current.

An operation already at a settled or terminal phase is not a member: it holds no
authority to fence. The membership test is 'classifyRecordedPhase', so the set
here and the set the prepare gate would admit cannot drift apart.
-}
fenceOldPermits ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (OldPermitsFenced scope planId))
fenceOldPermits session planDigest = do
    settled <- establishInitialFence session planDigest 1
    case settled of
        Left failure -> pure (Left failure)
        Right (FenceEpoch from) -> do
            outstanding <- outstandingOperationKeys session planDigest
            case outstanding of
                Left failure -> pure (Left failure)
                Right keys -> do
                    rotated <- rotateFence session planDigest (FenceEpoch from :: FenceEpoch scope planId)
                    pure $ case rotated of
                        Left failure -> Left failure
                        Right (FenceEpoch to) -> Right (OldPermitsFenced planDigest from to keys)

{- | Every operation record of this plan whose recorded phase can still receive
effect authority, named by its own operation key.

This walks the store's own key space rather than any session's declared
membership: an operation whose session record was lost is still an outstanding
permit, and a fence set derived from membership would silently omit it.
-}
outstandingOperationKeys ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError [Text])
outstandingOperationKeys session planDigest = do
    enumerated <- enumerateOperationRecords session planDigest
    pure (fmap (sort . outstanding) enumerated)
  where
    outstanding records =
        [opKey | (disposition, opKey, _) <- records, holdsAuthority disposition]

    holdsAuthority disposition = case disposition of
        Settled -> False
        TerminalDisposition -> False
        _ -> True

{- | Every operation record of this plan, as
@(disposition, operationKey, sessionId)@ triples read out of the store's key
space.
-}
enumerateOperationRecords ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError [(OperationDisposition, Text, Text)])
enumerateOperationRecords session planDigest = do
    listed <- listProtectedRecords session
    case (listed, operationKeyNamespace planDigest) of
        (Left failure, _) -> pure (Left (SessionStoreFailure failure))
        (_, Left failure) -> pure (Left failure)
        (Right keys, Right namespace) ->
            foldM step (Right []) [raw | raw <- map recordKeyText keys, namespace `Text.isPrefixOf` raw]
      where
        step (Left failure) _ = pure (Left failure)
        step (Right acc) raw = do
            observed <- readOperationRecordAt session raw
            pure $ case observed of
                Left failure -> Left failure
                Right Nothing -> Right acc
                Right (Just (disposition, opKey, sid)) ->
                    Right ((disposition, opKey, sid) : acc)

{- | The @op.\<digest\>.@ prefix every one of this plan's operation records sits
under.
-}
operationKeyNamespace :: Text -> Either SessionError Text
operationKeyNamespace planDigest = do
    digest <- recordName planDigest
    pure ("op." <> digest <> ".")

{- | Read one operation record by its raw store key, recovering the session and
operation components from the key itself.

An operation key is @op.\<digest\>.\<session\>.\<operation\>@, so the two
components are the last two segments. A key that does not have them is not an
operation record this plan owns and is skipped rather than guessed at.
-}
readOperationRecordAt ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError (Maybe (OperationDisposition, Text, Text)))
readOperationRecordAt session raw = case splitOperationKey raw of
    Nothing -> pure (Right Nothing)
    Just (sid, opKey) -> case keyFor raw of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readTransactionRecord session key
            pure $ case observed of
                Left failure -> Left (transactionFailure failure)
                Right Nothing -> Right Nothing
                Right (Just record) ->
                    Right
                        ( Just
                            ( classifyRecordedPhase (phaseTextOf (transactionRecordPayload record))
                            , opKey
                            , sid
                            )
                        )

{- | Split @op.\<digest\>.\<session\>.\<operation\>@ into its session and
operation identities.

Both components come back through 'recordIdentity', so a namespaced record name
and the identity it denotes agree with what 'operationKeyFor' would have built.
-}
splitOperationKey :: Text -> Maybe (Text, Text)
splitOperationKey raw = case reverse (Text.splitOn "." raw) of
    (opKey : sid : _rest@(_ : _ : _)) -> Just (recordIdentity sid, recordIdentity opKey)
    _ -> Nothing

{- | One session as the manifest observed it, with the operation set the /store/
holds for it rather than the set the session record claims.
-}
data ManifestSession = ManifestSession
    { manifestSessionId :: SessionId
    , manifestSessionIsOpen :: Bool
    , manifestSessionOperations :: [Text]
    }
    deriving (Eq, Show)

{- | A manifest pairing the plan's independently enumerated complete session set
with its independently enumerated complete operation set.

"Independently" is the load-bearing word. The session set comes from the
@session.\<digest\>.@ key space and the operation set from the
@op.\<digest\>.@ key space; neither is derived from the other. The pairing is
then /checked/ rather than assumed, which is what makes a wrong membership a
refusal instead of an unnoticed divergence.

A zero-operation Open session is a required member (§ EE) — it is precisely what
a run killed immediately after 'openOperationSession' leaves behind, and a
manifest that dropped it would let the next admission believe the plan had no
outstanding session.
-}
data VerifiedSessionManifest scope planId
    = VerifiedSessionManifest Text [ManifestSession]

instance Show (VerifiedSessionManifest scope planId) where
    show (VerifiedSessionManifest plan sessions) =
        "VerifiedSessionManifest " <> show plan <> " " <> show (length sessions)

-- | The plan digest this manifest was taken over.
manifestPlanDigest :: VerifiedSessionManifest scope planId -> Text
manifestPlanDigest (VerifiedSessionManifest plan _) = plan

-- | Every session of the plan, in sorted identity order.
manifestSessions :: VerifiedSessionManifest scope planId -> [ManifestSession]
manifestSessions (VerifiedSessionManifest _ sessions) = sessions

-- | How many operations the paired complete operation set holds.
manifestOperationCount :: VerifiedSessionManifest scope planId -> Int
manifestOperationCount = sum . map (length . manifestSessionOperations) . manifestSessions

{- | Verify the manifest, refusing every way the two sets can fail to pair.

The refusals are exactly § EE's: a missing record, a duplicate record, and a
wrong membership. Concretely:

* an operation record naming a session with no session record is
  'SessionManifestOrphanOperation' — the operation exists but nothing owns it,
  so no admission may be minted over it;
* two store keys resolving to one session identity is
  'SessionManifestDuplicateSession'. Record names are namespaced, so this needs
  two differently-spelled keys denoting the same identity; it is checked rather
  than assumed impossible because the pairing's correctness rests on the session
  set being a set;
* a session whose record declares a membership different from the operation
  records the store actually holds is 'SessionManifestMembershipMismatch'. The
  enumerated set wins as the truth and the declared one is reported beside it,
  because the declaration is what a killed writer can leave stale.

A session record that predates exact membership declares none; that is not a
mismatch, and its enumerated operations are simply adopted.
-}
verifySessionManifest ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (VerifiedSessionManifest scope planId))
verifySessionManifest session planDigest = do
    coordinator <- ensureCoordinator session planDigest
    case coordinator of
        Left failure -> pure (Left failure)
        Right _ -> do
            listed <- listProtectedRecords session
            case (listed, sessionKeyPrefixFor planDigest) of
                (Left failure, _) -> pure (Left (SessionStoreFailure failure))
                (_, Left failure) -> pure (Left failure)
                (Right keys, Right prefix) -> do
                    let identities =
                            [ recordIdentity (Text.drop (Text.length prefix) raw)
                            | raw <- map recordKeyText keys
                            , prefix `Text.isPrefixOf` raw
                            ]
                    case firstDuplicate (sort identities) of
                        Just repeated ->
                            pure (Left (SessionManifestDuplicateSession (SessionId repeated)))
                        Nothing -> do
                            enumerated <- enumerateOperationRecords session planDigest
                            case enumerated of
                                Left failure -> pure (Left failure)
                                Right records ->
                                    pairEnumeratedSets session planDigest (sort identities) records

{- | Pair the enumerated session set with the enumerated operation set, or refuse.

An operation whose owning session has no record is refused first: it is the one
failure that cannot be repaired by reading further, because there is no session
whose membership could be compared against it.
-}
pairEnumeratedSets ::
    ProtectedSession session ->
    Text ->
    [Text] ->
    [(OperationDisposition, Text, Text)] ->
    IO (Either SessionError (VerifiedSessionManifest scope planId))
pairEnumeratedSets session planDigest identities records =
    case [(opKey, sid) | (_, opKey, sid) <- records, sid `notElem` identities] of
        ((opKey, sid) : _) -> pure (Left (SessionManifestOrphanOperation opKey sid))
        [] -> do
            members <- foldM step (Right []) identities
            pure (fmap (VerifiedSessionManifest planDigest . reverse) members)
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        observed <- readSessionRecord session planDigest (SessionId sid)
        pure $ case observed of
            Left failure -> Left failure
            Right Nothing -> Left (SessionManifestMissingRecord (SessionId sid))
            Right (Just (_, state))
                | sessionRecordHasExactMembership state
                , sort (sessionRecordMembers state) /= enumeratedFor sid ->
                    Left
                        ( SessionManifestMembershipMismatch
                            (SessionId sid)
                            (Text.intercalate "," (sort (sessionRecordMembers state)))
                            (Text.intercalate "," (enumeratedFor sid))
                        )
                | otherwise ->
                    Right
                        ( ManifestSession
                            { manifestSessionId = SessionId sid
                            , manifestSessionIsOpen = sessionRecordIsOpen state
                            , manifestSessionOperations = enumeratedFor sid
                            }
                            : acc
                        )

    enumeratedFor sid = sort [opKey | (_, opKey, owner) <- records, owner == sid]

-- | The first value that appears twice in a sorted list.
firstDuplicate :: (Eq a) => [a] -> Maybe a
firstDuplicate (x : y : rest)
    | x == y = Just x
    | otherwise = firstDuplicate (y : rest)
firstDuplicate _ = Nothing

{- | What the interpreter did with one recorded operation.

Every constructor is a /handled/ outcome. The unknown phase is not one of them:
it has no disposition the interpreter may act on, so it refuses the whole
interpretation rather than appearing here as a fifth kind of success.
-}
data RecoveredOperation
    = -- | already committed; left exactly as it was
      OperationAlreadySettled Text Text
    | -- | already terminal; left exactly as it was
      OperationAlreadyTerminal Text Text
    | -- | pre-call, so no effect was attempted; recorded terminal for this run
      OperationAbandonedPreCall Text Text
    | -- | observed-absent under the old fence; recorded terminal for this run
      OperationAbandonedRetryable Text Text
    deriving (Eq, Show)

{- | The result of running the recorded-session interpreter over one plan.

Its constructor is private: it exists only as evidence that every session in the
manifest was driven to Closed and every one of their operations was handled.
-}
data InterpretedRecovery scope planId
    = InterpretedRecovery Text [SessionId] [RecoveredOperation]

instance Show (InterpretedRecovery scope planId) where
    show (InterpretedRecovery plan sessions operations) =
        "InterpretedRecovery "
            <> show plan
            <> " "
            <> show (length sessions)
            <> " "
            <> show (length operations)

interpretedRecoveryPlanDigest :: InterpretedRecovery scope planId -> Text
interpretedRecoveryPlanDigest (InterpretedRecovery plan _ _) = plan

-- | Every session the interpretation drove to Closed, in the order it drove them.
interpretedRecoverySessions :: InterpretedRecovery scope planId -> [SessionId]
interpretedRecoverySessions (InterpretedRecovery _ sessions _) = sessions

-- | Every operation the interpretation handled, with what it did to each.
interpretedRecoveryOperations :: InterpretedRecovery scope planId -> [RecoveredOperation]
interpretedRecoveryOperations (InterpretedRecovery _ _ operations) = operations

{- | Drive every session in the manifest to Closed under the fresh broker
generation, handling each of its operations by its recorded disposition.

This is § EE's recorded-session interpreter, and it is what normal activation
with an older Open session must run before any current-broker session admission.
It is a strictly stronger thing than 'recoverAbandonedSessions': that sweep
closes Open sessions and /counts/ continuable operations, leaving them at a phase
a later holder could still prepare against, and it never rebinds a session to the
generation that is about to run. This one settles them and rebinds.

Per session, in order:

1. every operation is classified. 'UnknownDisposition' refuses the whole
   interpretation — a phase this binary cannot classify is exactly the case where
   guessing is unsafe, so it blocks admission rather than being swept;
2. a 'Continuable' or 'FencedRetryable' operation is recorded terminal at
   @RecoveryAbandoned@. That is sound in both cases and for the same reason: the
   run that registered the operation is dead, so nothing will continue it. The
   pre-call one attempted no effect at all; the retryable one attempted an effect
   and observed its absence, and its permit is in the set 'fenceOldPermits'
   already superseded, so a delayed landing cannot be mistaken for this run's;
3. a 'Settled' or 'TerminalDisposition' operation is left byte-for-byte alone.
   Recovery never rewrites committed work;
4. the session record is compare-and-swapped to the fresh broker generation while
   /still Open/ — the rebind § EE names — so what closes next is unambiguously
   this generation's record and not a record another generation could still be
   holding a version of;
5. only then is the session closed, which re-proves through
   'closeOperationSession' that no operation was left unsettled.

The permit is threaded through all of it, so the whole interpretation is one
chain of sole-successor advances rather than a set of independent writes.
-}
interpretRecordedSessions ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    VerifiedSessionManifest scope planId ->
    OldPermitsFenced scope planId ->
    ProjectPermit scope planId ->
    IO (Either SessionError (InterpretedRecovery scope planId, ProjectPermit scope planId))
interpretRecordedSessions session epoch manifest fenced permit
    | manifestPlanDigest manifest /= oldPermitsFencedPlanDigest fenced =
        pure
            ( Left
                ( SessionRecoveryPlanMismatch
                    (manifestPlanDigest manifest)
                    (oldPermitsFencedPlanDigest fenced)
                )
            )
    | otherwise = do
        driven <- foldM step (Right ([], [], permit)) (manifestSessions manifest)
        pure $ case driven of
            Left failure -> Left failure
            Right (sessions, operations, finalPermit) ->
                Right
                    ( InterpretedRecovery planDigest (reverse sessions) (reverse operations)
                    , finalPermit
                    )
  where
    planDigest = manifestPlanDigest manifest

    step (Left failure) _ = pure (Left failure)
    step (Right (sessions, operations, current)) member = do
        handled <- foldM (handleOperation member) (Right (operations, current)) (manifestSessionOperations member)
        case handled of
            Left failure -> pure (Left failure)
            Right (afterOperations, afterPermit) -> do
                closed <- rebindAndClose member afterPermit
                pure $ case closed of
                    Left failure -> Left failure
                    Right nextPermit ->
                        Right (manifestSessionId member : sessions, afterOperations, nextPermit)

    handleOperation _ (Left failure) _ = pure (Left failure)
    handleOperation member (Right (operations, current)) opKey =
        case operationKeyFor planDigest (manifestSessionId member) opKey of
            Left failure -> pure (Left failure)
            Right oKey -> do
                observed <- readTransactionRecord session oKey
                case observed of
                    Left failure -> pure (Left (transactionFailure failure))
                    -- The manifest enumerated this key from the store under the
                    -- same protected entry, so an absent record here is a torn
                    -- store rather than an ordinary miss.
                    Right Nothing -> pure (Left (SessionManifestOrphanOperation opKey (sessionIdText (manifestSessionId member))))
                    Right (Just record) -> do
                        let recorded = phaseTextOf (transactionRecordPayload record)
                        case classifyRecordedPhase recorded of
                            UnknownDisposition ->
                                pure (Left (SessionUnclassifiedPhase opKey recorded))
                            Settled ->
                                pure (Right (OperationAlreadySettled opKey recorded : operations, current))
                            TerminalDisposition ->
                                pure (Right (OperationAlreadyTerminal opKey recorded : operations, current))
                            Continuable ->
                                abandon member oKey record opKey recorded operations current OperationAbandonedPreCall
                            FencedRetryable ->
                                abandon member oKey record opKey recorded operations current OperationAbandonedRetryable

    abandon member oKey record opKey recorded operations (ProjectPermit current) build = do
        let desired =
                encodeFields
                    [ "RecoveryAbandoned"
                    , sessionIdText (manifestSessionId member)
                    , Text.pack (show (oldPermitsFencedTo fenced))
                    , Text.pack (show (recordedAttempt (transactionRecordPayload record)))
                    ]
        advanced <-
            runTransaction
                session
                planDigest
                current
                TxnAcknowledgeOutcome
                [operationTransactionTarget oKey (Just record) desired]
        pure $ case advanced of
            Left failure -> Left failure
            Right next -> Right (build opKey recorded : operations, ProjectPermit next)

    rebindAndClose member current@(ProjectPermit raw) =
        case sessionKey planDigest (manifestSessionId member) of
            Left failure -> pure (Left failure)
            Right sKey -> do
                observed <- readSessionRecord session planDigest (manifestSessionId member)
                case observed of
                    Left failure -> pure (Left failure)
                    Right Nothing ->
                        pure (Left (SessionManifestMissingRecord (manifestSessionId member)))
                    Right (Just (record, state))
                        -- A session already Closed needs neither rebind nor
                        -- close; it is a member of the manifest because the set
                        -- is complete, not because it has work outstanding.
                        | not (sessionRecordIsOpen state) -> pure (Right current)
                        | otherwise -> do
                            rebound <-
                                runTransaction
                                    session
                                    planDigest
                                    raw
                                    TxnRebindSession
                                    [ sessionTransactionTarget
                                        sKey
                                        (Just record)
                                        ( encodeSessionRecord
                                            True
                                            (Text.pack (show (brokerEpochWord epoch)))
                                            (manifestSessionOperations member)
                                        )
                                    ]
                            case rebound of
                                Left failure -> pure (Left failure)
                                Right next ->
                                    closeOperationSession
                                        session
                                        OperationSession
                                            { sessionRecordId = manifestSessionId member
                                            , sessionPlanDigest = planDigest
                                            , sessionBrokerGeneration = brokerEpochWord epoch
                                            }
                                        (ProjectPermit next)

{- | Proof that the current broker generation may open sessions for this plan.

§ EE: "Only both complete session/operation sets yield
'CurrentBrokerSessionAdmission'; missing/duplicate records, wrong membership,
missing/replaced resource evidence, or unresolved recovery cannot manufacture it
or create a second logical session."

So its constructor is private and 'admitCurrentBroker' is its sole producer,
requiring all three of the fence set, the manifest, and the interpretation that
consumed them — and requiring the interpretation to have covered the manifest
exactly. A caller cannot verify a manifest, skip the interpreter, and present the
manifest alone.
-}
data CurrentBrokerSessionAdmission scope planId brokerGeneration
    = CurrentBrokerSessionAdmission Text Word64 Int Int

instance Show (CurrentBrokerSessionAdmission scope planId brokerGeneration) where
    show (CurrentBrokerSessionAdmission plan generation sessions operations) =
        "CurrentBrokerSessionAdmission "
            <> show plan
            <> " "
            <> show generation
            <> " "
            <> show sessions
            <> " "
            <> show operations

admissionPlanDigest :: CurrentBrokerSessionAdmission scope planId brokerGeneration -> Text
admissionPlanDigest (CurrentBrokerSessionAdmission plan _ _ _) = plan

admissionBrokerGeneration ::
    CurrentBrokerSessionAdmission scope planId brokerGeneration -> Word64
admissionBrokerGeneration (CurrentBrokerSessionAdmission _ generation _ _) = generation

-- | How many sessions the admission's manifest covered.
admissionSessionCount :: CurrentBrokerSessionAdmission scope planId brokerGeneration -> Int
admissionSessionCount (CurrentBrokerSessionAdmission _ _ sessions _) = sessions

-- | How many operations the admission's manifest covered.
admissionOperationCount :: CurrentBrokerSessionAdmission scope planId brokerGeneration -> Int
admissionOperationCount (CurrentBrokerSessionAdmission _ _ _ operations) = operations

{- | Mint current-broker session admission from the complete evidence, or refuse.

Every input is compared rather than trusted:

* all three values must be over the same plan digest, because the phantom indices
  alone would let evidence taken for one plan authorize another;
* the interpretation must have covered exactly the manifest's sessions. A
  manifest of three sessions and an interpretation of two is
  'SessionRecoveryIncomplete', which is the "unresolved recovery" § EE says
  cannot manufacture an admission;
* every session must be observed Closed /again/, at this store version, through
  'verifyAllSessionsClosed'. The interpreter proved it drove them closed; this
  re-proves it against the store after the fact, so a session reopened between
  the interpretation and the admission refuses.
-}
admitCurrentBroker ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    VerifiedSessionManifest scope planId ->
    OldPermitsFenced scope planId ->
    InterpretedRecovery scope planId ->
    IO (Either SessionError (CurrentBrokerSessionAdmission scope planId brokerGeneration))
admitCurrentBroker session epoch manifest fenced interpreted
    | manifestPlanDigest manifest /= oldPermitsFencedPlanDigest fenced =
        pure
            ( Left
                ( SessionRecoveryPlanMismatch
                    (manifestPlanDigest manifest)
                    (oldPermitsFencedPlanDigest fenced)
                )
            )
    | manifestPlanDigest manifest /= interpretedRecoveryPlanDigest interpreted =
        pure
            ( Left
                ( SessionRecoveryPlanMismatch
                    (manifestPlanDigest manifest)
                    (interpretedRecoveryPlanDigest interpreted)
                )
            )
    | sort (map manifestSessionId (manifestSessions manifest))
        /= sort (interpretedRecoverySessions interpreted) =
        pure
            ( Left
                ( SessionRecoveryIncomplete
                    (length (manifestSessions manifest))
                    (length (interpretedRecoverySessions interpreted))
                )
            )
    | otherwise = do
        closed <- verifyAllSessionsClosed session (manifestPlanDigest manifest)
        pure $ case closed of
            Left (SessionStillOpen sid) ->
                Left (SessionRecoveryUnresolved (sessionIdText sid <> " is still open"))
            Left failure -> Left failure
            Right (proof :: VerifiedAllSessionsClosed scope planId) ->
                Right
                    ( CurrentBrokerSessionAdmission
                        (allSessionsClosedPlanDigest proof)
                        (brokerEpochWord epoch)
                        (length (manifestSessions manifest))
                        (manifestOperationCount manifest)
                    )

-- ---------------------------------------------------------------------------
-- The prepare compare-and-swap

{- | Run one operation's prepare compare-and-swap.

The order is the contract. Before the continuation sees anything, this
revalidates the live broker generation, that the session is still Open, that the
project journal is Open and at the presented version, that the fence is the
current observed one, and that the operation's recorded phase is one recovery
classified as able to receive authority. It then **durably records the
operation-specific unknown phase**, so a crash between here and the adapter
leaves evidence that an effect may have been attempted. Only then does it mint
the pure prepared pair and hand both halves to the continuation.

The journal version it consumed is spent: the successor permit carries the new
version, and a retained older permit fails the compare-and-swap.
-}
withPreparedGate ::
    ProtectedSession session ->
    OperationSession scope planId ->
    BrokerEpoch brokerGeneration ->
    FenceEpoch scope planId ->
    -- | the operation key
    Text ->
    -- | the unknown phase to record before the call
    Text ->
    ProjectPermit scope planId ->
    ( PreparedGate ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
withPreparedGate session sess epoch fence opKey unknownPhase (ProjectPermit presented) use
    | brokerEpochWord epoch /= sessionBrokerGeneration sess =
        pure
            ( Left
                ( SessionBrokerEpochMismatch
                    (sessionBrokerGeneration sess)
                    (brokerEpochWord epoch)
                )
            )
    | otherwise = withCurrentOpenPermit session plan presented $ do
        live <- readSessionRecord session plan (sessionRecordId sess)
        case live of
            Left failure -> pure (Left failure)
            Right Nothing -> pure (Left (SessionNotOpen (sessionRecordId sess)))
            Right (Just (_, state))
                | not (sessionRecordIsOpen state) ->
                    pure (Left (SessionNotOpen (sessionRecordId sess)))
                | otherwise -> do
                    members <- sessionOperationNames session plan (sessionRecordId sess) state
                    case members of
                        Left failure -> pure (Left failure)
                        Right names
                            | opKey `notElem` names ->
                                pure (Left (SessionOperationUnregistered opKey))
                            | otherwise -> do
                                observedFence <- currentFence session plan
                                case observedFence of
                                    Left failure -> pure (Left failure)
                                    Right (FenceEpoch liveEpoch)
                                        | liveEpoch /= fenceEpochWord fence ->
                                            pure (Left (SessionFenceSuperseded (fenceEpochWord fence) liveEpoch))
                                        | otherwise -> gateOperation liveEpoch
  where
    plan = sessionPlanDigest sess

    gateOperation liveEpoch = case operationKeyFor plan (sessionRecordId sess) opKey of
        Left failure -> pure (Left failure)
        Right oKey -> do
            observed <- readTransactionRecord session oKey
            case observed of
                Left failure -> pure (Left (transactionFailure failure))
                Right Nothing -> pure (Left (SessionOperationUnregistered opKey))
                Right (Just record) -> do
                    let recorded = phaseTextOf (transactionRecordPayload record)
                        priorFence = recordedFenceOf (transactionRecordPayload record)
                    case classifyRecordedPhase recorded of
                        UnknownDisposition -> pure (Left (SessionUnclassifiedPhase opKey recorded))
                        Settled -> pure (Left (SessionOperationSettled opKey recorded))
                        TerminalDisposition -> pure (Left (SessionOperationTerminal opKey recorded))
                        FencedRetryable
                            | priorFence >= liveEpoch ->
                                pure (Left (SessionRetryNeedsFreshFence opKey priorFence liveEpoch))
                            | otherwise -> advance oKey record liveEpoch
                        Continuable -> advance oKey record liveEpoch

    advance oKey record liveEpoch = do
        let attempt = recordedAttempt (transactionRecordPayload record) + 1
            desired =
                encodeFields
                    [ unknownPhase
                    , sessionIdText (sessionRecordId sess)
                    , Text.pack (show liveEpoch)
                    , Text.pack (show attempt)
                    ]
        advanced <-
            runTransaction
                session
                plan
                presented
                TxnPrepareOperation
                [operationTransactionTarget oKey (Just record) desired]
        case advanced of
            Left failure -> pure (Left failure)
            Right next -> do
                committed <- readTransactionRecord session oKey
                case committed of
                    Left failure -> pure (Left (transactionFailure failure))
                    Right Nothing -> pure (Left (SessionOperationUnregistered opKey))
                    Right (Just durable)
                        | transactionRecordPayload durable /= desired ->
                            pure (Left (SessionRecordCorrupt "prepared operation"))
                        | otherwise ->
                            use
                                ( mintPreparedGate
                                    plan
                                    opKey
                                    (sessionIdText (sessionRecordId sess))
                                    liveEpoch
                                    attempt
                                    (recordVersionWord (transactionRecordVersion durable))
                                )
                                (ProjectPermit next)

{- | The route from a step's plan-minted execution descriptor to the prepared
gate for **that step's own operation** (§ CC).

'withPreparedGate' takes the operation key as an ordinary argument, which is
correct for the core's own operations but is not a route a *step action* may
take: an action holding a descriptor could name any key the plan happens to
contain, and prepare a node other than its own. This seam removes the choice.
The plan digest and the operation key are both read off the descriptor. The
exact producer is 'HostBootstrap.Reconcile.stepExecutionFor' over one admitted
project plan and its matching projected node. A step can therefore reach exactly
one gate — its own.

The @scope@ and @planId@ indices are shared with the 'OperationSession' and the
'FenceEpoch', so a descriptor from one plan cannot be presented in another
plan's session. The plan digest is compared as a *value* as well, because those
indices are phantom on the session side and a caller could otherwise instantiate
them to agree: the descriptor's digest comes from the plan and the session's from
the journal, and a disagreement means the two are not the same interpretation.

Everything else — the broker epoch, the open session, the operation's
registration, the live fence, the recorded phase, and the durable unknown write —
is 'withPreparedGate''s own compare-and-swap, unchanged.
-}
withStepPreparedGate ::
    ProtectedSession session ->
    OperationSession scope planId ->
    BrokerEpoch brokerGeneration ->
    FenceEpoch scope planId ->
    StepExecution scope planId ->
    -- | the unknown phase to record before the call
    Text ->
    ProjectPermit scope planId ->
    ( PreparedGate ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
withStepPreparedGate session sess epoch fence execution unknownPhase permit use
    | stepExecutionPlanDigest execution /= sessionPlanDigest sess =
        pure
            ( Left
                ( SessionStepPlanMismatch
                    (sessionPlanDigest sess)
                    (stepExecutionPlanDigest execution)
                )
            )
    | otherwise =
        withPreparedGate
            session
            sess
            epoch
            fence
            (stepExecutionOperationKey execution)
            unknownPhase
            permit
            use

recordedAttempt :: ByteString -> Word64
recordedAttempt raw = case decodeFields raw of
    (_ : _ : _ : attempt : _) -> maybe 0 id (readWord attempt)
    _ -> 0

-- ---------------------------------------------------------------------------
-- Terminal acknowledgment

{- | A settled terminal observation. Its eliminator is the only way to read the
adapter's result, and it yields that result together with the sole successor
permit — so a caller cannot take the result and keep the old permit.
-}
data OperationAdvance scope planId result
    = OperationAdvance result (ProjectPermit scope planId)

instance Show (OperationAdvance scope planId result) where
    show (OperationAdvance _ permit) = "OperationAdvance <result> " <> show permit

{- | Record an operation's terminal phase and mint its advance.

Refuses a phase the journal graph does not allow from the recorded one, so an
adapter cannot report an outcome that skips the durable unknown state.
-}
acknowledgeOutcome ::
    ProtectedSession session ->
    OperationSession scope planId ->
    PreparedGate ->
    -- | the observed terminal phase
    Text ->
    result ->
    ProjectPermit scope planId ->
    IO (Either SessionError (OperationAdvance scope planId result))
acknowledgeOutcome session sess gate observedPhase result (ProjectPermit presented)
    | preparedGatePlan gate /= plan =
        pure (Left (SessionPreparedGateMismatch "plan"))
    | preparedGateSession gate /= sessionIdText (sessionRecordId sess) =
        pure (Left (SessionPreparedGateMismatch "session"))
    | otherwise =
        withCurrentOpenPermit session plan presented $
            case operationKeyFor plan (sessionRecordId sess) (preparedGateOperation gate) of
                Left failure -> pure (Left failure)
                Right oKey -> do
                    observed <- readTransactionRecord session oKey
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionOperationUnregistered (preparedGateOperation gate)))
                        Right (Just record)
                            | transactionVersionOf record /= preparedGateJournalVersion gate ->
                                pure
                                    ( Left
                                        ( SessionStaleJournalVersion
                                            (preparedGateJournalVersion gate)
                                            (transactionVersionOf record)
                                        )
                                    )
                            | not (gateMatchesRecord sess gate (transactionRecordPayload record)) ->
                                pure (Left (SessionPreparedGateMismatch "durable operation"))
                            | otherwise -> do
                                advanced <-
                                    runTransaction
                                        session
                                        plan
                                        presented
                                        TxnAcknowledgeOutcome
                                        [ operationTransactionTarget
                                            oKey
                                            (Just record)
                                            ( encodeFields
                                                [ observedPhase
                                                , sessionIdText (sessionRecordId sess)
                                                , Text.pack (show (preparedGateFence gate))
                                                , Text.pack (show (preparedGateAttempt gate))
                                                ]
                                            )
                                        ]
                                pure
                                    ( OperationAdvance result . ProjectPermit
                                        <$> advanced
                                    )
  where
    plan = sessionPlanDigest sess

transactionVersionOf :: TransactionRecord -> Word64
transactionVersionOf = recordVersionWord . transactionRecordVersion

gateMatchesRecord :: OperationSession scope planId -> PreparedGate -> ByteString -> Bool
gateMatchesRecord sess gate raw = case decodeFields raw of
    [_phase, recordedSession, fence, attempt] ->
        recordedSession == sessionIdText (sessionRecordId sess)
            && readWord fence == Just (preparedGateFence gate)
            && readWord attempt == Just (preparedGateAttempt gate)
    _ -> False

-- | Eliminate an advance: the result is available only with its successor permit.
withOperationAdvance ::
    OperationAdvance scope planId result ->
    (result -> ProjectPermit scope planId -> outcome) ->
    outcome
withOperationAdvance (OperationAdvance result permit) use = use result permit

-- ---------------------------------------------------------------------------
-- Failures

-- | Lifecycle composition failures currently share Session's closed error
-- vocabulary. This preserves the target signature without introducing a
-- second public error data contract.
type LifecycleError = SessionError

lifecycleErrorMessage :: LifecycleError -> String
lifecycleErrorMessage = sessionErrorMessage

data SessionError
    = SessionStoreFailure ProtectedError
    | SessionTransactionFailure Text
    | SessionRecordCorrupt Text
    | SessionProjectMissing Text
    | SessionProjectClosed Text
    | -- | terminal close is under way, so no new work is admitted
      SessionProjectClosing Text
    | -- | a session was still Open when a completeness proof was required
      SessionStillOpen SessionId
    | SessionStaleProjectPermit Word64
    | SessionOlderStillOpen SessionId
    | SessionUnknown SessionId
    | SessionNotOpen SessionId
    | SessionBrokerEpochMismatch Word64 Word64
    | SessionFenceInvalid Text
    | SessionFenceMissing Text
    | SessionFenceUnsettled FencePhase
    | -- | presented epoch, then the live one
      SessionFenceSuperseded Word64 Word64
    | SessionIntentAlreadyRecorded Text Text
    | SessionIntentOriginRefused Text Text
    | SessionOperationUnregistered Text
    | SessionOperationSettled Text Text
    | SessionOperationTerminal Text Text
    | SessionOperationUnsettled Text
    | SessionRetryNeedsFreshFence Text Word64 Word64
    | SessionUnclassifiedPhase Text Text
    | SessionPreparedGateMismatch Text
    | -- | the session's plan digest, then the step descriptor's
      SessionStepPlanMismatch Text Text
    | -- | consumed version, then the version actually on the record
      SessionStaleJournalVersion Word64 Word64
    | -- | an operation record names a session the manifest does not carry
      SessionManifestOrphanOperation Text Text
    | -- | the store holds two records resolving to one session identity
      SessionManifestDuplicateSession SessionId
    | -- | the session's declared membership, then what the store actually holds
      SessionManifestMembershipMismatch SessionId Text Text
    | -- | a manifest member's session record vanished between enumeration and use
      SessionManifestMissingRecord SessionId
    | -- | a value taken over one plan digest was presented for another
      SessionRecoveryPlanMismatch Text Text
    | -- | recovery left something an operator must resolve, so nothing is admitted
      SessionRecoveryUnresolved Text
    | -- | the interpretation did not cover the manifest it was taken against
      SessionRecoveryIncomplete Int Int
    | -- | one required immutable acquisition binding field was absent or zero
      SessionAcquisitionBindingInvalid Text
    | -- | field, expected value, observed value
      SessionAcquisitionBindingMismatch Text Text Text
    | -- | the authenticated root acquisition row does not exist
      SessionAcquisitionMissing Text
    | -- | one cursor binding member is empty or exceeds its canonical bound
      SessionCursorBindingInvalid Text
    | -- | field, expected value, observed value
      SessionCursorBindingMismatch Text Text Text
    | -- | journal/cursor root verb, then the requested verb
      SessionCursorVerbMismatch Text Text
    | -- | authoritative current phase, then the requested phase
      SessionCursorPhaseMismatch Text Text
    | -- | a non-seed child phase was requested before its cursor existed
      SessionCursorMissing Text
    | -- | retained cursor version, then the current protected version
      SessionStaleCursorVersion Word64 Word64
    deriving (Eq, Show)

sessionErrorMessage :: SessionError -> String
sessionErrorMessage err = case err of
    SessionStoreFailure failure -> "session: " <> Text.unpack (protectedErrorMessage failure)
    SessionTransactionFailure failure -> "session: " <> Text.unpack failure
    SessionRecordCorrupt what -> "session: the " <> Text.unpack what <> " record is unreadable"
    SessionProjectMissing plan -> "session: no project journal for plan " <> Text.unpack plan
    SessionProjectClosed plan -> "session: the project journal for " <> Text.unpack plan <> " is closed"
    SessionProjectClosing plan ->
        "session: the project journal for "
            <> Text.unpack plan
            <> " is closing; no new work is admitted"
    SessionStillOpen sid ->
        "session: " <> Text.unpack (sessionIdText sid) <> " is still open"
    SessionStaleProjectPermit version ->
        "session: project permit version " <> show version <> " is no longer current"
    SessionOlderStillOpen sid ->
        "session: an older session " <> Text.unpack (sessionIdText sid) <> " is still open"
    SessionUnknown sid -> "session: no record for " <> Text.unpack (sessionIdText sid)
    SessionNotOpen sid -> "session: " <> Text.unpack (sessionIdText sid) <> " is not open"
    SessionBrokerEpochMismatch expected actual ->
        "session: broker generation " <> show actual <> " does not match the session's " <> show expected
    SessionFenceInvalid detail -> "session: " <> Text.unpack detail
    SessionFenceMissing plan -> "session: no fence for plan " <> Text.unpack plan
    SessionFenceUnsettled phase -> "session: the fence is still at " <> show phase
    SessionFenceSuperseded presented live ->
        "session: fence epoch " <> show presented <> " was superseded by " <> show live
    SessionIntentAlreadyRecorded opKey phase ->
        "session: operation " <> Text.unpack opKey <> " already has a record at " <> Text.unpack phase
    SessionIntentOriginRefused opKey phase ->
        "session: operation " <> Text.unpack opKey <> " cannot reacquire from " <> Text.unpack phase
    SessionOperationUnregistered opKey ->
        "session: operation " <> Text.unpack opKey <> " has no registered intent"
    SessionOperationSettled opKey phase ->
        "session: operation " <> Text.unpack opKey <> " is settled at " <> Text.unpack phase
    SessionOperationTerminal opKey phase ->
        "session: operation " <> Text.unpack opKey <> " is terminal at " <> Text.unpack phase
    SessionOperationUnsettled opKey ->
        "session: operation " <> Text.unpack opKey <> " has not settled"
    SessionRetryNeedsFreshFence opKey recorded live ->
        "session: operation "
            <> Text.unpack opKey
            <> " was observed at fence "
            <> show recorded
            <> " and needs a fence above "
            <> show live
    SessionUnclassifiedPhase opKey phase ->
        "session: operation " <> Text.unpack opKey <> " is at unrecognised phase " <> Text.unpack phase
    SessionPreparedGateMismatch field ->
        "session: the prepared gate does not match the " <> Text.unpack field
    SessionStepPlanMismatch sessionPlan stepPlan ->
        "session: the step descriptor belongs to plan "
            <> Text.unpack stepPlan
            <> ", but this session is open on "
            <> Text.unpack sessionPlan
    SessionStaleJournalVersion consumed actual ->
        "session: journal version " <> show consumed <> " was superseded by " <> show actual
    SessionManifestOrphanOperation opKey sid ->
        "session: operation "
            <> Text.unpack opKey
            <> " names session "
            <> Text.unpack sid
            <> ", which is not a member of the manifest"
    SessionManifestDuplicateSession sid ->
        "session: " <> Text.unpack (sessionIdText sid) <> " is recorded more than once"
    SessionManifestMembershipMismatch sid declared enumerated ->
        "session: "
            <> Text.unpack (sessionIdText sid)
            <> " declares membership ["
            <> Text.unpack declared
            <> "] but the store holds ["
            <> Text.unpack enumerated
            <> "]"
    SessionManifestMissingRecord sid ->
        "session: the record for " <> Text.unpack (sessionIdText sid) <> " is gone"
    SessionRecoveryPlanMismatch expected presented ->
        "session: recovery evidence for plan "
            <> Text.unpack presented
            <> " was presented for "
            <> Text.unpack expected
    SessionRecoveryUnresolved detail ->
        "session: recovery is unresolved: " <> Text.unpack detail
    SessionRecoveryIncomplete manifested interpreted ->
        "session: the interpretation covered "
            <> show interpreted
            <> " of the manifest's "
            <> show manifested
            <> " sessions"
    SessionAcquisitionBindingInvalid field ->
        "session: the acquisition journal "
            <> Text.unpack field
            <> " binding is invalid"
    SessionAcquisitionBindingMismatch field expected observed ->
        "session: the acquisition journal "
            <> Text.unpack field
            <> " expected "
            <> Text.unpack expected
            <> " but observed "
            <> Text.unpack observed
    SessionAcquisitionMissing key ->
        "session: no authenticated acquisition record exists at " <> Text.unpack key
    SessionCursorBindingInvalid field ->
        "session: the lifecycle cursor "
            <> Text.unpack field
            <> " binding is invalid"
    SessionCursorBindingMismatch field expected observed ->
        "session: the lifecycle cursor "
            <> Text.unpack field
            <> " expected "
            <> Text.unpack expected
            <> " but observed "
            <> Text.unpack observed
    SessionCursorVerbMismatch expected observed ->
        "session: the lifecycle cursor verb "
            <> Text.unpack observed
            <> " does not match the journal's "
            <> Text.unpack expected
    SessionCursorPhaseMismatch expected observed ->
        "session: the lifecycle cursor phase "
            <> Text.unpack observed
            <> " does not match the authoritative "
            <> Text.unpack expected
    SessionCursorMissing frame ->
        "session: no lifecycle cursor exists for frame " <> Text.unpack frame
    SessionStaleCursorVersion expected observed ->
        "session: lifecycle cursor version "
            <> show expected
            <> " was superseded by "
            <> show observed
