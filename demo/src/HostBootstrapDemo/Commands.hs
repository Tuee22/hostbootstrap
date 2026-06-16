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
import HostBootstrap.Cluster.Lifecycle (ClusterPlan (..), ClusterProfile (Production), clusterDelete, clusterUp, resolvePlan)
import HostBootstrap.Config.Schema (ProjectConfig (..), Resources (..), projectConfigFromContext, withSiblingProjectConfigContext, writeProjectConfigFile)
import HostBootstrap.Config.Vocab (Budget (..), Mount (..), PodResources (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf)
import HostBootstrap.Ensure (runEnsure, runTool, runToolWithStdin)
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as EnsureLima
import HostBootstrap.Harness (Case (..), CaseResult (..), Seams (..), testCaseProfile)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Incus, Kind, Lima, Sudo), toolCommandName)
import HostBootstrap.Incus (IncusVM (..), createVMArgs, destroyVMArgs, execVMArgs, pushFileArgs)
import HostBootstrap.Lift (ContainerLift (..))
import HostBootstrap.Lima (LimaVM (..))
import qualified HostBootstrap.Lima as LimaVM
import HostBootstrap.Registry (discoverHostRegistryAuth, dockerAuthStdinWrapper, registryAuthEnvVar, registryConfigPayload)
import HostBootstrap.Substrate (detect, isAppleSilicon, isLinux, renderArch, substrateArch)
import qualified HostBootstrapDemo.Chain as Chain
import qualified HostBootstrapDemo.Role as Role
import HostBootstrapDemo.Web.Bridge (writeBridge)
import HostBootstrapDemo.Web.Server (serveWeb)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, removeFile, withCurrentDirectory)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
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
            cfg <- metalConfig
            root <- getCurrentDirectory
            let plan = resolvePlan demoProject root (testCaseProfile c)
            putStrLn ("harness setup: cluster up " ++ clusterName plan)
            clusterUp cfg plan caseResources
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
            else Fail "web bundle web/public/app.js is missing (run `web bridge` + spago build + esbuild)"

{- | Per-case assertion: the Playwright e2e passes against the in-cluster
webservice, reached through its NodePort. Starts the project image itself on
the kind docker network and points base-provided Playwright at the
control-plane node's NodePort (live-gated: needs the chart deployed and the
project image).
-}
assertE2E :: HostConfig -> ClusterPlan -> IO CaseResult
assertE2E cfg plan = do
    let baseUrl = "http://" ++ clusterName plan ++ "-control-plane:30080"
    -- Make the project image available to the per-case cluster (the chart pod runs it).
    loaded <- runTool cfg Kind ["load", "docker-image", demoProjectImage, "--name", clusterName plan]
    case loaded of
        Left err -> pure (Fail ("e2e: kind load: " ++ err))
        Right (ExitFailure n, _, err) -> pure (Fail ("e2e: kind load exit " ++ show n ++ " " ++ err))
        Right (ExitSuccess, _, _) -> do
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
demoCommands = [incusCmd, vmCmd, harborCmd, webCmd, deployCmd, roleCmd]

-- ---------------------------------------------------------------------------
-- Metal-host orchestration helpers.
-- ---------------------------------------------------------------------------

-- | Detect the substrate and resolve the metal host's tool configuration.
metalConfig :: IO HostConfig
metalConfig = do
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
    cfg <- metalConfig
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
    cfg <- metalConfig
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
    cfg <- metalConfig
    provider <- demoVMProvider cfg
    let lifecycleResources = resourcesFromContext ctx
    either die pure (requireDemoLifecycleResources lifecycleResources)
    case provider of
        AppleLimaVM vm -> do
            sizing <- either die pure (limaSizingArgs lifecycleResources)
            let argv = LimaVM.startVMArgs vm (sizing ++ ["--vm-type", "vz"])
            putStrLn ("vm up: launching Lima instance " ++ limaName vm ++ " cordoned to the budget " ++ show sizing)
            runOrDie cfg Lima argv
            putStrLn ("vm up: waiting for " ++ limaName vm ++ " to answer")
            waitLimaVM cfg vm 60
            putStrLn ("vm up: launched " ++ limaName vm)
        LinuxIncusVM vm -> do
            sizing <- either die pure (incusSizingArgs lifecycleResources)
            let argv = createVMArgs vm (concatMap toLaunchFlag sizing)
            putStrLn ("vm up: launching " ++ vmName vm ++ " cordoned to the budget " ++ show sizing)
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
                [ shortage "cpu" show show budgetCpu actual required
                , shortage "memory" showGiB showGiB budgetMemoryBytes actual required
                , shortage "storage" showGiB showGiB budgetStorageBytes actual required
                ]
    case shortages of
        [] -> Right ()
        _ ->
            Left $
                "demo vm up: resource budget too small for full demo lifecycle: "
                    ++ intercalate ", " shortages
                    ++ "; regenerate the host config with `hostbootstrap run --project-root demo -- config init --role host-orchestrator --output .build/hostbootstrap-demo.dhall --source-root demo --dockerfile docker/Dockerfile --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1 --force`"
  where
    shortage label renderActual renderRequired field actual required
        | field actual < field required =
            [ label
                ++ " has "
                ++ renderActual (field actual)
                ++ ", needs at least "
                ++ renderRequired (field required)
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
exec'ing it (here with @config schema@, so the built binary proves itself).
-}
runVmBootstrap :: IO ()
runVmBootstrap = demoConfigContext Context.HostOrchestratorCommand [Context.HostTools] $ \parentCfg ctx -> do
    cfg <- metalConfig
    provider <- demoVMProvider cfg
    -- Discovered on the metal host (the only place the credential lives); forwarded
    -- into the VM only over stdin for the build #3 base-image pull. 'Nothing' when
    -- the host is not logged in, in which case the pull stays anonymous.
    mAuth <- discoverHostRegistryAuth
    stageSource cfg provider (T.unpack (Context.sourceRoot ctx))
    writeAndCopyVMConfig cfg provider parentCfg ctx
    let inVM label script = do
            putStrLn ("pristine-bootstrap: " ++ label)
            runInDemoVM cfg provider script
    inVM
        "apt install pipx + GHC build prerequisites"
        "export DEBIAN_FRONTEND=noninteractive; sudo -E apt-get update -qq && sudo -E apt-get install -y -qq pipx python3-venv build-essential curl libgmp-dev libtinfo-dev libncurses-dev zlib1g-dev pkg-config git ca-certificates"
    inVM
        "ensure the ghcup toolchain (GHC 9.12.4 + cabal) — the documented Linux host prerequisite"
        "test -x \"$HOME/.ghcup/bin/ghcup\" || { export BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=9.12.4 BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1; curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh; }"
    inVM
        "pipx install the local hostbootstrap CLI"
        ("pipx install --force " ++ shellQuote vmRepoRoot)
    inVM
        "hostbootstrap run (build #2: the demo binary, host-native in the VM)"
        (". \"$HOME/.ghcup/env\"; export PATH=\"$HOME/.local/bin:$PATH\"; cd " ++ shellQuote (vmRepoRoot ++ "/demo") ++ " && hostbootstrap run -- config schema")
    inVM
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
            inVM
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
    case tc of
        ExitFailure _ -> die ("pristine-bootstrap: source tar failed: " ++ terr)
        ExitSuccess -> pure ()
    case provider of
        LinuxIncusVM vm -> do
            runOrDie cfg Incus (pushFileArgs vm tarball "/tmp/hostbootstrap-src.tgz")
            runInDemoVM cfg provider ("rm -rf " ++ shellQuote vmRepoRoot ++ " && mkdir -p " ++ shellQuote vmRepoRoot ++ " && tar -xzf /tmp/hostbootstrap-src.tgz -C " ++ shellQuote vmRepoRoot ++ " && rm -f /tmp/hostbootstrap-src.tgz")
        AppleLimaVM vm -> do
            runOrDie cfg Lima (LimaVM.copyToVMArgs vm tarball "/tmp/hostbootstrap-src.tgz")
            runInDemoVM cfg provider ("rm -rf " ++ shellQuote vmRepoRoot ++ " && mkdir -p " ++ shellQuote vmRepoRoot ++ " && tar -xzf /tmp/hostbootstrap-src.tgz -C " ++ shellQuote vmRepoRoot ++ " && rm -f /tmp/hostbootstrap-src.tgz")
    removeFile tarball

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
    cfg <- metalConfig
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

harborCmd :: ProjectCommand
harborCmd =
    projectCommand
        "harbor"
        ( info
            (hsubparser (harborInstall <> harborPush))
            (progDesc "in-VM kind + Harbor registry")
        )
  where
    harborInstall =
        command
            "install"
            (info (pure runHarborInstall) (progDesc "core `cluster up` (cordon #2) + install the Harbor registry via Helm"))
    harborPush =
        command
            "push"
            (info (runHarborPush <$> imageArg) (progDesc "tag + push the project image to the in-cluster registry"))
    imageArg =
        strArgument (metavar "IMAGE" <> value "hostbootstrap-demo:local" <> showDefault <> help "local image to push")

-- | The in-cluster registry endpoint (a NodePort the demo publishes Harbor on).
harborEndpoint :: String
harborEndpoint = "localhost:30500"

{- | @demo harbor install@: bring the cluster up within the budget (cordon #2 —
the applied @docker update@ kind-node cap), then install the Harbor registry
via its Helm chart (HTTP NodePort, the demo's in-cluster registry). Runs where
Docker + kind + Helm are present (inside the VM / project container).
-}
runHarborInstall :: IO ()
runHarborInstall = demoContext Context.ClusterLifecycleCommand [] $ \ctx -> do
    cfg <- metalConfig
    let root = T.unpack (Context.sourceRoot ctx)
        plan = resolvePlan demoProject root Production
    withCurrentDirectory root $ do
        putStrLn "harbor install: cluster up (cordon #2) then Helm-install Harbor"
        clusterUp cfg plan (resourcesFromContext ctx)
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
            ]
        putStrLn ("harbor install: Harbor reachable at http://" ++ harborEndpoint)

{- | @demo harbor push@: tag the project image to the in-cluster registry and push
it (the arch-explicit tag is then pullable from inside the cluster).
-}
runHarborPush :: String -> IO ()
runHarborPush image = demoAction Context.ProjectCommand [] $ do
    cfg <- metalConfig
    let ref = harborEndpoint ++ "/library/hostbootstrap-demo:demo"
    putStrLn ("harbor push: " ++ image ++ " -> " ++ ref)
    runOrDie cfg Docker ["tag", image, ref]
    runOrDie cfg Docker ["push", ref]
    putStrLn ("harbor push: pushed " ++ ref)

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

{- | @demo deploy [--dry-run]@: the demo's deploy chain (F1). The chain is a pure
value (see "HostBootstrapDemo.Chain"); @--dry-run@ prints the plan, while apply
lifts each step through the self-reference lift.
-}
deployCmd :: ProjectCommand
deployCmd =
    projectCommand
        "deploy"
        ( info
            (runDeploy <$> dryRunFlag)
            (progDesc "Run the demo deploy chain (operations lifted across contexts); --dry-run prints the plan")
        )
  where
    runDeploy dryRun =
        demoAction Context.HostOrchestratorCommand [Context.HostTools] (Chain.runDeploy demoVM demoLimaVM demoDeployImage dryRun)
    dryRunFlag =
        switch (long "dry-run" <> help "print the planned operation/context sequence without running it")

{- | The project container the deploy chain lifts into: the demo image, with the
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
            , Mount (T.pack Chain.vmRuntimeContainerConfigPath) "/usr/local/bin/hostbootstrap-demo.dhall" True
            , Mount "/run/hostbootstrap" "/run/hostbootstrap" True
            ]
        , clExtraArgs =
            [ "--network=host"
            , "-e"
            , "HOSTBOOTSTRAP_CURRENT_FRAME=" ++ Chain.containerRuntimeFrameId
            , "-e"
            , registryAuthEnvVar
            ]
        , clRemoveAfter = True
        }

{- | @demo role serve|submit@ (F2): a stateless role over a toy bus + object-store
stand-in, dispatching budget-eval requests to the budget-fit engine. See
"HostBootstrapDemo.Role".
-}
roleCmd :: ProjectCommand
roleCmd =
    projectCommand
        "role"
        ( info
            (hsubparser (serveSub <> submitSub))
            (progDesc "A stateless role over a toy bus + object store (the business-logic shape)")
        )
  where
    serveSub =
        command
            "serve"
            (info (pure (demoAction Context.ServiceCommand [] Role.roleServe)) (progDesc "drain the request topic: dispatch budget-eval requests to the engine"))
    submitSub =
        command
            "submit"
            (info (demoAction Context.ProjectCommand [] . Role.roleSubmit <$> budgetArg) (progDesc "enqueue a budget-eval request (CPU MEMORY STORAGE)"))
    budgetArg =
        Budget
            <$> argument auto (metavar "CPU")
            <*> argument auto (metavar "MEMORY")
            <*> argument auto (metavar "STORAGE")
