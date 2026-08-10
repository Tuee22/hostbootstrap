module CoercePlanDigestBindingPlan where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)

data Scope
data SpecDigest
data PlanDigest
data PlanA
data PlanB

wrongPlan ::
    PlanDigestBinding Scope SpecDigest PlanDigest PlanA ->
    PlanDigestBinding Scope SpecDigest PlanDigest PlanB
wrongPlan = coerce
