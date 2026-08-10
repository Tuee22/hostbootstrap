module CoerceBoundPlanSnapshotPlan where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)

data Scope
data SpecDigest
data PlanDigest
data PlanA
data PlanB

wrongPlan ::
    BoundPlanSnapshot Scope SpecDigest PlanDigest PlanA ->
    BoundPlanSnapshot Scope SpecDigest PlanDigest PlanB
wrongPlan = coerce
