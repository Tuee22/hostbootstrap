module CallerFrameNameTeardown where

import HostBootstrap.Authority (ProjectVerb (ProjectDown), VerbDown)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.Teardown

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope
data Frame

-- A caller-selected frame name is descriptive text, not plan-local frame
-- evidence. Only an admitted CurrentFrame can select the projection suffix.
projectFromFrameName ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    TeardownPlan Scope Plan Frame VerbDown
projectFromFrameName plan = teardownPlan plan "host-orchestrator-0" ProjectDown
