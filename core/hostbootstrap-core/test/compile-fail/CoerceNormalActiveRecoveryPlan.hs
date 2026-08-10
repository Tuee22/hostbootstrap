module CoerceNormalActiveRecoveryPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (NormalActiveRecovery)

data Scope
data SpecDigest
data PlanDigest
data PlanA
data PlanB
data BrokerGeneration

wrongPlan ::
    NormalActiveRecovery Scope SpecDigest PlanDigest PlanA BrokerGeneration ->
    NormalActiveRecovery Scope SpecDigest PlanDigest PlanB BrokerGeneration
wrongPlan = coerce
