module ForgePlanDigestBinding where

import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)

data Scope
data SpecDigest
data PlanDigest
data PlanId

forgedBinding :: PlanDigestBinding Scope SpecDigest PlanDigest PlanId
forgedBinding = PlanDigestBinding
