{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Exact, plan-owned cluster reconciliation.

Raw observations remain plan-independent backend data.  Preparation joins one
admitted 'ProjectPlan' to its exact cluster resource, direct provider resource,
retained topology, and cluster budget slice.  The module accepts neither the
compatibility @LifecyclePlan@ nor a caller-assembled dependency snapshot.
-}
module HostBootstrap.Cluster.Reconcile (
    ClusterReconcileCallResult,
    ClusterReconcileResultView (..),
    clusterReconcileResultView,
    PreparedClusterReconcile,
    withPreparedClusterReconcile,
    preparedClusterReconcileHandle,
    preparedClusterName,
    preparedClusterStateDirectory,
    preparedClusterDurableRoot,
    preparedClusterPublishesHostPorts,
    preparedClusterConfigPath,
    preparedClusterConfigDigest,
    preparedClusterDriver,
    preparedClusterConfigBytes,
    preparedClusterLoopbackPorts,
    preparedClusterNodeMappings,
    preparedClusterWorkloadSlice,
    withPreparedPlanOwnedClusterConfig,
    preparedClusterPlacement,
    preparedClusterProviderKey,
    preparedClusterOwnershipIdentity,
    preparedClusterBudget,
    preparedClusterNodeNames,
    ManagedClusterHandle,
    managedClusterKey,
    managedClusterGeneration,
    ClusterReconcileSettlement,
    withClusterReconcileSettlement,
    carryClusterReconcileSettlement,
    settleClusterReconcile,
    ClusterCordonCallResult,
    ClusterCordonResultView (..),
    clusterCordonResultView,
    PreparedClusterCordon,
    withPreparedClusterCordon,
    preparedClusterCordonHandle,
    preparedClusterCordonName,
    preparedClusterCordonStateDirectory,
    preparedClusterCordonOwnershipIdentity,
    preparedClusterCordonNodeNames,
    preparedClusterCordonBudget,
    AppliedClusterCordon,
    appliedClusterCordonHandle,
    appliedClusterCordonName,
    appliedClusterCordonStateDirectory,
    appliedClusterCordonOwnershipIdentity,
    appliedClusterCordonNodeNames,
    settleClusterCordon,
    ClusterReadinessCallResult,
    ClusterReadinessResultView (..),
    clusterReadinessResultView,
    ClusterReadiness,
    settleClusterReadiness,
    withFreshClusterReadiness,
    reprobeClusterReadiness,
    clusterReadinessProbe,
    withClusterReadinessResourceHandle,
    withRecoveredClusterReadiness,
    ClusterCleanupCallResult,
    ClusterCleanupResultView (..),
    clusterCleanupResultView,
    PreparedClusterCleanup,
    withPreparedClusterCleanup,
    preparedClusterCleanupHandle,
    preparedCleanupClusterName,
    preparedCleanupStateDirectory,
    preparedCleanupOwnershipIdentity,
    preparedCleanupConfigPath,
    preparedCleanupNodeNames,
    settleClusterCleanup,
    runExactClusterCleanupKernel,
)
where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.Char (digitToInt)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import Data.IORef (atomicModifyIORef', newIORef)
import Numeric.Natural (Natural)
import HostBootstrap.Authority (ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp))
import HostBootstrap.Cluster.Cordon.Foundation (
    ResourceBudget,
    budgetCpu,
    budgetMemoryBytes,
    budgetStorageBytes,
 )
import HostBootstrap.Cluster.Lifecycle (
    ClusterDriver,
    PlanOwnedCluster,
    PlanOwnedClusterConfig,
    planOwnedClusterConfigBase,
    planOwnedClusterConfigBytes,
    planOwnedClusterConfigDigest,
    planOwnedClusterConfigDriver,
    planOwnedClusterConfigLoopbackPorts,
    planOwnedClusterConfigNodeMappings,
    planOwnedClusterConfigWorkloadSlice,
    planOwnedRenderedConfigPath,
    planOwnedClusterBudget,
    planOwnedClusterDurableRoot,
    planOwnedClusterName,
    planOwnedClusterNodeNames,
    planOwnedClusterOwnershipIdentity,
    planOwnedClusterPlacement,
    planOwnedClusterProviderKey,
    planOwnedClusterPublishesHostPorts,
    planOwnedClusterStateDirectory,
    withPlanOwnedClusterPreparation,
 )
import HostBootstrap.Cluster.Observation.Internal (
    ClusterBackendBinding,
    ClusterCleanupCallResult (..),
    ClusterCleanupObservation (..),
    ClusterCordonCallResult (..),
    ClusterCordonObservation (..),
    ClusterReadinessCallResult (..),
    ClusterReadinessObservation (..),
    ClusterReconcileCallResult (..),
    ClusterReconcileObservation (..),
    ManagedClusterHandle (..),
    clusterBackendBindingIdentity,
    managedClusterBackendIdentity,
    managedClusterReceipt,
    managedClusterResourceHandle,
 )
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
 )
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.ProjectPlan (
    ClusterResource,
    ProjectPlan,
    renderSnapshot,
    stablePlanSnapshotDigest,
 )
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ChangeView,
    ConflictDetail (..),
    DependencyProbe,
    FailureDetail (..),
    ForeignObservation (..),
    Managed,
    Observed,
    OwnershipReceipt,
    PreparedOperation,
    PreparedPreconditions,
    PriorCommitProof,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    ResourceHandle,
    Unclassified,
    completePreparedUnchanged,
    completeReconcile,
    carryManagedResourceSettlement,
    dependencyProbe,
    emptyDependencySnapshot,
    plannedNodeOperation,
    plannedProjectOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
    validateOwnershipReceipt,
    withDependencySnapshotEntry,
    withNodeObservedResource,
    withObservedProjectResource,
    withOperationPreconditions,
    withPreparedOperation,
    withReconcileResult,
 )
import HostBootstrap.Substrate.Provider.Dependency.Internal (
    RunningProviderDependency,
    runningProviderDependencyHandle,
    runningProviderDependencyReprobe,
 )
import HostBootstrap.Teardown (
    LocalWork,
    TeardownAction (DeleteCluster),
    TeardownOutcome (TeardownFailed, TeardownReleased),
    localWorkAction,
    localWorkKey,
 )

{- | The complete prepared reconcile.  Every source-package identity remains a
nominal index through the effect boundary.
-}
data
    PreparedClusterReconcile
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
        operationKey
        callDigest
        attempt
        journalVersion
    = PreparedClusterReconcile
        ( PlanOwnedClusterConfig
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
        )
        (Maybe PreparedClusterConfig)
        (ResourceHandle scope planId clusterId ClusterResource Unclassified Observed)
        (PreparedOperation scope planId clusterId ClusterResource operationKey callDigest attempt journalVersion)
        (PreparedPreconditions scope planId clusterId ClusterResource operationKey callDigest attempt journalVersion)

type role PreparedClusterReconcile nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Exact bytes observed at preparation for the plan-derived config path.
The constructor is private; the backend receives only path/digest
projections and revalidates both under the ownership lock before mutation.
-}
data PreparedClusterConfig = PreparedClusterConfig FilePath Text

{- | Prepare only the exact package projected by one admitted plan.

The provider probe is paired internally with the exact managed provider handle;
there is no caller-supplied dependency snapshot, digest, frame, cluster profile,
or independently resolved root.
-}
withPreparedClusterReconcile ::
    PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    RunningProviderDependency scope planId providerId ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedClusterReconcile
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
        operationKey
        callDigest
        attempt
        journalVersion ->
      result
    ) ->
    IO (Either ReconcileError result)
withPreparedClusterReconcile
    configured
    runningProvider
    gate
    consume = do
        withPlanOwnedClusterPreparation
            package
            (\plan cluster ->
                case withObservedProjectResource plan cluster generation version id of
                    Left err -> pure (Left err)
                    Right observed -> finish observed (plannedProjectOperation plan cluster observed digest))
            (\execution cluster ->
                case withNodeObservedResource execution cluster generation version id of
                    Left err -> pure (Left err)
                    Right observed -> finish observed (plannedNodeOperation execution cluster observed digest))
  where
    package = planOwnedClusterConfigBase configured
    configBinding = Just (PreparedClusterConfig (planOwnedRenderedConfigPath configured) (planOwnedClusterConfigDigest configured))
    generation = clusterResourceGeneration package
    version = preparedGateJournalVersion gate
    digest = clusterCallDigest package configBinding
    finish observed described = case described of
        Left err -> pure (Left err)
        Right descriptor -> do
            let snapshot =
                    withDependencySnapshotEntry
                        (runningProviderDependencyHandle runningProvider)
                        (dependencyProbe (runningProviderDependencyReprobe runningProvider))
                        emptyDependencySnapshot
            sealed <- withOperationPreconditions descriptor snapshot
            pure $ do
                preconditionSet <- sealed
                withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions ->
                    consume (PreparedClusterReconcile configured configBinding observed prepared preconditions)

{- | Stable generation of this exact admitted cluster resource.

The generic journal model requires a positive resource generation before the
effect runs.  Cluster identity itself is not available until creation, so it is
retained separately in 'ManagedClusterHandle'.  This generation is instead a
stable cryptographic projection of the plan-owned owner/resource identity;
retries and prior-commit recovery therefore agree, while callers cannot select
it.  The fresh phase-observation version comes from the durable prepare gate.
-}
clusterResourceGeneration ::
    PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    Word64
clusterResourceGeneration package =
    let digest = hash (TextEncoding.encodeUtf8 (planOwnedClusterOwnershipIdentity package)) :: Digest SHA256
        hex = Text.take 16 (TextEncoding.decodeUtf8 (convertToBase Base16 digest))
        generation = Text.foldl' (\value digit -> value * 16 + fromIntegral (digitToInt digit)) 0 hex
     in if generation == 0 then 1 else generation

clusterCallDigest :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Maybe PreparedClusterConfig -> Text
clusterCallDigest package configBinding =
    let budget = planOwnedClusterBudget package
        configDigest = maybe "config-absent" (\(PreparedClusterConfig _ digest) -> "config-" <> digest) configBinding
     in Text.intercalate
            ":"
            [ "cluster-reconcile"
            , planOwnedClusterOwnershipIdentity package
            , planOwnedClusterProviderKey package
            , fst (planOwnedClusterPlacement package)
            , snd (planOwnedClusterPlacement package)
            , Text.pack (show (budgetCpu budget))
            , Text.pack (show (budgetMemoryBytes budget))
            , Text.pack (show (budgetStorageBytes budget))
            , configDigest
            ]

preparedClusterReconcileHandle ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ResourceHandle scope planId clusterId ClusterResource Unclassified Observed
preparedClusterReconcileHandle (PreparedClusterReconcile _ _ handle _ _) = handle

preparedClusterName :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> String
preparedClusterName (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterName (planOwnedClusterConfigBase package)

preparedClusterStateDirectory :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> FilePath
preparedClusterStateDirectory (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterStateDirectory (planOwnedClusterConfigBase package)

preparedClusterDurableRoot :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> FilePath
preparedClusterDurableRoot (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterDurableRoot (planOwnedClusterConfigBase package)

preparedClusterPublishesHostPorts :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Bool
preparedClusterPublishesHostPorts (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterPublishesHostPorts (planOwnedClusterConfigBase package)

preparedClusterConfigPath :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Maybe FilePath
preparedClusterConfigPath (PreparedClusterReconcile _ config _ _ _) =
    fmap (\(PreparedClusterConfig path _) -> path) config

preparedClusterConfigDigest :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Maybe Text
preparedClusterConfigDigest (PreparedClusterReconcile _ config _ _ _) =
    fmap (\(PreparedClusterConfig _ digest) -> digest) config

preparedClusterDriver :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> ClusterDriver
preparedClusterDriver (PreparedClusterReconcile configured _ _ _ _) = planOwnedClusterConfigDriver configured

preparedClusterConfigBytes :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> ByteString
preparedClusterConfigBytes (PreparedClusterReconcile configured _ _ _ _) = planOwnedClusterConfigBytes configured

preparedClusterLoopbackPorts :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> [(Text, Natural)]
preparedClusterLoopbackPorts (PreparedClusterReconcile configured _ _ _ _) = planOwnedClusterConfigLoopbackPorts configured

preparedClusterNodeMappings :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> [(Text, Text)]
preparedClusterNodeMappings (PreparedClusterReconcile configured _ _ _ _) = planOwnedClusterConfigNodeMappings configured

preparedClusterWorkloadSlice :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> [Text]
preparedClusterWorkloadSlice (PreparedClusterReconcile configured _ _ _ _) = planOwnedClusterConfigWorkloadSlice configured

withPreparedPlanOwnedClusterConfig ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    (PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> result) ->
    result
withPreparedPlanOwnedClusterConfig (PreparedClusterReconcile configured _ _ _ _) consume = consume configured

preparedClusterPlacement :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> (Text, Text)
preparedClusterPlacement (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterPlacement (planOwnedClusterConfigBase package)

preparedClusterProviderKey :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Text
preparedClusterProviderKey (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterProviderKey (planOwnedClusterConfigBase package)

preparedClusterOwnershipIdentity :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Text
preparedClusterOwnershipIdentity (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterOwnershipIdentity (planOwnedClusterConfigBase package)

preparedClusterBudget :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> ResourceBudget
preparedClusterBudget (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterBudget (planOwnedClusterConfigBase package)

preparedClusterNodeNames :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> [String]
preparedClusterNodeNames (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterNodeNames (planOwnedClusterConfigBase package)

-- | Descriptive projections from the opaque settled cluster authority.
managedClusterKey :: ManagedClusterHandle scope planId clusterId phase -> Text
managedClusterKey = resourceHandleKey . managedClusterResourceHandle

managedClusterGeneration :: ManagedClusterHandle scope planId clusterId phase -> Word64
managedClusterGeneration = resourceHandleGeneration . managedClusterResourceHandle

-- | Descriptive, non-authorizing projection of a strong-backend result.
data ClusterReconcileResultView
    = ClusterResultCreated Text
    | ClusterResultHealthy Text
    | ClusterResultForeign Text
    | ClusterResultUnhealthy Text
    | ClusterResultProbeFailed Text
    deriving (Eq, Show)

clusterReconcileResultView ::
    ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ClusterReconcileResultView
clusterReconcileResultView (ClusterReconcileCallResult observation) = case observation of
    ClusterCreated binding -> ClusterResultCreated (clusterBackendBindingIdentity binding)
    ClusterHealthy binding -> ClusterResultHealthy (clusterBackendBindingIdentity binding)
    ClusterForeign identity -> ClusterResultForeign identity
    ClusterUnhealthy identity -> ClusterResultUnhealthy identity
    ClusterProbeFailed reason -> ClusterResultProbeFailed reason

{- | Settlement never relabels the prepared journal generation with a backend
identity.  The managed branch retains both values in the opaque handle; the
foreign branch carries description only and grants no mutation authority.
-}
data ClusterReconcileSettlement scope planId clusterId
    = ManagedClusterProvision
        (ManagedClusterHandle scope planId clusterId Provisioned)
        (OwnershipReceipt scope planId clusterId ClusterResource)
        ChangeView
    | ForeignClusterProvision Text Word64 Word64 ForeignObservation

type role ClusterReconcileSettlement nominal nominal nominal

withClusterReconcileSettlement ::
    ClusterReconcileSettlement scope planId clusterId ->
    (ManagedClusterHandle scope planId clusterId Provisioned -> OwnershipReceipt scope planId clusterId ClusterResource -> ChangeView -> result) ->
    (Text -> Word64 -> Word64 -> ForeignObservation -> result) ->
    result
withClusterReconcileSettlement settlement consumeManaged consumeForeign =
    case settlement of
        ManagedClusterProvision managed receipt change -> consumeManaged managed receipt change
        ForeignClusterProvision key generation version foreignObservation ->
            consumeForeign key generation version foreignObservation

carryClusterReconcileSettlement ::
    StepExecution scope planId ->
    ManagedClusterHandle scope planId clusterId phase ->
    OwnershipReceipt scope planId clusterId ClusterResource ->
    IO (Either ReconcileError ())
carryClusterReconcileSettlement execution managed receipt =
    carryManagedResourceSettlement execution (managedClusterResourceHandle managed) receipt "provisioned" "cluster-reconcile-v1"

settleClusterReconcile ::
    Maybe (PriorCommitProof scope planId clusterId ClusterResource) ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ClusterReconcileSettlement scope planId clusterId)
settleClusterReconcile priorProof (PreparedClusterReconcile _package _config handle prepared preconditions) (ClusterReconcileCallResult observation) =
    case observation of
        ClusterCreated binding -> do
            reconciled <-
                completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendCreated (resourceHandleGeneration handle))
            clusterSettlement binding reconciled
        ClusterHealthy binding
            | Just proof <- priorProof ->
                completePreparedUnchanged handle prepared preconditions proof
                    >>= clusterSettlement binding
            | otherwise ->
                completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendRepaired (resourceHandleGeneration handle))
                    >>= clusterSettlement binding
        ClusterForeign identity ->
            completeReconcile
                handle
                prepared
                preconditions
                ( BackendForeign
                    (resourceHandleGeneration handle)
                    (ForeignObservation (resourceHandleKey handle) ("a same-named cluster exists without the exact durable origin; identity=" <> identity))
                )
                >>= clusterForeignSettlement
        ClusterUnhealthy identity ->
            Left
                ( Conflict
                    ( ConflictDetail
                        (resourceHandleKey handle)
                        "a healthy cluster owned by this plan"
                        ("an unhealthy same-named cluster (identity=" <> identity <> ")")
                        "resolve or remove the unhealthy cluster by hand; a same-named cluster is never auto-deleted"
                    )
                )
        ClusterProbeFailed reason ->
            Left (Failure (FailureDetail "reconcile cluster" reason ReprobeBeforeRetry))

clusterSettlement ::
    ClusterBackendBinding ->
    ReconcileResult scope planId clusterId ClusterResource Provisioned ->
    Either ReconcileError (ClusterReconcileSettlement scope planId clusterId)
clusterSettlement binding reconciled
    | Text.null identity =
        Left (Failure (FailureDetail "settle cluster" "the backend reported an empty control-plane identity" DoNotRetry))
    | otherwise =
        withReconcileResult
            reconciled
            ( \handle receipt change -> do
                validateOwnershipReceipt handle receipt
                Right (ManagedClusterProvision (ManagedClusterHandle handle receipt binding) receipt change)
            )
            ( \foreignHandle foreignObservation ->
                Right
                    ( ForeignClusterProvision
                        (resourceHandleKey foreignHandle)
                        (resourceHandleGeneration foreignHandle)
                        (resourceHandleObservationVersion foreignHandle)
                        foreignObservation
                    )
            )
  where
    identity = clusterBackendBindingIdentity binding

clusterForeignSettlement ::
    ReconcileResult scope planId clusterId ClusterResource Provisioned ->
    Either ReconcileError (ClusterReconcileSettlement scope planId clusterId)
clusterForeignSettlement reconciled =
    withReconcileResult
        reconciled
        (\_ _ _ -> Left (Failure (FailureDetail "settle foreign cluster" "the backend returned managed authority for a foreign observation" DoNotRetry)))
        ( \foreignHandle foreignObservation ->
            Right
                ( ForeignClusterProvision
                    (resourceHandleKey foreignHandle)
                    (resourceHandleGeneration foreignHandle)
                    (resourceHandleObservationVersion foreignHandle)
                    foreignObservation
                )
        )

-- | Descriptive, non-authorizing projection of a strong cordon result.
data ClusterCordonResultView
    = ClusterCordonResultApplied
    | ClusterCordonResultReplaced Text
    | ClusterCordonResultFailed Text
    deriving (Eq, Show)

clusterCordonResultView ::
    ClusterCordonCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterCordonResultView
clusterCordonResultView (ClusterCordonCallResult observation) = case observation of
    ClusterCordonApplied -> ClusterCordonResultApplied
    ClusterCordonReplaced identity -> ClusterCordonResultReplaced identity
    ClusterCordonFailed reason -> ClusterCordonResultFailed reason

{- | Cordon authority exists only after the exact reconcile settled to a
managed handle and its matching ownership receipt.
-}
data
    PreparedClusterCordon
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
    = PreparedClusterCordon
        ( PlanOwnedClusterConfig
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
        )
        (ManagedClusterHandle scope planId clusterId phase)

type role PreparedClusterCordon nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedClusterCordon ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ManagedClusterHandle scope planId clusterId phase ->
    (PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> result) ->
    Either ReconcileError result
withPreparedClusterCordon (PreparedClusterReconcile package _ observed _ _) managed consume = do
    let handle = managedClusterResourceHandle managed
    if sameObservedResource observed handle
        then Right ()
        else
            Left
                ( Conflict
                    ( ConflictDetail
                        (resourceHandleKey observed)
                        ("prepared binding " <> resourceBinding observed)
                        ("managed binding " <> resourceBinding handle)
                        "use the managed cluster minted by this exact preparation"
                    )
                )
    validateOwnershipReceipt handle (managedClusterReceipt managed)
    Right (consume (PreparedClusterCordon package managed))

preparedClusterCordonHandle ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ManagedClusterHandle scope planId clusterId phase
preparedClusterCordonHandle (PreparedClusterCordon _ managed) = managed

preparedClusterCordonName ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    String
preparedClusterCordonName (PreparedClusterCordon package _) = planOwnedClusterName (planOwnedClusterConfigBase package)

preparedClusterCordonStateDirectory ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    FilePath
preparedClusterCordonStateDirectory (PreparedClusterCordon package _) = planOwnedClusterStateDirectory (planOwnedClusterConfigBase package)

preparedClusterCordonOwnershipIdentity ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Text
preparedClusterCordonOwnershipIdentity (PreparedClusterCordon package _) =
    planOwnedClusterOwnershipIdentity (planOwnedClusterConfigBase package)

preparedClusterCordonNodeNames ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    [String]
preparedClusterCordonNodeNames (PreparedClusterCordon package _) =
    planOwnedClusterNodeNames (planOwnedClusterConfigBase package)

preparedClusterCordonBudget ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ResourceBudget
preparedClusterCordonBudget (PreparedClusterCordon package _) =
    planOwnedClusterBudget (planOwnedClusterConfigBase package)

{- | Settled cordon evidence gates readiness and therefore every dependent
cluster operation.
-}
data
    AppliedClusterCordon
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
    = AppliedClusterCordon
        ( PlanOwnedClusterConfig
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
        )
        (ManagedClusterHandle scope planId clusterId phase)

type role AppliedClusterCordon nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

appliedClusterCordonHandle ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ManagedClusterHandle scope planId clusterId phase
appliedClusterCordonHandle (AppliedClusterCordon _ managed) = managed

appliedClusterCordonName ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    String
appliedClusterCordonName (AppliedClusterCordon package _) = planOwnedClusterName (planOwnedClusterConfigBase package)

appliedClusterCordonStateDirectory ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    FilePath
appliedClusterCordonStateDirectory (AppliedClusterCordon package _) =
    planOwnedClusterStateDirectory (planOwnedClusterConfigBase package)

appliedClusterCordonOwnershipIdentity ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Text
appliedClusterCordonOwnershipIdentity (AppliedClusterCordon package _) =
    planOwnedClusterOwnershipIdentity (planOwnedClusterConfigBase package)

appliedClusterCordonNodeNames ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    [String]
appliedClusterCordonNodeNames (AppliedClusterCordon package _) =
    planOwnedClusterNodeNames (planOwnedClusterConfigBase package)

settleClusterCordon ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterCordonCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError (AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
settleClusterCordon (PreparedClusterCordon package managed) (ClusterCordonCallResult observation) =
    case observation of
        ClusterCordonApplied -> Right (AppliedClusterCordon package managed)
        ClusterCordonReplaced identity ->
            clusterIdentityConflict managed identity "a same-named replacement appeared before cordoning; no node was mutated"
        ClusterCordonFailed reason ->
            Left (Failure (FailureDetail "apply exact cluster cordon" reason ReprobeBeforeRetry))

-- | Descriptive, non-authorizing projection of a strong readiness result.
data ClusterReadinessResultView
    = ClusterReadinessResultReady Word64 Text
    | ClusterReadinessResultNotReady Text
    | ClusterReadinessResultProbeFailed Text
    deriving (Eq, Show)

clusterReadinessResultView ::
    ClusterReadinessCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterReadinessResultView
clusterReadinessResultView (ClusterReadinessCallResult version observation _) = case observation of
    ClusterReady identity -> ClusterReadinessResultReady version identity
    ClusterNotReady identity -> ClusterReadinessResultNotReady identity
    ClusterReadinessProbeFailed reason -> ClusterReadinessResultProbeFailed reason

-- | Readiness evidence for the exact managed cluster generation.
data ClusterReadiness scope planId clusterId phase where
    ClusterReadiness ::
        ManagedClusterHandle scope planId clusterId phase ->
        IO
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
            ) ->
        ClusterReadiness scope planId clusterId phase
    RecoveredClusterReadiness ::
        ResourceHandle scope planId clusterId ClusterResource Managed observedPhase ->
        IO (Either ReconcileError Word64) ->
        ClusterReadiness scope planId clusterId phase

type role ClusterReadiness nominal nominal nominal nominal

settleClusterReadiness ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterReadinessCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError (ClusterReadiness scope planId clusterId phase)
settleClusterReadiness (AppliedClusterCordon _ managed) (ClusterReadinessCallResult version observation reprobe) = do
    _ <- settleClusterReadinessObservation managed version observation
    Right (ClusterReadiness managed reprobe)

{- | Reconstruct readiness only inside a continuation from a newly executed
backend observation.  Neither the call result nor the opaque readiness witness
can be supplied by the continuation, and a failed or stale observation never
enters it.
-}
withFreshClusterReadiness ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterReadinessCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase) ->
    (ClusterReadiness scope planId clusterId phase -> result) ->
    IO (Either ReconcileError result)
withFreshClusterReadiness applied observe consume = do
    fresh <- observe
    pure (consume <$> settleClusterReadiness applied fresh)

settleClusterReadinessObservation ::
    ManagedClusterHandle scope planId clusterId phase ->
    Word64 ->
    ClusterReadinessObservation ->
    Either ReconcileError Word64
settleClusterReadinessObservation managed version observation =
    case observation of
        ClusterReady identity
            | identity /= managedClusterBackendIdentity managed ->
                clusterIdentityConflict managed identity "re-observe readiness for the managed cluster identity"
            | version == 0 ->
                Left
                    ( Failure
                        ( FailureDetail
                            "settle cluster readiness"
                            "the strong backend did not attach a fresh successful phase-observation version"
                            DoNotRetry
                        )
                    )
            | otherwise -> Right version
        ClusterNotReady identity
            | identity /= managedClusterBackendIdentity managed ->
                clusterIdentityConflict managed identity "a same-named replacement is not readiness evidence for this plan"
            | otherwise ->
                Left
                    ( Failure
                        ( FailureDetail
                            "settle cluster readiness"
                            ("the managed cluster identity is not ready: " <> identity)
                            ReprobeBeforeRetry
                        )
                    )
        ClusterReadinessProbeFailed reason ->
            Left (Failure (FailureDetail "probe cluster readiness" reason ReprobeBeforeRetry))

{- | The only cluster-module dependency probe producer consumes readiness
evidence, so a dependent planned operation cannot be offered before the
exact managed cluster generation has been observed ready.
-}
clusterReadinessProbe ::
    ClusterReadiness scope planId clusterId phase ->
    DependencyProbe scope planId clusterId ClusterResource
clusterReadinessProbe evidence = dependencyProbe (reprobeClusterReadiness evidence)

withClusterReadinessResourceHandle ::
    ClusterReadiness scope planId clusterId phase ->
    (forall observedPhase. ResourceHandle scope planId clusterId ClusterResource Managed observedPhase -> result) ->
    result
withClusterReadinessResourceHandle (ClusterReadiness managed _) consume = consume (managedClusterResourceHandle managed)
withClusterReadinessResourceHandle (RecoveredClusterReadiness handle _) consume = consume handle

withRecoveredClusterReadiness ::
    ResourceHandle scope planId clusterId ClusterResource Managed observedPhase ->
    Word64 ->
    (ClusterReadiness scope planId clusterId phase -> result) ->
    IO (Either ReconcileError result)
withRecoveredClusterReadiness handle version consume
    | version == 0 = pure (Left (Failure (FailureDetail "recover cluster readiness" "fresh observation version must be positive" DoNotRetry)))
    | otherwise = do
        unused <- newIORef True
        let reprobe = do
                available <- atomicModifyIORef' unused (\current -> (False, current))
                pure $ if available
                    then Right version
                    else Left (Failure (FailureDetail "recover cluster readiness" "fresh readiness observation has already been consumed" DoNotRetry))
        pure (Right (consume (RecoveredClusterReadiness handle reprobe)))

{- | Rerun the backend-bound read-only readiness probe retained by the opaque
evidence.  The returned version is descriptive and non-authorizing on its own;
dependent preparation consumes the same action through
'clusterReadinessProbe'.
-}
reprobeClusterReadiness ::
    ClusterReadiness scope planId clusterId phase ->
    IO (Either ReconcileError Word64)
reprobeClusterReadiness (ClusterReadiness managed reprobe) = do
    ClusterReadinessCallResult version observation _ <- reprobe
    pure (settleClusterReadinessObservation managed version observation)
reprobeClusterReadiness (RecoveredClusterReadiness _ reprobe) = reprobe

-- | Descriptive, non-authorizing projection of a strong cleanup result.
data ClusterCleanupResultView
    = ClusterCleanupResultRemoved
    | ClusterCleanupResultReplaced Text
    | ClusterCleanupResultFailed ReconcileError
    deriving (Eq, Show)

clusterCleanupResultView ::
    ClusterCleanupCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterCleanupResultView
clusterCleanupResultView (ClusterCleanupCallResult observation) = case observation of
    ClusterCleanupRemoved -> ClusterCleanupResultRemoved
    ClusterCleanupReplaced identity -> ClusterCleanupResultReplaced identity
    ClusterCleanupFailed err -> ClusterCleanupResultFailed err

data
    PreparedClusterCleanup
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
    = PreparedClusterCleanup
        ( PlanOwnedClusterConfig
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
        )
        (ManagedClusterHandle scope planId clusterId phase)

type role PreparedClusterCleanup nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedClusterCleanup ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ManagedClusterHandle scope planId clusterId phase ->
    (PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> result) ->
    Either ReconcileError result
withPreparedClusterCleanup (PreparedClusterReconcile package _ observed _ _) managed consume = do
    let handle = managedClusterResourceHandle managed
    if sameObservedResource observed handle
        then Right ()
        else
            Left
                ( Conflict
                    ( ConflictDetail
                        (resourceHandleKey observed)
                        ("prepared binding " <> resourceBinding observed)
                        ("managed binding " <> resourceBinding handle)
                        "use the managed cluster minted by this exact preparation"
                    )
                )
    validateOwnershipReceipt handle (managedClusterReceipt managed)
    Right (consume (PreparedClusterCleanup package managed))

preparedClusterCleanupHandle ::
    PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ManagedClusterHandle scope planId clusterId phase
preparedClusterCleanupHandle (PreparedClusterCleanup _ managed) = managed

preparedCleanupClusterName :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> String
preparedCleanupClusterName (PreparedClusterCleanup package _) = planOwnedClusterName (planOwnedClusterConfigBase package)

preparedCleanupStateDirectory :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> FilePath
preparedCleanupStateDirectory (PreparedClusterCleanup package _) = planOwnedClusterStateDirectory (planOwnedClusterConfigBase package)

preparedCleanupOwnershipIdentity :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> Text
preparedCleanupOwnershipIdentity (PreparedClusterCleanup package _) =
    planOwnedClusterOwnershipIdentity (planOwnedClusterConfigBase package)

preparedCleanupConfigPath :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> Maybe FilePath
preparedCleanupConfigPath (PreparedClusterCleanup package _) = Just (planOwnedRenderedConfigPath package)

preparedCleanupNodeNames :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> [String]
preparedCleanupNodeNames (PreparedClusterCleanup package _) = planOwnedClusterNodeNames (planOwnedClusterConfigBase package)

settleClusterCleanup ::
    PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterCleanupCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError ()
settleClusterCleanup (PreparedClusterCleanup _ managed) (ClusterCleanupCallResult observation) =
    case observation of
        ClusterCleanupRemoved -> Right ()
        ClusterCleanupReplaced identity ->
            clusterIdentityConflict managed identity "a different cluster now holds the name; refusing to delete state this plan does not own"
        ClusterCleanupFailed err -> Left err

{- | Run the one core-managed cluster cleanup selected by an exact reverse entry.

The durable gate and local work must name the same admitted plan and operation.
The closed verb chooses the effect; callers cannot pass a retain/delete flag.
-}
runExactClusterCleanupKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    ProjectVerb verb ->
    PreparedGate ->
    LocalWork scope planId frame verb ->
    IO () ->
    IO () ->
    IO TeardownOutcome
runExactClusterCleanupKernel plan verb gate local runDown runDestroy
    | preparedGatePlan gate /= stablePlanSnapshotDigest (renderSnapshot plan) =
        pure (TeardownFailed "cluster cleanup: the durable gate names another plan")
    | preparedGateOperation gate /= localWorkKey local =
        pure (TeardownFailed "cluster cleanup: the durable gate names another operation")
    | localWorkAction local /= DeleteCluster =
        pure (TeardownFailed "cluster cleanup: the reverse work is not the plan's cluster action")
    | otherwise = case verb of
        ProjectUp -> pure (TeardownFailed "cluster cleanup: project up has no cleanup policy")
        ProjectDown -> run runDown
        ProjectDestroy -> run runDestroy
  where
    run action = do
        attempted <- try action
        pure $ case attempted of
            Left exception -> TeardownFailed (displayException (exception :: SomeException))
            Right () -> TeardownReleased

sameObservedResource ::
    ResourceHandle scope planId id resource ownershipA phaseA ->
    ResourceHandle scope planId id resource ownershipB phaseB ->
    Bool
sameObservedResource expected observed =
    resourceHandleKey expected == resourceHandleKey observed
        && resourceHandleGeneration expected == resourceHandleGeneration observed
        && resourceHandleObservationVersion expected == resourceHandleObservationVersion observed

resourceBinding :: ResourceHandle scope planId id resource ownership phase -> Text
resourceBinding handle =
    Text.intercalate
        ","
        [ "key=" <> resourceHandleKey handle
        , "generation=" <> Text.pack (show (resourceHandleGeneration handle))
        , "observation-version=" <> Text.pack (show (resourceHandleObservationVersion handle))
        ]

clusterIdentityConflict ::
    ManagedClusterHandle scope planId clusterId phase ->
    Text ->
    Text ->
    Either ReconcileError value
clusterIdentityConflict managed identity remedy =
    Left
        ( Conflict
            ( ConflictDetail
                (managedClusterKey managed)
                ("control-plane identity=" <> managedClusterBackendIdentity managed)
                ("control-plane identity=" <> identity)
                remedy
            )
        )
