module LifecyclePlanAsTeardownPlanSource where

import HostBootstrap.Authority (ProjectVerb (ProjectDown), VerbDown)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Reconcile (LifecyclePlan)
import HostBootstrap.Teardown (TeardownPlan, teardownPlan)

data Scope
data Plan
data Frame
data SpecificationDigest
data ConfigurationIdentity
data Configuration scope

projectDownPlan ::
    ProjectPlan
        Scope
        SpecificationDigest
        Plan
        ConfigurationIdentity
        Configuration ->
    CurrentFrame Scope Plan Frame ->
    TeardownPlan Scope Plan Frame VerbDown
projectDownPlan plan current = teardownPlan plan current ProjectDown

-- The compatibility LifecyclePlan cannot enter the exact reverse-projection
-- gate.  Projection requires the indexed ProjectPlan and its CurrentFrame.
lifecyclePlanCannotProject ::
    LifecyclePlan Scope Plan ->
    CurrentFrame Scope Plan Frame ->
    TeardownPlan Scope Plan Frame VerbDown
lifecyclePlanCannotProject plan current = projectDownPlan plan current
