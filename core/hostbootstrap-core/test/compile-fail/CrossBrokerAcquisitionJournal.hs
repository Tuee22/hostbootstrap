module CrossBrokerAcquisitionJournal where

import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data Scope
data PlanId
data BrokerA
data BrokerB

-- A callback selected for BrokerB cannot consume the journal admitted under
-- BrokerA, independently of the nominal-role coercion boundary.
useWrongBroker ::
    (AcquisitionJournal Scope PlanId BrokerB -> result) ->
    AcquisitionJournal Scope PlanId BrokerA ->
    result
useWrongBroker use journal = use journal
