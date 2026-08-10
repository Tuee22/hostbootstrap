module ProductionProjectPlanAsHarnessChain where

import HostBootstrap.Authority (CommandAuthority, ExecutePhase, VerbUp)
import HostBootstrap.Chain (runChainFromFrame)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Mode (LifecycleCursor)
import HostBootstrap.Lift (SelfRef)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectScope (Harness, Production)
import HostBootstrap.Protected (ProtectedStore)

data Project
data Run
data Specification
data Plan
data Configuration
data Config scope
data Frame
data Broker

-- A Production plan cannot enter the direct Harness interpreter even when the
-- authority and cursor otherwise agree on every plan-local index.
wrongScope ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan (Production Project) Specification Plan Configuration Config ->
    CommandAuthority (Harness Project Run) Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor (Harness Project Run) Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongScope cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()
