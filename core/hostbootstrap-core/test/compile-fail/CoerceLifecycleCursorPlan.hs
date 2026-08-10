module CoerceLifecycleCursorPlan where

import Data.Coerce (coerce)
import HostBootstrap.Authority (PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanA
data PlanB
data Frame
data BrokerGeneration

wrongPlan ::
    LifecycleCursor Scope PlanA Frame BrokerGeneration VerbUp PreparePhase ->
    LifecycleCursor Scope PlanB Frame BrokerGeneration VerbUp PreparePhase
wrongPlan = coerce
