module DuplicateCurrentFrameTeardown where

import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope
data Frame

-- Exact projection consumes one CurrentFrame. A second witness has no place in
-- the API and cannot be used to relabel or reconfirm the projection.
projectWithSecondFrame ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    CurrentFrame Scope Plan Frame ->
    CurrentFrame Scope Plan Frame ->
    TeardownPlan Scope Plan Frame DownVerb
projectWithSecondFrame plan current = teardownPlan plan current downVerb
