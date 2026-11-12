{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Pure cluster-backend decisions and authored fixture compatibility.

The backend joins prepared descriptions to the private ownership transaction.
Value cases apply the real classifications directly. Cases using FakeCluster
exercise a real protected store but receive fixture-authored tool answers;
their subprocesses establish fixture routing and compatibility, not section NN
evidence about Docker, Kind, kubectl or Helm. Actual provider behavior belongs
to the real cluster-live gate. Every fixture case remains present on every host.
-}
module ClusterBackendSpec (tests, withRuntimeExposure) where

import ClusterReconcileSpec (
    withAppliedFixtureCordon,
    withChartWorkloadFixture,
    withClusterFixtureM,
    withHarnessClusterFixtureM,
    withNvkindClusterFixtureM,
 )
import Control.Concurrent (forkFinally, threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (UserInterrupt), fromException)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString as ByteString
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified FakeCluster
import qualified SourceGuard
import SealedExportInventory (pinnedPrivateExportLists)
import HostBootstrap.CLI.Bare.Runtime (runtimeExposureAssertionWith)
import HostBootstrap.Cluster.Backend
import HostBootstrap.Cluster.Lifecycle (
    ClusterDriver (..),
    ClusterPlan (clusterName, clusterNodeSuffixes),
    ClusterProfile (Production),
    mkTestCaseProfile,
    resolvePlan,
    resolvePlanWithDriver,
    retainedClusterProjection,
    retainedClusterName,
    retainedClusterNodeNames,
    retainedClusterStateDirectory,
    retainedClusterKubeconfigPath,
 )
import HostBootstrap.Cluster.Reconcile
import qualified HostBootstrap.Cluster.Resume as Resume
import qualified HostBootstrap.Cluster.Ownership as Owned
import qualified HostBootstrap.Ownership.Object as Object
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect.Run (CapturedRun (..), capturedTriple)
import HostBootstrap.Effect.Vocabulary (hostCommand)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Docker, Helm, Kind, Kubectl, Nvkind), mkAbsExe)
import HostBootstrap.Network.Port (portNumber)
import HostBootstrap.Protected (
    Expectation (ExpectVersion),
    ProtectedRecord (..),
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    mkRecordSegment,
    readProtectedRecord,
    recordTupleSeparator,
    listProtectedRecords,
    openProtectedStore,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, getTemporaryDirectory, removeFile)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (dropTrailingPathSeparator, isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (readFile')
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

fixtureHarnessProfile :: String -> ClusterProfile
fixtureHarnessProfile = either (error . show) id . mkTestCaseProfile . Text.pack

tests :: TestTree
tests =
    testGroup
        "ClusterBackendSpec"
        [ testCase "interrupting bare relay creation removes the recorded names" $
            withBackend $ \host root -> do
                FakeCluster.armBareRelayBlock root
                result <- newEmptyMVar
                let runDocker arguments = fmap capturedTriple <$> Owned.interpretClusterCommand host (hostCommand Docker arguments)
                    awaitCreation = do
                        created <- doesFileExist (root </> "bare-relay-state-bare-live-exposure-a")
                        unless created (threadDelay 10000 >> awaitCreation)
                worker <- forkFinally
                    (runtimeExposureAssertionWith runDocker (ioError . userError) "bare-live")
                    (putMVar result)
                ready <- timeout 30000000 awaitCreation
                case ready of
                    Nothing -> assertFailure "fake Docker did not record relay creation"
                    Just () -> pure ()
                throwTo worker UserInterrupt
                ended <- timeout 30000000 (takeMVar result)
                case ended of
                    Just (Left exception) | Just UserInterrupt <- fromException exception -> pure ()
                    _ -> assertFailure "the interrupted relay assertion did not propagate UserInterrupt"
                FakeCluster.readRelays root >>= (@?= [])
        , testGroup "retained release preflights" retainedReleasePreflightCases
        , testGroup "what the driver's listing means" statusCases
        , testGroup "admitting the declared backend" admissionCases
        , testGroup "the join, driven for real" (joinCases <> stagedConfigCases <> cordonFailureCases)
        , testGroup "no program written in another language" sourceCases
        , testGroup "loopback-bound exposure" exposureCases
        , testGroup "recovered readiness" recoveredReadinessCases
        ]

recoveredReadinessCases :: [TestTree]
recoveredReadinessCases =
    [ testCase "recovered readiness reprobes invoke the runtime service with distinct nonces" $
        recoveredReadinessCase False
    , testCase "recovered readiness propagates refusal on its second runtime probe" $
        recoveredReadinessCase True
    ]

recoveredReadinessCase :: Bool -> IO ()
recoveredReadinessCase refuseSecond = do
    outcome <- withChartWorkloadFixture $ \_plan _cluster _chart _workloads _partition _execution readiness _exposures _backend root -> do
        first <- reprobeClusterReadiness readiness
        firstVersion <- either (assertFailure . show) pure first
        assertBool "the fresh service observation has no positive version" (firstVersion > 0)
        when refuseSecond (FakeCluster.armApiUnready root)
        second <- reprobeClusterReadiness readiness
        if refuseSecond
            then case second of
                Left (Failure detail) ->
                    assertBool "the refusal retains the actual runtime diagnostic" ("not ready" `Text.isInfixOf` failureCause detail)
                other -> assertFailure ("expected the second actual runtime probe to refuse, got " <> show other)
            else case second of
                Right version -> assertBool "the real backend readiness version did not advance" (version > firstVersion)
                other -> assertFailure ("expected a second actual successful runtime probe, got " <> show other)
        requests <- lines <$> readFile' (root </> "runtime-probe-nonces")
        case requests of
            [initialNonce, firstNonce, secondNonce] -> do
                initialNonce @?= "fixture-readiness-nonce"
                assertBool "reprobes reused a runtime request nonce" (firstNonce /= secondNonce && firstNonce /= initialNonce && secondNonce /= initialNonce)
            other -> assertFailure ("expected the initial observation and two actual runtime probe requests, got " <> show other)
        pure (Right ())
    outcome @?= Right ()

-- What a listing means ----------------------------------------------------------

statusCases :: [TestTree]
statusCases =
    [ testCase "the read-only status classification is total over what a driver can say" $ do
        answered "" @?= ClusterStatusAbsent
        answered "demo\n" @?= ClusterStatusPresent
        answered "other\ndemo\n" @?= ClusterStatusPresent
        answered "other\n" @?= ClusterStatusAbsent
        refusesListing "a body with no trailing newline" (answered "demo")
        refusesListing "a carriage return" (answered "demo\r\n")
        refusesListing "a byte outside ASCII" (answered "dem\224\n")
        refusesListing "an empty name" (answered "\n")
        refusesListing "a name outside the portable alphabet" (answered "bad name\n")
        refusesListing "an over-long name" (answered (replicate 129 'x' <> "\n"))
        refusesListing "the same name twice" (answered "demo\ndemo\n")
    , testCase "a command that produced no child is not an absence" $
        refusesListing "no process at all" (classifyClusterStatus "demo" (Left "kind not found"))
    , testCase "a non-zero exit and a noisy success are each refusals" $ do
        refusesListing "a non-zero exit" (classifyClusterStatus "demo" (ran (ExitFailure 1) "demo\n" ""))
        refusesListing "anything at all on standard error" (classifyClusterStatus "demo" (ran ExitSuccess "demo\n" "warning\n"))
    ]
  where
    answered payload = classifyClusterStatus "demo" (ran ExitSuccess payload "")

ran :: ExitCode -> String -> String -> Either String CapturedRun
ran code out err = Right (CapturedRun{capturedExit = code, capturedStdout = out, capturedStderr = err})

refusesListing :: String -> ClusterStatusObservation -> IO ()
refusesListing label observed = case observed of
    ClusterStatusProbeFailed _ -> pure ()
    other -> assertFailure ("the status classification admitted " <> label <> ": " <> show other)

-- Admitting the declared backend -------------------------------------------------

admissionCases :: [TestTree]
admissionCases =
    [ testCase "a configuration missing one cluster tool mints no capability" $
        forM_ [Kind, Docker, Kubectl, Helm] $ \omitted -> do
            self <- getExecutablePath
            outcome <- withClusterFixtureM $ \prepared -> do
                discovered <- discoverPrepared (hostConfigWithout self omitted) prepared
                pure (Right (() <$ discovered))
            case outcome of
                Right (Left (Unsupported _)) -> pure ()
                other -> assertFailure ("a missing tool must mint no backend, got " <> show other)
    , testCase "an invalid or expanded exposure address creates no store" $
        withBackend $ \cfg root -> do
            let state = root </> "uncreated-exposure-store"
            forM_ ["bad/name", replicate 100 'A'] $ \name -> do
                observed <- observeRecordedClusterExposure cfg state name "web"
                case observed of
                    Left (Failure _) -> pure ()
                    _ -> assertFailure "an invalid exposure address was not refused"
                doesDirectoryExist state >>= (@?= False)
            FakeCluster.recordedClusterMutations root >>= (@?= [])
    , testCase "a configuration carrying the required tools is admitted" $ do
        self <- getExecutablePath
        outcome <- withClusterFixtureM $ \prepared -> do
            discovered <- discoverPrepared (clusterHostConfig self) prepared
            pure (Right (() <$ discovered))
        case outcome of
            Right (Right ()) -> pure ()
            other -> assertFailure ("expected an admitted backend, got " <> show other)
    , testCase "nvkind discovery requires both nvkind creation and Kind ownership tools" $ do
        self <- getExecutablePath
        outcome <- withNvkindClusterFixtureM $ \prepared -> do
            let configured = clusterHostConfig self
                withoutKind = configured{hcToolPaths = Map.delete Kind (hcToolPaths configured)}
                withoutNvkind = configured{hcToolPaths = Map.delete Nvkind (hcToolPaths configured)}
            admitted <- discoverPrepared configured prepared
            (() <$ admitted) @?= Right ()
            noKind <- discoverPrepared withoutKind prepared
            (() <$ noKind) @?= Left (Unsupported (UnsupportedDetail "reconcile cluster" "required cluster tool was not resolved through HostConfig: kind"))
            noNvkind <- discoverPrepared withoutNvkind prepared
            (() <$ noNvkind) @?= Left (Unsupported (UnsupportedDetail "reconcile cluster" "required cluster tool was not resolved through HostConfig: nvkind"))
            pure (Right ())
        outcome @?= Right ()
    , testCase "a discovered Kind backend refuses an nvkind package" $ do
        self <- getExecutablePath
        outcome <- withClusterFixtureM $ \kindPrepared -> do
            backend <- requireBackend (clusterHostConfig self) kindPrepared
            nested <- withNvkindClusterFixtureM $ \nvkindPrepared -> do
                observed <- runClusterStatusCall backend nvkindPrepared
                pure (Right observed)
            pure (Right nested)
        case outcome of
            Right (Right (ClusterStatusProbeFailed reason)) -> assertBool "the mismatch does not name the driver" ("driver differs" `Text.isInfixOf` reason)
            other -> assertFailure ("expected a pre-command driver mismatch, got " <> show other)
    , testCase "the exact package projects absolute backend paths" $ do
        outcome <-
            withClusterFixtureM $ \prepared ->
                pure
                    ( Right
                        ( isAbsolute (preparedClusterStateDirectory prepared)
                            && maybe True isAbsolute (preparedClusterConfigPath prepared)
                        )
                    )
        outcome @?= Right True
    , testCase "a Harness package retains its isolated driver configuration" $ do
        outcome <-
            withHarnessClusterFixtureM
                (\prepared -> pure (Right (preparedClusterConfigPath prepared)))
        case outcome of
            Right (Just path) -> assertBool "Harness config is not the exact driver path" (("cluster" </> "kind" </> "config.yaml") `isSuffixOf` path)
            other -> assertFailure ("expected an isolated Harness config path, got " ++ show other)
    ]

hostConfigWithout :: FilePath -> HostTool -> HostConfig
hostConfigWithout self omitted =
    let full = clusterHostConfig self
     in full{hcToolPaths = Map.delete omitted (hcToolPaths full)}

clusterHostConfig :: FilePath -> HostConfig
clusterHostConfig self =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64
        , hcToolPaths =
            Map.fromList [(Kind, fixtureExe (FakeCluster.fixtureToolPath self "kind")), (Docker, fixtureExe (FakeCluster.fixtureToolPath self "docker")), (Kubectl, fixtureExe (FakeCluster.fixtureToolPath self "kubectl")), (Helm, fixtureExe (FakeCluster.fixtureToolPath self "helm")), (Nvkind, fixtureExe (FakeCluster.fixtureToolPath self "nvkind"))]
        }

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

discoverPrepared ::
    HostConfig ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError StrongClusterBackend)
discoverPrepared cfg prepared =
    withPreparedPlanOwnedClusterConfig prepared (discoverStrongClusterBackend cfg)

requireBackend ::
    HostConfig ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO StrongClusterBackend
requireBackend cfg prepared = do
    discovered <- discoverPrepared cfg prepared
    either (assertFailure . show) pure discovered

-- The join, driven for real -------------------------------------------------------

cordonFailureCases :: [TestTree]
cordonFailureCases =
    [ testCase label $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                createdResult <- runClusterReconcileCall backend prepared
                case settleClusterReconcile Nothing prepared createdResult of
                    Left err -> pure (Left err)
                    Right created ->
                        withClusterReconcileSettlement
                            created
                            ( \managed _ _ ->
                                case withPreparedClusterCordon prepared managed id of
                                    Left err -> pure (Left err)
                                    Right cordon -> do
                                        arm root
                                        observed <- runClusterCordonCall backend cordon
                                        case clusterCordonResultView observed of
                                            ClusterCordonResultFailed reason ->
                                                assertBool "the failed observation retains the runtime's diagnostic" (diagnostic `Text.isInfixOf` reason)
                                            _ -> assertFailure "a failed runtime update must not report an applied cordon"
                                        case settleClusterCordon cordon observed of
                                            Left (Failure detail) -> failedOperation detail @?= "apply exact cluster cordon"
                                            _ -> assertFailure "a failed runtime update must offer no AppliedClusterCordon"
                                        FakeCluster.recordedClusterMutations root >>= (@?= expectedMutations)
                                        pure (Right ())
                            )
                            (\_ _ _ _ -> assertFailure "the created fixture cluster must be managed")
        outcome @?= Right ()
    | (label, arm, diagnostic, expectedMutations) <-
        [ ("a refused Docker update offers no applied cordon", FakeCluster.armUpdateRefusal, "the cluster runtime refused the update", ["create"])
        , ("a successful Docker update with stderr offers no applied cordon", FakeCluster.armUpdateStderr, "the cluster runtime emitted update stderr", ["create", "update"])
        ]
    ]

stagedConfigCases :: [TestTree]
stagedConfigCases =
    [ testCase label $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                let consumerPath = maybe (error "fixture has no config path") id (preparedClusterConfigPath prepared)
                    expected = preparedClusterConfigBytes prepared
                createDirectoryIfMissing True (takeDirectory consumerPath)
                ByteString.writeFile consumerPath expected
                alter consumerPath
                result <- runClusterReconcileCall backend prepared
                case clusterReconcileResultView result of
                    ClusterResultCreated _ -> pure ()
                    other -> assertFailure ("expected creation from prepared bytes, got " <> show other)
                FakeCluster.recordedConfigFiles root >>= \case
                    [(stagedPath, bytes)] -> do
                        bytes @?= expected
                        assertBool "creation used a private config path" (stagedPath /= consumerPath)
                        FakeCluster.recordedKubeconfigPaths root >>= \case
                            [credentialPath] -> takeDirectory stagedPath @?= takeDirectory credentialPath
                            paths -> assertFailure ("expected one staged credential, got " <> show paths)
                        doesFileExist stagedPath >>= (@?= False)
                        doesDirectoryExist (takeDirectory stagedPath) >>= (@?= False)
                    other -> assertFailure ("expected one actual config read, got " <> show other)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                pure (Right ())
        outcome @?= Right ()
    | (label, alter) <-
        [ ("creation reads unchanged prepared config bytes", const (pure ()))
        , ("creation ignores an overwritten consumer config file", \path -> ByteString.writeFile path "foreign config bytes\n")
        , ("creation ignores a removed consumer config file", removeFile)
        ]
    ]

joinCases :: [TestTree]
joinCases =
    [ testCase "a fresh reconcile creates and binds the control plane" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                listed <- FakeCluster.readClusters root
                pure
                    ( Right
                        ( clusterReconcileResultView observed
                        , mutations
                        , listed == [preparedClusterName prepared]
                        )
                    )
        case outcome of
            Right (ClusterResultCreated identity, mutations, listedOwnCluster) -> do
                assertBool "the bound identity is not empty" (not (Text.null identity))
                mutations @?= ["create"]
                listedOwnCluster @?= True
            other -> assertFailure ("expected a created cluster, got " <> show other)
    , testCase "a recreated record names its observed identity without advancing stale readiness" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                withAppliedFixtureCordon backend prepared $ \oldApplied -> do
                    first <- runClusterReadinessCall backend oldApplied
                    clusterReadinessResultView first @?= ClusterReadinessResultReady 1
                        (Text.pack (FakeCluster.fixtureNodeIdentity (preparedClusterName prepared <> "-control-plane")))
                    let stateRoot = preparedClusterStateDirectory prepared
                        durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                        plan = resolvePlan (preparedClusterName prepared) (takeDirectory durableRoot) Production
                    oldRecords <- recordSnapshotsUnder stateRoot
                    assertBool "the first generation has no records" (not (null oldRecords))
                    releaseRetainedCluster cfg plan >>= (@?= Right ())
                    recordSnapshotsUnder stateRoot >>= (@?= [])
                    FakeCluster.armReplacementAfter root "create"
                    withAppliedFixtureCordon backend prepared $ \newApplied -> do
                        stale <- runClusterReadinessCall backend oldApplied
                        clusterReadinessResultView stale @?= ClusterReadinessResultNotReady
                            (Text.pack FakeCluster.replacementIdentity)
                        fresh <- runClusterReadinessCall backend newApplied
                        clusterReadinessResultView fresh @?= ClusterReadinessResultReady 2
                            (Text.pack FakeCluster.replacementIdentity)
                        FakeCluster.recordedClusterMutations root >>= (@?= ["create", "update", "delete", "create", "update"])
                        pure (Right ())
        outcome @?= Right ()
    , testCase "the identity bound is the one the runtime answered for the control plane" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                observed <- runClusterReconcileCall backend prepared
                let controlPlane = take 1 (preparedClusterNodeNames prepared)
                    expected = map (Text.pack . FakeCluster.fixtureNodeIdentity) controlPlane
                pure (Right (clusterReconcileResultView observed, expected))
        case outcome of
            Right (ClusterResultCreated identity, [expected]) -> identity @?= expected
            other -> assertFailure ("expected the control plane's own identity, got " <> show other)
    , testCase "the durable record lives under the plan's own state directory" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                Right . length <$> recordsUnder (preparedClusterStateDirectory prepared)
        outcome @?= Right (1 :: Int)
    , testCase "retained reverse conditionally deletes the cluster and retires its record" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    projectRoot = takeDirectory durableRoot
                    plan = resolvePlan (preparedClusterName prepared) projectRoot Production
                released <- releaseRetainedCluster cfg plan
                remaining <- FakeCluster.readClusters root
                records <- recordsUnder stateRoot
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (released, remaining, records, mutations))
        case outcome of
            Right (Right (), [], [], mutations) -> mutations @?= ["create", "delete"]
            other -> assertFailure ("expected retained cluster release, got " <> show other)
    , testCase "retained cleanup re-probes a successful modeled delete whose node remains" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                created <- runClusterReconcileCall backend prepared
                clusterReconcileResultView created @?= ClusterResultCreated (Text.pack (FakeCluster.fixtureNodeIdentity (preparedClusterName prepared <> "-control-plane")))
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    plan = resolvePlan (preparedClusterName prepared) (takeDirectory durableRoot) Production
                before <- recordSnapshotsUnder stateRoot
                nodes <- FakeCluster.readNodes root
                FakeCluster.armDeleteNoop root
                released <- releaseRetainedCluster cfg plan
                released @?= Left (Failure (FailureDetail "release retained cluster" "the runtime still reports an owned node" ReprobeBeforeRetry))
                recordSnapshotsUnder stateRoot >>= (@?= before)
                FakeCluster.readNodes root >>= (@?= nodes)
                FakeCluster.readClusters root >>= (@?= [preparedClusterName prepared])
                FakeCluster.recordedClusterMutations root >>= (@?= ["create", "delete"])
                pure (Right ())
        outcome @?= Right ()
    , testCase "retained backend refuses a replacement and preserves exact records" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                created <- runClusterReconcileCall backend prepared
                clusterReconcileResultView created @?= ClusterResultCreated (Text.pack (FakeCluster.fixtureNodeIdentity (preparedClusterName prepared <> "-control-plane")))
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    plan = resolvePlan (preparedClusterName prepared) (takeDirectory durableRoot) Production
                before <- recordSnapshotsUnder stateRoot
                nodes <- FakeCluster.readNodes root
                FakeCluster.writeNodes root [(name,node{FakeCluster.nodeIdentity = FakeCluster.replacementIdentity}) | (name,node) <- nodes]
                replacements <- FakeCluster.readNodes root
                originalIdentity <- either (assertFailure . show) pure (Object.mkObjectIdentity
                    (TextEncoding.encodeUtf8 (Text.pack (FakeCluster.fixtureNodeIdentity (preparedClusterName prepared <> "-control-plane")))))
                replacementIdentity <- either (assertFailure . show) pure (Object.mkObjectIdentity
                    (TextEncoding.encodeUtf8 (Text.pack FakeCluster.replacementIdentity)))
                released <- releaseRetainedCluster cfg plan
                case released of
                    Left (Failure detail) -> do
                        failedOperation detail @?= "release retained cluster"
                        recoveryDisposition detail @?= ReprobeBeforeRetry
                        failureCause detail @?= Resume.clusterStandingConflictMessage (Resume.NodeReplaced originalIdentity replacementIdentity)
                    other -> assertFailure ("expected replacement refusal: " <> show other)
                recordSnapshotsUnder stateRoot >>= (@?= before)
                FakeCluster.readNodes root >>= (@?= replacements)
                FakeCluster.readClusters root >>= (@?= [preparedClusterName prepared])
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                pure (Right ())
        outcome @?= Right ()
    , testCase "retained cleanup preserves every record when the driver refuses delete" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    plan = resolvePlan (preparedClusterName prepared) (takeDirectory durableRoot) Production
                recordsBefore <- recordsUnder stateRoot
                assertBool "the owned fixture has no cluster record" (not (null recordsBefore))
                nodesBefore <- FakeCluster.readNodes root
                FakeCluster.armDeleteRefusal root
                released <- releaseRetainedCluster cfg plan
                case released of
                    Left (Failure detail) -> do
                        failedOperation detail @?= "release retained cluster"
                        assertBool "the failure lost the actual delete refusal" ("the cluster client refused the delete it was asked for" `Text.isInfixOf` failureCause detail)
                    other -> assertFailure ("expected retained deletion refusal, got " <> show other)
                FakeCluster.readClusters root >>= (@?= [preparedClusterName prepared])
                FakeCluster.readNodes root >>= (@?= nodesBefore)
                recordsUnder stateRoot >>= (@?= recordsBefore)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                pure (Right ())
        outcome @?= Right ()
    , testCase "retained Harness projection contains the exact run-scoped coordinates" $
        forM_ [(KindDriver, "kind", ["control-plane"]), (NvkindDriver, "nvkind", ["control-plane", "worker"])] $ \(driver, driverName, suffixes) -> do
            let projectRoot = "project-root" </> "consumer"
                retained = retainedClusterProjection (resolvePlanWithDriver "project" projectRoot (fixtureHarnessProfile "run-17") driver)
                expectedName = "project-test-run-17"
                expectedState = projectRoot </> ".test_data" </> "run-17" </> "cluster" </> driverName </> "state"
            retainedClusterName retained @?= expectedName
            retainedClusterNodeNames retained @?= map ((expectedName <> "-") <>) suffixes
            retainedClusterStateDirectory retained @?= expectedState
            retainedClusterKubeconfigPath retained @?= expectedState </> "cluster.kubeconfig"
    , testCase "retained Harness reverse resolves the exact run-scoped store" $ do
        outcome <- withBackend $ \cfg root ->
            withHarnessClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    runName = takeFileName durableRoot
                    projectRoot = takeDirectory (takeDirectory durableRoot)
                    suffix = Text.pack ("-test-" <> runName)
                projectName <-
                    maybe
                        (assertFailure "the Harness cluster name lacks its exact run suffix")
                        (pure . Text.unpack)
                        (Text.stripSuffix suffix (Text.pack (preparedClusterName prepared)))
                let plan = resolvePlan projectName projectRoot (fixtureHarnessProfile runName)
                released <- releaseRetainedCluster cfg plan
                remaining <- FakeCluster.readClusters root
                records <- recordsUnder stateRoot
                pure (Right (released, remaining, records))
        outcome @?= Right (Right (), [], [])
    , testCase "the creating client stages locally and the exact credential lands in durable state" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                stagingPaths <- FakeCluster.recordedKubeconfigPaths root
                stagingPresent <- traverse doesFileExist stagingPaths
                temporaryRoot <- getTemporaryDirectory
                durable <- readFile' (preparedClusterStateDirectory prepared </> "cluster.kubeconfig")
                pure (Right (preparedClusterName prepared, stagingPaths, stagingPresent, temporaryRoot, durable))
        case outcome of
            Right (name, [staging], [False], temporaryRoot, durable) -> do
                takeDirectory (takeDirectory staging) @?= dropTrailingPathSeparator temporaryRoot
                assertBool "the local staging path is absolute" (isAbsolute staging)
                assertBool
                    "the staging path names the exact cluster"
                    ( (".hostbootstrap-kind-" <> name)
                        `isPrefixOf` takeFileName staging
                    )
                durable @?= FakeCluster.fixtureKubeconfig name
            other -> assertFailure ("expected one removed local stage and one exact durable credential, got " <> show other)
    , testCase "an exact repeat is healthy and creates nothing more" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultHealthy _, mutations) -> mutations @?= ["create"]
            other -> assertFailure ("expected a healthy cluster, got " <> show other)
    , testCase "an owned cluster whose containers stopped is unhealthy, never recreated" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                stopEveryNode root
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultUnhealthy _, mutations) -> mutations @?= ["create"]
            other -> assertFailure ("expected an unhealthy cluster, got " <> show other)
    , testCase "a cluster no record of this project's claims is foreign and is not touched" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                FakeCluster.writeClusters root [preparedClusterName prepared]
                FakeCluster.writeNodes
                    root
                    [ (node, FakeCluster.ClusterNode (replicate 64 'a') True [])
                    | node <- preparedClusterNodeNames prepared
                    ]
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultForeign identity, mutations) -> do
                identity @?= Text.replicate 64 "a"
                mutations @?= []
            other -> assertFailure ("expected a foreign cluster, got " <> show other)
    , testCase "the read-only status path asks the driver and decides from the bytes" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                absent <- runClusterStatusCall backend prepared
                _ <- runClusterReconcileCall backend prepared
                present <- runClusterStatusCall backend prepared
                pure (Right (absent, present))
        outcome @?= Right (ClusterStatusAbsent, ClusterStatusPresent)
    ]

{- | Every durable record this run's own state directory holds.

Read through the protected store's own listing rather than off the filesystem,
because where a record lives inside the store is the store's business and what
this case is about is that the records are the store's at all.
-}
recordsUnder :: FilePath -> IO [RecordKey]
recordsUnder stateDirectory = do
    opened <- openProtectedStore stateDirectory
    store <- either (assertFailure . show) pure opened
    outcome <- withProtectedEntry store listProtectedRecords
    either (assertFailure . show) pure outcome

{- | Declare the plan's own node set to the fixture's driver.

The topology a real driver establishes comes out of its configuration snapshot,
so the fixture is told the node names rather than guessing them from a filename.
-}
declare ::
    FilePath ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO ()
declare root prepared = FakeCluster.declareNodes root (preparedClusterNodeNames prepared)

stopEveryNode :: FilePath -> IO ()
stopEveryNode root = do
    held <- FakeCluster.readNodes root
    FakeCluster.writeNodes root [(name, node{FakeCluster.nodeRunning = False}) | (name, node) <- held]

-- | An admitted model backend with one executable name per fixture tool.
withBackend :: (HostConfig -> FilePath -> IO result) -> IO result
withBackend consume =
    withSystemTempDirectory "hostbootstrap-cluster-backend" $ \temporary -> do
        root <- canonicalizePath temporary
        _ <- FakeCluster.newClusterFixture root []
        self <- FakeCluster.prepareFixtureExecutables root
        FakeCluster.withFakeClusterClient root (consume (clusterHostConfig self) root)

-- No program written in another language --------------------------------------------

{- | The absence this sprint's whole subject is, held mechanically.

A guard over the sources themselves rather than over a run, because what is being
asserted is that there is nowhere left for such a program to be: it fires on a
reintroduced interpreter or locking front end instead of waiting for a fixture to
happen to reach one. [rationale.md](rationale.md) says why a program carried in a
string is refused — it parses its own protocol, restates invariants its caller
already states, and has to be reviewed in two languages.

The positive half matters as much as the negative one: a guard that only forbade
the old names would stay quiet over a backend that had stopped driving anything at
all, so it also asserts that the boundary still reaches the described commands and
the clause-holding driver.
-}
sourceCases :: [TestTree]
sourceCases =
    [ testCase "reconciliation and its running check share one exact protected entry" $ do
        source <- backendSource
        body <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "runClusterReconcileCall" source)
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "withClusterTransaction") (unwords body) @?= 1
        forM_ [ "Owned.reconcileOwnedCluster (strongClusterDriver backend) cfg session key owned"
              , "Owned.ownedClusterRunning cfg session key owned"
              , "Owned.observeOwnedNode cfg (Owned.ownedClusterControlPlane owned)"
              ] $ \sequenceText ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) (unwords body) @?= 1
    , testCase "readiness carries the post-probe control-plane identity into its version guard" $ do
        backend <- backendSource
        body <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "runClusterReadinessCall" backend)
        forM_ [ "Right (observedIdentity, readyOutcome)"
              , "actualIdentity = identityText observedIdentity"
              , "if actualIdentity /= expectedIdentity then ClusterNotReady actualIdentity"
              , "ClusterReady identity | identity == expectedIdentity"
              , "advanced <- nextReadinessVersion readinessVersion"
              ] $ \sequenceText ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) (unwords body) @?= 1
        root <- repositoryRoot
        owned <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile
            (root </> "core" </> "hostbootstrap-core" </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
        observed <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "observeOwnedClusterReadiness" owned)
        forM_ [ "after <- ownedClusterNodes cfg session key owned"
              , "nodes <- after"
              , "node == ownedClusterControlPlane owned"
              , "[identity] -> Right (identity, outcome)"
              , "_ -> Left (nodeNoLongerOwned (ownedClusterControlPlane owned))"
              ] $ \sequenceText ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) (unwords observed) @?= 1
    , testCase "forward and retained cluster targets validate canonical worker keys before storage" $ do
        source <- backendSource
        target <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "clusterCallTarget" source)
        forM_ [ "Owned.ownedClusterRecordKey owned"
              , "traverse (Owned.ownedNodeRecordKey owned) workers"
              , "clusterExposureRecordKey name"
              ] $ \sequenceText ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) (unwords target) @?= 1
        retained <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "releaseRetainedCluster" source)
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "clusterCallTarget (retainedClusterName retained) stateDirectory nodes Nothing Nothing")
            (unwords retained) @?= 1
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "Right (ClusterCallTarget _ target) -> releaseTarget target")
            (unwords retained) @?= 1
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "openProtectedStore stateDirectory") (unwords retained) @?= 1
    , testCase "retained release checks actual record presence and shares node completion classification" $ do
        source <- backendSource
        preflight <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "releaseClusterAfterExposure" source)
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "record <- readProtectedRecord session key") (unwords preflight) @?= 1
        forM_ ["\"the cluster ownership record is absent\"", "Owned.releaseRetainedOwnedCluster cfg session key owned"] $ \sequenceText ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) (unwords preflight) @?= 1
        root <- repositoryRoot
        raw <- ByteString.readFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
        owned <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
        completion <- concat <$> either assertFailure pure (SourceGuard.haskellDefinitionClauseTokens "everyNodeGone" owned)
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "nodeRemovalComplete expected origin") (unwords completion) @?= 1
    , testCase "release resumes only through actual node observations and the shared removal primitive" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            raw <- ByteString.readFile (packageRoot </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
            release <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "releaseClusterForClaim" source)
            forM_ ["clusterReleaseStanding", "releaseClusterNodes", "withBoundNodeClaim", "removeOwnedCluster"] $ \name ->
                assertBool ("release lost " <> name) (name `elem` release)
            nodes <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "releaseClusterNodes" source)
            forM_ ["observeOwnedNode", "readRecordUnder", "nodeReleaseStanding", "bindOneNodeForClaim"] $ \name ->
                assertBool ("release node entry lost " <> name) (name `elem` nodes)
            removal <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "removeOwnedCluster" source)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "reobserveReportedIdentity witness origin") (unwords removal) @?= 1
            forM_ ["observeOwnedNode", "withBoundNodeClaim", "everyNodeGone", "deleteClusterCommand"] $ \name ->
                assertBool ("conditional deletion lost " <> name) (name `elem` removal)
            finish <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "finishOwnedRelease" source)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "resumeReportedRemoval bound OriginAbsent") (unwords finish) @?= 1
            origins <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "forgetEveryRecordForClaim" source)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "ownedClusterWorkers owned <> [ownedClusterControlPlane owned]") (unwords origins) @?= 1
    , testCase "refused creation observes actual absence before retiring the same entry's origins" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            raw <- ByteString.readFile (packageRoot </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
            create <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "createThenBind" source)
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "Left <$> settleRefusedCreate cfg session key owned") (unwords create) @?= 2
            refusal <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "settleRefusedCreate" source)
            forM_ ["observeOwnedClusterPresence", "observeOwnedNode", "refusedCreateOriginsMayRetire"] $ \name ->
                assertBool ("refused create retirement lost " <> name) (name `elem` refusal)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "forgetEveryRecordForClaim (ownedClusterClaim owned) session key owned")
                (unwords refusal) @?= 1
    , testCase "cluster credentials sync before binding through the canonical publication primitives" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            raw <- ByteString.readFile (packageRoot </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
            assertBool "cluster publication must import the shared primitives"
                (SourceGuard.importsModule "HostBootstrap.Protected.Publication" source)
            publisher <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "atomicPublishKubeconfig" source)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "syncPublishedFile temporary renamePublishedFile temporary destination syncPublishedParent destination")
                (unwords publisher) @?= 1
            reconciliation <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "reconcileOwnedCluster" source)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "Right (ClusterOwned identity) -> do published <- publishOwnedClusterKubeconfig cfg owned")
                (unwords reconciliation) @?= 1
    , testCase "cluster ownership stays private and retains its exact reviewed exports" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            private <- maybe (assertFailure "the private cluster ownership unit is absent") pure
                (SourceGuard.namedStanza "library cluster-ownership-internal" description)
            SourceGuard.fieldValues "visibility" private @?= ["private"]
            SourceGuard.fieldValues "hs-source-dirs" private @?= ["internal/cluster-ownership"]
            public <- either assertFailure pure (SourceGuard.effectiveMainExposedModules description)
            let ownershipModule = "HostBootstrap.Cluster.Ownership"
            assertBool "downstream components can import the ownership transaction" (ownershipModule `notElem` public)
            forM_ ["HostBootstrap.Cluster.Command", "HostBootstrap.Cluster.Report", "HostBootstrap.Cluster.Resume",
                   "HostBootstrap.Cluster.Cordon", "HostBootstrap.Cluster.Cordon.Foundation", "HostBootstrap.Effect.Interpreter"] $ \name ->
                assertBool ("the existing public dependency disappeared: " <> name) (name `elem` public)
            raw <- ByteString.readFile (packageRoot </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
            source <- either (assertFailure . show) (pure . Text.unpack) (TextEncoding.decodeUtf8' raw)
            expected <- maybe (assertFailure "the reviewed private ownership exports are absent") pure
                (lookup ownershipModule pinnedPrivateExportLists)
            SourceGuard.moduleExportTokens ownershipModule source @?= Just (SourceGuard.haskellTokens expected)
    , testCase "workers bind before the root and every recovery retains the generation claim" $ do
        root <- repositoryRoot
        owned <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
        binding <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "bindNodeRecords" owned)
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "ownedClusterWorkers owned <> [ownedClusterControlPlane owned]") (unwords binding) @?= 1
        worker <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "requireOwnedWorkers" owned)
        forM_ ["bindOneNodeForClaim", "ownedClusterClaim", "ClusterRecovered", "ClusterAlreadyOwned"] $ \name ->
            assertBool ("worker reconciliation lost " <> name) (name `elem` worker)
        nodes <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "ownedClusterNodesForClaim" owned)
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "bindOneNodeForClaim expected cfg session nodeKey owned node") (unwords nodes) @?= 1
        resume <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "bindOneNodeForClaim" owned)
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "withRecordedNodeClaim session nodeKey owned node expected") (unwords resume) @?= 1
    , testCase "live generation assertions use real entries and immutable state snapshots" $ do
        root <- repositoryRoot
        bare <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "CLI" </> "Bare.hs")
        suite <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "bareClusterLiveSuite" bare)
        forM_ ["assertBareClaimGeneration", "assertBareRetirementPreflight"] $ \name ->
            assertBool ("the live suite does not execute " <> name) (name `elem` suite)
        generation <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "assertBareClaimGeneration" bare)
        forM_ ["withProtectedEntry", "RecordClaimedByAnotherGeneration"] $ \name ->
            assertBool ("the live claim assertion lost " <> name) (name `elem` generation)
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "Owned.reconcileOwnedCluster") (unwords generation) @?= 1
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "bareStatusSnapshot host plan") (unwords generation) @?= 2
        retirement <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "assertBareRetirementPreflight" bare)
        forM_ ["withProtectedEntry", "recordTape", "publishFreshRecord", "readProtectedRecord", "RecordClaimedByAnotherGeneration"] $ \name ->
            assertBool ("the real retirement assertion lost " <> name) (name `elem` retirement)
        forM_ ["Owned.ownedClusterStanding", "Owned.observeOwnedNode", "Owned.releaseOwnedCluster"] $ \name ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens name) (unwords retirement) @?= 1
    , testCase "cluster standings and record retirement retain the exact expected generation claim" $ do
        root <- repositoryRoot
        owned <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "cluster-ownership" </> "HostBootstrap" </> "Cluster" </> "Ownership.hs")
        forM_ ["ownedClusterStandingForClaim = ownedClusterStandingUsing clusterStanding", "decide expected record listed origin"] $ \sequenceText ->
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) owned @?= 1
        forM_ ["bindOneNodeForClaim", "requireOwnedNode"] $ \name -> do
            body <- either assertFailure pure (SourceGuard.haskellDefinitionTokens name owned)
            SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "nodeStanding expected record origin") (unwords body) @?= 1
        retained <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "releaseRetainedOwnedCluster" owned)
        forM_ ["retainedClaim", "releaseClusterForClaim"] $ \name ->
            assertBool ("retained release lost its stored-claim path: " <> name) (name `elem` retained)
        shared <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "releaseClusterForClaim" owned)
        forM_ [ "ownedClusterStandingUsing clusterReleaseStanding claim cfg session key owned"
              , "releaseClusterNodes claim cfg session key owned"
              , "releaseUnboundOrigins claim cfg session key owned"
              , "withBoundNodeClaim session key (ownedClusterControlPlane owned) claim identity"
              ] $ \sequenceText ->
            assertBool ("shared release lost its exact claim: " <> sequenceText)
                (SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens sequenceText) (unwords shared) > 0)
        preflight <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "forgetEveryRecordForClaim" owned)
        forM_ ["checkClaims", "validateClusterOriginRecord", "forgetNodeRecords"] $ \name ->
            assertBool ("record retirement lost its all-record preflight: " <> name) (name `elem` preflight)
    , testCase "API diagnostics reach the private observation, descriptive view and refusal" $ do
        backend <- backendSource
        root <- repositoryRoot
        reconcile <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Cluster" </> "Reconcile.hs")
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "Owned.ClusterApiUnready diagnostic -> ClusterApiNotReady actualIdentity diagnostic") backend @?= 1
        view <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "clusterReadinessResultView" reconcile)
        forM_ ["ClusterApiNotReady", "apiNotReadyMessage", "diagnostic"] $ \name ->
            assertBool ("the readiness view lost " <> name) (name `elem` view)
        settlement <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "settleClusterReadinessObservation" reconcile)
        forM_ ["ClusterApiNotReady", "clusterApiNotReadyRefusal", "managedClusterKey", "managedClusterBackendIdentity", "diagnostic"] $ \name ->
            assertBool ("readiness settlement lost " <> name) (name `elem` settlement)
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "ClusterReadinessResultNotReady reason -> Left reason") backend @?= 1
    , testCase "status uses one bounded observation without opening ownership" $ do
        source <- backendSource
        forM_ ["runClusterStatusCall", "runRetainedClusterStatusCall", "observeClusterStatus"] $ \name -> do
            body <- either assertFailure pure (SourceGuard.haskellDefinitionTokens name source)
            forM_ ["openProtectedStore", "withProtectedEntry", "runClusterReconcileCall", "compareAndSwapProtectedRecord", "carryClusterReconcileSettlement", "runTool", "interpretHostCommand"] $ \mutation ->
                assertBool ("status reaches an ownership or unbounded operation: " <> mutation) (mutation `notElem` body)
        prepared <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "runClusterStatusCall" source)
        assertBool "prepared status lost binding validation" ("validateReconcileBinding" `elem` prepared)
        retained <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "runRetainedClusterStatusCall" source)
        assertBool "retained status lost its single projection" ("retainedClusterProjection" `elem` retained && "retainedClusterName" `elem` retained)
        query <- either assertFailure pure (SourceGuard.haskellDefinitionTokens "observeClusterStatus" source)
        forM_ ["classifyClusterStatus", "listClustersCommand"] $ \name ->
            assertBool ("status lost its shared decision/query: " <> name) (name `elem` query)
        SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "Owned.interpretClusterCommand") (unwords query) @?= 1
    , testCase "the lifecycle package exposes planning without a second execution route" $ do
        root <- repositoryRoot
        source <- readFile' (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Cluster" </> "Lifecycle.hs")
        definitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
        forM_ ["clusterCreate", "clusterDelete", "clusterDown", "clusterTeardown", "createCluster", "ensureCluster", "clusterHealthy", "clusterHealthyFromProbe", "applyLinuxCordon", "waitNodesReady", "_clusterUp", "_clusterStatus", "statusReport", "deployChart", "probeNvidiaRuntime", "ensureNvidiaRuntimeClass", "ensureNvidiaDevicePlugin", "removeAll", "reportStep", "requireStep", "clusterCreateTool", "clusterCreateArgs", "clusterCreateLabel", "clusterConfigPresence"] $ \name ->
            assertBool ("a second lifecycle execution entry remains: " <> name) (name `notElem` definitions)
        forM_ ["teardown", "resolvePlan", "clusterNodeNames", "withExecutionOwnedCluster", "withPlanOwnedClusterConfig"] $ \name ->
            assertBool ("a shared planning definition disappeared: " <> name) (name `elem` definitions)
        SourceGuard.countHaskellIdentifier "runTool" source @?= 0
    , testCase "the independent live gate uses the owned backend and a real provider dependency" $ do
        root <- repositoryRoot
        source <- readFile' (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "CLI" </> "Bare.hs")
        forM_ ["withExecutionOwnedCluster", "withPlanOwnedClusterConfig", "discoverStrongClusterBackend", "runClusterReconcileCall", "runClusterCordonCall", "runClusterReadinessCall", "releaseRetainedCluster", "withFreshCarriedRunningProviderDependency", "registerRunningProviderDependencyPackage", "interpretClusterCommand", "clusterKubeconfigPath plan"] $ \name ->
            assertBool ("the live gate does not reach " <> name) (name `isInfixOf` source)
        forM_ ["clusterCreate", "clusterDelete", "runTool", "interpretHostCommand"] $ \name ->
            assertBool ("the live gate retains " <> name) (not (name `isInfixOf` source))
    , testCase "the cluster backend names no interpreter and no locking front end" $ do
        source <- backendSource
        forM_ forbiddenNames $ \name ->
            assertBool
                (name <> " is named in the cluster backend")
                (not (name `isInfixOf` source))
    , testCase "retained release reads only one projection without a durable root" $ do
        source <- backendSource
        let body =
                takeWhile (not . isPrefixOf "releaseClusterAfterExposure ::")
                    (dropWhile (not . isPrefixOf "releaseRetainedCluster cfg plan =") (lines source))
            release = unlines body
        assertBool "the production retained release body is absent" (not (null body))
        length (filter (isInfixOf "retainedClusterProjection plan") body) @?= 1
        forM_ ["retainedClusterName retained", "retainedClusterNodeNames retained", "retainedClusterStateDirectory retained", "retainedClusterKubeconfigPath retained"] $ \coordinate ->
            assertBool ("retained release does not use its coordinate: " <> coordinate) (coordinate `isInfixOf` release)
        forM_ ["dataPath", "planOwnedClusterDurableRoot", "clusterName plan", "clusterNodeNames plan", "clusterRuntimeStateDirectory", "clusterKubeconfigPath"] $ \accessor ->
            assertBool ("retained release reads beyond its projection: " <> accessor) (not (accessor `isInfixOf` release))
    , testCase "only retained cluster cleanup and the lifecycle gate remain" $ do
        backend <- backendSource
        root <- repositoryRoot
        reconcile <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Cluster" </> "Reconcile.hs")
        forM_ [backend, reconcile] $ \source ->
            forM_ ["PreparedClusterCleanup", "runClusterCleanupCall", "settleClusterCleanup"] $ \unused ->
                assertBool ("an unused cleanup authority is defined or named: " <> unused) (not (unused `isInfixOf` source))
        assertBool "the production lifecycle cleanup gate disappeared" ("runExactClusterCleanupKernel ::" `isInfixOf` reconcile)
    , testCase "the hidden backend component retains capability data and no injected executor" $ do
        root <- repositoryRoot
        let internalPath = root </> "core" </> "hostbootstrap-core" </> "internal" </> "cluster-backend" </> "HostBootstrap" </> "Cluster" </> "Backend" </> "Internal.hs"
        present <- doesFileExist internalPath
        assertBool "the plan-owned hidden backend component is absent" present
        internalSource <- readFile' internalPath
        let declaration = takeWhile (/= "mkStrongClusterBackend")
                (dropWhile (/= "data") (SourceGuard.haskellTokens internalSource))
        declaration @?= SourceGuard.haskellTokens
            "data StrongClusterBackend = StrongClusterBackend HostConfig ClusterDriver ByteString Text Text FilePath (IORef Word64)"
    , testCase "the backend still reaches the described commands and the clause-holding driver" $ do
        source <- backendSource
        forM_ ["HostBootstrap.Cluster.Command", "HostBootstrap.Cluster.Ownership"] $ \name ->
            assertBool (name <> " is not imported by the cluster backend") (SourceGuard.importsModule name source)
        assertBool "the backend does not reach the cluster interpreter"
            ("Owned.interpretClusterCommand" `isInfixOf` source)
    , testCase "runtime publication has no scan-then-bind or caller-port compatibility path" $ do
        source <- backendSource
        forM_ ["mkLoopbackExposure", "PreparedLoopbackExposure", "settleLoopbackExposure", "Network.Socket"] $ \name ->
            assertBool (name <> " remains in the cluster backend") (not (name `isInfixOf` source))
        forM_ ["127.0.0.1::", "ResolvedExposure", "getRandomBytes 32", "ExpectAbsent"] $ \name ->
            assertBool (name <> " is absent from runtime-owned exposure") (name `isInfixOf` source)
    ]

backendSource :: IO String
backendSource = do
    root <- repositoryRoot
    readFile'
        ( root
            </> "core"
            </> "hostbootstrap-core"
            </> "src"
            </> "HostBootstrap"
            </> "Cluster"
            </> "Backend.hs"
        )

repositoryRoot :: IO FilePath
repositoryRoot = do
    cwd <- getCurrentDirectory
    findRepoRoot cwd
        >>= maybe (assertFailure ("could not locate the repository root from " <> cwd)) pure

{- | The names a cluster effect may no longer be spelled with.

@Python3@ and @Flock@ are the host-tool constructors the retired program
resolved, @Lockf@ the one it deliberately refused, @-c@ is how an interpreter is
handed a program, and @ClusterExec@ is the function a suite used to answer with
instead of supplying one.
-}
forbiddenNames :: [String]
forbiddenNames = ["Python3", "Flock", "Lockf", "ClusterExec", "\"-c\""]

-- Loopback exposure ------------------------------------------------------------

exposureIntentBoundaryCases :: [TestTree]
exposureIntentBoundaryCases =
    [ testCase "128 service characters retain the exact intent" $
        case mkExposureIntent (Text.replicate 128 "a") "demo-control-plane" 30080 of
            Right intent -> do
                exposureIntentService intent @?= Text.replicate 128 "a"
                exposureIntentTargetHost intent @?= "demo-control-plane"
                portNumber (exposureIntentTargetPort intent) @?= 30080
            Left refusal -> assertFailure (show refusal)
    , testCase "129 service characters are refused" $
        refuses (Text.replicate 129 "a") "demo-control-plane"
    , testCase "an empty service is refused" $ refuses "" "demo-control-plane"
    , testCase "a NUL in the service is refused" $ refuses "we\0b" "demo-control-plane"
    , testCase "an empty target host is refused" $ refuses "web" ""
    , testCase "a space in the target host is refused" $ refuses "web" "demo control-plane"
    ] <> [testCase ("a " <> label <> " in the service is refused") $
            refuses ("we" <> Text.singleton separator <> "b") "demo-control-plane"
         | (label, separator) <-
            [("slash", '/'), ("backslash", toEnum 92), ("colon", ':'),
             ("carriage return", '\r'), ("newline", '\n'), ("tab", '\t')]]
  where
    refuses service target = case mkExposureIntent service target 30080 of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected an exposure intent refusal, got " <> show other)

exposureCases :: [TestTree]
exposureCases =
    [ testCase "fixture refuses Docker vectors routed to its kubectl executable" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \cluster -> do
                backend <- requireBackend cfg cluster
                declare root cluster
                withAppliedFixtureCordon backend cluster $ \applied -> do
                    kubectl <- maybe (assertFailure "the fixture has no kubectl executable") pure (Map.lookup Kubectl (hcToolPaths cfg))
                    let wrong = cfg{hcToolPaths = Map.insert Docker kubectl (hcToolPaths cfg)}
                    wrongBackend <- requireBackend wrong cluster
                    intent <- either (assertFailure . show) pure (mkExposureIntent "web" (Text.pack (preparedClusterName cluster <> "-control-plane")) 30080)
                    case withPreparedClusterExposure applied immutableTestImage [intent] id of
                        Left refusal -> pure (Left refusal)
                        Right prepared -> do
                            before <- FakeCluster.recordedClusterMutations root
                            result <- runClusterExposureCall wrongBackend prepared
                            FakeCluster.recordedClusterMutations root >>= (@?= before)
                            pure (Right (() <$ result))
        case outcome of
            Right (Left refusal) -> assertBool (show refusal) ("fixture wrong tool: expected docker, got kubectl" `isInfixOf` show refusal)
            other -> assertFailure ("expected the fixture's wrong-tool refusal, got " <> show other)
    , testGroup "exposure intent boundaries" exposureIntentBoundaryCases
    , testGroup "prepared exposure admission" exposurePreparationCases
    , testGroup "owned relay lifecycle" exposureLifecycleCases
    , testCase "intent contains only semantic service and cluster target" $
        case mkExposureIntent "web" "demo-control-plane" 30080 of
            Right intent -> do
                exposureIntentService intent @?= "web"
                exposureIntentTargetHost intent @?= "demo-control-plane"
                portNumber (exposureIntentTargetPort intent) @?= 30080
            Left refusal -> assertFailure (show refusal)
    , testCase "an invalid internal target port is refused" $
        forM_ [0, 65536] $ \port -> case mkExposureIntent "web" "demo-control-plane" port of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected an internal-port refusal, got " <> show other)
    , testCase "the runtime assigns distinct loopback ports and exact inspection mints them" $ do
        outcome <- withRuntimeExposure $ \_ root _ _ resolved -> do
            web <- resolvedTuple "web" resolved
            registry <- resolvedTuple "registry" resolved
            mutations <- FakeCluster.recordedClusterMutations root
            pure (web, registry, mutations)
        case outcome of
            Right (("127.0.0.1", webPort, webTarget, 30080), ("127.0.0.1", registryPort, registryTarget, 30500), mutations) -> do
                assertBool "the runtime reused one selected host port" (webPort /= registryPort)
                assertBool "the services target different cluster nodes" (webTarget == registryTarget && "-control-plane" `Text.isSuffixOf` webTarget)
                mutations @?= ["create", "update", "relay-create"]
            other -> assertFailure ("expected runtime-resolved mappings, got " <> show other)
    , testCase "exact recovery re-inspects the same relay without creating another" $ do
        outcome <- withRuntimeExposure $ \backend root _ prepared first -> do
            second <- runClusterExposureCall backend prepared >>= either (assertFailure . show) pure
            firstWeb <- resolvedTuple "web" first
            secondWeb <- resolvedTuple "web" second
            mutations <- FakeCluster.recordedClusterMutations root
            pure (firstWeb, secondWeb, mutations)
        case outcome of
            Right (first, second, mutations) -> do
                first @?= second
                mutations @?= ["create", "update", "relay-create"]
            other -> assertFailure ("expected exact exposure recovery, got " <> show other)
    , testCase "a wildcard mapping is a Conflict and its ownership record remains" $ do
        outcome <- withRuntimeExposure $ \backend root stateRoot prepared _ -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayMappings = [(listener, "0.0.0.0", port) | (listener, _, port) <- FakeCluster.relayMappings relay]} | relay <- relays]
            rerun <- runClusterExposureCall backend prepared
            records <- recordsUnder stateRoot
            pure (case rerun of Left (Conflict _) -> True; _ -> False, length records)
        case outcome of
            Right (True, 2) -> pure ()
            other -> assertFailure ("expected a retained wildcard conflict, got " <> showExposureOutcome other)
    , testCase "a replacement relay is a Conflict and is not adopted" $ do
        outcome <- withRuntimeExposure $ \backend root _ prepared _ -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayIdentity = Text.unpack (Text.replicate 64 "b")} | relay <- relays]
            rerun <- runClusterExposureCall backend prepared
            pure (case rerun of Left (Conflict _) -> True; _ -> False)
        outcome @?= Right True
    , testCase "an additional runtime mapping is a Conflict" $ do
        outcome <- withRuntimeExposure $ \backend root _ prepared _ -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayMappings = (29999, "127.0.0.1", 41999) : FakeCluster.relayMappings relay} | relay <- relays]
            rerun <- runClusterExposureCall backend prepared
            pure (case rerun of Left (Conflict _) -> True; _ -> False)
        outcome @?= Right True
    , testCase "release removes the exact relay before forgetting its record" $ do
        outcome <- withRuntimeExposure $ \backend root stateRoot prepared _ -> do
            released <- releaseClusterExposureCall backend prepared
            relays <- FakeCluster.readRelays root
            records <- recordsUnder stateRoot
            mutations <- FakeCluster.recordedClusterMutations root
            pure (released, relays, length records, mutations)
        case outcome of
            Right (Right (), [], 1, mutations) -> mutations @?= ["create", "update", "relay-create", "relay-delete"]
            other -> assertFailure ("expected identity-conditional relay release, got " <> showExposureOutcome other)
    , testCase "recorded observation re-inspects the relay and selects one exact service" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            self <- FakeCluster.prepareFixtureExecutables root
            plan <- recordedPlan stateRoot resolved
            expected <- resolvedTuple "web" resolved
            observed <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "web"
            absent <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "absent"
            pure (expected, recordedClusterExposureHostPort <$> observed, either (const True) (const False) absent)
        case outcome of
            Right (("127.0.0.1", expectedPort, _, _), Right actualPort, True) -> actualPort @?= expectedPort
            other -> assertFailure ("expected one freshly observed service, got " <> showExposureOutcome other)
    , testCase "recorded observation refuses a replacement relay identity" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayIdentity = Text.unpack (Text.replicate 64 "b")} | relay <- relays]
            self <- FakeCluster.prepareFixtureExecutables root
            plan <- recordedPlan stateRoot resolved
            observed <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "web"
            assertExposureConflict "another relay stands at the recorded name" observed
        outcome @?= Right ()
    , testCase "recorded observation refuses a changed relay mapping" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayMappings = [(listener, address, port + 10) | (listener, address, port) <- FakeCluster.relayMappings relay]} | relay <- relays]
            self <- FakeCluster.prepareFixtureExecutables root
            plan <- recordedPlan stateRoot resolved
            observed <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "web"
            pure (either (const True) (const False) observed)
        outcome @?= Right True
    , testCase "reverse recovers and releases the recorded relay without caller-supplied identity or port" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            self <- FakeCluster.prepareFixtureExecutables root
            plan <- recordedPlan stateRoot resolved
            released <- releaseRecordedClusterExposure (clusterHostConfig self) plan
            relays <- FakeCluster.readRelays root
            records <- recordsUnder stateRoot
            mutations <- FakeCluster.recordedClusterMutations root
            pure (released, relays, length records, mutations)
        case outcome of
            Right (Right (), [], 1, mutations) -> mutations @?= ["create", "update", "relay-create", "relay-delete"]
            other -> assertFailure ("expected recorded reverse exposure release, got " <> showExposureOutcome other)
    , testCase "reverse refuses a replacement relay and retains the exposure record" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayIdentity = Text.unpack (Text.replicate 64 "b")} | relay <- relays]
            self <- FakeCluster.prepareFixtureExecutables root
            plan <- recordedPlan stateRoot resolved
            released <- releaseRecordedClusterExposure (clusterHostConfig self) plan
            records <- recordsUnder stateRoot
            assertExposureConflict "another relay stands at the recorded name" released
            length records @?= 2
        outcome @?= Right ()
    , testCase "retained cluster cleanup refuses until the owned relay has been released" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \cluster -> do
                backend <- requireBackend cfg cluster
                declare root cluster
                withAppliedFixtureCordon backend cluster $ \applied ->
                    case mkExposureIntent "web" (Text.pack (preparedClusterName cluster <> "-control-plane")) 30080 of
                        Left refusal -> pure (Left refusal)
                        Right intent -> case withPreparedClusterExposure applied immutableTestImage [intent] id of
                            Left refusal -> pure (Left refusal)
                            Right exposure -> do
                                exposed <- runClusterExposureCall backend exposure
                                case exposed of
                                    Left refusal -> pure (Left refusal)
                                    Right _ -> do
                                        let stateRoot = preparedClusterStateDirectory cluster
                                            durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                                            plan = resolvePlan (preparedClusterName cluster) (takeDirectory durableRoot) Production
                                        before <- recordsUnder stateRoot
                                        length before @?= 2
                                        result <- releaseRetainedCluster cfg plan
                                        case result of
                                            Left (Failure detail) ->
                                                assertBool "the retained transaction must name the outstanding relay" ("the owned exposure relay must be released before the cluster" `Text.isInfixOf` failureCause detail)
                                            other -> assertFailure ("expected retained release to refuse the relay record, got " <> show other)
                                        FakeCluster.readClusters root >>= (@?= [preparedClusterName cluster])
                                        recordsUnder stateRoot >>= (@?= before)
                                        FakeCluster.readRelays root >>= (\relays -> length relays @?= 1)
                                        FakeCluster.recordedClusterMutations root >>= (@?= ["create", "update", "relay-create"])
                                        releaseRecordedClusterExposure cfg plan >>= (@?= Right ())
                                        releaseRetainedCluster cfg plan >>= (@?= Right ())
                                        FakeCluster.readClusters root >>= (@?= [])
                                        recordsUnder stateRoot >>= (@?= [])
                                        pure (Right ())
        outcome @?= Right ()
    ]

exposureLifecycleCases :: [TestTree]
exposureLifecycleCases =
    [ testCase (route <> " release accepts an authenticated stopped relay") (stoppedRelayRelease recorded)
    | (route, recorded) <- [("prepared", False), ("recorded", True)]
    ]
        <> [ testCase (route <> " removal refusal retains the exact relay and record") (refusedRelayRemoval recorded)
           | (route, recorded) <- [("prepared", False), ("recorded", True)]
           ]
        <> [ testCase "a stopped owned relay is recreated with fresh identity, operation and mappings" $ do
                outcome <- withRuntimeExposure $ \backend root stateRoot prepared resolved -> do
                    oldRelays <- FakeCluster.readRelays root
                    oldWeb <- resolvedTuple "web" resolved
                    stopRelays root
                    recovered <- runClusterExposureCall backend prepared
                    exact <- either (assertFailure . show) pure recovered
                    newWeb <- resolvedTuple "web" exact
                    current <- FakeCluster.readRelays root
                    case (oldRelays, current) of
                        ([oldRelay], [newRelay]) -> do
                            assertBool "recreation reused a container identity" (FakeCluster.relayIdentity oldRelay /= FakeCluster.relayIdentity newRelay)
                            assertBool "recreation reused the ownership operation" (lookup "io.hostbootstrap.operation" (FakeCluster.relayLabels oldRelay) /= lookup "io.hostbootstrap.operation" (FakeCluster.relayLabels newRelay))
                            FakeCluster.relayRunning newRelay @?= True
                        _ -> assertFailure "recreation did not leave one exact relay"
                    assertBool "recreation retained stale host mappings" (oldWeb /= newWeb)
                    recordsUnder stateRoot >>= (\records -> length records @?= 2)
                    FakeCluster.recordedClusterMutations root >>= (@?= ["create", "update", "relay-create", "relay-delete", "relay-create"])
                outcome @?= Right ()
           , testCase "a newly stopped creation refuses once and the pending relay recovers on retry" $ do
                outcome <- withPreparedExposureFixture $ \backend root stateRoot prepared -> do
                    FakeCluster.armRelayStoppedOnCreate root
                    first <- runClusterExposureCall backend prepared
                    case first of
                        Left (Failure detail) -> do
                            failureCause detail @?= "the newly created relay is stopped"
                            recoveryDisposition detail @?= ReprobeBeforeRetry
                        _ -> assertFailure "a stopped fresh creation was not a bounded refusal"
                    old <- FakeCluster.readRelays root
                    recovered <- runClusterExposureCall backend prepared
                    _ <- either (assertFailure . show) pure recovered
                    current <- FakeCluster.readRelays root
                    map FakeCluster.relayIdentity old == map FakeCluster.relayIdentity current @?= False
                    recordsUnder stateRoot >>= (\records -> length records @?= 2)
                    pure (Right ())
                outcome @?= Right ()
           , testCase "null image EXPOSE entries retain exact publication and recorded observation" $ do
                outcome <- withPreparedExposureFixture $ \backend root stateRoot prepared -> do
                    FakeCluster.armRelayNullPorts root
                    exposed <- runClusterExposureCall backend prepared
                    exact <- either (assertFailure . show) pure exposed
                    self <- FakeCluster.prepareFixtureExecutables root
                    plan <- recordedPlan stateRoot exact
                    (_, expected, _, _) <- resolvedTuple "web" exact
                    observed <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "web"
                    (recordedClusterExposureHostPort <$> observed) @?= Right expected
                    releaseRecordedClusterExposure (clusterHostConfig self) plan >>= (@?= Right ())
                    FakeCluster.readRelays root >>= (@?= [])
                    pure (Right ())
                outcome @?= Right ()
           , testCase "successful pull progress does not refuse exact relay creation" $ do
                outcome <- withPreparedExposureFixture $ \backend root _ prepared -> do
                    FakeCluster.armRelayPullProgress root
                    exposed <- runClusterExposureCall backend prepared
                    exact <- either (assertFailure . show) pure exposed
                    length exact @?= 2
                    pure (Right ())
                outcome @?= Right ()
           , testCase "each resolved service maps to its declared listener and cluster target" $ do
                outcome <- withRuntimeExposure $ \_ root _ _ exact -> do
                    nodes <- FakeCluster.readNodes root
                    relays <- FakeCluster.readRelays root
                    case (nodes, relays) of
                        ([(node, _)], [relay]) ->
                            forM_ [("web", 30080), ("registry", 30500)] $ \(service, targetPort) -> do
                                (_, hostPort, _, _) <- resolvedTuple (Text.pack service) exact
                                case [(listener, host, port) | (name, listener, host, port) <- FakeCluster.relayTargets relay, name == service] of
                                    [(listener, host, port)] -> do
                                        host @?= node
                                        port @?= targetPort
                                        [(address, selected) | (candidate, address, selected) <- FakeCluster.relayMappings relay, candidate == listener] @?= [("127.0.0.1", hostPort)]
                                    _ -> assertFailure "a service lacks one recorded target tuple"
                        _ -> assertFailure "the fixture lacks its exact node and relay"
                outcome @?= Right ()
           , testCase "a replaced control plane yields the observed identity Conflict before relay mutation" $ do
                outcome <- withRuntimeExposure $ \backend root stateRoot prepared _ -> do
                    before <- FakeCluster.recordedClusterMutations root
                    nodes <- FakeCluster.readNodes root
                    FakeCluster.writeNodes root [(name, node{FakeCluster.nodeIdentity = FakeCluster.replacementIdentity}) | (name, node) <- nodes]
                    exposed <- runClusterExposureCall backend prepared
                    case exposed of
                        Left (Conflict detail) -> conflictObserved detail @?= Text.pack FakeCluster.replacementIdentity
                        _ -> assertFailure "a replaced node was not an identity Conflict"
                    FakeCluster.recordedClusterMutations root >>= (@?= before)
                    recordsUnder stateRoot >>= (\records -> length records @?= 2)
                outcome @?= Right ()
           ]
        <> [ testCase ("tampered record " <> label <> " refuses observation and release before deletion") $ do
                outcome <- withRuntimeExposure $ \_ root stateRoot _ exact -> do
                    self <- FakeCluster.prepareFixtureExecutables root
                    plan <- recordedPlan stateRoot exact
                    before <- FakeCluster.recordedClusterMutations root
                    tamperExposureRecord stateRoot (clusterName plan) mutate
                    observed <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "web"
                    released <- releaseRecordedClusterExposure (clusterHostConfig self) plan
                    assertExposureConflict reason observed
                    assertExposureConflict reason released
                    FakeCluster.recordedClusterMutations root >>= (@?= before)
                    FakeCluster.readRelays root >>= (\relays -> length relays @?= 1)
                    recordsUnder stateRoot >>= (\records -> length records @?= 2)
                outcome @?= Right ()
           | (label, mutate, reason) <-
                [ ("invalid UTF-8", const (ByteString.pack [255]), "not UTF-8")
                , ("trailing whitespace", (<> " "), "not canonical")
                , ("re-spaced show", TextEncoding.encodeUtf8 . Text.replace "ExposureManaged " "ExposureManaged  " . TextEncoding.decodeUtf8, "not canonical")
                ]
           ]

stopRelays :: FilePath -> IO ()
stopRelays root = do
    relays <- FakeCluster.readRelays root
    FakeCluster.writeRelays root [relay{FakeCluster.relayRunning = False, FakeCluster.relayMappings = []} | relay <- relays]

stoppedRelayRelease :: Bool -> IO ()
stoppedRelayRelease recorded = do
    outcome <- withRuntimeExposure $ \backend root stateRoot prepared exact -> do
        stopRelays root
        self <- FakeCluster.prepareFixtureExecutables root
        plan <- recordedPlan stateRoot exact
        observed <- observeRecordedClusterExposure (clusterHostConfig self) stateRoot (clusterName plan) "web"
        case observed of
            Left (Failure detail) -> recoveryDisposition detail @?= ReprobeBeforeRetry
            _ -> assertFailure "a stopped relay minted a local endpoint"
        released <- if recorded
            then releaseRecordedClusterExposure (clusterHostConfig self) plan
            else releaseClusterExposureCall backend prepared
        released @?= Right ()
        FakeCluster.readRelays root >>= (@?= [])
        recordsUnder stateRoot >>= (\records -> length records @?= 1)
    outcome @?= Right ()

refusedRelayRemoval :: Bool -> IO ()
refusedRelayRemoval recorded = do
    outcome <- withRuntimeExposure $ \backend root stateRoot prepared exact -> do
        relays <- FakeCluster.readRelays root
        records <- recordsUnder stateRoot
        mutations <- FakeCluster.recordedClusterMutations root
        FakeCluster.armRelayRemovalRefusal root
        self <- FakeCluster.prepareFixtureExecutables root
        plan <- recordedPlan stateRoot exact
        released <- if recorded
            then releaseRecordedClusterExposure (clusterHostConfig self) plan
            else releaseClusterExposureCall backend prepared
        case released of
            Left _ -> pure ()
            Right () -> assertFailure "the runtime's refused removal was reported as released"
        FakeCluster.readRelays root >>= (@?= relays)
        recordsUnder stateRoot >>= (@?= records)
        FakeCluster.recordedClusterMutations root >>= (@?= mutations)
    outcome @?= Right ()

assertExposureConflict :: Text.Text -> Either ReconcileError value -> IO ()
assertExposureConflict reason observed = case observed of
    Left (Conflict detail) -> assertBool ("the conflict did not name " <> Text.unpack reason) (reason `Text.isInfixOf` conflictRemedy detail)
    _ -> assertFailure "expected the exact non-retryable Conflict category"

tamperExposureRecord :: FilePath -> String -> (ByteString.ByteString -> ByteString.ByteString) -> IO ()
tamperExposureRecord stateRoot name mutate = do
    segment <- either (assertFailure . show) pure (mkRecordSegment ("cluster:" <> Text.pack name))
    key <- either (assertFailure . show) pure (mkRecordKey (segment <> recordTupleSeparator <> "exposure"))
    store <- openProtectedStore stateRoot >>= either (assertFailure . show) pure
    changed <- withProtectedEntry store $ \session -> do
        readBack <- readProtectedRecord session key
        case readBack of
            Left refusal -> pure (Left refusal)
            Right Nothing -> fail "the fixture has no managed exposure record to mutate"
            Right (Just record) -> compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) (mutate (protectedRecordBytes record))
    either (assertFailure . show) (const (pure ())) changed

exposurePreparationCases :: [TestTree]
exposurePreparationCases =
    [ testCase "a mutable image is refused" $
        refuses "example.invalid/relay:latest" ["web"] imageRefusal
    , testCase "an empty service set is refused" $
        refuses immutableTestImage [] "at least one service exposure is required"
    , testCase "duplicate services are refused" $
        refuses immutableTestImage ["web", "web"] "service identities must be distinct"
    , testCase "129 distinct services are refused" $
        refuses immutableTestImage ["service-" <> Text.pack (show i) | i <- [0 .. 128 :: Int]]
            "too many service exposures"
    , testCase "an empty repository is refused before an exposure record" $
        refuses ("@sha256:" <> digest) ["web"] imageRefusal
    , testCase "a CLI-option image is refused before an exposure record" $
        refuses ("--label=x@sha256:" <> digest) ["web"] imageRefusal
    , testCase "canonical immutable image forms retain admission" $
        forM_
            ["alpine", "library/alpine", "registry.example:5000/team/relay",
             "REGISTRY.EXAMPLE/team/relay", "localhost:5000/relay",
             "[2001:db8::1]:5000/team/relay", "team/a.b_c__d---e",
             "team/relay:Release_1.2-3", Text.replicate 255 "a",
             "team/relay:" <> Text.replicate 128 "t"] $ \name ->
                checkExposurePreparation (name <> "@sha256:" <> digest) ["web"] (Right ())
    , testCase "malformed repository and tag grammar is refused" $
        forM_
            ["registry.example/UPPER", ".repo", "repo.", "repo..name", "repo___name",
             "repo/-name", "repo//name", "repo/name/", "/repo",
             "registry.example:/team/relay", "registry.example:abc/team/relay",
             "repo:-tag", "repo:", "repo:tag space", "repo\0name",
             "bad..registry:5000/team/relay", "[2001:db8::1/team/relay",
             "[]:5000/team/relay", "[GG::1]/team/relay",
             Text.replicate 256 "a", "team/relay:" <> Text.replicate 129 "t"] $ \name ->
                refuses (name <> "@sha256:" <> digest) ["web"] imageRefusal
    , testCase "image IDs stay immutable and malformed digests refuse" $ do
        checkExposurePreparation ("sha256:" <> digest) ["web"] (Right ())
        forM_
            ["example/relay@sha256:" <> Text.replicate 63 "a",
             "example/relay@sha256:" <> Text.replicate 64 "A",
             "example/relay@sha256:" <> Text.replicate 64 "g",
             "example/relay@sha256:" <> digest <> "@sha256:" <> digest] $ \image ->
                refuses image ["web"] imageRefusal
    ]
  where
    digest = Text.replicate 64 "a"
    imageRefusal = "relay image must be an immutable repository@sha256 or sha256 image identity"
    refuses image services reason = checkExposurePreparation image services
        (Left (Failure (FailureDetail "prepare cluster exposure" reason DoNotRetry)))

checkExposurePreparation :: Text.Text -> [Text.Text] -> Either ReconcileError () -> IO ()
checkExposurePreparation image services expected = do
    result <- withBackend $ \cfg root ->
        withClusterFixtureM $ \cluster -> do
            backend <- requireBackend cfg cluster
            declare root cluster
            withAppliedFixtureCordon backend cluster $ \applied -> do
                let target = Text.pack (preparedClusterName cluster <> "-control-plane")
                intents <- either (assertFailure . show) pure
                    (traverse (\service -> mkExposureIntent service target 30080) services)
                records <- recordsUnder (preparedClusterStateDirectory cluster)
                mutations <- FakeCluster.recordedClusterMutations root
                withPreparedClusterExposure applied image intents (const ()) @?= expected
                recordsUnder (preparedClusterStateDirectory cluster) >>= (@?= records)
                FakeCluster.recordedClusterMutations root >>= (@?= mutations)
                FakeCluster.readRelays root >>= (@?= [])
                pure (Right ())
    result @?= Right ()

withRuntimeExposure ::
    ( forall scope planId clusterId clusterFrame.
      StrongClusterBackend ->
      FilePath ->
      FilePath ->
      PreparedClusterExposure scope planId clusterId clusterFrame ->
      [ResolvedExposure scope planId clusterId ()] ->
      IO result
    ) ->
    IO (Either ReconcileError result)
withRuntimeExposure consume =
    withPreparedExposureFixture $ \backend root stateRoot prepared -> do
        resolved <- runClusterExposureCall backend prepared
        case resolved of
            Left refusal -> pure (Left refusal)
            Right exact -> Right <$> consume backend root stateRoot prepared exact

withPreparedExposureFixture ::
    ( forall scope planId clusterId clusterFrame.
      StrongClusterBackend -> FilePath -> FilePath ->
      PreparedClusterExposure scope planId clusterId clusterFrame -> IO (Either ReconcileError result)
    ) ->
    IO (Either ReconcileError result)
withPreparedExposureFixture consume =
    withBackend $ \cfg root ->
        withClusterFixtureM $ \cluster -> do
            backend <- requireBackend cfg cluster
            declare root cluster
            withAppliedFixtureCordon backend cluster $ \applied -> do
                let target = Text.pack (preparedClusterName cluster <> "-control-plane")
                web <- pure (mkExposureIntent "web" target 30080)
                registry <- pure (mkExposureIntent "registry" target 30500)
                case (web, registry) of
                    (Right webIntent, Right registryIntent) ->
                        case withPreparedClusterExposure applied immutableTestImage [webIntent, registryIntent] id of
                            Left refusal -> pure (Left refusal)
                            Right prepared -> consume backend root (preparedClusterStateDirectory cluster) prepared
                    (Left refusal, _) -> pure (Left refusal)
                    (_, Left refusal) -> pure (Left refusal)

recordedPlan :: FilePath -> [ResolvedExposure scope planId clusterId seed] -> IO ClusterPlan
recordedPlan stateRoot resolved = do
    (_, _, target, _) <- resolvedTuple "web" resolved
    name <- maybe (assertFailure "the fixture target lacks its control-plane suffix") (pure . Text.unpack) (Text.stripSuffix "-control-plane" target)
    pure (resolvePlan name (takeDirectory durableRoot) Production)
  where
    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))

immutableTestImage :: Text.Text
immutableTestImage = "example.invalid/hostbootstrap-test@sha256:" <> Text.replicate 64 "a"

resolvedTuple :: Text.Text -> [ResolvedExposure scope planId clusterId seed] -> IO (Text.Text, Int, Text.Text, Int)
resolvedTuple service resolved =
    case withResolvedExposure service resolved $ \exact ->
        ( resolvedExposureListenAddress exact
        , portNumber (resolvedExposureHostPort exact)
        , resolvedExposureTargetHost exact
        , portNumber (resolvedExposureTargetPort exact)
        ) of
        Left refusal -> assertFailure (show refusal)
        Right tuple -> pure tuple

showExposureOutcome :: value -> String
showExposureOutcome _ = "opaque exposure outcome"

-- | These preflights use actual storage and no configured provider executable.
retainedReleasePreflightCases :: [TestTree]
retainedReleasePreflightCases =
    [ testCase "a retained plan with no nodes refuses before storage or provider access" $
        withSystemTempDirectory "hostbootstrap-retained-empty-plan" $ \temporary -> do
            root <- canonicalizePath temporary
            let cfg = HostConfig (Substrate LinuxCpu Amd64) Map.empty
                plan = (resolvePlan "empty" root Production){clusterNodeSuffixes = []}
                stateRoot = retainedClusterStateDirectory (retainedClusterProjection plan)
            releaseRetainedCluster cfg plan >>= (@?= Left (Failure
                (FailureDetail "release retained cluster" "the retained cluster plan declares no nodes" DoNotRetry)))
            doesDirectoryExist stateRoot >>= (@?= False)
    , testCase "an absent actual ownership record refuses before resolving any provider tool" $
        withSystemTempDirectory "hostbootstrap-retained-absent-record" $ \temporary -> do
            root <- canonicalizePath temporary
            let cfg = HostConfig (Substrate LinuxCpu Amd64) Map.empty
                plan = resolvePlan "absent" root Production
                stateRoot = retainedClusterStateDirectory (retainedClusterProjection plan)
            releaseRetainedCluster cfg plan >>= (@?= Left (Failure
                (FailureDetail "release retained cluster" "the cluster ownership record is absent" DoNotRetry)))
            doesDirectoryExist stateRoot >>= (@?= True)
            recordsUnder stateRoot >>= (@?= [])
    , testCase "an oversized nvkind worker address refuses before state storage opens" $
        withSystemTempDirectory "hostbootstrap-retained-worker-key" $ \temporary -> do
            root <- canonicalizePath temporary
            let cfg = HostConfig (Substrate LinuxCpu Amd64) Map.empty
                name = replicate 99 'a'
                plan = resolvePlanWithDriver name root Production NvkindDriver
                retained = retainedClusterProjection plan
                stateRoot = retainedClusterStateDirectory retained
            retainedClusterNodeNames retained @?= [name <> "-control-plane",name <> "-worker"]
            releaseRetainedCluster cfg plan >>= (@?= Left (Failure
                (FailureDetail "validate cluster spec"
                    "a record key must be at most 200 ASCII bytes (observed 221, namespace cluster)" DoNotRetry)))
            doesDirectoryExist stateRoot >>= (@?= False)
    ]

recordSnapshotsUnder :: FilePath -> IO [(RecordKey, Maybe ProtectedRecord)]
recordSnapshotsUnder stateDirectory = do
    store <- openProtectedStore stateDirectory >>= either (assertFailure . show) pure
    outcome <- withProtectedEntry store $ \session -> do
        keys <- listProtectedRecords session >>= either (assertFailure . show) pure
        values <- traverse (\key -> do
            value <- readProtectedRecord session key >>= either (assertFailure . show) pure
            pure (key,value)) keys
        pure (Right values)
    either (assertFailure . show) pure outcome
