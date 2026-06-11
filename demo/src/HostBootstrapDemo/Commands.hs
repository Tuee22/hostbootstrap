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
--   * test harness — the inherited @test@ verb drives the matrix over 'demoCases'
--     with 'demoSeams' (the app supplies only its case matrix; the @(Seams, Cases)@
--     pair is threaded into @test@ via @runHostBootstrapCLI@ in @app/Main.hs@).
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

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import HostBootstrap.Cluster.Cordon (incusSizingArgs)
import HostBootstrap.Cluster.Lifecycle (ClusterPlan (..), ClusterProfile (Production), clusterDelete, clusterUp, resolvePlan)
import HostBootstrap.Config.Schema (Resources (..), StaticBase (..), decodeStaticBaseFile)
import HostBootstrap.Config.Vocab (Budget (..), Mount (..), PodResources (..))
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf, coreArtifacts, schemaUnion)
import HostBootstrap.Ensure (runEnsure, runTool)
import qualified HostBootstrap.Ensure.Incus as Incus
import HostBootstrap.Harness (Case (..), CaseResult (..), Seams (..), testCaseProfile)
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Helm, Incus, Kind, Sudo), toolCommandName)
import HostBootstrap.Incus (IncusVM (..), createVMArgs, destroyVMArgs, execVMArgs, pushFileArgs)
import HostBootstrap.Lift (ContainerLift (..))
import HostBootstrap.Substrate (detect)
import qualified HostBootstrapDemo.Chain as Chain
import qualified HostBootstrapDemo.Role as Role
import HostBootstrapDemo.Web.Bridge (writeBridge)
import HostBootstrapDemo.Web.Server (serveWeb)
import Options.Applicative
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..), die)
import System.Process (readProcessWithExitCode)

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
      seamRun = \(CaseEnv cfg plan) c -> case caseId c of
        "pristine-bootstrap" -> assertClusterLive cfg plan
        "web-build" -> assertWebBundle
        "e2e-tabs" -> assertE2E cfg plan
        other -> pure (Fail ("unknown demo case: " ++ other)),
      seamTeardown = \(CaseEnv cfg plan) _ -> do
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

-- | Per-case assertion: the Playwright e2e passes against the in-cluster
-- webservice, reached through its NodePort. Lifts a Playwright container onto the
-- kind docker network and points it at the control-plane node's NodePort
-- (live-gated: needs the chart deployed and the e2e image).
assertE2E :: HostConfig -> ClusterPlan -> IO CaseResult
assertE2E cfg plan = do
  cwd <- getCurrentDirectory
  let baseUrl = "http://" ++ clusterName plan ++ "-control-plane:30080"
      specVol = "hostbootstrap-demo-e2e-spec-" ++ clusterName plan
      specDir = cwd ++ "/playwright"
  -- Make the project image available to the per-case cluster (the chart pod runs it).
  loaded <- runTool cfg Kind ["load", "docker-image", "hostbootstrap-demo:local", "--name", clusterName plan]
  case loaded of
    Left err -> pure (Fail ("e2e: kind load: " ++ err))
    Right (ExitFailure n, _, err) -> pure (Fail ("e2e: kind load exit " ++ show n ++ " " ++ err))
    Right (ExitSuccess, _, _) -> do
      ready <- waitNodePort cfg (baseUrl ++ "/api/budget") 72
      if not ready
        then pure (Fail "e2e: the in-cluster webservice did not become reachable via its NodePort")
        else do
          -- Deliver the spec through a named volume via `docker cp` (which streams from the
          -- harness's own filesystem, host or in-container) rather than a bind mount of a path
          -- the daemon would resolve on the host — so the e2e lifts into any context.
          delivered <- deliverSpec cfg specVol specDir
          case delivered of
            Left err -> pure (Fail ("e2e: spec delivery: " ++ err))
            Right () -> do
              result <-
                runTool
                  cfg
                  Docker
                  [ "run",
                    "--rm",
                    "--network",
                    "kind",
                    "-e",
                    "BASE_URL=" ++ baseUrl,
                    "-v",
                    specVol ++ ":/src:ro",
                    playwrightImage,
                    "sh",
                    "-lc",
                    "cp -r /src /work && cd /work && npm install --no-audit --no-fund && npx playwright test"
                  ]
              _ <- runTool cfg Docker ["volume", "rm", "-f", specVol]
              pure $ case result of
                Right (ExitSuccess, _, _) -> Pass
                Right (_, _, err) -> Fail ("e2e failed: " ++ err)
                Left err -> Fail ("e2e: " ++ err)

-- | Populate a named Docker volume with the Playwright spec by @docker cp@-ing it from
-- the harness's own filesystem into a throwaway container that mounts the volume. @docker
-- cp@ reads the source on the client side, so this works whether the harness runs on the
-- host or is itself lifted into the project container — the bind-mount alternative would
-- have the daemon resolve the path on the host and find nothing.
deliverSpec :: HostConfig -> String -> FilePath -> IO (Either String ())
deliverSpec cfg vol specDir = do
  let tmpName = vol ++ "-load"
  _ <- runTool cfg Docker ["volume", "rm", "-f", vol]
  _ <- runTool cfg Docker ["rm", "-f", tmpName]
  created <- runTool cfg Docker ["create", "--name", tmpName, "-v", vol ++ ":/spec", specLoaderImage]
  case created of
    Left err -> pure (Left err)
    Right (ExitFailure n, _, err) -> pure (Left ("create exit " ++ show n ++ " " ++ err))
    Right (ExitSuccess, _, _) -> do
      copied <- runTool cfg Docker ["cp", specDir ++ "/.", tmpName ++ ":/spec"]
      _ <- runTool cfg Docker ["rm", "-f", tmpName]
      pure $ case copied of
        Right (ExitSuccess, _, _) -> Right ()
        Right (ExitFailure n, _, err) -> Left ("cp exit " ++ show n ++ " " ++ err)
        Left err -> Left err

-- | Poll the in-cluster NodePort (via a curl container on the kind network) until
-- it serves, bounded by @n@ five-second attempts — the readiness check the e2e
-- probe validated (the @Service@ routes only to ready pods).
waitNodePort :: HostConfig -> String -> Int -> IO Bool
waitNodePort _ _ 0 = pure False
waitNodePort cfg url n = do
  r <- runTool cfg Docker ["run", "--rm", "--network", "kind", "curlimages/curl:latest", "-fsS", url]
  case r of
    Right (ExitSuccess, _, _) -> pure True
    _ -> threadDelay 5000000 >> waitNodePort cfg url (n - 1)

-- | The Playwright runner image the e2e seam lifts.
playwrightImage :: String
playwrightImage = "mcr.microsoft.com/playwright:v1.49.0-noble"

-- | A tiny image used only as the throwaway @docker create@ target whose mounted volume
-- the spec is @docker cp@-ed into (the container is never started). Reuses the image the
-- NodePort poll already pulls, so no extra layer is fetched.
specLoaderImage :: String
specLoaderImage = "curlimages/curl:latest"

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
demoCommands = [incusCmd, vmCmd, harborCmd, webCmd, deployCmd, roleCmd]

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
        (hsubparser (vmUp <> vmDown <> vmBootstrap))
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
        (info (pure runVmBootstrap) (progDesc "apt install pipx -> pipx install hostbootstrap -> hostbootstrap run (build #2 host-native in the VM)"))

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
  putStrLn ("vm up: waiting for the " ++ vmName demoVM ++ " guest agent to come up")
  waitVMAgent cfg demoVM 60
  putStrLn ("vm up: launched " ++ vmName demoVM)
  where
    toLaunchFlag a
      | "root," `isPrefixOf` a = ["-d", a]
      | otherwise = ["-c", a]

-- | Poll @incus exec <vm> -- true@ until the VM's guest agent answers — an incus
-- VM accepts @incus exec@ only once its agent has started (a few seconds after
-- launch), so @vm up@ waits here rather than returning a VM that a chained
-- @pristine-bootstrap@ (or any immediate @incus exec@) would race. Bounded by @n@
-- two-second attempts.
waitVMAgent :: HostConfig -> IncusVM -> Int -> IO ()
waitVMAgent _ vm 0 = die ("vm up: " ++ vmName vm ++ " guest agent did not become ready")
waitVMAgent cfg vm n = do
  r <- runTool cfg Incus (execVMArgs vm ["true"])
  case r of
    Right (ExitSuccess, _, _) -> pure ()
    _ -> threadDelay 2000000 >> waitVMAgent cfg vm (n - 1)

-- | @demo vm pristine-bootstrap@: the from-zero first-run flow inside the VM
-- (the project source is staged at @/root/hostbootstrap@; see the runbook).
-- Provision the documented Linux host prerequisites (pipx + the @ghcup@ toolchain
-- pinned to GHC 9.12.4), @pipx install@ the local hostbootstrap, then run
-- @hostbootstrap run@ — which asserts the host minimums, ensures the toolchain,
-- and builds the demo binary **host-native** in the VM (**build #2**) before
-- exec'ing it (here with @config schema@, so the built binary proves itself).
runVmBootstrap :: IO ()
runVmBootstrap = do
  cfg <- metalConfig
  stageSource cfg
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
    "pipx install --force /root/hostbootstrap"
  inVM
    "hostbootstrap run (build #2: the demo binary, host-native in the VM)"
    ". \"$HOME/.ghcup/env\"; export PATH=\"$HOME/.local/bin:$PATH\"; cd /root/hostbootstrap/demo && hostbootstrap run -- config schema"
  putStrLn "pristine-bootstrap: done (the demo binary built host-native in the VM and ran)"

-- | Stage the project working tree into the VM at @/root/hostbootstrap@ — the
-- source @pipx install@ and the in-VM @hostbootstrap run@ build from. The host
-- working tree (uncommitted changes included) is tarred minus build/VCS
-- artifacts, pushed as a single file (@pushFileArgs@), and extracted in the VM.
-- Without this step the from-zero bootstrap has nothing to install — the runbook
-- documents the source as "staged at @/root/hostbootstrap@", and this is where
-- that staging happens.
stageSource :: HostConfig -> IO ()
stageSource cfg = do
  cwd <- getCurrentDirectory
  let repoRoot = cwd ++ "/.." -- cwd is demo/; the repo root is its parent
      tarball = "/tmp/hostbootstrap-src.tgz"
  putStrLn ("pristine-bootstrap: staging the project source into " ++ vmName demoVM ++ ":/root/hostbootstrap")
  (tc, _, terr) <-
    readProcessWithExitCode
      "tar"
      [ "czf",
        tarball,
        "--exclude=.git",
        "--exclude=dist-newstyle",
        "--exclude=.build",
        "--exclude=node_modules",
        "--exclude=.test_data",
        "--exclude=.role-bus",
        "--exclude=.venv",
        "--exclude=*.tgz",
        "-C",
        repoRoot,
        "."
      ]
      ""
  case tc of
    ExitFailure _ -> die ("pristine-bootstrap: source tar failed: " ++ terr)
    ExitSuccess -> pure ()
  runOrDie cfg Incus (pushFileArgs demoVM tarball "/root/hostbootstrap-src.tgz")
  runOrDie
    cfg
    Incus
    ( execVMArgs
        demoVM
        [ "bash",
          "-lc",
          "rm -rf /root/hostbootstrap && mkdir -p /root/hostbootstrap && tar -xzf /root/hostbootstrap-src.tgz -C /root/hostbootstrap && rm -f /root/hostbootstrap-src.tgz"
        ]
    )

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

-- | @demo deploy [--dry-run]@: the demo's deploy chain (F1). The chain is a pure
-- value (see "HostBootstrapDemo.Chain"); @--dry-run@ prints the plan, while apply
-- lifts each step through the self-reference lift.
deployCmd :: Mod CommandFields (IO ())
deployCmd =
  command
    "deploy"
    ( info
        (Chain.runDeploy demoVM demoDeployImage <$> dryRunFlag)
        (progDesc "Run the demo deploy chain (operations lifted across contexts); --dry-run prints the plan")
    )
  where
    dryRunFlag =
      switch (long "dry-run" <> help "print the planned operation/context sequence without running it")

-- | The project container the deploy chain lifts into: the demo image, with the
-- host Docker socket mounted (so kind nodes are siblings on the VM daemon) and
-- host networking.
demoDeployImage :: ContainerLift
demoDeployImage =
  ContainerLift
    { clImage = "hostbootstrap-demo:local",
      clMounts = [Mount "/var/run/docker.sock" "/var/run/docker.sock" False],
      clExtraArgs = ["--network=host"],
      clRemoveAfter = True
    }

-- | @demo role serve|submit@ (F2): a stateless role over a toy bus + object-store
-- stand-in, dispatching budget-eval requests to the budget-fit engine. See
-- "HostBootstrapDemo.Role".
roleCmd :: Mod CommandFields (IO ())
roleCmd =
  command
    "role"
    ( info
        (hsubparser (serveSub <> submitSub))
        (progDesc "A stateless role over a toy bus + object store (the business-logic shape)")
    )
  where
    serveSub =
      command
        "serve"
        (info (pure Role.roleServe) (progDesc "drain the request topic: dispatch budget-eval requests to the engine"))
    submitSub =
      command
        "submit"
        (info (Role.roleSubmit <$> budgetArg) (progDesc "enqueue a budget-eval request (CPU MEMORY STORAGE)"))
    budgetArg =
      Budget
        <$> argument auto (metavar "CPU")
        <*> argument auto (metavar "MEMORY")
        <*> argument auto (metavar "STORAGE")
