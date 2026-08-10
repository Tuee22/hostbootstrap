module CrossPlanProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeProjectUp)
import HostBootstrap.Lifecycle.Mode (VerifiedPlanSnapshot)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )

data Scope
data BrokerGeneration
data SpecDigest
data PlanDigest
data PlanA
data PlanB

crossPlan ::
    RootInvocationAuthority Scope BrokerGeneration VerbUp ->
    VerifiedPlanSnapshot Scope SpecDigest PlanDigest ->
    BoundPlanSnapshot Scope SpecDigest PlanDigest PlanA ->
    PlanDigestBinding Scope SpecDigest PlanDigest PlanB ->
    ()
crossPlan root verified bound binding =
    authorizeProjectUp root ProjectUp verified bound binding `seq` ()
