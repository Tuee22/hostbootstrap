{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The cluster ownership backend and its loopback-bound exposure.

The backend cases run the real @flock@/@sh@ protocol on the host filesystem
against a driver and container runtime the test writes itself, so the four
ownership clauses — exclusive entry, an origin record written before the first
mutation, identity binding to the control-plane container ID, and
identity-conditional deletion — are executed rather than modelled.
-}
module ClusterBackendSpec (tests) where

import ClusterReconcileSpec (withClusterFixtureM, withPlannedClusterFixture)
import Control.Monad (forM_)
import HostBootstrap.Cluster.Backend
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Reconcile
import System.Directory (
    createDirectoryIfMissing,
    doesFileExist,
    getPermissions,
    listDirectory,
    setOwnerExecutable,
    setPermissions,
 )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterBackendSpec"
        [ testGroup "the clause-holding cluster backend" backendCases
        , testGroup "loopback-bound exposure" exposureCases
        ]

-- The clause-holding backend --------------------------------------------------

backendCases :: [TestTree]
backendCases =
    [ testCase "discovery mints no capability without the driver" $
        withFakeHost $ \host -> do
            discovered <-
                discoverStrongClusterBackend
                    (localExec host)
                    (hostRoot host </> "absent-driver")
                    (runtimePath host)
            case discovered of
                Left (Unsupported _) -> pure ()
                Left other -> assertFailure ("expected Unsupported, got " ++ show other)
                Right _ ->
                    assertFailure "a host without the driver must mint no capability"
    , testCase "a relative tool path is refused before any probe" $
        withFakeHost $ \host -> do
            discovered <-
                discoverStrongClusterBackend (localExec host) "kind" (runtimePath host)
            case discovered of
                Left (Failure _) -> pure ()
                Left other ->
                    assertFailure ("expected a validation failure, got " ++ show other)
                Right _ ->
                    assertFailure "a relative tool path must mint no capability"
    , testCase "an absent cluster is created, journalled, and identity-bound" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            spec <- requireSpec host
            observation <-
                runClusterFixtureCall backend spec
            observation @?= Right (ClusterCreated 17)

            recorded <- readFile (recordPath host)
            assertBool
                "the origin record names the absent original before the first mutation"
                ("origin absent" `elem` lines recorded)
            assertBool
                "the origin record binds the created control-plane identity"
                (any (("managed " ++ controlPlaneId) ==) (lines recorded))
            clusters <- readFile (clustersPath host)
            lines clusters @?= [clusterName]
    , testCase "a healthy cluster reports the control-plane identity, not the name" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            spec <- requireSpec host
            _ <- runClusterFixtureCall backend spec
            second <- runClusterFixtureCall backend spec
            case second of
                Right (ClusterHealthy generation) ->
                    assertBool "a healthy generation is strictly positive" (generation > 0)
                other ->
                    assertFailure ("expected a healthy observation, got " ++ show other)
    , testCase "a stopped control plane is unhealthy, never a silent recreate" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            spec <- requireSpec host
            _ <- runClusterFixtureCall backend spec
            writeFile (statePath host </> (clusterName ++ "-control-plane.running")) "false\n"
            observation <- runClusterFixtureCall backend spec
            case observation of
                Right (ClusterUnhealthy _) -> pure ()
                other ->
                    assertFailure ("expected an unhealthy observation, got " ++ show other)
            clusters <- readFile (clustersPath host)
            lines clusters @?= [clusterName]
    , testCase "a driver that cannot create reports a probe failure, not absence" $
        withFakeHost $ \host -> do
            writeFakeDriver host False
            backend <- requireBackend host
            spec <- requireSpec host
            observation <- runClusterFixtureCall backend spec
            case observation of
                Right (ClusterProbeFailed _) -> pure ()
                other ->
                    assertFailure ("expected a probe failure, got " ++ show other)
    , testCase "clause 4: cleanup removes only our identity" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            spec <- requireSpec host
            _ <- runClusterFixtureCall backend spec
            cleanup <- runCleanupFixtureCall backend spec
            cleanup @?= Right (Right ClusterCleanupRemoved)
            clusters <- readFile (clustersPath host)
            lines clusters @?= []
            recordRemains <- doesFileExist (recordPath host)
            recordRemains @?= False
    , testCase "clause 4: a replaced cluster is reported and left intact" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            spec <- requireSpec host
            _ <- runClusterFixtureCall backend spec
            -- Same name, different control plane: someone rebuilt the cluster
            -- out of band, so our receipt no longer denotes this object.
            writeFile
                (statePath host </> (clusterName ++ "-control-plane.id"))
                "sha256:0000000000000000000000000000000000000000000000000000000000000000\n"
            cleanup <- runCleanupFixtureCall backend spec
            case cleanup of
                Right (Right (ClusterCleanupReplaced generation)) ->
                    assertBool "a replacement generation is positive" (generation > 0)
                other ->
                    assertFailure ("expected a replacement report, got " ++ show other)
            clusters <- readFile (clustersPath host)
            lines clusters @?= [clusterName]
    , testCase "clause 1: the exclusive lock file lives beside the cluster state" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            spec <- requireSpec host
            _ <- runClusterFixtureCall backend spec
            entries <- listDirectory (statePath host)
            assertBool
                ("expected a cluster lock file, saw " ++ show entries)
                ((clusterName ++ ".cluster.lock") `elem` entries)
    , testCase "a spec refuses a relative state directory" $
        case mkClusterSpec clusterName "relative/state" "/tmp/kind.yaml" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected a validation failure, got " ++ showEither other)
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
    , testCase "an exact loopback binding settles" $
        case withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "127.0.0.1" "30080")) of
            Right () -> pure ()
            other -> assertFailure ("expected a settled exposure, got " ++ showEither other)
    , testCase "a wildcard binding is a Conflict, not a warning" $
        case withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "0.0.0.0" "30080")) of
            Left (Conflict detail) -> conflictObserved detail @?= "0.0.0.0:30080"
            other -> assertFailure ("expected a wildcard conflict, got " ++ showEither other)
    , testCase "a different published port is a Conflict" $
        case withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "127.0.0.1" "31080")) of
            Left (Conflict _) -> pure ()
            other -> assertFailure ("expected a port conflict, got " ++ showEither other)
    , testCase "an unparseable published port is a Failure, never an assumed match" $
        case withExposure 30080 (\prepared -> settleLoopbackExposure prepared (ObservedPortBinding "127.0.0.1" "")) of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected a parse failure, got " ++ showEither other)
    , testCase "the rendered mapping is the loopback triple" $
        case withExposure 30080 (Right . preparedLoopbackExposureMapping) of
            Right mapping -> mapping @?= ("127.0.0.1", 30080, 30080)
            other -> assertFailure ("expected a mapping, got " ++ showEither other)
    ]

-- Fixtures ---------------------------------------------------------------------

clusterName :: String
clusterName = "hostbootstrap-demo"

controlPlaneId :: String
controlPlaneId =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111"

-- | A temporary host carrying a driver and container runtime the test writes.
newtype FakeHost = FakeHost FilePath

hostRoot :: FakeHost -> FilePath
hostRoot (FakeHost root) = root

statePath :: FakeHost -> FilePath
statePath host = hostRoot host </> "state"

clustersPath :: FakeHost -> FilePath
clustersPath host = statePath host </> "clusters"

recordPath :: FakeHost -> FilePath
recordPath host = statePath host </> (clusterName ++ ".cluster.origin")

driverPath :: FakeHost -> FilePath
driverPath host = hostRoot host </> "fake-kind"

runtimePath :: FakeHost -> FilePath
runtimePath host = hostRoot host </> "fake-runtime"

withFakeHost :: (FakeHost -> IO result) -> IO result
withFakeHost consume =
    withSystemTempDirectory "hostbootstrap-cluster-backend" $ \root -> do
        let host = FakeHost root
        createState host
        writeFakeDriver host True
        writeFakeRuntime host
        consume host

createState :: FakeHost -> IO ()
createState host = do
    createDirectoryIfMissing True (statePath host)
    writeFile (clustersPath host) ""

{- | A driver with the shape the backend calls: @get clusters@, @create cluster
--name X --config Y@, and @delete cluster --name X@. Creation also materialises
the control-plane node's identity and running state.
-}
writeFakeDriver :: FakeHost -> Bool -> IO ()
writeFakeDriver host createSucceeds = do
    writeFile (driverPath host) script
    setExecutable (driverPath host)
  where
    state = statePath host
    script =
        unlines
            [ "#!/bin/sh"
            , "state=" ++ show state
            , "case \"$1 $2\" in"
            , "  'get clusters') cat \"$state/clusters\"; exit 0;;"
            , "  'create cluster')"
            , "     name=\"$4\""
            , if createSucceeds then "     :" else "     exit 1"
            , "     printf '%s\\n' \"$name\" >> \"$state/clusters\""
            , "     printf '%s\\n' " ++ show controlPlaneId ++ " > \"$state/$name-control-plane.id\""
            , "     printf 'true\\n' > \"$state/$name-control-plane.running\""
            , "     exit 0;;"
            , "  'delete cluster')"
            , "     name=\"$4\""
            , "     grep -vx \"$name\" \"$state/clusters\" > \"$state/clusters.next\" || true"
            , "     mv \"$state/clusters.next\" \"$state/clusters\""
            , "     rm -f \"$state/$name-control-plane.id\" \"$state/$name-control-plane.running\""
            , "     exit 0;;"
            , "esac"
            , "exit 1"
            ]

-- | A container runtime that answers only the two inspect formats the backend
-- uses, from files the driver writes.
writeFakeRuntime :: FakeHost -> IO ()
writeFakeRuntime host = do
    writeFile (runtimePath host) script
    setExecutable (runtimePath host)
  where
    state = statePath host
    script =
        unlines
            [ "#!/bin/sh"
            , "state=" ++ show state
            , "case \"$3\" in"
            , "  '{{.Id}}') f=\"$state/$4.id\";;"
            , "  '{{.State.Running}}') f=\"$state/$4.running\";;"
            , "  *) exit 1;;"
            , "esac"
            , "if [ -f \"$f\" ]; then cat \"$f\"; exit 0; else exit 1; fi"
            ]

setExecutable :: FilePath -> IO ()
setExecutable path = do
    permissions <- getPermissions path
    setPermissions path (setOwnerExecutable True permissions)

-- | Run a command locally, so the backend's @flock@ bracket is real.
localExec :: FakeHost -> ClusterExec
localExec _ = ClusterExec $ \argv ->
    case argv of
        [] ->
            pure (ClusterCommandResult False "" "empty command")
        (command : rest) -> do
            (code, out, err) <- readProcessWithExitCode command rest ""
            pure (ClusterCommandResult (code == ExitSuccess) out err)

requireBackend :: FakeHost -> IO StrongClusterBackend
requireBackend host = do
    discovered <-
        discoverStrongClusterBackend
            (localExec host)
            (driverPath host)
            (runtimePath host)
    either (assertFailure . ("backend discovery: " ++) . show) pure discovered

requireSpec :: FakeHost -> IO ClusterSpec
requireSpec host =
    either
        (assertFailure . ("cluster spec: " ++) . show)
        pure
        ( mkClusterSpec
            clusterName
            (statePath host)
            (hostRoot host </> "kind.yaml")
        )

runClusterFixtureCall ::
    StrongClusterBackend ->
    ClusterSpec ->
    IO (Either ReconcileError ClusterObservation)
runClusterFixtureCall backend spec =
    withClusterFixtureM 17 $ \_ _ prepared ->
        Right <$> runClusterReconcileCall backend spec prepared

runCleanupFixtureCall ::
    StrongClusterBackend ->
    ClusterSpec ->
    IO (Either ReconcileError (Either ReconcileError ClusterCleanupObservation))
runCleanupFixtureCall backend spec =
    withClusterFixtureM 17 $ \_ _ prepared -> do
        settled <- pure (settleClusterReconcile Nothing prepared (ClusterCreated 17))
        case settled of
            Left err -> pure (Left err)
            Right result ->
                withReconcileResult
                    result
                    ( \managed receipt _ ->
                        case withPreparedClusterCleanup managed receipt id of
                            Left err -> pure (Left err)
                            Right cleanup ->
                                Right <$> runClusterCleanupCall backend spec cleanup
                    )
                    ( \_ _ ->
                        pure
                            ( Left
                                ( Failure
                                    ( FailureDetail
                                        "test cleanup"
                                        "a created cluster must be managed"
                                        DoNotRetry
                                    )
                                )
                            )
                    )

withExposure ::
    Int ->
    ( forall scope planId clusterId clusterFrame.
      PreparedLoopbackExposure scope planId clusterId clusterFrame ->
      Either ReconcileError result
    ) ->
    Either ReconcileError result
withExposure port consume = do
    exposure <- mkLoopbackExposure port port
    joinEither $
        withPlannedClusterFixture $ \planned ->
            withPreparedLoopbackExposure planned exposure consume

joinEither :: Either error (Either error value) -> Either error value
joinEither = either Left id

showEither :: (Show value) => Either ReconcileError value -> String
showEither = either show show
