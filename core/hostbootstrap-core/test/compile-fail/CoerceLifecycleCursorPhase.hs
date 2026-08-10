module CoerceLifecycleCursorPhase where

import Data.Coerce (coerce)
import HostBootstrap.Authority (ExecutePhase, PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration

wrongPhase ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp ExecutePhase
wrongPhase = coerce
