{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private root/child lifecycle entries and fixed interpreters.

The public command facade exposes this type only abstractly.  Its sole
root constructor joins the exact root @up@ authority, plan, lifecycle context,
acquisition journal, Execute cursor, and command reservation.  Its child
constructor retains one inseparable authorized child package.  No caller can
project those retained values or substitute a raw Chain invocation.
-}
module HostBootstrap.Command.LifecycleEntry
    ( LifecycleEntry
    , AuthorizedChildCursor
    , lifecycleEntryFrameName
    , lifecycleEntryVerbName
    , withRootProjectUpLifecycleEntry
    , withRootProjectReverseLifecycleEntry
    , withRootRecursiveHandoffRuntimeKernel
    , withPreparedRootReverseDescentKernel
    , withReceivedRecoveryChildLifecycleEntry
    , withChildRecoveryTerminalOrigin
    , withChildProjectUpLifecycleEntry
    , runRootProjectUpLifecycleEntry
    , runChildProjectUpLifecycleEntry
    , renderForwardTerminalOrigin
    )
where

import Control.Exception (SomeException, displayException, fromException)
import Control.Exception.Safe (try)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Authority
    ( CommandAuthority
    , ExecutePhase
    , InstalledProjectIdentity
    , LifecyclePhase (Execute, Prepare, Teardown)
    , ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp)
    , TeardownPhase
    , RootInvocationAuthority
    , VerbDestroy
    , VerbDown
    , VerbUp
    , brokerEpochWord
    , projectVerbName
    , rootAuthorityEpoch
    )
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity)
import qualified HostBootstrap.Authority.ProjectPlan as ProjectAuthority
import HostBootstrap.Authority.ProjectPlan.Internal
    ( ChildRecoveryOrigin
    , childRecoveryOriginFrameNameKernel
    , childRecoveryOriginVerbNameKernel
    , withChildRecoveryTerminalOriginKernel
    )
import HostBootstrap.Chain (runChainFromFrame)
import HostBootstrap.Config.Class (ProjectCfg)
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , VerifiedConfigHandoff
    , verifiedConfigHandoffPhase
    )
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Harness
    ( SafetyRefusal (SafetyRefusal)
    , safetyRefusalMarker
    )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Handoff
    ( HandoffScope
    , RootBroker
    , rootBrokerRoute
    )
import HostBootstrap.Handoff.Receiver (ReceivedRecoveryDescent)
import HostBootstrap.Handoff.Runtime
    ( RecursiveHandoffRuntime
    , rootRecursiveHandoffRuntimeKernel
    )
import HostBootstrap.Lifecycle.Context
    ( ValidatedLifecycleContext
    , lifecycleContextErrorMessage
    , withValidatedLifecycleContext
    )
import HostBootstrap.Lifecycle.Context.Internal
    ( withValidatedRootLifecycleContext
    )
import HostBootstrap.Lifecycle.Mode
    ( AcquisitionJournal
    , BoundRunLease
    , LifecycleCursor
    , ModeError (..)
    , VerifiedPlanSnapshot
    , lifecycleCursorFrame
    , lifecycleErrorMessage
    , planSnapshotProjectName
    , planSnapshotStoreIdentity
    , projectModeLeaseEpoch
    , recoveredProductionProfileEpoch
    , withAcquisitionJournal
    , withAcquisitionJournalPhase
    , withCurrentLifecycleCursor
    , withExecuteLifecycleCursor
    , withRecoveredProductionLifecycleProfile
    , withTeardownLifecycleCursor
    )
import HostBootstrap.Lifecycle.Plan
    ( acquisitionJournalAdmissionKernel
    , existingBoundSnapshotAdmissionKernel
    , projectPlanProfileEpochKernel
    )
import HostBootstrap.Lifecycle.RootedPlan
    ( RootedPlanCatalog
    , rootedPlanCatalogManifestKernel
    , rootedPlanCatalogManifestMatchesKernel
    , rootedPlanCatalogRecordIdentityKernel
    , withRootedPlanCatalogKernel
    )
import HostBootstrap.Lifecycle.Session
    ( withReverseRootTargetLifecycleCursorKernel
    )
import HostBootstrap.Lift (SelfRef)
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , projectPlanProjectName
    , renderSnapshot
    , stablePlanSnapshotRoot
    )
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    , SnapshotError (..)
    , withReauthorizedBoundPlanSnapshotKernel
    )
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , projectPlanDrafts
    , withRecoveredProductionProjectPlan
    , withRecoveredProductionProjectPlanInputs
    )
import HostBootstrap.ProjectPlan.Child.Internal
    ( AuthorizedChildCursor
    , ChildPlanAuthority
    , authorizeAuthenticatedChildCursorKernel
    , authorizedChildCursorFrameNameKernel
    , authorizedChildCursorVerbNameKernel
    , renderForwardTerminalOriginKernel
    , runAuthorizedChildCursorKernel
    , withAuthenticatedChildCursor
    , withReceivedRecoveryChildOriginKernel
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    )
import HostBootstrap.Protected
    ( Expectation (ExpectAbsent)
    , ProtectedRecord (protectedRecordBytes, protectedRecordVersion)
    , ProtectedSession
    , ProtectedStore
    , RecordKey
    , compareAndSwapProtectedRecord
    , mkRecordKey
    , mkRecordName
    , protectedErrorMessage
    , protectedStoreIdentity
    , protectedStoreIdentityText
    , readProtectedRecord
    , recordVersionWord
    , withProtectedEntry
    )
import HostBootstrap.Teardown
    ( DescentWork
    , TeardownError (TeardownReverseDescentRefused)
    )
import HostBootstrap.Teardown.Internal
    ( ReverseDescent
    , withPreparedReverseDescentKernel
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
            scope specDigest planDigest brokerGeneration parentFrame
            planId configId frame VerbUp ExecutePhase ->
        LifecycleEntry scope planId frame brokerGeneration VerbUp
    ChildRecoveryLifecycleEntry ::
        ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
            planId configId frame verb ->
        LifecycleEntry scope planId frame brokerGeneration verb
    RootDownLifecycleEntry ::
        RootInvocationAuthority scope brokerGeneration VerbDown ->
        ProjectVerb VerbDown ->
        ProjectPlan scope specDigest planId configId cfg ->
        ValidatedLifecycleContext scope specDigest planId configId frame ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId frame brokerGeneration VerbDown TeardownPhase ->
        CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase ->
        IO (Either Authority.AuthorityError
            (CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase)) ->
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
        IO (Either Authority.AuthorityError
            (CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase)) ->
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
        case
            withValidatedRootLifecycleContext
                lifecycleContext
                (\root store current frame _validated ->
                    case
                        validateRootBoundary
                            (canonicalProjectRootPath root)
                            (protectedStoreIdentityText (protectedStoreIdentity store))
                    of
                        Left failure -> pure (Left failure)
                        Right () -> openJournal store current frame
                )
        of
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
                (\journal -> do
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
    case
        ( rootedPlanCatalogManifestKernel catalog
        , mkRecordName (rootedPlanCatalogRecordIdentityKernel catalog) >>= mkRecordKey
        )
    of
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
        (Production projectId) targetPlanId targetFrame targetBroker verb ->
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
                ( \sourceRoot sourceMode sourceLease sourceVerified sourceBound sourceBinding
                    sourceRecovery continue ->
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
                                                                        case
                                                                            withValidatedRootLifecycleContext
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
                                                                                )
                                                                        of
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
                ( \targetVerb targetRoot targetMode targetLease targetVerified targetBound
                    targetBinding targetProfile ->
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
                                                                            case
                                                                                withValidatedRootLifecycleContext
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
                                                                                                                            use
                                                                                                            )
                                                                                                    pure (either (Left . lifecycleErrorMessage) id cursor)
                                                                                                )
                                                                                        pure (either (Left . lifecycleErrorMessage) id opened)
                                                                                    )
                                                                            of
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
    IO (Either Authority.AuthorityError
        (CommandAuthority scope planId frame brokerGeneration verb TeardownPhase)) ->
    (LifecycleEntry scope planId frame brokerGeneration verb -> IO (Either String ())) ->
    IO (Either String ())
sealReverseRootEntry
    finalized verb root plan current lifecycleContext journal cursor authority reauthorize use =
        case verb of
            ProjectUp -> pure (Left "lifecycle entry: reverse target refuses Up")
            ProjectDown ->
                withReverseRootCatalog finalized root plan current lifecycleContext $ \catalog ->
                    use
                        ( RootDownLifecycleEntry
                            root verb plan lifecycleContext journal cursor authority reauthorize catalog
                        )
            ProjectDestroy ->
                withReverseRootCatalog finalized root plan current lifecycleContext $ \catalog ->
                    use
                        ( RootDestroyLifecycleEntry
                            root verb plan lifecycleContext journal cursor authority reauthorize catalog
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
    LifecycleEntry scope planId parentFrame brokerGeneration verb ->
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
        ValidatedLifecycleContext admittedScope specDigest admittedPlanId configId admittedFrame ->
        AcquisitionJournal admittedScope admittedPlanId admittedBroker ->
        LifecycleCursor admittedScope admittedPlanId admittedFrame admittedBroker admittedVerb TeardownPhase ->
        CommandAuthority admittedScope admittedPlanId admittedFrame admittedBroker admittedVerb TeardownPhase ->
        IO (Either Authority.AuthorityError
            (CommandAuthority admittedScope admittedPlanId admittedFrame admittedBroker admittedVerb TeardownPhase)) ->
        DescentWork admittedScope admittedPlanId admittedFrame admittedChild admittedVerb ->
        ( forall descentId.
          ReverseDescent () admittedScope admittedPlanId admittedFrame
            admittedChild admittedBroker admittedVerb descentId ->
          IO admittedResult
        ) ->
        IO (Either
            (TeardownError, DescentWork admittedScope admittedPlanId admittedFrame admittedChild admittedVerb)
            admittedResult)
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

{- | Seal one authenticated recovery child as an opaque lifecycle entry.

The received descent is forced before Entry derives the typed drafts.  The
child substrate retains every admitted term; this wrapper receives only its
sealed origin and cannot project it.
-}
withReceivedRecoveryChildLifecycleEntry ::
    (ProjectCfg cfg) =>
    ReceivedRecoveryDescent
        (Production projectId) brokerGeneration planDigest parentFrame signedChildFrame
        recoveryWireDigest recoveryWireId verb ->
    ProtectedStore ->
    CanonicalProjectRoot (Production projectId) rootId ->
    FinalizedProjectSpec (Production projectId) specDigest cfg ->
    ValidatedConfig
        (Production projectId) specDigest configId (cfg (Production projectId)) ->
    Context.BinaryContext ->
    ( forall localPlanId localFrame.
      LifecycleEntry
        (Production projectId) localPlanId localFrame brokerGeneration verb ->
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
        scope planDigest brokerGeneration parentFrame signedChildFrame
        configId verb phase ->
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame signedChildFrame
        planId configId verb phase ->
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
    LifecycleEntry scope planId frame brokerGeneration VerbUp ->
    IO (Either String ())
runRootProjectUpLifecycleEntry
    _cfg
    _self
    (ChildUpLifecycleEntry _) =
        pure (Left "lifecycle entry: the root interpreter refuses a child origin")
runRootProjectUpLifecycleEntry
    _cfg
    _self
    (ChildRecoveryLifecycleEntry _) =
        pure (Left "lifecycle entry: the root interpreter refuses a recovery child origin")
runRootProjectUpLifecycleEntry
    cfg
    self
    (RootUpLifecycleEntry _rootAuthority _verb plan lifecycleContext _journal cursor authority _catalog) =
        case
            withValidatedRootLifecycleContext
                lifecycleContext
                (\_root store _current _frame _validated -> run store)
        of
            Left failure -> pure (Left (lifecycleContextErrorMessage failure))
            Right interpreted -> interpreted
  where
    run store = do
        attempted <-
            try (runChainFromFrame cfg self store plan authority cursor) ::
                IO (Either SomeException (Either String ()))
        case attempted of
            Right (Left failure) -> pure (Left failure)
            Left exception ->
                pure $ case fromException exception of
                    Just (SafetyRefusal reason) ->
                        Left (safetyRefusalMarker ++ " " ++ reason)
                    Nothing -> Left (displayException exception)
            Right (Right ()) -> do
                transitioned <-
                    withTeardownLifecycleCursor cursor (const (pure ()))
                pure (either (Left . lifecycleErrorMessage) Right transitioned)

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
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId frame VerbUp TeardownPhase ->
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
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId frame VerbUp TeardownPhase ->
    ByteString.ByteString
renderForwardTerminalOrigin = renderForwardTerminalOriginKernel
