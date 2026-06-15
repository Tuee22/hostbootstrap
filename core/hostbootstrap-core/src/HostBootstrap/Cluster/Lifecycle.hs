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
    clusterUp,
    clusterDown,
    clusterDelete,
    clusterStatus,
  )
where

import Control.Monad (forM_)
import HostBootstrap.Cluster.Cordon
  ( kindNodeCordonArgs,
    preflightBudget,
    resolveHostCapacity,
  )
import HostBootstrap.Config.Schema (Resources)
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Helm, Kind))
import HostBootstrap.Substrate (isLinux)
import System.Directory (doesDirectoryExist, removePathForcibly)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))

-- | The cluster profile: production uses fixed names and the canonical @.data@
-- path; the test profile isolates each case under its own paths so a
-- harness-driven test never collides with a production cluster.
data ClusterProfile = Production | TestCase String
  deriving (Eq, Show)

-- | A resolved cluster plan: the kind cluster name, the never-deleted host
-- @.data@ path, and the derived state safe to remove on @delete@.
data ClusterPlan = ClusterPlan
  { clusterName :: String,
    dataPath :: FilePath,
    derivedPaths :: [FilePath]
  }
  deriving (Eq, Show)

-- | Resolve a cluster plan for a project, rooted at @root@, under a profile.
resolvePlan :: String -> FilePath -> ClusterProfile -> ClusterPlan
resolvePlan project root profile = case profile of
  Production ->
    ClusterPlan
      { clusterName = project,
        dataPath = root </> ".data",
        derivedPaths = [root </> ".cluster" </> project]
      }
  TestCase caseId ->
    ClusterPlan
      { clusterName = project ++ "-test-" ++ caseId,
        dataPath = root </> ".test_data" </> caseId,
        derivedPaths = [root </> ".cluster" </> (project ++ "-test-" ++ caseId)]
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

-- | Bring the cluster up (idempotent): run the spare-capacity preflight, create
-- the kind cluster if absent, apply the budget cordon (fail-closed), then
-- install/upgrade the Helm release. The applied cordon sits **after** @kind
-- create@ and **before** Helm, so the workloads never schedule against an
-- un-cordoned node.
clusterUp :: HostConfig -> ClusterPlan -> Resources -> IO ()
clusterUp cfg plan resources = do
  resolvedCapacity <- resolveHostCapacity cfg
  case resolvedCapacity >>= preflightBudget resources of
    Left err -> die err
    Right () -> pure ()
  existing <- runTool cfg Kind ["get", "clusters"]
  case existing of
    Right (ExitSuccess, out, _)
      | clusterName plan `elem` lines out ->
          putStrLn ("cluster up: kind cluster " ++ clusterName plan ++ " already exists")
    Right (ExitSuccess, _, _) -> do
      created <- runTool cfg Kind ["create", "cluster", "--name", clusterName plan]
      requireStep "kind create cluster" created
    _ -> die "cluster up: kind not available; install kind and retry"
  applyLinuxCordon cfg plan resources
  deployChart cfg plan

-- | Deploy the project's Helm chart if one is present. A project ships its chart
-- at @./chart@ (relative to the directory the lifecycle runs in — the project root
-- on the host, or @/workspace/\<project\>@ inside the project container); @cluster
-- up@ installs it **fail-closed**. A project with no chart (the cluster is the
-- workload, or it deploys via another path such as @harbor install@) gets a clean
-- kind + cordon bring-up with the deploy skipped — that is "no deploy requested",
-- not a swallowed failure.
deployChart :: HostConfig -> ClusterPlan -> IO ()
deployChart cfg plan = do
  hasChart <- doesDirectoryExist chartPath
  if hasChart
    then do
      release <- runTool cfg Helm ["upgrade", "--install", clusterName plan, chartPath]
      requireStep "helm upgrade --install" release
    else putStrLn ("cluster up: no chart at ./" ++ chartPath ++ "; skipping deploy (kind + cordon only)")
  where
    chartPath = "chart"

-- | Apply the Linux kind-node cordon: @docker update@ the budget caps onto the
-- resolved control-plane container, fail-closed. On Apple the per-project Colima
-- VM is the cordon (sized by @ensure docker@), so there is no kind-node cap.
applyLinuxCordon :: HostConfig -> ClusterPlan -> Resources -> IO ()
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
