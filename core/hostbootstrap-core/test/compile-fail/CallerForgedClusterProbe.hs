{- | Exact cluster preparation accepts only the opaque Running provider
dependency minted by the strong provider backend, never a caller-built probe.
-}
module CallerForgedClusterProbe where

import HostBootstrap.Cluster.Budget (ResourceSlice)
import HostBootstrap.Cluster.Reconcile (withPreparedClusterReconcile)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan
import HostBootstrap.Reconcile (DependencyProbe, ReconcileError)

forgedProbeConsumer ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId clusterId ClusterResource clusterFrame ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  DerivedTopology scope planId ->
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId clusterFrame clusterId ->
  DependencyProbe scope planId providerId ProviderResource ->
  PreparedGate ->
  IO (Either ReconcileError ())
forgedProbeConsumer plan cluster provider topology slice callerProbe gate =
  withPreparedClusterReconcile
    plan
    cluster
    provider
    topology
    slice
    callerProbe
    gate
    (const ())
