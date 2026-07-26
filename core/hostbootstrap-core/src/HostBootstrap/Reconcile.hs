{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Opaque lifecycle/reconciliation state shared by provider implementations.

The module separates untrusted observations and persisted records from
generative local authority. Constructors for handles, receipts, prepared calls,
verified records, and phase evidence are private.
-}
module HostBootstrap.Reconcile
  ( LifecyclePlan,
    withLifecyclePlan,
    lifecyclePlanDigest,
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
    DockerResource,
    MinioResource,
    RegistryResource,
    ClusterResource,
    PlannedResourceKind (..),
    plannedResourceKey,
    plannedResourceFrame,
    withPlannedResource,
    withPlannedResourceOfKind,
    PlannedEdge,
    withPlannedEdge,
    withObservedPlannedResource,
    OwnershipReceipt,
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
    DependencyObservation,
    dependencyObservation,
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
    completeUnchanged,
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

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Config.Class (ProjectCodec, projectCodecSpecDigest)
import HostBootstrap.Step
  ( StepPlan,
    frameId,
    operationKeyText,
    stepDependencies,
    stepFrame,
    stepIdentity,
    stepOperationKey,
    stepPlanSteps,
    stepReversePolicy,
  )

data LifecyclePlan scope planId = LifecyclePlan Text StepPlan

withLifecyclePlan ::
  ProjectCodec scope specDigest cfg ->
  StepPlan ->
  (forall planId. LifecyclePlan scope planId -> result) ->
  result
withLifecyclePlan codec plan consume =
  consume (LifecyclePlan (planDigest codec plan) plan)

lifecyclePlanDigest :: LifecyclePlan scope planId -> Text
lifecyclePlanDigest (LifecyclePlan digest _) = digest

planDigest :: ProjectCodec scope specDigest cfg -> StepPlan -> Text
planDigest codec plan =
  Text.intercalate
    "|"
    ( projectCodecSpecDigest codec
        : [ Text.pack (frameId (stepFrame step))
              <> ":"
              <> Text.pack (operationKeyText (stepOperationKey step))
              <> ":"
              <> Text.pack (show (stepReversePolicy step))
          | step <- stepPlanSteps plan
          ]
    )

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
  PlannedResource Text Text

data ProviderResource
data DurableShareResource
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
plannedResourceKey (PlannedResource key _) = key

plannedResourceFrame ::
  PlannedResource scope planId id resource frame ->
  Text
plannedResourceFrame (PlannedResource _ frame) = frame

withPlannedResource ::
  LifecyclePlan scope planId ->
  Text ->
  ( forall id resource frame.
    PlannedResource scope planId id resource frame ->
    result
  ) ->
  Either ReconcileError result
withPlannedResource (LifecyclePlan _ plan) requestedKey consume =
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
withPlannedResourceOfKind (LifecyclePlan _ plan) resourceKind requestedKey consume
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
                (PlannedResource requestedKey (Text.pack (frameId (stepFrame step))))
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

plannedKindAccepts :: PlannedResourceKind resource -> Text -> Bool
plannedKindAccepts resourceKind key =
  case resourceKind of
    ProviderResourceKind -> key == "core:deploy-vm"
    DurableShareResourceKind -> key == "core:copy-source"
    DockerResourceKind -> key == "core:ensure-docker"
    MinioResourceKind -> key == "project:deploy-minio"
    RegistryResourceKind -> key == "project:deploy-registry"
    ClusterResourceKind -> key == "core:deploy-kind"

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
withPlannedEdge (LifecyclePlan _ plan) targetKey dependencyKey consume = do
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
            (PlannedResource targetKey (Text.pack (frameId (stepFrame targetStep))))
            (PlannedResource dependencyKey (Text.pack (frameId (stepFrame dependencyStep))))
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
  OperationDescriptor Text Text [Text]

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
              (plannedResourceKey planned)
              callDigest
              [ Text.pack (operationKeyText (stepOperationKey dependency))
              | dependencyIdentity <- stepDependencies plan step
              , dependency <-
                  maybeToList
                    (find ((== dependencyIdentity) . stepIdentity) (stepPlanSteps plan))
              ]
          )
  where
    targetStep =
      find
        ((== Text.unpack (plannedResourceKey planned)) . operationKeyText . stepOperationKey)
        (stepPlanSteps plan)

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

data PreparedOperation scope planId id resource operationKey callDigest attempt journalVersion =
  PreparedOperation Text Word64 Word64

data PreparedPreconditions scope planId id resource operationKey callDigest attempt journalVersion =
  PreparedPreconditions Word64

withPreparedOperation ::
  OperationDescriptor scope planId id resource fromPhase toPhase ->
  [SomeDependencyObservation scope planId] ->
  Word64 ->
  Word64 ->
  ( forall operationKey callDigest attempt journalVersion.
    PreparedOperation scope planId id resource operationKey callDigest attempt journalVersion ->
    PreparedPreconditions scope planId id resource operationKey callDigest attempt journalVersion ->
    result
  ) ->
  Either ReconcileError result
withPreparedOperation (OperationDescriptor operationKey callDigest expectedDependencies) observations attempt journalVersion consume
  | attempt == 0 =
      Left (Failure (FailureDetail "prepare operation" "attempt must be positive" DoNotRetry))
  | journalVersion == 0 =
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
            (PreparedOperation (operationKey <> ":" <> callDigest) attempt journalVersion)
            (PreparedPreconditions journalVersion)
        )
  where
    invalidObservation (SomeDependencyObservation (DependencyObservation _ generation phaseVersion)) =
      generation == 0 || phaseVersion == 0
    observedDependencyKeys =
      [ key
      | SomeDependencyObservation (DependencyObservation key _ _) <- observations
      ]

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
completeReconcile handle _ _ observation =
  case observation of
    BackendCreated generation ->
      managed Created generation
    BackendRepaired generation ->
      managed Repaired generation
    BackendForeign generation foreignState ->
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
                (OwnershipReceipt (resourceHandleKey handle) generation "ordinary-acquire")
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

data VerifiedJournalRecord scope planId id resource =
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

data PriorCommitProof scope planId id resource = PriorCommitProof Text

withPriorCommitProof ::
  VerifiedJournalRecord scope planId id resource ->
  (PriorCommitProof scope planId id resource -> result) ->
  Either ReconcileError result
withPriorCommitProof (VerifiedJournalRecord record) consume
  | persistedPhase record == Committed =
      Right (consume (PriorCommitProof (persistedOperationKey record)))
  | otherwise =
      Left
        ( Failure
            ( FailureDetail
                "rebind ownership"
                "journal record is not committed"
                OperatorResolutionRequired
            )
        )

completeUnchanged ::
  ResourceHandle scope planId id resource Unclassified Observed ->
  PriorCommitProof scope planId id resource ->
  ReconcileResult scope planId id resource Provisioned
completeUnchanged handle (PriorCommitProof operationKey) =
  ManagedResult
    ( ResourceHandle
        (resourceHandleKey handle)
        (resourceHandleGeneration handle)
        (resourceHandleObservationVersion handle)
    )
    ( OwnershipReceipt
        (resourceHandleKey handle)
        (resourceHandleGeneration handle)
        operationKey
    )
    Unchanged

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
verifyPhaseTransition handle (OwnershipReceipt _ receiptGeneration _) (PhaseTransition operation target) observedGeneration
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
            (OwnershipReceipt (resourceHandleKey handle) receiptGeneration operation)
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
