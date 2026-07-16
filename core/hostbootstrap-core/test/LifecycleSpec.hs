{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleSpec (tests) where

import Control.Exception (SomeException, displayException, try)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Cluster.Lifecycle
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (..), mkAbsExe)
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
    [ testCase "down removes nothing on disk and preserves .data" $ do
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
    [ testCase "running cluster reports (running) and preserves .data" $ do
        let report = statusReport prod True
        assertBool "names the cluster" ("demo" `isInfixOf` report)
        assertBool "marks it running" ("(running)" `isInfixOf` report)
        assertBool "shows preserved .data" (((rootPath </> ".data") ++ " (preserved)") `isInfixOf` report)
    , testCase "absent cluster reports (absent), still preserving .data" $ do
        let report = statusReport prod False
        assertBool "marks it absent" ("(absent)" `isInfixOf` report)
        assertBool "still preserves .data" ("(preserved)" `isInfixOf` report)
    ]
