module CrossSpecProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeProjectUp)
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
    authorizeProjectUp root ProjectUp verified bound `seq` ()
