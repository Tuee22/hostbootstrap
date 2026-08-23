{- | Exact cluster preparation accepts only the opaque Running provider
dependency minted by the strong provider backend, never a caller-built probe.
-}
module CallerForgedClusterProbe where

import HostBootstrap.Cluster.Lifecycle (PlanOwnedClusterConfig)
import HostBootstrap.Cluster.Reconcile (withPreparedClusterReconcile)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (ProviderResource)
import HostBootstrap.Reconcile (DependencyProbe, ReconcileError)

forgedProbeConsumer ::
  PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  DependencyProbe scope planId providerId ProviderResource ->
  PreparedGate ->
  IO (Either ReconcileError ())
forgedProbeConsumer configured callerProbe gate =
  withPreparedClusterReconcile
    configured
    callerProbe
    gate
    (const ())
