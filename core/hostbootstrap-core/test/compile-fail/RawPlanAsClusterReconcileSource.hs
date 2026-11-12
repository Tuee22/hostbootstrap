{- | Cluster preparation requires its closed plan-owned package and opaque
Running provider dependency. A raw project plan or dependency snapshot cannot
replace either independently checked input.
-}
module RawPlanAsClusterReconcileSource where

import HostBootstrap.Cluster.Lifecycle (PlanOwnedClusterConfig)
import HostBootstrap.Cluster.Reconcile (withPreparedClusterReconcile)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.Reconcile (DependencySnapshot, ReconcileError)
import HostBootstrap.Substrate.Provider.Backend (RunningProviderDependency)

rawPlanSource ::
    ProjectPlan scope specDigest planId configId cfg ->
    RunningProviderDependency scope planId providerId ->
    PreparedGate ->
    IO (Either ReconcileError ())
rawPlanSource plan running gate =
    withPreparedClusterReconcile plan running Nothing gate (const ())

rawSnapshotSource ::
    PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    DependencySnapshot scope planId ->
    PreparedGate ->
    IO (Either ReconcileError ())
rawSnapshotSource configured snapshot gate =
    withPreparedClusterReconcile configured snapshot Nothing gate (const ())
