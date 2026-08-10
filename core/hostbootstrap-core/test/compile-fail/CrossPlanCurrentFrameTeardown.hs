module CrossPlanCurrentFrameTeardown where

import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown (DownVerb, TeardownPlan, downVerb, teardownPlan)

data PlanA
data PlanB

-- A current-frame witness is evidence for one exact admitted plan.  It cannot
-- select a frame in a different plan's reverse projection.
crossPlanCurrentFrame ::
    ProjectPlan Scope SpecDigest PlanA ConfigId Config ->
    CurrentFrame Scope PlanB Frame ->
    TeardownPlan Scope PlanA Frame DownVerb
crossPlanCurrentFrame plan current = teardownPlan plan current downVerb

data Scope
data SpecDigest
data ConfigId
data Config scope
data Frame
