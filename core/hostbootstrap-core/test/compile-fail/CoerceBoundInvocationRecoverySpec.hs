module CoerceBoundInvocationRecoverySpec where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (BoundInvocationRecovery)

data Scope
data SpecA
data SpecB
data PlanDigest
data PlanId
data BrokerGeneration

wrongSpec ::
    BoundInvocationRecovery Scope SpecA PlanDigest PlanId BrokerGeneration ->
    BoundInvocationRecovery Scope SpecB PlanDigest PlanId BrokerGeneration
wrongSpec = coerce
