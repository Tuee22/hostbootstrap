module CoerceVerifiedRolePlanDraftRoles where

import Data.Coerce (coerce)
import HostBootstrap.RoleLifecycle (VerifiedRolePlanDraft)

data ScopeA
data ScopeB
data PlanA
data PlanB
data FrameA
data FrameB
data RevisionA
data RevisionB
data InstanceA
data InstanceB
data DigestA
data DigestB

type Draft scope plan frame revision instanceId digest =
    VerifiedRolePlanDraft scope plan frame revision instanceId digest

wrongScope :: Draft ScopeA PlanA FrameA RevisionA InstanceA DigestA -> Draft ScopeB PlanA FrameA RevisionA InstanceA DigestA
wrongScope = coerce

wrongPlan :: Draft ScopeA PlanA FrameA RevisionA InstanceA DigestA -> Draft ScopeA PlanB FrameA RevisionA InstanceA DigestA
wrongPlan = coerce

wrongFrame :: Draft ScopeA PlanA FrameA RevisionA InstanceA DigestA -> Draft ScopeA PlanA FrameB RevisionA InstanceA DigestA
wrongFrame = coerce

wrongRevision :: Draft ScopeA PlanA FrameA RevisionA InstanceA DigestA -> Draft ScopeA PlanA FrameA RevisionB InstanceA DigestA
wrongRevision = coerce

wrongInstance :: Draft ScopeA PlanA FrameA RevisionA InstanceA DigestA -> Draft ScopeA PlanA FrameA RevisionA InstanceB DigestA
wrongInstance = coerce

wrongDigest :: Draft ScopeA PlanA FrameA RevisionA InstanceA DigestA -> Draft ScopeA PlanA FrameA RevisionA InstanceA DigestB
wrongDigest = coerce
