module CoerceAcquisitionJournalBroker where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data Scope
data PlanId
data BrokerA
data BrokerB

wrongBroker ::
    AcquisitionJournal Scope PlanId BrokerA ->
    AcquisitionJournal Scope PlanId BrokerB
wrongBroker = coerce
