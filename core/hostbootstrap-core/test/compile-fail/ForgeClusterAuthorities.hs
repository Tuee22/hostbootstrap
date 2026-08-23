{- | Public cluster authority constructors remain private; only exact
preparation and settlement can mint them.
-}
module ForgeClusterAuthorities where

import HostBootstrap.Cluster.Lifecycle
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Substrate.Provider.Backend (RunningProviderDependency)

badPlanOwnedCluster = PlanOwnedCluster

badPlanOwnedClusterConfig = PlanOwnedClusterConfig

badPreparedClusterReconcile = PreparedClusterReconcile

badClusterReconcileSettlement = ClusterReconcileSettlement

badClusterReconcileCallResult = ClusterReconcileCallResult

badPreparedClusterCordon = PreparedClusterCordon

badClusterCordonCallResult = ClusterCordonCallResult

badAppliedClusterCordon = AppliedClusterCordon

badClusterReadiness = ClusterReadiness

badClusterReadinessCallResult = ClusterReadinessCallResult

badPreparedClusterCleanup = PreparedClusterCleanup

badClusterCleanupCallResult = ClusterCleanupCallResult

badManagedClusterHandle = ManagedClusterHandle

badRunningProviderDependency = RunningProviderDependency
