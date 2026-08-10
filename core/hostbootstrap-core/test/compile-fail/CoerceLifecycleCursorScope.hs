module CoerceLifecycleCursorScope where

import Data.Coerce (coerce)
import HostBootstrap.Authority (PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data ScopeA
data ScopeB
data PlanId
data Frame
data BrokerGeneration

wrongScope ::
    LifecycleCursor ScopeA PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    LifecycleCursor ScopeB PlanId Frame BrokerGeneration VerbUp PreparePhase
wrongScope = coerce
