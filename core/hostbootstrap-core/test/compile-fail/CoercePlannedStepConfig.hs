module CoercePlannedStepConfig where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlannedStep)

data Scope
data PlanId
data ConfigA
data ConfigB
data Config

wrongConfig ::
    PlannedStep Scope PlanId ConfigA Config ->
    PlannedStep Scope PlanId ConfigB Config
wrongConfig = coerce
