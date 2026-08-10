module ForgeBoundInvocationRecovery where

import HostBootstrap.Lifecycle.Mode (BoundInvocationRecovery)

data Scope
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration

forgedRecovery ::
    BoundInvocationRecovery Scope SpecDigest PlanDigest PlanId BrokerGeneration
forgedRecovery = BoundInvocationRecovery
