module CoerceRecoveryWireGrantRoles where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (RecoveryWireGrant)

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

type Grant scope broker verb plan parent child digest =
    RecoveryWireGrant scope broker verb plan parent child digest

wrongScope :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeB BrokerA VerbA PlanA ParentA ChildA DigestA
wrongScope = coerce

wrongBroker :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeA BrokerB VerbA PlanA ParentA ChildA DigestA
wrongBroker = coerce

wrongVerb :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeA BrokerA VerbB PlanA ParentA ChildA DigestA
wrongVerb = coerce

wrongPlan :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeA BrokerA VerbA PlanB ParentA ChildA DigestA
wrongPlan = coerce

wrongParent :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeA BrokerA VerbA PlanA ParentB ChildA DigestA
wrongParent = coerce

wrongChild :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeA BrokerA VerbA PlanA ParentA ChildB DigestA
wrongChild = coerce

wrongDigest :: Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestA -> Grant ScopeA BrokerA VerbA PlanA ParentA ChildA DigestB
wrongDigest = coerce
