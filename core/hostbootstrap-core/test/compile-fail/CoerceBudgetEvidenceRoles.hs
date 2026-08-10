{- | The plan axes on public budget evidence are nominal, so representational
coercion cannot relabel evidence onto another admitted plan.
-}
module CoerceBudgetEvidenceRoles where

import Data.Coerce (coerce)
import HostBootstrap.Cluster.Budget
  ( ProviderBudgetCapability,
    SliceRequest,
    Workload,
  )

data Scope
data WorkloadPlanA
data WorkloadPlanB
data SlicePlanA
data SlicePlanB
data CapabilityPlanA
data CapabilityPlanB
data Provider
data CapabilityIdentity

wrongWorkloadPlan ::
  Workload Scope WorkloadPlanA ->
  Workload Scope WorkloadPlanB
wrongWorkloadPlan = coerce

wrongSlicePlan ::
  SliceRequest Scope SlicePlanA ->
  SliceRequest Scope SlicePlanB
wrongSlicePlan = coerce

wrongCapabilityPlan ::
  ProviderBudgetCapability Scope CapabilityPlanA Provider CapabilityIdentity ->
  ProviderBudgetCapability Scope CapabilityPlanB Provider CapabilityIdentity
wrongCapabilityPlan = coerce
