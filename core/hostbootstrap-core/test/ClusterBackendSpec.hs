{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The cluster ownership backend and its loopback-bound exposure.

On POSIX hosts, the backend cases run the real filesystem and kernel @flock@
protocol against a lock frontend, driver, and container runtime the test writes
itself, so the four ownership clauses — exclusive entry, an origin record
written before the first mutation, identity binding to the control-plane
container ID, and identity-conditional deletion — are executed rather than
modelled.

The production protocol runs inside a Linux provider guest and deliberately
accepts POSIX guest paths. A native Windows test process has neither those path
semantics nor @flock@, so it runs the portable validation and exposure cases
without substituting a weaker locking protocol.
-}
module ClusterBackendSpec (tests) where

import ClusterReconcileSpec (
    withClusterFixtureM,
    withHarnessClusterFixtureM,
    withPlannedClusterFixture,
 )
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, try)
import Control.Monad (forM_)
import Data.List (isInfixOf, isSuffixOf, stripPrefix, tails)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.IORef (writeIORef)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import HostBootstrap.Cluster.Backend
import HostBootstrap.Cluster.Backend.Internal
    ( ClusterCommandResult (..)
    , ClusterExec (..)
    , StrongClusterBackend (..)
    , discoverInjectedStrongClusterBackend
    , runClosedClusterCommandForTest
    )
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Reconcile
import System.Directory (
    createDirectoryLink,
    createDirectoryIfMissing,
    createFileLink,
    copyFile,
    doesDirectoryExist,
    doesFileExist,
    getPermissions,
    listDirectory,
    removeFile,
    renameDirectory,
    renameFile,
    setOwnerExecutable,
    setPermissions,
 )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
#ifndef mingw32_HOST_OS
import System.Posix.Files (setFileMode)
#endif
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
backendCases = includePosixCases posixBackendCases ++ portableBackendCases

includePosixCases :: [TestTree] -> [TestTree]
#ifdef mingw32_HOST_OS
includePosixCases _ = []
#else
includePosixCases = id
#endif

portableBackendCases :: [TestTree]
portableBackendCases =
    [ testCase "production discovery resolves its closed HostConfig without caller paths" $ do
        discovered <- discoverStrongClusterBackend
        case discovered of
            Right _ -> pure ()
            Left (Unsupported _) -> pure ()
            Left other -> assertFailure ("production resolver returned a non-capability classification: " ++ show other)
    , testCase "a relative tool path is refused before any probe" $
        withFakeHost $ \host -> do
            discovered <-
                discoverInjectedStrongClusterBackend (localExec host) "kind" (runtimePath host) (kubectlPath host)
            case discovered of
                Left _ -> pure ()
                Right _ ->
                    assertFailure "a relative tool path must mint no capability"
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
    , {- A probe that exits zero is not by itself proof: it must NAME the lock
      front end it found, because the clause-1 bracket is built from that
      answer. This pins the decoder's fail-closed reading on every platform
      rather than leaving it to whichever userland the suite runs on. -}
      testCase "an exit-zero probe that names no recognizable lock tool mints nothing" $
        withFakeHost $ \host -> do
            let reports payload =
                    ClusterExec (\_ -> pure (ClusterCommandResult True payload ""))
                refuses label payload = do
                    discovered <-
                        discoverInjectedStrongClusterBackend
                            (reports payload)
                            (driverPath host)
                            (runtimePath host)
                            (kubectlPath host)
                    case discovered of
                        Left _ -> pure ()
                        other ->
                            assertFailure
                                (label ++ ": expected a private discovery refusal, got " ++ show (() <$ other))
            refuses "silent success" ""
            refuses "an unknown lock tool" "mkdirlock\n"
            refuses "a Linux lockf-only report" "lockf\n"
            refuses "a stat flavor instead of a lock tool" "gnu\n"
    ]

posixBackendCases :: [TestTree]
posixBackendCases =
    [ testCase "the outer runner kills a leader-exited grandchild that retains its pipes" $ do
        result <-
            timeout
                (12 * 1000 * 1000)
                (runClosedClusterCommandForTest 1 ["/bin/sh", "-c", "(trap '' INT TERM; sleep 30) & exit 0"])
        case result of
            Just commandResult -> clusterCommandOk commandResult @?= False
            Nothing -> assertFailure "the closed outer runner exceeded its bounded reader/group cleanup"
    , testCase "the outer runner escalates from TERM to group KILL within its bound" $ do
        result <-
            timeout
                (12 * 1000 * 1000)
                (runClosedClusterCommandForTest 1 ["/bin/sh", "-c", "trap '' INT TERM; while :; do sleep 1; done"])
        case result of
            Just commandResult -> clusterCommandOk commandResult @?= False
            Nothing -> assertFailure "the closed outer runner failed to kill an uncooperative process group"
    , testCase "the outer runner preserves asynchronous cancellation while cleaning its group" $ do
        resultBox <- newEmptyMVar
        worker <-
            forkIO $ do
                result <- tryAny (runClosedClusterCommandForTest 30 ["/bin/sh", "-c", "trap '' INT TERM; while :; do /bin/sleep 1; done"])
                putMVar resultBox result
        threadDelay 100000
        killThread worker
        settled <- timeout (12 * 1000 * 1000) (takeMVar resultBox)
        case settled of
            Just (Left failure)
                | Just ThreadKilled <- (fromException failure :: Maybe AsyncException) -> pure ()
            Just (Left failure) -> assertFailure ("expected ThreadKilled propagation, got " ++ show failure)
            Just (Right commandResult) ->
                assertFailure
                    ( "expected ThreadKilled propagation, command returned "
                        ++ show
                            ( clusterCommandOk commandResult
                            , length (clusterCommandStdout commandResult)
                            , clusterCommandStderr commandResult
                            )
                    )
            Nothing -> assertFailure "asynchronous cancellation hung during process-group cleanup"
    , testCase "the outer runner enters the closed root working directory and environment" $ do
        result <-
            runClosedClusterCommandForTest
                2
                [ "/bin/sh"
                , "-c"
                , "test \"$PWD\" = / && test \"$HOME\" = /nonexistent && test \"$PATH\" = /bin && test \"$DOCKER_HOST\" = unix:///var/run/docker.sock && printf 'entered\\n'"
                ]
        result @?= ClusterCommandResult True "entered\n" ""
    , testCase "the outer runner refuses a child past its output ceiling rather than truncating" $ do
        -- Two MiB against the driver's one MiB ceiling. The runner drains the
        -- pipe so the child never blocks on a full one, and then refuses:
        -- a truncated transcript reads as a complete one, so the caller is told
        -- the ceiling was passed instead of being handed a prefix.
        result <-
            runClosedClusterCommandForTest
                10
                ["/bin/sh", "-c", "/usr/bin/yes x | /usr/bin/head -c 2097152"]
        clusterCommandOk result @?= False
        clusterCommandStdout result @?= ""
        assertBool
            ("the refusal names the ceiling: " ++ clusterCommandStderr result)
            ("output ceiling" `isInfixOf` clusterCommandStderr result)
    , testCase "discovery mints no capability without the driver" $
        withFakeHost $ \host -> do
            discovered <-
                discoverInjectedStrongClusterBackend
                    (localExec host)
                    (hostRoot host </> "absent-driver")
                    (runtimePath host)
                    (kubectlPath host)
            case discovered of
                Left _ -> pure ()
                Right _ ->
                    assertFailure "a host without the driver must mint no capability"
    , testCase "a pristine project root gets a safe state parent, origin, and identity binding" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            result <- withClusterFixtureM $ \prepared -> do
                existedBefore <- doesDirectoryExist (preparedClusterStateDirectory prepared)
                observation <- runClusterReconcileCall backend prepared
                existsAfter <- doesDirectoryExist (preparedClusterStateDirectory prepared)
                recorded <-
                    readFile
                        ( preparedClusterStateDirectory prepared
                            </> (preparedClusterName prepared ++ ".cluster.origin")
                        )
                calls <- readFile (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observation, recorded, preparedClusterName prepared, existedBefore, existsAfter, calls))
            (observation, recorded, exactName, existedBefore, existsAfter, calls) <-
                either (assertFailure . show) pure result
            existedBefore @?= False
            existsAfter @?= True
            case observation of
                ClusterResultCreated identity -> identity @?= Text.pack controlPlaneId
                other -> assertFailure ("expected created observation, got " ++ show other)
            assertBool
                "the origin record names the absent original before the first mutation"
                ("\"origin\":\"absent\"" `isInfixOf` recorded)
            assertBool
                "the origin record binds the created control-plane identity"
                ( ("\"identity\":\"" ++ controlPlaneId ++ "\"") `isInfixOf` recorded
                    && "\"state\":\"managed\"" `isInfixOf` recorded
                    && ("\"" ++ exactName ++ "-control-plane\":\"" ++ controlPlaneId ++ "\"") `isInfixOf` recorded
                )
            assertBool "the origin carries a fresh 256-bit nonce" (maybe False ((== 64) . length) (originField "nonce" recorded))
            assertBool "the exact prepared config is supplied" ("create cluster --name" `isInfixOf` calls && "--config" `isInfixOf` calls)
            clusters <- readFile (clustersPath host)
            lines clusters @?= [exactName]
    , testCase "a Harness cluster omits the config flag instead of inventing a path" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withHarnessClusterFixtureM $ \prepared -> do
                preparedClusterConfigPath prepared @?= Nothing
                observed <- runClusterReconcileCall backend prepared
                calls <- readFile (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observed, calls))
            case outcome of
                Right (ClusterResultCreated identity, calls) -> do
                    identity @?= Text.pack controlPlaneId
                    assertBool "create was invoked" ("create cluster --name" `isInfixOf` calls)
                    assertBool "--config is absent" (not ("--config" `isInfixOf` calls))
                other -> assertFailure ("expected a Harness create without config, got " ++ show other)
    , testCase "a healthy cluster reports the control-plane identity, not the name" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            second <- withClusterFixtureM $ \prepared -> do
                _ <- runClusterReconcileCall backend prepared
                Right . clusterReconcileResultView <$> runClusterReconcileCall backend prepared
            case second of
                Right (ClusterResultHealthy identity) -> identity @?= Text.pack controlPlaneId
                other ->
                    assertFailure ("expected a healthy observation, got " ++ show other)
    , testCase "the inherited flock descriptor excludes a concurrent create bracket" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            writeFile (statePath host </> "slow-create") ""
            outcome <- withClusterFixtureM $ \prepared -> do
                firstBox <- newEmptyMVar
                secondBox <- newEmptyMVar
                let launch box = do
                        observed <- tryAny (runClusterReconcileCall backend prepared)
                        putMVar box observed
                _ <- forkIO (launch firstBox)
                threadDelay 100000
                _ <- forkIO (launch secondBox)
                first <- takeMVar firstBox
                second <- takeMVar secondBox
                clusters <- lines <$> readFile (clustersPath host)
                pure (Right (fmap clusterReconcileResultView first, fmap clusterReconcileResultView second, clusters))
            case outcome of
                Right
                    ( Right (ClusterResultCreated createdIdentity)
                        , Right (ClusterResultHealthy healthyIdentity)
                        , [_]
                        ) -> do
                            createdIdentity @?= Text.pack controlPlaneId
                            healthyIdentity @?= Text.pack controlPlaneId
                Right
                    ( Right (ClusterResultHealthy healthyIdentity)
                        , Right (ClusterResultCreated createdIdentity)
                        , [_]
                        ) -> do
                            createdIdentity @?= Text.pack controlPlaneId
                            healthyIdentity @?= Text.pack controlPlaneId
                other ->
                    assertFailure
                        ("expected one serialized create and one healthy observation, got " ++ show other)
    , testCase "a stopped control plane is unhealthy, never a silent recreate" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            observation <- withClusterFixtureM $ \prepared -> do
                _ <- runClusterReconcileCall backend prepared
                writeFile (statePath host </> (preparedClusterName prepared ++ "-control-plane.running")) "false\n"
                Right . clusterReconcileResultView <$> runClusterReconcileCall backend prepared
            case observation of
                Right (ClusterResultUnhealthy _) -> pure ()
                other ->
                    assertFailure ("expected an unhealthy observation, got " ++ show other)
            clusters <- readFile (clustersPath host)
            assertBool "the same-named cluster remains present" (not (null (lines clusters)))
    , testCase "a driver that cannot create reports a probe failure, not absence" $
        withFakeHost $ \host -> do
            writeFakeDriver host False
            backend <- requireBackend host
            observation <- runClusterFixtureCall backend
            case observation of
                Right (ClusterResultProbeFailed _) -> pure ()
                other ->
                    assertFailure ("expected a probe failure, got " ++ show other)
    , testCase "a durable executing origin retries a failed create with the same nonce" $
        withFakeHost $ \host -> do
            writeFakeDriver host False
            backend <- requireBackend host
            recovery <- withClusterFixtureM $ \prepared -> do
                first <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                preparedRecord <- readFile record
                writeFakeDriver host True
                second <- runClusterReconcileCall backend prepared
                managedRecord <- readFile record
                pure (Right (clusterReconcileResultView first, preparedRecord, clusterReconcileResultView second, managedRecord))
            case recovery of
                Right (ClusterResultProbeFailed _, preparedRecord, ClusterResultCreated identity, managedRecord) -> do
                    identity @?= Text.pack controlPlaneId
                    assertBool "the first durable state binds the exact pre-effect snapshots" ("\"state\":\"executing\"" `isInfixOf` preparedRecord)
                    assertBool "the retry settles managed" ("\"state\":\"managed\"" `isInfixOf` managedRecord)
                    originField "nonce" preparedRecord @?= originField "nonce" managedRecord
                other -> assertFailure ("expected crash-window recovery, got " ++ show other)
    , testCase "an origin-owned post-create crash repairs the exact identity without prior proof" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            writeFile (statePath host </> "kill-owner-after-create") ""
            recovery <- withClusterFixtureM $ \prepared -> do
                first <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                preparedRecord <- readFile record
                second <- runClusterReconcileCall backend prepared
                managedRecord <- readFile record
                pure (Right (clusterReconcileResultView first, preparedRecord, clusterReconcileResultView second, managedRecord))
            case recovery of
                Right (ClusterResultProbeFailed _, preparedRecord, ClusterResultHealthy identity, managedRecord) -> do
                    identity @?= Text.pack controlPlaneId
                    assertBool "the crash left exact executing intent" ("\"state\":\"executing\"" `isInfixOf` preparedRecord)
                    assertBool "the retry completed the managed transition" ("\"state\":\"managed\"" `isInfixOf` managedRecord)
                    originField "nonce" preparedRecord @?= originField "nonce" managedRecord
                other -> assertFailure ("expected origin-owned crash repair, got " ++ show other)
    , testCase "config drift after preparation fails before origin publication or create" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                case preparedClusterConfigPath prepared of
                    Nothing -> assertFailure "Production fixture must retain kind.yaml"
                    Just path -> writeFile path "kind: Cluster\nchanged: true\n"
                observed <- runClusterReconcileCall backend prepared
                recordExists <-
                    doesFileExist
                        (preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin"))
                callsExist <- doesFileExist (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observed, recordExists, callsExist))
            case outcome of
                Right (ClusterResultProbeFailed _, False, False) -> pure ()
                other -> assertFailure ("expected fail-closed config drift, got " ++ show other)
    , testCase "a failed cluster-list probe is never absence" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            writeFile (statePath host </> "fail-list") ""
            outcome <- runClusterFixtureCall backend
            case outcome of
                Right (ClusterResultProbeFailed _) -> pure ()
                other -> assertFailure ("expected strict list failure, got " ++ show other)
    , testCase "a symlinked .cluster parent is refused without touching its target" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                let stateDirectory = preparedClusterStateDirectory prepared
                    stateParent = takeDirectory stateDirectory
                    target = takeDirectory stateParent </> "foreign-cluster-parent"
                createDirectoryIfMissing True target
                writeFile (target </> "sentinel") "foreign\n"
                createDirectoryLink target stateParent
                observed <- runClusterReconcileCall backend prepared
                sentinel <- readFile (target </> "sentinel")
                targetEntries <- listDirectory target
                pure (Right (clusterReconcileResultView observed, sentinel, targetEntries))
            case outcome of
                Right (ClusterResultProbeFailed _, "foreign\n", ["sentinel"]) -> pure ()
                other -> assertFailure ("expected symlink-parent refusal, got " ++ show other)
    , testCase "a symlinked state leaf is refused without touching its target" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                let stateDirectory = preparedClusterStateDirectory prepared
                    stateParent = takeDirectory stateDirectory
                    target = stateParent </> "foreign-leaf"
                createDirectoryIfMissing True stateParent
                createDirectoryIfMissing True target
                writeFile (target </> "sentinel") "foreign\n"
                createDirectoryLink target stateDirectory
                observed <- runClusterReconcileCall backend prepared
                sentinel <- readFile (target </> "sentinel")
                targetEntries <- listDirectory target
                pure (Right (clusterReconcileResultView observed, sentinel, targetEntries))
            case outcome of
                Right (ClusterResultProbeFailed _, "foreign\n", ["sentinel"]) -> pure ()
                other -> assertFailure ("expected symlink-leaf refusal, got " ++ show other)
    , testCase "symlinked origin and lock paths are no-follow refusals" $
        forM_ ["origin", "lock"] $ \kind ->
            withFakeHost $ \host -> do
                backend <- requireBackend host
                outcome <- withClusterFixtureM $ \prepared -> do
                    let stateDirectory = preparedClusterStateDirectory prepared
                        suffix = if kind == "origin" then ".cluster.origin" else ".cluster.lock"
                        protectedPath = stateDirectory </> (preparedClusterName prepared ++ suffix)
                        target = takeDirectory stateDirectory </> ("foreign-" ++ kind)
                    createDirectoryIfMissing True stateDirectory
                    writeFile target "foreign\n"
                    createFileLink target protectedPath
                    observed <- runClusterReconcileCall backend prepared
                    targetBytes <- readFile target
                    pure (Right (clusterReconcileResultView observed, targetBytes))
                case outcome of
                    Right (ClusterResultProbeFailed _, "foreign\n") -> pure ()
                    other -> assertFailure (kind ++ ": expected no-follow refusal, got " ++ show other)
    , testCase "a hard-linked lock is refused before cluster observation or mutation" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                let stateDirectory = preparedClusterStateDirectory prepared
                    lockPath = stateDirectory </> (preparedClusterName prepared ++ ".cluster.lock")
                    foreignPath = takeDirectory stateDirectory </> "foreign-lock-inode"
                createDirectoryIfMissing True stateDirectory
                writeFile foreignPath ""
                createFileLink foreignPath lockPath
                observed <- runClusterReconcileCall backend prepared
                callsExist <- doesFileExist (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observed, callsExist))
            case outcome of
                Right (ClusterResultProbeFailed _, False) -> pure ()
                other -> assertFailure ("expected hard-linked-lock refusal, got " ++ show other)
    , testCase "a noncanonical foreign stage is refused and never unlinked" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                let stateDirectory = preparedClusterStateDirectory prepared
                    stage = stateDirectory </> (preparedClusterName prepared ++ ".cluster.origin.transition-prepared-foreign")
                createDirectoryIfMissing True stateDirectory
                writeFile stage "foreign\n"
                observed <- runClusterReconcileCall backend prepared
                remains <- doesFileExist stage
                callsExist <- doesFileExist (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observed, remains, callsExist))
            case outcome of
                Right (ClusterResultProbeFailed _, True, False) -> pure ()
                other -> assertFailure ("expected foreign-stage refusal without unlink, got " ++ show other)
    , testCase "a digest-shaped canonical stage for another owner is refused and retained" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                let stateDirectory = preparedClusterStateDirectory prepared
                    foreignRecord =
                        "{\"config\":null,\"nonce\":\""
                            ++ replicate 64 'a'
                            ++ "\",\"origin\":\"absent\",\"owner\":\"foreign-owner\",\"state\":\"prepared\",\"version\":1}\n"
                    stage =
                        stateDirectory
                            </> ( preparedClusterName prepared
                                    ++ ".cluster.origin.transition-prepared-"
                                    ++ replicate 64 'a'
                                )
                createDirectoryIfMissing True stateDirectory
                writeFile stage foreignRecord
                setPrivateMode stage
                observed <- runClusterReconcileCall backend prepared
                remains <- doesFileExist stage
                callsExist <- doesFileExist (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observed, remains, callsExist))
            case outcome of
                Right (ClusterResultProbeFailed _, True, False) -> pure ()
                other -> assertFailure ("expected foreign canonical-stage refusal, got " ++ show other)
    , testCase "an origin pathname replacement during create cannot be published as managed" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                writeFile (statePath host </> "replace-origin-during-create") (record ++ "\n")
                observed <- runClusterReconcileCall backend prepared
                recordRemains <- doesFileExist record
                pure (Right (clusterReconcileResultView observed, recordRemains))
            case outcome of
                Right (ClusterResultProbeFailed _, True) -> pure ()
                other -> assertFailure ("expected retained-record create refusal, got " ++ show other)
    , testCase "clause 4: cleanup removes only our identity" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            cleanup <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                firstRecord <- readFile (preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin"))
                removed <- runCleanupFromPrepared backend prepared created
                recordRemains <-
                    doesFileExist
                        ( preparedClusterStateDirectory prepared
                            </> (preparedClusterName prepared ++ ".cluster.origin")
                        )
                recreated <- runClusterReconcileCall backend prepared
                secondRecord <- readFile (preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin"))
                pure (Right (removed, recordRemains, clusterReconcileResultView recreated, originField "nonce" firstRecord, originField "nonce" secondRecord))
            case cleanup of
                Right (Right ClusterCleanupResultRemoved, False, ClusterResultCreated _, Just firstNonce, Just secondNonce) ->
                    assertBool "a new acquisition uses a fresh nonce" (firstNonce /= secondNonce)
                other -> assertFailure ("expected exact cleanup and reacquisition, got " ++ show other)
            clusters <- readFile (clustersPath host)
            assertBool "the raw backend reacquisition recreated the cluster" (not (null (lines clusters)))
    , testCase "clause 4: a replaced cluster is reported and left intact" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            cleanup <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                writeFile
                    (statePath host </> (preparedClusterName prepared ++ "-control-plane.id"))
                    "sha256:0000000000000000000000000000000000000000000000000000000000000000\n"
                runCleanupFromPrepared backend prepared created
            case cleanup of
                Right (ClusterCleanupResultReplaced identity) ->
                    identity @?= "sha256:0000000000000000000000000000000000000000000000000000000000000000"
                other ->
                    assertFailure ("expected a replacement report, got " ++ show other)
            clusters <- readFile (clustersPath host)
            assertBool "the replacement is left intact" (not (null (lines clusters)))
    , testCase "cleanup cannot unlink an origin pathname replaced during deletion" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                writeFile (statePath host </> "replace-origin-during-delete") (record ++ "\n")
                cleanup <- runCleanupFromPrepared backend prepared created
                recordRemains <- doesFileExist record
                pure (Right (cleanup, recordRemains))
            case outcome of
                Right (Left (Failure _), True) -> pure ()
                other -> assertFailure ("expected retained-record cleanup refusal, got " ++ show other)
    , testCase "a byte-identical replacement origin cannot authorize cordon" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withManagedCluster prepared created $ \managed ->
                    case withPreparedClusterCordon prepared managed id of
                        Left err -> pure (Left err)
                        Right cordon -> do
                            let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                                replacement = record ++ ".replacement"
                            original <- readFile record
                            writeFile replacement original
                            setPrivateMode replacement
                            renameFile replacement record
                            observed <- runClusterCordonCall backend cordon
                            runtimeCalled <- doesFileExist (statePath host </> "runtime.calls")
                            pure (Right (clusterCordonResultView observed, runtimeCalled))
            case outcome of
                Right (ClusterCordonResultFailed _, False) -> pure ()
                other -> assertFailure ("expected copied-origin refusal before cordon, got " ++ show other)
    , testCase "a fresh reconcile refuses a byte-identical copied self-bound origin" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                _created <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                    replacement = record ++ ".replacement"
                original <- readFile record
                callsBefore <- readFile (statePath host </> "driver.calls")
                writeFile replacement original
                setPrivateMode replacement
                renameFile replacement record
                observed <- runClusterReconcileCall backend prepared
                callsAfter <- readFile (statePath host </> "driver.calls")
                copied <- readFile record
                pure (Right (clusterReconcileResultView observed, callsBefore == callsAfter, copied == original))
            case outcome of
                Right (ClusterResultProbeFailed reason, True, True) ->
                    assertBool "the copied inode is rejected by the record's self-binding" ("record-self-identity" `Text.isInfixOf` reason)
                other -> assertFailure ("expected fresh-process copied-origin refusal, got " ++ show other)
    , testCase "the canonical origin is bound to the exact cluster name" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                _created <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                    expectedName = Text.pack ("\"name\":\"" ++ preparedClusterName prepared ++ "\"")
                original <- TextIO.readFile record
                callsBefore <- TextIO.readFile (statePath host </> "driver.calls")
                TextIO.writeFile record (Text.replace expectedName "\"name\":\"foreign-cluster\"" original)
                observed <- runClusterReconcileCall backend prepared
                callsAfter <- TextIO.readFile (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView observed, callsBefore == callsAfter))
            case outcome of
                Right (ClusterResultProbeFailed reason, True) ->
                    assertBool "the mismatched record name is rejected" ("record-name" `Text.isInfixOf` reason)
                other -> assertFailure ("expected exact record-name refusal, got " ++ show other)
    , testCase "a byte-identical replacement kube snapshot blocks settlement and recovery" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                writeFile (statePath host </> "replace-bound-kube") (preparedClusterStateDirectory prepared ++ "\n")
                first <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                executing <- readFile record
                callsAfterFirst <- readFile (statePath host </> "driver.calls")
                second <- runClusterReconcileCall backend prepared
                callsAfterSecond <- readFile (statePath host </> "driver.calls")
                entries <- listDirectory (preparedClusterStateDirectory prepared)
                pure
                    ( Right
                        ( clusterReconcileResultView first
                        , clusterReconcileResultView second
                        , executing
                        , callsAfterFirst == callsAfterSecond
                        , any (".cluster.origin.kube-" `isInfixOf`) entries
                        )
                    )
            case outcome of
                Right (ClusterResultProbeFailed _, ClusterResultProbeFailed reason, executing, True, True) -> do
                    assertBool "the exact executing record survives" ("\"state\":\"executing\"" `isInfixOf` executing)
                    assertBool "fresh recovery rejects the replacement inode" ("kube-stage-binding" `Text.isInfixOf` reason || "kube-snapshot-identity" `Text.isInfixOf` reason)
                other -> assertFailure ("expected snapshot replacement refusal without a second mutation, got " ++ show other)
    , testCase "config snapshot digest drift blocks settlement and fresh recovery" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                writeFile
                    (statePath host </> "tamper-bound-config")
                    (preparedClusterStateDirectory prepared ++ "\n")
                first <- runClusterReconcileCall backend prepared
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                executing <- TextIO.readFile record
                callsAfterFirst <- TextIO.readFile (statePath host </> "driver.calls")
                second <- runClusterReconcileCall backend prepared
                callsAfterSecond <- TextIO.readFile (statePath host </> "driver.calls")
                pure (Right (clusterReconcileResultView first, clusterReconcileResultView second, executing, callsAfterFirst == callsAfterSecond))
            case outcome of
                Right (ClusterResultProbeFailed firstReason, ClusterResultProbeFailed secondReason, executing, True) -> do
                    assertBool "settlement revalidates the consumed snapshot" ("config-snapshot-digest" `Text.isInfixOf` firstReason)
                    assertBool "fresh recovery revalidates the durable snapshot" ("config-stage-digest" `Text.isInfixOf` secondReason)
                    assertBool "drift cannot promote executing ownership" ("\"state\":\"executing\"" `Text.isInfixOf` executing)
                other -> assertFailure ("expected exact config-snapshot drift refusal, got " ++ show other)
    , testCase "a replacement lock path cannot establish a second cleanup namespace" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                let lockPath = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.lock")
                    replacement = lockPath ++ ".replacement"
                    record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                writeFile replacement ""
                setPrivateMode replacement
                renameFile replacement lockPath
                cleanup <- runCleanupFromPrepared backend prepared created
                recordRemains <- doesFileExist record
                pure (Right (cleanup, recordRemains))
            case outcome of
                Right (Left (Failure _), True) -> pure ()
                other -> assertFailure ("expected cross-call lock identity refusal, got " ++ show other)
    , testCase "cleanup never recreates a missing retained state leaf" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                let stateDirectory = preparedClusterStateDirectory prepared
                    displaced = stateDirectory ++ ".displaced"
                renameDirectory stateDirectory displaced
                cleanup <- runCleanupFromPrepared backend prepared created
                recreated <- doesDirectoryExist stateDirectory
                displacedRecord <- doesFileExist (displaced </> (preparedClusterName prepared ++ ".cluster.origin"))
                clusters <- lines <$> readFile (clustersPath host)
                pure (Right (cleanup, recreated, displacedRecord, not (null clusters)))
            case outcome of
                Right (Left (Failure _), False, True, True) -> pure ()
                other -> assertFailure ("expected missing-state refusal without recreation, got " ++ show other)
    , testCase "cleanup never recreates a missing retained lock" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                let stateDirectory = preparedClusterStateDirectory prepared
                    lockPath = stateDirectory </> (preparedClusterName prepared ++ ".cluster.lock")
                    record = stateDirectory </> (preparedClusterName prepared ++ ".cluster.origin")
                removeFile lockPath
                cleanup <- runCleanupFromPrepared backend prepared created
                recreated <- doesFileExist lockPath
                recordRemains <- doesFileExist record
                clusters <- lines <$> readFile (clustersPath host)
                pure (Right (cleanup, recreated, recordRemains, not (null clusters)))
            case outcome of
                Right (Left (Failure _), False, True, True) -> pure ()
                other -> assertFailure ("expected missing-lock refusal without recreation, got " ++ show other)
    , testCase "a copied replacement state leaf cannot reuse managed ownership bytes" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withManagedCluster prepared created $ \managed ->
                    case withPreparedClusterCordon prepared managed id of
                        Left err -> pure (Left err)
                        Right cordon -> do
                            let stateDirectory = preparedClusterStateDirectory prepared
                                displaced = stateDirectory ++ ".displaced"
                                base = preparedClusterName prepared
                            renameDirectory stateDirectory displaced
                            createDirectoryIfMissing True stateDirectory
                            forM_ [base ++ ".cluster.origin", base ++ ".cluster.lock"] $ \entry -> do
                                copyFile (displaced </> entry) (stateDirectory </> entry)
                                setPrivateMode (stateDirectory </> entry)
                            observed <- runClusterCordonCall backend cordon
                            runtimeCalled <- doesFileExist (statePath host </> "runtime.calls")
                            pure (Right (clusterCordonResultView observed, runtimeCalled))
            case outcome of
                Right (ClusterCordonResultFailed _, False) -> pure ()
                other -> assertFailure ("expected replacement state-leaf refusal, got " ++ show other)
    , testCase "cordon rechecks identity under the ownership lock before any node mutation" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withManagedCluster prepared created $ \managed ->
                    case withPreparedClusterCordon prepared managed id of
                        Left err -> pure (Left err)
                        Right cordon -> do
                            let replacement = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
                            writeFile (statePath host </> (preparedClusterName prepared ++ "-control-plane.id")) (replacement ++ "\n")
                            observed <- runClusterCordonCall backend cordon
                            runtimeCalled <- doesFileExist (statePath host </> "runtime.calls")
                            pure (Right (clusterCordonResultView observed, runtimeCalled))
            case outcome of
                Right (ClusterCordonResultReplaced identity, False) ->
                    identity @?= "sha256:2222222222222222222222222222222222222222222222222222222222222222"
                other -> assertFailure ("expected pre-mutation replacement refusal, got " ++ show other)
    , testCase "cordon targets the immutable node container ID rather than its reusable name" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withAppliedCluster backend prepared created $ \_applied -> do
                    calls <- readFile (statePath host </> "runtime.calls")
                    pure (calls, preparedClusterName prepared)
            case outcome of
                Right (calls, name) -> do
                    assertBool "the immutable container ID is the update target" (controlPlaneId `isInfixOf` calls)
                    assertBool "the reusable node name is not the update target" (not ((name ++ "-control-plane") `isSuffixOf` last (lines calls)))
                other -> assertFailure ("expected an ID-targeted cordon, got " ++ show other)
    , testCase "readiness checks API and nodes and distinguishes same identity from replacement" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withAppliedCluster backend prepared created $ \applied -> do
                    ready <- runClusterReadinessCall backend applied
                    writeFile (statePath host </> (preparedClusterName prepared ++ ".nodes-ready")) "false\n"
                    notReady <- runClusterReadinessCall backend applied
                    let replacement = "sha256:3333333333333333333333333333333333333333333333333333333333333333"
                    writeFile (statePath host </> (preparedClusterName prepared ++ "-control-plane.id")) (replacement ++ "\n")
                    replaced <- runClusterReadinessCall backend applied
                    writeFile (statePath host </> (preparedClusterName prepared ++ "-control-plane.id")) (controlPlaneId ++ "\n")
                    writeFile (statePath host </> (preparedClusterName prepared ++ ".nodes-ready")) "true\n"
                    writeFile (statePath host </> "fail-node-query") ""
                    probeFailure <- runClusterReadinessCall backend applied
                    pure
                        ( clusterReadinessResultView ready
                        , clusterReadinessResultView notReady
                        , clusterReadinessResultView replaced
                        , clusterReadinessResultView probeFailure
                        )
            case outcome of
                Right
                    ( ClusterReadinessResultReady _ readyIdentity
                        , ClusterReadinessResultNotReady notReadyIdentity
                        , ClusterReadinessResultNotReady replacementIdentity
                        , ClusterReadinessResultProbeFailed _
                        ) -> do
                            readyIdentity @?= Text.pack controlPlaneId
                            notReadyIdentity @?= Text.pack controlPlaneId
                            replacementIdentity @?= "sha256:3333333333333333333333333333333333333333333333333333333333333333"
                other -> assertFailure ("expected real readiness classifications, got " ++ show other)
    , testCase "readiness refuses a wrong origin owner and exact-node-set drift" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withAppliedCluster backend prepared created $ \applied -> do
                    let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                        owner = appliedClusterCordonOwnershipIdentity applied
                    original <- TextIO.readFile record
                    TextIO.writeFile record (Text.replace owner "foreign-owner" original)
                    wrongOwner <- clusterReadinessResultView <$> runClusterReadinessCall backend applied
                    TextIO.writeFile record original
                    writeFile (statePath host </> "missing-kube-node") ""
                    missing <- clusterReadinessResultView <$> runClusterReadinessCall backend applied
                    removeFile (statePath host </> "missing-kube-node")
                    writeFile (statePath host </> "unexpected-kube-node") ""
                    unexpected <- clusterReadinessResultView <$> runClusterReadinessCall backend applied
                    pure (wrongOwner, missing, unexpected)
            case outcome of
                Right
                    ( ClusterReadinessResultProbeFailed _
                        , ClusterReadinessResultNotReady missingIdentity
                        , ClusterReadinessResultNotReady unexpectedIdentity
                        ) -> do
                            missingIdentity @?= Text.pack controlPlaneId
                            unexpectedIdentity @?= Text.pack controlPlaneId
                other -> assertFailure ("expected owner/node-set readiness refusals, got " ++ show other)
    , testCase "readiness observation-version exhaustion fails without wrapping" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                withAppliedCluster backend prepared created $ \applied -> do
                    exhaustReadinessCounter backend
                    clusterReadinessResultView <$> runClusterReadinessCall backend applied
            case outcome of
                Right (ClusterReadinessResultProbeFailed reason) ->
                    assertBool "overflow is classified structurally" ("exhausted" `Text.isInfixOf` reason)
                other -> assertFailure ("expected readiness counter exhaustion, got " ++ show other)
    , testCase "ambient engine/provider overrides cannot drift reconcile, readiness, or cleanup" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                ready <-
                    withAppliedCluster backend prepared created $ \applied ->
                        clusterReadinessResultView <$> runClusterReadinessCall backend applied
                case ready of
                    Left err -> pure (Left err)
                    Right readinessView -> do
                        cleanup <- runCleanupFromPrepared backend prepared created
                        pure (Right (readinessView, cleanup))
            case outcome of
                Right (ClusterReadinessResultReady _ identity, Right ClusterCleanupResultRemoved) ->
                    identity @?= Text.pack controlPlaneId
                other -> assertFailure ("expected a closed namespace across ownership calls, got " ++ show other)
    , testCase "the lock file is a regular state sibling and cleanup probe failure preserves ownership" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                entries <- listDirectory (preparedClusterStateDirectory prepared)
                writeFile (statePath host </> "fail-list") ""
                cleanup <- runCleanupFromPrepared backend prepared created
                recordRemains <-
                    doesFileExist
                        (preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin"))
                pure (Right (entries, cleanup, recordRemains))
            case outcome of
                Right (entries, Left (Failure _), True) ->
                    assertBool ("expected a cluster lock file, saw " ++ show entries) (any (".cluster.lock" `isSuffixOf`) entries)
                other -> assertFailure ("expected cleanup probe failure to retain ownership, got " ++ show other)
    , testCase "Kind-list absence cannot hide retained owned node containers during cleanup" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                writeFile (clustersPath host) ""
                cleanup <- runCleanupFromPrepared backend prepared created
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                recordRemains <- doesFileExist record
                pure (Right (cleanup, recordRemains))
            case outcome of
                Right (Left (Failure _), True) -> pure ()
                other -> assertFailure ("expected retained-node cleanup refusal, got " ++ show other)
    , testCase "a failed runtime node query cannot be classified as absence" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            outcome <- withClusterFixtureM $ \prepared -> do
                created <- runClusterReconcileCall backend prepared
                writeFile (statePath host </> "fail-runtime-list") ""
                cleanup <- runCleanupFromPrepared backend prepared created
                let record = preparedClusterStateDirectory prepared </> (preparedClusterName prepared ++ ".cluster.origin")
                recordRemains <- doesFileExist record
                pure (Right (cleanup, recordRemains))
            case outcome of
                Right (Left (Failure _), True) -> pure ()
                other -> assertFailure ("expected runtime-observation cleanup refusal, got " ++ show other)
    , testCase "status is read-only and reports absence without creating" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            status <- withClusterFixtureM $ \prepared -> do
                before <- readFile (clustersPath host)
                stateBefore <- doesDirectoryExist (preparedClusterStateDirectory prepared)
                observed <- runClusterStatusCall backend prepared
                after <- readFile (clustersPath host)
                stateAfter <- doesDirectoryExist (preparedClusterStateDirectory prepared)
                pure (Right (observed, before == after, stateBefore, stateAfter))
            status @?= Right (ClusterStatusAbsent, True, False, False)
    , testCase "status reports a driver failure rather than absence" $
        withFakeHost $ \host -> do
            backend <- requireBackend host
            writeFile (statePath host </> "fail-list") ""
            status <- withClusterFixtureM $ \prepared -> Right <$> runClusterStatusCall backend prepared
            case status of
                Right (ClusterStatusProbeFailed _) -> pure ()
                other -> assertFailure ("expected a status probe failure, got " ++ show other)
    , testCase "status rejects stderr and malformed list framing for every name" $
        forM_
            [ "status-stderr"
            , "status-missing-newline"
            , "status-cr"
            , "status-duplicate"
            , "status-malformed-name"
            ]
            $ \marker ->
                withFakeHost $ \host -> do
                    backend <- requireBackend host
                    writeFile (statePath host </> marker) ""
                    status <- withClusterFixtureM $ \prepared -> Right <$> runClusterStatusCall backend prepared
                    case status of
                        Right (ClusterStatusProbeFailed _) -> pure ()
                        other -> assertFailure (marker ++ ": expected strict status refusal, got " ++ show other)
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

-- Fixtures ---------------------------------------------------------------------

controlPlaneId :: String
controlPlaneId =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111"

setPrivateMode :: FilePath -> IO ()
#ifdef mingw32_HOST_OS
setPrivateMode _ = pure ()
#else
setPrivateMode path = setFileMode path 0o600
#endif

-- | A temporary host carrying a driver and container runtime the test writes.
newtype FakeHost = FakeHost FilePath

hostRoot :: FakeHost -> FilePath
hostRoot (FakeHost root) = root

statePath :: FakeHost -> FilePath
statePath host = hostRoot host </> "state"

clustersPath :: FakeHost -> FilePath
clustersPath host = statePath host </> "clusters"

driverPath :: FakeHost -> FilePath
driverPath host = hostRoot host </> "fake-kind"

runtimePath :: FakeHost -> FilePath
runtimePath host = hostRoot host </> "fake-runtime"

kubectlPath :: FakeHost -> FilePath
kubectlPath host = hostRoot host </> "fake-kubectl"

ambientBinPath :: FakeHost -> FilePath
ambientBinPath host = hostRoot host </> "ambient-bin"

withFakeHost :: (FakeHost -> IO result) -> IO result
withFakeHost consume =
    withSystemTempDirectory "hostbootstrap-cluster-backend" $ \root -> do
        let host = FakeHost root
        createState host
        createDirectoryIfMissing True (ambientBinPath host)
        writeFile (ambientBinPath host </> "hostile-cluster-helper") "#!/bin/sh\nexit 0\n"
        setExecutable (ambientBinPath host </> "hostile-cluster-helper")
        writeFakeDriver host True
        writeFakeRuntime host
        writeFakeKubectl host
        writeFakeFlock host
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
            , "test \"$DOCKER_HOST\" = unix:///var/run/docker.sock || exit 91"
            , "test \"$DOCKER_CONTEXT\" = default || exit 92"
            , "test \"$KIND_EXPERIMENTAL_PROVIDER\" = docker || exit 93"
            , "test \"$PWD\" = / || exit 94"
            , "command -v hostile-cluster-helper >/dev/null 2>&1 && exit 95"
            , "printf '%s\\n' \"$*\" >> \"$state/driver.calls\""
            , "case \"$1 $2\" in"
            , "  'get clusters')"
            , "     test ! -f \"$state/fail-list\" || exit 71"
            , "     if test -f \"$state/status-stderr\"; then printf 'warning\\n' >&2; exit 0; fi"
            , "     if test -f \"$state/status-missing-newline\"; then printf foreign; exit 0; fi"
            , "     if test -f \"$state/status-cr\"; then printf 'foreign\\r\\n'; exit 0; fi"
            , "     if test -f \"$state/status-duplicate\"; then printf 'foreign\\nforeign\\n'; exit 0; fi"
            , "     if test -f \"$state/status-malformed-name\"; then printf 'bad name\\n'; exit 0; fi"
            , "     /bin/cat \"$state/clusters\"; exit 0;;"
            , "  'get kubeconfig') test ! -f \"$state/fail-kubeconfig\" || exit 72; printf '%s\\n' \"$4\"; exit 0;;"
            , "  'create cluster')"
            , "     name=\"$4\""
            , "     kubeconfig="
            , "     config="
            , "     while test \"$#\" -gt 0; do if test \"$1\" = --kubeconfig; then shift; kubeconfig=$1; elif test \"$1\" = --config; then shift; config=$1; fi; shift; done"
            , "     case \"$kubeconfig\" in /proc/self/fd/*|/dev/fd/*) ;; *) exit 75;; esac"
            , if createSucceeds then "     :" else "     exit 1"
            , "     test ! -f \"$state/slow-create\" || /bin/sleep 1"
            , "     printf '%s\\n' \"$name\" >> \"$state/clusters\""
            , "     printf '%s\\n' " ++ show controlPlaneId ++ " > \"$state/$name-control-plane.id\""
            , "     printf 'true\\n' > \"$state/$name-control-plane.running\""
            , "     printf 'true\\n' > \"$state/$name.api-ready\""
            , "     printf 'true\\n' > \"$state/$name.nodes-ready\""
            , "     printf 'private-kubeconfig\\n' > \"$kubeconfig\""
            , "     if test -f \"$state/tamper-bound-config\"; then root=$(/bin/cat \"$state/tamper-bound-config\"); for bound in \"$root\"/*.cluster.origin.config-*; do test -f \"$bound\" || continue; printf 'tampered-config\\n' > \"$bound\"; done; fi"
            , "     if test -f \"$state/replace-bound-kube\"; then root=$(/bin/cat \"$state/replace-bound-kube\"); for bound in \"$root\"/*.cluster.origin.kube-*; do test -f \"$bound\" || continue; /bin/cat \"$bound\" > \"$bound.replacement\"; /bin/chmod 600 \"$bound.replacement\"; /bin/mv \"$bound.replacement\" \"$bound\"; done; fi"
            , "     if test -f \"$state/kill-owner-after-create\"; then /bin/rm -f \"$state/kill-owner-after-create\"; kill -KILL \"$PPID\"; /bin/sleep 1; exit 76; fi"
            , "     if test -f \"$state/replace-origin-during-create\"; then record=$(/bin/cat \"$state/replace-origin-during-create\"); /bin/cat \"$record\" > \"$record.replacement\"; /bin/chmod 600 \"$record.replacement\"; /bin/mv \"$record.replacement\" \"$record\"; fi"
            , "     exit 0;;"
            , "  'delete cluster')"
            , "     name=\"$4\""
            , "     test ! -f \"$state/fail-delete\" || exit 73"
            , "     /usr/bin/grep -vx \"$name\" \"$state/clusters\" > \"$state/clusters.next\" || true"
            , "     /bin/mv \"$state/clusters.next\" \"$state/clusters\""
            , "     /bin/rm -f \"$state/$name-control-plane.id\" \"$state/$name-control-plane.running\""
            , "     /bin/rm -f \"$state/$name.api-ready\""
            , "     /bin/rm -f \"$state/$name.nodes-ready\""
            , "     if test -f \"$state/replace-origin-during-delete\"; then record=$(/bin/cat \"$state/replace-origin-during-delete\"); /bin/cat \"$record\" > \"$record.replacement\"; /bin/chmod 600 \"$record.replacement\"; /bin/mv \"$record.replacement\" \"$record\"; fi"
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
            , "test \"$DOCKER_HOST\" = unix:///var/run/docker.sock || exit 91"
            , "test \"$DOCKER_CONTEXT\" = default || exit 92"
            , "test \"$KIND_EXPERIMENTAL_PROVIDER\" = docker || exit 93"
            , "test \"$PWD\" = / || exit 94"
            , "if [ \"$1\" = update ]; then printf '%s\\n' \"$*\" >> \"$state/runtime.calls\"; exit 0; fi"
            , "if [ \"$1 $2\" = 'container ls' ]; then"
            , "  node=${7#name=^/}; node=${node%\\$}"
            , "  test ! -f \"$state/fail-runtime-list\" || exit 75"
            , "  test ! -f \"$state/$node.id\" || /bin/cat \"$state/$node.id\""
            , "  exit 0"
            , "fi"
            , "target=$4; base="
            , "for candidate in \"$state\"/*.id; do test -f \"$candidate\" || continue; test \"$(/bin/cat \"$candidate\")\" != \"$target\" || base=${candidate%.id}; done"
            , "test -n \"$base\" || exit 1"
            , "case \"$3\" in"
            , "  '{{.Id}}') printf '%s\\n' \"$target\"; exit 0;;"
            , "  '{{.State.Running}}') f=\"$base.running\";;"
            , "  *) exit 1;;"
            , "esac"
            , "if [ -f \"$f\" ]; then /bin/cat \"$f\"; exit 0; else exit 1; fi"
            ]

writeFakeKubectl :: FakeHost -> IO ()
writeFakeKubectl host = do
    writeFile (kubectlPath host) script
    setExecutable (kubectlPath host)
  where
    state = statePath host
    script =
        unlines
            [ "#!/bin/sh"
            , "state=" ++ show state
            , "test \"$DOCKER_HOST\" = unix:///var/run/docker.sock || exit 91"
            , "test \"$DOCKER_CONTEXT\" = default || exit 92"
            , "test \"$KIND_EXPERIMENTAL_PROVIDER\" = docker || exit 93"
            , "test \"$PWD\" = / || exit 94"
            , "read name"
            , "test -n \"$name\" || exit 1"
            , "case \"$2 $3 $4 $5\" in"
            , "  'get --raw=/readyz  ')"
            , "    test \"$(/bin/cat \"$state/$name.api-ready\" 2>/dev/null)\" = true || exit 1"
            , "    printf 'ok\\n'; exit 0;;"
            , "  'get nodes -o json')"
            , "    test ! -f \"$state/fail-node-query\" || exit 74"
            , "    if test \"$(/bin/cat \"$state/$name.nodes-ready\" 2>/dev/null)\" = true; then status=True; else status=False; fi"
            , "    if test -f \"$state/missing-kube-node\"; then printf '{\"items\":[]}\\n'; exit 0; fi"
            , "    if test -f \"$state/unexpected-kube-node\"; then node=unexpected-node; else node=$name-control-plane; fi"
            , "    printf '{\"items\":[{\"metadata\":{\"name\":\"%s\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"%s\"}]}}]}\\n' \"$node\" \"$status\""
            , "    exit 0;;"
            , "esac"
            , "exit 1"
            ]

fakeFlockPath :: FakeHost -> FilePath
fakeFlockPath host = hostRoot host </> "flock"

-- The behavioral tests exercise the inherited-descriptor protocol on macOS
-- as well as Linux. This narrow test frontend implements only the two
-- util-linux flock shapes discovery/backend use; production still discovers
-- and version-checks the real util-linux executable in its Linux frame.
writeFakeFlock :: FakeHost -> IO ()
writeFakeFlock host = do
    writeFile
        (fakeFlockPath host)
        ( unlines
            [ "#!/usr/bin/env python3"
            , "import fcntl,sys"
            , "if sys.argv[1:] == ['--version']:"
            , "    print('flock from util-linux 2.99-test'); raise SystemExit(0)"
            , "if len(sys.argv) == 5 and sys.argv[1:4] == ['-w','30','-x']:"
            , "    fcntl.flock(int(sys.argv[4]),fcntl.LOCK_EX); raise SystemExit(0)"
            , "raise SystemExit(2)"
            ]
        )
    setExecutable (fakeFlockPath host)

setExecutable :: FilePath -> IO ()
setExecutable path = do
    permissions <- getPermissions path
    setPermissions path (setOwnerExecutable True permissions)

-- | Run a command locally, so the backend's @flock@ bracket is real.
localExec :: FakeHost -> ClusterExec
localExec host = ClusterExec $ \argv ->
    case argv of
        [] ->
            pure (ClusterCommandResult False "" "empty command")
        (command : rest) -> do
            inherited <- getEnvironment
            let oldPath = fromMaybe "" (lookup "PATH" inherited)
                testPath = ambientBinPath host ++ ":" ++ hostRoot host ++ ":" ++ oldPath
                adversarialNamespace =
                    [ ("DOCKER_HOST", "tcp://attacker.invalid:2375")
                    , ("DOCKER_CONTEXT", "attacker-context")
                    , ("KIND_EXPERIMENTAL_PROVIDER", "podman")
                    ]
                overridden = "PATH" : map fst adversarialNamespace
                childEnvironment = ("PATH", testPath) : adversarialNamespace ++ filter ((`notElem` overridden) . fst) inherited
            (code, out, err) <-
                readCreateProcessWithExitCode
                    (proc command rest){env = Just childEnvironment}
                    ""
            pure (ClusterCommandResult (code == ExitSuccess) out err)

requireBackend :: FakeHost -> IO StrongClusterBackend
requireBackend host = do
    discovered <-
        discoverInjectedStrongClusterBackend
            (localExec host)
            (driverPath host)
            (runtimePath host)
            (kubectlPath host)
    either (assertFailure . ("backend discovery: " ++) . show) pure discovered

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

exhaustReadinessCounter :: StrongClusterBackend -> IO ()
exhaustReadinessCounter (StrongClusterBackend _ _ _ _ _ _ _ counter) =
    writeIORef counter maxBound

runClusterFixtureCall ::
    StrongClusterBackend ->
    IO (Either ReconcileError ClusterReconcileResultView)
runClusterFixtureCall backend =
    withClusterFixtureM $ \prepared -> do
        Right . clusterReconcileResultView <$> runClusterReconcileCall backend prepared

runCleanupFromPrepared ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ClusterCleanupResultView)
runCleanupFromPrepared backend prepared observation =
    withManagedCluster prepared observation $ \managed ->
        case withPreparedClusterCleanup prepared managed id of
            Left err -> pure (Left err)
            Right cleanup -> do
                result <- runClusterCleanupCall backend cleanup
                let view = clusterCleanupResultView result
                pure $ case (view, settleClusterCleanup cleanup result) of
                    (ClusterCleanupResultRemoved, Right ()) -> Right view
                    (ClusterCleanupResultReplaced _, Left (Conflict _)) -> Right view
                    (ClusterCleanupResultFailed err, Left _) -> Left err
                    (_, Left err) -> Left err
                    _ -> Left (Failure (FailureDetail "test cluster cleanup" "result view and settlement disagree" DoNotRetry))

withManagedCluster ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    (ManagedClusterHandle scope planId clusterId Provisioned -> IO (Either ReconcileError result)) ->
    IO (Either ReconcileError result)
withManagedCluster prepared observation consume =
    case settleClusterReconcile Nothing prepared observation of
        Left err -> pure (Left err)
        Right settlement ->
            withClusterReconcileSettlement
                settlement
                (\managed _receipt _change -> consume managed)
                ( \_key _generation _version _foreign ->
                    pure
                        ( Left
                            ( Failure
                                ( FailureDetail
                                    "test managed cluster"
                                    "a created cluster must settle as managed"
                                    DoNotRetry
                                )
                            )
                        )
                )

withAppliedCluster ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    (AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId Provisioned -> IO result) ->
    IO (Either ReconcileError result)
withAppliedCluster backend prepared observation consume =
    withManagedCluster prepared observation $ \managed ->
        case withPreparedClusterCordon prepared managed id of
            Left err -> pure (Left err)
            Right cordon -> do
                observed <- runClusterCordonCall backend cordon
                case settleClusterCordon cordon observed of
                    Left err -> pure (Left err)
                    Right applied -> Right <$> consume applied

originField :: String -> String -> Maybe String
originField field raw =
    case mapMaybe (stripPrefix ("\"" ++ field ++ "\":\"")) (tails raw) of
        value : _ -> Just (takeWhile (/= '"') value)
        [] -> Nothing

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
