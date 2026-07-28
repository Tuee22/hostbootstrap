module CrossClusterReceipt where

import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Reconcile

-- A receipt whose cluster-identity param (@clusterB@) differs from the handle's
-- (@clusterA@) cannot authorize its cleanup.
badCleanup ::
    ResourceHandle scope planId clusterA ClusterResource Managed phase ->
    OwnershipReceipt scope planId clusterB ClusterResource ->
    Either ReconcileError ()
badCleanup handle receipt =
    withPreparedClusterCleanup handle receipt (const ())
