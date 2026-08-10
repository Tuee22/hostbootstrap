module CoerceRecoveredProductionProfileSpec where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)

data Project
data SpecA
data SpecB
data PlanDigest
data PlanId
data BrokerGeneration

wrongSpec ::
    RecoveredProductionLifecycleProfile Project SpecA PlanDigest PlanId BrokerGeneration ->
    RecoveredProductionLifecycleProfile Project SpecB PlanDigest PlanId BrokerGeneration
wrongSpec = coerce
