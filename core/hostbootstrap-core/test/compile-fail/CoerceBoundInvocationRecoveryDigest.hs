module CoerceBoundInvocationRecoveryDigest where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (BoundInvocationRecovery)

data Scope
data SpecDigest
data DigestA
data DigestB
data PlanId
data BrokerGeneration

wrongDigest ::
    BoundInvocationRecovery Scope SpecDigest DigestA PlanId BrokerGeneration ->
    BoundInvocationRecovery Scope SpecDigest DigestB PlanId BrokerGeneration
wrongDigest = coerce
