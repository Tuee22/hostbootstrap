module CoerceRecoveredProductionProfileDigest where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)

data Project
data SpecDigest
data DigestA
data DigestB
data PlanId
data BrokerGeneration

wrongDigest ::
    RecoveredProductionLifecycleProfile Project SpecDigest DigestA PlanId BrokerGeneration ->
    RecoveredProductionLifecycleProfile Project SpecDigest DigestB PlanId BrokerGeneration
wrongDigest = coerce
