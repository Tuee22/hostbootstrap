module CoercePlannedEdgeRoles where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlannedEdge)

data EdgeScopeA
data EdgeScopeB
data EdgePlanA
data EdgePlanB
data TargetIdentityA
data TargetIdentityB
data TargetKindA
data TargetKindB
data TargetFrameA
data TargetFrameB
data DependencyIdentityA
data DependencyIdentityB
data DependencyKindA
data DependencyKindB
data DependencyFrameA
data DependencyFrameB

type EdgeProjection scope plan targetId target targetFrame dependencyId dependency dependencyFrame =
    PlannedEdge
        scope
        plan
        targetId
        target
        targetFrame
        dependencyId
        dependency
        dependencyFrame

type BaselineEdge =
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityA
        TargetKindA
        TargetFrameA
        DependencyIdentityA
        DependencyKindA
        DependencyFrameA

wrongEdgeScope ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeB
        EdgePlanA
        TargetIdentityA
        TargetKindA
        TargetFrameA
        DependencyIdentityA
        DependencyKindA
        DependencyFrameA
wrongEdgeScope = coerce

wrongEdgePlan ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanB
        TargetIdentityA
        TargetKindA
        TargetFrameA
        DependencyIdentityA
        DependencyKindA
        DependencyFrameA
wrongEdgePlan = coerce

wrongTargetIdentity ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityB
        TargetKindA
        TargetFrameA
        DependencyIdentityA
        DependencyKindA
        DependencyFrameA
wrongTargetIdentity = coerce

wrongTargetKind ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityA
        TargetKindB
        TargetFrameA
        DependencyIdentityA
        DependencyKindA
        DependencyFrameA
wrongTargetKind = coerce

wrongTargetFrame ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityA
        TargetKindA
        TargetFrameB
        DependencyIdentityA
        DependencyKindA
        DependencyFrameA
wrongTargetFrame = coerce

wrongDependencyIdentity ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityA
        TargetKindA
        TargetFrameA
        DependencyIdentityB
        DependencyKindA
        DependencyFrameA
wrongDependencyIdentity = coerce

wrongDependencyKind ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityA
        TargetKindA
        TargetFrameA
        DependencyIdentityA
        DependencyKindB
        DependencyFrameA
wrongDependencyKind = coerce

wrongDependencyFrame ::
    BaselineEdge ->
    EdgeProjection
        EdgeScopeA
        EdgePlanA
        TargetIdentityA
        TargetKindA
        TargetFrameA
        DependencyIdentityA
        DependencyKindA
        DependencyFrameB
wrongDependencyFrame = coerce
