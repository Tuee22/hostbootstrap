module CrossRunLeaseBinding where

import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Harness)

data Project
data RunA
data RunB
data BrokerGeneration
data SpecDigest
data PlanDigest

-- Both values are Harness-scoped, but they name different generative runs.
wrongRun ::
    UnboundRunLease (Harness Project RunA) BrokerGeneration ->
    VerifiedPlanSnapshot (Harness Project RunB) SpecDigest PlanDigest ->
    IO (Either LeaseConflict ())
wrongRun lease snapshot =
    bindRunLease lease snapshot (\_ -> pure ())
