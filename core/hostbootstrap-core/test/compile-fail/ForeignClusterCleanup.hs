module ForeignClusterCleanup where

import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Reconcile

-- An unmanaged (foreign) cluster handle must not authorize conditional cleanup.
badCleanup ::
    ResourceHandle scope planId clusterId ClusterResource Unmanaged Observed ->
    OwnershipReceipt scope planId clusterId ClusterResource ->
    Either ReconcileError ()
badCleanup handle receipt =
    withPreparedClusterCleanup handle receipt (const ())
