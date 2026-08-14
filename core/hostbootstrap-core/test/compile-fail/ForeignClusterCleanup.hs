module ForeignClusterCleanup where

import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Reconcile

-- An unmanaged (foreign) cluster handle must not authorize conditional cleanup.
badCleanup ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ResourceHandle scope planId clusterId ClusterResource Unmanaged Observed ->
    Either ReconcileError ()
badCleanup prepared unmanaged =
    withPreparedClusterCleanup prepared unmanaged (const ())
