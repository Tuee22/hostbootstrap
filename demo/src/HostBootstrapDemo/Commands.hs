{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | The hostbootstrap-demo project commands and the four-stream extension
demonstration.

The demo groups its project verbs under nouns (@incus@/@vm@/@harbor@/@web@),
distinct from the inherited verb-first core verbs, and exercises the
additive extension streams:

  * CLI tree — 'demoCommands' is appended to the core tree via
    @runHostBootstrapCLI@ (append, never shadow);
  * schema-gen registry — @config schema@ / @config render@ receive
    @demoArtifacts@ through the project spec (registry concatenation);
  * test harness — the inherited @test@ verb drives the matrix over 'demoCases'
    with 'demoSeams' (the app supplies only its case matrix; the @(Seams, Cases)@
    pair is threaded into @test@ via @runHostBootstrapCLI@ in @app/Main.hs@).

The orchestration verbs (@incus@/@vm@) drive a fresh Linux host for the demo:
on Apple Silicon @vm@ uses a Lima VM, while on Linux it uses native Incus.
@incus ensure@ remains as an explicit Incus provider verb.
-}
module HostBootstrapDemo.Commands (
    demoCommands,
    demoChain,
    demoFrameContext,
    demoTeardown,
    demoArtifacts,
    demoCheckCode,
    demoCases,
    demoSeams,
    demoVM,
    demoLimaVM,
    demoGuardPrefix,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Control.Monad (unless)
import Data.List (intercalate, isPrefixOf, isSuffixOf)
import qualified Data.Text as T
import HostBootstrap.CLI (ProjectCommand, projectCommand)
import HostBootstrap.Cluster.Cordon (
    ResourceBudget (..),
    budgetFromResources,
    gibibytes,
    incusSizingArgs,
    limaSizingArgs,
 )
import HostBootstrap.Cluster.Lifecycle (ClusterPlan (..), ClusterProfile (Production), clusterCreate, clusterDelete, deployChart, resolvePlan)
import HostBootstrap.Config.Schema (ProjectConfig (..), Resources (..), projectConfigFromContext, withSiblingProjectConfigContext, writeProjectConfigFile)
import HostBootstrap.Config.Vocab (Mount (..), PodResources (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf)
import HostBootstrap.Ensure (runEnsure, runTool, runToolWithStdin)
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as EnsureLima
import HostBootstrap.Harness (Case (..), CaseResult (..), Seams (..), testCaseProfile)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Incus, Kind, Lima, Sudo), toolCommandName)
import HostBootstrap.Incus (IncusVM (..), createVMArgs, destroyVMArgs, execVMArgs, pushFileArgs, stopVMArgs)
import HostBootstrap.Lift (ContainerLift (..), LiftContext, inContainer, inLimaVM, inVM, localContext)
import HostBootstrap.Lima (LimaVM (..))
import qualified HostBootstrap.Lima as LimaVM
import HostBootstrap.Registry (discoverHostRegistryAuth, dockerAuthStdinWrapper, registryAuthEnvVar, registryConfigPayload)
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
import HostBootstrap.Substrate (Substrate, detect, isAppleSilicon, isLinux, renderArch, substrateArch)
import HostBootstrapDemo.Web.Bridge (writeBridge)
import HostBootstrapDemo.Web.Server (serveWeb)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, removeFile, withCurrentDirectory)
import System.Exit (ExitCode (..), die)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStr, stderr)
import System.Process (readProcessWithExitCode)

{- | The demo's schema-gen artifacts, appended to @coreArtifacts@ (the registry
concatenation stream). A demo web-pod footprint reflected from the vocabulary.
-}
demoArtifacts :: [ConfigArtifact]
demoArtifacts =
    [ artifactOf @PodResources "demoWeb" (PodResources 2 1 1 1 2)
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
    [ Case "pristine-bootstrap" 1 False
    , Case "web-build" 1 False
    , Case "e2e-tabs" 1 False
    ]

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
    [ deployVMStep "ensure the VM provider (Lima on Apple Silicon, Incus on Linux)" demoMetalFrame (const runVmEnsure)
    , deployVMStep "launch the budget-sized VM (cordon #1: the VM is the wall)" demoMetalFrame (const runVmUp)
    , buildPbStep "pristine-bootstrap: build the binary host-native, then the project image, in the VM" demoMetalFrame (const runVmBootstrap)
    , -- vm-orchestrator-1 (the in-VM pb): mint the project-container child config, then hand off.
      contextInitStep "mint the project-container child config in the VM" demoVMFrame mintContainerConfig
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
threads in from @main@ (the same selection 'demoVMProvider' makes). The in-VM
binary's handoff into @vm-project-container-2@ folds to a local @docker run --rm
\<image\> project up@ (local because that binary already runs inside the VM, so it
needs no provider). Each binary only ever hands off to its immediate next frame,
so a single one-level lift per transition is correct.
-}
demoFrameContext :: Substrate -> ProjectConfig -> StepFrame -> LiftContext
demoFrameContext sub _ next
    | frameId next == frameId demoVMFrame =
        if isAppleSilicon sub
            then inLimaVM demoLimaVM localContext
            else inVM demoVM localContext
    | frameId next == frameId demoContainerFrame = inContainer demoDeployImage localContext
    | otherwise = localContext

{- | @context-init@ (the @vm-orchestrator-1@ step): mint the project-container
child @<project>.dhall@ (parameters + context + witness, never the chain) from
the active VM config and write it where 'demoDeployImage' mounts it into the
container, just before the @docker run … project up@ handoff. Idempotent.
-}
mintContainerConfig :: HostConfig -> IO ()
mintContainerConfig _ = demoConfigContext Context.ContextCreationCommand [] $ \parentCfg ctx -> do
    -- The container's source root is @/workspace/demo@ (the Dockerfile's @COPY demo
    -- /workspace/demo@ + @WORKDIR@), NOT the VM's @/tmp/hostbootstrap/demo@ — the
    -- container-frame steps @cd@ here for @./chart@ etc.
    let containerCtx = Context.deriveContainerContext ctx (T.pack containerSourceRoot)
        containerCfg = projectConfigFromContext (dockerfile parentCfg) (deploy parentCfg) containerCtx
    createDirectoryIfMissing True (takeDirectory vmRuntimeContainerConfigPath)
    writeProjectConfigFile vmRuntimeContainerConfigPath containerCfg
    putStrLn ("context-init: minted project-container config at " ++ vmRuntimeContainerConfigPath)

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
    withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterCreate cfg (containerPlan ctx) (resourcesFromContext ctx))

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
    runOrDie
        cfg
        Helm
        [ "upgrade"
        , "--install"
        , "harbor"
        , "harbor/harbor"
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
        , -- Wait for the Harbor pods to be Ready before returning, so push-image
          -- finds the registry live (helm returns immediately without this).
          "--wait"
        , "--timeout"
        , "15m"
        ]
    putStrLn ("deploy-harbor: Harbor reachable at http://" ++ harborEndpoint)

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

deployChartAction :: HostConfig -> IO ()
deployChartAction _ = demoContext Context.ClusterLifecycleCommand [] $ \ctx -> do
    cfg <- resolveHostConfig
    withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (deployChart cfg (containerPlan ctx))

exposeAction :: HostConfig -> IO ()
exposeAction _ = demoContext Context.ClusterLifecycleCommand [] $ \_ -> do
    ready <- waitWebReachable "http://localhost:30080/api/budget" 60
    unless ready (die "expose-port: the web NodePort 30080 did not become reachable on the host")
    putStrLn "expose-port: web service reachable at http://localhost:30080/"

{- | Poll a URL with the project container's own @curl@ on the VM host network
(the container runs @--network=host@), so the NodePort published on the VM's
@localhost@ is reached directly. Distinct from the harness's 'waitNodePort', which
curls from a throwaway container on the @kind@ docker network (where @localhost@
is that container's own loopback, not the VM's). Bounded by @n@ five-second
attempts.
-}
waitWebReachable :: String -> Int -> IO Bool
waitWebReachable _ 0 = pure False
waitWebReachable url n = do
    (code, _, _) <- readProcessWithExitCode "curl" ["-fsS", "-m", "5", "-o", "/dev/null", url] ""
    case code of
        ExitSuccess -> pure True
        _ -> threadDelay 5000000 >> waitWebReachable url (n - 1)

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

{- | The per-case cluster budget — a slice small enough to fit inside the
budget-sized VM's spare capacity (the full project budget is the VM wall).
-}
caseResources :: Resources
caseResources = Resources 2 "2GiB" "10GiB"

{- | The full demo lifecycle pulls the large base image, builds the project
image, and duplicates layers through kind. Smaller budgets fail late in
Docker extraction, so reject them before launching the VM.
-}
demoFullLifecycleResources :: Resources
demoFullLifecycleResources = Resources 6 "10GiB" "80GiB"

{- | Size the VM (cordon #1, the outer wall) /larger/ than the cluster budget
(cordon #2, the in-VM kind cluster) so the cluster fits inside its own VM with
headroom for the VM's OS + Docker daemon + the multi-GB image builds. The
in-container preflight requires the cluster budget to be strictly within the VM's
spare capacity, so the VM must exceed the cluster budget in /every/ dimension —
@demoFullLifecycleResources@ is the cluster budget, and this adds the VM headroom
on top. Without it the VM and the cluster claim the same budget and the cluster
can never fit inside its own wall.
-}
vmSizingWithHeadroom :: Resources -> Either String Resources
vmSizingWithHeadroom r = do
    b <- budgetFromResources r
    pure
        ( Resources
            (budgetCpu b + 4)
            (T.pack (show (gibibytes (budgetMemoryBytes b) + 10) ++ "GiB"))
            (T.pack (show (gibibytes (budgetStorageBytes b) + 80) ++ "GiB"))
        )

{- | A case's live environment: the resolved host config and its isolated
per-case cluster plan.
-}
data CaseEnv = CaseEnv HostConfig ClusterPlan

{- | The demo's harness seams. Each case brings up an **isolated per-case kind
cluster** (the @TestCase@ profile — name @hostbootstrap-demo-test-<case>@, data
under @./.test_data/<case>/@) in @seamSetup@, runs its body, and — the point —
**tears that cluster down** in @seamTeardown@ via @clusterDelete@, which
'runMatrix' guarantees through @finally@ even when the body fails. The delete
preserves host @.data@ and is guarded to the per-case test name, so a harness
run can never touch a production cluster. These seams run where Docker + kind
are present (inside the demo VM / project container).
-}
demoSeams :: Seams CaseEnv
demoSeams =
    Seams
        { seamSetup = \c -> do
            cfg <- resolveHostConfig
            root <- getCurrentDirectory
            let plan = resolvePlan demoProject root (testCaseProfile c)
            putStrLn ("harness setup: cluster up " ++ clusterName plan)
            -- Create the isolated test cluster, then load the project image into it
            -- before the chart deploys — mirroring the production
            -- @deploy-kind → push-image → deploy-chart@ order. The chart's web pod
            -- pulls @hostbootstrap-demo:local@ with @IfNotPresent@; the per-case
            -- cluster has no registry to pull from, so without the kind-load the
            -- pod would ImagePullBackOff and the chart's @--wait@ would time out.
            clusterCreate cfg plan caseResources
            runOrDie cfg Kind ["load", "docker-image", demoProjectImage, "--name", clusterName plan]
            deployChart cfg plan
            pure (CaseEnv cfg plan)
        , seamRun = \(CaseEnv cfg plan) c -> case caseId c of
            "pristine-bootstrap" -> assertClusterLive cfg plan
            "web-build" -> assertWebBundle
            "e2e-tabs" -> assertE2E cfg plan
            other -> pure (Fail ("unknown demo case: " ++ other))
        , seamTeardown = \(CaseEnv cfg plan) _ -> do
            putStrLn ("harness teardown: cluster delete " ++ clusterName plan ++ " (preserving .data)")
            clusterDelete cfg plan
        }

-- | Per-case assertion: the kind cluster the case stood up is live.
assertClusterLive :: HostConfig -> ClusterPlan -> IO CaseResult
assertClusterLive cfg plan = do
    result <- runTool cfg Kind ["get", "clusters"]
    pure $ case result of
        Right (ExitSuccess, out, _)
            | clusterName plan `elem` lines out -> Pass
        _ -> Fail ("cluster " ++ clusterName plan ++ " is not live")

-- | Per-case assertion: the web build produced the bundled SPA.
assertWebBundle :: IO CaseResult
assertWebBundle = do
    built <- doesFileExist "web/public/app.js"
    pure $
        if built
            then Pass
            else Fail "web bundle web/public/app.js is missing from the project image (the Dockerfile's `web bridge` + spago + esbuild stage builds it)"

{- | Per-case assertion: the Playwright e2e passes against the in-cluster
webservice, reached through its NodePort. The project image is already
kind-loaded and the chart deployed in 'seamSetup'; this waits for the
webservice to answer on its NodePort — reached over the @kind@ container
network at @\<cluster\>-control-plane:30080@, not a host port — then runs the
base-provided Playwright against it.
-}
assertE2E :: HostConfig -> ClusterPlan -> IO CaseResult
assertE2E cfg plan = do
    let baseUrl = "http://" ++ clusterName plan ++ "-control-plane:30080"
    ready <- waitNodePort cfg (baseUrl ++ "/api/budget") 72
    if not ready
        then pure (Fail "e2e: the in-cluster webservice did not become reachable via its NodePort")
        else do
            result <-
                runTool
                    cfg
                    Docker
                    [ "run"
                    , "--rm"
                    , "--network"
                    , "kind"
                    , "--entrypoint"
                    , "sh"
                    , "-e"
                    , "BASE_URL=" ++ baseUrl
                    , "-e"
                    , "NODE_PATH=" ++ baseNodeModulesPath
                    , demoProjectImage
                    , "-lc"
                    , "cd /workspace/demo/playwright && playwright test"
                    ]
            pure $ case result of
                Right (ExitSuccess, _, _) -> Pass
                Right (_, _, err) -> Fail ("e2e failed: " ++ err)
                Left err -> Fail ("e2e: " ++ err)

{- | Poll the in-cluster NodePort (via a curl container on the kind network) until
it serves, bounded by @n@ five-second attempts — the readiness check the e2e
probe validated (the @Service@ routes only to ready pods).
-}
waitNodePort :: HostConfig -> String -> Int -> IO Bool
waitNodePort _ _ 0 = pure False
waitNodePort cfg url n = do
    r <- runTool cfg Docker ["run", "--rm", "--network", "kind", "curlimages/curl:latest", "-fsS", url]
    case r of
        Right (ExitSuccess, _, _) -> pure True
        _ -> threadDelay 5000000 >> waitNodePort cfg url (n - 1)

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

{- | The managed demo VM: a name carrying the delete-guard prefix and the
pristine @ubuntu/24.04@ image the from-zero bootstrap starts from.
-}
demoVM :: IncusVM
demoVM = IncusVM "hostbootstrap-demo-vm" "images:ubuntu/24.04"

demoLimaVM :: LimaVM
demoLimaVM = LimaVM "hostbootstrap-demo-vm"

{- | The name-prefix delete-guard for the demo's VM namespace; @vm down@ will
only destroy a VM/profile whose name starts with this.
-}
demoGuardPrefix :: String
demoGuardPrefix = "hostbootstrap-demo"

-- | The appended demo command tree (noun-first).
demoCommands :: [ProjectCommand]
demoCommands = [incusCmd, vmCmd, webCmd]

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

data DemoVMProvider
    = AppleLimaVM LimaVM
    | LinuxIncusVM IncusVM

demoVMProvider :: HostConfig -> IO DemoVMProvider
demoVMProvider cfg
    | isAppleSilicon (hcSubstrate cfg) = pure (AppleLimaVM demoLimaVM)
    | isLinux (hcSubstrate cfg) = pure (LinuxIncusVM demoVM)
    | otherwise = die "vm: unsupported substrate"

demoVMName :: DemoVMProvider -> String
demoVMName (AppleLimaVM vm) = limaName vm
demoVMName (LinuxIncusVM vm) = vmName vm

vmRepoRoot :: FilePath
vmRepoRoot = "/tmp/hostbootstrap"

{- | Where the project source lives inside the project container (the Dockerfile's
@COPY demo /workspace/demo@ + @WORKDIR@). The container-frame chain steps run
from here (for @./chart@); the minted container @<project>.dhall@ names it as
the @sourceRoot@.
-}
containerSourceRoot :: FilePath
containerSourceRoot = "/workspace/demo"

runInDemoVM :: HostConfig -> DemoVMProvider -> String -> IO ()
runInDemoVM cfg provider script = runInDemoVMStdin cfg provider script ""

{- | Like 'runInDemoVM', but pipe @stdin@ to the in-VM @bash -lc@ — the channel a
forwarded Docker Hub credential travels on (never @argv@). Used to authenticate
the in-VM base-image pull of build #3 (see 'HostBootstrap.Registry').
-}
runInDemoVMStdin :: HostConfig -> DemoVMProvider -> String -> String -> IO ()
runInDemoVMStdin cfg provider script input =
    case provider of
        AppleLimaVM vm -> runOrDieStdin cfg Lima (LimaVM.shellVMArgs vm ["bash", "-lc", script]) input
        LinuxIncusVM vm -> runOrDieStdin cfg Incus (execVMArgs vm ["bash", "-lc", script]) input

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

incusCmd :: ProjectCommand
incusCmd =
    projectCommand
        "incus"
        ( info
            (hsubparser ensureSub)
            (progDesc "incus host-provider verbs")
        )
  where
    ensureSub =
        command
            "ensure"
            ( info
                (pure ensureIncus)
                (progDesc "install-and-verify incus and its VM capability")
            )

{- | @demo incus ensure@: run the core @ensure incus@ reconciler (install+verify
a usable provider: Colima-backed on Apple, native daemon plus @incus-admin@
membership on Linux). On Linux, also ensure the VM capability the core
reconciler does not cover — the @qemu-system-x86@ machine emulator and
@ovmf@ UEFI firmware incus VMs require — and restart the daemon so it
re-detects QEMU. Idempotent: a satisfied host is a verified no-op.
-}
ensureIncus :: IO ()
ensureIncus = demoAction Context.HostOrchestratorCommand [Context.IncusProvider] ensureIncusProvider

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

vmCmd :: ProjectCommand
vmCmd =
    projectCommand
        "vm"
        ( info
            (hsubparser (vmEnsure <> vmUp <> vmDown <> vmBootstrap))
            (progDesc "fresh Linux VM lifecycle and the pristine-host bootstrap")
        )
  where
    vmEnsure =
        command
            "ensure"
            (info (pure runVmEnsure) (progDesc "install-and-verify the VM provider for this substrate"))
    vmUp =
        command
            "up"
            (info (pure runVmUp) (progDesc "launch a budget-sized pristine ubuntu/24.04 VM (cordon #1: the VM is the wall)"))
    vmDown =
        command
            "down"
            (info (pure runVmDown) (progDesc "destroy the demo VM (refused unless the name carries the guard prefix)"))
    vmBootstrap =
        command
            "pristine-bootstrap"
            (info (pure runVmBootstrap) (progDesc "apt/pipx/ghcup -> hostbootstrap run (build #2 host-native) -> ensure docker + docker build (build #3 project image), in the VM"))

{- | @demo vm ensure@: use a Lima VM on Apple Silicon and native
Incus on Linux.
-}
runVmEnsure :: IO ()
runVmEnsure = demoAction Context.HostOrchestratorCommand [Context.HostTools] $ do
    cfg <- resolveHostConfig
    if isAppleSilicon (hcSubstrate cfg)
        then do
            runEnsure EnsureLima.reconciler
            putStrLn "vm ensure: Apple Silicon uses a Lima VM (no Incus nested VM)"
        else ensureIncusProvider

{- | @demo vm up@: read the active context envelope, derive the VM sizing from
the one canonical parser, and launch the VM cordoned to it (cordon #1). Apple
Silicon starts a dedicated Lima VM; Linux launches an Incus VM.
-}
runVmUp :: IO ()
runVmUp = demoContext Context.HostOrchestratorCommand [Context.HostTools] $ \ctx -> do
    cfg <- resolveHostConfig
    provider <- demoVMProvider cfg
    let lifecycleResources = resourcesFromContext ctx
    either die pure (requireDemoLifecycleResources lifecycleResources)
    case provider of
        AppleLimaVM vm -> do
            sizing <- either die pure (vmSizingWithHeadroom lifecycleResources >>= limaSizingArgs)
            let argv = LimaVM.startVMArgs vm (sizing ++ ["--vm-type", "vz"])
            putStrLn ("vm up: launching Lima instance " ++ limaName vm ++ " (cordon #1, sized above the cluster budget) " ++ show sizing)
            runOrDie cfg Lima argv
            putStrLn ("vm up: waiting for " ++ limaName vm ++ " to answer")
            waitLimaVM cfg vm 60
            putStrLn ("vm up: launched " ++ limaName vm)
        LinuxIncusVM vm -> do
            sizing <- either die pure (vmSizingWithHeadroom lifecycleResources >>= incusSizingArgs)
            let argv = createVMArgs vm (concatMap toLaunchFlag sizing)
            putStrLn ("vm up: launching " ++ vmName vm ++ " (cordon #1, sized above the cluster budget) " ++ show sizing)
            runOrDie cfg Incus argv
            putStrLn ("vm up: waiting for the " ++ vmName vm ++ " guest agent to come up")
            waitVMAgent cfg vm 60
            putStrLn ("vm up: launched " ++ vmName vm)
  where
    toLaunchFlag a
        | "root," `isPrefixOf` a = ["-d", a]
        | otherwise = ["-c", a]

requireDemoLifecycleResources :: Resources -> Either String ()
requireDemoLifecycleResources actualResources = do
    actual <- budgetFromResources actualResources
    required <- budgetFromResources demoFullLifecycleResources
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
                    ++ "; regenerate the host config with `hostbootstrap run --project-root demo -- project init --role host-orchestrator --output .build/hostbootstrap-demo.dhall --source-root demo --dockerfile docker/Dockerfile --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1 --force`"
  where
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

{- | Poll @incus exec <vm> -- true@ until the VM's guest agent answers — an incus
VM accepts @incus exec@ only once its agent has started (a few seconds after
launch), so @vm up@ waits here rather than returning a VM that a chained
@pristine-bootstrap@ (or any immediate @incus exec@) would race. Bounded by @n@
two-second attempts.
-}
waitVMAgent :: HostConfig -> IncusVM -> Int -> IO ()
waitVMAgent _ vm 0 = die ("vm up: " ++ vmName vm ++ " guest agent did not become ready")
waitVMAgent cfg vm n = do
    r <- runTool cfg Incus (execVMArgs vm ["true"])
    case r of
        Right (ExitSuccess, _, _) -> pure ()
        _ -> threadDelay 2000000 >> waitVMAgent cfg vm (n - 1)

waitLimaVM :: HostConfig -> LimaVM -> Int -> IO ()
waitLimaVM _ vm 0 = die ("vm up: " ++ limaName vm ++ " did not become ready")
waitLimaVM cfg vm n = do
    r <- runTool cfg Lima (LimaVM.shellVMArgs vm ["true"])
    case r of
        Right (ExitSuccess, _, _) -> pure ()
        _ -> threadDelay 2000000 >> waitLimaVM cfg vm (n - 1)

{- | @demo vm pristine-bootstrap@: the from-zero first-run flow inside the VM
(the project source is staged at @/tmp/hostbootstrap@; see the runbook).
Provision the documented Linux host prerequisites (pipx + the @ghcup@ toolchain
pinned to GHC 9.12.4), @pipx install@ the local hostbootstrap, then run
@hostbootstrap run@ — which asserts the host minimums, ensures the toolchain,
and builds the demo binary **host-native** in the VM (**build #2**) before
exec'ing it (here with @context schema@, so the built binary proves itself).
-}
runVmBootstrap :: IO ()
runVmBootstrap = demoConfigContext Context.HostOrchestratorCommand [Context.HostTools] $ \parentCfg ctx -> do
    cfg <- resolveHostConfig
    provider <- demoVMProvider cfg
    -- Discovered on the metal host (the only place the credential lives); forwarded
    -- into the VM only over stdin for the build #3 base-image pull. 'Nothing' when
    -- the host is not logged in, in which case the pull stays anonymous.
    mAuth <- discoverHostRegistryAuth
    stageSource cfg provider (T.unpack (Context.sourceRoot ctx))
    writeAndCopyVMConfig cfg provider parentCfg ctx
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
        "hostbootstrap run (build #2: the demo binary, host-native in the VM)"
        (". \"$HOME/.ghcup/env\"; export PATH=\"$HOME/.local/bin:$PATH\"; cd " ++ shellQuote (vmRepoRoot ++ "/demo") ++ " && hostbootstrap run -- context schema")
    vmStep
        "install the in-VM pb + its sibling vm-orchestrator-1 config at /usr/local/bin (the metal->VM handoff SelfRef path)"
        ( "sudo install -m 0755 "
            ++ shellQuote (vmRepoRoot ++ "/demo/.build/hostbootstrap-demo")
            ++ " /usr/local/bin/hostbootstrap-demo && sudo cp "
            ++ shellQuote (vmRepoRoot ++ "/demo/.build/hostbootstrap-demo.dhall")
            ++ " /usr/local/bin/hostbootstrap-demo.dhall"
        )
    vmStep
        "ensure docker in the VM (install + start the daemon) — prerequisite for build #3"
        ("cd " ++ shellQuote (vmRepoRoot ++ "/demo") ++ " && .build/hostbootstrap-demo ensure docker")
    let buildImageScript =
            "cd "
                ++ shellQuote vmRepoRoot
                ++ " && docker build -f demo/docker/Dockerfile --build-arg BASE_IMAGE="
                ++ demoBaseImage cfg
                ++ " -t hostbootstrap-demo:local ."
    case mAuth of
        Just auth -> do
            putStrLn "pristine-bootstrap: build #3 — the project container FROM the base (authenticating the pull with the forwarded Docker Hub credential)"
            runInDemoVMStdin cfg provider (dockerAuthStdinWrapper buildImageScript) (T.unpack (registryConfigPayload auth))
        Nothing ->
            vmStep
                "build #3 — the project container FROM the pulled base (repo-root context, L0-direct; anonymous pull)"
                buildImageScript
    putStrLn "pristine-bootstrap: done (build #2 host-native + build #3 project image, in the VM)"

writeAndCopyVMConfig :: HostConfig -> DemoVMProvider -> ProjectConfig -> Context.BinaryContext -> IO ()
writeAndCopyVMConfig cfg provider parentCfg ctx = do
    let hostRoot = T.unpack (Context.sourceRoot ctx)
        localPath = hostRoot </> ".build" </> "hostbootstrap-demo.vm.dhall"
        remotePath = vmRepoRoot </> "demo" </> ".build" </> "hostbootstrap-demo.dhall"
        providerKind =
            case provider of
                AppleLimaVM _ -> Context.LimaVMProvider
                LinuxIncusVM _ -> Context.IncusVMProvider
        vmCfg =
            projectConfigFromContext
                (dockerfile parentCfg)
                (deploy parentCfg)
                (Context.deriveVMContextWithProvider providerKind ctx (T.pack (vmRepoRoot </> "demo")))
    createDirectoryIfMissing True (hostRoot </> ".build")
    writeProjectConfigFile localPath vmCfg
    runInDemoVM
        cfg
        provider
        ( "mkdir -p "
            ++ shellQuote (vmRepoRoot </> "demo" </> ".build")
            ++ " && sudo mkdir -p /run/hostbootstrap"
            ++ " && printf %s "
            ++ shellQuote (demoVMName provider)
            ++ " | sudo tee /run/hostbootstrap/vm-provider >/dev/null"
        )
    copyFileToDemoVM cfg provider localPath remotePath
    putStrLn ("pristine-bootstrap: copied parent-derived VM config to " ++ demoVMName provider ++ ":" ++ remotePath)

{- | The published base tag the demo's project container builds @FROM@ — cpu /
the detected VM architecture. The base is pulled inside the VM by build #3.
-}
demoBaseImage :: HostConfig -> String
demoBaseImage cfg =
    "docker.io/tuee22/hostbootstrap:basecontainer-cpu-" ++ renderArch (substrateArch (hcSubstrate cfg))

{- | Stage the project working tree into the VM at @/tmp/hostbootstrap@ — the
source @pipx install@ and the in-VM @hostbootstrap run@ build from. The host
working tree (uncommitted changes included) is tarred minus build/VCS
artifacts, pushed as a single file (@pushFileArgs@), and extracted in the VM.
Without this step the from-zero bootstrap has nothing to install — the runbook
documents the source as "staged at @/tmp/hostbootstrap@", and this is where
that staging happens.
-}
stageSource :: HostConfig -> DemoVMProvider -> FilePath -> IO ()
stageSource cfg provider sourceRoot = do
    cwd <- getCurrentDirectory
    let repoRoot =
            if "demo" `isSuffixOfPath` sourceRoot
                then sourceRoot ++ "/.."
                else cwd ++ "/.."
        tarball = repoRoot ++ "/.hostbootstrap-src.tgz"
    putStrLn ("pristine-bootstrap: staging the project source into " ++ demoVMName provider ++ ":" ++ vmRepoRoot)
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
    ( case provider of
            LinuxIncusVM vm -> do
                runOrDie cfg Incus (pushFileArgs vm tarball "/tmp/hostbootstrap-src.tgz")
                runInDemoVM cfg provider ("rm -rf " ++ shellQuote vmRepoRoot ++ " && mkdir -p " ++ shellQuote vmRepoRoot ++ " && tar -xzf /tmp/hostbootstrap-src.tgz -C " ++ shellQuote vmRepoRoot ++ " && rm -f /tmp/hostbootstrap-src.tgz")
            AppleLimaVM vm -> do
                runOrDie cfg Lima (LimaVM.copyToVMArgs vm tarball "/tmp/hostbootstrap-src.tgz")
                runInDemoVM cfg provider ("rm -rf " ++ shellQuote vmRepoRoot ++ " && mkdir -p " ++ shellQuote vmRepoRoot ++ " && tar -xzf /tmp/hostbootstrap-src.tgz -C " ++ shellQuote vmRepoRoot ++ " && rm -f /tmp/hostbootstrap-src.tgz")
        )
        `finally` removeFile tarball

copyFileToDemoVM :: HostConfig -> DemoVMProvider -> FilePath -> FilePath -> IO ()
copyFileToDemoVM cfg provider localPath remotePath =
    case provider of
        LinuxIncusVM vm -> runOrDie cfg Incus (pushFileArgs vm localPath remotePath)
        AppleLimaVM vm -> runOrDie cfg Lima (LimaVM.copyToVMArgs vm localPath remotePath)

isSuffixOfPath :: FilePath -> FilePath -> Bool
isSuffixOfPath suffix path =
    ("/" ++ suffix) `isSuffixOf` path || suffix == path

shellQuote :: String -> String
shellQuote s = "'" ++ concatMap quoteChar s ++ "'"
  where
    quoteChar '\'' = "'\\''"
    quoteChar c = [c]

-- | @demo vm down@: destroy the demo VM behind the name-prefix delete-guard.
runVmDown :: IO ()
runVmDown = demoAction Context.HostOrchestratorCommand [Context.HostTools] $ do
    cfg <- resolveHostConfig
    provider <- demoVMProvider cfg
    case provider of
        AppleLimaVM vm ->
            case LimaVM.deleteVMArgs demoGuardPrefix vm of
                Left err -> die err
                Right argv -> do
                    putStrLn ("vm down: destroying Lima instance " ++ limaName vm)
                    runOrDie cfg Lima argv
                    putStrLn ("vm down: destroyed " ++ limaName vm)
        LinuxIncusVM vm ->
            case destroyVMArgs demoGuardPrefix vm of
                Left err -> die err
                Right argv -> do
                    putStrLn ("vm down: destroying " ++ vmName vm)
                    runOrDie cfg Incus argv
                    putStrLn ("vm down: destroyed " ++ vmName vm)

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
    provider <- demoVMProvider cfg
    let name = demoVMName provider
    case provider of
        AppleLimaVM vm
            | destroyVM -> guardedDelete cfg Lima name (LimaVM.deleteVMArgs demoGuardPrefix vm)
            | otherwise ->
                bestEffortTool cfg Lima (LimaVM.stopVMArgs vm) ("project down: stopping Lima instance " ++ name)
        LinuxIncusVM vm
            | destroyVM -> guardedDelete cfg Incus name (destroyVMArgs demoGuardPrefix vm)
            | otherwise ->
                bestEffortTool cfg Incus (stopVMArgs vm) ("project down: stopping " ++ name)
  where
    guardedDelete cfg tool name =
        either die (\argv -> bestEffortTool cfg tool argv ("project destroy: deleting " ++ name))

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

{- | The minted project-container child @<project>.dhall@ path in the VM: the
@context-init@ chain step writes it and 'demoDeployImage' mounts it into the
container at the binary's sibling-config path.
-}
vmRuntimeContainerConfigPath :: FilePath
vmRuntimeContainerConfigPath = "/tmp/hostbootstrap/demo/.build/hostbootstrap-demo.runtime-container.dhall"

-- | The container frame's topology id (the @vm-project-container-2@ witness).
containerRuntimeFrameId :: String
containerRuntimeFrameId = "vm-project-container-2"

webCmd :: ProjectCommand
webCmd =
    projectCommand
        "web"
        ( info
            (hsubparser (webServe <> webBridge))
            (progDesc "the servant webservice + purescript-bridge SPA")
        )
  where
    webServe =
        command
            "serve"
            (info (pure (demoAction Context.ServiceCommand [] (serveWeb 8080))) (progDesc "serve the warp/wai webservice (the Playwright baseURL)"))
    webBridge =
        command
            "bridge"
            (info (pure (demoAction Context.ConfigGenerationCommand [] (writeBridge "web/src/Generated"))) (progDesc "generate the PureScript types from the API via purescript-bridge"))

{- | The project container the chain's container frame runs in: the demo image, with the
host Docker socket mounted (so kind nodes are siblings on the VM daemon) and
host networking. It also forwards the Docker Hub credential by /name/ only
(@-e HOSTBOOTSTRAP_REGISTRY_AUTH@) — never the value, which the lift pipes in
over stdin — so the in-container kind/curl pulls authenticate; with no host
login the variable is unset and pulls stay anonymous (see "HostBootstrap.Registry").
-}
demoDeployImage :: ContainerLift
demoDeployImage =
    ContainerLift
        { clImage = "hostbootstrap-demo:local"
        , clMounts =
            [ Mount "/var/run/docker.sock" "/var/run/docker.sock" False
            , Mount (T.pack vmRuntimeContainerConfigPath) "/usr/local/bin/hostbootstrap-demo.dhall" True
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
        }

-- The demo's CLI tree (the project-extension seam): the @incus@ / @vm@
-- provider+VM verbs and the @web@ verb the chart pod and Dockerfile depend on.
-- The deploy itself is the contributed @demoChain@ that @project up@ interprets.
