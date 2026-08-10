{- | Provider admission cannot combine a validated budget with a capability
projected from another admitted plan.
-}
module CrossPlanBudgetProviderCapability where

import HostBootstrap.Cluster.Budget
  ( BudgetError,
    ProviderBudgetCapability,
    ValidatedBudget,
    admitProviderBudget,
  )

data Scope
data PlanA
data PlanB
data BudgetIdentity
data Provider
data CapabilityIdentity

crossPlanProviderCapability ::
  ValidatedBudget Scope PlanA BudgetIdentity ->
  ProviderBudgetCapability Scope PlanB Provider CapabilityIdentity ->
  Either BudgetError ()
crossPlanProviderCapability budget capability =
  admitProviderBudget budget capability (\_wall _effective -> ())
