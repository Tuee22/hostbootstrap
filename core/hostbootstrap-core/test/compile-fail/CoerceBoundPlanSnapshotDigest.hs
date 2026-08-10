module CoerceBoundPlanSnapshotDigest where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)

data Scope
data SpecDigest
data DigestA
data DigestB
data PlanId

wrongDigest ::
    BoundPlanSnapshot Scope SpecDigest DigestA PlanId ->
    BoundPlanSnapshot Scope SpecDigest DigestB PlanId
wrongDigest = coerce
