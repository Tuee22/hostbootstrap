module CoerceLifecycleCursorVerb where

import Data.Coerce (coerce)
import HostBootstrap.Authority (PreparePhase, VerbDown, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration

wrongVerb ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbDown PreparePhase
wrongVerb = coerce
