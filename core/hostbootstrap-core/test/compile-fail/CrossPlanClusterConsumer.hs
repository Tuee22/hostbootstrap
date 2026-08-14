{- | Every member of the exact cluster package must come from one admitted
project plan.
-}
module CrossPlanClusterConsumer where

import HostBootstrap.Cluster.Budget (LimaProvider, ResourceSlice)
import HostBootstrap.Cluster.Lifecycle (ClusterPackageError, withPlanOwnedCluster)
import HostBootstrap.ProjectPlan
  ( ClusterResource,
    DerivedTopology,
    PlannedResource,
    ProjectPlan,
    ProviderResource,
  )

data Scope
data SpecificationDigest
data ConfigurationIdentity
data Configuration scope
data ClusterPlan
data ForeignClusterPlan
data ForeignProviderPlan
data ForeignTopologyPlan
data ForeignSlicePlan
data ClusterIdentity
data ClusterFrame
data ProviderIdentity
data ProviderFrame
data BudgetIdentity
data CapabilityIdentity
data WallIdentity
data WorkloadIdentity
data PartitionIdentity

type ExactPlan plan =
  ProjectPlan Scope SpecificationDigest plan ConfigurationIdentity Configuration

type Cluster plan =
  PlannedResource Scope plan ClusterIdentity ClusterResource ClusterFrame

type Provider plan =
  PlannedResource Scope plan ProviderIdentity ProviderResource ProviderFrame

type Slice plan =
  ResourceSlice
    Scope
    plan
    BudgetIdentity
    LimaProvider
    CapabilityIdentity
    WallIdentity
    WorkloadIdentity
    PartitionIdentity
    ClusterFrame
    ClusterIdentity

crossPlanClusterResource ::
  ExactPlan ClusterPlan ->
  Cluster ForeignClusterPlan ->
  Provider ClusterPlan ->
  DerivedTopology Scope ClusterPlan ->
  Slice ClusterPlan ->
  Either ClusterPackageError ()
crossPlanClusterResource plan cluster provider topology slice =
  () <$ withPlanOwnedCluster plan cluster provider topology slice

crossPlanProviderResource ::
  ExactPlan ClusterPlan ->
  Cluster ClusterPlan ->
  Provider ForeignProviderPlan ->
  DerivedTopology Scope ClusterPlan ->
  Slice ClusterPlan ->
  Either ClusterPackageError ()
crossPlanProviderResource plan cluster provider topology slice =
  () <$ withPlanOwnedCluster plan cluster provider topology slice

crossPlanTopology ::
  ExactPlan ClusterPlan ->
  Cluster ClusterPlan ->
  Provider ClusterPlan ->
  DerivedTopology Scope ForeignTopologyPlan ->
  Slice ClusterPlan ->
  Either ClusterPackageError ()
crossPlanTopology plan cluster provider topology slice =
  () <$ withPlanOwnedCluster plan cluster provider topology slice

crossPlanSlice ::
  ExactPlan ClusterPlan ->
  Cluster ClusterPlan ->
  Provider ClusterPlan ->
  DerivedTopology Scope ClusterPlan ->
  Slice ForeignSlicePlan ->
  Either ClusterPackageError ()
crossPlanSlice plan cluster provider topology slice =
  () <$ withPlanOwnedCluster plan cluster provider topology slice
