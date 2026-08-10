module CrossPlanIdRecoveredProductionProfile where

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
data PlanDigest
data PlanA
data PlanB
data BrokerGeneration

-- The bound snapshot and digest binding fix PlanA. Recovery evidence indexed
-- by PlanB cannot select another local recovery identity.
wrongPlanId ::
    RootInvocationAuthority (Production Project) BrokerGeneration VerbUp ->
    ProjectModeLease Project ProductionMode BrokerGeneration ->
    BoundRunLease (Production Project) SpecDigest PlanDigest BrokerGeneration ->
    VerifiedPlanSnapshot (Production Project) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecDigest PlanDigest PlanA ->
    PlanDigestBinding (Production Project) SpecDigest PlanDigest PlanA ->
    BoundInvocationRecovery
        (Production Project)
        SpecDigest
        PlanDigest
        PlanB
        BrokerGeneration ->
    Either ModeError ()
wrongPlanId root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        (const ())
