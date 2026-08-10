{- | The exact execution-descriptor producer has no compatibility overload: a
legacy lifecycle plan and a raw authored step cannot stand in for the matching
indexed project plan and its projected node.
-}
module CompatibilityInputsAsStepExecutionSource where

import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution
    ( StepExecution
    , StepRuntime
    )
import HostBootstrap.ProjectPlan
    ( PlannedStep
    , ProjectPlan
    )
import HostBootstrap.Reconcile
    ( LifecyclePlan
    , stepExecutionFor
    )
import HostBootstrap.Step (Step)

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope

lifecyclePlanSource ::
    LifecyclePlan Scope Plan ->
    HostConfig ->
    StepRuntime Scope Plan ->
    PlannedStep Scope Plan ConfigurationIdentity (Configuration Scope) ->
    StepExecution Scope Plan
lifecyclePlanSource lifecycle cfg runtime node =
    stepExecutionFor lifecycle cfg runtime node

rawStepSource ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    HostConfig ->
    StepRuntime Scope Plan ->
    Step ->
    StepExecution Scope Plan
rawStepSource plan cfg runtime step =
    stepExecutionFor plan cfg runtime step
