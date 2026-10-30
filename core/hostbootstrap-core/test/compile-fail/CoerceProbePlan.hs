module CoerceProbePlan where

import Data.Coerce (coerce)
import HostBootstrap.Readiness (Probe)

data PlanA

data PlanB

-- The backend action remains bound to the plan that admitted its probe.
wrongPlan ::
    Probe scope PlanA resourceId resource dependency probeId value ->
    Probe scope PlanB resourceId resource dependency probeId value
wrongPlan = coerce
