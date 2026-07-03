{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
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
    @web@ role @service run web@ dispatches to (§ AA).

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
    demoFrameContext,
    demoTeardown,
    demoArtifacts,
    demoCheckCode,
    demoCases,
    demoServices,
    demoTestSuite,
    demoVM,
    demoLimaVM,
    demoManagedVMName,
    demoGuardPrefix,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, finally, try)
import Control.Monad (unless, when)
import Data.List (intercalate, isSuffixOf)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Cluster.Cordon (
    ResourceBudget (..),
    budgetFromResources,
    gibibytes,
    preflightBudget,
    resolveHostCapacity,
 )
import HostBootstrap.Cluster.Lifecycle (ClusterPlan (..), ClusterProfile (Production), clusterCreate, deployChart, resolvePlan)
import HostBootstrap.Config.Schema (siblingProjectConfigPath, withSiblingProjectConfigContext)
import HostBootstrap.Config.Vocab (Mount (..), PodResources (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf)
import HostBootstrap.Ensure (runEnsure, runTool, runToolWithStdin)
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as EnsureLima
import qualified HostBootstrap.Ensure.Wsl2 as EnsureWsl2
import HostBootstrap.Harness (Case (..), CaseResult (..), TestSuite (..), testSafetyPreconditions)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Kind, Sudo), toolCommandName)
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift (ConfigDelivery (..), ContainerLift (..), LiftContext (..), LiftLeaf (..), inContainer, liftLeaf, localContext, reachLeaf)
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Registry (discoverHostRegistryAuth, dockerAuthStdinWrapper, registryAuthEnvVar, registryConfigPayload)
import HostBootstrap.Service (ServiceHandler (..), ServiceRegistry)
import HostBootstrap.Step (
    Step,
    StepFrame (..),
    buildPbStep,
    contextInitStep,
    deployChartStep,
    deployKindStep,
    deployVMStep,
    exposePortStep,
    projectStep,
 )
import HostBootstrap.Substrate (Substrate, detect, isAppleSilicon, isLinux, isWindows, renderArch, substrateArch)
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
import HostBootstrap.Wsl2 (Wsl2VM (..))
import HostBootstrapDemo.Config (
    DeployConfig (..),
    ProjectConfig (..),
    Resources (..),
    demoCaseIds,
    demoDefaultResources,
    envelopeOfResources,
    projectConfigFromContext,
    renderDhallText,
    renderProjectConfig,
 )
import HostBootstrapDemo.Container (dockerBuildArgs)
import HostBootstrapDemo.Web.Api (demoWebPod)
import HostBootstrapDemo.Web.Bridge (writeBridge)
import HostBootstrapDemo.Web.Server (serveWeb)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getHomeDirectory, removeFile, renameFile, withCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
import System.IO (hPutStr, stderr)
import System.Process (readProcessWithExitCode)

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

{- | The demo's deploy: a contributed @chain :: ProjectConfig -> [Step]@ value the
core @project up@ interprets recursively (§ Y). @project up --dry-run@ renders it.
The chain descends three frames (the full fractal): the metal host-orchestrator
provisions the VM and builds the pb (#2) + the project image (#3) in it; the in-VM
@vm-orchestrator-1@ mints the project-container child config and hands off; the
in-container @vm-project-container-2@ stands up the persistent stack —
@deploy-kind@ → @deploy-harbor@ → @push-image@ → @deploy-chart@ → @expose-port@ —
ending at a live webservice on the NodePort. Each frame's binary runs only its
own segment, then hands off @project up@ one level down via 'demoFrameContext'.
-}
demoChain :: ProjectConfig -> [Step]
demoChain _ =
    -- host-orchestrator-0 (metal): provision the VM, build the pb (#2) + image (#3) in it.
    [ deployVMStep "ensure the VM provider (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows)" demoMetalFrame (const runVmEnsure)
    , deployVMStep "launch the budget-sized VM (cordon #1: the VM is the wall)" demoMetalFrame (const runVmUp)
    , buildPbStep "pristine-bootstrap: build the binary host-native, then the project image, in the VM" demoMetalFrame (const runVmBootstrap)
    , -- vm-orchestrator-1 (the in-VM pb): mint the project-container child config, then hand off.
      contextInitStep "prepare the project-container child config for in-place delivery" demoVMFrame contextInitAnnounce
    , -- vm-project-container-2 (the in-container pb): stand up the persistent stack.
      deployKindStep "deploy the persistent kind cluster (cordon #2, Production profile)" demoContainerFrame deployKindAction
    , projectStep "deploy-harbor" "install the in-cluster Harbor registry (helm, NodePort 30500)" demoContainerFrame deployHarborAction
    , projectStep "push-image" "load the project image into kind + push it to Harbor" demoContainerFrame pushImageAction
    , deployChartStep "deploy the web service chart pod (NodePort 30080)" demoContainerFrame deployChartAction
    , exposePortStep "verify the web NodePort (30080) is reachable" demoContainerFrame exposeAction
    ]

demoMetalFrame :: StepFrame
demoMetalFrame = StepFrame "host-orchestrator-0" "metal"

demoVMFrame :: StepFrame
demoVMFrame = StepFrame "vm-orchestrator-1" "vm-orchestrator"

demoContainerFrame :: StepFrame
demoContainerFrame = StepFrame containerRuntimeFrameId "project-container"

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
        inContainer (demoDeployImage (containerConfigPayload cfg)) localContext
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
            (Context.deriveContainerContext (context cfg) (T.pack containerSourceRoot))
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

{- | The persistent cluster plan for the demo's container-frame steps: the
Production profile (fixed name + the never-deleted @.data@ path, § O), rooted at
the container's source root.
-}
containerPlan :: Context.BinaryContext -> ClusterPlan
containerPlan ctx = resolvePlan demoProject (T.unpack (Context.sourceRoot ctx)) Production

{- | Container-frame (@vm-project-container-2@) workload step actions. They run in
the project container, where the VM's Docker socket is mounted (kind nodes are
siblings on the VM daemon) and @kubectl@/@helm@/@kind@ resolve on @$PATH@ (baked
into the base image). Each reads the container's local @<project>.dhall@ for the
source root + resources, then drives the real reconcile — reusing the core
cluster lifecycle and the demo's Harbor logic. The persistent stack: a cordoned
kind cluster (Production profile) → the Harbor registry → the image (kind-loaded
+ pushed) → the web chart pod → the verified NodePort.
-}
deployKindAction :: HostConfig -> IO ()
deployKindAction _ = demoContext Context.ClusterLifecycleCommand [] $ \ctx -> do
    cfg <- resolveHostConfig
    -- Cordon the cluster to a slice within the budget-sized VM wall (§ O), not the
    -- full budget — the budget is used once, as the VM wall (cordon #1).
    slice <- either die pure (clusterSliceOfBudget (resourcesFromContext ctx))
    withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterCreate cfg (containerPlan ctx) (envelopeOfResources slice))

{- | The default Harbor admin credential the demo installs Harbor with and logs in
as to push (the in-cluster registry is a demo fixture, not a secret store).
-}
harborAdminPassword :: String
harborAdminPassword = "Harbor12345"

deployHarborAction :: HostConfig -> IO ()
deployHarborAction _ = demoContext Context.ClusterLifecycleCommand [] $ \_ -> do
    cfg <- resolveHostConfig
    runOrDie cfg Helm ["repo", "add", "harbor", "https://helm.goharbor.io"]
    runOrDie cfg Helm ["repo", "update"]
    runOrDie cfg Helm $
        [ "upgrade"
        , "--install"
        , "harbor"
        , "harbor/harbor"
        , "--version"
        , harborChartVersion
        , "--set"
        , "expose.type=nodePort"
        , "--set"
        , "expose.tls.enabled=false"
        , "--set"
        , "expose.nodePort.ports.http.nodePort=30500"
        , "--set"
        , "externalURL=http://" ++ harborEndpoint
        , "--set"
        , "harborAdminPassword=" ++ harborAdminPassword
        ]
            ++ harborImageOverrides
            ++ [ -- Wait for the Harbor pods to be Ready before returning, so push-image
                 -- finds the registry live (helm returns immediately without this).
                 "--wait"
               , "--timeout"
               , "15m"
               ]
    putStrLn ("deploy-harbor: Harbor reachable at http://" ++ harborEndpoint)

{- | The Harbor chart version pinned to match 'harborImageTag': chart @1.18.3@
ships Harbor @v2.14.0@, the version of the dual-arch 'octohelm' mirror images, so
the chart templates and the overridden image tags stay in lockstep.
-}
harborChartVersion :: String
harborChartVersion = "1.18.3"

-- | The dual-arch Harbor image tag (Harbor @v2.14.0@).
harborImageTag :: String
harborImageTag = "v2.14.0"

{- | Override every Harbor component image to the @ghcr.io/octohelm/harbor/*@
**dual-arch** mirror (development_plan_standards § K; see
@documents/engineering/harbor.md@). The upstream @goharbor/*@ images are
**amd64-only single-arch manifests**, so on an @arm64@ kind node (Apple Silicon)
their pods crash with @exec format error@; the @octohelm@ mirror publishes
@linux/amd64@ + @linux/arm64@ for the same @v2.14.0@ components, so Harbor runs
natively on whatever substrate the VM is. Each @--set@ retargets a component's
@image.repository@ + @image.tag@; the set covers every pod the default chart
enables (nginx, portal, core, jobservice, registry + registryctl, the internal
database and redis, and trivy).
-}
harborImageOverrides :: [String]
harborImageOverrides =
    concatMap
        override
        [ ("nginx.image", "nginx-photon")
        , ("portal.image", "harbor-portal")
        , ("core.image", "harbor-core")
        , ("jobservice.image", "harbor-jobservice")
        , ("registry.registry.image", "registry-photon")
        , ("registry.controller.image", "harbor-registryctl")
        , ("database.internal.image", "harbor-db")
        , ("redis.internal.image", "redis-photon")
        , ("trivy.image", "trivy-adapter-photon")
        ]
  where
    override (key, img) =
        [ "--set"
        , key ++ ".repository=ghcr.io/octohelm/harbor/" ++ img
        , "--set"
        , key ++ ".tag=" ++ harborImageTag
        ]

pushImageAction :: HostConfig -> IO ()
pushImageAction _ = demoContext Context.ProjectCommand [] $ \ctx -> do
    cfg <- resolveHostConfig
    -- Load the image into the kind nodes (so the web chart pod's IfNotPresent pull
    -- resolves without a registry round-trip), then also push it to Harbor (the
    -- in-cluster registry capability). @localhost@ registries are insecure by
    -- default in Docker, so the HTTP NodePort needs no extra config.
    runOrDie cfg Kind ["load", "docker-image", demoProjectImage, "--name", clusterName (containerPlan ctx)]
    loggedIn <- waitHarborLogin cfg 60
    unless loggedIn (die ("push-image: could not log in to the Harbor registry at " ++ harborEndpoint))
    let ref = harborEndpoint ++ "/library/hostbootstrap-demo:demo"
    runOrDie cfg Docker ["tag", demoProjectImage, ref]
    runOrDie cfg Docker ["push", ref]
    putStrLn ("push-image: kind-loaded " ++ demoProjectImage ++ " and pushed " ++ ref)

{- | Retry @docker login@ to the Harbor registry until it succeeds. The registry's
@/v2/@ returns 401 until authenticated, so a login probe — not a 2xx HTTP check —
is the right readiness signal once Harbor's pods are up (the @deploy-harbor@ helm
@--wait@ already gates on pod readiness; this absorbs the brief NodePort / token-
service warm-up after that). Bounded by @n@ five-second attempts.
-}
waitHarborLogin :: HostConfig -> Int -> IO Bool
waitHarborLogin _ 0 = pure False
waitHarborLogin cfg n = do
    r <- runToolWithStdin cfg Docker ["login", harborEndpoint, "-u", "admin", "-p", harborAdminPassword] ""
    case r of
        Right (ExitSuccess, _, _) -> pure True
        _ -> threadDelay 5000000 >> waitHarborLogin cfg (n - 1)

{- | @deploy-chart@: install the web chart pod, templating the chart's embedded
config from the live config's served @message@ (Sprint 20.2). The message is
forwarded to helm as the generic @demoMessage@ extra-value; the ConfigMap template
interpolates it into the pod's mounted @<project>.dhall@, so @service run web@
reads the same message the host config carried, end to end.
-}
deployChartAction :: HostConfig -> IO ()
deployChartAction _ = demoConfigContext Context.ClusterLifecycleCommand [] $ \projectCfg ctx -> do
    cfg <- resolveHostConfig
    let extraValues =
            [ ("demoMessage", renderDhallText (message projectCfg))
            , ("haReplicas", T.pack (show (haReplicas (deploy projectCfg))))
            ]
    withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (deployChart cfg (containerPlan ctx) extraValues)

exposeAction :: HostConfig -> IO ()
exposeAction cfg = demoContext Context.ClusterLifecycleCommand [] $ \_ -> do
    ready <- waitWebReachable cfg localContext "http://localhost:30080/api/budget" 60
    unless ready (die "expose-port: the web NodePort 30080 did not become reachable on the host")
    putStrLn "expose-port: web service reachable at http://localhost:30080/"

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
waitWebReachable _ _ _ 0 = pure False
waitWebReachable cfg frame url n = do
    result <- liftLeaf cfg frame (reachLeaf url)
    case result of
        Right (ExitSuccess, _, _) -> pure True
        _ -> threadDelay 5000000 >> waitWebReachable cfg frame url (n - 1)

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
    let sliceCpu = if budgetCpu b > 1 then budgetCpu b - 1 else 1
        sliceMem = max 2 (gibibytes (budgetMemoryBytes b) - 4)
        sliceStore = max 10 (gibibytes (budgetStorageBytes b) - 40)
    pure
        ( Resources
            sliceCpu
            (T.pack (show sliceMem ++ "GiB"))
            (T.pack (show sliceStore ++ "GiB"))
        )

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
    let prodPlan = resolvePlan demoProject root Production
    testSafetyPreconditions
        cfgPath
        (clusterIsRunning cfg prodPlan)

-- | Whether a cluster of the plan's name is already running on the host's kind.
clusterIsRunning :: HostConfig -> ClusterPlan -> IO Bool
clusterIsRunning cfg plan = do
    result <- runTool cfg Kind ["get", "clusters"]
    pure $ case result of
        Right (ExitSuccess, out, _) -> clusterName plan `elem` lines out
        _ -> False

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
    runSelfOrDie self ["project", "up"]
    cfg <- resolveHostConfig
    pure (CaseEnv cfg (demoVMFrameContext (hcSubstrate cfg)) label)

{- | Tear the test stack down by driving @project destroy@ (best-effort, so a
partial stack always tears down; host @.data@ is preserved by the lifecycle, § O).
-}
demoTestDown :: CaseEnv -> IO ()
demoTestDown _ = do
    self <- getExecutablePath
    putStrLn "test run: tearing the stack down via `project destroy`"
    runSelfBestEffort self ["project", "destroy"]

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
    let script =
            "docker run --rm --network host --entrypoint sh -e BASE_URL=http://localhost:30080 -e EXPECTED_MESSAGE="
                ++ shellQuote (T.unpack expectedMessage)
                ++ " -e NODE_PATH="
                ++ baseNodeModulesPath
                ++ " "
                ++ demoProjectImage
                ++ " -lc 'cd /workspace/demo/playwright && playwright test'"
    result <- liftLeaf cfg frame (RawCmd ["bash", "-lc", script])
    pure $ case result of
        Right (ExitSuccess, _, _) -> Pass
        Right (_, out, err) -> Fail ("e2e failed: " ++ takeWhile (/= '\n') (err ++ out))
        Left err -> Fail ("e2e: " ++ err)

-- | Run the binary's own subcommand (the self-reference, § U), dying on failure.
runSelfOrDie :: FilePath -> [String] -> IO ()
runSelfOrDie self args = do
    (code, out, err) <- readProcessWithExitCode self args ""
    unless (null out) (putStr out)
    case code of
        ExitSuccess -> pure ()
        ExitFailure n -> die (self ++ " " ++ unwords args ++ " failed (exit " ++ show n ++ ")\n" ++ err)

-- | Run the binary's own subcommand best-effort (teardown tolerates failure).
runSelfBestEffort :: FilePath -> [String] -> IO ()
runSelfBestEffort self args = do
    (code, out, err) <- readProcessWithExitCode self args ""
    unless (null out) (putStr out)
    case code of
        ExitSuccess -> pure ()
        ExitFailure _ -> putStrLn ("  (teardown skipped: " ++ takeWhile (/= '\n') err ++ ")")

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

{- | The demo's service-handler registry (§ AA): the long-running @web@ role
@service run web@ dispatches to (the former @web serve@ verb). The @service run@
context gate has already validated the service-role @<project>.dhall@ (the
ConfigMap-delivered cluster-service config, § X) before the handler runs, so the
handler is just the role body — the warp/wai webservice on the service port.
-}
demoServices :: ServiceRegistry
demoServices = [ServiceHandler "web" (serveWeb 8080)]

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

{- | Write @content@ to @path@, first backing up any existing file to
@<path>.hostbootstrap-demo.bak@ (once), so the global @.wslconfig@ the WSL2
cordon writes never clobbers a user's own file irretrievably.
-}
writeHostFileWithBackup :: FilePath -> String -> IO ()
writeHostFileWithBackup path content = do
    let bak = path ++ ".hostbootstrap-demo.bak"
    exists <- doesFileExist path
    bakExists <- doesFileExist bak
    when (exists && not bakExists) (copyFile path bak)
    writeFile path content
    putStrLn ("vm up: wrote the WSL2 resource cordon to " ++ path)

-- | Restore @path@ from its backup (or remove it if there was none), best-effort.
restoreHostFile :: FilePath -> IO ()
restoreHostFile path = do
    let bak = path ++ ".hostbootstrap-demo.bak"
    bakExists <- doesFileExist bak
    outcome <-
        try $
            if bakExists
                then renameFile bak path >> pure ("project destroy: restored " ++ path)
                else do
                    exists <- doesFileExist path
                    if exists
                        then removeFile path >> pure ("project destroy: removed " ++ path)
                        else pure ""
    case (outcome :: Either SomeException String) of
        Right msg -> unless (null msg) (putStrLn msg)
        Left _ -> pure ()

-- | Probe whether the provider's VM already exists (idempotent reconcile).
substrateExists :: HostConfig -> SubstrateProvider -> IO Bool
substrateExists cfg sp =
    case spExists sp of
        ExistsProbe tool args membership -> do
            r <- runTool cfg tool args
            pure $ case r of
                Right (ExitSuccess, out, _) -> spVmId sp `elem` membersOf membership out
                _ -> False

{- | Poll the provider's readiness probe until the VM answers, bounded by @n@
two-second attempts (the substrate-generic peer of the former per-provider
@waitVMAgent@ / @waitLimaVM@ / @waitWsl2VM@).
-}
substrateWait :: HostConfig -> SubstrateProvider -> Int -> IO ()
substrateWait _ sp 0 = die ("vm up: " ++ spVmId sp ++ " did not become ready")
substrateWait cfg sp n =
    case spWait sp of
        WaitProbe tool args -> do
            r <- runTool cfg tool args
            case r of
                Right (ExitSuccess, _, _) -> pure ()
                _ -> threadDelay 2000000 >> substrateWait cfg sp (n - 1)

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

{- | @demo vm up@: read the active context envelope, derive the VM sizing from
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
    either die pure (requireDemoLifecycleResources lifecycleResources)
    resolvedCapacity <- resolveHostCapacity cfg
    either die pure (resolvedCapacity >>= preflightBudget envelope)
    -- Idempotent reconcile-to-running (§ Y): if the VM already exists, ensure it
    -- is started rather than re-creating it (a create on an existing instance
    -- fails), so a re-run of `project up` reconciles a partially-built stack.
    exists <- substrateExists cfg sp
    if exists
        then do
            putStrLn ("vm up: " ++ spVmId sp ++ " already exists; ensuring it is started (idempotent)")
            runEffectsBestEffort cfg ("vm up: starting existing " ++ spVmId sp) (spStartExisting sp)
        else do
            launch <- either die pure (spLaunch sp envelope)
            putStrLn ("vm up: launching " ++ spVmId sp ++ " (cordon #1: the VM is the wall, sized to the budget)")
            runEffects cfg launch
    putStrLn ("vm up: waiting for " ++ spVmId sp ++ " to answer")
    substrateWait cfg sp 60
    putStrLn ("vm up: " ++ spVmId sp ++ " is up")

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

{- | @demo vm pristine-bootstrap@: the from-zero first-run flow inside the VM
(the project source is staged at @/root/hostbootstrap@; see the runbook).
Provision the documented Linux host prerequisites (pipx + the @ghcup@ toolchain
pinned to GHC 9.12.4), @pipx install@ the local hostbootstrap, then run
@hostbootstrap run@ — which asserts the host minimums, ensures the toolchain,
and builds the demo binary **host-native** in the VM (**build #2**) before
exec'ing it (here with @context schema@, so the built binary proves itself).
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
    stageSource cfg provider (T.unpack (Context.sourceRoot ctx))
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
        "export DEBIAN_FRONTEND=noninteractive; sudo -E apt-get update -qq && sudo -E apt-get install -y -qq docker.io acl && sudo systemctl enable --now docker && sudo setfacl -m u:$(id -un):rw /var/run/docker.sock && docker info >/dev/null"
    let buildImageScript =
            "cd " ++ shellQuote vmRepoRoot ++ " && " ++ dockerCommand (dockerBuildArgs repoRootCfg (demoBaseImage cfg))
        repoRootCfg =
            parentCfg{dockerfile = "demo/" <> dockerfile parentCfg}
    case mAuth of
        Just auth -> do
            putStrLn "pristine-bootstrap: build #3 — the project container FROM the base (authenticating the pull with the forwarded Docker Hub credential)"
            runInDemoVMStdin cfg provider (dockerAuthStdinWrapper buildImageScript) (T.unpack (registryConfigPayload auth))
        Nothing -> do
            putStrLn "pristine-bootstrap: no host Docker Hub login found — build #3 pulls the base anonymously (Docker Hub rate limits may apply). Run `docker login` on the host (the standalone Docker CLI writes an inline token) for an authenticated, forwarded pull."
            vmStep
                "build #3 — the project container FROM the pulled base (repo-root context, L0-direct; anonymous pull)"
                buildImageScript
    putStrLn "pristine-bootstrap: done (build #2 host-native + build #3 project image, in the VM)"

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
demoBaseImage cfg =
    "docker.io/tuee22/hostbootstrap:basecontainer-cpu-" ++ renderArch (substrateArch (hcSubstrate cfg))

{- | Stage the project working tree into the VM at @/root/hostbootstrap@ — the
source @pipx install@ and the in-VM @hostbootstrap build@ build from. The host
working tree (uncommitted changes included) is tarred minus build/VCS
artifacts, pushed as a single file (@pushFileArgs@), and extracted in the VM.
Without this step the from-zero bootstrap has nothing to install — the runbook
documents the source as "staged at @/root/hostbootstrap@", and this is where
that staging happens.
-}
stageSource :: HostConfig -> SubstrateProvider -> FilePath -> IO ()
stageSource cfg provider sourceRoot = do
    cwd <- getCurrentDirectory
    let repoRoot =
            if "demo" `isSuffixOfPath` sourceRoot
                then sourceRoot ++ "/.."
                else cwd ++ "/.."
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
                )
        )
        `finally` removeFile tarball

isSuffixOfPath :: FilePath -> FilePath -> Bool
isSuffixOfPath suffix path =
    ("/" ++ suffix) `isSuffixOf` path || suffix == path

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
demoTeardown _ destroyVM = do
    cfg <- resolveHostConfig
    provider <- demoProvider cfg
    let name = spVmId provider
    if destroyVM
        then case spDestroy provider of
            -- The guard prefix refuses a VM name outside the managed namespace;
            -- a refusal is a hard error (we will not delete an unguarded VM).
            Left err -> die err
            -- WSL2 destroy also restores the global @.wslconfig@ we backed up.
            Right effs -> runEffectsBestEffort cfg ("project destroy: deleting " ++ name) effs
        else runEffectsBestEffort cfg ("project down: stopping " ++ name) (spStop provider)

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

-- | The in-cluster registry endpoint (a NodePort the demo publishes Harbor on).
harborEndpoint :: String
harborEndpoint = "localhost:30500"

-- | The container frame's topology id (the @vm-project-container-2@ witness).
containerRuntimeFrameId :: String
containerRuntimeFrameId = "vm-project-container-2"

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
demoDeployImage :: T.Text -> ContainerLift
demoDeployImage payload =
    ContainerLift
        { clImage = "hostbootstrap-demo:local"
        , clMounts =
            [ Mount "/var/run/docker.sock" "/var/run/docker.sock" False
            , Mount "/run/hostbootstrap" "/run/hostbootstrap" True
            ]
        , clExtraArgs =
            [ "--network=host"
            , "-e"
            , "HOSTBOOTSTRAP_CURRENT_FRAME=" ++ containerRuntimeFrameId
            , "-e"
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
