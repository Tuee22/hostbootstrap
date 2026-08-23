{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Pure, caller-free binding between one admitted chart declaration and the
generative workload/partition values that implement it.
-}
module HostBootstrap.Cluster.Workload.Binding
    ( withMatchingChartWorkloadDeclaration
    )
where

import Data.Text (Text)
import HostBootstrap.Cluster.Budget
    ( BudgetPartition
    , PlannedWorkloadSet
    , plannedWorkloadSetDeclarationKey
    , workloadPartitionDigest
    )
import HostBootstrap.Lifecycle.Plan
    ( ChartWorkloadResource
    , ClusterResource
    , PlannedResource
    , chartWorkloadResourceFrameKernel
    , withChartWorkloadResourceDetailsKernel
    )
import HostBootstrap.ProjectPlan (plannedResourceFrame, plannedResourceKey)
import HostBootstrap.Reconcile (plannedResourcePlanDigest)

withMatchingChartWorkloadDeclaration ::
    ChartWorkloadResource scope planId chartId chartFrame ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    PlannedWorkloadSet scope planId workloadSetId ->
    BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    (Text -> Text -> Text -> Text -> Text -> Text -> Text -> [Text] -> Text -> result) ->
    Either Text result
withMatchingChartWorkloadDeclaration chart cluster workloads partition consume =
    withChartWorkloadResourceDetailsKernel chart $ \artifact release namespace values image key digest role effects planDigest clusterKey -> do
        require "the chart resource and cluster resource have different frames"
            (chartWorkloadResourceFrameKernel chart == plannedResourceFrame cluster)
        require "the chart declaration names another cluster resource"
            (clusterKey == plannedResourceKey cluster)
        require "the chart declaration belongs to another stable plan"
            (planDigest == plannedResourcePlanDigest cluster)
        require "the chart declaration key differs from the planned workload set"
            (key == plannedWorkloadSetDeclarationKey workloads)
        require "the chart declaration digest differs from the workload partition"
            (digest == workloadPartitionDigest workloads partition)
        pure (consume artifact release namespace values image key role effects planDigest)
  where
    require _ True = Right ()
    require reason False = Left reason
