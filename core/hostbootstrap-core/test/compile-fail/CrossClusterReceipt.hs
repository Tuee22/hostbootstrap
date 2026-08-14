module CrossClusterReceipt where

import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Reconcile

-- A receipt whose cluster-identity param (@clusterB@) differs from the exact
-- managed handle's (@clusterA@) cannot validate as ownership authority.
badReceipt ::
    ResourceHandle scope planId clusterA ClusterResource Managed phase ->
    OwnershipReceipt scope planId clusterB ClusterResource ->
    Either ReconcileError ()
badReceipt handle receipt =
    validateOwnershipReceipt handle receipt
