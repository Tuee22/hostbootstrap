{- | Partition evidence and every requested slice must belong to the same
admitted plan.
-}
module CrossPlanBudgetSlice where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Cluster.Budget
  ( BudgetError,
    EffectiveBudget,
    SliceRequest,
    VerifiedWorkloadFit,
    withBudgetPartition,
  )
import HostBootstrap.Cluster.Cordon (ResourceBudget)

data Scope
data PlanA
data PlanB
data BudgetIdentity
data Provider
data CapabilityIdentity
data WallSpecificationIdentity
data WorkloadSetIdentity

crossPlanSlice ::
  EffectiveBudget
    Scope
    PlanA
    BudgetIdentity
    Provider
    CapabilityIdentity
    WallSpecificationIdentity ->
  VerifiedWorkloadFit
    Scope
    PlanA
    BudgetIdentity
    Provider
    CapabilityIdentity
    WallSpecificationIdentity
    WorkloadSetIdentity ->
  ResourceBudget ->
  NonEmpty (SliceRequest Scope PlanB) ->
  Either BudgetError ()
crossPlanSlice effective fit overhead requests =
  withBudgetPartition effective fit overhead requests (\_partition _slices -> ())
