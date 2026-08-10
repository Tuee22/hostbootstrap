module CoercePlannedStepPlan where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlannedStep)

data Scope
data PlanA
data PlanB
data ConfigId
data Config

wrongPlan ::
    PlannedStep Scope PlanA ConfigId Config ->
    PlannedStep Scope PlanB ConfigId Config
wrongPlan = coerce
