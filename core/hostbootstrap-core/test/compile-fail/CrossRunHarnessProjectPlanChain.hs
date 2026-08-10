module CrossRunHarnessProjectPlanChain where

import HostBootstrap.Authority (CommandAuthority, ExecutePhase, VerbUp)
import HostBootstrap.Chain (runChainFromFrame)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Mode (LifecycleCursor)
import HostBootstrap.Lift (SelfRef)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectScope (Harness)
import HostBootstrap.Protected (ProtectedStore)

data Project
data RunA
data RunB
data Specification
data Plan
data Configuration
data Config scope
data Frame
data Broker

-- The run identity retained by a Harness plan cannot be substituted at its
-- direct interpreter boundary.
wrongRun ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan (Harness Project RunA) Specification Plan Configuration Config ->
    CommandAuthority (Harness Project RunB) Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor (Harness Project RunB) Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongRun cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()
