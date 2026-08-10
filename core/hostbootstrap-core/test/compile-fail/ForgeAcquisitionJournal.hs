module ForgeAcquisitionJournal where

import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data Scope
data PlanId
data BrokerGeneration

-- Acquisition journals are minted only after the public plan-bound opener has
-- revalidated all live protected evidence; there is no constructor to call.
forgedJournal :: AcquisitionJournal Scope PlanId BrokerGeneration
forgedJournal = AcquisitionJournal
