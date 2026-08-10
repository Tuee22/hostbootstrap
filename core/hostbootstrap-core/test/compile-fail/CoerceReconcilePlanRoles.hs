{- | Every public opaque reconciliation value retains the exact generative
plan that produced it.  Equal runtime representations cannot relabel that
plan, even for reporting or intermediate evidence types.
-}
module CoerceReconcilePlanRoles where

import Data.Coerce (coerce)
import HostBootstrap.Reconcile
    ( AdoptionAuthority
    , DependencyProbe
    , DependencySnapshot
    , LifecyclePlan
    , OperationDescriptor
    , OperationPreconditionSet
    , OwnershipReceipt
    , PhaseAdvance
    , PhaseTransition
    , PreparedOperation
    , PreparedPreconditions
    , PriorCommitProof
    , ReconcileResult
    , VerifiedAtPhase
    , VerifiedForeignOrigin
    , VerifiedJournalRecord
    )

data Scope
data Identity
data Resource
data Origin
data Operation
data CallDigest
data Attempt
data JournalVersion
data FromPhase
data ToPhase

data LifecyclePlanA
data LifecyclePlanB
data ReceiptPlanA
data ReceiptPlanB
data ForeignOriginPlanA
data ForeignOriginPlanB
data AdoptionPlanA
data AdoptionPlanB
data DescriptorPlanA
data DescriptorPlanB
data ProbePlanA
data ProbePlanB
data SnapshotPlanA
data SnapshotPlanB
data PreconditionsPlanA
data PreconditionsPlanB
data PreparedOperationPlanA
data PreparedOperationPlanB
data PreparedPreconditionsPlanA
data PreparedPreconditionsPlanB
data ResultPlanA
data ResultPlanB
data JournalRecordPlanA
data JournalRecordPlanB
data CommitProofPlanA
data CommitProofPlanB
data TransitionPlanA
data TransitionPlanB
data VerifiedPhasePlanA
data VerifiedPhasePlanB
data AdvancePlanA
data AdvancePlanB

coerceLifecyclePlan ::
    LifecyclePlan Scope LifecyclePlanA ->
    LifecyclePlan Scope LifecyclePlanB
coerceLifecyclePlan = coerce

coerceReceiptPlan ::
    OwnershipReceipt Scope ReceiptPlanA Identity Resource ->
    OwnershipReceipt Scope ReceiptPlanB Identity Resource
coerceReceiptPlan = coerce

coerceForeignOriginPlan ::
    VerifiedForeignOrigin Scope ForeignOriginPlanA Identity Resource Origin ->
    VerifiedForeignOrigin Scope ForeignOriginPlanB Identity Resource Origin
coerceForeignOriginPlan = coerce

coerceAdoptionPlan ::
    AdoptionAuthority Scope AdoptionPlanA Identity Resource Origin Operation ->
    AdoptionAuthority Scope AdoptionPlanB Identity Resource Origin Operation
coerceAdoptionPlan = coerce

coerceDescriptorPlan ::
    OperationDescriptor Scope DescriptorPlanA Identity Resource FromPhase ToPhase ->
    OperationDescriptor Scope DescriptorPlanB Identity Resource FromPhase ToPhase
coerceDescriptorPlan = coerce

coerceProbePlan ::
    DependencyProbe Scope ProbePlanA Identity Resource ->
    DependencyProbe Scope ProbePlanB Identity Resource
coerceProbePlan = coerce

coerceSnapshotPlan ::
    DependencySnapshot Scope SnapshotPlanA ->
    DependencySnapshot Scope SnapshotPlanB
coerceSnapshotPlan = coerce

coercePreconditionsPlan ::
    OperationPreconditionSet Scope PreconditionsPlanA Identity Resource ->
    OperationPreconditionSet Scope PreconditionsPlanB Identity Resource
coercePreconditionsPlan = coerce

coercePreparedOperationPlan ::
    PreparedOperation
        Scope
        PreparedOperationPlanA
        Identity
        Resource
        Operation
        CallDigest
        Attempt
        JournalVersion ->
    PreparedOperation
        Scope
        PreparedOperationPlanB
        Identity
        Resource
        Operation
        CallDigest
        Attempt
        JournalVersion
coercePreparedOperationPlan = coerce

coercePreparedPreconditionsPlan ::
    PreparedPreconditions
        Scope
        PreparedPreconditionsPlanA
        Identity
        Resource
        Operation
        CallDigest
        Attempt
        JournalVersion ->
    PreparedPreconditions
        Scope
        PreparedPreconditionsPlanB
        Identity
        Resource
        Operation
        CallDigest
        Attempt
        JournalVersion
coercePreparedPreconditionsPlan = coerce

coerceResultPlan ::
    ReconcileResult Scope ResultPlanA Identity Resource ToPhase ->
    ReconcileResult Scope ResultPlanB Identity Resource ToPhase
coerceResultPlan = coerce

coerceJournalRecordPlan ::
    VerifiedJournalRecord Scope JournalRecordPlanA Identity Resource ->
    VerifiedJournalRecord Scope JournalRecordPlanB Identity Resource
coerceJournalRecordPlan = coerce

coerceCommitProofPlan ::
    PriorCommitProof Scope CommitProofPlanA Identity Resource ->
    PriorCommitProof Scope CommitProofPlanB Identity Resource
coerceCommitProofPlan = coerce

coerceTransitionPlan ::
    PhaseTransition Scope TransitionPlanA Identity Resource FromPhase ToPhase ->
    PhaseTransition Scope TransitionPlanB Identity Resource FromPhase ToPhase
coerceTransitionPlan = coerce

coerceVerifiedPhasePlan ::
    VerifiedAtPhase Scope VerifiedPhasePlanA Identity Resource ToPhase ->
    VerifiedAtPhase Scope VerifiedPhasePlanB Identity Resource ToPhase
coerceVerifiedPhasePlan = coerce

coerceAdvancePlan ::
    PhaseAdvance Scope AdvancePlanA Identity Resource ToPhase ->
    PhaseAdvance Scope AdvancePlanB Identity Resource ToPhase
coerceAdvancePlan = coerce
