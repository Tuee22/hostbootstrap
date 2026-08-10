module CoerceNormalActiveRecoveryBroker where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (NormalActiveRecovery)

data Scope
data SpecDigest
data PlanDigest
data PlanId
data BrokerA
data BrokerB

wrongBroker ::
    NormalActiveRecovery Scope SpecDigest PlanDigest PlanId BrokerA ->
    NormalActiveRecovery Scope SpecDigest PlanDigest PlanId BrokerB
wrongBroker = coerce
