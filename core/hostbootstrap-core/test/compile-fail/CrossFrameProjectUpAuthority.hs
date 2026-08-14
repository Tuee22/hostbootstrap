module CrossFrameProjectUpAuthority where

import HostBootstrap.Authority
    ( PreparePhase
    , ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeRootProject)
import HostBootstrap.Lifecycle.Mode
    ( AcquisitionJournal
    , BoundRunLease
    , LifecycleCursor
    , VerifiedPlanSnapshot
    )
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )

data Scope
data BrokerGeneration
data SpecDigest
data PlanDigest
data PlanId
data ConfigId
data FrameA
data FrameB
data Configuration scope

crossFrame ::
    RootInvocationAuthority Scope BrokerGeneration VerbUp ->
    VerifiedPlanSnapshot Scope SpecDigest PlanDigest ->
    BoundPlanSnapshot Scope SpecDigest PlanDigest PlanId ->
    PlanDigestBinding Scope SpecDigest PlanDigest PlanId ->
    BoundRunLease Scope SpecDigest PlanDigest BrokerGeneration ->
    ProjectPlan Scope SpecDigest PlanId ConfigId Configuration ->
    AcquisitionJournal Scope PlanId BrokerGeneration ->
    LifecycleCursor Scope PlanId FrameA BrokerGeneration VerbUp PreparePhase ->
    ValidatedLifecycleContext Scope SpecDigest PlanId ConfigId FrameB ->
    ()
crossFrame root verified bound binding lease plan journal cursor lifecycleContext =
    authorizeRootProject
        root
        ProjectUp
        verified
        bound
        binding
        lease
        plan
        journal
        cursor
        lifecycleContext
        `seq` ()
