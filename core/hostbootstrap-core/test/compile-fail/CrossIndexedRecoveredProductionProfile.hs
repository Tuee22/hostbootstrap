module CrossIndexedRecoveredProductionProfile where

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
data SpecA
data SpecB
data PlanDigest
data PlanId
data BrokerGeneration

-- The bound tuple fixes SpecA. Recovery evidence indexed by SpecB cannot be
-- substituted, even when every other identity agrees.
wrongSpec ::
    RootInvocationAuthority (Production Project) BrokerGeneration VerbUp ->
    ProjectModeLease Project ProductionMode BrokerGeneration ->
    BoundRunLease (Production Project) SpecA PlanDigest BrokerGeneration ->
    VerifiedPlanSnapshot (Production Project) SpecA PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecA PlanDigest PlanId ->
    PlanDigestBinding (Production Project) SpecA PlanDigest PlanId ->
    BoundInvocationRecovery
        (Production Project)
        SpecB
        PlanDigest
        PlanId
        BrokerGeneration ->
    Either ModeError ()
wrongSpec root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        (const ())
