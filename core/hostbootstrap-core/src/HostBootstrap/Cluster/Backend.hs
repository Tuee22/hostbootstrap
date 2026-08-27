{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The IO backend that produces cluster observations while holding the four
ownership clauses, plus the loopback-bound exposure operation the cluster's
published ports must consume.

This is the cluster peer of "HostBootstrap.Substrate.Provider.Backend": the
classification and receipt gating live in "HostBootstrap.Cluster.Reconcile", and
this module supplies only the effects that feed it.

__Nothing here is written in another language, and nothing here runs a string.__
Every effect is a described command interpreted by the one interpreter (§ KK),
every decision above it is a total function over the bytes a tool wrote, and the
four clauses are held by "HostBootstrap.Cluster.Ownership" over the one seam
(§ EE, § LL). What is left for this module is the __join__: turning a prepared
plan-owned package into the object that driver is about, and turning the driver's
answer into the observation the reconciler classifies.

Clause realization (see @documents/architecture/ownership_invariant.md@):

* clause 1 — the protected store's exclusive entry, taken for exactly one
  transaction and released by the kernel if the holder dies;
* clause 2 — that store's compare-and-swap, published over an explicit absence
  before the creating command;
* clause 3 — the node container's immutable identity, one per record: the
  cluster's own record binds the control-plane container and every other node
  carries its own record beside it, so a later cordon addresses a node by the
  identity this run bound rather than by the name a replacement inherits;
* clause 4 — every node re-observed as that identity before the destructive
  command, and a record forgotten only over a reported absence.

__A backend is a value the declaration decides.__ Nothing is probed here: the
writable state directory and clause-holding protected store are established when
a transaction enters it, and tools are resolved once through typed @HostConfig@
(§ K). What is admitted is only that the selected Kind/nvkind creation driver and
Docker, Kubectl, and Helm are in that configuration, so a backend that cannot
reach one of them mints no
capability rather than failing at the first effect.
-}
module HostBootstrap.Cluster.Backend (
    -- * The clause-holding backend
    StrongClusterBackend,
    discoverStrongClusterBackend,
    runClusterReconcileCall,
    runClusterCleanupCall,
    releaseRetainedCluster,
    runClusterCordonCall,
    ClusterStatusObservation (..),
    runClusterStatusCall,
    classifyClusterStatus,
    runClusterReadinessCall,
    registerClusterRuntimeDependencyPackage,
    withFreshClusterRuntimeDependency,
    PreparedChartWorkload,
    withPreparedActivatedChartWorkload,
    withPreparedChartWorkload,
    runChartWorkloadCall,
    runChartWorkloadCleanupCall,
    runVerifiedChartWorkloadCleanupCall,

    -- * Runtime-owned loopback exposure
    ExposureIntent,
    mkExposureIntent,
    exposureIntentService,
    exposureIntentTargetHost,
    exposureIntentTargetPort,
    PreparedClusterExposure,
    withPreparedClusterExposure,
    ResolvedExposure,
    withResolvedExposure,
    resolvedExposureService,
    resolvedExposureListenAddress,
    resolvedExposureHostPort,
    resolvedExposureTargetHost,
    resolvedExposureTargetPort,
    resolvedExposureRelayIdentity,
    resolvedExposureClusterGeneration,
    resolvedExposureOwnershipOperation,
    runClusterExposureCall,
    releaseClusterExposureCall,
    RecordedClusterExposure,
    recordedClusterExposureHostPort,
    observeRecordedClusterExposure,
    releaseRecordedClusterExposure,
)
where

import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (Array, Object, String), eitherDecodeStrict')
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as AesonKeyMap
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (intercalate, isInfixOf, sort)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Cluster.Backend.Internal (
    StrongClusterBackend,
    mkStrongClusterBackend,
    strongClusterConfigBytes,
    strongClusterConfigDigest,
    strongClusterDriver,
    strongClusterHostConfig,
    strongClusterKubeconfigPath,
    strongClusterOwnershipIdentity,
    strongClusterReadinessVersion,
 )
import HostBootstrap.Cluster.Command (listClustersCommand)
import HostBootstrap.Cluster.Cordon (ResourceBudget)
import HostBootstrap.Cluster.Exposure.Internal (exposureRelayMarker)
import HostBootstrap.Cluster.Lifecycle (
    ClusterDriver (KindDriver, NvkindDriver),
    ClusterPlan (clusterConfigFile, clusterDriver, clusterName, dataPath),
    ExposureIntent,
    PlanOwnedClusterConfig,
    clusterKubeconfigPath,
    clusterNodeNames,
    clusterRuntimeStateDirectory,
    exposureIntentService,
    exposureIntentTargetHost,
    exposureIntentTargetPort,
    mkPlanExposureIntent,
    planOwnedClusterConfigBase,
    planOwnedClusterConfigBytes,
    planOwnedClusterConfigDigest,
    planOwnedClusterConfigDriver,
    planOwnedClusterOwnershipIdentity,
    planOwnedClusterStateDirectory,
 )
import HostBootstrap.Cluster.Observation.Internal (
    ClusterBackendBinding (..),
    ClusterCleanupCallResult (..),
    ClusterCleanupObservation (..),
    ClusterCordonCallResult (..),
    ClusterCordonObservation (..),
    ClusterReadinessCallResult (..),
    ClusterReadinessObservation (..),
    ClusterReconcileCallResult (..),
    ClusterReconcileObservation (..),
    managedClusterBackendIdentity,
 )
import qualified HostBootstrap.Cluster.Ownership as Owned
import HostBootstrap.Cluster.Reconcile (
    AppliedClusterCordon,
    ClusterReadiness,
    ClusterReadinessResultView (..),
    PreparedClusterCleanup,
    PreparedClusterCordon,
    PreparedClusterReconcile,
    appliedClusterCordonHandle,
    appliedClusterCordonName,
    appliedClusterCordonNodeNames,
    appliedClusterCordonOwnershipIdentity,
    appliedClusterCordonStateDirectory,
    clusterReadinessResultView,
    managedClusterGeneration,
    managedClusterKey,
    preparedCleanupClusterName,
    preparedCleanupNodeNames,
    preparedCleanupOwnershipIdentity,
    preparedCleanupStateDirectory,
    preparedClusterConfigBytes,
    preparedClusterConfigDigest,
    preparedClusterConfigPath,
    preparedClusterCordonBudget,
    preparedClusterCordonName,
    preparedClusterCordonNodeNames,
    preparedClusterCordonOwnershipIdentity,
    preparedClusterCordonStateDirectory,
    preparedClusterDriver,
    preparedClusterName,
    preparedClusterNodeNames,
    preparedClusterOwnershipIdentity,
    preparedClusterStateDirectory,
    reprobeClusterReadiness,
    withRecoveredClusterReadiness,
 )
import HostBootstrap.Cluster.Report (
    ClusterPresence (ClusterAbsent, ClusterPresent),
    classifyClusterListing,
    clusterReportFaultMessage,
    containerReference,
    safeClusterName,
 )
import HostBootstrap.Cluster.Resume (ClusterStandingConflict (ClusterUnderNoRecord, NodeReplaced))
import HostBootstrap.Cluster.Workload (
    PreparedChartWorkload,
    settlePreparedChartWorkload,
    settlePreparedChartWorkloadUnchanged,
    withPreparedActivatedChartWorkload,
    withPreparedChartWorkload,
    withPreparedChartWorkloadParts,
    withSettledChartWorkloadCleanup,
 )
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand, withCommandStdin)
import HostBootstrap.HostConfig (HostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Kind, Kubectl, Nvkind), toolCommandName)
import HostBootstrap.Lifecycle.Dependency.Internal (
    RuntimeDependencyPackage,
    mkClusterRuntimeDependencyPackage,
    renderRuntimeDependencyChartResponse,
    renderRuntimeDependencyExposureResponse,
    renderRuntimeDependencyProbeResponse,
    runtimeDependencyChartRequest,
    runtimeDependencyExposureRequest,
    runtimeDependencyPackageGeneration,
    runtimeDependencyPackageKey,
    runtimeDependencyProbeRequest,
    verifyRuntimeDependencyChartResponse,
    verifyRuntimeDependencyExposureResponse,
    verifyRuntimeDependencyProbeResponse,
    withClusterRuntimeDependencySuccessor,
    withRuntimeDependencyChartRequest,
    withRuntimeDependencyExposureRequest,
    withRuntimeDependencyProbeRequest,
 )
import HostBootstrap.Lifecycle.Execution.Internal (
    StepExecution,
    invokeStepRuntimeDependencyService,
    registerStepRuntimeDependencyPackage,
    replaceStepRuntimeDependencyService,
    stepExecutionFrame,
    stepExecutionPlanDigest,
    stepExecutionRuntime,
    stepRuntimeDependencyPackages,
 )
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
 )
import HostBootstrap.Ownership.Object (ObjectIdentity)
import HostBootstrap.ProjectPlan (ChartWorkloadResource)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    RecordVersion,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ClusterResource,
    ConflictDetail (..),
    FailureDetail (..),
    PlannedResource,
    PriorCommitProof,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    UnsupportedDetail (..),
    VerifiedResourceRecordBundle,
    resourceHandleGeneration,
    withCarriedManagedResourceOfKind,
    withVerifiedResourceRecordBundle,
 )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, (</>))
import Text.Read (readMaybe)

-- The clause-holding backend --------------------------------------------------

{- | Capability for a backend that holds the four clauses for a cluster.

Its constructor is not exported, so a caller cannot mint one from chosen tool
paths. It retains the exact plan-owned driver, config bytes/digest, ownership
identity, typed host configuration, and readiness-observation counter.
-}

{- | Admit the declared backend.

No probe, and no discovery of its own: the tools were resolved once into the
typed configuration (§ K), and the state directory, the exclusive entry, and the
durable record are the protected store's to establish when the first transaction
enters it. A tool the configuration does not carry is 'Unsupported' here rather
than a failure at the first effect, because a backend that cannot reach its
driver should mint no capability at all.
-}
discoverStrongClusterBackend ::
    HostConfig ->
    PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    IO (Either ReconcileError StrongClusterBackend)
discoverStrongClusterBackend cfg configured =
    case filter (isNothing . resolveMaybe cfg) requiredTools of
        [] -> do
            readiness <- newIORef 0
            pure
                ( Right
                    ( mkStrongClusterBackend
                        cfg
                        driver
                        (planOwnedClusterConfigBytes configured)
                        (planOwnedClusterConfigDigest configured)
                        (planOwnedClusterOwnershipIdentity (planOwnedClusterConfigBase configured))
                        (planOwnedClusterStateDirectory (planOwnedClusterConfigBase configured) </> "cluster.kubeconfig")
                        readiness
                    )
                )
        (missing : _) ->
            pure
                ( Left
                    ( Unsupported
                        ( UnsupportedDetail
                            "reconcile cluster"
                            ( "required cluster tool was not resolved through HostConfig: "
                                <> Text.pack (toolCommandName missing)
                            )
                        )
                    )
                )
  where
    driver = planOwnedClusterConfigDriver configured
    requiredTools =
        [ case driver of
            KindDriver -> Kind
            NvkindDriver -> Nvkind
        , Docker
        , Kubectl
        , Helm
        ]

runChartWorkloadCall ::
    Maybe (PriorCommitProof scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame)) ->
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned))
runChartWorkloadCall prior prepared =
    withPreparedChartWorkloadParts prepared $ \execution values activationRevision artifact release namespace _valuesDigest image _workloadKey _role _effects clusterKey operationCallDigest _observed _ _ ->
        case (TextEncoding.decodeUtf8' values, deployments) of
            (Left _, _) -> pure (failed "canonical values are not UTF-8")
            (_, []) -> pure (failed "the admitted effects contain no deployment readiness target")
            (_, _ : _ : _) -> pure (failed "the admitted effects contain multiple deployment readiness targets")
            (Right valuesText, [deployment]) -> do
                packages <- stepRuntimeDependencyPackages (stepExecutionRuntime execution)
                case filter ((== "cluster:" <> clusterKey) . runtimeDependencyPackageKey) packages of
                    [package] ->
                        case runtimeDependencyChartRequest package operationCallDigest artifact release namespace image deployment (maybe "" id activationRevision) valuesText of
                            Left refusal -> pure (failed refusal)
                            Right request -> do
                                response <- invokeStepRuntimeDependencyService (stepExecutionRuntime execution) package request
                                pure $ case response >>= verifyRuntimeDependencyChartResponse package operationCallDigest of
                                    Left refusal -> failed refusal
                                    Right "unchanged" -> maybe (settlePreparedChartWorkload prepared (BackendRepaired generation)) (settlePreparedChartWorkloadUnchanged prepared) prior
                                    Right "created" -> settlePreparedChartWorkload prepared (BackendCreated generation)
                                    Right "repaired" -> settlePreparedChartWorkload prepared (BackendRepaired generation)
                                    Right _ -> failed "runtime dependency returned an impossible chart outcome"
                    [] -> pure (failed "the exact cluster runtime dependency package is absent")
                    _ -> pure (failed "the cluster runtime dependency registry contains duplicate resource keys")
  where
    deployments = [Text.drop 11 effect | effect <- preparedEffects, "deployment:" `Text.isPrefixOf` effect]
    preparedEffects = withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ effects _ _ _ _ _ -> effects
    generation = withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ _ _ _ observed _ _ -> resourceHandleGeneration observed
    failed reason = settlePreparedChartWorkload prepared (BackendFailed reason ReprobeBeforeRetry)

runChartWorkloadCleanupCall ::
    StrongClusterBackend ->
    ChartWorkloadResource scope planId chartId chartFrame ->
    ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned ->
    IO (Either ReconcileError ())
runChartWorkloadCleanupCall backend chart settlement =
    case withSettledChartWorkloadCleanup chart settlement (,) of
        Left failure -> pure (Left failure)
        Right (release, namespace) ->
            runChartCleanup
                (strongClusterHostConfig backend)
                (strongClusterKubeconfigPath backend)
                release
                namespace

runVerifiedChartWorkloadCleanupCall ::
    HostConfig ->
    ClusterPlan ->
    ChartWorkloadResource scope planId chartId chartFrame ->
    VerifiedResourceRecordBundle scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) ->
    IO (Either ReconcileError ())
runVerifiedChartWorkloadCleanupCall cfg cluster chart bundle =
    withVerifiedResourceRecordBundle
        bundle
        (\_receipt -> let (release, namespace, _) = ProjectPlan.chartWorkloadReverseIdentity chart in runChartCleanup cfg (clusterKubeconfigPath cluster) release namespace)
        (\_ _ _ _ _ _ _ -> pure (Right ()))

runChartCleanup :: HostConfig -> FilePath -> Text -> Text -> IO (Either ReconcileError ())
runChartCleanup cfg kubeconfig release namespace = do
    removed <-
        interpretHostCommand
            cfg
            (hostCommand Helm ["--kubeconfig", kubeconfig, "uninstall", Text.unpack release, "--namespace", Text.unpack namespace, "--wait"])
    case classifyHelmUninstall release removed of
        Left reason -> pure (Left (cleanupFailure reason))
        Right () -> do
            absent <-
                interpretHostCommand
                    cfg
                    (hostCommand Helm ["--kubeconfig", kubeconfig, "status", Text.unpack release, "--namespace", Text.unpack namespace])
            pure $ case absent of
                Right captured
                    | capturedExit captured == ExitSuccess -> Left (cleanupFailure "Helm still reports the release after uninstall")
                    | "not found" `isInfixOf` capturedStderr captured -> Right ()
                    | otherwise -> Left (cleanupFailure (Text.pack (capturedStderr captured)))
                Left reason -> Left (cleanupFailure (Text.pack reason))

cleanupFailure :: Text -> ReconcileError
cleanupFailure reason = Failure (FailureDetail "cleanup chart workload" reason ReprobeBeforeRetry)

classifyHelmUninstall :: Text -> Either String CapturedRun -> Either Text ()
classifyHelmUninstall release result = case result of
    Right captured
        | capturedExit captured == ExitSuccess
        , null (capturedStderr captured)
        , ("release \"" <> Text.unpack release <> "\" uninstalled") `isInfixOf` capturedStdout captured ->
            Right ()
        | capturedExit captured /= ExitSuccess
        , "not found" `isInfixOf` capturedStderr captured ->
            Right ()
    _ -> successfulRun result >> Left "Helm returned an unrecognized uninstall result"

classifyHelm :: Text -> Either String CapturedRun -> Either Text (Maybe Bool)
classifyHelm release result = do
    output <- successfulRun result
    let renderedRelease = Text.unpack release
        outputLines = lines output
        installed = "Release \"" <> renderedRelease <> "\" has been installed"
        installing = "Release \"" <> renderedRelease <> "\" does not exist. Installing it now."
        upgraded = "Release \"" <> Text.unpack release <> "\" has been upgraded"
        helmFourInstall =
            all
                (`elem` outputLines)
                [ installing
                , "NAME: " <> renderedRelease
                , "STATUS: deployed"
                , "REVISION: 1"
                , "DESCRIPTION: Install complete"
                ]
    if "no changes" `isInfixOf` output
        then Right Nothing
        else
            if installed `isInfixOf` output || helmFourInstall
                then Right (Just True)
                else
                    if upgraded `isInfixOf` output
                        then Right (Just False)
                        else Left "Helm returned an unrecognized successful result"

successfulRun :: Either String CapturedRun -> Either Text String
successfulRun (Left reason) = Left (Text.pack reason)
successfulRun (Right captured)
    | capturedExit captured /= ExitSuccess = Left (Text.pack (capturedStderr captured))
    | not (null (capturedStderr captured)) = Left "the command wrote stderr on success"
    | otherwise = Right (capturedStdout captured)

-- The object a prepared call owns ---------------------------------------------

{- | Where this run's records live, and the cluster they are about.

Both are derived from the prepared plan-owned package, so no caller supplies a
name, a node, or a directory. Deriving them in one place is what keeps reconcile,
cordon, readiness, and cleanup from coming to disagree about which object they
are each addressing.
-}
data ClusterCallTarget = ClusterCallTarget FilePath Owned.OwnedCluster

{- | Derive that object, or refuse before anything is opened.

The refusals are exactly the ones a name or a path can earn: an unusable cluster
or node name, a state directory or configuration that is not absolute in the
grammar of the process that will read it (§ MM), an embedded NUL, an owner
binding outside its bound, a configuration path and digest that were not retained
together, and a declared node set whose first entry is not the control plane the
cluster's own identity comes from.

What a configuration drift changes is __upstream of here__. The ownership
identity is derived from the plan's own stable snapshot digest, which the
rendered cluster configuration is part of, so a plan whose configuration changed
presents a different identity, mints a different claim, and finds a record it
does not recognize. The digest is therefore checked for shape and carried to the
creating command rather than folded into the binding a second time — and it has
to be, because the later transactions are prepared from packages that declare no
configuration at all and would otherwise derive a different claim for the same
cluster.
-}
clusterCallTarget ::
    -- | the cluster's own name
    String ->
    -- | where this run's protected store lives
    FilePath ->
    -- | every declared node container, control plane first
    [String] ->
    -- | the declared configuration snapshot, where the plan declares one
    Maybe FilePath ->
    -- | that snapshot's digest, retained with it
    Maybe Text ->
    -- | this run's durable ownership identity
    Text ->
    Either ReconcileError ClusterCallTarget
clusterCallTarget name stateDirectory nodes configPath configDigest owner
    | not (safeClusterName name) =
        invalid "cluster name must be a bounded ASCII letter, digit, dot, underscore, or hyphen value"
    | not (isAbsolute stateDirectory) =
        invalid "cluster state directory must be an absolute path"
    | maybe False (not . isAbsolute) configPath =
        invalid "cluster driver config must be an absolute path"
    | '\0' `elem` stateDirectory || maybe False ('\0' `elem`) configPath =
        invalid "cluster identifiers must not contain NUL"
    | Text.null owner || Text.length owner > 2048 || Text.any (== '\0') owner =
        invalid "cluster ownership identity must be non-empty, bounded, and contain no NUL"
    | isJust configPath /= isJust configDigest =
        invalid "cluster config path and digest must be retained together"
    | maybe False (not . validSha256) configDigest =
        invalid "cluster config digest must be a lowercase SHA-256 value"
    | not (all safeClusterName nodes) =
        invalid "every declared cluster node must be a bounded ASCII name"
    | otherwise = case nodes of
        [] -> invalid "the plan declares no cluster node containers"
        (controlPlane : workers)
            | controlPlane /= name <> "-control-plane" ->
                invalid "the first declared node must be the cluster's own control plane"
            | otherwise ->
                Right
                    ( ClusterCallTarget
                        stateDirectory
                        Owned.OwnedCluster
                            { Owned.ownedClusterName = name
                            , Owned.ownedClusterControlPlane = controlPlane
                            , Owned.ownedClusterWorkers = workers
                            , Owned.ownedClusterConfig = configPath
                            , Owned.ownedClusterKubeconfig = stateDirectory </> "cluster.kubeconfig"
                            , Owned.ownedClusterOwner = owner
                            }
                    )
  where
    invalid reason =
        Left (Failure (FailureDetail "validate cluster spec" reason DoNotRetry))

validSha256 :: Text -> Bool
validSha256 digest =
    Text.length digest == 64
        && Text.all (\character -> isDigit character || character >= 'a' && character <= 'f') digest

-- The one transaction shape ----------------------------------------------------

{- | Why a transaction did not produce an answer at all.

Two, because two authorities can refuse before the driver has anything to say:
the protected store, which is where clause 1 and clause 2 live, and the driver
itself, whose refusals carry which clause or which standing they are about.
-}
data ClusterCallFault
    = ClusterCallStore Text
    | ClusterCallOwnership Owned.ClusterOwnershipFault

-- | One rendering, so no observation writes a second description of a refusal.
clusterCallFaultMessage :: ClusterCallFault -> Text
clusterCallFaultMessage (ClusterCallStore reason) = reason
clusterCallFaultMessage (ClusterCallOwnership fault) =
    Owned.clusterOwnershipFaultMessage fault

{- | Run one clause-holding transaction inside this run's own exclusive entry.

Every call below is this function with a different continuation, so the store is
opened once per transaction, the entry covers the whole of it, and no operation
can come to hold a different notion of what its exclusive entry is.
-}
withClusterTransaction ::
    StrongClusterBackend ->
    ClusterCallTarget ->
    ( forall session.
      HostConfig ->
      ProtectedSession session ->
      RecordKey ->
      Owned.OwnedCluster ->
      IO (Either Owned.ClusterOwnershipFault result)
    ) ->
    IO (Either ClusterCallFault result)
withClusterTransaction backend (ClusterCallTarget stateDirectory owned) run = do
    let cfg = strongClusterHostConfig backend
    opened <- openProtectedStore stateDirectory
    case opened of
        Left failure -> pure (Left (storeFault failure))
        Right store -> case Owned.ownedClusterRecordKey owned of
            Left failure -> pure (Left (storeFault failure))
            Right key -> do
                outcome <- withProtectedEntry store (\session -> Right <$> run cfg session key owned)
                pure $ case outcome of
                    Left failure -> Left (storeFault failure)
                    Right (Left fault) -> Left (ClusterCallOwnership fault)
                    Right (Right value) -> Right value
  where
    storeFault = ClusterCallStore . protectedErrorMessage

{- | The container a conflict says took a node's name, where that is what happened.

Clause 4 and the applied cordon both refuse on the same standing, and both owe
their caller the identity that is standing there now rather than a sentence about
it, so the one projection is written here.
-}
replacedIdentity :: ClusterCallFault -> Maybe Text
replacedIdentity (ClusterCallOwnership (Owned.ClusterOwnershipStanding (NodeReplaced _ observed))) =
    Just (identityText observed)
replacedIdentity _ = Nothing

-- | Whether the refusal is "something stands here under no record of this project's".
standsUnderNoRecord :: ClusterCallFault -> Bool
standsUnderNoRecord (ClusterCallOwnership (Owned.ClusterOwnershipStanding ClusterUnderNoRecord)) = True
standsUnderNoRecord _ = False

{- | An identity as the runtime's own reference for it.

The hexadecimal rendering is what a journal carries; what an operator reading a
conflict wants, and what a caller compares against the identity settlement
retained, is the container identifier the runtime answered with.
-}
identityText :: ObjectIdentity -> Text
identityText = Text.pack . containerReference

-- The clause-holding reconcile/cordon/readiness/cleanup calls ------------------

{- | Observe the cluster inside the exclusive entry and, when it is absent, create
it.

The raw observation reports the control-plane node container's immutable
identity. Settlement retains it beside, rather than in place of, the prepared
journal generation, and the durable record binds the same identity so conditional
deletion can compare against it (clauses 2–4).

A cluster this record already owned is asked one further question the creation
path does not need: whether every node container the record bound is still
running. That is a different authority from readiness — the runtime rather than
the API server — and an owned cluster whose containers are stopped is a conflict
an operator resolves rather than something to recreate.
-}
runClusterReconcileCall ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion)
runClusterReconcileCall backend prepared =
    ClusterReconcileCallResult <$> case validateReconcileBinding backend prepared >> reconcileTarget prepared of
        Left err -> pure (ClusterProbeFailed (Text.pack (show err)))
        Right target -> do
            outcome <- withClusterTransaction backend target Owned.reconcileOwnedCluster
            case outcome of
                Left fault
                    | standsUnderNoRecord fault -> pure (ClusterForeign (clusterCallFaultMessage fault))
                    | otherwise -> pure (ClusterProbeFailed (clusterCallFaultMessage fault))
                Right (Owned.ClusterCreated identity) ->
                    pure (ClusterCreated (ClusterBackendBinding (identityText identity)))
                Right (Owned.ClusterRecovered identity) ->
                    pure (ClusterCreated (ClusterBackendBinding (identityText identity)))
                Right (Owned.ClusterAlreadyOwned identity) -> do
                    running <- withClusterTransaction backend target Owned.ownedClusterRunning
                    pure $ case running of
                        Left fault -> ClusterProbeFailed (clusterCallFaultMessage fault)
                        Right False -> ClusterUnhealthy (identityText identity)
                        Right True -> ClusterHealthy (ClusterBackendBinding (identityText identity))

{- | Delete the cluster inside the same exclusive entry, but only while every node
identity the durable record bound is still the one standing there.

A replacement is reported as such and left intact, and no record is forgotten
over it.
-}
runClusterCleanupCall ::
    StrongClusterBackend ->
    PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterCleanupCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
runClusterCleanupCall backend prepared =
    ClusterCleanupCallResult <$> case cleanupTarget prepared of
        Left err -> pure (ClusterCleanupFailed err)
        Right target -> do
            outcome <- withClusterTransaction backend target releaseClusterAfterExposure
            pure $ case outcome of
                Right (Right Owned.ClusterReleased) -> ClusterCleanupRemoved
                Right (Right Owned.ClusterAlreadyReleased) -> ClusterCleanupRemoved
                Right (Right Owned.ClusterStillPresent) ->
                    cleanupRefusal
                        key
                        "the runtime still reports a node container this record bound"
                        ReprobeBeforeRetry
                Right (Left reason) -> cleanupRefusal key reason DoNotRetry
                Left fault -> case replacedIdentity fault of
                    Just identity -> ClusterCleanupReplaced identity
                    Nothing -> cleanupRefusal key (clusterCallFaultMessage fault) ReprobeBeforeRetry
  where
    key = Text.pack (preparedCleanupClusterName prepared)

{- | Release the exact cluster described by a retained lifecycle plan.

The recursive reverse command retains the canonical 'ClusterPlan' but not the
forward action's lexical managed handle.  The ownership store beneath that
plan's durable root is therefore the authority: its claim and bound node
identities are re-read under one protected entry, and only those identities can
reach the destructive driver call.
-}
releaseRetainedCluster :: HostConfig -> ClusterPlan -> IO (Either ReconcileError ())
releaseRetainedCluster cfg plan =
    case clusterNodeNames plan of
        [] -> pure (Left (Failure (FailureDetail "release retained cluster" "the retained cluster plan declares no nodes" DoNotRetry)))
        controlPlane : workers -> do
            let stateDirectory = clusterRuntimeStateDirectory plan
                owned =
                    Owned.OwnedCluster
                        { Owned.ownedClusterName = clusterName plan
                        , Owned.ownedClusterControlPlane = controlPlane
                        , Owned.ownedClusterWorkers = workers
                        , Owned.ownedClusterConfig = clusterConfigFile plan
                        , Owned.ownedClusterKubeconfig = clusterKubeconfigPath plan
                        , Owned.ownedClusterOwner = "retained-record"
                        }
            opened <- openProtectedStore stateDirectory
            case opened of
                Left failure -> pure (Left (Failure (FailureDetail "release retained cluster" (protectedErrorMessage failure) ReprobeBeforeRetry)))
                Right store -> case Owned.ownedClusterRecordKey owned of
                    Left failure -> pure (Left (Failure (FailureDetail "release retained cluster" (protectedErrorMessage failure) DoNotRetry)))
                    Right key -> do
                        outcome <-
                            withProtectedEntry store $ \session ->
                                Right <$> Owned.releaseRetainedOwnedCluster cfg session key owned
                        pure $ case outcome of
                            Left failure -> Left (Failure (FailureDetail "release retained cluster" (protectedErrorMessage failure) ReprobeBeforeRetry))
                            Right (Left fault) -> Left (Failure (FailureDetail "release retained cluster" (Owned.clusterOwnershipFaultMessage fault) ReprobeBeforeRetry))
                            Right (Right Owned.ClusterReleased) -> Right ()
                            Right (Right Owned.ClusterAlreadyReleased) -> Right ()
                            Right (Right Owned.ClusterStillPresent) -> Left (Failure (FailureDetail "release retained cluster" "the runtime still reports an owned node" ReprobeBeforeRetry))

releaseClusterAfterExposure ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    Owned.OwnedCluster ->
    IO (Either Owned.ClusterOwnershipFault (Either Text Owned.ClusterReleaseOutcome))
releaseClusterAfterExposure cfg session key owned =
    case mkRecordKey (Text.pack (Owned.ownedClusterName owned) <> ".exposure") of
        Left failure -> pure (Left (Owned.ClusterOwnershipStore failure))
        Right exposureKey -> do
            exposure <- readProtectedRecord session exposureKey
            case exposure of
                Left failure -> pure (Left (Owned.ClusterOwnershipStore failure))
                Right (Just _) -> pure (Right (Left "the owned exposure relay must be released before the cluster"))
                Right Nothing -> fmap (fmap Right) (Owned.releaseOwnedCluster cfg session key owned)

cleanupRefusal :: Text -> Text -> RecoveryDisposition -> ClusterCleanupObservation
cleanupRefusal key reason disposition =
    ClusterCleanupFailed
        ( Failure
            ( FailureDetail
                "clean up cluster"
                ("the cluster ownership driver refused to delete " <> key <> ": " <> reason)
                disposition
            )
        )

{- | Apply the exact admitted cluster slice only after ownership settlement has
minted cordon authority.

The wall lands on the container identity each durable record bound, never on a
node name, and no caller supplies resource values or node names here: the budget
is the plan's own and the nodes are the ones the record already owns.
-}
runClusterCordonCall ::
    StrongClusterBackend ->
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterCordonCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
runClusterCordonCall backend prepared =
    ClusterCordonCallResult <$> case cordonTarget prepared of
        Left err -> pure (ClusterCordonFailed (Text.pack (show err)))
        Right target -> do
            outcome <- withClusterTransaction backend target (cordonWith budget)
            pure $ case outcome of
                Right _ -> ClusterCordonApplied
                Left fault -> case replacedIdentity fault of
                    Just identity -> ClusterCordonReplaced identity
                    Nothing -> ClusterCordonFailed (clusterCallFaultMessage fault)
  where
    budget = preparedClusterCordonBudget prepared

cordonWith ::
    ResourceBudget ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    Owned.OwnedCluster ->
    IO (Either Owned.ClusterOwnershipFault [String])
cordonWith budget cfg session key owned =
    Owned.cordonOwnedCluster cfg session key owned budget

{- | Ask the live control plane whether this run's own cluster is ready.

Read-only, and versioned: the counter advances only when this call freshly
observed the same managed container identity with the API server and every
declared node reporting ready, so a stale observation cannot be presented as a
fresh one. The retained action reruns exactly this pair and is never projected
publicly.
-}
runClusterReadinessCall ::
    StrongClusterBackend ->
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterReadinessCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
runClusterReadinessCall backend applied = runFresh
  where
    readinessVersion = strongClusterReadinessVersion backend
    expectedIdentity = managedClusterBackendIdentity (appliedClusterCordonHandle applied)

    runFresh = do
        observation <- case readinessTarget applied of
            Left err -> pure (ClusterReadinessProbeFailed (Text.pack (show err)))
            Right target -> do
                outcome <- withClusterTransaction backend target Owned.observeOwnedClusterReadiness
                pure $ case outcome of
                    Left fault -> case replacedIdentity fault of
                        -- A container that took a node's name is not this
                        -- plan's cluster failing to be ready: it is somebody
                        -- else's standing there. Reporting the identity that is
                        -- actually there is what lets settlement tell the two
                        -- apart, because a readiness observation naming an
                        -- identity the record did not bind is a conflict rather
                        -- than a retry.
                        Just other -> ClusterNotReady other
                        Nothing -> ClusterReadinessProbeFailed (clusterCallFaultMessage fault)
                    Right Owned.ClusterReady -> ClusterReady expectedIdentity
                    Right Owned.ClusterApiUnready -> ClusterNotReady expectedIdentity
                    Right Owned.ClusterNodesUnready -> ClusterNotReady expectedIdentity
                    Right Owned.ClusterNodesUndeclared -> ClusterNotReady expectedIdentity
        (version, versionedObservation) <- case observation of
            ClusterReady identity
                | identity == expectedIdentity -> do
                    advanced <- nextReadinessVersion readinessVersion
                    pure $ case advanced of
                        Right fresh -> (fresh, observation)
                        Left reason -> (0, ClusterReadinessProbeFailed reason)
            _ -> pure (0, observation)
        pure (ClusterReadinessCallResult version versionedObservation runFresh)

nextReadinessVersion :: IORef Word64 -> IO (Either Text Word64)
nextReadinessVersion counter =
    atomicModifyIORef' counter $ \current ->
        if current == maxBound
            then (current, Left "the readiness phase-observation version is exhausted")
            else
                let next = current + 1
                 in (next, Right next)

{- | Register one pending cluster-domain commitment and its separately held
fresh-readiness service. Registration is possible only after an already-settled
cordon and readiness witness agree with a fresh backend reprobe.
-}
registerClusterRuntimeDependencyPackage ::
    StrongClusterBackend ->
    StepExecution scope planId ->
    Text ->
    PreparedGate ->
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    ClusterReadiness scope planId clusterId phase ->
    PreparedClusterExposure scope planId clusterId clusterFrame ->
    Text ->
    Word64 ->
    IO (Either ReconcileError (RuntimeDependencyPackage scope planId))
registerClusterRuntimeDependencyPackage backend execution scopeCommitment gate applied readiness preparedExposure route expiry = do
    exposed <- runClusterExposureCall backend preparedExposure
    case exposed of
        Left failure -> pure (Left failure)
        Right settledExposure -> do
            let origin = clusterBackendOrigin backend <> ":" <> exposureSetCommitment settledExposure
            fresh <- reprobeClusterReadiness readiness
            case fresh of
                Left failure -> pure (Left failure)
                Right generation
                    | preparedGatePlan gate /= stepExecutionPlanDigest execution ->
                        pure (dependencyFailure "the producer gate names another plan")
                    | otherwise ->
                        case mkClusterRuntimeDependencyPackage
                            (stepExecutionPlanDigest execution)
                            scopeCommitment
                            resource
                            (stepExecutionFrame execution)
                            origin
                            (managedClusterGeneration handle)
                            (clusterGateCommitment gate)
                            (clusterReadyCommitment generation)
                            route
                            expiry of
                            Left refusal -> pure (dependencyFailure refusal)
                            Right package -> do
                                registered <- registerStepRuntimeDependencyPackage runtime package
                                case registered of
                                    Left refusal -> pure (dependencyFailure refusal)
                                    Right () -> do
                                        usedNonces <- newIORef []
                                        installed <- replaceStepRuntimeDependencyService runtime package $ \request ->
                                            case withRuntimeDependencyExposureRequest package request id of
                                                Right nonce -> consumeNonce usedNonces nonce $ do
                                                    observed <- runClusterExposureCall backend preparedExposure
                                                    pure $ do
                                                        resolved <- either (Left . Text.pack . show) Right observed
                                                        if exposureSetCommitment resolved /= exposureSetCommitment settledExposure
                                                            then Left "cluster runtime exposure identity or mapping changed"
                                                            else renderRuntimeDependencyExposureResponse package nonce (map exposureResponseFields resolved)
                                                Left _ -> case withRuntimeDependencyProbeRequest package request id of
                                                    Left _ -> serveClusterChartRequest backend package request
                                                    Right nonce -> consumeNonce usedNonces nonce $ do
                                                        observed <- runClusterReadinessCall backend applied
                                                        pure $ case clusterReadinessResultView observed of
                                                            ClusterReadinessResultReady version _ ->
                                                                Right (renderRuntimeDependencyProbeResponse package nonce version)
                                                            ClusterReadinessResultNotReady _ -> Left "cluster runtime dependency is not ready"
                                                            ClusterReadinessResultProbeFailed reason -> Left reason
                                        pure $ either dependencyFailure (const (Right package)) installed
  where
    runtime = stepExecutionRuntime execution
    handle = appliedClusterCordonHandle applied
    resource = managedClusterKey handle
    dependencyFailure reason = Left (Failure (FailureDetail "register cluster runtime dependency" reason ReprobeBeforeRetry))

consumeNonce :: IORef [Text] -> Text -> IO (Either Text ByteString.ByteString) -> IO (Either Text ByteString.ByteString)
consumeNonce usedNonces nonce action = do
    replay <- atomicModifyIORef' usedNonces $ \seen ->
        if nonce `elem` seen then (seen, True) else (nonce : seen, False)
    if replay
        then pure (Left "cluster runtime dependency nonce has already been consumed")
        else action

exposureResponseFields :: ResolvedExposure scope planId clusterId service -> (Text, Text, Int, Text, Int, Text, Word64, Text)
exposureResponseFields resolved =
    ( resolvedExposureService resolved
    , resolvedExposureListenAddress resolved
    , resolvedExposureHostPort resolved
    , resolvedExposureTargetHost resolved
    , resolvedExposureTargetPort resolved
    , resolvedExposureRelayIdentity resolved
    , resolvedExposureClusterGeneration resolved
    , resolvedExposureOwnershipOperation resolved
    )

exposureSetCommitment :: [ResolvedExposure scope planId clusterId service] -> Text
exposureSetCommitment = digestText . Text.intercalate "\NUL" . concatMap fields
  where
    fields resolved =
        let (service, address, hostPort, target, targetPort, relay, generation, operation) = exposureResponseFields resolved
         in [service, address, Text.pack (show hostPort), target, Text.pack (show targetPort), relay, Text.pack (show generation), operation]

serveClusterChartRequest ::
    StrongClusterBackend ->
    RuntimeDependencyPackage scope planId ->
    ByteString.ByteString ->
    IO (Either Text ByteString.ByteString)
serveClusterChartRequest backend package request =
    case withRuntimeDependencyChartRequest package request (,,,,,,,) of
        Left refusal -> pure (Left refusal)
        Right (call, artifact, release, namespace, image, deployment, activationRevision, values) -> do
            helm <-
                interpretHostCommand
                    (strongClusterHostConfig backend)
                    ( withCommandStdin
                        (Text.unpack values)
                        ( hostCommand
                            Helm
                            ( [ "--kubeconfig"
                              , strongClusterKubeconfigPath backend
                              , "upgrade"
                              , "--install"
                              , Text.unpack release
                              , Text.unpack artifact
                              , "--namespace"
                              , Text.unpack namespace
                              , "--create-namespace=false"
                              , "--values"
                              , "-"
                              , "--set-string"
                              , "image.identity=" <> Text.unpack image
                              ]
                                <> activationArgs activationRevision
                                <> [ "--rollback-on-failure"
                                   , "--wait"
                                   ]
                            )
                        )
                    )
            case classifyHelm release helm of
                Left reason -> pure (Left reason)
                Right change -> do
                    rollout <-
                        interpretHostCommand
                            (strongClusterHostConfig backend)
                            (hostCommand Kubectl ["--kubeconfig", strongClusterKubeconfigPath backend, "rollout", "status", "--namespace", Text.unpack namespace, "deployment/" <> Text.unpack deployment, "--timeout=5m"])
                    pure $ do
                        _ <- successfulRun rollout
                        renderRuntimeDependencyChartResponse package call $ case change of
                            Nothing -> "unchanged"
                            Just True -> "created"
                            Just False -> "repaired"
  where
    activationArgs revision
        | Text.null revision = []
        | otherwise = ["--set-string", "activation.revision=" <> Text.unpack revision]

{- | Open the exact canonical/live cluster package and reconstruct readiness
only in the supplied continuation after a nonce-bound service observation and
a second fresh backend observation both succeed.
-}
withFreshClusterRuntimeDependency ::
    StepExecution scope planId ->
    Text ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    (forall phase. ClusterReadiness scope planId clusterId phase -> [ResolvedExposure scope planId clusterId ()] -> result) ->
    IO (Either ReconcileError result)
withFreshClusterRuntimeDependency execution scopeCommitment plannedCluster dependencyKey route now nonce consume = do
    packages <- stepRuntimeDependencyPackages runtime
    case filter ((== "cluster:" <> dependencyKey) . runtimeDependencyPackageKey) packages of
        [package] -> do
            carried <- withCarriedManagedResourceOfKind execution plannedCluster $ \handle ->
                case withClusterRuntimeDependencySuccessor
                    (stepExecutionPlanDigest execution)
                    scopeCommitment
                    dependencyKey
                    (stepExecutionFrame execution)
                    (resourceHandleGeneration handle)
                    route
                    now
                    package
                    id of
                    Left refusal -> pure (dependencyFailure refusal)
                    Right _ -> case runtimeDependencyProbeRequest package nonce of
                        Left refusal -> pure (dependencyFailure refusal)
                        Right request -> do
                            response <- invokeStepRuntimeDependencyService runtime package request
                            case response >>= verifyRuntimeDependencyProbeResponse package nonce of
                                Left refusal -> pure (dependencyFailure refusal)
                                Right version -> do
                                    let exposureNonce = nonce <> "-exposure"
                                    case runtimeDependencyExposureRequest package exposureNonce of
                                        Left refusal -> pure (dependencyFailure refusal)
                                        Right exposureRequest -> do
                                            exposureResponse <- invokeStepRuntimeDependencyService runtime package exposureRequest
                                            case exposureResponse >>= verifyRuntimeDependencyExposureResponse package exposureNonce of
                                                Left refusal -> pure (dependencyFailure refusal)
                                                Right fields ->
                                                    case traverse (resolvedExposureFromFields (runtimeDependencyPackageGeneration package)) fields of
                                                        Left refusal -> pure (dependencyFailure refusal)
                                                        Right resolved -> withRecoveredClusterReadiness handle version (\readiness -> consume readiness resolved)
            either (pure . Left) id carried
        [] -> pure (dependencyFailure "the exact cluster package is absent")
        _ -> pure (dependencyFailure "the cluster package registry contains duplicate resource keys")
  where
    runtime = stepExecutionRuntime execution
    dependencyFailure reason = Left (Failure (FailureDetail "recover cluster runtime dependency" reason ReprobeBeforeRetry))

resolvedExposureFromFields ::
    Word64 ->
    (Text, Text, Int, Text, Int, Text, Word64, Text) ->
    Either Text (ResolvedExposure scope planId clusterId ())
resolvedExposureFromFields expectedGeneration (service, address, hostPort, target, targetPort, relay, generation, operation)
    | address /= "127.0.0.1" = Left "cluster runtime exposure is not loopback-bound"
    | generation /= expectedGeneration = Left "cluster runtime exposure generation changed"
    | otherwise = Right (ResolvedExposure service hostPort target targetPort relay generation operation)

clusterBackendOrigin :: StrongClusterBackend -> Text
clusterBackendOrigin backend =
    Text.intercalate
        ":"
        [ Text.pack (show (strongClusterDriver backend))
        , strongClusterConfigDigest backend
        , strongClusterOwnershipIdentity backend
        ]

clusterGateCommitment :: PreparedGate -> Text
clusterGateCommitment gate =
    Text.intercalate
        ":"
        [ preparedGatePlan gate
        , preparedGateOperation gate
        , preparedGateSession gate
        , Text.pack (show (preparedGateFence gate))
        , Text.pack (show (preparedGateAttempt gate))
        , Text.pack (show (preparedGateJournalVersion gate))
        ]

clusterReadyCommitment :: Word64 -> Text
clusterReadyCommitment generation = "ready:" <> Text.pack (show generation)

-- The four targets, each derived from its own prepared package ------------------

reconcileTarget ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    Either ReconcileError ClusterCallTarget
reconcileTarget prepared =
    clusterCallTarget
        (preparedClusterName prepared)
        (preparedClusterStateDirectory prepared)
        (preparedClusterNodeNames prepared)
        (preparedClusterConfigPath prepared)
        (preparedClusterConfigDigest prepared)
        (preparedClusterOwnershipIdentity prepared)

cordonTarget ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError ClusterCallTarget
cordonTarget prepared =
    clusterCallTarget
        (preparedClusterCordonName prepared)
        (preparedClusterCordonStateDirectory prepared)
        (preparedClusterCordonNodeNames prepared)
        Nothing
        Nothing
        (preparedClusterCordonOwnershipIdentity prepared)

cleanupTarget ::
    PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError ClusterCallTarget
cleanupTarget prepared =
    clusterCallTarget
        (preparedCleanupClusterName prepared)
        (preparedCleanupStateDirectory prepared)
        (preparedCleanupNodeNames prepared)
        Nothing
        Nothing
        (preparedCleanupOwnershipIdentity prepared)

readinessTarget ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError ClusterCallTarget
readinessTarget applied =
    clusterCallTarget
        (appliedClusterCordonName applied)
        (appliedClusterCordonStateDirectory applied)
        (appliedClusterCordonNodeNames applied)
        Nothing
        Nothing
        (appliedClusterCordonOwnershipIdentity applied)

-- The read-only status path -----------------------------------------------------

-- | Read-only status returned by the exact plan-owned status path.
data ClusterStatusObservation
    = ClusterStatusPresent
    | ClusterStatusAbsent
    | ClusterStatusProbeFailed Text
    deriving (Eq, Show)

{- | Ask the cluster driver which clusters it names, and decide from the answer.

Read-only, and outside every ownership clause, because it mutates nothing: one
described command through the one interpreter and one total classification of
what came back.
-}
runClusterStatusCall ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO ClusterStatusObservation
runClusterStatusCall backend prepared =
    case validateReconcileBinding backend prepared of
        Left err -> pure (ClusterStatusProbeFailed (Text.pack (show err)))
        Right () ->
            classifyClusterStatus (preparedClusterName prepared)
                <$> interpretHostCommand (strongClusterHostConfig backend) listClustersCommand

validateReconcileBinding ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    Either ReconcileError ()
validateReconcileBinding backend prepared
    | strongClusterDriver backend /= preparedClusterDriver prepared = mismatch "the prepared cluster driver differs from backend discovery"
    | strongClusterConfigBytes backend /= preparedClusterConfigBytes prepared = mismatch "the prepared canonical config bytes differ from backend discovery"
    | Just (strongClusterConfigDigest backend) /= preparedClusterConfigDigest prepared = mismatch "the prepared config digest differs from backend discovery"
    | strongClusterOwnershipIdentity backend /= preparedClusterOwnershipIdentity prepared = mismatch "the prepared ownership identity differs from backend discovery"
    | otherwise = Right ()
  where
    mismatch reason = Left (Conflict (ConflictDetail (Text.pack (preparedClusterName prepared)) "discovered backend package" "changed prepared package" reason))

{- | What the driver's listing says about one cluster, as a total function of it.

Narrow on purpose, because a listing is another program's output. The refusals
are the cluster report vocabulary's own — a command that produced no child, a
non-zero exit, anything at all on standard error, a body that does not end in
exactly one newline, a carriage return, a byte outside ASCII, an empty row, a
name outside the portable alphabet, and the same name listed twice — and this is
one projection of them rather than a second copy. Telling "the driver says this
cluster is not here" apart from "the driver did not answer" is the whole point:
the first authorizes creation and the second must not.
-}
classifyClusterStatus :: String -> Either String CapturedRun -> ClusterStatusObservation
classifyClusterStatus name captured = case classifyClusterListing name captured of
    Left fault -> ClusterStatusProbeFailed (clusterReportFaultMessage fault)
    Right ClusterPresent -> ClusterStatusPresent
    Right ClusterAbsent -> ClusterStatusAbsent

-- Runtime-owned loopback exposure --------------------------------------------

mkExposureIntent :: Text -> Text -> Int -> Either ReconcileError ExposureIntent
mkExposureIntent service target port =
    case mkPlanExposureIntent service target port of
        Left refusal -> Left (Failure (FailureDetail "validate cluster exposure intent" (Text.pack (show refusal)) DoNotRetry))
        Right intent -> Right intent

-- | Exact exposure work derived from one already-cordoned cluster package.
data PreparedClusterExposure scope planId clusterId clusterFrame = PreparedClusterExposure
    { preparedExposureKey :: Text
    , preparedExposureClusterName :: String
    , preparedExposureStateDirectory :: FilePath
    , preparedExposureNodeNames :: [String]
    , preparedExposureOwner :: Text
    , preparedExposureClusterIdentity :: Text
    , preparedExposureGeneration :: Word64
    , preparedExposureImage :: Text
    , preparedExposureIntents :: [ExposureIntent]
    }

withPreparedClusterExposure ::
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Text ->
    [ExposureIntent] ->
    (PreparedClusterExposure scope planId clusterId clusterFrame -> result) ->
    Either ReconcileError result
withPreparedClusterExposure applied image intents consume
    | not (immutableImage image) = invalid "relay image must be an immutable repository@sha256 or sha256 image identity"
    | null intents = invalid "at least one service exposure is required"
    | length intents > maxExposureCount = invalid "too many service exposures"
    | not (distinct (map exposureIntentService intents)) = invalid "service identities must be distinct"
    | otherwise =
        Right
            ( consume
                PreparedClusterExposure
                    { preparedExposureKey = managedClusterKey handle
                    , preparedExposureClusterName = appliedClusterCordonName applied
                    , preparedExposureStateDirectory = appliedClusterCordonStateDirectory applied
                    , preparedExposureNodeNames = appliedClusterCordonNodeNames applied
                    , preparedExposureOwner = appliedClusterCordonOwnershipIdentity applied
                    , preparedExposureClusterIdentity = managedClusterBackendIdentity handle
                    , preparedExposureGeneration = managedClusterGeneration handle
                    , preparedExposureImage = image
                    , preparedExposureIntents = intents
                    }
            )
  where
    handle = appliedClusterCordonHandle applied
    invalid reason = Left (Failure (FailureDetail "prepare cluster exposure" reason DoNotRetry))

{- | A runtime-inspected mapping.  Its constructor is private: only a successful
exact relay inspection can mint the value.
-}
data ResolvedExposure scope planId clusterId service
    = ResolvedExposure
        Text
        Int
        Text
        Int
        Text
        Word64
        Text

withResolvedExposure ::
    Text ->
    [ResolvedExposure scope planId clusterId seed] ->
    (forall service. ResolvedExposure scope planId clusterId service -> result) ->
    Either ReconcileError result
withResolvedExposure service resolved consume =
    case filter ((== service) . resolvedExposureService) resolved of
        [ResolvedExposure name hostPort target targetPort relay generation operation] ->
            Right (consume (ResolvedExposure name hostPort target targetPort relay generation operation))
        [] -> exposureFailure "open resolved cluster exposure" "the requested service is absent" DoNotRetry
        _ -> exposureFailure "open resolved cluster exposure" "the requested service is duplicated" DoNotRetry

resolvedExposureService :: ResolvedExposure scope planId clusterId service -> Text
resolvedExposureService (ResolvedExposure service _ _ _ _ _ _) = service

resolvedExposureListenAddress :: ResolvedExposure scope planId clusterId service -> Text
resolvedExposureListenAddress _ = "127.0.0.1"

resolvedExposureHostPort :: ResolvedExposure scope planId clusterId service -> Int
resolvedExposureHostPort (ResolvedExposure _ port _ _ _ _ _) = port

resolvedExposureTargetHost :: ResolvedExposure scope planId clusterId service -> Text
resolvedExposureTargetHost (ResolvedExposure _ _ target _ _ _ _) = target

resolvedExposureTargetPort :: ResolvedExposure scope planId clusterId service -> Int
resolvedExposureTargetPort (ResolvedExposure _ _ _ port _ _ _) = port

resolvedExposureRelayIdentity :: ResolvedExposure scope planId clusterId service -> Text
resolvedExposureRelayIdentity (ResolvedExposure _ _ _ _ relay _ _) = relay

resolvedExposureClusterGeneration :: ResolvedExposure scope planId clusterId service -> Word64
resolvedExposureClusterGeneration (ResolvedExposure _ _ _ _ _ generation _) = generation

resolvedExposureOwnershipOperation :: ResolvedExposure scope planId clusterId service -> Text
resolvedExposureOwnershipOperation (ResolvedExposure _ _ _ _ _ _ operation) = operation

data ExposureRecord
    = ExposurePending Text Text Text
    | ExposureManaged Text Text Text Text [(Text, Int, Int)]
    deriving (Eq, Read, Show)

data RelayObservation = RelayObservation Text Text Text Text Word64 Text Text [(Int, Text, Int)]

{- | One loopback port minted only after the durable managed-exposure record and
its Docker relay have been re-observed together.

The constructor stays private: a caller can consume the port, but cannot turn a
number obtained from configuration or an earlier invocation into a successful
observation.
-}
newtype RecordedClusterExposure = RecordedClusterExposure Int
    deriving (Eq, Show)

recordedClusterExposureHostPort :: RecordedClusterExposure -> Int
recordedClusterExposureHostPort (RecordedClusterExposure hostPort) = hostPort

runClusterExposureCall ::
    StrongClusterBackend ->
    PreparedClusterExposure scope planId clusterId clusterFrame ->
    IO (Either ReconcileError [ResolvedExposure scope planId clusterId ()])
runClusterExposureCall backend prepared = do
    case exposureTarget prepared of
        Left refusal -> pure (Left refusal)
        Right target -> do
            transacted <- withClusterTransaction backend target $ \cfg session _ owned -> do
                case ownedKey owned of
                    Left fault -> pure (Left fault)
                    Right key -> do
                        standing <- Owned.ownedClusterNodes cfg session key owned
                        case standing of
                            Left fault -> pure (Left fault)
                            Right [] -> pure (Right (exposureConflict prepared "the cluster has no owned node identity"))
                            Right (controlPlane : _)
                                | identityText (third controlPlane) /= preparedExposureClusterIdentity prepared ->
                                    pure (Right (exposureConflict prepared "the cluster identity differs from the exposure package"))
                            Right _ -> Right <$> reconcileExposure cfg session prepared
            pure $ case transacted of
                Left fault -> exposureFailure "reconcile cluster exposure" (clusterCallFaultMessage fault) ReprobeBeforeRetry
                Right result -> result
  where
    third (_, _, value) = value
    ownedKey owned = case Owned.ownedClusterRecordKey owned of
        Left failure -> Left (Owned.ClusterOwnershipStore failure)
        Right key -> Right key

releaseClusterExposureCall ::
    StrongClusterBackend ->
    PreparedClusterExposure scope planId clusterId clusterFrame ->
    IO (Either ReconcileError ())
releaseClusterExposureCall backend prepared =
    case exposureTarget prepared of
        Left refusal -> pure (Left refusal)
        Right target -> do
            transacted <- withClusterTransaction backend target $ \cfg session _ _ ->
                Right <$> releaseExposure cfg session prepared
            pure $ case transacted of
                Left fault -> exposureFailure "release cluster exposure" (clusterCallFaultMessage fault) ReprobeBeforeRetry
                Right result -> result

{- | Re-open one exact service from a durable exposure row.

This is deliberately read-only. The protected entry gives the record a stable
read interval, and 'openRecordedRelay' then checks the recorded name, immutable
identity, operation, specification, and complete loopback mapping set against
Docker. Only a managed record with one exact service row can mint the result.
-}
observeRecordedClusterExposure ::
    HostConfig ->
    FilePath ->
    String ->
    Text ->
    IO (Either ReconcileError RecordedClusterExposure)
observeRecordedClusterExposure cfg stateDirectory name service
    | not (isAbsolute stateDirectory) = pure (invalid "the cluster state directory is not absolute")
    | '\0' `elem` stateDirectory = pure (invalid "the cluster state directory contains NUL")
    | not (safeClusterName name) = pure (invalid "the cluster name is outside the portable alphabet")
    | not (validExposureService service) = pure (invalid "the service identity is invalid or unbounded")
    | otherwise = do
        opened <- openProtectedStore stateDirectory
        case opened of
            Left failure -> pure (storeExposureFailure operation failure)
            Right store -> case mkRecordKey (Text.pack name <> ".exposure") of
                Left failure -> pure (storeExposureFailure operation failure)
                Right key -> do
                    observed <- withProtectedEntry store (\session -> Right <$> readRecorded session key)
                    pure $ case observed of
                        Left failure -> storeExposureFailure operation failure
                        Right result -> result
  where
    operation = "observe recorded cluster exposure"
    invalid reason = exposureFailure operation reason DoNotRetry
    readRecorded session key = do
        readBack <- readProtectedRecord session key
        case readBack of
            Left failure -> pure (storeExposureFailure operation failure)
            Right Nothing -> pure (exposureFailure operation "the exact exposure record is absent" ReprobeBeforeRetry)
            Right (Just protected) -> case parseExposureRecord (protectedRecordBytes protected) of
                Left reason -> pure (invalid reason)
                Right (ExposurePending _ _ _) -> pure (exposureFailure operation "the exact exposure is still pending" ReprobeBeforeRetry)
                Right record@(ExposureManaged digest nonce recordedName identity mappings)
                    | not (validManagedExposureRecord digest nonce recordedName identity mappings) ->
                        pure (invalid "the managed exposure record contains invalid fields")
                    | not (distinct (map firstOfThree mappings)) ->
                        pure (invalid "the managed exposure record duplicates a service identity")
                    | otherwise -> do
                        relay <- openRecordedRelay operation cfg record
                        pure $ case relay of
                            Left refusal -> Left refusal
                            Right Nothing -> exposureFailure operation "the exact exposure relay is absent" ReprobeBeforeRetry
                            Right (Just _) -> case [hostPort | (candidate, _, hostPort) <- mappings, candidate == service] of
                                [hostPort] -> Right (RecordedClusterExposure hostPort)
                                [] -> exposureFailure operation "the requested service is absent" DoNotRetry
                                _ -> exposureFailure operation "the requested service is duplicated" DoNotRetry

    firstOfThree (value, _, _) = value

{- | Release the exact durable exposure record before compatibility cluster
teardown. The record, immutable relay identity, nonce-bound labels, and exact
loopback mapping set provide the four ownership clauses; no caller supplies a
container name or port.
-}
releaseRecordedClusterExposure :: HostConfig -> ClusterPlan -> IO (Either ReconcileError ())
releaseRecordedClusterExposure cfg plan = do
    opened <- openProtectedStore stateDirectory
    case opened of
        Left failure -> pure (storeExposureFailure "open recorded exposure store" failure)
        Right store -> case mkRecordKey (Text.pack (clusterName plan) <> ".exposure") of
            Left failure -> pure (storeExposureFailure "open recorded exposure record" failure)
            Right key -> do
                released <- withProtectedEntry store (\session -> Right <$> releaseRecorded session key)
                pure $ case released of
                    Left failure -> storeExposureFailure "lock recorded exposure" failure
                    Right result -> result
  where
    driverName = case clusterDriver plan of
        KindDriver -> "kind"
        NvkindDriver -> "nvkind"
    stateDirectory = dataPath plan </> "cluster" </> driverName </> "state"
    releaseRecorded session key = do
        observed <- readProtectedRecord session key
        case observed of
            Left failure -> pure (storeExposureFailure "read recorded exposure" failure)
            Right Nothing -> pure (Right ())
            Right (Just protected) -> case parseExposureRecord (protectedRecordBytes protected) of
                Left reason -> pure (recordedConflict reason)
                Right record -> do
                    openedRelay <- openRecordedRelay "release recorded cluster exposure" cfg record
                    case openedRelay of
                        Left refusal -> pure (Left refusal)
                        Right Nothing -> forget session key protected
                        Right (Just identity) -> do
                            removed <- successfulCommand cfg (hostCommand Docker ["container", "rm", "--force", Text.unpack identity])
                            case removed of
                                Left refusal -> pure (Left refusal)
                                Right output
                                    | output /= Text.unpack identity <> "\n" -> pure (exposureFailure "remove recorded exposure relay" "the runtime returned an unexpected removal report" ReprobeBeforeRetry)
                                    | otherwise -> do
                                        remaining <- listRelayByIdentity cfg identity
                                        case remaining of
                                            Left refusal -> pure (Left refusal)
                                            Right True -> pure (recordedConflict "the relay identity remains after removal")
                                            Right False -> forget session key protected
    forget session key protected = do
        deleted <- compareAndDeleteProtectedRecord session key (ExpectVersion (protectedRecordVersion protected))
        pure (either (storeExposureFailure "forget recorded exposure") (const (Right ())) deleted)
    recordedConflict reason =
        exposureFailure "release recorded cluster exposure" (Text.pack (clusterName plan) <> ": " <> reason) DoNotRetry

openRecordedRelay :: Text -> HostConfig -> ExposureRecord -> IO (Either ReconcileError (Maybe Text))
openRecordedRelay operationName cfg record = do
    let (digest, nonce, name, expectedIdentity, expectedMappings) = case record of
            ExposurePending spec operation recordedName -> (spec, operation, recordedName, Nothing, Nothing)
            ExposureManaged spec operation recordedName identity mappings -> (spec, operation, recordedName, Just identity, Just [(listener, hostPort) | (_, listener, hostPort) <- mappings])
    named <- listRelayByName cfg name
    case (named, expectedIdentity) of
        (Left refusal, _) -> pure (Left refusal)
        (Right Nothing, Nothing) -> pure (Right Nothing)
        (Right Nothing, Just identity) -> do
            present <- listRelayByIdentity cfg identity
            case present of
                Left refusal -> pure (Left refusal)
                Right False -> pure (Right Nothing)
                Right True -> verify digest nonce name identity expectedMappings
        (Right (Just identity), Nothing) -> verify digest nonce name identity expectedMappings
        (Right (Just actual), Just expected)
            | actual /= expected -> pure (recordedRelayConflict "another relay stands at the recorded name")
            | otherwise -> verify digest nonce name expected expectedMappings
  where
    verify digest nonce name identity expectedMappings = do
        inspected <- successfulCommand cfg (hostCommand Docker ["inspect", "--format", relayInspectionTemplate, Text.unpack identity])
        pure $ do
            output <- inspected
            case lines output of
                [actualIdentity, rawName, owner, cluster, generation, operation, spec, ports]
                    | Text.pack actualIdentity /= identity -> recordedRelayConflict "the inspected relay identity changed"
                    | Text.pack rawName /= "/" <> name -> recordedRelayConflict "the inspected relay name changed"
                    | null owner || null cluster || readMaybe generation == (Nothing :: Maybe Word64) -> recordedRelayConflict "the inspected relay ownership labels are malformed"
                    | Text.pack operation /= nonce -> recordedRelayConflict "the inspected relay operation changed"
                    | Text.pack spec /= digest -> recordedRelayConflict "the inspected relay specification changed"
                    | otherwise -> do
                        mappings <- parseRecordedPortBindings operationName (TextEncoding.encodeUtf8 (Text.pack ports))
                        case expectedMappings of
                            Just expected | sort expected /= sort mappings -> recordedRelayConflict "the inspected relay mapping set changed"
                            _ -> Right (Just identity)
                _ -> recordedRelayConflict "the runtime returned malformed relay metadata"
    recordedRelayConflict reason = exposureFailure operationName reason DoNotRetry

parseRecordedPortBindings :: Text -> ByteString.ByteString -> Either ReconcileError [(Int, Int)]
parseRecordedPortBindings operationName raw = case eitherDecodeStrict' raw of
    Right (Object ports) -> traverse parseOne (AesonKeyMap.toList ports)
    _ -> exposureFailure operationName "the runtime returned malformed port JSON" ReprobeBeforeRetry
  where
    parseOne (key, Array bindings)
        | Just listenerText <- Text.stripSuffix "/tcp" (AesonKey.toText key)
        , Just listener <- readMaybe (Text.unpack listenerText)
        , [Object binding] <- toList bindings
        , Just (String address) <- AesonKeyMap.lookup "HostIp" binding
        , Just (String portText) <- AesonKeyMap.lookup "HostPort" binding
        , Just hostPort <- readMaybe (Text.unpack portText)
        , address == "127.0.0.1"
        , validPort listener
        , validPort hostPort =
            Right (listener, hostPort)
    parseOne _ = exposureFailure operationName "the runtime returned a wildcard, duplicate, absent, or malformed relay binding" ReprobeBeforeRetry

reconcileExposure ::
    HostConfig ->
    ProtectedSession session ->
    PreparedClusterExposure scope planId clusterId clusterFrame ->
    IO (Either ReconcileError [ResolvedExposure scope planId clusterId ()])
reconcileExposure cfg session prepared = do
    keyed <- pure (exposureRecordKey prepared)
    case keyed of
        Left failure -> pure (storeExposureFailure "open exposure record" failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (storeExposureFailure "read exposure record" failure)
                Right Nothing -> beginExposure cfg session key prepared
                Right (Just record) -> resumeExposure cfg session key record prepared

beginExposure :: HostConfig -> ProtectedSession session -> RecordKey -> PreparedClusterExposure scope planId clusterId clusterFrame -> IO (Either ReconcileError [ResolvedExposure scope planId clusterId ()])
beginExposure cfg session key prepared = do
    nonce <- nonceText <$> (getRandomBytes 32 :: IO ByteString.ByteString)
    let name = relayName prepared nonce
        pending = ExposurePending (exposureSpecDigest prepared) nonce name
    published <- compareAndSwapProtectedRecord session key ExpectAbsent (renderExposureRecord pending)
    case published of
        Left failure -> pure (storeExposureFailure "publish pending exposure" failure)
        Right version -> realizeExposure cfg session key version prepared pending

resumeExposure :: HostConfig -> ProtectedSession session -> RecordKey -> ProtectedRecord -> PreparedClusterExposure scope planId clusterId clusterFrame -> IO (Either ReconcileError [ResolvedExposure scope planId clusterId ()])
resumeExposure cfg session key protected prepared =
    case parseExposureRecord (protectedRecordBytes protected) of
        Left reason -> pure (exposureConflict prepared reason)
        Right pending@(ExposurePending digest nonce name)
            | digest /= exposureSpecDigest prepared || name /= relayName prepared nonce -> pure (exposureConflict prepared "the pending exposure record names another operation")
            | otherwise -> realizeExposure cfg session key (protectedRecordVersion protected) prepared pending
        Right managed@(ExposureManaged digest nonce name _ _)
            | digest /= exposureSpecDigest prepared || name /= relayName prepared nonce -> pure (exposureConflict prepared "the managed exposure record names another operation")
            | otherwise -> inspectManagedExposure cfg prepared managed

realizeExposure :: HostConfig -> ProtectedSession session -> RecordKey -> RecordVersion -> PreparedClusterExposure scope planId clusterId clusterFrame -> ExposureRecord -> IO (Either ReconcileError [ResolvedExposure scope planId clusterId ()])
realizeExposure cfg session key version prepared (ExposurePending _ nonce name) = do
    listed <- listRelayByName cfg name
    identity <- case listed of
        Left refusal -> pure (Left refusal)
        Right Nothing -> createRelay cfg prepared nonce name
        Right (Just existing) -> pure (Right existing)
    case identity of
        Left refusal -> pure (Left refusal)
        Right relay -> do
            inspected <- inspectRelay cfg prepared nonce name relay
            case inspected of
                Left refusal -> pure (Left refusal)
                Right observation -> do
                    let mappings = observationRecordMappings prepared observation
                        managed = ExposureManaged (exposureSpecDigest prepared) nonce name relay mappings
                    settled <- compareAndSwapProtectedRecord session key (ExpectVersion version) (renderExposureRecord managed)
                    case settled of
                        Left failure -> pure (storeExposureFailure "bind managed exposure" failure)
                        Right _ -> inspectManagedExposure cfg prepared managed
realizeExposure _ _ _ _ prepared _ = pure (exposureConflict prepared "an impossible managed record reached pending realization")

inspectManagedExposure :: HostConfig -> PreparedClusterExposure scope planId clusterId clusterFrame -> ExposureRecord -> IO (Either ReconcileError [ResolvedExposure scope planId clusterId ()])
inspectManagedExposure cfg prepared (ExposureManaged _ nonce name expectedIdentity expectedMappings) = do
    listed <- listRelayByName cfg name
    case listed of
        Left refusal -> pure (Left refusal)
        Right Nothing -> pure (exposureConflict prepared "the owned exposure relay is absent")
        Right (Just identity)
            | identity /= expectedIdentity -> pure (exposureConflict prepared "another relay stands at the owned relay name")
            | otherwise -> do
                inspected <- inspectRelay cfg prepared nonce name expectedIdentity
                pure $ do
                    observation <- inspected
                    if observationRecordMappings prepared observation /= expectedMappings
                        then exposureConflict prepared "the relay mapping set differs from its durable ownership record"
                        else resolvedSet prepared observation
inspectManagedExposure _ prepared _ = pure (exposureConflict prepared "a pending record cannot be opened as managed exposure")

releaseExposure :: HostConfig -> ProtectedSession session -> PreparedClusterExposure scope planId clusterId clusterFrame -> IO (Either ReconcileError ())
releaseExposure cfg session prepared = case exposureRecordKey prepared of
    Left failure -> pure (storeExposureFailure "open exposure record" failure)
    Right key -> do
        readBack <- readProtectedRecord session key
        case readBack of
            Left failure -> pure (storeExposureFailure "read exposure record" failure)
            Right Nothing -> pure (Right ())
            Right (Just protected) -> case parseExposureRecord (protectedRecordBytes protected) of
                Left reason -> pure (exposureConflict prepared reason)
                Right record -> do
                    opened <- openRecordForRelease cfg prepared record
                    case opened of
                        Left refusal -> pure (Left refusal)
                        Right Nothing -> forget key protected
                        Right (Just identity) -> do
                            removed <- successfulCommand cfg (hostCommand Docker ["container", "rm", "--force", Text.unpack identity])
                            case removed of
                                Left refusal -> pure (Left refusal)
                                Right output
                                    | output /= Text.unpack identity <> "\n" -> pure (exposureFailure "remove exposure relay" "the runtime returned an unexpected removal report" ReprobeBeforeRetry)
                                    | otherwise -> do
                                        absent <- listRelayByIdentity cfg identity
                                        case absent of
                                            Left refusal -> pure (Left refusal)
                                            Right True -> pure (exposureConflict prepared "the relay identity remains after removal")
                                            Right False -> forget key protected
  where
    forget key protected = do
        deleted <- compareAndDeleteProtectedRecord session key (ExpectVersion (protectedRecordVersion protected))
        pure (either (storeExposureFailure "forget released exposure") (const (Right ())) deleted)

openRecordForRelease :: HostConfig -> PreparedClusterExposure scope planId clusterId clusterFrame -> ExposureRecord -> IO (Either ReconcileError (Maybe Text))
openRecordForRelease cfg prepared record = case record of
    ExposurePending digest nonce name
        | digest /= exposureSpecDigest prepared || name /= relayName prepared nonce -> pure (exposureConflict prepared "the pending exposure record names another operation")
        | otherwise -> do
            listed <- listRelayByName cfg name
            case listed of
                Left refusal -> pure (Left refusal)
                Right Nothing -> pure (Right Nothing)
                Right (Just identity) -> fmap (fmap (const (Just identity))) (inspectRelay cfg prepared nonce name identity)
    ExposureManaged digest nonce name identity mappings
        | digest /= exposureSpecDigest prepared || name /= relayName prepared nonce -> pure (exposureConflict prepared "the managed exposure record names another operation")
        | otherwise -> do
            named <- listRelayByName cfg name
            case named of
                Left refusal -> pure (Left refusal)
                Right (Just current)
                    | current /= identity -> pure (exposureConflict prepared "another relay stands at the owned relay name")
                    | otherwise -> verifyManaged
                Right Nothing -> do
                    present <- listRelayByIdentity cfg identity
                    case present of
                        Left refusal -> pure (Left refusal)
                        Right False -> pure (Right Nothing)
                        Right True -> verifyManaged
      where
        verifyManaged = do
            inspected <- inspectRelay cfg prepared nonce name identity
            pure $ do
                observation <- inspected
                if observationRecordMappings prepared observation == mappings
                    then Right (Just identity)
                    else exposureConflict prepared "the relay mappings changed before release"

createRelay :: HostConfig -> PreparedClusterExposure scope planId clusterId clusterFrame -> Text -> Text -> IO (Either ReconcileError Text)
createRelay cfg prepared nonce name = do
    outcome <- successfulCommand cfg (hostCommand Docker arguments)
    pure $ do
        output <- outcome
        identity <- exactIdentityLine "create exposure relay" output
        Right identity
  where
    arguments =
        ["container", "run", "--detach", "--name", Text.unpack name]
            <> concatMap (\(key, value) -> ["--label", Text.unpack key <> "=" <> Text.unpack value]) (relayLabels prepared nonce)
            <> ["--network", "kind"]
            <> concatMap (\(_, listener, _) -> ["--publish", "127.0.0.1::" <> show listener <> "/tcp"]) (intentBindings prepared)
            <> [Text.unpack (preparedExposureImage prepared), exposureRelayMarker]
            <> concatMap renderIntent (intentBindings prepared)
    renderIntent (intent, listener, _) =
        [ Text.unpack (exposureIntentService intent)
        , show listener
        , Text.unpack (exposureIntentTargetHost intent)
        , show (exposureIntentTargetPort intent)
        ]

inspectRelay :: HostConfig -> PreparedClusterExposure scope planId clusterId clusterFrame -> Text -> Text -> Text -> IO (Either ReconcileError RelayObservation)
inspectRelay cfg prepared nonce expectedName expectedIdentity = do
    outcome <- successfulCommand cfg (hostCommand Docker ["inspect", "--format", relayInspectionTemplate, Text.unpack expectedIdentity])
    pure $ outcome >>= classifyRelayInspection prepared nonce expectedName expectedIdentity

relayInspectionTemplate :: String
relayInspectionTemplate = intercalate "{{\"\\n\"}}" ["{{.Id}}", "{{.Name}}", label "owner", label "cluster", label "generation", label "operation", label "spec", "{{json .NetworkSettings.Ports}}"]
  where
    label name = "{{index .Config.Labels \"io.hostbootstrap." <> name <> "\"}}"

classifyRelayInspection :: PreparedClusterExposure scope planId clusterId clusterFrame -> Text -> Text -> Text -> String -> Either ReconcileError RelayObservation
classifyRelayInspection prepared nonce expectedName expectedIdentity output = case lines output of
    [identity, rawName, owner, cluster, generation, operation, spec, ports]
        | Text.pack identity /= expectedIdentity -> exposureConflict prepared "the inspected relay identity changed"
        | Text.pack rawName /= "/" <> expectedName -> exposureConflict prepared "the inspected relay name changed"
        | Text.pack owner /= ownerDigest prepared -> exposureConflict prepared "the inspected relay owner changed"
        | Text.pack cluster /= preparedExposureKey prepared -> exposureConflict prepared "the inspected relay cluster changed"
        | readMaybe generation /= Just (preparedExposureGeneration prepared) -> exposureConflict prepared "the inspected relay generation changed"
        | Text.pack operation /= nonce -> exposureConflict prepared "the inspected relay operation changed"
        | Text.pack spec /= exposureSpecDigest prepared -> exposureConflict prepared "the inspected relay specification changed"
        | otherwise -> do
            mappings <- parsePortBindings prepared (TextEncoding.encodeUtf8 (Text.pack ports))
            Right (RelayObservation expectedIdentity expectedName (Text.pack owner) (Text.pack cluster) (preparedExposureGeneration prepared) nonce (Text.pack spec) mappings)
    _ -> exposureFailure "inspect exposure relay" "the runtime returned malformed relay metadata" ReprobeBeforeRetry

parsePortBindings :: PreparedClusterExposure scope planId clusterId clusterFrame -> ByteString.ByteString -> Either ReconcileError [(Int, Text, Int)]
parsePortBindings prepared raw = case eitherDecodeStrict' raw of
    Left _ -> exposureFailure "inspect exposure relay" "the runtime returned malformed port JSON" ReprobeBeforeRetry
    Right (Object ports)
        | AesonKeyMap.size ports /= length expected -> exposureConflict prepared "the runtime returned a missing or additional relay mapping"
        | otherwise -> traverse (parseOne ports) expected
    Right _ -> exposureFailure "inspect exposure relay" "the runtime returned a non-object port mapping" ReprobeBeforeRetry
  where
    expected = [(listener, exposureIntentService intent) | (intent, listener, _) <- intentBindings prepared]
    parseOne ports (listener, _) = case AesonKeyMap.lookup (AesonKey.fromString (show listener <> "/tcp")) ports of
        Just (Array bindings)
            | [Object binding] <- toList bindings
            , Just (String address) <- AesonKeyMap.lookup "HostIp" binding
            , Just (String portText) <- AesonKeyMap.lookup "HostPort" binding
            , Just hostPort <- readMaybe (Text.unpack portText)
            , address == "127.0.0.1"
            , validPort hostPort ->
                Right (listener, address, hostPort)
        _ -> exposureConflict prepared "the runtime returned a wildcard, duplicate, absent, or malformed relay binding"

listRelayByName :: HostConfig -> Text -> IO (Either ReconcileError (Maybe Text))
listRelayByName cfg name = do
    outcome <- successfulCommand cfg (hostCommand Docker ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", "name=^/" <> Text.unpack name <> "$"])
    pure $ outcome >>= optionalIdentityLines "find exposure relay"

listRelayByIdentity :: HostConfig -> Text -> IO (Either ReconcileError Bool)
listRelayByIdentity cfg identity = do
    outcome <- successfulCommand cfg (hostCommand Docker ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", "id=" <> Text.unpack identity])
    pure $ do
        found <- outcome >>= optionalIdentityLines "find exposure relay identity"
        case found of
            Nothing -> Right False
            Just exact
                | exact == identity -> Right True
                | otherwise -> exposureFailure "find exposure relay identity" "the runtime returned another identity" ReprobeBeforeRetry

optionalIdentityLines :: Text -> String -> Either ReconcileError (Maybe Text)
optionalIdentityLines _ "" = Right Nothing
optionalIdentityLines operation output = Just <$> exactIdentityLine operation output

exactIdentityLine :: Text -> String -> Either ReconcileError Text
exactIdentityLine operation output = case lines output of
    [identity]
        | length identity == 64 && all lowerHex identity && output == identity <> "\n" -> Right (Text.pack identity)
    _ -> exposureFailure operation "the runtime returned a malformed or ambiguous container identity" ReprobeBeforeRetry

successfulCommand :: HostConfig -> HostCommand -> IO (Either ReconcileError String)
successfulCommand cfg command = do
    outcome <- successfulRun <$> interpretHostCommand cfg command
    pure (either (\reason -> exposureFailure "run exposure runtime command" reason ReprobeBeforeRetry) Right outcome)

resolvedSet :: PreparedClusterExposure scope planId clusterId clusterFrame -> RelayObservation -> Either ReconcileError [ResolvedExposure scope planId clusterId ()]
resolvedSet prepared observation@(RelayObservation relay _ _ _ generation operation _ _) =
    traverse resolve (intentBindings prepared)
  where
    resolve (intent, listener, _) = case lookup listener (observationPorts observation) of
        Just hostPort ->
            Right
                ( ResolvedExposure
                    (exposureIntentService intent)
                    hostPort
                    (exposureIntentTargetHost intent)
                    (exposureIntentTargetPort intent)
                    relay
                    generation
                    operation
                )
        Nothing -> exposureConflict prepared "an inspected mapping has no matching semantic service"

observationPorts :: RelayObservation -> [(Int, Int)]
observationPorts (RelayObservation _ _ _ _ _ _ _ mappings) = [(listener, hostPort) | (listener, _, hostPort) <- mappings]

observationRecordMappings :: PreparedClusterExposure scope planId clusterId clusterFrame -> RelayObservation -> [(Text, Int, Int)]
observationRecordMappings prepared observation =
    [ (service, listener, hostPort)
    | (listener, service) <- [(listener, name) | (listener, name) <- expected]
    , Just hostPort <- [lookup listener (observationPorts observation)]
    ]
  where
    expected = [(listener, exposureIntentService intent) | (intent, listener, _) <- intentBindings prepared]

intentBindings :: PreparedClusterExposure scope planId clusterId clusterFrame -> [(ExposureIntent, Int, Text)]
intentBindings prepared =
    [ (intent, exposureRelayPortBase + offset, exposureIntentService intent)
    | (offset, intent) <- zip [0 ..] (preparedExposureIntents prepared)
    ]

exposureTarget :: PreparedClusterExposure scope planId clusterId clusterFrame -> Either ReconcileError ClusterCallTarget
exposureTarget prepared =
    clusterCallTarget
        (preparedExposureClusterName prepared)
        (preparedExposureStateDirectory prepared)
        (preparedExposureNodeNames prepared)
        Nothing
        Nothing
        (preparedExposureOwner prepared)

exposureRecordKey :: PreparedClusterExposure scope planId clusterId clusterFrame -> Either ProtectedError RecordKey
exposureRecordKey prepared = mkRecordKey (Text.pack (preparedExposureClusterName prepared) <> ".exposure")

renderExposureRecord :: ExposureRecord -> ByteString.ByteString
renderExposureRecord = TextEncoding.encodeUtf8 . Text.pack . show

parseExposureRecord :: ByteString.ByteString -> Either Text ExposureRecord
parseExposureRecord bytes = case TextEncoding.decodeUtf8' bytes of
    Left _ -> Left "the exposure ownership record is not UTF-8"
    Right raw -> case readMaybe (Text.unpack raw) of
        Just record | renderExposureRecord record == bytes -> Right record
        _ -> Left "the exposure ownership record is not canonical"

exposureSpecDigest :: PreparedClusterExposure scope planId clusterId clusterFrame -> Text
exposureSpecDigest prepared = digestText (Text.intercalate "\NUL" fields)
  where
    fields =
        [ "hostbootstrap/exposure/v1"
        , preparedExposureKey prepared
        , Text.pack (show (preparedExposureGeneration prepared))
        , preparedExposureClusterIdentity prepared
        , ownerDigest prepared
        , preparedExposureImage prepared
        ]
            <> concatMap intentFields (preparedExposureIntents prepared)
    intentFields intent =
        [ exposureIntentService intent
        , "tcp"
        , exposureIntentTargetHost intent
        , Text.pack (show (exposureIntentTargetPort intent))
        ]

ownerDigest :: PreparedClusterExposure scope planId clusterId clusterFrame -> Text
ownerDigest = digestText . preparedExposureOwner

relayLabels :: PreparedClusterExposure scope planId clusterId clusterFrame -> Text -> [(Text, Text)]
relayLabels prepared nonce =
    [ ("io.hostbootstrap.owner", ownerDigest prepared)
    , ("io.hostbootstrap.cluster", preparedExposureKey prepared)
    , ("io.hostbootstrap.generation", Text.pack (show (preparedExposureGeneration prepared)))
    , ("io.hostbootstrap.operation", nonce)
    , ("io.hostbootstrap.spec", exposureSpecDigest prepared)
    ]

relayName :: PreparedClusterExposure scope planId clusterId clusterFrame -> Text -> Text
relayName prepared nonce = "hostbootstrap-exposure-" <> Text.take 32 (digestText (exposureSpecDigest prepared <> nonce))

nonceText :: ByteString.ByteString -> Text
nonceText = TextEncoding.decodeUtf8 . convertToBase Base16

digestText :: Text -> Text
digestText = Text.pack . show . (hash :: ByteString.ByteString -> Digest SHA256) . TextEncoding.encodeUtf8

immutableImage :: Text -> Bool
immutableImage image = repositoryDigest || imageId
  where
    repositoryDigest = case Text.breakOnEnd "@sha256:" image of
        (prefix, digest) -> not (Text.null prefix) && Text.length digest == 64 && Text.all lowerHex digest
    imageId = case Text.stripPrefix "sha256:" image of
        Just digest -> Text.length digest == 64 && Text.all lowerHex digest
        Nothing -> False

validPort :: Int -> Bool
validPort port = port > 0 && port < 65536

validExposureService :: Text -> Bool
validExposureService service =
    not (Text.null service)
        && Text.length service <= 128
        && not (Text.any (`elem` ['\0', '/', '\\', ':', '\n', '\r', '\t']) service)

validManagedExposureRecord :: Text -> Text -> Text -> Text -> [(Text, Int, Int)] -> Bool
validManagedExposureRecord digest nonce name identity mappings =
    validDigest digest
        && validDigest nonce
        && name == "hostbootstrap-exposure-" <> Text.take 32 (digestText (digest <> nonce))
        && validDigest identity
        && not (null mappings)
        && length mappings <= maxExposureCount
        && all validMapping mappings
        && distinct [listener | (_, listener, _) <- mappings]
  where
    validDigest value = Text.length value == 64 && Text.all lowerHex value
    validMapping (service, listener, hostPort) =
        validExposureService service && validPort listener && validPort hostPort

lowerHex :: Char -> Bool
lowerHex character = isDigit character || character >= 'a' && character <= 'f'

distinct :: (Eq value) => [value] -> Bool
distinct [] = True
distinct (value : values) = value `notElem` values && distinct values

maxExposureCount, exposureRelayPortBase :: Int
maxExposureCount = 128
exposureRelayPortBase = 20000

exposureFailure :: Text -> Text -> RecoveryDisposition -> Either ReconcileError value
exposureFailure operation reason disposition = Left (Failure (FailureDetail operation reason disposition))

exposureConflict :: PreparedClusterExposure scope planId clusterId clusterFrame -> Text -> Either ReconcileError value
exposureConflict prepared reason =
    Left (Conflict (ConflictDetail (preparedExposureKey prepared) (exposureSpecDigest prepared) "changed runtime exposure" reason))

storeExposureFailure :: Text -> ProtectedError -> Either ReconcileError value
storeExposureFailure operation = (\reason -> Left (Failure (FailureDetail operation reason ReprobeBeforeRetry))) . protectedErrorMessage
