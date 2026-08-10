module CoerceVerifiedConfigHandoffRoles where

import Data.Coerce (coerce)
import HostBootstrap.Config.Schema (VerifiedConfigHandoff)

data ScopeA
data ScopeB
data PlanA
data PlanB
data BrokerA
data BrokerB
data ParentA
data ParentB
data ChildA
data ChildB
data ConfigA
data ConfigB
data VerbA
data VerbB
data PhaseA
data PhaseB

type Handoff scope plan broker parent child config verb phase =
    VerifiedConfigHandoff scope plan broker parent child config verb phase

wrongScope :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeB PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA
wrongScope = coerce

wrongPlan :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanB BrokerA ParentA ChildA ConfigA VerbA PhaseA
wrongPlan = coerce

wrongBroker :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanA BrokerB ParentA ChildA ConfigA VerbA PhaseA
wrongBroker = coerce

wrongParent :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanA BrokerA ParentB ChildA ConfigA VerbA PhaseA
wrongParent = coerce

wrongChild :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanA BrokerA ParentA ChildB ConfigA VerbA PhaseA
wrongChild = coerce

wrongConfig :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigB VerbA PhaseA
wrongConfig = coerce

wrongVerb :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbB PhaseA
wrongVerb = coerce

wrongPhase :: Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseA -> Handoff ScopeA PlanA BrokerA ParentA ChildA ConfigA VerbA PhaseB
wrongPhase = coerce
