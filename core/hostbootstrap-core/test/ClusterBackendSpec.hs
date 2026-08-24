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
module ClusterBackendSpec (tests, withRuntimeExposure) where

import ClusterReconcileSpec (
    withAppliedFixtureCordon,
    withClusterFixtureM,
    withHarnessClusterFixtureM,
    withNvkindClusterFixtureM,
 )
import Control.Monad (forM_)
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified FakeCluster
import HostBootstrap.Cluster.Backend
import HostBootstrap.Cluster.Lifecycle (ClusterPlan, ClusterProfile (..), resolvePlan)
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Docker, Helm, Kind, Kubectl, Nvkind), mkAbsExe)
import HostBootstrap.Protected (
    RecordKey,
    listProtectedRecords,
    openProtectedStore,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
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
        forM_ [Kind, Docker, Kubectl, Helm] $ \omitted -> do
            self <- getExecutablePath
            outcome <- withClusterFixtureM $ \prepared -> do
                discovered <- discoverPrepared (hostConfigWithout self omitted) prepared
                pure (Right (() <$ discovered))
            case outcome of
                Right (Left (Unsupported _)) -> pure ()
                other -> assertFailure ("a missing tool must mint no backend, got " <> show other)
    , testCase "a configuration carrying all three is admitted with no probe" $ do
        self <- getExecutablePath
        outcome <- withClusterFixtureM $ \prepared -> do
            discovered <- discoverPrepared (clusterHostConfig self) prepared
            pure (Right (() <$ discovered))
        case outcome of
            Right (Right ()) -> pure ()
            other -> assertFailure ("expected an admitted backend, got " <> show other)
    , testCase "nvkind discovery requires nvkind and does not fall back to Kind" $ do
        self <- getExecutablePath
        outcome <- withNvkindClusterFixtureM $ \prepared -> do
            let withoutKind = (clusterHostConfig self){hcToolPaths = Map.delete Kind (hcToolPaths (clusterHostConfig self))}
                withoutNvkind = (clusterHostConfig self){hcToolPaths = Map.delete Nvkind (hcToolPaths (clusterHostConfig self))}
            admitted <- discoverPrepared withoutKind prepared
            refused <- discoverPrepared withoutNvkind prepared
            pure (Right (either (const False) (const True) admitted, either isUnsupported (const False) refused))
        outcome @?= Right (True, True)
    , testCase "a discovered Kind backend refuses an nvkind package before a command" $ do
        self <- getExecutablePath
        outcome <- withClusterFixtureM $ \kindPrepared -> do
            backend <- requireBackend (clusterHostConfig self) kindPrepared
            nested <- withNvkindClusterFixtureM $ \nvkindPrepared -> do
                observed <- runClusterStatusCall backend nvkindPrepared
                pure (Right observed)
            pure (Right nested)
        case outcome of
            Right (Right (ClusterStatusProbeFailed reason)) -> assertBool "the mismatch does not name the driver" ("driver differs" `Text.isInfixOf` reason)
            other -> assertFailure ("expected a pre-command driver mismatch, got " <> show other)
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
    , testCase "a Harness package retains its isolated driver configuration" $ do
        outcome <-
            withHarnessClusterFixtureM
                (\prepared -> pure (Right (preparedClusterConfigPath prepared)))
        case outcome of
            Right (Just path) -> assertBool "Harness config is not the exact driver path" ("cluster/kind/config.yaml" `isSuffixOf` path)
            other -> assertFailure ("expected an isolated Harness config path, got " ++ show other)
    ]
  where
    isUnsupported (Unsupported _) = True
    isUnsupported _ = False

hostConfigWithout :: FilePath -> HostTool -> HostConfig
hostConfigWithout self omitted =
    let full = clusterHostConfig self
     in full{hcToolPaths = Map.delete omitted (hcToolPaths full)}

clusterHostConfig :: FilePath -> HostConfig
clusterHostConfig self =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64
        , hcToolPaths =
            Map.fromList [(Kind, fixtureExe self), (Docker, fixtureExe self), (Kubectl, fixtureExe self), (Helm, fixtureExe self), (Nvkind, fixtureExe self)]
        }

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

discoverPrepared ::
    HostConfig ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError StrongClusterBackend)
discoverPrepared cfg prepared =
    withPreparedPlanOwnedClusterConfig prepared (discoverStrongClusterBackend cfg)

requireBackend ::
    HostConfig ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO StrongClusterBackend
requireBackend cfg prepared = do
    discovered <- discoverPrepared cfg prepared
    either (assertFailure . show) pure discovered

-- The join, driven for real -------------------------------------------------------

joinCases :: [TestTree]
joinCases =
    [ testCase "a fresh reconcile creates the plan's own cluster and binds its nodes" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
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
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                observed <- runClusterReconcileCall backend prepared
                let controlPlane = take 1 (preparedClusterNodeNames prepared)
                    expected = map (Text.pack . FakeCluster.fixtureNodeIdentity) controlPlane
                pure (Right (clusterReconcileResultView observed, expected))
        case outcome of
            Right (ClusterResultCreated identity, [expected]) -> identity @?= expected
            other -> assertFailure ("expected the control plane's own identity, got " <> show other)
    , testCase "the durable record lives under the plan's own state directory" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                Right . length <$> recordsUnder (preparedClusterStateDirectory prepared)
        outcome @?= Right (1 :: Int)
    , testCase "retained reverse conditionally deletes the cluster and retires its record" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    projectRoot = takeDirectory durableRoot
                    plan = resolvePlan (preparedClusterName prepared) projectRoot Production
                released <- releaseRetainedCluster cfg plan
                remaining <- FakeCluster.readClusters root
                records <- recordsUnder stateRoot
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (released, remaining, records, mutations))
        case outcome of
            Right (Right (), [], [], mutations) -> mutations @?= ["create", "delete"]
            other -> assertFailure ("expected retained cluster release, got " <> show other)
    , testCase "retained Harness reverse resolves the exact run-scoped store" $ do
        outcome <- withBackend $ \cfg root ->
            withHarnessClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                let stateRoot = preparedClusterStateDirectory prepared
                    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))
                    runName = takeFileName durableRoot
                    projectRoot = takeDirectory (takeDirectory durableRoot)
                    suffix = Text.pack ("-test-" <> runName)
                projectName <-
                    maybe
                        (assertFailure "the Harness cluster name lacks its exact run suffix")
                        (pure . Text.unpack)
                        (Text.stripSuffix suffix (Text.pack (preparedClusterName prepared)))
                let plan = resolvePlan projectName projectRoot (TestCase runName)
                released <- releaseRetainedCluster cfg plan
                remaining <- FakeCluster.readClusters root
                records <- recordsUnder stateRoot
                pure (Right (released, remaining, records))
        outcome @?= Right (Right (), [], [])
    , testCase "the credential the driver wrote lands inside that state directory" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
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
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
                declare root prepared
                _ <- runClusterReconcileCall backend prepared
                observed <- runClusterReconcileCall backend prepared
                mutations <- FakeCluster.recordedClusterMutations root
                pure (Right (clusterReconcileResultView observed, mutations))
        case outcome of
            Right (ClusterResultHealthy _, mutations) -> mutations @?= ["create"]
            other -> assertFailure ("expected a healthy cluster, got " <> show other)
    , testCase "an owned cluster whose containers stopped is unhealthy, never recreated" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
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
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
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
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \prepared -> do
                backend <- requireBackend cfg prepared
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
withBackend :: (HostConfig -> FilePath -> IO result) -> IO result
withBackend consume =
    withSystemTempDirectory "hostbootstrap-cluster-backend" $ \temporary -> do
        root <- canonicalizePath temporary
        _ <- FakeCluster.newClusterFixture root []
        self <- getExecutablePath
        FakeCluster.withFakeClusterClient root (consume (clusterHostConfig self) root)

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
    , testCase "the hidden backend component retains capability data and no injected executor" $ do
        root <- repositoryRoot
        let internalPath = root </> "core" </> "hostbootstrap-core" </> "internal" </> "cluster-backend" </> "HostBootstrap" </> "Cluster" </> "Backend" </> "Internal.hs"
        present <- doesFileExist internalPath
        assertBool "the plan-owned hidden backend component is absent" present
        internalSource <- readFile' internalPath
        forM_ forbiddenNames $ \name ->
            assertBool (name <> " is named in the hidden capability component") (not (name `isInfixOf` internalSource))
    , testCase "the backend still reaches the described commands and the clause-holding driver" $ do
        source <- backendSource
        forM_ reachedNames $ \name ->
            assertBool
                (name <> " is not reached from the cluster backend")
                (name `isInfixOf` source)
    , testCase "runtime publication has no scan-then-bind or caller-port compatibility path" $ do
        source <- backendSource
        forM_ ["mkLoopbackExposure", "PreparedLoopbackExposure", "settleLoopbackExposure", "Network.Socket"] $ \name ->
            assertBool (name <> " remains in the cluster backend") (not (name `isInfixOf` source))
        forM_ ["127.0.0.1::", "ResolvedExposure", "getRandomBytes 32", "ExpectAbsent"] $ \name ->
            assertBool (name <> " is absent from runtime-owned exposure") (name `isInfixOf` source)
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
    [ testCase "intent contains only semantic service and cluster target" $
        case mkExposureIntent "web" "demo-control-plane" 30080 of
            Right intent -> do
                exposureIntentService intent @?= "web"
                exposureIntentTargetHost intent @?= "demo-control-plane"
                exposureIntentTargetPort intent @?= 30080
            Left refusal -> assertFailure (show refusal)
    , testCase "an invalid internal target port is refused" $
        forM_ [0, 65536] $ \port -> case mkExposureIntent "web" "demo-control-plane" port of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected an internal-port refusal, got " <> show other)
    , testCase "the runtime assigns distinct loopback ports and exact inspection mints them" $ do
        outcome <- withRuntimeExposure $ \_ root _ _ resolved -> do
            web <- resolvedTuple "web" resolved
            registry <- resolvedTuple "registry" resolved
            mutations <- FakeCluster.recordedClusterMutations root
            pure (web, registry, mutations)
        case outcome of
            Right (("127.0.0.1", webPort, webTarget, 30080), ("127.0.0.1", registryPort, registryTarget, 30500), mutations) -> do
                assertBool "the runtime reused one selected host port" (webPort /= registryPort)
                assertBool "the services target different cluster nodes" (webTarget == registryTarget && "-control-plane" `Text.isSuffixOf` webTarget)
                mutations @?= ["create", "update", "relay-create"]
            other -> assertFailure ("expected runtime-resolved mappings, got " <> show other)
    , testCase "exact recovery re-inspects the same relay without creating another" $ do
        outcome <- withRuntimeExposure $ \backend root _ prepared first -> do
            second <- runClusterExposureCall backend prepared >>= either (assertFailure . show) pure
            firstWeb <- resolvedTuple "web" first
            secondWeb <- resolvedTuple "web" second
            mutations <- FakeCluster.recordedClusterMutations root
            pure (firstWeb, secondWeb, mutations)
        case outcome of
            Right (first, second, mutations) -> do
                first @?= second
                mutations @?= ["create", "update", "relay-create"]
            other -> assertFailure ("expected exact exposure recovery, got " <> show other)
    , testCase "a wildcard mapping is a Conflict and its ownership record remains" $ do
        outcome <- withRuntimeExposure $ \backend root stateRoot prepared _ -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayMappings = [(listener, "0.0.0.0", port) | (listener, _, port) <- FakeCluster.relayMappings relay]} | relay <- relays]
            rerun <- runClusterExposureCall backend prepared
            records <- recordsUnder stateRoot
            pure (case rerun of Left (Conflict _) -> True; _ -> False, length records)
        case outcome of
            Right (True, 2) -> pure ()
            other -> assertFailure ("expected a retained wildcard conflict, got " <> showExposureOutcome other)
    , testCase "a replacement relay is a Conflict and is not adopted" $ do
        outcome <- withRuntimeExposure $ \backend root _ prepared _ -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayIdentity = Text.unpack (Text.replicate 64 "b")} | relay <- relays]
            rerun <- runClusterExposureCall backend prepared
            pure (case rerun of Left (Conflict _) -> True; _ -> False)
        outcome @?= Right True
    , testCase "an additional runtime mapping is a Conflict" $ do
        outcome <- withRuntimeExposure $ \backend root _ prepared _ -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayMappings = (29999, "127.0.0.1", 41999) : FakeCluster.relayMappings relay} | relay <- relays]
            rerun <- runClusterExposureCall backend prepared
            pure (case rerun of Left (Conflict _) -> True; _ -> False)
        outcome @?= Right True
    , testCase "release removes the exact relay before forgetting its record" $ do
        outcome <- withRuntimeExposure $ \backend root stateRoot prepared _ -> do
            released <- releaseClusterExposureCall backend prepared
            relays <- FakeCluster.readRelays root
            records <- recordsUnder stateRoot
            mutations <- FakeCluster.recordedClusterMutations root
            pure (released, relays, length records, mutations)
        case outcome of
            Right (Right (), [], 1, mutations) -> mutations @?= ["create", "update", "relay-create", "relay-delete"]
            other -> assertFailure ("expected identity-conditional relay release, got " <> showExposureOutcome other)
    , testCase "reverse recovers and releases the recorded relay without caller-supplied identity or port" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            self <- getExecutablePath
            plan <- recordedPlan stateRoot resolved
            released <- releaseRecordedClusterExposure (clusterHostConfig self) plan
            relays <- FakeCluster.readRelays root
            records <- recordsUnder stateRoot
            mutations <- FakeCluster.recordedClusterMutations root
            pure (released, relays, length records, mutations)
        case outcome of
            Right (Right (), [], 1, mutations) -> mutations @?= ["create", "update", "relay-create", "relay-delete"]
            other -> assertFailure ("expected recorded reverse exposure release, got " <> showExposureOutcome other)
    , testCase "reverse refuses a replacement relay and retains the exposure record" $ do
        outcome <- withRuntimeExposure $ \_ root stateRoot _ resolved -> do
            relays <- FakeCluster.readRelays root
            FakeCluster.writeRelays root [relay{FakeCluster.relayIdentity = Text.unpack (Text.replicate 64 "b")} | relay <- relays]
            self <- getExecutablePath
            plan <- recordedPlan stateRoot resolved
            released <- releaseRecordedClusterExposure (clusterHostConfig self) plan
            records <- recordsUnder stateRoot
            pure (case released of Left _ -> True; Right () -> False, length records)
        outcome @?= Right (True, 2)
    , testCase "cluster cleanup refuses until the owned relay has been released" $ do
        outcome <- withBackend $ \cfg root ->
            withClusterFixtureM $ \cluster -> do
                backend <- requireBackend cfg cluster
                declare root cluster
                withAppliedFixtureCordon backend cluster $ \applied -> do
                    case mkExposureIntent "web" (Text.pack (preparedClusterName cluster <> "-control-plane")) 30080 of
                        Left refusal -> pure (Left refusal)
                        Right intent -> case withPreparedClusterExposure applied immutableTestImage [intent] id of
                            Left refusal -> pure (Left refusal)
                            Right exposure -> do
                                exposed <- runClusterExposureCall backend exposure
                                case exposed of
                                    Left refusal -> pure (Left refusal)
                                    Right _ -> case withPreparedClusterCleanup cluster (appliedClusterCordonHandle applied) id of
                                        Left refusal -> pure (Left refusal)
                                        Right cleanup -> do
                                            result <- runClusterCleanupCall backend cleanup
                                            remaining <- FakeCluster.readClusters root
                                            pure
                                                ( Right
                                                    ( case clusterCleanupResultView result of
                                                        ClusterCleanupResultFailed (Failure _) -> True
                                                        _ -> False
                                                    , not (null remaining)
                                                    )
                                                )
        outcome @?= Right (True, True)
    ]

withRuntimeExposure ::
    ( forall scope planId clusterId clusterFrame.
      StrongClusterBackend ->
      FilePath ->
      FilePath ->
      PreparedClusterExposure scope planId clusterId clusterFrame ->
      [ResolvedExposure scope planId clusterId ()] ->
      IO result
    ) ->
    IO (Either ReconcileError result)
withRuntimeExposure consume =
    withBackend $ \cfg root ->
        withClusterFixtureM $ \cluster -> do
            backend <- requireBackend cfg cluster
            declare root cluster
            withAppliedFixtureCordon backend cluster $ \applied -> do
                web <- pure (mkExposureIntent "web" (Text.pack (preparedClusterName cluster <> "-control-plane")) 30080)
                registry <- pure (mkExposureIntent "registry" (Text.pack (preparedClusterName cluster <> "-control-plane")) 30500)
                case (web, registry) of
                    (Right webIntent, Right registryIntent) ->
                        case withPreparedClusterExposure applied immutableTestImage [webIntent, registryIntent] id of
                            Left refusal -> pure (Left refusal)
                            Right prepared -> do
                                resolved <- runClusterExposureCall backend prepared
                                case resolved of
                                    Left refusal -> pure (Left refusal)
                                    Right exact -> Right <$> consume backend root (preparedClusterStateDirectory cluster) prepared exact
                    (Left refusal, _) -> pure (Left refusal)
                    (_, Left refusal) -> pure (Left refusal)

recordedPlan :: FilePath -> [ResolvedExposure scope planId clusterId seed] -> IO ClusterPlan
recordedPlan stateRoot resolved = do
    (_, _, target, _) <- resolvedTuple "web" resolved
    name <- maybe (assertFailure "the fixture target lacks its control-plane suffix") (pure . Text.unpack) (Text.stripSuffix "-control-plane" target)
    pure (resolvePlan name (takeDirectory durableRoot) Production)
  where
    durableRoot = takeDirectory (takeDirectory (takeDirectory stateRoot))

immutableTestImage :: Text.Text
immutableTestImage = "example.invalid/hostbootstrap-test@sha256:" <> Text.replicate 64 "a"

resolvedTuple :: Text.Text -> [ResolvedExposure scope planId clusterId seed] -> IO (Text.Text, Int, Text.Text, Int)
resolvedTuple service resolved =
    case withResolvedExposure service resolved $ \exact ->
        ( resolvedExposureListenAddress exact
        , resolvedExposureHostPort exact
        , resolvedExposureTargetHost exact
        , resolvedExposureTargetPort exact
        ) of
        Left refusal -> assertFailure (show refusal)
        Right tuple -> pure tuple

showExposureOutcome :: value -> String
showExposureOutcome _ = "opaque exposure outcome"
