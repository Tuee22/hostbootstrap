module CoerceBoundInvocationRecoveryScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (BoundInvocationRecovery)

data ScopeA
data ScopeB
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

wrongScope ::
    BoundInvocationRecovery ScopeA SpecDigest PlanDigest PlanId BrokerGeneration ->
    BoundInvocationRecovery ScopeB SpecDigest PlanDigest PlanId BrokerGeneration
wrongScope = coerce
