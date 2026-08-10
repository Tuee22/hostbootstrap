module CoerceReservedRoleAdmissionRoles where

import Data.Coerce (coerce)
import HostBootstrap.RoleLifecycle (ReservedRoleAdmission)

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

type Admission scope plan frame revision instanceId =
    ReservedRoleAdmission scope plan frame revision instanceId

wrongScope :: Admission ScopeA PlanA FrameA RevisionA InstanceA -> Admission ScopeB PlanA FrameA RevisionA InstanceA
wrongScope = coerce

wrongPlan :: Admission ScopeA PlanA FrameA RevisionA InstanceA -> Admission ScopeA PlanB FrameA RevisionA InstanceA
wrongPlan = coerce

wrongFrame :: Admission ScopeA PlanA FrameA RevisionA InstanceA -> Admission ScopeA PlanA FrameB RevisionA InstanceA
wrongFrame = coerce

wrongRevision :: Admission ScopeA PlanA FrameA RevisionA InstanceA -> Admission ScopeA PlanA FrameA RevisionB InstanceA
wrongRevision = coerce

wrongInstance :: Admission ScopeA PlanA FrameA RevisionA InstanceA -> Admission ScopeA PlanA FrameA RevisionA InstanceB
wrongInstance = coerce
