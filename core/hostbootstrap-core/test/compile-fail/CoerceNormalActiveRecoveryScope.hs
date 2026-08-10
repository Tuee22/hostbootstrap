module CoerceNormalActiveRecoveryScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (NormalActiveRecovery)

data ScopeA
data ScopeB
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

wrongScope ::
    NormalActiveRecovery ScopeA SpecDigest PlanDigest PlanId BrokerGeneration ->
    NormalActiveRecovery ScopeB SpecDigest PlanDigest PlanId BrokerGeneration
wrongScope = coerce
