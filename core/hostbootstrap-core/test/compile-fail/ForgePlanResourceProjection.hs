module ForgePlanResourceProjection where

import HostBootstrap.ProjectPlan (PlannedEdge, PlannedResource)

data Scope
data PlanId
data ResourceId
data Resource
data ResourceFrame
data DependencyId
data Dependency
data DependencyFrame

forgedResource :: PlannedResource Scope PlanId ResourceId Resource ResourceFrame
forgedResource = PlannedResource

forgedEdge ::
    PlannedEdge
        Scope
        PlanId
        ResourceId
        Resource
        ResourceFrame
        DependencyId
        Dependency
        DependencyFrame
forgedEdge = PlannedEdge
