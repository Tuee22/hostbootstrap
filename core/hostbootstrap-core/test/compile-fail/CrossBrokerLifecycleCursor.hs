module CrossBrokerLifecycleCursor where

import HostBootstrap.Authority (PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerA
data BrokerB

consumeBrokerB ::
    LifecycleCursor Scope PlanId Frame BrokerB VerbUp PreparePhase ->
    ()
consumeBrokerB _ = ()

useWrongBroker ::
    LifecycleCursor Scope PlanId Frame BrokerA VerbUp PreparePhase ->
    ()
useWrongBroker cursor = consumeBrokerB cursor
