module CoerceNormalActiveRecoverySpec where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (NormalActiveRecovery)

data Scope
data SpecA
data SpecB
data PlanDigest
data PlanId
data BrokerGeneration

wrongSpec ::
    NormalActiveRecovery Scope SpecA PlanDigest PlanId BrokerGeneration ->
    NormalActiveRecovery Scope SpecB PlanDigest PlanId BrokerGeneration
wrongSpec = coerce
