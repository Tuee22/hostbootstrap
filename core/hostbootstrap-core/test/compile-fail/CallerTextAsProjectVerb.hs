module CallerTextAsProjectVerb where

import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown (TeardownPlan, teardownPlan)

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope
data Frame
data Verb

-- Parser text is descriptive input, not the canonical admitted ProjectVerb.
projectFromText ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    CurrentFrame Scope Plan Frame ->
    TeardownPlan Scope Plan Frame Verb
projectFromText plan current = teardownPlan plan current "destroy"
