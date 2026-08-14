module CrossPlanDigestProjectUpAuthority where

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
data SpecDigest
data PlanDigestA
data PlanDigestB
data PlanId

crossPlanDigest ::
    RootInvocationAuthority Scope BrokerGeneration VerbUp ->
    VerifiedPlanSnapshot Scope SpecDigest PlanDigestA ->
    BoundPlanSnapshot Scope SpecDigest PlanDigestB PlanId ->
    ()
crossPlanDigest root verified bound =
    authorizeRootProject root ProjectUp verified bound `seq` ()
