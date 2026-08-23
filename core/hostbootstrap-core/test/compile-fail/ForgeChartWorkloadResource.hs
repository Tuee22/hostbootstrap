module ForgeChartWorkloadResource where

-- Workload resources can only be minted from an admitted chart declaration;
-- callers cannot invent their plan, resource, or frame brands.
import HostBootstrap.ProjectPlan
    ( ChartWorkloadResource (ChartWorkloadResource)
    )

forged :: ChartWorkloadResource scope planId resourceId frame
forged =
    ChartWorkloadResource
        "chart"
        "release"
        "namespace"
        "values"
        "image"
        "workload"
        "digest"
        "role"
        ["effect"]
        "operation"
        "frame"
