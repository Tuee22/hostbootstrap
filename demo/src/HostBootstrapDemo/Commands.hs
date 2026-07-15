{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | The hostbootstrap-demo project extension streams.

The command surface is **fixed** (development_plan_standards § P): the demo adds
**no** verbs. @hostbootstrap-core@ is a library of composable tools, so the demo
extends the core only through the parallel extension streams threaded into its
@ProjectSpec@ (@app/Main.hs@):

  * the **lift chain** — 'demoChain' (@ProjectConfig -> [Step]@) the core
    @project up@ interprets recursively (§ Y), with 'demoFrameContext' /
    'demoTeardown' for per-frame descent and stop\/delete;
  * the **schema-gen registry** — @context render@ / @context schema@ receive
    'demoArtifacts' (registry concatenation, § T);
  * the **test suite** — 'demoTestSuite' drives the real @project up@ under a
    test config and asserts against the live stack, then @project destroy@
    (the harness owns no second bring-up path, § W);
  * the **service-handler registry** — 'demoServices' registers the long-running
    @web@ and @accelerator@ handler keys selected from the config's @ServiceType@
    when @service run@ executes (§ AA).

The former @incus@ / @vm@ provider verbs are dissolved: their IO is retained as
the chain-step library functions 'runVmEnsure' / 'runVmUp' / 'runVmBootstrap'
('ensureIncusProvider') the metal chain interprets. The former @web@ verb is
dissolved too: @web serve@ → the @web@ 'ServiceHandler', @web bridge@ → the
build-image step ('runVmBootstrap' generates the PureScript bridge before the
image build). On Apple Silicon the demo VM is a Lima VM; on Linux it is native
Incus.
-}
module HostBootstrapDemo.Commands (
    demoChain,
    demoChainFor,
    containerPlan,
    demoFrameContext,
    demoTestFrameContext,
    demoTeardown,
    demoArtifacts,
    demoCheckCode,
    demoCases,
    absoluteHostAcceleratorDaemonExePath,
    hostAcceleratorDaemonProcess,
    hostAcceleratorDaemonPowerShellScript,
    hostAcceleratorSubstrate,
    hostDaemonLifecycleStateConsistent,
    hostDaemonIdentityMatches,
    readHostAcceleratorDaemonPid,
    acceleratorDaemonManifest,
    acceleratorHelmValuesForContext,
    renderServiceConfigForContext,
    serviceConfigMapManifest,
    validateAcceleratorReplicaCount,
    demoBaseImageFor,
    demoDeployImage,
    directClusterPresence,
    directClusterTeardownArgs,
    demoServices,
    demoTestSuite,
    demoVM,
    demoLimaVM,
    demoManagedVMName,
    demoGuardPrefix,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, finally, mask, onException, throwIO, try)
import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace, toLower)
import Data.List (intercalate, isInfixOf)
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Cluster.Cordon (
    ResourceBudget (..),
    budgetFromResources,
    gibibytes,
    preflightHostBudget,
    resolveHostCapacity,
 )
import HostBootstrap.Cluster.Lifecycle (
    AcceleratorDaemonPlacement (..),
    AcceleratorIngressPlan (..),
    ClusterDriver (NvkindDriver),
    ClusterPlan (..),
    ClusterProfile (Production),
    acceleratorIngressPlan,
    clusterCreate,
    clusterNodeNames,
    deployChart,
    resolvePlan,
    resolvePlanWithDriver,
 )
import HostBootstrap.Config.Schema (projectConfigSnapshotHash, projectConfigSnapshotHashBytes, renderProjectConfigSnapshotLog, siblingProjectConfigPath, withSiblingProjectConfigContext, writeProjectConfigFile)
import HostBootstrap.Config.Vocab (Mount (..), PodResources (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf)
import HostBootstrap.Ensure (runEnsure, runTool, runToolWithStdin, toolPresent)
import qualified HostBootstrap.Ensure.Cuda as EnsureCuda
import qualified HostBootstrap.Ensure.Docker as EnsureDocker
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as EnsureLima
import qualified HostBootstrap.Ensure.Wsl2 as EnsureWsl2
import HostBootstrap.Harness (Case (..), CaseResult (..), SafetyRefusal (..), TestSuite (..), safetyRefusalMarker, testSafetyPreconditions)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Kill, Kind, Kubectl, Mc, PowerShell, Ps, Sudo), toolCommandName)
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift (ConfigDelivery (..), ContainerLift (..), LiftContext (..), LiftLeaf (..), inContainer, liftLeaf, localContext, reachLeaf)
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Readiness (
    PollPolicy,
    Probe,
    ProbeResult (..),
    Ready,
    awaitReady,
    awaitReadyWith,
    dockerPoll,
    networkPoll,
    pollUntilReady,
    pollUntilReadyWith,
    pushPoll,
    reachPoll,
    renderPollError,
    rolloutPoll,
    vmBootPoll,
    withAttempts,
 )
import HostBootstrap.Registry (RegistryAuth, discoverHostRegistryAuth, dockerAuthStdinWrapper, registryAuthEnvVar, registryConfigPayload)
import HostBootstrap.Service (ServiceHandler (..), ServiceRegistry)
import HostBootstrap.Step (
    Step,
    StepFrame (..),
    buildImageStep,
    buildPbStep,
    contextInitStep,
    deployChartStep,
    deployKindStep,
    deployVMStep,
    exposePortStep,
    postHandoffStep,
    projectStep,
 )
import HostBootstrap.Substrate (Substrate, SubstrateName (LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu), detect, isAppleSilicon, isLinux, isWindows, renderArch, substrateArch, substrateName)
import HostBootstrap.Substrate.Provider (
    ExistsProbe (..),
    HostEffect (..),
    StagedFile (..),
    SubstrateProvider (..),
    VMHandles (..),
    WaitProbe (..),
    membersOf,
    selectSubstrateProvider,
    stageFileEffects,
    vmShellArgs,
 )
import HostBootstrap.Wsl2 (Wsl2VM (..), mergeWslConfig)
import HostBootstrapDemo.Accelerator (backendName)
import HostBootstrapDemo.Accelerator.Daemon (acceleratorBackendForSubstrate, serveAcceleratorDaemon)
import HostBootstrapDemo.Config (
    DeployConfig (..),
    ProjectConfig (..),
    Resources (..),
    ServiceType (Web),
    WebServiceConfig (WebServiceConfig),
    configuredServiceVariant,
    demoCaseIds,
    demoDefaultResources,
    envelopeOfResources,
    projectConfigFromContext,
    renderProjectConfig,
 )
import HostBootstrapDemo.Container (dockerBuildArgs)
import HostBootstrapDemo.Web.Api (demoWebPod)
import HostBootstrapDemo.Web.Bridge (writeBridge)
import HostBootstrapDemo.Web.Server (serveWeb)
import Numeric.Natural (Natural)
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, getHomeDirectory, getPermissions, makeAbsolute, removeDirectory, removeFile, setPermissions, withCurrentDirectory)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..), die)
import System.FilePath (normalise, takeDirectory, (</>))
import System.IO (hFlush, hPutStr, stderr, stdout)
import System.IO.Error (tryIOError)
import System.Info (os)
import System.Process (CreateProcess (close_fds, env, std_err, std_in, std_out), StdStream (NoStream), createProcess, getPid, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

{- | One SPA tab as typed data: its label and the API endpoint it reads (empty
for a static tab).
-}
data WebTab = WebTab
    { tabLabel :: T.Text
    , tabEndpoint :: T.Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

{- | The demo SPA described as **typed Dhall data** (the minimal instance of the
"UI generated from typed Dhall" pattern, see
@documents/engineering/composition_patterns.md@): the app title and its tabs.
Contributed through the schema-gen registry stream as the @demoWebApp@ artifact,
so the SPA's shape is reflectable/renderable Dhall rather than only hand-written
Halogen. Mirrors the three tabs the Halogen app renders (@web/src/Main.purs@) and
the @/api/budget@ binding the @Budget@ tab reads.
-}
data WebAppSpec = WebAppSpec
    { appTitle :: T.Text
    , appTabs :: [WebTab]
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The demo SPA as typed data (the @demoWebApp@ schema-gen artifact).
demoWebApp :: WebAppSpec
demoWebApp =
    WebAppSpec
        { appTitle = "hostbootstrap-demo"
        , appTabs =
            [ WebTab "Overview" ""
            , WebTab "Budget" "/api/budget"
            , WebTab "Status" ""
            ]
        }

{- | The demo's schema-gen artifacts, appended to @coreArtifacts@ (the registry
concatenation stream): a demo web-pod footprint reflected from the vocabulary,
and the SPA described as typed Dhall data ('demoWebApp').
-}
demoArtifacts :: [ConfigArtifact]
demoArtifacts =
    [ artifactOf @PodResources "demoWeb" demoWebPod
    , artifactOf @WebAppSpec "demoWebApp" demoWebApp
    ]

{- | The demo's canonical build-time quality gate. It runs inside the project
container after the binary and its container-local context are installed, using
the formatter/linter/toolchain pinned in the base image.
-}
demoCheckCode :: IO ()
demoCheckCode = do
    runCheck "fourmolu" fourmoluPath ["--mode", "check", "app", "src"]
    runCheck "hlint" hlintPath ["app", "src"]
    runCheck "cabal -Werror" cabalPath ["build", "--enable-tests", "--enable-benchmarks", "all", "--ghc-options=-Werror"]
  where
    fourmoluPath = "/opt/hostbootstrap/haskell-style/bin/fourmolu"
    hlintPath = "/opt/hostbootstrap/haskell-style/bin/hlint"
    cabalPath = "/root/.ghcup/bin/cabal"

runCheck :: String -> FilePath -> [String] -> IO ()
runCheck label exe args = do
    putStrLn ("check-code: " ++ label)
    (code, out, err) <- readProcessWithExitCode exe args ""
    unless (null out) (putStr out)
    unless (null err) (hPutStr stderr err)
    case code of
        ExitSuccess -> pure ()
        ExitFailure n -> die (label ++ " failed (exit " ++ show n ++ "): " ++ exe ++ " " ++ unwords args)

{- | The demo's harness case matrix (the app supplies only this; the L0 engine
drives it). The headline @pristine-bootstrap@ case plus the web/e2e cases.
-}
demoCases :: [Case]
demoCases =
    [Case (T.unpack i) 1 False | i <- demoCaseIds]

-- | The demo project name (used to resolve per-case cluster plans).
demoProject :: String
demoProject = "hostbootstrap-demo"

{- | The VM-backed persistent stack shared by the Apple/Windows host-daemon chain
('demoChain') and the Linux CPU in-cluster-daemon chain ('demoLinuxCpuChain') — a
contributed @chain :: ProjectConfig -> [Step]@ value the core @project up@ interprets
recursively (§ Y; @project up --dry-run@ renders it). It descends three frames (the
full fractal): the metal host-orchestrator provisions the VM and builds the pb (#2) +
the project image (#3); the in-VM @vm-orchestrator-1@ mints the project-container child
config and hands off; the in-container @vm-project-container-2@ stands up the persistent
stack (@deploy-kind@ → @deploy-minio@ → @deploy-registry@ → @push-image@ →
@deploy-chart@ → @expose-port@), ending at a live webservice on the NodePort. The two
chains differ ONLY in how the accelerator daemon is placed (host-resident vs.
in-cluster), appended after this stack.
-}
demoVmBackedStack :: [Step]
demoVmBackedStack =
    -- host-orchestrator-0 (metal): provision the VM, build the pb (#2) + image (#3) in it.
    [ deployVMStep "ensure the VM provider (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows)" demoMetalFrame (const runVmEnsure)
    , deployVMStep "launch the budget-sized VM (cordon #1: the VM is the wall)" demoMetalFrame (const runVmUp)
    , buildPbStep "pristine-bootstrap: build the binary host-native, then the project image, in the VM" demoMetalFrame (const runVmBootstrap)
    , -- vm-orchestrator-1 (the in-VM pb): mint the project-container child config, then hand off.
      contextInitStep "prepare the project-container child config for in-place delivery" demoVMFrame contextInitAnnounce
    , -- vm-project-container-2 (the in-container pb): stand up the persistent stack.
      deployKindStep "deploy the persistent kind cluster (cordon #2, Production profile)" demoContainerFrame deployKindAction
    , projectStep "deploy-minio" "install the in-cluster MinIO (S3) backing store + create the registry bucket" demoContainerFrame deployMinioAction
    , projectStep "deploy-registry" "install the in-cluster registry (registry:2, NodePort 30500), S3-backed by MinIO" demoContainerFrame deployRegistryAction
    , projectStep "push-image" "load the project image into kind + push it to the in-cluster registry" demoContainerFrame pushImageAction
    , deployChartStep "deploy the web service chart pod (NodePort 30080)" demoContainerFrame deployChartAction
    , exposePortStep "verify the web NodePort (30080) is reachable" demoContainerFrame exposeAction
    ]

{- | The Apple Silicon / Windows GPU chain: the VM-backed stack plus a HOST-resident
accelerator daemon started after the web ingress is exposed. The host daemon reaches
the in-VM cluster's local-only accelerator ingress because Lima and WSL2 forward the
guest NodePort to the host loopback (Incus does not — hence Linux CPU uses an
in-cluster pod, 'demoLinuxCpuChain'; accelerator_daemon.md § Cluster Exposure).
-}
demoChain :: ProjectConfig -> [Step]
demoChain _ =
    demoVmBackedStack
        ++ [postHandoffStep "accelerator-daemon" "start the host-resident accelerator daemon after ingress is reachable" demoMetalFrame startHostAcceleratorDaemonAction]

{- | The Linux CPU chain: the same VM-backed stack, but the accelerator daemon runs
as an IN-CLUSTER pod that dials the web service over ClusterIP — because Incus does
not forward the guest NodePort to the host, a host-resident daemon could not reach
the in-VM cluster. The pod is the CPU-base project image, whose @clang++@ builds the
C++ worker (accelerator_daemon.md § Substrate Matrix).
-}
demoLinuxCpuChain :: ProjectConfig -> [Step]
demoLinuxCpuChain _ =
    demoVmBackedStack
        ++ [projectStep "deploy-accelerator-daemon" "deploy the in-cluster accelerator daemon pod (Linux CPU: clang++ C++ worker, dials the web ClusterIP)" demoContainerFrame deployAcceleratorDaemonAction]

{- | Select the demo's chain. The chain shape must be a pure function of the ROOT
parameters (§ Y): a WSL2 VM on a Windows GPU host detects @linux-gpu@ through GPU
passthrough, and an Incus/Lima VM detects @linux-cpu@/@apple@ — so a nested frame's
pb that re-derived the chain from its OWN locally detected substrate would build a
frame-incompatible chain (e.g. the VM-less direct @linux-gpu@ chain, whose frames
lack @vm-orchestrator-1@, under a metal handoff that targets @vm-orchestrator-1@),
failing the recursive interpreter's frame check with no output. So only the ROOT
(metal, empty @parentChain@) frame chooses the chain from the locally detected
substrate; a nested frame recovers the shape the root chose from the topology
providers forwarded in its config — the VM-orchestrator frame's provider
(Wsl2/Lima ⇒ the host-daemon VM-backed chain, Incus ⇒ the in-cluster Linux CPU
chain) or, with no VM-orchestrator frame, the direct Linux GPU chain.
-}
demoChainFor :: Substrate -> ProjectConfig -> [Step]
demoChainFor sub cfg
    | not (null (Context.parentChain ctx)) = nestedChain cfg
    | substrateName sub == LinuxGpu = demoLinuxGpuChain cfg
    | substrateName sub == LinuxCpu = demoLinuxCpuChain cfg
    | substrateName sub == WindowsCpu = demoVmBackedStack
    | otherwise = demoChain cfg
  where
    ctx = context cfg
    providers = map Context.topologyProvider (Context.topologyFrames ctx)
    nestedChain
        | Context.IncusVMProvider `elem` providers = demoLinuxCpuChain
        | Context.Wsl2VMProvider `elem` providers || Context.LimaVMProvider `elem` providers = demoChain
        | otherwise = demoLinuxGpuChain

demoLinuxGpuChain :: ProjectConfig -> [Step]
demoLinuxGpuChain _ =
    [ buildImageStep "build the project image on the Linux GPU host for the direct container handoff" demoMetalFrame (const runDirectHostBootstrap)
    , contextInitStep "prepare the Linux GPU direct project-container config for in-place delivery" demoMetalFrame contextInitDirectAnnounce
    , deployKindStep "deploy the persistent nvkind cluster (Production profile)" demoDirectContainerFrame deployKindAction
    , projectStep "deploy-minio" "install the in-cluster MinIO (S3) backing store + create the registry bucket" demoDirectContainerFrame deployMinioAction
    , projectStep "deploy-registry" "install the in-cluster registry (registry:2, NodePort 30500), S3-backed by MinIO" demoDirectContainerFrame deployRegistryAction
    , projectStep "push-image" "load the project image into nvkind + push it to the in-cluster registry" demoDirectContainerFrame pushImageAction
    , deployChartStep "deploy the web service chart pod (NodePort 30080)" demoDirectContainerFrame deployChartAction
    , exposePortStep "verify the web NodePort (30080) is reachable" demoDirectContainerFrame exposeAction
    , projectStep "deploy-accelerator-daemon" "deploy the CUDA accelerator daemon pod with one NVIDIA GPU (dials the web ClusterIP)" demoDirectContainerFrame deployAcceleratorDaemonAction
    ]

demoMetalFrame :: StepFrame
demoMetalFrame = StepFrame "host-orchestrator-0" "metal"

demoVMFrame :: StepFrame
demoVMFrame = StepFrame "vm-orchestrator-1" "vm-orchestrator"

demoContainerFrame :: StepFrame
demoContainerFrame = StepFrame containerRuntimeFrameId "project-container"

demoDirectContainerFrame :: StepFrame
demoDirectContainerFrame = StepFrame directContainerRuntimeFrameId "linux-gpu-project-container"

{- | The per-frame lift-context resolver (§ U) attached via 'withFrameContext':
how the binary in the CURRENT frame descends ONE level into @next@. The metal
binary's handoff into @vm-orchestrator-1@ folds to the substrate's VM shell —
@incus exec \<vm\> -- \<pb\> project up@ on Linux, @limactl shell \<vm\> -- \<pb\>
project up@ on Apple Silicon — selected by the detected 'Substrate' the demo
threads in from @main@ (the same selection 'demoProvider' makes). The in-VM
binary's handoff into @vm-project-container-2@ folds to a local @docker run --rm
\<image\> project up@ (local because that binary already runs inside the VM, so it
needs no provider). Each binary only ever hands off to its immediate next frame,
so a single one-level lift per transition is correct.
-}
demoFrameContext :: Substrate -> ProjectConfig -> StepFrame -> LiftContext
demoFrameContext sub cfg next
    | frameId next == frameId demoVMFrame = demoVMFrameContext sub
    | frameId next == frameId demoContainerFrame =
        inContainer (demoDeployImage containerRuntimeFrameId False (containerConfigPayload cfg)) localContext
    | frameId next == frameId demoDirectContainerFrame =
        inContainer (demoDeployImage directContainerRuntimeFrameId True (directContainerConfigPayload cfg)) localContext
    | otherwise = localContext

{- | The narrowed project-container projection rendered to Dhall text (pure): the
child config the VM→container handoff streams in-place on its @stdin@ (§ X). It
reproduces exactly what the former @context-init@ write minted, but the result is
carried on the handoff @stdin@ and written by the container entrypoint to its own
sibling @<project>.dhall@ before dispatch — no host-side file, no config bind-mount.
Only this narrowed projection crosses the boundary; the parent's full config never
does.
-}
containerConfigPayload :: ProjectConfig -> T.Text
containerConfigPayload cfg =
    renderProjectConfig
        ( projectConfigFromContext
            (dockerfile cfg)
            (deploy cfg)
            (message cfg)
            (service cfg)
            (Context.deriveContainerContext (context cfg) (T.pack containerSourceRoot))
        )

directContainerConfigPayload :: ProjectConfig -> T.Text
directContainerConfigPayload cfg =
    renderProjectConfig
        ( projectConfigFromContext
            (dockerfile cfg)
            (deploy cfg)
            (message cfg)
            (service cfg)
            (Context.deriveLinuxGpuContainerContext (context cfg) (T.pack containerSourceRoot))
        )

{- | The lift from the metal/harness frame into the demo's VM frame, selected by
substrate — @inLimaVM@ on Apple Silicon, @inVM@ (Incus) on Linux. Shared by
'demoFrameContext' (the @project up@ handoff) and 'demoTestUp' (so the harness's
reachability probes run inside the VM, where the NodePort is published, on both
providers — § U).
-}
demoVMFrameContext :: Substrate -> LiftContext
demoVMFrameContext sub =
    case selectSubstrateProvider sub demoStaticVMHandles of
        Right sp -> LiftContext [spLiftLayer sp]
        Left _ -> localContext

{- | Assertions run where the production NodePorts are published: in the
provider VM for VM-backed lanes, directly on the host for Linux GPU's
VM-less nvkind lane.
-}
demoTestFrameContext :: Substrate -> LiftContext
demoTestFrameContext sub
    | substrateName sub == LinuxGpu = localContext
    | otherwise = demoVMFrameContext sub

{- | @context-init@ (the @vm-orchestrator-1@ step): the project-container child
@<project>.dhall@ is now streamed in-place into the container over the handoff
@stdin@ ('containerConfigPayload' folded into 'demoDeployImage' by
'demoFrameContext'), so this step is a frame anchor. Keeping it in the chain is what
makes @vm-orchestrator-1@ a real frame in the topology (so the metal→VM→container
descent is three-deep and the recursive interpreter hands off into the container
rather than folding a local @docker run@ on the metal host). Re-deriving the
projection here would duplicate the pure computation the frame context already does,
so the body is a no-op announce (the container's source root @/workspace/demo@ and
the derivation live in 'containerConfigPayload').
-}
contextInitAnnounce :: HostConfig -> IO ()
contextInitAnnounce _ =
    putStrLn
        "context-init: the project-container config is streamed into the container in-place on handoff (stdin, no config bind-mount)"

contextInitDirectAnnounce :: HostConfig -> IO ()
contextInitDirectAnnounce _ =
    putStrLn
        "context-init: the Linux GPU direct project-container config is streamed into the host-launched container with the direct topology witness"

{- | The persistent cluster plan for the demo's container-frame steps: the
Production profile (fixed name + the never-deleted @.data@ path, § O), rooted at
the container's source root.
-}
containerPlan :: Context.BinaryContext -> ClusterPlan
containerPlan ctx =
    basePlan{clusterConfigFile = Just configFile}
  where
    root = T.unpack (Context.sourceRoot ctx)
    placement = acceleratorPlacementForContext ctx
    basePlan
        | Context.isExplicitLinuxGpuContainer ctx =
            resolvePlanWithDriver demoProject root Production NvkindDriver
        | otherwise = resolvePlan demoProject root Production
    configFile
        | Context.isExplicitLinuxGpuContainer ctx = "nvkind-in-cluster.yaml"
        | placement == InClusterDaemon = "kind-in-cluster.yaml"
        | otherwise = "kind.yaml"

{- | Daemon placement is recovered from the validated topology, never from a
nested frame's local substrate detection (a WSL2 VM can itself see the GPU).
-}
acceleratorPlacementForContext :: Context.BinaryContext -> AcceleratorDaemonPlacement
acceleratorPlacementForContext ctx
    | Context.isExplicitLinuxGpuContainer ctx = InClusterDaemon
    | Context.IncusVMProvider `elem` providers = InClusterDaemon
    | otherwise = HostResidentDaemon
  where
    providers = map Context.topologyProvider (Context.topologyFrames ctx)

acceleratorHelmValuesForContext :: ProjectConfig -> Context.BinaryContext -> Either String [(T.Text, T.Text)]
acceleratorHelmValuesForContext projectCfg ctx = do
    WebServiceConfig publicPort' acceleratorPort' <- validatedWebServiceConfigForContext projectCfg ctx
    let ingress = acceleratorIngressPlan (acceleratorPlacementForContext ctx) (fromIntegral acceleratorPort') 30081
    pure $
        [ ("service.port", T.pack (show publicPort'))
        , ("service.accelerator.type", T.pack (ingressServiceType ingress))
        , ("service.accelerator.port", T.pack (show (ingressServicePort ingress)))
        , ("service.accelerator.targetPort", T.pack (show (ingressServicePort ingress)))
        ]
            ++ maybe [] (\nodePort -> [("service.accelerator.nodePort", T.pack (show nodePort))]) (ingressNodePort ingress)

validatedWebServiceConfigForContext :: ProjectConfig -> Context.BinaryContext -> Either String WebServiceConfig
validatedWebServiceConfigForContext projectCfg ctx =
    case service serviceCfg of
        Just (Web params) -> configuredServiceVariant serviceCfg >> pure params
        _ -> Left "projectConfigForServiceContext did not produce a Web service config"
  where
    serviceCfg = projectConfigForServiceContext projectCfg ctx

{- | Container-frame (@vm-project-container-2@) workload step actions. They run in
the project container, where the VM's Docker socket is mounted (kind nodes are
siblings on the VM daemon) and @kubectl@/@helm@/@kind@ resolve on @$PATH@ (baked
into the base image). Each reads the container's local @<project>.dhall@ for the
source root + resources, then drives the real reconcile — reusing the core
cluster lifecycle and the demo's registry logic. The persistent stack: a cordoned
kind cluster (Production profile) → the in-cluster registry → the image (kind-loaded
+ pushed) → the web chart pod → the verified NodePort.
-}
deployKindAction :: HostConfig -> IO ()
deployKindAction _ = demoContext Context.ClusterLifecycleCommand [] $ \ctx -> do
    cfg <- resolveHostConfig
    -- Cordon the cluster to a slice within the budget-sized VM wall (§ O), not the
    -- full budget — the budget is used once, as the VM wall (cordon #1).
    slice <- either die pure (clusterSliceOfBudget (resourcesFromContext ctx))
    withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterCreate cfg (containerPlan ctx) (envelopeOfResources slice))

{- | The in-cluster OCI registry image: the single-binary, natively multi-arch
CNCF @distribution@ registry. Because it ships one multi-arch manifest, it runs on
every substrate (amd64 + arm64) with no per-component image override (a multi-pod
registry stack would otherwise need a dual-arch mirror per component).
-}
registryImage :: String
registryImage = "registry:2"

-- ---------------------------------------------------------------------------
-- MinIO (S3) backing store for the in-cluster registry.
-- ---------------------------------------------------------------------------

{- | The MinIO (S3-compatible) object store image the registry's storage backend
targets. Single-binary and natively multi-arch (like @registry:2@), so it runs on
every substrate with no per-component override.
-}
minioImage :: String
minioImage = "minio/minio"

{- | The MinIO S3-API NodePort, published to the VM localhost by @kind.yaml@ so the
container frame creates the registry bucket over the same loopback idiom
@push-image@ uses for the registry (30500).
-}
minioNodePort :: Int
minioNodePort = 30900

-- | The in-cluster DNS the registry pod reaches MinIO's S3 API on (same namespace).
minioClusterEndpoint :: String
minioClusterEndpoint = "minio.default.svc:9000"

{- | The bucket the registry stores all its blobs/manifests in. Created idempotently
by @deploy-minio@ before the registry starts — the s3 driver requires it to
pre-exist.
-}
registryBucket :: String
registryBucket = "registry"

{- | Fixed demo-internal MinIO root credentials — also the S3 credentials the
registry authenticates with. They live only in the in-cluster @minio-credentials@
Secret and the bucket-init @MC_HOST_local@ env, never in Dhall, @argv@, or a
persisted host file. These are NOT the host Docker Hub credential
"HostBootstrap.Registry" governs, so that credential doctrine does not apply.
-}
minioAccessKey :: String
minioAccessKey = "hostbootstrap"

minioSecretKey :: String
minioSecretKey = "hostbootstrap-demo-secret"

{- | The registry's @config.yml@ storage stanza — the @s3@ driver ONLY. Stock
@registry:2@ ships a default config carrying a @filesystem@ driver; layering
@REGISTRY_STORAGE_S3_*@ env on top of it makes @registry:2@ refuse to start ("must
provide exactly one storage type"). So the whole config is replaced by this
ConfigMap-mounted file declaring only @s3@; the two secret keys are merged in
separately by env @secretKeyRef@ (env-over-config into this same @storage.s3@ map),
which adds credentials without introducing a second driver.
-}
registryConfigYaml :: [String]
registryConfigYaml =
    [ "version: 0.1"
    , "storage:"
    , "  cache: { blobdescriptor: inmemory }"
    , "  s3:"
    , "    regionendpoint: http://" ++ minioClusterEndpoint
    , "    region: us-east-1"
    , "    bucket: " ++ registryBucket
    , "    forcepathstyle: true"
    , "    secure: false"
    , "http: { addr: \":5000\" }"
    , "health: { storagedriver: { enabled: true, interval: 10s, threshold: 3 } }"
    ]

{- | The in-cluster registry manifest: a @registry:2@ Deployment plus a NodePort
Service on 30500, now S3-backed by MinIO. The registry image stays single-binary
and multi-arch; storage is externalized to MinIO so the pushed blobs survive a
registry pod restart (see 'minioManifest'). Anonymous + HTTP — a @localhost@
NodePort is insecure-by-default in Docker, so @push-image@ needs no @docker login@
and no TLS. The s3 storage stanza is supplied by the @registry-config@ ConfigMap
('registryConfigYaml') mounted over the image's default @config.yml@; only the two
S3 secrets come from the @minio-credentials@ Secret via env.
-}
registryManifest :: String
registryManifest =
    unlines $
        [ "apiVersion: v1"
        , "kind: ConfigMap"
        , "metadata:"
        , "  name: registry-config"
        , "data:"
        , "  config.yml: |"
        ]
            ++ map ("    " ++) registryConfigYaml
            ++ [ "---"
               , "apiVersion: apps/v1"
               , "kind: Deployment"
               , "metadata:"
               , "  name: registry"
               , "  labels: { app: registry }"
               , "spec:"
               , "  replicas: 1"
               , "  selector: { matchLabels: { app: registry } }"
               , "  template:"
               , "    metadata: { labels: { app: registry } }"
               , "    spec:"
               , "      containers:"
               , "        - name: registry"
               , "          image: " ++ registryImage
               , "          imagePullPolicy: IfNotPresent"
               , -- The two S3 secrets come from the minio-credentials Secret (env-over-
                 -- config merge into storage.s3), never the ConfigMap. The non-secret s3
                 -- params live in the mounted config.yml.
                 "          env:"
               , "            - name: REGISTRY_STORAGE_S3_ACCESSKEY"
               , "              valueFrom: { secretKeyRef: { name: minio-credentials, key: accesskey } }"
               , "            - name: REGISTRY_STORAGE_S3_SECRETKEY"
               , "              valueFrom: { secretKeyRef: { name: minio-credentials, key: secretkey } }"
               , -- Gate the Service endpoints on the registry actually serving GET /v2/, so
                 -- push-image cannot race a scheduled-but-not-yet-listening registry (a
                 -- NodePort Service routes only to Ready pods). A generous failureThreshold
                 -- tolerates a slow first (unauthenticated) registry:2 pull.
                 "          readinessProbe:"
               , "            httpGet: { path: /v2/, port: 5000 }"
               , "            periodSeconds: 5"
               , "            failureThreshold: 60"
               , "          ports: [ { containerPort: 5000 } ]"
               , "          volumeMounts:"
               , "            - { name: config, mountPath: /etc/docker/registry/config.yml, subPath: config.yml, readOnly: true }"
               , "      volumes:"
               , "        - name: config"
               , "          configMap: { name: registry-config }"
               , "---"
               , "apiVersion: v1"
               , "kind: Service"
               , "metadata:"
               , "  name: registry"
               , "spec:"
               , "  type: NodePort"
               , "  selector: { app: registry }"
               , "  ports:"
               , "    - { port: 5000, targetPort: 5000, nodePort: 30500 }"
               ]

{- | The in-cluster MinIO (S3) deployment the registry's @s3@ storage driver
targets: a @minio-credentials@ Secret, a @minio-data@ PVC (bound to kind's default
@local-path@ StorageClass, so the store survives registry/MinIO POD restarts — the
persistence win — though not @project destroy@), a single @minio server@ Deployment
(@Recreate@ strategy, since a RWO PVC cannot attach to two pods at once), and a
NodePort Service exposing only the S3 API (9000) for bucket-init.
-}
minioManifest :: String
minioManifest =
    unlines
        [ "apiVersion: v1"
        , "kind: Secret"
        , "metadata:"
        , "  name: minio-credentials"
        , "type: Opaque"
        , "stringData:"
        , "  accesskey: " ++ minioAccessKey
        , "  secretkey: " ++ minioSecretKey
        , "---"
        , "apiVersion: v1"
        , "kind: PersistentVolumeClaim"
        , "metadata:"
        , "  name: minio-data"
        , "spec:"
        , "  accessModes: [ ReadWriteOnce ]"
        , "  resources: { requests: { storage: 10Gi } }"
        , "---"
        , "apiVersion: apps/v1"
        , "kind: Deployment"
        , "metadata:"
        , "  name: minio"
        , "  labels: { app: minio }"
        , "spec:"
        , "  replicas: 1"
        , "  strategy: { type: Recreate }"
        , "  selector: { matchLabels: { app: minio } }"
        , "  template:"
        , "    metadata: { labels: { app: minio } }"
        , "    spec:"
        , "      containers:"
        , "        - name: minio"
        , "          image: " ++ minioImage
        , "          imagePullPolicy: IfNotPresent"
        , "          args: [ \"server\", \"/data\", \"--console-address\", \":9001\" ]"
        , "          env:"
        , "            - name: MINIO_ROOT_USER"
        , "              valueFrom: { secretKeyRef: { name: minio-credentials, key: accesskey } }"
        , "            - name: MINIO_ROOT_PASSWORD"
        , "              valueFrom: { secretKeyRef: { name: minio-credentials, key: secretkey } }"
        , "          ports: [ { containerPort: 9000 }, { containerPort: 9001 } ]"
        , "          readinessProbe:"
        , "            httpGet: { path: /minio/health/ready, port: 9000 }"
        , "            periodSeconds: 5"
        , "            failureThreshold: 30"
        , "          resources:"
        , "            requests: { cpu: 100m, memory: 256Mi }"
        , "            limits: { cpu: 500m, memory: 512Mi }"
        , "          volumeMounts:"
        , "            - { name: data, mountPath: /data }"
        , "      volumes:"
        , "        - name: data"
        , "          persistentVolumeClaim: { claimName: minio-data }"
        , "---"
        , "apiVersion: v1"
        , "kind: Service"
        , "metadata:"
        , "  name: minio"
        , "spec:"
        , "  type: NodePort"
        , "  selector: { app: minio }"
        , "  ports:"
        , "    - { name: api, port: 9000, targetPort: 9000, nodePort: " ++ show minioNodePort ++ " }"
        ]

-- Phantom readiness tags (empty marker types, § Tier-2): each names a dependency
-- whose readiness a 'Ready' witness proves. They are distinct types, so a witness
-- minted at one boundary cannot be passed where another is required — "push before
-- the registry serves /v2/", "build #3 before dockerd", "bucket before MinIO Ready",
-- and "network probe before the VM answers" become type errors, not comments.
data VMReady

data DockerDaemon

data MinioReady

data RegistryServing

{- | The demo's readiness probes and rollout waits share these small combinators over
"HostBootstrap.Readiness". 'exitZeroProbe' treats an exit-0 run as ready; 'stdoutProbe'
additionally carries the captured stdout so rollout progress still prints; 'reachProbe'
folds a @curl@ into a lift frame; 'pollRolloutOrDie' is the rollout-style wait — poll,
echo a retry note between attempts and the probe's stdout on success, die on timeout.
-}
exitZeroProbe :: HostTool -> [String] -> Probe ()
exitZeroProbe tool args c = classify <$> runTool c tool args
  where
    classify (Right (ExitSuccess, _, _)) = ProbeReady ()
    classify _ = NotReady

stdoutProbe :: HostTool -> [String] -> Probe String
stdoutProbe tool args c = classify <$> runTool c tool args
  where
    classify (Right (ExitSuccess, out, _)) = ProbeReady out
    classify _ = NotReady

reachProbe :: LiftContext -> String -> Probe ()
reachProbe frame url c = classify <$> liftLeaf c frame (reachLeaf url)
  where
    classify (Right (ExitSuccess, _, _)) = ProbeReady ()
    classify _ = NotReady

pollRolloutOrDie :: HostConfig -> PollPolicy -> String -> String -> Probe String -> IO ()
pollRolloutOrDie cfg pol retryNote failMsg probe = do
    outcome <- pollUntilReadyWith pol failMsg (const (putStrLn retryNote)) probe cfg
    either (const (die failMsg)) (\out -> unless (null out) (putStr out)) outcome

{- | @deploy-minio@ (the demo's contributed workload step, ordered BEFORE
@deploy-registry@): stand up the MinIO S3 backing store, wait for it Ready, and
create the registry bucket idempotently. The @s3@ driver requires the bucket to
pre-exist, so this completes fully before the registry pod schedules.
-}
deployMinioAction :: HostConfig -> IO ()
deployMinioAction _ = demoContext Context.ClusterLifecycleCommand [] $ \_ -> do
    cfg <- resolveHostConfig
    runOrDieStdin cfg Kubectl ["apply", "-f", "-"] minioManifest
    minioReady <- waitMinioRollout cfg
    ensureRegistryBucket minioReady cfg
    putStrLn
        ( "deploy-minio: MinIO ready at "
            ++ minioClusterEndpoint
            ++ "; registry bucket '"
            ++ registryBucket
            ++ "' present"
        )

{- | Poll @kubectl rollout status deployment/minio@ to Ready with backoff (the peer
of 'waitRegistryRollout'), tolerating a slow first @minio/minio@ pull.
-}
waitMinioRollout :: HostConfig -> IO (Ready MinioReady)
waitMinioRollout cfg = do
    outcome <-
        awaitReadyWith
            rolloutPoll
            "deploy-minio"
            (const (putStrLn "deploy-minio: minio not Ready yet (kubelet still pulling minio/minio); retrying"))
            (stdoutProbe Kubectl ["rollout", "status", "deployment/minio", "--timeout=60s"])
            cfg
    either (const (die "deploy-minio: minio deployment did not become Ready")) pure outcome

{- | Create the registry bucket in MinIO with @mc mb --ignore-existing@ (idempotent,
so a re-run of @project up@ is safe). Runs from the container frame — the
base-derived project image ships @mc@ — reaching MinIO over the loopback NodePort,
the same idiom @push-image@ uses for the registry. The credentials travel in the
@MC_HOST_local@ env (mc auto-registers the alias from it), never in @argv@. Bounded
retry covers the window between MinIO pod-Ready and its S3 endpoint accepting a
MakeBucket.
-}
ensureRegistryBucket :: Ready MinioReady -> HostConfig -> IO ()
ensureRegistryBucket _minioReady cfg = do
    setEnv
        "MC_HOST_local"
        ("http://" ++ minioAccessKey ++ ":" ++ minioSecretKey ++ "@localhost:" ++ show minioNodePort)
    -- The @Ready MinioReady@ witness proves MinIO rolled out before we make the
    -- bucket, so the @s3@ driver's "bucket must pre-exist" invariant is a type
    -- dependency here, not a comment.
    pollRolloutOrDie
        cfg
        rolloutPoll
        "deploy-minio: MinIO S3 endpoint not ready for bucket create; retrying"
        "deploy-minio: could not create the registry bucket in MinIO"
        (stdoutProbe Mc ["mb", "--ignore-existing", "local/" ++ registryBucket])

{- | @deploy-registry@ (the demo's contributed workload step): stand up the
in-cluster OCI registry the @push-image@ step pushes to. A single @registry:2@
Deployment + NodePort Service applied with @kubectl@ (no Helm, no multi-pod
chart), the Deployment then waited to Ready. The pod pulls @registry:2@ from
Docker Hub itself: containerd on the node selects the node platform from the
multi-arch manifest, whereas @kind load docker-image@ cannot pre-load a
multi-arch image (its @ctr import --all-platforms@ fails "content digest not
found"). @registry:2@ is natively multi-arch, so one manifest serves every
substrate with no component overrides.
-}
deployRegistryAction :: HostConfig -> IO ()
deployRegistryAction _ = demoContext Context.ClusterLifecycleCommand [] $ \_ -> do
    cfg <- resolveHostConfig
    -- Apply the registry Deployment + NodePort and wait for the rollout. The pod
    -- pulls registry:2 from Docker Hub itself — NOT `kind load docker-image`, which
    -- cannot pre-load a multi-arch image (its `ctr import --all-platforms` fails
    -- "content digest not found"). containerd on the node selects the node platform
    -- from registry:2's multi-arch manifest on pull. The demo's own single-arch
    -- project image is still delivered locally by push-image's `kind load`.
    runOrDieStdin cfg Kubectl ["apply", "-f", "-"] registryManifest
    -- Poll the rollout to Ready with backoff rather than a single fatal
    -- `rollout status --timeout=120s`: the pod's first (unauthenticated) registry:2
    -- pull can exceed a fixed window under Docker Hub load, so retry the rollout wait
    -- before failing.
    waitRegistryRollout cfg
    putStrLn ("deploy-registry: in-cluster registry rollout complete at http://" ++ registryEndpoint)

{- | Poll @kubectl rollout status deployment/registry@ to Ready with backoff,
tolerating a slow first registry:2 pull. Each attempt waits up to 60 s; @n@
attempts with a 5 s backoff give generous headroom, then a final failure dies so a
genuinely stuck rollout still surfaces.
-}
waitRegistryRollout :: HostConfig -> IO ()
waitRegistryRollout cfg =
    pollRolloutOrDie
        cfg
        rolloutPoll
        "deploy-registry: registry not Ready yet (kubelet still pulling registry:2); retrying"
        "deploy-registry: registry deployment did not become Ready"
        (stdoutProbe Kubectl ["rollout", "status", "deployment/registry", "--timeout=60s"])

pushImageAction :: HostConfig -> IO ()
pushImageAction _ = demoContext Context.ProjectCommand [] $ \ctx -> do
    cfg <- resolveHostConfig
    -- Load the image into the kind nodes (so the web chart pod's IfNotPresent pull
    -- resolves without a registry round-trip), then also push it to the in-cluster
    -- registry (the capability the demo demonstrates). A @localhost@ registry is
    -- insecure-by-default in Docker, and @registry:2@ is anonymous, so the HTTP
    -- NodePort needs no @docker login@ and no TLS.
    runOrDie cfg Kind ["load", "docker-image", demoProjectImage, "--name", clusterName (containerPlan ctx)]
    let ref = registryEndpoint ++ "/library/hostbootstrap-demo:demo"
    -- Poll GET /v2/ on the registry NodePort from this frame, minting the
    -- `Ready RegistryServing` witness `pushImageBlob` requires: the tag-and-push
    -- cannot race a scheduled-but-not-yet-serving registry because pushing without
    -- that proof is a type error (the readinessProbe gates the Service endpoints;
    -- this confirms it answers here too, and encodes the dependency in the types).
    serving <-
        awaitReady
            (reachPoll `withAttempts` 24)
            ("push-image: registry /v2/ at " ++ registryEndpoint)
            (reachProbe localContext ("http://" ++ registryEndpoint ++ "/v2/"))
            cfg
    registryServing <-
        either
            (const (die ("push-image: in-cluster registry did not answer GET /v2/ at " ++ registryEndpoint)))
            pure
            serving
    runOrDie cfg Docker ["tag", demoProjectImage, ref]
    pushImageBlob registryServing cfg ref
    putStrLn ("push-image: kind-loaded " ++ demoProjectImage ++ " and pushed " ++ ref)

{- | The transient @docker push@ failure markers a bounded retry safely absorbs:
the digest/blob-upload races and connection blips that occur under registry load.
A push is idempotent (it re-uploads only the missing blobs and re-verifies each
digest), so retrying these is safe; anything else is a deterministic failure that
must surface immediately, not be retried. Pure, so the classifier is unit-tested.
-}
isTransientPushError :: String -> Bool
isTransientPushError s = any (`isInfixOf` s) markers
  where
    markers =
        [ "provided digest did not match uploaded content"
        , "blob upload unknown"
        , "blob upload invalid"
        , "connection refused"
        , "connection reset"
        , "i/o timeout"
        , "TLS handshake timeout"
        , "unexpected EOF"
        , "500 Internal Server Error"
        , "502 Bad Gateway"
        , "503 Service Unavailable"
        ]

{- | Retry @docker push@ **only** for the transient registry class
('isTransientPushError'); a non-transient failure dies immediately with the
registry's full diagnostics rather than burning the retry budget on a deterministic
error. Bounded by @n@ attempts with a five-second backoff; the last attempt is a
plain 'runOrDie'.
-}
pushImageBlob :: Ready RegistryServing -> HostConfig -> String -> IO ()
pushImageBlob _serving cfg ref = do
    outcome <- pollUntilReadyWith pushPoll "push-image" backoffNote pushProbe cfg
    either (die . renderPollError) emitProgress outcome
  where
    -- The 'push-image' label is prepended to a 'Failed' message by 'pollStep', so
    -- the rendered non-transient / could-not-run errors read exactly as before.
    pushProbe c = classify <$> runToolWithStdin c Docker ["push", ref] ""
    classify (Right (ExitSuccess, out, _)) = ProbeReady out
    classify (Right (ExitFailure code, out, err))
        | isTransientPushError (out ++ err) = NotReady
        | otherwise = Failed ("docker push failed (exit " ++ show code ++ ", non-transient)\n" ++ out ++ err)
    classify (Left err) = Failed ("docker push could not run: " ++ err)
    backoffNote _ = putStrLn "push-image: transient registry error; retrying after backoff"
    emitProgress out = unless (null out) (putStr out)

{- | Render the service projection from the actual validated parent topology.
This replaces the chart's former hand-written Lima-only context: Incus, WSL2,
and the direct Linux GPU topology now produce their own correct providers,
parents, frame id, and witness.
-}
renderServiceConfigForContext :: ProjectConfig -> Context.BinaryContext -> (T.Text, T.Text)
renderServiceConfigForContext projectCfg parentCtx =
    ( renderProjectConfig serviceCfg
    , Context.currentFrame serviceCtx
    )
  where
    serviceCtx = Context.deriveServiceContext parentCtx (Context.sourceRoot parentCtx)
    serviceCfg = projectConfigForServiceContext projectCfg parentCtx

projectConfigForServiceContext :: ProjectConfig -> Context.BinaryContext -> ProjectConfig
projectConfigForServiceContext projectCfg parentCtx =
    projectConfigFromContext
        (dockerfile projectCfg)
        (deploy projectCfg)
        (message projectCfg)
        (service projectCfg)
        (Context.deriveServiceContext parentCtx (Context.sourceRoot parentCtx))

serviceConfigMapManifest :: T.Text -> String
serviceConfigMapManifest serviceConfig =
    unlines
        [ "apiVersion: v1"
        , "kind: ConfigMap"
        , "metadata:"
        , "  name: " ++ demoProject ++ "-config"
        , "data:"
        , "  hostbootstrap-demo.dhall: |"
        ]
        ++ indentBlock 4 serviceConfig

{- | @deploy-chart@: derive and apply the web service's ConfigMap from the live
parent context, then install the chart. The service frame and a stable config
fingerprint are Helm values so the pod witness is exact and a changed config
rolls the Deployment even though the ConfigMap is applied outside Helm.
-}
deployChartAction :: HostConfig -> IO ()
deployChartAction _ = demoConfigContext Context.ClusterLifecycleCommand [] $ \projectCfg ctx -> do
    cfg <- resolveHostConfig
    either die pure (validateAcceleratorReplicaCount (haReplicas (deploy projectCfg)))
    acceleratorHelmValues <- either die pure (acceleratorHelmValuesForContext projectCfg ctx)
    let (serviceConfig, serviceFrame) = renderServiceConfigForContext projectCfg ctx
        extraValues =
            [ ("haReplicas", T.pack (show (haReplicas (deploy projectCfg))))
            , ("service.currentFrame", serviceFrame)
            , ("service.configHash", projectConfigSnapshotHash (configMapMountedText serviceConfig))
            ]
                ++ acceleratorHelmValues
    runOrDieStdin cfg Kubectl ["apply", "-f", "-"] (serviceConfigMapManifest serviceConfig)
    withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (deployChart cfg (containerPlan ctx) extraValues)

{- | The accelerator hub is process-local, so requests and the daemon connection
must meet in one web pod. Reject an HA value that would make routing
nondeterministic instead of deploying a topology that only works by chance.
-}
validateAcceleratorReplicaCount :: Natural -> Either String ()
validateAcceleratorReplicaCount 1 = Right ()
validateAcceleratorReplicaCount actual =
    Left
        ( "deploy-chart: accelerator routing requires exactly one web replica; configured haReplicas="
            ++ show actual
        )

exposeAction :: HostConfig -> IO ()
exposeAction cfg = demoContext Context.ClusterLifecycleCommand [] $ \_ -> do
    ready <- waitWebReachable cfg localContext "http://localhost:30080/api/budget" 60
    unless ready (die "expose-port: the web NodePort 30080 did not become reachable on the host")
    putStrLn "expose-port: web service reachable at http://localhost:30080/"

{- | @deploy-accelerator-daemon@ (Linux CPU/GPU): deploy the accelerator daemon as an
IN-CLUSTER pod rather than a host-resident process. Apple/Windows run the daemon on
the host because Lima/WSL2 forward the guest NodePort so a host daemon can dial the
local-only ingress; Incus does not forward guest ports, so the Linux daemon runs
inside the cluster and dials the web service over its ClusterIP (accelerator_daemon.md
§ Cluster Exposure). The pod is the project image running @service run@ with an
@Accelerator@ config;
its daemon-role @<project>.dhall@ is delivered as a ConfigMap overriding the baked
container config (§ X / § AA), and @HOSTBOOTSTRAP_ACCELERATOR_WS_URL@ points at the
web ClusterIP accelerator port. Runs in the container frame (where @kubectl@
resolves), the peer of @deploy-chart@.
-}
deployAcceleratorDaemonAction :: HostConfig -> IO ()
deployAcceleratorDaemonAction _ = demoConfigContext Context.ClusterLifecycleCommand [] $ \projectCfg ctx -> do
    cfg <- resolveHostConfig
    WebServiceConfig _ acceleratorServicePort <- either die pure (validatedWebServiceConfigForContext projectCfg ctx)
    let daemonCtx = Context.deriveClusterDaemonContext ctx (Context.sourceRoot ctx)
        gpuDaemon = Context.isExplicitLinuxGpuContainer ctx
        daemonProjectCfg =
            projectConfigFromContext (dockerfile projectCfg) (deploy projectCfg) (message projectCfg) (service projectCfg) daemonCtx
        daemonConfig = renderProjectConfig daemonProjectCfg
        frame = T.unpack (Context.currentFrame daemonCtx)
    _ <- either die pure (configuredServiceVariant daemonProjectCfg)
    runOrDieStdin cfg Kubectl ["apply", "-f", "-"] (acceleratorDaemonManifest gpuDaemon frame daemonConfig acceleratorServicePort)
    pollRolloutOrDie
        cfg
        rolloutPoll
        "deploy-accelerator-daemon: daemon not Ready yet (kubelet pulling / worker building); retrying"
        "deploy-accelerator-daemon: the in-cluster accelerator daemon did not become Ready"
        (stdoutProbe Kubectl ["rollout", "status", "deployment/accelerator-daemon", "--timeout=60s"])
    putStrLn "deploy-accelerator-daemon: in-cluster accelerator daemon deployed (dials the web ClusterIP ingress)"

{- | The in-cluster accelerator daemon manifest: a ConfigMap carrying the daemon's
generated @<project>.dhall@ and a Deployment that runs config-selected @service run@ from
the project image, mounting the ConfigMap over the baked container config and pointing
@HOSTBOOTSTRAP_ACCELERATOR_WS_URL@ at the web ClusterIP accelerator port.
-}
acceleratorDaemonManifest :: Bool -> String -> T.Text -> Natural -> String
acceleratorDaemonManifest gpuDaemon frame daemonConfig acceleratorServicePort =
    configMap ++ "---\n" ++ deployment
  where
    configMap =
        unlines
            [ "apiVersion: v1"
            , "kind: ConfigMap"
            , "metadata:"
            , "  name: accelerator-daemon-config"
            , "data:"
            , "  hostbootstrap-demo.dhall: |"
            ]
            ++ indentBlock 4 daemonConfig
    deployment =
        unlines
            [ "apiVersion: apps/v1"
            , "kind: Deployment"
            , "metadata:"
            , "  name: accelerator-daemon"
            , "  labels:"
            , "    app: accelerator-daemon"
            , "spec:"
            , "  replicas: 1"
            , "  strategy:"
            , "    type: Recreate"
            , "  selector:"
            , "    matchLabels:"
            , "      app: accelerator-daemon"
            , "  template:"
            , "    metadata:"
            , "      labels:"
            , "        app: accelerator-daemon"
            , "      annotations:"
            , "        hostbootstrap.io/config-hash: \"" ++ T.unpack (projectConfigSnapshotHash (configMapMountedText daemonConfig)) ++ "\""
            , "    spec:"
            , "      volumes:"
            , "        - name: daemon-config"
            , "          configMap:"
            , "            name: accelerator-daemon-config"
            , "      containers:"
            , "        - name: daemon"
            , "          image: \"" ++ demoProjectImage ++ "\""
            , "          imagePullPolicy: IfNotPresent"
            , "          args: [\"service\", \"run\"]"
            , "          env:"
            , "            - name: HOSTBOOTSTRAP_CURRENT_FRAME"
            , "              value: \"" ++ frame ++ "\""
            , "            - name: HOSTBOOTSTRAP_ACCELERATOR_WS_URL"
            , "              value: \"ws://" ++ demoProject ++ "-accelerator:" ++ show acceleratorServicePort ++ "/api/accelerator/daemon\""
            , "            - name: HOSTBOOTSTRAP_ACCELERATOR_READY_FILE"
            , "              value: \"/tmp/hostbootstrap-accelerator.ready\""
            , "          volumeMounts:"
            , "            - name: daemon-config"
            , "              mountPath: /usr/local/bin/hostbootstrap-demo.dhall"
            , "              subPath: hostbootstrap-demo.dhall"
            , "              readOnly: true"
            , "          readinessProbe:"
            , "            exec:"
            , "              command: [\"/usr/bin/test\", \"-f\", \"/tmp/hostbootstrap-accelerator.ready\"]"
            , "            initialDelaySeconds: 1"
            , "            periodSeconds: 2"
            ]
            ++ gpuResources
    gpuResources
        | gpuDaemon =
            unlines
                [ "          resources:"
                , "            limits:"
                , "              nvidia.com/gpu: 1"
                ]
        | otherwise = ""

{- | YAML's literal block scalar (@|@) mounts one final newline. Hash that exact
payload so rollout annotations and the runtime snapshot log name the same
bytes.
-}
configMapMountedText :: T.Text -> T.Text
configMapMountedText value
    | T.isSuffixOf "\n" value = value
    | otherwise = value <> "\n"

indentBlock :: Int -> T.Text -> String
indentBlock n = unlines . map (replicate n ' ' ++) . lines . T.unpack

startHostAcceleratorDaemonAction :: HostConfig -> IO ()
startHostAcceleratorDaemonAction cfg
    | hostAcceleratorSubstrate (hcSubstrate cfg) =
        demoConfigContext Context.HostOrchestratorCommand [Context.HostTools] $ \projectCfg ctx -> do
            withHostAcceleratorDaemonOperation ctx $ do
                stopHostAcceleratorDaemonUnlocked cfg ctx
                daemonExe <- installHostAcceleratorDaemonBinary ctx
                shutdownPath <- makeAbsolute (hostAcceleratorDaemonShutdownPath ctx)
                readyPath <- makeAbsolute (hostAcceleratorDaemonReadyPath ctx)
                let daemonCtx = Context.deriveHostDaemonContext (context projectCfg) (Context.sourceRoot ctx)
                    daemonCfg =
                        projectConfigFromContext
                            (dockerfile projectCfg)
                            (deploy projectCfg)
                            (message projectCfg)
                            (service projectCfg)
                            daemonCtx
                    daemonCfgPath = hostAcceleratorDaemonConfigPath ctx
                    endpoint = "ws://127.0.0.1:30081/api/accelerator/daemon"
                pidPath <- makeAbsolute (hostAcceleratorDaemonPidPath ctx)
                _ <- either die pure (configuredServiceVariant daemonCfg)
                removeIfExists readyPath
                writeProjectConfigFile daemonCfgPath daemonCfg
                daemonPayload <- BS.readFile daemonCfgPath
                TIO.putStrLn
                    ( renderProjectConfigSnapshotLog
                        daemonCfgPath
                        (projectConfigSnapshotHashBytes daemonPayload)
                        daemonCtx
                    )
                env0 <- getEnvironment
                let daemonOverrides =
                        [ ("HOSTBOOTSTRAP_CURRENT_FRAME", T.unpack (Context.currentFrame daemonCtx))
                        , ("HOSTBOOTSTRAP_ACCELERATOR_WS_URL", endpoint)
                        , ("HOSTBOOTSTRAP_ACCELERATOR_SHUTDOWN_FILE", shutdownPath)
                        , ("HOSTBOOTSTRAP_ACCELERATOR_READY_FILE", readyPath)
                        ]
                    daemonEnv =
                        daemonOverrides
                            ++ filter
                                ( \kv ->
                                    fst kv
                                        `notElem` [ "HOSTBOOTSTRAP_CURRENT_FRAME"
                                                  , "HOSTBOOTSTRAP_ACCELERATOR_WS_URL"
                                                  , "HOSTBOOTSTRAP_ACCELERATOR_SHUTDOWN_FILE"
                                                  , "HOSTBOOTSTRAP_ACCELERATOR_READY_FILE"
                                                  , harnessMutationGuardEnv
                                                  ]
                                )
                                env0
                mask $ \restore -> do
                    claimHostAcceleratorDaemon ctx
                    let abortTracked = do
                            cleanup <- try (stopHostAcceleratorDaemonUnlocked cfg ctx) :: IO (Either SomeException ())
                            case cleanup of
                                Right () -> pure ()
                                Left err ->
                                    ioError
                                        ( userError
                                            ( "accelerator-daemon: startup failed and owned cleanup also failed; preserving lifecycle state: "
                                                ++ show err
                                            )
                                        )
                        finishTracked pid = do
                            readiness <-
                                restore (waitForHostAcceleratorDaemonReady cfg pid daemonExe readyPath hostDaemonReadyAttempts)
                                    `onException` abortTracked
                            case readiness of
                                Left err -> abortTracked >> die err
                                Right () ->
                                    restore (putStrLn ("accelerator-daemon: host daemon ready at " ++ endpoint ++ " (pid " ++ pid ++ ")"))
                                        `onException` abortTracked
                    if isWindows (hcSubstrate cfg)
                        then do
                            let abortWindowsLaunch = do
                                    tracked <- doesFileExist pidPath
                                    if tracked
                                        then abortTracked
                                        else do
                                            removeIfExists readyPath
                                            releaseHostAcceleratorDaemon ctx
                            pid <-
                                restore (startWindowsHostAcceleratorDaemon cfg daemonExe pidPath daemonOverrides)
                                    `onException` abortWindowsLaunch
                            finishTracked pid
                        else do
                            (_, _, _, ph) <-
                                restore (createProcess (hostAcceleratorDaemonProcess daemonExe daemonEnv))
                                    `onException` releaseHostAcceleratorDaemon ctx
                            let abortUntracked = do
                                    removed <- try (removeIfExists pidPath) :: IO (Either SomeException ())
                                    removedReady <- try (removeIfExists readyPath) :: IO (Either SomeException ())
                                    _ <- try (terminateProcess ph) :: IO (Either SomeException ())
                                    waited <- timeout 5000000 (try (waitForProcess ph) :: IO (Either SomeException ExitCode))
                                    case (removed, removedReady, waited) of
                                        (Right (), Right (), Just (Right _)) -> releaseHostAcceleratorDaemon ctx
                                        _ ->
                                            ioError
                                                ( userError
                                                    ( "accelerator-daemon: could not prove cleanup of an untracked daemon; preserving lifecycle ownership (pid cleanup="
                                                        ++ show removed
                                                        ++ ", readiness cleanup="
                                                        ++ show removedReady
                                                        ++ ", process exit="
                                                        ++ show waited
                                                        ++ ")"
                                                    )
                                                )
                            mpid <- getPid ph `onException` abortUntracked
                            case mpid of
                                Nothing -> do
                                    abortUntracked
                                    die "accelerator-daemon: process id unavailable; terminated untrackable daemon"
                                Just pid -> do
                                    restore (writeFile pidPath (show pid ++ "\n"))
                                        `onException` abortUntracked
                                    finishTracked (show pid)
    | otherwise =
        putStrLn "accelerator-daemon: in-cluster daemon placement; host daemon hook is a no-op"

hostAcceleratorDaemonDir :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonDir ctx =
    T.unpack (Context.sourceRoot ctx) </> ".build" </> "accelerator-daemon"

hostAcceleratorDaemonExePath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonExePath ctx =
    hostAcceleratorDaemonDir ctx </> daemonExecutableName
  where
    daemonExecutableName
        | os == "mingw32" = demoProject ++ ".exe"
        | otherwise = demoProject

hostAcceleratorDaemonConfigPath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonConfigPath ctx =
    hostAcceleratorDaemonDir ctx </> (demoProject ++ ".dhall")

hostAcceleratorDaemonPidPath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonPidPath ctx =
    hostAcceleratorDaemonDir ctx </> "hostbootstrap-demo.accelerator.pid"

hostAcceleratorDaemonShutdownPath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonShutdownPath ctx =
    hostAcceleratorDaemonDir ctx </> "hostbootstrap-demo.accelerator.shutdown"

hostAcceleratorDaemonReadyPath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonReadyPath ctx =
    hostAcceleratorDaemonDir ctx </> "hostbootstrap-demo.accelerator.ready"

hostAcceleratorDaemonOwnerPath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonOwnerPath ctx =
    hostAcceleratorDaemonDir ctx </> "hostbootstrap-demo.accelerator.owner"

hostAcceleratorDaemonOperationPath :: Context.BinaryContext -> FilePath
hostAcceleratorDaemonOperationPath ctx =
    hostAcceleratorDaemonDir ctx </> "hostbootstrap-demo.accelerator.operation"

withHostAcceleratorDaemonOperation :: Context.BinaryContext -> IO a -> IO a
withHostAcceleratorDaemonOperation ctx action =
    mask $ \restore -> do
        let operationPath = hostAcceleratorDaemonOperationPath ctx
        createDirectoryIfMissing True (hostAcceleratorDaemonDir ctx)
        claimed <- tryIOError (createDirectory operationPath)
        case claimed of
            Left _ -> die ("accelerator-daemon: lifecycle operation already active at " ++ operationPath)
            Right () -> restore action `finally` removeDirectory operationPath

claimHostAcceleratorDaemon :: Context.BinaryContext -> IO ()
claimHostAcceleratorDaemon ctx = do
    let ownerPath = hostAcceleratorDaemonOwnerPath ctx
    claimed <- tryIOError (createDirectory ownerPath)
    case claimed of
        Right () -> pure ()
        Left _ -> die ("accelerator-daemon: lifecycle ownership already held at " ++ ownerPath)

releaseHostAcceleratorDaemon :: Context.BinaryContext -> IO ()
releaseHostAcceleratorDaemon ctx = do
    let ownerPath = hostAcceleratorDaemonOwnerPath ctx
    present <- doesDirectoryExist ownerPath
    when present (removeDirectory ownerPath)

hostAcceleratorSubstrate :: Substrate -> Bool
hostAcceleratorSubstrate sub =
    isAppleSilicon sub || substrateName sub == WindowsGpu

{- | Build the POSIX host-daemon process specification. A host daemon must not
inherit the @project up@ process's capture pipe: an inherited writer prevents
the harness from ever observing EOF. 'NoStream' plus 'close_fds' closes that
surface on POSIX. Windows uses 'hostAcceleratorDaemonPowerShellScript' instead,
because @process@ only honors @close_fds@ there when all three streams are
@Inherit@; hidden @Start-Process@ supplies the independent Windows lifetime.
-}
hostAcceleratorDaemonProcess :: FilePath -> [(String, String)] -> CreateProcess
hostAcceleratorDaemonProcess daemonExe daemonEnv =
    (proc daemonExe ["service", "run"])
        { env = Just daemonEnv
        , std_in = NoStream
        , std_out = NoStream
        , std_err = NoStream
        , close_fds = True
        }

{- | Render the Windows-only hidden launch script. The short-lived PowerShell
parent receives the four daemon-specific environment overrides, removes the
harness mutation guard, and uses @Start-Process@ without @-NoNewWindow@. That
child does not retain the captured @project up@ pipe. The script writes the PID
before reporting success and force-stops the child if PID persistence fails, so
the Haskell lifecycle never creates an untrackable daemon.
-}
hostAcceleratorDaemonPowerShellScript :: FilePath -> FilePath -> [(String, String)] -> String
hostAcceleratorDaemonPowerShellScript daemonExe pidPath overrides =
    "$ErrorActionPreference = 'Stop'; "
        ++ concatMap setOverride overrides
        ++ "Remove-Item -LiteralPath "
        ++ powerShellQuote ("Env:" ++ harnessMutationGuardEnv)
        ++ " -ErrorAction SilentlyContinue; "
        ++ "$p = Start-Process -FilePath "
        ++ powerShellQuote daemonExe
        ++ " -ArgumentList @('service', 'run') -WindowStyle Hidden -PassThru; "
        ++ "try { [System.IO.File]::WriteAllText("
        ++ powerShellQuote pidPath
        ++ ", ([string]$p.Id + [Environment]::NewLine), [System.Text.Encoding]::ASCII); "
        ++ "[Console]::WriteLine($p.Id) } catch { "
        ++ "Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw }"
  where
    setOverride (name, value) = "$env:" ++ name ++ " = " ++ powerShellQuote value ++ "; "

startWindowsHostAcceleratorDaemon :: HostConfig -> FilePath -> FilePath -> [(String, String)] -> IO String
startWindowsHostAcceleratorDaemon cfg daemonExe pidPath overrides = do
    result <-
        runTool
            cfg
            PowerShell
            [ "-NoProfile"
            , "-Command"
            , hostAcceleratorDaemonPowerShellScript daemonExe pidPath overrides
            ]
    pid <- case result of
        Left err -> die ("accelerator-daemon: hidden Windows launch failed: " ++ err)
        Right (ExitFailure n, _, err) -> die ("accelerator-daemon: hidden Windows launch failed (exit " ++ show n ++ "): " ++ err)
        Right (ExitSuccess, out, _) -> pure (T.unpack (T.strip (T.pack out)))
    unless (not (null pid) && all isDigit pid) $
        die ("accelerator-daemon: hidden Windows launch returned an invalid pid: " ++ show pid)
    recorded <- readHostAcceleratorDaemonPid pidPath
    unless (recorded == pid) $
        die ("accelerator-daemon: hidden Windows launch pid disagrees with its lifecycle file: " ++ pid ++ " /= " ++ recorded)
    pure pid

powerShellQuote :: String -> String
powerShellQuote value = "'" ++ concatMap escape value ++ "'"
  where
    escape '\'' = "''"
    escape c = [c]

-- | Strictly read the teardown pid so Windows releases the pid-file handle.
readHostAcceleratorDaemonPid :: FilePath -> IO String
readHostAcceleratorDaemonPid pidPath = do
    raw <- TIO.readFile pidPath
    let value = T.unpack (T.strip raw)
    if not (null value) && all isDigit value
        then pure value
        else ioError (userError ("accelerator-daemon: invalid pid file: " ++ pidPath))

installHostAcceleratorDaemonBinary :: Context.BinaryContext -> IO FilePath
installHostAcceleratorDaemonBinary ctx = do
    daemonExe <- absoluteHostAcceleratorDaemonExePath ctx
    let daemonDir = takeDirectory daemonExe
    createDirectoryIfMissing True daemonDir
    currentExe <- getExecutablePath
    copyFile currentExe daemonExe
    getPermissions currentExe >>= setPermissions daemonExe
    pure daemonExe

-- | Resolve the copied daemon executable before launch and identity checks.
absoluteHostAcceleratorDaemonExePath :: Context.BinaryContext -> IO FilePath
absoluteHostAcceleratorDaemonExePath = makeAbsolute . hostAcceleratorDaemonExePath

stopHostAcceleratorDaemon :: HostConfig -> Context.BinaryContext -> IO ()
stopHostAcceleratorDaemon cfg ctx =
    withHostAcceleratorDaemonOperation ctx (stopHostAcceleratorDaemonUnlocked cfg ctx)

stopHostAcceleratorDaemonUnlocked :: HostConfig -> Context.BinaryContext -> IO ()
stopHostAcceleratorDaemonUnlocked cfg ctx = do
    daemonExe <- absoluteHostAcceleratorDaemonExePath ctx
    readyPath <- makeAbsolute (hostAcceleratorDaemonReadyPath ctx)
    let pidPath = hostAcceleratorDaemonPidPath ctx
        shutdownPath = hostAcceleratorDaemonShutdownPath ctx
    exists <- doesFileExist pidPath
    ownerExists <- doesDirectoryExist (hostAcceleratorDaemonOwnerPath ctx)
    unless (hostDaemonLifecycleStateConsistent exists ownerExists) $
        die "accelerator-daemon: pid and lifecycle ownership disagree; refusing ambiguous cleanup"
    when exists $ do
        pid <- readHostAcceleratorDaemonPid pidPath
        when (null pid) (die ("accelerator-daemon: invalid pid file; refusing lossy cleanup: " ++ pidPath))
        TIO.writeFile shutdownPath "stop\n"
        graceful <- waitForExit pid daemonExe 20
        case graceful of
            Left err -> die err
            Right True -> removeFile pidPath
            Right False -> do
                stillOurs <- hostDaemonProcessRunning cfg pid daemonExe
                case stillOurs of
                    Left err -> die err
                    -- Dead or a reused PID belonging to another executable: the
                    -- stale pid file is ours to remove, but never signal the process.
                    Right False -> removeFile pidPath
                    Right True -> do
                        stopPid pid
                        forced <- waitForExit pid daemonExe 20
                        case forced of
                            Right True -> removeFile pidPath
                            Right False -> die ("accelerator-daemon: pid " ++ pid ++ " remained live after forced stop; preserving pid file")
                            Left err -> die err
    removeIfExists shutdownPath
    removeIfExists readyPath
    releaseHostAcceleratorDaemon ctx
  where
    waitForExit :: String -> FilePath -> Int -> IO (Either String Bool)
    waitForExit _ _ 0 = pure (Right False)
    waitForExit pid daemonExe attempts = do
        running <- hostDaemonProcessRunning cfg pid daemonExe
        case running of
            Left err -> pure (Left err)
            Right False -> pure (Right True)
            Right True -> threadDelay 250000 >> waitForExit pid daemonExe (attempts - 1)
    stopPid pid
        | isWindows (hcSubstrate cfg) = do
            putStrLn ("accelerator-daemon: stopping host daemon pid " ++ pid)
            requireStop =<< runTool cfg PowerShell ["-NoProfile", "-Command", "Stop-Process -Id " ++ pid ++ " -Force -ErrorAction Stop"]
        | otherwise = do
            putStrLn ("accelerator-daemon: stopping host daemon pid " ++ pid)
            requireStop =<< runTool cfg Kill [pid]
    requireStop (Right (ExitSuccess, _, _)) = pure ()
    requireStop (Right (ExitFailure n, _, err)) = die ("accelerator-daemon: forced stop failed (exit " ++ show n ++ "): " ++ err)
    requireStop (Left err) = die ("accelerator-daemon: forced stop failed: " ++ err)

-- | A daemon is either wholly absent or has both lifecycle witnesses.
hostDaemonLifecycleStateConsistent :: Bool -> Bool -> Bool
hostDaemonLifecycleStateConsistent pidPresent ownerPresent = pidPresent == ownerPresent

waitForHostAcceleratorDaemonReady :: HostConfig -> String -> FilePath -> FilePath -> Int -> IO (Either String ())
waitForHostAcceleratorDaemonReady _ pid _ _ 0 =
    pure
        ( Left
            ( "accelerator-daemon: pid "
                ++ pid
                ++ " did not become ready within "
                ++ show hostDaemonReadyTimeoutSeconds
                ++ " seconds"
            )
        )
waitForHostAcceleratorDaemonReady cfg pid daemonExe readyPath attempts = do
    ready <- doesFileExist readyPath
    running <- hostDaemonProcessRunning cfg pid daemonExe
    case running of
        Left err -> pure (Left err)
        Right False -> pure (Left ("accelerator-daemon: pid " ++ pid ++ " exited before readiness"))
        Right True
            | ready -> pure (Right ())
            | otherwise -> threadDelay hostDaemonReadyPollMicros >> waitForHostAcceleratorDaemonReady cfg pid daemonExe readyPath (attempts - 1)

-- A pristine host may install CUDA, VS Build Tools, LLVM, or the Apple build stack before connecting.
hostDaemonReadyTimeoutSeconds :: Int
hostDaemonReadyTimeoutSeconds = 30 * 60

hostDaemonReadyPollMicros :: Int
hostDaemonReadyPollMicros = 5 * 1000000

hostDaemonReadyAttempts :: Int
hostDaemonReadyAttempts = hostDaemonReadyTimeoutSeconds `div` (hostDaemonReadyPollMicros `div` 1000000)

hostDaemonProcessRunning :: HostConfig -> String -> FilePath -> IO (Either String Bool)
hostDaemonProcessRunning cfg pid daemonExe = do
    result <-
        if isWindows (hcSubstrate cfg)
            then
                runTool
                    cfg
                    PowerShell
                    [ "-NoProfile"
                    , "-Command"
                    , "$p = Get-CimInstance Win32_Process -Filter 'ProcessId = " ++ pid ++ "' -ErrorAction SilentlyContinue; if ($null -ne $p) { [Console]::WriteLine($p.ExecutablePath); [Console]::WriteLine($p.CommandLine) }"
                    ]
            else runTool cfg Ps ["-ww", "-p", pid, "-o", "command="]
    pure $ case result of
        Left err -> Left ("accelerator-daemon: process identity probe failed for pid " ++ pid ++ ": " ++ err)
        Right (ExitFailure 1, out, err)
            | not (isWindows (hcSubstrate cfg)) && null (trim (out ++ err)) -> Right False
        Right (ExitFailure n, _, err) -> Left ("accelerator-daemon: process identity probe failed for pid " ++ pid ++ " (exit " ++ show n ++ "): " ++ err)
        success -> Right (hostDaemonIdentityMatches (isWindows (hcSubstrate cfg)) daemonExe success)
  where
    trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

hostDaemonIdentityMatches :: Bool -> FilePath -> Either String (ExitCode, String, String) -> Bool
hostDaemonIdentityMatches windows daemonExe result = case result of
    Right (ExitSuccess, out, _) ->
        if windows
            then case filter (not . null) (map trim (lines out)) of
                observedExe : observedCommand : _ ->
                    map toLower (normalise observedExe) == map toLower (normalise daemonExe)
                        && commandMatches True observedCommand
                _ -> False
            else commandMatches False (trim out)
    _ -> False
  where
    trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
    commandMatches caseInsensitive observed =
        let normalize = if caseInsensitive then map toLower else id
            actual = normalize (trim observed)
            bare = normalize (daemonExe ++ " service run")
            quotedExe = normalize ("\"" ++ daemonExe ++ "\" service run")
            quotedArgs = normalize (daemonExe ++ " \"service\" \"run\"")
            quotedExeAndArgs = normalize ("\"" ++ daemonExe ++ "\" \"service\" \"run\"")
         in actual `elem` [bare, quotedExe, quotedArgs, quotedExeAndArgs]

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    when exists (removeFile path)

{- | Poll a URL by folding a 'reachLeaf' (@curl@) into @frame@ via the
self-reference lift, so the probe runs in the frame where the NodePort is
published. The @expose-port@ step passes 'localContext' (it already runs in the
@vm-project-container@ frame, @--network=host@, so @localhost@ is the VM's); the
harness passes the VM frame ('demoVMFrameContext'), so the same probe folds to
@incus exec \<vm\> -- curl …@ on Linux and @limactl shell \<vm\> -- curl …@ on
Apple Silicon — correct on both providers, with no dependency on host port
forwarding. Bounded by @n@ five-second attempts.
-}
waitWebReachable :: HostConfig -> LiftContext -> String -> Int -> IO Bool
waitWebReachable cfg frame url n = do
    outcome <- pollUntilReady (reachPoll `withAttempts` n) url (reachProbe frame url) cfg
    pure (either (const False) (const True) outcome)

demoConfigContext :: Context.CommandClass -> [Context.Capability] -> (ProjectConfig -> Context.BinaryContext -> IO a) -> IO a
demoConfigContext =
    withSiblingProjectConfigContext (T.pack demoProject)

demoContext :: Context.CommandClass -> [Context.Capability] -> (Context.BinaryContext -> IO a) -> IO a
demoContext cls caps =
    demoConfigContext cls caps . const

demoAction :: Context.CommandClass -> [Context.Capability] -> IO a -> IO a
demoAction cls caps body =
    demoContext cls caps (const body)

resourcesFromContext :: Context.BinaryContext -> Resources
resourcesFromContext ctx =
    let envelope = Context.resourceEnvelope ctx
     in Resources (Context.cpu envelope) (Context.memory envelope) (Context.storage envelope)

{- | The full demo lifecycle pulls the large base image, builds the project
image, and duplicates layers through kind. Smaller budgets fail late in
Docker extraction, so reject them before launching the VM. This is the **one
ceiling** — the budget — used **once** as the VM wall (§ O).
-}
demoFullLifecycleResources :: Resources
demoFullLifecycleResources = demoDefaultResources

{- | The in-VM cluster cordon (cordon #2): a slice **strictly smaller than the
budget in every dimension** (§ O), leaving the budget-sized VM (cordon #1, the
wall) headroom for its OS, the Docker daemon, and the multi-GB image builds. The
budget is the one ceiling, used once as the VM wall; the cluster fits **inside**
it. The budget is **never** added to itself — there is no budget-sized VM
"headroom" that sizes the VM above the ceiling (the superseded
@vmSizingWithHeadroom@, see legacy-tracking-for-deletion.md).
-}
clusterSliceOfBudget :: Resources -> Either String Resources
clusterSliceOfBudget r = do
    b <- budgetFromResources (envelopeOfResources r)
    let memGiB = gibibytes (budgetMemoryBytes b)
        storeGiB = gibibytes (budgetStorageBytes b)
        -- Scale the reserve with the budget rather than subtracting a fixed 4 GiB:
        -- a bigger VM wall leaves the VM OS + Docker + the multi-GB image builds
        -- proportionally more headroom (≥ 4 GiB / ≥ 40 GiB floors), so the slice
        -- stays strictly inside the wall and the kind node (whose swap headroom is
        -- 2× its RAM, `kindNodeCordonArgs`) does not OOM on a large `kind load`/push.
        memReserve = max 4 (memGiB `div` 4)
        storeReserve = max 40 (storeGiB `div` 2)
        sliceCpu = if budgetCpu b > 1 then budgetCpu b - 1 else 1
        sliceMem = max 2 (memGiB - memReserve)
        sliceStore = max 10 (storeGiB - storeReserve)
    pure
        ( Resources
            sliceCpu
            (T.pack (show sliceMem ++ "GiB"))
            (T.pack (show sliceStore ++ "GiB"))
        )

{- | On Windows the WSL2 swap file (sized to the memory budget) lands on the system
drive alongside the distro's vhdx, so the storage preflight must reserve room for
vhdx **+** swap. Returns the budget resources with storage bumped by the memory
(swap) size; off-Windows callers skip this and preflight the plain budget. Pure.
-}
withWsl2SwapStorage :: Resources -> Either String Resources
withWsl2SwapStorage r@(Resources c m _) = do
    b <- budgetFromResources (envelopeOfResources r)
    let store = gibibytes (budgetStorageBytes b) + gibibytes (budgetMemoryBytes b)
    pure (Resources c m (T.pack (show store ++ "GiB")))

{- | A case's live environment: the resolved host config, the **VM frame** lift
context (so every assertion reaches the live persistent stack @project up@ brought
up by folding its probe into the frame where the NodePort is published — the VM —
correct on both Lima and Incus via the self-reference lift, § U), and the active
variant's expected @message@ (Sprint 20.3), which the polymorphic Playwright
asserts the SPA renders.
-}
data CaseEnv = CaseEnv HostConfig LiftContext T.Text

{- | The demo's **stack-driven** test suite (development_plan_standards § W, § Z):
it drives the **real** @project up@ under a test config and asserts against the
live persistent stack, then tears it down with @project destroy@. There is **no
second cluster-bring-up path** — the deleted @demoSeams@ mirror (which stood up an
isolated per-case kind cluster via @clusterCreate@ → @kind load@ → @deployChart@)
is gone; the harness reuses the chain the deploy uses. The three cases share the
one stack @project up@ brings up.
-}
demoTestSuite :: TestSuite
demoTestSuite =
    TestSuite
        demoTestSafety
        demoTestUp
        demoCases
        demoAssert
        demoTestDown

{- | The two hard fail-fast safety preconditions (§ Z): never overwrite a
production config, never touch a running production cluster. Checked before any
bring-up; if either holds, no tests run.
-}
demoTestSafety :: IO (Either String ())
demoTestSafety = do
    cfg <- resolveHostConfig
    root <- getCurrentDirectory
    -- The production-config existence precondition checks the **executable
    -- sibling** <project>.dhall (the path the harness generates the run config
    -- at), not the cwd — so `test run` refuses to overwrite a real config but
    -- correctly generates its own. The running-cluster precondition still keys
    -- off the cwd-rooted production plan.
    cfgPath <- siblingProjectConfigPath (T.pack demoProject)
    let prodPlan
            | substrateName (hcSubstrate cfg) == LinuxGpu = resolvePlanWithDriver demoProject root Production NvkindDriver
            | otherwise = resolvePlan demoProject root Production
    testSafetyPreconditions
        cfgPath
        (productionClusterRunning cfg prodPlan)

{- | The "production cluster running" safety probe (§ Z), folded into the VM frame
so it actually fires. The demo's cluster lives **inside** the provider VM, so a
metal @kind get clusters@ never sees it (the reopened phase-10 gap: the probe was a
structural no-op). This checks the metal kind (for a hypothetical no-VM path) **and**
whether the managed provider VM exists — an existing VM is an operator's live stack
(or a crashed run's leftover) whose in-VM cluster the harness must not disturb, so a
present VM refuses the run. The operator tears it down first (@project destroy@, or
@wsl --unregister@ for a crashed WSL2 run). This is also the demo's spatial-isolation
guard: because the cluster and its NodePorts are the VM's, a metal port is never a
collision — a second run is refused by the existing VM (and by the sibling-config
precondition), so runs are mutually exclusive rather than racing.
-}
productionClusterRunning :: HostConfig -> ClusterPlan -> IO Bool
productionClusterRunning cfg plan
    | substrateName (hcSubstrate cfg) == LinuxGpu =
        if toolPresent cfg Docker then directClusterExists cfg plan else pure False
    | otherwise = do
        sp <- demoProvider cfg
        case spExists sp of
            ExistsProbe tool _ _
                | toolPresent cfg tool -> substrateExists cfg sp
                | otherwise -> pure False

{- | The direct lane has no Incus provider. Refuse the harness whenever Docker
still has the managed kind/nvkind control-plane, running or stopped.
-}
directClusterExists :: HostConfig -> ClusterPlan -> IO Bool
directClusterExists cfg plan
    | not (toolPresent cfg Docker) =
        die "test safety: Docker CLI is unavailable, so the direct production-cluster precondition cannot be proven"
    | otherwise = do
        result <- runTool cfg Docker ["ps", "-a", "--format", "{{.Names}}"]
        either die pure (directClusterPresence (clusterNodeNames plan) result)

{- | Fail-closed classifier for the direct harness safety probe. A missing Docker
CLI means no Docker-backed production stack can exist and is handled by the
caller; once the CLI is present, daemon/probe errors are ambiguous and must
refuse the test rather than hiding a stopped control-plane or worker.
-}
directClusterPresence :: [String] -> Either String (ExitCode, String, String) -> Either String Bool
directClusterPresence expected result = case result of
    Right (ExitSuccess, out, _) -> Right (any (`elem` lines out) expected)
    Right (ExitFailure n, _, err) -> Left ("test safety: Docker cluster probe failed (exit " ++ show n ++ "): " ++ err)
    Left err -> Left ("test safety: Docker cluster probe failed: " ++ err)

{- | Bring the test stack up by driving the **real** @project up@ (the same chain
interpreter production uses, § W) through the binary's self-reference (§ U), then
resolve the assertion env (the live Production stack the cases assert against).
One @project up@ per variant; the variant @label@ (its expected served message) is
threaded into the 'CaseEnv' so the assertions can check the SPA renders it (Sprint
20.3).
-}
demoTestUp :: T.Text -> IO CaseEnv
demoTestUp label = do
    self <- getExecutablePath
    putStrLn ("test run: bringing the stack up via the real `project up` (variant message=" ++ T.unpack label ++ ")")
    withHarnessMutationGuard (runSelfOrDie self ["project", "up"])
    cfg <- resolveHostConfig
    pure (CaseEnv cfg (demoTestFrameContext (hcSubstrate cfg)) label)

{- | Tear the test stack down by driving @project destroy@ (best-effort, so a
partial stack always tears down; host @.data@ is preserved by the lifecycle, § O).
Env-independent (§ Y): @project destroy@ re-detects the stack itself, so the harness
can run this even after a failed @project up@ — the guaranteed-teardown path.
-}
demoTestDown :: IO ()
demoTestDown = do
    self <- getExecutablePath
    putStrLn "test run: tearing the stack down via `project destroy`"
    runSelfOrDie self ["project", "destroy"]
    verifyHarnessTeardown

harnessMutationGuardEnv :: String
harnessMutationGuardEnv = "HOSTBOOTSTRAP_DEMO_HARNESS_MUTATION_GUARD"

{- | Mark the child @project up@ so its post-ensure safety check can distinguish
a harness bring-up (which must never reconcile pre-existing state) from an
operator's idempotent production reconcile. Restore the caller's environment
exactly after the child exits.
-}
withHarnessMutationGuard :: IO a -> IO a
withHarnessMutationGuard body = do
    previous <- lookupEnv harnessMutationGuardEnv
    setEnv harnessMutationGuardEnv "1"
    body `finally` maybe (unsetEnv harnessMutationGuardEnv) (setEnv harnessMutationGuardEnv) previous

{- | A green variant requires a proven-empty teardown, not merely a zero exit
from best-effort lifecycle cleanup.
-}
verifyHarnessTeardown :: IO ()
verifyHarnessTeardown = do
    cfg <- resolveHostConfig
    root <- getCurrentDirectory
    let daemonDir = root </> ".build" </> "accelerator-daemon"
        daemonPid = daemonDir </> "hostbootstrap-demo.accelerator.pid"
        daemonOwner = daemonDir </> "hostbootstrap-demo.accelerator.owner"
        daemonOperation = daemonDir </> "hostbootstrap-demo.accelerator.operation"
    pidRemaining <- doesFileExist daemonPid
    ownerRemaining <- doesDirectoryExist daemonOwner
    operationRemaining <- doesDirectoryExist daemonOperation
    when (pidRemaining || ownerRemaining || operationRemaining) $
        die "test teardown: host accelerator daemon ownership/PID/operation state remains after project destroy"
    if substrateName (hcSubstrate cfg) == LinuxGpu
        then do
            unless (toolPresent cfg Docker) $
                die "test teardown: Docker is unavailable, so absence of the direct nvkind stack cannot be proven"
            let plan = resolvePlanWithDriver demoProject root Production NvkindDriver
            remaining <- directClusterExists cfg plan
            when remaining (die "test teardown: the direct nvkind stack still exists after project destroy")
        else do
            provider <- demoProvider cfg
            case spExists provider of
                ExistsProbe tool _ _ ->
                    unless (toolPresent cfg tool) $
                        die "test teardown: the provider probe is unavailable, so VM deletion cannot be proven"
            remaining <- substrateExists cfg provider
            when remaining (die ("test teardown: managed VM still exists after project destroy: " ++ spVmId provider))
            when (isWindows (hcSubstrate cfg)) $ do
                handles <- demoVMHandles
                backupRemaining <- doesFileExist (vmhWslConfigPath handles ++ ".hostbootstrap-demo.bak")
                when backupRemaining (die "test teardown: the original .wslconfig backup remains; restoration was not completed")

{- | The per-case assertions against the live persistent stack @project up@ brought
up. Every case runs in the **VM frame** (the frame where the NodePort is
published), folded there by the self-reference lift (§ U): the reachability checks
probe via 'reachLeaf' and the Playwright e2e via a raw @bash -lc@ leaf. Because the
frame is the VM on every provider, all three pass on both Lima and Incus without
any provider-specific assertion code.
-}
demoAssert :: CaseEnv -> Case -> IO CaseResult
demoAssert (CaseEnv cfg frame expectedMessage) c = case caseId c of
    "pristine-bootstrap" -> assertReachable cfg frame "http://localhost:30080/api/budget" "the in-cluster webservice"
    "web-build" -> assertReachable cfg frame "http://localhost:30080/app.js" "the esbuild SPA bundle"
    "e2e-tabs" -> assertE2EInVM cfg frame expectedMessage
    "registry-persistence" -> assertRegistrySurvivesRestart cfg frame
    other -> pure (Fail ("unknown demo case: " ++ other))

{- | Reachability assertion: poll the endpoint from @frame@ (the VM frame, where
the NodePort lives) via the lifted 'reachLeaf' probe, passing when it answers.
-}
assertReachable :: HostConfig -> LiftContext -> String -> String -> IO CaseResult
assertReachable cfg frame url what = do
    ok <- waitWebReachable cfg frame url 12
    pure (if ok then Pass else Fail (what ++ " was not reachable at " ++ url))

{- | The Playwright e2e, lifted into @frame@ (the VM) via a raw @bash -lc@ leaf:
run the base-provided Playwright from a container on the VM host network against
the NodePort the VM publishes on its own @localhost@. The variant's
@expectedMessage@ is passed as @-e EXPECTED_MESSAGE@ (Sprint 20.4), so the
polymorphic spec asserts the SPA's @#message@ element renders the config-driven
message for this variant. Captures the result rather than dying, so a failure is a
case 'Fail' (not a crashed matrix).
-}
assertE2EInVM :: HostConfig -> LiftContext -> T.Text -> IO CaseResult
assertE2EInVM cfg frame expectedMessage = do
    expectation <- resolveAcceleratorE2E cfg frame
    case expectation of
        Left failMsg -> pure (Fail failMsg)
        Right mBackend -> do
            let acceleratorEnv = case mBackend of
                    Nothing -> ""
                    Just backend -> " -e EXPECTED_ACCELERATOR_BACKEND=" ++ shellQuote (T.unpack backend)
                script =
                    "docker run --rm --network host --entrypoint sh -e BASE_URL=http://localhost:30080 -e EXPECTED_MESSAGE="
                        ++ shellQuote (T.unpack expectedMessage)
                        ++ acceleratorEnv
                        ++ " -e NODE_PATH="
                        ++ baseNodeModulesPath
                        ++ " "
                        ++ demoProjectImage
                        ++ " -lc 'cd /workspace/demo/playwright && playwright test'"
            result <- liftLeaf cfg frame (RawCmd ["bash", "-lc", script])
            pure $ case result of
                Right (ExitSuccess, _, _) -> Pass
                Right (ExitFailure n, out, err) -> Fail ("e2e failed (exit " ++ show n ++ "):\n" ++ boundedDiagnostic (err ++ out))
                Left err -> Fail ("e2e: " ++ err)
  where
    boundedDiagnostic output =
        let meaningful = dropWhile isSpace output
         in if null meaningful
                then "(no subprocess output)"
                else reverse (take 4000 (reverse meaningful))

{- | Resolve the accelerator e2e expectation for the detected substrate, folded
into the same VM frame the e2e runs in. A lane WITH a daemon backend must have a
daemon actually serving before the browser e2e asserts the real add result, so we
poll the ingress first — @/api/accelerator/add@ answers HTTP 200 only when a
connected daemon returns a success (503 otherwise, § AA / accelerator_daemon.md),
so a passing @curl -f@ probe is proof the whole daemon path (worker build →
WebSocket connect → CBOR round-trip) is live. Returns:

  * @Right Nothing@  — no accelerator lane on this substrate (windows-cpu): the
    e2e keeps the no-in-process-fallback "unavailable" assertion.
  * @Right (Just b)@ — a daemon is serving; the e2e asserts the real sum, the
    backend @b@, and a non-empty artifact hash (a fake in-process path cannot pass).
  * @Left msg@       — a lane exists but no daemon became ready in time: a real
    failure (the accelerator path is broken), surfaced as a case 'Fail'.

The host-resident daemon (Apple Silicon / Windows GPU) is started by the chain's
@accelerator-daemon@ post-handoff step during @project up@ (§ Y), so by the time the
harness runs @e2e-tabs@ it is already building/connecting; in-cluster daemon lanes
(Linux CPU/GPU) start their pod during @deploy-chart@.
-}
resolveAcceleratorE2E :: HostConfig -> LiftContext -> IO (Either String (Maybe T.Text))
resolveAcceleratorE2E cfg frame =
    case acceleratorBackendForSubstrate (hcSubstrate cfg) of
        Left _ -> pure (Right Nothing)
        Right backend -> do
            putStrLn "e2e: waiting for the accelerator daemon to build its worker and connect…"
            ready <- waitWebReachable cfg frame acceleratorProbeUrl acceleratorReadyAttempts
            pure $
                if ready
                    then Right (Just (backendName backend))
                    else Left ("e2e: the accelerator daemon never served a result at " ++ acceleratorProbeUrl)
  where
    -- The add endpoint answers 200 only when a daemon computes the sum; the probe
    -- values match the SPA defaults the e2e submits (1.5 + 2.25 = 3.75).
    acceleratorProbeUrl = "http://localhost:30080/api/accelerator/add?requestId=e2e-probe&left=1.5&right=2.25"
    -- 60 × 5 s (reachPoll) ≈ 5 min ceiling — ample for ensure (a verified no-op when
    -- present) + the tiny worker build + the WebSocket connect.
    acceleratorReadyAttempts = 60

{- | The @registry-persistence@ case — the MinIO-backing proof. Confirm the pushed
image's @tags/list@ is reachable (200), delete the registry pod and wait its
rollout, then confirm @tags/list@ is reachable AGAIN. With the old ephemeral
pod-filesystem storage the restarted registry would be empty (@tags/list@ 404, which
'reachLeaf'\'s @curl -f@ reports as unreachable); MinIO-backed, the new pod re-reads
the blobs from the bucket and it stays 200. Reuses the VM-frame lift so the probe and
the @kubectl@ restart both run where the NodePort is published. Runs last in the case
matrix and leaves a healthy registry pod (it waits the new rollout Ready).
-}
assertRegistrySurvivesRestart :: HostConfig -> LiftContext -> IO CaseResult
assertRegistrySurvivesRestart cfg frame = do
    let tagsUrl = "http://" ++ registryEndpoint ++ "/v2/library/hostbootstrap-demo/tags/list"
        node = demoProject ++ "-control-plane"
        restart =
            "docker exec "
                ++ node
                ++ " kubectl delete pod -l app=registry --wait=true"
                ++ " && docker exec "
                ++ node
                ++ " kubectl rollout status deployment/registry --timeout=120s"
    before <- waitWebReachable cfg frame tagsUrl 6
    if not before
        then pure (Fail ("registry-persistence: pushed image not present before restart at " ++ tagsUrl))
        else do
            _ <- liftLeaf cfg frame (RawCmd ["bash", "-lc", restart])
            after <- waitWebReachable cfg frame tagsUrl 24
            pure $
                if after
                    then Pass
                    else Fail "registry-persistence: the pushed image was LOST after a registry pod restart (storage is not durable)"

-- | Run the binary's own subcommand (the self-reference, § U), dying on failure.
runSelfOrDie :: FilePath -> [String] -> IO ()
runSelfOrDie self args = do
    (code, out, err) <- readProcessWithExitCode self args ""
    unless (null out) (putStr out)
    case code of
        ExitSuccess -> pure ()
        ExitFailure n
            | safetyRefusalMarker `isInfixOf` err -> throwIO (SafetyRefusal err)
            | otherwise -> die (self ++ " " ++ unwords args ++ " failed (exit " ++ show n ++ ")\n" ++ err)

{- | The project image carries both the served demo app and the base image's
Playwright installation, so the e2e runner never pulls an external Playwright
image and stays native to the platform the project image was built for.
-}
demoProjectImage :: String
demoProjectImage = "hostbootstrap-demo:local"

{- | The base image installs Playwright globally. Node needs this search path
when a project-local spec imports @\@playwright/test@ without a local
@node_modules@ tree.
-}
baseNodeModulesPath :: String
baseNodeModulesPath = "/opt/build/node/global/lib/node_modules"

{- | The managed demo VM name is composed from the project identity. All
providers use the same name, and destructive teardown is guarded by the project
name prefix, so hostbootstrap-demo never targets a user's unrelated VM or WSL2
distro.
-}
demoManagedVMName :: String
demoManagedVMName = demoProject ++ "-vm"

demoVM :: IncusVM
demoVM = IncusVM demoManagedVMName "images:ubuntu/24.04"

demoLimaVM :: LimaVM
demoLimaVM = LimaVM demoManagedVMName

demoWsl2VM :: Wsl2VM
demoWsl2VM = Wsl2VM demoManagedVMName

{- | The name-prefix delete-guard for the demo's VM namespace; @vm down@ will
only destroy a VM/profile whose name starts with this.
-}
demoGuardPrefix :: String
demoGuardPrefix = demoProject

{- | The demo's service-handler registry (§ AA): @service run@ maps the effective
config's @Web@ or @Accelerator@ 'ServiceType' to the corresponding internal key,
then dispatches to the warp/wai webservice or accelerator daemon. The @service run@
context gate has already validated the service-role @<project>.dhall@ (the
ConfigMap-delivered cluster-service or daemon config, § X) before the handler
runs, so the handler is just the role body.
-}
demoServices :: ServiceRegistry
demoServices =
    [ ServiceHandler "web" serveWeb
    , ServiceHandler "accelerator" serveAcceleratorDaemon
    ]

-- ---------------------------------------------------------------------------
-- Metal-host orchestration helpers.
-- ---------------------------------------------------------------------------

{- | Detect the current frame's substrate and resolve its host tool
configuration. The demo binary runs this in every frame (metal, VM, and
container), so it resolves whichever host it currently executes on — not
only the metal orchestrator.
-}
resolveHostConfig :: IO HostConfig
resolveHostConfig = do
    detected <- detect
    either die buildHostConfig detected

{- | The demo's VM handles for every substrate: the per-provider VM identities,
the delete-guard prefix, and the resolved global @.wslconfig@ path (used only on
Windows). 'demoStaticVMHandles' is the pure form for the lift-layer selection
('demoVMFrameContext'); 'demoVMHandles' resolves the real @.wslconfig@ path for
the lifecycle IO.
-}
mkDemoVMHandles :: FilePath -> VMHandles
mkDemoVMHandles wslConfigPath =
    VMHandles
        { vmhIncus = demoVM
        , vmhLima = demoLimaVM
        , vmhWsl2 = demoWsl2VM
        , vmhGuardPrefix = demoGuardPrefix
        , vmhWslConfigPath = wslConfigPath
        }

demoStaticVMHandles :: VMHandles
demoStaticVMHandles = mkDemoVMHandles ""

demoVMHandles :: IO VMHandles
demoVMHandles = do
    home <- getHomeDirectory
    pure (mkDemoVMHandles (home </> ".wslconfig"))

{- | The one pure lift into the current substrate (Lima on Apple Silicon, Incus
on Linux, WSL2 on Windows), selected once and interpreted generically by the
lifecycle helpers below ('substrateExists' / 'runLaunch' / 'substrateWait' /
'stageSource' / 'demoTeardown'). Replaces the former hand-branched
@DemoVMProvider@ with the single pure 'SubstrateProvider' value, so per-substrate
knowledge lives in one place ('selectSubstrateProvider').
-}
demoProvider :: HostConfig -> IO SubstrateProvider
demoProvider cfg = do
    handles <- demoVMHandles
    either die pure (selectSubstrateProvider (hcSubstrate cfg) handles)

{- | Run a list of pure host effects, dying on the first failure (the launch /
staging path). 'WriteHostFile' backs up any existing file once (the global
@.wslconfig@ is a user file); 'RestoreHostFile' is the teardown inverse.
-}
runEffects :: HostConfig -> [HostEffect] -> IO ()
runEffects cfg = mapM_ go
  where
    go (RunHostTool tool args) = runOrDie cfg tool args
    go (WriteHostFile path content) = writeHostFileWithBackup path content
    go (MergeWslConfig path body) = mergeWslConfigWithBackup path body
    go (RestoreHostFile path) = restoreHostFile path

{- | Run teardown effects best-effort under one intent message: a missing or
already-stopped VM is not a failure for idempotent teardown.
-}
runEffectsBestEffort :: HostConfig -> String -> [HostEffect] -> IO ()
runEffectsBestEffort cfg intent = mapM_ go
  where
    go (RunHostTool tool args) = bestEffortTool cfg tool args intent
    go (RestoreHostFile path) = restoreHostFile path
    go (WriteHostFile path content) = writeHostFileWithBackup path content
    go (MergeWslConfig path body) = mergeWslConfigWithBackup path body

{- | Write @content@ to @path@, first backing up any existing file to
@<path>.hostbootstrap-demo.bak@ (once), so the global @.wslconfig@ the WSL2
cordon writes never clobbers a user's own file irretrievably.
-}
writeHostFileWithBackup :: FilePath -> String -> IO ()
writeHostFileWithBackup path content = do
    backupHostFileOnce path
    writeFile path content
    putStrLn ("vm up: wrote the WSL2 resource cordon to " ++ path)

{- | Merge the WSL2 @[wsl2]@ cordon body into the global @.wslconfig@ **without
clobbering** the user's other sections (the pure 'mergeWslConfig'), backing up the
original once so @project down@/@destroy@ can restore it. When a leftover backup is
found on this @project up@ (a prior run that never restored — a crash-recoverable
case, § C), the original @.wslconfig@ is preserved as-is (backup-once keeps the
true original) and the merge re-applies our block idempotently.
-}
mergeWslConfigWithBackup :: FilePath -> [String] -> IO ()
mergeWslConfigWithBackup path body = do
    let bak = path ++ ".hostbootstrap-demo.bak"
    bakExists <- doesFileExist bak
    when bakExists (putStrLn ("vm up: found leftover " ++ bak ++ " from a prior run; preserving the original and re-applying the cordon"))
    existing <- do
        exists <- doesFileExist path
        if exists then readFile path else pure ""
    backupHostFileOnce path
    -- @readFile@ is lazy; force it before the write so we do not truncate the file
    -- mid-read. 'length' fully evaluates @existing@ (already forced by the backup
    -- copy above, but explicit here for the no-backup path).
    length existing `seq` writeFile path (mergeWslConfig existing body)
    putStrLn ("vm up: merged the WSL2 resource cordon into " ++ path ++ " (other sections preserved)")

{- | Back up @path@ to @<path>.hostbootstrap-demo.bak@ exactly once — the first
time we touch a pre-existing global @.wslconfig@ — so the backup always holds the
user's true original across idempotent re-applies, and never overwrites it with an
already-cordoned copy from a re-run.
-}
backupHostFileOnce :: FilePath -> IO ()
backupHostFileOnce path = do
    let bak = path ++ ".hostbootstrap-demo.bak"
    exists <- doesFileExist path
    bakExists <- doesFileExist bak
    when (exists && not bakExists) (copyFile path bak)

{- | Restore @path@ from its backup (or remove it if there was none). Copy before
deleting the backup so a failed restore preserves the user's original bytes;
failures propagate and make teardown non-green.
-}
restoreHostFile :: FilePath -> IO ()
restoreHostFile path = do
    let bak = path ++ ".hostbootstrap-demo.bak"
    bakExists <- doesFileExist bak
    if bakExists
        then do
            copyFile bak path
            removeFile bak
            putStrLn ("project destroy: restored " ++ path)
        else do
            exists <- doesFileExist path
            when exists (removeFile path >> putStrLn ("project destroy: removed " ++ path))

-- | Probe whether the provider's VM already exists (idempotent reconcile).
substrateExists :: HostConfig -> SubstrateProvider -> IO Bool
substrateExists cfg sp =
    case spExists sp of
        ExistsProbe tool args membership -> do
            r <- runTool cfg tool args
            case r of
                Right (ExitSuccess, out, _) -> pure (spVmId sp `elem` membersOf membership out)
                Right (ExitFailure n, _, err) ->
                    die ("provider existence probe failed for " ++ spVmId sp ++ " (exit " ++ show n ++ "): " ++ err)
                Left err -> die ("provider existence probe failed for " ++ spVmId sp ++ ": " ++ err)

{- | Poll the provider's readiness probe until the VM answers, bounded by @n@
two-second attempts (the substrate-generic peer of the former per-provider
@waitVMAgent@ / @waitLimaVM@ / @waitWsl2VM@).
-}
substrateWait :: HostConfig -> SubstrateProvider -> IO (Ready VMReady)
substrateWait cfg sp = do
    outcome <- awaitReady vmBootPoll ("vm up: " ++ spVmId sp) probe cfg
    either (const (die ("vm up: " ++ spVmId sp ++ " did not become ready"))) pure outcome
  where
    probe = case spWait sp of
        WaitProbe tool args -> exitZeroProbe tool args

{- | Keep only the FILE effects of a launch effect list (the WSL2 @.wslconfig@
merge/restore) — used to re-apply the cordon on the idempotent reconcile path
without re-running the one-time @wsl --shutdown@/@--install@ tool effects.
-}
fileEffectsOnly :: [HostEffect] -> [HostEffect]
fileEffectsOnly = filter isFile
  where
    isFile (MergeWslConfig _ _) = True
    isFile (WriteHostFile _ _) = True
    isFile (RestoreHostFile _) = True
    isFile (RunHostTool _ _) = False

{- | Disclose that applying the WSL2 @.wslconfig@ ceiling runs @wsl --shutdown@ — a
global cross-distro side-effect (the historical @0x80072746@ session-drop surface):
it briefly stops every running WSL2 distro, which then restart on next use.
-}
discloseWslShutdown :: IO ()
discloseWslShutdown =
    putStrLn
        "vm up: NOTE — applying the WSL2 .wslconfig ceiling runs `wsl --shutdown`, a GLOBAL cross-distro side-effect that briefly stops ALL running WSL2 distros (they restart on next use); the utility VM then restarts with the budget ceiling in effect."

{- | Wait for a real **network** condition inside the VM, not just the guest agent
answering (§ C): let cloud-init finish if present (Incus), then require DNS to
resolve the apt mirror, so the first in-VM @apt@/@ghcup@/@curl@ step of the
pristine bootstrap cannot race a not-yet-configured network. Bounded by @n@
three-second attempts.
-}
waitVMNetwork :: Ready VMReady -> HostConfig -> SubstrateProvider -> IO ()
waitVMNetwork _vmReady cfg sp =
    case vmShellArgs (spLiftLayer sp) ["bash", "-lc", netProbe] of
        Nothing -> pure ()
        Just (tool, args) -> do
            outcome <- pollUntilReady networkPoll ("vm up: " ++ spVmId sp ++ " network") (exitZeroProbe tool args) cfg
            either
                (const (die ("vm up: " ++ spVmId sp ++ " network did not come up (DNS still unresolved)")))
                (const (putStrLn ("vm up: " ++ spVmId sp ++ " network is up")))
                outcome
  where
    netProbe =
        "command -v cloud-init >/dev/null 2>&1 && timeout 90 sudo cloud-init status --wait >/dev/null 2>&1; "
            ++ "getent hosts archive.ubuntu.com >/dev/null 2>&1"

{- | Poll @docker info@ inside the VM until the daemon answers (§ C), bounded by
@n@ two-second attempts, after @systemctl enable --now docker@ + the socket ACL —
so build #3 does not race a socket/ACL that is not yet live. The retry lives in
Haskell (not an inline shell loop) so the probe stays a simple
@docker info >/dev/null 2>&1@ that survives the Windows PowerShell→wsl→bash quoting
path.
-}
waitDockerReady :: HostConfig -> SubstrateProvider -> IO (Ready DockerDaemon)
waitDockerReady cfg provider =
    case vmShellArgs (spLiftLayer provider) ["bash", "-lc", "docker info >/dev/null 2>&1"] of
        Nothing -> die ("waitDockerReady: " ++ spVmId provider ++ " is not a VM frame")
        Just (tool, args) -> do
            outcome <- awaitReady dockerPoll ("pristine-bootstrap: docker daemon in " ++ spVmId provider) (exitZeroProbe tool args) cfg
            daemon <-
                either
                    (const (die ("pristine-bootstrap: docker daemon in " ++ spVmId provider ++ " did not become ready")))
                    pure
                    outcome
            putStrLn ("pristine-bootstrap: docker daemon ready in " ++ spVmId provider)
            pure daemon

{- | Build #3 — the project container FROM the base — gated on the @Ready DockerDaemon@
witness so it cannot run before 'waitDockerReady' observed the in-VM daemon answering
(pushing the build without that proof is a type error). An authenticated host Docker Hub
login is forwarded on @stdin@; otherwise the base pulls anonymously.
-}
buildProjectImage :: Ready DockerDaemon -> HostConfig -> SubstrateProvider -> Maybe RegistryAuth -> String -> IO ()
buildProjectImage _dockerReady cfg provider mAuth buildImageScript =
    case mAuth of
        Just auth -> do
            putStrLn "pristine-bootstrap: build #3 — the project container FROM the base (authenticating the pull with the forwarded Docker Hub credential)"
            runBuildImageReporting cfg provider (dockerAuthStdinWrapper buildImageScript) (T.unpack (registryConfigPayload auth))
        Nothing -> do
            putStrLn "pristine-bootstrap: no host Docker Hub login found — build #3 pulls the base anonymously (Docker Hub rate limits may apply). Run `docker login` on the host (the standalone Docker CLI writes an inline token) for an authenticated, forwarded pull."
            putStrLn "pristine-bootstrap: build #3 — the project container FROM the pulled base (repo-root context, L0-direct; anonymous pull)"
            runBuildImageReporting cfg provider buildImageScript ""

{- | Run the in-VM build #3 (project container) and, on failure, STREAM the captured
build output to the metal binary's line-buffered stdout before dying. Build #3's
@docker build@ output would otherwise be swallowed: 'runOrDieStdin' surfaces it via a
@die@ to stderr, but the recursive @project up@ handoff + 'applyChain'\'s
best-effort-teardown exception handler + the harness's per-variant failure handling
unwind that stderr before it reaches the run log, leaving a bare "chain failed" with no
cause. Printing the captured output on stdout (line-buffered, flushed) makes a build #3
failure (base pull, the in-Dockerfile @check-code@ gate, or the web build) diagnosable
in the run log (§ C).
-}
runBuildImageReporting :: HostConfig -> SubstrateProvider -> String -> String -> IO ()
runBuildImageReporting cfg provider script input =
    case vmShellArgs (spLiftLayer provider) ["bash", "-lc", script] of
        Nothing -> die ("runInDemoVM: " ++ spVmId provider ++ " is not a VM frame")
        Just (tool, args) -> do
            result <- runToolWithStdin cfg tool args input
            case result of
                Right (ExitSuccess, out, _) -> unless (null out) (putStr out)
                Right (ExitFailure n, out, err) -> do
                    putStrLn ("pristine-bootstrap: build #3 FAILED (exit " ++ show n ++ "); captured build output follows:")
                    unless (null out) (putStr out)
                    unless (null err) (putStr err)
                    hFlush stdout
                    die ("pristine-bootstrap: build #3 (project container) failed (exit " ++ show n ++ ")")
                Left e -> die ("pristine-bootstrap: build #3 could not run: " ++ e)

vmRepoRoot :: FilePath
vmRepoRoot = "/root/hostbootstrap"

vmDemoRoot :: FilePath
vmDemoRoot = vmRepoRoot ++ "/demo"

{- | Where the project source lives inside the project container (the Dockerfile's
@COPY demo /workspace/demo@ + @WORKDIR@). The container-frame chain steps run
from here (for @./chart@); the minted container @<project>.dhall@ names it as
the @sourceRoot@.
-}
containerSourceRoot :: FilePath
containerSourceRoot = "/workspace/demo"

runInDemoVM :: HostConfig -> SubstrateProvider -> String -> IO ()
runInDemoVM cfg provider script = runInDemoVMStdin cfg provider script ""

{- | Like 'runInDemoVM', but pipe @stdin@ to the in-VM @bash -lc@ — the channel a
forwarded Docker Hub credential travels on (never @argv@). Used to authenticate
the in-VM base-image pull of build #3 (see 'HostBootstrap.Registry').
-}
runInDemoVMStdin :: HostConfig -> SubstrateProvider -> String -> String -> IO ()
runInDemoVMStdin cfg provider script input =
    case vmShellArgs (spLiftLayer provider) ["bash", "-lc", script] of
        Just (tool, args) -> runOrDieStdin cfg tool args input
        Nothing -> die ("runInDemoVM: " ++ spVmId provider ++ " is not a VM frame")

{- | Run a resolved host tool, streaming its stdout and dying with the captured
stderr on a non-zero exit.
-}
runOrDie :: HostConfig -> HostTool -> [String] -> IO ()
runOrDie cfg tool args = runOrDieStdin cfg tool args ""

-- | Like 'runOrDie', but feed @stdin@ to the process.
runOrDieStdin :: HostConfig -> HostTool -> [String] -> String -> IO ()
runOrDieStdin cfg tool args input = do
    result <- runToolWithStdin cfg tool args input
    case result of
        Right (ExitSuccess, out, _) -> unless (null out) (putStr out)
        Right (ExitFailure n, out, err) ->
            die
                ( toolCommandName tool
                    ++ " "
                    ++ unwords args
                    ++ " failed (exit "
                    ++ show n
                    ++ ")\n"
                    ++ out
                    ++ err
                )
        Left err -> die err

{- | Ensure a usable Incus provider (the IO behind the dissolved @incus ensure@
verb, reused by the metal chain's @ensure-the-VM-provider@ step on Linux): run
the core @ensure incus@ reconciler (install+verify — Colima-backed on Apple,
native daemon plus @incus-admin@ membership on Linux), then on Linux also ensure
the VM capability the core reconciler does not cover — the @qemu-system-x86@
machine emulator and @ovmf@ UEFI firmware incus VMs require — and restart the
daemon so it re-detects QEMU. Idempotent: a satisfied host is a verified no-op.
-}
ensureIncusProvider :: IO ()
ensureIncusProvider = do
    runEnsure Incus.reconciler
    cfg <- resolveHostConfig
    case (isLinux (hcSubstrate cfg), isAppleSilicon (hcSubstrate cfg)) of
        (True, _) -> ensureLinuxIncusVMCapability cfg
        (_, True) ->
            putStrLn $
                "incus ensure: Colima Incus profile `"
                    ++ Incus.appleIncusProfile
                    ++ "` present; Incus VMs on Apple require nested virtualization support"
        _ -> die "incus ensure: unsupported substrate after core ensure"

ensureLinuxIncusVMCapability :: HostConfig -> IO ()
ensureLinuxIncusVMCapability cfg = do
    Incus.ensureKvmAccess cfg
    putStrLn "incus ensure: ensuring the VM capability (qemu-system-x86 + ovmf)"
    runOrDie cfg Sudo ["apt-get", "install", "-y", "qemu-system-x86", "ovmf"]
    runOrDie cfg Sudo ["systemctl", "restart", "incus"]
    putStrLn "incus ensure: ensuring incusbr0 egress past Docker's FORWARD policy"
    ensureBridgeForwarding cfg
    putStrLn "incus ensure: incus + VM capability present"

{- | When Docker is installed it sets the iptables @FORWARD@ policy to @DROP@ and
accepts only its own bridges, which strands incus VMs (no egress, so the in-VM
@apt@/@ghcup@/@docker pull@ all fail). Insert an @ACCEPT@ for @incusbr0@ into
Docker's @DOCKER-USER@ hook so VM traffic is forwarded. Idempotent, and a no-op
when Docker (hence the @DOCKER-USER@ chain) is absent.
-}
ensureBridgeForwarding :: HostConfig -> IO ()
ensureBridgeForwarding cfg = mapM_ ensureRule ["-i", "-o"]
  where
    ensureRule dir =
        runOrDie
            cfg
            Sudo
            [ "bash"
            , "-c"
            , "iptables -nL DOCKER-USER >/dev/null 2>&1 || exit 0; "
                ++ "iptables -C DOCKER-USER "
                ++ dir
                ++ " incusbr0 -j ACCEPT 2>/dev/null "
                ++ "|| iptables -I DOCKER-USER "
                ++ dir
                ++ " incusbr0 -j ACCEPT"
            ]

{- | Ensure the VM provider for this substrate (the chain's
@ensure-the-VM-provider@ metal step): a Lima VM on Apple Silicon, native Incus on
Linux. The IO behind the dissolved @vm ensure@ verb.
-}
runVmEnsure :: IO ()
runVmEnsure = demoAction Context.HostOrchestratorCommand [Context.HostTools] $ do
    cfg <- resolveHostConfig
    case () of
        _
            | isAppleSilicon (hcSubstrate cfg) -> do
                runEnsure EnsureLima.reconciler
                putStrLn "vm ensure: Apple Silicon uses a Lima VM (no Incus nested VM)"
            | isLinux (hcSubstrate cfg) -> ensureIncusProvider
            | isWindows (hcSubstrate cfg) -> do
                runEnsure EnsureWsl2.reconciler
                putStrLn "vm ensure: Windows uses a WSL2 Ubuntu-24.04 distro"
            | otherwise -> die "vm ensure: unsupported substrate"

{- | The IO behind the dissolved @vm up@ verb: read the active context envelope, derive the VM sizing from
the one canonical parser, and launch the VM cordoned to it (cordon #1). The launch
is the substrate's pure 'spLaunch' effect list — a single sized argv on Apple
Silicon (Lima) and Linux (Incus); on Windows it begins by writing the global
@.wslconfig@ ceiling and @wsl --shutdown@ (the honest WSL2 wall, since WSL2 has no
per-distro @wsl --memory@/@--cpu@), then registers the distro with its VHDX cap.
-}
runVmUp :: IO ()
runVmUp = demoContext Context.HostOrchestratorCommand [Context.HostTools] $ \ctx -> do
    cfg <- resolveHostConfig
    sp <- demoProvider cfg
    let lifecycleResources = resourcesFromContext ctx
        envelope = envelopeOfResources lifecycleResources
    preflightDemoLifecycleHost cfg lifecycleResources
    -- Idempotent reconcile-to-running (§ Y): if the VM already exists, ensure it
    -- is started rather than re-creating it (a create on an existing instance
    -- fails), so a re-run of `project up` reconciles a partially-built stack.
    exists <- substrateExists cfg sp
    harnessRun <- lookupEnv harnessMutationGuardEnv
    when (harnessRun == Just "1" && exists) $
        throwIO
            ( SafetyRefusal
                ( "managed VM appeared after provider ensure; refusing to reconcile pre-existing state: "
                    ++ spVmId sp
                )
            )
    if exists
        then do
            putStrLn ("vm up: " ++ spVmId sp ++ " already exists; re-applying the cordon + ensuring it is started (idempotent)")
            -- Reconcile the cordon on the exists path (§ C): re-apply the launch's
            -- FILE effects (the WSL2 .wslconfig merge) — never the one-time install —
            -- and then 'applyReconcileCordon' actually makes the ceiling take effect: a
            -- STOPPED WSL2 distro needs a `wsl --shutdown` so it re-reads the merged
            -- instanceIdleTimeout + vmIdleTimeout ceiling on its next cold boot (a
            -- crashed-run distro left stopped would otherwise idle-stop mid-recovery),
            -- while a RUNNING one already has it live. Lima/Incus carry no launch file
            -- effects and never idle-stop, so both steps are a no-op there.
            reCordon <- either die pure (spLaunch sp envelope)
            runEffects cfg (fileEffectsOnly reCordon)
            applyReconcileCordon cfg sp
            runEffectsBestEffort cfg ("vm up: starting existing " ++ spVmId sp) (spStartExisting sp)
        else do
            launch <- either die pure (spLaunch sp envelope)
            when (isWindows (hcSubstrate cfg)) discloseWslShutdown
            putStrLn ("vm up: launching " ++ spVmId sp ++ " (cordon #1: the VM is the wall, sized to the budget)")
            runEffects cfg launch
    putStrLn ("vm up: waiting for " ++ spVmId sp ++ " to answer")
    vmReady <- substrateWait cfg sp
    putStrLn ("vm up: waiting for " ++ spVmId sp ++ " network to come up")
    waitVMNetwork vmReady cfg sp
    putStrLn ("vm up: " ++ spVmId sp ++ " is up")

{- | Shared metal-host floor/headroom gate for both VM-backed and direct Linux
GPU chains. The direct lane has no VM wall, but it still must not consume a
project budget that leaves no room for the host OS and image/cluster builds.
-}
preflightDemoLifecycleHost :: HostConfig -> Resources -> IO ()
preflightDemoLifecycleHost cfg lifecycleResources = do
    either die pure (requireDemoLifecycleResources lifecycleResources)
    resolvedCapacity <- resolveHostCapacity cfg
    preflightResources <-
        if isWindows (hcSubstrate cfg)
            then either die pure (withWsl2SwapStorage lifecycleResources)
            else pure lifecycleResources
    either die pure (resolvedCapacity >>= preflightHostBudget (envelopeOfResources preflightResources))

{- | Apply a substrate's reconcile-time cordon whose global file only takes effect
on a VM restart. No-op for Lima/Incus (@spReconcileCordon = Nothing@: their cordon
is baked into the VM at create and they never idle-stop). For WSL2: probe the
distro's running state; a RUNNING distro already booted with the cordon live, so
leave the live stack untouched (skip the global side-effect); a STOPPED distro is
safe to restart, so run the disclosed @wsl --shutdown@ — the subsequent
'substrateWait' then cold-boots the utility VM, which re-reads the merged
@[general] instanceIdleTimeout=-1@ (the key that keeps the distro instance alive) +
@[wsl2] vmIdleTimeout=-1@. This is what makes an idempotent @project up@ reconcile of a
crashed-run distro survive the idle-stop instead of losing the kind cluster.
-}
applyReconcileCordon :: HostConfig -> SubstrateProvider -> IO ()
applyReconcileCordon cfg sp =
    case spReconcileCordon sp of
        Nothing -> pure ()
        Just (ExistsProbe tool args membership, whenStopped) -> do
            r <- runTool cfg tool args
            running <- case r of
                Right (ExitSuccess, out, _) -> pure (spVmId sp `elem` membersOf membership out)
                Right (ExitFailure n, _, err) -> die ("vm up: reconcile-state probe failed (exit " ++ show n ++ "): " ++ err)
                Left err -> die ("vm up: reconcile-state probe failed: " ++ err)
            if running
                then putStrLn ("vm up: " ++ spVmId sp ++ " is already running; its cordon is live — skipping the global `wsl --shutdown`")
                else do
                    discloseWslShutdown
                    putStrLn ("vm up: " ++ spVmId sp ++ " is stopped; applying the .wslconfig cordon via `wsl --shutdown` so the utility VM re-reads it on the next boot")
                    runEffects cfg whenStopped

requireDemoLifecycleResources :: Resources -> Either String ()
requireDemoLifecycleResources actualResources = do
    actual <- budgetFromResources (envelopeOfResources actualResources)
    required <- budgetFromResources (envelopeOfResources demoFullLifecycleResources)
    let shortages =
            concat
                [ shortage "cpu" show budgetCpu actual required
                , shortage "memory" showGiB budgetMemoryBytes actual required
                , shortage "storage" showGiB budgetStorageBytes actual required
                ]
    case shortages of
        [] -> Right ()
        _ ->
            Left $
                "demo vm up: resource budget too small for full demo lifecycle: "
                    ++ intercalate ", " shortages
                    ++ "; regenerate the host config with `hostbootstrap run --project-root demo -- project init --role host-orchestrator --output .build/hostbootstrap-demo.dhall --source-root demo --dockerfile docker/Dockerfile --cpu "
                    ++ show reqCpu
                    ++ " --memory "
                    ++ T.unpack reqMem
                    ++ " --storage "
                    ++ T.unpack reqSto
                    ++ " --ha-replicas 1 --force`"
  where
    Resources reqCpu reqMem reqSto = demoFullLifecycleResources
    shortage label render field actual required
        | field actual < field required =
            [ label
                ++ " has "
                ++ render (field actual)
                ++ ", needs at least "
                ++ render (field required)
            ]
        | otherwise = []
    showGiB bytes = show (gibibytes bytes) ++ "GiB"

{- | The IO behind the dissolved @vm pristine-bootstrap@ verb: the from-zero first-run flow inside the VM
(the project source is staged at @/root/hostbootstrap@; see the runbook).
Provision the documented Linux host prerequisites (pipx + the @ghcup@ toolchain
pinned to GHC 9.12.4), @pipx install@ the local hostbootstrap, then run
@hostbootstrap build@ — which asserts the host minimums, ensures the toolchain,
and builds the demo binary **host-native** in the VM (**build #2**), then
installs the built binary (no exec).
-}
runVmBootstrap :: IO ()
runVmBootstrap = demoConfigContext Context.HostOrchestratorCommand [Context.HostTools] $ \parentCfg ctx -> do
    cfg <- resolveHostConfig
    provider <- demoProvider cfg
    -- Discovered on the metal host (the only place the credential lives); forwarded
    -- into the VM only over stdin for the build #3 base-image pull. 'Nothing' when
    -- the host is not logged in, in which case the pull stays anonymous.
    mAuth <- discoverHostRegistryAuth
    -- Re-homed from the dissolved @web bridge@ verb (§ P): the build-image step
    -- generates the PureScript bridge into the source tree, so the staged source
    -- (hence the build #3 docker context) carries it and the Dockerfile only runs
    -- @spago build@ + @esbuild@. The bridge is reflected from the Haskell API, so
    -- it cannot drift from the binary the same step builds.
    let bridgeDir = T.unpack (Context.sourceRoot ctx) </> "web" </> "src" </> "Generated"
    putStrLn ("build-image: generating the PureScript bridge into " ++ bridgeDir)
    createDirectoryIfMissing True bridgeDir
    writeBridge bridgeDir
    stageSource cfg provider
    streamVMConfig cfg provider parentCfg ctx
    let vmStep label script = do
            putStrLn ("pristine-bootstrap: " ++ label)
            runInDemoVM cfg provider script
    vmStep
        "apt install pipx + GHC build prerequisites"
        "export DEBIAN_FRONTEND=noninteractive; sudo -E apt-get update -qq && sudo -E apt-get install -y -qq pipx python3-venv build-essential curl libgmp-dev libtinfo-dev libncurses-dev zlib1g-dev pkg-config git ca-certificates"
    vmStep
        "ensure the ghcup toolchain (GHC 9.12.4 + cabal) — the documented Linux host prerequisite"
        "test -x \"$HOME/.ghcup/bin/ghcup\" || { export BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=9.12.4 BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1; curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh; }"
    vmStep
        "pipx install the local hostbootstrap CLI"
        ("pipx install --force " ++ shellQuote vmRepoRoot)
    vmStep
        "hostbootstrap build (build #2: the demo binary, host-native in the VM)"
        ( "export PATH=/root/.ghcup/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd "
            ++ shellQuote (vmRepoRoot ++ "/demo")
            ++ " && hostbootstrap build && test -x .build/hostbootstrap-demo"
        )
    vmStep
        "install the in-VM pb + its sibling vm-orchestrator-1 config at /usr/local/bin (the metal->VM handoff SelfRef path)"
        ( "sudo install -m 0755 "
            ++ shellQuote (vmRepoRoot ++ "/demo/.build/hostbootstrap-demo")
            ++ " /usr/local/bin/hostbootstrap-demo && sudo cp "
            ++ shellQuote (vmRepoRoot ++ "/demo/.build/hostbootstrap-demo.dhall")
            ++ " /usr/local/bin/hostbootstrap-demo.dhall"
        )
    vmStep
        "install Docker in the VM (install + start the daemon) — prerequisite for build #3"
        "export DEBIAN_FRONTEND=noninteractive; sudo -E apt-get update -qq && sudo -E apt-get install -y -qq docker.io acl && sudo systemctl enable --now docker && sudo setfacl -m u:$(id -un):rw /var/run/docker.sock"
    -- Poll `docker info` to Ready in Haskell (§ C) rather than assuming the
    -- daemon/socket is instant. The retry lives here, NOT as an inline shell `for`
    -- loop: a loop with a single-quoted `echo` mangles through the Windows
    -- PowerShell→wsl→bash quoting path (the `'`→`''` escaping splits the line), so the
    -- probe stays a simple `docker info >/dev/null 2>&1` — the same shape
    -- `waitVMNetwork`/`substrateWait` use safely.
    dockerReady <- waitDockerReady cfg provider
    let buildImageScript =
            "cd " ++ shellQuote vmRepoRoot ++ " && " ++ dockerCommand (dockerBuildArgs repoRootCfg (demoBaseImage cfg))
        repoRootCfg =
            parentCfg{dockerfile = "demo/" <> dockerfile parentCfg}
    buildProjectImage dockerReady cfg provider mAuth buildImageScript
    putStrLn "pristine-bootstrap: done (build #2 host-native + build #3 project image, in the VM)"

runDirectHostBootstrap :: IO ()
runDirectHostBootstrap = demoConfigContext Context.HostOrchestratorCommand [Context.HostTools] $ \parentCfg ctx -> do
    initialCfg <- resolveHostConfig
    when (substrateName (hcSubstrate initialCfg) /= LinuxGpu) $
        die "direct-linux-gpu-bootstrap: this path is only valid on the linux-gpu substrate"
    preflightDemoLifecycleHost initialCfg (resourcesFromContext ctx)
    runEnsure EnsureDocker.reconciler
    cfgAfterDocker <- resolveHostConfig
    root <- getCurrentDirectory
    let directPlan = resolvePlanWithDriver demoProject root Production NvkindDriver
    harnessRun <- lookupEnv harnessMutationGuardEnv
    when (harnessRun == Just "1") $ do
        exists <- directClusterExists cfgAfterDocker directPlan
        when exists $
            throwIO (SafetyRefusal "direct nvkind state appeared after Docker ensure; refusing to reconcile it before CUDA mutates Docker")
    runEnsure EnsureCuda.reconciler
    cfg <- resolveHostConfig
    let bridgeDir = T.unpack (Context.sourceRoot ctx) </> "web" </> "src" </> "Generated"
        repoRoot = takeDirectory (T.unpack (Context.sourceRoot ctx))
        repoRootCfg = parentCfg{dockerfile = "demo/" <> dockerfile parentCfg}
    putStrLn ("build-image: generating the PureScript bridge into " ++ bridgeDir)
    createDirectoryIfMissing True bridgeDir
    writeBridge bridgeDir
    putStrLn "direct-linux-gpu-bootstrap: build the project container on the host for nvkind"
    withCurrentDirectory repoRoot $
        runOrDie cfg Docker (dockerBuildArgs repoRootCfg (demoBaseImage cfg))
    putStrLn "direct-linux-gpu-bootstrap: done (project image built on the host)"

{- | Stream the parent-derived VM-orchestrator config into the VM **in-place**
(§ X): render the narrowed VM projection and pipe it over the VM shell's @stdin@,
where a single in-VM @bash -lc@ mints the @/run/hostbootstrap/vm-provider@ witness
and @cat@s the config to the VM's sibling @<project>.dhall@. No host-side
@.vm.dhall@ file and no file copy — only the narrowed projection crosses, on
@stdin@ only. The witness is still minted here on the metal side because the in-VM
@project up@ gate checks it before any step runs. The @printf … | sudo tee@
sub-pipeline has its own @stdin@, so the outer @stdin@ stays intact for the final
@cat@, which writes the config bytes verbatim.
-}
streamVMConfig :: HostConfig -> SubstrateProvider -> ProjectConfig -> Context.BinaryContext -> IO ()
streamVMConfig cfg provider parentCfg ctx = do
    let remotePath = vmDemoRoot ++ "/.build/hostbootstrap-demo.dhall"
        vmCfg =
            projectConfigFromContext
                (dockerfile parentCfg)
                (deploy parentCfg)
                (message parentCfg)
                (service parentCfg)
                (Context.deriveVMContextWithProvider (spProviderKind provider) ctx (T.pack vmDemoRoot))
    runInDemoVMStdin
        cfg
        provider
        ( "mkdir -p "
            ++ shellQuote (vmDemoRoot ++ "/.build")
            ++ " && sudo mkdir -p /run/hostbootstrap"
            ++ " && printf %s "
            ++ shellQuote (spVmId provider)
            ++ " | sudo tee /run/hostbootstrap/vm-provider >/dev/null"
            ++ " && cat > "
            ++ shellQuote remotePath
        )
        (T.unpack (renderProjectConfig vmCfg))
    putStrLn ("pristine-bootstrap: streamed parent-derived VM config into " ++ spVmId provider ++ ":" ++ remotePath)

{- | The published base tag the demo's project container builds @FROM@ — cpu /
the detected VM architecture. The base is pulled inside the VM by build #3.
-}
demoBaseImage :: HostConfig -> String
demoBaseImage = demoBaseImageFor . hcSubstrate

demoBaseImageFor :: Substrate -> String
demoBaseImageFor sub =
    "docker.io/tuee22/hostbootstrap:basecontainer-"
        ++ flavor
        ++ "-"
        ++ renderArch (substrateArch sub)
  where
    flavor
        | substrateName sub == LinuxGpu = "cuda"
        | otherwise = "cpu"

{- | The hostbootstrap monorepo root (holding @core/@ + @demo/@) given the project
home. The demo is nested one level under the repo, and the binary now always runs
with cwd = the project home (the Python launcher execs it with @cwd=project_root@),
so the repo root is that parent. Pure.
-}
repoRootOfProjectRoot :: FilePath -> FilePath
repoRootOfProjectRoot projectRoot = projectRoot ++ "/.."

{- | Stage the project working tree into the VM at @/root/hostbootstrap@ — the
source @pipx install@ and the in-VM @hostbootstrap build@ build from. The host
working tree (uncommitted changes included) is tarred minus build/VCS
artifacts, pushed as a single file (@pushFileArgs@), and extracted in the VM.
Without this step the from-zero bootstrap has nothing to install — the runbook
documents the source as "staged at @/root/hostbootstrap@", and this is where
that staging happens. The binary runs with cwd = the project home (@demo/@), so the
repo root is 'repoRootOfProjectRoot' of the cwd (cwd-consistent, not cwd-fragile).
-}
stageSource :: HostConfig -> SubstrateProvider -> IO ()
stageSource cfg provider = do
    cwd <- getCurrentDirectory
    let repoRoot = repoRootOfProjectRoot cwd
        tarball = repoRoot ++ "/.hostbootstrap-src.tgz"
    putStrLn ("pristine-bootstrap: staging the project source into " ++ spVmId provider ++ ":" ++ vmRepoRoot)
    (tc, _, terr) <-
        readProcessWithExitCode
            "tar"
            [ "czf"
            , tarball
            , "--exclude=.git"
            , "--exclude=dist-newstyle"
            , "--exclude=.build"
            , "--exclude=node_modules"
            , "--exclude=.test_data"
            , "--exclude=.role-bus"
            , "--exclude=.venv"
            , -- Transient host-side caches: never staged into the VM, and (being
              -- tool-created, sometimes with restrictive ACLs) a source of
              -- "Permission denied" stat errors that truncate the archive. Excluding
              -- them keeps the stage complete and reproducible (§ C).
              "--exclude=.pytest_cache"
            , "--exclude=.mypy_cache"
            , "--exclude=.ruff_cache"
            , "--exclude=__pycache__"
            , "--exclude=*.tgz"
            , "-C"
            , repoRoot
            , "."
            ]
            ""
    -- @tar@ exits 1 on benign warnings such as "file changed as we read it" (an
    -- active source tree races the read); the archive is still written. Treat
    -- exit 1 with a produced tarball as a non-fatal warning, and only a fatal exit
    -- (>= 2) or a missing tarball as a real failure.
    tarballWritten <- doesFileExist tarball
    case tc of
        ExitSuccess -> pure ()
        ExitFailure 1
            | tarballWritten ->
                putStrLn ("pristine-bootstrap: tar warning (non-fatal): " ++ takeWhile (/= '\n') terr)
        _ -> die ("pristine-bootstrap: source tar failed: " ++ terr)
    -- Always remove the host-side staging tarball, even if a push or in-VM
    -- extract dies: 'finally' guarantees the cleanup runs on the exception path
    -- so a failed run never leaves a stale @.hostbootstrap-src.tgz@ in the repo
    -- root. The tarball is guaranteed to exist here (a fatal tar already
    -- 'die'd above), so the unconditional 'removeFile' cannot itself throw.
    -- One staging path for every substrate: place the tarball where the guest can
    -- read it (a push to @/tmp@ on Lima/Incus; read in place via @/mnt@ on WSL2,
    -- which emits no host effect), then extract it, removing the temp only when one
    -- was pushed. The per-substrate difference is the pure 'stageFileEffects' plan.
    ( do
            let staged = stageFileEffects (spTransfer provider) tarball "/tmp/hostbootstrap-src.tgz"
                cleanup = if sfPushedTemp staged then " && rm -f " ++ shellQuote (sfGuestPath staged) else ""
            runEffects cfg (sfHostEffects staged)
            runInDemoVM
                cfg
                provider
                ( "rm -rf "
                    ++ shellQuote vmRepoRoot
                    ++ " && mkdir -p "
                    ++ shellQuote vmRepoRoot
                    ++ " && tar -xzf "
                    ++ shellQuote (sfGuestPath staged)
                    ++ " -C "
                    ++ shellQuote vmRepoRoot
                    ++ cleanup
                    -- Guard against a truncated stage (a host-side tar that dropped
                    -- entries, e.g. on an unreadable file): fail loudly here rather
                    -- than letting `pipx install` fail later with a confusing
                    -- "not installable" error (§ C).
                    ++ " && { test -f "
                    ++ shellQuote (vmRepoRoot ++ "/pyproject.toml")
                    ++ " || { echo 'pristine-bootstrap: staged source is truncated (pyproject.toml missing at repo root) — the host staging tar dropped entries' >&2; exit 1; }; }"
                )
        )
        `finally` removeFile tarball

shellQuote :: String -> String
shellQuote s = "'" ++ concatMap quoteChar s ++ "'"
  where
    quoteChar '\'' = "'\\''"
    quoteChar c = [c]

dockerCommand :: [String] -> String
dockerCommand args = unwords (map shellQuote ("docker" : args))

{- | The demo's chain-frame teardown for @project down@ / @project destroy@. The
metal frame's only provisioned resource is the VM, so @down@ (@False@) /stops/ it
(the stop-without-delete capability) and @destroy@ (@True@) /deletes/ it
(guard-prefixed). The core runs this after the recursive cluster teardown — which
preserves host @.data@ (§ O) — so the VM is the last frame torn down. Best-effort
and idempotent: a missing or already-stopped VM is reported and skipped, never a
hard failure, so a partial stack always tears down.
-}
demoTeardown :: ProjectConfig -> Bool -> IO ()
demoTeardown projectCfg destroyVM = do
    cfg <- resolveHostConfig
    daemonError <- captureCleanup "host accelerator daemon" (stopHostAcceleratorDaemon cfg (context projectCfg))
    frameError <- captureCleanup "provider/direct cluster" (teardownFrames cfg)
    let errors = catMaybes [daemonError, frameError]
    unless (null errors) $
        die ("project teardown attempted every cleanup step but failed:\n" ++ unlines (map ("  - " ++) errors))
  where
    captureCleanup label action = do
        outcome <- try action :: IO (Either SomeException ())
        pure $ case outcome of
            Right () -> Nothing
            Left err -> Just (label ++ ": " ++ show err)
    teardownFrames cfg
        | substrateName (hcSubstrate cfg) == LinuxGpu = do
            putStrLn "project teardown: direct Linux GPU lane has no provider VM"
            unless (toolPresent cfg Docker) $
                die "project teardown: Docker is unavailable, so absence of the direct nvkind cluster cannot be proven"
            let root = T.unpack (Context.sourceRoot (context projectCfg))
                directPlan = resolvePlanWithDriver demoProject root Production NvkindDriver
            exists <- directClusterExists cfg directPlan
            when exists $ do
                putStrLn "project teardown: deleting the direct nvkind cluster through the project image"
                runOrDie cfg Docker directClusterTeardownArgs
            remaining <- directClusterExists cfg directPlan
            when remaining (die "project teardown: direct nvkind node containers remain after deletion")
        | otherwise = do
            provider <- demoProvider cfg
            let name = spVmId provider
            if destroyVM
                then case spDestroy provider of
                    Left err -> die err
                    Right effs -> do
                        runEffectsBestEffort cfg ("project destroy: deleting " ++ name) effs
                        remaining <- substrateExists cfg provider
                        when remaining (die ("project destroy: managed VM still exists after deletion: " ++ name))
                else runEffectsBestEffort cfg ("project down: stopping " ++ name) (spStop provider)

{- | The direct lane deliberately does not require host-installed kind/nvkind.
Execute the image's pinned @kind@ against the host Docker socket so teardown
uses the same toolchain image that created the nvkind cluster.
-}
directClusterTeardownArgs :: [String]
directClusterTeardownArgs =
    [ "run"
    , "--rm"
    , "--network=host"
    , "-v"
    , "/var/run/docker.sock:/var/run/docker.sock"
    , "--entrypoint"
    , "/usr/local/bin/kind"
    , demoProjectImage
    , "delete"
    , "cluster"
    , "--name"
    , demoProject
    ]

{- | Run a teardown tool invocation best-effort: announce the intent, then tolerate
a non-zero exit (a missing or already-stopped VM is not a failure for idempotent
teardown). Only a clean exit streams its output.
-}
bestEffortTool :: HostConfig -> HostTool -> [String] -> String -> IO ()
bestEffortTool cfg tool argv intent = do
    putStrLn intent
    result <- runToolWithStdin cfg tool argv ""
    case result of
        Right (ExitSuccess, out, _) -> unless (null out) (putStr out)
        Right (ExitFailure _, _, err) -> putStrLn ("  (skipped: " ++ takeWhile (/= '\n') err ++ ")")
        Left err -> putStrLn ("  (skipped: " ++ err ++ ")")

-- | The in-cluster registry endpoint (the NodePort the demo publishes registry:2 on).
registryEndpoint :: String
registryEndpoint = "localhost:30500"

-- | The container frame's topology id (the @vm-project-container-2@ witness).
containerRuntimeFrameId :: String
containerRuntimeFrameId = "vm-project-container-2"

-- | The Linux GPU direct container topology id: host -> project container.
directContainerRuntimeFrameId :: String
directContainerRuntimeFrameId = "vm-project-container-1"

{- | The project container the chain's container frame runs in: the demo image, with the
host Docker socket mounted (so kind nodes are siblings on the VM daemon) and
host networking. The project-container child @<project>.dhall@ is delivered
**in-place** via 'clConfigDelivery' — the narrowed projection (@payload@) is piped
on the handoff @stdin@ and the entrypoint writes it to
@/usr/local/bin/hostbootstrap-demo.dhall@ before @exec@ing @project up@, so there is
**no config bind-mount** (only the docker-socket and @/run/hostbootstrap@ witness
mounts remain). It also forwards the Docker Hub credential by /name/ only
(@-e HOSTBOOTSTRAP_REGISTRY_AUTH@) — never the value — so the in-container kind/curl
pulls authenticate; with no host login the variable is unset and pulls stay
anonymous (see "HostBootstrap.Registry").
-}
demoDeployImage :: String -> Bool -> T.Text -> ContainerLift
demoDeployImage currentFrameId directLinuxGpu payload =
    ContainerLift
        { clImage = "hostbootstrap-demo:local"
        , clMounts =
            Mount "/var/run/docker.sock" "/var/run/docker.sock" False
                : [Mount "/run/hostbootstrap" "/run/hostbootstrap" True | not directLinuxGpu]
        , clExtraArgs =
            [ "--network=host"
            , "-e"
            , "HOSTBOOTSTRAP_CURRENT_FRAME=" ++ currentFrameId
            ]
                ++ ( if directLinuxGpu
                        then
                            [ "--gpus=all"
                            , "-e"
                            , "HOSTBOOTSTRAP_DIRECT_CONTAINER=linux-gpu"
                            ]
                        else []
                   )
                ++ [ "-e"
                   , registryAuthEnvVar
                   ]
        , clRemoveAfter = True
        , clConfigDelivery =
            Just
                ( ConfigDelivery
                    "/usr/local/bin/hostbootstrap-demo.dhall"
                    "/usr/local/bin/hostbootstrap-demo"
                    payload
                )
        }
