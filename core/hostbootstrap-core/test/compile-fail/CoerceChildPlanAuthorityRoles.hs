module CoerceChildPlanAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Construct (ChildPlanAuthority)

data ScopeA
data ScopeB
data SpecA
data SpecB
data DigestA
data DigestB
data BrokerA
data BrokerB
data ParentA
data ParentB
data ChildA
data ChildB
data PlanA
data PlanB
data ConfigA
data ConfigB
data VerbA
data VerbB
data PhaseA
data PhaseB

type Authority scope spec digest broker parent child plan config verb phase =
    ChildPlanAuthority scope spec digest broker parent child plan config verb phase

wrongScope :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeB SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA
wrongScope = coerce

wrongSpec :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecB DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA
wrongSpec = coerce

wrongDigest :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestB BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA
wrongDigest = coerce

wrongBroker :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerB ParentA ChildA PlanA ConfigA VerbA PhaseA
wrongBroker = coerce

wrongParent :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerA ParentB ChildA PlanA ConfigA VerbA PhaseA
wrongParent = coerce

wrongChild :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerA ParentA ChildB PlanA ConfigA VerbA PhaseA
wrongChild = coerce

wrongPlan :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanB ConfigA VerbA PhaseA
wrongPlan = coerce

wrongConfig :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigB VerbA PhaseA
wrongConfig = coerce

wrongVerb :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbB PhaseA
wrongVerb = coerce

wrongPhase :: Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseA -> Authority ScopeA SpecA DigestA BrokerA ParentA ChildA PlanA ConfigA VerbA PhaseB
wrongPhase = coerce
