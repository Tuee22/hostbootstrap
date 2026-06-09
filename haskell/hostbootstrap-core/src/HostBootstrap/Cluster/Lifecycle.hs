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
    clusterUp,
    clusterDown,
    clusterDelete,
  )
where

import Control.Monad (forM_)
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Helm, Kind))
import System.Directory (doesDirectoryExist, removePathForcibly)
import System.Exit (ExitCode (..))
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

-- ---------------------------------------------------------------------------
-- IO drivers
-- ---------------------------------------------------------------------------

-- | Bring the cluster up (idempotent): create the kind cluster if absent, then
-- install/upgrade the Helm release.
clusterUp :: HostConfig -> ClusterPlan -> IO ()
clusterUp cfg plan = do
  existing <- runTool cfg Kind ["get", "clusters"]
  case existing of
    Right (ExitSuccess, out, _)
      | clusterName plan `elem` lines out ->
          putStrLn ("cluster up: kind cluster " ++ clusterName plan ++ " already exists")
    Right (ExitSuccess, _, _) -> do
      created <- runTool cfg Kind ["create", "cluster", "--name", clusterName plan]
      reportStep "kind create cluster" created
    _ -> putStrLn "cluster up: kind not available; install kind and retry"
  release <- runTool cfg Helm ["upgrade", "--install", clusterName plan, "."]
  reportStep "helm upgrade --install" release

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
