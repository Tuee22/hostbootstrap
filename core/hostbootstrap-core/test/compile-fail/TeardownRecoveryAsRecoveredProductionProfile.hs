module TeardownRecoveryAsRecoveredProductionProfile where

import HostBootstrap.Authority
    ( RootInvocationAuthority
    , VerbDestroy
    , VerbUp
    )
import HostBootstrap.Lifecycle.Mode
    ( BoundInvocationRecovery
    , BoundRunLease
    , ModeError
    , ProductionMode
    , ProjectModeLease
    , VerifiedPlanSnapshot
    , withRecoveredProductionLifecycleProfile
    )
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )
import HostBootstrap.ProjectScope (Production)

data Project
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

-- A teardown root cannot open the ProjectUp-only recovered profile.
wrongVerb ::
    RootInvocationAuthority (Production Project) BrokerGeneration VerbDestroy ->
    ProjectModeLease Project ProductionMode BrokerGeneration ->
    BoundRunLease (Production Project) SpecDigest PlanDigest BrokerGeneration ->
    VerifiedPlanSnapshot (Production Project) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecDigest PlanDigest PlanId ->
    PlanDigestBinding (Production Project) SpecDigest PlanDigest PlanId ->
    BoundInvocationRecovery
        (Production Project)
        SpecDigest
        PlanDigest
        PlanId
        BrokerGeneration ->
    Either ModeError ()
wrongVerb root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        (const ())
