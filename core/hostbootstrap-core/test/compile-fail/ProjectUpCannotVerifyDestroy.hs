module ProjectUpCannotVerifyDestroy where

import HostBootstrap.Authority (VerbUp)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown
    ( DestroySettled
    , SubtreeSettled
    , TeardownError
    , verifyDestroySettled
    )

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope
data Frame

-- A total project-up projection cannot be relabelled as completed destroy
-- evidence, even if a caller somehow receives same-indexed opaque values.
verifyUp ::
    ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
    CurrentFrame Scope Plan Frame ->
    SubtreeSettled Scope Plan Frame VerbUp ->
    Either TeardownError (DestroySettled Scope Plan)
verifyUp = verifyDestroySettled
