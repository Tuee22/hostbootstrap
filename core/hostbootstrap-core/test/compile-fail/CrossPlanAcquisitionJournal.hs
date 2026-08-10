module CrossPlanAcquisitionJournal where

import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data Scope
data PlanA
data PlanB
data BrokerGeneration

-- A callback selected for PlanB cannot consume the journal admitted for
-- PlanA, independently of the nominal-role coercion boundary.
useWrongPlan ::
    (AcquisitionJournal Scope PlanB BrokerGeneration -> result) ->
    AcquisitionJournal Scope PlanA BrokerGeneration ->
    result
useWrongPlan use journal = use journal
