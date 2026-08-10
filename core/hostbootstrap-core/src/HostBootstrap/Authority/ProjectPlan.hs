{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Exact current-frame @project up@ admission.

'authorizeProjectUp' joins the complete retained plan, lease, journal, cursor,
frame, and descriptive-context evidence before entering the package-private
reservation kernel.
-}
module HostBootstrap.Authority.ProjectPlan (
    authorizeProjectUp,
    authorizeChildProject,
) where

import qualified Data.Text as Text
import HostBootstrap.Authority (
    AuthorityError (AuthorityMalformedBinding),
    CommandAuthority,
    ProjectVerb (ProjectUp),
    RootInvocationAuthority,
    VerbUp,
    brokerEpochWord,
    lifecyclePhaseName,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
 )
import HostBootstrap.Authority.Kernel (
    childCommandReservationKernel,
    commandReservationKernel,
    rootAuthorityStoreIdentity,
 )
import qualified HostBootstrap.Context as Context
import HostBootstrap.Lifecycle.Mode (
    BoundRunLease,
    VerifiedPlanSnapshot,
    boundRunLeasePlanDigest,
    boundRunLeaseRunText,
    boundRunLeaseSpecDigest,
    lifecycleErrorMessage,
    planSnapshotCanonicalBytes,
    planSnapshotConfigDigest,
    planSnapshotPlanDigest,
    planSnapshotProjectName,
    planSnapshotRunText,
    planSnapshotSpecDigest,
    planSnapshotStoreIdentity,
    validateBoundRunLeaseAcquisitionJournal,
 )
import HostBootstrap.Lifecycle.Plan (
    BoundPlanSnapshot,
    PlanDigestBinding,
    boundPlanSnapshotBytesKernel,
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotConfigDigest,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotSpecDigest,
    planDigestBindingDigestKernel,
    projectPlanCanonicalSnapshotKernel,
    projectPlanProfileEpochKernel,
    projectPlanProfileNameKernel,
    projectPlanProfileProjectNameKernel,
    projectPlanProfileStoreIdentityKernel,
    projectPlanValidatedConfigKernel,
 )
import HostBootstrap.Lifecycle.Session (
    AcquisitionJournal,
    LifecycleCursor,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRootVerb,
    acquisitionJournalRunLease,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalStableScope,
    lifecycleCursorFrame,
    lifecycleCursorPhase,
    lifecycleCursorVerb,
    reserveCurrentLifecycleCommandKernel,
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    topology,
    topologyContainsFrame,
    topologyParentFrame,
 )
import HostBootstrap.ProjectPlan.Frame (
    ProjectFrame,
    ValidatedContext,
    projectFrameId,
    validatedContextValue,
 )
import HostBootstrap.ProjectPlan.Child.Internal (
    ChildPlanAuthority,
    childPlanAuthorityBindingKernel,
 )
import HostBootstrap.Config.Schema (
    validatedConfigDigest,
    validatedConfigSpecDigest,
 )
import HostBootstrap.Handoff (
    handoffBrokerGeneration,
    handoffChildConfigDigest,
    handoffChildFrame,
    handoffInstalledProject,
    handoffPhase,
    handoffPlanRevision,
    handoffParentFrame,
    handoffScope,
    handoffSpecDigest,
    handoffStoreIdentity,
    handoffVerb,
 )

{- | Reserve one @project up@ invocation for the exact current frame.

Every retained term is checked before the protected reservation bridge is
entered.  The bridge then revalidates the journal and cursor against live
protected state and performs the one-use reservation in that same entry.
-}
authorizeProjectUp ::
    RootInvocationAuthority scope brokerGeneration VerbUp ->
    ProjectVerb VerbUp ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    ProjectPlan scope specDigest planId configId cfg ->
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp phase ->
    ValidatedContext scope planId frame ->
    IO
        ( Either
            AuthorityError
            (CommandAuthority scope planId frame brokerGeneration VerbUp phase)
        )
authorizeProjectUp root ProjectUp verified bound binding lease plan journal frame cursor validated =
    case validateRetainedEvidence of
        Left failure -> pure (Left failure)
        Right () ->
            reserveCurrentLifecycleCommandKernel
                journal
                cursor
                ( commandReservationKernel
                    root
                    canonicalPlanDigest
                    (lifecycleCursorPhase cursor)
                    frameId
                )
  where
    canonical = projectPlanCanonicalSnapshotKernel plan
    canonicalSpecDigest = canonicalPlanSnapshotSpecDigest canonical
    canonicalConfigDigest = canonicalPlanSnapshotConfigDigest canonical
    canonicalPlanDigest = canonicalPlanSnapshotDigest canonical
    canonicalBytes = canonicalPlanSnapshotBytes canonical
    rootProject = rootAuthorityProjectName root
    rootStore = rootAuthorityStoreIdentity root
    rootEpoch = brokerEpochWord (rootAuthorityEpoch root)
    leaseRun = boundRunLeaseRunText lease
    frameId = projectFrameId frame
    context = validatedContextValue validated

    validateRetainedEvidence = do
        requireText "root project verb" "up" (projectVerbName (rootAuthorityVerb root))
        requireText "cursor project verb" "up" (projectVerbName (lifecycleCursorVerb cursor))
        requireText "journal project verb" "up" (acquisitionJournalRootVerb journal)
        requireText "plan specification digest" canonicalSpecDigest (planSnapshotSpecDigest verified)
        requireText "lease specification digest" canonicalSpecDigest (boundRunLeaseSpecDigest lease)
        requireMaybeText
            "verified configuration digest"
            canonicalConfigDigest
            (planSnapshotConfigDigest verified)
        requireText "verified plan digest" canonicalPlanDigest (planSnapshotPlanDigest verified)
        requireText "bound lease plan digest" canonicalPlanDigest (boundRunLeasePlanDigest lease)
        requireText "plan digest binding" canonicalPlanDigest (planDigestBindingDigestKernel binding)
        requireText
            "acquisition journal snapshot digest"
            canonicalPlanDigest
            (acquisitionJournalSnapshotDigest journal)
        requireMaybeBytes "verified canonical plan bytes" canonicalBytes (planSnapshotCanonicalBytes verified)
        requireBytes "bound canonical plan bytes" canonicalBytes (boundPlanSnapshotBytesKernel bound)
        requireText "plan project" rootProject (projectPlanProfileProjectNameKernel plan)
        requireText "verified project" rootProject (planSnapshotProjectName verified)
        requireText "plan protected store" rootStore (projectPlanProfileStoreIdentityKernel plan)
        requireText "verified protected store" rootStore (planSnapshotStoreIdentity verified)
        requireWord "plan broker epoch" rootEpoch (projectPlanProfileEpochKernel plan)
        requireWord
            "acquisition journal broker epoch"
            rootEpoch
            (acquisitionJournalBrokerGeneration journal)
        requireText
            "acquisition journal stable scope"
            (projectPlanProfileNameKernel plan)
            (acquisitionJournalStableScope journal)
        requireText "verified run lease" leaseRun (planSnapshotRunText verified)
        requireText "acquisition journal run lease" leaseRun (acquisitionJournalRunLease journal)
        either
            (malformed . Text.pack . lifecycleErrorMessage)
            Right
            (validateBoundRunLeaseAcquisitionJournal lease journal)
        requireCondition
            "project frame is outside the admitted topology"
            (topologyContainsFrame (topology plan) frameId)
        requireText "cursor frame" frameId (lifecycleCursorFrame cursor)
        requireText "validated context current frame" frameId (Context.currentFrame context)
        placement <-
            either
                (const (malformed "validated context has no structural placement"))
                Right
                (Context.contextPlacement context)
        requireCondition
            "validated context placement refuses cluster lifecycle commands"
            ( Context.placementAllowsCommand
                placement
                (Context.isRootFrame context)
                Context.ClusterLifecycleCommand
            )

    malformed subject = Left (AuthorityMalformedBinding subject)

    requireCondition subject condition
        | condition = Right ()
        | otherwise = malformed subject

    requireText subject expected observed =
        requireCondition (subject <> " does not match") (expected == observed)

    requireMaybeText subject expected observed =
        requireCondition (subject <> " does not match") (observed == Just expected)

    requireWord subject expected observed =
        requireCondition (subject <> " does not match") (expected == observed)

    requireBytes subject expected observed =
        requireCondition (subject <> " do not match") (expected == observed)

    requireMaybeBytes subject expected observed =
        requireCondition (subject <> " do not match") (observed == Just expected)

{- | Reserve one authenticated child invocation for its exact local plan and
current frame.

The child has no root, Harness-root, or signing authority.  Its opaque
'ChildPlanAuthority' was minted only beside this plan's local identity and the
signed stable digest.  This gate compares every retained signed origin with the
plan, journal, frame, cursor, and context, then enters the same one-use
protected reservation kernel as root admission.
-}
authorizeChildProject ::
    ProjectVerb verb ->
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame frame
        planId configId verb phase ->
    ProjectPlan scope specDigest planId configId cfg ->
    AcquisitionJournal scope planId brokerGeneration ->
    ProjectFrame scope specDigest planId configId frame ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    ValidatedContext scope planId frame ->
    IO
        ( Either
            AuthorityError
            (CommandAuthority scope planId frame brokerGeneration verb phase)
        )
authorizeChildProject verb authority plan journal frame cursor validated =
    case validateRetainedEvidence of
        Left failure -> pure (Left failure)
        Right () ->
            reserveCurrentLifecycleCommandKernel
                journal
                cursor
                ( childCommandReservationKernel
                    signedProject
                    signedStore
                    signedGeneration
                    verb
                    canonicalPlanDigest
                    (lifecycleCursorPhase cursor)
                    frameId
                )
  where
    signed = childPlanAuthorityBindingKernel authority
    signedProject = handoffInstalledProject signed
    signedStore = handoffStoreIdentity signed
    signedGeneration = handoffBrokerGeneration signed
    canonical = projectPlanCanonicalSnapshotKernel plan
    canonicalSpecDigest = canonicalPlanSnapshotSpecDigest canonical
    canonicalConfigDigest = canonicalPlanSnapshotConfigDigest canonical
    canonicalPlanDigest = canonicalPlanSnapshotDigest canonical
    retainedConfig = projectPlanValidatedConfigKernel plan
    frameId = projectFrameId frame
    context = validatedContextValue validated

    validateRetainedEvidence = do
        requireText "requested project verb" (handoffVerb signed) (projectVerbName verb)
        requireText "cursor project verb" (handoffVerb signed) (projectVerbName (lifecycleCursorVerb cursor))
        requireText "journal project verb" (handoffVerb signed) (acquisitionJournalRootVerb journal)
        requireText "cursor lifecycle phase" (handoffPhase signed) (lifecyclePhaseName (lifecycleCursorPhase cursor))
        requireText "plan specification digest" (handoffSpecDigest signed) canonicalSpecDigest
        requireText "validated specification digest" canonicalSpecDigest (validatedConfigSpecDigest retainedConfig)
        requireText "plan configuration digest" (handoffChildConfigDigest signed) canonicalConfigDigest
        requireText "validated configuration digest" canonicalConfigDigest (validatedConfigDigest retainedConfig)
        requireText "stable plan digest" (handoffPlanRevision signed) canonicalPlanDigest
        requireText "acquisition journal snapshot digest" canonicalPlanDigest (acquisitionJournalSnapshotDigest journal)
        requireText "plan project" signedProject (projectPlanProfileProjectNameKernel plan)
        requireText "plan protected store" signedStore (projectPlanProfileStoreIdentityKernel plan)
        requireWord "plan broker epoch" signedGeneration (projectPlanProfileEpochKernel plan)
        requireWord "acquisition journal broker epoch" signedGeneration (acquisitionJournalBrokerGeneration journal)
        expectedScope <- childStableScope signed
        requireText "plan lifecycle scope" expectedScope (projectPlanProfileNameKernel plan)
        requireText "acquisition journal stable scope" expectedScope (acquisitionJournalStableScope journal)
        requireText "authenticated child frame" (handoffChildFrame signed) frameId
        requireCondition
            "project frame is outside the admitted topology"
            (topologyContainsFrame (topology plan) frameId)
        requireMaybeText
            "authenticated parent frame"
            (handoffParentFrame signed)
            (topologyParentFrame (topology plan) frameId)
        requireText "cursor frame" frameId (lifecycleCursorFrame cursor)
        requireText "validated context current frame" frameId (Context.currentFrame context)
        placement <-
            either
                (const (malformed "validated context has no structural placement"))
                Right
                (Context.contextPlacement context)
        requireCondition
            "validated context placement refuses cluster lifecycle commands"
            ( Context.placementAllowsCommand
                placement
                (Context.isRootFrame context)
                Context.ClusterLifecycleCommand
            )

    childStableScope binding
        | handoffScope binding == "Production" = Right "production"
        | Just runName <- Text.stripPrefix "Harness " (handoffScope binding)
        , not (Text.null runName) = Right ("harness:" <> runName)
        | otherwise = malformed "authenticated handoff carries an unknown lifecycle scope"

    malformed subject = Left (AuthorityMalformedBinding subject)

    requireCondition subject condition
        | condition = Right ()
        | otherwise = malformed subject

    requireText subject expected observed =
        requireCondition (subject <> " does not match") (expected == observed)

    requireMaybeText subject expected observed =
        requireCondition (subject <> " does not match") (observed == Just expected)

    requireWord subject expected observed =
        requireCondition (subject <> " does not match") (expected == observed)
