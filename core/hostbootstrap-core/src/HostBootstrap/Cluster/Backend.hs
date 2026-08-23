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
    runClusterCordonCall,
    ClusterStatusObservation (..),
    runClusterStatusCall,
    classifyClusterStatus,
    runClusterReadinessCall,
    registerClusterRuntimeDependencyPackage,
    withFreshClusterRuntimeDependency,
    PreparedChartWorkload,
    withPreparedChartWorkload,
    runChartWorkloadCall,
    runChartWorkloadCleanupCall,
    runVerifiedChartWorkloadCleanupCall,

    -- * Loopback-bound exposure
    LoopbackExposure,
    mkLoopbackExposure,
    loopbackExposureListenAddress,
    loopbackExposureHostPort,
    loopbackExposureNodePort,
    PreparedLoopbackExposure,
    withPreparedLoopbackExposure,
    preparedLoopbackExposureMapping,
    ObservedPortBinding (..),
    settleLoopbackExposure,
)
where

import Data.Char (isDigit)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Cluster.Command (listClustersCommand)
import HostBootstrap.Cluster.Backend.Internal
    ( StrongClusterBackend
    , mkStrongClusterBackend
    , strongClusterHostConfig
    , strongClusterDriver
    , strongClusterConfigBytes
    , strongClusterConfigDigest
    , strongClusterOwnershipIdentity
    , strongClusterReadinessVersion
    )
import HostBootstrap.Cluster.Lifecycle
    ( ClusterDriver (KindDriver, NvkindDriver)
    , PlanOwnedClusterConfig
    , planOwnedClusterConfigBase
    , planOwnedClusterConfigBytes
    , planOwnedClusterConfigDigest
    , planOwnedClusterConfigDriver
    , planOwnedClusterOwnershipIdentity
    )
import HostBootstrap.Cluster.Cordon (ResourceBudget)
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
    preparedClusterConfigDigest,
    preparedClusterConfigBytes,
    preparedClusterDriver,
    preparedClusterConfigPath,
    preparedClusterCordonBudget,
    preparedClusterCordonName,
    preparedClusterCordonNodeNames,
    preparedClusterCordonOwnershipIdentity,
    preparedClusterCordonStateDirectory,
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
import HostBootstrap.Cluster.Workload
    ( PreparedChartWorkload
    , settlePreparedChartWorkload
    , settlePreparedChartWorkloadUnchanged
    , withPreparedChartWorkload
    , withPreparedChartWorkloadParts
    , withSettledChartWorkloadCleanup
    )
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary (hostCommand, withCommandStdin)
import HostBootstrap.HostConfig (HostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Kind, Kubectl, Nvkind), toolCommandName)
import System.Exit (ExitCode (ExitSuccess))
import HostBootstrap.Lifecycle.Dependency.Internal (
    RuntimeDependencyPackage,
    mkClusterRuntimeDependencyPackage,
    renderRuntimeDependencyProbeResponse,
    renderRuntimeDependencyChartResponse,
    runtimeDependencyChartRequest,
    runtimeDependencyPackageKey,
    runtimeDependencyProbeRequest,
    verifyRuntimeDependencyProbeResponse,
    verifyRuntimeDependencyChartResponse,
    withClusterRuntimeDependencySuccessor,
    withRuntimeDependencyProbeRequest,
    withRuntimeDependencyChartRequest,
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
import HostBootstrap.Protected (
    ProtectedSession,
    RecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ClusterResource,
    ConflictDetail (..),
    FailureDetail (..),
    PlannedResource,
    VerifiedResourceRecordBundle,
    PriorCommitProof,
    Provisioned,
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    ReconcileResult,
    UnsupportedDetail (..),
    plannedResourceKey,
    resourceHandleGeneration,
    withCarriedManagedResourceOfKind,
    withVerifiedResourceRecordBundle,
 )
import System.FilePath (isAbsolute, (</>))
import HostBootstrap.ProjectPlan (ChartWorkloadResource)
import qualified HostBootstrap.ProjectPlan as ProjectPlan

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
    withPreparedChartWorkloadParts prepared $ \execution values artifact release namespace _valuesDigest image _workloadKey _role _effects clusterKey operationCallDigest _observed _ _ ->
        case (TextEncoding.decodeUtf8' values, deployments) of
            (Left _, _) -> pure (failed "canonical values are not UTF-8")
            (_, []) -> pure (failed "the admitted effects contain no deployment readiness target")
            (_, _ : _ : _) -> pure (failed "the admitted effects contain multiple deployment readiness targets")
            (Right valuesText, [deployment]) -> do
                packages <- stepRuntimeDependencyPackages (stepExecutionRuntime execution)
                case filter ((== "cluster:" <> clusterKey) . runtimeDependencyPackageKey) packages of
                    [package] ->
                        case runtimeDependencyChartRequest package operationCallDigest artifact release namespace image deployment valuesText of
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
    preparedEffects = withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ effects _ _ _ _ _ -> effects
    generation = withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ _ _ observed _ _ -> resourceHandleGeneration observed
    failed reason = settlePreparedChartWorkload prepared (BackendFailed reason ReprobeBeforeRetry)

runChartWorkloadCleanupCall ::
    StrongClusterBackend ->
    ChartWorkloadResource scope planId chartId chartFrame ->
    ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned ->
    IO (Either ReconcileError ())
runChartWorkloadCleanupCall backend chart settlement =
    case withSettledChartWorkloadCleanup chart settlement (,) of
        Left failure -> pure (Left failure)
        Right (release, namespace) -> runChartCleanup (strongClusterHostConfig backend) release namespace

runVerifiedChartWorkloadCleanupCall ::
    HostConfig ->
    ChartWorkloadResource scope planId chartId chartFrame ->
    VerifiedResourceRecordBundle scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) ->
    IO (Either ReconcileError ())
runVerifiedChartWorkloadCleanupCall cfg chart bundle =
    withVerifiedResourceRecordBundle
        bundle
        (\_receipt -> let (release, namespace, _) = ProjectPlan.chartWorkloadReverseIdentity chart in runChartCleanup cfg release namespace)
        (\_ _ _ _ _ _ _ -> pure (Right ()))

runChartCleanup :: HostConfig -> Text -> Text -> IO (Either ReconcileError ())
runChartCleanup cfg release namespace = do
            removed <-
                interpretHostCommand
                    cfg
                    (hostCommand Helm ["uninstall", Text.unpack release, "--namespace", Text.unpack namespace, "--wait"])
            case classifyHelmUninstall release removed of
                Left reason -> pure (Left (cleanupFailure reason))
                Right () -> do
                    absent <-
                        interpretHostCommand
                            cfg
                            (hostCommand Helm ["status", Text.unpack release, "--namespace", Text.unpack namespace])
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
        , ("release \"" <> Text.unpack release <> "\" uninstalled") `isInfixOf` capturedStdout captured -> Right ()
        | capturedExit captured /= ExitSuccess
        , "not found" `isInfixOf` capturedStderr captured -> Right ()
    _ -> successfulRun result >> Left "Helm returned an unrecognized uninstall result"

classifyHelm :: Text -> Either String CapturedRun -> Either Text (Maybe Bool)
classifyHelm release result = do
    output <- successfulRun result
    let installed = "Release \"" <> Text.unpack release <> "\" has been installed"
        upgraded = "Release \"" <> Text.unpack release <> "\" has been upgraded"
    if "no changes" `isInfixOf` output
        then Right Nothing
        else if installed `isInfixOf` output
            then Right (Just True)
            else if upgraded `isInfixOf` output
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
            outcome <- withClusterTransaction backend target Owned.releaseOwnedCluster
            pure $ case outcome of
                Right Owned.ClusterReleased -> ClusterCleanupRemoved
                Right Owned.ClusterAlreadyReleased -> ClusterCleanupRemoved
                Right Owned.ClusterStillPresent ->
                    cleanupRefusal
                        key
                        "the runtime still reports a node container this record bound"
                        ReprobeBeforeRetry
                Left fault -> case replacedIdentity fault of
                    Just identity -> ClusterCleanupReplaced identity
                    Nothing -> cleanupRefusal key (clusterCallFaultMessage fault) ReprobeBeforeRetry
  where
    key = Text.pack (preparedCleanupClusterName prepared)

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
    Text ->
    Word64 ->
    IO (Either ReconcileError (RuntimeDependencyPackage scope planId))
registerClusterRuntimeDependencyPackage backend execution scopeCommitment gate applied readiness route expiry = do
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
                                    case withRuntimeDependencyProbeRequest package request id of
                                        Left _ -> serveClusterChartRequest backend package request
                                        Right nonce -> do
                                            replay <- atomicModifyIORef' usedNonces $ \seen ->
                                                if nonce `elem` seen then (seen, True) else (nonce : seen, False)
                                            if replay
                                                then pure (Left "cluster runtime dependency nonce has already been consumed")
                                                else do
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
    origin = clusterBackendOrigin backend
    dependencyFailure reason = Left (Failure (FailureDetail "register cluster runtime dependency" reason ReprobeBeforeRetry))

serveClusterChartRequest ::
    StrongClusterBackend ->
    RuntimeDependencyPackage scope planId ->
    ByteString.ByteString ->
    IO (Either Text ByteString.ByteString)
serveClusterChartRequest backend package request =
    case withRuntimeDependencyChartRequest package request (,,,,,,) of
        Left refusal -> pure (Left refusal)
        Right (call, artifact, release, namespace, image, deployment, values) -> do
            helm <-
                interpretHostCommand
                    (strongClusterHostConfig backend)
                    ( withCommandStdin
                        (Text.unpack values)
                        ( hostCommand Helm
                            [ "upgrade", "--install", Text.unpack release, Text.unpack artifact
                            , "--namespace", Text.unpack namespace, "--create-namespace=false"
                            , "--values", "-", "--set-string", "image.identity=" <> Text.unpack image
                            , "--atomic", "--wait"
                            ]
                        )
                    )
            case classifyHelm release helm of
                Left reason -> pure (Left reason)
                Right change -> do
                    rollout <-
                        interpretHostCommand
                            (strongClusterHostConfig backend)
                            (hostCommand Kubectl ["rollout", "status", "--namespace", Text.unpack namespace, "deployment/" <> Text.unpack deployment, "--timeout=5m"])
                    pure $ do
                        _ <- successfulRun rollout
                        renderRuntimeDependencyChartResponse package call $ case change of
                            Nothing -> "unchanged"
                            Just True -> "created"
                            Just False -> "repaired"

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
    (forall phase. ClusterReadiness scope planId clusterId phase -> result) ->
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
                                Right version -> withRecoveredClusterReadiness handle version consume
            either (pure . Left) id carried
        [] -> pure (dependencyFailure "the exact cluster package is absent")
        _ -> pure (dependencyFailure "the cluster package registry contains duplicate resource keys")
  where
    runtime = stepExecutionRuntime execution
    dependencyFailure reason = Left (Failure (FailureDetail "recover cluster runtime dependency" reason ReprobeBeforeRetry))

clusterBackendOrigin :: StrongClusterBackend -> Text
clusterBackendOrigin backend =
    Text.intercalate ":"
        [ Text.pack (show (strongClusterDriver backend))
        , strongClusterConfigDigest backend
        , strongClusterOwnershipIdentity backend
        ]

clusterGateCommitment :: PreparedGate -> Text
clusterGateCommitment gate =
    Text.intercalate ":"
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

-- Loopback-bound exposure -----------------------------------------------------

{- | A published cluster port. There is deliberately no way to supply a listen
address: the mapping is always loopback, so a wildcard exposure of a
project-local service is unrepresentable rather than merely discouraged.
-}
data LoopbackExposure = LoopbackExposure Int Int
    deriving (Eq, Show)

mkLoopbackExposure ::
    -- | host port
    Int ->
    -- | node port inside the cluster
    Int ->
    Either ReconcileError LoopbackExposure
mkLoopbackExposure hostPort nodePort
    | not (validPort hostPort) =
        invalid ("host port out of range: " <> Text.pack (show hostPort))
    | not (validPort nodePort) =
        invalid ("node port out of range: " <> Text.pack (show nodePort))
    | otherwise = Right (LoopbackExposure hostPort nodePort)
  where
    validPort port = port > 0 && port < 65536
    invalid reason =
        Left (Failure (FailureDetail "validate cluster exposure" reason DoNotRetry))

-- | Always @127.0.0.1@. This is the whole point of the type.
loopbackExposureListenAddress :: LoopbackExposure -> String
loopbackExposureListenAddress _ = "127.0.0.1"

loopbackExposureHostPort :: LoopbackExposure -> Int
loopbackExposureHostPort (LoopbackExposure hostPort _) = hostPort

loopbackExposureNodePort :: LoopbackExposure -> Int
loopbackExposureNodePort (LoopbackExposure _ nodePort) = nodePort

{- | An exposure bound to one planned cluster resource. The renderer that emits
the driver's port mapping consumes this, so it cannot publish a port for a
cluster that is not in the plan.
-}
data PreparedLoopbackExposure scope planId clusterId clusterFrame
    = PreparedLoopbackExposure Text LoopbackExposure

withPreparedLoopbackExposure ::
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    LoopbackExposure ->
    (PreparedLoopbackExposure scope planId clusterId clusterFrame -> result) ->
    Either ReconcileError result
withPreparedLoopbackExposure planned exposure consume =
    Right (consume (PreparedLoopbackExposure (plannedResourceKey planned) exposure))

-- | The exact mapping to render: listen address, host port, node port.
preparedLoopbackExposureMapping ::
    PreparedLoopbackExposure scope planId clusterId clusterFrame ->
    (String, Int, Int)
preparedLoopbackExposureMapping (PreparedLoopbackExposure _ exposure) =
    ( loopbackExposureListenAddress exposure
    , loopbackExposureHostPort exposure
    , loopbackExposureNodePort exposure
    )

{- | What the runtime reports the published port is actually bound to. A
wildcard address is the failure this operation exists to catch: it silently
exposes a project-local service to the network.
-}
data ObservedPortBinding = ObservedPortBinding
    { observedBindAddress :: String
    , observedBindPort :: String
    }
    deriving (Eq, Show)

{- | Confirm that the live binding is the exact loopback mapping that was
prepared. A wildcard or foreign address is a structured 'Conflict', never a
warning, and an unparseable port is a 'Failure' rather than an assumed match.
-}
settleLoopbackExposure ::
    PreparedLoopbackExposure scope planId clusterId clusterFrame ->
    ObservedPortBinding ->
    Either ReconcileError ()
settleLoopbackExposure
    (PreparedLoopbackExposure key exposure)
    observed
        | not (all isDigit port) || null port =
            Left
                ( Failure
                    ( FailureDetail
                        "verify cluster exposure"
                        ("unparseable published port: " <> Text.pack port)
                        ReprobeBeforeRetry
                    )
                )
        | address /= loopbackExposureListenAddress exposure
            || read port /= loopbackExposureHostPort exposure =
            Left
                ( Conflict
                    ( ConflictDetail
                        key
                        ( Text.pack
                            ( loopbackExposureListenAddress exposure
                                <> ":"
                                <> show (loopbackExposureHostPort exposure)
                            )
                        )
                        (Text.pack (address <> ":" <> port))
                        "the cluster port is not bound to the prepared loopback address; refusing to treat a wider binding as the declared exposure"
                    )
                )
        | otherwise = Right ()
      where
        address = observedBindAddress observed
        port = observedBindPort observed
