module CoerceRecoveredProductionProfileProject where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)

data ProjectA
data ProjectB
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

wrongProject ::
    RecoveredProductionLifecycleProfile ProjectA SpecDigest PlanDigest PlanId BrokerGeneration ->
    RecoveredProductionLifecycleProfile ProjectB SpecDigest PlanDigest PlanId BrokerGeneration
wrongProject = coerce
