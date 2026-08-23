{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

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
    workloadName,
    workloadFrame,
    PlannedWorkloadSet,
    withPlannedWorkloadSet,
    plannedWorkloadSetDeclarationKey,
    plannedWorkloadSetDigest,
    VerifiedWorkloadFit,
    verifyPlannedWorkloadFit,
    SliceRequest,
    mkSliceRequest,
    BudgetPartition,
    budgetPartitionDigest,
    workloadPartitionDigest,
    ResourceSlice,
    SomeResourceSlice,
    withBudgetPartition,
    forResourceSlices,
    withResourceSliceFor,
    withActionResourceSlice,
    resourceSliceName,
    resourceSliceFrame,
    resourceSliceBudget,
    ProviderWallReservation,
    withProviderWallReservation,
    PreparedProviderWallCall,
    prepareProviderWallCall,
    preparePlanOwnedProviderWallCall,
    providerWallCallArgs,
    providerWallCallFence,
    WallAcquireObservation (..),
    ProviderWallSettlementPermit,
    ProviderWallAuthority,
    providerWallEpoch,
    providerWallFence,
    WslGlobalWallLease,
    LiveProviderWall,
    settleProviderWallCall,
    withLiveProviderWall,
    StorageWallMechanism (..),
    StorageWallUnsupported (..),
    PreparedStorageWallCall,
    prepareStorageWallCall,
    storageWallCallArgs,
    storageWallCallMechanism,
    storageWallCeilingBytes,
    StorageWallObservation (..),
    AppliedStorageWall,
    appliedStorageWallChange,
    settleStorageWallCall,
  )
where

import qualified Crypto.Hash as Hash
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Budget.Internal
  ( BareLinuxProvider,
    ColimaProvider,
    DockerNodeProvider,
    IncusProvider,
    LimaProvider,
    PreparedProviderWallCall (..),
    ProviderBackend (..),
    ProviderKey (..),
    ProviderWallReservation (..),
    ProviderWallSettlementPermit,
    WallAcquireObservation (..),
    Wsl2Provider,
    providerBackend,
    samePreparedProviderWallCall,
    withProviderKeyForBackend,
    withProviderWallSettlementPermit,
  )
import HostBootstrap.Cluster.Cordon (budgetFromResources)
import qualified HostBootstrap.Cluster.Cordon.Foundation as Cordon
import HostBootstrap.Cluster.Cordon.Foundation
  ( ResourceBudget,
    budgetCpu,
    budgetMemoryBytes,
    budgetStorageBytes,
  )
import HostBootstrap.Context (ResourceEnvelope)
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared
  ( PreparedGate,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
  )
import HostBootstrap.ProjectPlan
  ( DerivedTopology,
    PlannedResource,
    ProjectPlan,
    ProviderResource,
    plannedResourceFrame,
    plannedResourceKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    topologyContainsFrame,
    topologyDescentEdges,
    topologyFrameOrder,
    topologyParentEdges,
  )
import HostBootstrap.Reconcile
  ( ChangeView (..),
    ChangedKind (..),
    ConflictDetail (..),
    FailureDetail (..),
    ReconcileError (..),
    RecoveryDisposition (..),
    UnsupportedDetail (..),
    plannedResourcePlanDigest,
  )
import Numeric.Natural (Natural)

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
  | InvalidProviderPackage String
  deriving (Eq, Show)

data ValidatedBudget scope planId budgetId = ValidatedBudget ResourceBudget

type role ValidatedBudget nominal nominal nominal

withValidatedBudget ::
  ProjectPlan scope specDigest planId configId cfg ->
  ResourceEnvelope ->
  (forall budgetId. ValidatedBudget scope planId budgetId -> result) ->
  Either BudgetError result
withValidatedBudget _plan envelope consume =
  case budgetFromResources envelope of
    Left err -> Left (InvalidBudget err)
    Right budget -> Right (consume (ValidatedBudget budget))

validatedBudgetValue :: ValidatedBudget scope planId budgetId -> ResourceBudget
validatedBudgetValue (ValidatedBudget budget) = budget

data ProviderBudgetCapability scope planId provider capabilityId where
  ProviderBudgetCapability ::
    PlannedResource scope planId resourceId ProviderResource frame ->
    ProviderKey provider ->
    ProviderBudgetCapability scope planId provider capabilityId

type role ProviderBudgetCapability nominal nominal nominal nominal

withProviderBudgetCapability ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId resourceId ProviderResource frame ->
  ProviderKey provider ->
  (forall capabilityId. ProviderBudgetCapability scope planId provider capabilityId -> result) ->
  result
withProviderBudgetCapability _plan resource key consume =
  consume (ProviderBudgetCapability resource key)

data ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId =
  ProviderWallSpec (ProviderKey provider) ResourceBudget

type role ProviderWallSpec nominal nominal nominal nominal nominal nominal

data EffectiveBudget scope planId budgetId provider capabilityId wallSpecId =
  EffectiveBudget ResourceBudget

type role EffectiveBudget nominal nominal nominal nominal nominal nominal

admitProviderBudget ::
  ValidatedBudget scope planId budgetId ->
  ProviderBudgetCapability scope planId provider capabilityId ->
  ( forall wallSpecId.
    ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
    EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
    result
  ) ->
  Either BudgetError result
admitProviderBudget (ValidatedBudget budget) (ProviderBudgetCapability _resource providerKey) consume = do
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
    ColimaBackend -> do
      exact "memory" (budgetMemoryBytes budget)
      exact "storage" (budgetStorageBytes budget)
      case Cordon.colimaSizingArgsForBudget "provider-admission" budget of
        Left reason -> Left (InvalidBudget reason)
        Right _ -> Right ()
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
      render (Cordon.colimaSizingArgsForBudget name budget)
    LimaProviderKey ->
      render (Cordon.limaSizingArgsForBudget budget)
    IncusProviderKey ->
      render (Cordon.incusSizingArgsForBudget budget)
    Wsl2ProviderKey ->
      render (Cordon.wsl2SizingArgsForBudget budget)
    DockerNodeProviderKey ->
      render (Cordon.kindNodeCordonArgsForBudget name budget)
    BareLinuxProviderKey ->
      Left
        ( UnsupportedBudgetWall
            BareLinuxBackend
            "bare Linux has no complete provider wall"
        )
  where
    render = either (Left . InvalidBudget) Right

data Workload scope planId where
  Workload ::
    PlannedResource scope planId resourceId resource frame ->
    Natural ->
    Natural ->
    Integer ->
    Integer ->
    Workload scope planId

type role Workload nominal nominal

instance Eq (Workload scope planId) where
  left == right =
    workloadName left == workloadName right
      && workloadFrame left == workloadFrame right
      && workloadReplicas left == workloadReplicas right
      && workloadCpuPerReplica left == workloadCpuPerReplica right
      && workloadMemoryPerReplica left == workloadMemoryPerReplica right
      && workloadStoragePerReplica left == workloadStoragePerReplica right

instance Show (Workload scope planId) where
  show workload =
    "Workload {workloadName = "
      ++ show (workloadName workload)
      ++ ", workloadFrame = "
      ++ show (workloadFrame workload)
      ++ ", workloadReplicas = "
      ++ show (workloadReplicas workload)
      ++ ", workloadCpuPerReplica = "
      ++ show (workloadCpuPerReplica workload)
      ++ ", workloadMemoryPerReplica = "
      ++ show (workloadMemoryPerReplica workload)
      ++ ", workloadStoragePerReplica = "
      ++ show (workloadStoragePerReplica workload)
      ++ "}"

workloadName :: Workload scope planId -> String
workloadName (Workload resource _ _ _ _) =
  Text.unpack (plannedResourceKey resource)

workloadFrame :: Workload scope planId -> String
workloadFrame (Workload resource _ _ _ _) =
  Text.unpack (plannedResourceFrame resource)

workloadReplicas :: Workload scope planId -> Natural
workloadReplicas (Workload _resource replicas _ _ _) = replicas

workloadCpuPerReplica :: Workload scope planId -> Natural
workloadCpuPerReplica (Workload _resource _ cores _ _) = cores

workloadMemoryPerReplica :: Workload scope planId -> Integer
workloadMemoryPerReplica (Workload _resource _ _ memoryBytes _) = memoryBytes

workloadStoragePerReplica :: Workload scope planId -> Integer
workloadStoragePerReplica (Workload _resource _ _ _ storageBytes) = storageBytes

mkWorkload ::
  PlannedResource scope planId resourceId resource frame ->
  Natural ->
  Natural ->
  Integer ->
  Integer ->
  Either BudgetError (Workload scope planId)
mkWorkload resource replicas cores memoryBytes storageBytes
  | null name = Left (InvalidWorkload "workload name must not be empty")
  | null frame = Left (InvalidWorkload (name ++ ": frame must not be empty"))
  | replicas == 0 = Left (InvalidWorkload (name ++ ": replicas must be positive"))
  | cores == 0 = Left (InvalidWorkload (name ++ ": CPU must be positive"))
  | memoryBytes <= 0 = Left (InvalidWorkload (name ++ ": memory must be positive"))
  | storageBytes <= 0 = Left (InvalidWorkload (name ++ ": storage must be positive"))
  | otherwise =
      Right (Workload resource replicas cores memoryBytes storageBytes)
  where
    name = Text.unpack (plannedResourceKey resource)
    frame = Text.unpack (plannedResourceFrame resource)

data PlannedWorkloadSet scope planId workloadSetId =
  PlannedWorkloadSet (NonEmpty (Workload scope planId)) Text.Text Text.Text

type role PlannedWorkloadSet nominal nominal nominal

withPlannedWorkloadSet ::
  ProjectPlan scope specDigest planId configId cfg ->
  [Workload scope planId] ->
  (forall workloadSetId. PlannedWorkloadSet scope planId workloadSetId -> result) ->
  Either BudgetError result
withPlannedWorkloadSet plan workloads consume =
  case NonEmpty.nonEmpty workloads of
    Nothing -> Left EmptyWorkloadSet
    Just nonEmpty -> do
      mapM_ validateFrame (NonEmpty.toList nonEmpty)
      let key = "workload-set:" <> canonicalDigest ("workload-key" : concatMap workloadIdentityFields (NonEmpty.toList nonEmpty))
          digest = canonicalDigest ("workloads" : concatMap workloadFields (NonEmpty.toList nonEmpty))
      Right (consume (PlannedWorkloadSet nonEmpty key digest))
  where
    derivedTopology = topology plan
    validateFrame workload
      | topologyContainsFrame derivedTopology (Text.pack (workloadFrame workload)) = Right ()
      | otherwise =
          Left
            ( InvalidWorkload
                ( workloadName workload
                    ++ ": frame "
                    ++ workloadFrame workload
                    ++ " is not part of the admitted plan topology"
                )
            )
    workloadFields workload =
      [ Text.pack (workloadName workload)
      , Text.pack (workloadFrame workload)
      , Text.pack (show (workloadReplicas workload))
      , Text.pack (show (workloadCpuPerReplica workload))
      , Text.pack (show (workloadMemoryPerReplica workload))
      , Text.pack (show (workloadStoragePerReplica workload))
      ]
    workloadIdentityFields workload =
      [Text.pack (workloadName workload), Text.pack (workloadFrame workload)]

plannedWorkloadSetDeclarationKey :: PlannedWorkloadSet scope planId workloadSetId -> Text.Text
plannedWorkloadSetDeclarationKey (PlannedWorkloadSet _ key _) = key

plannedWorkloadSetDigest :: PlannedWorkloadSet scope planId workloadSetId -> Text.Text
plannedWorkloadSetDigest (PlannedWorkloadSet _ _ digest) = digest

data VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId =
  VerifiedWorkloadFit

type role VerifiedWorkloadFit nominal nominal nominal nominal nominal nominal nominal

verifyPlannedWorkloadFit ::
  EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
  PlannedWorkloadSet scope planId workloadSetId ->
  Either
    BudgetError
    (VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId)
verifyPlannedWorkloadFit (EffectiveBudget budget) (PlannedWorkloadSet workloads _ _) = do
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

data SliceRequest scope planId where
  SliceRequest ::
    PlannedResource scope planId resourceId resource frame ->
    ResourceBudget ->
    SliceRequest scope planId

type role SliceRequest nominal nominal

mkSliceRequest ::
  PlannedResource scope planId resourceId resource frame ->
  ResourceBudget ->
  ResourceBudget ->
  Either BudgetError (SliceRequest scope planId)
mkSliceRequest resource budget requiredMinimum
  | null name = Left (InvalidSlice "slice name must not be empty")
  | null frame = Left (InvalidSlice (name ++ ": frame must not be empty"))
  | budgetCpu budget < budgetCpu requiredMinimum =
      Left (InvalidSlice (name ++ ": CPU is below the provider minimum"))
  | budgetMemoryBytes budget < budgetMemoryBytes requiredMinimum =
      Left (InvalidSlice (name ++ ": memory is below the provider minimum"))
  | budgetStorageBytes budget < budgetStorageBytes requiredMinimum =
      Left (InvalidSlice (name ++ ": storage is below the provider minimum"))
  | otherwise = Right (SliceRequest resource budget)
  where
    name = Text.unpack (plannedResourceKey resource)
    frame = Text.unpack (plannedResourceFrame resource)

requestedBudget :: SliceRequest scope planId -> ResourceBudget
requestedBudget (SliceRequest _resource budget) = budget

data BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId =
  BudgetPartition Text.Text

type role BudgetPartition nominal nominal nominal nominal nominal nominal nominal nominal

data ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId where
  ResourceSlice ::
    PlannedResource scope planId resourceId resource frame ->
    ResourceBudget ->
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId

type role ResourceSlice nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

data SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId where
  SomeResourceSlice ::
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
    SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId

type role SomeResourceSlice nominal nominal nominal nominal nominal nominal nominal nominal

withBudgetPartition ::
  EffectiveBudget scope planId budgetId provider capabilityId wallSpecId ->
  VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId ->
  ResourceBudget ->
  NonEmpty (SliceRequest scope planId) ->
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
        (BudgetPartition (canonicalDigest ("partition" : budgetFields overhead <> concatMap requestFields (NonEmpty.toList requests))))
        [ SomeResourceSlice
            ( ResourceSlice
                resource
                budget
            )
        | SliceRequest resource budget <- NonEmpty.toList requests
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
    requestFields (SliceRequest resource budget) =
      plannedResourceKey resource : plannedResourceFrame resource : budgetFields budget

budgetPartitionDigest :: BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Text.Text
budgetPartitionDigest (BudgetPartition digest) = digest

workloadPartitionDigest ::
  PlannedWorkloadSet scope planId workloadSetId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  Text.Text
workloadPartitionDigest workloads partition =
  canonicalDigest ["workload-partition", plannedWorkloadSetDigest workloads, budgetPartitionDigest partition]

budgetFields :: ResourceBudget -> [Text.Text]
budgetFields budget =
  [ Text.pack (show (budgetCpu budget))
  , Text.pack (show (budgetMemoryBytes budget))
  , Text.pack (show (budgetStorageBytes budget))
  ]

canonicalDigest :: [Text.Text] -> Text.Text
canonicalDigest fields =
  Text.pack (show (Hash.hash (TextEncoding.encodeUtf8 framed) :: Hash.Digest Hash.SHA256))
  where
    framed = Text.concat [Text.pack (show (Text.length field)) <> ":" <> field | field <- fields]

forResourceSlices ::
  [SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId] ->
  ( forall frame resourceId.
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
    result
  ) ->
  [result]
forResourceSlices slices consume =
  [consume slice | SomeResourceSlice slice <- slices]

{- | Select the one partition slice minted for an exact planned resource.

The returned slice carries the resource's actual @frame@ and @resourceId@
indices, so a final consumer can require that exact resource rather than
accepting an existential slice and re-attaching identity from text.  Missing
and duplicate projections fail closed.
-}
withResourceSliceFor ::
  PlannedResource scope planId resourceId resource frame ->
  [SomeResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId] ->
  ( ResourceSlice
      scope
      planId
      budgetId
      provider
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      frame
      resourceId ->
    result
  ) ->
  Either BudgetError result
withResourceSliceFor planned slices consume =
  case
      [ budget
      | SomeResourceSlice (ResourceSlice resource budget) <- slices
      , plannedResourceKey resource == plannedResourceKey planned
      , plannedResourceFrame resource == plannedResourceFrame planned
      ] of
    [] -> Left (InvalidSlice (name ++ ": the budget partition has no slice for this planned resource"))
    [budget] -> Right (consume (ResourceSlice planned budget))
    _ -> Left (InvalidSlice (name ++ ": the budget partition contains duplicate slices for this planned resource"))
  where
    name = Text.unpack (plannedResourceKey planned)

{- | Attach an already-validated action-local budget to the executing planned
resource under fresh partition indices. The caller cannot choose any identity
index; the resource supplies key/frame and the closed 'ResourceBudget' supplies
the quantities.
-}
withActionResourceSlice ::
  PlannedResource scope planId resourceId resource frame ->
  ResourceBudget ->
  ( forall budgetId provider capabilityId wallSpecId workloadSetId partitionId.
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
    result
  ) ->
  result
withActionResourceSlice planned budget consume = consume (ResourceSlice planned budget)

resourceSliceName ::
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
  String
resourceSliceName (ResourceSlice resource _) =
  Text.unpack (plannedResourceKey resource)

resourceSliceFrame ::
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
  String
resourceSliceFrame (ResourceSlice resource _) =
  Text.unpack (plannedResourceFrame resource)

resourceSliceBudget ::
  ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId ->
  ResourceBudget
resourceSliceBudget (ResourceSlice _resource budget) = budget

{- | Mint the pre-call reservation only from the exact plan/provider operation's
durable prepare gate.  The descriptive budget algebra alone cannot produce
authority to enter a backend.
-}
withProviderWallReservation ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  PreparedGate ->
  ( forall reservationId fence.
    ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    result
  ) ->
  Either BudgetError result
withProviderWallReservation plan providerResource _wall _partition gate consume
  | plannedResourcePlanDigest providerResource /= planDigest =
      invalid "the provider resource does not retain this project's stable plan digest"
  | preparedGatePlan gate /= planDigest =
      invalid "the prepare gate belongs to another project plan"
  | preparedGateOperation gate /= operationKey =
      invalid "the prepare gate belongs to another provider operation"
  | Text.null (preparedGateSession gate) =
      invalid "the prepare gate session must be non-empty"
  | preparedGateFence gate == 0 =
      invalid "the prepare gate fence must be positive"
  | preparedGateAttempt gate == 0 =
      invalid "the prepare gate attempt must be positive"
  | preparedGateJournalVersion gate == 0 =
      invalid "the prepare gate journal version must be positive"
  | otherwise =
      Right
        ( consume
            ( ProviderWallReservation
                planDigest
                operationKey
                (preparedGateSession gate)
                (preparedGateFence gate)
                (preparedGateAttempt gate)
                (preparedGateJournalVersion gate)
            )
        )
  where
    snapshot = renderSnapshot plan
    planDigest = stablePlanSnapshotDigest snapshot
    operationKey = plannedResourceKey providerResource
    invalid = Left . InvalidWallReservation

prepareProviderWallCall ::
  String ->
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Either
    BudgetError
    (PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)
prepareProviderWallCall
  name
  wall@(ProviderWallSpec providerKey _)
  _partition
  (ProviderWallReservation plan operation session fenceValue attemptValue journalVersion) = do
  args <- providerWallArgs name wall
  pure
    ( PreparedProviderWallCall
        providerKey
        args
        plan
        operation
        session
        fenceValue
        attemptValue
        journalVersion
    )

{- | Prepare a provider call only after joining the complete plan-owned budget
package at the final consumer boundary.

The phantom indices already reject a resource, topology, budget, workload-fit,
partition, or reservation from another admitted plan.  The term checks below
also defend the internal boundary: the supplied topology must be the exact
projection retained by the plan, the provider frame must belong to it, the
capability must have been minted for the supplied provider resource, and the
wall must retain the validated budget byte-for-byte.
-}
preparePlanOwnedProviderWallCall ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  DerivedTopology scope planId ->
  ValidatedBudget scope planId budgetId ->
  ProviderBudgetCapability scope planId provider capabilityId ->
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  String ->
  Either
    BudgetError
    (PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)
preparePlanOwnedProviderWallCall
  plan
  providerResource
  suppliedTopology
  (ValidatedBudget validated)
  (ProviderBudgetCapability capabilityResource _providerKey)
  wall@(ProviderWallSpec _wallProviderKey wallBudget)
  VerifiedWorkloadFit
  partition@(BudgetPartition _)
  reservation@(ProviderWallReservation _plan _operation _session _fenceValue _attempt _journalVersion)
  name = do
    requirePackage
      "the supplied topology is not the exact topology projected by the project plan"
      (sameTopology suppliedTopology (topology plan))
    requirePackage
      "the provider resource frame is outside the supplied plan topology"
      (topologyContainsFrame suppliedTopology (plannedResourceFrame providerResource))
    requirePackage
      "the provider capability was minted for another provider resource"
      ( sameResource providerResource capabilityResource
      )
    requirePackage
      "the provider wall does not retain the exact validated budget"
      (validated == wallBudget)
    prepareProviderWallCall name wall partition reservation
  where
    sameTopology left right =
      topologyFrameOrder left == topologyFrameOrder right
        && topologyParentEdges left == topologyParentEdges right
        && topologyDescentEdges left == topologyDescentEdges right
    sameResource left right =
      plannedResourceKey left == plannedResourceKey right
        && plannedResourceFrame left == plannedResourceFrame right
    requirePackage detail condition
      | condition = Right ()
      | otherwise = Left (InvalidProviderPackage detail)

providerWallCallArgs ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  [String]
providerWallCallArgs (PreparedProviderWallCall _ args _ _ _ _ _ _) = args

-- | The descriptive durable fence retained by the exact reservation that
-- prepared this call.  It identifies the ownership record namespace but does
-- not itself grant mutation or settlement authority.
providerWallCallFence ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Word64
providerWallCallFence (PreparedProviderWallCall _ _ _ _ _ fenceValue _ _) = fenceValue

data ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence =
  ProviderWallAuthority Word64 Word64

type role ProviderWallAuthority nominal nominal nominal nominal nominal nominal

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

type role WslGlobalWallLease nominal nominal nominal nominal nominal

data WallReceipt scope planId provider wallSpecId wallEpoch fence =
  WallReceipt String

type role WallReceipt nominal nominal nominal nominal nominal nominal

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

type role LiveProviderWall nominal nominal nominal nominal nominal nominal

settleProviderWallCall ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  ProviderWallSettlementPermit
    scope
    planId
    providerResourceId
    budgetId
    provider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    operationKey
    callDigest
    attempt
    journalVersion ->
  ( forall wallEpoch.
    LiveProviderWall scope planId provider wallSpecId wallEpoch fence ->
    result
  ) ->
  Either ReconcileError result
settleProviderWallCall prepared permit consume =
  withProviderWallSettlementPermit permit $ \authorized observation ->
    if samePreparedProviderWallCall prepared authorized
      then settleAuthorized prepared observation
      else
        Left
          ( Conflict
              ( ConflictDetail
                  "settle provider wall"
                  "the exact journal reservation and provider call enclosed by the backend permit"
                  "a different prepared provider call"
                  "settle only the call whose closed backend result produced this permit"
              )
          )
  where
    settleAuthorized
      (PreparedProviderWallCall providerKey _ _ _ _ fenceValue _ _)
      observation =
        case observation of
          WallApplied epoch -> successful providerKey fenceValue epoch (Changed Created) "applied"
          WallAlreadyExact epoch -> successful providerKey fenceValue epoch Unchanged "unchanged"
          WallMigrated epoch receipt -> successful providerKey fenceValue epoch (Changed Repaired) receipt
          WallRefused detail -> Left (Conflict detail)
          WallAcquireFailed detail -> Left (Failure detail)
          WallAcquireUncertain detail ->
            Left
              ( Failure
                  (FailureDetail "acquire provider wall" (Text.pack detail) ReprobeBeforeRetry)
              )
    successful providerKey fenceValue epoch change receipt
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

-- The storage wall ------------------------------------------------------------

{- | The concrete mechanism that enforces a declared storage ceiling. Each one
is a real provider argument, not a preflight check: a mechanism named here
/applies/ the ceiling.
-}
data StorageWallMechanism
  = ColimaDiskArgument
  | LimaDiskArgument
  | IncusRootSizeArgument
  | Wsl2VhdSizeArgument
  deriving (Eq, Show)

{- | Why a provider cannot enforce the declared ceiling. These are the honest
gaps: @docker update@ has no storage flag, so a kind node container cannot be
capped after creation, and bare Linux has neither a quota'd project path nor an
image-GC wall (§ O, the canonical-quantities-and-reconcile-results phase).
-}
data StorageWallUnsupported
  = DockerNodeHasNoStorageFlag
  | BareLinuxHasNoStorageQuota
  deriving (Eq, Show)

{- | An opaque prepared storage-wall call. It exists only for a provider whose
mechanism can actually apply the ceiling, and it carries the exact declared
byte value the observation must match.
-}
data PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence =
  PreparedStorageWallCall StorageWallMechanism [String] Integer Word64

type role PreparedStorageWallCall nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Prepare the storage-wall call from already-validated budget inputs: the
admitted wall spec, the proved partition, and the journaled reservation. A
provider that cannot enforce the ceiling returns a typed 'Unsupported' rather
than a silent success — the whole point of this operation is that "we did not
apply your storage ceiling" is never indistinguishable from "applied".
-}
prepareStorageWallCall ::
  String ->
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Either
    ReconcileError
    (PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)
prepareStorageWallCall
  name
  (ProviderWallSpec providerKey budget)
  _partition
  (ProviderWallReservation _plan _operation _session fenceValue _attempt _journalVersion) =
    case providerKey of
      ColimaProviderKey ->
        case Cordon.colimaSizingArgsForBudget name budget of
          Left reason ->
            Left
              ( Failure
                  ( FailureDetail
                      "apply storage wall"
                      (Text.pack reason)
                      DoNotRetry
                  )
              )
          Right args ->
            exactStorageWall
              ColimaDiskArgument
              args
              storageBytes
              fenceValue
      LimaProviderKey ->
        exactStorageWall
          LimaDiskArgument
          ["--disk", show storageGiB]
          storageBytes
          fenceValue
      IncusProviderKey ->
        exactStorageWall
          IncusRootSizeArgument
          ["-d", "root,size=" ++ show storageGiB ++ "GiB"]
          storageBytes
          fenceValue
      Wsl2ProviderKey ->
        exactStorageWall
          Wsl2VhdSizeArgument
          ["--vhd-size", show storageGiB ++ "GB"]
          storageBytes
          fenceValue
      DockerNodeProviderKey ->
        unsupportedStorageWall DockerNodeBackend DockerNodeHasNoStorageFlag
      BareLinuxProviderKey ->
        unsupportedStorageWall BareLinuxBackend BareLinuxHasNoStorageQuota
    where
      storageBytes = budgetStorageBytes budget
      storageGiB = storageBytes `div` storageGibibyte

storageGibibyte :: Integer
storageGibibyte = 1024 ^ (3 :: Integer)

-- | A supported mechanism still refuses a ceiling it cannot represent exactly,
-- because rounding a hard ceiling upward is the failure § O forbids.
exactStorageWall ::
  StorageWallMechanism ->
  [String] ->
  Integer ->
  Word64 ->
  Either
    ReconcileError
    (PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)
exactStorageWall mechanism args storageBytes fenceValue
  | (storageBytes `div` storageGibibyte) * storageGibibyte /= storageBytes =
      Left
        ( Failure
            ( FailureDetail
                "apply storage wall"
                ( "the declared storage ceiling is not exactly representable in whole GiB: "
                    <> Text.pack (show storageBytes)
                )
                DoNotRetry
            )
        )
  | otherwise =
      Right (PreparedStorageWallCall mechanism args storageBytes fenceValue)

unsupportedStorageWall ::
  ProviderBackend ->
  StorageWallUnsupported ->
  Either ReconcileError result
unsupportedStorageWall backend reason =
  Left
    ( Unsupported
        ( UnsupportedDetail
            "apply storage wall"
            ( "the "
                <> Text.pack (show backend)
                <> " backend cannot enforce a storage ceiling ("
                <> Text.pack (show reason)
                <> ")"
            )
        )
    )

storageWallCallArgs ::
  PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  [String]
storageWallCallArgs (PreparedStorageWallCall _ args _ _) = args

storageWallCallMechanism ::
  PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  StorageWallMechanism
storageWallCallMechanism (PreparedStorageWallCall mechanism _ _ _) = mechanism

-- | The exact declared ceiling in bytes the observation must reproduce.
storageWallCeilingBytes ::
  PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Integer
storageWallCeilingBytes (PreparedStorageWallCall _ _ ceiling_ _) = ceiling_

{- | What the provider reported after the storage-wall call. The observed
ceiling is carried explicitly so settlement can reject a value the provider
rounded rather than accepting any success.
-}
data StorageWallObservation
  = StorageWallApplied Word64 Integer
  | StorageWallAlreadyExact Word64 Integer
  | StorageWallRefused ConflictDetail
  | StorageWallFailed FailureDetail
  | StorageWallUncertain String
  deriving (Eq, Show)

{- | Proof that the exact declared storage ceiling is in force, with the change
view that produced it.
-}
data AppliedStorageWall scope planId provider wallSpecId wallEpoch fence =
  AppliedStorageWall ChangeView

type role AppliedStorageWall nominal nominal nominal nominal nominal nominal

appliedStorageWallChange ::
  AppliedStorageWall scope planId provider wallSpecId wallEpoch fence ->
  ChangeView
appliedStorageWallChange (AppliedStorageWall change) = change

{- | Settle the storage-wall call. An observed ceiling that differs from the
declared one is a 'Conflict' even when the provider reported success: a
silently rounded hard ceiling is exactly the failure this operation exists to
make impossible (§ O).
-}
settleStorageWallCall ::
  PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  StorageWallObservation ->
  ( forall wallEpoch.
    AppliedStorageWall scope planId provider wallSpecId wallEpoch fence ->
    result
  ) ->
  Either ReconcileError result
settleStorageWallCall prepared observation consume =
  case observation of
    StorageWallApplied epoch observed -> settled epoch observed (Changed Created)
    StorageWallAlreadyExact epoch observed -> settled epoch observed Unchanged
    StorageWallRefused detail -> Left (Conflict detail)
    StorageWallFailed detail -> Left (Failure detail)
    StorageWallUncertain detail ->
      Left
        ( Failure
            (FailureDetail "apply storage wall" (Text.pack detail) ReprobeBeforeRetry)
        )
  where
    declared = storageWallCeilingBytes prepared
    settled epoch observed change
      | epoch == 0 =
          Left
            ( Failure
                (FailureDetail "apply storage wall" "wall epoch must be positive" DoNotRetry)
            )
      | observed /= declared =
          Left
            ( Conflict
                ( ConflictDetail
                    "storage-wall"
                    (Text.pack (show declared) <> " bytes")
                    (Text.pack (show observed) <> " bytes")
                    "the provider did not apply the declared storage ceiling exactly; a rounded hard ceiling is never accepted"
                )
            )
      | otherwise = Right (consume (AppliedStorageWall change))
