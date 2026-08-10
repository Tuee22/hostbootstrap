module CrossPlanFramePlannedProjection where

import HostBootstrap.ProjectPlan (PlannedEdge, PlannedResource)

data ProjectionScope
data ProjectionPlan
data ForeignProjectionPlan
data TargetIdentity
data TargetResource
data TargetFrame
data ForeignTargetFrame
data DependencyIdentity
data DependencyResource
data DependencyFrame
data ForeignDependencyFrame

type ResourceProjection plan identity resource frame =
    PlannedResource ProjectionScope plan identity resource frame

type EdgeProjection plan targetFrame dependencyFrame =
    PlannedEdge
        ProjectionScope
        plan
        TargetIdentity
        TargetResource
        targetFrame
        DependencyIdentity
        DependencyResource
        dependencyFrame

consumeProjection ::
    ResourceProjection
        ProjectionPlan
        TargetIdentity
        TargetResource
        TargetFrame ->
    ResourceProjection
        ProjectionPlan
        DependencyIdentity
        DependencyResource
        DependencyFrame ->
    EdgeProjection
        ProjectionPlan
        TargetFrame
        DependencyFrame ->
    ()
consumeProjection _ _ _ = ()

wrongProjectionPlan ::
    ResourceProjection
        ProjectionPlan
        TargetIdentity
        TargetResource
        TargetFrame ->
    ResourceProjection
        ProjectionPlan
        DependencyIdentity
        DependencyResource
        DependencyFrame ->
    EdgeProjection
        ForeignProjectionPlan
        TargetFrame
        DependencyFrame ->
    ()
wrongProjectionPlan target dependency edge =
    consumeProjection target dependency edge

wrongProjectionTargetFrame ::
    ResourceProjection
        ProjectionPlan
        TargetIdentity
        TargetResource
        TargetFrame ->
    ResourceProjection
        ProjectionPlan
        DependencyIdentity
        DependencyResource
        DependencyFrame ->
    EdgeProjection
        ProjectionPlan
        ForeignTargetFrame
        DependencyFrame ->
    ()
wrongProjectionTargetFrame target dependency edge =
    consumeProjection target dependency edge

wrongProjectionDependencyFrame ::
    ResourceProjection
        ProjectionPlan
        TargetIdentity
        TargetResource
        TargetFrame ->
    ResourceProjection
        ProjectionPlan
        DependencyIdentity
        DependencyResource
        DependencyFrame ->
    EdgeProjection
        ProjectionPlan
        TargetFrame
        ForeignDependencyFrame ->
    ()
wrongProjectionDependencyFrame target dependency edge =
    consumeProjection target dependency edge
