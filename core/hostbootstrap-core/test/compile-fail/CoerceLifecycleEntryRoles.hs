module CoerceLifecycleEntryRoles where

import Data.Coerce (coerce)
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

coerceScope :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> LifecycleEntry ScopeB PlanA FrameA BrokerA VerbUp
coerceScope = coerce

coercePlan :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> LifecycleEntry ScopeA PlanB FrameA BrokerA VerbUp
coercePlan = coerce

coerceFrame :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> LifecycleEntry ScopeA PlanA FrameB BrokerA VerbUp
coerceFrame = coerce

coerceBroker :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> LifecycleEntry ScopeA PlanA FrameA BrokerB VerbUp
coerceBroker = coerce

coerceVerb :: LifecycleEntry ScopeA PlanA FrameA BrokerA VerbUp -> LifecycleEntry ScopeA PlanA FrameA BrokerA VerbDown
coerceVerb = coerce
