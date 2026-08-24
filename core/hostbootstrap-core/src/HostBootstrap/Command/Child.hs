{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The protocol-only entry for one storeless forward child frame.

The command line selects only this entry.  Project, scope, verb, plan, frame,
and every conversation coordinate arrive through the authenticated Offer or a
root-signed response.  The child reconstructs its exact local plan, executes
only root-prepared nodes, and returns observations; it opens no protected
store and settles nothing durably.
-}
module HostBootstrap.Command.Child (
    lifecycleChildArguments,
    runForwardLifecycleChild,
)
where

import Control.Exception.Safe (tryAny)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Dhall
import HostBootstrap.Activation (activationErrorMessage, activationGrantSignature, activationManifestFromWire)
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectUp),
    VerbUp,
 )
import HostBootstrap.Command.Child.Reverse (recoveryProfileName, runCoreManagedReverse)
import HostBootstrap.Config.Authority.Internal (mintAuthenticatedHarnessConfigAuthority)
import HostBootstrap.Config.Class (
    ProjectCfg (cfgContext),
    decodeProjectCodecWithSettings,
 )
import HostBootstrap.Config.Schema (
    ValidatedConfig,
    VerifiedConfigWire,
    configWireAdmissionErrorMessage,
    renderScopedProjectConfigBytes,
    siblingProjectConfigPath,
    validatedConfigValue,
    withAuthenticatedConfigWire,
    withValidatedConfig,
    withVerifiedConfigHandoff,
 )
import HostBootstrap.Config.Vocab (Harness, HarnessConfigAuthority, Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff (
    AuthenticatedConfigPayload,
    ProjectVerificationKey,
    frameWire,
    handoffBrokerGeneration,
    handoffChildFrame,
    handoffErrorMessage,
    handoffInstalledProject,
    handoffPlanRevision,
    handoffStoreIdentity,
    installedVerificationKey,
    renderAuthenticatedRootScope,
    renderRootedLifecycleResponse,
    takeHandoffFrame,
    verifiedHandoffBinding,
    withVerifiedRootedLifecycleResponse,
 )
import HostBootstrap.Handoff.Process (
    seedProviderDependencyCarrierKernel,
    withCarriedProviderDependencyFromCarrierKernel,
 )
import HostBootstrap.Handoff.Process.Route (
    withLifecycleChildOpeningKernel,
    withNestedForwardLifecycleProcessRouteKernel,
 )
import HostBootstrap.Handoff.Receiver (
    ReceivedRecoveryDescent,
    ReceiverError (..),
    receiverErrorMessage,
    withIsolatedReceivedHandoffEdge,
    withProviderDependencyClientKernel,
 )
import HostBootstrap.Handoff.Receiver.Internal (
    ReceivedEdge,
    receivedEdgeAuthenticatedRootScope,
    receivedEdgeHandoff,
    withReceivedRecoveryDescent,
 )
import HostBootstrap.Handoff.Recovery (
    recoveryChildPackageFromWireKernel,
    withRecoveryChildPackageKernel,
 )
import HostBootstrap.Handoff.Relay (
    BrokerLink,
    linkSignActivation,
    receiveRootedLifecycleResponseThroughLink,
    relayErrorMessage,
    withNestedRecursiveHandoffRuntimeKernel,
 )
import HostBootstrap.Handoff.Rooted (withRootedLifecycleResponseKernel)
import HostBootstrap.Handoff.Runtime (RecursiveHandoffRuntime)
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Lifecycle.Execution.Internal (
    ExecutionNode (..),
    ResourceCarrier,
    newResourceCarrier,
    newStepRuntime,
    openStepRuntimeGate,
    replaceStepRuntimeActivationSigningService,
    setStepRuntimeOwnGate,
 )
import HostBootstrap.Lifecycle.FrameExecutor (
    FrameExecutor,
    withAdvancedFrameExecutorKernel,
    withExecutedFrameNodeKernel,
    withFrameExecutorRequestKernel,
    withOpenedFrameExecutorForPlanKernel,
    withOpenedFrameExecutorKernel,
 )
import HostBootstrap.Lifecycle.Plan (PlannedStep (..))
import qualified HostBootstrap.Lifecycle.Plan as LifecyclePlan
import HostBootstrap.Lift.Context (
    LiftContext (LiftContext),
    LiftLayer (ViaContainer),
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    operationKeyText,
    plannedStepDependencyOperations,
    plannedStepFrameId,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    topologyDescentFrom,
 )
import HostBootstrap.ProjectPlan.Construct (
    FinalizedProjectSpec,
    finalizedProjectCodec,
    projectPlanDrafts,
    withChildProjectPlan,
    withHarnessFinalizedProjectSpec,
 )
import HostBootstrap.ProjectPlan.Frame (CurrentFrame, withCurrentFrame)
import HostBootstrap.ProjectPlan.Projection.Internal (withImmediateTargetKernel)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot, withCanonicalProjectRoot)
import HostBootstrap.Reconcile (stepExecutionFor)
import HostBootstrap.Step (Step, StepObservation, TeardownOutcome, observationDetail, observationSucceeded, runStep)
import HostBootstrap.Substrate (detect)
import HostBootstrap.Teardown (
    LocalWork,
    TeardownForest,
    eliminateTeardownProgress,
    nextTeardownWork,
    openTeardownForest,
    teardownErrorMessage,
    teardownForestOutstanding,
 )
import HostBootstrap.Teardown.Executor.Internal (
    runStorelessReversePreparedKernel,
    withStorelessReverseDescentResultKernel,
    withStorelessReverseExecutorKernel,
 )
import System.Environment (getExecutablePath)
import System.Exit (die)

-- | The coordinate-free private process entry rendered by the lifecycle route.
lifecycleChildArguments :: [String]
lifecycleChildArguments = ["--hostbootstrap-lifecycle-child"]

-- | Run the Production forward receiver selected by the fixed entry marker.
runForwardLifecycleChild ::
    (ProjectCfg cfg) =>
    InstalledProjectIdentity projectId ->
    FinalizedProjectSpec (Production projectId) specDigest cfg ->
    IO ()
runForwardLifecycleChild project finalized = do
    executable <- getExecutablePath
    loadedKey <- installedVerificationKey (executable <> ".handoff.pub")
    key <- either (die . handoffErrorMessage) pure loadedKey
    received <-
        withIsolatedReceivedHandoffEdge
            project
            key
            (runProduction key finalized)
            (runProductionRecovery key finalized)
            (runHarness key finalized)
            (runHarnessRecovery key finalized)
    either (die . receiverErrorMessage) pure received

runHarness ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec (Production projectId) productionSpecDigest cfg ->
    ReceivedEdge (Harness projectId runId) brokerGeneration ->
    AuthenticatedConfigPayload (Harness projectId runId) brokerGeneration ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
runHarness key production edge authenticated sendReport =
    case harnessConfigAuthorityFromEdge edge of
        Left failure -> pure (Left failure)
        Right authority ->
            withHarnessFinalizedProjectSpec authority production $ \finalized ->
                runScoped key finalized edge authenticated sendReport

runHarnessRecovery ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec (Production projectId) productionSpecDigest cfg ->
    ReceivedRecoveryDescent
        (Harness projectId runId)
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
runHarnessRecovery key production descent sendReport =
    withReceivedRecoveryDescent descent $ \edge _binding _package _verb _projection _grant ->
        case harnessConfigAuthorityFromEdge edge of
            Left failure -> pure (Left failure)
            Right authority ->
                withHarnessFinalizedProjectSpec authority production $ \finalized ->
                    runScopedRecovery key finalized descent sendReport

harnessConfigAuthorityFromEdge ::
    ReceivedEdge (Harness projectId runId) brokerGeneration ->
    Either Text (HarnessConfigAuthority projectId runId)
harnessConfigAuthorityFromEdge edge = do
    fields <- takeFrames 7 (renderAuthenticatedRootScope (receivedEdgeAuthenticatedRootScope edge))
    case fields of
        [_domain, _version, _project, "harness", runBytes, _keyDigest, _signature] ->
            case TextEncoding.decodeUtf8' runBytes of
                Left _ -> Left "the authenticated Harness scope run is not UTF-8"
                Right runName -> Right (mintAuthenticatedHarnessConfigAuthority runName)
        _ -> Left "the authenticated Harness scope capsule differs"
  where
    takeFrames :: Int -> ByteString -> Either Text [ByteString]
    takeFrames 0 trailing
        | ByteString.null trailing = Right []
        | otherwise = Left "the authenticated Harness scope capsule has trailing bytes"
    takeFrames count raw = do
        (field, trailing) <- either (Left . Text.pack . handoffErrorMessage) Right (takeHandoffFrame raw)
        (field :) <$> takeFrames (count - 1) trailing

runProductionRecovery ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec (Production projectId) specDigest cfg ->
    ReceivedRecoveryDescent
        (Production projectId)
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
runProductionRecovery key finalized descent sendReport =
    runScopedRecovery key finalized descent sendReport

runScopedRecovery ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec scope specDigest cfg ->
    ReceivedRecoveryDescent
        scope
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
runScopedRecovery key finalized descent sendReport =
    withReceivedRecoveryDescent descent $ \edge packageBytes verb adapter _projection _grant ->
        case recoveryChildPackageFromWireKernel packageBytes of
            Left failure -> pure (Left ("reverse child: " <> failure))
            Right package -> withRecoveryChildPackageKernel package $ \childConfig packageAdapter ->
                if packageAdapter /= adapter
                    then pure (Left "reverse child: the verified adapter differs from its package")
                    else do
                        decoded <-
                            tryAny
                                ( decodeProjectCodecWithSettings
                                    (finalizedProjectCodec finalized)
                                    Dhall.defaultInputSettings
                                    (TextEncoding.decodeUtf8 childConfig)
                                )
                        case decoded of
                            Left _ -> pure (Left "reverse child: the installed codec rejected the child config")
                            Right value
                                | renderScopedProjectConfigBytes (finalizedProjectCodec finalized) value /= childConfig ->
                                    pure (Left "reverse child: the child config is not canonical")
                                | otherwise -> do
                                    admitted <-
                                        withValidatedConfig
                                            (finalizedProjectCodec finalized)
                                            value
                                            (\_wire config -> admitReverse key finalized edge verb adapter config sendReport)
                                    pure $ either (Left . Text.pack) id admitted

admitReverse ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec scope specDigest cfg ->
    ReceivedEdge scope brokerGeneration ->
    ProjectVerb verb ->
    ByteString ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
admitReverse key finalized edge verb adapter config sendReport = do
    configPath <- siblingProjectConfigPath (Context.project context)
    rooted <-
        withCanonicalProjectRoot configPath (Text.unpack (Context.sourceRoot context)) $ \root ->
            case projectPlanDrafts finalized root config of
                Left failure -> pure (Left ("reverse child: " <> Text.pack (show failure)))
                Right drafts -> case recoveryProfileName binding of
                    Left failure -> pure (Left failure)
                    Right profileName ->
                        case LifecyclePlan.withChildProjectPlanKernel
                            profileName
                            (handoffBrokerGeneration binding)
                            (handoffInstalledProject binding)
                            (handoffStoreIdentity binding)
                            (handoffPlanRevision binding)
                            config
                            drafts
                            ( \plan _digestBinding ->
                                case withCurrentFrame plan context $ \current _frame _admitted ->
                                    if Context.currentFrame context /= handoffChildFrame binding
                                        then pure (Left "reverse child: the local frame differs from the authenticated child")
                                        else case withStorelessReverseExecutorKernel plan current verb adapter id of
                                            Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                                            Right projection -> case openTeardownForest projection of
                                                Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                                                Right forest -> do
                                                    configured <- hostConfig
                                                    case configured of
                                                        Left failure -> pure (Left failure)
                                                        Right host -> openReverseFrame key edge host root context verb plan forest sendReport of
                                    Left failure -> pure (Left (Text.pack (show failure)))
                                    Right action -> action
                            ) of
                            Left failure -> pure (Left ("reverse child: " <> Text.pack (show failure)))
                            Right action -> action
    pure $ either (Left . Text.pack . show) id rooted
  where
    binding = verifiedHandoffBinding (receivedEdgeHandoff edge)
    context = cfgContext (validatedConfigValue config)

openReverseFrame ::
    ProjectVerificationKey ->
    ReceivedEdge scope brokerGeneration ->
    HostConfig ->
    CanonicalProjectRoot scope rootId ->
    Context.BinaryContext ->
    ProjectVerb verb ->
    ProjectPlan scope specDigest planId configId cfg ->
    TeardownForest scope planId frame verb ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
openReverseFrame key edge host root context verb plan forest sendReport =
    withNestedRecursiveHandoffRuntimeKernel edge verb $ \runtime link -> do
        nonce <- freshNonce
        withLifecycleChildOpeningKernel runtime key nonce (carry key link) $ \request signedOpened ->
            withOpenedFrameExecutorKernel
                key
                (receivedEdgeAuthenticatedRootScope edge)
                verb
                frameName
                planDigest
                nodes
                request
                signedOpened
                (driveReverse key link host (runCoreManagedReverse root context plan host) forest sendReport)
  where
    binding = verifiedHandoffBinding (receivedEdgeHandoff edge)
    frameName = handoffChildFrame binding
    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    nodes = [ExecutionNode operation frameName [] [] Nothing | operation <- teardownForestOutstanding forest]

driveReverse ::
    ProjectVerificationKey ->
    BrokerLink scope linkGeneration ->
    HostConfig ->
    (LocalWork scope planId frame verb -> IO TeardownOutcome) ->
    TeardownForest scope planId frame verb ->
    (ByteString -> IO (Either ReceiverError ())) ->
    FrameExecutor scope rootPlanId executorGeneration catalogId executorFrame sessionId verb ->
    IO (Either Text ())
driveReverse key link host runCoreManaged forest sendReport executor =
    eliminateTeardownProgress (nextTeardownWork forest) (const requestClose) (const requestNext)
  where
    requestNext = sendExecutorRequest executor "next-node" Nothing $ \exactRequest signed ->
        case responseView key exactRequest signed of
            Left failure -> pure (Left failure)
            Right ("prepared", _) -> do
                successorRef <- newIORef Nothing
                withExecutedFrameNodeKernel
                    executor
                    key
                    exactRequest
                    signed
                    ( \node _own _projected _carrier -> do
                        advanced <- runStorelessReversePreparedKernel host runCoreManaged forest (executionNodeOperationKey node)
                        case advanced of
                            Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                            Right (successor, observation) -> do
                                writeIORef successorRef (Just successor)
                                pure (Right observation)
                    )
                    ( \observation -> do
                        successor <- readIORef successorRef
                        case successor of
                            Nothing -> pure (Left "reverse child: local work produced no successor")
                            Just advancedForest ->
                                withAdvancedFrameExecutorKernel executor key exactRequest signed $ \prepared ->
                                    sendExecutorRequest prepared "settle-node" (Just observation) $ \settleRequest settled ->
                                        case responseView key settleRequest settled of
                                            Right ("settled", _) ->
                                                withAdvancedFrameExecutorKernel prepared key settleRequest settled $ \advanced ->
                                                    driveReverse key link host runCoreManaged advancedForest sendReport advanced
                                            Right (family, _) -> unexpected "settle-node" family
                                            Left failure -> pure (Left failure)
                    )
            Right ("descend", body) -> case reverseDescentBody body of
                Left failure -> pure (Left failure)
                Right (child, observations) ->
                    case withStorelessReverseDescentResultKernel forest child observations id of
                        Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                        Right advancedForest ->
                            withAdvancedFrameExecutorKernel executor key exactRequest signed $ \descending ->
                                sendExecutorRequest descending "descend-result" (Just observations) $ \resultRequest settled ->
                                    case responseView key resultRequest settled of
                                        Right ("settled", _) ->
                                            withAdvancedFrameExecutorKernel descending key resultRequest settled $ \advanced ->
                                                driveReverse key link host runCoreManaged advancedForest sendReport advanced
                                        Right (family, _) -> unexpected "descend-result" family
                                        Left failure -> pure (Left failure)
            Right ("refused", detail) -> pure (Left ("reverse child: root refused NextNode: " <> decode detail))
            Right (family, _) -> unexpected "next-node" family

    requestClose = sendExecutorRequest executor "close-frame" Nothing $ \closeRequest completedResponse ->
        case responseView key closeRequest completedResponse of
            Right ("frame-complete", report) ->
                withAdvancedFrameExecutorKernel executor key closeRequest completedResponse $ \completedFrame ->
                    sendExecutorRequest completedFrame "receipt-confirm" Nothing $ \receiptRequest receipt ->
                        case responseView key receiptRequest receipt of
                            Right ("receipt-recorded", _) ->
                                either (Left . Text.pack . receiverErrorMessage) Right <$> sendReport report
                            Right (family, _) -> unexpected "receipt-confirm" family
                            Left failure -> pure (Left failure)
            Right ("refused", detail) -> pure (Left ("reverse child: root refused CloseFrame: " <> decode detail))
            Right (family, _) -> unexpected "close-frame" family
            Left failure -> pure (Left failure)

    sendExecutorRequest active family body continuation = do
        nonce <- freshNonce
        withFrameExecutorRequestKernel active family nonce body $ \exactRequest -> do
            answered <- carryRaw key link exactRequest
            either (pure . Left) (continuation exactRequest) answered
    unexpected requestFamily responseFamily =
        pure (Left ("reverse child: " <> requestFamily <> " received " <> responseFamily))
    decode = TextEncoding.decodeUtf8Lenient

reverseDescentBody :: ByteString -> Either Text (Text, ByteString)
reverseDescentBody body = do
    (childBytes, afterChild) <- either (Left . Text.pack . handoffErrorMessage) Right (takeHandoffFrame body)
    (observations, trailing) <- either (Left . Text.pack . handoffErrorMessage) Right (takeHandoffFrame afterChild)
    if ByteString.null trailing
        then case TextEncoding.decodeUtf8' childBytes of
            Left _ -> Left "reverse child: Descend names a non-UTF-8 child frame"
            Right child -> Right (child, observations)
        else Left "reverse child: Descend has trailing bytes"

runProduction ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec (Production projectId) specDigest cfg ->
    ReceivedEdge (Production projectId) brokerGeneration ->
    AuthenticatedConfigPayload (Production projectId) brokerGeneration ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
runProduction key finalized edge authenticated sendReport = do
    runScoped key finalized edge authenticated sendReport

runScoped ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec scope specDigest cfg ->
    ReceivedEdge scope brokerGeneration ->
    AuthenticatedConfigPayload scope brokerGeneration ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
runScoped key finalized edge authenticated sendReport = do
    admitted <-
        withAuthenticatedConfigWire
            (finalizedProjectCodec finalized)
            authenticated
            (runConfig key finalized edge authenticated sendReport)
    pure $ either (Left . configWireAdmissionErrorMessage) id admitted

runConfig ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec scope specDigest cfg ->
    ReceivedEdge scope brokerGeneration ->
    AuthenticatedConfigPayload scope brokerGeneration ->
    (ByteString -> IO (Either ReceiverError ())) ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    IO (Either Text ())
runConfig key finalized edge _authenticated sendReport wire config = do
    configPath <- siblingProjectConfigPath (Context.project context)
    rooted <-
        withCanonicalProjectRoot
            configPath
            (Text.unpack (Context.sourceRoot context))
            ( \root -> case projectPlanDrafts finalized root config of
                Left failure -> pure (Left (Text.pack (show failure)))
                Right drafts ->
                    case withVerifiedConfigHandoff
                        ProjectUp
                        (receivedEdgeHandoff edge)
                        wire
                        config
                        ( \handoff ->
                            withChildProjectPlan ProjectUp handoff wire config drafts $ \_authority plan _binding -> do
                                case withCurrentFrame
                                    plan
                                    context
                                    ( \current _frame _admitted -> do
                                        configured <- hostConfig
                                        case configured of
                                            Left failure -> pure (Left failure)
                                            Right host -> openFrame key finalized edge host config plan current sendReport
                                    ) of
                                    Left failure -> pure (Left (Text.pack (show failure)))
                                    Right action -> action
                        ) of
                        Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                        Right (Left failure) -> pure (Left (Text.pack (show failure)))
                        Right (Right action) -> action
            )
    pure $ either (Left . Text.pack . show) id rooted
  where
    context = cfgContext (validatedConfigValue config)

openFrame ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    FinalizedProjectSpec scope specDigest cfg ->
    ReceivedEdge scope brokerGeneration ->
    HostConfig ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
openFrame key finalized edge host config plan current sendReport =
    withNestedRecursiveHandoffRuntimeKernel edge ProjectUp $ \runtime link -> do
        nonce <- freshNonce
        carrier <- newResourceCarrier
        activationRuntime <- newStepRuntime carrier
        replaceStepRuntimeActivationSigningService activationRuntime $ \manifestWire ->
            case activationManifestFromWire manifestWire of
                Left failure -> pure (Left (Text.pack (activationErrorMessage failure)))
                Right manifest -> do
                    signed <- linkSignActivation link manifest
                    pure (either (Left . Text.pack . relayErrorMessage) (Right . activationGrantSignature) signed)
        let opened = openWith carrier runtime link nonce
        admitted <- withProviderDependencyClientKernel edge $ \packageWires client ->
            case packageWires of
                Nothing -> fmap (either (Left . ReceiverDeclined) Right) opened
                Just admittedPackages -> do
                    seeded <-
                        traverse
                            ( \admittedPackage ->
                                seedProviderDependencyCarrierKernel
                                    carrier
                                    admittedPackage
                                    (fmap (either (Left . Text.pack . receiverErrorMessage) Right) . client admittedPackage)
                            )
                            admittedPackages
                    case sequence seeded of
                        Left failure -> pure (Left (ReceiverDeclined failure))
                        Right _ -> fmap (either (Left . ReceiverDeclined) Right) opened
        pure (either (Left . Text.pack . receiverErrorMessage) (const (Right ())) admitted)
  where
    frame = Context.currentFrame (cfgContext (validatedConfigValue config))
    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    local =
        [ plannedNode planned
        | planned <- NonEmpty.toList (forward plan)
        , plannedStepFrameId planned == frame
        ]
    openWith carrier runtime link nonce =
        withLifecycleChildOpeningKernel runtime key nonce (carry key link) $ \request signedOpened ->
            withOpenedFrameExecutorForPlanKernel
                key
                (receivedEdgeAuthenticatedRootScope edge)
                ProjectUp
                frame
                planDigest
                [node | (node, _, _) <- local]
                carrier
                request
                signedOpened
                (\executor -> drive key runtime link host finalized config plan current carrier planDigest local [] False Nothing executor sendReport)

drive ::
    (ProjectCfg cfg) =>
    ProjectVerificationKey ->
    RecursiveHandoffRuntime scope linkGeneration VerbUp ->
    BrokerLink scope linkGeneration ->
    HostConfig ->
    FinalizedProjectSpec scope specDigest cfg ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId currentFrame ->
    ResourceCarrier scope planId ->
    Text ->
    [(ExecutionNode, Step, PlannedStep scope planId configId (cfg scope))] ->
    [Text] ->
    Bool ->
    Maybe Text ->
    FrameExecutor scope planId executorGeneration catalogId frame sessionId VerbUp ->
    (ByteString -> IO (Either ReceiverError ())) ->
    IO (Either Text ())
drive key runtime link host finalized config plan current carrier planDigest local completed descended failed executor sendReport
    | failed /= Nothing = requestClose
    | length completed == length local && (descended || noDescent) = requestClose
    | otherwise = requestNext
  where
    noDescent = case topologyDescentFrom (topology plan) frameName of
        Nothing -> True
        Just _ -> False
    frameName = Context.currentFrame (cfgContext (validatedConfigValue config))
    requestNext = sendExecutorRequest executor "next-node" Nothing $ \exactRequest signed ->
        case responseView key exactRequest signed of
            Left failure -> pure (Left failure)
            Right ("prepared", nodeBytes) ->
                case TextEncoding.decodeUtf8' nodeBytes of
                    Left _ -> pure (Left "forward child: Prepared names a non-UTF-8 operation")
                    Right operation ->
                        withExecutedFrameNodeKernel executor key exactRequest signed (runLocal operation) $ \observation ->
                            withAdvancedFrameExecutorKernel executor key exactRequest signed $ \prepared ->
                                sendExecutorRequest prepared "settle-node" (Just observation) $ \settleRequest settled ->
                                    case responseView key settleRequest settled of
                                        Right ("settled", _) ->
                                            withAdvancedFrameExecutorKernel prepared key settleRequest settled $ \advanced ->
                                                case nodeObservationFailure observation of
                                                    Left failure -> pure (Left failure)
                                                    Right observedFailure ->
                                                        drive key runtime link host finalized config plan current carrier planDigest local (operation : completed) descended observedFailure advanced sendReport
                                        Right (family, _) -> unexpected "settle-node" family
                                        Left failure -> pure (Left failure)
            Right ("descend", body) ->
                withAdvancedFrameExecutorKernel executor key exactRequest signed $ \descending -> do
                    nested <- runNested body
                    sendExecutorRequest descending "descend-result" (Just (descentObservation nested)) $ \resultRequest settled ->
                        case responseView key resultRequest settled of
                            Right ("settled", _) ->
                                withAdvancedFrameExecutorKernel descending key resultRequest settled $ \advanced ->
                                    case nested of
                                        Left failure -> drive key runtime link host finalized config plan current carrier planDigest local completed True (Just failure) advanced sendReport
                                        Right () -> drive key runtime link host finalized config plan current carrier planDigest local completed True Nothing advanced sendReport
                            Right (family, _) -> unexpected "descend-result" family
                            Left failure -> pure (Left failure)
            Right ("refused", detail) -> pure (Left ("forward child: root refused NextNode: " <> decode detail))
            Right (family, _) -> unexpected "next-node" family

    requestClose = sendExecutorRequest executor "close-frame" Nothing $ \closeRequest completedResponse ->
        case responseView key closeRequest completedResponse of
            Right ("frame-complete", report) ->
                withAdvancedFrameExecutorKernel executor key closeRequest completedResponse $ \completedFrame ->
                    sendExecutorRequest completedFrame "receipt-confirm" Nothing $ \receiptRequest receipt ->
                        case responseView key receiptRequest receipt of
                            Right ("receipt-recorded", _) ->
                                sendReport report >>= \sent ->
                                    pure $ case sent of
                                        Left sendFailure -> Left (Text.pack (receiverErrorMessage sendFailure))
                                        Right () -> maybe (Right ()) Left failed
                            Right (family, _) -> unexpected "receipt-confirm" family
                            Left failure -> pure (Left failure)
            Right ("refused", detail) -> pure (Left ("forward child: root refused CloseFrame: " <> decode detail))
            Right (family, _) -> unexpected "close-frame" family
            Left failure -> pure (Left failure)

    sendExecutorRequest activeExecutor family body continuation = do
        nonce <- freshNonce
        withFrameExecutorRequestKernel activeExecutor family nonce body $ \exactRequest -> do
            answered <- carryRaw key link exactRequest
            either (pure . Left) (continuation exactRequest) answered

    runLocal operation node own projected runtimeCarrier =
        case [(step, planned) | (candidate, step, planned) <- local, candidate == node] of
            [(step, planned)] -> do
                stepRuntime <- newStepRuntime runtimeCarrier
                setStepRuntimeOwnGate stepRuntime own
                mapM_ (openStepRuntimeGate stepRuntime) projected
                observed <-
                    runStep
                        step
                        (stepExecutionFor plan host stepRuntime planned)
                pure (Right (renderObservation operation observed))
            _ -> pure (Left "forward child: the prepared node is not uniquely present in the local plan")

    unexpected requestFamily responseFamily =
        pure (Left ("forward child: " <> requestFamily <> " received " <> responseFamily))
    decode = TextEncoding.decodeUtf8Lenient

    runNested body =
        withImmediateTargetKernel
            finalized
            plan
            current
            (cfgContext (validatedConfigValue config))
            ( \_targetPlan _binding _targetCurrent _childContext _parent child _raw route payload _configDigest _payloadDigest input ->
                if TextEncoding.decodeUtf8Lenient body /= child
                    then pure (Left "forward child: Descend names another admitted child frame")
                    else
                        withNestedForwardLifecycleProcessRouteKernel
                            runtime
                            route
                            input
                            ProjectUp
                            (targetBinary route)
                            ( \processRoute ->
                                withCarriedProviderDependencyFromCarrierKernel
                                    host
                                    link
                                    processRoute
                                    1
                                    input
                                    payload
                                    carrier
                            )
            )

    targetBinary (LiftContext [ViaContainer _]) = Text.empty
    targetBinary _ = "/usr/local/bin/" <> Context.binary (cfgContext (validatedConfigValue config))

    descentObservation (Right ()) =
        frameWire "hostbootstrap/forward-descent-result/v1" <> frameWire "succeeded"
    descentObservation (Left failure) =
        frameWire "hostbootstrap/forward-descent-result/v1"
            <> frameWire "failed"
            <> frameWire (TextEncoding.encodeUtf8 failure)

nodeObservationFailure :: ByteString -> Either Text (Maybe Text)
nodeObservationFailure raw = do
    (domain, afterDomain) <- takeFrame "observation domain" raw
    (_operation, afterOperation) <- takeFrame "observation operation" afterDomain
    (status, afterStatus) <- takeFrame "observation status" afterOperation
    (detailBytes, trailing) <- takeFrame "observation detail" afterStatus
    if domain /= "hostbootstrap/forward-node-observation/v1"
        then Left "forward child: the observation domain differs"
        else
            if not (ByteString.null trailing)
                then Left "forward child: the observation has trailing fields"
                else case status of
                    "succeeded" -> Right Nothing
                    "failed" -> case TextEncoding.decodeUtf8' detailBytes of
                        Left _ -> Left "forward child: the observation failure is not UTF-8"
                        Right detail
                            | Text.null detail -> Left "forward child: the observation failure is empty"
                            | otherwise -> Right (Just detail)
                    _ -> Left "forward child: the observation status is unknown"
  where
    takeFrame field bytes =
        case takeHandoffFrame bytes of
            Left failure -> Left ("forward child: " <> field <> ": " <> Text.pack (handoffErrorMessage failure))
            Right value -> Right value

plannedNode :: PlannedStep scope planId configId config -> (ExecutionNode, Step, PlannedStep scope planId configId config)
plannedNode planned@(PlannedStep _ step _) =
    ( ExecutionNode
        { executionNodeOperationKey = key
        , executionNodeFrame = plannedStepFrameId planned
        , executionNodeDependencies =
            [ (Text.pack (operationKeyText dependency), frame)
            | (dependency, frame) <- plannedStepDependencyOperations planned
            ]
        , executionNodeProjectedKeys =
            map (Text.pack . operationKeyText) (plannedStepProjectedOperationKeys planned)
        , executionNodeChartWorkload = Nothing
        }
    , step
    , planned
    )
  where
    key = Text.pack (operationKeyText (plannedStepOperationKey planned))

renderObservation :: Text -> StepObservation -> ByteString
renderObservation operation observed =
    frameWire "hostbootstrap/forward-node-observation/v1"
        <> frameWire (TextEncoding.encodeUtf8 operation)
        <> frameWire (if observationSucceeded observed then "succeeded" else "failed")
        <> frameWire (TextEncoding.encodeUtf8 (observationDetail observed))

responseView :: ProjectVerificationKey -> ByteString -> ByteString -> Either Text (Text, ByteString)
responseView key request signed = do
    response <- either (Left . Text.pack . handoffErrorMessage) Right (withVerifiedRootedLifecycleResponse key request signed id)
    pure
        ( withRootedLifecycleResponseKernel
            response
            (\_ _ _ _ _ _ -> ("opened", ByteString.empty))
            (\_ _ _ _ _ _ node _ _ _ _ -> ("prepared", node))
            (\_ _ _ _ _ _ body _ -> ("descend", body))
            (\_ _ _ _ _ _ body _ -> ("settled", body))
            (\_ _ _ _ _ _ body _ -> ("frame-complete", body))
            (\_ _ _ _ _ _ completion _ -> ("receipt-recorded", TextEncoding.encodeUtf8 completion))
            (\_ _ _ _ _ _ detail _ -> ("refused", TextEncoding.encodeUtf8 detail))
        )

carry ::
    ProjectVerificationKey ->
    BrokerLink scope brokerGeneration ->
    ByteString ->
    IO (Either Text ByteString)
carry = carryRaw

carryRaw ::
    ProjectVerificationKey ->
    BrokerLink scope brokerGeneration ->
    ByteString ->
    IO (Either Text ByteString)
carryRaw key link request = do
    answered <- receiveRootedLifecycleResponseThroughLink key link request
    pure (either (Left . Text.pack . relayErrorMessage) (Right . renderRootedLifecycleResponse) answered)

freshNonce :: IO ByteString
freshNonce = getRandomBytes 32

hostConfig :: IO (Either Text HostConfig)
hostConfig = do
    detected <- detect
    case detected of
        Left failure -> pure (Left (Text.pack failure))
        Right substrate -> Right <$> buildHostConfig substrate
