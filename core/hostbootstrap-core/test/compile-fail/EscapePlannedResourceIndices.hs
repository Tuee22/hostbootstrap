{-# LANGUAGE RankNTypes #-}

module EscapePlannedResourceIndices where

import HostBootstrap.ProjectPlan
    ( OperationKey
    , PlanError
    , PlannedResource
    , PlannedResourceKind
    , ProjectPlan
    , withPlannedResourceOfKind
    )

data ProjectionScope
data SpecificationDigest
data PlanIdentity
data ConfigurationIdentity
data Configuration scope
data Resource
data ChosenResourceIdentity
data ChosenResourceFrame

type ExactPlan =
    ProjectPlan
        ProjectionScope
        SpecificationDigest
        PlanIdentity
        ConfigurationIdentity
        Configuration

type ResourceProjection identity frame =
    PlannedResource ProjectionScope PlanIdentity identity Resource frame

consumeChosenIdentity ::
    ResourceProjection ChosenResourceIdentity frame ->
    ()
consumeChosenIdentity _ = ()

escapeResourceIdentity ::
    ExactPlan ->
    PlannedResourceKind Resource ->
    OperationKey ->
    Either PlanError ()
escapeResourceIdentity plan resourceKind operationKey =
    withPlannedResourceOfKind
        plan
        resourceKind
        operationKey
        consumeChosenIdentity

consumeChosenFrame ::
    ResourceProjection resourceIdentity ChosenResourceFrame ->
    ()
consumeChosenFrame _ = ()

escapeResourceFrame ::
    ExactPlan ->
    PlannedResourceKind Resource ->
    OperationKey ->
    Either PlanError ()
escapeResourceFrame plan resourceKind operationKey =
    withPlannedResourceOfKind
        plan
        resourceKind
        operationKey
        consumeChosenFrame
