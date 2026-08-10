module CrossBrokerRecoveredProductionProfile where

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
data PlanId
data BrokerA
data BrokerB

-- The root, mode, and bound lease fix BrokerA. Recovery evidence indexed by
-- BrokerB cannot be substituted into that package.
wrongBroker ::
    RootInvocationAuthority (Production Project) BrokerA VerbUp ->
    ProjectModeLease Project ProductionMode BrokerA ->
    BoundRunLease (Production Project) SpecDigest PlanDigest BrokerA ->
    VerifiedPlanSnapshot (Production Project) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecDigest PlanDigest PlanId ->
    PlanDigestBinding (Production Project) SpecDigest PlanDigest PlanId ->
    BoundInvocationRecovery
        (Production Project)
        SpecDigest
        PlanDigest
        PlanId
        BrokerB ->
    Either ModeError ()
wrongBroker root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        (const ())
