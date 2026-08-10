{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module LifecycleSpec (tests) where

import Control.Exception (SomeException, displayException, finally, try)
import Data.Bits ((.&.), shiftR)
import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as ByteArray
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (ord)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Authority
    ( AuthorityError (..)
    , InstalledProjectIdentity
    , ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    , brokerEpochWord
    , installedProjectName
    , rootAuthorityEpoch
    , rootAuthorityVerb
    , rootScopeAuthority
    )
import HostBootstrap.Cluster.Lifecycle
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Schema (ValidatedConfig, withValidatedConfig)
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (..), mkAbsExe)
import HostBootstrap.Lifecycle.Mode
    ( BoundInvocationRecovery
    , BoundRunLease
    , LeaseConflict
    , LifecycleProfile
    , ModeError (..)
    , NormalActiveRecovery
    , OpenRevisionKind (..)
    , ProductionMode
    , ProjectModeLease
    , UnboundRunLease
    , VerifiedPlanSnapshot
    , bindRunLeaseWithPlanRecovery
    , boundInvocationRecoveryRevisionKind
    , boundInvocationRecoveryRunText
    , boundRunLeasePlanDigest
    , boundRunLeaseRunText
    , boundRunLeaseSpecDigest
    , normalActiveRecoveryRunText
    , leaseConflictMessage
    , invocationCloseKeyText
    , mkInvocationCloseKey
    , planSnapshotCanonicalBytes
    , planSnapshotPlanDigest
    , planSnapshotRevision
    , planSnapshotRunText
    , planSnapshotSpecDigest
    , productionActiveMode
    , productionRootAuthority
    , productionRootModeLease
    , productionRootUnboundLease
    , projectModeLeaseEpoch
    , recordProductionInvocationAcknowledgment
    , recoveredProductionProfileCanonicalBytes
    , recoveredProductionProfileConfigDigest
    , recoveredProductionProfileEpoch
    , recoveredProductionProfilePlanDigest
    , recoveredProductionProfileProjectName
    , recoveredProductionProfileRevision
    , recoveredProductionProfileRevisionKind
    , recoveredProductionProfileRunText
    , recoveredProductionProfileSpecDigest
    , recoveredProductionProfileStoreIdentity
    , unboundRunLeaseRunText
    , withProductionLifecycleProfile
    , withProductionRoot
    , withBoundPlanSnapshotKernel
    , withRecoveredProductionLifecycleProfile
    )
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , StablePlanSnapshot
    , planDraftsFromValidatedBuilder
    , renderSnapshot
    , stablePlanSnapshotBytes
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotDigest
    , stablePlanSnapshotSpecDigest
    )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    , SnapshotError (..)
    , boundPlanSnapshotBytes
    , withPlanDigestBinding
    , withPersistedPlanSnapshot
    , withBoundPlanSnapshot
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    , withCanonicalProjectRoot
    )
import HostBootstrap.Protected
    ( Expectation (ExpectAbsent, ExpectVersion)
    , ProtectedRecord (protectedRecordBytes, protectedRecordVersion)
    , ProtectedStore
    , RecordKey
    , compareAndDeleteProtectedRecord
    , compareAndSwapProtectedRecord
    , listProtectedRecords
    , mkRecordKey
    , openProtectedStore
    , protectedStoreRoot
    , readProtectedRecord
    , recordKeyText
    , recordVersionWord
    , tryProtectedEntry
    , withProtectedEntry
    )
import HostBootstrap.Step
    ( StepFrame (StepFrame)
    , StepObservation (StepChanged)
    , StepPlan
    , contextInitStep
    , mkStepPlan
    )
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.Directory
    ( createDirectory
    , createDirectoryIfMissing
    , doesDirectoryExist
    , findExecutable
    , getPermissions
    , setPermissions
    , writable
    )
import System.Exit (ExitCode (..))
import System.FilePath ((<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

rootPath :: FilePath
rootPath = rootDir </> "demo"

rootDir :: FilePath
#ifdef mingw32_HOST_OS
rootDir = "C:\\srv"
#else
rootDir = "/srv"
#endif

prod :: ClusterPlan
prod = resolvePlan "demo" rootPath Production

test1 :: ClusterPlan
test1 = resolvePlan "demo" rootPath (TestCase "case1")

tests :: TestTree
tests =
    testGroup
        "LifecycleSpec"
        [ testGroup "resolvePlan" planCases
        , testGroup "cluster drivers" driverCases
        , testGroup "profiles are distinct" profileCases
        , testGroup "host-port publication" hostPortCases
        , testGroup "accelerator ingress" acceleratorIngressCases
        , testGroup "NVIDIA runtime probe" nvidiaRuntimeCases
        , testGroup "NVIDIA device plugin" nvidiaDevicePluginCases
        , testGroup "multi-node cordon" nodeCordonCases
        , testGroup "never-delete-.data" dataInvariantCases
        , testGroup "teardown failure propagation" teardownFailureCases
        , testGroup "status report" statusCases
        , testGroup "health-check-and-recreate" healthProbeCases
        , testGroup "persisted project snapshots" snapshotPersistenceCases
        , testGroup "existing bound Production snapshots" existingBoundSnapshotCases
        , testGroup "recovered Production lifecycle profile" recoveredProductionProfileCases
        ]

-- The pure classification behind clusterCreate's health-check-and-recreate: a
-- listed kind cluster is only trusted when @kubectl get nodes@ actually answers
-- with a node line; a stopped cluster (connection refused) or an empty listing is
-- unhealthy so the caller deletes and recreates it.
healthProbeCases :: [TestTree]
healthProbeCases =
    [ testCase "a node listing is healthy" $
        clusterHealthyFromProbe (Right (ExitSuccess, "demo-control-plane   Ready   control-plane   2m   v1.29\n", "")) @?= True
    , testCase "a stopped cluster (connection refused) is unhealthy" $
        clusterHealthyFromProbe (Left "could not exec kubectl: connection refused") @?= False
    , testCase "a non-zero kubectl exit is unhealthy" $
        clusterHealthyFromProbe (Right (ExitFailure 1, "", "The connection to the server was refused")) @?= False
    , testCase "an empty node listing is unhealthy" $
        clusterHealthyFromProbe (Right (ExitSuccess, "   \n", "")) @?= False
    ]

planCases :: [TestTree]
planCases =
    [ testCase "production: fixed name and .data path" $ do
        clusterName prod @?= "demo"
        dataPath prod @?= rootPath </> ".data"
        derivedPaths prod @?= [rootPath </> ".cluster" </> "demo"]
        clusterDriver prod @?= KindDriver
        clusterConfigFile prod @?= Just "kind.yaml"
        clusterNodeSuffixes prod @?= ["control-plane"]
    , testCase "test: per-case isolated name and path" $ do
        clusterName test1 @?= "demo-test-case1"
        dataPath test1 @?= rootPath </> ".test_data" </> "case1"
        derivedPaths test1 @?= [rootPath </> ".cluster" </> "demo-test-case1"]
        clusterConfigFile test1 @?= Nothing
        clusterNodeSuffixes test1 @?= ["control-plane"]
    , testCase "production maps host, VM, and container roots to their canonical .data child" $ do
        let vmRoot = rootDir </> "vm" </> "demo"
            containerRoot = rootDir </> "workspace" </> "demo"
            resolvedData root = dataPath (resolvePlan "demo" root Production)
        resolvedData rootPath @?= durableDataPath rootPath
        resolvedData vmRoot @?= durableDataPath vmRoot
        resolvedData containerRoot @?= durableDataPath containerRoot
    ]

driverCases :: [TestTree]
driverCases =
    [ testCase "Linux GPU accelerator plan selects nvkind" $ do
        let plan = resolveAcceleratorPlan "demo" rootPath Production (Substrate LinuxGpu Amd64)
        clusterDriver plan @?= NvkindDriver
        clusterCreateTool plan @?= Nvkind
        clusterConfigFile plan @?= Just "nvkind.yaml"
        clusterNodeSuffixes plan @?= ["control-plane", "worker"]
        clusterCreateArgs plan True @?= ["cluster", "create", "--name=demo", "--config-template=nvkind.yaml"]
    , testCase "Linux CPU accelerator plan keeps kind" $ do
        let plan = resolveAcceleratorPlan "demo" rootPath Production (Substrate LinuxCpu Amd64)
        clusterDriver plan @?= KindDriver
        clusterCreateTool plan @?= Kind
        clusterCreateArgs plan True @?= ["create", "cluster", "--name", "demo", "--config", "kind.yaml"]
    , testCase "a placement-specific cluster config is passed to kind/nvkind" $ do
        let kindPlan = prod{clusterConfigFile = Just "kind-in-cluster.yaml"}
            nvkindPlan = (resolvePlanWithDriver "demo" rootPath Production NvkindDriver){clusterConfigFile = Just "nvkind-in-cluster.yaml"}
        clusterCreateArgs kindPlan True @?= ["create", "cluster", "--name", "demo", "--config", "kind-in-cluster.yaml"]
        clusterCreateArgs nvkindPlan True @?= ["cluster", "create", "--name=demo", "--config-template=nvkind-in-cluster.yaml"]
    , testCase "test clusters do not publish fixed kind host ports" $
        clusterCreateArgs test1 True @?= ["create", "cluster", "--name", "demo-test-case1"]
    , testCase "an explicit non-publishing nvkind topology is still honored" $ do
        let plan = (resolvePlanWithDriver "demo" rootPath (TestCase "gpu") NvkindDriver){clusterConfigFile = Just "nvkind-test.yaml"}
        publishesHostPorts plan @?= False
        clusterCreateArgs plan True @?= ["cluster", "create", "--name=demo-test-gpu", "--config-template=nvkind-test.yaml"]
    , testCase "an explicit cluster config is required and an intentional default is not" $ do
        clusterConfigPresence Nothing False @?= Right False
        clusterConfigPresence (Just "nvkind.yaml") True @?= Right True
        clusterConfigPresence (Just "nvkind.yaml") False @?= Left "cluster up: required config file is missing: nvkind.yaml"
    ]

hostPortCases :: [TestTree]
hostPortCases =
    [ testCase "production publishes the host NodePorts (kind.yaml)" $
        publishesHostPorts prod @?= True
    , testCase "test cluster binds no host port so cases never collide" $
        publishesHostPorts test1 @?= False
    ]

profileCases :: [TestTree]
profileCases =
    [ testCase "production and test resolve distinct cluster names" $
        assertBool "names differ" (clusterName prod /= clusterName test1)
    , testCase "production and test resolve distinct host data paths" $
        assertBool "data paths differ" (dataPath prod /= dataPath test1)
    ]

acceleratorIngressCases :: [TestTree]
acceleratorIngressCases =
    [ testCase "in-cluster daemon uses ClusterIP with no host mapping" $
        acceleratorIngressPlan InClusterDaemon 8081 30081
            @?= AcceleratorIngressPlan
                { ingressServiceType = "ClusterIP"
                , ingressServicePort = 8081
                , ingressNodePort = Nothing
                , ingressKindListenAddress = Nothing
                }
    , testCase "host daemon uses local-only NodePort" $
        acceleratorIngressPlan HostResidentDaemon 8081 30081
            @?= AcceleratorIngressPlan
                { ingressServiceType = "NodePort"
                , ingressServicePort = 8081
                , ingressNodePort = Just 30081
                , ingressKindListenAddress = Just "127.0.0.1"
                }
    ]

nvidiaRuntimeCases :: [TestTree]
nvidiaRuntimeCases =
    [ testCase "NVIDIA runtime probe uses nvkind's volume-mount injection" $
        nvidiaRuntimeProbeArgs
            @?= [ "run"
                , "--rm"
                , "-v"
                , "/dev/null:/var/run/nvidia-container-devices/all"
                , "ubuntu:20.04"
                , "nvidia-smi"
                , "-L"
                ]
    , testCase "NVIDIA runtime probe accepts a GPU listing" $
        nvidiaRuntimeProbeReady (Right (ExitSuccess, "GPU 0: NVIDIA RTX 5090\n", "")) @?= True
    , testCase "NVIDIA runtime probe rejects empty or failed output" $ do
        nvidiaRuntimeProbeReady (Right (ExitSuccess, "", "")) @?= False
        nvidiaRuntimeProbeReady (Right (ExitFailure 1, "", "nvidia runtime missing")) @?= False
    ]

nvidiaDevicePluginCases :: [TestTree]
nvidiaDevicePluginCases =
    [ testCase "pins and installs the NVIDIA device-plugin chart" $
        nvidiaDevicePluginHelmArgs
            @?= [ "upgrade"
                , "--install"
                , "nvidia-device-plugin"
                , "nvdp/nvidia-device-plugin"
                , "--version"
                , "0.19.3"
                , "--namespace"
                , "nvidia"
                , "--create-namespace"
                , "--set"
                , "runtimeClassName=nvidia"
                , "--wait"
                , "--timeout"
                , "3m"
                ]
    , testCase "waits for the reconciled DaemonSet rollout and queries allocatable GPUs" $ do
        nvidiaDevicePluginReadyArgs
            @?= [ "rollout"
                , "status"
                , "daemonset/nvidia-device-plugin"
                , "-n"
                , "nvidia"
                , "--timeout=120s"
                ]
        nvidiaAllocatableProbeArgs
            @?= [ "get"
                , "nodes"
                , "-o"
                , "jsonpath={range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}"
                ]
    , testCase "requires at least one positive allocatable GPU" $ do
        nvidiaAllocatableReady (Right (ExitSuccess, "1\n", "")) @?= True
        nvidiaAllocatableReady (Right (ExitSuccess, "0\n\n", "")) @?= False
        nvidiaAllocatableReady (Right (ExitFailure 1, "", "not found")) @?= False
    , testCase "positive allocatable pre-probe is a verified no-op" $ do
        events <- newIORef ([] :: [String])
        let record event = modifyIORef' events (event :)
        ensureNvidiaDevicePluginWith
            NvidiaDevicePluginOps
                { ndpProbeAllocatable = record "probe-allocatable" >> pure True
                , ndpReconcilePlugin = record "reconcile-plugin"
                , ndpWaitPluginReady = record "wait-plugin-ready"
                , ndpRequireAllocatable = record "require-allocatable"
                }
        seen <- reverse <$> readIORef events
        seen @?= ["probe-allocatable"]
    , testCase "missing allocation reconciles, waits, then requires positive allocation" $ do
        events <- newIORef ([] :: [String])
        let record event = modifyIORef' events (event :)
        ensureNvidiaDevicePluginWith
            NvidiaDevicePluginOps
                { ndpProbeAllocatable = record "probe-allocatable" >> pure False
                , ndpReconcilePlugin = record "reconcile-plugin"
                , ndpWaitPluginReady = record "wait-plugin-ready"
                , ndpRequireAllocatable = record "require-allocatable"
                }
        seen <- reverse <$> readIORef events
        seen
            @?= [ "probe-allocatable"
                , "reconcile-plugin"
                , "wait-plugin-ready"
                , "require-allocatable"
                ]
    ]

nodeCordonCases :: [TestTree]
nodeCordonCases =
    [ testCase "kind has one cordoned control-plane" $
        clusterNodeNames prod @?= ["demo-control-plane"]
    , testCase "nvkind splits the one slice across control-plane and GPU worker" $ do
        let plan = resolvePlanWithDriver "demo" rootPath Production NvkindDriver
            resources = ResourceEnvelope 6 "8GiB" "20GiB"
            perNodeMemoryBytes = (4 * 1024 ^ (3 :: Int) :: Integer)
            perNodeMemory = show perNodeMemoryBytes
            perNodeSwap = show (2 * perNodeMemoryBytes)
        clusterNodeNames plan @?= ["demo-control-plane", "demo-worker"]
        clusterNodeCordonArgs plan resources
            @?= Right
                [ ["update", "--cpus", "3", "--memory", perNodeMemory, "--memory-swap", perNodeSwap, "demo-control-plane"]
                , ["update", "--cpus", "3", "--memory", perNodeMemory, "--memory-swap", perNodeSwap, "demo-worker"]
                ]
    , testCase "multi-node cordon refuses a CPU slice smaller than its node count" $
        assertBool "expected an undersized cordon to fail" $
            case clusterNodeCordonArgs (resolvePlanWithDriver "demo" rootPath Production NvkindDriver) (ResourceEnvelope 1 "8GiB" "20GiB") of
                Left _ -> True
                Right _ -> False
    , testCase "the plan owns node topology instead of inferring it from the driver" $ do
        let plan = prod{clusterNodeSuffixes = ["control-plane", "worker", "worker2"]}
        clusterNodeNames plan @?= ["demo-control-plane", "demo-worker", "demo-worker2"]
    , testCase "cordoning rejects an empty declared topology" $
        assertBool "expected an empty topology to fail" $
            case clusterNodeCordonArgs (prod{clusterNodeSuffixes = []}) (ResourceEnvelope 6 "8GiB" "20GiB") of
                Left _ -> True
                Right _ -> False
    ]

dataInvariantCases :: [TestTree]
dataInvariantCases =
    [ testCase "ensuring the durable root is idempotent and leaves existing content intact" $
        withSystemTempDirectory "hostbootstrap-durable-root" $ \root -> do
            first <- ensureDurableDataPath root
            first @?= root </> ".data"
            doesDirectoryExist first >>= (@?= True)
            let marker = first </> "marker"
            writeFile marker "durable-content"
            second <- ensureDurableDataPath root
            second @?= first
            readFile marker >>= (@?= "durable-content")
    , testCase "down removes nothing on disk and preserves .data" $ do
        let (remove, preserve) = teardown Down prod
        remove @?= []
        assertBool ".data preserved" (dataPath prod `elem` preserve)
    , testCase "delete removes derived state but never .data" $ do
        let (remove, preserve) = teardown Delete prod
        assertBool ".data not in removal set" (dataPath prod `notElem` remove)
        assertBool "derived state removed" (derivedPaths prod == remove)
        assertBool ".data preserved" (dataPath prod `elem` preserve)
    , testCase "test profile also never deletes its .data" $ do
        let (removeDown, _) = teardown Down test1
            (removeDel, _) = teardown Delete test1
        assertBool "down keeps test .data" (dataPath test1 `notElem` removeDown)
        assertBool "delete keeps test .data" (dataPath test1 `notElem` removeDel)
    ]

teardownFailureCases :: [TestTree]
teardownFailureCases =
    [ testCase "cluster down turns an unresolved kind cleanup into a reported failure" $
        withSystemTempDirectory "hostbootstrap-cluster-down" $ \root -> do
            let durable = root </> ".data"
                derived = root </> ".cluster" </> "demo"
                plan = (resolvePlan "demo" root Production){dataPath = durable, derivedPaths = [derived]}
                cfg = HostConfig (Substrate LinuxCpu Amd64) Map.empty
            createDirectoryIfMissing True durable
            createDirectoryIfMissing True derived
            outcome <- try (clusterDown cfg plan) :: IO (Either SomeException ())
            case outcome of
                Right () -> assertFailure "cluster down reported success after kind could not be resolved"
                Left err -> do
                    let message = displayException err
                    assertBool "names the aggregate teardown failure" ("cluster down attempted every cleanup step but failed" `isInfixOf` message)
                    assertBool "reports the unresolved kind tool" ("kind delete cluster: kind not found on this host" `isInfixOf` message)
            doesDirectoryExist durable >>= (@?= True)
            doesDirectoryExist derived >>= (@?= True)
    , testCase "cluster delete attempts every path after a non-zero kind cleanup and then fails" $
        withSystemTempDirectory "hostbootstrap-cluster-delete" $ \root -> do
            failingProgram <- findExecutable teardownFailureProgram
            case failingProgram >>= either (const Nothing) Just . mkAbsExe of
                Nothing -> assertFailure ("could not resolve teardown failure fixture: " ++ teardownFailureProgram)
                Just failingExe -> do
                    let durable = root </> ".data"
                        derivedOne = root </> ".cluster" </> "demo-a"
                        derivedTwo = root </> ".cluster" </> "demo-b"
                        plan =
                            (resolvePlan "demo" root Production)
                                { dataPath = durable
                                , derivedPaths = [derivedOne, derivedTwo]
                                }
                        cfg =
                            HostConfig
                                (Substrate LinuxCpu Amd64)
                                (Map.singleton Kind failingExe)
                    createDirectoryIfMissing True durable
                    createDirectoryIfMissing True derivedOne
                    createDirectoryIfMissing True derivedTwo
                    outcome <- try (clusterDelete cfg plan) :: IO (Either SomeException ())
                    case outcome of
                        Right () -> assertFailure "cluster delete reported success after kind exited non-zero"
                        Left err -> do
                            let message = displayException err
                            assertBool "names the aggregate teardown failure" ("cluster delete attempted every cleanup step but failed" `isInfixOf` message)
                            assertBool "reports the non-zero kind exit" ("kind delete cluster: exit" `isInfixOf` message)
                    doesDirectoryExist durable >>= (@?= True)
                    doesDirectoryExist derivedOne >>= (@?= False)
                    doesDirectoryExist derivedTwo >>= (@?= False)
    ]

teardownFailureProgram :: String
#ifdef mingw32_HOST_OS
teardownFailureProgram = "where.exe"
#else
teardownFailureProgram = "false"
#endif

statusCases :: [TestTree]
statusCases =
    [ testCase "running cluster reports only the data-path teardown omission contract" $ do
        let report = statusReport prod True
        assertBool "names the cluster" ("demo" `isInfixOf` report)
        assertBool "marks it running" ("(running)" `isInfixOf` report)
        assertBool
            "states that cluster teardown does not remove .data"
            (((rootPath </> ".data") ++ " (not removed by cluster teardown)") `isInfixOf` report)
        assertBool "does not claim the uninspected path is preserved" (not ("(preserved)" `isInfixOf` report))
    , testCase "absent cluster reports (absent) without claiming data was inspected" $ do
        let report = statusReport prod False
        assertBool "marks it absent" ("(absent)" `isInfixOf` report)
        assertBool "still states the teardown contract" ("(not removed by cluster teardown)" `isInfixOf` report)
        assertBool "does not claim the uninspected path is preserved" (not ("(preserved)" `isInfixOf` report))
    ]

snapshotPersistenceCases :: [TestTree]
snapshotPersistenceCases =
    [ testCase "fresh admission persists, verifies, and binds one exact indexed snapshot" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            let stable = renderSnapshot plan
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \verified bound binding lease active -> do
                    modifyIORef' continued (+ 1)
                    observed <- readRecord store (snapshotKey project unbound)
                    assertBool "continuation runs after the protected entries close" (observed /= Nothing)
                    exactPersistedEvidence verified bound binding lease active
            outcome
                @?= Right
                    ( stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    , stablePlanSnapshotBytes stable
                    , unboundRunLeaseRunText unbound
                    )
            readIORef continued >>= (@?= 1)
            snapshot <- requireRecord store (snapshotKey project unbound)
            recordVersionWord (protectedRecordVersion snapshot) @?= 1
            lease <- requireRecord store (leaseKey project unbound)
            recordVersionWord (protectedRecordVersion lease) @?= 2
            assertNoPreparedOrEffectRecords store
    , testCase "an exact snapshot-persisted unbound retry is idempotent" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            let stable = renderSnapshot plan
                key = snapshotKey project unbound
            writeStableSnapshot store project unbound stable
            before <- requireRecord store key
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ -> pure ()
            outcome @?= Right ()
            after <- requireRecord store key
            protectedRecordVersion after @?= protectedRecordVersion before
            protectedRecordBytes after @?= protectedRecordBytes before
            assertNoPreparedOrEffectRecords store
    , testCase "immutable canonical-byte substitution is refused without continuation work" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            let stable = renderSnapshot plan
            writeRawPlanSnapshot
                store
                project
                (unboundRunLeaseRunText unbound)
                (stablePlanSnapshotSpecDigest stable)
                (stablePlanSnapshotDigest stable)
                (stablePlanSnapshotConfigDigest stable)
                (stablePlanSnapshotBytes stable <> ByteString.singleton 0)
            original <- requireRecord store (snapshotKey project unbound)
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            assertSnapshotMismatch outcome
            readIORef continued >>= (@?= 0)
            retained <- requireRecord store (snapshotKey project unbound)
            retained @?= original
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "a malformed immutable snapshot is refused without lease or continuation work" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeRawRecord store (snapshotKey project unbound) "malformed-snapshot"
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            outcome
                @?= Left
                    ( SnapshotVerificationError
                        (ModeMalformedRecord (recordKeyText (snapshotKey project unbound)))
                    )
            readIORef continued >>= (@?= 0)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "a missing lease after snapshot persistence refuses before rewriting the snapshot" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            deleteRecord store (leaseKey project unbound)
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            outcome
                @?= Left
                    ( SnapshotVerificationError
                        (ModeLeaseMissing (unboundRunLeaseRunText unbound))
                    )
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    , testCase "a stale retained lease after snapshot persistence refuses without rewriting it" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            advanceRecordVersion store (leaseKey project unbound)
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            case outcome of
                Left (SnapshotVerificationError (ModeLeaseNotBindable run reason)) -> do
                    run @?= unboundRunLeaseRunText unbound
                    assertBool "reports the stale retained version" ("stale" `Text.isInfixOf` reason)
                other -> assertFailure ("expected stale-lease refusal, observed " <> show other)
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    , testCase "the exposed binding seam forces its private indexed witness" $
        withPersistedSnapshotPlan $ \store project _root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            attempted <-
                try
                    ( withPlanDigestBinding unbound plan $ \verified binding ->
                        bindRunLeaseWithPlanRecovery
                            unbound
                            (error "bottom private indexed snapshot")
                            verified
                            binding
                            (\_ _ -> modifyIORef' continued (+ 1))
                    ) ::
                    IO
                        ( Either
                            SomeException
                            (Either SnapshotError (Either LeaseConflict ()))
                        )
            case attempted of
                Left failure ->
                    assertBool
                        "the private indexed witness itself was forced"
                        ("bottom private indexed snapshot" `isInfixOf` displayException failure)
                Right other ->
                    assertFailure
                        ("the bottom private indexed witness was not forced: " <> show other)
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            assertLeaseVersion store project unbound 1
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    , testCase "a real protected snapshot read failure leaves the lease unbound" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            createDirectory (recordPath store (snapshotKey project unbound))
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            case outcome of
                Left (SnapshotVerificationError (ModeStoreFailure _)) -> pure ()
                other -> assertFailure ("expected protected read failure, observed " <> show other)
            readIORef continued >>= (@?= 0)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "same project and epoch in another store is rejected before any snapshot write" $
        withPersistedSnapshotPlan $ \_storeA project _rootA _unboundA plan ->
            withSystemTempDirectory "hostbootstrap-plan-origin-store-b" $ \directory -> do
                storeB <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
                second <-
                    withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                        let unboundB = productionRootUnboundLease productionRoot
                        continued <- newIORef (0 :: Int)
                        outcome <-
                            withPersistedPlanSnapshot
                                (productionRootAuthority productionRoot)
                                unboundB
                                plan
                                (\_ _ _ _ _ -> modifyIORef' continued (+ 1))
                        absent <- readRecord storeB (snapshotKey project unboundB)
                        count <- readIORef continued
                        pure (Right (outcome, absent, count))
                (outcome, observed, count) <- either (fail . show) pure second
                case outcome of
                    Left
                        ( SnapshotVerificationError
                            (ModeEvidenceMismatch "plan store" expected observedStore)
                            ) -> assertBool "the two protected stores have distinct identities" (expected /= observedStore)
                    other -> assertFailure ("expected plan-store refusal, observed " <> show other)
                observed @?= Nothing
                count @?= 0
                assertNoPreparedOrEffectRecords storeB
    , testCase "a stale plan epoch is rejected before any snapshot write" $
        withPersistedSnapshotPlan $ \_storeA project _rootA _unboundA plan ->
            withSystemTempDirectory "hostbootstrap-plan-origin-epoch-b" $ \directory -> do
                storeB <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
                writeRawRecord storeB (brokerGenerationKey project) "1"
                second <-
                    withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                        let unboundB = productionRootUnboundLease productionRoot
                        continued <- newIORef (0 :: Int)
                        outcome <-
                            withPersistedPlanSnapshot
                                (productionRootAuthority productionRoot)
                                unboundB
                                plan
                                (\_ _ _ _ _ -> modifyIORef' continued (+ 1))
                        absent <- readRecord storeB (snapshotKey project unboundB)
                        count <- readIORef continued
                        pure (Right (outcome, absent, count))
                (outcome, observed, count) <- either (fail . show) pure second
                outcome
                    @?= Left
                        ( SnapshotVerificationError
                            (ModeEvidenceMismatch "plan epoch" "2" "1")
                        )
                observed @?= Nothing
                count @?= 0
                assertNoPreparedOrEffectRecords storeB
    ]
        <> snapshotFilesystemFailureCases

existingBoundSnapshotCases :: [TestTree]
existingBoundSnapshotCases =
    [ testCase "terminal admission yields only the exact close key after unlocking" $
        withExistingBoundSnapshotFixture $ \store project unbound bound _stable -> do
            closeKey <- either (fail . show) pure (mkInvocationCloseKey "production-up-close")
            recorded <-
                withProtectedEntry store $ \session ->
                    fmap Right
                        ( recordProductionInvocationAcknowledgment
                            session
                            project
                            bound
                            closeKey
                        )
            either (fail . show) (either (fail . show) pure) recorded
            -- Terminal classification must not inspect Open revision state.
            writeRawRecord store (migrationKey project) "malformed-migration"
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    ( \observed -> do
                        assertProtectedEntryReleased store
                        modifyIORef' terminalCount (+ 1)
                        invocationCloseKeyText observed @?= "production-up-close"
                        pure ("terminal" :: Text.Text)
                    )
                    ( \_ _ _ _ _ _ _ -> do
                        modifyIORef' openCount (+ 1)
                        pure "open"
                    )
            outcome @?= Right "terminal"
            readIORef terminalCount >>= (@?= 1)
            readIORef openCount >>= (@?= 0)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "Open admission jointly propagates the exact indexed evidence after unlocking" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open invocation entered the terminal callback")
                    ( \root modeLease boundLease verified boundSnapshot binding recovery -> do
                        assertProtectedEntryReleased store
                        exactBoundAdmissionEvidence
                            root
                            modeLease
                            boundLease
                            verified
                            boundSnapshot
                            binding
                            recovery
                    )
            outcome
                @?= Right
                    ( stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    , stablePlanSnapshotBytes stable
                    , 1
                    , NormalRevision
                    )
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "two Open admissions preserve durable bytes and mint isolated local identities" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            continued <- newIORef (0 :: Int)
            let open _ _ _ _ _ _ _ = modifyIORef' continued (+ 1)
            first <- withBoundPlanSnapshot store project (\_ -> pure ()) open
            second <- withBoundPlanSnapshot store project (\_ -> pure ()) open
            first @?= Right ()
            second @?= Right ()
            readIORef continued >>= (@?= 2)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "an Open callback exception releases admission for exact re-entry" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            attempted <-
                try
                    ( withBoundPlanSnapshot
                        store
                        project
                        (\_ -> pure ())
                        (\_ _ _ _ _ _ _ -> ioError (userError "Open callback interrupted"))
                    ) ::
                    IO (Either SomeException (Either SnapshotError ()))
            case attempted of
                Left failure ->
                    assertBool
                        "the callback exception escaped the already-released bracket"
                        ("Open callback interrupted" `isInfixOf` displayException failure)
                Right other -> assertFailure ("the callback interruption was swallowed: " <> show other)
            resumed <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open re-entry entered the terminal callback")
                    (\_ _ _ _ _ _ _ -> pure ())
            resumed @?= Right ()
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "the package-gated lower seam forces its hidden admission witness" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            attempted <-
                try
                    ( withBoundPlanSnapshotKernel
                        (error "bottom existing-bound admission witness")
                        store
                        project
                        (\_ -> modifyIORef' terminalCount (+ 1))
                        (\_ _ _ _ _ _ _ -> modifyIORef' openCount (+ 1))
                    ) ::
                    IO (Either SomeException (Either ModeError ()))
            case attempted of
                Left failure ->
                    assertBool
                        "the hidden package witness was forced before store access"
                        ("bottom existing-bound admission witness" `isInfixOf` displayException failure)
                Right other ->
                    assertFailure ("the bottom admission witness was accepted: " <> show other)
            readIORef terminalCount >>= (@?= 0)
            readIORef openCount >>= (@?= 0)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "the shared compatibility sentinel passes structural snapshot admission" $ do
        admitted <- admitCanonicalRootMutation "<hostbootstrap:unrooted-lifecycle-plan>"
        assertBool "the compatibility snapshot lost its canonical bytes" (not (ByteString.null admitted))
    , testCase "canonical-root code points preserve surrogate and replacement-character identity" $ do
        surrogate <- admitCanonicalRootMutation (rootDir </> ['\xD800'])
        replacement <- admitCanonicalRootMutation (rootDir </> ['\xFFFD'])
        assertBool
            "a surrogate code point collapsed into the Unicode replacement character"
            (surrogate /= replacement)
    ]
        <> existingOpenRevisionCases
        <> existingBoundRefusalCases

admitCanonicalRootMutation :: FilePath -> IO ByteString.ByteString
admitCanonicalRootMutation root =
    withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
        let specDigest = stablePlanSnapshotSpecDigest stable
            changedBytes = replaceCanonicalRoot root (stablePlanSnapshotBytes stable)
            changedPlan = canonicalPlanDigestForTest specDigest changedBytes
        replaceRawRecord
            store
            (leaseKey project unbound)
            (encodeExactFields ["bound", "1", specDigest, changedPlan])
        replaceRawRecord
            store
            (snapshotKey project unbound)
            ( rawPlanSnapshotPayloadWithConfig
                1
                specDigest
                changedPlan
                (stablePlanSnapshotConfigDigest stable)
                changedBytes
            )
        outcome <-
            withBoundPlanSnapshot
                store
                project
                (\_ -> assertFailure "the mutated Open snapshot entered the terminal callback")
                (\_ _ _ _ boundSnapshot _ _ -> pure (boundPlanSnapshotBytes boundSnapshot))
        either (fail . show) pure outcome

existingOpenRevisionCases :: [TestTree]
existingOpenRevisionCases =
    [ revisionCase
        "Open admission retains an incomplete migration revision"
        "incomplete\tmigration-12-18"
        (IncompleteMigration "migration-12-18")
    , revisionCase
        "Open admission retains a completed migration revision"
        "completed\tmigration-12-18"
        (CompletedMigration "migration-12-18")
    ]
  where
    revisionCase label payload expected =
        testCase label $
            withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
                writeRawRecord store (migrationKey project) payload
                let keys = productionAdmissionKeys project unbound
                before <- mapM (readRecord store) keys
                outcome <-
                    withBoundPlanSnapshot
                        store
                        project
                        (\_ -> assertFailure "an Open revision entered the terminal callback")
                        (\_ _ _ _ _ _ recovery -> pure (boundInvocationRecoveryRevisionKind recovery))
                outcome @?= Right expected
                mapM (readRecord store) keys >>= (@?= before)

existingBoundRefusalCases :: [TestTree]
existingBoundRefusalCases =
    [ refusalCase
        "an advanced broker counter is exact-generation drift"
        (\store project _ _ -> replaceRawRecord store (brokerGenerationKey project) "2")
        (\failure -> case failure of ModeAuthorityFailure (AuthorityInvalidIdentity _) -> True; _ -> False)
    , refusalCase
        "a missing authority binding is refused read-only"
        (\store _ _ _ -> deleteRecord store authorityBindingKey)
        (\failure -> case failure of ModeAuthorityFailure (AuthorityMalformedBinding _) -> True; _ -> False)
    , refusalCase
        "a missing Production mode is refused"
        (\store project _ _ -> deleteRecord store (productionModeKey project))
        (\failure -> case failure of ModeWrongMode "production" "absent" -> True; _ -> False)
    , refusalCase
        "a missing bound lease is refused"
        (\store project unbound _ -> deleteRecord store (leaseKey project unbound))
        (\failure -> case failure of ModeLeaseMissing "production" -> True; _ -> False)
    , refusalCase
        "a missing immutable snapshot is refused"
        (\store project unbound _ -> deleteRecord store (snapshotKey project unbound))
        (\failure -> case failure of ModeSnapshotMissing "production" -> True; _ -> False)
    , refusalCase
        "bound lease epoch drift is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (leaseKey project unbound)
                ( encodeExactFields
                    [ "bound"
                    , "2"
                    , stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    ]
                )
        )
        (\failure -> case failure of ModeEpochMismatch 2 1 -> True; _ -> False)
    , refusalCase
        "empty bound lease digests are malformed"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", "", stablePlanSnapshotDigest stable])
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "lease and snapshot digest drift is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (leaseKey project unbound)
                ( encodeExactFields
                    [ "bound"
                    , "1"
                    , stablePlanSnapshotSpecDigest stable
                    , "different-plan-digest"
                    ]
                )
        )
        (\failure -> case failure of ModeSnapshotMismatch _ _ -> True; _ -> False)
    , refusalCase
        "an unsupported snapshot envelope version is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                (rawPlanSnapshotPayload 2 stable (stablePlanSnapshotBytes stable))
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "the rootless version-2 canonical plan is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                (rawPlanSnapshotPayload 1 stable (replaceCanonicalVersion 2 (stablePlanSnapshotBytes stable)))
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "malformed canonical plan bytes are refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                (rawPlanSnapshotPayload 1 stable "not-a-canonical-plan")
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "canonical content-digest drift is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayload
                    1
                    stable
                    (stablePlanSnapshotBytes stable <> ByteString.singleton 0)
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "a recomputed digest cannot bless a relative canonical root"
        ( \store project unbound stable -> do
            let specDigest = stablePlanSnapshotSpecDigest stable
                changedBytes = replaceCanonicalRoot "relative-root" (stablePlanSnapshotBytes stable)
                changedPlan = canonicalPlanDigestForTest specDigest changedBytes
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", specDigest, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    specDigest
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    changedBytes
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "the outer and embedded canonical configuration digests must agree"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    "different-config-digest"
                    (stablePlanSnapshotBytes stable)
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "coordinated lease/envelope drift cannot relabel the embedded specification"
        ( \store project unbound stable -> do
            let changedSpec = "different-spec-digest"
                digestSuffix = Text.dropWhile (/= ':') (stablePlanSnapshotDigest stable)
                changedPlan = changedSpec <> digestSuffix
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", changedSpec, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    changedSpec
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "a recomputed digest cannot bless a structurally corrupt canonical step stream"
        ( \store project unbound stable -> do
            let specDigest = stablePlanSnapshotSpecDigest stable
                changedBytes = replaceCanonicalStepCount 2 (stablePlanSnapshotBytes stable)
                changedPlan = canonicalPlanDigestForTest specDigest changedBytes
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", specDigest, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    specDigest
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    changedBytes
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "a legacy digest-only snapshot cannot mint bound plan evidence"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( encodeExactFields
                    [ "1"
                    , stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    ]
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "an invalid terminal close key is never normalized or surfaced"
        (\store project _ _ -> writeRawRecord store (productionInvocationKey project) "ack\tbad/key")
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "terminal close-key whitespace is never stripped"
        (\store project _ _ -> writeRawRecord store (productionInvocationKey project) "ack\tvalid-key ")
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    , refusalCase
        "a Harness Closing disposition cannot enter Production recovery"
        (\store project _ _ -> writeRawRecord store (productionInvocationKey project) "closing\t1")
        (\failure -> case failure of ModeWrongRecoveryScope "production" _ -> True; _ -> False)
    , refusalCase
        "malformed Open revision state is refused before the callback"
        (\store project _ _ -> writeRawRecord store (migrationKey project) "incomplete\t")
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)
    ]
        <> canonicalRootParserRefusalCases

canonicalRootParserRefusalCases :: [TestTree]
canonicalRootParserRefusalCases =
    [ canonicalRootParserRefusalCase "an empty canonical root is refused" ByteString.empty
    , canonicalRootParserRefusalCase
        "a partial canonical-root code point is refused"
        (ByteString.singleton 0)
    , canonicalRootParserRefusalCase
        "an out-of-range canonical-root code point is refused"
        (ByteString.pack [0, 17, 0, 0])
    , canonicalRootParserRefusalCase
        "a NUL canonical-root code point is refused"
        (ByteString.replicate 4 0)
    , canonicalRootParserRefusalCase
        "an oversized canonical root is refused"
        (ByteString.replicate 131076 0)
    ]

canonicalRootParserRefusalCase :: String -> ByteString.ByteString -> TestTree
canonicalRootParserRefusalCase label rootPayload =
    refusalCase
        label
        ( \store project unbound stable -> do
            let specDigest = stablePlanSnapshotSpecDigest stable
                changedBytes =
                    replaceCanonicalRootPayload rootPayload (stablePlanSnapshotBytes stable)
                changedPlan = canonicalPlanDigestForTest specDigest changedBytes
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", specDigest, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    specDigest
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    changedBytes
                )
        )
        (\failure -> case failure of ModeMalformedRecord _ -> True; _ -> False)

recoveredProductionProfileCases :: [TestTree]
recoveredProductionProfileCases =
    [ testCase "the exact seven-value Open package refines without selecting another plan identity" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                    (\root modeLease boundLease verified boundSnapshot binding recovery ->
                        pure
                            ( exactRecoveredProductionProfileEvidence
                                root
                                modeLease
                                boundLease
                                verified
                                boundSnapshot
                                binding
                                recovery
                            )
                    )
            case outcome of
                Right
                    ( Right
                            ( run
                                , profileProject
                                , profileStore
                                , revision
                                , specDigest
                                , planDigest
                                , configDigest
                                , canonicalBytes
                                , epoch
                                , revisionKind
                                )
                        ) -> do
                            run @?= "production"
                            profileProject @?= installedProjectName project
                            assertBool "the recovered profile retains a protected-store identity" (not (Text.null profileStore))
                            revision @?= 1
                            specDigest @?= stablePlanSnapshotSpecDigest stable
                            planDigest @?= stablePlanSnapshotDigest stable
                            configDigest @?= stablePlanSnapshotConfigDigest stable
                            canonicalBytes @?= stablePlanSnapshotBytes stable
                            epoch @?= 1
                            revisionKind @?= NormalRevision
                other -> assertFailure ("expected exact recovered profile, observed " <> show other)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "pure profile refinement is repeatable and leaves every protected record unchanged" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                    (\root modeLease boundLease verified boundSnapshot binding recovery -> do
                        let refine =
                                withRecoveredProductionLifecycleProfile
                                    root
                                    modeLease
                                    boundLease
                                    verified
                                    boundSnapshot
                                    binding
                                    recovery
                                    recoveredProductionProfileRevisionKind
                        pure (refine, refine)
                    )
            outcome @?= Right (Right NormalRevision, Right NormalRevision)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "a fresh-bound lease cannot substitute for the exact existing binding" $
        withExistingBoundSnapshotFixture $ \store project unbound freshBound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                    (\root modeLease _existingBound verified boundSnapshot binding recovery ->
                        pure
                            ( withRecoveredProductionLifecycleProfile
                                root
                                modeLease
                                (unsafeCoerce freshBound)
                                verified
                                boundSnapshot
                                binding
                                recovery
                                (const ())
                            )
                    )
            case outcome of
                Right
                    ( Left
                            ( ModeEvidenceMismatch
                                    "lease binding origin"
                                    "existing"
                                    "fresh"
                                )
                        ) -> pure ()
                other -> assertFailure ("expected fresh-binding refusal, observed " <> show other)
            mapM (readRecord store) keys >>= (@?= before)
    ]
        <> recoveredProductionRevisionCases
        <> recoveredProductionProfileDriftCases

recoveredProductionRevisionCases :: [TestTree]
recoveredProductionRevisionCases =
    [ revisionCase
        "the recovered profile retains an incomplete migration classification"
        "incomplete\tmigration-12-19"
        (IncompleteMigration "migration-12-19")
    , revisionCase
        "the recovered profile retains a completed migration classification"
        "completed\tmigration-12-19"
        (CompletedMigration "migration-12-19")
    ]
  where
    revisionCase label payload expected =
        testCase label $
            withExistingBoundSnapshotFixture $ \store project _unbound _bound _stable -> do
                writeRawRecord store (migrationKey project) payload
                outcome <-
                    withBoundPlanSnapshot
                        store
                        project
                        (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                        (\root modeLease boundLease verified boundSnapshot binding recovery ->
                            pure
                                ( withRecoveredProductionLifecycleProfile
                                    root
                                    modeLease
                                    boundLease
                                    verified
                                    boundSnapshot
                                    binding
                                    recovery
                                    recoveredProductionProfileRevisionKind
                                )
                        )
                outcome @?= Right (Right expected)

data RecoveredProductionProfileDrift
    = RecoveredRootDrift
    | RecoveredModeDrift
    | RecoveredLeaseDrift
    | RecoveredVerifiedSnapshotDrift
    | RecoveredBoundSnapshotDrift
    | RecoveredDigestBindingDrift
    | RecoveredRecoveryDrift
    | RecoveredBrokerDrift

recoveredProductionProfileDriftCases :: [TestTree]
recoveredProductionProfileDriftCases =
    [ mismatchCase
        "root origin drift is refused"
        RecoveredRootDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "root store" _ _ -> True; _ -> False)
    , mismatchCase
        "Production mode origin drift is refused"
        RecoveredModeDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "mode store" _ _ -> True; _ -> False)
    , mismatchCase
        "bound lease origin drift is refused"
        RecoveredLeaseDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "root store" _ _ -> True; _ -> False)
    , mismatchCase
        "verified snapshot origin drift is refused"
        RecoveredVerifiedSnapshotDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "snapshot store" _ _ -> True; _ -> False)
    , mismatchCase
        "stable canonical-byte drift is refused"
        RecoveredBoundSnapshotDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "canonical bytes" _ _ -> True; _ -> False)
    , mismatchCase
        "stable plan-digest binding drift is refused"
        RecoveredDigestBindingDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "digest binding" _ _ -> True; _ -> False)
    , mismatchCase
        "broker generation drift is refused"
        RecoveredBrokerDrift
        (Just 1)
        (\failure -> case failure of ModeEpochMismatch 1 2 -> True; _ -> False)
    , mismatchCase
        "bound-invocation recovery origin drift is refused"
        RecoveredRecoveryDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "recovery store" _ _ -> True; _ -> False)
    ]
  where
    mismatchCase label drift initialForeignCounter accepts =
        testCase label $
            withExistingBoundOpenPackage Nothing $ \_outerStore _outerProject outer ->
                withExistingBoundOpenPackage initialForeignCounter $ \_foreignStore _foreignProject foreignPackage ->
                    case refineRecoveredProductionProfileWithDrift drift outer foreignPackage of
                        Left failure | accepts failure -> pure ()
                        other -> assertFailure ("expected recovered-profile refusal, observed " <> show other)

refusalCase ::
    String ->
    ( forall projectId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      StablePlanSnapshot ->
      IO ()
    ) ->
    (ModeError -> Bool) ->
    TestTree
refusalCase label mutate accepts =
    testCase label $
        withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
            mutate store project unbound stable
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> modifyIORef' terminalCount (+ 1))
                    (\_ _ _ _ _ _ _ -> modifyIORef' openCount (+ 1))
            case outcome of
                Left (SnapshotVerificationError failure)
                    | accepts failure -> pure ()
                other -> assertFailure ("expected existing-bound refusal, observed " <> show other)
            readIORef terminalCount >>= (@?= 0)
            readIORef openCount >>= (@?= 0)
            mapM (readRecord store) keys >>= (@?= before)

#ifdef mingw32_HOST_OS
snapshotFilesystemFailureCases :: [TestTree]
snapshotFilesystemFailureCases = []
#else
snapshotFilesystemFailureCases :: [TestTree]
snapshotFilesystemFailureCases =
    [ testCase "a real protected snapshot write failure leaves the lease unbound" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            let records = protectedStoreRoot store </> "records"
            permissions <- getPermissions records
            let readOnly = permissions{writable = False}
            outcome <-
                ( do
                    setPermissions records readOnly
                    withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                        modifyIORef' continued (+ 1)
                )
                    `finally` setPermissions records permissions
            case outcome of
                Left (SnapshotVerificationError (ModeStoreFailure _)) -> pure ()
                other -> assertFailure ("expected protected write failure, observed " <> show other)
            readIORef continued >>= (@?= 0)
            readRecord store (snapshotKey project unbound) >>= (@?= Nothing)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "a lease-CAS write failure preserves the verified snapshot and unbound lease" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            let records = protectedStoreRoot store </> "records"
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            permissions <- getPermissions records
            let readOnly = permissions{writable = False}
            outcome <-
                ( do
                    setPermissions records readOnly
                    withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                        modifyIORef' continued (+ 1)
                )
                    `finally` setPermissions records permissions
            case outcome of
                Left (SnapshotLeaseConflict conflict) ->
                    assertBool
                        "the separate lease publish reports its store failure"
                        ("publish a protected record" `Text.isInfixOf` leaseConflictMessage conflict)
                other -> assertFailure ("expected separate lease-CAS failure, observed " <> show other)
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            assertLeaseVersion store project unbound 1
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    ]
#endif

exactPersistedEvidence ::
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    NormalActiveRecovery scope specDigest planDigest planId brokerGeneration ->
    IO (Text.Text, Text.Text, ByteString.ByteString, Text.Text)
exactPersistedEvidence verified bound _binding lease active = do
    planSnapshotRevision verified @?= 1
    planSnapshotCanonicalBytes verified @?= Just (boundPlanSnapshotBytes bound)
    boundRunLeaseSpecDigest lease @?= planSnapshotSpecDigest verified
    boundRunLeasePlanDigest lease @?= planSnapshotPlanDigest verified
    boundRunLeaseRunText lease @?= planSnapshotRunText verified
    normalActiveRecoveryRunText active @?= planSnapshotRunText verified
    pure
        ( planSnapshotSpecDigest verified
        , planSnapshotPlanDigest verified
        , boundPlanSnapshotBytes bound
        , planSnapshotRunText verified
        )

exactBoundAdmissionEvidence ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId)
        specDigest
        planDigest
        planId
        brokerGeneration ->
    IO (Text.Text, Text.Text, ByteString.ByteString, Word64, OpenRevisionKind)
exactBoundAdmissionEvidence root modeLease lease verified bound _binding recovery = do
    rootAuthorityVerb root @?= ProjectUp
    let rootEpoch = brokerEpochWord (rootAuthorityEpoch root)
    brokerEpochWord (projectModeLeaseEpoch modeLease) @?= rootEpoch
    planSnapshotRevision verified @?= 1
    planSnapshotCanonicalBytes verified @?= Just (boundPlanSnapshotBytes bound)
    boundRunLeaseSpecDigest lease @?= planSnapshotSpecDigest verified
    boundRunLeasePlanDigest lease @?= planSnapshotPlanDigest verified
    boundRunLeaseRunText lease @?= planSnapshotRunText verified
    boundInvocationRecoveryRunText recovery @?= planSnapshotRunText verified
    pure
        ( planSnapshotSpecDigest verified
        , planSnapshotPlanDigest verified
        , boundPlanSnapshotBytes bound
        , rootEpoch
        , boundInvocationRecoveryRevisionKind recovery
        )

exactRecoveredProductionProfileEvidence ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId)
        specDigest
        planDigest
        planId
        brokerGeneration ->
    Either
        ModeError
        ( Text.Text
        , Text.Text
        , Text.Text
        , Word64
        , Text.Text
        , Text.Text
        , Text.Text
        , ByteString.ByteString
        , Word64
        , OpenRevisionKind
        )
exactRecoveredProductionProfileEvidence root modeLease lease verified bound binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        modeLease
        lease
        verified
        bound
        binding
        recovery
        ( \profile ->
            ( recoveredProductionProfileRunText profile
            , recoveredProductionProfileProjectName profile
            , recoveredProductionProfileStoreIdentity profile
            , recoveredProductionProfileRevision profile
            , recoveredProductionProfileSpecDigest profile
            , recoveredProductionProfilePlanDigest profile
            , recoveredProductionProfileConfigDigest profile
            , recoveredProductionProfileCanonicalBytes profile
            , recoveredProductionProfileEpoch profile
            , recoveredProductionProfileRevisionKind profile
            )
        )

data RecoveredProductionProfileInputs projectId specDigest planDigest planId brokerGeneration
    = RecoveredProductionProfileInputs
        (RootInvocationAuthority (Production projectId) brokerGeneration VerbUp)
        (ProjectModeLease projectId ProductionMode brokerGeneration)
        (BoundRunLease (Production projectId) specDigest planDigest brokerGeneration)
        (VerifiedPlanSnapshot (Production projectId) specDigest planDigest)
        (BoundPlanSnapshot (Production projectId) specDigest planDigest planId)
        (PlanDigestBinding (Production projectId) specDigest planDigest planId)
        ( BoundInvocationRecovery
            (Production projectId)
            specDigest
            planDigest
            planId
            brokerGeneration
        )

refineRecoveredProductionProfileWithDrift ::
    forall
        projectId
        specDigest
        planDigest
        planId
        brokerGeneration
        otherProjectId
        otherSpecDigest
        otherPlanDigest
        otherPlanId
        otherBrokerGeneration.
    RecoveredProductionProfileDrift ->
    RecoveredProductionProfileInputs
        projectId specDigest planDigest planId brokerGeneration ->
    RecoveredProductionProfileInputs
        otherProjectId otherSpecDigest otherPlanDigest otherPlanId otherBrokerGeneration ->
    Either ModeError ()
refineRecoveredProductionProfileWithDrift
    drift
    (RecoveredProductionProfileInputs root modeLease lease verified bound binding recovery)
    ( RecoveredProductionProfileInputs
            otherRoot
            otherModeLease
            otherLease
            otherVerified
            otherBound
            otherBinding
            otherRecovery
        ) =
        -- Ordinary callers cannot construct these cross-index packages: the
        -- compile-fail suite proves that boundary.  Deliberate test-only
        -- unsafe coercion reaches the runtime backstops against compromised or
        -- package-private evidence without weakening the public API.
        case drift of
            RecoveredRootDrift -> apply (unsafeCoerce otherRoot) modeLease lease verified bound binding recovery
            RecoveredModeDrift -> apply root (unsafeCoerce otherModeLease) lease verified bound binding recovery
            RecoveredLeaseDrift -> apply root modeLease (unsafeCoerce otherLease) verified bound binding recovery
            RecoveredVerifiedSnapshotDrift ->
                apply root modeLease lease (unsafeCoerce otherVerified) bound binding recovery
            RecoveredBoundSnapshotDrift ->
                apply root modeLease lease verified (unsafeCoerce otherBound) binding recovery
            RecoveredDigestBindingDrift ->
                apply root modeLease lease verified bound (unsafeCoerce otherBinding) recovery
            RecoveredRecoveryDrift ->
                apply root modeLease lease verified bound binding (unsafeCoerce otherRecovery)
            RecoveredBrokerDrift ->
                apply root modeLease lease verified bound binding (unsafeCoerce otherRecovery)
  where
    apply ::
        RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
        ProjectModeLease projectId ProductionMode brokerGeneration ->
        BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
        VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
        BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
        PlanDigestBinding (Production projectId) specDigest planDigest planId ->
        BoundInvocationRecovery
            (Production projectId)
            specDigest
            planDigest
            planId
            brokerGeneration ->
        Either ModeError ()
    apply exactRoot exactMode exactLease exactVerified exactBound exactBinding exactRecovery =
        withRecoveredProductionLifecycleProfile
            exactRoot
            exactMode
            exactLease
            exactVerified
            exactBound
            exactBinding
            exactRecovery
            (const ())

withExistingBoundOpenPackage ::
    Maybe Word64 ->
    ( forall projectId specDigest planDigest planId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProductionProfileInputs
        projectId specDigest planDigest planId brokerGeneration ->
      IO result
    ) ->
    IO result
withExistingBoundOpenPackage initialCounter use =
    withExistingBoundSnapshotFixtureAtCounter initialCounter $ \store project _unbound _bound _stable -> do
        admitted <-
            withBoundPlanSnapshot
                store
                project
                (\_ -> assertFailure "the Open package fixture entered the terminal callback")
                (\root modeLease lease verified bound binding recovery ->
                    use
                        store
                        project
                        ( RecoveredProductionProfileInputs
                            root
                            modeLease
                            lease
                            verified
                            bound
                            binding
                            recovery
                        )
                )
        either (fail . show) pure admitted

withExistingBoundSnapshotFixture ::
    ( forall projectId brokerGeneration specDigest planDigest.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      BoundRunLease
        (Production projectId)
        specDigest
        planDigest
        brokerGeneration ->
      StablePlanSnapshot ->
      IO result
    ) ->
    IO result
withExistingBoundSnapshotFixture use =
    withExistingBoundSnapshotFixtureAtCounter Nothing use

withExistingBoundSnapshotFixtureAtCounter ::
    Maybe Word64 ->
    ( forall projectId brokerGeneration specDigest planDigest.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      BoundRunLease
        (Production projectId)
        specDigest
        planDigest
        brokerGeneration ->
      StablePlanSnapshot ->
      IO result
    ) ->
    IO result
withExistingBoundSnapshotFixtureAtCounter initialCounter use =
    withPersistedSnapshotPlanAtCounter initialCounter $ \store project root unbound plan -> do
        let stable = renderSnapshot plan
        admitted <-
            withPersistedPlanSnapshot root unbound plan $ \_ _ _ bound _ ->
                use store project unbound bound stable
        either (fail . show) pure admitted

assertProtectedEntryReleased :: ProtectedStore -> IO ()
assertProtectedEntryReleased store = do
    attempted <- tryProtectedEntry store (\_ -> pure (Right ()))
    case attempted of
        Right (Just ()) -> pure ()
        other -> assertFailure ("snapshot callback ran before protected unlock: " <> show other)

productionAdmissionKeys ::
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    [RecordKey]
productionAdmissionKeys project unbound =
    [ authorityBindingKey
    , brokerGenerationKey project
    , productionModeKey project
    , leaseKey project unbound
    , snapshotKey project unbound
    , productionInvocationKey project
    , migrationKey project
    ]

authorityBindingKey :: RecordKey
authorityBindingKey = exactRecordKey "authority.binding"

productionModeKey :: InstalledProjectIdentity projectId -> RecordKey
productionModeKey project = exactRecordKey ("mode." <> installedProjectName project)

productionInvocationKey :: InstalledProjectIdentity projectId -> RecordKey
productionInvocationKey project =
    exactRecordKey ("invocation." <> installedProjectName project <> ".production")

migrationKey :: InstalledProjectIdentity projectId -> RecordKey
migrationKey project =
    exactRecordKey ("migration." <> installedProjectName project <> ".production")

exactRecordKey :: Text.Text -> RecordKey
exactRecordKey = either (error . show) id . mkRecordKey

encodeExactFields :: [Text.Text] -> ByteString.ByteString
encodeExactFields = TextEncoding.encodeUtf8 . Text.intercalate "\t"

rawPlanSnapshotPayload ::
    Word64 ->
    StablePlanSnapshot ->
    ByteString.ByteString ->
    ByteString.ByteString
rawPlanSnapshotPayload envelopeVersion stable canonicalBytes =
    rawPlanSnapshotPayloadWithConfig
        envelopeVersion
        (stablePlanSnapshotSpecDigest stable)
        (stablePlanSnapshotDigest stable)
        (stablePlanSnapshotConfigDigest stable)
        canonicalBytes

rawPlanSnapshotPayloadWithConfig ::
    Word64 ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString ->
    ByteString.ByteString
rawPlanSnapshotPayloadWithConfig envelopeVersion specDigest planDigest configDigest canonicalBytes =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                <> Builder.word64BE envelopeVersion
                <> Builder.word64BE 1
                <> encodeSnapshotText specDigest
                <> encodeSnapshotText planDigest
                <> Builder.word8 1
                <> encodeSnapshotText configDigest
                <> encodeSnapshotBytes canonicalBytes
            )
        )

replaceCanonicalVersion :: Word64 -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalVersion version bytes =
    planMagic
        <> LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64BE version))
        <> ByteString.drop (ByteString.length planMagic + 8) bytes
  where
    planMagic = "HOSTBOOTSTRAP-PLAN"

replaceCanonicalRoot :: FilePath -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalRoot root bytes =
    replaceCanonicalRootPayload (encodedRootPayload root) bytes

replaceCanonicalRootPayload :: ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalRootPayload rootPayload bytes =
    case rootFrameOffsets bytes of
        Nothing -> error "the fixture canonical root prefix is malformed"
        Just (rootValueOffset, afterRoot) ->
            ByteString.take rootValueOffset bytes
                <> LazyByteString.toStrict
                    (Builder.toLazyByteString (encodeSnapshotBytes rootPayload))
                <> ByteString.drop afterRoot bytes

rootFrameOffsets :: ByteString.ByteString -> Maybe (Int, Int)
rootFrameOffsets bytes = do
    let afterVersion = ByteString.length ("HOSTBOOTSTRAP-PLAN" :: ByteString.ByteString) + 8
    rootValueOffset <- skipCanonicalFrame bytes afterVersion
    afterRoot <- skipCanonicalFrame bytes rootValueOffset
    pure (rootValueOffset, afterRoot)

encodedRootPayload :: FilePath -> ByteString.ByteString
encodedRootPayload root =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            (foldMap (Builder.word32BE . fromIntegral . ord) root)
        )

replaceCanonicalStepCount :: Word64 -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalStepCount count bytes =
    case canonicalStepCountOffset bytes of
        Nothing -> error "the fixture canonical plan prefix is malformed"
        Just offset ->
            ByteString.take offset bytes
                <> encodedWord count
                <> ByteString.drop (offset + 8) bytes

canonicalStepCountOffset :: ByteString.ByteString -> Maybe Int
canonicalStepCountOffset bytes = do
    let afterVersion = ByteString.length ("HOSTBOOTSTRAP-PLAN" :: ByteString.ByteString) + 8
    afterRootTag <- skipCanonicalFrame bytes afterVersion
    afterRoot <- skipCanonicalFrame bytes afterRootTag
    afterSpecTag <- skipCanonicalFrame bytes afterRoot
    afterSpec <- skipCanonicalFrame bytes afterSpecTag
    afterConfigTag <- skipCanonicalFrame bytes afterSpec
    afterConfig <- skipCanonicalFrame bytes afterConfigTag
    skipCanonicalFrame bytes afterConfig

skipCanonicalFrame :: ByteString.ByteString -> Int -> Maybe Int
skipCanonicalFrame bytes offset = do
    frameLength <- canonicalWordAt bytes offset
    let payloadOffset = offset + 8
    if payloadOffset > ByteString.length bytes
        || frameLength > fromIntegral (ByteString.length bytes - payloadOffset)
        then Nothing
        else Just (payloadOffset + fromIntegral frameLength)

canonicalWordAt :: ByteString.ByteString -> Int -> Maybe Word64
canonicalWordAt bytes offset =
    let wordBytes = ByteString.take 8 (ByteString.drop offset bytes)
     in if ByteString.length wordBytes /= 8
            then Nothing
            else Just (ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 wordBytes)

encodedWord :: Word64 -> ByteString.ByteString
encodedWord = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

canonicalPlanDigestForTest :: Text.Text -> ByteString.ByteString -> Text.Text
canonicalPlanDigestForTest specDigest bytes = specDigest <> ":" <> sha256HexForTest bytes

sha256HexForTest :: ByteString.ByteString -> Text.Text
sha256HexForTest payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

withPersistedSnapshotPlan ::
    ( forall projectId brokerGeneration specDigest configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withPersistedSnapshotPlan = withPersistedSnapshotPlanAtCounter Nothing

withPersistedSnapshotPlanAtCounter ::
    Maybe Word64 ->
    ( forall projectId brokerGeneration specDigest configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withPersistedSnapshotPlanAtCounter initialCounter use =
    withSystemTempDirectory "hostbootstrap-persisted-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) -> do
            case initialCounter of
                Nothing -> pure ()
                Just counter ->
                    writeRawRecord
                        store
                        (brokerGenerationKey project)
                        (ByteStringChar8.pack (show counter))
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \(canonicalRoot :: CanonicalProjectRoot (Production projectId) rootId) ->
                        withProductionRoot store project ProjectUp $ \productionRoot -> do
                            let unbound = productionRootUnboundLease productionRoot
                            opened <-
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    unbound
                                    ( \profile ->
                                        withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                                            let value =
                                                    Fixture.defaultProjectConfig
                                                        (installedProjectName project)
                                                        (Text.pack (canonicalProjectRootPath canonicalRoot))
                                                        Context.HostOrchestrator
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config ->
                                                    withAdmittedSnapshotPlan
                                                        profile
                                                        canonicalRoot
                                                        config
                                                        ( use
                                                            store
                                                            project
                                                            (productionRootAuthority productionRoot)
                                                            unbound
                                                        )
                                            either fail pure validated
                                    )
                            case opened of
                                Left failure -> pure (Left (ModeAuthorityFailure failure))
                                Right action -> Right <$> action
                    )
            admitted <- either (fail . show) pure rooted
            either (fail . show) pure admitted

withAdmittedSnapshotPlan ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    (forall planId. ProjectPlan scope specDigest planId configId cfg -> IO result) ->
    IO result
withAdmittedSnapshotPlan profile canonicalRoot config use = do
    drafts <-
        either (fail . show) pure
            (planDraftsFromValidatedBuilder canonicalRoot config (\_ _ -> Right snapshotStepPlan))
    action <- either (fail . show) pure (withProjectPlan profile canonicalRoot config drafts use)
    action

snapshotStepPlan :: StepPlan
snapshotStepPlan =
    case
        mkStepPlan
            [ contextInitStep
                "context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            ]
    of
        Left failure -> error (show failure)
        Right plan -> plan

snapshotKey ::
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    RecordKey
snapshotKey project unbound =
    either (error . show) id
        ( mkRecordKey
            ( "snapshot."
                <> installedProjectName project
                <> "."
                <> unboundRunLeaseRunText unbound
            )
        )

leaseKey ::
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    RecordKey
leaseKey project unbound =
    either (error . show) id
        ( mkRecordKey
            ( "lease."
                <> installedProjectName project
                <> "."
                <> unboundRunLeaseRunText unbound
            )
        )

brokerGenerationKey :: InstalledProjectIdentity projectId -> RecordKey
brokerGenerationKey project =
    either (error . show) id
        (mkRecordKey ("broker." <> installedProjectName project <> ".generation"))

recordPath :: ProtectedStore -> RecordKey -> FilePath
recordPath store key =
    protectedStoreRoot store
        </> "records"
        </> Text.unpack (recordKeyText key)
        <.> "rec"

readRecord :: ProtectedStore -> RecordKey -> IO (Maybe ProtectedRecord)
readRecord store key = do
    entered <- withProtectedEntry store (\session -> readProtectedRecord session key)
    either (fail . show) pure entered

requireRecord :: ProtectedStore -> RecordKey -> IO ProtectedRecord
requireRecord store key = do
    observed <- readRecord store key
    maybe (assertFailure ("missing protected record " <> Text.unpack (recordKeyText key))) pure observed

writeRawRecord :: ProtectedStore -> RecordKey -> ByteString.ByteString -> IO ()
writeRawRecord store key bytes = do
    entered <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent bytes
    either (fail . show) (const (pure ())) entered

replaceRawRecord :: ProtectedStore -> RecordKey -> ByteString.ByteString -> IO ()
replaceRawRecord store key bytes = do
    record <- requireRecord store key
    entered <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord
                session
                key
                (ExpectVersion (protectedRecordVersion record))
                bytes
    either (fail . show) (const (pure ())) entered

deleteRecord :: ProtectedStore -> RecordKey -> IO ()
deleteRecord store key = do
    record <- requireRecord store key
    entered <-
        withProtectedEntry store $ \session ->
            compareAndDeleteProtectedRecord
                session
                key
                (ExpectVersion (protectedRecordVersion record))
    either (fail . show) pure entered

advanceRecordVersion :: ProtectedStore -> RecordKey -> IO ()
advanceRecordVersion store key = do
    record <- requireRecord store key
    entered <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord
                session
                key
                (ExpectVersion (protectedRecordVersion record))
                (protectedRecordBytes record)
    either (fail . show) (const (pure ())) entered

assertLeaseVersion ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    Word64 ->
    IO ()
assertLeaseVersion store project unbound expected = do
    record <- requireRecord store (leaseKey project unbound)
    recordVersionWord (protectedRecordVersion record) @?= expected

assertNoPreparedOrEffectRecords :: ProtectedStore -> IO ()
assertNoPreparedOrEffectRecords store = do
    entered <- withProtectedEntry store listProtectedRecords
    keys <- either (fail . show) pure entered
    let forbidden key =
            any
                (`Text.isPrefixOf` recordKeyText key)
                ["session.", "effect.", "operation.", "prepared."]
    assertBool
        "snapshot admission created no session, prepared operation, or effect record"
        (not (any forbidden keys))

writeStableSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    StablePlanSnapshot ->
    IO ()
writeStableSnapshot store project unbound stable =
    writeRawPlanSnapshot
        store
        project
        (unboundRunLeaseRunText unbound)
        (stablePlanSnapshotSpecDigest stable)
        (stablePlanSnapshotDigest stable)
        (stablePlanSnapshotConfigDigest stable)
        (stablePlanSnapshotBytes stable)

writeRawPlanSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString ->
    IO ()
writeRawPlanSnapshot store project runName specDigest planDigest configDigest canonicalBytes =
    writeRawRecord store key payload
  where
    key =
        either (error . show) id
            (mkRecordKey ("snapshot." <> installedProjectName project <> "." <> runName))
    payload =
        LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                    <> Builder.word64BE 1
                    <> Builder.word64BE 1
                    <> encodeSnapshotText specDigest
                    <> encodeSnapshotText planDigest
                    <> Builder.word8 1
                    <> encodeSnapshotText configDigest
                    <> encodeSnapshotBytes canonicalBytes
                )
            )

encodeSnapshotText :: Text.Text -> Builder.Builder
encodeSnapshotText = encodeSnapshotBytes . TextEncoding.encodeUtf8

encodeSnapshotBytes :: ByteString.ByteString -> Builder.Builder
encodeSnapshotBytes bytes =
    Builder.word64BE (fromIntegral (ByteString.length bytes))
        <> Builder.byteString bytes

assertSnapshotMismatch :: Show result => Either SnapshotError result -> IO ()
assertSnapshotMismatch outcome =
    case outcome of
        Left (SnapshotVerificationError (ModeSnapshotMismatch _ _)) -> pure ()
        other -> assertFailure ("expected immutable snapshot mismatch, observed " <> show other)
