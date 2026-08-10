module CoerceVerifiedRecoveryHandoffRoles where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (VerifiedRecoveryHandoff)

data ScopeA
data ScopeB
data BrokerA
data BrokerB
data PlanA
data PlanB
data ParentA
data ParentB
data ChildA
data ChildB
data DigestA
data DigestB
data WireA
data WireB
data VerbA
data VerbB

type Handoff scope broker plan parent child digest wireId verb =
    VerifiedRecoveryHandoff scope broker plan parent child digest wireId verb

wrongScope :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeB BrokerA PlanA ParentA ChildA DigestA WireA VerbA
wrongScope = coerce

wrongBroker :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerB PlanA ParentA ChildA DigestA WireA VerbA
wrongBroker = coerce

wrongPlan :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerA PlanB ParentA ChildA DigestA WireA VerbA
wrongPlan = coerce

wrongParent :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerA PlanA ParentB ChildA DigestA WireA VerbA
wrongParent = coerce

wrongChild :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerA PlanA ParentA ChildB DigestA WireA VerbA
wrongChild = coerce

wrongDigest :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerA PlanA ParentA ChildA DigestB WireA VerbA
wrongDigest = coerce

wrongWire :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireB VerbA
wrongWire = coerce

wrongVerb :: Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbA -> Handoff ScopeA BrokerA PlanA ParentA ChildA DigestA WireA VerbB
wrongVerb = coerce
