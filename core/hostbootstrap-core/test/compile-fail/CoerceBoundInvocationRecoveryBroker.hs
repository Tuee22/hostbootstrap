module CoerceBoundInvocationRecoveryBroker where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (BoundInvocationRecovery)

data Scope
data SpecDigest
data PlanDigest
data PlanId
data BrokerA
data BrokerB

wrongBroker ::
    BoundInvocationRecovery Scope SpecDigest PlanDigest PlanId BrokerA ->
    BoundInvocationRecovery Scope SpecDigest PlanDigest PlanId BrokerB
wrongBroker = coerce
