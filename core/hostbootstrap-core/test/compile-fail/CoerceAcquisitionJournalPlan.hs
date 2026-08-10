module CoerceAcquisitionJournalPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data Scope
data PlanA
data PlanB
data BrokerGeneration

wrongPlan ::
    AcquisitionJournal Scope PlanA BrokerGeneration ->
    AcquisitionJournal Scope PlanB BrokerGeneration
wrongPlan = coerce
