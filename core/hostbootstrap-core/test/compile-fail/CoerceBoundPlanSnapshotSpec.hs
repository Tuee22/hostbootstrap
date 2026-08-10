module CoerceBoundPlanSnapshotSpec where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)

data Scope
data SpecA
data SpecB
data PlanDigest
data PlanId

wrongSpecification ::
    BoundPlanSnapshot Scope SpecA PlanDigest PlanId ->
    BoundPlanSnapshot Scope SpecB PlanDigest PlanId
wrongSpecification = coerce
