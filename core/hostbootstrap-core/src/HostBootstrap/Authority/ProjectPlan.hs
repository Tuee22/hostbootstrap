{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Exact current-frame root-project admission.

'authorizeRootProject' joins the complete retained plan, lease, journal, cursor,
frame, and descriptive-context evidence before entering the package-private
reservation kernel.
-}
module HostBootstrap.Authority.ProjectPlan (
    authorizeRootProject,
) where

import qualified Data.Text as Text
import HostBootstrap.Authority (
    AuthorityError (AuthorityMalformedBinding),
    CommandAuthority,
    ProjectVerb,
    RootInvocationAuthority,
    brokerEpochWord,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
 )
import HostBootstrap.Authority.Kernel (
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
import HostBootstrap.Lifecycle.Context
    ( ValidatedLifecycleContext
    , lifecycleContextErrorMessage
    )
import HostBootstrap.Lifecycle.Context.Internal
    ( withValidatedRootLifecycleContext
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
 )
import HostBootstrap.ProjectPlan.Frame (
    projectFrameId,
    validatedContextValue,
 )

{- | Reserve one root-project invocation for the exact current frame.

Every retained term is checked before the protected reservation bridge is
entered.  The bridge then revalidates the journal and cursor against live
protected state and performs the one-use reservation in that same entry.
-}
authorizeRootProject ::
    RootInvocationAuthority scope brokerGeneration verb ->
    ProjectVerb verb ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    ProjectPlan scope specDigest planId configId cfg ->
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    ValidatedLifecycleContext scope specDigest planId configId frame ->
    IO
        ( Either
            AuthorityError
            (CommandAuthority scope planId frame brokerGeneration verb phase)
        )
authorizeRootProject root verb verified bound binding lease plan journal cursor lifecycleContext =
    case
        withValidatedRootLifecycleContext
            lifecycleContext
            (\_canonicalRoot _store _current frame validated -> authorize frame validated)
    of
        Left failure ->
            pure
                ( Left
                    (AuthorityMalformedBinding (Text.pack (lifecycleContextErrorMessage failure)))
                )
        Right admitted -> admitted
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
    expectedVerb = projectVerbName verb

    authorize frame validated =
        case validateRetainedEvidence frame validated of
            Left failure -> pure (Left failure)
            Right () ->
                reserveCurrentLifecycleCommandKernel
                    journal
                    cursor
                    ( commandReservationKernel
                        root
                        canonicalPlanDigest
                        (lifecycleCursorPhase cursor)
                        (projectFrameId frame)
                    )

    validateRetainedEvidence frame validated = do
        let frameId = projectFrameId frame
            context = validatedContextValue validated
        requireText "root project verb" expectedVerb (projectVerbName (rootAuthorityVerb root))
        requireText "cursor project verb" expectedVerb (projectVerbName (lifecycleCursorVerb cursor))
        requireText "journal project verb" expectedVerb (acquisitionJournalRootVerb journal)
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
