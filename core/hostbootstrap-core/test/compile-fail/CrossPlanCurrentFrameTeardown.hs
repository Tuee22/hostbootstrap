module CrossPlanCurrentFrameTeardown where

import HostBootstrap.Authority (ProjectVerb (ProjectDown), VerbDown)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown (TeardownPlan, teardownPlan)

data PlanA
data PlanB

-- A current-frame witness is evidence for one exact admitted plan.  It cannot
-- select a frame in a different plan's reverse projection.
crossPlanCurrentFrame ::
    ProjectPlan Scope SpecDigest PlanA ConfigId Config ->
    CurrentFrame Scope PlanB Frame ->
    TeardownPlan Scope PlanA Frame VerbDown
crossPlanCurrentFrame plan current = teardownPlan plan current ProjectDown

data Scope
data SpecDigest
data ConfigId
data Config scope
data Frame
