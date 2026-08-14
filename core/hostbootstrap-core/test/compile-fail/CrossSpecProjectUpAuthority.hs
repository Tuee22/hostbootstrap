module CrossSpecProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeRootProject)
import HostBootstrap.Lifecycle.Mode (VerifiedPlanSnapshot)
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)

data Scope
data BrokerGeneration
data SpecA
data SpecB
data PlanDigest
data PlanId

crossSpec ::
    RootInvocationAuthority Scope BrokerGeneration VerbUp ->
    VerifiedPlanSnapshot Scope SpecA PlanDigest ->
    BoundPlanSnapshot Scope SpecB PlanDigest PlanId ->
    ()
crossSpec root verified bound =
    authorizeRootProject root ProjectUp verified bound `seq` ()
