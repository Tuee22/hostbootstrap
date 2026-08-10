module ProductionLeaseAsHarnessSnapshot where

import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data BrokerGeneration
data SpecDigest
data PlanDigest

-- Binding requires one exact lifecycle scope; a Production lease cannot consume
-- a snapshot verified for a Harness run.
wrongScope ::
    UnboundRunLease (Production Project) BrokerGeneration ->
    VerifiedPlanSnapshot (Harness Project Run) SpecDigest PlanDigest ->
    IO (Either LeaseConflict ())
wrongScope lease snapshot =
    bindRunLease lease snapshot (\_ -> pure ())
