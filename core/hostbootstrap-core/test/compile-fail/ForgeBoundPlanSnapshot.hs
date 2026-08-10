module ForgeBoundPlanSnapshot where

import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)

data Scope
data SpecDigest
data PlanDigest
data PlanId

forgedSnapshot :: BoundPlanSnapshot Scope SpecDigest PlanDigest PlanId
forgedSnapshot = BoundPlanSnapshot
