module CoerceReadyPlan where

import Data.Coerce (coerce)
import HostBootstrap.Readiness (Ready)

data PlanA

data PlanB

-- Readiness for one plan cannot be represented as readiness for another.
wrongPlan ::
    Ready scope PlanA resourceId resource dependency ->
    Ready scope PlanB resourceId resource dependency
wrongPlan = coerce
