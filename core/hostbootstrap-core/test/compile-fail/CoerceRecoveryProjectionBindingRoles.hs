module CoerceRecoveryProjectionBindingRoles where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (RecoveryProjectionBinding)

data ScopeA
data ScopeB
data BrokerA
data BrokerB
data VerbA
data VerbB
data PlanA
data PlanB
data ParentA
data ParentB
data ChildA
data ChildB
data DigestA
data DigestB

type Binding scope broker verb plan parent child digest =
    RecoveryProjectionBinding scope broker verb plan parent child digest

wrongScope :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeB BrokerA VerbA PlanA ParentA ChildA DigestA
wrongScope = coerce

wrongBroker :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeA BrokerB VerbA PlanA ParentA ChildA DigestA
wrongBroker = coerce

wrongVerb :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeA BrokerA VerbB PlanA ParentA ChildA DigestA
wrongVerb = coerce

wrongPlan :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeA BrokerA VerbA PlanB ParentA ChildA DigestA
wrongPlan = coerce

wrongParent :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeA BrokerA VerbA PlanA ParentB ChildA DigestA
wrongParent = coerce

wrongChild :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeA BrokerA VerbA PlanA ParentA ChildB DigestA
wrongChild = coerce

wrongDigest :: Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Binding ScopeA BrokerA VerbA PlanA ParentA ChildA DigestB
wrongDigest = coerce
