module CrossDigestLeaseBinding where

import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Production)

data Project
data BrokerGeneration
data SpecDigestA
data PlanDigestA
data SpecDigestB
data PlanDigestB

-- The bound lease handed to the continuation has the verified snapshot's exact
-- digest pair; the caller cannot demand a different pair.
wrongDigests ::
    UnboundRunLease (Production Project) BrokerGeneration ->
    VerifiedPlanSnapshot (Production Project) SpecDigestA PlanDigestA ->
    (BoundRunLease (Production Project) SpecDigestB PlanDigestB BrokerGeneration -> IO ()) ->
    IO (Either LeaseConflict ())
wrongDigests lease snapshot use = bindRunLease lease snapshot use
