{- | Every generative role on the execution descriptor, runtime, and carrier is
nominal.  Equal runtime representations cannot relabel either the admitted
project scope or the exact plan whose resources they carry.
-}
module CoerceExecutionRoles where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Execution
    ( ResourceCarrier
    , StepExecution
    , StepRuntime
    )

data ExecutionScopeA
data ExecutionScopeB
data ExecutionPlanA
data ExecutionPlanB
data RuntimeScopeA
data RuntimeScopeB
data RuntimePlanA
data RuntimePlanB
data CarrierScopeA
data CarrierScopeB
data CarrierPlanA
data CarrierPlanB

coerceStepExecutionScope ::
    StepExecution ExecutionScopeA ExecutionPlanA ->
    StepExecution ExecutionScopeB ExecutionPlanA
coerceStepExecutionScope = coerce

coerceStepExecutionPlan ::
    StepExecution ExecutionScopeA ExecutionPlanA ->
    StepExecution ExecutionScopeA ExecutionPlanB
coerceStepExecutionPlan = coerce

coerceStepRuntimeScope ::
    StepRuntime RuntimeScopeA RuntimePlanA ->
    StepRuntime RuntimeScopeB RuntimePlanA
coerceStepRuntimeScope = coerce

coerceStepRuntimePlan ::
    StepRuntime RuntimeScopeA RuntimePlanA ->
    StepRuntime RuntimeScopeA RuntimePlanB
coerceStepRuntimePlan = coerce

coerceResourceCarrierScope ::
    ResourceCarrier CarrierScopeA CarrierPlanA ->
    ResourceCarrier CarrierScopeB CarrierPlanA
coerceResourceCarrierScope = coerce

coerceResourceCarrierPlan ::
    ResourceCarrier CarrierScopeA CarrierPlanA ->
    ResourceCarrier CarrierScopeA CarrierPlanB
coerceResourceCarrierPlan = coerce
