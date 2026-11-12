{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{- | Production-plan preparation for the opt-in native provider gate.

The live component deliberately has no test-fixture shortcut.  It admits a
real Production project plan, projects provider/share/alias resources from
that plan, and reaches every mutation through the same opaque prepared calls
and backend-indexed managed handles as an ordinary consumer.
-}
module ProviderLiveAliasFixture (
    runLiveIncusRoute,
    runLiveDirectRoute,
) where

import Control.Exception (SomeException, displayException, mask, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Schema (withValidatedConfig)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.HostConfig (HostConfig)
import qualified HostBootstrap.Lifecycle.Execution as Execution
import qualified HostBootstrap.Lifecycle.Execution.Core as ExecutionCore (newResourceCarrierCore, newStepRuntimeCore)
import HostBootstrap.Lifecycle.Mode (
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withProductionLifecycleProfile,
    withProductionRoot,
 )
import HostBootstrap.Lifecycle.Prepared (PreparedGate, recordDurableUnknown)
import HostBootstrap.Lift (InVMSelfPath (InVMSelfPath), SelfRef, currentSelfRef, localContext)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    planDraftsFromValidatedBuilder,
 )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectRoot (
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.Readiness (DurableShareReady, ProviderResponding)
import HostBootstrap.Reconcile (
    DependencyProbe,
    DurableShareResource,
    FailureDetail (FailureDetail),
    PlannedResource,
    PlannedResourceKind (DurableShareResourceKind, ProviderResourceKind),
    ProviderResource,
    Provisioned,
    ReconcileError (Failure, Unsupported),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    Running,
    Stopped,
    UnsupportedDetail (UnsupportedDetail),
    plannedResourceKey,
    stepExecutionFor,
    withNodeGuestAliasProjection,
    withNodeObservedResource,
    withNodeResourceOfKind,
 )
import HostBootstrap.Step (
    StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    StepPlanError,
    copySourceStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
    projectsOperation,
 )
import HostBootstrap.Substrate.Provider (
    ProviderCapability,
    ProviderError (ProviderOperationFailure, ProviderUnsupported),
    SubstrateProvider,
    discoverProvider,
 )
import HostBootstrap.Substrate.Provider.Alias (
    GuestAliasSpec,
    PreparedGuestAliasCall,
    StrongAliasBackend,
    discoverStrongAliasBackend,
    managedGuestAliasObservationVersion,
    runPreparedGuestAliasCall,
    runPreparedGuestAliasRelease,
    settlePreparedGuestAliasCall,
    withGuestAliasCallSettlement,
    withPreparedGuestAliasCall,
    withPreparedGuestAliasRelease,
 )
import HostBootstrap.Substrate.Provider.Backend (
    StrongProviderBackend,
    providerBackendBinding,
    providerShareDependencyProbe,
    registerProviderShareDependencyPackage,
    runProviderDeleteCall,
    runProviderProvisionCall,
    runProviderReadyCall,
    runProviderShareCall,
    runProviderStopCall,
    runningProviderDependencyProbe,
    withProviderBoundExec,
    withProviderShareDependency,
    withRunningProviderDependency,
 )
import HostBootstrap.Substrate.Provider.Reconcile (
    ManagedProviderHandle,
    ManagedProviderShareHandle,
    ProviderShareSpec,
    ProviderStartable,
    carryProviderShareSettlement,
    providerStartableAfterProvision,
    providerStartableAfterStop,
    settleProviderDelete,
    settleProviderProvision,
    settleProviderReady,
    settleProviderShare,
    settleProviderStop,
    withFreshCarriedProviderShareDependency,
    withPreparedProviderDelete,
    withPreparedProviderProvision,
    withPreparedProviderReady,
    withPreparedProviderShare,
    withPreparedProviderStop,
    withProviderPhaseAdvance,
    withProviderProvisionSettlement,
    withProviderShareSettlement,
 )
import ProviderLiveConfig (LiveConfig (LiveConfig))
import System.Environment (getExecutablePath)
import System.FilePath ((</>))

data RouteExercise
    = IncusExercise
        GuestAliasSpec
        (IO (Either ReconcileError ()))
        (IO (Either ReconcileError ()))
        (IO (Either ReconcileError ()))
    | DirectExercise

data ProviderCleanupAuthority scope planId backendId providerId
    = CleanupRunning (ManagedProviderHandle scope planId backendId providerId Running)
    | CleanupStopped (ManagedProviderHandle scope planId backendId providerId Stopped)

{- | Exercise the complete prepared Incus route.

@prepareGuest@ runs after the exact share settles and before the alias is
claimed; its failure therefore requires no alias release. @beforeRestart@
and @afterRestart@ run while the managed alias is held, respectively before
stop and after restart and fresh provider discovery. Conditional release is
attempted even when either callback or the stop/restart body fails.
-}
runLiveIncusRoute ::
    FilePath ->
    FilePath ->
    HostConfig ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    ProviderShareSpec ->
    GuestAliasSpec ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ())
runLiveIncusRoute root guestSelfPath config backend provider shareSpec aliasSpec prepareGuest beforeRestart afterRestart =
    runProviderRoute
        root
        guestSelfPath
        config
        backend
        provider
        shareSpec
        (IncusExercise aliasSpec prepareGuest beforeRestart afterRestart)

{- | Exercise Direct admission, Ready validation, identity share settlement,
and the sealed refusal boundary.  A refused prepared stop produces no
@Stopped@ authority, making prepared delete statically unreachable.  Direct
capability discovery likewise produces no guest executor or alias backend.
-}
runLiveDirectRoute ::
    FilePath ->
    FilePath ->
    HostConfig ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    ProviderShareSpec ->
    IO (Either ReconcileError ())
runLiveDirectRoute root guestSelfPath config backend provider shareSpec =
    runProviderRoute root guestSelfPath config backend provider shareSpec DirectExercise

{- | Admit one live project plan and execute its matching prepared provider,
readiness, share and optional guest-alias route. Retained managed authority
selects cleanup for the exact lifecycle state reached by the exercise.
-}
runProviderRoute ::
    FilePath ->
    FilePath ->
    HostConfig ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    ProviderShareSpec ->
    RouteExercise ->
    IO (Either ReconcileError ())
runProviderRoute root guestSelfPath config backend provider shareSpec exercise =
    withLiveProjectPlan root liveStepPlan $ \projectPlan ->
        case NonEmpty.toList (forward projectPlan) of
            [providerNode, shareNode] -> do
                self <- currentSelfRef (InVMSelfPath guestSelfPath)
                carrier <- ExecutionCore.newResourceCarrierCore
                providerRuntime <- ExecutionCore.newStepRuntimeCore carrier
                shareRuntime <- ExecutionCore.newStepRuntimeCore carrier
                let providerExecution = stepExecutionFor projectPlan config providerRuntime providerNode
                    shareExecution = stepExecutionFor projectPlan config shareRuntime shareNode
                    providerKey = Execution.stepExecutionOperationKey providerExecution
                    shareKey = Execution.stepExecutionOperationKey shareExecution
                    planDigest = Execution.stepExecutionPlanDigest providerExecution
                provisionGate <- gateFor root "provider-provision" planDigest providerKey
                joinReconcileIO $
                    withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
                        joinReconcileIO $
                            withNodeObservedResource providerExecution plannedProvider 101 1 $ \observedProvider ->
                                joinReconcileIO $
                                    withPreparedProviderProvision
                                        providerExecution
                                        (providerBackendBinding backend)
                                        plannedProvider
                                        observedProvider
                                        provisionGate
                                        ( \preparedProvision -> do
                                            result <- runProviderProvisionCall backend preparedProvision
                                            case settleProviderProvision Nothing preparedProvision result of
                                                Left failure -> pure (Left failure)
                                                Right settlement ->
                                                    withProviderProvisionSettlement
                                                        settlement
                                                        ( \provisioned _change ->
                                                            continueProvisioned
                                                                root
                                                                config
                                                                self
                                                                backend
                                                                provider
                                                                providerExecution
                                                                shareExecution
                                                                plannedProvider
                                                                shareKey
                                                                shareSpec
                                                                exercise
                                                                provisioned
                                                        )
                                                        (\_ _ _ _ -> pure (fixtureFailure "the live provider remained foreign"))
                                        )
            nodes -> pure (fixtureFailure ("unexpected project-plan shape: " <> Text.pack (show (length nodes))))

continueProvisioned ::
    FilePath ->
    HostConfig ->
    SelfRef ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    Execution.StepExecution scope planId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    Text ->
    ProviderShareSpec ->
    RouteExercise ->
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    IO (Either ReconcileError ())
continueProvisioned root config self backend provider providerExecution shareExecution plannedProvider shareKey shareSpec exercise provisioned = do
    ready <-
        attemptReconcile "initial provider-live readiness" $
            readyProviderWithDependency
                root
                "provider-initial-ready"
                backend
                providerExecution
                plannedProvider
                provisioned
                (providerStartableAfterProvision provisioned)
    case ready of
        Left primaryFailure -> case exercise of
            DirectExercise -> pure (Left primaryFailure)
            IncusExercise{} -> do
                cleanup <-
                    attemptReconcile "recover provisioned provider-live VM" $
                        recoverProvisioned root backend providerExecution plannedProvider provisioned
                pure (combinePrimaryCleanup (Left primaryFailure) cleanup)
        Right (running, runningProbe) -> case exercise of
            DirectExercise ->
                withDiscoveredRunning backend provider running $ \capability ->
                    prepareShare
                        root
                        config
                        self
                        backend
                        provider
                        providerExecution
                        shareExecution
                        plannedProvider
                        shareKey
                        shareSpec
                        exercise
                        Nothing
                        running
                        runningProbe
                        capability
            IncusExercise{} -> do
                cleanupAuthority <- newIORef (CleanupRunning running)
                let routed =
                        withDiscoveredRunning backend provider running $ \capability ->
                            prepareShare
                                root
                                config
                                self
                                backend
                                provider
                                providerExecution
                                shareExecution
                                plannedProvider
                                shareKey
                                shareSpec
                                exercise
                                (Just cleanupAuthority)
                                running
                                runningProbe
                                capability
                primary <- attemptReconcile "exercise prepared Incus route" routed
                currentAuthority <- readIORef cleanupAuthority
                cleanup <-
                    attemptReconcile
                        "clean up exact managed provider"
                        (cleanupProvider root backend providerExecution plannedProvider cleanupAuthority currentAuthority)
                pure (combinePrimaryCleanup primary cleanup)

prepareShare ::
    FilePath ->
    HostConfig ->
    SelfRef ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    Execution.StepExecution scope planId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    Text ->
    ProviderShareSpec ->
    RouteExercise ->
    Maybe (IORef (ProviderCleanupAuthority scope planId backendId providerId)) ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    DependencyProbe scope planId providerId ProviderResource ProviderResponding ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    IO (Either ReconcileError ())
prepareShare root config self backend provider providerExecution shareExecution plannedProvider shareKey shareSpec exercise cleanupAuthority running runningProbe capability =
    joinReconcileIO $
        withNodeResourceOfKind shareExecution DurableShareResourceKind shareKey $ \plannedShare ->
            joinReconcileIO $
                withNodeObservedResource shareExecution plannedShare 211 1 $ \observedShare -> do
                    shareGate <-
                        gateFor
                            root
                            "provider-share"
                            (Execution.stepExecutionPlanDigest shareExecution)
                            shareKey
                    prepared <-
                        withPreparedProviderShare
                            shareExecution
                            plannedShare
                            observedShare
                            running
                            runningProbe
                            shareSpec
                            shareGate
                            ( \preparedShare -> do
                                result <- runProviderShareCall backend preparedShare
                                case settleProviderShare Nothing preparedShare result of
                                    Left failure -> pure (Left failure)
                                    Right settlement ->
                                        withProviderShareSettlement
                                            settlement
                                            ( \managedShare _change ->
                                                case exercise of
                                                    DirectExercise ->
                                                        exerciseDirect
                                                            root
                                                            config
                                                            self
                                                            backend
                                                            providerExecution
                                                            plannedProvider
                                                            capability
                                                            running
                                                    IncusExercise aliasSpec prepareGuest beforeRestart afterRestart -> do
                                                        carried <- carryProviderShareSettlement shareExecution managedShare "provider-live-share"
                                                        registered <-
                                                            registerProviderShareDependencyPackage
                                                                backend
                                                                shareExecution
                                                                "provider-live"
                                                                shareGate
                                                                preparedShare
                                                                managedShare
                                                                "runtime://provider-share/live"
                                                                100
                                                        fresh <- case (carried, registered) of
                                                            (Left failure, _) -> pure (Left failure)
                                                            (_, Left failure) -> pure (Left failure)
                                                            (Right (), Right _) ->
                                                                withFreshCarriedProviderShareDependency
                                                                    shareExecution
                                                                    "provider-live"
                                                                    shareKey
                                                                    "runtime://provider-share/live"
                                                                    1
                                                                    "provider-live-share-probe"
                                                                    (\_ _ -> ())
                                                        case (fresh, cleanupAuthority) of
                                                            (Left failure, _) -> pure (Left failure)
                                                            (_, Nothing) -> pure (fixtureFailure "the Incus route lost its cleanup authority")
                                                            (Right (), Just retainedAuthority) ->
                                                                case withProviderShareDependency backend preparedShare managedShare providerShareDependencyProbe of
                                                                    Left failure -> pure (Left failure)
                                                                    Right shareProbe ->
                                                                        exerciseIncus
                                                                            root
                                                                            config
                                                                            self
                                                                            backend
                                                                            provider
                                                                            providerExecution
                                                                            shareExecution
                                                                            plannedProvider
                                                                            plannedShare
                                                                            capability
                                                                            running
                                                                            managedShare
                                                                            shareProbe
                                                                            aliasSpec
                                                                            retainedAuthority
                                                                            prepareGuest
                                                                            beforeRestart
                                                                            afterRestart
                                            )
                                            (\_ _ _ _ -> pure (fixtureFailure "the live provider share remained foreign"))
                            )
                    joinReconcileIO prepared

exerciseDirect ::
    FilePath ->
    HostConfig ->
    SelfRef ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError ())
exerciseDirect root config self backend providerExecution plannedProvider capability running = do
    aliasRefusal <- case discoverStrongAliasBackend config self capability of
        Left (Unsupported _) -> pure (Right ())
        Left failure -> pure (Left failure)
        Right _ -> pure (fixtureFailure "Direct unexpectedly admitted a strong alias backend")
    stopped <- stopProvider root "direct-stop-refusal" backend providerExecution plannedProvider running
    let stopRefusal = case stopped of
            Left (Unsupported _) -> Right ()
            Left failure -> Left failure
            Right _ -> fixtureFailure "Direct stop unexpectedly minted Stopped authority"
    pure $ do
        aliasRefusal
        stopRefusal

exerciseIncus ::
    FilePath ->
    HostConfig ->
    SelfRef ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    Execution.StepExecution scope planId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    DependencyProbe scope planId shareId DurableShareResource DurableShareReady ->
    GuestAliasSpec ->
    IORef (ProviderCleanupAuthority scope planId backendId providerId) ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ())
exerciseIncus root config self backend provider providerExecution shareExecution plannedProvider plannedShare capability running managedShare shareProbe aliasSpec cleanupAuthority prepareGuest beforeRestart afterRestart = do
    preparedGuest <- prepareGuest
    case preparedGuest of
        Left failure -> pure (Left failure)
        Right () ->
            attemptReconcile "exercise prepared provider alias" $
                case discoverStrongAliasBackend config self capability of
                    Left failure -> pure (Left failure)
                    Right aliasBackend ->
                        joinReconcileIO $
                            withNodeGuestAliasProjection shareExecution plannedProvider plannedShare $ \plannedAlias edge ->
                                joinReconcileIO $
                                    withNodeObservedResource shareExecution plannedAlias 307 1 $ \observedAlias -> do
                                        aliasGate <-
                                            gateFor
                                                root
                                                "provider-alias"
                                                (Execution.stepExecutionPlanDigest shareExecution)
                                                (plannedResourceKey plannedAlias)
                                        prepared <-
                                            withPreparedGuestAliasCall
                                                aliasBackend
                                                running
                                                managedShare
                                                plannedAlias
                                                edge
                                                observedAlias
                                                shareProbe
                                                aliasSpec
                                                aliasGate
                                                ( runOwnedAlias
                                                    root
                                                    config
                                                    self
                                                    backend
                                                    provider
                                                    providerExecution
                                                    plannedProvider
                                                    aliasBackend
                                                    running
                                                    cleanupAuthority
                                                    beforeRestart
                                                    afterRestart
                                                )
                                        joinReconcileIO prepared

runOwnedAlias ::
    FilePath ->
    HostConfig ->
    SelfRef ->
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IORef (ProviderCleanupAuthority scope planId backendId providerId) ->
    IO (Either ReconcileError ()) ->
    IO (Either ReconcileError ()) ->
    PreparedGuestAliasCall
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO (Either ReconcileError ())
runOwnedAlias root config self backend provider providerExecution plannedProvider aliasBackend running cleanupAuthority beforeRestart afterRestart preparedAlias = do
    result <- runPreparedGuestAliasCall aliasBackend preparedAlias
    case settlePreparedGuestAliasCall Nothing preparedAlias result of
        Left failure -> pure (Left failure)
        Right settlement ->
            withGuestAliasCallSettlement
                settlement
                ( \managedAlias _change ->
                    mask $ \restore -> do
                        body <-
                            try @SomeException $
                                restore $ do
                                    first <- beforeRestart
                                    case first of
                                        Left failure -> pure (Left failure)
                                        Right () -> do
                                            stopped <-
                                                stopProviderRetained
                                                    cleanupAuthority
                                                    root
                                                    "provider-reboot-stop"
                                                    backend
                                                    providerExecution
                                                    plannedProvider
                                                    running
                                            case stopped of
                                                Left failure -> pure (Left failure)
                                                Right stoppedProvider -> do
                                                    restarted <-
                                                        readyProviderRetained
                                                            cleanupAuthority
                                                            root
                                                            "provider-restart-ready"
                                                            backend
                                                            providerExecution
                                                            plannedProvider
                                                            stoppedProvider
                                                            (providerStartableAfterStop stoppedProvider)
                                                    case restarted of
                                                        Left failure -> pure (Left failure)
                                                        Right runningAgain ->
                                                            withDiscoveredRunning backend provider runningAgain $ \freshCapability ->
                                                                case discoverStrongAliasBackend config self freshCapability of
                                                                    Left failure -> pure (Left failure)
                                                                    Right _ -> afterRestart
                        release <-
                            try @SomeException $
                                restore $
                                    joinReconcileIO
                                        ( withPreparedGuestAliasRelease
                                            managedAlias
                                            (managedGuestAliasObservationVersion managedAlias)
                                            (runPreparedGuestAliasRelease aliasBackend)
                                        )
                        pure (combineBodyRelease body release)
                )
                (\_ _ _ _ -> pure (fixtureFailure "the live guest alias remained foreign"))

withDiscoveredRunning ::
    StrongProviderBackend backendId ->
    SubstrateProvider ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    ( forall capabilityId.
      ProviderCapability scope planId providerId backendId capabilityId ->
      IO (Either ReconcileError result)
    ) ->
    IO (Either ReconcileError result)
withDiscoveredRunning backend provider running consume =
    case withProviderBoundExec backend running $ \bound ->
        discoverProvider running provider bound consume of
        Left failure -> pure (Left failure)
        Right action -> do
            discovered <- action
            pure $ case discovered of
                Left failure -> Left (providerFailure failure)
                Right result -> result

readyProviderWithDependency ::
    FilePath ->
    Text ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId fromPhase ->
    ProviderStartable scope planId backendId providerId fromPhase ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Running, DependencyProbe scope planId providerId ProviderResource ProviderResponding))
readyProviderWithDependency root label backend execution planned managed startable = do
    gate <- gateFor root label (Execution.stepExecutionPlanDigest execution) (Execution.stepExecutionOperationKey execution)
    joinReconcileIO $
        withPreparedProviderReady execution planned managed startable gate $ \prepared -> do
            result <- runProviderReadyCall backend prepared
            pure $ do
                advance <- settleProviderReady prepared result
                withRunningProviderDependency backend advance $ \dependency ->
                    (withProviderPhaseAdvance advance id, runningProviderDependencyProbe dependency)

readyProvider ::
    FilePath ->
    Text ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId fromPhase ->
    ProviderStartable scope planId backendId providerId fromPhase ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Running))
readyProvider root label backend execution planned managed startable = do
    gate <- gateFor root label (Execution.stepExecutionPlanDigest execution) (Execution.stepExecutionOperationKey execution)
    joinReconcileIO $
        withPreparedProviderReady execution planned managed startable gate $ \prepared -> do
            result <- runProviderReadyCall backend prepared
            pure $ do
                advance <- settleProviderReady prepared result
                pure (withProviderPhaseAdvance advance id)

readyProviderRetained ::
    IORef (ProviderCleanupAuthority scope planId backendId providerId) ->
    FilePath ->
    Text ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    ProviderStartable scope planId backendId providerId Stopped ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Running))
readyProviderRetained retained root label backend execution planned stopped startable =
    mask $ \restore -> do
        result <- restore (readyProvider root label backend execution planned stopped startable)
        case result of
            Left failure -> pure (Left failure)
            Right running -> do
                writeIORef retained (CleanupRunning running)
                pure (Right running)

stopProvider ::
    FilePath ->
    Text ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Stopped))
stopProvider root label backend execution planned running = do
    gate <- gateFor root label (Execution.stepExecutionPlanDigest execution) (Execution.stepExecutionOperationKey execution)
    joinReconcileIO $
        withPreparedProviderStop execution planned running gate $ \prepared -> do
            result <- runProviderStopCall backend prepared
            pure $ do
                advance <- settleProviderStop prepared result
                pure (withProviderPhaseAdvance advance id)

stopProviderRetained ::
    IORef (ProviderCleanupAuthority scope planId backendId providerId) ->
    FilePath ->
    Text ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Stopped))
stopProviderRetained retained root label backend execution planned running =
    mask $ \restore -> do
        result <- restore (stopProvider root label backend execution planned running)
        case result of
            Left failure -> pure (Left failure)
            Right stopped -> do
                writeIORef retained (CleanupStopped stopped)
                pure (Right stopped)

deleteProvider ::
    FilePath ->
    Text ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    IO (Either ReconcileError ())
deleteProvider root label backend execution planned stopped = do
    gate <- gateFor root label (Execution.stepExecutionPlanDigest execution) (Execution.stepExecutionOperationKey execution)
    joinReconcileIO $
        withPreparedProviderDelete execution planned stopped gate $ \prepared -> do
            result <- runProviderDeleteCall backend prepared
            pure (() <$ settleProviderDelete prepared result)

stopAndDelete ::
    FilePath ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError ())
stopAndDelete root backend execution planned running = do
    stopped <- stopProvider root "provider-final-stop" backend execution planned running
    case stopped of
        Left failure -> pure (Left failure)
        Right stoppedProvider ->
            deleteProvider root "provider-final-delete" backend execution planned stoppedProvider

cleanupProvider ::
    FilePath ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    IORef (ProviderCleanupAuthority scope planId backendId providerId) ->
    ProviderCleanupAuthority scope planId backendId providerId ->
    IO (Either ReconcileError ())
cleanupProvider root backend execution planned retained authority = case authority of
    CleanupRunning running -> do
        stopped <-
            stopProviderRetained
                retained
                root
                "provider-final-stop"
                backend
                execution
                planned
                running
        case stopped of
            Left failure -> pure (Left failure)
            Right currentStopped ->
                deleteProvider root "provider-final-delete" backend execution planned currentStopped
    CleanupStopped stopped ->
        deleteProvider root "provider-final-delete" backend execution planned stopped

recoverProvisioned ::
    FilePath ->
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    IO (Either ReconcileError ())
recoverProvisioned root backend execution planned provisioned = do
    recovered <-
        readyProvider
            root
            "provider-cleanup-ready"
            backend
            execution
            planned
            provisioned
            (providerStartableAfterProvision provisioned)
    case recovered of
        Left failure -> pure (Left failure)
        Right running -> stopAndDelete root backend execution planned running

withLiveProjectPlan ::
    FilePath ->
    Either StepPlanError StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        LiveConfig ->
      IO result
    ) ->
    IO result
withLiveProjectPlan directory stepPlan use = do
    store <-
        openProtectedStore (directory </> "plan-authority")
            >>= either (fail . Text.unpack . protectedErrorMessage) pure
    executable <- Authority.normalizeExecutableIdentity <$> getExecutablePath
    admitted <-
        Authority.withInstalledProjectIdentity executable $ \project -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "provider-live.dhall")
                    "."
                    ( \root ->
                        withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                            opened <-
                                withProductionLifecycleProfile
                                    (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    (productionRootUnboundLease productionRoot)
                                    ( \profile ->
                                        withProductionProjectCodec @LiveConfig $ \codec -> do
                                            let projectName = Authority.installedProjectName project
                                                value =
                                                    LiveConfig
                                                        ( Context.contextForKind
                                                            projectName
                                                            projectName
                                                            (Text.pack (canonicalProjectRootPath root))
                                                            Context.HostOrchestrator
                                                        )
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config -> do
                                                    drafts <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            (planDraftsFromValidatedBuilder root config (\_ _ -> stepPlan))
                                                    action <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            (withProjectPlan profile root config drafts use)
                                                    action
                                            either fail pure validated
                                    )
                            result <- either (fail . show) id opened
                            pure (Right result)
                    )
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult
    either
        (fail . Text.unpack . Authority.authorityErrorMessage)
        pure
        admitted

gateFor :: FilePath -> Text -> Text -> Text -> IO PreparedGate
gateFor root label planDigest operation = do
    store <-
        openProtectedStore (root </> ("operation-authority-" <> Text.unpack (sanitize label)))
            >>= either (fail . Text.unpack . protectedErrorMessage) pure
    key <- either (const (fail "provider-live operation record key is malformed")) pure (mkRecordKey ("operation." <> sanitize operation))
    recorded <-
        withProtectedEntry store $ \session ->
            recordDurableUnknown
                session
                key
                ExpectAbsent
                "EffectOutcomeUnknown"
                planDigest
                operation
                ("provider-live-" <> label)
                1
                1
    either (fail . Text.unpack . protectedErrorMessage) pure recorded

sanitize :: Text -> Text
sanitize = Text.map replace
  where
    replace character
        | character `elem` ("-_." :: String) = character
        | character >= 'a' && character <= 'z' = character
        | character >= 'A' && character <= 'Z' = character
        | character >= '0' && character <= '9' = character
        | otherwise = '-'

aliasProjectedOperation :: Text
aliasProjectedOperation = "core:deploy-vm/core:copy-source/guest-alias"

liveStepPlan :: Either StepPlanError StepPlan
liveStepPlan =
    mkStepPlan
        [ descendsVia
            localContext
            (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
        , projectsOperation
            (Text.unpack aliasProjectedOperation)
            (copySourceStep "durable share" (StepFrame "provider" "Provider") (const (pure StepChanged)))
        ]

providerFailure :: ProviderError -> ReconcileError
providerFailure failure = case failure of
    ProviderUnsupported _ operation reason ->
        Unsupported
            ( UnsupportedDetail
                "discover managed provider"
                (Text.pack (show operation <> ": " <> reason))
            )
    ProviderOperationFailure _ operation reason ->
        Failure
            ( FailureDetail
                "discover managed provider"
                (Text.pack (show operation <> ": " <> reason))
                ReprobeBeforeRetry
            )

fixtureFailure :: Text -> Either ReconcileError value
fixtureFailure reason =
    Left
        ( Failure
            (FailureDetail "provider-live prepared route" reason DoNotRetry)
        )

runtimeFailure :: Text -> SomeException -> ReconcileError
runtimeFailure operation exception =
    Failure
        ( FailureDetail
            operation
            (Text.pack (displayException exception))
            ReprobeBeforeRetry
        )

attemptReconcile :: Text -> IO (Either ReconcileError value) -> IO (Either ReconcileError value)
attemptReconcile operation action = do
    outcome <- try @SomeException action
    pure $ case outcome of
        Left exception -> Left (runtimeFailure operation exception)
        Right result -> result

combinePrimaryCleanup :: Either ReconcileError () -> Either ReconcileError () -> Either ReconcileError ()
combinePrimaryCleanup primary cleanup = case cleanup of
    Left cleanupFailure -> case primary of
        Left primaryFailure ->
            fixtureFailure
                ( "primary failure: "
                    <> Text.pack (show primaryFailure)
                    <> "; cleanup failure: "
                    <> Text.pack (show cleanupFailure)
                )
        Right () -> Left cleanupFailure
    Right () -> primary

combineBodyRelease ::
    Either SomeException (Either ReconcileError ()) ->
    Either SomeException (Either ReconcileError ()) ->
    Either ReconcileError ()
combineBodyRelease body release =
    let primary = either (Left . runtimeFailure "exercise provider-live alias") id body
        released = either (Left . runtimeFailure "release provider-live alias") id release
     in case (primary, released) of
            (Left bodyFailure, Left releaseFailure) ->
                fixtureFailure
                    ( "body failure: "
                        <> Text.pack (show bodyFailure)
                        <> "; release failure: "
                        <> Text.pack (show releaseFailure)
                    )
            (_, Left releaseFailure) -> Left releaseFailure
            (_, Right ()) -> primary

joinReconcileIO :: Either ReconcileError (IO (Either ReconcileError value)) -> IO (Either ReconcileError value)
joinReconcileIO = either (pure . Left) id
