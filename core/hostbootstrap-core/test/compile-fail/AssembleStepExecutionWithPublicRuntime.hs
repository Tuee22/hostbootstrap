module AssembleStepExecutionWithPublicRuntime where

import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution (ResourceCarrier, StepExecution, newStepRuntime)
import HostBootstrap.ProjectPlan (PlannedStep, ProjectPlan)
import HostBootstrap.Reconcile (stepExecutionFor)

assemble ::
    ProjectPlan scope specDigest planId configId cfg ->
    HostConfig ->
    ResourceCarrier scope planId ->
    PlannedStep scope planId configId (cfg scope) ->
    IO (StepExecution scope planId)
assemble plan host carrier planned = do
    runtime <- newStepRuntime carrier
    pure (stepExecutionFor plan host runtime planned)
