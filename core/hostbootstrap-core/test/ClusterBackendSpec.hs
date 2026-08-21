{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The cluster ownership backend and its loopback-bound exposure.

The backend is a __join__ rather than a driver: the clauses are held by
"HostBootstrap.Cluster.Ownership" over the one seam, the effects are described
commands the one interpreter launches, and what is left here is turning a
prepared plan-owned package into the object that driver is about and turning the
driver's answer into the observation the reconciler classifies. The cases below
are therefore of exactly two kinds — the derivation applied to values, and the
join driven against a real protected store and a real cluster client process.

Nothing here is host-specific. The store is ordinary files, the client is this
suite's own executable, and the paths a described command carries obey the
grammar of the process that reads them (§ MM), so every case runs and is counted
on every gate host (§ JJ).

There is no executor to inject and no program to ship. A suite that wants the
driver to have answered a particular way supplies a program the interpreter can
launch, which is what "FakeCluster" is, so no case here can pass against a
substitution point (§ NN).
-}
module ClusterBackendSpec (tests) where

import ClusterReconcileSpec (
    withClusterFixtureM,
    withHarnessClusterFixtureM,
    withPlannedClusterFixture,
 )
import Control.Monad (forM_)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified FakeCluster
import HostBootstrap.Cluster.Backend
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Docker, Kind, Kubectl), mkAbsExe)
import HostBootstrap.Reconcile
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Protected (
    RecordKey,
    listProtectedRecords,
    openProtectedStore,
    withProtectedEntry,
 )
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (isAbsolute, (</>))
import System.IO (readFile')
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterBackendSpec"
        [ testGroup "what the driver's listing means" statusCases
        , testGroup "admitting the declared backend" admissionCases
        , testGroup "the join, driven for real" joinCases
        , testGroup "no program written in another language" sourceCases
        , testGroup "loopback-bound exposure" exposureCases
        ]

-- What a listing means ----------------------------------------------------------

statusCases :: [TestTree]
statusCases =
    [ testCase "the read-only status classification is total over what a driver can say" $ do
        answered "" @?= ClusterStatusAbsent
        answered "demo\n" @?= ClusterStatusPresent
        answered "other\ndemo\n" @?= ClusterStatusPresent
        answered "other\n" @?= ClusterStatusAbsent
        refusesListing "a body with no trailing newline" (answered "demo")
        refusesListing "a carriage return" (answered "demo\r\n")
        refusesListing "a byte outside ASCII" (answered "dem\224\n")
        refusesListing "an empty name" (answered "\n")
        refusesListing "a name outside the portable alphabet" (answered "bad name\n")
        refusesListing "an over-long name" (answered (replicate 129 'x' <> "\n"))
        refusesListing "the same name twice" (answered "demo\ndemo\n")
    , testCase "a command that produced no child is not an absence" $
        refusesListing "no process at all" (classifyClusterStatus "demo" (Left "kind not found"))
    , testCase "a non-zero exit and a noisy success are each refusals" $ do
        refusesListing "a non-zero exit" (classifyClusterStatus "demo" (ran (ExitFailure 1) "demo\n" ""))
        refusesListing "anything at all on standard error" (classifyClusterStatus "demo" (ran ExitSuccess "demo\n" "warning\n"))
    ]
  where
    answered payload = classifyClusterStatus "demo" (ran ExitSuccess payload "")

ran :: ExitCode -> String -> String -> Either String CapturedRun
ran code out err = Right (CapturedRun{capturedExit = code, capturedStdout = out, capturedStderr = err})

refusesListing :: String -> ClusterStatusObservation -> IO ()
refusesListing label observed = case observed of
    ClusterStatusProbeFailed _ -> pure ()
    other -> assertFailure ("the status classification admitted " <> label <> ": " <> show other)

-- Admitting the declared backend -------------------------------------------------

admissionCases :: [TestTree]
admissionCases =
    [ testCase "a configuration missing one cluster tool mints no capability" $
        forM_ [Kind, Docker, Kubectl] $ \omitted -> do
            self <- getExecutablePath
            discovered <- discoverStrongClusterBackend (hostConfigWithout self omitted)
            case discovered of
                Left (Unsupported _) -> pure ()
                other ->
                    assertFailure
                        ("a missing tool must mint no backend, got " <> show (() <$ other))
    , testCase "a configuration carrying all three is admitted with no probe" $ do
        self <- getExecutablePath
        discovered <- discoverStrongClusterBackend (clusterHostConfig self)
        case discovered of
            Right _ -> pure ()
            other -> assertFailure ("expected an admitted backend, got " <> show (() <$ other))
    , testCase "the exact package projects absolute backend paths" $ do
        outcome <-
            withClusterFixtureM $ \prepared ->
                pure
                    ( Right
                        ( isAbsolute (preparedClusterStateDirectory prepared)
                            && maybe True isAbsolute (preparedClusterConfigPath prepared)
                        )
                    )
        outcome @?= Right True
    , testCase "a Harness package declares no driver configuration at all" $ do
        outcome <-
            withHarnessClusterFixtureM
                (\prepared -> pure (Right (preparedClusterConfigPath prepared)))
        outcome @?= Right Nothing
    ]

hostConfigWithout :: FilePath -> HostTool -> HostConfig
hostConfigWithout self omitted =
    let full = clusterHostConfig self
     in full{hcToolPaths = Map.delete omitted (hcToolPaths full)}

clusterHostConfig :: FilePath -> HostConfig
clusterHostConfig self =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64
        , hcToolPaths =
            Map.fromList [(Kind, fixtureExe self), (Docker, fixtureExe self), (Kubectl, fixtureExe self)]
        }

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

-- The join, driven for real -------------------------------------------------------

joinCases :: [TestTree]
joinCases =
    [ testCase "a fresh reconcile creates the plan's own cluster and binds its nodes" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                listed <- FakeCluster.readClusters root
                pure
                    ( Right
                        ( clusterReconcileResultView observed
                        , mutations
                        , listed == [preparedClusterName prepared]
                        )
                    )
        case outcome of
            Right (ClusterResultCreated identity, mutations, listedOwnCluster) -> do
                assertBool "the bound identity is not empty" (not (Text.null identity))
                mutations @?= ["create"]
                listedOwnCluster @?= True
            other -> assertFailure ("expected a created cluster, got " <> show other)
    , testCase "the identity bound is the one the runtime answered for the control plane" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                observed <- runClusterReconcileCall backend prepared
                let controlPlane = take 1 (preparedClusterNodeNames prepared)
                    expected = map (Text.pack . FakeCluster.fixtureNodeIdentity) controlPlane
                pure (Right (clusterReconcileResultView observed, expected))
        case outcome of
            Right (ClusterResultCreated identity, [expected]) -> identity @?= expected
            other -> assertFailure ("expected the control plane's own identity, got " <> show other)
    , testCase "the durable record lives under the plan's own state directory" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                Right . length <$> recordsUnder (preparedClusterStateDirectory prepared)
        outcome @?= Right (1 :: Int)
    , testCase "the credential the driver wrote lands inside that state directory" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                written <- FakeCluster.recordedKubeconfigPaths root
                pure
                    ( Right
                        ( not (null written)
                        , all (preparedClusterStateDirectory prepared `isInfixOf`) written
                        )
                    )
        outcome @?= Right (True, True)
    , testCase "an exact repeat is healthy and creates nothing more" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultHealthy _, mutations) -> mutations @?= ["create"]
            other -> assertFailure ("expected a healthy cluster, got " <> show other)
    , testCase "an owned cluster whose containers stopped is unhealthy, never recreated" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                stopEveryNode root
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultUnhealthy _, mutations) -> mutations @?= ["create"]
            other -> assertFailure ("expected an unhealthy cluster, got " <> show other)
    , testCase "a cluster no record of this project's claims is foreign and is not touched" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                FakeCluster.writeClusters root [preparedClusterName prepared]
                FakeCluster.writeNodes
                    root
                    [ (node, FakeCluster.ClusterNode (replicate 64 'a') True [])
                    | node <- preparedClusterNodeNames prepared
                    ]
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultForeign reason, mutations) -> do
                assertBool
                    ("the refusal names what it found, got " <> show reason)
                    ("no durable record" `Text.isInfixOf` reason)
                mutations @?= []
            other -> assertFailure ("expected a foreign cluster, got " <> show other)
    , testCase "the read-only status path asks the driver and decides from the bytes" $ do
        outcome <- withBackend $ \backend root ->
            withClusterFixtureM $ \prepared -> do
                declare root prepared
                absent <- runClusterStatusCall backend prepared
                _ <- runClusterReconcileCall backend prepared
                present <- runClusterStatusCall backend prepared
                pure (Right (absent, present))
        outcome @?= Right (ClusterStatusAbsent, ClusterStatusPresent)
    ]

{- | Every durable record this run's own state directory holds.

Read through the protected store's own listing rather than off the filesystem,
because where a record lives inside the store is the store's business and what
this case is about is that the records are the store's at all.
-}
recordsUnder :: FilePath -> IO [RecordKey]
recordsUnder stateDirectory = do
    opened <- openProtectedStore stateDirectory
    store <- either (assertFailure . show) pure opened
    outcome <- withProtectedEntry store listProtectedRecords
    either (assertFailure . show) pure outcome

{- | Declare the plan's own node set to the fixture's driver.

The topology a real driver establishes comes out of its configuration snapshot,
so the fixture is told the node names rather than guessing them from a filename.
-}
declare ::
    FilePath ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO ()
declare root prepared = FakeCluster.declareNodes root (preparedClusterNodeNames prepared)

stopEveryNode :: FilePath -> IO ()
stopEveryNode root = do
    held <- FakeCluster.readNodes root
    FakeCluster.writeNodes root [(name, node{FakeCluster.nodeRunning = False}) | (name, node) <- held]

-- | An admitted backend whose three tools are this suite's own executable.
withBackend :: (StrongClusterBackend -> FilePath -> IO result) -> IO result
withBackend consume =
    withSystemTempDirectory "hostbootstrap-cluster-backend" $ \temporary -> do
        root <- canonicalizePath temporary
        _ <- FakeCluster.newClusterFixture root []
        self <- getExecutablePath
        discovered <- discoverStrongClusterBackend (clusterHostConfig self)
        backend <- either (assertFailure . show) pure discovered
        FakeCluster.withFakeClusterClient root (consume backend root)

-- No program written in another language --------------------------------------------

{- | The absence this sprint's whole subject is, held mechanically.

A guard over the sources themselves rather than over a run, because what is being
asserted is that there is nowhere left for such a program to be: it fires on a
reintroduced interpreter or locking front end instead of waiting for a fixture to
happen to reach one. [rationale.md](rationale.md) says why a program carried in a
string is refused — it parses its own protocol, restates invariants its caller
already states, and has to be reviewed in two languages.

The positive half matters as much as the negative one: a guard that only forbade
the old names would stay quiet over a backend that had stopped driving anything at
all, so it also asserts that the boundary still reaches the described commands and
the clause-holding driver.
-}
sourceCases :: [TestTree]
sourceCases =
    [ testCase "the cluster backend names no interpreter and no locking front end" $ do
        source <- backendSource
        forM_ forbiddenNames $ \name ->
            assertBool
                (name <> " is named in the cluster backend")
                (not (name `isInfixOf` source))
    , testCase "the private component the injected executor lived in is gone" $ do
        root <- repositoryRoot
        present <-
            doesFileExist
                ( root
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "internal"
                    </> "cluster-backend"
                    </> "HostBootstrap"
                    </> "Cluster"
                    </> "Backend"
                    </> "Internal.hs"
                )
        assertBool "the retired private cluster-backend component is still in the tree" (not present)
    , testCase "the backend still reaches the described commands and the clause-holding driver" $ do
        source <- backendSource
        forM_ reachedNames $ \name ->
            assertBool
                (name <> " is not reached from the cluster backend")
                (name `isInfixOf` source)
    ]

backendSource :: IO String
backendSource = do
    root <- repositoryRoot
    readFile'
        ( root
            </> "core"
            </> "hostbootstrap-core"
            </> "src"
            </> "HostBootstrap"
            </> "Cluster"
            </> "Backend.hs"
        )

repositoryRoot :: IO FilePath
repositoryRoot = do
    cwd <- getCurrentDirectory
    findRepoRoot cwd
        >>= maybe (assertFailure ("could not locate the repository root from " <> cwd)) pure

{- | The names a cluster effect may no longer be spelled with.

@Python3@ and @Flock@ are the host-tool constructors the retired program
resolved, @Lockf@ the one it deliberately refused, @-c@ is how an interpreter is
handed a program, and @ClusterExec@ is the function a suite used to answer with
instead of supplying one.
-}
forbiddenNames :: [String]
forbiddenNames = ["Python3", "Flock", "Lockf", "ClusterExec", "\"-c\""]

{- | What the boundary must still reach.

A guard that only forbade the old names would stay quiet over a backend that had
stopped driving anything at all.
-}
reachedNames :: [String]
reachedNames =
    [ "HostBootstrap.Cluster.Command"
    , "HostBootstrap.Cluster.Ownership"
    , "interpretHostCommand"
    ]

-- Loopback exposure ------------------------------------------------------------

exposureCases :: [TestTree]
exposureCases =
    [ testCase "an exposure is always loopback and carries both ports" $
        case mkLoopbackExposure 30080 30080 of
            Right exposure -> do
                loopbackExposureListenAddress exposure @?= "127.0.0.1"
                loopbackExposureHostPort exposure @?= 30080
                loopbackExposureNodePort exposure @?= 30080
            other -> assertFailure ("expected an exposure, got " ++ showEither other)
    , testCase "an out-of-range port is refused" $
        forM_ [(0, 30080), (30080, 0), (65536, 30080)] $ \(hostPort, nodePort) ->
            case mkLoopbackExposure hostPort nodePort of
                Left (Failure _) -> pure ()
                other ->
                    assertFailure ("expected a port refusal, got " ++ showEither other)
    , testCase "an exact loopback binding settles" $ do
        outcome <- withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "127.0.0.1" "30080"))
        case outcome of
            Right () -> pure ()
            other -> assertFailure ("expected a settled exposure, got " ++ showEither other)
    , testCase "a wildcard binding is a Conflict, not a warning" $ do
        outcome <- withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "0.0.0.0" "30080"))
        case outcome of
            Left (Conflict detail) -> conflictObserved detail @?= "0.0.0.0:30080"
            other -> assertFailure ("expected a wildcard conflict, got " ++ showEither other)
    , testCase "a different published port is a Conflict" $ do
        outcome <- withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "127.0.0.1" "31080"))
        case outcome of
            Left (Conflict _) -> pure ()
            other -> assertFailure ("expected a port conflict, got " ++ showEither other)
    , testCase "an unparseable published port is a Failure, never an assumed match" $ do
        outcome <- withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "127.0.0.1" ""))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected a parse failure, got " ++ showEither other)
    , testCase "the rendered mapping is the loopback triple" $ do
        outcome <- withExposure 30080 (Right . preparedLoopbackExposureMapping)
        case outcome of
            Right mapping -> mapping @?= ("127.0.0.1", 30080, 30080)
            other -> assertFailure ("expected a mapping, got " ++ showEither other)
    ]

withExposure ::
    Int ->
    ( forall scope planId clusterId clusterFrame.
      PreparedLoopbackExposure scope planId clusterId clusterFrame ->
      Either ReconcileError result
    ) ->
    IO (Either ReconcileError result)
withExposure port consume =
    case mkLoopbackExposure port port of
        Left err -> pure (Left err)
        Right exposure ->
            withPlannedClusterFixture $ \planned ->
                withPreparedLoopbackExposure planned exposure id >>= consume

showEither :: (Show value) => Either ReconcileError value -> String
showEither = either show show
