module CrossPlanDigestRecoveredProductionProfile where

import HostBootstrap.Authority (RootInvocationAuthority, VerbUp)
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
data DigestA
data DigestB
data PlanId
data BrokerGeneration

-- The first six arguments fix DigestA. Recovery evidence indexed by DigestB
-- cannot be substituted into the recovered-profile opener.
wrongPlanDigest ::
    RootInvocationAuthority (Production Project) BrokerGeneration VerbUp ->
    ProjectModeLease Project ProductionMode BrokerGeneration ->
    BoundRunLease (Production Project) SpecDigest DigestA BrokerGeneration ->
    VerifiedPlanSnapshot (Production Project) SpecDigest DigestA ->
    BoundPlanSnapshot (Production Project) SpecDigest DigestA PlanId ->
    PlanDigestBinding (Production Project) SpecDigest DigestA PlanId ->
    BoundInvocationRecovery
        (Production Project)
        SpecDigest
        DigestB
        PlanId
        BrokerGeneration ->
    Either ModeError ()
wrongPlanDigest root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        (const ())
