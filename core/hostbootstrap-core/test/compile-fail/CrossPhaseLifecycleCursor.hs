module CrossPhaseLifecycleCursor where

import HostBootstrap.Authority (ExecutePhase, PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeExecute ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp ExecutePhase ->
    ()
consumeExecute _ = ()

usePrepareAsExecute ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
usePrepareAsExecute cursor = consumeExecute cursor
