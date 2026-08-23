{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Package-private root/child lifecycle entries and fixed interpreters.

The public command facade exposes this type only abstractly.  Its sole
root constructor joins the exact root @up@ authority, plan, lifecycle context,
acquisition journal, Execute cursor, and command reservation.  Its child
constructor retains one inseparable authorized child package.  No caller can
project those retained values or substitute a raw Chain invocation.
-}
module HostBootstrap.Command.LifecycleEntry (
    LifecycleEntry,
    AuthorizedChildCursor,
    lifecycleEntryFrameName,
    lifecycleEntryVerbName,
    withRootProjectUpLifecycleEntry,
    withRootProjectReverseLifecycleEntry,
    withRootRecursiveHandoffRuntimeKernel,
    withPreparedRootReverseDescentKernel,
    withPreparedFailedUpReverseDescentKernel,
    withPreparedRootReverseFrameServiceKernel,
    withFailedUpUnwindAuthorityForEntryKernel,
    withFailedUpTeardownForestForEntryKernel,
    runPreparedRootClusterCleanupKernel,
    terminalizeRootReverseLifecycleEntryKernel,
    withReceivedRecoveryChildLifecycleEntry,
    withChildRecoveryTerminalOrigin,
    withChildProjectUpLifecycleEntry,
    runRootProjectUpLifecycleEntry,
    runRootProjectReverseLifecycleEntry,
    runChildProjectUpLifecycleEntry,
    renderForwardTerminalOrigin,
)
where

import Control.Exception (SomeException, displayException, fromException)
import Control.Exception.Safe (try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (
    CommandAuthority,
    ExecutePhase,
    InstalledProjectIdentity,
    LifecyclePhase (Execute, Prepare, Teardown),
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
    RootInvocationAuthority,
    TeardownPhase,
    VerbDestroy,
    VerbDown,
    VerbUp,
    brokerEpochWord,
    commandAuthorityEpoch,
    commandAuthorityInvocation,
    commandAuthorityPhase,
    commandAuthorityVerb,
    invocationIdText,
    lifecyclePhaseName,
    projectVerbName,
    rootAuthorityEpoch,
 )
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Authority.FailedUp.Internal (
    FailedUpUnwindAuthority,
    withFailedUpCleanupOperationsKernel,
    withFailedUpUnwindAuthorityKernel,
    withRootFailedUpUnwindAuthorityKernel,
 )
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity)
import qualified HostBootstrap.Authority.ProjectPlan as ProjectAuthority
import HostBootstrap.Authority.ProjectPlan.Internal (
    ChildRecoveryOrigin,
    childRecoveryOriginFrameNameKernel,
    childRecoveryOriginVerbNameKernel,
    withChildRecoveryTerminalOriginKernel,
 )
import HostBootstrap.Chain (
    runChainFromFrameWithDescentFailure,
 )
import HostBootstrap.Cluster.Reconcile (runExactClusterCleanupKernel)
import HostBootstrap.Config.Class (ProjectCfg)
import HostBootstrap.Config.Schema (
    ValidatedConfig,
    VerifiedConfigHandoff,
    verifiedConfigHandoffPhase,
 )
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff (
    HandoffBindingInput (..),
    HandoffOffer,
    HandoffPayloadKind (NarrowedProjectConfig, RecoveryAdapterWire),
    HandoffScope,
    ProjectSigningKey,
    RootBroker,
    childConfigDigest,
    frameWire,
    freshHandoffToken,
    handoffChildFrame,
    handoffErrorMessage,
    handoffOfferBinding,
    mkHandoffBinding,
    renderForwardFailedLifecycleReportWithObservations,
    renderHandoffBinding,
    renderHandoffBindingInput,
    renderLifecycleAcknowledgement,
    renderReverseCompletedLifecycleReport,
    renderReverseFailedLifecycleReport,
    requestedChildFrame,
    requestedParentFrame,
    rootBrokerRoute,
    takeHandoffFrame,
    withRootBroker,
 )
import HostBootstrap.Handoff.Process (
    withCarriedProviderDependencyFromCarrierKernel,
    withPreparedReverseLifecycleChildProcess,
 )
import HostBootstrap.Handoff.Process.Route (withForwardLifecycleProcessRouteKernel)
import HostBootstrap.Handoff.Receiver (ReceivedRecoveryDescent)
import HostBootstrap.Handoff.Relay (
    RelayError,
    persistRootedLifecycleCompletionKernel,
    publishRootedLifecycleReportKernel,
    relayErrorMessage,
    rootForwardBrokerLink,
    rootReverseBrokerLink,
    withRootedOpenedResponseKernel,
    withRootedPostOpenResponseKernel,
    withRootedPreparedResponseKernel,
 )
import qualified HostBootstrap.Handoff.Rooted as RootedWire
import HostBootstrap.Handoff.Runtime (
    RecursiveHandoffRuntime,
    rootRecursiveHandoffRuntimeKernel,
 )
import HostBootstrap.Handoff.TerminalReport (
    withFailedForwardRootedTerminalReportKernel,
    withForwardRootedTerminalReportKernel,
 )
import HostBootstrap.Harness (
    SafetyRefusal (SafetyRefusal),
    safetyRefusalMarker,
 )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Closure (destroyCloseRoot)
import HostBootstrap.Lifecycle.Context (
    ValidatedLifecycleContext,
    lifecycleContextErrorMessage,
    withValidatedLifecycleContext,
 )
import HostBootstrap.Lifecycle.Context.Internal (
    withValidatedRootLifecycleContext,
 )
import HostBootstrap.Lifecycle.Mode (
    AcquisitionJournal,
    BoundRunLease,
    LifecycleCursor,
    ModeError (..),
    VerifiedPlanSnapshot,
    acquisitionJournalRecordVersion,
    destroySettledClosure,
    lifecycleCursorFrame,
    lifecycleCursorRecordVersion,
    lifecycleErrorMessage,
    modeErrorMessage,
    planSnapshotProjectName,
    planSnapshotStoreIdentity,
    projectModeLeaseEpoch,
    recoveredProductionProfileEpoch,
    terminalizeExistingBoundReverseRootKernel,
    withAcquisitionJournal,
    withAcquisitionJournalPhase,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withRecoveredProductionLifecycleProfile,
    withTeardownLifecycleCursor,
 )
import HostBootstrap.Lifecycle.Plan (
    acquisitionJournalAdmissionKernel,
    existingBoundSnapshotAdmissionKernel,
    projectPlanProfileEpochKernel,
 )
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lifecycle.Rooted (
    RootedFrameSession,
    withAdvancedRootedFrameSessionKernel,
    withRootOpenedDirectFrameSessionKernel,
    withRootOpenedFrameSessionKernel,
    withRootedFrameSessionKernel,
 )
import HostBootstrap.Lifecycle.Rooted.Node (
    withPreparedRootedNodeGrantKernel,
    withSettledRootedNodeKernel,
 )
import HostBootstrap.Lifecycle.Rooted.Receipt (
    withRootedReceiptConfirmationKernel,
    withRootedTerminalReportKernel,
 )
import HostBootstrap.Lifecycle.RootedPlan (
    RootedPlanCatalog,
    rootedPlanCatalogManifestKernel,
    rootedPlanCatalogManifestMatchesKernel,
    rootedPlanCatalogRecordIdentityKernel,
    withRootedPlanCatalogEntriesContinuationKernel,
    withRootedPlanCatalogEntriesKernel,
    withRootedPlanCatalogKernel,
 )
import HostBootstrap.Lifecycle.Session (
    VerifiedAllSessionsClosed,
    sessionErrorMessage,
    verifyAllSessionsClosed,
    withReverseRootTargetLifecycleCursorKernel,
 )
import HostBootstrap.Lift (
    LiftContext (LiftContext),
    LiftLayer (ViaContainer),
    SelfRef (inVMSelfPath),
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    operationKeyText,
    plannedStepDependencyOperations,
    plannedStepFrameId,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    projectPlanProjectName,
    renderSnapshot,
    stablePlanSnapshotConfigDigest,
    stablePlanSnapshotDigest,
    stablePlanSnapshotRoot,
    stablePlanSnapshotSpecDigest,
    topology,
    topologyDescentFrom,
 )
import HostBootstrap.ProjectPlan.Child.Internal (
    AuthorizedChildCursor,
    ChildPlanAuthority,
    authorizeAuthenticatedChildCursorKernel,
    authorizedChildCursorFrameNameKernel,
    authorizedChildCursorVerbNameKernel,
    renderForwardTerminalOriginKernel,
    runAuthorizedChildCursorKernel,
    withAuthenticatedChildCursor,
    withReceivedRecoveryChildOriginKernel,
 )
import HostBootstrap.ProjectPlan.Construct (
    FinalizedProjectSpec,
    projectPlanDrafts,
    withRecoveredProductionProjectPlan,
    withRecoveredProductionProjectPlanInputs,
 )
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.ProjectPlan.Handoff.Internal (
    withCatalogForwardHandoffKernel,
    withCatalogForwardProcessInputsKernel,
 )
import HostBootstrap.ProjectPlan.Snapshot (
    BoundPlanSnapshot,
    PlanDigestBinding,
    SnapshotError (..),
    withReauthorizedBoundPlanSnapshotKernel,
 )
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    mkRecordName,
    protectedErrorMessage,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    readProtectedRecord,
    recordVersionWord,
    withProtectedEntry,
 )
import HostBootstrap.Teardown (
    DescentWork,
    LocalWork,
    PreDescentStep,
    SubtreeSettled,
    TeardownError (TeardownReverseDescentRefused),
    TeardownForest,
    TeardownOutcome (TeardownFailed, TeardownReleased),
    attemptLocalWork,
    attemptPreDescentStep,
    completedForestTerminalObservations,
    descentWorkChildFrame,
    driveTeardownForest,
    eliminateTeardownProgress,
    eliminateTeardownWork,
    failedUpTeardownPlanKernel,
    localWorkKey,
    nextTeardownWork,
    openTeardownForest,
    renderTeardownObservations,
    settleDescentWork,
    subtreeSettledTerminalObservations,
    teardownErrorMessage,
    teardownObservationsFromWire,
    teardownPlan,
    teardownPlanFrameId,
    validateRootSubtreeSettled,
    verifyDestroySettled,
    verifySubtreeSettled,
    withTeardownAuthorization,
 )
import HostBootstrap.Teardown.Internal (
    ReverseDescent,
    renderPreparedReverseTerminalOriginKernel,
    withPreparedReverseAdmissionsKernel,
    withPreparedReverseDescentKernel,
    withPreparedReverseForestKernel,
    withReverseDescentLiftContextKernel,
    withReverseDescentProcessInputsKernel,
 )

{- | The exact root lifecycle leaf consumed by the fixed @project up@
interpreter.

The specification/configuration indices remain existential inside the package;
the five identities shared with consumers are all nominal.
-}
data LifecycleEntry scope planId frame brokerGeneration verb where
    RootUpLifecycleEntry ::
        RootInvocationAuthority scope brokerGeneration VerbUp ->
        ProjectVerb VerbUp ->
        ProjectPlan scope specDigest planId configId cfg ->
        ValidatedLifecycleContext scope specDigest planId configId frame ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase ->
        CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
        RootedPlanCatalog scope planId brokerGeneration catalogId ->
        LifecycleEntry scope planId frame brokerGeneration VerbUp
    ChildUpLifecycleEntry ::
        AuthorizedChildCursor
            scope
            specDigest
            planDigest
            brokerGeneration
            parentFrame
            planId
            configId
            frame
            VerbUp
            ExecutePhase ->
        LifecycleEntry scope planId frame brokerGeneration VerbUp
    ChildRecoveryLifecycleEntry ::
        ChildRecoveryOrigin
            scope
            specDigest
            planDigest
            brokerGeneration
            parentFrame
            planId
            configId
            frame
            verb ->
        LifecycleEntry scope planId frame brokerGeneration verb
    RootDownLifecycleEntry ::
        RootInvocationAuthority scope brokerGeneration VerbDown ->
        ProjectVerb VerbDown ->
        ProjectPlan scope specDigest planId configId cfg ->
        ValidatedLifecycleContext scope specDigest planId configId frame ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId frame brokerGeneration VerbDown TeardownPhase ->
        CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase ->
        IO
            ( Either
                Authority.AuthorityError
                (CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase)
            ) ->
        RootedPlanCatalog scope planId brokerGeneration catalogId ->
        LifecycleEntry scope planId frame brokerGeneration VerbDown
    RootDestroyLifecycleEntry ::
        RootInvocationAuthority scope brokerGeneration VerbDestroy ->
        ProjectVerb VerbDestroy ->
        ProjectPlan scope specDigest planId configId cfg ->
        ValidatedLifecycleContext scope specDigest planId configId frame ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId frame brokerGeneration VerbDestroy TeardownPhase ->
        CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase ->
        IO
            ( Either
                Authority.AuthorityError
                (CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase)
            ) ->
        RootedPlanCatalog scope planId brokerGeneration catalogId ->
        LifecycleEntry scope planId frame brokerGeneration VerbDestroy

type role LifecycleEntry nominal nominal nominal nominal nominal

-- | Descriptive frame name; this grants no cursor or frame authority.
lifecycleEntryFrameName :: LifecycleEntry scope planId frame broker verb -> Text
lifecycleEntryFrameName (RootUpLifecycleEntry _ _ _ _ _ cursor _ _) =
    lifecycleCursorFrame cursor
lifecycleEntryFrameName (ChildUpLifecycleEntry authorized) =
    authorizedChildCursorFrameNameKernel authorized
lifecycleEntryFrameName (ChildRecoveryLifecycleEntry origin) =
    childRecoveryOriginFrameNameKernel origin
lifecycleEntryFrameName (RootDownLifecycleEntry _ _ _ _ _ cursor _ _ _) =
    lifecycleCursorFrame cursor
lifecycleEntryFrameName (RootDestroyLifecycleEntry _ _ _ _ _ cursor _ _ _) =
    lifecycleCursorFrame cursor

-- | Descriptive canonical project verb; this grants no command authority.
lifecycleEntryVerbName :: LifecycleEntry scope planId frame broker verb -> Text
lifecycleEntryVerbName (RootUpLifecycleEntry _ verb _ _ _ _ _ _) =
    projectVerbName verb
lifecycleEntryVerbName (ChildUpLifecycleEntry authorized) =
    authorizedChildCursorVerbNameKernel authorized
lifecycleEntryVerbName (ChildRecoveryLifecycleEntry origin) =
    childRecoveryOriginVerbNameKernel origin
lifecycleEntryVerbName (RootDownLifecycleEntry _ verb _ _ _ _ _ _ _) =
    projectVerbName verb
lifecycleEntryVerbName (RootDestroyLifecycleEntry _ verb _ _ _ _ _ _ _) =
    projectVerbName verb

{- | Admit or exactly resume one root @project up@ entry.

Root refinement happens before a journal or cursor can be opened.  Prepare is
normalized to Execute, an existing Execute row resumes at the reservation
gate, and an existing Teardown row means the exact invocation already ran and
therefore returns without a second entry.

The journal has already revalidated the live global lease, protected
snapshot, and plan digest by the time the recursive catalog is admitted, so
the catalog's own bounded canonical manifest is compare-and-swapped and
strictly re-read against that same live evidence.  Only a convergent manifest
reaches the reservation, and the exact catalog is what the entry retains.
-}
withRootProjectUpLifecycleEntry ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    ProjectVerb VerbUp ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    ProjectPlan scope specDigest planId configId cfg ->
    ValidatedLifecycleContext scope specDigest planId configId frame ->
    (LifecycleEntry scope planId frame brokerGeneration VerbUp -> IO (Either String ())) ->
    IO (Either String ())
withRootProjectUpLifecycleEntry
    finalized
    rootAuthority
    verb
    verified
    bound
    binding
    lease
    plan
    lifecycleContext
    use =
        case withValidatedRootLifecycleContext
            lifecycleContext
            ( \root store current frame _validated ->
                case validateRootBoundary
                    (canonicalProjectRootPath root)
                    (protectedStoreIdentityText (protectedStoreIdentity store)) of
                    Left failure -> pure (Left failure)
                    Right () -> openJournal store current frame
            ) of
            Left failure -> pure (Left (lifecycleContextErrorMessage failure))
            Right admitted -> admitted
      where
        validateRootBoundary observedRoot observedStore
            | observedRoot /= stablePlanSnapshotRoot (renderSnapshot plan) =
                Left "lifecycle entry: canonical root does not match the retained plan"
            | observedStore /= planSnapshotStoreIdentity verified =
                Left "lifecycle entry: protected store does not match the verified snapshot"
            | observedStore /= rootAuthorityStoreIdentity rootAuthority =
                Left "lifecycle entry: protected store does not match the root authority"
            | projectPlanProjectName plan /= planSnapshotProjectName verified =
                Left "lifecycle entry: project does not match the verified snapshot"
            | otherwise = Right ()
        openJournal store current frame = do
            opened <-
                withAcquisitionJournal
                    rootAuthority
                    lease
                    bound
                    binding
                    plan
                    ( \journal -> do
                        cursored <-
                            withCurrentLifecycleCursor journal frame verb $ \phase cursor ->
                                case phase of
                                    Authority.Prepare -> do
                                        advanced <-
                                            withExecuteLifecycleCursor
                                                cursor
                                                (mint store current journal)
                                        pure (either (Left . lifecycleErrorMessage) id advanced)
                                    Authority.Execute -> mint store current journal cursor
                                    Authority.Teardown -> pure (Right ())
                        pure (either (Left . lifecycleErrorMessage) id cursored)
                    )
            pure (either (Left . lifecycleErrorMessage) id opened)

        mint store current journal executeCursor = do
            cataloged <-
                withRootedPlanCatalogKernel
                    finalized
                    rootAuthority
                    plan
                    current
                    lifecycleContext
                    ( \catalog -> do
                        settled <- settleRootedPlanCatalog store catalog
                        case settled of
                            Left failure -> pure (Left (Text.pack failure))
                            Right () -> do
                                reserved <-
                                    ProjectAuthority.authorizeRootProject
                                        rootAuthority
                                        verb
                                        verified
                                        bound
                                        binding
                                        lease
                                        plan
                                        journal
                                        executeCursor
                                        lifecycleContext
                                case reserved of
                                    Left failure ->
                                        pure (Left (Authority.authorityErrorMessage failure))
                                    Right authority ->
                                        either (Left . Text.pack) Right
                                            <$> use
                                                ( RootUpLifecycleEntry
                                                    rootAuthority
                                                    verb
                                                    plan
                                                    lifecycleContext
                                                    journal
                                                    executeCursor
                                                    authority
                                                    catalog
                                                )
                    )
            pure (either (Left . Text.unpack) Right cataloged)

{- | Compare-and-swap and strictly re-read one recursive catalog manifest.

An absent record is written exactly once; an exact retry and a
compare-and-swap loser both converge on the record already present, because
the decision comes from the strict readback rather than from who won the
swap.  Any other durable bytes under this project, profile, and broker epoch
are a refusal, and no lifecycle effect has run when it is returned.
-}
settleRootedPlanCatalog ::
    ProtectedStore ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    IO (Either String ())
settleRootedPlanCatalog store catalog =
    case ( rootedPlanCatalogManifestKernel catalog
         , mkRecordName (rootedPlanCatalogRecordIdentityKernel catalog) >>= mkRecordKey
         ) of
        (Left failure, _) -> pure (Left ("lifecycle entry: " ++ Text.unpack failure))
        (_, Left failure) -> pure (Left (storeFailure failure))
        (Right manifest, Right key) -> do
            entered <-
                withProtectedEntry store $ \session -> do
                    settled <- settleManifest session key manifest
                    settled `seq` pure (Right settled)
            pure (either (Left . storeFailure) id entered)
  where
    storeFailure failure =
        "lifecycle entry: " ++ Text.unpack (protectedErrorMessage failure)

    settleManifest :: ProtectedSession session -> RecordKey -> ByteString.ByteString -> IO (Either String ())
    settleManifest session key manifest = do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (Left (storeFailure failure))
            Right (Just record) -> pure (verifyManifest record)
            Right Nothing -> do
                _written <- compareAndSwapProtectedRecord session key ExpectAbsent manifest
                latest <- readProtectedRecord session key
                pure $ case latest of
                    Left failure -> Left (storeFailure failure)
                    Right Nothing ->
                        Left "lifecycle entry: the recursive catalog manifest did not persist"
                    Right (Just record) -> verifyManifest record

    verifyManifest record
        | recordVersionWord (protectedRecordVersion record) /= 1 =
            Left "lifecycle entry: the durable recursive catalog manifest is not its only version"
        | otherwise =
            either
                (Left . ("lifecycle entry: " ++) . Text.unpack)
                Right
                ( rootedPlanCatalogManifestMatchesKernel
                    catalog
                    (protectedRecordBytes record)
                )

{- | Reauthorize and seal exactly one root Down or Destroy entry.

This hidden producer owns the only valid admission token for the Snapshot
facade.  Its source reconstruction is confined to the absent-only callback;
the sibling target callback rebuilds and seals authority solely from the
committed target package while the facade retains run liveness.
-}
withRootProjectReverseLifecycleEntry ::
    (ProjectCfg cfg) =>
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot (Production projectId) rootId ->
    FinalizedProjectSpec (Production projectId) candidateSpecDigest cfg ->
    ValidatedConfig
        (Production projectId)
        candidateSpecDigest
        configId
        (cfg (Production projectId)) ->
    Context.BinaryContext ->
    ProjectVerb verb ->
    ( forall targetBroker targetPlanId targetFrame.
      LifecycleEntry
        (Production projectId)
        targetPlanId
        targetFrame
        targetBroker
        verb ->
      ( SubtreeSettled
            (Production projectId)
            targetPlanId
            targetFrame
            verb ->
        IO (Either String ())
      ) ->
      IO (Either String ())
    ) ->
    IO (Either String ())
withRootProjectReverseLifecycleEntry
    store
    project
    root
    finalizedSpec
    candidateConfig
    binaryContext
    verb
    use = do
        admitted <-
            withReauthorizedBoundPlanSnapshotKernel
                existingBoundSnapshotAdmissionKernel
                store
                project
                verb
                ( \sourceRoot sourceMode sourceLease sourceVerified sourceBound sourceBinding sourceRecovery continue ->
                    either
                        (pure . Left . SnapshotVerificationError)
                        id
                        ( withRecoveredProductionLifecycleProfile
                            sourceRoot
                            sourceMode
                            sourceLease
                            sourceVerified
                            sourceBound
                            sourceBinding
                            sourceRecovery
                            ( \sourceProfile ->
                                either
                                    sourcePlanFailure
                                    id
                                    ( withRecoveredProductionProjectPlanInputs
                                        sourceProfile
                                        root
                                        finalizedSpec
                                        candidateConfig
                                        ( \_sourceSpec sourceConfig sourceDrafts ->
                                            either
                                                sourcePlanFailure
                                                id
                                                ( withRecoveredProductionProjectPlan
                                                    sourceProfile
                                                    root
                                                    sourceVerified
                                                    sourceBound
                                                    sourceBinding
                                                    sourceConfig
                                                    sourceDrafts
                                                    ( \sourcePlan -> do
                                                        admittedContext <-
                                                            withValidatedLifecycleContext
                                                                root
                                                                store
                                                                sourcePlan
                                                                binaryContext
                                                                ( \lifecycleContext ->
                                                                    case withValidatedRootLifecycleContext
                                                                        lifecycleContext
                                                                        ( \_ _ _ frame _ -> do
                                                                            opened <-
                                                                                withAcquisitionJournal
                                                                                    sourceRoot
                                                                                    sourceLease
                                                                                    sourceBound
                                                                                    sourceBinding
                                                                                    sourcePlan
                                                                                    ( \journal -> do
                                                                                        withAcquisitionJournalPhase journal $ \seedPhase ->
                                                                                            case seedPhase of
                                                                                                Prepare -> do
                                                                                                    current <-
                                                                                                        withCurrentLifecycleCursor
                                                                                                            journal
                                                                                                            frame
                                                                                                            ProjectUp
                                                                                                            ( \phase cursor ->
                                                                                                                case phase of
                                                                                                                    Prepare -> sourcePhaseFailure "prepare"
                                                                                                                    Execute -> sourcePhaseFailure "execute"
                                                                                                                    Teardown ->
                                                                                                                        continue
                                                                                                                            sourcePlan
                                                                                                                            lifecycleContext
                                                                                                                            journal
                                                                                                                            cursor
                                                                                                            )
                                                                                                    pure (either sourceSessionFailure id current)
                                                                                                Execute -> sourceSeedFailure "execute"
                                                                                                Teardown -> sourceSeedFailure "teardown"
                                                                                    )
                                                                            pure (either sourceSessionFailure id opened)
                                                                        ) of
                                                                        Left failure -> pure (sourceContextFailure failure)
                                                                        Right action -> action
                                                                )
                                                        pure (either sourceContextFailure id admittedContext)
                                                    )
                                                )
                                        )
                                    )
                            )
                        )
                )
                ( \targetVerb targetRoot targetMode targetLease targetVerified targetBound targetBinding targetProfile ->
                    case validateTargetEpoch targetRoot targetMode targetProfile of
                        Left failure -> pure (Left failure)
                        Right targetEpoch ->
                            either
                                (pure . planFailure)
                                id
                                ( withRecoveredProductionProjectPlanInputs
                                    targetProfile
                                    root
                                    finalizedSpec
                                    candidateConfig
                                    ( \targetSpec targetConfig targetDrafts ->
                                        either
                                            (pure . planFailure)
                                            id
                                            ( withRecoveredProductionProjectPlan
                                                targetProfile
                                                root
                                                targetVerified
                                                targetBound
                                                targetBinding
                                                targetConfig
                                                targetDrafts
                                                ( \targetPlan ->
                                                    if projectPlanProfileEpochKernel targetPlan /= targetEpoch
                                                        then pure (Left "lifecycle entry: target plan broker epoch differs")
                                                        else do
                                                            admittedContext <-
                                                                withValidatedLifecycleContext
                                                                    root
                                                                    store
                                                                    targetPlan
                                                                    binaryContext
                                                                    ( \lifecycleContext ->
                                                                        case withValidatedRootLifecycleContext
                                                                            lifecycleContext
                                                                            ( \_ _ targetCurrent frame _ -> do
                                                                                opened <-
                                                                                    withAcquisitionJournal
                                                                                        targetRoot
                                                                                        targetLease
                                                                                        targetBound
                                                                                        targetBinding
                                                                                        targetPlan
                                                                                        ( \journal -> do
                                                                                            cursor <-
                                                                                                withReverseRootTargetLifecycleCursorKernel
                                                                                                    acquisitionJournalAdmissionKernel
                                                                                                    journal
                                                                                                    frame
                                                                                                    targetVerb
                                                                                                    ( \teardownCursor -> do
                                                                                                        let reauthorize =
                                                                                                                ProjectAuthority.authorizeRootProject
                                                                                                                    targetRoot
                                                                                                                    targetVerb
                                                                                                                    targetVerified
                                                                                                                    targetBound
                                                                                                                    targetBinding
                                                                                                                    targetLease
                                                                                                                    targetPlan
                                                                                                                    journal
                                                                                                                    teardownCursor
                                                                                                                    lifecycleContext
                                                                                                        reserved <- reauthorize
                                                                                                        case reserved of
                                                                                                            Left failure ->
                                                                                                                pure
                                                                                                                    ( Left
                                                                                                                        ( Text.unpack
                                                                                                                            (Authority.authorityErrorMessage failure)
                                                                                                                        )
                                                                                                                    )
                                                                                                            Right authority ->
                                                                                                                sealReverseRootEntry
                                                                                                                    targetSpec
                                                                                                                    targetVerb
                                                                                                                    targetRoot
                                                                                                                    targetPlan
                                                                                                                    targetCurrent
                                                                                                                    lifecycleContext
                                                                                                                    journal
                                                                                                                    teardownCursor
                                                                                                                    authority
                                                                                                                    reauthorize
                                                                                                                    ( \entry ->
                                                                                                                        use entry $ \settled -> do
                                                                                                                            checked <- withProtectedEntry store $ \session ->
                                                                                                                                Right
                                                                                                                                    <$> verifyAllSessionsClosed
                                                                                                                                        session
                                                                                                                                        (stablePlanSnapshotDigest (renderSnapshot targetPlan))
                                                                                                                            case checked of
                                                                                                                                Left failure -> pure (Left (Text.unpack (protectedErrorMessage failure)))
                                                                                                                                Right (Left failure) -> pure (Left (sessionErrorMessage failure))
                                                                                                                                Right (Right sessions) ->
                                                                                                                                    terminalizeRootReverseLifecycleEntryKernel
                                                                                                                                        store
                                                                                                                                        project
                                                                                                                                        targetLease
                                                                                                                                        sessions
                                                                                                                                        settled
                                                                                                                                        entry
                                                                                                                    )
                                                                                                    )
                                                                                            pure (either (Left . lifecycleErrorMessage) id cursor)
                                                                                        )
                                                                                pure (either (Left . lifecycleErrorMessage) id opened)
                                                                            ) of
                                                                            Left failure ->
                                                                                pure (Left (lifecycleContextErrorMessage failure))
                                                                            Right action -> action
                                                                    )
                                                            pure
                                                                ( either
                                                                    (Left . lifecycleContextErrorMessage)
                                                                    id
                                                                    admittedContext
                                                                )
                                                )
                                            )
                                    )
                                )
                )
        pure $ case admitted of
            Left failure -> Left ("lifecycle entry: " <> show failure)
            Right result -> result
      where
        sourcePlanFailure =
            pure . sourceMismatch "reverse-root source plan" "exact recovered plan" . Text.pack . show

        sourceContextFailure =
            sourceMismatch "reverse-root source context" "valid root lifecycle context"
                . Text.pack
                . lifecycleContextErrorMessage
        sourceSessionFailure = Left . SnapshotVerificationError . ModeSessionFailure
        sourcePhaseFailure = pure . sourceMismatch "reverse-root source phase" "teardown"
        sourceSeedFailure = pure . sourceMismatch "reverse-root source acquisition seed" "prepare"
        sourceMismatch field expected observed =
            Left (SnapshotVerificationError (ModeEvidenceMismatch field expected observed))

        validateTargetEpoch targetRoot targetMode targetProfile
            | rootEpoch /= modeEpoch =
                Left "lifecycle entry: target root and mode broker epochs differ"
            | rootEpoch /= profileEpoch =
                Left "lifecycle entry: target root and recovered-profile broker epochs differ"
            | otherwise = Right rootEpoch
          where
            rootEpoch = brokerEpochWord (rootAuthorityEpoch targetRoot)
            modeEpoch = brokerEpochWord (projectModeLeaseEpoch targetMode)
            profileEpoch = recoveredProductionProfileEpoch targetProfile

        planFailure failure =
            Left ("lifecycle entry: recovered target plan refused: " <> show failure)

{- | Install the root arm of the recursive-handoff runtime from a sealed entry.

The entry is the admitted root environment: its own invocation authority and
closed verb are what the runtime's identity is derived from, so no caller
selects a project, generation, verb, or key. A child entry has no root arm to
install — its runtime comes from the authenticated parent edge it was admitted
through, and is keyless by construction.

The broker and its matching scope evidence supply the installed verification
identity and the descriptive tag. Neither is retained: what escapes is a value
that can say who this frame is and that it is the one allowed to sign, and
nothing that lets it sign.
-}
withRootRecursiveHandoffRuntimeKernel ::
    LifecycleEntry scope planId frame brokerGeneration verb ->
    RootBroker scope brokerGeneration verb ->
    HandoffScope scope ->
    (RecursiveHandoffRuntime scope brokerGeneration verb -> IO (Either Text ())) ->
    IO (Either Text ())
withRootRecursiveHandoffRuntimeKernel entry broker scope use = case entry of
    RootUpLifecycleEntry root verb _ _ _ _ _ _ -> install root verb
    RootDownLifecycleEntry root verb _ _ _ _ _ _ _ -> install root verb
    RootDestroyLifecycleEntry root verb _ _ _ _ _ _ _ -> install root verb
    ChildUpLifecycleEntry{} -> keylessArmRefusal
    ChildRecoveryLifecycleEntry{} -> keylessArmRefusal
  where
    install root verb =
        case rootRecursiveHandoffRuntimeKernel broker scope (rootBrokerRoute broker) root verb of
            Left failure -> pure (Left failure)
            Right runtime -> use runtime
    keylessArmRefusal =
        pure
            ( Left
                "lifecycle entry: only a sealed root entry installs the root recursive handoff runtime"
            )

{- | Admit the recursive catalog one reverse root entry stands on, then seal
that entry.

Construction is the same recursion the forward entry admits: the recovered
finalized specification, root invocation authority, recovered plan, its own
retained current frame, and the root-resident lifecycle context.  The reverse
entry retains the exact result so a prepared descent takes its canonical child
configuration from an admitted edge rather than from a caller.  No durable
manifest is written here — the Up entry alone owns that record — and Up is a
structural refusal because only Down and Destroy have a reverse.
-}
sealReverseRootEntry ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    ProjectVerb verb ->
    RootInvocationAuthority scope brokerGeneration verb ->
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    ValidatedLifecycleContext scope specDigest planId configId frame ->
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId frame brokerGeneration verb TeardownPhase ->
    CommandAuthority scope planId frame brokerGeneration verb TeardownPhase ->
    IO
        ( Either
            Authority.AuthorityError
            (CommandAuthority scope planId frame brokerGeneration verb TeardownPhase)
        ) ->
    (LifecycleEntry scope planId frame brokerGeneration verb -> IO (Either String ())) ->
    IO (Either String ())
sealReverseRootEntry
    finalized
    verb
    root
    plan
    current
    lifecycleContext
    journal
    cursor
    authority
    reauthorize
    use =
        case verb of
            ProjectUp -> pure (Left "lifecycle entry: reverse target refuses Up")
            ProjectDown ->
                withReverseRootCatalog finalized root plan current lifecycleContext $ \catalog ->
                    use
                        ( RootDownLifecycleEntry
                            root
                            verb
                            plan
                            lifecycleContext
                            journal
                            cursor
                            authority
                            reauthorize
                            catalog
                        )
            ProjectDestroy ->
                withReverseRootCatalog finalized root plan current lifecycleContext $ \catalog ->
                    use
                        ( RootDestroyLifecycleEntry
                            root
                            verb
                            plan
                            lifecycleContext
                            journal
                            cursor
                            authority
                            reauthorize
                            catalog
                        )

{- | Admit the exact recursive catalog for one reverse root frame.

The producer is the same recursion the forward entry admits; only its fixed
result is rewrapped so the reverse entry's own @Either String ()@ escapes.
-}
withReverseRootCatalog ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    RootInvocationAuthority scope brokerGeneration verb ->
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    ValidatedLifecycleContext scope specDigest planId configId frame ->
    ( forall catalogId.
      RootedPlanCatalog scope planId brokerGeneration catalogId ->
      IO (Either String ())
    ) ->
    IO (Either String ())
withReverseRootCatalog finalized root plan current lifecycleContext use = do
    cataloged <-
        withRootedPlanCatalogKernel
            finalized
            root
            plan
            current
            lifecycleContext
            (fmap (either (Left . Text.pack) Right) . use)
    pure (either (Left . Text.unpack) Right cataloged)

{- | Prepare a descent only from a sealed root Down or Destroy entry.

The original work is returned unchanged on refusal. The entry's exact replay
action remains inseparable from its retained Teardown authority.
-}
withPreparedRootReverseDescentKernel ::
    LifecycleEntry scope planId rootFrame brokerGeneration verb ->
    DescentWork scope planId parentFrame childFrame verb ->
    ( forall descentId.
      ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
      IO result
    ) ->
    IO (Either (TeardownError, DescentWork scope planId parentFrame childFrame verb) result)
withPreparedRootReverseDescentKernel entry descent use =
    case entry of
        RootUpLifecycleEntry{} -> refused
        ChildUpLifecycleEntry{} -> refused
        ChildRecoveryLifecycleEntry{} -> refused
        RootDownLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog ->
            prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use
        RootDestroyLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog ->
            prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use
  where
    prepare ::
        RootInvocationAuthority admittedScope admittedBroker admittedVerb ->
        ProjectVerb admittedVerb ->
        ProjectPlan admittedScope specDigest admittedPlanId configId admittedCfg ->
        RootedPlanCatalog admittedScope admittedPlanId admittedBroker catalogId ->
        ValidatedLifecycleContext admittedScope specDigest admittedPlanId configId admittedRootFrame ->
        AcquisitionJournal admittedScope admittedPlanId admittedBroker ->
        LifecycleCursor admittedScope admittedPlanId admittedRootFrame admittedBroker admittedVerb TeardownPhase ->
        CommandAuthority admittedScope admittedPlanId admittedRootFrame admittedBroker admittedVerb TeardownPhase ->
        IO
            ( Either
                Authority.AuthorityError
                (CommandAuthority admittedScope admittedPlanId admittedRootFrame admittedBroker admittedVerb TeardownPhase)
            ) ->
        DescentWork admittedScope admittedPlanId admittedParent admittedChild admittedVerb ->
        ( forall descentId.
          ReverseDescent
            ()
            admittedScope
            admittedPlanId
            admittedParent
            admittedChild
            admittedBroker
            admittedVerb
            descentId ->
          IO admittedResult
        ) ->
        IO
            ( Either
                (TeardownError, DescentWork admittedScope admittedPlanId admittedParent admittedChild admittedVerb)
                admittedResult
            )
    prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize work deliver =
        withPreparedReverseDescentKernel
            acquisitionJournalAdmissionKernel
            root
            verb
            plan
            catalog
            lifecycleContext
            journal
            cursor
            authority
            reauthorize
            work
            deliver
    refused =
        pure
            ( Left
                ( TeardownReverseDescentRefused "only a root Down or Destroy entry can prepare descent"
                , descent
                )
            )

{- | Prepare one failed-Up cleanup descent without entering a reverse
lifecycle phase. The narrow failure authority is required at this wrapper;
the retained Up cursor and command remain at Execute throughout preparation.
-}
withPreparedFailedUpReverseDescentKernel ::
    LifecycleEntry scope planId rootFrame brokerGeneration VerbUp ->
    FailedUpUnwindAuthority scope planId brokerGeneration catalogId ->
    DescentWork scope planId parentFrame childFrame VerbUp ->
    ( forall descentId.
      ReverseDescent () scope planId parentFrame childFrame brokerGeneration VerbUp descentId ->
      IO result
    ) ->
    IO (Either (TeardownError, DescentWork scope planId parentFrame childFrame VerbUp) result)
withPreparedFailedUpReverseDescentKernel entry failedAuthority descent use =
    failedAuthority `seq` case entry of
        RootUpLifecycleEntry root verb plan lifecycleContext journal cursor authority catalog ->
            withPreparedReverseDescentKernel
                acquisitionJournalAdmissionKernel
                root
                verb
                plan
                catalog
                lifecycleContext
                journal
                cursor
                authority
                (pure (Right authority))
                descent
                use
        ChildUpLifecycleEntry{} -> refused
        ChildRecoveryLifecycleEntry{} -> refused
  where
    refused =
        pure
            ( Left
                ( TeardownReverseDescentRefused "only a failed root Up entry can prepare cleanup descent"
                , descent
                )
            )

{- | Derive failed-Up cleanup authority only from a sealed root Up entry.

The catalog identity remains existential under the continuation. A child entry
or a reverse root cannot be reinterpreted as failed forward authority.
-}
withFailedUpUnwindAuthorityForEntryKernel ::
    LifecycleEntry scope planId rootFrame brokerGeneration VerbUp ->
    RootedFrameSession scope planId brokerGeneration sessionCatalogId failedFrame sessionId VerbUp ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    [Text] ->
    [Text] ->
    ( forall catalogId.
      FailedUpUnwindAuthority scope planId brokerGeneration catalogId ->
      result
    ) ->
    Either Text result
withFailedUpUnwindAuthorityForEntryKernel entry failed report binding reached unresolved use =
    case entry of
        RootUpLifecycleEntry root _ _ _ _ _ _ catalog ->
            withFailedUpUnwindAuthorityKernel root catalog failed report binding reached unresolved use
        ChildUpLifecycleEntry{} -> refused "a child Up entry is not the root failure owner"
        ChildRecoveryLifecycleEntry{} -> refused "a recovery child is not the root failure owner"
  where
    refused detail = Left ("failed-Up unwind authority: " <> detail)

{- | Open only the failed-Up cleanup forest authorized for this sealed root
entry. The forest retains VerbUp and therefore cannot enter Destroy closure.
-}
withFailedUpTeardownForestForEntryKernel ::
    LifecycleEntry scope planId rootFrame brokerGeneration VerbUp ->
    FailedUpUnwindAuthority scope planId brokerGeneration catalogId ->
    (TeardownForest scope planId rootFrame VerbUp -> result) ->
    Either Text result
withFailedUpTeardownForestForEntryKernel entry authority use =
    case entry of
        RootUpLifecycleEntry _ _ plan lifecycleContext _ _ _ _ ->
            case withValidatedRootLifecycleContext lifecycleContext $ \_ _ current _ _ ->
                withFailedUpCleanupOperationsKernel authority $ \operations -> do
                    projection <- failedUpTeardownPlanKernel plan current operations
                    forest <- openTeardownForest projection
                    pure (use forest) of
                Left failure -> Left (Text.pack (lifecycleContextErrorMessage failure))
                Right result -> either (Left . Text.pack . teardownErrorMessage) Right result
        ChildUpLifecycleEntry{} -> refused "a child Up entry is not the root failure owner"
        ChildRecoveryLifecycleEntry{} -> refused "a recovery child is not the root failure owner"
  where
    refused detail = Left ("failed-Up unwind forest: " <> detail)

-- | Run cluster cleanup only through the exact sealed root reverse entry.
runPreparedRootClusterCleanupKernel ::
    LifecycleEntry scope planId frame brokerGeneration verb ->
    PreparedGate ->
    LocalWork scope planId frame verb ->
    IO () ->
    IO () ->
    IO TeardownOutcome
runPreparedRootClusterCleanupKernel entry gate local runDown runDestroy =
    case entry of
        RootDownLifecycleEntry _ verb plan _ _ _ _ _ _ ->
            runExactClusterCleanupKernel plan verb gate local runDown runDestroy
        RootDestroyLifecycleEntry _ verb plan _ _ _ _ _ _ ->
            runExactClusterCleanupKernel plan verb gate local runDown runDestroy
        RootUpLifecycleEntry{} -> pure (TeardownFailed "cluster cleanup: root Up has no reverse work")
        ChildUpLifecycleEntry{} -> pure (TeardownFailed "cluster cleanup: a child entry is not the root owner")
        ChildRecoveryLifecycleEntry{} -> pure (TeardownFailed "cluster cleanup: a recovery child is not the root owner")

{- | Seal one authenticated recovery child as an opaque lifecycle entry.

The received descent is forced before Entry derives the typed drafts.  The
child substrate retains every admitted term; this wrapper receives only its
sealed origin and cannot project it.
-}
withReceivedRecoveryChildLifecycleEntry ::
    (ProjectCfg cfg) =>
    ReceivedRecoveryDescent
        (Production projectId)
        brokerGeneration
        planDigest
        parentFrame
        signedChildFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
    ProtectedStore ->
    CanonicalProjectRoot (Production projectId) rootId ->
    FinalizedProjectSpec (Production projectId) specDigest cfg ->
    ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (cfg (Production projectId)) ->
    Context.BinaryContext ->
    ( forall localPlanId localFrame.
      LifecycleEntry
        (Production projectId)
        localPlanId
        localFrame
        brokerGeneration
        verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withReceivedRecoveryChildLifecycleEntry #-}
withReceivedRecoveryChildLifecycleEntry descent =
    case descent `seq` () of
        () -> \store root finalizedSpec config binaryContext use ->
            case projectPlanDrafts finalizedSpec root config of
                Left failure ->
                    pure (Left ("lifecycle entry: recovery child drafts refused: " <> Text.pack (show failure)))
                Right drafts ->
                    withReceivedRecoveryChildOriginKernel
                        descent
                        store
                        root
                        config
                        drafts
                        binaryContext
                        (\origin -> use (ChildRecoveryLifecycleEntry origin))

{- | Emit only the canonical byte identity of a sealed recovery child.

Every other entry is a structural refusal; no retained child evidence is
projected through this fixed-unit fold.
-}
withChildRecoveryTerminalOrigin ::
    LifecycleEntry scope planId frame brokerGeneration verb ->
    (ByteString.ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withChildRecoveryTerminalOrigin entry use =
    case entry of
        ChildRecoveryLifecycleEntry origin -> withChildRecoveryTerminalOriginKernel origin use
        RootUpLifecycleEntry{} -> refused
        ChildUpLifecycleEntry{} -> refused
        RootDownLifecycleEntry{} -> refused
        RootDestroyLifecycleEntry{} -> refused
  where
    refused = pure (Left "lifecycle entry: terminal recovery origin requires a recovery child")

{- | Admit exactly one authenticated child Up/Execute entry.

Verb and phase are classified before the child cursor bridge is called, so a
Prepare, Teardown, Down, or Destroy request cannot open a journal, seed a
cursor, or reserve an invocation.  The callback receives only the shared
opaque entry sum after the child module has durably reserved the exact command.
-}
withChildProjectUpLifecycleEntry ::
    ProjectVerb verb ->
    VerifiedConfigHandoff
        scope
        planDigest
        brokerGeneration
        parentFrame
        signedChildFrame
        configId
        verb
        phase ->
    ChildPlanAuthority
        scope
        specDigest
        planDigest
        brokerGeneration
        parentFrame
        signedChildFrame
        planId
        configId
        verb
        phase ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ValidatedLifecycleContext scope specDigest planId configId childFrame ->
    (LifecycleEntry scope planId childFrame brokerGeneration verb -> IO result) ->
    IO (Either String result)
withChildProjectUpLifecycleEntry
    verb
    handoff
    childAuthority
    plan
    digestBinding
    lifecycleContext
    use =
        case verb of
            ProjectUp -> case verifiedConfigHandoffPhase handoff of
                Execute -> do
                    joined <-
                        withAuthenticatedChildCursor
                            handoff
                            childAuthority
                            plan
                            digestBinding
                            lifecycleContext
                            ( \authenticated -> do
                                reserved <- authorizeAuthenticatedChildCursorKernel authenticated
                                case reserved of
                                    Left failure ->
                                        pure (Left (Text.unpack (Authority.authorityErrorMessage failure)))
                                    Right authorized -> Right <$> use (ChildUpLifecycleEntry authorized)
                            )
                    pure $ case joined of
                        Left failure -> Left (lifecycleErrorMessage failure)
                        Right outcome -> outcome
                Prepare -> pure (Left "lifecycle entry: child Up requires Execute, not Prepare")
                Teardown -> pure (Left "lifecycle entry: child Up requires Execute, not Teardown")
            ProjectDown -> pure (Left "lifecycle entry: config-origin child entry refuses Down")
            ProjectDestroy -> pure (Left "lifecycle entry: config-origin child entry refuses Destroy")

{- | Interpret exactly one admitted root @project up@ leaf.

The retained lifecycle context supplies the only store.  Chain success is
followed by the exact Execute-to-Teardown cursor transition; any failure leaves
the consumed invocation durably fail-closed at Execute and is returned
descriptively.
-}
runRootProjectUpLifecycleEntry ::
    HostConfig ->
    SelfRef ->
    HandoffScope scope ->
    IO (Either String ProjectSigningKey) ->
    (LocalWork scope planId frame VerbUp -> IO TeardownOutcome) ->
    LifecycleEntry scope planId frame brokerGeneration VerbUp ->
    IO (Either String ())
runRootProjectUpLifecycleEntry
    _cfg
    _self
    _scope
    _loadSigningKey
    _runFailedLocal
    (ChildUpLifecycleEntry _) =
        pure (Left "lifecycle entry: the root interpreter refuses a child origin")
runRootProjectUpLifecycleEntry
    _cfg
    _self
    _scope
    _loadSigningKey
    _runFailedLocal
    (ChildRecoveryLifecycleEntry _) =
        pure (Left "lifecycle entry: the root interpreter refuses a recovery child origin")
runRootProjectUpLifecycleEntry
    cfg
    self
    scope
    loadSigningKey
    runFailedLocal
    entry@(RootUpLifecycleEntry rootAuthority verb plan lifecycleContext journal cursor authority catalog) =
        case withValidatedRootLifecycleContext
            lifecycleContext
            (\_root store _current _frame _validated -> run store) of
            Left failure -> pure (Left (lifecycleContextErrorMessage failure))
            Right interpreted -> interpreted
      where
        run store = do
            attempted <-
                try (runRootForwardCoordinator cfg self scope loadSigningKey runFailedLocal entry rootAuthority verb store plan catalog journal authority cursor) ::
                    IO (Either SomeException (Either (String, [Text], [Text]) ()))
            case attempted of
                Right (Left (failure, _reached, _unresolved)) -> pure (Left failure)
                Left exception ->
                    pure $ case fromException exception of
                        Just (SafetyRefusal reason) ->
                            Left (safetyRefusalMarker ++ " " ++ reason)
                        Nothing -> Left (displayException exception)
                Right (Right ()) -> do
                    transitioned <-
                        withTeardownLifecycleCursor cursor (const (pure ()))
                    pure (either (Left . lifecycleErrorMessage) Right transitioned)

{- | Drive one sealed root Down or Destroy entry through the shared rooted
reverse protocol. Root-local work is supplied only as already classified
'LocalWork'; every descent is prepared from the same root command, launched
through its exact catalog edge, and rejoins only as 'SubtreeSettled'.
-}
runRootProjectReverseLifecycleEntry ::
    forall scope planId rootFrame brokerGeneration verb.
    HostConfig ->
    SelfRef ->
    HandoffScope scope ->
    IO (Either String ProjectSigningKey) ->
    LifecycleEntry scope planId rootFrame brokerGeneration verb ->
    (forall specDigest configId cfg. ProjectPlan scope specDigest planId configId cfg -> LocalWork scope planId rootFrame verb -> IO TeardownOutcome) ->
    (SubtreeSettled scope planId rootFrame verb -> IO (Either String ())) ->
    IO (Either String ())
runRootProjectReverseLifecycleEntry cfg self scope loadSigningKey entry runLocal terminalize =
    case entry of
        RootDownLifecycleEntry root verb plan lifecycleContext _ _ _ _ catalog ->
            run root verb plan lifecycleContext catalog
        RootDestroyLifecycleEntry root verb plan lifecycleContext _ _ _ _ catalog ->
            run root verb plan lifecycleContext catalog
        RootUpLifecycleEntry{} -> refused "root Up"
        ChildUpLifecycleEntry{} -> refused "child Up"
        ChildRecoveryLifecycleEntry{} -> refused "recovery child"
  where
    run ::
        forall specDigest configId cfg catalogId.
        RootInvocationAuthority scope brokerGeneration verb ->
        ProjectVerb verb ->
        ProjectPlan scope specDigest planId configId cfg ->
        ValidatedLifecycleContext scope specDigest planId configId rootFrame ->
        RootedPlanCatalog scope planId brokerGeneration catalogId ->
        IO (Either String ())
    run root verb plan lifecycleContext catalog =
        case withValidatedRootLifecycleContext lifecycleContext $ \_ store current _ _ -> do
            signing <- loadSigningKey
            case signing of
                Left failure -> pure (Left (Text.pack failure))
                Right signingKey -> do
                    brokered <- withRootBroker scope store signingKey root $ \broker ->
                        withRootRecursiveHandoffRuntimeKernel entry broker scope $ \runtime -> do
                            let projection = teardownPlan plan current verb
                            case openTeardownForest projection of
                                Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                                Right forest -> do
                                    descentFailures <- newIORef []
                                    driven <-
                                        driveTeardownForest
                                            forest
                                            (const (pure TeardownReleased))
                                            (\_ local -> runLocal plan local)
                                            ( \_ descent -> do
                                                outcome <- launch store broker runtime descent
                                                case outcome of
                                                    Left failure -> modifyIORef' descentFailures (<> [failure])
                                                    Right _ -> pure ()
                                                pure outcome
                                            )
                                            (\_ _ -> pure ())
                                    case driven of
                                        Left outstanding -> do
                                            failures <- readIORef descentFailures
                                            pure (Left ("reverse lifecycle left unsettled work: " <> Text.intercalate ", " outstanding <> if null failures then "" else "; " <> Text.intercalate "; " failures))
                                        Right completed -> case verifySubtreeSettled projection completed of
                                            Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                                            Right settled -> fmap (either (Left . Text.pack) Right) (terminalize settled)
                    pure $ case brokered of
                        Left failure -> Left (Text.pack (handoffErrorMessage failure))
                        Right result -> result of
            Left failure -> pure (Left (lifecycleContextErrorMessage failure))
            Right action -> fmap (either (Left . Text.unpack) Right) action
      where
        launch ::
            forall parentFrame childFrame.
            ProtectedStore ->
            RootBroker scope brokerGeneration verb ->
            RecursiveHandoffRuntime scope brokerGeneration verb ->
            DescentWork scope planId parentFrame childFrame verb ->
            IO (Either Text (SubtreeSettled scope planId childFrame verb))
        launch store broker runtime descent = do
            settledRef <- newIORef Nothing
            prepared <- withPreparedRootReverseDescentKernel entry descent $ \reverseDescent ->
                withRootOpenedDirectFrameSessionKernel
                    runtime
                    catalog
                    store
                    verb
                    (stablePlanSnapshotDigest (renderSnapshot plan))
                    (descentWorkChildFrame descent)
                    ( \session -> do
                        served <-
                            withPreparedRootReverseFrameServiceKernel
                                store
                                (brokerEpochWord (rootAuthorityEpoch root))
                                runtime
                                broker
                                reverseDescent
                                session
                                (const (pure TeardownReleased))
                                (launch store broker runtime)
                                (\settled -> writeIORef settledRef (Just settled) >> pure (Right ()))
                                ( \retainOffer service ->
                                    withPreparedReverseAdmissionsKernel reverseDescent $ \admitEdge admitRecovery -> do
                                        linked <- rootReverseBrokerLink broker scope admitEdge admitRecovery retainOffer service
                                        case linked of
                                            Left failure -> pure (Left (Text.pack (relayErrorMessage failure)))
                                            Right link ->
                                                withReverseDescentLiftContextKernel reverseDescent $ \liftContext ->
                                                    withPreparedReverseLifecycleChildProcess
                                                        cfg
                                                        link
                                                        1
                                                        (targetBinary liftContext)
                                                        reverseDescent
                                )
                        pure $ case served of
                            Left failure -> Left (Text.pack (teardownErrorMessage failure))
                            Right result -> result
                    )
            case prepared of
                Left (failure, _) -> pure (Left (Text.pack (teardownErrorMessage failure)))
                Right (Left failure) -> pure (Left failure)
                Right (Right ()) -> do
                    settled <- readIORef settledRef
                    pure $ maybe (Left "reverse child returned without verified subtree settlement") Right settled

    targetBinary (LiftContext [ViaContainer _]) = Text.empty
    targetBinary _ = Text.pack (inVMSelfPath self)
    refused owner = pure (Left ("reverse lifecycle: " ++ owner ++ " is not a root reverse entry"))

{- | Run the root frame and every declared forward child under one live root.

All child sessions are opened from catalog evidence before the root Chain is
entered. Their closures erase the existential session indices while retaining
the exact session values, so dispatch can select only the canonical requester
path and never reconstruct a session from request bytes.
-}
runRootForwardCoordinator ::
    forall scope specDigest planId configId cfg frame brokerGeneration catalogId.
    HostConfig ->
    SelfRef ->
    HandoffScope scope ->
    IO (Either String ProjectSigningKey) ->
    (LocalWork scope planId frame VerbUp -> IO TeardownOutcome) ->
    LifecycleEntry scope planId frame brokerGeneration VerbUp ->
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    ProjectVerb VerbUp ->
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    RootedPlanCatalog scope planId brokerGeneration catalogId ->
    AcquisitionJournal scope planId brokerGeneration ->
    CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase ->
    IO (Either (String, [Text], [Text]) ())
runRootForwardCoordinator cfg self scope loadSigningKey runFailedLocal entry rootAuthority verb store plan catalog journal authority cursor
    | null catalogEntries = do
        driven <-
            runChainFromFrameWithDescentFailure
                cfg
                self
                store
                plan
                authority
                cursor
                (\_ _ _ _ -> pure (Left "project up: no admitted catalog edge can descend"))
        case driven of
            Right () -> pure (Right ())
            Left failure@(detail, reached, unresolved) -> do
                loaded <- loadSigningKey
                case loaded of
                    Left _ -> pure ()
                    Right signingKey -> do
                        _ <- withRootBroker scope store signingKey rootAuthority $ \broker ->
                            withRootRecursiveHandoffRuntimeKernel entry broker scope $ \runtime ->
                                runRootFailedUpUnwind broker runtime reached unresolved (Text.pack detail)
                        pure ()
                pure (Left failure)
    | otherwise = do
        loaded <- loadSigningKey
        case loaded of
            Left failure -> pure (Left ("project up: " ++ failure, [], []))
            Right signingKey -> do
                coordinatorFailureRef <- newIORef Nothing
                brokered <- withRootBroker scope store signingKey rootAuthority $ \broker ->
                    withRootRecursiveHandoffRuntimeKernel entry broker scope $ \runtime ->
                        withRootedPlanCatalogEntriesContinuationKernel
                            catalog
                            []
                            ( \childPlan _binding _current _parent child _raw _route _payload _configDigest _payloadDigest _keys services continue ->
                                withRootOpenedFrameSessionKernel runtime catalog store verb rootDigest child $ \session -> do
                                    sessionRef <- newIORef session
                                    nodeRef <- newIORef 0
                                    descendedRef <- newIORef False
                                    offerRef <- newIORef Nothing
                                    terminalRef <- newIORef Nothing
                                    observationFailureRef <- newIORef Nothing
                                    observationsRef <- newIORef []
                                    let admitFailedUnwind ::
                                            [Text] ->
                                            [Text] ->
                                            IO (Either Text ())
                                        admitFailedUnwind reached unresolved = do
                                            retainedSession <- readIORef sessionRef
                                            retainedOffer <- readIORef offerRef
                                            retainedTerminal <- readIORef terminalRef
                                            case (retainedOffer, retainedTerminal) of
                                                (Just offer, Just (report, _completion)) ->
                                                    case withFailedUpUnwindAuthorityForEntryKernel
                                                        entry
                                                        retainedSession
                                                        report
                                                        (renderHandoffBinding (handoffOfferBinding offer))
                                                        reached
                                                        unresolved
                                                        ( \failedAuthority ->
                                                            withFailedUpTeardownForestForEntryKernel
                                                                entry
                                                                failedAuthority
                                                                (runFailedUpUnwind broker runtime failedAuthority)
                                                        ) of
                                                        Left failure -> pure (Left failure)
                                                        Right admitted ->
                                                            case admitted of
                                                                Left failure -> pure (Left failure)
                                                                Right action -> action
                                                _ -> pure (Left "the failed frame has no authenticated terminal report")
                                    withRootedFrameSessionKernel session $ \_ _ _ _ _ path _ _ _ _ ->
                                        continue
                                            ( ( path
                                              , child
                                              , offerRef
                                              , observationsRef
                                              , serveForwardFrame store generation runtime broker childPlan child sessionRef nodeRef descendedRef offerRef terminalRef observationFailureRef observationsRef
                                              , admitFailedUnwind
                                              )
                                                : services
                                            )
                            )
                            $ \services -> do
                                linked <- rootForwardBrokerLink broker scope admitEdge (retainOffer services) (dispatch services)
                                case linked of
                                    Left failure -> pure (Left (Text.pack (relayErrorMessage failure)))
                                    Right link -> do
                                        driven <-
                                            runChainFromFrameWithDescentFailure
                                                cfg
                                                self
                                                store
                                                plan
                                                authority
                                                cursor
                                                (launchChild link)
                                        case driven of
                                            Right () -> pure (Right ())
                                            Left failure@(detail, reached, unresolved) -> do
                                                writeIORef coordinatorFailureRef (Just failure)
                                                observedRows <-
                                                    mapM
                                                        (\(_path, _child, _offer, observations, _service, _admit) -> readIORef observations)
                                                        services
                                                let childReached = [operation | rows <- reverse observedRows, (operation, _, _) <- rows]
                                                    frozenReached = reached <> filter (`notElem` reached) childReached
                                                    frozenUnresolved = unresolved <> filter (`notElem` unresolved) childReached
                                                joined <-
                                                    admitFirstFailedFrame
                                                        services
                                                        frozenReached
                                                        frozenUnresolved
                                                case joined of
                                                    Right () -> pure (Left (Text.pack detail))
                                                    Left _ -> do
                                                        rootJoined <- runRootFailedUpUnwind broker runtime frozenReached frozenUnresolved (Text.pack detail)
                                                        pure $ case rootJoined of
                                                            Right () -> Left (Text.pack detail)
                                                            Left unwindFailure -> Left unwindFailure
                case brokered of
                    Left failure -> pure (Left ("project up: " ++ handoffErrorMessage failure, [], []))
                    Right (Right ()) -> pure (Right ())
                    Right (Left failure) -> do
                        retained <- readIORef coordinatorFailureRef
                        pure (Left (maybe (Text.unpack failure, [], []) id retained))
  where
    rootDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    generation = brokerEpochWord (rootAuthorityEpoch rootAuthority)
    catalogEntries = withRootedPlanCatalogEntriesKernel catalog (\_ _ _ _ _ _ _ _ _ _ _ -> ())

    dispatch services path request =
        case [service | (expected, _child, _offer, _observations, service, _admit) <- services, expected == path] of
            [service] -> service path request
            [] -> pure (Right (Left ("rooted-path", "no admitted frame session names this requester path")))
            _ -> pure (Right (Left ("rooted-path", "more than one frame session names this requester path")))

    retainOffer services offer =
        case [ref | (_path, child, ref, _observations, _service, _admit) <- services, child == offeredChild] of
            [ref] -> do
                present <- readIORef ref
                let binding = renderHandoffBinding (handoffOfferBinding offer)
                case present of
                    Nothing -> writeIORef ref (Just offer) >> pure (Right ())
                    Just existing
                        | renderHandoffBinding (handoffOfferBinding existing) == binding -> pure (Right ())
                        | otherwise -> pure (Left "the admitted child already retains another handoff offer")
            [] -> pure (Left "no rooted frame session names the opened child edge")
            _ -> pure (Left "more than one rooted frame session names the opened child edge")
      where
        offeredChild = handoffChildFrame (handoffOfferBinding offer)

    admitFirstFailedFrame [] _ _ = pure (Left ("no failed rooted frame was admitted" :: Text))
    admitFirstFailedFrame ((_path, _child, _offer, _observations, _service, admit) : rest) reached unresolved = do
        attempted <- admit reached unresolved
        case attempted of
            Right () -> pure (Right ())
            Left _ -> admitFirstFailedFrame rest reached unresolved

    admitEdge input =
        withCatalogForwardHandoffKernel catalog (requestedParentFrame input) (requestedChildFrame input) $ \package ->
            withCatalogForwardProcessInputsKernel package $ \_ expected _ ->
                pure
                    ( if renderHandoffBindingInput expected == renderHandoffBindingInput input
                        then Right ()
                        else Left "the requested forward edge differs from its catalog package"
                    )

    launchChild link carrier parent child descent =
        fmap (either (Left . Text.unpack) Right) $
            withCatalogForwardHandoffKernel catalog parent child $ \package ->
                withCatalogForwardProcessInputsKernel package $ \_ input payload ->
                    withForwardLifecycleProcessRouteKernel package verb (targetBinary descent) $ \route ->
                        withCarriedProviderDependencyFromCarrierKernel cfg link route 1 input payload carrier

    targetBinary (LiftContext [ViaContainer _]) = Text.empty
    targetBinary _ = Text.pack (inVMSelfPath self)

    runFailedUpUnwind ::
        forall failedCatalogId.
        RootBroker scope brokerGeneration VerbUp ->
        RecursiveHandoffRuntime scope brokerGeneration VerbUp ->
        FailedUpUnwindAuthority scope planId brokerGeneration failedCatalogId ->
        TeardownForest scope planId frame VerbUp ->
        IO (Either Text ())
    runFailedUpUnwind broker runtime failedAuthority forest = do
        driven <-
            driveTeardownForest
                forest
                (const (pure TeardownReleased))
                (\_ local -> runFailedLocal local)
                (\_ descent -> launchFailed broker runtime failedAuthority descent)
                (\_ _ -> pure ())
        case driven of
            Left outstanding -> do
                let failure :: Text
                    failure = "failed-Up unwind left unsettled work: " <> Text.intercalate ", " outstanding
                published <- publishFailedUnwindReport broker outstanding failure
                pure (either Left (const (Left failure)) published)
            Right completed -> publishCompletedUnwindReport broker completed

    publishFailedUnwindReport broker outstanding detail = do
        token <- freshHandoffToken
        let snapshot = renderSnapshot plan
            rootFrame = lifecycleEntryFrameName entry
            adapterDigest = childConfigDigest (TextEncoding.encodeUtf8 (Text.intercalate "\n" outstanding))
            input =
                HandoffBindingInput
                    { requestedSpecDigest = stablePlanSnapshotSpecDigest snapshot
                    , requestedPayloadKind = RecoveryAdapterWire
                    , requestedPlanRevision = stablePlanSnapshotDigest snapshot
                    , requestedParentFrame = rootFrame
                    , requestedChildFrame = rootFrame
                    , requestedChildConfigDigest = adapterDigest
                    , requestedPhase = "teardown"
                    }
        case mkHandoffBinding broker input token of
            Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
            Right binding ->
                case renderTeardownObservations [(operation, TeardownFailed (Text.unpack detail)) | operation <- outstanding] of
                    Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                    Right observations ->
                        case renderReverseFailedLifecycleReport (renderHandoffBinding binding) observations detail of
                            Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                            Right report -> publishRootedLifecycleReportKernel store report

    publishCompletedUnwindReport broker completed = do
        token <- freshHandoffToken
        let snapshot = renderSnapshot plan
            rootFrame = lifecycleEntryFrameName entry
            rows =
                [ (Text.pack (operationKeyText operation), outcome)
                | (operation, outcome) <- completedForestTerminalObservations completed
                ]
        case renderTeardownObservations rows of
            Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
            Right observations -> do
                let adapterDigest = childConfigDigest observations
                    input =
                        HandoffBindingInput
                            { requestedSpecDigest = stablePlanSnapshotSpecDigest snapshot
                            , requestedPayloadKind = RecoveryAdapterWire
                            , requestedPlanRevision = stablePlanSnapshotDigest snapshot
                            , requestedParentFrame = rootFrame
                            , requestedChildFrame = rootFrame
                            , requestedChildConfigDigest = adapterDigest
                            , requestedPhase = "teardown"
                            }
                case mkHandoffBinding broker input token of
                    Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                    Right binding -> do
                        let bindingBytes = renderHandoffBinding binding
                            word = TextEncoding.encodeUtf8 . Text.pack . show
                            origin =
                                ByteString.concat . map frameWire $
                                    [ "child-recovery-terminal-origin-v1"
                                    , "1"
                                    , bindingBytes
                                    , TextEncoding.encodeUtf8 (stablePlanSnapshotDigest snapshot)
                                    , TextEncoding.encodeUtf8 (stablePlanSnapshotDigest snapshot)
                                    , TextEncoding.encodeUtf8 (invocationIdText (commandAuthorityInvocation authority))
                                    , word (acquisitionJournalRecordVersion journal)
                                    , word (lifecycleCursorRecordVersion cursor)
                                    , TextEncoding.encodeUtf8 rootFrame
                                    , word (brokerEpochWord (commandAuthorityEpoch authority))
                                    , "up"
                                    , TextEncoding.encodeUtf8 (projectVerbName (commandAuthorityVerb authority))
                                    , TextEncoding.encodeUtf8 (lifecyclePhaseName (commandAuthorityPhase authority))
                                    , TextEncoding.encodeUtf8 rootFrame
                                    , "up"
                                    , TextEncoding.encodeUtf8 adapterDigest
                                    ]
                        case renderReverseCompletedLifecycleReport origin observations of
                            Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                            Right report -> do
                                published <- publishRootedLifecycleReportKernel store report
                                pure (() <$ published)

    runRootFailedUpUnwind broker runtime reached unresolved detail
        | null reached = pure (Right ())
        | otherwise = do
            token <- freshHandoffToken
            let snapshot = renderSnapshot plan
                rootFrame = lifecycleEntryFrameName entry
                input =
                    HandoffBindingInput
                        { requestedSpecDigest = stablePlanSnapshotSpecDigest snapshot
                        , requestedPayloadKind = NarrowedProjectConfig
                        , requestedPlanRevision = stablePlanSnapshotDigest snapshot
                        , requestedParentFrame = rootFrame
                        , requestedChildFrame = rootFrame
                        , requestedChildConfigDigest = stablePlanSnapshotConfigDigest snapshot
                        , requestedPhase = "execute"
                        }
                rows =
                    [ (operation, if index == length reached - 1 then "failed" else "succeeded", if index == length reached - 1 then detail else "none")
                    | (index, operation) <- zip [0 :: Int ..] reached
                    ]
            case mkHandoffBinding broker input token of
                Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                Right binding ->
                    let bindingBytes = renderHandoffBinding binding
                     in case renderForwardFailedLifecycleReportWithObservations bindingBytes rows detail of
                            Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                            Right report -> do
                                published <- publishRootedLifecycleReportKernel store report
                                case published of
                                    Left failure -> pure (Left failure)
                                    Right () ->
                                        case withRootFailedUpUnwindAuthorityKernel
                                            rootAuthority
                                            catalog
                                            report
                                            bindingBytes
                                            rootFrame
                                            reached
                                            unresolved
                                            ( \failedAuthority ->
                                                withFailedUpTeardownForestForEntryKernel
                                                    entry
                                                    failedAuthority
                                                    (runFailedUpUnwind broker runtime failedAuthority)
                                            ) of
                                            Left failure -> pure (Left failure)
                                            Right admitted -> case admitted of
                                                Left failure -> pure (Left failure)
                                                Right action -> action

    launchFailed ::
        forall failedCatalogId parentFrame childFrame.
        RootBroker scope brokerGeneration VerbUp ->
        RecursiveHandoffRuntime scope brokerGeneration VerbUp ->
        FailedUpUnwindAuthority scope planId brokerGeneration failedCatalogId ->
        DescentWork scope planId parentFrame childFrame VerbUp ->
        IO (Either Text (SubtreeSettled scope planId childFrame VerbUp))
    launchFailed broker runtime failedAuthority descent = do
        settledRef <- newIORef Nothing
        prepared <- withPreparedFailedUpReverseDescentKernel entry failedAuthority descent $ \reverseDescent ->
            withRootOpenedDirectFrameSessionKernel
                runtime
                catalog
                store
                verb
                rootDigest
                (descentWorkChildFrame descent)
                ( \session -> do
                    served <-
                        withPreparedRootReverseFrameServiceKernel
                            store
                            generation
                            runtime
                            broker
                            reverseDescent
                            session
                            (const (pure TeardownReleased))
                            (launchFailed broker runtime failedAuthority)
                            (\settled -> writeIORef settledRef (Just settled) >> pure (Right ()))
                            ( \retain service ->
                                withPreparedReverseAdmissionsKernel reverseDescent $ \admitPreparedEdge admitRecovery -> do
                                    linked <- rootReverseBrokerLink broker scope admitPreparedEdge admitRecovery retain service
                                    case linked of
                                        Left failure -> pure (Left (Text.pack (relayErrorMessage failure)))
                                        Right link ->
                                            withReverseDescentLiftContextKernel reverseDescent $ \liftContext ->
                                                withPreparedReverseLifecycleChildProcess
                                                    cfg
                                                    link
                                                    1
                                                    (targetBinary liftContext)
                                                    reverseDescent
                            )
                    pure $ case served of
                        Left failure -> Left (Text.pack (teardownErrorMessage failure))
                        Right result -> result
                )
        case prepared of
            Left (failure, _) -> pure (Left (Text.pack (teardownErrorMessage failure)))
            Right (Left failure) -> pure (Left failure)
            Right (Right ()) -> do
                settled <- readIORef settledRef
                pure (maybe (Left "failed-Up child returned without verified subtree settlement") Right settled)

serveForwardFrame ::
    forall scope rootPlanId brokerGeneration catalogId frame sessionId specDigest planId configId cfg.
    ProtectedStore ->
    Word64 ->
    RecursiveHandoffRuntime scope brokerGeneration VerbUp ->
    RootBroker scope brokerGeneration VerbUp ->
    ProjectPlan scope specDigest planId configId cfg ->
    Text ->
    IORef (RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId VerbUp) ->
    IORef Int ->
    IORef Bool ->
    IORef (Maybe (HandoffOffer scope brokerGeneration)) ->
    IORef (Maybe (ByteString.ByteString, Text)) ->
    IORef (Maybe Text) ->
    IORef [(Text, Text, Text)] ->
    [Text] ->
    ByteString.ByteString ->
    IO (Either RelayError (Either (ByteString.ByteString, ByteString.ByteString) ByteString.ByteString))
serveForwardFrame store generation runtime broker childPlan child sessionRef nodeRef descendedRef offerRef terminalRef failureRef observationsRef path request = do
    captured <- newIORef Nothing
    let release signed = writeIORef captured (Just signed) >> pure (Right ())
        finish action = do
            outcome <- action release
            case outcome of
                Left failure -> pure (Right (Left ("rooted-refused", TextEncoding.encodeUtf8 failure)))
                Right () -> do
                    signed <- readIORef captured
                    pure $ case signed of
                        Nothing -> Right (Left ("rooted-refused", "the root produced no response"))
                        Just bytes -> Right (Right bytes)
        settle session node observation after =
            case forwardObservationFailure observation of
                Left failure -> refused session (TextEncoding.encodeUtf8 failure)
                Right observedFailure ->
                    finish $ \releaseSigned ->
                        withRootedPostOpenResponseKernel
                            broker
                            session
                            "settled"
                            request
                            (TextEncoding.encodeUtf8 (childConfigDigest observation))
                            $ \signed ->
                                withSettledRootedNodeKernel runtime session store node request signed $ \_ -> do
                                    after
                                    case observedFailure of
                                        Just detail -> do
                                            writeIORef failureRef (Just detail)
                                            modifyIORef' observationsRef (<> [(node, "failed", detail)])
                                        Nothing -> modifyIORef' observationsRef (<> [(node, "succeeded", "none")])
                                    advanceRootedSession sessionRef session request signed (releaseSigned signed)
        noDescent = case forwardFrameDescent childPlan child of
            Nothing -> True
            Just _ -> False
        refused session detail =
            finish $ \releaseSigned ->
                withRootedPostOpenResponseKernel broker session "refused" request detail $ \signed ->
                    advanceRootedSession sessionRef session request signed (releaseSigned signed)
    case forwardRequestView request of
        Left failure -> pure (Right (Left ("rooted-request", TextEncoding.encodeUtf8 failure)))
        Right ("open", _) -> do
            session <- readIORef sessionRef
            finish $ \releaseSigned ->
                withRootedOpenedResponseKernel runtime broker session store path request $ \attached signed -> do
                    writeIORef sessionRef attached
                    releaseSigned signed
        Right ("next", _) -> do
            session <- readIORef sessionRef
            index <- readIORef nodeRef
            descended <- readIORef descendedRef
            case drop index (forwardFrameNodes childPlan child) of
                ((node, dependencies, projections) : _) ->
                    finish $ \releaseSigned ->
                        withPreparedRootedNodeGrantKernel runtime session store generation (stablePlanSnapshotDigest (renderSnapshot childPlan)) node dependencies projections $ \grant ->
                            withRootedPreparedResponseKernel broker session request grant $ \signed ->
                                advanceRootedSession sessionRef session request signed (releaseSigned signed)
                [] -> case (descended, forwardFrameDescent childPlan child) of
                    (False, Just nextChild) ->
                        finish $ \releaseSigned ->
                            withRootedPostOpenResponseKernel broker session "descend" request (TextEncoding.encodeUtf8 nextChild) $ \signed ->
                                advanceRootedSession sessionRef session request signed (releaseSigned signed)
                    _ ->
                        finish $ \releaseSigned ->
                            withRootedPostOpenResponseKernel broker session "refused" request "terminal report integration is not yet admitted" $ \signed ->
                                advanceRootedSession sessionRef session request signed (releaseSigned signed)
        Right ("settle", Just observation) -> do
            session <- readIORef sessionRef
            index <- readIORef nodeRef
            case drop index (forwardFrameNodes childPlan child) of
                ((node, _, _) : _) -> settle session node observation (modifyIORef' nodeRef (+ 1))
                [] -> pure (Right (Left ("rooted-settle", "no prepared node occupies this ordinal")))
        Right ("descend-result", Just observation) -> do
            session <- readIORef sessionRef
            settle session ("descent/" <> child) observation (writeIORef descendedRef True)
        Right ("close", _) -> do
            session <- readIORef sessionRef
            index <- readIORef nodeRef
            descended <- readIORef descendedRef
            offered <- readIORef offerRef
            failed <- readIORef failureRef
            if failed == Nothing && (index /= length (forwardFrameNodes childPlan child) || not (descended || noDescent))
                then refused session "the frame requested completion before its exact work settled"
                else case offered of
                    Nothing -> refused session "the frame requested completion before its admitted offer was retained"
                    Just offer ->
                        finish $ \releaseSigned ->
                            let publish report =
                                    withRootedPostOpenResponseKernel broker session "frame-complete" request report $ \signed ->
                                        withRootedTerminalReportKernel
                                            runtime
                                            session
                                            request
                                            signed
                                            (publishRootedLifecycleReportKernel store)
                                            $ \published completion -> do
                                                writeIORef terminalRef (Just (published, completion))
                                                advanceRootedSession sessionRef session request signed (releaseSigned signed)
                             in case failed of
                                    Nothing ->
                                        withRootedForwardReportOrigin session offer $ \origin ->
                                            withForwardRootedTerminalReportKernel session origin publish
                                    Just detail ->
                                        readIORef observationsRef >>= \observations ->
                                            withFailedForwardRootedTerminalReportKernel
                                                session
                                                (renderHandoffBinding (handoffOfferBinding offer))
                                                observations
                                                detail
                                                publish
        Right ("receipt", _) -> do
            session <- readIORef sessionRef
            offered <- readIORef offerRef
            terminal <- readIORef terminalRef
            case (offered, terminal) of
                (Just _offer, Just (_report, completion)) ->
                    finish $ \releaseSigned ->
                        withRootedPostOpenResponseKernel
                            broker
                            session
                            "receipt-recorded"
                            request
                            (TextEncoding.encodeUtf8 completion)
                            $ \signedReceipt ->
                                withRootedReceiptConfirmationKernel
                                    runtime
                                    session
                                    request
                                    completion
                                    signedReceipt
                                    ( case renderLifecycleAcknowledgement _report of
                                        Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                                        Right acknowledgement ->
                                            persistRootedLifecycleCompletionKernel store _report acknowledgement
                                    )
                                    $ \_ ->
                                        advanceRootedSession sessionRef session request signedReceipt (releaseSigned signedReceipt)
                _ -> pure (Right (Left ("rooted-receipt", "no FrameComplete has been issued for this session")))
        Right _ -> pure (Right (Left ("rooted-request", "the rooted request body is missing")))

forwardObservationFailure :: ByteString.ByteString -> Either Text (Maybe Text)
forwardObservationFailure raw = do
    (domain, afterDomain) <- takeFrame "observation domain" raw
    (statusOrOperation, afterSecond) <- takeFrame "observation operation or status" afterDomain
    case domain of
        "hostbootstrap/forward-node-observation/v1" -> do
            (status, afterStatus) <- takeFrame "observation status" afterSecond
            (detailBytes, trailing) <- takeFrame "observation detail" afterStatus
            requireEmpty trailing
            classify status detailBytes
        "hostbootstrap/forward-descent-result/v1" -> do
            case statusOrOperation of
                "succeeded" -> requireEmpty afterSecond >> pure Nothing
                "failed" -> do
                    (detailBytes, trailing) <- takeFrame "descent failure detail" afterSecond
                    requireEmpty trailing
                    classify statusOrOperation detailBytes
                _ -> Left "the forward descent observation status is unknown"
        _ -> Left "the forward observation domain is unknown"
  where
    takeFrame field bytes =
        case takeHandoffFrame bytes of
            Left failure -> Left (field <> ": " <> Text.pack (handoffErrorMessage failure))
            Right value -> Right value
    requireEmpty trailing
        | ByteString.null trailing = Right ()
        | otherwise = Left "the forward observation has trailing fields"
    classify "succeeded" _ = Right Nothing
    classify "failed" detailBytes =
        case TextEncoding.decodeUtf8' detailBytes of
            Left _ -> Left "the forward failure detail is not UTF-8"
            Right detail
                | Text.null detail -> Left "the forward failure detail is empty"
                | otherwise -> Right (Just detail)
    classify _ _ = Left "the forward observation status is unknown"

{- | Serve one exact prepared reverse descent through the rooted frame
protocol. The root consumes pre-descent reachability itself; the child sees
only local prepared work or an already completed deeper descent. Every state
advance is retained under the prepared descent's nominal child index.
-}
withPreparedRootReverseFrameServiceKernel ::
    forall scope planId parentFrame childFrame brokerGeneration verb descentId catalogId sessionFrame sessionId result.
    ProtectedStore ->
    Word64 ->
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootBroker scope brokerGeneration verb ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    RootedFrameSession scope planId brokerGeneration catalogId sessionFrame sessionId verb ->
    (PreDescentStep scope planId childFrame verb -> IO TeardownOutcome) ->
    ( forall grandchildFrame.
      DescentWork scope planId childFrame grandchildFrame verb ->
      IO (Either Text (SubtreeSettled scope planId grandchildFrame verb))
    ) ->
    (SubtreeSettled scope planId childFrame verb -> IO (Either Text ())) ->
    ( (HandoffOffer scope brokerGeneration -> IO (Either Text ())) ->
      ([Text] -> ByteString.ByteString -> IO (Either RelayError (Either (ByteString.ByteString, ByteString.ByteString) ByteString.ByteString))) ->
      IO result
    ) ->
    IO (Either TeardownError result)
withPreparedRootReverseFrameServiceKernel store generation runtime broker prepared opened runPre descend complete use =
    case withPreparedReverseForestKernel prepared (,) of
        Left failure -> pure (Left failure)
        Right (projection, forest) -> do
            localPlanDigestRef <- newIORef Nothing
            inputs <-
                withReverseDescentProcessInputsKernel prepared $ \_package _route bindingInput _verb ->
                    writeIORef localPlanDigestRef (Just (requestedPlanRevision bindingInput)) >> pure (Right ())
            localPlanDigest <- case inputs of
                Left failure -> pure (Left failure)
                Right () -> maybe (Left "the prepared reverse descent carries no local plan digest") Right <$> readIORef localPlanDigestRef
            case localPlanDigest of
                Left failure -> pure (Left (TeardownReverseDescentRefused failure))
                Right exactLocalPlanDigest -> openService projection forest exactLocalPlanDigest
  where
    openService projection forest exactLocalPlanDigest = do
        sessionRef <- newIORef opened
        forestRef <- newIORef forest
        offerRef <- newIORef Nothing
        descentRef <- newIORef Nothing
        terminalRef <- newIORef Nothing
        Right <$> use (retain projection offerRef) (serve exactLocalPlanDigest sessionRef forestRef offerRef descentRef terminalRef projection)

    retain projection offerRef offer
        | handoffChildFrame (handoffOfferBinding offer) /= teardownPlanFrameId projection =
            pure (Left "the reverse offer names another child frame")
        | otherwise = do
            present <- readIORef offerRef
            let binding = renderHandoffBinding (handoffOfferBinding offer)
            case present of
                Nothing -> writeIORef offerRef (Just offer) >> pure (Right ())
                Just existing
                    | renderHandoffBinding (handoffOfferBinding existing) == binding -> pure (Right ())
                    | otherwise -> pure (Left "the reverse frame already retains another handoff offer")

    serve exactLocalPlanDigest sessionRef forestRef offerRef descentRef terminalRef projection path request = do
        captured <- newIORef Nothing
        let release signed = writeIORef captured (Just signed) >> pure (Right ())
            finish action = do
                outcome <- action release
                case outcome of
                    Left failure -> refusedWire "rooted-refused" failure
                    Right () -> do
                        signed <- readIORef captured
                        pure $ case signed of
                            Nothing -> Right (Left ("rooted-refused", "the root produced no response"))
                            Just bytes -> Right (Right bytes)
            respond session family body after =
                finish $ \releaseSigned ->
                    withRootedPostOpenResponseKernel broker session family request body $ \signed -> do
                        after
                        advanceRootedSession sessionRef session request signed (releaseSigned signed)
            prepare session node =
                finish $ \releaseSigned ->
                    withPreparedRootedNodeGrantKernel runtime session store generation exactLocalPlanDigest node [] [] $ \grant ->
                        withRootedPreparedResponseKernel broker session request grant $ \signed ->
                            advanceRootedSession sessionRef session request signed (releaseSigned signed)
        case forwardRequestView request of
            Left failure -> refusedWire "rooted-request" failure
            Right ("open", _) -> do
                session <- readIORef sessionRef
                finish $ \releaseSigned ->
                    withRootedOpenedResponseKernel runtime broker session store path request $ \attached signed -> do
                        writeIORef sessionRef attached
                        releaseSigned signed
            Right ("next", _) -> do
                session <- readIORef sessionRef
                forest <- readIORef forestRef
                answerNext respond prepare forestRef descentRef session forest
            Right ("settle", Just observation) -> do
                session <- readIORef sessionRef
                forest <- readIORef forestRef
                case advanceLocal forest observation of
                    Left failure -> refusedWire "rooted-settle" failure
                    Right (node, successor) ->
                        finish $ \releaseSigned ->
                            withRootedPostOpenResponseKernel broker session "settled" request observation $ \signed ->
                                withSettledRootedNodeKernel runtime session store node request signed $ \_ -> do
                                    writeIORef forestRef successor
                                    advanceRootedSession sessionRef session request signed (releaseSigned signed)
            Right ("descend-result", Just observation) -> do
                session <- readIORef sessionRef
                pending <- readIORef descentRef
                case pending of
                    Nothing -> refusedWire "rooted-descent" "no completed descent awaits this result"
                    Just (expected, successor)
                        | expected /= observation -> refusedWire "rooted-descent" "the descent result differs from the completed child"
                        | otherwise ->
                            finish $ \releaseSigned ->
                                withRootedPostOpenResponseKernel broker session "settled" request observation $ \signed ->
                                    withSettledRootedNodeKernel runtime session store ("descent/" <> childFrameName projection) request signed $ \_ -> do
                                        writeIORef forestRef successor
                                        writeIORef descentRef Nothing
                                        advanceRootedSession sessionRef session request signed (releaseSigned signed)
            Right ("close", _) -> do
                session <- readIORef sessionRef
                forest <- readIORef forestRef
                offered <- readIORef offerRef
                case completedProof projection forest of
                    Left failure -> refusedResponseWith respond session failure
                    Right settled -> case offered of
                        Nothing -> refusedResponseWith respond session "the frame requested completion before its admitted offer was retained"
                        Just offer -> case reverseReport prepared offer settled of
                            Left failure -> refusedResponseWith respond session failure
                            Right report ->
                                finish $ \releaseSigned ->
                                    withRootedPostOpenResponseKernel broker session "frame-complete" request report $ \signed ->
                                        withRootedTerminalReportKernel
                                            runtime
                                            session
                                            request
                                            signed
                                            (publishRootedLifecycleReportKernel store)
                                            $ \published completion -> do
                                                writeIORef terminalRef (Just (published, completion, settled))
                                                advanceRootedSession sessionRef session request signed (releaseSigned signed)
            Right ("receipt", _) -> do
                session <- readIORef sessionRef
                terminal <- readIORef terminalRef
                case terminal of
                    Nothing -> refusedWire "rooted-receipt" "no FrameComplete has been issued for this session"
                    Just (_report, completion, settled) ->
                        finish $ \releaseSigned ->
                            withRootedPostOpenResponseKernel
                                broker
                                session
                                "receipt-recorded"
                                request
                                (TextEncoding.encodeUtf8 completion)
                                $ \signed ->
                                    withRootedReceiptConfirmationKernel
                                        runtime
                                        session
                                        request
                                        completion
                                        signed
                                        (complete settled)
                                        $ \_ ->
                                            advanceRootedSession sessionRef session request signed (releaseSigned signed)
            Right _ -> refusedWire "rooted-request" "the rooted request body is missing"

    answerNext respond prepare forestRef descentRef session forest =
        eliminateTeardownProgress
            (nextTeardownWork forest)
            (const (refusedResponseWith respond session "the frame is complete; CloseFrame is required"))
            ( \point ->
                withTeardownAuthorization
                    point
                    ( \pre -> do
                        outcome <- runPre pre
                        let successor = attemptPreDescentStep pre outcome
                        writeIORef forestRef successor
                        case outcome of
                            TeardownFailed detail -> refusedResponseWith respond session (Text.pack detail)
                            _ -> answerNext respond prepare forestRef descentRef session successor
                    )
                    ( \_ teardownWork ->
                        eliminateTeardownWork
                            teardownWork
                            ( \local ->
                                prepare session (localWorkKey local)
                            )
                            ( \descentWork -> do
                                child <- descend descentWork
                                case child of
                                    Left failure -> refusedResponseWith respond session failure
                                    Right settled -> case settleDescentWork descentWork settled of
                                        Left failure -> refusedResponseWith respond session (Text.pack (teardownErrorMessage failure))
                                        Right successor -> case renderSettled settled of
                                            Left failure -> refusedResponseWith respond session failure
                                            Right observations -> do
                                                writeIORef descentRef (Just (observations, successor))
                                                respond session "descend" (framedText (descentWorkChildFrame descentWork) <> framedBytes observations) (pure ())
                            )
                    )
            )

    advanceLocal forest observation = do
        rows <- either (Left . Text.pack . teardownErrorMessage) Right (teardownObservationsFromWire observation)
        case rows of
            [(node, outcome)] ->
                eliminateTeardownProgress
                    (nextTeardownWork forest)
                    (const (Left "the frame is already complete"))
                    ( \point ->
                        withTeardownAuthorization
                            point
                            (const (Left "a child cannot settle root-owned pre-descent work"))
                            ( \_ work ->
                                eliminateTeardownWork
                                    work
                                    ( \local ->
                                        if localWorkKey local == node
                                            then Right (node, attemptLocalWork local outcome)
                                            else Left "the settled node differs from the prepared node"
                                    )
                                    (const (Left "a local settlement cannot advance descent work"))
                            )
                    )
            _ -> Left "a local settlement must carry exactly one observation"

    completedProof projection forest =
        eliminateTeardownProgress
            (nextTeardownWork forest)
            (either (Left . Text.pack . teardownErrorMessage) Right . verifySubtreeSettled projection)
            (const (Left "the frame requested completion before its exact work settled"))

    reverseReport descent offer settled = do
        origin <-
            renderPreparedReverseTerminalOriginKernel
                descent
                (renderHandoffBinding (handoffOfferBinding offer))
        observations <- renderSettled settled
        either
            (Left . Text.pack . handoffErrorMessage)
            Right
            (renderReverseCompletedLifecycleReport origin observations)

    renderSettled settled =
        either
            (Left . Text.pack . teardownErrorMessage)
            Right
            ( renderTeardownObservations
                [(Text.pack (operationKeyText key), outcome) | (key, outcome) <- subtreeSettledTerminalObservations settled]
            )

    childFrameName = teardownPlanFrameId
    framedText = framedBytes . TextEncoding.encodeUtf8
    framedBytes bytes =
        LazyByteString.toStrict . Builder.toLazyByteString $
            Builder.word64BE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes
    refusedResponseWith respond session detail = respond session "refused" (TextEncoding.encodeUtf8 detail) (pure ())
    refusedWire family detail = pure (Right (Left (TextEncoding.encodeUtf8 family, TextEncoding.encodeUtf8 detail)))

withRootedForwardReportOrigin ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId VerbUp ->
    HandoffOffer scope brokerGeneration ->
    (ByteString.ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withRootedForwardReportOrigin session offer use =
    withRootedFrameSessionKernel session $ \_ _ _ _ _ _ token _ _ _ ->
        use
            ( LazyByteString.toStrict . Builder.toLazyByteString . foldMap framed $
                [ "forward-terminal-origin-v1"
                , renderHandoffBinding (handoffOfferBinding offer)
                , TextEncoding.encodeUtf8 token
                , "1"
                , "2"
                , "3"
                , "up"
                , "execute"
                , "teardown"
                ]
            )
  where
    framed bytes = Builder.word64BE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes

advanceRootedSession ::
    IORef (RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb) ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    IO (Either Text ()) ->
    IO (Either Text ())
advanceRootedSession ref session request signed next =
    withAdvancedRootedFrameSessionKernel session request signed $ \advanced ->
        writeIORef ref advanced >> next

forwardFrameNodes :: ProjectPlan scope specDigest planId configId cfg -> Text -> [(Text, [Text], [Text])]
forwardFrameNodes childPlan child =
    [ ( Text.pack (operationKeyText (plannedStepOperationKey planned))
      , [Text.pack (operationKeyText dependency) | (dependency, _) <- plannedStepDependencyOperations planned]
      , map (Text.pack . operationKeyText) (plannedStepProjectedOperationKeys planned)
      )
    | planned <- NonEmpty.toList (forward childPlan)
    , plannedStepFrameId planned == child
    ]

forwardFrameDescent :: ProjectPlan scope specDigest planId configId cfg -> Text -> Maybe Text
forwardFrameDescent childPlan child = fst <$> topologyDescentFrom (topology childPlan) child

forwardRequestView :: ByteString.ByteString -> Either Text (Text, Maybe ByteString.ByteString)
forwardRequestView request = do
    decoded <- RootedWire.rootedLifecycleRequestFromWireKernel request
    RootedWire.withRootedLifecycleRequestKernel
        decoded
        (const (Right ("open", Nothing)))
        (\_ _ _ _ _ _ -> Right ("next", Nothing))
        (\_ _ _ _ _ _ body -> Right ("settle", Just body))
        (\_ _ _ _ _ _ body -> Right ("descend-result", Just body))
        (\_ _ _ _ _ _ -> Right ("close", Nothing))
        (\_ _ _ _ _ _ -> Right ("receipt", Nothing))

{- | Interpret one child-origin Up entry with a sealed completion operation.

The completion callback receives only the opaque terminal origin.  It runs
only after the complete local Chain succeeds and the retained Execute cursor
durably advances to Teardown.  A root-origin entry is an explicit refusal.
-}
runChildProjectUpLifecycleEntry ::
    HostConfig ->
    SelfRef ->
    LifecycleEntry scope planId frame brokerGeneration VerbUp ->
    ( forall specDigest planDigest parentFrame configId.
      AuthorizedChildCursor
        scope
        specDigest
        planDigest
        brokerGeneration
        parentFrame
        planId
        configId
        frame
        VerbUp
        TeardownPhase ->
      IO (Either String ())
    ) ->
    IO (Either String ())
runChildProjectUpLifecycleEntry _cfg _self (RootUpLifecycleEntry{}) _complete =
    pure (Left "lifecycle entry: the child interpreter refuses a root origin")
runChildProjectUpLifecycleEntry _cfg _self (ChildRecoveryLifecycleEntry{}) _complete =
    pure (Left "lifecycle entry: the child Up interpreter refuses a recovery origin")
runChildProjectUpLifecycleEntry cfg self (ChildUpLifecycleEntry authorized) complete =
    runAuthorizedChildCursorKernel cfg self authorized complete

-- | Canonical opaque identity bytes for the later completion protocol.
renderForwardTerminalOrigin ::
    AuthorizedChildCursor
        scope
        specDigest
        planDigest
        brokerGeneration
        parentFrame
        planId
        configId
        frame
        VerbUp
        TeardownPhase ->
    ByteString.ByteString
renderForwardTerminalOrigin = renderForwardTerminalOriginKernel

{- | Terminalize only a sealed root reverse entry. The entry supplies the exact
plan/current-frame pair; destroy is promoted to its unique-root proof here,
before the durable Mode kernel can mutate the retained intent.
-}
terminalizeRootReverseLifecycleEntryKernel ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedAllSessionsClosed (Production projectId) planId ->
    SubtreeSettled (Production projectId) planId frame verb ->
    LifecycleEntry (Production projectId) planId frame brokerGeneration verb ->
    IO (Either String ())
terminalizeRootReverseLifecycleEntryKernel store project lease sessions settled entry =
    case entry of
        RootDownLifecycleEntry _ verb plan lifecycleContext _ _ _ _ _ ->
            validateRoot lifecycleContext $ \current ->
                case validateRootSubtreeSettled plan current settled of
                    Left failure -> pure (Left (show failure))
                    Right () -> terminalize verb Nothing
        RootDestroyLifecycleEntry root verb plan lifecycleContext _ _ _ _ _ ->
            validateRoot lifecycleContext $ \current ->
                case validateRootSubtreeSettled plan current settled of
                    Left failure -> pure (Left (show failure))
                    Right () -> case verifyDestroySettled plan current settled of
                        Left failure -> pure (Left (show failure))
                        Right destroy ->
                            case destroySettledClosure lease sessions destroy of
                                Left failure -> pure (Left (Text.unpack (modeErrorMessage failure)))
                                Right closure ->
                                    terminalize verb (Just (destroy, destroyCloseRoot root, closure))
        RootUpLifecycleEntry{} -> refused "root Up"
        ChildUpLifecycleEntry{} -> refused "child Up"
        ChildRecoveryLifecycleEntry{} -> refused "recovery child"
  where
    validateRoot context use =
        case withValidatedRootLifecycleContext context $ \_ _ current _ _ -> use current of
            Left failure -> pure (Left (lifecycleContextErrorMessage failure))
            Right result -> result
    terminalize verb proof =
        either (Left . Text.unpack . modeErrorMessage) Right
            <$> terminalizeExistingBoundReverseRootKernel store project verb lease sessions settled proof
    refused owner = pure (Left ("reverse terminalization: " ++ owner ++ " is not a root reverse entry"))

-- End reverse terminalization kernel ------------------------------------------
