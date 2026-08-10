module CoerceProjectPlanScope where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (ProjectPlan)

data ScopeA
data ScopeB
data SpecDigest
data PlanId
data ConfigId
data Config scope

wrongScope ::
    ProjectPlan ScopeA SpecDigest PlanId ConfigId Config ->
    ProjectPlan ScopeB SpecDigest PlanId ConfigId Config
wrongScope = coerce
