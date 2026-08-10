module CrossFrameLifecycleCursor where

import HostBootstrap.Authority (PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data FrameA
data FrameB
data BrokerGeneration

consumeFrameB ::
    LifecycleCursor Scope PlanId FrameB BrokerGeneration VerbUp PreparePhase ->
    ()
consumeFrameB _ = ()

useWrongFrame ::
    LifecycleCursor Scope PlanId FrameA BrokerGeneration VerbUp PreparePhase ->
    ()
useWrongFrame cursor = consumeFrameB cursor
