module CoerceRecoveredProductionProfilePlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)

data Project
data SpecDigest
data PlanDigest
data PlanA
data PlanB
data BrokerGeneration

wrongPlan ::
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanA BrokerGeneration ->
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanB BrokerGeneration
wrongPlan = coerce
