module HarnessRecoveryAsRecoveredProductionProfile where

import HostBootstrap.Authority (RootInvocationAuthority, VerbUp)
import HostBootstrap.Lifecycle.Mode
    ( BoundInvocationRecovery
    , BoundRunLease
    , HarnessMode
    , ModeError
    , ProjectModeLease
    , VerifiedPlanSnapshot
    , withRecoveredProductionLifecycleProfile
    )
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

-- Harness evidence cannot inhabit any input of the recovered Production
-- profile opener, even when all of its own indices agree exactly.
wrongScope ::
    RootInvocationAuthority (Harness Project Run) BrokerGeneration VerbUp ->
    ProjectModeLease Project (HarnessMode Run) BrokerGeneration ->
    BoundRunLease (Harness Project Run) SpecDigest PlanDigest BrokerGeneration ->
    VerifiedPlanSnapshot (Harness Project Run) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Harness Project Run) SpecDigest PlanDigest PlanId ->
    PlanDigestBinding (Harness Project Run) SpecDigest PlanDigest PlanId ->
    BoundInvocationRecovery
        (Harness Project Run)
        SpecDigest
        PlanDigest
        PlanId
        BrokerGeneration ->
    Either ModeError ()
wrongScope root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        (const ())
