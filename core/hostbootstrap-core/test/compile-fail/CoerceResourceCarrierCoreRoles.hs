module CoerceResourceCarrierCoreRoles where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Execution.Core (ResourceCarrierCore)

newtype CoreScopeA = CoreScopeA Int
newtype CoreScopeB = CoreScopeB Int
newtype CorePlanA = CorePlanA Int
newtype CorePlanB = CorePlanB Int
newtype CorePayloadA = CorePayloadA Int
newtype CorePayloadB = CorePayloadB Int

coerceCoreScope ::
    ResourceCarrierCore CoreScopeA CorePlanA CorePayloadA ->
    ResourceCarrierCore CoreScopeB CorePlanA CorePayloadA
coerceCoreScope = coerce

coerceCorePlan ::
    ResourceCarrierCore CoreScopeA CorePlanA CorePayloadA ->
    ResourceCarrierCore CoreScopeA CorePlanB CorePayloadA
coerceCorePlan = coerce

coerceCorePayload ::
    ResourceCarrierCore CoreScopeA CorePlanA CorePayloadA ->
    ResourceCarrierCore CoreScopeA CorePlanA CorePayloadB
coerceCorePayload = coerce
