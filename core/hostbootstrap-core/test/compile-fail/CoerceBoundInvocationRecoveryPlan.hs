module CoerceBoundInvocationRecoveryPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (BoundInvocationRecovery)

data Scope
data SpecDigest
data PlanDigest
data PlanA
data PlanB
data BrokerGeneration

wrongPlan ::
    BoundInvocationRecovery Scope SpecDigest PlanDigest PlanA BrokerGeneration ->
    BoundInvocationRecovery Scope SpecDigest PlanDigest PlanB BrokerGeneration
wrongPlan = coerce
