{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The cluster's four clauses, held over real objects.

Two kinds of case, and no third. The decisions are applied to values — record
keys, node orderings, and the rendering of a refusal. The clause-holding effects
run against a __real protected store__ in a temporary directory and a __real
cluster client process__ ("FakeCluster"), so nothing here reaches a substitution
point and nothing can pass against one (§ NN).

Nothing here is host-specific: the client is this suite's own executable and its
durable state is ordinary files, so the family runs — and is counted — on every
gate host (§ JJ).
-}
module ClusterOwnershipSpec (tests) where

import Data.Either (isLeft)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified FakeCluster
import HostBootstrap.Cluster.Command (ClusterDriver (KindDriver))
import HostBootstrap.Cluster.Ownership hiding (reconcileOwnedCluster)
import qualified HostBootstrap.Cluster.Ownership as Ownership
import HostBootstrap.Cluster.Report (
    ClusterPresence (ClusterAbsent, ClusterPresent),
    ClusterReportFault (ClusterCommandUnrun),
 )
import HostBootstrap.Cluster.Cordon (ResourceBudget, mkResourceBudget)
import HostBootstrap.Cluster.Resume (
    ClusterStanding (ClusterCreatedUnbound, ClusterNothingDone, ClusterOwned),
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Kind, Kubectl), mkAbsExe)
import HostBootstrap.Ownership.Object (Origin (OriginAbsent, OriginPresent))
import HostBootstrap.Protected (
    ProtectedSession,
    RecordKey,
    listProtectedRecords,
    openProtectedStore,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, getTemporaryDirectory)
import System.Environment (getExecutablePath)
import System.FilePath (dropTrailingPathSeparator, isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (readFile')
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "cluster ownership"
        [ testGroup "the object a transaction owns" objectTests
        , testGroup "what the authorities report" observationTests
        , testGroup "reconciling" reconcileTests
        , testGroup "readiness" readinessTests
        , testGroup "cordoning" cordonTests
        , testGroup "releasing" releaseTests
        ]

reconcileOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
reconcileOwnedCluster = Ownership.reconcileOwnedCluster KindDriver

-- ---------------------------------------------------------------------------
-- The owned object

clusterName :: String
clusterName = "hostbootstrap-demo"

controlPlane :: String
controlPlane = clusterName <> "-control-plane"

worker :: String
worker = clusterName <> "-worker"

owned :: OwnedCluster
owned =
    OwnedCluster
        { ownedClusterName = clusterName
        , ownedClusterControlPlane = controlPlane
        , ownedClusterWorkers = [worker]
        , ownedClusterConfig = Nothing
        , ownedClusterKubeconfig = "/state/demo.kubeconfig"
        , ownedClusterOwner = "hostbootstrap/cluster-origin/v2:demo:1"
        }

ownedAt :: FilePath -> OwnedCluster
ownedAt root = owned{ownedClusterKubeconfig = root </> "store" </> "cluster.kubeconfig"}

objectTests :: [TestTree]
objectTests =
    [ testCase "the cluster's record lives under its own declared name" $
        fmap recordKeyText (ownedClusterRecordKey owned) @?= Right (Text.pack clusterName)
    , testCase "a node's record is discoverable from the cluster's own key" $
        fmap recordKeyText (ownedNodeRecordKey owned worker)
            @?= Right (Text.pack (clusterName <> "." <> worker))
    , testCase "the declared nodes are the control plane first, then the workers" $
        ownedClusterNodeNames owned @?= [controlPlane, worker]
    , testCase "one generation derives one claim and another derives a different one" $ do
        ownedClusterClaim owned @?= ownedClusterClaim owned{ownedClusterKubeconfig = "/elsewhere"}
        assertBool
            "a different owner binding is a different claim"
            (ownedClusterClaim owned /= ownedClusterClaim owned{ownedClusterOwner = "other"})
    , testCase "every fault renders through the one renderer" $
        assertBool
            "no fault renders as nothing"
            ( not
                ( Text.null
                    (clusterOwnershipFaultMessage (ClusterOwnershipReport (ClusterCommandUnrun "no child")))
                )
            )
    ]

-- ---------------------------------------------------------------------------
-- What the authorities report

observationTests :: [TestTree]
observationTests =
    [ testCase "an absent node is an authoritative absence" $
        withFixture $ \config _root ->
            observeOwnedNode config controlPlane >>= (@?= Right OriginAbsent)
    , testCase "a present node answers with the identity it reports for itself" $
        withFixture $ \config root -> do
            standUpCluster root
            observeOwnedNode config controlPlane >>= \case
                Right (OriginPresent _) -> pure ()
                other -> assertFailure ("expected a present node, got " <> show other)
    , testCase "the driver's own listing decides presence" $
        withFixture $ \config root -> do
            observeOwnedClusterPresence config (ownedAt root) >>= (@?= Right ClusterAbsent)
            standUpCluster root
            observeOwnedClusterPresence config (ownedAt root) >>= (@?= Right ClusterPresent)
    , testCase "a container replaced between the listing and the readback is a conflict" $
        withFixture $ \config root -> do
            standUpCluster root
            FakeCluster.armReplacementAfter root "listing"
            observed <- observeOwnedNode config controlPlane
            assertBool ("expected a readback conflict, got " <> show observed) (isLeft observed)
    ]

-- ---------------------------------------------------------------------------
-- Reconciling

reconcileTests :: [TestTree]
reconcileTests =
    [ testCase "a fresh reconcile creates the cluster and binds every node" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                reconcileOwnedCluster config session key (ownedAt root) >>= \case
                    Right (ClusterCreated _) -> pure ()
                    other -> assertFailure ("expected a created cluster, got " <> show other)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                readFile' (ownedClusterKubeconfig (ownedAt root))
                    >>= (@?= FakeCluster.fixtureKubeconfig clusterName)
                FakeCluster.recordedKubeconfigPaths root >>= \case
                    [staging] -> do
                        temporaryRoot <- getTemporaryDirectory
                        takeDirectory (takeDirectory staging) @?= dropTrailingPathSeparator temporaryRoot
                        assertBool "the staging path is absolute" (isAbsolute staging)
                        assertBool
                            ("the staging name is bounded to this cluster: " <> takeFileName staging)
                            ( (".hostbootstrap-kind-" <> clusterName)
                                `isPrefixOf` takeFileName staging
                                && ".kubeconfig" `isSuffixOf` takeFileName staging
                            )
                        assertBool
                            "Kind did not lock the protected durable destination"
                            (staging /= ownedClusterKubeconfig (ownedAt root))
                        doesFileExist staging >>= (@?= False)
                    paths -> assertFailure ("expected one private staging path, got " <> show paths)
                ownedClusterStanding config session key (ownedAt root) >>= \case
                    Right (ClusterOwned _) -> pure ()
                    other -> assertFailure ("expected an owned cluster, got " <> show other)
    , testCase "an exact repeat is already owned and creates nothing more" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                reconcileOwnedCluster config session key (ownedAt root) >>= \case
                    Right (ClusterAlreadyOwned _) -> pure ()
                    other -> assertFailure ("expected an already-owned cluster, got " <> show other)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
    , testCase "a client that dies after its create is recovered without creating again" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                writeFile (FakeCluster.crashAfterCreatePath root) "once\n"
                first <- reconcileOwnedCluster config session key (ownedAt root)
                assertBool
                    ("the interrupted create is a refusal, got " <> show first)
                    (isLeft first)
                reconcileOwnedCluster config session key (ownedAt root) >>= \case
                    Right (ClusterRecovered _) -> pure ()
                    other -> assertFailure ("expected recovery, got " <> show other)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                readFile' (ownedClusterKubeconfig (ownedAt root))
                    >>= (@?= FakeCluster.fixtureKubeconfig clusterName)
    , testCase "a durable publication failure binds nothing and recovery publishes before binding" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                let missingDirectory = root </> "missing-durable-state"
                    interrupted =
                        (ownedAt root)
                            { ownedClusterKubeconfig = missingDirectory </> "cluster.kubeconfig"
                            }
                first <- reconcileOwnedCluster config session key interrupted
                case first of
                    Left (ClusterOwnershipKubeconfig _) -> pure ()
                    other -> assertFailure ("expected a named kubeconfig publication refusal, got " <> show other)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                ownedClusterStanding config session key interrupted >>= \case
                    Right (ClusterCreatedUnbound _) -> pure ()
                    other -> assertFailure ("expected an unbound created cluster, got " <> show other)
                createDirectoryIfMissing True missingDirectory
                reconcileOwnedCluster config session key interrupted >>= \case
                    Right (ClusterRecovered _) -> pure ()
                    other -> assertFailure ("expected publication recovery, got " <> show other)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
                readFile' (ownedClusterKubeconfig interrupted)
                    >>= (@?= FakeCluster.fixtureKubeconfig clusterName)
                ownedClusterStanding config session key interrupted >>= \case
                    Right (ClusterOwned _) -> pure ()
                    other -> assertFailure ("expected recovery to bind only after publication, got " <> show other)
    , testCase "a cluster nothing claims is refused rather than adopted" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                standUpCluster root
                outcome <- reconcileOwnedCluster config session key (ownedAt root)
                assertBool ("an unclaimed cluster is refused, got " <> show outcome) (isLeft outcome)
                FakeCluster.recordedClusterMutations root >>= (@?= [])
    , testCase "a worker replaced under an owned cluster is refused" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                replaceNode root worker
                outcome <- reconcileOwnedCluster config session key (ownedAt root)
                assertBool ("a replaced worker is refused, got " <> show outcome) (isLeft outcome)
    , testCase "nothing at all under no record is nothing done" $
        withFixture $ \config root ->
            withEntry root $ \session key ->
                ownedClusterStanding config session key (ownedAt root) >>= (@?= Right ClusterNothingDone)
    ]

-- ---------------------------------------------------------------------------
-- Readiness

readinessTests :: [TestTree]
readinessTests =
    [ testCase "a cluster whose declared nodes have all joined is ready" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                observeOwnedClusterReadiness config session key (ownedAt root) @?>= ClusterReady
    , testCase "a node that has not joined is not a readiness" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                setNodeRunning root worker False
                observeOwnedClusterReadiness config session key (ownedAt root) @?>= ClusterNodesUnready
    , testCase "a control plane that has not come up is an answer, not a fault" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                FakeCluster.armApiUnready root
                observeOwnedClusterReadiness config session key (ownedAt root) @?>= ClusterApiUnready
    , testCase "a node set the plan does not declare is not this cluster's readiness" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                held <- FakeCluster.readNodes root
                FakeCluster.writeNodes
                    root
                    (held <> [(clusterName <> "-worker2", FakeCluster.ClusterNode (replicate 64 'c') True [])])
                observeOwnedClusterReadiness config session key (ownedAt root) @?>= ClusterNodesUndeclared
    , testCase "a node replaced while the probe ran is a conflict rather than a readiness" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                FakeCluster.armReplacementAfter root "nodes"
                outcome <- observeOwnedClusterReadiness config session key (ownedAt root)
                assertBool ("a replacement is refused, got " <> show outcome) (isLeft outcome)
    , testCase "a cluster the driver no longer names cannot be re-entered" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                FakeCluster.writeClusters root []
                outcome <- observeOwnedClusterReadiness config session key (ownedAt root)
                assertBool ("an unnamed cluster is refused, got " <> show outcome) (isLeft outcome)
    ]

-- ---------------------------------------------------------------------------
-- Cordoning

{- | One declared wall, and the flags it renders to.

Written out rather than derived from the renderer, so a case compares the applied
limits against a value an operator can read instead of against the function that
produced them.
-}
declaredBudget :: ResourceBudget
declaredBudget = either error id (mkResourceBudget 2 (4 * 1024 * 1024 * 1024) (20 * 1024 * 1024 * 1024))

declaredLimits :: [String]
declaredLimits =
    ["--cpus", "2", "--memory", "4294967296", "--memory-swap", "8589934592"]

cordonTests :: [TestTree]
cordonTests =
    [ testCase "the wall lands on every declared node, by its bound identity" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                cordonOwnedCluster config session key (ownedAt root) declaredBudget
                    @?>= [controlPlane, worker]
                held <- FakeCluster.readNodes root
                map (FakeCluster.nodeLimits . snd) held
                    @?= replicate (length held) declaredLimits
                FakeCluster.recordedClusterMutations root >>= (@?= ["create", "update", "update"])
    , testCase "a node replaced while the wall was applied is a conflict" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                FakeCluster.armReplacementAfter root "update"
                outcome <- cordonOwnedCluster config session key (ownedAt root) declaredBudget
                assertBool ("a replacement is refused, got " <> show outcome) (isLeft outcome)
    , testCase "a cluster no record of this project's claims is never walled" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                standUpCluster root
                outcome <- cordonOwnedCluster config session key (ownedAt root) declaredBudget
                assertBool ("an unclaimed cluster is refused, got " <> show outcome) (isLeft outcome)
                FakeCluster.recordedClusterMutations root >>= (@?= [])
    ]

-- ---------------------------------------------------------------------------
-- Releasing

releaseTests :: [TestTree]
releaseTests =
    [ testCase "releasing removes the cluster and forgets every record" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                releaseOwnedCluster config session key (ownedAt root) @?>= ClusterReleased
                FakeCluster.recordedClusterMutations root >>= (@?= ["create", "delete"])
                FakeCluster.readClusters root >>= (@?= [])
                remainingRecords session >>= (@?= [])
    , testCase "a second release finds nothing left to do" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                _ <- releaseOwnedCluster config session key (ownedAt root)
                releaseOwnedCluster config session key (ownedAt root) @?>= ClusterAlreadyReleased
    , testCase "a record published over a create that never happened is forgotten" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                FakeCluster.armCreateRefusal root
                refused <- reconcileOwnedCluster config session key (ownedAt root)
                assertBool ("the refused create is a refusal, got " <> show refused) (isLeft refused)
                releaseOwnedCluster config session key (ownedAt root) @?>= ClusterAlreadyReleased
                remainingRecords session >>= (@?= [])
                FakeCluster.recordedClusterMutations root >>= (@?= [])
    , testCase "a cluster created and never bound authorizes no removal" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                writeFile (FakeCluster.crashAfterCreatePath root) "once\n"
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                outcome <- releaseOwnedCluster config session key (ownedAt root)
                assertBool ("an unbound cluster is refused, got " <> show outcome) (isLeft outcome)
                FakeCluster.recordedClusterMutations root >>= (@?= ["create"])
    , testCase "a replacement that took a node's name is left standing" $
        withFixture $ \config root ->
            withEntry root $ \session key -> do
                _ <- reconcileOwnedCluster config session key (ownedAt root)
                FakeCluster.armReplacementAfter root "delete"
                outcome <- releaseOwnedCluster config session key (ownedAt root)
                assertBool ("a replacement is refused, got " <> show outcome) (isLeft outcome)
                held <- FakeCluster.readNodes root
                lookup controlPlane held
                    @?= Just (FakeCluster.ClusterNode FakeCluster.replacementIdentity True [])
                records <- remainingRecords session
                assertBool "no record was forgotten over a replacement" (not (null records))
    ]

-- ---------------------------------------------------------------------------
-- The fixture

{- | A host whose three cluster tools are this suite's own executable.

§ KK's one interpreter launches whatever the configuration resolves with the
exact argument vector the described command carries, so a fixture supplies a
program rather than a function.
-}
withFixture :: (HostConfig -> FilePath -> IO ()) -> IO ()
withFixture consume =
    withSystemTempDirectory "hostbootstrap-cluster-ownership" $ \temporary -> do
        root <- canonicalizePath temporary
        let toolRoot = root </> "tools"
        createDirectoryIfMissing True toolRoot
        _ <- FakeCluster.newClusterFixture toolRoot [controlPlane, worker]
        self <- getExecutablePath
        let config =
                HostConfig
                    { hcSubstrate = Substrate LinuxCpu Amd64
                    , hcToolPaths =
                        Map.fromList
                            [ (Kind, fixtureExe self)
                            , (Docker, fixtureExe self)
                            , (Kubectl, fixtureExe self)
                            ]
                    }
        FakeCluster.withFakeClusterClient toolRoot (consume config toolRoot)
  where
    fixtureExe path = either (error . show) id (mkAbsExe path)

-- | One exclusive entry over a real protected store, with the cluster's key.
withEntry ::
    FilePath ->
    (forall session. ProtectedSession session -> RecordKey -> IO ()) ->
    IO ()
withEntry root use = do
    store <- openProtectedStore (root </> "store")
    opened <- either (assertFailure . show) pure store
    key <- either (assertFailure . show) pure (ownedClusterRecordKey owned)
    outcome <- withProtectedEntry opened (\session -> Right <$> use session key)
    either (assertFailure . show) pure outcome

{- | Bring a cluster up outside any transaction.

Written through the fixture's own durable state rather than through the driver,
because the point of every case that uses it is a cluster no record of this
project's claims.
-}
standUpCluster :: FilePath -> IO ()
standUpCluster root = do
    FakeCluster.writeClusters root [clusterName]
    FakeCluster.writeNodes
        root
        [ (controlPlane, FakeCluster.ClusterNode (replicate 64 'a') True [])
        , (worker, FakeCluster.ClusterNode (replicate 64 'b') True [])
        ]

{- | Assert that a transaction answered with exactly one outcome.

Named because every later transaction is asserted the same way, and a case that
wrote the case-analysis out would be describing the @Either@ rather than the
answer.
-}
(@?>=) :: (Eq value, Show value) => IO (Either fault value) -> value -> IO ()
answered @?>= expected = do
    outcome <- answered
    case outcome of
        Right value -> value @?= expected
        Left _ -> assertFailure ("expected " <> show expected <> ", got a refusal")

infix 1 @?>=

-- | Every record the store still holds, so a release can be checked for orphans.
remainingRecords :: ProtectedSession session -> IO [RecordKey]
remainingRecords session =
    listProtectedRecords session >>= either (assertFailure . show) pure

-- | Change whether one node container reports itself running.
setNodeRunning :: FilePath -> String -> Bool -> IO ()
setNodeRunning root node running = do
    held <- FakeCluster.readNodes root
    FakeCluster.writeNodes
        root
        [ (name, if name == node then current{FakeCluster.nodeRunning = running} else current)
        | (name, current) <- held
        ]

-- | Put a different container at one node's name, outside any transaction.
replaceNode :: FilePath -> String -> IO ()
replaceNode root node = do
    held <- FakeCluster.readNodes root
    FakeCluster.writeNodes
        root
        [ (name, if name == node then current{FakeCluster.nodeIdentity = FakeCluster.replacementIdentity} else current)
        | (name, current) <- held
        ]
