{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- | The bare binary's owned live-gate configuration, plan, and assertions.
module HostBootstrap.CLI.Bare (
    BareConfig,
    BareTestConfig,
    bareTestCodec,
    bareTestInit,
    bareAssemble,
    bareInit,
    bareStepPlan,
    bareKubectlArguments,
    successfulLine,
    parseLoopbackMapping,
    runtimeExposureAssertion,
    bareClusterLiveSuite,
#ifdef HOSTBOOTSTRAP_BARE_TESTING
    bareWithRunForTesting,
#endif
)
where

import Control.Exception (throwIO)
import Control.Monad (filterM, foldM, forM, unless, when)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (intercalate, sort)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.CLI.Bare.Runtime (parseLoopbackMapping, runtimeExposureAssertionWith, successfulLine)
import HostBootstrap.Cluster.Lifecycle (
    ClusterPlan (clusterName, dataPath),
    ClusterProfile,
    mkTestCaseProfile,
    ClusterDriver (KindDriver),
    clusterKubeconfigPath,
    withExecutionOwnedCluster,
    withPlanOwnedClusterConfig,
    planOwnedClusterName,
    clusterRuntimeStateDirectory,
    planOwnedRenderedConfigPath,
    planOwnedClusterConfigBytes,
    resolvePlan,
    retainedClusterProjection,
    retainedClusterName,
    retainedClusterNodeNames,
    retainedClusterStateDirectory,
    retainedClusterKubeconfigPath,
 )
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    ExistingOutputPolicy (..),
    InitArgs (..),
    ProjectCfg (..),
    ProjectCodec,
    TestCfg (..),
    decodeProjectCodecFile,
    failConfigAssembly,
    pureConfigAssembly,
    withProjectCodec,
 )
import HostBootstrap.Config.Schema (renderScopedProjectConfigBytes, siblingProjectConfigPath)
import HostBootstrap.Config.Vocab (harnessConfigAuthority, harnessRunName)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (CodecWitness, autoCodecWitness, requireCodecWitness)
import qualified HostBootstrap.Cluster.Backend as CB
import HostBootstrap.Cluster.Budget (BudgetCfg (..), withActionResourceSlice)
import HostBootstrap.Cluster.Cordon (budgetFromResources)
import qualified HostBootstrap.Cluster.Ownership as Owned
import qualified HostBootstrap.Cluster.Reconcile as CR
import HostBootstrap.Cluster.Resume (ClusterStanding (ClusterNothingDone), ClusterStandingConflict (RecordClaimedByAnotherGeneration))
import HostBootstrap.Ownership.Object (ObjectKind (ReportedObject), Origin (OriginAbsent), mkOwnerClaim, originRecord)
import HostBootstrap.Protected (openProtectedStore, readProtectedRecord, withProtectedEntry)
import HostBootstrap.Ownership.Tape (RecordSubject (RecordSubject), publishFreshRecord, recordTape)
import System.IO.Temp (withSystemTempDirectory)
import HostBootstrap.Digest (sha256Hex)
import HostBootstrap.Effect.Run (capturedTriple)
import HostBootstrap.Effect.Vocabulary (hostCommand)
import HostBootstrap.Lifecycle.Prepared (preparedGateFence, preparedGateJournalVersion)
import HostBootstrap.ProjectPlan (PlannedResourceKind (ProviderResourceKind, ClusterResourceKind))
import HostBootstrap.Readiness (ProbeResult (..), ProbeFailure (..), ProbeConflict (ProbeConflict), nodePoll, pollUntilReady, renderPollError)
import HostBootstrap.Reconcile (ReconcileError (Conflict), ConflictDetail (..), withNodeResourceOfKind, withNodeObservedResource)
import qualified HostBootstrap.Substrate.Provider.Backend as PB
import qualified HostBootstrap.Substrate.Provider.Reconcile as PR
import HostBootstrap.Harness (
    Case (..),
    CaseId,
    CaseLifecycle (AssertOnce),
    LifecycleFailure (LifecycleFailure),
    CaseResult (..),
    TestMatrixError (..),
    TestSuite (..),
    VariantId,
    mkCaseId,
    mkTestMatrix,
    mkVariantId,
    variantDraft,
    variantDraftId,
 )
import HostBootstrap.HostConfig (HostConfig, buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Kind, Kubectl, Helm), toolCommandName)
import HostBootstrap.Lifecycle.Execution (stepExecutionHostConfig, stepExecutionPreparedGate, stepExecutionOperationKey)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot, canonicalProjectRootPath)
import HostBootstrap.Step (
    Step,
    StepAction,
    StepFrame (..),
    StepObservation (..),
    StepPlan,
    StepPlanError (..),
    TeardownOutcome (..),
    deployKindStep,
    deployVMStep,
    declaresProviderResource,
    providerResourceAtCurrentFrame,
    mkStepPlan,
    reversedBy,
 )
import HostBootstrap.Substrate (detect)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))

data BareConfig scope = BareConfig
    { bareContext :: Context.BinaryContext
    , bareResources :: Context.ResourceEnvelope
    , bareNodeImage :: Text
    , bareHarnessRun :: Maybe Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance BudgetCfg BareConfig where
    budgetResourceEnvelope = bareResources

#ifdef HOSTBOOTSTRAP_BARE_TESTING
bareWithRunForTesting :: Text -> BareConfig scope -> BareConfig scope
bareWithRunForTesting runName cfg = cfg{bareHarnessRun = Just runName}
#endif

newtype BareTestConfig = BareTestConfig {runClusterLive :: Bool}
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance TestCfg BareTestConfig where
    type TestVariant BareTestConfig = ()
    projectTestMatrix caseIds config
        | runClusterLive config =
            mkTestMatrix caseIds [draft] [(cid, [variantDraftId draft]) | cid <- caseIds]
        | otherwise = Left EmptyVariantRegistry
      where
        draft = variantDraft bareVariantId ()

instance ProjectCfg BareConfig where
    withProductionProjectCodec =
        withProjectCodec
            (T.pack "BareConfig/Production")
            (requireCodecWitness "BareConfig" autoCodecWitness)
    withHarnessProjectCodec _ =
        withProjectCodec
            (T.pack "BareConfig/Harness")
            (requireCodecWitness "BareConfig" autoCodecWitness)
    cfgContext = bareContext

bareTestCodec :: CodecWitness BareTestConfig
bareTestCodec = requireCodecWitness "bare test config" autoCodecWitness

bareTestInit :: InitArgs -> BareTestConfig
bareTestInit _ = BareTestConfig True

bareAssemble ::
    forall projectId scope.
    String ->
    FilePath ->
    AssemblyRequest projectId BareTestConfig () scope ->
    ConfigAssembly scope (BareConfig scope)
bareAssemble progName root request = case request of
    ProductionAssembly args ->
        either failConfigAssembly pureConfigAssembly (bareInit progName root args)
    HarnessAssembly authority _ _ _ ->
        either
            failConfigAssembly
            (pureConfigAssembly . (\cfg -> cfg{bareHarnessRun = Just (harnessRunName authority)}))
            (bareInit progName root (defaultBareArgs root))

bareInit :: String -> FilePath -> InitArgs -> Either String (BareConfig scope)
bareInit progName root args =
    let baseContext =
            Context.contextForKind
                (T.pack progName)
                (T.pack progName)
                (T.pack (fromMaybe root (sourceRoot args)))
                (role args)
     in case foldM (flip Context.addRole) baseContext (alsoRoles args) of
            Left err -> Left (Context.contextErrorMessage err)
            Right context -> do
                let resources = Context.ResourceEnvelope (fromMaybe 2 (mCpu args)) (fromMaybe "2GiB" (memory args)) (fromMaybe "8GiB" (storage args))
                _ <- either (Left . show) Right (budgetFromResources resources)
                Right (BareConfig context resources "kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5" Nothing)

defaultBareArgs :: FilePath -> InitArgs
defaultBareArgs root =
    InitArgs
        { role = Context.HostOrchestrator
        , alsoRoles = []
        , output = Nothing
        , sourceRoot = Just root
        , mCpu = Nothing
        , memory = Nothing
        , storage = Nothing
        , dockerfile = Nothing
        , haReplicas = Nothing
        , existingOutput = RefuseExistingOutput
        }

bareCaseId :: CaseId
bareCaseId = either (error . show) id (mkCaseId (T.pack "cluster-live"))

bareVariantId :: VariantId
bareVariantId = either (error . show) id (mkVariantId (T.pack "linux-cpu"))

bareStepPlan ::
    String ->
    CanonicalProjectRoot scope rootId ->
    BareConfig scope ->
    Either StepPlanError StepPlan
bareStepPlan progName canonicalRoot cfg = case bareHarnessRun cfg of
    Nothing -> Left EmptyStepPlan
    Just runName -> case mkTestCaseProfile runName of
        Left _ -> Left EmptyStepPlan
        Right profile -> mkStepPlan
            [ declaresProviderResource providerResourceAtCurrentFrame $
                reversedBy (\_ _ -> pure TeardownReleased) $
                    deployVMStep "reserve the live gate's Direct host provider" frame (bareProviderAction cfg root runName)
            , bareClusterStep progName cfg root runName profile
            ]
  where
    root = canonicalProjectRootPath canonicalRoot
    frame = StepFrame (T.unpack (Context.currentFrame (bareContext cfg))) "metal"

bareProviderAction :: BareConfig configScope -> FilePath -> Text -> StepAction
bareProviderAction config root runName execution = do
    let host = stepExecutionHostConfig execution
    gate <- stepExecutionPreparedGate execution >>= maybe (failBare "cluster-live: provider gate is absent") pure
    when (preparedGateJournalVersion gate > maxBound - 1024) (failBare "cluster-live: dependency lifetime overflows")
    spec <- either (failBare . show) pure (PB.mkDirectHostBackendSpec host root (T.unpack (bareNodeImage config)))
    discovered <- PB.discoverStrongProviderBackend host spec $ \backend -> do
        action <- either (failBare . show) pure $ withNodeResourceOfKind execution ProviderResourceKind (stepExecutionOperationKey execution) $ \planned -> do
            observing <- either (failBare . show) pure $ withNodeObservedResource execution planned (preparedGateFence gate) (preparedGateJournalVersion gate) $ \observed -> do
                provisioning <- either (failBare . show) pure $ PR.withPreparedProviderProvision execution (PB.providerBackendBinding backend) planned observed gate $ \prepared -> do
                    result <- PB.runProviderProvisionCall backend prepared
                    settlement <- either (failBare . show) pure (PR.settleProviderProvision Nothing prepared result)
                    PR.withProviderProvisionSettlement settlement
                        (\managed _ -> do
                            checking <- either (failBare . show) pure $ PR.withPreparedProviderReady execution planned managed (PR.providerStartableAfterProvision managed) gate $ \ready -> do
                                readyCall <- PB.runProviderReadyCall backend ready
                                advance <- either (failBare . show) pure (PR.settleProviderReady ready readyCall)
                                PR.carryCreatedRunningProviderSettlement execution advance "bare-direct-provider-v1" >>= either (failBare . show) pure
                                PB.registerRunningProviderDependencyPackage backend execution ("harness:" <> runName) gate ready advance
                                    "runtime://provider/bare-direct-readiness" (preparedGateJournalVersion gate + 1024) >>= either (failBare . show) (const (pure ()))
                            checking)
                        (\_ _ _ _ -> failBare "cluster-live: Direct reservation remains foreign")
                provisioning
            observing
        action
    either (failBare . show) pure discovered
    pure StepChanged

bareClusterStep :: String -> BareConfig configScope -> FilePath -> Text -> ClusterProfile -> Step
bareClusterStep progName cfg root runName profile =
    reversedBy
        (\host _ -> bareClusterReverse host plan)
        (deployKindStep "create and cordon the harness-owned live Kind cluster"
            (StepFrame (T.unpack (Context.currentFrame (bareContext cfg))) "metal")
            (bareClusterAction cfg plan runName))
  where
    plan = resolvePlan progName root profile

bareClusterAction :: BareConfig configScope -> ClusterPlan -> Text -> StepAction
bareClusterAction config plan runName execution = do
    let host = stepExecutionHostConfig execution
    gate <- stepExecutionPreparedGate execution >>= maybe (failBare "cluster-live: cluster gate is absent") pure
    budget <- either (failBare . show) pure (budgetFromResources (bareResources config))
    let now = preparedGateJournalVersion gate
    opened <- PR.withFreshCarriedRunningProviderDependency execution ("harness:" <> runName) "core:deploy-vm"
        "runtime://provider/bare-direct-readiness" now ("cluster-live-" <> T.pack (show now)) $ \provider running -> do
            action <- either (failBare . show) pure $ withNodeResourceOfKind execution ClusterResourceKind (stepExecutionOperationKey execution) $ \cluster ->
                withActionResourceSlice cluster budget $ \slice -> do
                    base <- either (failBare . show) pure (withExecutionOwnedCluster execution cluster provider slice KindDriver)
                    let state = clusterRuntimeStateDirectory plan
                        path = takeDirectory state </> "config.yaml"
                        node = T.pack (planOwnedClusterName base <> "-control-plane")
                        bytes = LBS.toStrict $ Aeson.encode $ Aeson.object
                            ["kind" Aeson..= ("Cluster" :: Text), "apiVersion" Aeson..= ("kind.x-k8s.io/v1alpha4" :: Text),
                             "nodes" Aeson..= [Aeson.object
                                ["role" Aeson..= ("control-plane" :: Text), "image" Aeson..= bareNodeImage config,
                                 "kubeadmConfigPatches" Aeson..= ["apiVersion: kubeadm.k8s.io/v1beta4\nkind: InitConfiguration\ntimeouts:\n  kubernetesAPICall: 5m0s\n" :: Text]]]]
                    intents <- either (failBare . show) pure (traverse (\service -> CB.mkExposureIntent service node 20000) ["gate-a", "gate-b"])
                    configuredAction <- either (failBare . show) pure $ withPlanOwnedClusterConfig base bytes (sha256Hex bytes) state path intents
                        [("control-plane", node)] [stepExecutionOperationKey execution] $ \configured -> do
                            createDirectoryIfMissing True (dataPath plan)
                            writeFile (bareSentinelPath plan) (bareSentinelBytes runName)
                            createDirectoryIfMissing True (takeDirectory (planOwnedRenderedConfigPath configured))
                            BS.writeFile (planOwnedRenderedConfigPath configured) (planOwnedClusterConfigBytes configured)
                            backend <- CB.discoverStrongClusterBackend host configured >>= either (failBare . show) pure
                            reconciling <- CR.withPreparedClusterReconcile configured running Nothing gate $ \prepared -> do
                                beforeCreate <- observeBareStatus host plan
                                unless (beforeCreate == CB.ClusterStatusAbsent) (failBare "cluster-live: fresh plan already names a cluster")
                                result <- CB.runClusterReconcileCall backend prepared
                                settled <- either (failBare . show) pure (CR.settleClusterReconcile Nothing prepared result)
                                CR.withClusterReconcileSettlement settled
                                    (\managed receipt _ -> do
                                        CR.carryClusterReconcileSettlement execution managed receipt >>= either (failBare . show) pure
                                        cordon <- either (failBare . show) pure (CR.withPreparedClusterCordon prepared managed id)
                                        cordoned <- CB.runClusterCordonCall backend cordon
                                        applied <- either (failBare . show) pure (CR.settleClusterCordon cordon cordoned)
                                        outcome <- pollUntilReady nodePoll "cluster-live: exact cluster readiness" (\_ -> do
                                            ready <- CB.runClusterReadinessCall backend applied
                                            pure $ case (CR.clusterReadinessResultView ready, CR.settleClusterReadiness applied ready) of
                                                (CR.ClusterReadinessResultReady _ _, Right evidence) -> ProbeReady evidence
                                                (CR.ClusterReadinessResultNotReady _, Left (Conflict detail)) -> ProbeConflicted (ProbeConflict (T.unpack (conflictExpected detail)) (T.unpack (conflictObserved detail)) (T.unpack (conflictRemedy detail)))
                                                (CR.ClusterReadinessResultNotReady identity, _) -> NotReady (T.unpack identity)
                                                (CR.ClusterReadinessResultProbeFailed reason, _) -> Unavailable (T.unpack reason)
                                                (_, Left failure) -> Failed (ProbeFailure "settle cluster-live readiness" (show failure))) host
                                        either (failBare . renderPollError) (const (pure ())) outcome
                                        afterReady <- observeBareStatus host plan
                                        unless (afterReady == CB.ClusterStatusPresent) (failBare "cluster-live: ready cluster is absent from status"))
                                    (\_ _ _ _ -> failBare "cluster-live: cluster remains foreign")
                            either (failBare . show) id reconciling
                    configuredAction
            action
    either (failBare . show) id opened
    pure StepChanged

-- | The reverse may also run after a failed create, so either pre-release observation is valid.
bareClusterReverse :: HostConfig -> ClusterPlan -> IO TeardownOutcome
bareClusterReverse host plan = do
    _ <- observeBareStatus host plan
    CB.releaseRetainedCluster host plan >>= either (failBare . show) pure
    afterRelease <- observeBareStatus host plan
    unless (afterRelease == CB.ClusterStatusAbsent) (failBare "cluster-live: released cluster remains in status")
    pure TeardownReleased

-- The snapshots are audit data only, never ownership witnesses, and are not rendered.
data BareStatusSnapshot = BareStatusSnapshot (Maybe (Bool, [(FilePath, BS.ByteString)])) [(String, String)]
    deriving (Eq)

observeBareStatus :: HostConfig -> ClusterPlan -> IO CB.ClusterStatusObservation
observeBareStatus host plan = do
    before <- bareStatusSnapshot host plan
    observed <- CB.runRetainedClusterStatusCall host plan
    after <- bareStatusSnapshot host plan
    unless (before == after) (failBare "cluster-live: status changed protected records or container state")
    case observed of
        CB.ClusterStatusProbeFailed reason -> failBare ("cluster-live: status probe failed: " <> T.unpack reason)
        _ -> do
            putStrLn ("cluster-live: read-only status " <> show observed <> "; records and containers unchanged")
            pure observed

bareStatusSnapshot :: HostConfig -> ClusterPlan -> IO BareStatusSnapshot
bareStatusSnapshot host plan = do
    let state = clusterRuntimeStateDirectory plan
        recordDirectory = state </> "records"
    exists <- doesDirectoryExist state
    records <- if not exists then pure Nothing else do
        hasRecords <- doesDirectoryExist recordDirectory
        names <- if hasRecords then sort <$> listDirectory recordDirectory else pure []
        paths <- filterM (doesFileExist . (state </>)) ("store.identity" : map ("records" </>) names)
        bytes <- forM paths $ \path -> (,) path <$> BS.readFile (state </> path)
        pure (Just (hasRecords, bytes))
    listing <- runBareCommand host Docker
        ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", "label=io.x-k8s.kind.cluster=" <> clusterName plan]
    identities <- case listing of
        Right (ExitSuccess, outputText, "") -> do
            let ids = sort (lines outputText)
            unless (all (\identity -> length identity == 64 && all (`elem` ("0123456789abcdef" :: String)) identity) ids)
                (failBare "cluster-live: invalid container identity in status snapshot")
            pure ids
        _ -> failBare "cluster-live: cannot list actual node identities for status snapshot"
    containers <- forM identities $ \identity -> do
        inspected <- runBareCommand host Docker ["inspect", "--format", statusContainerTemplate, identity]
        row <- either failBare pure (successfulLine "snapshot actual node state for status" inspected)
        pure (identity, row)
    pure (BareStatusSnapshot records containers)
  where
    statusContainerTemplate = "{{json .Id}} {{json .Name}} {{json .State}} {{json .HostConfig}} {{json .NetworkSettings.Ports}}"

runBareCommand :: HostConfig -> HostTool -> [String] -> IO (Either String (ExitCode, String, String))
runBareCommand host tool arguments = fmap capturedTriple <$> Owned.interpretClusterCommand host (hostCommand tool arguments)

bareClusterLiveSuite :: String -> TestSuite
bareClusterLiveSuite progName =
    ScopedTestSuite bareLivePrecondition [Case bareCaseId AssertOnce] $ \authority expectedConfig ->
        withHarnessProjectCodec (harnessConfigAuthority authority) $ \codec ->
            TestSuite
                bareLivePrecondition
                (\_ _ -> readBarePlan codec expectedConfig (harnessRunName authority) progName)
                [Case bareCaseId AssertOnce]
                (assertLive codec expectedConfig (harnessRunName authority))
                (assertReversed codec expectedConfig (harnessRunName authority))
  where
    assertLive :: ProjectCodec scope specDigest BareConfig -> BS.ByteString -> Text -> ClusterPlan -> Case -> IO CaseResult
    assertLive codec expectedConfig runName _ _ = do
        host <- resolveBareHostConfig
        plan <- readBarePlan codec expectedConfig runName progName
        generation <- assertBareClaimGeneration host plan
        retirement <- case generation of
            Left reason -> pure (Left reason)
            Right () -> assertBareRetirementPreflight host plan
        case retirement of
            Left reason -> pure (Fail reason)
            Right () -> do
                exposure <- runtimeExposureAssertion host plan
                case exposure of
                    Left reason -> pure (Fail reason)
                    Right () -> do
                        version <- runBareCommand host Kubectl (bareKubectlArguments plan ["version", "-o", "json"])
                        case version of
                            Right (ExitSuccess, out, _) -> do
                                putStrLn ("cluster-live: kubectl version " ++ out)
                                observed <- runBareCommand host Kubectl (bareKubectlArguments plan ["get", "nodes", "-o", "name"])
                                pure $ case observed of
                                    Right (ExitSuccess, nodes, _)
                                        | not (null (lines nodes)) -> Pass
                                        | otherwise -> Fail "cluster-live: kubectl returned no nodes"
                                    Right (ExitFailure code, _, err) -> Fail ("cluster-live: kubectl node observation failed (exit " ++ show code ++ "): " ++ err)
                                    Left err -> Fail ("cluster-live: kubectl node observation failed: " ++ err)
                            Right (ExitFailure code, _, err) -> pure (Fail ("cluster-live: kubectl version observation failed (exit " ++ show code ++ "): " ++ err))
                            Left err -> pure (Fail ("cluster-live: kubectl version observation failed: " ++ err))
    assertReversed :: ProjectCodec scope specDigest BareConfig -> BS.ByteString -> Text -> IO ()
    assertReversed codec expectedConfig runName = do
        plan <- readBarePlan codec expectedConfig runName progName
        host <- resolveBareHostConfig
        remaining <-
            runBareCommand
                host
                Docker
                [ "ps"
                , "-a"
                , "--filter"
                , "label=io.x-k8s.kind.cluster=" ++ clusterName plan
                , "--format"
                , "{{.ID}}"
                ]
        case remaining of
            Right (ExitSuccess, out, _) | null (lines out) -> pure ()
            Right (ExitSuccess, _, _) -> failBare "cluster-live: labelled node container remains after reverse"
            Right (ExitFailure code, _, err) -> failBare ("cluster-live: Docker absence observation failed (exit " ++ show code ++ "): " ++ err)
            Left err -> failBare ("cluster-live: Docker absence observation failed: " ++ err)
        sentinel <- readFile (bareSentinelPath plan)
        cfg <- readBareConfig codec expectedConfig runName progName
        case bareHarnessRun cfg of
            Just observedRun | sentinel == bareSentinelBytes observedRun -> pure ()
            _ -> failBare "cluster-live: durable-root sentinel changed across cluster deletion"

-- | Refuse another generation against this gate's actual already-owned cluster.
assertBareClaimGeneration :: HostConfig -> ClusterPlan -> IO (Either String ())
assertBareClaimGeneration host plan = do
    let retained = retainedClusterProjection plan
    case retainedClusterNodeNames retained of
        [] -> pure (Left "cluster-live: the retained cluster has no nodes")
        controlPlane : workers -> do
            let wrong = Owned.OwnedCluster
                    { Owned.ownedClusterName = retainedClusterName retained
                    , Owned.ownedClusterControlPlane = controlPlane
                    , Owned.ownedClusterWorkers = workers
                    , Owned.ownedClusterConfig = Nothing
                    , Owned.ownedClusterKubeconfig = retainedClusterKubeconfigPath retained
                    , Owned.ownedClusterOwner = "hostbootstrap/claim-mismatch/" <> T.pack (retainedClusterName retained)
                    }
            before <- bareStatusSnapshot host plan
            outcome <- case Owned.ownedClusterRecordKey wrong of
                Left failure -> pure (Left ("cluster-live: claim key: " <> show failure))
                Right key -> do
                    opened <- openProtectedStore (retainedClusterStateDirectory retained)
                    case opened of
                        Left failure -> pure (Left ("cluster-live: claim store: " <> show failure))
                        Right store -> do
                            entered <- withProtectedEntry store $ \session ->
                                Right <$> Owned.reconcileOwnedCluster KindDriver host session key wrong
                            pure $ case entered of
                                Left failure -> Left ("cluster-live: claim entry: " <> show failure)
                                Right (Left (Owned.ClusterOwnershipStanding RecordClaimedByAnotherGeneration)) -> Right ()
                                Right other -> Left ("cluster-live: expected another-generation refusal, got " <> show other)
            after <- bareStatusSnapshot host plan
            if before /= after
                then pure (Left "cluster-live: a generation refusal changed records or containers")
                else case outcome of
                    Left reason -> pure (Left reason)
                    Right () -> do
                        putStrLn "cluster-live: another generation refused; records and containers unchanged"
                        pure (Right ())

-- | Real absent runtime observations and real protected CAS records hold retirement preflight.
assertBareRetirementPreflight :: HostConfig -> ClusterPlan -> IO (Either String ())
assertBareRetirementPreflight host plan =
    withSystemTempDirectory "hostbootstrap-generation-preflight" $ \temporary -> do
        let name = clusterName plan <> "-preflight"
            worker = name <> "-worker"
            owned = Owned.OwnedCluster name (name <> "-control-plane") [worker] Nothing
                (temporary </> "cluster.kubeconfig") ("hostbootstrap/preflight/" <> T.pack name)
            rootRecord = originRecord (ReportedObject (Owned.ownedClusterClaim owned)) OriginAbsent
            workerRecord = originRecord (ReportedObject (mkOwnerClaim "hostbootstrap/preflight/another-generation")) OriginAbsent
        case (Owned.ownedClusterRecordKey owned, Owned.ownedNodeRecordKey owned worker) of
            (Right key, Right workerKey) -> do
                opened <- openProtectedStore (temporary </> "store")
                case opened of
                    Left failure -> pure (Left ("cluster-live: preflight store: " <> show failure))
                    Right store -> do
                        entered <- withProtectedEntry store $ \session -> do
                            absent <- Owned.ownedClusterStanding host session key owned
                            workerAbsent <- Owned.observeOwnedNode host worker
                            if absent /= Right ClusterNothingDone || workerAbsent /= Right OriginAbsent
                                then pure (Right (Left "cluster-live: preflight namespace is not observed absent"))
                                else do
                                    let tape = recordTape session (RecordSubject "the live cluster origin record" "bind the live cluster identity")
                                    rootWritten <- publishFreshRecord tape key rootRecord
                                    case rootWritten of
                                        Left failure -> pure (Right (Left ("cluster-live: publish preflight root: " <> show failure)))
                                        Right _ -> do
                                            workerWritten <- publishFreshRecord tape workerKey workerRecord
                                            case workerWritten of
                                                Left failure -> pure (Right (Left ("cluster-live: publish preflight worker: " <> show failure)))
                                                Right _ -> do
                                                    before <- traverse (readProtectedRecord session) [key, workerKey]
                                                    outcome <- Owned.releaseOwnedCluster host session key owned
                                                    after <- traverse (readProtectedRecord session) [key, workerKey]
                                                    let unchanged = case (sequence before, sequence after) of
                                                            (Right original, Right observed) -> all isJust original && original == observed
                                                            _ -> False
                                                    pure $ Right $ if not unchanged
                                                        then Left "cluster-live: retirement refusal changed protected records"
                                                        else case outcome of
                                                            Left (Owned.ClusterOwnershipStanding RecordClaimedByAnotherGeneration) -> Right ()
                                                            other -> Left ("cluster-live: expected worker generation refusal, got " <> show other)
                        case entered of
                            Left failure -> pure (Left ("cluster-live: preflight entry: " <> show failure))
                            Right (Left reason) -> pure (Left reason)
                            Right (Right ()) -> do
                                putStrLn "cluster-live: wrong-generation retirement refused; records unchanged"
                                pure (Right ())
            _ -> pure (Left "cluster-live: invalid preflight record keys")

bareLivePrecondition :: IO (Either String ())
bareLivePrecondition = do
    substrate <- detect
    case substrate of
        Left err -> pure (Left err)
        Right detected -> do
            host <- buildHostConfig detected
            let missing = filter ((== Nothing) . resolveMaybe host) [Docker, Kind, Kubectl, Helm]
            pure $ case missing of
                [] -> Right ()
                _ -> Left ("cluster-live: missing required host tools: " ++ intercalate ", " (map toolCommandName missing))

readBareConfig :: ProjectCodec scope specDigest BareConfig -> BS.ByteString -> Text -> String -> IO (BareConfig scope)
readBareConfig codec expectedConfig runName progName = do
    path <- siblingProjectConfigPath (T.pack progName)
    cfg <- decodeProjectCodecFile codec path
    if renderScopedProjectConfigBytes codec cfg /= expectedConfig
        then failBare "cluster-live: generated Harness config differs from the retained run"
        else if bareHarnessRun cfg /= Just runName
        then failBare "cluster-live: generated Harness config belongs to another run"
        else if Context.project (bareContext cfg) /= T.pack progName || Context.binary (bareContext cfg) /= T.pack progName
            then failBare "cluster-live: generated Harness config belongs to another project"
            else pure cfg

readBarePlan :: ProjectCodec scope specDigest BareConfig -> BS.ByteString -> Text -> String -> IO ClusterPlan
readBarePlan codec expectedConfig runName progName = do
    cfg <- readBareConfig codec expectedConfig runName progName
    case bareHarnessRun cfg of
        Nothing -> failBare "cluster-live: generated Harness config has no run identity"
        Just observedRun -> do
            profile <- either (failBare . show) pure (mkTestCaseProfile observedRun)
            pure (resolvePlan progName (T.unpack (Context.sourceRoot (bareContext cfg))) profile)

bareSentinelPath :: ClusterPlan -> FilePath
bareSentinelPath plan = dataPath plan </> "cluster-live.sentinel"

bareSentinelBytes :: Text -> String
bareSentinelBytes runName = "hostbootstrap-cluster-live:" ++ T.unpack runName ++ "\n"

{- | Exercise Docker's atomic loopback allocation independently of Kind's
configuration.  Both containers are created at the same time without a host
port argument, inspected by immutable identity, and removed before the case may
report success.
-}
runtimeExposureAssertion :: HostConfig -> ClusterPlan -> IO (Either String ())
runtimeExposureAssertion host plan =
    runtimeExposureAssertionWith (runBareCommand host Docker) failBare (clusterName plan)

bareKubectlArguments :: ClusterPlan -> [String] -> [String]
bareKubectlArguments plan arguments = ["--kubeconfig", clusterKubeconfigPath plan] <> arguments

failBare :: String -> IO a
failBare = throwIO . LifecycleFailure

resolveBareHostConfig :: IO HostConfig
resolveBareHostConfig = detect >>= either failBare buildHostConfig
