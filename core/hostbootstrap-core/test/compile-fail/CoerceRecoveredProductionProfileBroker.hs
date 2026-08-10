module CoerceRecoveredProductionProfileBroker where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)

data Project
data SpecDigest
data PlanDigest
data PlanId
data BrokerA
data BrokerB

wrongBroker ::
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanId BrokerA ->
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanId BrokerB
wrongBroker = coerce
