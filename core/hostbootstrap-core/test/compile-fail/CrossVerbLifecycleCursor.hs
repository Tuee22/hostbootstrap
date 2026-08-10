module CrossVerbLifecycleCursor where

import HostBootstrap.Authority (PreparePhase, VerbDown, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeDown ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbDown PreparePhase ->
    ()
consumeDown _ = ()

useUpAsDown ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
useUpAsDown cursor = consumeDown cursor
