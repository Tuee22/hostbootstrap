module CrossBrokerProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeRootProject)
import HostBootstrap.Lifecycle.Mode
    ( BoundRunLease
    , VerifiedPlanSnapshot
    )
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )

data Scope
data BrokerA
data BrokerB
data SpecDigest
data PlanDigest
data PlanId

crossBroker ::
    RootInvocationAuthority Scope BrokerA VerbUp ->
    VerifiedPlanSnapshot Scope SpecDigest PlanDigest ->
    BoundPlanSnapshot Scope SpecDigest PlanDigest PlanId ->
    PlanDigestBinding Scope SpecDigest PlanDigest PlanId ->
    BoundRunLease Scope SpecDigest PlanDigest BrokerB ->
    ()
crossBroker root verified bound binding lease =
    authorizeRootProject root ProjectUp verified bound binding lease `seq` ()
