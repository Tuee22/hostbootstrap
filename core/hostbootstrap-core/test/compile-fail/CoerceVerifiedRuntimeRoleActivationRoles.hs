module CoerceVerifiedRuntimeRoleActivationRoles where

import Data.Coerce (coerce)
import HostBootstrap.Activation (VerifiedRuntimeRoleActivation)

data ScopeA
data ScopeB
data PlanA
data PlanB
data SpecA
data SpecB
data BinaryA
data BinaryB
data FrameA
data FrameB
data RevisionA
data RevisionB
data InstanceA
data InstanceB

wrongScope ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeB PlanA SpecA BinaryA FrameA RevisionA InstanceA
wrongScope = coerce

wrongPlan ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeA PlanB SpecA BinaryA FrameA RevisionA InstanceA
wrongPlan = coerce

wrongSpec ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecB BinaryA FrameA RevisionA InstanceA
wrongSpec = coerce

wrongBinary ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryB FrameA RevisionA InstanceA
wrongBinary = coerce

wrongFrame ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameB RevisionA InstanceA
wrongFrame = coerce

wrongRevision ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionB InstanceA
wrongRevision = coerce

wrongInstance ::
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceA ->
    VerifiedRuntimeRoleActivation ScopeA PlanA SpecA BinaryA FrameA RevisionA InstanceB
wrongInstance = coerce
