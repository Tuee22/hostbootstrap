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
    reprobeClusterReadiness,
    clusterReadinessProbe,
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
)
where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as ByteString
import Data.Char (digitToInt)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Cluster.Budget (ResourceSlice)
import HostBootstrap.Cluster.Cordon.Foundation
    ( ResourceBudget
    , budgetCpu
    , budgetMemoryBytes
    , budgetStorageBytes
    )
import HostBootstrap.Cluster.Lifecycle
    ( ClusterPackageError (..)
    , PlanOwnedCluster
    , planOwnedClusterBudget
    , planOwnedClusterConfigPath
    , planOwnedClusterDurableRoot
    , planOwnedClusterName
    , planOwnedClusterNodeNames
    , planOwnedClusterOwnershipIdentity
    , planOwnedClusterPlacement
    , planOwnedClusterProviderKey
    , planOwnedClusterPublishesHostPorts
    , planOwnedClusterStateDirectory
    , withPlanOwnedCluster
    )
import HostBootstrap.Cluster.Observation.Internal
    ( ClusterCleanupCallResult (..)
    , ClusterBackendBinding
    , clusterBackendBindingIdentity
    , ClusterCleanupObservation (..)
    , ClusterCordonCallResult (..)
    , ClusterCordonObservation (..)
    , ClusterReadinessCallResult (..)
    , ClusterReadinessObservation (..)
    , ClusterReconcileCallResult (..)
    , ClusterReconcileObservation (..)
    , ManagedClusterHandle (..)
    , managedClusterBackendIdentity
    , managedClusterReceipt
    , managedClusterResourceHandle
    )
import HostBootstrap.Lifecycle.Prepared
    ( PreparedGate
    , preparedGateJournalVersion
    )
import HostBootstrap.ProjectPlan
    ( ClusterResource
    , DerivedTopology
    , PlannedResource
    , ProjectPlan
    , ProviderResource
    )
import HostBootstrap.Reconcile
    ( BackendReconcileObservation (..)
    , ChangeView
    , ConflictDetail (..)
    , DependencyProbe
    , FailureDetail (..)
    , ForeignObservation (..)
    , Observed
    , OwnershipReceipt
    , PreparedOperation
    , PreparedPreconditions
    , PriorCommitProof
    , Provisioned
    , ReconcileError (..)
    , ReconcileResult
    , RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry)
    , ResourceHandle
    , Unclassified
    , completePreparedUnchanged
    , completeReconcile
    , dependencyProbe
    , emptyDependencySnapshot
    , plannedProjectOperation
    , resourceHandleGeneration
    , resourceHandleKey
    , resourceHandleObservationVersion
    , validateOwnershipReceipt
    , withDependencySnapshotEntry
    , withObservedProjectResource
    , withOperationPreconditions
    , withPreparedOperation
    , withReconcileResult
    )
import HostBootstrap.Substrate.Provider.Dependency.Internal
    ( RunningProviderDependency
    , runningProviderDependencyHandle
    , runningProviderDependencyReprobe
    )
import System.Directory (doesFileExist, pathIsSymbolicLink)

{- | The complete prepared reconcile.  Every source-package identity remains a
nominal index through the effect boundary.
-}
data PreparedClusterReconcile
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
        ( PlanOwnedCluster
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

-- | Exact bytes observed at preparation for the plan-derived config path.
-- The constructor is private; the backend receives only path/digest
-- projections and revalidates both under the ownership lock before mutation.
data PreparedClusterConfig = PreparedClusterConfig FilePath Text

{- | Prepare only the exact package projected by one admitted plan.

The provider probe is paired internally with the exact managed provider handle;
there is no caller-supplied dependency snapshot, digest, frame, cluster profile,
or independently resolved root.
-}
withPreparedClusterReconcile ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    DerivedTopology scope planId ->
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId clusterFrame clusterId ->
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
    plan
    cluster
    provider
    suppliedTopology
    slice
    runningProvider
    gate
    consume =
        case withPlanOwnedCluster plan cluster provider suppliedTopology slice of
            Left packageError -> pure (Left (packageFailure packageError))
            Right package -> do
                configResult <- prepareClusterConfig package
                case configResult of
                    Left err -> pure (Left err)
                    Right configBinding ->
                      case
                          withObservedProjectResource
                              plan
                              cluster
                              (clusterResourceGeneration package)
                              (preparedGateJournalVersion gate)
                              id
                        of
                        Left err -> pure (Left err)
                        Right observed ->
                          case plannedProjectOperation plan cluster observed (clusterCallDigest package configBinding) of
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
                                    withPreparedOperation
                                        descriptor
                                        preconditionSet
                                        gate
                                        ( \prepared preconditions ->
                                            consume
                                                ( PreparedClusterReconcile
                                                    package
                                                    configBinding
                                                    observed
                                                    prepared
                                                    preconditions
                                                )
                                        )

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

packageFailure :: ClusterPackageError -> ReconcileError
packageFailure (ClusterPackageMismatch detail) =
    Failure (FailureDetail "prepare plan-owned cluster" detail DoNotRetry)

clusterCallDigest :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Maybe PreparedClusterConfig -> Text
clusterCallDigest package configBinding =
    let budget = planOwnedClusterBudget package
        configDigest = maybe "config-absent" (\(PreparedClusterConfig _ digest) -> "config-" <> digest) configBinding
     in
    Text.intercalate
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

prepareClusterConfig ::
    PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    IO (Either ReconcileError (Maybe PreparedClusterConfig))
prepareClusterConfig package =
    case planOwnedClusterConfigPath package of
        Nothing -> pure (Right Nothing)
        Just path -> do
            observed <- try (observe path) :: IO (Either SomeException (Either Text ByteString.ByteString))
            pure $ case observed of
                Left failure -> configFailure (Text.pack (displayException failure))
                Right (Left reason) -> configFailure reason
                Right (Right bytes) ->
                    let digest = hash bytes :: Digest SHA256
                     in Right
                            ( Just
                                ( PreparedClusterConfig
                                    path
                                    (TextEncoding.decodeUtf8 (convertToBase Base16 digest))
                                )
                            )
  where
    observe path = do
        symbolic <- pathIsSymbolicLink path
        regular <- doesFileExist path
        if symbolic
            then pure (Left "the plan-derived cluster config is a symbolic link")
            else
                if not regular
                    then pure (Left "the plan-derived cluster config is absent or not a regular file")
                    else do
                        bytes <- ByteString.readFile path
                        pure
                            ( if ByteString.length bytes > 1048576
                                then Left "the plan-derived cluster config exceeds 1 MiB"
                                else Right bytes
                            )
    configFailure reason =
        Left
            ( Failure
                ( FailureDetail
                    "bind plan-owned cluster config"
                    reason
                    DoNotRetry
                )
            )

preparedClusterReconcileHandle ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ResourceHandle scope planId clusterId ClusterResource Unclassified Observed
preparedClusterReconcileHandle (PreparedClusterReconcile _ _ handle _ _) = handle

preparedClusterName :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> String
preparedClusterName (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterName package

preparedClusterStateDirectory :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> FilePath
preparedClusterStateDirectory (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterStateDirectory package

preparedClusterDurableRoot :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> FilePath
preparedClusterDurableRoot (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterDurableRoot package

preparedClusterPublishesHostPorts :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Bool
preparedClusterPublishesHostPorts (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterPublishesHostPorts package

preparedClusterConfigPath :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Maybe FilePath
preparedClusterConfigPath (PreparedClusterReconcile _ config _ _ _) =
    fmap (\(PreparedClusterConfig path _) -> path) config

preparedClusterConfigDigest :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Maybe Text
preparedClusterConfigDigest (PreparedClusterReconcile _ config _ _ _) =
    fmap (\(PreparedClusterConfig _ digest) -> digest) config

preparedClusterPlacement :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> (Text, Text)
preparedClusterPlacement (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterPlacement package

preparedClusterProviderKey :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Text
preparedClusterProviderKey (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterProviderKey package

preparedClusterOwnershipIdentity :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> Text
preparedClusterOwnershipIdentity (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterOwnershipIdentity package

preparedClusterBudget :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> ResourceBudget
preparedClusterBudget (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterBudget package

preparedClusterNodeNames :: PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion -> [String]
preparedClusterNodeNames (PreparedClusterReconcile package _ _ _ _) = planOwnedClusterNodeNames package

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
data PreparedClusterCordon
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
        ( PlanOwnedCluster
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
preparedClusterCordonName (PreparedClusterCordon package _) = planOwnedClusterName package

preparedClusterCordonStateDirectory ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    FilePath
preparedClusterCordonStateDirectory (PreparedClusterCordon package _) = planOwnedClusterStateDirectory package

preparedClusterCordonOwnershipIdentity ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Text
preparedClusterCordonOwnershipIdentity (PreparedClusterCordon package _) =
    planOwnedClusterOwnershipIdentity package

preparedClusterCordonNodeNames ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    [String]
preparedClusterCordonNodeNames (PreparedClusterCordon package _) =
    planOwnedClusterNodeNames package

preparedClusterCordonBudget ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ResourceBudget
preparedClusterCordonBudget (PreparedClusterCordon package _) =
    planOwnedClusterBudget package

-- | Settled cordon evidence gates readiness and therefore every dependent
-- cluster operation.
data AppliedClusterCordon
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
        ( PlanOwnedCluster
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
appliedClusterCordonName (AppliedClusterCordon package _) = planOwnedClusterName package

appliedClusterCordonStateDirectory ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    FilePath
appliedClusterCordonStateDirectory (AppliedClusterCordon package _) =
    planOwnedClusterStateDirectory package

appliedClusterCordonOwnershipIdentity ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Text
appliedClusterCordonOwnershipIdentity (AppliedClusterCordon package _) =
    planOwnedClusterOwnershipIdentity package

appliedClusterCordonNodeNames ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    [String]
appliedClusterCordonNodeNames (AppliedClusterCordon package _) =
    planOwnedClusterNodeNames package

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

type role ClusterReadiness nominal nominal nominal nominal

settleClusterReadiness ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterReadinessCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError (ClusterReadiness scope planId clusterId phase)
settleClusterReadiness (AppliedClusterCordon _ managed) (ClusterReadinessCallResult version observation reprobe) = do
    _ <- settleClusterReadinessObservation managed version observation
    Right (ClusterReadiness managed reprobe)

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

-- | The only cluster-module dependency probe producer consumes readiness
-- evidence, so a dependent planned operation cannot be offered before the
-- exact managed cluster generation has been observed ready.
clusterReadinessProbe ::
    ClusterReadiness scope planId clusterId phase ->
    DependencyProbe scope planId clusterId ClusterResource
clusterReadinessProbe evidence = dependencyProbe (reprobeClusterReadiness evidence)

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

data PreparedClusterCleanup
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
        ( PlanOwnedCluster
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
preparedCleanupClusterName (PreparedClusterCleanup package _) = planOwnedClusterName package

preparedCleanupStateDirectory :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> FilePath
preparedCleanupStateDirectory (PreparedClusterCleanup package _) = planOwnedClusterStateDirectory package

preparedCleanupOwnershipIdentity :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> Text
preparedCleanupOwnershipIdentity (PreparedClusterCleanup package _) =
    planOwnedClusterOwnershipIdentity package

preparedCleanupConfigPath :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> Maybe FilePath
preparedCleanupConfigPath (PreparedClusterCleanup package _) = planOwnedClusterConfigPath package

preparedCleanupNodeNames :: PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase -> [String]
preparedCleanupNodeNames (PreparedClusterCleanup package _) = planOwnedClusterNodeNames package

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
