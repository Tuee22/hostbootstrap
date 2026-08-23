{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Prepared, ownership-aware settlement for provider lifecycle calls.

Raw provider observations remain plan-independent, package-private facts.  A
clause-holding backend binds each observation to an opaque call result carrying
the exact prepared operation and generative backend indices.  It becomes
managed provider state only when settled against the matching opaque call,
prepared from one exact 'StepExecution', backend binding, planned
'ProviderResource', handle, and 'PreparedGate'.  Provider discovery happens
only after settlement, from the managed handle this module returns.

The Direct provider follows the same algebra but has deliberately narrower
meaning.  Its prepared lifecycle journal is the plan-local reservation for the
local frame; the backend publishes no separate origin record.  Its generation
identifies that reservation only: it is never the physical host's identity,
never ownership of the host, and never authority to stop or delete it.  Direct
readiness may advance that reservation, while Direct stop/delete return no
successor phase.
-}
module HostBootstrap.Substrate.Provider.Reconcile (
    ProviderBackendBinding,
    ManagedProviderHandle,
    managedProviderKey,
    managedProviderGeneration,
    managedProviderObservationVersion,
    PreparedProviderBinding,
    preparedProviderBindingOwner,
    preparedProviderBindingPlanDigest,
    preparedProviderBindingResourceKey,
    preparedProviderBindingGeneration,
    preparedProviderBindingOperationKey,
    preparedProviderBindingCallDigest,
    ProviderProvisionCallResult,
    PreparedProviderProvision,
    withPreparedProviderProvision,
    preparedProviderProvisionBinding,
    preparedProviderProvisionHandle,
    ProviderProvisionSettlement,
    withProviderProvisionSettlement,
    settleProviderProvision,
    ProviderShareSpec,
    mkProviderShareSpec,
    providerShareHostPath,
    providerShareGuestPath,
    ManagedProviderShareHandle,
    managedProviderShareKey,
    managedProviderShareGeneration,
    managedProviderShareObservationVersion,
    ProviderShareCallResult,
    PreparedProviderShare,
    withPreparedProviderShare,
    preparedProviderShareBinding,
    preparedProviderShareSpec,
    preparedProviderShareHandle,
    ProviderShareSettlement,
    withProviderShareSettlement,
    settleProviderShare,
    ProviderStartable,
    providerStartableAfterProvision,
    providerStartableAfterStop,
    ProviderReadyCallResult,
    PreparedProviderReady,
    withPreparedProviderReady,
    preparedProviderReadyBinding,
    preparedProviderReadyHandle,
    ProviderPhaseAdvance,
    withProviderPhaseAdvance,
    settleProviderReady,
    carryRunningProviderSettlement,
    carryCreatedRunningProviderSettlement,
    withFreshRunningProviderDependency,
    withFreshCarriedRunningProviderDependency,
    withFreshRunningProviderHandle,
    ProviderStopCallResult,
    PreparedProviderStop,
    withPreparedProviderStop,
    preparedProviderStopBinding,
    preparedProviderStopHandle,
    settleProviderStop,
    ProviderDeleteCallResult,
    PreparedProviderDelete,
    withPreparedProviderDelete,
    preparedProviderDeleteBinding,
    preparedProviderDeleteHandle,
    settleProviderDelete,
)
where

import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Dependency.Internal (
    RuntimeDependencyPackage,
    runtimeDependencyPackageKey,
    runtimeDependencyProbeRequest,
    verifyRuntimeDependencyProbeResponse,
    withCarriedProviderRuntimeDependencyCoordinates,
    withProviderRuntimeDependencyCoordinates,
 )
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
 )
import qualified HostBootstrap.Lifecycle.Execution.Internal as ExecutionInternal
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (PlannedResource, plannedResourceFrame)
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ChangeView,
    ConflictDetail (..),
    DependencyProbe,
    Destroyed,
    DurableShareResource,
    FailureDetail (..),
    ForeignObservation (..),
    Managed,
    Observed,
    OperationDescriptor,
    OperationPreconditionSet,
    OwnershipReceipt,
    PhaseTransition,
    PlannedResourceKind (ProviderResourceKind),
    PreparedOperation,
    PreparedPhaseTransition,
    PreparedPreconditions,
    PriorCommitProof,
    ProviderResource,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (..),
    ResourceHandle,
    Running,
    Stopped,
    Unclassified,
    carryManagedResourcePhaseSettlement,
    carryManagedResourceSettlement,
    completePreparedPhaseTransition,
    completePreparedUnchanged,
    completeReconcile,
    emptyDependencySnapshot,
    planDestroy,
    planProviderBoot,
    planRestart,
    planStop,
    plannedNodeOperation,
    plannedNodePhaseOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
    validateOwnershipReceipt,
    withCarriedManagedResourceReceipt,
    withDependencySnapshotEntry,
    withNodeResourceOfKind,
    withOperationPreconditions,
    withPhaseAdvance,
    withPlannedReboundManagedResourceEvidence,
    withPreparedOperation,
    withPreparedPhaseTransition,
    withReconcileResult,
    zeroDependencyPreconditions,
 )
import HostBootstrap.Substrate.Provider.Dependency.Internal (RunningProviderDependency (..))
import HostBootstrap.Substrate.Provider.Observation.Internal (
    ManagedProviderHandle (..),
    ManagedProviderShareHandle (..),
    ProviderBackendBinding,
    ProviderDeleteCallResult (..),
    ProviderDeleteObservation (..),
    ProviderOriginBinding (..),
    ProviderProvisionCallResult (..),
    ProviderProvisionObservation (..),
    ProviderReadyCallResult (..),
    ProviderReadyObservation (..),
    ProviderShareCallResult (..),
    ProviderShareObservation (..),
    ProviderStopCallResult (..),
    ProviderStopObservation (..),
    providerBackendRealizationFingerprint,
    providerBackendSemanticFingerprint,
    providerOriginOwner,
 )
import System.FilePath (isAbsolute)

{- | Descriptive binding retained by every opaque provider call.

The owner text is stable across provision/readiness/stop/delete for the same
plan resource generation.  The operation key and call digest remain separate
so a backend can journal which prepared effect it is executing without making
that effect part of the resource's ownership identity.
-}
data PreparedProviderBinding scope planId backendId providerId
    = PreparedProviderBinding
        (ProviderOriginBinding scope planId backendId providerId)
        Text
        Text

type role PreparedProviderBinding nominal nominal nominal nominal

preparedProviderBindingPlanDigest ::
    PreparedProviderBinding scope planId backendId providerId ->
    Text
preparedProviderBindingPlanDigest (PreparedProviderBinding origin _ _) =
    providerOriginPlanDigest origin

preparedProviderBindingResourceKey ::
    PreparedProviderBinding scope planId backendId providerId ->
    Text
preparedProviderBindingResourceKey (PreparedProviderBinding origin _ _) =
    providerOriginResourceKey origin

preparedProviderBindingOperationKey ::
    PreparedProviderBinding scope planId backendId providerId ->
    Text
preparedProviderBindingOperationKey (PreparedProviderBinding _ operationKey _) = operationKey

preparedProviderBindingGeneration ::
    PreparedProviderBinding scope planId backendId providerId ->
    Word64
preparedProviderBindingGeneration (PreparedProviderBinding origin _ _) =
    providerOriginGeneration origin

preparedProviderBindingCallDigest ::
    PreparedProviderBinding scope planId backendId providerId ->
    Text
preparedProviderBindingCallDigest (PreparedProviderBinding _ _ callDigest) = callDigest

-- | Exact persisted owner binding for one plan-local provider generation.
preparedProviderBindingOwner ::
    PreparedProviderBinding scope planId backendId providerId ->
    Text
preparedProviderBindingOwner (PreparedProviderBinding origin _ _) =
    providerOriginOwner origin

{- | Descriptive identity of one managed provider.  These projections grant no
access to the generic managed handle, its receipt, or its retained origin.
-}
managedProviderKey :: ManagedProviderHandle scope planId backendId providerId phase -> Text
managedProviderKey (ManagedProviderHandle _ handle _) = resourceHandleKey handle

managedProviderGeneration :: ManagedProviderHandle scope planId backendId providerId phase -> Word64
managedProviderGeneration (ManagedProviderHandle _ handle _) = resourceHandleGeneration handle

managedProviderObservationVersion :: ManagedProviderHandle scope planId backendId providerId phase -> Word64
managedProviderObservationVersion (ManagedProviderHandle _ handle _) =
    resourceHandleObservationVersion handle

providerBinding ::
    StepExecution scope planId ->
    ProviderBackendBinding backendId ->
    ResourceHandle scope planId providerId ProviderResource ownership phase ->
    Text ->
    PreparedProviderBinding scope planId backendId providerId
providerBinding execution backend handle callDigest =
    PreparedProviderBinding
        ( ProviderOriginBinding
            backend
            (stepExecutionPlanDigest execution)
            (resourceHandleKey handle)
            (resourceHandleGeneration handle)
        )
        (stepExecutionOperationKey execution)
        callDigest

providerBindingFromManaged ::
    StepExecution scope planId ->
    ManagedProviderHandle scope planId backendId providerId phase ->
    Text ->
    Either ReconcileError (PreparedProviderBinding scope planId backendId providerId)
providerBindingFromManaged execution managed@(ManagedProviderHandle origin _ _) callDigest = do
    validateManagedProviderHandle managed
    if providerOriginPlanDigest origin /= stepExecutionPlanDigest execution
        then
            Left
                ( Conflict
                    ( ConflictDetail
                        (managedProviderKey managed)
                        ("provider origin plan=" <> providerOriginPlanDigest origin)
                        ("execution plan=" <> stepExecutionPlanDigest execution)
                        "use the StepExecution from the provider's retained origin plan"
                    )
                )
        else
            Right
                ( PreparedProviderBinding
                    origin
                    (stepExecutionOperationKey execution)
                    callDigest
                )

validateManagedProviderHandle ::
    ManagedProviderHandle scope planId backendId providerId phase ->
    Either ReconcileError ()
validateManagedProviderHandle managed@(ManagedProviderHandle origin handle receipt) = do
    validateOwnershipReceipt handle receipt
    if providerOriginResourceKey origin /= managedProviderKey managed
        then
            Left
                ( Conflict
                    ( ConflictDetail
                        (managedProviderKey managed)
                        ("provider origin resource=" <> providerOriginResourceKey origin)
                        ("managed resource=" <> managedProviderKey managed)
                        "retain the provider settlement that minted this managed handle"
                    )
                )
        else
            if providerOriginGeneration origin /= managedProviderGeneration managed
                then
                    generationConflict
                        "validate managed provider origin"
                        handle
                        (providerOriginGeneration origin)
                else Right ()

-- Initial provider reconciliation -------------------------------------------

data PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion
    = PreparedProviderProvision
        (PreparedProviderBinding scope planId backendId providerId)
        (ResourceHandle scope planId providerId ProviderResource Unclassified Observed)
        (PreparedOperation scope planId providerId ProviderResource operationKey callDigest attempt journalVersion)
        (PreparedPreconditions scope planId providerId ProviderResource operationKey callDigest attempt journalVersion)

type role PreparedProviderProvision nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedProviderProvision ::
    StepExecution scope planId ->
    ProviderBackendBinding backendId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedProviderProvision
        scope
        planId
        backendId
        providerId
        operationKey
        callDigest
        attempt
        journalVersion ->
      result
    ) ->
    Either ReconcileError result
withPreparedProviderProvision execution backend planned handle gate consume = do
    let callDigest = providerCallDigest "provider:provision/v2" backend
    descriptor <- plannedNodeOperation execution planned handle callDigest
    preconditions <- zeroDependencyPreconditions descriptor
    withPreparedOperation descriptor preconditions gate $ \prepared sealed ->
        consume
            ( PreparedProviderProvision
                (providerBinding execution backend handle callDigest)
                handle
                prepared
                sealed
            )

preparedProviderProvisionBinding ::
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    PreparedProviderBinding scope planId backendId providerId
preparedProviderProvisionBinding (PreparedProviderProvision binding _ _ _) = binding

preparedProviderProvisionHandle ::
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ResourceHandle scope planId providerId ProviderResource Unclassified Observed
preparedProviderProvisionHandle (PreparedProviderProvision _ handle _ _) = handle

{- | Opaque outcome of initial provider settlement.

The managed branch carries the only public provider authority: a handle bound
to the exact backend origin retained by the prepared provision.  The foreign
branch exposes only descriptive identity and the foreign observation; it
cannot be fed to any provider operation.
-}
data ProviderProvisionSettlement scope planId backendId providerId
    = ManagedProviderProvision
        (ManagedProviderHandle scope planId backendId providerId Provisioned)
        ChangeView
    | ForeignProviderProvision Text Word64 Word64 ForeignObservation

type role ProviderProvisionSettlement nominal nominal nominal nominal

withProviderProvisionSettlement ::
    ProviderProvisionSettlement scope planId backendId providerId ->
    (ManagedProviderHandle scope planId backendId providerId Provisioned -> ChangeView -> result) ->
    (Text -> Word64 -> Word64 -> ForeignObservation -> result) ->
    result
withProviderProvisionSettlement settlement consumeManaged consumeForeign =
    case settlement of
        ManagedProviderProvision managed change -> consumeManaged managed change
        ForeignProviderProvision key generation version observation ->
            consumeForeign key generation version observation

settleProviderProvision ::
    Maybe (PriorCommitProof scope planId providerId ProviderResource) ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either
        ReconcileError
        (ProviderProvisionSettlement scope planId backendId providerId)
settleProviderProvision
    priorProof
    (PreparedProviderProvision binding handle prepared preconditions)
    (ProviderProvisionCallResult observation) = do
        reconciled <- case observation of
            ProviderProvisionCreated generation ->
                completeReconcile handle prepared preconditions (BackendCreated generation)
            ProviderProvisionRepaired generation ->
                completeReconcile handle prepared preconditions (BackendRepaired generation)
            ProviderProvisionAlreadyOwned generation
                | generation /= resourceHandleGeneration handle ->
                    generationConflict "reconcile provider" handle generation
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile handle prepared preconditions (BackendRepaired generation)
            ProviderProvisionForeign generation foreignState ->
                completeReconcile handle prepared preconditions (BackendForeign generation foreignState)
            ProviderProvisionDirectLocal generation
                | generation /= resourceHandleGeneration handle ->
                    generationConflict "reconcile Direct provider" handle generation
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    -- The prepared lifecycle journal is the plan-local reservation.  There
                    -- is no separate Direct backend origin record and the physical host is
                    -- intentionally outside the resource identity.
                    completeReconcile handle prepared preconditions (BackendCreated generation)
            ProviderProvisionAbsent ->
                Left
                    ( Failure
                        ( FailureDetail
                            "reconcile provider"
                            "the provider remained absent after the prepared call"
                            ReprobeBeforeRetry
                        )
                    )
            ProviderProvisionConflict detail -> Left (Conflict detail)
            ProviderProvisionUnsupported detail -> Left (Unsupported detail)
            ProviderProvisionFailed detail -> Left (Failure detail)
        providerProvisionSettlement binding reconciled

providerProvisionSettlement ::
    PreparedProviderBinding scope planId backendId providerId ->
    ReconcileResult scope planId providerId ProviderResource Provisioned ->
    Either ReconcileError (ProviderProvisionSettlement scope planId backendId providerId)
providerProvisionSettlement (PreparedProviderBinding origin _ _) reconciled =
    withReconcileResult
        reconciled
        ( \handle receipt change -> do
            let managed = ManagedProviderHandle origin handle receipt
            validateManagedProviderHandle managed
            Right (ManagedProviderProvision managed change)
        )
        ( \foreignHandle observation ->
            Right
                ( ForeignProviderProvision
                    (resourceHandleKey foreignHandle)
                    (resourceHandleGeneration foreignHandle)
                    (resourceHandleObservationVersion foreignHandle)
                    observation
                )
        )

-- Host-side durable-share reconciliation ------------------------------------

{- | Total observation of the provider-side share primitive.

For a VM provider, attached/repaired means the clause-holding backend observed
the exact provider generation and made the declared share ready.  For Direct,
settlement records only that the already-local source and target projection was
admitted; it performs no host mutation and claims no ownership of the
directory.
-}

-- | The exact host/guest path declaration consumed by one prepared share call.
data ProviderShareSpec = ProviderShareSpec FilePath FilePath
    deriving (Eq, Show)

mkProviderShareSpec :: FilePath -> FilePath -> Either ReconcileError ProviderShareSpec
mkProviderShareSpec hostPath guestPath
    | null hostPath || null guestPath =
        invalid "provider share paths must not be empty"
    | not (isAbsolute hostPath) =
        invalid "the provider share host path must be absolute on this host"
    | not (providerShareAbsolutePath guestPath) =
        invalid "the provider share guest path must be an absolute POSIX path"
    | '\0' `elem` hostPath || '\0' `elem` guestPath =
        invalid "provider share paths must not contain NUL"
    | otherwise = Right (ProviderShareSpec hostPath guestPath)
  where
    invalid reason =
        Left (Failure (FailureDetail "validate provider share" reason DoNotRetry))

{- | Whether a path a /guest/ process will interpret is absolute.

POSIX on every outer host, because the frame that reads it is the Linux
substrate the provider realizes (§ MM).  The host side of the same declaration
is the outer host's own grammar, because the provider client that mounts it runs
there.
-}
providerShareAbsolutePath :: FilePath -> Bool
providerShareAbsolutePath ('/' : _) = True
providerShareAbsolutePath _ = False

providerShareHostPath :: ProviderShareSpec -> FilePath
providerShareHostPath (ProviderShareSpec hostPath _) = hostPath

providerShareGuestPath :: ProviderShareSpec -> FilePath
providerShareGuestPath (ProviderShareSpec _ guestPath) = guestPath

providerShareCallDigest :: ProviderBackendBinding backendId -> ProviderShareSpec -> Text
providerShareCallDigest backend spec =
    Text.concat
        [ providerCallDigest "provider:share/v2" backend
        , sized (Text.pack (providerShareHostPath spec))
        , sized (Text.pack (providerShareGuestPath spec))
        ]
  where
    sized value = showText (Text.length value) <> ":" <> value

data PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion
    = PreparedProviderShare
        (PreparedProviderBinding scope planId backendId providerId)
        ProviderShareSpec
        (ResourceHandle scope planId shareId DurableShareResource Unclassified Observed)
        (PreparedOperation scope planId shareId DurableShareResource operationKey callDigest attempt journalVersion)
        (PreparedPreconditions scope planId shareId DurableShareResource operationKey callDigest attempt journalVersion)

type role PreparedProviderShare nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Prepare the durable-share node's own operation with its exact managed
provider dependency sealed and freshly probed.

The descriptor reads the node's ordered resource prefix from 'StepExecution'.
The snapshot supplied to that traversal contains only this indexed provider;
therefore an undeclared provider, an additional resource dependency, a stale
probe, or a provider from another plan cannot prepare the call.
-}
withPreparedProviderShare ::
    StepExecution scope planId ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ResourceHandle scope planId shareId DurableShareResource Unclassified Observed ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    DependencyProbe scope planId providerId ProviderResource ->
    ProviderShareSpec ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedProviderShare
        scope
        planId
        backendId
        providerId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      result
    ) ->
    IO (Either ReconcileError result)
withPreparedProviderShare
    execution
    planned
    shareHandle
    managedProvider@(ManagedProviderHandle origin providerHandle _)
    providerProbe
    spec
    gate
    consume =
        case providerBindingFromManaged execution managedProvider callDigest of
            Left failure -> pure (Left failure)
            Right binding ->
                case plannedNodeOperation execution planned shareHandle callDigest of
                    Left failure -> pure (Left failure)
                    Right descriptor -> do
                        sealed <-
                            withOperationPreconditions
                                descriptor
                                ( withDependencySnapshotEntry
                                    providerHandle
                                    providerProbe
                                    emptyDependencySnapshot
                                )
                        pure $ do
                            preconditions <- sealed
                            withPreparedOperation descriptor preconditions gate $ \prepared preparedPreconditions ->
                                consume
                                    ( PreparedProviderShare
                                        binding
                                        spec
                                        shareHandle
                                        prepared
                                        preparedPreconditions
                                    )
      where
        callDigest =
            providerShareCallDigest
                (providerOriginBackendBinding origin)
                spec

preparedProviderShareBinding ::
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    PreparedProviderBinding scope planId backendId providerId
preparedProviderShareBinding (PreparedProviderShare binding _ _ _ _) = binding

preparedProviderShareSpec ::
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    ProviderShareSpec
preparedProviderShareSpec (PreparedProviderShare _ spec _ _ _) = spec

preparedProviderShareHandle ::
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    ResourceHandle scope planId shareId DurableShareResource Unclassified Observed
preparedProviderShareHandle (PreparedProviderShare _ _ handle _ _) = handle

{- | Descriptive identity of one managed provider share.  These projections do
not expose its generic managed handle, receipt, or retained provider origin.
-}
managedProviderShareKey ::
    ManagedProviderShareHandle scope planId backendId providerId shareId phase ->
    Text
managedProviderShareKey (ManagedProviderShareHandle _ handle _) = resourceHandleKey handle

managedProviderShareGeneration ::
    ManagedProviderShareHandle scope planId backendId providerId shareId phase ->
    Word64
managedProviderShareGeneration (ManagedProviderShareHandle _ handle _) =
    resourceHandleGeneration handle

managedProviderShareObservationVersion ::
    ManagedProviderShareHandle scope planId backendId providerId shareId phase ->
    Word64
managedProviderShareObservationVersion (ManagedProviderShareHandle _ handle _) =
    resourceHandleObservationVersion handle

{- | Opaque provider-derived share settlement.  A managed share retains the
exact provider origin that authorized its attachment.  A foreign observation
is descriptive only and cannot authorize alias preparation.
-}
data ProviderShareSettlement scope planId backendId providerId shareId
    = ManagedProviderShare
        (ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned)
        ChangeView
    | ForeignProviderShare Text Word64 Word64 ForeignObservation

type role ProviderShareSettlement nominal nominal nominal nominal nominal

withProviderShareSettlement ::
    ProviderShareSettlement scope planId backendId providerId shareId ->
    ( ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
      ChangeView ->
      result
    ) ->
    (Text -> Word64 -> Word64 -> ForeignObservation -> result) ->
    result
withProviderShareSettlement settlement consumeManaged consumeForeign =
    case settlement of
        ManagedProviderShare managed change -> consumeManaged managed change
        ForeignProviderShare key generation version observation ->
            consumeForeign key generation version observation

settleProviderShare ::
    Maybe (PriorCommitProof scope planId shareId DurableShareResource) ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    Either
        ReconcileError
        (ProviderShareSettlement scope planId backendId providerId shareId)
settleProviderShare
    priorProof
    (PreparedProviderShare binding _ handle prepared preconditions)
    (ProviderShareCallResult observation) = do
        reconciled <- case observation of
            ProviderShareAttached generation ->
                completeReconcile handle prepared preconditions (BackendCreated generation)
            ProviderShareRepaired generation ->
                completeReconcile handle prepared preconditions (BackendRepaired generation)
            ProviderShareAlreadyReady generation
                | generation /= resourceHandleGeneration handle ->
                    generationConflict "reconcile provider share" handle generation
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile handle prepared preconditions (BackendRepaired generation)
            ProviderShareForeign generation foreignState ->
                completeReconcile handle prepared preconditions (BackendForeign generation foreignState)
            ProviderShareDirectLocal generation
                | generation /= resourceHandleGeneration handle ->
                    generationConflict "reconcile Direct provider share" handle generation
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile handle prepared preconditions (BackendCreated generation)
            ProviderShareAbsent ->
                Left
                    ( Failure
                        ( FailureDetail
                            "reconcile provider share"
                            "the declared provider share remained absent"
                            ReprobeBeforeRetry
                        )
                    )
            ProviderShareProviderReplaced generation foreignState ->
                phaseReplacement "reconcile provider share" binding generation foreignState
            ProviderShareConflict detail -> Left (Conflict detail)
            ProviderShareUnsupported detail -> Left (Unsupported detail)
            ProviderShareFailed detail -> Left (Failure detail)
        providerShareSettlement binding reconciled

providerShareSettlement ::
    PreparedProviderBinding scope planId backendId providerId ->
    ReconcileResult scope planId shareId DurableShareResource Provisioned ->
    Either ReconcileError (ProviderShareSettlement scope planId backendId providerId shareId)
providerShareSettlement (PreparedProviderBinding origin _ _) reconciled =
    withReconcileResult
        reconciled
        ( \handle receipt change -> do
            validateOwnershipReceipt handle receipt
            Right
                ( ManagedProviderShare
                    (ManagedProviderShareHandle origin handle receipt)
                    change
                )
        )
        ( \foreignHandle observation ->
            Right
                ( ForeignProviderShare
                    (resourceHandleKey foreignHandle)
                    (resourceHandleGeneration foreignHandle)
                    (resourceHandleObservationVersion foreignHandle)
                    observation
                )
        )

-- Managed phase preparations ------------------------------------------------

{- | Plan-owned eligibility for the two provider states that may boot.

Constructors are private and retain the exact handle key/generation.  A fresh
allocation ('Provisioned') and a previously stopped provider are the only
producers; an arbitrary managed phase cannot be relabelled as startable.
-}
data ProviderStartable scope planId backendId providerId fromPhase where
    ProvisionedProviderStartable ::
        Text ->
        Word64 ->
        ProviderStartable scope planId backendId providerId Provisioned
    StoppedProviderStartable ::
        Text ->
        Word64 ->
        ProviderStartable scope planId backendId providerId Stopped

type role ProviderStartable nominal nominal nominal nominal nominal

providerStartableAfterProvision ::
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    ProviderStartable scope planId backendId providerId Provisioned
providerStartableAfterProvision handle =
    ProvisionedProviderStartable
        (managedProviderKey handle)
        (managedProviderGeneration handle)

providerStartableAfterStop ::
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    ProviderStartable scope planId backendId providerId Stopped
providerStartableAfterStop handle =
    StoppedProviderStartable
        (managedProviderKey handle)
        (managedProviderGeneration handle)

data PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion
    = PreparedProviderReady
        (PreparedProviderBinding scope planId backendId providerId)
        (ManagedProviderHandle scope planId backendId providerId fromPhase)
        ( PreparedPhaseTransition
            scope
            planId
            providerId
            ProviderResource
            fromPhase
            Running
            operationKey
            callDigest
            attempt
            journalVersion
        )

type role PreparedProviderReady nominal nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedProviderReady ::
    StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId fromPhase ->
    ProviderStartable scope planId backendId providerId fromPhase ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
      result
    ) ->
    Either ReconcileError result
withPreparedProviderReady execution planned managed@(ManagedProviderHandle origin handle receipt) startable gate consume = do
    validateProviderStartable managed startable
    transition <- providerStartTransition handle startable
    let callDigest = providerReadyCallDigest (providerOriginBackendBinding origin) startable
    binding <- providerBindingFromManaged execution managed callDigest
    prepareProviderPhase
        execution
        planned
        handle
        receipt
        transition
        callDigest
        gate
        ( \prepared ->
            consume
                ( PreparedProviderReady
                    binding
                    managed
                    prepared
                )
        )

preparedProviderReadyBinding ::
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    PreparedProviderBinding scope planId backendId providerId
preparedProviderReadyBinding (PreparedProviderReady binding _ _) = binding

preparedProviderReadyHandle ::
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    ManagedProviderHandle scope planId backendId providerId fromPhase
preparedProviderReadyHandle (PreparedProviderReady _ managed _) = managed

{- | Opaque successful provider phase transition.  Its eliminator exposes only
the backend-indexed successor authority, never the generic 'PhaseAdvance', raw
managed resource handle, receipt, or verification token.
-}
newtype ProviderPhaseAdvance scope planId backendId providerId phase
    = ProviderPhaseAdvance
        (ManagedProviderHandle scope planId backendId providerId phase)

type role ProviderPhaseAdvance nominal nominal nominal nominal nominal

withProviderPhaseAdvance ::
    ProviderPhaseAdvance scope planId backendId providerId phase ->
    (ManagedProviderHandle scope planId backendId providerId phase -> result) ->
    result
withProviderPhaseAdvance (ProviderPhaseAdvance managed) consume = consume managed

carryRunningProviderSettlement ::
    StepExecution scope planId ->
    ProviderPhaseAdvance scope planId backendId providerId Running ->
    Text ->
    Text ->
    IO (Either ReconcileError ())
carryRunningProviderSettlement execution advance sourcePhase adapter =
    withProviderPhaseAdvance advance $ \(ManagedProviderHandle _ handle receipt) ->
        carryManagedResourcePhaseSettlement execution handle receipt sourcePhase "running" adapter

{- | Publish the final Running member for a provider created in this same step.
No intermediate Provisioned member has reached the durable store yet, so the
final member must retain the acquisition's absent predecessor instead of
attempting a CAS against an in-memory phase transition.
-}
carryCreatedRunningProviderSettlement ::
    StepExecution scope planId ->
    ProviderPhaseAdvance scope planId backendId providerId Running ->
    Text ->
    IO (Either ReconcileError ())
carryCreatedRunningProviderSettlement execution advance adapter =
    withProviderPhaseAdvance advance $ \(ManagedProviderHandle _ handle receipt) ->
        carryManagedResourceSettlement execution handle receipt "running" adapter

{- | Recover a provider dependency only after the exact canonical package,
carried ownership evidence, and a nonce-bound live backend reprobe all agree.
The freshly rebound provider identity is scoped by the caller's rank-2
continuation and cannot be returned as a retained managed witness.
-}
withFreshRunningProviderDependency ::
    StepExecution scope planId ->
    Text ->
    ProviderBackendBinding backendId ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    ( forall providerId.
      RunningProviderDependency scope planId providerId ->
      result
    ) ->
    IO (Either ReconcileError result)
withFreshRunningProviderDependency execution scopeCommitment backend dependencyKey route now nonce consume = do
    withFreshRunningProviderHandle execution scopeCommitment backend dependencyKey route now nonce $ \_planned managed reprobe ->
        consume (RunningProviderDependency managed reprobe)

{- | Recover the authenticated parent-carried provider package without
reconstructing the parent's backend on the child. The package's sealed origin
is checked by its authenticated carrier; only the freshly rebound generic
resource handle and nonce-serviced reprobe enter the dependency capability.
-}
withFreshCarriedRunningProviderDependency ::
    StepExecution scope planId ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    (forall providerId providerFrame. PlannedResource scope planId providerId ProviderResource providerFrame -> RunningProviderDependency scope planId providerId -> result) ->
    IO (Either ReconcileError result)
withFreshCarriedRunningProviderDependency execution scopeCommitment dependencyKey route now nonce consume = do
    packages <- ExecutionInternal.stepRuntimeDependencyPackages (ExecutionInternal.stepExecutionRuntime execution)
    case filter ((== "provider:" <> dependencyKey) . runtimeDependencyPackageKey) packages of
        [package] ->
            case withNodeResourceOfKind execution ProviderResourceKind dependencyKey $ \planned -> do
                carried <- withCarriedManagedResourceReceipt execution dependencyKey $ \oldHandle oldReceipt ->
                    withPlannedReboundManagedResourceEvidence planned oldHandle oldReceipt $ \handle receipt ->
                        case withCarriedProviderRuntimeDependencyCoordinates
                            scopeCommitment
                            dependencyKey
                            (plannedResourceFrame planned)
                            (resourceHandleGeneration handle)
                            route
                            now
                            package
                            (\_origin _route -> ()) of
                            Left refusal -> pure (dependencyFailure refusal)
                            Right () -> do
                                first <- invokePackageProbe execution package nonce
                                case first of
                                    Left failure -> pure (Left failure)
                                    Right generation
                                        | generation /= resourceHandleGeneration handle ->
                                            pure (Left (Conflict (ConflictDetail dependencyKey ("generation=" <> Text.pack (show (resourceHandleGeneration handle))) ("fresh generation=" <> Text.pack (show generation)) "reconcile the provider generation before using its dependency")))
                                        | otherwise -> case validateOwnershipReceipt handle receipt of
                                            Left failure -> pure (Left failure)
                                            Right () -> do
                                                sequenceRef <- newIORef (0 :: Word64)
                                                let reprobe = do
                                                        sequenceNumber <- atomicModifyIORef' sequenceRef $ \value -> let next = value + 1 in (next, next)
                                                        invokePackageProbe execution package (nonce <> "-" <> Text.pack (show sequenceNumber))
                                                pure (Right (consume planned (RecoveredRunningProviderDependency handle reprobe)))
                case carried of
                    Left failure -> pure (Left failure)
                    Right rebound -> either (pure . Left) id rebound of
                Left failure -> pure (Left failure)
                Right opened -> opened
        [] -> pure (dependencyFailure "the exact provider package is absent")
        _ -> pure (dependencyFailure "the provider package registry contains duplicate resource keys")
  where
    dependencyFailure reason = Left (Failure (FailureDetail "recover carried provider runtime dependency" reason ReprobeBeforeRetry))

withFreshRunningProviderHandle ::
    StepExecution scope planId ->
    Text ->
    ProviderBackendBinding backendId ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    ( forall providerId providerFrame.
      PlannedResource scope planId providerId ProviderResource providerFrame ->
      ManagedProviderHandle scope planId backendId providerId Running ->
      IO (Either ReconcileError Word64) ->
      result
    ) ->
    IO (Either ReconcileError result)
withFreshRunningProviderHandle execution scopeCommitment backend dependencyKey route now nonce consume = do
    packages <- ExecutionInternal.stepRuntimeDependencyPackages (ExecutionInternal.stepExecutionRuntime execution)
    case filter ((== "provider:" <> dependencyKey) . runtimeDependencyPackageKey) packages of
        [] -> pure (dependencyFailure "the exact provider package is absent")
        [package] ->
            case withNodeResourceOfKind execution ProviderResourceKind dependencyKey $ \planned ->
                do
                    carried <- withCarriedManagedResourceReceipt execution dependencyKey $ \oldHandle oldReceipt ->
                        withPlannedReboundManagedResourceEvidence planned oldHandle oldReceipt $ \handle receipt -> do
                            let origin =
                                    ProviderOriginBinding
                                        backend
                                        (stepExecutionPlanDigest execution)
                                        dependencyKey
                                        (resourceHandleGeneration handle)
                            case withProviderRuntimeDependencyCoordinates
                                (stepExecutionPlanDigest execution)
                                scopeCommitment
                                dependencyKey
                                (plannedResourceFrame planned)
                                (providerOriginOwner origin)
                                (resourceHandleGeneration handle)
                                route
                                now
                                package
                                id of
                                Left refusal -> pure (dependencyFailure refusal)
                                Right _ -> do
                                    first <- invokePackageProbe execution package nonce
                                    case first of
                                        Left failure -> pure (Left failure)
                                        Right generation
                                            | generation /= resourceHandleGeneration handle ->
                                                pure
                                                    ( Left
                                                        ( Conflict
                                                            ( ConflictDetail
                                                                dependencyKey
                                                                ("generation=" <> Text.pack (show (resourceHandleGeneration handle)))
                                                                ("fresh generation=" <> Text.pack (show generation))
                                                                "reconcile the provider generation before using its dependency"
                                                            )
                                                        )
                                                    )
                                            | otherwise -> case validateOwnershipReceipt handle receipt of
                                                Left failure -> pure (Left failure)
                                                Right () -> do
                                                    sequenceRef <- newIORef (0 :: Word64)
                                                    let reprobe = do
                                                            sequenceNumber <- atomicModifyIORef' sequenceRef $ \value -> let next = value + 1 in (next, next)
                                                            invokePackageProbe execution package (nonce <> "-" <> Text.pack (show sequenceNumber))
                                                        managed = ManagedProviderHandle origin handle receipt
                                                    pure $ do
                                                        validateManagedProviderHandle managed
                                                        pure (consume planned managed reprobe)
                    case carried of
                        Left failure -> pure (Left failure)
                        Right rebound -> case rebound of
                            Left failure -> pure (Left failure)
                            Right opened -> opened of
                Left failure -> pure (Left failure)
                Right opened -> opened
        _ -> pure (dependencyFailure "the provider package registry contains duplicate resource keys")
  where
    dependencyFailure reason =
        Left (Failure (FailureDetail "recover provider runtime dependency" reason ReprobeBeforeRetry))

invokePackageProbe ::
    StepExecution scope planId ->
    RuntimeDependencyPackage scope planId ->
    Text ->
    IO (Either ReconcileError Word64)
invokePackageProbe execution package nonce =
    case runtimeDependencyProbeRequest package nonce of
        Left refusal -> pure (failure refusal)
        Right request -> do
            response <- ExecutionInternal.invokeStepRuntimeDependencyService (ExecutionInternal.stepExecutionRuntime execution) package request
            pure $ case response of
                Left refusal -> failure refusal
                Right bytes -> either failure Right (verifyRuntimeDependencyProbeResponse package nonce bytes)
  where
    failure refusal = Left (Failure (FailureDetail "fresh provider dependency probe" refusal ReprobeBeforeRetry))

settleProviderReady ::
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ProviderPhaseAdvance scope planId backendId providerId Running)
settleProviderReady
    (PreparedProviderReady binding managed prepared)
    (ProviderReadyCallResult observation) =
        case observation of
            ProviderReadyObserved generation -> completeProviderPhaseAdvance managed prepared generation
            ProviderReadyAlready generation -> completeProviderPhaseAdvance managed prepared generation
            ProviderReadyNotReady reason -> phaseNotAtTarget "reconcile provider ready" reason
            ProviderReadyAbsent -> phaseAbsent "reconcile provider ready"
            ProviderReadyReplaced generation foreignState ->
                phaseReplacement "reconcile provider ready" binding generation foreignState
            ProviderReadyConflict detail -> Left (Conflict detail)
            ProviderReadyUnsupported detail -> Left (Unsupported detail)
            ProviderReadyFailed detail -> Left (Failure detail)

completeProviderPhaseAdvance ::
    ManagedProviderHandle scope planId backendId providerId fromPhase ->
    PreparedPhaseTransition
        scope
        planId
        providerId
        ProviderResource
        fromPhase
        toPhase
        operationKey
        callDigest
        attempt
        journalVersion ->
    Word64 ->
    Either ReconcileError (ProviderPhaseAdvance scope planId backendId providerId toPhase)
completeProviderPhaseAdvance
    (ManagedProviderHandle origin _ _)
    prepared
    observedGeneration = do
        advanced <- completePreparedPhaseTransition prepared observedGeneration
        withPhaseAdvance advanced $ \handle receipt _verified -> do
            let successor = ManagedProviderHandle origin handle receipt
            validateManagedProviderHandle successor
            Right (ProviderPhaseAdvance successor)

validateProviderStartable ::
    ManagedProviderHandle scope planId backendId providerId fromPhase ->
    ProviderStartable scope planId backendId providerId fromPhase ->
    Either ReconcileError ()
validateProviderStartable handle startable
    | startableKey startable /= managedProviderKey handle =
        Left
            ( Conflict
                ( ConflictDetail
                    (managedProviderKey handle)
                    ("startable resource=" <> managedProviderKey handle)
                    ("startable resource=" <> startableKey startable)
                    "derive provider startability from the exact managed handle"
                )
            )
    | startableGeneration startable /= managedProviderGeneration handle =
        Left
            ( Conflict
                ( ConflictDetail
                    (managedProviderKey handle)
                    ("generation=" <> showText (managedProviderGeneration handle))
                    ("generation=" <> showText (startableGeneration startable))
                    "derive provider startability from the exact managed generation"
                )
            )
    | otherwise = Right ()

providerStartTransition ::
    ResourceHandle scope planId providerId ProviderResource Managed fromPhase ->
    ProviderStartable scope planId backendId providerId fromPhase ->
    Either
        ReconcileError
        (PhaseTransition scope planId providerId ProviderResource fromPhase Running)
providerStartTransition handle startable =
    case startable of
        ProvisionedProviderStartable _ _ -> planProviderBoot handle
        StoppedProviderStartable _ _ -> planRestart handle

providerReadyCallDigest ::
    ProviderBackendBinding backendId ->
    ProviderStartable scope planId backendId providerId fromPhase ->
    Text
providerReadyCallDigest backend startable =
    case startable of
        ProvisionedProviderStartable _ _ -> providerCallDigest "provider:boot-ready/v2" backend
        StoppedProviderStartable _ _ -> providerCallDigest "provider:restart-ready/v2" backend

startableKey :: ProviderStartable scope planId backendId providerId fromPhase -> Text
startableKey startable =
    case startable of
        ProvisionedProviderStartable key _ -> key
        StoppedProviderStartable key _ -> key

startableGeneration :: ProviderStartable scope planId backendId providerId fromPhase -> Word64
startableGeneration startable =
    case startable of
        ProvisionedProviderStartable _ generation -> generation
        StoppedProviderStartable _ generation -> generation

data PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion
    = PreparedProviderStop
        (PreparedProviderBinding scope planId backendId providerId)
        (ManagedProviderHandle scope planId backendId providerId Running)
        ( PreparedPhaseTransition
            scope
            planId
            providerId
            ProviderResource
            Running
            Stopped
            operationKey
            callDigest
            attempt
            journalVersion
        )

type role PreparedProviderStop nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedProviderStop ::
    StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
      result
    ) ->
    Either ReconcileError result
withPreparedProviderStop execution planned managed@(ManagedProviderHandle origin handle receipt) gate consume = do
    transition <- planStop handle
    let callDigest =
            providerCallDigest
                "provider:stop/v2"
                (providerOriginBackendBinding origin)
    binding <- providerBindingFromManaged execution managed callDigest
    prepareProviderPhase
        execution
        planned
        handle
        receipt
        transition
        callDigest
        gate
        ( \prepared ->
            consume
                ( PreparedProviderStop
                    binding
                    managed
                    prepared
                )
        )

preparedProviderStopBinding ::
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    PreparedProviderBinding scope planId backendId providerId
preparedProviderStopBinding (PreparedProviderStop binding _ _) = binding

preparedProviderStopHandle ::
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ManagedProviderHandle scope planId backendId providerId Running
preparedProviderStopHandle (PreparedProviderStop _ managed _) = managed

settleProviderStop ::
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ProviderPhaseAdvance scope planId backendId providerId Stopped)
settleProviderStop
    (PreparedProviderStop binding managed prepared)
    (ProviderStopCallResult observation) =
        case observation of
            ProviderStopped generation -> completeProviderPhaseAdvance managed prepared generation
            ProviderAlreadyStopped generation -> completeProviderPhaseAdvance managed prepared generation
            ProviderStopStillRunning reason -> phaseNotAtTarget "stop provider" reason
            ProviderStopAbsent -> phaseAbsent "stop provider"
            ProviderStopReplaced generation foreignState ->
                phaseReplacement "stop provider" binding generation foreignState
            ProviderStopConflict detail -> Left (Conflict detail)
            ProviderStopUnsupported detail -> Left (Unsupported detail)
            ProviderStopFailed detail -> Left (Failure detail)

data PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion
    = PreparedProviderDelete
        (PreparedProviderBinding scope planId backendId providerId)
        (ManagedProviderHandle scope planId backendId providerId Stopped)
        ( PreparedPhaseTransition
            scope
            planId
            providerId
            ProviderResource
            Stopped
            Destroyed
            operationKey
            callDigest
            attempt
            journalVersion
        )

type role PreparedProviderDelete nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedProviderDelete ::
    StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
      result
    ) ->
    Either ReconcileError result
withPreparedProviderDelete execution planned managed@(ManagedProviderHandle origin handle receipt) gate consume = do
    transition <- planDestroy handle
    let callDigest =
            providerCallDigest
                "provider:delete/v2"
                (providerOriginBackendBinding origin)
    binding <- providerBindingFromManaged execution managed callDigest
    prepareProviderPhase
        execution
        planned
        handle
        receipt
        transition
        callDigest
        gate
        ( \prepared ->
            consume
                ( PreparedProviderDelete
                    binding
                    managed
                    prepared
                )
        )

preparedProviderDeleteBinding ::
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    PreparedProviderBinding scope planId backendId providerId
preparedProviderDeleteBinding (PreparedProviderDelete binding _ _) = binding

preparedProviderDeleteHandle ::
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ManagedProviderHandle scope planId backendId providerId Stopped
preparedProviderDeleteHandle (PreparedProviderDelete _ managed _) = managed

settleProviderDelete ::
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ProviderPhaseAdvance scope planId backendId providerId Destroyed)
settleProviderDelete
    (PreparedProviderDelete binding managed prepared)
    (ProviderDeleteCallResult observation) =
        case observation of
            ProviderDeleted ->
                completeProviderPhaseAdvance managed prepared (preparedProviderBindingGeneration binding)
            ProviderAlreadyDeleted ->
                completeProviderPhaseAdvance managed prepared (preparedProviderBindingGeneration binding)
            ProviderDeleteStillPresent generation
                | generation /= preparedProviderBindingGeneration binding ->
                    phaseReplacement
                        "delete provider"
                        binding
                        generation
                        (ForeignObservation (preparedProviderBindingResourceKey binding) "a different provider still holds the name")
                | otherwise ->
                    phaseNotAtTarget
                        "delete provider"
                        "the exact managed provider remains present after conditional deletion"
            ProviderDeleteReplaced generation foreignState ->
                phaseReplacement "delete provider" binding generation foreignState
            ProviderDeleteConflict detail -> Left (Conflict detail)
            ProviderDeleteUnsupported detail -> Left (Unsupported detail)
            ProviderDeleteFailed detail -> Left (Failure detail)

prepareProviderPhase ::
    StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceHandle scope planId providerId ProviderResource Managed fromPhase ->
    OwnershipReceipt scope planId providerId ProviderResource ->
    PhaseTransition
        scope
        planId
        providerId
        ProviderResource
        fromPhase
        toPhase ->
    Text ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedPhaseTransition
        scope
        planId
        providerId
        ProviderResource
        fromPhase
        toPhase
        operationKey
        callDigest
        attempt
        journalVersion ->
      result
    ) ->
    Either ReconcileError result
prepareProviderPhase execution planned handle receipt transition callDigest gate consume = do
    descriptor <-
        plannedNodePhaseOperation
            execution
            planned
            handle
            receipt
            transition
            callDigest
    preconditions <- zeroProviderDependencies descriptor
    withPreparedPhaseTransition
        handle
        receipt
        transition
        descriptor
        preconditions
        gate
        consume

zeroProviderDependencies ::
    OperationDescriptor scope planId providerId ProviderResource fromPhase toPhase ->
    Either ReconcileError (OperationPreconditionSet scope planId providerId ProviderResource)
zeroProviderDependencies = zeroDependencyPreconditions

phaseNotAtTarget :: Text -> Text -> Either ReconcileError result
phaseNotAtTarget operation reason =
    Left
        ( Failure
            ( FailureDetail
                operation
                reason
                RetrySameOperationKeyAfterFencing
            )
        )

phaseAbsent :: Text -> Either ReconcileError result
phaseAbsent operation =
    Left
        ( Failure
            ( FailureDetail
                operation
                "the managed provider generation is absent"
                OperatorResolutionRequired
            )
        )

phaseReplacement ::
    Text ->
    PreparedProviderBinding scope planId backendId providerId ->
    Word64 ->
    ForeignObservation ->
    Either ReconcileError result
phaseReplacement operation binding generation foreignState =
    Left
        ( Conflict
            ( ConflictDetail
                (preparedProviderBindingResourceKey binding)
                ("owned generation=" <> showText (preparedProviderBindingGeneration binding))
                ( "replacement generation="
                    <> showText generation
                    <> "; "
                    <> foreignDetail foreignState
                )
                (operation <> " must leave the replacement untouched and require operator resolution")
            )
        )

generationConflict ::
    Text ->
    ResourceHandle scope planId resourceId resource ownership phase ->
    Word64 ->
    Either ReconcileError result
generationConflict operation handle generation =
    Left
        ( Conflict
            ( ConflictDetail
                (resourceHandleKey handle)
                ("generation=" <> showText (resourceHandleGeneration handle))
                ("generation=" <> showText generation)
                (operation <> " must reprobe and resolve replacement ownership")
            )
        )

providerCallDigest :: Text -> ProviderBackendBinding backendId -> Text
providerCallDigest operation backend =
    Text.concat
        [ operation
        , ":"
        , sized (providerBackendSemanticFingerprint backend)
        , sized (providerBackendRealizationFingerprint backend)
        ]
  where
    sized value = showText (Text.length value) <> ":" <> value

showText :: (Show value) => value -> Text
showText = Text.pack . show
