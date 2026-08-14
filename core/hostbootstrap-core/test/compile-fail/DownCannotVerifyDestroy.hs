module DownCannotVerifyDestroy where

import HostBootstrap.Authority (VerbDown)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope
data Frame

downCannotPromote ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    CurrentFrame Scope Plan Frame ->
    SubtreeSettled Scope Plan Frame VerbDown ->
    Either TeardownError (DestroySettled Scope Plan)
downCannotPromote = verifyDestroySettled
