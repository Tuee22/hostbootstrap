module CoerceAcquisitionJournalScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data ScopeA
data ScopeB
data PlanId
data BrokerGeneration

wrongScope ::
    AcquisitionJournal ScopeA PlanId BrokerGeneration ->
    AcquisitionJournal ScopeB PlanId BrokerGeneration
wrongScope = coerce
