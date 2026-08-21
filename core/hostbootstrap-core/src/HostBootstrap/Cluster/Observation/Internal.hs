{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation of settled cluster ownership.  The generic
journal generation remains exactly the one prepared by reconciliation, while
the backend-reported immutable control-plane identity is retained separately
for readiness, cordon, and conditional cleanup.
-}
module HostBootstrap.Cluster.Observation.Internal
    ( ClusterReconcileObservation (..)
    , ClusterBackendBinding (..)
    , clusterBackendBindingIdentity
    , ClusterReconcileCallResult (..)
    , ClusterCordonObservation (..)
    , ClusterCordonCallResult (..)
    , ClusterReadinessObservation (..)
    , ClusterReadinessCallResult (..)
    , ClusterCleanupObservation (..)
    , ClusterCleanupCallResult (..)
    , ManagedClusterHandle (..)
    , managedClusterResourceHandle
    , managedClusterReceipt
    , managedClusterBackendIdentity
    , managedClusterBackendBinding
    )
where

import Data.Text (Text)
import Data.Kind (Type)
import Data.Word (Word64)
import HostBootstrap.ProjectPlan (ClusterResource)
import HostBootstrap.Reconcile
    ( Managed
    , OwnershipReceipt
    , ReconcileError
    , ResourceHandle
    )

-- | Plan-independent report parsed inside the strong reconcile backend.
data ClusterReconcileObservation
    = ClusterCreated ClusterBackendBinding
    | ClusterHealthy ClusterBackendBinding
    | ClusterForeign Text
    | ClusterUnhealthy Text
    | ClusterProbeFailed Text
    deriving (Eq, Show)

{- | The container identity a successful strong backend report bound.

One field, because one is what clause 3 binds: the immutable identity of the
node container the cluster's own durable record names. The state directory, the
exclusive entry, and the durable record are the protected store's, so nothing
about where they live is retained here — a later operation re-enters through the
store rather than through a kernel object this value remembered.

The generic journal generation is unaffected and stays exactly where
reconciliation prepared it.
-}
newtype ClusterBackendBinding = ClusterBackendBinding Text
    deriving (Eq, Show)

clusterBackendBindingIdentity :: ClusterBackendBinding -> Text
clusterBackendBindingIdentity (ClusterBackendBinding identity) = identity

-- | Proof that the strong backend executed one exact prepared reconcile call.
newtype ClusterReconcileCallResult scope specDigest planId configId (cfg :: Type -> Type) clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion =
    ClusterReconcileCallResult ClusterReconcileObservation
    deriving (Eq, Show)

type role ClusterReconcileCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | Plan-independent report parsed inside the strong cordon backend.
data ClusterCordonObservation
    = ClusterCordonApplied
    | ClusterCordonReplaced Text
    | ClusterCordonFailed Text
    deriving (Eq, Show)

-- | Proof that the strong backend executed one exact prepared cordon call.
newtype ClusterCordonCallResult scope specDigest planId configId (cfg :: Type -> Type) clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase =
    ClusterCordonCallResult ClusterCordonObservation
    deriving (Eq, Show)

type role ClusterCordonCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | Plan-independent report parsed inside the strong readiness backend.
data ClusterReadinessObservation
    = ClusterReady Text
    | ClusterNotReady Text
    | ClusterReadinessProbeFailed Text
    deriving (Eq, Show)

{- | Proof that the strong backend executed one exact readiness call.

The version is positive only when this call freshly observed the same managed
container identity with both the API and every node ready.  The retained action
reruns that exact backend/applied-cordon pair and is never projected publicly.
-}
data ClusterReadinessCallResult scope specDigest planId configId (cfg :: Type -> Type) clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase =
    ClusterReadinessCallResult
        Word64
        ClusterReadinessObservation
        ( IO
            ( ClusterReadinessCallResult
                scope
                specDigest
                planId
                configId
                cfg
                clusterId
                clusterFrame
                providerId
                providerFrame
                budgetId
                provider
                capabilityId
                wallSpecId
                workloadSetId
                partitionId
                phase
            )
        )

type role ClusterReadinessCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | Plan-independent report parsed inside the strong cleanup backend.
data ClusterCleanupObservation
    = ClusterCleanupRemoved
    | ClusterCleanupReplaced Text
    | ClusterCleanupFailed ReconcileError
    deriving (Eq, Show)

-- | Proof that the strong backend executed one exact prepared cleanup call.
newtype ClusterCleanupCallResult scope specDigest planId configId (cfg :: Type -> Type) clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase =
    ClusterCleanupCallResult ClusterCleanupObservation
    deriving (Eq, Show)

type role ClusterCleanupCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

data ManagedClusterHandle scope planId clusterId phase =
    ManagedClusterHandle
        (ResourceHandle scope planId clusterId ClusterResource Managed phase)
        (OwnershipReceipt scope planId clusterId ClusterResource)
        ClusterBackendBinding

type role ManagedClusterHandle nominal nominal nominal nominal

managedClusterResourceHandle ::
    ManagedClusterHandle scope planId clusterId phase ->
    ResourceHandle scope planId clusterId ClusterResource Managed phase
managedClusterResourceHandle (ManagedClusterHandle handle _ _) = handle

managedClusterReceipt ::
    ManagedClusterHandle scope planId clusterId phase ->
    OwnershipReceipt scope planId clusterId ClusterResource
managedClusterReceipt (ManagedClusterHandle _ receipt _) = receipt

managedClusterBackendIdentity ::
    ManagedClusterHandle scope planId clusterId phase ->
    Text
managedClusterBackendIdentity (ManagedClusterHandle _ _ binding) =
    clusterBackendBindingIdentity binding

managedClusterBackendBinding ::
    ManagedClusterHandle scope planId clusterId phase ->
    ClusterBackendBinding
managedClusterBackendBinding (ManagedClusterHandle _ _ binding) = binding
