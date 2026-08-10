module CoerceBoundPlanSnapshotScope where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)

data ScopeA
data ScopeB
data SpecDigest
data PlanDigest
data PlanId

wrongScope ::
    BoundPlanSnapshot ScopeA SpecDigest PlanDigest PlanId ->
    BoundPlanSnapshot ScopeB SpecDigest PlanDigest PlanId
wrongScope = coerce
