{- | An interpreter observation is tied nominally to the exact scope, plan,
and validated configuration whose planned node produced it.  Its identical
runtime representation cannot relabel any of those admission axes.
-}
module CoercePlannedStepObservationRoles where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlannedStepObservation)

data ObservationScopeA
data ObservationScopeB
data ObservationPlanA
data ObservationPlanB
data ObservationConfigA
data ObservationConfigB

coerceObservationScope ::
    PlannedStepObservation ObservationScopeA ObservationPlanA ObservationConfigA ->
    PlannedStepObservation ObservationScopeB ObservationPlanA ObservationConfigA
coerceObservationScope = coerce

coerceObservationPlan ::
    PlannedStepObservation ObservationScopeA ObservationPlanA ObservationConfigA ->
    PlannedStepObservation ObservationScopeA ObservationPlanB ObservationConfigA
coerceObservationPlan = coerce

coerceObservationConfig ::
    PlannedStepObservation ObservationScopeA ObservationPlanA ObservationConfigA ->
    PlannedStepObservation ObservationScopeA ObservationPlanA ObservationConfigB
coerceObservationConfig = coerce
