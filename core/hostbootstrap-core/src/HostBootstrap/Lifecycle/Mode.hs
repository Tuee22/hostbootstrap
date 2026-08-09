{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Project-wide lifecycle mode, run leases, and the lifecycle-profile openers
(§ EE, the test-harness-and-run-ownership phase the test-harness-and-run-ownership phase).

A project is in exactly one mode at a time — Production or one Harness run — and
that exclusion is a single protected record both openers contend on.  Production
retains its mode across @down@; a Harness run releases its mode only after
terminal close.  Neither profile can slip between a precondition check and
ownership, because the check is re-run inside the same compare-and-swap that
takes the mode.

The run lease is the second half. An opener records an
'UnboundRunLease' before it has a plan; only after the plan snapshot is
persisted and verified does 'bindRunLease' produce the 'BoundRunLease' that
every later effect requires.  A crash therefore always leaves a durable,
classifiable lease rather than an opaque lock directory:

* an unbound incomplete lease can be closed by the sweep once
  'verifyUnboundLeaseHasNoEffects' proves it recorded no effect;
* a bound incomplete lease is reopened through 'withAbandonedHarnessRun', which
  rechecks it, reads back its snapshot, classifies its durable invocation record,
  and yields @destroy@-only recovery and close authority on a fresh broker
  generation. A new run is not allocated until every old lease closes.

That is the direct replacement for the bare @createDirectory@ ownership claim
whose crash left @.test_data@ and @.test_data.hostbootstrap-run-owner@ behind
with no way to tell a dead predecessor from a live one.
-}
module HostBootstrap.Lifecycle.Mode (
    -- * Run identity
    RunId,
    mkRunId,
    runIdText,

    -- * Modes
    ProjectMode (..),
    projectModeName,
    ProjectModeLease,
    projectModeLeaseMode,
    projectModeLeaseEpoch,

    -- * Plan snapshots
    VerifiedPlanSnapshot,
    planSnapshotRun,
    planSnapshotRevision,
    planSnapshotSpecDigest,
    planSnapshotPlanDigest,
    planSnapshotConfigDigest,
    planSnapshotCanonicalBytes,
    persistPlanSnapshot,
    persistCanonicalPlanSnapshot,
    verifyPlanSnapshot,

    -- * Run leases
    UnboundRunLease,
    unboundRunLeaseRun,
    BoundRunLease,
    boundRunLeaseRun,
    boundRunLeaseSpecDigest,
    boundRunLeasePlanDigest,
    RunLeaseBinding (..),
    NormalActiveRecovery,
    normalActiveRecoveryRun,
    bindRunLease,

    -- * Bound-invocation recovery
    BoundInvocationRecovery,
    boundInvocationRecoveryRun,
    OpenRevisionRecovery,
    openRevisionRecoveryRun,
    OpenRevisionKind (..),
    openRevisionKind,
    ProductionBoundRecovery (..),
    eliminateProductionBoundRecovery,
    HarnessBoundRecovery (..),
    eliminateHarnessBoundRecovery,
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
    lifecycleProfileMode,
    lifecycleProfileEpoch,
    withProductionLifecycleProfile,
    withHarnessLifecycleProfile,
    RecoveredProductionLifecycleProfile,
    recoveredProductionProfileRun,
    recoveredProductionProfileSpecDigest,
    recoveredProductionProfilePlanDigest,
    recoveredProductionProfileEpoch,
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
    productionRunId,
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
    destroySettledClosure,
    verifyUnboundLeaseHasNoEffects,
    VerifiedUnboundLeaseHasNoEffects,
    releaseProductionMode,
    closeHarnessRun,

    -- * Abandoned-run recovery
    VerifiedIncompleteRunLease,
    incompleteRunLeaseRun,
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
) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import HostBootstrap.Authority (
    AuthorityError,
    BrokerEpoch,
    InstalledProject,
    OperatorAuthorization,
    ProductionCloseKind (PreEffectRefusalClose, SettledDestroyClose),
    ProductionCloseRoot,
    ProjectVerb (ProjectDestroy),
    RootInvocationAuthority,
    VerbDestroy,
    VerbUp,
    authorityErrorMessage,
    brokerEpochWord,
    installedProjectName,
    productionCloseRootVerb,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    verifyOperatorAuthorization,
    withFreshBrokerEpoch,
    withVerifiedRootInvocation,
 )
import HostBootstrap.Config.Authority.Internal (
    HarnessAuthority,
    mintHarnessAuthority,
 )
import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Lifecycle.Plan (
    CanonicalPlanSnapshot,
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotConfigDigest,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotSpecDigest,
 )
import HostBootstrap.Lifecycle.Session (
    CurrentBrokerSessionAdmission,
    InterpretedRecovery,
    OldPermitsFenced,
    ProjectPermit,
    SessionError,
    VerifiedAllSessionsClosed,
    VerifiedSessionManifest,
    admitCurrentBroker,
    allSessionsClosedCount,
    allSessionsClosedPlanDigest,
    fenceOldPermits,
    interpretRecordedSessions,
    openProjectJournal,
    sessionErrorMessage,
    verifySessionManifest,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    protectedErrorMessage,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Teardown (
    DestroySettled,
    destroySettledPlanDigest,
 )
import System.Directory (doesFileExist)
import System.FilePath ((<.>), (</>))

-- Run identity -----------------------------------------------------------------

{- | A generative harness run identifier. It names the run's cluster, data root,
and lease; it is not itself authority.
-}
newtype RunId = RunId Text
    deriving (Eq, Ord)

instance Show RunId where
    show (RunId value) = "RunId " <> show value

runIdText :: RunId -> Text
runIdText (RunId value) = value

mkRunId :: Text -> Either ModeError RunId
mkRunId raw
    | Text.null raw = Left (ModeInvalidIdentity "a run id must not be empty")
    | Text.length raw > 48 = Left (ModeInvalidIdentity "a run id must be at most 48 characters")
    | not (Text.all legal raw) =
        Left (ModeInvalidIdentity ("a run id may contain only alphanumerics and '-': " <> raw))
    | otherwise = Right (RunId raw)
  where
    legal character = isAlphaNum character || character == '-'

freshRunId :: IO RunId
freshRunId = do
    stamp <- getMonotonicTimeNSec
    pure (RunId (Text.pack ("run-" <> showHexWord stamp)))

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

-- | The project-wide mode. Exactly one is active at a time.
data ProjectMode
    = ProductionMode
    | HarnessMode RunId
    deriving (Eq, Show)

projectModeName :: ProjectMode -> Text
projectModeName ProductionMode = "production"
projectModeName (HarnessMode run) = "harness:" <> runIdText run

{- | The held project-wide mode lease. Its constructor is private: a lease value
exists only where the protected compare-and-swap that took the mode succeeded.
-}
data ProjectModeLease projectId brokerGeneration
    = ProjectModeLease ProjectMode (BrokerEpoch brokerGeneration)

instance Show (ProjectModeLease projectId brokerGeneration) where
    show (ProjectModeLease mode epoch) =
        "ProjectModeLease " <> show mode <> " " <> show epoch

projectModeLeaseMode :: ProjectModeLease projectId brokerGeneration -> ProjectMode
projectModeLeaseMode (ProjectModeLease mode _) = mode

projectModeLeaseEpoch ::
    ProjectModeLease projectId brokerGeneration -> BrokerEpoch brokerGeneration
projectModeLeaseEpoch (ProjectModeLease _ epoch) = epoch

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
data VerifiedPlanSnapshot projectId specDigest planDigest
    = VerifiedPlanSnapshot RunId Word64 Text Text (Maybe Text) (Maybe ByteString)

instance Show (VerifiedPlanSnapshot projectId specDigest planDigest) where
    show (VerifiedPlanSnapshot run revision spec plan config canonicalBytes) =
        "VerifiedPlanSnapshot "
            <> show run
            <> " "
            <> show revision
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> maybe " <digest-only>" (const " <canonical>") config
            <> maybe "" (\bytes -> " <" <> show (ByteString.length bytes) <> " bytes>") canonicalBytes

planSnapshotRun :: VerifiedPlanSnapshot projectId specDigest planDigest -> RunId
planSnapshotRun (VerifiedPlanSnapshot run _ _ _ _ _) = run

-- | The active plan revision. Positive by construction.
planSnapshotRevision :: VerifiedPlanSnapshot projectId specDigest planDigest -> Word64
planSnapshotRevision (VerifiedPlanSnapshot _ revision _ _ _ _) = revision

planSnapshotSpecDigest :: VerifiedPlanSnapshot projectId specDigest planDigest -> Text
planSnapshotSpecDigest (VerifiedPlanSnapshot _ _ spec _ _ _) = spec

planSnapshotPlanDigest :: VerifiedPlanSnapshot projectId specDigest planDigest -> Text
planSnapshotPlanDigest (VerifiedPlanSnapshot _ _ _ plan _ _) = plan

-- | The exact admitted config digest, present only on a canonical snapshot.
planSnapshotConfigDigest :: VerifiedPlanSnapshot projectId specDigest planDigest -> Maybe Text
planSnapshotConfigDigest (VerifiedPlanSnapshot _ _ _ _ config _) = config

-- | The exact stable plan bytes, present only on a canonical snapshot.
planSnapshotCanonicalBytes :: VerifiedPlanSnapshot projectId specDigest planDigest -> Maybe ByteString
planSnapshotCanonicalBytes (VerifiedPlanSnapshot _ _ _ _ _ bytes) = bytes

data PlanSnapshotRecord = PlanSnapshotRecord
    { snapshotRecordRevision :: Word64
    , snapshotRecordSpecDigest :: Text
    , snapshotRecordPlanDigest :: Text
    , snapshotRecordConfigDigest :: Maybe Text
    , snapshotRecordCanonicalBytes :: Maybe ByteString
    }

snapshotRecordVersion :: Word64
snapshotRecordVersion = 1

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
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    -- | active plan revision; must be positive
    Word64 ->
    -- | spec digest
    Text ->
    -- | plan digest
    Text ->
    IO (Either ModeError ())
persistPlanSnapshot session project run revision spec plan
    | revision == 0 =
        pure (Left (ModeInvalidIdentity "a plan revision must be positive"))
    | Text.null spec || Text.null plan =
        pure (Left (ModeInvalidIdentity "a plan snapshot needs both digests"))
    | not (snapshotTextWithinBound spec) || not (snapshotTextWithinBound plan) =
        pure (Left (ModeInvalidIdentity "a plan snapshot digest exceeds the wire bound"))
    | otherwise =
        persistSnapshotRecord
            session
            project
            run
            (PlanSnapshotRecord revision spec plan Nothing Nothing)

{- | Persist the exact canonical plan bytes together with their revision and
spec/config/plan digests. Every identity is derived from the opaque canonical
snapshot rather than accepted as an independently supplied string.
-}
persistCanonicalPlanSnapshot ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    Word64 ->
    CanonicalPlanSnapshot ->
    IO (Either ModeError ())
persistCanonicalPlanSnapshot session project run revision snapshot
    | revision == 0 =
        pure (Left (ModeInvalidIdentity "a plan revision must be positive"))
    | Text.null spec || Text.null config || Text.null plan || ByteString.null canonicalBytes =
        pure (Left (ModeInvalidIdentity "a canonical plan snapshot needs non-empty identities and bytes"))
    | any (not . snapshotTextWithinBound) [spec, config, plan] =
        pure (Left (ModeInvalidIdentity "a canonical plan snapshot identity exceeds the wire bound"))
    | ByteString.length canonicalBytes > maxCanonicalPlanBytes =
        pure (Left (ModeInvalidIdentity "a canonical plan snapshot exceeds the wire bound"))
    | otherwise =
        persistSnapshotRecord
            session
            project
            run
            (PlanSnapshotRecord revision spec plan (Just config) (Just canonicalBytes))
  where
    spec = canonicalPlanSnapshotSpecDigest snapshot
    config = canonicalPlanSnapshotConfigDigest snapshot
    plan = canonicalPlanSnapshotDigest snapshot
    canonicalBytes = canonicalPlanSnapshotBytes snapshot

persistSnapshotRecord ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    PlanSnapshotRecord ->
    IO (Either ModeError ())
persistSnapshotRecord session project run proposed =
    withRecordKey (snapshotKey project run) $ \key -> do
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
    checkExistingSnapshot key candidate payload existing
        | protectedRecordBytes existing == payload = Right ()
        | otherwise = case decodePlanSnapshotRecord (protectedRecordBytes existing) of
            Just recorded ->
                Left
                    ( ModeSnapshotMismatch
                        (snapshotDescription candidate)
                        (snapshotDescription recorded)
                    )
            _ -> Left (ModeMalformedRecord (recordKeyText key))

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
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    ( forall specDigest planDigest.
      VerifiedPlanSnapshot projectId specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
verifyPlanSnapshot session project run use =
    withRecordKey (snapshotKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeSnapshotMissing (runIdText run)))
            Right (Just record) -> case decodePlanSnapshotRecord (protectedRecordBytes record) of
                Just snapshot ->
                    use
                        ( VerifiedPlanSnapshot
                            run
                            (snapshotRecordRevision snapshot)
                            (snapshotRecordSpecDigest snapshot)
                            (snapshotRecordPlanDigest snapshot)
                            (snapshotRecordConfigDigest snapshot)
                            (snapshotRecordCanonicalBytes snapshot)
                        )
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))

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
data UnboundRunLease scope brokerGeneration
    = UnboundRunLease RunId (BrokerEpoch brokerGeneration)

instance Show (UnboundRunLease scope brokerGeneration) where
    show (UnboundRunLease run epoch) = "UnboundRunLease " <> show run <> " " <> show epoch

unboundRunLeaseRun :: UnboundRunLease scope brokerGeneration -> RunId
unboundRunLeaseRun (UnboundRunLease run _) = run

{- | A lease bound to one verified plan snapshot. Every prepared operation
requires it, so an effect cannot precede the snapshot it claims to belong to.
-}
data BoundRunLease scope specDigest planDigest brokerGeneration
    = BoundRunLease RunId Text Text (BrokerEpoch brokerGeneration)

instance Show (BoundRunLease scope specDigest planDigest brokerGeneration) where
    show (BoundRunLease run spec plan epoch) =
        "BoundRunLease "
            <> show run
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch

boundRunLeaseRun :: BoundRunLease scope specDigest planDigest brokerGeneration -> RunId
boundRunLeaseRun (BoundRunLease run _ _ _) = run

boundRunLeaseSpecDigest ::
    BoundRunLease scope specDigest planDigest brokerGeneration -> Text
boundRunLeaseSpecDigest (BoundRunLease _ spec _ _) = spec

boundRunLeasePlanDigest ::
    BoundRunLease scope specDigest planDigest brokerGeneration -> Text
boundRunLeasePlanDigest (BoundRunLease _ _ plan _) = plan

{- | What binding a lease found. Both branches carry the same
'BoundRunLease' — the lease /is/ bound either way — but they carry different
recovery authority, so a caller cannot treat an abandoned invocation as a fresh
one (§ EE).
-}
data RunLeaseBinding projectId scope specDigest planDigest brokerGeneration
    = {- | The lease was still unbound: this invocation bound it, and there is
      no prior invocation to recover.
      -}
      FreshRunLeaseBinding
        (BoundRunLease scope specDigest planDigest brokerGeneration)
        (NormalActiveRecovery scope)
    | {- | The lease was already bound to this exact snapshot: a previous
      invocation reached a plan and did not settle.
      -}
      ExistingRunLeaseBinding
        (BoundRunLease scope specDigest planDigest brokerGeneration)
        (BoundInvocationRecovery projectId)

{- | Proof that a binding was fresh, so no recovery is owed. Its constructor is
private: absence of recovery is a verified observation, not a default.
-}
data NormalActiveRecovery scope = NormalActiveRecovery RunId

instance Show (NormalActiveRecovery scope) where
    show (NormalActiveRecovery run) = "NormalActiveRecovery " <> show run

normalActiveRecoveryRun :: NormalActiveRecovery scope -> RunId
normalActiveRecoveryRun (NormalActiveRecovery run) = run

{- | Bind a lease to the exact verified plan snapshot, in one protected
compare-and-swap over the recorded lease.

The digests are the snapshot's, not a caller's: they are carried by
'VerifiedPlanSnapshot', which exists only where 'verifyPlanSnapshot' read them
back out of the protected store. That is what makes "the lease is bound to a
snapshot that was persisted and verified" structural rather than a convention,
and it is why the successor lease record can classify an abandoned run without a
config.

An already-bound lease is /not/ an error. It is the abandoned-invocation case,
and it yields 'BoundInvocationRecovery' so the caller must classify it before
doing anything else. A lease bound to *different* digests is refused: that is a
snapshot substitution, not a resumption.
-}
bindRunLease ::
    ProtectedSession session ->
    InstalledProject projectId ->
    UnboundRunLease scope brokerGeneration ->
    VerifiedPlanSnapshot projectId specDigest planDigest ->
    ( RunLeaseBinding projectId scope specDigest planDigest brokerGeneration ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
bindRunLease session project (UnboundRunLease run epoch) snapshot use
    | planSnapshotRun snapshot /= run =
        pure
            ( Left
                ( ModeSnapshotMismatch
                    (runIdText run)
                    (runIdText (planSnapshotRun snapshot))
                )
            )
    | otherwise = withRecordKey (leaseKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeLeaseMissing (runIdText run)))
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Just (LeaseUnbound recordedEpoch)
                    | recordedEpoch /= brokerEpochWord epoch ->
                        pure (Left (ModeEpochMismatch recordedEpoch (brokerEpochWord epoch)))
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeLease (LeaseBound recordedEpoch specDigest planDigest))
                        case written of
                            Left failure -> pure (Left (ModeStoreFailure failure))
                            Right _ ->
                                use
                                    ( FreshRunLeaseBinding
                                        bound
                                        (NormalActiveRecovery run)
                                    )
                Just (LeaseBound _ recordedSpec recordedPlan)
                    | recordedSpec /= specDigest ->
                        pure (Left (ModeSnapshotMismatch specDigest recordedSpec))
                    | recordedPlan /= planDigest ->
                        pure (Left (ModeSnapshotMismatch planDigest recordedPlan))
                    | otherwise -> do
                        disposition <- readInvocationDisposition session project run
                        case disposition of
                            Left failure -> pure (Left failure)
                            Right recorded ->
                                use
                                    ( ExistingRunLeaseBinding
                                        bound
                                        ( BoundInvocationRecovery
                                            run
                                            specDigest
                                            planDigest
                                            recorded
                                        )
                                    )
                Just other ->
                    pure (Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other)))
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
  where
    specDigest = planSnapshotSpecDigest snapshot
    planDigest = planSnapshotPlanDigest snapshot
    bound = BoundRunLease run specDigest planDigest epoch

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

{- | An abandoned invocation that reached a plan. Its constructor is private: it
exists only where 'bindRunLease' observed an already-bound lease, so a caller
cannot claim recovery authority for a run that never bound one.

The value itself authorizes nothing. Only the scope-specific eliminators below
open it, and each refuses the other scope's disposition — a Production recovery
cannot consume a persisted Harness @Closing@ epoch, and a Harness recovery
cannot consume a Production terminal acknowledgment.
-}
data BoundInvocationRecovery projectId
    = BoundInvocationRecovery RunId Text Text InvocationDisposition

instance Show (BoundInvocationRecovery projectId) where
    show (BoundInvocationRecovery run spec plan disposition) =
        "BoundInvocationRecovery "
            <> show run
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show disposition

boundInvocationRecoveryRun :: BoundInvocationRecovery projectId -> RunId
boundInvocationRecoveryRun (BoundInvocationRecovery run _ _ _) = run

{- | The Open branch: the invocation was still operating, so its /revision/ has
to be recovered. Its constructor is private, and it is reached only after the
terminal dispositions have been ruled out.
-}
data OpenRevisionRecovery projectId
    = OpenRevisionRecovery RunId Text Text OpenRevisionKind

instance Show (OpenRevisionRecovery projectId) where
    show (OpenRevisionRecovery run spec plan kind) =
        "OpenRevisionRecovery "
            <> show run
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show kind

openRevisionRecoveryRun :: OpenRevisionRecovery projectId -> RunId
openRevisionRecoveryRun (OpenRevisionRecovery run _ _ _) = run

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

openRevisionKind :: OpenRevisionRecovery projectId -> OpenRevisionKind
openRevisionKind (OpenRevisionRecovery _ _ _ kind) = kind

{- | The Production eliminator. It distinguishes an exact terminal
@up@\/@down@ acknowledgment awaiting or uncertain of its lease close from Open
operational revision recovery. The former yields only the stable close key,
because the sole legal continuation is to resume that same close.
-}
data ProductionBoundRecovery projectId
    = ProductionTerminalAcknowledgment InvocationCloseKey
    | ProductionOpenRevisionRecovery (OpenRevisionRecovery projectId)
    deriving (Show)

eliminateProductionBoundRecovery ::
    ProtectedSession session ->
    InstalledProject projectId ->
    BoundInvocationRecovery projectId ->
    IO (Either ModeError (ProductionBoundRecovery projectId))
eliminateProductionBoundRecovery session project (BoundInvocationRecovery run spec plan disposition) =
    case disposition of
        InvocationAcknowledged key ->
            pure (Right (ProductionTerminalAcknowledgment key))
        InvocationClosing epoch ->
            -- Closing is the Harness terminal projection. A Production
            -- invocation that observed one is looking at another scope's record.
            pure
                ( Left
                    ( ModeWrongRecoveryScope
                        "production"
                        ("harness closing epoch " <> showWord epoch)
                    )
                )
        InvocationOpen -> do
            kind <- readOpenRevisionKind session project run
            pure (fmap (ProductionOpenRevisionRecovery . OpenRevisionRecovery run spec plan) kind)

{- | The Harness eliminator. It distinguishes an exact persisted Closing epoch
from Open before the Open branch selects its revision recovery.
-}
data HarnessBoundRecovery projectId
    = HarnessPersistedClosing Word64
    | HarnessOpenRevisionRecovery (OpenRevisionRecovery projectId)
    deriving (Show)

eliminateHarnessBoundRecovery ::
    ProtectedSession session ->
    InstalledProject projectId ->
    BoundInvocationRecovery projectId ->
    IO (Either ModeError (HarnessBoundRecovery projectId))
eliminateHarnessBoundRecovery session project (BoundInvocationRecovery run spec plan disposition) =
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
            kind <- readOpenRevisionKind session project run
            pure (fmap (HarnessOpenRevisionRecovery . OpenRevisionRecovery run spec plan) kind)

{- | Classify an abandoned __bound__ Harness lease so the sweep can act on it.

'bindRunLease' was the only producer of 'BoundInvocationRecovery', and it needs
an 'UnboundRunLease' that an abandoned run no longer has. Without this, a bound
lease could only be /reported/: the sweep named the run and refused every
variant, and the sole way forward was to delete the run's protected records by
hand — exactly the hand cleanup the recoverable reservation exists to eliminate,
moved from a lock directory into the store.

The only route in is a 'VerifiedIncompleteRunLease' the sweep itself minted, and
only its 'IncompleteBound' kind, so a caller cannot claim recovery authority for
a run that never bound a plan. The digests come from the lease record rather
than the caller, so a substituted snapshot cannot be presented as this run's.
-}
classifyAbandonedBoundRun ::
    ProtectedSession session ->
    InstalledProject projectId ->
    VerifiedIncompleteRunLease projectId ->
    IO (Either ModeError (HarnessBoundRecovery projectId))
classifyAbandonedBoundRun session project (VerifiedIncompleteRunLease run kind) =
    case kind of
        IncompleteUnbound ->
            pure (Left (ModeLeaseNotBindable (runIdText run) "unbound"))
        IncompleteBound spec plan -> do
            disposition <- readInvocationDisposition session project run
            case disposition of
                Left failure -> pure (Left failure)
                Right recorded ->
                    eliminateHarnessBoundRecovery
                        session
                        project
                        (BoundInvocationRecovery run spec plan recorded)

{- | Record an ordinary Production invocation's terminal acknowledgment under a
stable, idempotent close key, /before/ the lease close it authorizes. A crash
between the two therefore leaves the acknowledgment visible, which is exactly
what lets bound recovery resume the same close instead of reopening work.
-}
recordProductionInvocationAcknowledgment ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    InvocationCloseKey ->
    IO (Either ModeError ())
recordProductionInvocationAcknowledgment session project run key =
    writeInvocationDisposition session project run (InvocationAcknowledged key)

{- | Record a Harness run's Closing epoch before its terminal close projection
runs, so a persisted Closing run resumes only its own close journal.
-}
recordHarnessClosingEpoch ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    Word64 ->
    IO (Either ModeError ())
recordHarnessClosingEpoch session project run epoch
    | epoch == 0 =
        pure (Left (ModeInvalidIdentity "a closing epoch must be positive"))
    | otherwise = writeInvocationDisposition session project run (InvocationClosing epoch)

{- | Record which side of the migration activation barrier a revision is on, so
the Open branch's classification is a durable observation rather than an
inference from the current config.
-}
recordOpenRevisionMigration ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    OpenRevisionKind ->
    IO (Either ModeError ())
recordOpenRevisionMigration session project run kind =
    withRecordKey (migrationKey project run) $ \key -> do
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

readInvocationDisposition ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError InvocationDisposition)
readInvocationDisposition session project run =
    withRecordKey (invocationKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Right InvocationOpen
            Right (Just record) ->
                maybe
                    (Left (ModeMalformedRecord (recordKeyText key)))
                    Right
                    (decodeDisposition (protectedRecordBytes record))

writeInvocationDisposition ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    InvocationDisposition ->
    IO (Either ModeError ())
writeInvocationDisposition session project run disposition =
    withRecordKey (invocationKey project run) $ \key -> do
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
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError OpenRevisionKind)
readRecordedOpenRevisionKind = readOpenRevisionKind

readOpenRevisionKind ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError OpenRevisionKind)
readOpenRevisionKind session project run =
    withRecordKey (migrationKey project run) $ \key -> do
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
data LifecycleProfile scope
    = LifecycleProfile ProjectMode Word64

instance Show (LifecycleProfile scope) where
    show (LifecycleProfile mode epoch) =
        "LifecycleProfile " <> show mode <> " " <> show epoch

lifecycleProfileMode :: LifecycleProfile scope -> ProjectMode
lifecycleProfileMode (LifecycleProfile mode _) = mode

lifecycleProfileEpoch :: LifecycleProfile scope -> Word64
lifecycleProfileEpoch (LifecycleProfile _ epoch) = epoch

{- | Open the fresh Production profile. It requires the exact Production mode
lease and the still-unbound run lease minted under the same broker generation.
-}
withProductionLifecycleProfile ::
    ProjectModeLease projectId brokerGeneration ->
    UnboundRunLease (Production projectId) brokerGeneration ->
    Either ModeError (LifecycleProfile (Production projectId))
withProductionLifecycleProfile (ProjectModeLease mode epoch) _ =
    case mode of
        ProductionMode -> Right (LifecycleProfile mode (brokerEpochWord epoch))
        HarnessMode _ -> Left (ModeWrongMode "production" (projectModeName mode))

{- | Open the fresh Harness profile for one run. A 'TestComponent' is given only
this opener, so there is no route from harness code to a Production profile.
-}
withHarnessLifecycleProfile ::
    ProjectModeLease projectId brokerGeneration ->
    UnboundRunLease (Harness projectId runId) brokerGeneration ->
    Either ModeError (LifecycleProfile (Harness projectId runId))
withHarnessLifecycleProfile (ProjectModeLease mode epoch) unbound =
    case mode of
        HarnessMode run
            | run == unboundRunLeaseRun unbound ->
                Right (LifecycleProfile mode (brokerEpochWord epoch))
            | otherwise ->
                Left
                    ( ModeWrongMode
                        ("harness:" <> runIdText (unboundRunLeaseRun unbound))
                        (projectModeName mode)
                    )
        ProductionMode -> Left (ModeWrongMode "harness" (projectModeName mode))

{- | The recovered Production profile — the /only/ exception to fresh plan
construction (§ Y).

A configful abandoned Production @up@ must be able to rebuild the same plan it
left behind, and nothing else. So this profile is a distinct type from
'LifecycleProfile': it is indexed by the exact spec and plan digests and by the
local @planId@ its rebuild is fixed to, and there is no function from it to a
fresh profile, to Harness scope, or to teardown authority. A caller holding one
can reconstruct that same @planId@\/spec\/digest, or open the separately typed
migration builder, and nothing more.
-}
data RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration
    = RecoveredProductionLifecycleProfile RunId Word64 Text Text Word64

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
    show (RecoveredProductionLifecycleProfile run revision spec plan epoch) =
        "RecoveredProductionLifecycleProfile "
            <> show run
            <> " "
            <> show revision
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch

recoveredProductionProfileRun ::
    RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration ->
    RunId
recoveredProductionProfileRun (RecoveredProductionLifecycleProfile run _ _ _ _) = run

recoveredProductionProfileSpecDigest ::
    RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfileSpecDigest (RecoveredProductionLifecycleProfile _ _ spec _ _) = spec

recoveredProductionProfilePlanDigest ::
    RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration ->
    Text
recoveredProductionProfilePlanDigest (RecoveredProductionLifecycleProfile _ _ _ plan _) = plan

recoveredProductionProfileEpoch ::
    RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration ->
    Word64
recoveredProductionProfileEpoch (RecoveredProductionLifecycleProfile _ _ _ _ epoch) = epoch

{- | The separate protected bound-recovery opener.

Every one of its inputs is load-bearing, and none is substitutable:

* the root must be the exact Production @ProjectUp@ authority — a @down@ or
  @destroy@ root cannot rebuild a plan;
* the mode lease must currently hold Production, under the same broker
  generation as the root and the bound lease;
* the bound lease and the verified snapshot must agree on both digests, which
  they do by construction because 'bindRunLease' consumed that same snapshot;
* the recovery evidence must be the Open revision branch. A terminal
  acknowledgment is *not* recoverable into a profile — its only continuation is
  resuming the stable close key — so passing one is refused here rather than
  quietly rebuilding a plan for an invocation that already finished.

The rank-2 continuation binds a fresh local @planId@: recovery reconstructs the
same plan /identity/ under a new in-process handle, because generative handles
are never serialized (§ EE).
-}
withRecoveredProductionLifecycleProfile ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot projectId specDigest planDigest ->
    OpenRevisionRecovery projectId ->
    ( forall planId.
      RecoveredProductionLifecycleProfile
        projectId
        specDigest
        planDigest
        planId
        brokerGeneration ->
      result
    ) ->
    Either ModeError result
withRecoveredProductionLifecycleProfile root modeLease bound snapshot open use
    | ProductionMode /= projectModeLeaseMode modeLease =
        Left
            ( ModeWrongMode
                "production"
                (projectModeName (projectModeLeaseMode modeLease))
            )
    | brokerEpochWord (rootAuthorityEpoch root)
        /= brokerEpochWord (projectModeLeaseEpoch modeLease) =
        Left
            ( ModeEpochMismatch
                (brokerEpochWord (projectModeLeaseEpoch modeLease))
                (brokerEpochWord (rootAuthorityEpoch root))
            )
    | boundRunLeaseRun bound /= planSnapshotRun snapshot =
        Left
            ( ModeSnapshotMismatch
                (runIdText (boundRunLeaseRun bound))
                (runIdText (planSnapshotRun snapshot))
            )
    | boundRunLeaseRun bound /= openRevisionRecoveryRun open =
        Left
            ( ModeSnapshotMismatch
                (runIdText (boundRunLeaseRun bound))
                (runIdText (openRevisionRecoveryRun open))
            )
    | otherwise =
        Right
            ( use
                ( RecoveredProductionLifecycleProfile
                    (boundRunLeaseRun bound)
                    (planSnapshotRevision snapshot)
                    (planSnapshotSpecDigest snapshot)
                    (planSnapshotPlanDigest snapshot)
                    (brokerEpochWord (rootAuthorityEpoch root))
                )
            )

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
    = ProjectUpMigrationProfile RunId Text Text Word64

instance
    Show
        (ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration)
    where
    show (ProjectUpMigrationProfile run spec plan epoch) =
        "ProjectUpMigrationProfile "
            <> show run
            <> " "
            <> show spec
            <> " "
            <> show plan
            <> " "
            <> show epoch

migrationProfileRun ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> RunId
migrationProfileRun (ProjectUpMigrationProfile run _ _ _) = run

migrationProfileOldSpecDigest ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Text
migrationProfileOldSpecDigest (ProjectUpMigrationProfile _ spec _ _) = spec

migrationProfileOldPlanDigest ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Text
migrationProfileOldPlanDigest (ProjectUpMigrationProfile _ _ plan _) = plan

migrationProfileEpoch ::
    ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration -> Word64
migrationProfileEpoch (ProjectUpMigrationProfile _ _ _ epoch) = epoch

-- | Mint the migration profile, or refuse. See 'ProjectUpMigrationProfile'.
withProjectUpMigrationProfile ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId brokerGeneration ->
    BoundRunLease (Production projectId) oldSpecDigest oldPlanDigest brokerGeneration ->
    VerifiedPlanSnapshot projectId oldSpecDigest oldPlanDigest ->
    NormalActiveRecovery (Production projectId) ->
    Either
        ModeError
        (ProjectUpMigrationProfile projectId oldSpecDigest oldPlanDigest brokerGeneration)
withProjectUpMigrationProfile root modeLease bound snapshot active
    | ProductionMode /= projectModeLeaseMode modeLease =
        Left
            ( ModeWrongMode
                "production"
                (projectModeName (projectModeLeaseMode modeLease))
            )
    | brokerEpochWord (rootAuthorityEpoch root)
        /= brokerEpochWord (projectModeLeaseEpoch modeLease) =
        Left
            ( ModeEpochMismatch
                (brokerEpochWord (projectModeLeaseEpoch modeLease))
                (brokerEpochWord (rootAuthorityEpoch root))
            )
    | boundRunLeaseRun bound /= planSnapshotRun snapshot =
        Left
            ( ModeSnapshotMismatch
                (runIdText (boundRunLeaseRun bound))
                (runIdText (planSnapshotRun snapshot))
            )
    | boundRunLeaseRun bound /= normalActiveRecoveryRun active =
        Left
            ( ModeSnapshotMismatch
                (runIdText (boundRunLeaseRun bound))
                (runIdText (normalActiveRecoveryRun active))
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
                (boundRunLeaseRun bound)
                (planSnapshotSpecDigest snapshot)
                (planSnapshotPlanDigest snapshot)
                (brokerEpochWord (rootAuthorityEpoch root))
            )

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
    InstalledProject projectId ->
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
withProspectiveMigrationPlan session project profile newSpec newPlan use
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
  where
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
        ( runIdText (migrationProfileRun profile)
            <> "."
            <> migrationProfileOldPlanDigest profile
            <> "."
            <> newPlan
        )

readProspectiveSnapshot ::
    ProtectedSession session ->
    InstalledProject projectId ->
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
    = FrozenMigrationRunLease RunId StableMigrationKey Text Text Text Text Word64

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
    show (FrozenMigrationRunLease run key oldSpec oldPlan newSpec newPlan epoch) =
        "FrozenMigrationRunLease "
            <> show run
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
frozenMigrationKey (FrozenMigrationRunLease _ key _ _ _ _ _) = key

frozenMigrationRun ::
    FrozenMigrationRunLease
        projectId
        oldSpecDigest
        oldPlanDigest
        newSpecDigest
        newPlanDigest
        brokerGeneration ->
    RunId
frozenMigrationRun (FrozenMigrationRunLease run _ _ _ _ _ _) = run

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
    InstalledProject projectId ->
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
withPlanMigration session project profile candidate = do
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
                    recordOpenRevisionMigration
                        session
                        project
                        run
                        (IncompleteMigration (stableMigrationKeyText key))
                case recorded of
                    Left failure -> pure (Left failure)
                    Right () -> freezeLease session project profile key spec plan
  where
    key = prospectiveSnapshotKey candidate
    run = migrationProfileRun profile

freezeLease ::
    ProtectedSession session ->
    InstalledProject projectId ->
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
freezeLease session project profile key newSpec newPlan =
    withRecordKey (leaseKey project run) $ \recordKey -> do
        observed <- readProtectedRecord session recordKey
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeLeaseMissing (runIdText run)))
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
                                        key
                                        recordedSpec
                                        recordedPlan
                                        newSpec
                                        newPlan
                                        (migrationProfileEpoch profile)
                                    )
                Just other ->
                    pure (Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other)))
  where
    run = migrationProfileRun profile

{- | The activation barrier: proof that the lineage switch committed.

It is indexed by /both/ plan digests, so a barrier minted for one migration
cannot authorize another's activation. Its constructor is private and
'commitMigrationActivation' is its sole producer.
-}
data PlanMigrationBarrier projectId oldPlanDigest newPlanDigest
    = PlanMigrationBarrier StableMigrationKey RunId Text Text

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
    InstalledProject projectId ->
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
    withRecordKey (leaseKey project run) $ \recordKey -> do
        observed <- readProtectedRecord session recordKey
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeLeaseMissing (runIdText run)))
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
                            Right _ -> complete oldPlan newSpec newPlan
                -- The swap already committed and the record write did not: the
                -- lease is bound to the candidate, so finish the record rather
                -- than refusing a migration that is in fact activated.
                Just (LeaseBound _ recordedSpec recordedPlan)
                    | (recordedSpec, recordedPlan) == candidateDigests ->
                        complete oldPlanOf recordedSpec recordedPlan
                Just other ->
                    pure (Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other)))
  where
    FrozenMigrationRunLease _ key _oldSpecOf oldPlanOf newSpecOf newPlanOf _ = frozen
    run = frozenMigrationRun frozen
    candidateDigests = (newSpecOf, newPlanOf)

    complete oldPlan newSpec newPlan = do
        recorded <-
            recordOpenRevisionMigration
                session
                project
                run
                (CompletedMigration (stableMigrationKeyText key))
        pure $ case recorded of
            Left failure -> Left failure
            Right () ->
                Right
                    ( BoundRunLease run newSpec newPlan epoch
                    , PlanMigrationBarrier key run oldPlan newPlan
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
activateMigratedPlan session barrier bound epoch
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
    InstalledProject projectId ->
    RunId ->
    ( forall oldPlanDigest.
      PlanMigrationBarrier projectId oldPlanDigest newPlanDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withCompletedMigrationRecovery session project run use = do
    kind <- readOpenRevisionKind session project run
    case kind of
        Left failure -> pure (Left failure)
        Right (CompletedMigration key) -> withRecordKey (leaseKey project run) $ \recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (ModeStoreFailure failure))
                Right Nothing -> pure (Left (ModeLeaseMissing (runIdText run)))
                Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                    Nothing -> pure (Left (ModeMalformedRecord (recordKeyText recordKey)))
                    -- The lease is bound to the candidate, so the old plan
                    -- digest is recovered from the stable key rather than from
                    -- any config.
                    Just (LeaseBound _ _ recordedPlan) ->
                        case oldPlanFromStableKey key of
                            Nothing -> pure (Left (ModeMalformedRecord key))
                            Just oldPlan ->
                                use
                                    ( PlanMigrationBarrier
                                        (StableMigrationKey key)
                                        run
                                        oldPlan
                                        recordedPlan
                                    )
                    Just other ->
                        pure (Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other)))
        Right other ->
            pure
                ( Left
                    ( ModeWrongRecoveryScope
                        "completed-migration"
                        (openRevisionKindName other)
                    )
                )

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

prospectiveKey :: InstalledProject projectId -> StableMigrationKey -> Either ModeError RecordKey
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
    , productionRootModeLease :: ProjectModeLease projectId brokerGeneration
    , productionRootUnboundLease :: UnboundRunLease (Production projectId) brokerGeneration
    }

{- | The composite Production root bracket: it runs the the operator-root-and-command-authority phase verifier
*inside* the protected mode transaction, so no intermediate state is exposed and
a Harness opener cannot interleave.

Production mode is acquired if absent and **retained** if already held by this
project — that is what makes @down@ keep the exclusion — and it is refused when a
harness run holds the mode.
-}
withProductionRoot ::
    ProtectedStore ->
    InstalledProject projectId ->
    ProjectVerb verb ->
    ( forall brokerGeneration.
      ProductionRoot projectId brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withProductionRoot store project verb use = do
    -- The transaction runs under the exclusive entry and then releases it: the
    -- entry protects the mode/lease decision, not the whole lifecycle run.
    prepared <-
        runProtected store $ \session -> do
            operator <- verifyOperatorAuthorization session
            case operator of
                Left failure -> pure (Left (ModeAuthorityFailure failure))
                Right authorized ->
                    withFreshEpoch session project $ \epoch ->
                        withVerifiedRoot session project authorized epoch verb $ \root -> do
                            acquired <- acquireMode session project ProductionMode epoch
                            case acquired of
                                Left failure -> pure (Left failure)
                                Right modeLease -> do
                                    recorded <- recordUnboundLease session project productionRunId epoch
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
productionRunId :: RunId
productionRunId = RunId "production"

{- | Is this the reserved Production invocation lease rather than a harness run?

'freshRunId' only ever mints @run-\<hex\>@, so the reserved name cannot collide
with a generated run identity, and the distinction is structural rather than a
naming convention two call sites could disagree about.
-}
isProductionRun :: RunId -> Bool
isProductionRun = (== productionRunId)

-- | Everything the Harness bracket established for one fresh run.
data HarnessRoot projectId runId brokerGeneration verb = HarnessRoot
    { harnessRootAuthority ::
        RootInvocationAuthority (Harness projectId runId) brokerGeneration verb
    , harnessRootHarnessAuthority :: HarnessAuthority projectId runId
    , harnessRootRunId :: RunId
    , harnessRootModeLease :: ProjectModeLease projectId brokerGeneration
    , harnessRootUnboundLease ::
        UnboundRunLease (Harness projectId runId) brokerGeneration
    }

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
    InstalledProject projectId ->
    ProjectVerb verb ->
    HarnessPreconditions ->
    ClosedAbandonedHarnessRuns projectId ->
    ( forall runId brokerGeneration.
      HarnessRoot projectId runId brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withHarnessRoot store project verb preconditions swept use = do
    prepared <-
        runProtected store $ \session -> do
            operator <- verifyOperatorAuthorization session
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
                                    run <- freshRunId
                                    withFreshEpoch session project $ \epoch ->
                                        withVerifiedRoot session project authorized epoch verb $ \root -> do
                                            acquired <- acquireMode session project (HarnessMode run) epoch
                                            case acquired of
                                                Left failure -> pure (Left failure)
                                                Right modeLease -> do
                                                    recorded <- recordUnboundLease session project run epoch
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
    InstalledProject projectId ->
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

instance Show (ProjectClosureEvidence scope) where
    show (ProjectClosureEvidence kind) = "ProjectClosureEvidence " <> show kind

projectClosureEvidenceKind :: ProjectClosureEvidence scope -> ProductionCloseKind
projectClosureEvidenceKind (ProjectClosureEvidence kind) = kind

{- | The true-pre-effect verifier: the run's records must contain no effect of
any shape. A single effect-shaped record refuses, so partial @up@/@down@ work
cannot be relabelled as a refusal that preceded acquisition.
-}
verifyNoProjectResourcesAcquired ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError (ProjectClosureEvidence scope))
verifyNoProjectResourcesAcquired session project run = do
    effects <- effectRecordsFor session project run
    pure $ case effects of
        Left failure -> Left failure
        Right [] -> Right (ProjectClosureEvidence PreEffectRefusalClose)
        Right (record : _) -> Left (ModeEffectsRecorded (recordKeyText record))

{- | The settled-destroy half of 'ProjectClosureEvidence' (the recursive-lifecycle-command phase).

'verifyNoProjectResourcesAcquired' has always been the only producer, which
meant the @SettledDestroyClose@ branch had none: a Production project could be
closed after a true pre-effect refusal but never after an actual @destroy@.
This is that missing producer, and it is deliberately not a verifier of its own
— it is a **conversion**, and it accepts only proofs the two owning modules
already minted:

* @HostBootstrap.Teardown.verifyDestroySettled@ proves the plan-derived destroy
  forest completed with every node settled and no failure;
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

{- | Exact-version proof that an unbound lease recorded no effect. The sweep
cannot close an unbound lease without it.
-}
data VerifiedUnboundLeaseHasNoEffects projectId
    = VerifiedUnboundLeaseHasNoEffects RunId

instance Show (VerifiedUnboundLeaseHasNoEffects projectId) where
    show (VerifiedUnboundLeaseHasNoEffects run) =
        "VerifiedUnboundLeaseHasNoEffects " <> show run

verifyUnboundLeaseHasNoEffects ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError (VerifiedUnboundLeaseHasNoEffects projectId))
verifyUnboundLeaseHasNoEffects session project run = do
    effects <- effectRecordsFor session project run
    pure $ case effects of
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
    InstalledProject projectId ->
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
        closed <- closeLease session project productionRunId
        case closed of
            Left failure -> pure (Left failure)
            Right () -> releaseMode session project ProductionMode

-- Production invocation close ------------------------------------------------------

{- | Proof that one ordinary Production @up@\/@down@ invocation finished: every
session for the plan was observed Closed at one store version.

This is *not* project closure. It ends an invocation while the project keeps its
mode, its resources, and its Open journal — which is exactly what makes
@down@ retain Production mode (§ Y). Only `ProjectDestroy` or a verified
true-pre-effect refusal can release the mode, and neither goes through here.
-}
data ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration
    = ProductionInvocationCompleted RunId Int

instance Show (ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration) where
    show (ProductionInvocationCompleted run sessions) =
        "ProductionInvocationCompleted " <> show run <> " " <> show sessions

productionInvocationCompletedRun ::
    ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration -> RunId
productionInvocationCompletedRun (ProductionInvocationCompleted run _) = run

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
                (boundRunLeaseRun bound)
                (allSessionsClosedCount closed)
            )

{- | Proof that the invocation\'s lease is closed while the project remains open.
Deliberately carries no lease, admission, or permit: this value authorizes
nothing further.
-}
data ProductionInvocationClosed projectId specDigest planDigest brokerGeneration
    = ProductionInvocationClosed RunId

instance Show (ProductionInvocationClosed projectId specDigest planDigest brokerGeneration) where
    show (ProductionInvocationClosed run) = "ProductionInvocationClosed " <> show run

productionInvocationClosedRun ::
    ProductionInvocationClosed projectId specDigest planDigest brokerGeneration -> RunId
productionInvocationClosedRun (ProductionInvocationClosed run) = run

{- | The outcome of the close transaction. An uncertain acknowledgment is its own
constructor, not an error: the close may in fact have committed, so the only
sound continuation is to resume the same stable key rather than retry blindly.
-}
data ProductionInvocationClose projectId specDigest planDigest brokerGeneration
    = ProductionInvocationCloseCommitted
        (ProductionInvocationClosed projectId specDigest planDigest brokerGeneration)
    | ProductionInvocationCloseUnknown InvocationCloseKey
    deriving (Show)

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
    InstalledProject projectId ->
    ProjectModeLease projectId brokerGeneration ->
    ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration ->
    InvocationCloseKey ->
    IO
        ( Either
            ModeError
            (ProductionInvocationClose projectId specDigest planDigest brokerGeneration)
        )
closeCompletedProductionInvocation session project modeLease completed key
    | ProductionMode /= projectModeLeaseMode modeLease =
        pure
            ( Left
                ( ModeWrongMode
                    "production"
                    (projectModeName (projectModeLeaseMode modeLease))
                )
            )
    | otherwise = do
        held <- currentMode session project
        case held of
            Left failure -> pure (Left failure)
            Right (Just ProductionMode) -> do
                acknowledged <-
                    recordProductionInvocationAcknowledgment session project run key
                case acknowledged of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        closed <- closeLease session project run
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
                            (maybe "none" projectModeName observed)
                            "production"
                        )
                    )
  where
    run = productionInvocationCompletedRun completed

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
    = HarnessCloseRoot HarnessCloseOrigin RunId Text (BrokerEpoch brokerGeneration)

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

harnessCloseRootRun :: HarnessCloseRoot projectId runId brokerGeneration -> RunId
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
    = HarnessCloseAuthorization HarnessCloseOrigin RunId Word64

instance Show (HarnessCloseAuthorization projectId runId) where
    show (HarnessCloseAuthorization origin run epoch) =
        "HarnessCloseAuthorization " <> show origin <> " " <> show run <> " " <> show epoch

harnessCloseRun :: HarnessCloseAuthorization projectId runId -> RunId
harnessCloseRun (HarnessCloseAuthorization _ run _) = run

harnessCloseEpoch :: HarnessCloseAuthorization projectId runId -> Word64
harnessCloseEpoch (HarnessCloseAuthorization _ _ epoch) = epoch

-- | Which way the close that this authorization ends was reached.
harnessCloseOrigin :: HarnessCloseAuthorization projectId runId -> HarnessCloseOrigin
harnessCloseOrigin (HarnessCloseAuthorization origin _ _) = origin

{- | Authorize terminal close for one harness run.

It requires the close root — the live run\'s or recovery\'s, and nothing a caller
can build — the exact Harness mode lease for this run, the bound lease, and the
complete-session proof; it then persists the Closing epoch so a crash here
resumes this close rather than reopening the run (bound recovery reaches
'HarnessPersistedClosing'). Moving the project journal itself to @ClosingProject@
is "HostBootstrap.Lifecycle.Session"\'s 'Session.beginClosingProject', which
contends on the same version session-opening advances.

The close root is checked against the bound lease and the mode lease rather than
trusted: the shared @runId@ and @brokerGeneration@ indices already rule out most
substitutions, but a root and a lease can still be minted for two /different/
projects under the same indices, and the epochs can disagree when a caller
retains a root across a generation boundary.
-}
authorizeHarnessClose ::
    ProtectedSession session ->
    InstalledProject projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId brokerGeneration ->
    BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration ->
    VerifiedAllSessionsClosed (Harness projectId runId) planId ->
    -- | the fresh closing epoch; must be positive
    Word64 ->
    IO (Either ModeError (HarnessCloseAuthorization projectId runId))
authorizeHarnessClose session project closeRoot modeLease bound closed epoch
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
            | otherwise -> do
                recorded <- recordHarnessClosingEpoch session project run epoch
                pure
                    ( fmap
                        (const (HarnessCloseAuthorization origin run epoch))
                        recorded
                    )
  where
    run = boundRunLeaseRun bound
    origin = harnessCloseRootOrigin closeRoot

{- | The checks shared by every consumer of a 'HarnessCloseRoot': the root must
name this project, this exact run, and the same broker generation the held mode
lease does, and the mode must actually be this run\'s Harness mode.
-}
checkHarnessCloseRoot ::
    InstalledProject projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId brokerGeneration ->
    RunId ->
    Either ModeError ()
checkHarnessCloseRoot project (HarnessCloseRoot _ rootRun rootProject rootEpoch) modeLease run
    | rootProject /= installedProjectName project =
        Left (ModeClosureMismatch (installedProjectName project) rootProject)
    | rootRun /= run =
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
    | otherwise = case projectModeLeaseMode modeLease of
        ProductionMode ->
            Left (ModeWrongMode ("harness:" <> runIdText run) "production")
        HarnessMode active
            | active /= run ->
                Left
                    ( ModeWrongMode
                        ("harness:" <> runIdText run)
                        ("harness:" <> runIdText active)
                    )
            | otherwise -> Right ()

{- | Resume a close that was already authorized and never finished.

'authorizeHarnessClose' persists the Closing epoch **before** the terminal
projection runs, exactly so a crash between the two is resumable rather than
indistinguishable from a live run. This is that resumption, and it is the only
route to a 'HarnessCloseAuthorization' that does not persist a new epoch.

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
    InstalledProject projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId brokerGeneration ->
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
            recorded <- readInvocationDisposition session project run
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
    run = boundRunLeaseRun bound
    origin = harnessCloseRootOrigin closeRoot

{- | Proof that a harness run reached terminal @ClosedProject@ and gave its mode
back.
-}
data ClosedHarnessProject projectId runId = ClosedHarnessProject RunId

instance Show (ClosedHarnessProject projectId runId) where
    show (ClosedHarnessProject run) = "ClosedHarnessProject " <> show run

closedHarnessProjectRun :: ClosedHarnessProject projectId runId -> RunId
closedHarnessProjectRun (ClosedHarnessProject run) = run

{- | The terminal finalizer: close the run\'s lease, then release the exact
Harness mode epoch **last**.

Mode is never released before the lease, so a crash between the two leaves the
mode held and the run recoverable rather than the mode cleared with work
outstanding (§ Y).
-}
finalizeHarnessClose ::
    ProtectedSession session ->
    InstalledProject projectId ->
    HarnessCloseAuthorization projectId runId ->
    IO (Either ModeError (ClosedHarnessProject projectId runId))
finalizeHarnessClose session project authorization = do
    closed <- closeLease session project run
    case closed of
        Left failure -> pure (Left failure)
        Right () -> do
            released <- releaseMode session project (HarnessMode run)
            pure (fmap (const (ClosedHarnessProject run)) released)
  where
    run = harnessCloseRun authorization

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
    InstalledProject projectId ->
    HarnessCloseRoot projectId runId brokerGeneration ->
    ProjectModeLease projectId brokerGeneration ->
    ProjectClosureEvidence (Harness projectId runId) ->
    IO (Either ModeError ())
closeHarnessRun session project closeRoot modeLease evidence =
    case checkHarnessCloseRoot project closeRoot modeLease run of
        Left failure -> pure (Left failure)
        Right () -> case projectClosureEvidenceKind evidence of
            SettledDestroyClose ->
                pure (Left (ModeClosureMismatch "pre-effect refusal" "settled destroy"))
            PreEffectRefusalClose -> do
                closed <- closeLease session project run
                case closed of
                    Left failure -> pure (Left failure)
                    Right () -> releaseMode session project (HarnessMode run)
  where
    run = harnessCloseRootRun closeRoot

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
    = VerifiedIncompleteRunLease RunId IncompleteLeaseKind

instance Show (VerifiedIncompleteRunLease projectId) where
    show (VerifiedIncompleteRunLease run kind) =
        "VerifiedIncompleteRunLease " <> show run <> " " <> show kind

incompleteRunLeaseRun :: VerifiedIncompleteRunLease projectId -> RunId
incompleteRunLeaseRun (VerifiedIncompleteRunLease run _) = run

incompleteRunLeaseKind :: VerifiedIncompleteRunLease projectId -> IncompleteLeaseKind
incompleteRunLeaseKind (VerifiedIncompleteRunLease _ kind) = kind

{- | Proof that the sweep observed an empty incomplete-lease set. 'withHarnessRoot'
consumes it and re-verifies emptiness inside its own entry, so racing the sweep
cannot bypass unresolved ownership.
-}
data ClosedAbandonedHarnessRuns projectId
    = ClosedAbandonedHarnessRuns Int

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
    InstalledProject projectId ->
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
                                        (runIdText (incompleteRunLeaseRun unresolved))
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
                        verifyUnboundLeaseHasNoEffects session project (incompleteRunLeaseRun lease)
                    case proof of
                        Left failure -> pure (Left failure)
                        Right _ -> do
                            closed <- closeLease session project (incompleteRunLeaseRun lease)
                            case closed of
                                Left failure -> pure (Left failure)
                                Right () -> releaseModeIfRun session project (incompleteRunLeaseRun lease)
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
    { abandonedHarnessRunId :: RunId
    -- ^ the abandoned run this reopening belongs to
    , abandonedHarnessSnapshot :: VerifiedPlanSnapshot projectId specDigest planDigest
    -- ^ the exact plan snapshot the old lease was bound to, read back durably
    , abandonedHarnessBoundLease ::
        BoundRunLease (Harness projectId oldRunId) specDigest planDigest brokerGeneration
    -- ^ the /already-bound/ lease, retained on the fresh broker generation
    , abandonedHarnessModeLease :: ProjectModeLease projectId brokerGeneration
    -- ^ the old run's own project-wide Harness mode, likewise retained
    , abandonedHarnessDestroyRoot ::
        RootInvocationAuthority (Harness projectId oldRunId) brokerGeneration VerbDestroy
    -- ^ recovery's only root authority: @destroy@, so it can release and not acquire
    , abandonedHarnessRecovery :: HarnessBoundRecovery projectId
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
    InstalledProject projectId ->
    -- | the bound lease the sweep minted; an unbound one is refused
    VerifiedIncompleteRunLease projectId ->
    ( forall oldRunId specDigest planDigest planId brokerGeneration.
      AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withAbandonedHarnessRun store project lease use = case incompleteRunLeaseKind lease of
    IncompleteUnbound ->
        -- An unbound lease has no snapshot, so there is nothing to reopen: the
        -- sweep closes it behind 'verifyUnboundLeaseHasNoEffects' instead.
        pure (Left (ModeLeaseNotBindable (runIdText run) "unbound"))
    IncompleteBound recordedSpec recordedPlan -> do
        prepared <- runProtected store (reopen recordedSpec recordedPlan)
        case prepared of
            Left failure -> pure (Left failure)
            Right (SomeAbandonedHarnessRun reopened) -> use reopened
  where
    run = incompleteRunLeaseRun lease

    reopen ::
        Text ->
        Text ->
        ProtectedSession session ->
        IO (Either ModeError (SomeAbandonedHarnessRun projectId))
    reopen recordedSpec recordedPlan session = do
        stillBound <- leaseStillBoundTo session project run recordedSpec recordedPlan
        case stillBound of
            Left failure -> pure (Left failure)
            Right () -> do
                classified <- classifyAbandonedBoundRun session project lease
                case classified of
                    Left failure -> pure (Left failure)
                    Right recovery ->
                        verifyPlanSnapshot session project run $ \snapshot ->
                            case checkSnapshotDigests recovery snapshot recordedSpec recordedPlan of
                                Left failure -> pure (Left failure)
                                Right () -> do
                                    operator <- verifyOperatorAuthorization session
                                    case operator of
                                        Left failure -> pure (Left (ModeAuthorityFailure failure))
                                        Right authorized ->
                                            withFreshEpoch session project $ \epoch ->
                                                withVerifiedRoot
                                                    session
                                                    project
                                                    authorized
                                                    epoch
                                                    ProjectDestroy
                                                    ( retain
                                                        session
                                                        snapshot
                                                        (recordedSpec, recordedPlan)
                                                        recovery
                                                        epoch
                                                    )

    retain ::
        ProtectedSession session ->
        VerifiedPlanSnapshot projectId specDigest planDigest ->
        (Text, Text) ->
        HarnessBoundRecovery projectId ->
        BrokerEpoch brokerGeneration ->
        RootInvocationAuthority (Harness projectId oldRunId) brokerGeneration VerbDestroy ->
        IO (Either ModeError (SomeAbandonedHarnessRun projectId))
    retain session snapshot recordedDigests recovery epoch root = do
        retained <- retainAbandonedHarnessMode session project run epoch
        case retained of
            Left failure -> pure (Left failure)
            Right modeLease -> do
                rebound <-
                    retainBoundLeaseGeneration session project snapshot recordedDigests epoch
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
        VerifiedPlanSnapshot projectId specDigest planDigest ->
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
        HarnessBoundRecovery projectId ->
        VerifiedPlanSnapshot projectId specDigest planDigest ->
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
    InstalledProject projectId ->
    RunId ->
    Text ->
    Text ->
    IO (Either ModeError ())
leaseStillBoundTo session project run expectedSpec expectedPlan =
    withRecordKey (leaseKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (ModeStoreFailure failure)
            Right Nothing -> Left (ModeLeaseMissing (runIdText run))
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> Left (ModeMalformedRecord (recordKeyText key))
                Just (LeaseBound _ spec plan)
                    | spec /= expectedSpec -> Left (ModeSnapshotMismatch expectedSpec spec)
                    | plan /= expectedPlan -> Left (ModeSnapshotMismatch expectedPlan plan)
                    | otherwise -> Right ()
                Just other ->
                    Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other))

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
    InstalledProject projectId ->
    RunId ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (ProjectModeLease projectId brokerGeneration))
retainAbandonedHarnessMode session project run epoch =
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeHeldByAnother "none" wanted))
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (held, _)
                    | held /= HarnessMode run ->
                        pure (Left (ModeHeldByAnother (projectModeName held) wanted))
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeMode held (brokerEpochWord epoch))
                        pure $ case written of
                            Left failure -> Left (ModeStoreFailure failure)
                            Right _ -> Right (ProjectModeLease held epoch)
  where
    wanted = projectModeName (HarnessMode run)

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
    ProtectedSession session ->
    InstalledProject projectId ->
    VerifiedPlanSnapshot projectId specDigest planDigest ->
    -- | the digests the lease record must currently hold
    (Text, Text) ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (BoundRunLease scope specDigest planDigest brokerGeneration))
retainBoundLeaseGeneration session project snapshot (spec, plan) epoch =
    withRecordKey (leaseKey project run) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> pure (Left (ModeLeaseMissing (runIdText run)))
            Right (Just record) -> case decodeLease (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (LeaseBound _ recordedSpec recordedPlan)
                    | recordedSpec /= spec -> pure (Left (ModeSnapshotMismatch spec recordedSpec))
                    | recordedPlan /= plan -> pure (Left (ModeSnapshotMismatch plan recordedPlan))
                    | otherwise -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeLease (LeaseBound (brokerEpochWord epoch) spec plan))
                        pure $ case written of
                            Left failure -> Left (ModeStoreFailure failure)
                            Right _ -> Right (BoundRunLease run spec plan epoch)
                Just other ->
                    pure (Left (ModeLeaseNotBindable (runIdText run) (leaseStateName other)))
  where
    run = planSnapshotRun snapshot

{- | Release the project-wide mode when it is held by this exact abandoned run.
A Production mode, or another run's mode, is left untouched.
-}
releaseModeIfRun ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError ())
releaseModeIfRun session project run = do
    held <- currentMode session project
    case held of
        Left failure -> pure (Left failure)
        Right (Just (HarnessMode active)) | active == run -> releaseMode session project (HarnessMode run)
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
    ["bound", epoch, spec, plan] -> (\value -> LeaseBound value spec plan) <$> readWord epoch
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
decodeDisposition raw = case decodeFields raw of
    ["open"] -> Just InvocationOpen
    ["ack", key] | not (Text.null key) -> Just (InvocationAcknowledged (InvocationCloseKey key))
    ["closing", epoch] -> do
        value <- readWord epoch
        if value == 0 then Nothing else Just (InvocationClosing value)
    _ -> Nothing

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

encodeMode :: ProjectMode -> Word64 -> ByteString
encodeMode ProductionMode epoch = encodeFields ["production", showWord epoch]
encodeMode (HarnessMode run) epoch =
    encodeFields ["harness", showWord epoch, runIdText run]

decodeMode :: ByteString -> Maybe (ProjectMode, Word64)
decodeMode raw = case decodeFields raw of
    ["production", epoch] -> (\value -> (ProductionMode, value)) <$> readWord epoch
    ["harness", epoch, run] -> do
        value <- readWord epoch
        parsed <- either (const Nothing) Just (mkRunId run)
        pure (HarnessMode parsed, value)
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
acquireMode ::
    ProtectedSession session ->
    InstalledProject projectId ->
    ProjectMode ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (ProjectModeLease projectId brokerGeneration))
acquireMode session project requested epoch =
    withRecordKey (modeKey project) $ \key -> do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (ModeStoreFailure failure))
            Right Nothing -> take_ key ExpectAbsent
            Right (Just record) -> case decodeMode (protectedRecordBytes record) of
                Nothing -> pure (Left (ModeMalformedRecord (recordKeyText key)))
                Just (held, _)
                    | held == requested && requested == ProductionMode ->
                        take_ key (ExpectVersion (protectedRecordVersion record))
                    | otherwise ->
                        pure
                            ( Left
                                ( ModeHeldByAnother
                                    (projectModeName held)
                                    (projectModeName requested)
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
            Right _ -> Right (ProjectModeLease requested epoch)

-- | The mode currently recorded, if any.
currentMode ::
    ProtectedSession session ->
    InstalledProject projectId ->
    IO (Either ModeError (Maybe ProjectMode))
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
    InstalledProject projectId ->
    ProjectMode ->
    IO (Either ModeError ())
releaseMode session project expected =
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
                                    (projectModeName held)
                                    (projectModeName expected)
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
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    BrokerEpoch brokerGeneration ->
    IO (Either ModeError (UnboundRunLease scope brokerGeneration))
recordUnboundLease session project run epoch =
    withRecordKey (leaseKey project run) $ \key -> do
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
                        (encodeLease (LeaseUnbound (brokerEpochWord epoch)))
                pure $ case written of
                    Left failure -> Left (ModeStoreFailure failure)
                    Right _ -> Right (UnboundRunLease run epoch)

closeLease ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError ())
closeLease session project run =
    withRecordKey (leaseKey project run) $ \key -> do
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
profile's recovery ('eliminateProductionBoundRecovery',
'withRecoveredProductionLifecycleProfile', and the stable 'InvocationCloseKey').
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
    InstalledProject projectId ->
    IO (Either ModeError [VerifiedIncompleteRunLease projectId])
abandonedHarnessLeases session project =
    fmap
        (fmap (filter (not . isProductionRun . incompleteRunLeaseRun)))
        (incompleteLeases session project)

incompleteLeases ::
    ProtectedSession session ->
    InstalledProject projectId ->
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
    InstalledProject projectId ->
    ClosedAbandonedHarnessRuns projectId ->
    IO (Either ModeError ())
sweptSetStillEmpty session project _ = do
    remaining <- abandonedHarnessLeases session project
    pure $ case remaining of
        Left failure -> Left failure
        Right [] -> Right ()
        Right (unresolved : _) ->
            Left (ModeRecoveryRequired (runIdText (incompleteRunLeaseRun unresolved)))

effectRecordsFor ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RunId ->
    IO (Either ModeError [RecordKey])
effectRecordsFor session project run = do
    keys <- listProtectedRecords session
    pure $ case keys of
        Left failure -> Left (ModeStoreFailure failure)
        Right present -> Right (filter (isEffectKey project run) present)

-- Record keys ------------------------------------------------------------------------------------

modeKey :: InstalledProject projectId -> Either ModeError RecordKey
modeKey project = storeKey ("mode." <> installedProjectName project)

snapshotKey :: InstalledProject projectId -> RunId -> Either ModeError RecordKey
snapshotKey project run =
    storeKey ("snapshot." <> installedProjectName project <> "." <> runIdText run)

invocationKey :: InstalledProject projectId -> RunId -> Either ModeError RecordKey
invocationKey project run =
    storeKey ("invocation." <> installedProjectName project <> "." <> runIdText run)

migrationKey :: InstalledProject projectId -> RunId -> Either ModeError RecordKey
migrationKey project run =
    storeKey ("migration." <> installedProjectName project <> "." <> runIdText run)

leaseKey :: InstalledProject projectId -> RunId -> Either ModeError RecordKey
leaseKey project run =
    storeKey (leasePrefix project <> runIdText run)

leasePrefix :: InstalledProject projectId -> Text
leasePrefix project = "lease." <> installedProjectName project <> "."

isLeaseKey :: InstalledProject projectId -> RecordKey -> Bool
isLeaseKey project key = leasePrefix project `Text.isPrefixOf` recordKeyText key

runOfLeaseKey :: InstalledProject projectId -> RecordKey -> Maybe RunId
runOfLeaseKey project key =
    either
        (const Nothing)
        Just
        (mkRunId (Text.drop (Text.length (leasePrefix project)) (recordKeyText key)))

{- | Effect-shaped records for a run. Every durable record a lifecycle effect
writes uses this prefix, so "did this run touch anything" is a set membership
question rather than an inference.
-}
isEffectKey :: InstalledProject projectId -> RunId -> RecordKey -> Bool
isEffectKey project run key =
    ("effect." <> installedProjectName project <> "." <> runIdText run <> ".")
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
    InstalledProject projectId ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withFreshEpoch session project use = do
    outcome <- withFreshBrokerEpoch session project (fmap Right . use)
    pure (either (Left . ModeAuthorityFailure) id outcome)

withVerifiedRoot ::
    ProtectedSession session ->
    InstalledProject projectId ->
    OperatorAuthorization ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    ( RootInvocationAuthority scope brokerGeneration verb ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withVerifiedRoot session project operator epoch verb use = do
    outcome <-
        withVerifiedRootInvocation
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
    | -- | An effect-shaped record exists, so this is not a pre-effect state.
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
    | -- | A recovery record belongs to the other lifecycle scope.
      ModeWrongRecoveryScope Text Text
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
        "effect record " <> key <> " exists, so no pre-effect proof can be made"
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
    ModeWrongRecoveryScope scope observed ->
        scope <> " recovery cannot consume " <> observed
    ModeAuthorityFailure inner -> authorityErrorMessage inner
    ModeSessionFailure inner -> Text.pack (sessionErrorMessage inner)
    ModeStoreFailure inner -> protectedErrorMessage inner
