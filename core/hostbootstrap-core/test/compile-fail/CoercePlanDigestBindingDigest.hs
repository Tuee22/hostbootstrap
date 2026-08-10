module CoercePlanDigestBindingDigest where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)

data Scope
data SpecDigest
data DigestA
data DigestB
data PlanId

wrongDigest ::
    PlanDigestBinding Scope SpecDigest DigestA PlanId ->
    PlanDigestBinding Scope SpecDigest DigestB PlanId
wrongDigest = coerce
