module ForgeRecoveredProductionLifecycleProfile where

import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)

data Project
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

-- Only the exact recovered Production opener may mint this profile.
forgedProfile ::
    RecoveredProductionLifecycleProfile
        Project
        SpecDigest
        PlanDigest
        PlanId
        BrokerGeneration
forgedProfile = RecoveredProductionLifecycleProfile
