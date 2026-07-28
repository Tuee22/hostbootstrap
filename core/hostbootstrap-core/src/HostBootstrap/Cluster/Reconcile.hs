{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Ownership-aware reconciliation for the kind cluster resource.

This is the § EE total ownership classification for a same-named cluster,
expressed over Phase 9's opaque resource/receipt algebra exactly as the
provider-guest alias backend is (see "HostBootstrap.Substrate.Provider.Alias").
Observation is total (§ CC): absence, a healthy cluster this plan owns, a
healthy cluster it does not, and a listed-but-unhealthy cluster are distinct
outcomes, and only a receipt authorizes cleanup.

The load-bearing rule this module encodes and Sprint 5.7 requires: a healthy
same-named cluster without committed ownership is a 'ForeignResult', and an
unhealthy or unverifiable same-named cluster is a 'Conflict' that is /never/
automatically deleted — replacing the previous "delete and recreate an
unhealthy cluster" behavior in "HostBootstrap.Cluster.Lifecycle". Conditional
cleanup re-observes the cluster's generation and refuses to remove a
replacement this plan does not own.

This module owns only the classification and receipt gating. The IO backend
that produces these observations while holding the four clauses, and the
plan-driven wiring that replaces the imperative @ensureCluster@ path, are the
coordinated 10.9/16.6 tranche's to consume.
-}
module HostBootstrap.Cluster.Reconcile (
    ClusterObservation (..),
    PreparedClusterReconcile,
    withPreparedClusterReconcile,
    settleClusterReconcile,
    ClusterCleanupObservation (..),
    PreparedClusterCleanup,
    withPreparedClusterCleanup,
    settleClusterCleanup,
)
where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ClusterResource,
    ConflictDetail (..),
    FailureDetail (..),
    ForeignObservation (..),
    LifecyclePlan,
    Managed,
    Observed,
    OwnershipReceipt,
    PlannedResource,
    PreparedOperation,
    PreparedPreconditions,
    PriorCommitProof,
    ProviderResource,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (ReprobeBeforeRetry),
    ResourceHandle,
    Unclassified,
    completePreparedUnchanged,
    completeReconcile,
    dependencyObservation,
    plannedOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    validateOwnershipReceipt,
    withPreparedSingleDependencyOperation,
 )

{- | The total observation of a same-named cluster after the reconcile action.
'ClusterCreated' means a previously absent cluster was created and re-observed
healthy; 'ClusterHealthy' is a healthy cluster whose ownership settlement
depends on prior commit proof; 'ClusterUnhealthy' is a listed-but-unhealthy
cluster (a conflict, never a silent delete); 'ClusterProbeFailed' is an IO fault
in the probe itself.
-}
data ClusterObservation
    = ClusterCreated Word64
    | ClusterHealthy Word64
    | ClusterUnhealthy Word64
    | ClusterProbeFailed Text
    deriving (Eq, Show)

{- | An opaque prepared cluster reconcile: the observed handle plus the exact
prepared operation and preconditions it must settle against.
-}
data PreparedClusterReconcile scope planId clusterId operationKey callDigest attempt journalVersion
    = PreparedClusterReconcile
        (ResourceHandle scope planId clusterId ClusterResource Unclassified Observed)
        (PreparedOperation scope planId clusterId ClusterResource operationKey callDigest attempt journalVersion)
        (PreparedPreconditions scope planId clusterId ClusterResource operationKey callDigest attempt journalVersion)

{- | Prepare a cluster reconcile over the planned cluster resource, its observed
handle, and the managed provider/VM frame it depends on (the plan edge
@core:deploy-kind@ → @core:deploy-vm@).  The dependency observation is derived
from the managed VM handle at @dependencyVersion@.
-}
withPreparedClusterReconcile ::
    LifecyclePlan scope planId ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    ResourceHandle scope planId clusterId ClusterResource Unclassified Observed ->
    ResourceHandle scope planId providerId ProviderResource Managed providerPhase ->
    Word64 ->
    Word64 ->
    Word64 ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedClusterReconcile scope planId clusterId operationKey callDigest attempt journalVersion ->
      result
    ) ->
    Either ReconcileError result
withPreparedClusterReconcile plan planned observed vmHandle dependencyVersion attempt journalVersion consume = do
    descriptor <- plannedOperation plan planned observed "cluster:reconcile"
    vmDependency <- dependencyObservation vmHandle dependencyVersion
    withPreparedSingleDependencyOperation
        descriptor
        vmDependency
        attempt
        journalVersion
        ( \prepared preconditions ->
            consume (PreparedClusterReconcile observed prepared preconditions)
        )

{- | Settle a cluster observation into a receipt-preserving 'ReconcileResult'.
A healthy cluster without prior commit proof is explicitly foreign; an unhealthy
same-named cluster is a 'Conflict' that is never automatically deleted.
-}
settleClusterReconcile ::
    Maybe (PriorCommitProof scope planId clusterId ClusterResource) ->
    PreparedClusterReconcile scope planId clusterId operationKey callDigest attempt journalVersion ->
    ClusterObservation ->
    Either ReconcileError (ReconcileResult scope planId clusterId ClusterResource Provisioned)
settleClusterReconcile
    priorProof
    (PreparedClusterReconcile handle prepared preconditions)
    observation =
        case observation of
            ClusterCreated generation ->
                completeReconcile handle prepared preconditions (BackendCreated generation)
            ClusterHealthy generation
                | generation /= resourceHandleGeneration handle ->
                    Left
                        ( Conflict
                            ( ConflictDetail
                                (resourceHandleKey handle)
                                ("generation=" <> showText (resourceHandleGeneration handle))
                                ("generation=" <> showText generation)
                                "reprobe the cluster before classifying the healthy observation"
                            )
                        )
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile
                        handle
                        prepared
                        preconditions
                        ( BackendForeign
                            generation
                            ( ForeignObservation
                                (resourceHandleKey handle)
                                "a healthy same-named cluster exists without committed ownership"
                            )
                        )
            ClusterUnhealthy generation ->
                Left
                    ( Conflict
                        ( ConflictDetail
                            (resourceHandleKey handle)
                            "a healthy cluster owned by this plan"
                            ("an unhealthy same-named cluster (generation=" <> showText generation <> ")")
                            "resolve or remove the unhealthy cluster by hand; a same-named cluster is never auto-deleted"
                        )
                    )
            ClusterProbeFailed reason ->
                Left (Failure (FailureDetail "reconcile cluster" reason ReprobeBeforeRetry))

-- | The total observation of a cluster at cleanup time.
data ClusterCleanupObservation
    = ClusterCleanupRemoved
    | ClusterCleanupReplaced Word64
    deriving (Eq, Show)

{- | An opaque prepared cluster cleanup.  It type-checks only against a 'Managed'
handle and a receipt that matches the exact managed generation, so a
foreign/unmanaged cluster observation cannot authorize a delete.
-}
data PreparedClusterCleanup scope planId clusterId phase
    = PreparedClusterCleanup
        (ResourceHandle scope planId clusterId ClusterResource Managed phase)
        (OwnershipReceipt scope planId clusterId ClusterResource)

{- | Prepare conditional cleanup; requires a managed handle and a matching
receipt.
-}
withPreparedClusterCleanup ::
    ResourceHandle scope planId clusterId ClusterResource Managed phase ->
    OwnershipReceipt scope planId clusterId ClusterResource ->
    (PreparedClusterCleanup scope planId clusterId phase -> result) ->
    Either ReconcileError result
withPreparedClusterCleanup handle receipt consume = do
    validateOwnershipReceipt handle receipt
    Right (consume (PreparedClusterCleanup handle receipt))

{- | Settle a cluster cleanup: removal (or an already-absent cluster) succeeds,
but a replacement carrying a different generation is a 'Conflict' and the
replacement is left untouched — cleanup never removes state this plan does not
own.
-}
settleClusterCleanup ::
    PreparedClusterCleanup scope planId clusterId phase ->
    ClusterCleanupObservation ->
    Either ReconcileError ()
settleClusterCleanup (PreparedClusterCleanup handle _) observation =
    case observation of
        ClusterCleanupRemoved -> Right ()
        ClusterCleanupReplaced generation ->
            Left
                ( Conflict
                    ( ConflictDetail
                        (resourceHandleKey handle)
                        ("generation=" <> showText (resourceHandleGeneration handle))
                        ("generation=" <> showText generation)
                        "a different cluster now holds the name; refusing to delete state this plan does not own"
                    )
                )

showText :: (Show value) => value -> Text
showText = Text.pack . show
