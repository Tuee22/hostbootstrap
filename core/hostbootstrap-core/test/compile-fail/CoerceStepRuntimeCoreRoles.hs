module CoerceStepRuntimeCoreRoles where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Execution.Core (StepRuntimeCore)

newtype RuntimeCoreScopeA = RuntimeCoreScopeA Int
newtype RuntimeCoreScopeB = RuntimeCoreScopeB Int
newtype RuntimeCorePlanA = RuntimeCorePlanA Int
newtype RuntimeCorePlanB = RuntimeCorePlanB Int
newtype RuntimeCoreGateA = RuntimeCoreGateA Int
newtype RuntimeCoreGateB = RuntimeCoreGateB Int
newtype RuntimeCorePayloadA = RuntimeCorePayloadA Int
newtype RuntimeCorePayloadB = RuntimeCorePayloadB Int

coerceCoreRuntimeScope ::
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanA RuntimeCoreGateA RuntimeCorePayloadA ->
    StepRuntimeCore RuntimeCoreScopeB RuntimeCorePlanA RuntimeCoreGateA RuntimeCorePayloadA
coerceCoreRuntimeScope = coerce

coerceCoreRuntimePlan ::
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanA RuntimeCoreGateA RuntimeCorePayloadA ->
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanB RuntimeCoreGateA RuntimeCorePayloadA
coerceCoreRuntimePlan = coerce

coerceCoreRuntimeGate ::
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanA RuntimeCoreGateA RuntimeCorePayloadA ->
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanA RuntimeCoreGateB RuntimeCorePayloadA
coerceCoreRuntimeGate = coerce

coerceCoreRuntimePayload ::
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanA RuntimeCoreGateA RuntimeCorePayloadA ->
    StepRuntimeCore RuntimeCoreScopeA RuntimeCorePlanA RuntimeCoreGateA RuntimeCorePayloadB
coerceCoreRuntimePayload = coerce
