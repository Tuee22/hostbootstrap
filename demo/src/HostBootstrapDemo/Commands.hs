{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The hostbootstrap-demo project commands and the four-stream extension
-- demonstration.
--
-- The demo groups its project verbs under nouns (@incus@/@vm@/@harbor@/@web@),
-- distinct from the inherited verb-first core verbs, and exercises the
-- additive extension streams:
--
--   * CLI tree — 'demoCommands' is appended to the core tree via
--     @runHostBootstrapCLI@ (append, never shadow);
--   * schema-gen registry — @demo web schema@ prints @coreArtifacts ++
--     demoArtifacts@ (registry concatenation);
--   * test harness — @demo vm test@ drives @runMatrix@ over 'demoCases' with
--     'demoSeams' (the app supplies only its case matrix).
--
-- The orchestration verbs (@incus@/@vm@) drive the real incus host-provider
-- surface from @hostbootstrap-core@: @incus ensure@ installs+verifies incus and
-- its VM capability, @vm up@ launches a budget-cordoned VM (cordon #1), and
-- @vm down@ tears it down behind the name-prefix delete-guard. The metal-side
-- verbs resolve and run @incus@ directly, so they run as a user that can reach
-- the incus socket (run via @sudo@, or as a member of the @incus-admin@ group).
module HostBootstrapDemo.Commands
  ( demoCommands,
    demoArtifacts,
    demoCases,
    demoSeams,
    demoVM,
    demoGuardPrefix,
  )
where

import Control.Monad (unless)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import HostBootstrap.Cluster.Cordon (incusSizingArgs)
import HostBootstrap.Cluster.Lifecycle (ClusterPlan (..), ClusterProfile (Production), clusterDelete, clusterUp, resolvePlan)
import HostBootstrap.Config.Schema (Resources (..), StaticBase (..), decodeStaticBaseFile)
import HostBootstrap.Config.Vocab (PodResources (..))
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf, coreArtifacts, schemaUnion)
import HostBootstrap.Ensure (runEnsure, runTool)
import qualified HostBootstrap.Ensure.Incus as Incus
import HostBootstrap.Harness (Case (..), CaseResult (..), Seams (..), reportCard, runMatrix, testCaseProfile)
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Incus, Kind, Sudo), toolCommandName)
import HostBootstrap.Incus (IncusVM (..), createVMArgs, destroyVMArgs, execVMArgs)
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Web.Bridge (writeBridge)
import HostBootstrapDemo.Web.Server (serveWeb)
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), die)

-- | The demo's schema-gen artifacts, appended to @coreArtifacts@ (the registry
-- concatenation stream). A demo web-pod footprint reflected from the vocabulary.
demoArtifacts :: [ConfigArtifact]
demoArtifacts =
  [ artifactOf @PodResources "demoWeb" (PodResources 2 1 1 1 2)
  ]

-- | The demo's harness case matrix (the app supplies only this; the L0 engine
-- drives it). The headline @pristine-bootstrap@ case plus the web/e2e cases.
demoCases :: [Case]
demoCases =
  [ Case "pristine-bootstrap" 1 False,
    Case "web-build" 1 False,
    Case "e2e-tabs" 1 False
  ]

-- | The demo project name (used to resolve per-case cluster plans).
demoProject :: String
demoProject = "hostbootstrap-demo"

-- | The per-case cluster budget — a slice small enough to fit inside the
-- budget-sized VM's spare capacity (the full project budget is the VM wall).
caseResources :: Resources
caseResources = Resources 2 "2GiB" "10GiB"

-- | A case's live environment: the resolved host config and its isolated
-- per-case cluster plan.
data CaseEnv = CaseEnv HostConfig ClusterPlan

-- | The demo's harness seams. Each case brings up an **isolated per-case kind
-- cluster** (the @TestCase@ profile — name @hostbootstrap-demo-test-<case>@, data
-- under @./.test_data/<case>/@) in @seamSetup@, runs its body, and — the point —
-- **tears that cluster down** in @seamTeardown@ via @clusterDelete@, which
-- 'runMatrix' guarantees through @finally@ even when the body fails. The delete
-- preserves host @.data@ and is guarded to the per-case test name, so a harness
-- run can never touch a production cluster. These seams run where Docker + kind
-- are present (inside the demo VM / project container).
demoSeams :: Seams CaseEnv
demoSeams =
  Seams
    { seamSetup = \c -> do
        cfg <- metalConfig
        root <- getCurrentDirectory
        let plan = resolvePlan demoProject root (testCaseProfile c)
        putStrLn ("harness setup: cluster up " ++ clusterName plan)
        clusterUp cfg plan caseResources
        pure (CaseEnv cfg plan),
      seamRun = \(CaseEnv cfg plan) _ -> do
        result <- runTool cfg Kind ["get", "clusters"]
        pure $ case result of
          Right (ExitSuccess, out, _)
            | clusterName plan `elem` lines out -> Pass
          _ -> Fail ("cluster " ++ clusterName plan ++ " is not live"),
      seamTeardown = \(CaseEnv cfg plan) _ -> do
        putStrLn ("harness teardown: cluster delete " ++ clusterName plan ++ " (preserving .data)")
        clusterDelete cfg plan
    }

-- | The managed demo VM: a name carrying the delete-guard prefix and the
-- pristine @ubuntu/24.04@ image the from-zero bootstrap starts from.
demoVM :: IncusVM
demoVM = IncusVM "hostbootstrap-demo-vm" "images:ubuntu/24.04"

-- | The name-prefix delete-guard for the demo's incus namespace; @vm down@ will
-- only destroy a VM whose name starts with this (see
-- 'HostBootstrap.Incus.destroyVMArgs').
demoGuardPrefix :: String
demoGuardPrefix = "hostbootstrap-demo"

-- | The appended demo command tree (noun-first).
demoCommands :: [Mod CommandFields (IO ())]
demoCommands = [incusCmd, vmCmd, harborCmd, webCmd]

-- ---------------------------------------------------------------------------
-- Metal-host orchestration helpers (the demo resolves and runs incus directly)
-- ---------------------------------------------------------------------------

-- | Detect the substrate and resolve the metal host's tool configuration.
metalConfig :: IO HostConfig
metalConfig = do
  detected <- detect
  either die buildHostConfig detected

-- | Run a resolved host tool, streaming its stdout and dying with the captured
-- stderr on a non-zero exit.
runOrDie :: HostConfig -> HostTool -> [String] -> IO ()
runOrDie cfg tool args = do
  result <- runTool cfg tool args
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

incusCmd :: Mod CommandFields (IO ())
incusCmd =
  command
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
            (progDesc "install-and-verify incus and its VM capability (core `ensure incus` + qemu)")
        )

-- | @demo incus ensure@: run the core @ensure incus@ reconciler (install+verify
-- incus and @incus admin init@), then ensure the VM capability the reconciler
-- does not cover on Linux — the @qemu-system-x86@ machine emulator and @ovmf@
-- UEFI firmware incus VMs require — and restart the daemon so it re-detects
-- QEMU. Idempotent: a satisfied host is a verified no-op.
ensureIncus :: IO ()
ensureIncus = do
  runEnsure Incus.reconciler
  cfg <- metalConfig
  putStrLn "incus ensure: ensuring the VM capability (qemu-system-x86 + ovmf)"
  runOrDie cfg Sudo ["apt-get", "install", "-y", "qemu-system-x86", "ovmf"]
  runOrDie cfg Sudo ["systemctl", "restart", "incus"]
  putStrLn "incus ensure: ensuring incusbr0 egress past Docker's FORWARD policy"
  ensureBridgeForwarding cfg
  putStrLn "incus ensure: incus + VM capability present"

-- | When Docker is installed it sets the iptables @FORWARD@ policy to @DROP@ and
-- accepts only its own bridges, which strands incus VMs (no egress, so the in-VM
-- @apt@/@ghcup@/@docker pull@ all fail). Insert an @ACCEPT@ for @incusbr0@ into
-- Docker's @DOCKER-USER@ hook so VM traffic is forwarded. Idempotent, and a no-op
-- when Docker (hence the @DOCKER-USER@ chain) is absent.
ensureBridgeForwarding :: HostConfig -> IO ()
ensureBridgeForwarding cfg = mapM_ ensureRule ["-i", "-o"]
  where
    ensureRule dir =
      runOrDie
        cfg
        Sudo
        [ "bash",
          "-c",
          "iptables -nL DOCKER-USER >/dev/null 2>&1 || exit 0; "
            ++ "iptables -C DOCKER-USER "
            ++ dir
            ++ " incusbr0 -j ACCEPT 2>/dev/null "
            ++ "|| iptables -I DOCKER-USER "
            ++ dir
            ++ " incusbr0 -j ACCEPT"
        ]

vmCmd :: Mod CommandFields (IO ())
vmCmd =
  command
    "vm"
    ( info
        (hsubparser (vmUp <> vmDown <> vmBootstrap <> vmTest))
        (progDesc "incus VM lifecycle and the pristine-host bootstrap")
    )
  where
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
        (info (pure runVmBootstrap) (progDesc "apt install pipx -> pipx install hostbootstrap -> hostbootstrap up (build #2 host-native in the VM)"))
    vmTest =
      command
        "test"
        (info (pure runDemoTests) (progDesc "drive the demo harness over its case matrix (the harness stream)"))
    runDemoTests = runMatrix demoSeams demoCases >>= putStr . reportCard

-- | @demo vm up@: read the static-base budget, derive the incus VM sizing from
-- the one canonical parser ('incusSizingArgs'), and launch the VM cordoned to it
-- (cordon #1). The sizing list (@limits.cpu=…@, @limits.memory=…@, @root,size=…@)
-- is formatted into @incus launch@ flags: each @limits.*@ becomes a @-c@ config
-- flag and @root,size=…@ a @-d@ device override.
runVmUp :: IO ()
runVmUp = do
  staticBase <- decodeStaticBaseFile "hostbootstrap.dhall"
  sizing <- either die pure (incusSizingArgs (resources staticBase))
  cfg <- metalConfig
  let argv = createVMArgs demoVM (concatMap toLaunchFlag sizing)
  putStrLn ("vm up: launching " ++ vmName demoVM ++ " cordoned to the budget " ++ show sizing)
  runOrDie cfg Incus argv
  putStrLn ("vm up: launched " ++ vmName demoVM)
  where
    toLaunchFlag a
      | "root," `isPrefixOf` a = ["-d", a]
      | otherwise = ["-c", a]

-- | @demo vm pristine-bootstrap@: the from-zero first-run flow inside the VM
-- (the project source is staged at @/root/hostbootstrap@; see the runbook).
-- Provision the documented Linux host prerequisites (pipx + the @ghcup@ toolchain
-- pinned to GHC 9.12.4), @pipx install@ the local hostbootstrap, then run
-- @hostbootstrap up@ — which asserts the host minimums, ensures the toolchain,
-- and builds the demo binary **host-native** in the VM (**build #2**) before
-- exec'ing it (here with @config schema@, so the built binary proves itself).
runVmBootstrap :: IO ()
runVmBootstrap = do
  cfg <- metalConfig
  let inVM label script = do
        putStrLn ("pristine-bootstrap: " ++ label)
        runOrDie cfg Incus (execVMArgs demoVM ["bash", "-lc", script])
  inVM
    "apt install pipx + GHC build prerequisites"
    "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq pipx python3-venv build-essential curl libgmp-dev libtinfo-dev libncurses-dev zlib1g-dev pkg-config git ca-certificates"
  inVM
    "ensure the ghcup toolchain (GHC 9.12.4 + cabal) — the documented Linux host prerequisite"
    "test -x \"$HOME/.ghcup/bin/ghcup\" || { export BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=9.12.4 BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1; curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh; }"
  inVM
    "pipx install the local hostbootstrap CLI"
    "pipx install --force /root/hostbootstrap/python"
  inVM
    "hostbootstrap up (build #2: the demo binary, host-native in the VM)"
    ". \"$HOME/.ghcup/env\"; export PATH=\"$HOME/.local/bin:$PATH\"; cd /root/hostbootstrap/demo && hostbootstrap up -- config schema"
  putStrLn "pristine-bootstrap: done (the demo binary built host-native in the VM and ran)"

-- | @demo vm down@: destroy the demo VM behind the name-prefix delete-guard.
runVmDown :: IO ()
runVmDown = do
  cfg <- metalConfig
  case destroyVMArgs demoGuardPrefix demoVM of
    Left err -> die err
    Right argv -> do
      putStrLn ("vm down: destroying " ++ vmName demoVM)
      runOrDie cfg Incus argv
      putStrLn ("vm down: destroyed " ++ vmName demoVM)

harborCmd :: Mod CommandFields (IO ())
harborCmd =
  command
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

-- | @demo harbor install@: bring the cluster up within the budget (cordon #2 —
-- the applied @docker update@ kind-node cap), then install the Harbor registry
-- via its Helm chart (HTTP NodePort, the demo's in-cluster registry). Runs where
-- Docker + kind + Helm are present (inside the VM / project container).
runHarborInstall :: IO ()
runHarborInstall = do
  cfg <- metalConfig
  root <- getCurrentDirectory
  staticBase <- decodeStaticBaseFile "hostbootstrap.dhall"
  let plan = resolvePlan demoProject root Production
  putStrLn "harbor install: cluster up (cordon #2) then Helm-install Harbor"
  clusterUp cfg plan (resources staticBase)
  runOrDie cfg Helm ["repo", "add", "harbor", "https://helm.goharbor.io"]
  runOrDie cfg Helm ["repo", "update"]
  runOrDie
    cfg
    Helm
    [ "upgrade",
      "--install",
      "harbor",
      "harbor/harbor",
      "--set",
      "expose.type=nodePort",
      "--set",
      "expose.tls.enabled=false",
      "--set",
      "expose.nodePort.ports.http.nodePort=30500",
      "--set",
      "externalURL=http://" ++ harborEndpoint
    ]
  putStrLn ("harbor install: Harbor reachable at http://" ++ harborEndpoint)

-- | @demo harbor push@: tag the project image to the in-cluster registry and push
-- it (the arch-explicit tag is then pullable from inside the cluster).
runHarborPush :: String -> IO ()
runHarborPush image = do
  cfg <- metalConfig
  let ref = harborEndpoint ++ "/library/hostbootstrap-demo:demo"
  putStrLn ("harbor push: " ++ image ++ " -> " ++ ref)
  runOrDie cfg Docker ["tag", image, ref]
  runOrDie cfg Docker ["push", ref]
  putStrLn ("harbor push: pushed " ++ ref)

webCmd :: Mod CommandFields (IO ())
webCmd =
  command
    "web"
    ( info
        (hsubparser (webServe <> webBridge <> webSchema))
        (progDesc "the servant webservice + purescript-bridge SPA")
    )
  where
    webServe =
      command
        "serve"
        (info (pure (serveWeb 8080)) (progDesc "serve the warp/wai webservice on the incus host (the Playwright baseURL)"))
    webBridge =
      command
        "bridge"
        (info (pure (writeBridge "web/src/Generated")) (progDesc "generate the PureScript types from the API via purescript-bridge"))
    webSchema =
      command
        "schema"
        (info (pure printSchema) (progDesc "print the L0 + demo schema union (the schema-gen extension stream)"))
    printSchema = putStrLn (T.unpack (schemaUnion (coreArtifacts ++ demoArtifacts)))
