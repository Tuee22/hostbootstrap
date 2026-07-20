{- | kind/Helm cluster-lifecycle semantics.

The cluster lifecycle drives kind/Helm @up@ / @down@ / @delete@, enforces the
never-delete-@.data@ invariant, and distinguishes the production cluster
profile (fixed name / @.data@ path) from the test profile (per-case isolated
paths). The plan resolution and the teardown partition are pure so the
invariants are unit-tested; the IO drivers run kind/Helm through resolved host
tools.
-}
module HostBootstrap.Cluster.Lifecycle (
    ClusterProfile (..),
    ClusterDriver (..),
    ClusterPlan (..),
    AcceleratorDaemonPlacement (..),
    AcceleratorIngressPlan (..),
    TeardownKind (..),
    durableDataPath,
    ensureDurableDataPath,
    resolvePlan,
    resolvePlanWithDriver,
    resolveAcceleratorPlan,
    clusterDriverForSubstrate,
    clusterCreateTool,
    clusterCreateArgs,
    acceleratorIngressPlan,
    nvidiaRuntimeProbeArgs,
    nvidiaRuntimeProbeReady,
    nvidiaDevicePluginHelmArgs,
    nvidiaDevicePluginReadyArgs,
    nvidiaAllocatableProbeArgs,
    nvidiaAllocatableReady,
    NvidiaDevicePluginOps (..),
    ensureNvidiaDevicePluginWith,
    clusterConfigPresence,
    clusterNodeNames,
    clusterNodeCordonArgs,
    teardown,
    statusReport,
    clusterHealthyFromProbe,
    clusterUp,
    clusterCreate,
    deployChart,
    clusterDown,
    clusterDelete,
    clusterStatus,
)
where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Control.Monad (forM_, unless, when)
import Data.Maybe (catMaybes, maybeToList)
import Data.Text (Text)
import qualified Data.Text as T
import HostBootstrap.Cluster.Cordon (
    ResourceBudget (..),
    budgetFromResources,
    kindNodeCordonArgsFor,
    preflightBudget,
    resolveHostCapacity,
 )
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.Ensure (runTool)
import qualified HostBootstrap.Ensure.Cuda as Cuda
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Helm, Kind, Kubectl, Nvkind))
import HostBootstrap.Readiness (ProbeResult (..), nodePoll, pollUntilReady)
import HostBootstrap.Substrate (Substrate (substrateName), SubstrateName (LinuxGpu), isLinux)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removePathForcibly)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))

{- | The cluster profile: production uses fixed names and the canonical @.data@
path; the test profile isolates each case under its own paths so a
harness-driven test never collides with a production cluster.
-}
data ClusterProfile = Production | TestCase String
    deriving (Eq, Show)

{- | The cluster creator used by a plan. The standard path creates a plain kind
cluster. The Linux GPU accelerator path creates the cluster through @nvkind@ so
worker nodes are GPU-enabled, while the rest of the lifecycle still talks to
the resulting kind cluster through @kind@/@kubectl@.
-}
data ClusterDriver = KindDriver | NvkindDriver
    deriving (Eq, Show)

{- | A resolved cluster plan: the kind cluster name, the durable state path
teardown never enumerates for removal (@.data@ under 'Production',
@.test_data\/\<case\>@ under 'TestCase'), the derived state safe to remove on
@delete@, and whether this
cluster publishes the project's fixed host NodePorts (via @./kind.yaml@'s
@extraPortMappings@). Only the production cluster does — it is the persistent
stack the host reaches on @localhost:\<nodePort\>@. Test-case clusters set this
'False' so they create a plain kind cluster with no host-port binding: several
isolated case clusters then coexist (and never collide with a running
production cluster) on the same host, and each case reaches its in-cluster
workload through the kind container network rather than a fixed host port.
-}
data ClusterPlan = ClusterPlan
    { clusterName :: String
    , dataPath :: FilePath
    , derivedPaths :: [FilePath]
    , publishesHostPorts :: Bool
    , clusterDriver :: ClusterDriver
    , clusterConfigFile :: Maybe FilePath
    , clusterNodeSuffixes :: [String]
    }
    deriving (Eq, Show)

-- | Resolve a cluster plan for a project, rooted at @root@, under a profile.
resolvePlan :: String -> FilePath -> ClusterProfile -> ClusterPlan
resolvePlan project root profile = resolvePlanWithDriver project root profile KindDriver

{- | Resolve a cluster plan with an explicit driver. Most callers use
'resolvePlan'; accelerator topology code selects 'NvkindDriver' for Linux GPU.
-}
resolvePlanWithDriver :: String -> FilePath -> ClusterProfile -> ClusterDriver -> ClusterPlan
resolvePlanWithDriver project root profile driver = case profile of
    Production ->
        ClusterPlan
            { clusterName = project
            , dataPath = durableDataPath root
            , derivedPaths = [root </> ".cluster" </> project]
            , publishesHostPorts = True
            , clusterDriver = driver
            , clusterConfigFile = Just (driverConfigFile driver)
            , clusterNodeSuffixes = driverNodeSuffixes driver
            }
    TestCase caseId ->
        ClusterPlan
            { clusterName = project ++ "-test-" ++ caseId
            , dataPath = root </> ".test_data" </> caseId
            , derivedPaths = [root </> ".cluster" </> (project ++ "-test-" ++ caseId)]
            , publishesHostPorts = False
            , clusterDriver = driver
            , clusterConfigFile = Nothing
            , clusterNodeSuffixes = driverNodeSuffixes driver
            }

driverConfigFile :: ClusterDriver -> FilePath
driverConfigFile KindDriver = "kind.yaml"
driverConfigFile NvkindDriver = "nvkind.yaml"

driverNodeSuffixes :: ClusterDriver -> [String]
driverNodeSuffixes KindDriver = ["control-plane"]
driverNodeSuffixes NvkindDriver = ["control-plane", "worker"]

{- | Resolve the accelerator cluster driver from the host substrate. Linux GPU is
direct-host @nvkind@; every other substrate keeps the existing kind path.
-}
clusterDriverForSubstrate :: Substrate -> ClusterDriver
clusterDriverForSubstrate sub
    | substrateName sub == LinuxGpu = NvkindDriver
    | otherwise = KindDriver

resolveAcceleratorPlan :: String -> FilePath -> ClusterProfile -> Substrate -> ClusterPlan
resolveAcceleratorPlan project root profile sub =
    resolvePlanWithDriver project root profile (clusterDriverForSubstrate sub)

-- | Where an accelerator daemon is placed relative to the web service.
data AcceleratorDaemonPlacement = InClusterDaemon | HostResidentDaemon
    deriving (Eq, Show)

{- | The web-service accelerator ingress exposure selected for a daemon
placement. Host daemons get a local-only kind host mapping; in-cluster daemons
use a normal ClusterIP service and need no host mapping.
-}
data AcceleratorIngressPlan = AcceleratorIngressPlan
    { ingressServiceType :: String
    , ingressServicePort :: Int
    , ingressNodePort :: Maybe Int
    , ingressKindListenAddress :: Maybe String
    }
    deriving (Eq, Show)

acceleratorIngressPlan :: AcceleratorDaemonPlacement -> Int -> Int -> AcceleratorIngressPlan
acceleratorIngressPlan InClusterDaemon servicePort _nodePort =
    AcceleratorIngressPlan
        { ingressServiceType = "ClusterIP"
        , ingressServicePort = servicePort
        , ingressNodePort = Nothing
        , ingressKindListenAddress = Nothing
        }
acceleratorIngressPlan HostResidentDaemon servicePort nodePort =
    AcceleratorIngressPlan
        { ingressServiceType = "NodePort"
        , ingressServicePort = servicePort
        , ingressNodePort = Just nodePort
        , ingressKindListenAddress = Just "127.0.0.1"
        }

-- | The kind of teardown.
data TeardownKind = Down | Delete
    deriving (Eq, Show)

-- | The canonical host-owned durable root for a production project.
durableDataPath :: FilePath -> FilePath
durableDataPath root = root </> ".data"

{- | Ensure the canonical host-owned durable root exists and return its path.
Creating an existing directory is an idempotent no-op and never inspects or
removes its contents.
-}
ensureDurableDataPath :: FilePath -> IO FilePath
ensureDurableDataPath root = do
    let path = durableDataPath root
    createDirectoryIfMissing True path
    pure path

{- | Partition a teardown into the paths to remove and the paths to preserve.
The @.data@ path is preserved under both @down@ and @delete@ — the
never-delete-@.data@ invariant — so it never appears in the removal set.
-}
teardown :: TeardownKind -> ClusterPlan -> ([FilePath], [FilePath])
teardown Down plan = ([], dataPath plan : derivedPaths plan)
teardown Delete plan = (derivedPaths plan, [dataPath plan])

{- | Render a read-only status report for a resolved plan, given whether the kind
cluster is currently live. Pure, so the report shape is unit-tested. The data
line states only that cluster teardown omits the path; status does not inspect
the path and therefore makes no claim that it currently exists or is intact.
-}
statusReport :: ClusterPlan -> Bool -> String
statusReport plan live =
    unlines
        [ "cluster:    " ++ clusterName plan ++ (if live then " (running)" else " (absent)")
        , "data:       " ++ dataPath plan ++ " (not removed by cluster teardown)"
        , "derived:    " ++ unwords (derivedPaths plan)
        ]

-- ---------------------------------------------------------------------------
-- IO drivers
-- ---------------------------------------------------------------------------

{- | Bring the cluster up (idempotent): create the cordoned kind cluster, then
install/upgrade the Helm release. This is 'clusterCreate' followed by
'deployChart' — the bundled bring-up a single-chart project uses. A project
that must sequence other steps between cluster creation and the chart (e.g.
stand up an in-cluster registry and push the image the chart pulls) calls
'clusterCreate' and 'deployChart' as separate chain steps instead.
-}
clusterUp :: HostConfig -> ClusterPlan -> ResourceEnvelope -> IO ()
clusterUp cfg plan resources = do
    clusterCreate cfg plan resources
    deployChart cfg plan []

{- | Create the cordoned kind cluster (idempotent), **without** the chart: run the
spare-capacity preflight, create the kind cluster if absent (health-checking and
recreating a listed-but-unhealthy one), apply the budget cordon (fail-closed),
then gate on real node/CNI readiness before returning. The applied cordon sits
**after** @kind create@ so workloads never schedule against an un-cordoned node,
and the readiness gate sits **after** the cordon so the first @kubectl apply@ /
Helm install a chain runs next cannot race the API server or CNI on a busy host.
Split out from 'clusterUp' so a chain can interleave registry setup / image push
before 'deployChart'.
-}
clusterCreate :: HostConfig -> ClusterPlan -> ResourceEnvelope -> IO ()
clusterCreate cfg plan resources = do
    resolvedCapacity <- resolveHostCapacity cfg
    case resolvedCapacity >>= preflightBudget resources of
        Left err -> die err
        Right () -> pure ()
    probeNvidiaRuntime cfg plan
    ensureCluster cfg plan
    -- Always export the kubeconfig — whether the cluster was just created or already
    -- existed (an idempotent re-run, or any container that did not create it) — so
    -- helm/kubectl reach the cluster instead of the localhost:8080 default.
    exported <- runTool cfg Kind ["export", "kubeconfig", "--name", clusterName plan]
    requireStep "kind export kubeconfig" exported
    applyLinuxCordon cfg plan resources
    -- Node/CNI readiness gate: @kind create@ defaults to @--wait 0s@, so a chain's
    -- first @kubectl apply@ / @helm install@ could otherwise hit an API server or CNI
    -- that is not yet up on a busy host. Block here until the nodes are Ready.
    waitNodesReady cfg plan
    ensureNvidiaDevicePlugin cfg plan

{- | Ensure a live kind cluster named by the plan exists, creating it if absent and
**recreating** a listed-but-unhealthy one. @kind get clusters@ only lists names,
so a cluster whose containers are stopped (e.g. after the VM that hosts it was
@project down@-stopped and restarted — kind has no reliable stop/restart
contract) still reads as "present"; trusting the list would then leave the chain
talking to a dead API server. Instead a listed cluster is health-probed
('clusterHealthy'); an unhealthy one is deleted and recreated so @project up@
reconciles a stopped stack back to running.
-}
ensureCluster :: HostConfig -> ClusterPlan -> IO ()
ensureCluster cfg plan = do
    existing <- runTool cfg Kind ["get", "clusters"]
    case existing of
        Left err ->
            die ("cluster up: kind not available; install kind and retry\n" ++ err)
        Right (ExitSuccess, out, _)
            | clusterName plan `elem` lines out -> do
                healthy <- clusterHealthy cfg plan
                if healthy
                    then putStrLn ("cluster up: kind cluster " ++ clusterName plan ++ " already exists and is healthy")
                    else do
                        putStrLn
                            ( "cluster up: kind cluster "
                                ++ clusterName plan
                                ++ " is listed but unhealthy; deleting and recreating"
                            )
                        recreated <- runTool cfg Kind ["delete", "cluster", "--name", clusterName plan]
                        requireStep "kind delete cluster (unhealthy)" recreated
                        createCluster cfg plan
            | otherwise -> createCluster cfg plan
        Right (code, _, err) ->
            die ("cluster up: `kind get clusters` failed (" ++ show code ++ "): " ++ err)

{- | Create the kind cluster fresh (fail-closed). The production cluster publishes
its NodePorts to the host (the in-VM registry/web endpoints the demo reaches on
@localhost@) by shipping a @./kind.yaml@ with @extraPortMappings@; @kind create@
uses it via @--config@. A test-case plan intentionally carries
@clusterConfigFile = Nothing@, so its node binds no fixed host port and several
isolated case clusters can coexist. An explicitly supplied config is always
honored; this matters for a non-publishing nvkind test topology whose GPU worker
still needs its label and device mount.
-}
createCluster :: HostConfig -> ClusterPlan -> IO ()
createCluster cfg plan = do
    configExists <- maybe (pure False) doesFileExist (clusterConfigFile plan)
    hasKindConfig <- either die pure (clusterConfigPresence (clusterConfigFile plan) configExists)
    created <- runTool cfg (clusterCreateTool plan) (clusterCreateArgs plan hasKindConfig)
    requireStep (clusterCreateLabel plan) created

{- | Interpret the filesystem probe for an optional cluster config. @Nothing@
explicitly selects the driver's default template; @Just path@ is a contract
and therefore fails closed when the file is missing.
-}
clusterConfigPresence :: Maybe FilePath -> Bool -> Either String Bool
clusterConfigPresence Nothing _ = Right False
clusterConfigPresence (Just _) True = Right True
clusterConfigPresence (Just path) False = Left ("cluster up: required config file is missing: " ++ path)

clusterCreateTool :: ClusterPlan -> HostTool
clusterCreateTool plan = case clusterDriver plan of
    KindDriver -> Kind
    NvkindDriver -> Nvkind

clusterCreateArgs :: ClusterPlan -> Bool -> [String]
clusterCreateArgs plan hasKindConfig = case clusterDriver plan of
    KindDriver ->
        ["create", "cluster", "--name", clusterName plan] ++ kindConfigArgs
    NvkindDriver ->
        ["cluster", "create", "--name=" ++ clusterName plan] ++ nvkindConfigArgs
  where
    kindConfigArgs
        | useConfig = ["--config", kindClusterConfig]
        | otherwise = []
    nvkindConfigArgs
        | useConfig = ["--config-template=" ++ kindClusterConfig]
        | otherwise = []
    useConfig = hasKindConfig && maybe False (const True) (clusterConfigFile plan)
    kindClusterConfig = maybe "kind.yaml" id (clusterConfigFile plan)

clusterCreateLabel :: ClusterPlan -> String
clusterCreateLabel plan = case clusterDriver plan of
    KindDriver -> "kind create cluster"
    NvkindDriver -> "nvkind cluster create"

{- | Health-probe a listed kind cluster: export its kubeconfig (idempotent), then
ask @kubectl@ for its nodes. A cluster whose containers are stopped exports a
kubeconfig but cannot answer @kubectl get nodes@, so the probe fails and the
caller recreates it. Pure classification is 'clusterHealthyFromProbe'.
-}
clusterHealthy :: HostConfig -> ClusterPlan -> IO Bool
clusterHealthy cfg plan = do
    _ <- runTool cfg Kind ["export", "kubeconfig", "--name", clusterName plan]
    probe <- runTool cfg Kubectl ["get", "nodes", "--no-headers"]
    pure (clusterHealthyFromProbe probe)

{- | Classify a @kubectl get nodes --no-headers@ probe: healthy iff the command
succeeded and reported at least one node line. A connection failure (stopped
cluster) or an empty node list is unhealthy. Pure so the recreate decision is
unit-tested without a live cluster.
-}
clusterHealthyFromProbe :: Either String (ExitCode, String, String) -> Bool
clusterHealthyFromProbe (Right (ExitSuccess, out, _)) =
    not (null (filter (not . null) (map (dropWhile (== ' ')) (lines out))))
clusterHealthyFromProbe _ = False

{- | Block until the cluster's nodes reach @Ready@ (the node/CNI readiness gate).
Each attempt runs @kubectl wait --for=condition=Ready node --all@ with a bounded
per-attempt timeout, retrying a few times so a slow API server / CNI on a busy
host is tolerated. Fail-closed: if the nodes never report Ready the step dies so
a broken cluster is loud rather than racing the first apply.
-}
waitNodesReady :: HostConfig -> ClusterPlan -> IO ()
waitNodesReady cfg plan = do
    outcome <- pollUntilReady nodePoll lbl nodeProbe cfg
    case outcome of
        Right () -> putStrLn ("cluster up: nodes Ready for " ++ clusterName plan)
        Left _ -> die (lbl ++ " did not reach Ready in time")
  where
    lbl = "cluster up: nodes for " ++ clusterName plan
    nodeProbe c = classify <$> runTool c Kubectl ["wait", "--for=condition=Ready", "node", "--all", "--timeout=30s"]
    classify (Right (ExitSuccess, _, _)) = ProbeReady ()
    classify _ = NotReady

{- | NVIDIA Docker runtime smoke used before the Linux GPU direct @nvkind@ path
asks Kubernetes to run CUDA daemon pods.
-}
nvidiaRuntimeProbeArgs :: [String]
nvidiaRuntimeProbeArgs = Cuda.nvkindRuntimeProbeArgs

nvidiaRuntimeProbeReady :: Either String (ExitCode, String, String) -> Bool
nvidiaRuntimeProbeReady = Cuda.nvkindRuntimeProbeReady

probeNvidiaRuntime :: HostConfig -> ClusterPlan -> IO ()
probeNvidiaRuntime cfg plan =
    when (clusterDriver plan == NvkindDriver) $ do
        result <- runTool cfg Docker nvidiaRuntimeProbeArgs
        unless (nvidiaRuntimeProbeReady result) $
            die ("linux-gpu cluster up: Docker NVIDIA runtime probe failed; expected `docker " ++ unwords nvidiaRuntimeProbeArgs ++ "` to report a GPU")

{- | Pinned NVIDIA device-plugin install for an @nvkind@ cluster. The plugin is
what publishes @nvidia.com/gpu@ into node allocatable resources; creating the
GPU-enabled kind nodes alone is not sufficient for pod scheduling.
-}
nvidiaDevicePluginHelmArgs :: [String]
nvidiaDevicePluginHelmArgs =
    [ "upgrade"
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

nvidiaDevicePluginReadyArgs :: [String]
nvidiaDevicePluginReadyArgs =
    [ "rollout"
    , "status"
    , "daemonset/nvidia-device-plugin"
    , "-n"
    , "nvidia"
    , "--timeout=120s"
    ]

nvidiaAllocatableProbeArgs :: [String]
nvidiaAllocatableProbeArgs =
    [ "get"
    , "nodes"
    , "-o"
    , "jsonpath={range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}"
    ]

nvidiaAllocatableReady :: Either String (ExitCode, String, String) -> Bool
nvidiaAllocatableReady (Right (ExitSuccess, out, _)) = any positiveQuantity (lines out)
  where
    positiveQuantity raw = case reads raw of
        [(n, "")] -> n > (0 :: Integer)
        _ -> False
nvidiaAllocatableReady _ = False

{- | Injectable operations for the NVIDIA device-plugin reconciliation. Keeping
the control flow separate from the concrete Helm and kubectl calls makes the
idempotence contract directly testable: allocatable GPU capacity is probed
first, and a positive result must bypass every mutating/readiness operation.
-}
data NvidiaDevicePluginOps m = NvidiaDevicePluginOps
    { ndpProbeAllocatable :: m Bool
    , ndpReconcilePlugin :: m ()
    , ndpWaitPluginReady :: m ()
    , ndpRequireAllocatable :: m ()
    }

{- | Reconcile the NVIDIA device plugin only when the read-only pre-probe does
not already find positive allocatable GPU capacity. The post-reconcile
allocation requirement is deliberately a distinct final operation: a Ready
DaemonSet is not sufficient unless a node actually advertises
@nvidia.com/gpu@.
-}
ensureNvidiaDevicePluginWith :: (Monad m) => NvidiaDevicePluginOps m -> m ()
ensureNvidiaDevicePluginWith ops = do
    alreadyAllocatable <- ndpProbeAllocatable ops
    unless alreadyAllocatable $ do
        ndpReconcilePlugin ops
        ndpWaitPluginReady ops
        ndpRequireAllocatable ops

ensureNvidiaDevicePlugin :: HostConfig -> ClusterPlan -> IO ()
ensureNvidiaDevicePlugin cfg plan =
    when (clusterDriver plan == NvkindDriver) $
        ensureNvidiaDevicePluginWith
            NvidiaDevicePluginOps
                { ndpProbeAllocatable = do
                    result <- runTool cfg Kubectl nvidiaAllocatableProbeArgs
                    let positive = nvidiaAllocatableReady result
                    when positive $
                        putStrLn "cluster up: nvidia.com/gpu is already allocatable; NVIDIA device plugin is unchanged"
                    pure positive
                , ndpReconcilePlugin = do
                    repo <- runTool cfg Helm ["repo", "add", "nvdp", "https://nvidia.github.io/k8s-device-plugin", "--force-update"]
                    requireStep "NVIDIA device-plugin helm repository" repo
                    installed <- runTool cfg Helm nvidiaDevicePluginHelmArgs
                    requireStep "NVIDIA device-plugin install" installed
                , ndpWaitPluginReady = do
                    ready <- runTool cfg Kubectl nvidiaDevicePluginReadyArgs
                    requireStep "NVIDIA device-plugin DaemonSet rollout" ready
                , ndpRequireAllocatable = do
                    outcome <- pollUntilReady nodePoll "NVIDIA GPU allocatable" probe cfg
                    case outcome of
                        Right () -> putStrLn "cluster up: NVIDIA device plugin Ready; nvidia.com/gpu is allocatable"
                        Left _ -> die "cluster up: NVIDIA device plugin became Ready but no node advertised nvidia.com/gpu"
                }
  where
    probe c = classify <$> runTool c Kubectl nvidiaAllocatableProbeArgs
    classify result
        | nvidiaAllocatableReady result = ProbeReady ()
        | otherwise = NotReady

{- | Deploy the project's Helm chart if one is present. A project ships its chart
at @./chart@ (relative to the directory the lifecycle runs in — the project root
on the host, or @/workspace/\<project\>@ inside the project container); @cluster
up@ installs it **fail-closed**. A project with no chart (the cluster is the
workload, or it deploys via another path such as @harbor install@) gets a clean
kind + cordon bring-up with the deploy skipped — that is "no deploy requested",
not a swallowed failure.

@extraValues@ is a generic, project-supplied @[(KEY, VALUE)]@ passed to helm as
one @--set-string KEY=VALUE@ per pair, so a project can template its chart from
live config (e.g. the served message) without the core knowing the keys. The
core stays generic: it forwards the pairs verbatim.
-}
deployChart :: HostConfig -> ClusterPlan -> [(Text, Text)] -> IO ()
deployChart cfg plan extraValues = do
    hasChart <- doesDirectoryExist chartPath
    if hasChart
        then do
            -- @--wait@ so the chart's pods are Ready before the step returns — a
            -- following expose/readiness step (or a lifting parent) then sees a live
            -- service, not a still-scheduling one.
            release <-
                runTool
                    cfg
                    Helm
                    ( ["upgrade", "--install", clusterName plan, chartPath, "--wait", "--timeout", "8m"]
                        ++ concatMap setStringArg extraValues
                    )
            requireStep "helm upgrade --install" release
        else putStrLn ("cluster up: no chart at ./" ++ chartPath ++ "; skipping deploy (kind + cordon only)")
  where
    chartPath = "chart"
    setStringArg (key, value) = ["--set-string", T.unpack key ++ "=" ++ helmEscape (T.unpack value)]
    -- helm @--set-string@ treats commas as value separators (and backslash as its
    -- escape), so a value like "Hello, world!" would split into "Hello" + " world!"
    -- (a key with no value). Escape each literal comma and backslash so the value
    -- reaches the chart intact.
    helmEscape = concatMap esc
      where
        esc ',' = "\\,"
        esc '\\' = "\\\\"
        esc c = [c]

-- | The node containers the selected cluster driver creates.
clusterNodeNames :: ClusterPlan -> [String]
clusterNodeNames plan = map ((clusterName plan ++ "-") ++) (clusterNodeSuffixes plan)

{- | Split the one cluster envelope evenly across every node container, flooring
each dimension so the sum never exceeds the declared slice. An nvkind cluster
has a control-plane plus one GPU worker; giving the full envelope to both would
double-count the budget.
-}
clusterNodeCordonArgs :: ClusterPlan -> ResourceEnvelope -> Either String [[String]]
clusterNodeCordonArgs plan resources = do
    budget <- budgetFromResources resources
    let names = clusterNodeNames plan
        count = length names
        naturalCount = fromIntegral count
        integerCount = fromIntegral count
    case () of
        _ | count == 0 -> Left "cluster node cordon: the plan declares no nodes"
        _ | budgetCpu budget < naturalCount -> Left "cluster node cordon: CPU slice is smaller than the node count"
        _ | budgetMemoryBytes budget < integerCount -> Left "cluster node cordon: memory slice is smaller than the node count"
        _ | budgetStorageBytes budget < integerCount -> Left "cluster node cordon: storage slice is smaller than the node count"
        _ -> do
            let perNode =
                    ResourceEnvelope
                        (budgetCpu budget `div` naturalCount)
                        (T.pack (show (budgetMemoryBytes budget `div` integerCount)))
                        (T.pack (show (budgetStorageBytes budget `div` integerCount)))
            traverse (`kindNodeCordonArgsFor` perNode) names

{- | Apply the Linux kind/nvkind node cordon: @docker update@ every node with its
share of the one cluster slice, fail-closed. On Apple the provider VM is the
cordon, so there is no host-side kind-node cap.
-}
applyLinuxCordon :: HostConfig -> ClusterPlan -> ResourceEnvelope -> IO ()
applyLinuxCordon cfg plan resources
    | isLinux (hcSubstrate cfg) =
        case clusterNodeCordonArgs plan resources of
            Left err -> die ("cordon: " ++ err)
            Right argSets -> forM_ argSets $ \args -> do
                result <- runTool cfg Docker args
                case result of
                    Right (ExitSuccess, _, _) -> putStrLn ("cordon applied: docker " ++ unwords args)
                    Right (ExitFailure n, _, e) -> die ("cordon failed (exit " ++ show n ++ "): " ++ e)
                    Left e -> die ("cordon: " ++ e)
    | otherwise =
        putStrLn "cordon: Apple substrate — the per-project Colima VM is sized by `ensure docker`"

-- | Tear the cluster down. The removal set is empty, so no path is removed.
clusterDown :: HostConfig -> ClusterPlan -> IO ()
clusterDown = clusterTeardown Down

-- | Thoroughly delete derived cluster state, still never removing the plan's @.data@ path.
clusterDelete :: HostConfig -> ClusterPlan -> IO ()
clusterDelete = clusterTeardown Delete

{- | Run every independent cluster-cleanup action before reporting failure.

Best-effort teardown means that a failed @kind delete@ cannot prevent derived
paths from being considered, and one failed path removal cannot prevent the
remaining removals. It does not mean success: after all actions have been
attempted, their synchronous failures are raised together so the project
lifecycle and test harness cannot report a green teardown with leaked state.
-}
clusterTeardown :: TeardownKind -> HostConfig -> ClusterPlan -> IO ()
clusterTeardown teardownKind cfg plan = do
    let (toRemove, _) = teardown teardownKind plan
        operation = case teardownKind of
            Down -> "cluster down"
            Delete -> "cluster delete"
    deleted <- runTool cfg Kind ["delete", "cluster", "--name", clusterName plan]
    deleteFailure <- reportStep "kind delete cluster" deleted
    removalFailures <- removeAll toRemove
    putStrLn (operation ++ ": did not remove " ++ dataPath plan)
    let failures = maybeToList deleteFailure ++ removalFailures
    unless (null failures) $
        ioError . userError $
            operation
                ++ " attempted every cleanup step but failed:\n"
                ++ unlines (map ("  - " ++) failures)

{- | Report the cluster status (read-only): whether the kind cluster is live, and
the data / derived paths. The report states the cluster-teardown omission
contract for the data path without claiming to have inspected it. Never mutates
state.
-}
clusterStatus :: HostConfig -> ClusterPlan -> IO ()
clusterStatus cfg plan = do
    existing <- runTool cfg Kind ["get", "clusters"]
    let live = case existing of
            Right (ExitSuccess, out, _) -> clusterName plan `elem` lines out
            _ -> False
    putStr (statusReport plan live)

removeAll :: [FilePath] -> IO [String]
removeAll paths = catMaybes <$> mapM removeOne paths
  where
    removeOne path = do
        outcome <- try $ do
            exists <- doesDirectoryExist path
            when exists $ removePathForcibly path >> putStrLn ("removed " ++ path)
        pure $ case (outcome :: Either SomeException ()) of
            Right () -> Nothing
            Left err -> Just ("remove " ++ path ++ ": " ++ displayException err)

reportStep :: String -> Either String (ExitCode, String, String) -> IO (Maybe String)
reportStep label result = do
    let failure = case result of
            Right (ExitSuccess, _, _) -> Nothing
            Right (ExitFailure n, _, err) -> Just (label ++ ": exit " ++ show n ++ detail err)
            Left err -> Just (label ++ ": " ++ err)
        rendered = maybe (label ++ ": ok") id failure
    putStrLn rendered
    pure failure
  where
    detail "" = ""
    detail err = " " ++ err

{- | Like 'reportStep' but fail-closed: a non-zero exit or an unresolved tool
aborts (the @cluster up@ helm/kind steps must match the fail-closed cordon, so
a broken deploy is loud — never a swallowed @putStrLn@ that lets the caller,
or a lifting parent process, see success).
-}
requireStep :: String -> Either String (ExitCode, String, String) -> IO ()
requireStep label result = case result of
    Right (ExitSuccess, _, _) -> putStrLn (label ++ ": ok")
    Right (ExitFailure n, _, err) -> die (label ++ ": exit " ++ show n ++ " " ++ err)
    Left err -> die (label ++ ": " ++ err)
