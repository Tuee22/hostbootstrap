{-# LANGUAGE OverloadedStrings #-}

module CommandsSpec (tests) where

import Control.Exception (SomeException, bracket, try)
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Text as T
import HostBootstrap.Chain (renderChain)
import HostBootstrap.Cluster.Lifecycle (AcceleratorDaemonPlacement (HostResidentDaemon), AcceleratorIngressPlan (ingressKindListenAddress), ClusterDriver (..), ClusterPlan (clusterConfigFile, clusterDriver), acceleratorIngressPlan)
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Lift (ContainerLift (clExtraArgs), localContext)
import HostBootstrap.Service (serviceVariantNames)
import HostBootstrap.Step (Step (..), chainFrames, frameId, postHandoffStepsForFrame, stepKindName)
import HostBootstrap.Substrate (Arch (Amd64, Arm64), Substrate (Substrate), SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu))
import HostBootstrapDemo.Commands (
    absoluteHostAcceleratorDaemonExePath,
    acceleratorDaemonManifest,
    acceleratorHelmValuesForContext,
    containerPlan,
    demoBaseImageFor,
    demoChainFor,
    demoDeployImage,
    demoServices,
    demoTestFrameContext,
    directClusterPresence,
    directClusterTeardownArgs,
    hostAcceleratorDaemonPowerShellScript,
    hostAcceleratorDaemonProcess,
    hostAcceleratorSubstrate,
    hostDaemonIdentityMatches,
    hostDaemonLifecycleStateConsistent,
    readHostAcceleratorDaemonPid,
    renderServiceConfigForContext,
    serviceConfigMapManifest,
    validateAcceleratorReplicaCount,
 )
import HostBootstrapDemo.Config (
    ProjectConfig (..),
    ServiceType (Web),
    WebServiceConfig (WebServiceConfig),
    demoDefaultDeployConfig,
    demoDefaultDockerfile,
    demoDefaultMessage,
    demoDefaultResources,
    projectConfigForRole,
 )
import HostBootstrapDemo.Web.Bridge (writeBridge)
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))
import System.IO (hClose, hPutStr, openTempFile)
import System.Info (os)
import System.Process (CmdSpec (RawCommand), CreateProcess (close_fds, cmdspec, env, std_err, std_in, std_out), StdStream (NoStream))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "CommandsSpec"
        [ testCase "linux-gpu selects the direct host-to-container nvkind chain" $ do
            let steps = demoChainFor (Substrate LinuxGpu Amd64) hostCfg
            map frameId (chainFrames steps) @?= ["host-orchestrator-0", "vm-project-container-1"]
            map (stepKindName . stepKind) steps
                @?= [ "build-image"
                    , "context-init"
                    , "deploy-kind"
                    , "deploy-minio"
                    , "deploy-registry"
                    , "push-image"
                    , "deploy-chart"
                    , "expose-port"
                    , "deploy-accelerator-daemon"
                    ]
            assertBool "direct chain names nvkind" ("nvkind" `isInfixOf` renderChain steps)
        , testCase "validated direct context keeps nvkind even if the inner host detects CPU" $ do
            let directCtx = Context.deriveLinuxGpuContainerContext (context hostCfg) "/workspace/demo"
                vmCtx = Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo"
                ordinaryCtx = Context.deriveContainerContext vmCtx "/workspace/demo"
            clusterDriver (containerPlan directCtx) @?= NvkindDriver
            clusterConfigFile (containerPlan directCtx) @?= Just "nvkind-in-cluster.yaml"
            clusterDriver (containerPlan ordinaryCtx) @?= KindDriver
            clusterConfigFile (containerPlan ordinaryCtx) @?= Just "kind-in-cluster.yaml"
        , testCase "accelerator Helm values follow validated daemon placement" $ do
            let directCtx = Context.deriveLinuxGpuContainerContext (context hostCfg) "/workspace/demo"
                incusCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                wslCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.Wsl2VMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                clusterIpValues =
                    [ ("service.port", "8080")
                    , ("service.accelerator.type", "ClusterIP")
                    , ("service.accelerator.port", "8081")
                    , ("service.accelerator.targetPort", "8081")
                    ]
            acceleratorHelmValuesForContext hostCfg directCtx @?= Right clusterIpValues
            acceleratorHelmValuesForContext hostCfg incusCtx @?= Right clusterIpValues
            acceleratorHelmValuesForContext hostCfg wslCtx
                @?= Right
                    [ ("service.port", "8080")
                    , ("service.accelerator.type", "NodePort")
                    , ("service.accelerator.port", "8081")
                    , ("service.accelerator.targetPort", "8081")
                    , ("service.accelerator.nodePort", "30081")
                    ]
            let customPorts = hostCfg{service = Just (Web (WebServiceConfig 9090 9091))}
            acceleratorHelmValuesForContext customPorts directCtx
                @?= Right
                    [ ("service.port", "9090")
                    , ("service.accelerator.type", "ClusterIP")
                    , ("service.accelerator.port", "9091")
                    , ("service.accelerator.targetPort", "9091")
                    ]
            let invalidPorts = hostCfg{service = Just (Web (WebServiceConfig 0 9091))}
            assertBool "invalid configured ports fail before Helm" $
                case acceleratorHelmValuesForContext invalidPorts directCtx of
                    Left err -> "publicPort" `isInfixOf` err
                    Right _ -> False
        , testCase "service ConfigMaps derive the actual parent topology and frame" $ do
            let directCtx = Context.deriveLinuxGpuContainerContext (context hostCfg) "/workspace/demo"
                incusCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.IncusVMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                wslCtx = Context.deriveContainerContext (Context.deriveVMContextWithProvider Context.Wsl2VMProvider (context hostCfg) "/vm/demo") "/workspace/demo"
                (directConfig, directFrame) = renderServiceConfigForContext hostCfg directCtx
                (incusConfig, incusFrame) = renderServiceConfigForContext hostCfg incusCtx
                (wslConfig, wslFrame) = renderServiceConfigForContext hostCfg wslCtx
                manifest = serviceConfigMapManifest directConfig
            directFrame @?= "cluster-service-2"
            incusFrame @?= "cluster-service-3"
            wslFrame @?= "cluster-service-3"
            assertBool "direct service has no invented VM frame" (not ("topologyFrameId = \"vm-orchestrator-1\"" `T.isInfixOf` directConfig))
            assertBool "Incus provider survives into the service projection" ("IncusVMProvider" `T.isInfixOf` incusConfig)
            assertBool "WSL2 provider survives into the service projection" ("Wsl2VMProvider" `T.isInfixOf` wslConfig)
            assertBool "manifest carries every derived config line" $
                all (\line -> ("    " ++ line) `isInfixOf` manifest) (filter (not . null) (lines (T.unpack directConfig)))
        , testCase "chart and kind configs consume the placement-specific exposure" $ do
            serviceTemplate <- readFile ("chart" ++ "/templates/service.yaml")
            deploymentTemplate <- readFile ("chart" ++ "/templates/deployment.yaml")
            staticConfigMap <- doesFileExist ("chart" ++ "/templates/configmap.yaml")
            playwrightConfig <- readFile ("playwright" ++ "/playwright.config.ts")
            inClusterKind <- readFile "kind-in-cluster.yaml"
            nvkindTemplate <- readFile "nvkind-in-cluster.yaml"
            hostKind <- readFile "kind.yaml"
            let hostListenAddress = ingressKindListenAddress (acceleratorIngressPlan HostResidentDaemon 8081 30081)
            assertBool "chart renders the configured accelerator Service type" (".Values.service.accelerator.type" `isInfixOf` serviceTemplate)
            assertBool "accelerator Service targets its isolated listener" (".Values.service.accelerator.targetPort" `isInfixOf` serviceTemplate)
            assertBool "chart omits nodePort unless the plan selects NodePort" ("if eq .Values.service.accelerator.type \"NodePort\"" `isInfixOf` serviceTemplate)
            assertBool "chart consumes the derived service frame" (".Values.service.currentFrame" `isInfixOf` deploymentTemplate)
            assertBool "chart rolls when the applied service config changes" (".Values.service.configHash" `isInfixOf` deploymentTemplate)
            assertBool "single-peer web rollout cannot overlap replicas" ("type: Recreate" `isInfixOf` deploymentTemplate)
            assertBool "there is no hand-written topology ConfigMap" (not staticConfigMap)
            assertBool "browser engines serialize against the single accelerator session" ("workers: 1" `isInfixOf` playwrightConfig)
            assertBool "in-cluster config has no accelerator host mapping" (not ("hostPort: 30081" `isInfixOf` inClusterKind))
            assertBool "nvkind template injects all GPUs into its worker" ("/var/run/nvidia-container-devices/all" `isInfixOf` nvkindTemplate)
            assertBool "nvkind GPU worker is selected by the device-plugin chart" ("nvidia.com/gpu.present: \"true\"" `isInfixOf` nvkindTemplate)
            assertBool "nvkind accelerator remains ClusterIP-only" (not ("hostPort: 30081" `isInfixOf` nvkindTemplate))
            assertBool "host-daemon config consumes the planned local-only address" $
                case hostListenAddress of
                    Just address -> ("listenAddress: \"" ++ address ++ "\"") `isInfixOf` hostKind
                    Nothing -> False
        , testCase "base image flavor follows the metal lane" $ do
            demoBaseImageFor (Substrate LinuxGpu Amd64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64"
            demoBaseImageFor (Substrate LinuxCpu Amd64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64"
            demoBaseImageFor (Substrate AppleSilicon Arm64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
            demoBaseImageFor (Substrate WindowsGpu Amd64)
                @?= "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64"
        , testCase "direct project-container handoff passes the GPU and normal handoff does not" $ do
            let directArgs = clExtraArgs (demoDeployImage "vm-project-container-1" True "cfg")
                ordinaryArgs = clExtraArgs (demoDeployImage "vm-project-container-2" False "cfg")
            assertBool "direct handoff has --gpus=all" ("--gpus=all" `elem` directArgs)
            assertBool "ordinary handoff has no GPU flag" ("--gpus=all" `notElem` ordinaryArgs)
        , testCase "Linux GPU assertions stay local instead of entering Incus" $
            demoTestFrameContext (Substrate LinuxGpu Amd64) @?= localContext
        , testCase "direct-cluster safety checks every planned node and fails closed" $ do
            let nodes = ["demo-control-plane", "demo-worker"]
            directClusterPresence nodes (Right (ExitSuccess, "demo-worker\n", "")) @?= Right True
            directClusterPresence nodes (Right (ExitSuccess, "unrelated\n", "")) @?= Right False
            assertBool "Docker probe errors must refuse the run" $
                case directClusterPresence nodes (Right (ExitFailure 1, "", "daemon unavailable")) of
                    Left _ -> True
                    Right _ -> False
        , testCase "direct teardown uses the project image's pinned kind against the host socket" $ do
            assertBool "teardown mounts the Docker socket" ("/var/run/docker.sock:/var/run/docker.sock" `elem` directClusterTeardownArgs)
            assertBool "teardown bypasses the demo entrypoint" ("/usr/local/bin/kind" `elem` directClusterTeardownArgs)
            assertBool "teardown deletes the managed name" $
                ["delete", "cluster", "--name", "hostbootstrap-demo"] `isSuffixOf` directClusterTeardownArgs
        , testCase "accelerator daemon manifest requests a GPU only in the CUDA lane" $ do
            let cpuManifest = acceleratorDaemonManifest False "daemon-3" "config" 8081
                gpuManifest = acceleratorDaemonManifest True "daemon-3" "config" 8081
                customPortManifest = acceleratorDaemonManifest False "daemon-3" "config" 9091
            assertBool "CPU pod has no GPU request" (not ("nvidia.com/gpu" `isInfixOf` cpuManifest))
            assertBool "GPU pod requests one GPU" ("nvidia.com/gpu: 1" `isInfixOf` gpuManifest)
            assertBool "daemon dials the dedicated ClusterIP service" ("hostbootstrap-demo-accelerator:8081" `isInfixOf` gpuManifest)
            assertBool "daemon dials a configured accelerator port" ("hostbootstrap-demo-accelerator:9091" `isInfixOf` customPortManifest)
            assertBool "daemon config changes roll its subPath-mounted pod" ("hostbootstrap.io/config-hash" `isInfixOf` gpuManifest)
            assertBool "daemon rollout cannot overlap reconnecting peers" ("type: Recreate" `isInfixOf` gpuManifest)
            assertBool "daemon rollout waits for its connection readiness marker" ("HOSTBOOTSTRAP_ACCELERATOR_READY_FILE" `isInfixOf` gpuManifest && "readinessProbe:" `isInfixOf` gpuManifest)
        , testCase "accelerator topology rejects process-local HA routing" $ do
            validateAcceleratorReplicaCount 1 @?= Right ()
            assertBool "more than one web pod is unsupported" $
                case validateAcceleratorReplicaCount 2 of
                    Left _ -> True
                    Right _ -> False
        , testCase "linux-cpu runs the accelerator daemon as an in-cluster pod (no host hook)" $ do
            let steps = demoChainFor (Substrate LinuxCpu Amd64) hostCfg
            map frameId (chainFrames steps) @?= ["host-orchestrator-0", "vm-orchestrator-1", "vm-project-container-2"]
            -- Incus does not forward the guest NodePort to the host, so the Linux CPU
            -- accelerator daemon is an in-cluster pod (dialing the web ClusterIP), NOT a
            -- host-resident post-handoff process as on Apple/Windows.
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" steps) @?= []
            stepKindName (stepKind (last steps)) @?= "deploy-accelerator-daemon"
        , testCase "apple/windows keep the host-resident accelerator daemon post-handoff hook" $ do
            let steps = demoChainFor (Substrate AppleSilicon Arm64) hostCfg
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" steps)
                @?= ["start the host-resident accelerator daemon after ingress is reachable"]
            hostAcceleratorSubstrate (Substrate AppleSilicon Arm64) @?= True
            hostAcceleratorSubstrate (Substrate WindowsGpu Amd64) @?= True
        , testCase "windows-cpu has no accelerator worker or host-daemon hook" $ do
            let steps = demoChainFor (Substrate WindowsCpu Amd64) hostCfg
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" steps) @?= []
            hostAcceleratorSubstrate (Substrate WindowsCpu Amd64) @?= False
        , testCase "host accelerator daemon cannot inherit the project-up capture pipe" $ do
            let daemonEnv = [("HOSTBOOTSTRAP_ACCELERATOR_WS_URL", "ws://127.0.0.1:30081")]
                process = hostAcceleratorDaemonProcess "hostbootstrap-demo" daemonEnv
                windowsScript =
                    hostAcceleratorDaemonPowerShellScript
                        "C:\\demo's\\hostbootstrap-demo"
                        "C:\\demo's\\hostbootstrap-demo.accelerator.pid"
                        daemonEnv
            cmdspec process @?= RawCommand "hostbootstrap-demo" ["service", "run"]
            env process @?= Just daemonEnv
            std_in process @?= NoStream
            std_out process @?= NoStream
            std_err process @?= NoStream
            close_fds process @?= True
            assertBool "Windows launches into an independent hidden process" ("Start-Process" `isInfixOf` windowsScript && "-WindowStyle Hidden" `isInfixOf` windowsScript)
            assertBool "Windows persists the PID before reporting launch success" ("WriteAllText" `isInfixOf` windowsScript && "[Console]::WriteLine($p.Id)" `isInfixOf` windowsScript)
            assertBool "Windows launch failure force-stops an otherwise untracked child" ("Stop-Process -Id $p.Id -Force" `isInfixOf` windowsScript)
            assertBool "PowerShell literals escape apostrophes" ("'C:\\demo''s\\hostbootstrap-demo'" `isInfixOf` windowsScript)
        , testCase "host accelerator identity resolves relative source roots absolutely" $ do
            let relativeCfg =
                    projectConfigForRole
                        "hostbootstrap-demo"
                        "hostbootstrap-demo"
                        "."
                        demoDefaultDockerfile
                        demoDefaultResources
                        demoDefaultDeployConfig
                        demoDefaultMessage
                        HostOrchestrator
            daemonExe <- absoluteHostAcceleratorDaemonExePath (context relativeCfg)
            assertBool "daemon identity path is absolute" (isAbsolute daemonExe)
            assertBool "Windows copied daemons retain the executable extension" (os /= "mingw32" || ".exe" `isSuffixOf` daemonExe)
        , testCase "host accelerator lifecycle requires matching pid and owner witnesses" $ do
            hostDaemonLifecycleStateConsistent False False @?= True
            hostDaemonLifecycleStateConsistent True True @?= True
            hostDaemonLifecycleStateConsistent True False @?= False
            hostDaemonLifecycleStateConsistent False True @?= False
        , testCase "host accelerator pid read releases the file before teardown removal" $ do
            tmp <- getTemporaryDirectory
            (pidPath, handle) <- openTempFile tmp "hostbootstrap-accelerator.pid"
            hPutStr handle "1234\n"
            hClose handle
            readHostAcceleratorDaemonPid pidPath >>= (@?= "1234")
            removeFile pidPath
            doesFileExist pidPath >>= (@?= False)
        , testCase "host accelerator pid parser rejects numeric prefixes" $ do
            tmp <- getTemporaryDirectory
            (pidPath, handle) <- openTempFile tmp "hostbootstrap-accelerator-invalid.pid"
            hPutStr handle "1234junk\n"
            hClose handle
            parsed <- try (readHostAcceleratorDaemonPid pidPath) :: IO (Either SomeException String)
            assertBool "an invalid pid must not be truncated into another process id" (either (const True) (const False) parsed)
            removeFile pidPath
        , testCase "host daemon teardown requires executable identity before a forced stop" $ do
            let exe = "C:\\repo\\.build\\accelerator-daemon\\hostbootstrap-demo"
                validWindows = map toUpperAscii exe ++ "\r\n\"" ++ map toUpperAscii exe ++ "\" service run\r\n"
                validCimWindows = exe ++ "\r\n\"" ++ exe ++ "\" \"service\" \"run\"\r\n"
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, validWindows, "")) @?= True
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, validCimWindows, "")) @?= True
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, exe ++ "\r\n\"" ++ exe ++ "\" project up\r\n", "")) @?= False
            hostDaemonIdentityMatches True exe (Right (ExitSuccess, "C:\\Windows\\System32\\notepad.exe\r\nnotepad.exe\r\n", "")) @?= False
            hostDaemonIdentityMatches False "/repo/daemon" (Right (ExitSuccess, "/repo/daemon service run\n", "")) @?= True
            hostDaemonIdentityMatches False "/repo/daemon" (Right (ExitSuccess, "/repo/daemon project up\n", "")) @?= False
            hostDaemonIdentityMatches False "/repo/daemon" (Right (ExitSuccess, "/repo/daemon-old service run\n", "")) @?= False
        , testCase "web bridge maps Haskell Float into the PureScript numeric primitive" $
            withBridgeTempDirectory $ \dir -> do
                writeBridge dir
                generated <- readFile (dir </> "HostBootstrapDemo" </> "Web" </> "Api.purs")
                assertBool "Float fields use PureScript Number" ("result :: Number" `isInfixOf` generated)
                assertBool "the generated module has no Haskell-only GHC.Types import" (not ("GHC.Types" `isInfixOf` generated))
        , testCase "demo registers web and accelerator service variants" $
            serviceVariantNames demoServices @?= ["web", "accelerator"]
        ]

withBridgeTempDirectory :: (FilePath -> IO a) -> IO a
withBridgeTempDirectory = bracket create removePathForcibly
  where
    create = do
        tmp <- getTemporaryDirectory
        (path, handle) <- openTempFile tmp "hostbootstrap-purescript-bridge"
        hClose handle
        removeFile path
        createDirectory path
        pure path

toUpperAscii :: Char -> Char
toUpperAscii c
    | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
    | otherwise = c

hostCfg :: ProjectConfig
hostCfg =
    projectConfigForRole
        "hostbootstrap-demo"
        "hostbootstrap-demo"
        "/workspace/demo"
        demoDefaultDockerfile
        demoDefaultResources
        demoDefaultDeployConfig
        demoDefaultMessage
        HostOrchestrator
