module CoerceLifecycleCursorBroker where

import Data.Coerce (coerce)
import HostBootstrap.Authority (PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerA
data BrokerB

wrongBroker ::
    LifecycleCursor Scope PlanId Frame BrokerA VerbUp PreparePhase ->
    LifecycleCursor Scope PlanId Frame BrokerB VerbUp PreparePhase
wrongBroker = coerce
