module CoerceClusterAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.Cluster.Lifecycle (PlanOwnedCluster)
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Substrate.Provider.Backend (RunningProviderDependency)

data Scope
data Spec
data ConfigId
data Cfg mode
data ClusterId
data ClusterFrame
data ProviderId
data ProviderFrame
data BudgetId
data Provider
data CapabilityId
data WallSpecId
data WorkloadSetId
data PartitionId
data OperationKey
data CallDigest
data Attempt
data JournalVersion
data Phase

data PackagePlanA
data PackagePlanB
data ReconcilePlanA
data ReconcilePlanB
data SettlementPlanA
data SettlementPlanB
data ReconcileResultPlanA
data ReconcileResultPlanB
data PreparedCordonPlanA
data PreparedCordonPlanB
data CordonResultPlanA
data CordonResultPlanB
data AppliedCordonPlanA
data AppliedCordonPlanB
data ReadinessPlanA
data ReadinessPlanB
data ReadinessResultPlanA
data ReadinessResultPlanB
data CleanupPlanA
data CleanupPlanB
data CleanupResultPlanA
data CleanupResultPlanB
data ManagedPlanA
data ManagedPlanB
data DependencyPlanA
data DependencyPlanB

type Package planId =
  PlanOwnedCluster
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId

type ReconcileCall planId =
  PreparedClusterReconcile
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId
    OperationKey CallDigest Attempt JournalVersion

type Settlement planId = ClusterReconcileSettlement Scope planId ClusterId

type ReconcileResult planId =
  ClusterReconcileCallResult
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId
    OperationKey CallDigest Attempt JournalVersion

type Cordon planId =
  PreparedClusterCordon
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId Phase

type CordonResult planId =
  ClusterCordonCallResult
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId Phase

type AppliedCordon planId =
  AppliedClusterCordon
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId Phase

type Readiness planId = ClusterReadiness Scope planId ClusterId Phase

type ReadinessResult planId =
  ClusterReadinessCallResult
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId Phase

type Cleanup planId =
  PreparedClusterCleanup
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId Phase

type CleanupResult planId =
  ClusterCleanupCallResult
    Scope Spec planId ConfigId Cfg ClusterId ClusterFrame ProviderId ProviderFrame
    BudgetId Provider CapabilityId WallSpecId WorkloadSetId PartitionId Phase

type Managed planId = ManagedClusterHandle Scope planId ClusterId Phase

coercePackage :: Package PackagePlanA -> Package PackagePlanB
coercePackage = coerce

coerceReconcile :: ReconcileCall ReconcilePlanA -> ReconcileCall ReconcilePlanB
coerceReconcile = coerce

coerceSettlement :: Settlement SettlementPlanA -> Settlement SettlementPlanB
coerceSettlement = coerce

coerceReconcileResult :: ReconcileResult ReconcileResultPlanA -> ReconcileResult ReconcileResultPlanB
coerceReconcileResult = coerce

coercePreparedCordon :: Cordon PreparedCordonPlanA -> Cordon PreparedCordonPlanB
coercePreparedCordon = coerce

coerceCordonResult :: CordonResult CordonResultPlanA -> CordonResult CordonResultPlanB
coerceCordonResult = coerce

coerceAppliedCordon :: AppliedCordon AppliedCordonPlanA -> AppliedCordon AppliedCordonPlanB
coerceAppliedCordon = coerce

coerceReadiness :: Readiness ReadinessPlanA -> Readiness ReadinessPlanB
coerceReadiness = coerce

coerceReadinessResult :: ReadinessResult ReadinessResultPlanA -> ReadinessResult ReadinessResultPlanB
coerceReadinessResult = coerce

coerceCleanup :: Cleanup CleanupPlanA -> Cleanup CleanupPlanB
coerceCleanup = coerce

coerceCleanupResult :: CleanupResult CleanupResultPlanA -> CleanupResult CleanupResultPlanB
coerceCleanupResult = coerce

coerceManaged :: Managed ManagedPlanA -> Managed ManagedPlanB
coerceManaged = coerce

coerceRunningDependency ::
  RunningProviderDependency Scope DependencyPlanA ProviderId ->
  RunningProviderDependency Scope DependencyPlanB ProviderId
coerceRunningDependency = coerce
