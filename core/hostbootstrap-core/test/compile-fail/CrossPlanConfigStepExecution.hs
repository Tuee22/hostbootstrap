{- | The exact plan-owned producer accepts only a node projected by that same
plan and configuration admission.  Stable equality cannot substitute either
generative identity.
-}
module CrossPlanConfigStepExecution where

import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution
    ( StepExecution
    , StepRuntime
    )
import HostBootstrap.ProjectPlan
    ( PlannedStep
    , ProjectPlan
    )
import HostBootstrap.Reconcile (stepExecutionFor)

data Scope
data SpecificationDigest
data PlanA
data PlanB
data ConfigurationA
data ConfigurationB
data Configuration scope

crossPlan ::
    ProjectPlan Scope SpecificationDigest PlanA ConfigurationA Configuration ->
    HostConfig ->
    StepRuntime Scope PlanA ->
    PlannedStep Scope PlanB ConfigurationA (Configuration Scope) ->
    StepExecution Scope PlanA
crossPlan plan cfg runtime node =
    stepExecutionFor plan cfg runtime node

crossConfiguration ::
    ProjectPlan Scope SpecificationDigest PlanA ConfigurationA Configuration ->
    HostConfig ->
    StepRuntime Scope PlanA ->
    PlannedStep Scope PlanA ConfigurationB (Configuration Scope) ->
    StepExecution Scope PlanA
crossConfiguration plan cfg runtime node =
    stepExecutionFor plan cfg runtime node
