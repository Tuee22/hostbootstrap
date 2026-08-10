module CoerceProjectPlanIdentity where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (ProjectPlan)

data Scope
data SpecDigest
data PlanA
data PlanB
data ConfigId
data Config scope

wrongPlan ::
    ProjectPlan Scope SpecDigest PlanA ConfigId Config ->
    ProjectPlan Scope SpecDigest PlanB ConfigId Config
wrongPlan = coerce
