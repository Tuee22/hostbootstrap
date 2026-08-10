module ForgeIndexedProjectPlan where

import HostBootstrap.ProjectPlan (ProjectPlan)

data Scope
data SpecDigest
data PlanId
data ConfigId
data Config scope

-- Only authoritative fresh admission can construct the indexed plan.
forgedPlan :: ProjectPlan Scope SpecDigest PlanId ConfigId Config
forgedPlan = ProjectPlan
