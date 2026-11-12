{- | The exact descriptor producer accepts the admitted plan's projected node,
never a raw authored step with the same surrounding plan and runtime indices.
-}
module RawStepAsExecutionSource where

import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution (StepExecution, StepRuntime)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.Reconcile (stepExecutionFor)
import HostBootstrap.Step (Step)

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope

rawStepSource ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    HostConfig ->
    StepRuntime Scope Plan ->
    Step ->
    StepExecution Scope Plan
rawStepSource plan cfg runtime step =
    stepExecutionFor plan cfg runtime step
