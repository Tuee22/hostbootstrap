{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Opaque provider-exact budget admission and constructive partitioning.

These values are pure planning evidence. They do not authorize a provider
mutation; downstream lifecycle code must journal and acquire the matching wall
before an adapter call.
-}
module HostBootstrap.Cluster.Budget
  ( ProviderBackend (..),
    ColimaProvider,
    LimaProvider,
    IncusProvider,
    Wsl2Provider,
    DockerNodeProvider,
    BareLinuxProvider,
    ProviderKey (..),
    providerBackend,
    withProviderKeyForBackend,
    BudgetError (..),
    ValidatedBudget,
    withValidatedBudget,
    validatedBudgetValue,
    ProviderBudgetCapability,
    withProviderBudgetCapability,
    ProviderWallSpec,
    EffectiveBudget,
    admitProviderBudget,
    effectiveBudgetValue,
    Workload,
    mkWorkload,
    PlannedWorkloadSet,
    withPlannedWorkloadSet,
    VerifiedWorkloadFit,
    verifyPlannedWorkloadFit,
    SliceRequest,
    mkSliceRequest,
    BudgetPartition,
    ResourceSlice,
    SomeResourceSlice,
    withBudgetPartition,
    forResourceSlices,
    resourceSliceName,
    resourceSliceFrame,
    resourceSliceBudget,
    ProviderWallReservation,
    withProviderWallReservation,
    PreparedProviderWallCall,
    prepareProviderWallCall,
    providerWallCallArgs,
    WallAcquireObservation (..),
    ProviderWallAuthority,
    providerWallEpoch,
    providerWallFence,
    WslGlobalWallLease,
    LiveProviderWall,
    settleProviderWallCall,
    withLiveProviderWall,
  )
where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import HostBootstrap.Cluster.Cordon
  ( ResourceBudget,
    budgetCpu,
    budgetFromResources,
    budgetMemoryBytes,
    budgetStorageBytes,
  )
import HostBootstrap.Context (ResourceEnvelope)
import Data.Word (Word64)
import HostBootstrap.Reconcile
  ( ChangeView (..),
    ChangedKind (..),
    ConflictDetail (..),
    FailureDetail (..),
    LifecyclePlan,
    ReconcileError (..),
    RecoveryDisposition (..),
  )
import Numeric.Natural (Natural)

data ProviderBackend
  = ColimaBackend
  | LimaBackend
  | IncusBackend
  | Wsl2Backend
  | DockerNodeBackend
  | BareLinuxBackend
  deriving (Eq, Show)

data ColimaProvider
data LimaProvider
data IncusProvider
data Wsl2Provider
data DockerNodeProvider
data BareLinuxProvider

-- | Closed provider/type relation. A caller can select a backend value, but
-- cannot claim that it has another provider phantom.
data ProviderKey provider where
  ColimaProviderKey :: ProviderKey ColimaProvider
  LimaProviderKey :: ProviderKey LimaProvider
  IncusProviderKey :: ProviderKey IncusProvider
  Wsl2ProviderKey :: ProviderKey Wsl2Provider
  DockerNodeProviderKey :: ProviderKey DockerNodeProvider
  BareLinuxProviderKey :: ProviderKey BareLinuxProvider

providerBackend :: ProviderKey provider -> ProviderBackend
providerBackend key =
  case key of
    ColimaProviderKey -> ColimaBackend
    LimaProviderKey -> LimaBackend
    IncusProviderKey -> IncusBackend
    Wsl2ProviderKey -> Wsl2Backend
    DockerNodeProviderKey -> DockerNodeBackend
    BareLinuxProviderKey -> BareLinuxBackend

withProviderKeyForBackend ::
  ProviderBackend ->
  (forall provider. ProviderKey provider -> result) ->
  result
withProviderKeyForBackend backend consume =
  case backend of
    ColimaBackend -> consume ColimaProviderKey
    LimaBackend -> consume LimaProviderKey
    IncusBackend -> consume IncusProviderKey
    Wsl2Backend -> consume Wsl2ProviderKey
    DockerNodeBackend -> consume DockerNodeProviderKey
    BareLinuxBackend -> consume BareLinuxProviderKey

data BudgetError
  = InvalidBudget String
  | InexactProviderQuantity ProviderBackend String Integer
  | UnsupportedBudgetWall ProviderBackend String
  | EmptyWorkloadSet
  | WorkloadOverflow String Integer Integer
  | InvalidWorkload String
  | InvalidSlice String
  | PartitionOverflow String Integer Integer
  | InvalidWallReservation String
  deriving (Eq, Show)

data ValidatedBudget scope planId budgetId = ValidatedBudget ResourceBudget

withValidatedBudget ::
  LifecyclePlan scope planId ->
  ResourceEnvelope ->
  (forall budgetId. ValidatedBudget scope planId budgetId -> result) ->
  Either BudgetError result
withValidatedBudget _plan envelope consume =
  case budgetFromResources envelope of
    Left err -> Left (InvalidBudget err)
    Right budget -> Right (consume (ValidatedBudget budget))

validatedBudgetValue :: ValidatedBudget scope planId budgetId -> ResourceBudget
validatedBudgetValue (ValidatedBudget budget) = budget

data ProviderBudgetCapability scope planId provider capabilityId =
  ProviderBudgetCapability (ProviderKey provider)

withProviderBudgetCapability ::
  LifecyclePlan scope planId ->
  ProviderKey provider ->
  (forall capabilityId. ProviderBudgetCapability scope planId provider capabilityId -> result) ->
  result
withProviderBudgetCapability _plan key consume =
  consume (ProviderBudgetCapability key)

data ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId =
  ProviderWallSpec (ProviderKey provider) ResourceBudget

data EffectiveBudget scope planId budgetId provider capabilityId wallSpecId =
  EffectiveBudget ResourceBudget

admitProviderBudget ::
  ValidatedBudget scope planId budgetId ->
  ProviderBudgetCapability scope planId provider capabilityId ->
  ( forall wallSpecId.
    ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
    EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
    result
  ) ->
  Either BudgetError result
admitProviderBudget (ValidatedBudget budget) (ProviderBudgetCapability providerKey) consume = do
  let backend = providerBackend providerKey
  validateBackendExactness backend budget
  pure
    ( consume
        (ProviderWallSpec providerKey budget)
        (EffectiveBudget budget)
    )

effectiveBudgetValue ::
  EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
  ResourceBudget
effectiveBudgetValue (EffectiveBudget budget) = budget

validateBackendExactness :: ProviderBackend -> ResourceBudget -> Either BudgetError ()
validateBackendExactness backend budget =
  case backend of
    BareLinuxBackend ->
      Left
        ( UnsupportedBudgetWall
            BareLinuxBackend
            "bare Linux has no quota/image-GC storage wall"
        )
    DockerNodeBackend -> pure ()
    _ -> do
      exact "memory" (budgetMemoryBytes budget)
      exact "storage" (budgetStorageBytes budget)
  where
    gib = 1024 ^ (3 :: Integer)
    exact dimension value
      | value `mod` gib == 0 = Right ()
      | otherwise = Left (InexactProviderQuantity backend dimension value)

providerWallArgs ::
  String ->
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  Either BudgetError [String]
providerWallArgs name (ProviderWallSpec providerKey budget) =
  case providerKey of
    ColimaProviderKey ->
      pure
        [ "start",
          "--profile",
          name,
          "--runtime",
          "docker",
          "--activate=false",
          "--cpus",
          show (budgetCpu budget),
          "--memory",
          show memoryGiB,
          "--disk",
          show storageGiB
        ]
    LimaProviderKey ->
      pure
        [ "--cpus",
          show (budgetCpu budget),
          "--memory",
          show memoryGiB,
          "--disk",
          show storageGiB
        ]
    IncusProviderKey ->
      pure
        [ "limits.cpu=" ++ show (budgetCpu budget),
          "limits.memory=" ++ show memoryGiB ++ "GiB",
          "root,size=" ++ show storageGiB ++ "GiB"
        ]
    Wsl2ProviderKey ->
      pure
        [ "[general]",
          "instanceIdleTimeout=-1",
          "[wsl2]",
          "processors=" ++ show (budgetCpu budget),
          "memory=" ++ show memoryGiB ++ "GB",
          "swap=" ++ show memoryGiB ++ "GB",
          "vmIdleTimeout=-1"
        ]
    DockerNodeProviderKey ->
      pure
        [ "update",
          "--cpus",
          show (budgetCpu budget),
          "--memory",
          show (budgetMemoryBytes budget),
          "--memory-swap",
          show (2 * budgetMemoryBytes budget),
          name
        ]
    BareLinuxProviderKey ->
      Left
        ( UnsupportedBudgetWall
            BareLinuxBackend
            "bare Linux has no complete provider wall"
        )
  where
    gib = 1024 ^ (3 :: Integer)
    memoryGiB = budgetMemoryBytes budget `div` gib
    storageGiB = budgetStorageBytes budget `div` gib

data Workload = Workload
  { workloadName :: String,
    workloadReplicas :: Natural,
    workloadCpuPerReplica :: Natural,
    workloadMemoryPerReplica :: Integer,
    workloadStoragePerReplica :: Integer
  }
  deriving (Eq, Show)

mkWorkload ::
  String ->
  Natural ->
  Natural ->
  Integer ->
  Integer ->
  Either BudgetError Workload
mkWorkload name replicas cores memoryBytes storageBytes
  | null name = Left (InvalidWorkload "workload name must not be empty")
  | replicas == 0 = Left (InvalidWorkload (name ++ ": replicas must be positive"))
  | cores == 0 = Left (InvalidWorkload (name ++ ": CPU must be positive"))
  | memoryBytes <= 0 = Left (InvalidWorkload (name ++ ": memory must be positive"))
  | storageBytes <= 0 = Left (InvalidWorkload (name ++ ": storage must be positive"))
  | otherwise =
      Right (Workload name replicas cores memoryBytes storageBytes)

data PlannedWorkloadSet scope planId workloadSetId =
  PlannedWorkloadSet (NonEmpty Workload)

withPlannedWorkloadSet ::
  [Workload] ->
  (forall workloadSetId. PlannedWorkloadSet scope planId workloadSetId -> result) ->
  Either BudgetError result
withPlannedWorkloadSet workloads consume =
  case NonEmpty.nonEmpty workloads of
    Nothing -> Left EmptyWorkloadSet
    Just nonEmpty -> Right (consume (PlannedWorkloadSet nonEmpty))

data VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId =
  VerifiedWorkloadFit

verifyPlannedWorkloadFit ::
  EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
  PlannedWorkloadSet scope planId workloadSetId ->
  Either
    BudgetError
    (VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId)
verifyPlannedWorkloadFit (EffectiveBudget budget) (PlannedWorkloadSet workloads) = do
  fits "cpu" totalCpu (toInteger (budgetCpu budget))
  fits "memory" totalMemory (budgetMemoryBytes budget)
  fits "storage" totalStorage (budgetStorageBytes budget)
  pure VerifiedWorkloadFit
  where
    totalCpu =
      sum
        [ toInteger (workloadReplicas workload)
            * toInteger (workloadCpuPerReplica workload)
        | workload <- NonEmpty.toList workloads
        ]
    totalMemory =
      sum
        [ toInteger (workloadReplicas workload)
            * workloadMemoryPerReplica workload
        | workload <- NonEmpty.toList workloads
        ]
    totalStorage =
      sum
        [ toInteger (workloadReplicas workload)
            * workloadStoragePerReplica workload
        | workload <- NonEmpty.toList workloads
        ]
    fits dimension wanted allowed
      | wanted <= allowed = Right ()
      | otherwise = Left (WorkloadOverflow dimension wanted allowed)

data SliceRequest = SliceRequest
  { requestedSliceName :: String,
    requestedFrameName :: String,
    requestedBudget :: ResourceBudget
  }

mkSliceRequest ::
  String ->
  String ->
  ResourceBudget ->
  ResourceBudget ->
  Either BudgetError SliceRequest
mkSliceRequest name frame budget requiredMinimum
  | null name = Left (InvalidSlice "slice name must not be empty")
  | null frame = Left (InvalidSlice (name ++ ": frame must not be empty"))
  | budgetCpu budget < budgetCpu requiredMinimum =
      Left (InvalidSlice (name ++ ": CPU is below the provider minimum"))
  | budgetMemoryBytes budget < budgetMemoryBytes requiredMinimum =
      Left (InvalidSlice (name ++ ": memory is below the provider minimum"))
  | budgetStorageBytes budget < budgetStorageBytes requiredMinimum =
      Left (InvalidSlice (name ++ ": storage is below the provider minimum"))
  | otherwise = Right (SliceRequest name frame budget)

data BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId =
  BudgetPartition

data ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId =
  ResourceSlice String String ResourceBudget

data SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId where
  SomeResourceSlice ::
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
    SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId

withBudgetPartition ::
  EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
  VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId ->
  ResourceBudget ->
  NonEmpty SliceRequest ->
  ( forall partitionId.
    BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    [SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId] ->
    result
  ) ->
  Either BudgetError result
withBudgetPartition (EffectiveBudget effective) VerifiedWorkloadFit overhead requests consume = do
  check "cpu" totalCpu (toInteger (budgetCpu effective))
  check "memory" totalMemory (budgetMemoryBytes effective)
  check "storage" totalStorage (budgetStorageBytes effective)
  pure
    ( consume
        BudgetPartition
        [ SomeResourceSlice
            ( ResourceSlice
                (requestedSliceName request)
                (requestedFrameName request)
                (requestedBudget request)
            )
        | request <- NonEmpty.toList requests
        ]
    )
  where
    budgets = fmap requestedBudget (NonEmpty.toList requests)
    totalCpu = toInteger (budgetCpu overhead) + sum (fmap (toInteger . budgetCpu) budgets)
    totalMemory = budgetMemoryBytes overhead + sum (fmap budgetMemoryBytes budgets)
    totalStorage = budgetStorageBytes overhead + sum (fmap budgetStorageBytes budgets)
    check dimension wanted allowed
      | wanted <= allowed = Right ()
      | otherwise = Left (PartitionOverflow dimension wanted allowed)

forResourceSlices ::
  [SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId] ->
  ( forall frame resourceId.
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
    result
  ) ->
  [result]
forResourceSlices slices consume =
  [consume slice | SomeResourceSlice slice <- slices]

resourceSliceName ::
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
  String
resourceSliceName (ResourceSlice name _ _) = name

resourceSliceFrame ::
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
  String
resourceSliceFrame (ResourceSlice _ frame _) = frame

resourceSliceBudget ::
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
  ResourceBudget
resourceSliceBudget (ResourceSlice _ _ budget) = budget

{- | Journaled, pre-call reservation for one exact wall specification and
partition. It is the authority for the initial wall call; the live wall
authority does not exist yet.
-}
data ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence =
  ProviderWallReservation Word64

withProviderWallReservation ::
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  Word64 ->
  ( forall reservationId fence.
    ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    result
  ) ->
  Either BudgetError result
withProviderWallReservation _wall _partition fenceValue consume
  | fenceValue == 0 =
      Left (InvalidWallReservation "provider wall fence must be positive")
  | otherwise =
      Right (consume (ProviderWallReservation fenceValue))

-- | The sole prepared initial-wall adapter input. Its constructor is hidden.
data PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence =
  PreparedProviderWallCall
    (ProviderKey provider)
    [String]
    Word64

prepareProviderWallCall ::
  String ->
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Either
    BudgetError
    (PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)
prepareProviderWallCall name wall@(ProviderWallSpec providerKey _) _partition (ProviderWallReservation fenceValue) = do
  args <- providerWallArgs name wall
  pure (PreparedProviderWallCall providerKey args fenceValue)

providerWallCallArgs ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  [String]
providerWallCallArgs (PreparedProviderWallCall _ args _) = args

data WallAcquireObservation
  = WallApplied Word64
  | WallAlreadyExact Word64
  | WallMigrated Word64 String
  | WallRefused ConflictDetail
  | WallAcquireFailed FailureDetail
  | WallAcquireUncertain String
  deriving (Eq, Show)

data ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence =
  ProviderWallAuthority Word64 Word64

providerWallEpoch ::
  ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence ->
  Word64
providerWallEpoch (ProviderWallAuthority epoch _) = epoch

providerWallFence ::
  ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence ->
  Word64
providerWallFence (ProviderWallAuthority _ fenceValue) = fenceValue

data WslGlobalWallLease scope planId wallSpecId wallEpoch fence =
  WslGlobalWallLease Word64 Word64

data WallReceipt scope planId provider wallSpecId wallEpoch fence =
  WallReceipt String

data LiveProviderWall scope planId provider wallSpecId wallEpoch fence where
  LiveProviderWall ::
    ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence ->
    WallReceipt scope planId provider wallSpecId wallEpoch fence ->
    ChangeView ->
    LiveProviderWall scope planId provider wallSpecId wallEpoch fence
  LiveWslProviderWall ::
    ProviderWallAuthority scope planId Wsl2Provider wallSpecId wallEpoch fence ->
    WslGlobalWallLease scope planId wallSpecId wallEpoch fence ->
    WallReceipt scope planId Wsl2Provider wallSpecId wallEpoch fence ->
    ChangeView ->
    LiveProviderWall scope planId Wsl2Provider wallSpecId wallEpoch fence

settleProviderWallCall ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  WallAcquireObservation ->
  ( forall wallEpoch.
    LiveProviderWall scope planId provider wallSpecId wallEpoch fence ->
    result
  ) ->
  Either ReconcileError result
settleProviderWallCall (PreparedProviderWallCall providerKey _ fenceValue) observation consume =
  case observation of
    WallApplied epoch -> successful epoch (Changed Created) "applied"
    WallAlreadyExact epoch -> successful epoch Unchanged "unchanged"
    WallMigrated epoch receipt -> successful epoch (Changed Repaired) receipt
    WallRefused detail -> Left (Conflict detail)
    WallAcquireFailed detail -> Left (Failure detail)
    WallAcquireUncertain detail ->
      Left
        ( Failure
            (FailureDetail "acquire provider wall" (Text.pack detail) ReprobeBeforeRetry)
        )
  where
    successful epoch change receipt
      | epoch == 0 =
          Left
            ( Failure
                (FailureDetail "acquire provider wall" "wall epoch must be positive" DoNotRetry)
            )
      | otherwise =
          let authority = ProviderWallAuthority epoch fenceValue
              wallReceipt = WallReceipt receipt
           in case providerKey of
                Wsl2ProviderKey ->
                  Right
                    ( consume
                        ( LiveWslProviderWall
                            authority
                            (WslGlobalWallLease epoch fenceValue)
                            wallReceipt
                            change
                        )
                    )
                _ ->
                  Right
                    ( consume
                        (LiveProviderWall authority wallReceipt change)
                    )

withLiveProviderWall ::
  LiveProviderWall scope planId provider wallSpecId wallEpoch fence ->
  ( ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence ->
    ChangeView ->
    result
  ) ->
  ( ProviderWallAuthority scope planId Wsl2Provider wallSpecId wallEpoch fence ->
    WslGlobalWallLease scope planId wallSpecId wallEpoch fence ->
    ChangeView ->
    result
  ) ->
  result
withLiveProviderWall live ordinary wsl =
  case live of
    LiveProviderWall authority _receipt change ->
      ordinary authority change
    LiveWslProviderWall authority lease _receipt change ->
      wsl authority lease change
