{-# LANGUAGE CPP #-}

module LifecycleSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.Cluster.Lifecycle
import HostBootstrap.HostTool (HostTool (..))
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

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
        , testGroup "never-delete-.data" dataInvariantCases
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
    , testCase "test: per-case isolated name and path" $ do
        clusterName test1 @?= "demo-test-case1"
        dataPath test1 @?= rootPath </> ".test_data" </> "case1"
        derivedPaths test1 @?= [rootPath </> ".cluster" </> "demo-test-case1"]
    ]

driverCases :: [TestTree]
driverCases =
    [ testCase "Linux GPU accelerator plan selects nvkind" $ do
        let plan = resolveAcceleratorPlan "demo" rootPath Production (Substrate LinuxGpu Amd64)
        clusterDriver plan @?= NvkindDriver
        clusterCreateTool plan @?= Nvkind
        clusterCreateArgs plan True @?= ["cluster", "create", "--name=demo", "--config-template=kind.yaml"]
    , testCase "Linux CPU accelerator plan keeps kind" $ do
        let plan = resolveAcceleratorPlan "demo" rootPath Production (Substrate LinuxCpu Amd64)
        clusterDriver plan @?= KindDriver
        clusterCreateTool plan @?= Kind
        clusterCreateArgs plan True @?= ["create", "cluster", "--name", "demo", "--config", "kind.yaml"]
    , testCase "test clusters do not publish fixed kind host ports" $
        clusterCreateArgs test1 True @?= ["create", "cluster", "--name", "demo-test-case1"]
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
        acceleratorIngressPlan InClusterDaemon 30081
            @?= AcceleratorIngressPlan
                { ingressServiceType = "ClusterIP"
                , ingressServicePort = 30081
                , ingressNodePort = Nothing
                , ingressKindListenAddress = Nothing
                }
    , testCase "host daemon uses local-only NodePort" $
        acceleratorIngressPlan HostResidentDaemon 30081
            @?= AcceleratorIngressPlan
                { ingressServiceType = "NodePort"
                , ingressServicePort = 30081
                , ingressNodePort = Just 30081
                , ingressKindListenAddress = Just "127.0.0.1"
                }
    ]

nvidiaRuntimeCases :: [TestTree]
nvidiaRuntimeCases =
    [ testCase "NVIDIA runtime probe uses docker --runtime=nvidia" $
        nvidiaRuntimeProbeArgs
            @?= [ "run"
                , "--rm"
                , "--runtime=nvidia"
                , "-e"
                , "NVIDIA_VISIBLE_DEVICES=all"
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
