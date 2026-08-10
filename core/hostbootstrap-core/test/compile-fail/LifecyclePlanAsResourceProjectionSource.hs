{-# LANGUAGE RankNTypes #-}

module LifecyclePlanAsResourceProjectionSource where

import HostBootstrap.ProjectPlan
    ( OperationKey
    , PlanError
    , PlannedResource
    , PlannedResourceKind
    , ProjectPlan
    , withPlannedResourceOfKind
    )
import HostBootstrap.Reconcile (LifecyclePlan)

data ProjectionScope
data SpecificationDigest
data PlanIdentity
data ConfigurationIdentity
data Configuration scope
data Resource

type ResourceProjection resourceIdentity frame =
    PlannedResource
        ProjectionScope
        PlanIdentity
        resourceIdentity
        Resource
        frame

projectPlanProjection ::
    ProjectPlan
        ProjectionScope
        SpecificationDigest
        PlanIdentity
        ConfigurationIdentity
        Configuration ->
    PlannedResourceKind Resource ->
    OperationKey ->
    ( forall resourceIdentity frame.
      ResourceProjection resourceIdentity frame ->
      result
    ) ->
    Either PlanError result
projectPlanProjection = withPlannedResourceOfKind

wrongProjectionSource ::
    LifecyclePlan ProjectionScope PlanIdentity ->
    PlannedResourceKind Resource ->
    OperationKey ->
    ( forall resourceIdentity frame.
      ResourceProjection resourceIdentity frame ->
      result
    ) ->
    Either PlanError result
wrongProjectionSource lifecyclePlan resourceKind operationKey consume =
    projectPlanProjection lifecyclePlan resourceKind operationKey consume
