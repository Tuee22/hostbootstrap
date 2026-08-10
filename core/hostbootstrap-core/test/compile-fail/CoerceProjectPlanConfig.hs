module CoerceProjectPlanConfig where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (ProjectPlan)

data Scope
data SpecDigest
data PlanId
data ConfigA
data ConfigB
data Config scope

wrongConfig ::
    ProjectPlan Scope SpecDigest PlanId ConfigA Config ->
    ProjectPlan Scope SpecDigest PlanId ConfigB Config
wrongConfig = coerce
