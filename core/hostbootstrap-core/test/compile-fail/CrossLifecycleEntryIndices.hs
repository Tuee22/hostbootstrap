module CrossLifecycleEntryIndices where

import HostBootstrap.Authority (VerbDown, VerbUp)
import HostBootstrap.Command (LifecycleEntry)

data ScopeA
data ScopeB
data PlanA
data PlanB
data FrameA
data FrameB
data BrokerA
data BrokerB

needScope :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> ()
needScope _ = ()
crossScope :: LifecycleEntry ScopeB PlanA FrameA BrokerA VerbUp -> ()
crossScope = needScope

needPlan :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> ()
needPlan _ = ()
crossPlan :: LifecycleEntry ScopeA PlanB FrameA BrokerA VerbUp -> ()
crossPlan = needPlan

needFrame :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> ()
needFrame _ = ()
crossFrame :: LifecycleEntry ScopeA PlanA FrameB BrokerA VerbUp -> ()
crossFrame = needFrame

needBroker :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> ()
needBroker _ = ()
crossBroker :: LifecycleEntry ScopeA PlanA FrameA BrokerB VerbUp -> ()
crossBroker = needBroker

needVerb :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> ()
needVerb _ = ()
crossVerb :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbDown -> ()
crossVerb = needVerb
