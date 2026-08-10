module CoerceLifecycleCursorFrame where

import Data.Coerce (coerce)
import HostBootstrap.Authority (PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data FrameA
data FrameB
data BrokerGeneration

wrongFrame ::
    LifecycleCursor Scope PlanId FrameA BrokerGeneration VerbUp PreparePhase ->
    LifecycleCursor Scope PlanId FrameB BrokerGeneration VerbUp PreparePhase
wrongFrame = coerce
