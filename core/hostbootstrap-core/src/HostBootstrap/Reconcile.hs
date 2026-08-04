{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Opaque lifecycle/reconciliation state shared by provider implementations.

The module separates untrusted observations and persisted records from
generative local authority. Constructors for handles, receipts, prepared calls,
verified records, and phase evidence are private.
-}
module HostBootstrap.Reconcile
  ( CanonicalPlanSnapshot,
    canonicalPlanSnapshotFormatVersion,
    canonicalPlanSnapshotSpecDigest,
    canonicalPlanSnapshotConfigDigest,
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotDigest,
    LifecyclePlan,
    withLifecyclePlan,
    withLifecyclePlanForConfig,
    lifecyclePlanDigest,
    lifecyclePlanSnapshot,
    lifecyclePlanSnapshotBytes,
    lifecyclePlanConfigDigest,
    lifecyclePlanFrames,
    lifecyclePlanSteps,
    stepExecutionFor,
    Unclassified,
    Managed,
    Unmanaged,
    Observed,
    Provisioned,
    ReadyPhase,
    Staged,
    Built,
    Running,
    Stopped,
    Destroyed,
    ResourceHandle,
    resourceHandleKey,
    resourceHandleGeneration,
    resourceHandleObservationVersion,
    PlannedResource,
    ProviderResource,
    DurableShareResource,
    DurableAliasResource,
    DockerResource,
    MinioResource,
    RegistryResource,
    ClusterResource,
    PlannedResourceKind (..),
    plannedResourceKey,
    plannedResourceFrame,
    plannedResourcePlanDigest,
    withPlannedResource,
    withPlannedResourceOfKind,
    PlannedEdge,
    withPlannedEdge,
    withProviderGuestAliasProjection,
    withObservedPlannedResource,
    OwnershipReceipt,
    ownershipReceiptOperationKey,
    validateOwnershipReceipt,
    ReconcileError (..),
    ConflictDetail (..),
    SafetyDetail (..),
    UnsupportedDetail (..),
    FailureDetail (..),
    RecoveryDisposition (..),
    ChangedKind (..),
    ChangeView (..),
    ForeignObservation (..),
    VerifiedForeignOrigin,
    withVerifiedForeignOrigin,
    AdoptionAuthority,
    withAdoptionAuthority,
    completeAdoption,
    BackendReconcileObservation (..),
    OperationDescriptor,
    plannedOperation,
    plannedGuestAliasOperation,
    operationDescriptorDependencies,
    DependencyProbe,
    dependencyProbe,
    DependencySnapshot,
    emptyDependencySnapshot,
    withDependencySnapshotEntry,
    OperationPreconditionSet,
    operationPreconditionKeys,
    withOperationPreconditions,
    zeroDependencyPreconditions,
    PreparedOperation,
    PreparedPreconditions,
    withPreparedOperation,
    ReconcileResult,
    completeReconcile,
    withReconcileResult,
    PersistedJournalPhase (..),
    PersistedJournalRecord (..),
    legalJournalTransition,
    advancePersistedJournalRecord,
    VerifiedJournalRecord,
    verifyPersistedJournalRecord,
    PriorCommitProof,
    withPriorCommitProof,
    completePreparedUnchanged,
    PhaseTransition,
    planMarkReady,
    planStage,
    planBuild,
    planRun,
    planStop,
    planRestart,
    planDestroy,
    VerifiedAtPhase,
    PhaseAdvance,
    verifyPhaseTransition,
    withPhaseAdvance,
  )
where

import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Config.Class (ProjectCodec, projectCodecSpecDigest)
import HostBootstrap.Lifecycle.Plan (
  CanonicalPlanSnapshot,
  canonicalPlanSnapshot,
  canonicalPlanSnapshotBytes,
  canonicalPlanSnapshotConfigDigest,
  canonicalPlanSnapshotDigest,
  canonicalPlanSnapshotFormatVersion,
  canonicalPlanSnapshotSpecDigest,
 )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution.Internal (
  ExecutionNode (..),
  StepExecution,
  mintStepExecution,
 )
import HostBootstrap.Lifecycle.Prepared (
  PreparedGate,
  preparedGateAttempt,
  preparedGateJournalVersion,
  preparedGateOperation,
  preparedGatePlan,
 )
import HostBootstrap.Step
  ( Step,
    StepPlan,
    frameId,
    operationKeyText,
    stepDependencies,
    stepFrame,
    stepIdentity,
    stepOperationKey,
    stepPlanSteps,
  )

data LifecyclePlan scope planId = LifecyclePlan CanonicalPlanSnapshot StepPlan

{- | Open a lifecycle plan for a config-free caller. Production command paths
must use 'withLifecyclePlanForConfig' with the digest of their exact admitted
wire. This compatibility bracket remains for pure provider and reconciliation
tests whose plan has no configuration identity.
-}
withLifecyclePlan ::
  ProjectCodec scope specDigest cfg ->
  StepPlan ->
  (forall planId. LifecyclePlan scope planId -> result) ->
  result
withLifecyclePlan codec plan consume =
  withLifecyclePlanForConfig codec configFreeDigest plan consume

-- | Open the plan under the digest of the exact admitted configuration. Raw
-- config bytes never enter the stable snapshot.
withLifecyclePlanForConfig ::
  ProjectCodec scope specDigest cfg ->
  Text ->
  StepPlan ->
  (forall planId. LifecyclePlan scope planId -> result) ->
  result
withLifecyclePlanForConfig codec configDigest plan consume =
  consume
    ( LifecyclePlan
        (canonicalPlanSnapshot (projectCodecSpecDigest codec) configDigest plan)
        plan
    )

lifecyclePlanDigest :: LifecyclePlan scope planId -> Text
lifecyclePlanDigest (LifecyclePlan snapshot _) =
  canonicalPlanSnapshotDigest snapshot

-- | The exact non-secret canonical snapshot from which this plan's digest was
-- computed.
lifecyclePlanSnapshot :: LifecyclePlan scope planId -> CanonicalPlanSnapshot
lifecyclePlanSnapshot (LifecyclePlan snapshot _) = snapshot

lifecyclePlanSnapshotBytes :: LifecyclePlan scope planId -> ByteString
lifecyclePlanSnapshotBytes = canonicalPlanSnapshotBytes . lifecyclePlanSnapshot

lifecyclePlanConfigDigest :: LifecyclePlan scope planId -> Text
lifecyclePlanConfigDigest = canonicalPlanSnapshotConfigDigest . lifecyclePlanSnapshot

-- | The validated step plan this lifecycle plan was built from. The reverse
-- projection reads it here rather than accepting one from a caller, so the
-- forward traversal and the teardown forest are provably the same plan (§ W).
lifecyclePlanSteps :: LifecyclePlan scope planId -> StepPlan
lifecyclePlanSteps (LifecyclePlan _ plan) = plan

{- | Mint the plan-minted execution descriptor for one step of __this__ plan
(§ U).

This is the sole producer, and it derives every identity on the descriptor from
the plan rather than from the caller: the plan's own digest, the step's operation
key and frame, and the operation keys of its exact ordered plan prefix.

It is 'Nothing' for a step this plan does not contain. That branch matters
because the function is public: without it a caller could hand in a foreign step
and receive a descriptor stamped with this plan's real digest, an operation key
the plan never validated, and an empty edge set indistinguishable from a genuine
first step. An interpreter iterating the plan's own steps never sees 'Nothing'.
-}
stepExecutionFor ::
  LifecyclePlan scope planId ->
  HostConfig ->
  Step ->
  Maybe (StepExecution scope planId)
stepExecutionFor plan cfg step
  | not planMember = Nothing
  | otherwise =
      Just
        ( mintStepExecution
            cfg
            (lifecyclePlanDigest plan)
            (executionNodeFor steps step)
        )
  where
    steps = lifecyclePlanSteps plan
    planMember =
      stepIdentity step `elem` map stepIdentity (stepPlanSteps steps)

{- | The neutral view of one node: its operation key, its frame, and the
operation keys of its exact ordered plan prefix. The prefix is walked in plan
order, and plan identities are unique, so each edge resolves to exactly one
step.
-}
executionNodeFor :: StepPlan -> Step -> ExecutionNode
executionNodeFor plan step =
  ExecutionNode
    { executionNodeOperationKey = Text.pack (operationKeyText (stepOperationKey step)),
      executionNodeFrame = Text.pack (frameId (stepFrame step)),
      executionNodeDependencyKeys =
        [ Text.pack (operationKeyText (stepOperationKey candidate))
        | identity <- stepDependencies plan step,
          candidate <- stepPlanSteps plan,
          stepIdentity candidate == identity
        ]
    }

-- | Every frame identifier the validated plan declares, in chain order. The
-- command gate compares a requested frame against this list, so an authority
-- cannot be minted for a frame outside the plan.
lifecyclePlanFrames :: LifecyclePlan scope planId -> [Text]
lifecyclePlanFrames (LifecyclePlan _ plan) =
  foldr dedupe [] (map (Text.pack . frameId . stepFrame) (stepPlanSteps plan))
  where
    dedupe value seen
      | value `elem` seen = seen
      | otherwise = value : seen

-- SHA-256 of the empty byte string. It marks genuinely config-free plans while
-- preserving the invariant that the canonical field is a digest, never an
-- arbitrary sentinel or raw configuration.
configFreeDigest :: Text
configFreeDigest =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

data Unclassified
data Managed
data Unmanaged
data Observed
data Provisioned
data ReadyPhase
data Staged
data Built
data Running
data Stopped
data Destroyed

data ResourceHandle scope planId id resource ownership phase =
  ResourceHandle Text Word64 Word64

resourceHandleKey ::
  ResourceHandle scope planId id resource ownership phase ->
  Text
resourceHandleKey (ResourceHandle key _ _) = key

resourceHandleGeneration ::
  ResourceHandle scope planId id resource ownership phase ->
  Word64
resourceHandleGeneration (ResourceHandle _ generation _) = generation

resourceHandleObservationVersion ::
  ResourceHandle scope planId id resource ownership phase ->
  Word64
resourceHandleObservationVersion (ResourceHandle _ _ version) = version

data PlannedResource scope planId id resource frame =
  PlannedResource Text Text Text

data ProviderResource
data DurableShareResource
data DurableAliasResource
data DockerResource
data MinioResource
data RegistryResource
data ClusterResource

data PlannedResourceKind resource where
  ProviderResourceKind :: PlannedResourceKind ProviderResource
  DurableShareResourceKind :: PlannedResourceKind DurableShareResource
  DockerResourceKind :: PlannedResourceKind DockerResource
  MinioResourceKind :: PlannedResourceKind MinioResource
  RegistryResourceKind :: PlannedResourceKind RegistryResource
  ClusterResourceKind :: PlannedResourceKind ClusterResource

plannedResourceKey ::
  PlannedResource scope planId id resource frame ->
  Text
plannedResourceKey (PlannedResource _ key _) = key

plannedResourceFrame ::
  PlannedResource scope planId id resource frame ->
  Text
plannedResourceFrame (PlannedResource _ _ frame) = frame

-- | The plan digest this resource was resolved from. The prepare gate is
-- checked against it, so a gate recorded in another plan's journal cannot
-- prepare this plan's operation.
plannedResourcePlanDigest ::
  PlannedResource scope planId id resource frame ->
  Text
plannedResourcePlanDigest (PlannedResource digest _ _) = digest

withPlannedResource ::
  LifecyclePlan scope planId ->
  Text ->
  ( forall id resource frame.
    PlannedResource scope planId id resource frame ->
    result
  ) ->
  Either ReconcileError result
withPlannedResource (LifecyclePlan snapshot plan) requestedKey consume =
  case find ((== Text.unpack requestedKey) . operationKeyText . stepOperationKey) (stepPlanSteps plan) of
    Nothing ->
      Left
        ( Failure
            ( FailureDetail
                "resolve planned resource"
                ("operation key is absent from the validated plan: " <> requestedKey)
                DoNotRetry
            )
        )
    Just step ->
      Right
        ( consume
            ( PlannedResource
                (canonicalPlanSnapshotDigest snapshot)
                requestedKey
                (Text.pack (frameId (stepFrame step)))
            )
        )

withPlannedResourceOfKind ::
  LifecyclePlan scope planId ->
  PlannedResourceKind resource ->
  Text ->
  ( forall id frame.
    PlannedResource scope planId id resource frame ->
    result
  ) ->
  Either ReconcileError result
withPlannedResourceOfKind (LifecyclePlan snapshot plan) resourceKind requestedKey consume
  | plannedKindAccepts resourceKind requestedKey =
      case find ((== Text.unpack requestedKey) . operationKeyText . stepOperationKey) (stepPlanSteps plan) of
        Nothing ->
          Left
            ( Failure
                ( FailureDetail
                    "resolve planned resource"
                    ("operation key is absent from the validated plan: " <> requestedKey)
                    DoNotRetry
                )
            )
        Just step ->
          Right
            ( consume
                (PlannedResource (canonicalPlanSnapshotDigest snapshot) requestedKey (Text.pack (frameId (stepFrame step))))
            )
  | otherwise =
      Left
        ( Conflict
            ( ConflictDetail
                requestedKey
                ("operation key for " <> plannedKindName resourceKind)
                "operation key belongs to another resource family"
                "use the closed plan resource kind associated with this operation"
            )
        )

{- | The closed operation key each planned resource family owns.  This is the
single source of truth for "which validated steps carry a plan-owned resource":
'plannedKindAccepts' and the dependency-snapshot traversal both read it, so a new
family cannot be admitted to one and omitted from the other.
-}
plannedKindKey :: PlannedResourceKind resource -> Text
plannedKindKey resourceKind =
  case resourceKind of
    ProviderResourceKind -> "core:deploy-vm"
    DurableShareResourceKind -> "core:copy-source"
    DockerResourceKind -> "core:ensure-docker"
    MinioResourceKind -> "project:deploy-minio"
    RegistryResourceKind -> "project:deploy-registry"
    ClusterResourceKind -> "core:deploy-kind"

data SomePlannedResourceKind where
  SomePlannedResourceKind :: PlannedResourceKind resource -> SomePlannedResourceKind

-- | Every planned resource family, in plan order.
plannedResourceKinds :: [SomePlannedResourceKind]
plannedResourceKinds =
  [ SomePlannedResourceKind ProviderResourceKind,
    SomePlannedResourceKind DurableShareResourceKind,
    SomePlannedResourceKind DockerResourceKind,
    SomePlannedResourceKind MinioResourceKind,
    SomePlannedResourceKind RegistryResourceKind,
    SomePlannedResourceKind ClusterResourceKind
  ]

{- | The operation keys that denote a plan-owned resource.  A validated step
outside this set — a project's own @ensure@ fragment, a context announcement, a
build step — mutates no plan resource, so it contributes no dependency edge and
no managed handle can exist for it.  This is what makes the ordered edge set of
§ CC a set over /resources/ rather than over every preceding step.
-}
plannedResourceFamilyKeys :: [Text]
plannedResourceFamilyKeys =
  [plannedKindKey resourceKind | SomePlannedResourceKind resourceKind <- plannedResourceKinds]

plannedKindAccepts :: PlannedResourceKind resource -> Text -> Bool
plannedKindAccepts resourceKind key = plannedKindKey resourceKind == key

plannedKindName :: PlannedResourceKind resource -> Text
plannedKindName resourceKind =
  case resourceKind of
    ProviderResourceKind -> "provider"
    DurableShareResourceKind -> "durable share"
    DockerResourceKind -> "Docker daemon"
    MinioResourceKind -> "MinIO"
    RegistryResourceKind -> "registry"
    ClusterResourceKind -> "cluster"

data PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame =
  PlannedEdge Text Text

withPlannedEdge ::
  LifecyclePlan scope planId ->
  Text ->
  Text ->
  ( forall targetId target targetFrame dependencyId dependency dependencyFrame.
    PlannedResource scope planId targetId target targetFrame ->
    PlannedResource scope planId dependencyId dependency dependencyFrame ->
    PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame ->
    result
  ) ->
  Either ReconcileError result
withPlannedEdge (LifecyclePlan snapshot plan) targetKey dependencyKey consume = do
  targetStep <-
    maybe
      (missing targetKey)
      Right
      (find ((== Text.unpack targetKey) . operationKeyText . stepOperationKey) (stepPlanSteps plan))
  dependencyStep <-
    maybe
      (missing dependencyKey)
      Right
      (find ((== Text.unpack dependencyKey) . operationKeyText . stepOperationKey) (stepPlanSteps plan))
  if stepIdentity dependencyStep `elem` stepDependencies plan targetStep
    then
      Right
        ( consume
            (PlannedResource (canonicalPlanSnapshotDigest snapshot) targetKey (Text.pack (frameId (stepFrame targetStep))))
            (PlannedResource (canonicalPlanSnapshotDigest snapshot) dependencyKey (Text.pack (frameId (stepFrame dependencyStep))))
            (PlannedEdge targetKey dependencyKey)
        )
    else
      Left
        ( Conflict
            ( ConflictDetail
                targetKey
                ("dependency in the validated prefix: " <> dependencyKey)
                "no such plan edge"
                "use an edge derived from the finalized step plan"
            )
        )
  where
    missing key =
      Left
        ( Failure
            ( FailureDetail
                "resolve planned edge"
                ("operation key is absent from the validated plan: " <> key)
                DoNotRetry
            )
        )

{- | Derive the provider-guest durable alias as a sealed child resource of the
validated provider/share prefix.  The alias is intentionally not a caller-owned
step identity: its stable key is derived from the closed @deploy-vm@ and
@copy-source@ operation keys, and the only dependency edge exposed by this
bracket is alias -> durable share.
-}
withProviderGuestAliasProjection ::
  LifecyclePlan scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  PlannedResource scope planId shareId DurableShareResource shareFrame ->
  ( forall aliasId.
    PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
    PlannedEdge
      scope
      planId
      aliasId
      DurableAliasResource
      shareFrame
      shareId
      DurableShareResource
      shareFrame ->
    result
  ) ->
  Either ReconcileError result
withProviderGuestAliasProjection (LifecyclePlan _ plan) provider share consume
  | providerKey /= "core:deploy-vm" =
      wrongKind providerKey "provider operation core:deploy-vm"
  | shareKey /= "core:copy-source" =
      wrongKind shareKey "durable-share operation core:copy-source"
  | otherwise =
      case (findStep providerKey, findStep shareKey) of
        (Just providerStep, Just shareStep)
          | stepIdentity providerStep `elem` stepDependencies plan shareStep ->
              Right
                ( consume
                    (PlannedResource (plannedResourcePlanDigest share) aliasKey (plannedResourceFrame share))
                    (PlannedEdge aliasKey shareKey)
                )
          | otherwise ->
              Left
                ( Conflict
                    ( ConflictDetail
                        aliasKey
                        "validated provider -> durable-share prefix"
                        "durable share is not downstream of the provider"
                        "derive the projection from the finalized provider/share plan"
                    )
                )
        _ ->
          Left
            ( Failure
                ( FailureDetail
                    "derive provider guest alias"
                    "provider or durable-share operation disappeared from the validated plan"
                    DoNotRetry
                )
            )
  where
    providerKey = plannedResourceKey provider
    shareKey = plannedResourceKey share
    aliasKey = providerKey <> "/" <> shareKey <> "/guest-alias"
    findStep key =
      find
        ((== Text.unpack key) . operationKeyText . stepOperationKey)
        (stepPlanSteps plan)
    wrongKind observed expected =
      Left
        ( Conflict
            ( ConflictDetail
                observed
                expected
                "resource belongs to another operation family"
                "use the closed planned resource kind for the provider guest projection"
            )
        )

withObservedPlannedResource ::
  LifecyclePlan scope planId ->
  PlannedResource scope planId id resource frame ->
  Word64 ->
  Word64 ->
  ( ResourceHandle scope planId id resource Unclassified Observed ->
    result
  ) ->
  Either ReconcileError result
withObservedPlannedResource _ planned generation version consume
  | nullText key =
      Left (Failure (FailureDetail "observe resource" "resource key is empty" DoNotRetry))
  | generation == 0 =
      Left (Failure (FailureDetail "observe resource" "generation must be positive" DoNotRetry))
  | version == 0 =
      Left (Failure (FailureDetail "observe resource" "observation version must be positive" DoNotRetry))
  | otherwise = Right (consume (ResourceHandle key generation version))
  where
    key = plannedResourceKey planned

data OwnershipReceipt scope planId id resource =
  OwnershipReceipt Text Word64 Text

ownershipReceiptOperationKey ::
  OwnershipReceipt scope planId id resource ->
  Text
ownershipReceiptOperationKey (OwnershipReceipt _ _ operationKey) = operationKey

{- | Check that an opaque receipt still names the exact managed identity and
generation.  The shared type indices reject cross-plan/resource use at compile
time; these value checks reject stale durable records.
-}
validateOwnershipReceipt ::
  ResourceHandle scope planId id resource Managed phase ->
  OwnershipReceipt scope planId id resource ->
  Either ReconcileError ()
validateOwnershipReceipt handle (OwnershipReceipt receiptKey receiptGeneration operationKey)
  | receiptKey /= resourceHandleKey handle =
      mismatch "resource key" (resourceHandleKey handle) receiptKey
  | receiptGeneration /= resourceHandleGeneration handle =
      mismatch
        "generation"
        (showText (resourceHandleGeneration handle))
        (showText receiptGeneration)
  | nullText operationKey =
      Left
        ( Failure
            (FailureDetail "validate ownership receipt" "operation key is empty" DoNotRetry)
        )
  | otherwise = Right ()
  where
    mismatch field expected observed =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                (field <> "=" <> expected)
                (field <> "=" <> observed)
                "load the ownership receipt for the exact managed generation"
            )
        )

data ConflictDetail = ConflictDetail
  { conflictResource :: Text,
    conflictExpected :: Text,
    conflictObserved :: Text,
    conflictRemedy :: Text
  }
  deriving (Eq, Show)

data SafetyDetail = SafetyDetail
  { refusedOperation :: Text,
    refusalReason :: Text
  }
  deriving (Eq, Show)

data UnsupportedDetail = UnsupportedDetail
  { unsupportedOperation :: Text,
    unsupportedReason :: Text
  }
  deriving (Eq, Show)

data RecoveryDisposition
  = ReprobeBeforeRetry
  | RetrySameOperationKeyAfterFencing
  | OperatorResolutionRequired
  | DoNotRetry
  deriving (Eq, Show)

data FailureDetail = FailureDetail
  { failedOperation :: Text,
    failureCause :: Text,
    recoveryDisposition :: RecoveryDisposition
  }
  deriving (Eq, Show)

data ReconcileError
  = Conflict ConflictDetail
  | SafetyRefusal SafetyDetail
  | Unsupported UnsupportedDetail
  | Failure FailureDetail
  deriving (Eq, Show)

data ChangedKind = Created | Repaired | Adopted
  deriving (Eq, Show)

data ChangeView = Changed ChangedKind | Unchanged
  deriving (Eq, Show)

data ForeignObservation = ForeignObservation
  { foreignIdentity :: Text,
    foreignDetail :: Text
  }
  deriving (Eq, Show)

data VerifiedForeignOrigin scope planId id resource originId =
  VerifiedForeignOrigin Text Word64 Word64 ForeignObservation

withVerifiedForeignOrigin ::
  ResourceHandle scope planId id resource Unmanaged Observed ->
  ForeignObservation ->
  ( forall originId.
    VerifiedForeignOrigin scope planId id resource originId ->
    result
  ) ->
  result
withVerifiedForeignOrigin handle observation consume =
  consume
    ( VerifiedForeignOrigin
        (resourceHandleKey handle)
        (resourceHandleGeneration handle)
        (resourceHandleObservationVersion handle)
        observation
    )

data AdoptionAuthority scope planId id resource originId operationKey =
  AdoptionAuthority Text Text

withAdoptionAuthority ::
  LifecyclePlan scope planId ->
  PlannedResource scope planId id resource frame ->
  ResourceHandle scope planId id resource Unmanaged Observed ->
  VerifiedForeignOrigin scope planId id resource originId ->
  Text ->
  ( forall operationKey.
    AdoptionAuthority scope planId id resource originId operationKey ->
    result
  ) ->
  Either ReconcileError result
withAdoptionAuthority _ planned handle (VerifiedForeignOrigin originKey originGeneration originVersion _) operationKey consume
  | plannedResourceKey planned /= resourceHandleKey handle =
      mismatch "planned resource" (plannedResourceKey planned) (resourceHandleKey handle)
  | originKey /= resourceHandleKey handle =
      mismatch "foreign origin resource" (resourceHandleKey handle) originKey
  | originGeneration /= resourceHandleGeneration handle =
      mismatch "foreign origin generation" (showText (resourceHandleGeneration handle)) (showText originGeneration)
  | originVersion /= resourceHandleObservationVersion handle =
      mismatch "foreign origin observation" (showText (resourceHandleObservationVersion handle)) (showText originVersion)
  | nullText operationKey =
      Left (Failure (FailureDetail "authorize adoption" "operation key must not be empty" DoNotRetry))
  | otherwise =
      Right (consume (AdoptionAuthority (resourceHandleKey handle) operationKey))
  where
    mismatch field expected observed =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                (field <> "=" <> expected)
                (field <> "=" <> observed)
                "reprobe and authorize adoption for the exact foreign origin"
            )
        )

data BackendReconcileObservation
  = BackendCreated Word64
  | BackendRepaired Word64
  | BackendForeign Word64 ForeignObservation
  | BackendAbsent
  | BackendUnsupported Text
  | BackendFailed Text RecoveryDisposition
  deriving (Eq, Show)

completeAdoption ::
  ResourceHandle scope planId id resource Unmanaged Observed ->
  VerifiedForeignOrigin scope planId id resource originId ->
  AdoptionAuthority scope planId id resource originId operationKey ->
  BackendReconcileObservation ->
  Either ReconcileError (ReconcileResult scope planId id resource Provisioned)
completeAdoption handle (VerifiedForeignOrigin originKey originGeneration originVersion _) (AdoptionAuthority authorityKey operationKey) observation
  | originKey /= resourceHandleKey handle
      || authorityKey /= resourceHandleKey handle
      || originGeneration /= resourceHandleGeneration handle
      || originVersion /= resourceHandleObservationVersion handle =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                "matching verified foreign origin and adoption authority"
                "stale or unrelated adoption evidence"
                "reprobe and restart the adoption transaction"
            )
        )
  | otherwise =
      case observation of
        BackendCreated generation -> adopted generation
        BackendRepaired generation -> adopted generation
        BackendForeign _ foreignState ->
          Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    "adoption transferred to managed ownership"
                    ("still foreign: " <> foreignDetail foreignState)
                    "leave the resource unmanaged and resolve ownership"
                )
            )
        BackendAbsent ->
          Left
            (Failure (FailureDetail "adopt resource" "resource became absent" OperatorResolutionRequired))
        BackendUnsupported reason ->
          Left (Unsupported (UnsupportedDetail "adopt resource" reason))
        BackendFailed cause disposition ->
          Left (Failure (FailureDetail "adopt resource" cause disposition))
  where
    adopted generation
      | generation /= resourceHandleGeneration handle =
          Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    (showText (resourceHandleGeneration handle))
                    (showText generation)
                    "reprobe the replacement before adoption"
                )
            )
      | otherwise =
          Right
            ( ManagedResult
                ( ResourceHandle
                    (resourceHandleKey handle)
                    generation
                    (resourceHandleObservationVersion handle)
                )
                (OwnershipReceipt (resourceHandleKey handle) generation operationKey)
                (Changed Adopted)
            )

data OperationDescriptor scope planId id resource fromPhase toPhase =
  OperationDescriptor Text Text Text [Text]

plannedOperation ::
  LifecyclePlan scope planId ->
  PlannedResource scope planId id resource frame ->
  ResourceHandle scope planId id resource Unclassified Observed ->
  Text ->
  Either
    ReconcileError
    (OperationDescriptor scope planId id resource Observed Provisioned)
plannedOperation (LifecyclePlan _ plan) planned handle callDigest
  | plannedResourceKey planned /= resourceHandleKey handle =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                ("planned target " <> plannedResourceKey planned)
                "different observed target"
                "prepare the handle obtained from the same planned resource"
            )
        )
  | nullText callDigest =
      Left (Failure (FailureDetail "plan operation" "call digest is empty" DoNotRetry))
  | otherwise = case targetStep of
      Nothing ->
        Left
          (Failure (FailureDetail "plan operation" "planned target disappeared" DoNotRetry))
      Just step ->
        Right
          ( OperationDescriptor
              (plannedResourcePlanDigest planned)
              (plannedResourceKey planned)
              callDigest
              -- The exact ordered *resource-bearing* prefix (§ CC).  The
              -- validated prefix may also contain steps that own no plan
              -- resource; those have no managed handle to observe, so including
              -- them would make the edge set unsatisfiable rather than stricter.
              [ key
              | dependencyIdentity <- stepDependencies plan step
              , dependency <-
                  maybeToList
                    (find ((== dependencyIdentity) . stepIdentity) (stepPlanSteps plan))
              , let key = Text.pack (operationKeyText (stepOperationKey dependency))
              , key `elem` plannedResourceFamilyKeys
              ]
          )
  where
    targetStep =
      find
        ((== Text.unpack (plannedResourceKey planned)) . operationKeyText . stepOperationKey)
        (stepPlanSteps plan)

{- | Prepare the synthetic provider-guest alias operation from the exact sealed
alias -> durable-share edge.  Unlike 'plannedOperation', this operation is a
plan-derived child rather than a standalone step, so its dependency set is
exactly the durable share named by the edge.
-}
plannedGuestAliasOperation ::
  PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
  PlannedEdge
    scope
    planId
    aliasId
    DurableAliasResource
    aliasFrame
    shareId
    DurableShareResource
    shareFrame ->
  ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed ->
  Text ->
  Either
    ReconcileError
    ( OperationDescriptor
        scope
        planId
        aliasId
        DurableAliasResource
        Observed
        Provisioned
    )
plannedGuestAliasOperation planned (PlannedEdge edgeTarget edgeDependency) handle callDigest
  | plannedResourceKey planned /= resourceHandleKey handle =
      mismatch
        "planned alias"
        (plannedResourceKey planned)
        (resourceHandleKey handle)
  | edgeTarget /= plannedResourceKey planned =
      mismatch "alias edge target" (plannedResourceKey planned) edgeTarget
  | nullText edgeDependency =
      Left
        (Failure (FailureDetail "plan guest alias" "durable-share dependency is empty" DoNotRetry))
  | nullText callDigest =
      Left (Failure (FailureDetail "plan guest alias" "call digest is empty" DoNotRetry))
  | otherwise =
      Right
        ( OperationDescriptor
            (plannedResourcePlanDigest planned)
            (plannedResourceKey planned)
            callDigest
            [edgeDependency]
        )
  where
    mismatch field expected observed =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                (field <> "=" <> expected)
                (field <> "=" <> observed)
                "derive the alias operation from one provider guest projection"
            )
        )

-- | The exact ordered dependency operation keys a descriptor demands.
operationDescriptorDependencies ::
  OperationDescriptor scope planId id resource fromPhase toPhase ->
  [Text]
operationDescriptorDependencies (OperationDescriptor _ _ _ dependencies) = dependencies

data DependencyObservation scope planId dependencyId dependency =
  DependencyObservation Text Word64 Word64

dependencyObservation ::
  ResourceHandle scope planId dependencyId dependency Managed phase ->
  Word64 ->
  Either
    ReconcileError
    (DependencyObservation scope planId dependencyId dependency)
dependencyObservation handle phaseVersion
  | phaseVersion == 0 =
      Left
        (Failure (FailureDetail "dependency observation" "phase version must be positive" DoNotRetry))
  | otherwise =
      Right
        ( DependencyObservation
            (resourceHandleKey handle)
            (resourceHandleGeneration handle)
            phaseVersion
        )

{- | A plan-owned probe that produces a /fresh/ phase-observation version for one
managed dependency at prepare time.  It is stored beside the managed handle in
the dependency snapshot and is run by the traversal, never by the caller of
'withPreparedOperation'; that is what stops a retained observation taken earlier
in the bring-up from authorizing a later effect (§ CC).
-}
newtype DependencyProbe scope planId dependencyId dependency =
  DependencyProbe (IO (Either ReconcileError Word64))

dependencyProbe ::
  IO (Either ReconcileError Word64) ->
  DependencyProbe scope planId dependencyId dependency
dependencyProbe = DependencyProbe

data DependencySnapshotEntry scope planId where
  DependencySnapshotEntry ::
    ResourceHandle scope planId dependencyId dependency Managed phase ->
    DependencyProbe scope planId dependencyId dependency ->
    DependencySnapshotEntry scope planId

{- | The managed resources this plan has acquired so far, each paired with its
plan-owned probe.  Only 'completeReconcile' / 'completePreparedUnchanged' can
produce the @Managed@ handle an entry requires, so an unowned or foreign
resource cannot enter the snapshot.
-}
newtype DependencySnapshot scope planId =
  DependencySnapshot [DependencySnapshotEntry scope planId]

emptyDependencySnapshot :: DependencySnapshot scope planId
emptyDependencySnapshot = DependencySnapshot []

withDependencySnapshotEntry ::
  ResourceHandle scope planId dependencyId dependency Managed phase ->
  DependencyProbe scope planId dependencyId dependency ->
  DependencySnapshot scope planId ->
  DependencySnapshot scope planId
withDependencySnapshotEntry handle probe (DependencySnapshot entries) =
  DependencySnapshot (entries ++ [DependencySnapshotEntry handle probe])

{- | The sealed preconditions of exactly one operation.  Its only producer is the
plan-owned traversal 'withOperationPreconditions', so a caller can neither hand
'withPreparedOperation' an assembled observation list nor select or omit a member
of the plan's ordered edge set.
-}
data OperationPreconditionSet scope planId id resource =
  OperationPreconditionSet Text Text Text [SomeDependencyObservation scope planId]

-- | The dependency keys actually sealed, in plan order. Reporting only.
operationPreconditionKeys ::
  OperationPreconditionSet scope planId id resource ->
  [Text]
operationPreconditionKeys (OperationPreconditionSet _ _ _ observations) =
  [key | SomeDependencyObservation (DependencyObservation key _ _) <- observations]

{- | The plan-owned dependency-snapshot traversal (§ CC).

It reads the exact ordered edge set out of the descriptor the plan minted, looks
up each member's managed resource in the snapshot, and runs that member's
plan-owned probe /now/.  A member the snapshot does not carry refuses; a member
carried twice refuses; a probe that does not observe readiness refuses.  The
zero-dependency branch is reached only when the descriptor itself declares no
edges, because the traversal iterates the descriptor rather than the snapshot.
-}
{- | The zero-dependency branch of the traversal.  It is reachable only for an
operation whose plan descriptor declares no edges — a descriptor that names any
dependency is refused here and must go through 'withOperationPreconditions', so
this is not a route around the snapshot.
-}
zeroDependencyPreconditions ::
  OperationDescriptor scope planId id resource fromPhase toPhase ->
  Either ReconcileError (OperationPreconditionSet scope planId id resource)
zeroDependencyPreconditions (OperationDescriptor planDigestOfOperation operationKey callDigest expectedDependencies)
  | null expectedDependencies =
      Right (OperationPreconditionSet planDigestOfOperation operationKey callDigest [])
  | otherwise =
      Left
        ( Conflict
            ( ConflictDetail
                operationKey
                "an operation with no plan dependencies"
                ( "the plan declares "
                    <> Text.intercalate "," expectedDependencies
                )
                "seal this operation through the plan dependency-snapshot traversal"
            )
        )

withOperationPreconditions ::
  OperationDescriptor scope planId id resource fromPhase toPhase ->
  DependencySnapshot scope planId ->
  IO (Either ReconcileError (OperationPreconditionSet scope planId id resource))
withOperationPreconditions
  (OperationDescriptor planDigestOfOperation operationKey callDigest expectedDependencies)
  (DependencySnapshot entries) = go [] expectedDependencies
    where
      go acc [] =
        pure
          ( Right
              ( OperationPreconditionSet
                  planDigestOfOperation
                  operationKey
                  callDigest
                  (reverse acc)
              )
          )
      go acc (dependencyKey : rest) =
        case [entry | entry@(DependencySnapshotEntry handle _) <- entries, resourceHandleKey handle == dependencyKey] of
          [] ->
            pure
              ( Left
                  ( Failure
                      ( FailureDetail
                          "seal operation preconditions"
                          ( "no managed resource for plan dependency "
                              <> dependencyKey
                              <> " of "
                              <> operationKey
                          )
                          ReprobeBeforeRetry
                      )
                  )
              )
          _ : _ : _ ->
            pure
              ( Left
                  ( Conflict
                      ( ConflictDetail
                          dependencyKey
                          "one managed resource per plan dependency"
                          "the dependency snapshot carries the key more than once"
                          "register each acquired resource under its plan operation key exactly once"
                      )
                  )
              )
          [DependencySnapshotEntry handle (DependencyProbe probe)] -> do
            observed <- probe
            case observed >>= dependencyObservation handle of
              Left err -> pure (Left err)
              Right observation ->
                go (SomeDependencyObservation observation : acc) rest

data PreparedOperation scope planId id resource operationKey callDigest attempt journalVersion =
  PreparedOperation Text Text Text Word64 Word64

data PreparedPreconditions scope planId id resource operationKey callDigest attempt journalVersion =
  PreparedPreconditions Text Text Text Word64 Word64

{- | Mint the prepared operation/preconditions pair for one plan operation.

The attempt and journal version are read off the 'PreparedGate' rather than
taken from the caller, so an adapter cannot be reached with a fabricated journal
version: the gate exists only because
'HostBootstrap.Lifecycle.Prepared.recordDurableUnknown' published this
operation's unknown phase against the protected store first.  The gate is also
checked to name /this/ operation, so a gate recorded for a different operation
cannot prepare this one.
-}
withPreparedOperation ::
  OperationDescriptor scope planId id resource fromPhase toPhase ->
  OperationPreconditionSet scope planId id resource ->
  PreparedGate ->
  ( forall operationKey callDigest attempt journalVersion.
    PreparedOperation scope planId id resource operationKey callDigest attempt journalVersion ->
    PreparedPreconditions scope planId id resource operationKey callDigest attempt journalVersion ->
    result
  ) ->
  Either ReconcileError result
withPreparedOperation
  (OperationDescriptor planDigestOfOperation operationKey callDigest expectedDependencies)
  (OperationPreconditionSet sealedPlan sealedOperation sealedDigest observations)
  gate
  consume
  | preparedGatePlan gate /= planDigestOfOperation =
      Left
        ( Conflict
            ( ConflictDetail
                operationKey
                ("a prepare gate from plan " <> planDigestOfOperation)
                ("a prepare gate from plan " <> preparedGatePlan gate)
                "prepare each operation through its own plan's journal"
            )
        )
  | sealedPlan /= planDigestOfOperation =
      Left
        ( Conflict
            ( ConflictDetail
                operationKey
                ("preconditions sealed for plan " <> planDigestOfOperation)
                ("preconditions sealed for plan " <> sealedPlan)
                "seal the precondition set from the same plan operation descriptor"
            )
        )
  | preparedGateOperation gate /= operationKey =
      Left
        ( Conflict
            ( ConflictDetail
                operationKey
                ("a prepare gate recorded for " <> operationKey)
                ("a prepare gate recorded for " <> preparedGateOperation gate)
                "record this operation's unknown phase before preparing it"
            )
        )
  | sealedOperation /= operationKey || sealedDigest /= callDigest =
      Left
        ( Conflict
            ( ConflictDetail
                operationKey
                ("preconditions sealed for " <> operationKey <> ":" <> callDigest)
                ("preconditions sealed for " <> sealedOperation <> ":" <> sealedDigest)
                "seal the precondition set from the same plan operation descriptor"
            )
        )
  | preparedGateAttempt gate == 0 =
      Left (Failure (FailureDetail "prepare operation" "attempt must be positive" DoNotRetry))
  | preparedGateJournalVersion gate == 0 =
      Left (Failure (FailureDetail "prepare operation" "journal version must be positive" DoNotRetry))
  | any invalidObservation observations =
      Left (Conflict (ConflictDetail operationKey "fresh managed dependency" "stale dependency" "reprobe the complete dependency set"))
  | observedDependencyKeys /= expectedDependencies =
      Left
        ( Conflict
            ( ConflictDetail
                operationKey
                ("exact ordered dependency set " <> Text.intercalate "," expectedDependencies)
                ("dependency set " <> Text.intercalate "," observedDependencyKeys)
                "use the plan-owned dependency snapshot traversal"
            )
        )
  | otherwise =
      Right
        ( consume
            ( PreparedOperation
                operationKey
                (operationKey <> ":" <> callDigest)
                callDigest
                (preparedGateAttempt gate)
                (preparedGateJournalVersion gate)
            )
            ( PreparedPreconditions
                operationKey
                (operationKey <> ":" <> callDigest)
                callDigest
                (preparedGateAttempt gate)
                (preparedGateJournalVersion gate)
            )
        )
  where
    invalidObservation (SomeDependencyObservation (DependencyObservation _ generation phaseVersion)) =
      generation == 0 || phaseVersion == 0
    observedDependencyKeys =
      [ key
      | SomeDependencyObservation (DependencyObservation key _ _) <- observations
      ]

{- | The private existential packaging of one sealed dependency observation.  It
never leaves this module, so a caller cannot assemble a heterogeneous dependency
list of its own.
-}
data SomeDependencyObservation scope planId where
  SomeDependencyObservation ::
    DependencyObservation scope planId dependencyId dependency ->
    SomeDependencyObservation scope planId

data ReconcileResult scope planId id resource phase where
  ManagedResult ::
    ResourceHandle scope planId id resource Managed phase ->
    OwnershipReceipt scope planId id resource ->
    ChangeView ->
    ReconcileResult scope planId id resource phase
  ForeignResult ::
    ResourceHandle scope planId id resource Unmanaged Observed ->
    ForeignObservation ->
    ReconcileResult scope planId id resource phase

completeReconcile ::
  ResourceHandle scope planId id resource Unclassified Observed ->
  PreparedOperation scope planId id resource operationKey callDigest attempt journalVersion ->
  PreparedPreconditions scope planId id resource operationKey callDigest attempt journalVersion ->
  BackendReconcileObservation ->
  Either ReconcileError (ReconcileResult scope planId id resource Provisioned)
completeReconcile
  handle
  (PreparedOperation targetKey operationKey callDigest attempt journalVersion)
  (PreparedPreconditions expectedTarget expectedOperation expectedDigest expectedAttempt expectedJournal)
  observation
    | targetKey /= resourceHandleKey handle =
        preparedMismatch "target resource" (resourceHandleKey handle) targetKey
    | (targetKey, operationKey, callDigest, attempt, journalVersion)
        /= (expectedTarget, expectedOperation, expectedDigest, expectedAttempt, expectedJournal) =
        Left
          ( Conflict
              ( ConflictDetail
                  (resourceHandleKey handle)
                  "preconditions from the exact prepared operation"
                  "preconditions belong to another preparation"
                  "discard both values and prepare the operation again"
              )
          )
    | nullText operationKey || nullText callDigest || attempt == 0 || journalVersion == 0 =
        Left
          ( Failure
              (FailureDetail "complete reconcile" "prepared operation is invalid" DoNotRetry)
          )
    | otherwise =
        case observation of
          BackendCreated generation ->
            managed Created generation
          BackendRepaired generation ->
            managed Repaired generation
          BackendForeign generation foreignState
            | generation == 0 ->
                Left
                  (Failure (FailureDetail "reconcile resource" "foreign generation must be positive" DoNotRetry))
            | otherwise ->
                Right
                  ( ForeignResult
                      (ResourceHandle (resourceHandleKey handle) generation (resourceHandleObservationVersion handle))
                      foreignState
                  )
          BackendAbsent ->
            Left
              (Failure (FailureDetail "reconcile resource" "resource remained absent" ReprobeBeforeRetry))
          BackendUnsupported reason ->
            Left (Unsupported (UnsupportedDetail "reconcile resource" reason))
          BackendFailed cause disposition ->
            Left (Failure (FailureDetail "reconcile resource" cause disposition))
  where
    preparedMismatch field expected observed =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                (field <> "=" <> expected)
                (field <> "=" <> observed)
                "prepare against the exact observed resource"
            )
        )
    managed change generation
      | generation /= resourceHandleGeneration handle =
          Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    (showText (resourceHandleGeneration handle))
                    (showText generation)
                    "reprobe the resource and resolve replacement ownership"
                )
            )
      | otherwise =
          Right
            ( ManagedResult
                (ResourceHandle (resourceHandleKey handle) generation (resourceHandleObservationVersion handle))
                (OwnershipReceipt (resourceHandleKey handle) generation operationKey)
                (Changed change)
            )

withReconcileResult ::
  ReconcileResult scope planId id resource phase ->
  ( ResourceHandle scope planId id resource Managed phase ->
    OwnershipReceipt scope planId id resource ->
    ChangeView ->
    result
  ) ->
  ( ResourceHandle scope planId id resource Unmanaged Observed ->
    ForeignObservation ->
    result
  ) ->
  result
withReconcileResult result managed consumeForeign =
  case result of
    ManagedResult handle receipt change -> managed handle receipt change
    ForeignResult handle observation -> consumeForeign handle observation

data PersistedJournalPhase
  = IntentRecorded
  | ReservationOutcomeUnknown
  | ReservationAbsent
  | ReservationRetryFenced
  | Reserved
  | EffectOutcomeUnknown
  | EffectAbsent
  | EffectRetryFenced
  | ObservedManaged
  | ObservedForeign
  | Committed
  | TeardownOutcomeUnknown
  | TeardownObservedForeign
  | Released
  | AdoptionIntentRecorded
  | AdoptionOutcomeUnknown
  | AdoptionObservedManaged
  | AdoptionObservedAbsent
  | AdoptionRetryFenced
  | AdoptionObservedForeign
  | AdoptionRefused
  | AdoptionCommitted
  | AdoptionTeardownOutcomeUnknown
  | AdoptionTeardownObservedForeign
  | AdoptionReleased
  | RepairIntentRecorded
  | RepairEffectOutcomeUnknown
  | RepairObservedOriginal
  | RepairRetryFenced
  | RepairObservedTarget
  | RepairObservedAbsent
  | RepairObservedUnexpected
  | RepairObservedForeign
  | RepairCommitted
  | PhaseIntentRecorded
  | PhaseEffectOutcomeUnknown
  | PhaseObservedFrom
  | PhaseRetryFenced
  | PhaseObservedTo
  | PhaseObservedAbsent
  | PhaseObservedUnexpected
  | PhaseObservedForeign
  | PhaseCommitted
  deriving (Eq, Show)

data PersistedJournalRecord = PersistedJournalRecord
  { persistedPlanDigest :: Text,
    persistedFrameKey :: Text,
    persistedResourceKey :: Text,
    persistedGeneration :: Word64,
    persistedOperation :: Text,
    persistedOperationKey :: Text,
    persistedRecordVersion :: Word64,
    persistedPhase :: PersistedJournalPhase
  }
  deriving (Eq, Show)

-- | The complete durable journal graph. Terminal absence/foreign/unexpected
-- branches have no successor. Retry from an authoritative original/absent
-- observation must cross the explicit fenced state first.
legalJournalTransition :: PersistedJournalPhase -> PersistedJournalPhase -> Bool
legalJournalTransition fromPhase toPhase =
  (fromPhase, toPhase)
    `elem`
      [ (IntentRecorded, ReservationOutcomeUnknown),
        (ReservationOutcomeUnknown, ReservationAbsent),
        (ReservationOutcomeUnknown, Reserved),
        (ReservationOutcomeUnknown, ObservedManaged),
        (ReservationOutcomeUnknown, ObservedForeign),
        (ReservationAbsent, ReservationRetryFenced),
        (ReservationRetryFenced, ReservationOutcomeUnknown),
        (Reserved, EffectOutcomeUnknown),
        (EffectOutcomeUnknown, EffectAbsent),
        (EffectOutcomeUnknown, ObservedManaged),
        (EffectOutcomeUnknown, ObservedForeign),
        (EffectAbsent, EffectRetryFenced),
        (EffectRetryFenced, EffectOutcomeUnknown),
        (ObservedManaged, Committed),
        (Committed, TeardownOutcomeUnknown),
        (TeardownOutcomeUnknown, Committed),
        (TeardownOutcomeUnknown, Released),
        (TeardownOutcomeUnknown, TeardownObservedForeign),
        (AdoptionIntentRecorded, AdoptionOutcomeUnknown),
        (AdoptionOutcomeUnknown, AdoptionObservedManaged),
        (AdoptionOutcomeUnknown, AdoptionObservedAbsent),
        (AdoptionOutcomeUnknown, AdoptionObservedForeign),
        (AdoptionOutcomeUnknown, AdoptionRefused),
        (AdoptionObservedAbsent, AdoptionRetryFenced),
        (AdoptionRetryFenced, AdoptionOutcomeUnknown),
        (AdoptionObservedManaged, AdoptionCommitted),
        (AdoptionCommitted, AdoptionTeardownOutcomeUnknown),
        (AdoptionTeardownOutcomeUnknown, AdoptionCommitted),
        (AdoptionTeardownOutcomeUnknown, AdoptionReleased),
        (AdoptionTeardownOutcomeUnknown, AdoptionTeardownObservedForeign),
        (RepairIntentRecorded, RepairEffectOutcomeUnknown),
        (RepairEffectOutcomeUnknown, RepairObservedOriginal),
        (RepairEffectOutcomeUnknown, RepairObservedTarget),
        (RepairEffectOutcomeUnknown, RepairObservedAbsent),
        (RepairEffectOutcomeUnknown, RepairObservedUnexpected),
        (RepairEffectOutcomeUnknown, RepairObservedForeign),
        (RepairObservedOriginal, RepairRetryFenced),
        (RepairRetryFenced, RepairEffectOutcomeUnknown),
        (RepairObservedTarget, RepairCommitted),
        (PhaseIntentRecorded, PhaseEffectOutcomeUnknown),
        (PhaseEffectOutcomeUnknown, PhaseObservedFrom),
        (PhaseEffectOutcomeUnknown, PhaseObservedTo),
        (PhaseEffectOutcomeUnknown, PhaseObservedAbsent),
        (PhaseEffectOutcomeUnknown, PhaseObservedUnexpected),
        (PhaseEffectOutcomeUnknown, PhaseObservedForeign),
        (PhaseObservedFrom, PhaseRetryFenced),
        (PhaseRetryFenced, PhaseEffectOutcomeUnknown),
        (PhaseObservedTo, PhaseCommitted)
      ]

advancePersistedJournalRecord ::
  PersistedJournalRecord ->
  PersistedJournalPhase ->
  Either ReconcileError PersistedJournalRecord
advancePersistedJournalRecord record nextPhase
  | not (legalJournalTransition (persistedPhase record) nextPhase) =
      Left
        ( SafetyRefusal
            ( SafetyDetail
                (persistedOperation record)
                ( "illegal journal transition "
                    <> showText (persistedPhase record)
                    <> " -> "
                    <> showText nextPhase
                )
            )
        )
  | persistedRecordVersion record == maxBound =
      Left
        ( Failure
            (FailureDetail "advance journal" "record version overflow" DoNotRetry)
        )
  | otherwise =
      Right
        record
          { persistedRecordVersion = persistedRecordVersion record + 1,
            persistedPhase = nextPhase
          }

newtype VerifiedJournalRecord scope planId id resource =
  VerifiedJournalRecord PersistedJournalRecord

verifyPersistedJournalRecord ::
  LifecyclePlan scope planId ->
  ResourceHandle scope planId id resource ownership phase ->
  Text ->
  PersistedJournalRecord ->
  Either ReconcileError (VerifiedJournalRecord scope planId id resource)
verifyPersistedJournalRecord plan handle expectedOperation record
  | persistedPlanDigest record /= lifecyclePlanDigest plan =
      mismatch "plan digest" (lifecyclePlanDigest plan) (persistedPlanDigest record)
  | persistedResourceKey record /= resourceHandleKey handle =
      mismatch "resource key" (resourceHandleKey handle) (persistedResourceKey record)
  | persistedGeneration record /= resourceHandleGeneration handle =
      mismatch "generation" (showText (resourceHandleGeneration handle)) (showText (persistedGeneration record))
  | persistedOperation record /= expectedOperation =
      mismatch "operation" expectedOperation (persistedOperation record)
  | persistedRecordVersion record == 0 =
      Left (Failure (FailureDetail "verify journal" "record version must be positive" DoNotRetry))
  | nullText (persistedFrameKey record) || nullText (persistedOperationKey record) =
      Left (Failure (FailureDetail "verify journal" "stable frame/operation keys are required" DoNotRetry))
  | otherwise = Right (VerifiedJournalRecord record)
  where
    mismatch field expected observed =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                (field <> "=" <> expected)
                (field <> "=" <> observed)
                "load the matching protected journal record"
            )
        )

newtype PriorCommitProof scope planId id resource =
  PriorCommitProof (OwnershipReceipt scope planId id resource)

withPriorCommitProof ::
  VerifiedJournalRecord scope planId id resource ->
  (PriorCommitProof scope planId id resource -> result) ->
  Either ReconcileError result
withPriorCommitProof (VerifiedJournalRecord record) consume
  | persistedPhase record == Committed =
      Right
        ( consume
            ( PriorCommitProof
                ( OwnershipReceipt
                    (persistedResourceKey record)
                    (persistedGeneration record)
                    (persistedOperationKey record)
                )
            )
        )
  | otherwise =
      Left
        ( Failure
            ( FailureDetail
                "rebind ownership"
                "journal record is not committed"
                OperatorResolutionRequired
            )
        )

completePreparedUnchanged ::
  ResourceHandle scope planId id resource Unclassified Observed ->
  PreparedOperation scope planId id resource operationKey callDigest attempt journalVersion ->
  PreparedPreconditions scope planId id resource operationKey callDigest attempt journalVersion ->
  PriorCommitProof scope planId id resource ->
  Either ReconcileError (ReconcileResult scope planId id resource Provisioned)
completePreparedUnchanged
  handle
  (PreparedOperation targetKey operationKey callDigest attempt journalVersion)
  (PreparedPreconditions expectedTarget expectedOperation expectedDigest expectedAttempt expectedJournal)
  (PriorCommitProof receipt@(OwnershipReceipt receiptKey receiptGeneration receiptOperation))
    | targetKey /= resourceHandleKey handle =
        mismatch "target resource" (resourceHandleKey handle) targetKey
    | (targetKey, operationKey, callDigest, attempt, journalVersion)
        /= (expectedTarget, expectedOperation, expectedDigest, expectedAttempt, expectedJournal) =
        Left
          ( Conflict
              ( ConflictDetail
                  (resourceHandleKey handle)
                  "preconditions from the exact prepared operation"
                  "preconditions belong to another preparation"
                  "prepare again before rebinding the prior commit"
              )
          )
    | receiptKey /= resourceHandleKey handle =
        mismatch "receipt resource" (resourceHandleKey handle) receiptKey
    | receiptGeneration /= resourceHandleGeneration handle =
        mismatch
          "receipt generation"
          (showText (resourceHandleGeneration handle))
          (showText receiptGeneration)
    | receiptOperation /= operationKey =
        mismatch "receipt operation key" operationKey receiptOperation
    | otherwise =
        Right
          ( ManagedResult
              ( ResourceHandle
                  (resourceHandleKey handle)
                  (resourceHandleGeneration handle)
                  (resourceHandleObservationVersion handle)
              )
              receipt
              Unchanged
          )
  where
    mismatch field expected observed =
      Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                (field <> "=" <> expected)
                (field <> "=" <> observed)
                "load the committed record for the exact prepared operation"
            )
        )

data PhaseTransition scope planId id resource fromPhase toPhase =
  PhaseTransition Text Text

namedPhaseTransition ::
  ResourceHandle scope planId id resource Managed fromPhase ->
  Text ->
  Text ->
  Either ReconcileError (PhaseTransition scope planId id resource fromPhase toPhase)
namedPhaseTransition handle fromName toName
  | nullText fromName || nullText toName =
      Left (Failure (FailureDetail "plan phase transition" "phase names must not be empty" DoNotRetry))
  | fromName == toName =
      Left (Failure (FailureDetail "plan phase transition" "source and target phases must differ" DoNotRetry))
  | otherwise = Right (PhaseTransition (resourceHandleKey handle <> ":" <> fromName) toName)

planMarkReady ::
  ResourceHandle scope planId id resource Managed Provisioned ->
  Either ReconcileError (PhaseTransition scope planId id resource Provisioned ReadyPhase)
planMarkReady handle = namedPhaseTransition handle "provisioned" "ready"

planStage ::
  ResourceHandle scope planId id resource Managed ReadyPhase ->
  Either ReconcileError (PhaseTransition scope planId id resource ReadyPhase Staged)
planStage handle = namedPhaseTransition handle "ready" "staged"

planBuild ::
  ResourceHandle scope planId id resource Managed Staged ->
  Either ReconcileError (PhaseTransition scope planId id resource Staged Built)
planBuild handle = namedPhaseTransition handle "staged" "built"

planRun ::
  ResourceHandle scope planId id resource Managed Built ->
  Either ReconcileError (PhaseTransition scope planId id resource Built Running)
planRun handle = namedPhaseTransition handle "built" "running"

planStop ::
  ResourceHandle scope planId id resource Managed Running ->
  Either ReconcileError (PhaseTransition scope planId id resource Running Stopped)
planStop handle = namedPhaseTransition handle "running" "stopped"

planRestart ::
  ResourceHandle scope planId id resource Managed Stopped ->
  Either ReconcileError (PhaseTransition scope planId id resource Stopped Running)
planRestart handle = namedPhaseTransition handle "stopped" "running"

planDestroy ::
  ResourceHandle scope planId id resource Managed Stopped ->
  Either ReconcileError (PhaseTransition scope planId id resource Stopped Destroyed)
planDestroy handle = namedPhaseTransition handle "stopped" "destroyed"

data VerifiedAtPhase scope planId id resource phase = VerifiedAtPhase Text Word64

data PhaseAdvance scope planId id resource toPhase =
  PhaseAdvance
    (ResourceHandle scope planId id resource Managed toPhase)
    (OwnershipReceipt scope planId id resource)
    (VerifiedAtPhase scope planId id resource toPhase)

verifyPhaseTransition ::
  ResourceHandle scope planId id resource Managed fromPhase ->
  OwnershipReceipt scope planId id resource ->
  PhaseTransition scope planId id resource fromPhase toPhase ->
  Word64 ->
  Either ReconcileError (PhaseAdvance scope planId id resource toPhase)
verifyPhaseTransition handle receipt@(OwnershipReceipt receiptKey receiptGeneration _) (PhaseTransition operation target) observedGeneration
  | receiptKey /= resourceHandleKey handle =
      Left (Conflict (ConflictDetail (resourceHandleKey handle) "matching ownership receipt" "receipt resource mismatch" "load the matching receipt"))
  | receiptGeneration /= resourceHandleGeneration handle =
      Left (Conflict (ConflictDetail (resourceHandleKey handle) "matching ownership receipt" "receipt generation mismatch" "load the matching receipt"))
  | observedGeneration /= resourceHandleGeneration handle =
      Left (Conflict (ConflictDetail (resourceHandleKey handle) (showText (resourceHandleGeneration handle)) (showText observedGeneration) "reprobe the phase transition"))
  | resourceHandleObservationVersion handle == maxBound =
      Left (Failure (FailureDetail "verify phase transition" "observation version overflow" DoNotRetry))
  | otherwise =
      Right
        ( PhaseAdvance
            ( ResourceHandle
                (resourceHandleKey handle)
                observedGeneration
                (resourceHandleObservationVersion handle + 1)
            )
            receipt
            (VerifiedAtPhase (operation <> ":" <> target) observedGeneration)
        )

withPhaseAdvance ::
  PhaseAdvance scope planId id resource toPhase ->
  ( ResourceHandle scope planId id resource Managed toPhase ->
    OwnershipReceipt scope planId id resource ->
    VerifiedAtPhase scope planId id resource toPhase ->
    result
  ) ->
  result
withPhaseAdvance (PhaseAdvance handle receipt verified) consume =
  consume handle receipt verified

nullText :: Text -> Bool
nullText = (== "")

showText :: Show value => value -> Text
showText = Text.pack . show

maybeToList :: Maybe value -> [value]
maybeToList Nothing = []
maybeToList (Just value) = [value]
