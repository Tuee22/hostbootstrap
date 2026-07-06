-- | kind/Helm cluster-lifecycle semantics.
--
-- The cluster lifecycle drives kind/Helm @up@ / @down@ / @delete@, enforces the
-- never-delete-@.data@ invariant, and distinguishes the production cluster
-- profile (fixed name / @.data@ path) from the test profile (per-case isolated
-- paths). The plan resolution and the teardown partition are pure so the
-- invariants are unit-tested; the IO drivers run kind/Helm through resolved host
-- tools.
module HostBootstrap.Cluster.Lifecycle
  ( ClusterProfile (..),
    ClusterPlan (..),
    TeardownKind (..),
    resolvePlan,
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

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import HostBootstrap.Cluster.Cordon
  ( kindNodeCordonArgs,
    preflightBudget,
    resolveHostCapacity,
  )
import HostBootstrap.Context (ResourceEnvelope)
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Helm, Kind, Kubectl))
import HostBootstrap.Substrate (isLinux)
import System.Directory (doesDirectoryExist, doesFileExist, removePathForcibly)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))

-- | The cluster profile: production uses fixed names and the canonical @.data@
-- path; the test profile isolates each case under its own paths so a
-- harness-driven test never collides with a production cluster.
data ClusterProfile = Production | TestCase String
  deriving (Eq, Show)

-- | A resolved cluster plan: the kind cluster name, the never-deleted host
-- @.data@ path, the derived state safe to remove on @delete@, and whether this
-- cluster publishes the project's fixed host NodePorts (via @./kind.yaml@'s
-- @extraPortMappings@). Only the production cluster does — it is the persistent
-- stack the host reaches on @localhost:\<nodePort\>@. Test-case clusters set this
-- 'False' so they create a plain kind cluster with no host-port binding: several
-- isolated case clusters then coexist (and never collide with a running
-- production cluster) on the same host, and each case reaches its in-cluster
-- workload through the kind container network rather than a fixed host port.
data ClusterPlan = ClusterPlan
  { clusterName :: String,
    dataPath :: FilePath,
    derivedPaths :: [FilePath],
    publishesHostPorts :: Bool
  }
  deriving (Eq, Show)

-- | Resolve a cluster plan for a project, rooted at @root@, under a profile.
resolvePlan :: String -> FilePath -> ClusterProfile -> ClusterPlan
resolvePlan project root profile = case profile of
  Production ->
    ClusterPlan
      { clusterName = project,
        dataPath = root </> ".data",
        derivedPaths = [root </> ".cluster" </> project],
        publishesHostPorts = True
      }
  TestCase caseId ->
    ClusterPlan
      { clusterName = project ++ "-test-" ++ caseId,
        dataPath = root </> ".test_data" </> caseId,
        derivedPaths = [root </> ".cluster" </> (project ++ "-test-" ++ caseId)],
        publishesHostPorts = False
      }

-- | The kind of teardown.
data TeardownKind = Down | Delete
  deriving (Eq, Show)

-- | Partition a teardown into the paths to remove and the paths to preserve.
-- The @.data@ path is preserved under both @down@ and @delete@ — the
-- never-delete-@.data@ invariant — so it never appears in the removal set.
teardown :: TeardownKind -> ClusterPlan -> ([FilePath], [FilePath])
teardown Down plan = ([], dataPath plan : derivedPaths plan)
teardown Delete plan = (derivedPaths plan, [dataPath plan])

-- | Render a read-only status report for a resolved plan, given whether the kind
-- cluster is currently live. Pure, so the report shape is unit-tested; the
-- preserved @.data@ path is always shown to make the never-delete invariant
-- visible.
statusReport :: ClusterPlan -> Bool -> String
statusReport plan live =
  unlines
    [ "cluster:    " ++ clusterName plan ++ (if live then " (running)" else " (absent)"),
      "data:       " ++ dataPath plan ++ " (preserved)",
      "derived:    " ++ unwords (derivedPaths plan)
    ]

-- ---------------------------------------------------------------------------
-- IO drivers
-- ---------------------------------------------------------------------------

-- | Bring the cluster up (idempotent): create the cordoned kind cluster, then
-- install/upgrade the Helm release. This is 'clusterCreate' followed by
-- 'deployChart' — the bundled bring-up a single-chart project uses. A project
-- that must sequence other steps between cluster creation and the chart (e.g.
-- stand up an in-cluster registry and push the image the chart pulls) calls
-- 'clusterCreate' and 'deployChart' as separate chain steps instead.
clusterUp :: HostConfig -> ClusterPlan -> ResourceEnvelope -> IO ()
clusterUp cfg plan resources = do
  clusterCreate cfg plan resources
  deployChart cfg plan []

-- | Create the cordoned kind cluster (idempotent), **without** the chart: run the
-- spare-capacity preflight, create the kind cluster if absent (health-checking and
-- recreating a listed-but-unhealthy one), apply the budget cordon (fail-closed),
-- then gate on real node/CNI readiness before returning. The applied cordon sits
-- **after** @kind create@ so workloads never schedule against an un-cordoned node,
-- and the readiness gate sits **after** the cordon so the first @kubectl apply@ /
-- Helm install a chain runs next cannot race the API server or CNI on a busy host.
-- Split out from 'clusterUp' so a chain can interleave registry setup / image push
-- before 'deployChart'.
clusterCreate :: HostConfig -> ClusterPlan -> ResourceEnvelope -> IO ()
clusterCreate cfg plan resources = do
  resolvedCapacity <- resolveHostCapacity cfg
  case resolvedCapacity >>= preflightBudget resources of
    Left err -> die err
    Right () -> pure ()
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

-- | Ensure a live kind cluster named by the plan exists, creating it if absent and
-- **recreating** a listed-but-unhealthy one. @kind get clusters@ only lists names,
-- so a cluster whose containers are stopped (e.g. after the VM that hosts it was
-- @project down@-stopped and restarted — kind has no reliable stop/restart
-- contract) still reads as "present"; trusting the list would then leave the chain
-- talking to a dead API server. Instead a listed cluster is health-probed
-- ('clusterHealthy'); an unhealthy one is deleted and recreated so @project up@
-- reconciles a stopped stack back to running.
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
              reportStep "kind delete cluster (unhealthy)" recreated
              createCluster cfg plan
      | otherwise -> createCluster cfg plan
    Right (code, _, err) ->
      die ("cluster up: `kind get clusters` failed (" ++ show code ++ "): " ++ err)

-- | Create the kind cluster fresh (fail-closed). The production cluster publishes
-- its NodePorts to the host (the in-VM registry/web endpoints the demo reaches on
-- @localhost@) by shipping a @./kind.yaml@ with @extraPortMappings@; @kind create@
-- uses it via @--config@. A test-case cluster ('publishesHostPorts' 'False') skips
-- the config even when the file is present, so its node binds no fixed host port:
-- several isolated case clusters then coexist on one host without colliding on the
-- shared @kind.yaml@ ports (each case reaches its workload through the kind
-- container network instead). Without a config a plain single-node cluster is
-- created.
createCluster :: HostConfig -> ClusterPlan -> IO ()
createCluster cfg plan = do
  hasKindConfig <- doesFileExist kindClusterConfig
  let configArgs
        | publishesHostPorts plan && hasKindConfig = ["--config", kindClusterConfig]
        | otherwise = []
  created <- runTool cfg Kind (["create", "cluster", "--name", clusterName plan] ++ configArgs)
  requireStep "kind create cluster" created
  where
    kindClusterConfig = "kind.yaml"

-- | Health-probe a listed kind cluster: export its kubeconfig (idempotent), then
-- ask @kubectl@ for its nodes. A cluster whose containers are stopped exports a
-- kubeconfig but cannot answer @kubectl get nodes@, so the probe fails and the
-- caller recreates it. Pure classification is 'clusterHealthyFromProbe'.
clusterHealthy :: HostConfig -> ClusterPlan -> IO Bool
clusterHealthy cfg plan = do
  _ <- runTool cfg Kind ["export", "kubeconfig", "--name", clusterName plan]
  probe <- runTool cfg Kubectl ["get", "nodes", "--no-headers"]
  pure (clusterHealthyFromProbe probe)

-- | Classify a @kubectl get nodes --no-headers@ probe: healthy iff the command
-- succeeded and reported at least one node line. A connection failure (stopped
-- cluster) or an empty node list is unhealthy. Pure so the recreate decision is
-- unit-tested without a live cluster.
clusterHealthyFromProbe :: Either String (ExitCode, String, String) -> Bool
clusterHealthyFromProbe (Right (ExitSuccess, out, _)) =
  not (null (filter (not . null) (map (dropWhile (== ' ')) (lines out))))
clusterHealthyFromProbe _ = False

-- | Block until the cluster's nodes reach @Ready@ (the node/CNI readiness gate).
-- Each attempt runs @kubectl wait --for=condition=Ready node --all@ with a bounded
-- per-attempt timeout, retrying a few times so a slow API server / CNI on a busy
-- host is tolerated. Fail-closed: if the nodes never report Ready the step dies so
-- a broken cluster is loud rather than racing the first apply.
waitNodesReady :: HostConfig -> ClusterPlan -> IO ()
waitNodesReady cfg plan = go nodeReadyAttempts
  where
    nodeReadyAttempts :: Int
    nodeReadyAttempts = 10
    go 0 =
      die
        ( "cluster up: nodes for "
            ++ clusterName plan
            ++ " did not reach Ready in time"
        )
    go n = do
      result <- runTool cfg Kubectl ["wait", "--for=condition=Ready", "node", "--all", "--timeout=30s"]
      case result of
        Right (ExitSuccess, _, _) ->
          putStrLn ("cluster up: nodes Ready for " ++ clusterName plan)
        _ -> do
          threadDelay 3000000
          go (n - 1)

-- | Deploy the project's Helm chart if one is present. A project ships its chart
-- at @./chart@ (relative to the directory the lifecycle runs in — the project root
-- on the host, or @/workspace/\<project\>@ inside the project container); @cluster
-- up@ installs it **fail-closed**. A project with no chart (the cluster is the
-- workload, or it deploys via another path such as @harbor install@) gets a clean
-- kind + cordon bring-up with the deploy skipped — that is "no deploy requested",
-- not a swallowed failure.
--
-- @extraValues@ is a generic, project-supplied @[(KEY, VALUE)]@ passed to helm as
-- one @--set-string KEY=VALUE@ per pair, so a project can template its chart from
-- live config (e.g. the served message) without the core knowing the keys. The
-- core stays generic: it forwards the pairs verbatim.
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

-- | Apply the Linux kind-node cordon: @docker update@ the budget caps onto the
-- resolved control-plane container, fail-closed. On Apple the per-project Colima
-- VM is the cordon (sized by @ensure docker@), so there is no kind-node cap.
applyLinuxCordon :: HostConfig -> ClusterPlan -> ResourceEnvelope -> IO ()
applyLinuxCordon cfg plan resources
  | isLinux (hcSubstrate cfg) =
      case kindNodeCordonArgs (clusterName plan) resources of
        Left err -> die ("cordon: " ++ err)
        Right args -> do
          result <- runTool cfg Docker args
          case result of
            Right (ExitSuccess, _, _) -> putStrLn ("cordon applied: docker " ++ unwords args)
            Right (ExitFailure n, _, e) -> die ("cordon failed (exit " ++ show n ++ "): " ++ e)
            Left e -> die ("cordon: " ++ e)
  | otherwise =
      putStrLn "cordon: Apple substrate — the per-project Colima VM is sized by `ensure docker`"

-- | Tear the cluster down, preserving host @.data@.
clusterDown :: HostConfig -> ClusterPlan -> IO ()
clusterDown cfg plan = do
  let (toRemove, _) = teardown Down plan
  deleted <- runTool cfg Kind ["delete", "cluster", "--name", clusterName plan]
  reportStep "kind delete cluster" deleted
  removeAll toRemove
  putStrLn ("cluster down: preserved " ++ dataPath plan)

-- | Thoroughly delete derived cluster state, still never deleting host @.data@.
clusterDelete :: HostConfig -> ClusterPlan -> IO ()
clusterDelete cfg plan = do
  let (toRemove, _) = teardown Delete plan
  deleted <- runTool cfg Kind ["delete", "cluster", "--name", clusterName plan]
  reportStep "kind delete cluster" deleted
  removeAll toRemove
  putStrLn ("cluster delete: preserved " ++ dataPath plan)

-- | Report the cluster status (read-only): whether the kind cluster is live, and
-- the preserved @.data@ / derived paths. Never mutates state.
clusterStatus :: HostConfig -> ClusterPlan -> IO ()
clusterStatus cfg plan = do
  existing <- runTool cfg Kind ["get", "clusters"]
  let live = case existing of
        Right (ExitSuccess, out, _) -> clusterName plan `elem` lines out
        _ -> False
  putStr (statusReport plan live)

removeAll :: [FilePath] -> IO ()
removeAll paths = forM_ paths $ \p -> do
  exists <- doesDirectoryExist p
  if exists
    then removePathForcibly p >> putStrLn ("removed " ++ p)
    else pure ()

reportStep :: String -> Either String (ExitCode, String, String) -> IO ()
reportStep label result = case result of
  Right (ExitSuccess, _, _) -> putStrLn (label ++ ": ok")
  Right (ExitFailure n, _, err) -> putStrLn (label ++ ": exit " ++ show n ++ " " ++ err)
  Left err -> putStrLn (label ++ ": " ++ err)

-- | Like 'reportStep' but fail-closed: a non-zero exit or an unresolved tool
-- aborts (the @cluster up@ helm/kind steps must match the fail-closed cordon, so
-- a broken deploy is loud — never a swallowed @putStrLn@ that lets the caller,
-- or a lifting parent process, see success).
requireStep :: String -> Either String (ExitCode, String, String) -> IO ()
requireStep label result = case result of
  Right (ExitSuccess, _, _) -> putStrLn (label ++ ": ok")
  Right (ExitFailure n, _, err) -> die (label ++ ": exit " ++ show n ++ " " ++ err)
  Left err -> die (label ++ ": " ++ err)
