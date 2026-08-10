module CoerceNormalActiveRecoveryDigest where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (NormalActiveRecovery)

data Scope
data SpecDigest
data DigestA
data DigestB
data PlanId
data BrokerGeneration

wrongDigest ::
    NormalActiveRecovery Scope SpecDigest DigestA PlanId BrokerGeneration ->
    NormalActiveRecovery Scope SpecDigest DigestB PlanId BrokerGeneration
wrongDigest = coerce
