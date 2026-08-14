{- | The removed cluster consumer shape must not accept a compatibility plan or
caller-assembled dependency snapshot.
-}
module CompatibilityClusterInputs where

import HostBootstrap.Cluster.Reconcile (withPreparedClusterReconcile)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Reconcile
  ( ClusterResource,
    DependencySnapshot,
    LifecyclePlan,
    Observed,
    PlannedResource,
    ReconcileError,
    ResourceHandle,
    Unclassified,
  )

compatibilityPreparation ::
  LifecyclePlan scope planId ->
  PlannedResource scope planId clusterId ClusterResource clusterFrame ->
  ResourceHandle scope planId clusterId ClusterResource Unclassified Observed ->
  DependencySnapshot scope planId ->
  PreparedGate ->
  IO (Either ReconcileError ())
compatibilityPreparation plan cluster observed snapshot gate =
  withPreparedClusterReconcile plan cluster observed snapshot gate (const ())
