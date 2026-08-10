module CoercePlannedResourceRoles where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlannedResource)

data ResourceScopeA
data ResourceScopeB
data ResourcePlanA
data ResourcePlanB
data ResourceIdentityA
data ResourceIdentityB
data ResourceKindA
data ResourceKindB
data ResourceFrameA
data ResourceFrameB

type ResourceProjection scope plan identity resource frame =
    PlannedResource scope plan identity resource frame

type BaselineResource =
    ResourceProjection
        ResourceScopeA
        ResourcePlanA
        ResourceIdentityA
        ResourceKindA
        ResourceFrameA

wrongResourceScope ::
    BaselineResource ->
    ResourceProjection
        ResourceScopeB
        ResourcePlanA
        ResourceIdentityA
        ResourceKindA
        ResourceFrameA
wrongResourceScope = coerce

wrongResourcePlan ::
    BaselineResource ->
    ResourceProjection
        ResourceScopeA
        ResourcePlanB
        ResourceIdentityA
        ResourceKindA
        ResourceFrameA
wrongResourcePlan = coerce

wrongResourceIdentity ::
    BaselineResource ->
    ResourceProjection
        ResourceScopeA
        ResourcePlanA
        ResourceIdentityB
        ResourceKindA
        ResourceFrameA
wrongResourceIdentity = coerce

wrongResourceKind ::
    BaselineResource ->
    ResourceProjection
        ResourceScopeA
        ResourcePlanA
        ResourceIdentityA
        ResourceKindB
        ResourceFrameA
wrongResourceKind = coerce

wrongResourceFrame ::
    BaselineResource ->
    ResourceProjection
        ResourceScopeA
        ResourcePlanA
        ResourceIdentityA
        ResourceKindA
        ResourceFrameB
wrongResourceFrame = coerce
