{- | A workload projected from one admitted plan cannot enter another plan's
workload set, even when both plans share the same scope.
-}
module CrossPlanBudgetWorkload where

import HostBootstrap.Cluster.Budget
  ( BudgetError,
    Workload,
    withPlannedWorkloadSet,
  )
import HostBootstrap.ProjectPlan (ProjectPlan)

data Scope
data SpecificationDigest
data PlanA
data PlanB
data ConfigurationIdentity
data Configuration scope

crossPlanWorkload ::
  ProjectPlan Scope SpecificationDigest PlanA ConfigurationIdentity Configuration ->
  Workload Scope PlanB ->
  Either BudgetError ()
crossPlanWorkload plan workload =
  withPlannedWorkloadSet plan [workload] (const ())
