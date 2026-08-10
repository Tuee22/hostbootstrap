module CoerceProjectPlanSpec where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (ProjectPlan)

data Scope
data SpecA
data SpecB
data PlanId
data ConfigId
data Config scope

wrongSpecification ::
    ProjectPlan Scope SpecA PlanId ConfigId Config ->
    ProjectPlan Scope SpecB PlanId ConfigId Config
wrongSpecification = coerce
