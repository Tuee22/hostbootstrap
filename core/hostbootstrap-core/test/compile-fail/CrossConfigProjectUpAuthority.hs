module CrossConfigProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeProjectUp)
import HostBootstrap.Lifecycle.Mode
    ( AcquisitionJournal
    , BoundRunLease
    , VerifiedPlanSnapshot
    )
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (ProjectFrame)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )

data Scope
data BrokerGeneration
data SpecDigest
data PlanDigest
data PlanId
data ConfigA
data ConfigB
data Frame
data Configuration scope

crossConfig ::
    RootInvocationAuthority Scope BrokerGeneration VerbUp ->
    VerifiedPlanSnapshot Scope SpecDigest PlanDigest ->
    BoundPlanSnapshot Scope SpecDigest PlanDigest PlanId ->
    PlanDigestBinding Scope SpecDigest PlanDigest PlanId ->
    BoundRunLease Scope SpecDigest PlanDigest BrokerGeneration ->
    ProjectPlan Scope SpecDigest PlanId ConfigA Configuration ->
    AcquisitionJournal Scope PlanId BrokerGeneration ->
    ProjectFrame Scope SpecDigest PlanId ConfigB Frame ->
    ()
crossConfig root verified bound binding lease plan journal frame =
    authorizeProjectUp
        root
        ProjectUp
        verified
        bound
        binding
        lease
        plan
        journal
        frame
        `seq` ()
