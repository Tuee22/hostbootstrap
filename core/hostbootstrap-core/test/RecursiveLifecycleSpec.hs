{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module RecursiveLifecycleSpec (
    fixtureSteps,
    fixtureAuthorityImage,
    projectChild,
    runLifecycleChild,
    runLifecycleFrameChild,
    runLifecycleFixtureClient,
    runLifecycleRoot,
    runCancellationProbe,
    runDestroyInterruptionProbe,
    runAdoptedInterruptionProbe,
    runRoutedLiveProbe,
    spawnDestroyInterruptionProbe,
    spawnAdoptedInterruptionProbe,
    runPublicProcess,
    runCrashReverseProcess,
    withFixtureEnvironment,
    withLocalGuestFrame,
    tests,
) where

import ConditionalCase (conditionalAction)
import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import qualified Control.Exception as Exception
import Control.Monad (when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (toUpper)
import Data.List (isInfixOf, sortOn)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import qualified Fixture
import Expect (expectRight)
import qualified HostBootstrap.Activation as Activation
import HostBootstrap.Authority (normalizeExecutableIdentity)
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Config.Class (AssemblyRequest (..), ConfigAssembly, ProjectCfg (cfgContext), pureConfigAssembly)
import HostBootstrap.Config.Schema (writeProjectConfigFile)
import HostBootstrap.Cluster.Lifecycle (ClusterDriver (KindDriver), ClusterProfile (Production), clusterKubeconfigPath, clusterName, clusterRuntimeStateDirectory, resolvePlan)
import qualified HostBootstrap.Cluster.Ownership as Owned
import HostBootstrap.Context (ContextKind (HostOrchestrator, VMOrchestrator, VMProjectContainer), currentFrame)
import HostBootstrap.Handoff (
    frameWire,
    providerDependencyProbeRequestFields,
    providerDependencyProbeResponseFromFields,
    takeHandoffFrame,
    withProviderDependencyReprobeKernel,
 )
import qualified HostBootstrap.Handoff as Handoff
import qualified HostBootstrap.Handoff.Protocol as Protocol
import qualified HostBootstrap.Handoff.Rooted as RootedWire
import HostBootstrap.Harness (Case (Case), CaseLifecycle (AssertOnce), CaseResult (Pass), LifecycleFailure (LifecycleFailure), SafetyRefusal (SafetyRefusal), TestSuite (TestSuite), mkCaseId)
import HostBootstrap.Digest (sha256Hex)
import HostBootstrap.HostConfig (buildHostConfig, resolveInstalled)
import HostBootstrap.HostTool (HostTool (Kind), absExePath)
import HostBootstrap.Identity.Install (provisionInstalledIdentity)
import HostBootstrap.Lifecycle.Execution (StepExecution, stepExecutionPlanDigest, stepExecutionSignActivationManifest)
import HostBootstrap.Lift.Context (
    ConfigDelivery (ConfigDelivery),
    ContainerLift (ContainerLift),
    ContainerPlacement (ProviderGuestContainer),
    IncusVM (IncusVM),
    LiftContext,
    emptyVMStack,
    inContainer,
    inVM,
    vmContext,
 )
import HostBootstrap.Ownership.Object (OwnershipFault (OwnershipUnsupported))
import HostBootstrap.Ownership.Posix (posixOwnershipRow, posixOwnershipSupported)
import HostBootstrap.Ownership.Primitive (OwnershipPrimitive (rowObserveIdentity), withOwnershipRow)
import HostBootstrap.Protected (Expectation (ExpectAbsent, ExpectVersion), ProtectedStore, RecordKey, compareAndDeleteProtectedRecord, compareAndSwapProtectedRecord, listProtectedRecords, mkRecordKey, openProtectedStore, protectedRecordBytes, protectedRecordVersion, readProtectedRecord, recordKeyText, recordNameIdentity, withProtectedEntry)
import qualified HostBootstrap.Reconcile as Reconcile
import HostBootstrap.Step (DelayedEffectGuarantee (NoDelayedEffect), RecoveryObservation (RecoveryEffectAbsent, RecoveryInconclusive), RecoveryObserver, mkRecoveryObserver, observesRecoveryWith)
import HostBootstrap.Step (
    ProjectStepId,
    ReversePolicy (ProjectManagedReverse),
    Step,
    StepFrame (StepFrame),
    StepObservation (StepChanged, StepConflict),
    StepPlan,
    TeardownOutcome (TeardownFailed, TeardownRefused, TeardownReleased),
    deployChartStep,
    deployKindStep,
    declaresServiceActivation,
    declaresEmptyChildFrame,
    descendsVia,
    mkStepPlan,
    postHandoffStep,
    projectStep,
    projectStepId,
    reversedBy,
 )
import HostBootstrap.Substrate (detect)
import PlatformPath (hostPathAsPosixDescriptor)
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesFileExist, renameFile)
#if defined(linux_HOST_OS)
import System.Directory (findExecutable)
#endif
import System.Environment (getArgs, getEnv, getEnvironment, getExecutablePath, lookupEnv, setEnv, withArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.FilePath (searchPathSeparator, takeFileName, (<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import System.IO (hGetContents, stdin, stdout)
import System.Process (CreateProcess (env, std_in, std_out), ProcessHandle, StdStream (CreatePipe), createProcess, proc, rawSystem, readCreateProcessWithExitCode, readProcessWithExitCode, terminateProcess, waitForProcess, withCreateProcess)
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)
#if !defined(mingw32_HOST_OS)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Process (exitImmediately, getProcessGroupIDOf, getProcessID)
import System.Posix.Signals (Handler (Catch, Ignore), installHandler, nullSignal, sigINT, sigTERM, sigUSR1, signalProcess, signalProcessGroup)
import System.Process (getPid)
#endif

tests :: TestTree
tests =
    testGroup
        "RecursiveLifecycleSpec (root/VM/container process-transport fixture)"
        [ testCase "public up crosses two real authenticated process boundaries" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    readFile (root </> "stdio-probe") >>= (@?= "stdout redirected; stdin EOF\n")
                    lines <$> readFile (root </> "forward-frames") >>= (@?= ["vm-orchestrator-1", "vm-project-container-2"])
                    executable <- fixtureExecutable root
                    let projectName = normalizeExecutableIdentity executable
                    store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack projectName)
                    rows <- expectRight =<< withProtectedEntry store (\entry -> do
                        keys <- expectRight =<< listProtectedRecords entry
                        records <- mapM (\key -> do
                            record <- expectRight =<< readProtectedRecord entry key
                            pure (recordKeyText key, record)) keys
                        pure (Right records))
                    mapM_ (\suffix -> assertBool ("missing committed child operation " <> Text.unpack suffix)
                        (any (\(key, record) -> "op." `Text.isPrefixOf` key && suffix `Text.isSuffixOf` key
                            && maybe False (ByteStringChar8.isInfixOf "Committed" . protectedRecordBytes) record) rows))
                        ["project.vm", "project.vm-extra", "project.container"]
                    let guestBinary = "/usr/local/bin/" <> Text.unpack (normalizeExecutableIdentity executable)
                    readCrossingEvents root
                        >>= ( @?= [ ( "incus"
                                    , ["exec", "fixture-vm", "--cwd", "/", "-T", "--", guestBinary, "--hostbootstrap-lifecycle-child"]
                                    )
                                  , ( "docker"
                                    , [ "run", "--rm", "-i", "--network=host"
                                      , "-e", "HOSTBOOTSTRAP_CURRENT_FRAME=vm-project-container-2"
                                      , "-e", "HOSTBOOTSTRAP_REGISTRY_AUTH", "-w", "/"
                                      , "fixture:image", "--hostbootstrap-lifecycle-child"
                                      ]
                                    )
                                  ]
                            )
        , testCase "an admitted empty container frame settles from the root and completes" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentNamed "hostbootstrap-recursive-empty-container" False False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    -- The container frame ran its own authenticated child, which executed no node.
                    lines <$> readFile (root </> "forward-frames") >>= (@?= ["vm-orchestrator-1"])
                    crossings <- readCrossingEvents root
                    map fst crossings @?= ["incus", "docker"]
                    executable <- fixtureExecutable root
                    rows <- fixtureAuthorityImage root executable
                    let completedReports =
                            [ report
                            | (key, Just (_, row)) <- rows
                            , "lifecycle-child." `Text.isPrefixOf` key
                            , Just report <- [durableLifecycleReport row]
                            , lifecycleReportTag report == Just "forward-completed"
                            ]
                    assertBool ("every frame, the empty one included, published a completed report: " <> show (length completedReports))
                        (length completedReports >= 2)
                    assertBool "the empty frame committed no operation"
                        (not (any (\(key, _) -> "op." `Text.isPrefixOf` key && "project.container" `Text.isSuffixOf` key) rows))
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
        , testCase "the coordinator replays an opening after the frame advances" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
              mapM_ (\mode -> withFixtureEnvironment False $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    result <- timeout (45 * 1000000) $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_REPLAY_OPEN", mode) : childEnvironment)} ""
                    case result of
                        Nothing -> assertFailure "the coordinator replay fixture timed out"
                        Just (status, output, diagnostic) ->
                            if mode == "1" then assertEqual (output <> diagnostic) ExitSuccess status
                                else assertBool (output <> diagnostic) (status /= ExitSuccess)
                    readFile (root </> "opening-replay") >>= (@?= (mode <> "\n"))) ["1", "nonce", "path", "foreign", "domain", "unsolicited", "descent-domain"]
        , testCase "the installed root signer admits only the child's declared activation" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
              mapM_ (\mode -> withFixtureEnvironmentNamed "hostbootstrap-recursive-activation" False False $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    result <- timeout (45 * 1000000) $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_ACTIVATION", mode) : childEnvironment)} ""
                    (status, output, diagnostic) <- maybe (assertFailure "the activation fixture timed out") pure result
                    if mode == "valid"
                        then do
                            assertEqual (output <> diagnostic) ExitSuccess status
                            manifest <- ByteStringChar8.readFile (root </> "activation-manifest")
                            signatureBytes <- ByteStringChar8.readFile (root </> "activation-signature")
                            publicBytes <- ByteStringChar8.readFile (executable <> ".activation.pub")
                            publicKey <- case Ed25519.publicKey publicBytes of
                                CryptoPassed value -> pure value
                                CryptoFailed failure -> assertFailure (show failure)
                            signature <- case Ed25519.signature signatureBytes of
                                CryptoPassed value -> pure value
                                CryptoFailed failure -> assertFailure (show failure)
                            assertBool "the installed activation key verifies the child's manifest"
                                (Ed25519.verify publicKey (frameWire "hostbootstrap/activation/v1" <> frameWire manifest) signature)
                        else do
                            assertEqual (output <> diagnostic) (ExitFailure 1) status
                            let expected = case mode of
                                    "frame" -> "activation: the manifest frame is absent from the admitted rooted plan catalog"
                                    "plan" -> "activation: the manifest plan digest differs from its admitted frame plan"
                                    _ -> "activation: the manifest service/effect placement is absent from the admitted root plan"
                            assertBool (output <> diagnostic) (expected `isInfixOf` (output <> diagnostic)))
                ["valid", "frame", "plan", "service", "effects"]
        , testCase "reverse-relay-refusal: config and activation over the child pipe" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                mapM_ (\mode -> withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    result <- timeout (60 * 1000000) $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "down"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_REVERSE_REFUSAL", mode) : childEnvironment)} ""
                    (status, output, diagnostic) <- maybe (assertFailure "the reverse relay refusal timed out") pure result
                    assertBool (output <> diagnostic) (status /= ExitSuccess)
                    let reason = if mode == "activation" then "the reverse coordinator carries no activation signer"
                            else "the reverse coordinator admits no config edge"
                    assertBool (output <> diagnostic) (("handoff relay: the plan names no such edge: " <> reason) `isInfixOf` (output <> diagnostic))
                    readFile (root </> "reverse-relay-injected") >>= (@?= (mode <> "\n"))
                    before <- readFile (root </> "reverse-relay-token-keys")
                    after <- fixtureAuthorityImage root executable
                    show (reverseRelayTokenKeys after) @?= before) ["config", "activation"]
        , testCase "public down unwinds the same two real process boundaries child-first" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    forwardCrossings <- readCrossingEvents root
                    runPublicProcess root False "down" >>= (@?= ExitSuccess)
                    assertRecordedChildOperations root "Released" ["project.vm", "project.vm-extra", "project.container"]
                    allCrossings <- readCrossingEvents root
                    take (length forwardCrossings) allCrossings @?= forwardCrossings
                    executable <- fixtureExecutable root
                    let targetBinary = "/usr/local/bin/" <> Text.unpack (normalizeExecutableIdentity executable)
                        vmArguments = ["exec", "fixture-vm", "--cwd", "/", "-T", "--", targetBinary, "--hostbootstrap-lifecycle-child"]
                        composedArguments =
                            [ "exec", "fixture-vm", "--cwd", "/", "-T", "--"
                            , "docker", "run", "--rm", "-i", "--network=host"
                            , "-e", "HOSTBOOTSTRAP_CURRENT_FRAME=vm-project-container-2"
                            , "-e", "HOSTBOOTSTRAP_REGISTRY_AUTH", "-w", "/"
                            , "fixture:image", "--hostbootstrap-lifecycle-child"
                            ]
                    -- These are the arguments the existing native proxies
                    -- actually received, not a second call to the route fold.
                    drop (length forwardCrossings) allCrossings
                        @?= [("incus", vmArguments), ("incus", composedArguments)]
                    Text.lines <$> TextIO.readFile (root </> "reverse-attempts")
                        >>= (@?= ["container", "vm-extra", "vm", "root"])
        , testCase "successful child processes finish their post-protocol work naturally" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    result <- timeout (30 * 1000000) $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_NATURAL_EXIT", "1") : childEnvironment)}
                            ""
                    case result of
                        Nothing -> assertFailure "the natural-exit fixture timed out"
                        Just (status, _, diagnostic) -> assertEqual diagnostic ExitSuccess status
                    lines <$> readFile (root </> "natural-exits") >>= (@?= ["child exited", "child exited"])
        , testCase "public destroy unwinds the same two real process boundaries child-first" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    assertRecordedChildOperations root "Released" ["project.vm", "project.vm-extra", "project.container"]
                    Text.lines <$> TextIO.readFile (root </> "reverse-attempts")
                        >>= (@?= ["container", "vm-extra", "vm", "root"])
        , testCase "public down then destroy preserves the recursive source across separate root processes" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "down" >>= (@?= ExitSuccess)
                    let first = ["container", "vm-extra", "vm", "root"]
                    Text.lines <$> TextIO.readFile (root </> "reverse-attempts") >>= (@?= first)
                    runPublicProcess root False "down" >>= (@?= ExitSuccess)
                    Text.lines <$> TextIO.readFile (root </> "reverse-attempts") >>= (@?= first)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    Text.lines <$> TextIO.readFile (root </> "reverse-attempts") >>= (@?= first <> first)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    Text.lines <$> TextIO.readFile (root </> "reverse-attempts") >>= (@?= first <> first)
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
        , testCase "failed up preserves its failure and admits exact reverse recovery" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment True $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root True False
                    (status, output, diagnostic) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"]){env = Just childEnvironment} ""
                    status @?= ExitFailure 1
                    assertBool (output <> diagnostic) (not ("is not an ordered subset of the admitted plan" `isInfixOf` diagnostic))
                    crossings <- readCrossingEvents root
                    attemptsExist <- doesFileExist (root </> "reverse-attempts")
                    attempts <- if attemptsExist then Text.lines <$> TextIO.readFile (root </> "reverse-attempts") else pure []
                    assertEqual ("crossings: " <> show crossings <> "; reverse attempts: " <> show attempts)
                        ["incus", "docker", "incus", "incus"] (map fst crossings)
                    attempts @?= ["vm-extra", "vm", "root"]
                    records <- fixtureAuthorityImage root executable
                    let reports =
                            [ (tag, report)
                            | (key, Just (_, row)) <- records
                            , "lifecycle-child." `Text.isPrefixOf` key
                            , Just report <- [durableLifecycleReport row]
                            , Just tag <- [lifecycleReportTag report]
                            ]
                        failedReports = [report | ("forward-failed", report) <- reports]
                        completedReports = [report | ("reverse-completed", report) <- reports]
                    assertBool "the failed Up published a canonical forward-failed report" (not (null failedReports))
                    assertBool "the unwind published a canonical reverse-completed report" (not (null completedReports))
                    assertBool "forward failure and reverse completion are distinct records"
                        (and [failed /= completed | failed <- failedReports, completed <- completedReports])
                    runPublicProcess root True "destroy" >>= (@?= ExitSuccess)
        , testCase "root failure report retains the failing root operation after child observations" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentNamed "hostbootstrap-recursive-root-failure" False False $ \root _ -> do
                    executable <- fixtureExecutable root
                    runPublicProcess root False "up" >>= (@?= ExitFailure 1)
                    records <- fixtureAuthorityImage root executable
                    let forwardRows =
                            [ bytes
                            | (key, Just (_, bytes)) <- records
                            , "lifecycle-child." `Text.isPrefixOf` key
                            , (frameWire "core:post-handoff-root-failure" <> frameWire "failed") `ByteStringChar8.isInfixOf` bytes
                            ]
                    case forwardRows of
                        [report] -> mapM_
                            (\operation -> assertBool ("missing successful child observation: " <> show operation)
                                ((frameWire operation <> frameWire "succeeded") `ByteStringChar8.isInfixOf` report))
                            ["project:vm", "project:vm-extra", "project:container"]
                        other -> assertFailure ("expected one root failure report, got " <> show (length other))
        , testCase "failed up reports both the child failure and failed unwind" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentFor True True $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root True True
                    finished <- timeout 30000000 $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"]){env = Just childEnvironment} ""
                    case finished of
                        Nothing -> assertFailure "failed-Up cleanup fixture did not exit"
                        Just (status, output, diagnostic) -> do
                            status @?= ExitFailure 1
                            assertBool (output <> diagnostic) ("fixture failure" `isInfixOf` diagnostic)
                            assertBool (output <> diagnostic) ("left unsettled work" `isInfixOf` diagnostic)
        , testCase "failed up refuses cleanup after its Execute reservation changes" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
              mapM_ (\mode ->
                withFixtureEnvironment True $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root True False
                    finished <- timeout 30000000 $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_REPLACE_RESERVATION", mode) : childEnvironment)} ""
                    details <- case finished of
                        Nothing -> assertFailure "reservation replacement fixture did not exit"
                        Just (status, output, diagnostic) -> do
                            status @?= ExitFailure 1
                            assertBool (output <> diagnostic) ("the exact command reservation is stale" `isInfixOf` (output <> diagnostic))
                            pure (output <> diagnostic)
                    attemptsExist <- doesFileExist (root </> "reverse-attempts")
                    attempts <- if attemptsExist then Text.lines <$> TextIO.readFile (root </> "reverse-attempts") else pure []
                    replaced <- doesFileExist (root </> "reservation-replaced")
                    assertBool ("reservation fixture did not replace the record: " <> details) replaced
                    reservationKey <- TextIO.readFile (root </> "reservation-replaced")
                    assertBool ("cleanup reached a child despite the replaced reservation: " <> show attempts <> "; " <> details) ("container" `notElem` attempts)
                    rows <- fixtureAuthorityImage root executable
                    case mode of
                        "replace" -> length [() | (key, Just (version, bytes)) <- rows, key == reservationKey, version == "RecordVersion 2", bytes == "foreign reservation"] @?= 1
                        "same-bytes" -> length [() | (key, Just (version, bytes)) <- rows, key == reservationKey, version == "RecordVersion 2", "2:up7:execute" `ByteStringChar8.isSuffixOf` bytes] @?= 1
                        "delete" -> lookup reservationKey rows @?= Nothing
                        _ -> assertFailure "unknown reservation mutation"
              ) ["replace", "same-bytes", "delete"]
        , testCase "a throwing forward child settles its failed operation" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
              mapM_ (\(crashMode, expected) ->
                withFixtureEnvironment False $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    finished <- timeout 30000000 $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH", crashMode) : childEnvironment)} ""
                    case finished of
                        Nothing -> assertFailure "throwing forward fixture did not exit"
                        Just (status, output, diagnostic) -> do
                            status @?= ExitFailure 1
                            assertBool (output <> diagnostic) (expected `isInfixOf` (output <> diagnostic))
                    let projectName = normalizeExecutableIdentity executable
                    store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack projectName)
                    rows <- expectRight =<< withProtectedEntry store (\entry -> do
                        keys <- expectRight =<< listProtectedRecords entry
                        records <- mapM (\key -> do
                            record <- expectRight =<< readProtectedRecord entry key
                            pure (recordKeyText key, record)) keys
                        pure (Right records))
                    assertBool "the throwing child has a settled operation"
                        (any (\(key, record) -> "op." `Text.isPrefixOf` key && "project.container" `Text.isSuffixOf` key
                            && maybe False (not . ByteStringChar8.isInfixOf "EffectOutcomeUnknown" . protectedRecordBytes) record) rows)
                    assertBool "the container child published and received its failed terminal report"
                        (any (\(key, record) -> "lifecycle-child." `Text.isPrefixOf` key
                            && maybe False (\bytes -> ByteStringChar8.isInfixOf (frameWire "project:container" <> frameWire "failed") bytes
                                && ByteStringChar8.isInfixOf (frameWire "received") bytes
                                && ByteStringChar8.isInfixOf (ByteStringChar8.pack expected) bytes) (protectedRecordBytes <$> record)) rows))
                [("1", "fixture interrupted after preparation"), ("refusal", "refused: fixture safety refusal")]
        , testCase "cancelling the root owner rethrows and reaps its active child" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    result <- timeout (45 * 1000000) $
                        readCreateProcessWithExitCode
                            (proc executable ["--hostbootstrap-recursive-cancellation-probe"])
                                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_BLOCK", "1") : childEnvironment)}
                            ""
                    case result of
                        Nothing -> assertFailure "the cancellation fixture timed out"
                        Just (status, _, diagnostic) -> assertEqual diagnostic ExitSuccess status
        , testCase "a child that dies mid-exchange fails the root and leaves no process" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> crashedChildFixture root
        , testCase "an interrupted root aborts and reaps its children" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> interruptedRootFixture root
        , testCase "a routed managed reverse action records its foreign outcome" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentNamed "hostbootstrap-recursive-managed" False False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    assertRecordedChildOperations root "ObservedForeign" ["core.deploy-chart"]
        , testCase "a routed release settles its exact resource before acknowledgement" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    (store, key, previous) <- seedChildResource root "project.container" "project:container"
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    saved <- expectRight =<< withProtectedEntry store (\entry -> readProtectedRecord entry key)
                    fmap protectedRecordBytes saved @?= Just (ByteStringChar8.take (ByteStringChar8.length previous - 13) previous <> frameWire "released")
                    attempts <- Text.lines <$> TextIO.readFile (root </> "reverse-attempts")
                    assertBool "the child executed its release" ("container" `elem` attempts)
                    assertRecordedChildOperations root "Released" ["project.container"]
        , testCase "a routed foreign observation retains its resource evidence" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentNamed "hostbootstrap-recursive-managed" False False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    (store, key, previous) <- seedChildResource root "core.deploy-chart" "core:deploy-chart"
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    saved <- expectRight =<< withProtectedEntry store (\entry -> readProtectedRecord entry key)
                    fmap protectedRecordBytes saved @?= Just previous
                    assertRecordedChildOperations root "ObservedForeign" ["core.deploy-chart"]
        , testCase "a released prerequisite refuses the next grant and failed-Up cleanup refuses the foreign release" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentNamed "hostbootstrap-recursive-managed-kind-stale" False False $ \root _ -> do
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    finished <- timeout 60000000 $
                        readCreateProcessWithExitCode (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"]){env = Just childEnvironment} ""
                    (status, output, diagnostic) <- maybe (assertFailure "stale prerequisite fixture did not exit") pure finished
                    released <- doesFileExist (root </> "cluster-released")
                    attemptsExist <- doesFileExist (root </> "reverse-attempts")
                    attempts <- if attemptsExist then Text.lines <$> TextIO.readFile (root </> "reverse-attempts") else pure []
                    let details = show status <> "; attempts " <> show attempts <> "\n" <> output <> diagnostic
                    status @?= ExitFailure 1
                    assertBool ("the fixture did not release the cluster record: " <> details) released
                    assertBool ("the released prerequisite was not refused at the root: " <> details)
                        ("rooted probe prerequisite: resource is released" `isInfixOf` diagnostic)
                    assertBool ("the chart effect ran despite the refusal: " <> details) ("chart" `notElem` attempts)
                    -- The refusal fails the frame in protocol order, so failed-Up cleanup opens
                    -- rather than meeting the forward session still open.
                    assertBool ("failed-Up cleanup did not run: " <> details) ("failed-Up cleanup" `isInfixOf` diagnostic)
                    assertBool ("the refused frame left its session open: " <> details) (not ("is still open" `isInfixOf` diagnostic))
                    -- Cleanup must not release what an outside writer released; it refuses
                    -- before reversing anything and leaves that record exactly as written.
                    assertBool ("cleanup released a foreign-released cluster: " <> details) ("release predecessor is not owned" `isInfixOf` diagnostic)
                    attempts @?= []
                    keyText <- TextIO.readFile (root </> "cluster-released")
                    rows <- fixtureAuthorityImage root executable
                    case lookup keyText rows of
                        Just (Just (_, bytes)) -> assertBool "the released cluster record changed" (frameWire "released" `ByteStringChar8.isInfixOf` bytes)
                        other -> assertFailure ("the released cluster record disappeared: " <> show (fmap (fmap fst) other))
        , testCase "a routed cluster cleanup releases its root lease after backend refusal" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentNamed "hostbootstrap-recursive-managed-kind" False False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    (_, _, _, child) <- createProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                        {env = Just childEnvironment}
                    finished <- timeout 30000000 (waitForProcess child)
                    case finished of
                        Nothing -> do
                            terminateProcess child
                            _ <- waitForProcess child
                            assertFailure "routed cluster cleanup did not release its root lease"
                        Just status -> assertBool "the missing cluster record refused cleanup" (status /= ExitSuccess)
                    assertRecordedChildOperations root "StepObservedTerminal" ["core.deploy-kind"]
        , testCase "an interrupted reverse child leaves its operation unknown" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    (_, _, _, child) <- createProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                        {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH_REVERSE", "1") : childEnvironment)}
                    finished <- timeout 30000000 (waitForProcess child)
                    case finished of
                        Nothing -> do
                            terminateProcess child
                            _ <- waitForProcess child
                            assertFailure "interrupted reverse fixture did not exit"
                        Just status -> assertBool "interrupted reverse run failed" (status /= ExitSuccess)
                    assertRecordedChildOperations root "EffectOutcomeUnknown" ["project.container"]
        , testCase "an interrupted root reverse refuses to repeat its unknown effect" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    (first, _, _) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                            {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH_ROOT", "1") : childEnvironment)}
                        ""
                    assertBool "the root exited during its effect" (first /= ExitSuccess)
                    assertRecordedChildOperations root "EffectOutcomeUnknown" ["project.root"]
                    before <- fixtureAuthorityImage root executable
                    (second, _, stderrText) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                            {env = Just childEnvironment}
                        ""
                    assertBool ("recovery refuses the unknown root effect: " <> show second <> " " <> take 1200 stderrText)
                        (second /= ExitSuccess && "EffectOutcomeUnknown" `isInfixOf` stderrText)
                    fixtureAuthorityImage root executable >>= (@?= before)
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    length (filter (== "root") attempts) @?= 1
                    assertRecordedChildOperations root "EffectOutcomeUnknown" ["project.root"]
        , testGroup "root-settlement-interruption"
          [ testCase "an interrupted settled root reverse resumes without repeating its release" $
#if defined(linux_HOST_OS)
            conditionalAction ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)", "root-settlement-interruption"] posixOwnershipSupported
              (
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    interceptor <- compileRootCloseInterceptor root
                    let instrumented = ("LD_PRELOAD", interceptor) : filter ((/= "LD_PRELOAD") . fst) childEnvironment
                    (first, _, diagnostic) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"]){env = Just instrumented} ""
                    assertBool ("the root stopped before its session closed: " <> diagnostic) (first /= ExitSuccess)
                    assertRecordedChildOperations root "Released" ["project.root"]
                    image <- fixtureAuthorityImage root executable
                    assertBool "the released root operation still belongs to an open session"
                        (any (\(key, row) -> "session." `Text.isPrefixOf` key
                            && maybe False (\(_, bytes) -> "\nopen\t" `ByteStringChar8.isInfixOf` bytes
                                && "project:root" `ByteStringChar8.isInfixOf` bytes) row) image)
                    (second, _, retryDiagnostic) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"]){env = Just childEnvironment} ""
                    assertBool ("settled root reverse resumes: " <> retryDiagnostic) (second == ExitSuccess)
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    length (filter (== "root") attempts) @?= 1
              )
              (assertBool "the native POSIX ownership row is unavailable" (not posixOwnershipSupported))
#else
            conditionalAction ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)", "root-settlement-interruption"] False
              (assertFailure "the Linux publication interceptor is unavailable")
              (assertBool "the Linux publication interceptor is unavailable" (os /= "linux"))
#endif
          ]
        , testCase "a failed reverse operation is settled once and terminates the child" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironmentFor False True $ \root _ -> do
                    runPublicProcessFor root False True "up" >>= (@?= ExitSuccess)
                    runPublicProcessFor root False True "destroy" >>= (@?= ExitFailure 1)
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    attempts @?= ["container"]
                    assertRecordedChildOperations root "StepObservedTerminal" ["project.container"]
        , testCase "a throwing child reverse settles as failed and closes the frame" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    (status, _, stderrText) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                            {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_THROW_REVERSE", "1") : childEnvironment)}
                        ""
                    status @?= ExitFailure 1
                    assertBool "the unsettled detail contains the callback exception" ("fixture reverse exception" `isInfixOf` stderrText)
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    length (filter (== "container") attempts) @?= 1
                    assertRecordedChildOperations root "StepObservedTerminal" ["project.container"]
                    before <- filter (Text.isPrefixOf "rooted-node-settlement." . fst) <$> fixtureAuthorityImage root executable
                    assertBool "the failed attempt has durable settlements" (not (null before))
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    after <- fixtureAuthorityImage root executable
                    mapM_ (\(key, value) -> lookup key after @?= Just value) before
        , testCase "an empty child reverse refusal settles with a usable detail" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    (status, _, _) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                            {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EMPTY_REFUSAL", "1") : childEnvironment)}
                        ""
                    status @?= ExitSuccess
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    length (filter (== "container") attempts) @?= 1
                    assertRecordedChildOperations root "StepObservedTerminal" ["project.container"]
                    image <- fixtureAuthorityImage root executable
                    assertBool "the durable refusal carries a nonempty detail" $
                        any (maybe False (ByteStringChar8.isInfixOf "no detail given" . snd) . snd) image
        , testCase "an oversized child reverse detail settles at a UTF-8 boundary" $
            withLocalGuestFrame ["RecursiveLifecycleSpec (root/VM/container process-transport fixture)"] $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    executable <- fixtureExecutable root
                    childEnvironment <- recursiveFixtureEnvironment root False False
                    (status, _, stderrText) <- readCreateProcessWithExitCode
                        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
                            {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_LARGE_DETAIL", "1") : childEnvironment)}
                        ""
                    status @?= ExitFailure 1
                    let (_, oversized) = Text.breakOn "oversized" (Text.pack stderrText)
                    assertBool ("the observation exceeds a later bound: " <> Text.unpack (Text.take 240 oversized)) (Text.null oversized)
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    length (filter (== "container") attempts) @?= 1
                    assertRecordedChildOperations root "StepObservedTerminal" ["project.container"]
        , testCase "the local provider reprobe kernel returns only nonce-bound observation data" $ do
            let package = ByteStringChar8.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
            request <- either (assertFailure . Text.unpack) pure (providerDependencyProbeRequestFields package "recursive-nonce")
            withProviderDependencyReprobeKernel
                package
                "plan"
                "scope"
                "resource"
                "frame"
                "origin"
                7
                "journal"
                "receipt"
                "runtime://provider/reprobe"
                99
                (pure (Right 7))
                $ \answer -> do
                    response <- answer request >>= either (assertFailure . Text.unpack) pure
                    providerDependencyProbeResponseFromFields package "recursive-nonce" response @?= Right (Right 7)
                    case providerDependencyProbeResponseFromFields package "different-nonce" response of
                        Left _ -> pure ()
                        Right value -> assertFailure ("response accepted under a different nonce: " <> show value)
        , testCase "a replayed provider nonce refuses before another live observation" $ do
            calls <- newIORef (0 :: Int)
            let package = ByteStringChar8.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
            request <- either (assertFailure . Text.unpack) pure (providerDependencyProbeRequestFields package "one-use-nonce")
            withProviderDependencyReprobeKernel
                package
                "plan"
                "scope"
                "resource"
                "frame"
                "origin"
                7
                "journal"
                "receipt"
                "runtime://provider/reprobe"
                99
                (modifyIORef' calls (+ 1) >> pure (Right 7))
                $ \answer -> do
                    first <- answer request >>= either (assertFailure . Text.unpack) pure
                    providerDependencyProbeResponseFromFields package "one-use-nonce" first @?= Right (Right 7)
                    second <- answer request >>= either (assertFailure . Text.unpack) pure
                    providerDependencyProbeResponseFromFields package "one-use-nonce" second
                        @?= Right (Left "provider dependency probe nonce was replayed")
                    readIORef calls >>= (@?= 1)
        ]

-- | The actual test executable is also the installed child binary.
runLifecycleChild :: IO ()
runLifecycleChild = do
    project <- normalizeExecutableIdentity <$> getExecutablePath
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    installFixtureCrashHandler root
    failContainer <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL"
    failCleanup <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL"
    withArgs ["--hostbootstrap-lifecycle-child"] $
        CLI.runHostBootstrapCLI (Text.unpack project) (fixtureSpec root failContainer failCleanup)
    naturalExit <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_NATURAL_EXIT"
    when (naturalExit == Just "1") $ do
        threadDelay 300000
        appendFile (root </> "natural-exits") "child exited\n"

{- | The same installed binary entered as a frame child: a shipped frame
transaction (such as a recovery observation) reaches the fixture project's own
interpreter, exactly as a project binary dispatches it.
-}
runLifecycleFrameChild :: IO ()
runLifecycleFrameChild = do
    project <- normalizeExecutableIdentity <$> getExecutablePath
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    failContainer <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL"
    failCleanup <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL"
    withArgs ["--hostbootstrap-frame-child"] $
        CLI.runHostBootstrapCLI (Text.unpack project) (fixtureSpec root failContainer failCleanup)

{- | Re-enter the public command in a process whose host-tool discovery sees
only the fixture's explicit environment, leaving the suite process alone.
-}
runLifecycleRoot :: String -> IO ()
runLifecycleRoot verb = do
    project <- normalizeExecutableIdentity <$> getExecutablePath
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    failContainer <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL"
    failCleanup <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL"
    withArgs ["project", verb] $
        CLI.runHostBootstrapCLI (Text.unpack project) (fixtureSpec root failContainer failCleanup)

runCancellationProbe :: IO ()
runCancellationProbe = do
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    completed <- newEmptyMVar
    worker <- forkIO $ do
        result <- Exception.try (runLifecycleRoot "up") :: IO (Either Exception.SomeException ())
        putMVar completed result
    let marker = root </> "cancellation-child.pid"
        waitMarker = do
            present <- doesFileExist marker
            bytes <- if present then ByteStringChar8.readFile marker else pure ByteStringChar8.empty
            case if ByteStringChar8.null bytes || ByteStringChar8.last bytes /= '\n'
                    then Nothing else readMaybe (ByteStringChar8.unpack bytes) of
                Just identity -> pure identity
                Nothing -> threadDelay 25000 >> waitMarker
    ready <- timeout (20 * 1000000) waitMarker
    identity <- case ready of
        Nothing -> killThread worker >> assertFailure "the lifecycle child never entered its controlled wait"
        Just identity -> pure identity
    killThread worker
    result <- timeout (20 * 1000000) (takeMVar completed)
    case result of
        Just (Left failure) -> (Exception.fromException failure :: Maybe Exception.AsyncException) @?= Just Exception.ThreadKilled
        Just (Right ()) -> assertFailure "the cancelled lifecycle command returned normally"
        Nothing -> assertFailure "the lifecycle cancellation did not finish cleanup"
    gone <- timeout (5 * 1000000) (awaitFixtureProcessGone identity)
    gone @?= Just ()

installFixtureCrashHandler :: FilePath -> IO ()
#if defined(mingw32_HOST_OS)
installFixtureCrashHandler _ = pure ()
#else
installFixtureCrashHandler root = do
    enabled <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_CRASH_CHILD"
    when (enabled == Just "1") $ do
        _ <- installHandler sigUSR1 (Catch (exitImmediately (ExitFailure 9))) Nothing
        identity <- currentFixtureProcessId
        writeFile (root </> "child-pid") (show identity <> "\n")
#endif

crashedChildFixture :: FilePath -> IO ()
crashedChildFixture root = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root False False
    result <- timeout (45 * 1000000) $
        readCreateProcessWithExitCode
            (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
                {env = Just (("HOSTBOOTSTRAP_RECURSIVE_CRASH_AFTER_SETTLE", "1") : childEnvironment)} ""
    case result of
        Nothing -> assertFailure "child crash did not fail the root within the bound"
        Just (status, _, diagnostic) -> assertEqual diagnostic (ExitFailure 1) status
    marker <- readFile (root </> "child-pid")
    identity <- maybe (assertFailure "child pid is malformed") pure (readMaybe marker)
    gone <- timeout (5 * 1000000) (awaitFixtureProcessGone identity)
    gone @?= Just ()
    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)

interruptedRootFixture :: FilePath -> IO ()
#if defined(mingw32_HOST_OS)
interruptedRootFixture _ = ioError (userError "POSIX root interruption is unavailable on Windows")
#else
interruptedRootFixture root = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root False False
    withCreateProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"])
        {env = Just (("HOSTBOOTSTRAP_RECURSIVE_BLOCK_CONTAINER", "1") : childEnvironment)} $
        \_ _ _ rootProcess -> do
            let marker = root </> "interrupt-container.pid"
                waitMarker = do
                    present <- doesFileExist marker
                    bytes <- if present then ByteStringChar8.readFile marker else pure ByteStringChar8.empty
                    case if ByteStringChar8.null bytes || ByteStringChar8.last bytes /= '\n'
                            then Nothing else readMaybe (ByteStringChar8.unpack bytes) of
                        Just identity -> pure identity
                        Nothing -> threadDelay 25000 >> waitMarker
            identity <- timeout (20 * 1000000) waitMarker >>= maybe (assertFailure "container never entered its controlled wait") pure
            rootPid <- getPid rootProcess >>= maybe (assertFailure "root process exited before interruption") pure
            signalProcess sigINT rootPid
            status <- timeout (20 * 1000000) (waitForProcess rootProcess)
            case status of
                Just (ExitFailure _) -> pure ()
                Just ExitSuccess -> assertFailure "interrupted root exited successfully"
                Nothing -> terminateProcess rootProcess >> assertFailure "interrupted root did not exit"
            gone <- timeout (5 * 1000000) (awaitFixtureProcessGone identity)
            when (gone == Nothing) $ do
                _ <- Exception.try (getProcessGroupIDOf (fromIntegral identity) >>= signalProcessGroup sigTERM)
                    :: IO (Either Exception.IOException ())
                pure ()
            gone @?= Just ()
            doesFileExist (root </> "reverse-attempts") >>= (@?= False)
    before <- fixtureAuthorityImage root executable
    (status, _, diagnostic) <- readCreateProcessWithExitCode
        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
            {env = Just childEnvironment} ""
    status @?= ExitFailure 1
    assertBool "destroy refuses the interrupted unknown effect" ("EffectOutcomeUnknown" `isInfixOf` diagnostic)
    after <- fixtureAuthorityImage root executable
    let operationRows = filter (Text.isPrefixOf "op." . fst)
        childSessions =
            [ key
            | (key, Just (_, bytes)) <- before
            , "session." `Text.isPrefixOf` key
            , any (`ByteStringChar8.isInfixOf` bytes) ["project:vm", "project:container"]
            ]
        childFence key = "fence." <> fst (Text.breakOn "..." (Text.drop 8 key))
    operationRows after @?= operationRows before
    assertBool "the interrupted VM and container sessions were recorded" (length childSessions >= 2)
    mapM_ (\key -> do
        let fence = childFence key
        assertBool ("missing child fence " <> Text.unpack fence) (lookup fence before /= Nothing)
        lookup fence after @?= lookup fence before) childSessions
    doesFileExist (root </> "reverse-attempts") >>= (@?= False)
    -- Once the container's own observer verifies the effect absent, the root
    -- records that absence over the exact row and the requested Destroy completes.
    (observedStatus, _, observedDiagnostic) <- readCreateProcessWithExitCode
        (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
            {env = Just (("HOSTBOOTSTRAP_RECURSIVE_OBSERVE_ABSENT", "1") : childEnvironment)} ""
    assertEqual ("destroy after the verified absence; diagnostic: " <> observedDiagnostic) ExitSuccess observedStatus
    settled <- fixtureAuthorityImage root executable
    -- The container's observation crossed its composed route from the root: through
    -- the VM's incus layer with the container's docker layer nested inside it, never
    -- along the container's single edge from the root.
    crossingLines <- lines <$> readFile (root </> "crossings")
    let crossings = [crossing | Just crossing <- map readMaybe crossingLines] :: [(String, [String])]
    let frameChild (_, arguments) = "--hostbootstrap-frame-child" `elem` arguments
        observations = filter frameChild crossings
    assertBool ("the container observation crossed the VM then the container: " <> show observations)
        (any (\(tool, arguments) -> tool == "incus" && "docker" `elem` arguments) observations)
    assertBool ("a frame child was reached along a bare container edge: " <> show observations)
        (not (any ((== "docker") . fst) observations))
    assertBool "no operation remains outcome-unknown"
        (not (any (\(_, record) -> maybe False (ByteStringChar8.isInfixOf "OutcomeUnknown" . snd) record) (operationRows settled)))
#endif

awaitFixtureProcessGone :: Int -> IO ()
#if defined(mingw32_HOST_OS)
awaitFixtureProcessGone _ = ioError (userError "POSIX cancellation observation is unavailable on Windows")
#else
awaitFixtureProcessGone identity = do
    observed <- Exception.try (signalProcess nullSignal (fromIntegral identity)) :: IO (Either Exception.IOException ())
    case observed of
        Left failure | isDoesNotExistError failure -> pure ()
        Left failure -> Exception.throwIO failure
        Right () -> threadDelay 25000 >> awaitFixtureProcessGone identity
#endif

-- | Opt-in live confirmation: the recursive child releases a real cluster
-- whose origin and container identity were established by the ownership row.
runRoutedLiveProbe :: IO ()
runRoutedLiveProbe =
    withFixtureEnvironmentNamed "hostbootstrap-recursive-managed-kind-live" False False $ \root _ -> do
        lookupEnv "HOSTBOOTSTRAP_RECURSIVE_REAL_DOCKER" >>= (@?= Just "1")
        executable <- fixtureExecutable root
        let project = Text.unpack (normalizeExecutableIdentity executable)
            plan = resolvePlan project (root </> "container") Production
            name = clusterName plan
            config = ByteStringChar8.pack "kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n- role: control-plane\n  image: kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5\n"
            owned = Owned.OwnedCluster name (name <> "-control-plane") [] (Just (config, sha256Hex config)) (clusterKubeconfigPath plan) "routed-live-fixture"
        substrate <- either assertFailure pure =<< detect
        host <- buildHostConfig substrate
        kind <- maybe (assertFailure "kind is not installed") pure =<< resolveInstalled host Kind
        (listStatus, clusters, _) <- readProcessWithExitCode (absExePath kind) ["get", "clusters"] ""
        listStatus @?= ExitSuccess
        assertBool "the live fixture cluster name must be absent" (name `notElem` lines clusters)
        store <- expectRight =<< openProtectedStore (clusterRuntimeStateDirectory plan)
        key <- either (assertFailure . show) pure (Owned.ownedClusterRecordKey owned)
        let cleanup = do
                outcome <- withProtectedEntry store $ \entry -> Right <$> Owned.releaseRetainedOwnedCluster host entry key owned
                either (assertFailure . show) (either (assertFailure . show) (const (pure ()))) outcome
        (do
            runPublicProcess root False "up" >>= (@?= ExitSuccess)
            created <- withProtectedEntry store $ \entry -> Right <$> Owned.reconcileOwnedCluster KindDriver host entry key owned
            assertBool ("the fixture created and bound its cluster: " <> show created)
                (case created of Right (Right (Owned.ClusterCreated _)) -> True; _ -> False)
            runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
            assertRecordedChildOperations root "Released" ["core.deploy-kind"]
            fenceKey <- either (assertFailure . show) pure (mkRecordKey "routed-cluster-cleanup-fence")
            rows <- expectRight =<< withProtectedEntry store (\entry -> do
                fence <- readProtectedRecord entry fenceKey
                cluster <- readProtectedRecord entry key
                pure ((,) <$> fence <*> cluster))
            assertBool "the routed cleanup recorded its fence and retired the cluster origin"
                (case rows of (Just _, Nothing) -> True; _ -> False)
            (afterStatus, afterClusters, _) <- readProcessWithExitCode (absExePath kind) ["get", "clusters"] ""
            afterStatus @?= ExitSuccess
            assertBool "the routed cleanup removed its cluster" (name `notElem` lines afterClusters)
            putStrLn "routed live cleanup released its owned Kind cluster"
            ) `Exception.finally` cleanup

runDestroyInterruptionProbe :: FilePath -> IO ()
runDestroyInterruptionProbe readyPath = do
    runLifecycleRoot "destroy"
    let pendingPath = readyPath ++ ".pending"
    writeFile pendingPath "destroy-settled"
    renameFile pendingPath readyPath
    threadDelay 600000000

runAdoptedInterruptionProbe :: FilePath -> IO ()
runAdoptedInterruptionProbe readyPath = do
    setEnv "HOSTBOOTSTRAP_RECURSIVE_PAUSE_ADOPTED" readyPath
    runLifecycleRoot "destroy"
    assertFailure "destroy returned before the adopted interruption"

spawnDestroyInterruptionProbe :: FilePath -> FilePath -> IO ProcessHandle
spawnDestroyInterruptionProbe root readyPath = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root False False
    (_, _, _, child) <-
        createProcess
            (proc executable ["--hostbootstrap-destroy-interruption-probe", readyPath])
                { env = Just childEnvironment
                }
    pure child

spawnAdoptedInterruptionProbe :: FilePath -> FilePath -> IO ProcessHandle
spawnAdoptedInterruptionProbe root readyPath = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root False False
    (_, _, _, child) <-
        createProcess
            (proc executable ["--hostbootstrap-adopted-interruption-probe", readyPath])
                { env = Just childEnvironment
                }
    pure child

withFixtureEnvironment :: Bool -> (FilePath -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> IO result) -> IO result
withFixtureEnvironment failContainer = withFixtureEnvironmentFor failContainer False

withFixtureEnvironmentFor :: Bool -> Bool -> (FilePath -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> IO result) -> IO result
withFixtureEnvironmentFor = withFixtureEnvironmentNamed "hostbootstrap-recursive"

withFixtureEnvironmentNamed :: String -> Bool -> Bool -> (FilePath -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> IO result) -> IO result
withFixtureEnvironmentNamed prefix failContainer failCleanup use = do
    source <- getExecutablePath
    -- Keep the installed fixture and its project root together, outside the
    -- deeply nested Cabal output path and within every child's native anchor.
    withSystemTempDirectory prefix $ \root -> do
        executable <- fixtureExecutable root
        copyFile source executable
        provisionInstalledIdentity executable >>= either assertFailure pure
        let project = normalizeExecutableIdentity executable
            configPath = root </> Text.unpack project <.> "dhall"
        fixtureTools <- prepareRecursiveFixtureTools root
        createDirectory (root </> "vm")
        createDirectory (root </> "container")
        writeProjectConfigFile Fixture.projectConfigCodec configPath (Fixture.defaultProjectConfig project (Text.pack root) HostOrchestrator)
        let suffix = if os == "mingw32" then ".exe" else ""
        mapM_ (\tool -> doesFileExist (fixtureTools </> (tool <> suffix)) >>= assertBool ("missing fixture tool " <> tool)) ["incus", "docker"]
        use root (fixtureSpec root failContainer failCleanup)

fixtureExecutable :: FilePath -> IO FilePath
fixtureExecutable root = (root </>) . takeFileName <$> getExecutablePath

#if defined(linux_HOST_OS)
-- Kill the real fixture at the publication boundary after root settlement but
-- before its session-close rename. This is a temporary test-only shared object;
-- it does not add a failpoint or an environment switch to production code.
compileRootCloseInterceptor :: FilePath -> IO FilePath
compileRootCloseInterceptor root = do
    let source = root </> "root-close-interceptor.c"
        library = root </> "root-close-interceptor.so"
    writeFile source $ unlines
        [ "#define _GNU_SOURCE"
        , "#include <dlfcn.h>"
        , "#include <fcntl.h>"
        , "#include <signal.h>"
        , "#include <string.h>"
        , "#include <unistd.h>"
        , "int rename(const char *source, const char *target) {"
        , "  static int (*real_rename)(const char *, const char *);"
        , "  if (!real_rename) real_rename = dlsym(RTLD_NEXT, \"rename\");"
        , "  if (strstr(target, \"/session.\")) {"
        , "    char bytes[16384]; int fd = open(source, O_RDONLY);"
        , "    if (fd >= 0) {"
        , "      ssize_t size = read(fd, bytes, sizeof(bytes) - 1); close(fd);"
        , "      if (size > 0) { bytes[size] = 0;"
        , "        if (strstr(bytes, \"\\nclosed\\t\") && strstr(bytes, \"project:root\")) {"
        , "          kill(getpid(), SIGKILL); _exit(99);"
        , "        }"
        , "      }"
        , "    }"
        , "  }"
        , "  return real_rename(source, target);"
        , "}"
        ]
    compiler <- findExecutable "gcc" >>= maybe (assertFailure "the C compiler is unavailable") pure
    (status, _, diagnostic) <- readProcessWithExitCode compiler ["-shared", "-fPIC", "-O2", "-o", library, source, "-ldl"] ""
    assertBool ("could not compile the root interruption fixture: " <> diagnostic) (status == ExitSuccess)
    pure library
#endif

runPublicProcess :: FilePath -> Bool -> String -> IO ExitCode
runPublicProcess root failContainer = runPublicProcessFor root failContainer False

crashReverseFixture :: IO ()
#if defined(mingw32_HOST_OS)
crashReverseFixture = ioError (userError "fixture interrupted during reverse")
#else
crashReverseFixture = exitImmediately (ExitFailure 91)
#endif

runCrashReverseProcess :: FilePath -> IO ExitCode
runCrashReverseProcess root = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root False False
    (_, _, _, child) <- createProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", "destroy"])
        {env = Just (("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH_REVERSE", "1") : childEnvironment)}
    waitForProcess child

runPublicProcessFor :: FilePath -> Bool -> Bool -> String -> IO ExitCode
runPublicProcessFor root failContainer failCleanup verb = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root failContainer failCleanup
    (_, _, _, child) <- createProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", verb]){env = Just childEnvironment}
    waitForProcess child

recursiveFixtureEnvironment :: FilePath -> Bool -> Bool -> IO [(String, String)]
recursiveFixtureEnvironment root failContainer failCleanup = do
    executable <- fixtureExecutable root
    inherited <- getEnvironment
    fixtureTools <- prepareRecursiveFixtureTools root
    let
        inheritedPath = maybe "" id (lookup "PATH" [(map toUpper name, value) | (name, value) <- inherited])
        overridden =
            [ ("PATH", fixtureTools <> [searchPathSeparator] <> inheritedPath)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE", executable)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT", root)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL", if failContainer then "1" else "0")
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL", if failCleanup then "1" else "0")
            ]
        names = map (map toUpper . fst) overridden
    pure (overridden <> filter ((`notElem` names) . map toUpper . fst) inherited)

prepareRecursiveFixtureTools :: FilePath -> IO FilePath
prepareRecursiveFixtureTools root = do
    let tools = root </> "fixture-tools"
        suffix = if os == "mingw32" then ".exe" else ""
    createDirectoryIfMissing True tools
    executable <- getExecutablePath
    mapM_
        ( \tool -> do
            let path = tools </> (tool <> suffix)
            present <- doesFileExist path
            if present then pure () else copyFile executable path
        )
        ["incus", "docker"]
    pure tools

{- | A native client proxy keeps the installed binary's identity and inherited
protocol pipes intact. It exercises transport, not a live provider substrate.
-}
runLifecycleFixtureClient :: IO ()
runLifecycleFixtureClient = do
    executable <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE"
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    tool <- takeFileName <$> getExecutablePath
    arguments <- getArgs
    liveDocker <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_REAL_DOCKER"
    replayOpen <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_REPLAY_OPEN"
    reverseRefusal <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_REVERSE_REFUSAL"
    pauseAdopted <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_PAUSE_ADOPTED"
    crashAfterSettle <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_CRASH_AFTER_SETTLE"
    if tool == "docker" && liveDocker == Just "1" && "--hostbootstrap-lifecycle-child" `notElem` arguments
        then rawSystem "/usr/bin/docker" arguments >>= exitWith
        else do
            appendFile (root </> "crossings") (show (tool, arguments) <> "\n")
            case (tool, replayOpen) of
                ("docker", _) | crashAfterSettle == Just "1" -> crashAfterSettleProxy root executable >>= exitWith
                ("incus", Just mode) | mode `elem` ["1", "nonce", "path", "foreign", "domain", "unsolicited", "descent-domain"] -> replayOpeningProxy root executable mode >>= exitWith
                ("incus", _) | Just mode <- reverseRefusal, mode `elem` ["config", "activation"] -> reverseRefusalProxy root executable mode >>= exitWith
                ("incus", _) | "docker" `elem` arguments, Just readyPath <- pauseAdopted -> adoptedInterruptionProxy root executable readyPath >>= exitWith
                _ | "--hostbootstrap-frame-child" `elem` arguments ->
                    rawSystem executable ["--hostbootstrap-recursive-frame-child"] >>= exitWith
                _ -> rawSystem executable ["--hostbootstrap-recursive-lifecycle-child"] >>= exitWith

-- Relay the actual container protocol until the first settlement response, then
-- ask the fixture child to exit from its own signal handler with status 9.
crashAfterSettleProxy :: FilePath -> FilePath -> IO ExitCode
#if defined(mingw32_HOST_OS)
crashAfterSettleProxy _ _ = ioError (userError "POSIX child crash is unavailable on Windows")
#else
crashAfterSettleProxy _ executable = do
    inherited <- getEnvironment
    withCreateProcess (proc executable ["--hostbootstrap-recursive-lifecycle-child"])
        {env = Just (("HOSTBOOTSTRAP_RECURSIVE_CRASH_CHILD", "1") : inherited), std_in = CreatePipe, std_out = CreatePipe} $
        \maybeInput maybeOutput _ child -> do
            childInput <- maybe (assertFailure "crash child stdin is absent") pure maybeInput
            childOutput <- maybe (assertFailure "crash child stdout is absent") pure maybeOutput
            parent <- Protocol.handoffChannel stdin stdout
            nested <- Protocol.handoffChannel childOutput childInput
            pending <- newIORef Nothing
            let send channel message = Protocol.channelSend channel message >>= either (assertFailure . show) pure
                upward = do
                    received <- Protocol.channelReceive nested
                    case received of
                        Left _ -> pure ()
                        Right message -> do
                            when (Protocol.protocolMessageTag message == Protocol.RootedLifecycleRequestTag
                                && any (ByteStringChar8.isInfixOf "settle-node") (Protocol.protocolMessageFields message)) $
                                writeIORef pending (Just (Protocol.protocolMessageRequestId message))
                            send parent message
                            upward
                downward = do
                    received <- Protocol.channelReceive parent
                    case received of
                        Left _ -> pure ()
                        Right message -> do
                            send nested message
                            expected <- readIORef pending
                            if expected == Just (Protocol.protocolMessageRequestId message)
                                && Protocol.protocolMessageTag message == Protocol.RootedLifecycleResponseTag
                                then do
                                    threadDelay 50000
                                    identity <- getPid child >>= maybe (assertFailure "crash child exited before settlement") pure
                                    signalProcess sigUSR1 identity
                                else downward
            upThread <- forkIO upward
            downThread <- forkIO downward
            status <- waitForProcess child
            killThread upThread
            killThread downThread
            pure status
#endif

-- Inject one protocol request over the actual reverse child's handoff pipes.
reverseRefusalProxy :: FilePath -> FilePath -> String -> IO ExitCode
reverseRefusalProxy root executable mode =
    withCreateProcess (proc executable ["--hostbootstrap-recursive-lifecycle-child"]){std_in = CreatePipe, std_out = CreatePipe} $
        \maybeInput maybeOutput _ child -> do
            childInput <- maybe (assertFailure "reverse child stdin is absent") pure maybeInput
            childOutput <- maybe (assertFailure "reverse child stdout is absent") pure maybeOutput
            parent <- Protocol.handoffChannel stdin stdout
            nested <- Protocol.handoffChannel childOutput childInput
            before <- newEmptyMVar
            awaiting <- newIORef False
            finished <- newEmptyMVar
            downFinished <- newEmptyMVar
            let send channel message = Protocol.channelSend channel message >>= either (assertFailure . show) pure
                upward = do
                    received <- Protocol.channelReceive nested
                    case received of
                        Left _ -> pure ()
                        Right message -> do
                            if Protocol.protocolMessageTag message /= Protocol.RootedLifecycleRequestTag
                                then send parent message >> upward
                                else do
                                    envelope <- case Protocol.protocolMessageFields message of
                                        [value] -> pure value
                                        _ -> assertFailure "rooted request has no unique envelope"
                                    (domain, afterDomain) <- expectRight (takeHandoffFrame envelope)
                                    (path, _) <- expectRight (takeHandoffFrame afterDomain)
                                    (childFrame, _) <- expectRight (takeHandoffFrame path)
                                    payload <- if mode == "activation"
                                        then do
                                            manifest <- expectRight $ Activation.activationManifest $
                                                Activation.ActivationManifestInput
                                                    { Activation.manifestInputScope = "Production"
                                                    , Activation.manifestInputPlanDigest = "reverse-plan"
                                                    , Activation.manifestInputSpecDigest = "reverse-spec"
                                                    , Activation.manifestInputBinaryDigest = "reverse-binary"
                                                    , Activation.manifestInputFrame = "reverse-frame"
                                                    , Activation.manifestInputRevision = "reverse-revision"
                                                    , Activation.manifestInputConfigDigest = "reverse-config"
                                                    , Activation.manifestInputSecretDigest = Activation.activationSecretDigestFromBytes "reverse-secret"
                                                    , Activation.manifestInputService = "reverse-service"
                                                    , Activation.manifestInputRolePlanDigest = "reverse-role"
                                                    , Activation.manifestInputPermittedEffects = ["reverse-effect"]
                                                    , Activation.manifestInputSecretChannel = "reverse-secret-channel"
                                                    }
                                            pure (Activation.renderActivationManifest manifest)
                                        else pure $ Handoff.renderHandoffBindingInput Handoff.HandoffBindingInput
                                            { Handoff.requestedSpecDigest = "reverse-spec"
                                            , Handoff.requestedPayloadKind = Handoff.NarrowedProjectConfig
                                            , Handoff.requestedPlanRevision = "reverse-plan"
                                            , Handoff.requestedParentFrame = TextEncoding.decodeUtf8 childFrame
                                            , Handoff.requestedChildFrame = "reverse-grandchild"
                                            , Handoff.requestedChildConfigDigest = Handoff.childConfigDigest "reverse-config"
                                            , Handoff.requestedPhase = "execute"
                                            }
                                    original <- fixtureAuthorityImage root executable
                                    writeFile (root </> "reverse-relay-token-keys") (show (reverseRelayTokenKeys original))
                                    writeFile (root </> "reverse-relay-injected") (mode <> "\n")
                                    putMVar before original
                                    writeIORef awaiting True
                                    injected <- expectRight $ Protocol.protocolMessage
                                        (if mode == "activation" then Protocol.ActivationSignRequestTag else Protocol.OfferRequestTag)
                                        (Protocol.protocolMessageRequestId message)
                                        [frameWire domain <> frameWire path <> frameWire payload]
                                    send parent injected
                downward = do
                    received <- Protocol.channelReceive parent
                    case received of
                        Left _ -> pure ()
                        Right message -> do
                            injected <- readIORef awaiting
                            if injected then do
                                Protocol.protocolMessageTag message @?= Protocol.RefusedTag
                                let detail = if mode == "activation"
                                        then "the reverse coordinator carries no activation signer"
                                        else "the reverse coordinator admits no config edge"
                                Protocol.protocolMessageFields message @?= ["edge-not-planned", "handoff relay: the plan names no such edge: " <> detail]
                                original <- readMVar before
                                fixtureAuthorityImage root executable >>= (@?= original)
                                writeFile (root </> "reverse-relay-refusal") (mode <> "\n")
                                send nested message
                            else send nested message >> downward
            upThread <- forkFinally upward (putMVar finished)
            downThread <- forkFinally downward (putMVar downFinished)
            status <- waitForProcess child
            completed <- timeout (5 * 1000000) (takeMVar finished)
            downResult <- timeout (5 * 1000000) (takeMVar downFinished)
            killThread upThread
            killThread downThread
            case downResult of
                Just (Right ()) -> pure ()
                Just (Left failure) -> Exception.throwIO failure
                Nothing -> assertFailure "the reverse refusal response did not finish"
            case completed of
                Just (Right ()) -> pure status
                Just (Left failure) -> Exception.throwIO failure
                Nothing -> assertFailure "the reverse refusal proxy did not finish"

reverseRelayTokenKeys :: [(Text.Text, value)] -> [Text.Text]
reverseRelayTokenKeys = map fst . filter (Text.isPrefixOf "handoff-token." . fst)

-- Hold the child's acknowledgement after root adoption until the root process dies.
adoptedInterruptionProxy :: FilePath -> FilePath -> FilePath -> IO ExitCode
adoptedInterruptionProxy root executable readyPath =
    withCreateProcess (proc executable ["--hostbootstrap-recursive-lifecycle-child"]){std_in = CreatePipe, std_out = CreatePipe} $
        \maybeInput maybeOutput _ child -> do
            childInput <- maybe (assertFailure "adoption child stdin is absent") pure maybeInput
            childOutput <- maybe (assertFailure "adoption child stdout is absent") pure maybeOutput
            parent <- Protocol.handoffChannel stdin stdout
            nested <- Protocol.handoffChannel childOutput childInput
            let send channel message = Protocol.channelSend channel message >>= either (assertFailure . show) pure
                upward = do
                    received <- Protocol.channelReceive nested
                    case received of
                        Left _ -> pure ()
                        Right message -> send parent message >> upward
                downward = do
                    received <- Protocol.channelReceive parent
                    case received of
                        Left _ -> terminateProcess child
                        Right message
                            | Protocol.protocolMessageTag message == Protocol.AcknowledgedTag -> do
                                attempts <- lines <$> readFile (root </> "reverse-attempts")
                                attempts @?= ["container"]
                                image <- fixtureAuthorityImage root executable
                                assertBool "the container parent row is durably Adopted before interruption"
                                    (any (\(key, row) -> "lifecycle-parent." `Text.isPrefixOf` key
                                        && maybe False (\(_, bytes) -> frameWire "adopted" `ByteStringChar8.isInfixOf` bytes
                                            && "vm-project-container-2" `ByteStringChar8.isInfixOf` bytes) row) image)
                                writeFile (readyPath <> ".sessions") (show (filter (Text.isPrefixOf "session." . fst) image))
                                let pendingPath = readyPath <> ".pending"
                                writeFile pendingPath "container-adopted"
                                renameFile pendingPath readyPath
                                _ <- Protocol.channelReceive parent
                                terminateProcess child
                            | otherwise -> send nested message >> downward
            upThread <- forkIO upward
            downThread <- forkIO downward
            status <- waitForProcess child
            killThread upThread
            killThread downThread
            pure status

-- The fixture proxy duplicates the exact opening after the first prepared
-- response, then forwards the child's pending settle request unchanged.
replayOpeningProxy :: FilePath -> FilePath -> String -> IO ExitCode
replayOpeningProxy root executable mode =
    withCreateProcess (proc executable ["--hostbootstrap-recursive-lifecycle-child"]){std_in = CreatePipe, std_out = CreatePipe} $
        \maybeInput maybeOutput _ child -> do
            childInput <- maybe (assertFailure "replay child stdin is absent") pure maybeInput
            childOutput <- maybe (assertFailure "replay child stdout is absent") pure maybeOutput
            parent <- Protocol.handoffChannel stdin stdout
            nested <- Protocol.handoffChannel childOutput childInput
            opening <- newIORef Nothing
            count <- newIORef (0 :: Int)
            awaitingReplay <- newIORef False
            firstResponse <- newEmptyMVar
            replayResponse <- newEmptyMVar
            finished <- newEmptyMVar
            let send channel message = Protocol.channelSend channel message >>= either (assertFailure . show) pure
                upward = do
                    received <- Protocol.channelReceive nested
                    case received of
                        Left _ -> pure ()
                        Right message -> do
                            if Protocol.protocolMessageTag message /= Protocol.RootedLifecycleRequestTag
                                then send parent message
                                else do
                                    ordinal <- readIORef count
                                    writeIORef count (ordinal + 1)
                                    when (ordinal == 0) (writeIORef opening (Just message))
                                    let trigger = if mode == "descent-domain"
                                            then any (ByteStringChar8.isInfixOf "descend-result") (Protocol.protocolMessageFields message)
                                            else ordinal == 2
                                    when trigger $ do
                                        original <- readIORef opening >>= maybe (assertFailure "opening request was not recorded") pure
                                        expected <- readMVar firstResponse
                                        when (mode /= "1") ignoreReplayTermination
                                        before <- if mode == "1" then pure [] else fixtureAuthorityImage root executable
                                        writeIORef awaitingReplay True
                                        attempted <- case mode of
                                            "1" -> pure original
                                            "nonce" -> mutateOpening mode original
                                            "path" -> mutateOpening mode original
                                            _ -> mutateObservation mode message
                                        send parent attempted
                                        replay <- takeMVar replayResponse
                                        if mode == "1" then replay @?= expected else do
                                            if mode `elem` ["unsolicited", "descent-domain"]
                                                then do
                                                    Protocol.protocolMessageTag replay @?= Protocol.RootedLifecycleResponseTag
                                                    let detail = if mode == "unsolicited" then "the frame has no outstanding descent"
                                                            else "the forward descent observation domain is invalid"
                                                    assertBool "the signed refusal names the descent error"
                                                        (any (ByteStringChar8.isInfixOf detail) (Protocol.protocolMessageFields replay))
                                                else do
                                                    Protocol.protocolMessageTag replay @?= Protocol.RefusedTag
                                                    let expectedFields = case mode of
                                                            "nonce" -> ["rooted-refused", "rooted frame session: session: the the rooted frame session row conflicts record is unreadable"]
                                                            "path" -> ["rooted-path", "no admitted frame session names this requester path"]
                                                            "foreign" -> ["rooted-settle", "the observation names another node"]
                                                            _ -> ["rooted-settle", "has another node observation domain"]
                                                    Protocol.protocolMessageFields replay @?= expectedFields
                                            fixtureAuthorityImage root executable >>= (@?= before)
                                        writeIORef awaitingReplay False
                                        writeFile (root </> "opening-replay") (mode <> "\n")
                                        when (mode /= "1") (send nested replay)
                                    when (not trigger || mode == "1") (send parent message)
                            upward
                downward = do
                    received <- Protocol.channelReceive parent
                    case received of
                        Left _ -> pure ()
                        Right message -> do
                            replaying <- readIORef awaitingReplay
                            if replaying && Protocol.protocolMessageTag message `elem` [Protocol.RootedLifecycleResponseTag, Protocol.RefusedTag]
                                then putMVar replayResponse message
                                else do
                                    when (Protocol.protocolMessageTag message == Protocol.RootedLifecycleResponseTag) $ do
                                        _ <- tryPutMVar firstResponse message
                                        pure ()
                                    send nested message
                            downward
            upThread <- forkFinally upward (putMVar finished)
            downThread <- forkIO downward
            status <- waitForProcess child
            completed <- timeout (5 * 1000000) (takeMVar finished)
            killThread upThread
            killThread downThread
            case completed of
                Just (Right ()) -> pure status
                Just (Left failure) -> Exception.throwIO failure
                Nothing -> assertFailure "the replay child protocol did not finish"

mutateOpening :: String -> Protocol.ProtocolMessage -> IO Protocol.ProtocolMessage
mutateOpening mode original = case Protocol.protocolMessageFields original of
    [envelope] -> do
        (domain, afterDomain) <- expectRight (takeHandoffFrame envelope)
        (path, afterPath) <- expectRight (takeHandoffFrame afterDomain)
        (request, trailing) <- expectRight (takeHandoffFrame afterPath)
        trailing @?= ByteStringChar8.empty
        changed <- if mode == "nonce"
            then RootedWire.renderRootedLifecycleRequestKernel <$> expectRight (RootedWire.rootedOpenFrameRequestKernel (ByteStringChar8.replicate 32 'N'))
            else pure request
        let changedPath = if mode == "path" then path <> frameWire "foreign" else path
            payload = frameWire domain <> frameWire changedPath <> frameWire changed
        expectRight (Protocol.protocolMessage (Protocol.protocolMessageTag original) (Protocol.protocolMessageRequestId original) [payload])
    _ -> assertFailure "the opening request does not contain one envelope"

mutateObservation :: String -> Protocol.ProtocolMessage -> IO Protocol.ProtocolMessage
mutateObservation mode original = case Protocol.protocolMessageFields original of
    [envelope] -> do
        (domain, afterDomain) <- expectRight (takeHandoffFrame envelope)
        (pathWire, afterPath) <- expectRight (takeHandoffFrame afterDomain)
        (requestWire, trailing) <- expectRight (takeHandoffFrame afterPath)
        trailing @?= ByteStringChar8.empty
        request <- expectRight (RootedWire.rootedLifecycleRequestFromWireKernel requestWire)
        changed <- expectRight $ RootedWire.withRootedLifecycleRequestKernel request
            (const (Left "expected a settle request"))
            (\_ _ _ _ _ _ -> Left "expected a settle request")
            (\path session stage ordinal nonce predecessor body -> do
                replacement <- case mode of
                    "foreign" -> do
                        RootedWire.RootedNodeObservation _ succeeded detail projections <- RootedWire.readRootedNodeObservationKernel body
                        RootedWire.renderRootedNodeObservationKernel (RootedWire.RootedNodeObservation "project:foreign" succeeded detail projections)
                    _ -> Right (frameWire "hostbootstrap/forward-descent-result/v1" <> frameWire "succeeded")
                if mode == "unsolicited"
                    then RootedWire.rootedDescendResultRequestKernel path session stage ordinal nonce predecessor replacement
                    else RootedWire.rootedSettleNodeRequestKernel path session stage ordinal nonce predecessor replacement)
            (\path session stage ordinal nonce predecessor _ ->
                if mode == "descent-domain"
                    then do
                        wrong <- RootedWire.renderRootedNodeObservationKernel (RootedWire.RootedNodeObservation "project:foreign" True "unchanged" [])
                        RootedWire.rootedDescendResultRequestKernel path session stage ordinal nonce predecessor wrong
                    else Left "expected a settle request")
            (\_ _ _ _ _ _ -> Left "expected a settle request")
            (\_ _ _ _ _ _ -> Left "expected a settle request")
        let payload = frameWire domain <> frameWire pathWire <> frameWire (RootedWire.renderRootedLifecycleRequestKernel changed)
        expectRight (Protocol.protocolMessage (Protocol.protocolMessageTag original) (Protocol.protocolMessageRequestId original) [payload])
    _ -> assertFailure "the settle request does not contain one envelope"

ignoreReplayTermination :: IO ()
#if defined(mingw32_HOST_OS)
ignoreReplayTermination = pure ()
#else
ignoreReplayTermination = do
    _ <- installHandler sigTERM Ignore Nothing
    pure ()
#endif

-- A lifecycle durable row contains seven framed fields; the sixth is the exact report.
durableLifecycleReport :: ByteStringChar8.ByteString -> Maybe ByteStringChar8.ByteString
durableLifecycleReport raw = do
    (fields, trailing) <- takeFrames 7 raw
    case (fields, ByteStringChar8.null trailing) of
        (["hostbootstrap/lifecycle-durable", _, _, _, _, report, _], True) -> Just report
        _ -> Nothing
  where
    takeFrames :: Int -> ByteStringChar8.ByteString -> Maybe ([ByteStringChar8.ByteString], ByteStringChar8.ByteString)
    takeFrames 0 bytes = Just ([], bytes)
    takeFrames count bytes = do
        (field, rest) <- either (const Nothing) Just (takeHandoffFrame bytes)
        (fields, trailing) <- takeFrames (count - 1) rest
        pure (field : fields, trailing)

lifecycleReportTag :: ByteStringChar8.ByteString -> Maybe Text.Text
lifecycleReportTag report = either (const Nothing) id $
    Handoff.eliminateLifecycleReport report forwardCompleted none forwardFailed reverseCompleted none none
  where
    none _ _ _ _ _ = Nothing
    forwardCompleted _ _ _ _ _ = Just "forward-completed"
    forwardFailed _ _ _ _ _ = Just "forward-failed"
    reverseCompleted _ _ _ _ _ = Just "reverse-completed"

fixtureAuthorityImage :: FilePath -> FilePath -> IO [(Text.Text, Maybe (String, ByteStringChar8.ByteString))]
fixtureAuthorityImage root executable = do
    let projectName = normalizeExecutableIdentity executable
    store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack projectName)
    expectRight =<< withProtectedEntry store (\entry -> do
        keys <- expectRight =<< listProtectedRecords entry
        rows <- mapM (\key -> do
            record <- expectRight =<< readProtectedRecord entry key
            pure (recordKeyText key, (\value -> (show (protectedRecordVersion value), protectedRecordBytes value)) <$> record)) keys
        pure (Right (sortOn fst rows)))

-- | Read only the owned fixture's actual proxy observations. Each native
-- invocation records its complete vector before entering the child process.
readCrossingEvents :: FilePath -> IO [(FilePath, [String])]
readCrossingEvents root = do
    events <- Text.lines <$> TextIO.readFile (root </> "crossings")
    traverse
        ( \event ->
            maybe
                (assertFailure ("malformed fixture crossing event: " <> Text.unpack event))
                pure
                (readMaybe (Text.unpack event))
        )
        events

fixtureSpec :: FilePath -> Bool -> Bool -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
fixtureSpec fixtureRoot failContainer failCleanup =
    either (error . show) id $
        CLI.finalizeProjectSpec $
            CLI.addSteps (\_ config -> fixtureSteps fixtureRoot failContainer failCleanup config) $
                CLI.addForwardChildPlan (projectChild fixtureRoot failContainer failCleanup) $
                    CLI.projectSpec passingSuite (pure ()) [] Fixture.testConfigCodec fixtureTestInit fixtureAssemble

projectChild :: FilePath -> Bool -> Bool -> Fixture.ProjectConfig scope -> CLI.ParentFrameId -> CLI.ChildFrameId -> LiftContext -> Either String (FilePath, Fixture.ProjectConfig scope, StepPlan)
projectChild fixtureRoot failContainer failCleanup parent _parent (CLI.ChildFrameId child) _route = do
    let kind = if child == "vm-orchestrator-1" then VMOrchestrator else VMProjectContainer
        descriptor = projectDescriptorRoot fixtureRoot <> if kind == VMOrchestrator then "/vm" else "/container"
    config <- Fixture.deriveProjectConfigForKind kind parent (Text.pack descriptor)
    plan <- either (Left . show) Right (mkStepPlan (fixtureSteps fixtureRoot failContainer failCleanup config))
    pure (descriptor, config, plan)

assertRecordedChildOperations :: FilePath -> ByteStringChar8.ByteString -> [Text.Text] -> IO ()
assertRecordedChildOperations root phase suffixes = do
    executable <- fixtureExecutable root
    let projectName = normalizeExecutableIdentity executable
    store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack projectName)
    rows <- expectRight =<< withProtectedEntry store (\entry -> do
        keys <- expectRight =<< listProtectedRecords entry
        records <- mapM (\key -> do
            record <- expectRight =<< readProtectedRecord entry key
            pure (recordKeyText key, record)) keys
        pure (Right records))
    mapM_ (\suffix -> assertBool ("missing reverse operation evidence for " <> Text.unpack suffix)
        (any (\(key, record) -> "op." `Text.isPrefixOf` key && suffix `Text.isSuffixOf` key
            && maybe False (ByteStringChar8.isInfixOf phase . protectedRecordBytes) record) rows)) suffixes

seedChildResource :: FilePath -> Text.Text -> Text.Text -> IO (ProtectedStore, RecordKey, ByteStringChar8.ByteString)
seedChildResource root suffix operation = do
    executable <- fixtureExecutable root
    let projectName = normalizeExecutableIdentity executable
        frame = "vm-project-container-2"
    store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack projectName)
    keys <- expectRight =<< withProtectedEntry store listProtectedRecords
    let names = map recordKeyText keys
        operations = [key | key <- names, "op." `Text.isPrefixOf` key, suffix `Text.isSuffixOf` key]
        plans = [recordNameIdentity (Text.drop 8 key) | key <- names, "project." `Text.isPrefixOf` key]
        matches plan key = ("op." <> sha256Hex (TextEncoding.encodeUtf8 plan) <> ".") `Text.isPrefixOf` key
        selected = [plan | plan <- plans, any (matches plan) operations]
    plan <- case selected of
        [value] -> pure value
        _ -> assertFailure ("fixture did not find the operation's exact project plan: operations=" <> show operations <> ", plans=" <> show plans)
    keyText <- either (assertFailure . show) pure (Reconcile.resourceRecordKey plan frame operation)
    key <- expectRight (mkRecordKey keyText)
    let previous = ByteStringChar8.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, TextEncoding.encodeUtf8 frame, TextEncoding.encodeUtf8 operation, "1", TextEncoding.encodeUtf8 operation, "1", "active", "fixture", "owned"])
    _ <- expectRight =<< withProtectedEntry store (\entry -> compareAndSwapProtectedRecord entry key ExpectAbsent previous)
    pure (store, key, previous)

fixtureSteps :: FilePath -> Bool -> Bool -> Fixture.ProjectConfig scope -> [Step]
fixtureSteps fixtureRoot failContainer failCleanup config =
    [ reversible "root" $ descendsVia (vmContext (inVM (IncusVM "fixture-vm" "fixture:image") emptyVMStack)) (node "root" "host-orchestrator-0" StepChanged)
    , reversible "vm" $ emptyContainer $ descendsVia (inContainer _container emptyVMStack) (node "vm" "vm-orchestrator-1" StepChanged)
    , reversible "vm-extra" $ node "vm-extra" "vm-orchestrator-1" StepChanged
    ] ++ [containerNode | not emptyContainerFrame] ++ [deployKindStep "fixture cluster" (StepFrame "vm-project-container-2" "vm-project-container-2") (\_ -> pure StepChanged) | "recursive-managed-kind" `isInfixOf` fixtureRoot]
      ++ [staleClusterNode | "recursive-managed-kind-stale" `isInfixOf` fixtureRoot]
      ++ [deployChartStep "fixture chart" (StepFrame "vm-project-container-2" "vm-project-container-2") (\_ -> pure StepChanged) | "recursive-managed" `isInfixOf` fixtureRoot]
      ++ [reversible "root-failure" $ postHandoffStep "root-failure" "root-failure" (StepFrame "host-orchestrator-0" "host-orchestrator-0") (\_ -> pure (StepConflict "ready" "failed" "fixture root failure")) | "recursive-root-failure" `isInfixOf` fixtureRoot]
  where
    -- The empty-container variant admits the container frame with no step of its own.
    emptyContainerFrame = "recursive-empty-container" `isInfixOf` fixtureRoot
    emptyContainer
        | emptyContainerFrame = declaresEmptyChildFrame (StepFrame "vm-project-container-2" "vm-project-container-2")
        | otherwise = id
    containerNode =
        let action = activationPlacement $ node "container" "vm-project-container-2" (if failContainer then StepConflict "ready" "failed" "fixture failure" else StepChanged)
         in observesRecoveryWith fixtureContainerObserver (if failContainer && not failCleanup then action else reversible "container" action)
    activationPlacement = if "recursive-activation" `isInfixOf` fixtureRoot && currentFrame (cfgContext config) == "vm-project-container-2"
        then declaresServiceActivation "fixture-service-frame" "fixture-service" ["service-port"]
        else id
    reversible name = reversedBy $ \_ _ -> do
        appendFile (fixtureRoot </> "reverse-attempts") (name <> "\n")
        crashReverse <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH_REVERSE"
        if crashReverse == Just "1" && name == "container" then crashReverseFixture else pure ()
        crashRoot <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH_ROOT"
        if crashRoot == Just "1" && name == "root" then crashReverseFixture else pure ()
        throwReverse <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_THROW_REVERSE"
        if throwReverse == Just "1" && name == "container" then Exception.throwIO (LifecycleFailure "fixture reverse exception") else pure ()
        emptyRefusal <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EMPTY_REFUSAL"
        largeDetail <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_LARGE_DETAIL"
        pure $
            if emptyRefusal == Just "1" && name == "container"
                then TeardownRefused ""
                else if largeDetail == Just "1" && name == "container"
                then TeardownFailed (replicate 3200000 '\x00e9')
                else if failCleanup && name == "container"
                then TeardownFailed "fixture cleanup failure"
                else TeardownReleased
    deliveryPayload =
        case Fixture.deriveProjectConfigForKind VMProjectContainer config (Text.pack (projectDescriptorRoot fixtureRoot <> "/container")) of
            Right child -> Fixture.renderProjectConfig child <> "\n"
            Left _ ->
                case Fixture.deriveProjectConfigForKind VMOrchestrator config (Text.pack (projectDescriptorRoot fixtureRoot <> "/vm"))
                    >>= \vmConfig -> Fixture.deriveProjectConfigForKind VMProjectContainer vmConfig (Text.pack (projectDescriptorRoot fixtureRoot <> "/container")) of
                    Right child -> Fixture.renderProjectConfig child <> "\n"
                    Left _ -> Fixture.renderProjectConfig config <> "\n"
    _container =
        ContainerLift
            "fixture:image"
            ProviderGuestContainer
            []
            []
            True
            (Just (ConfigDelivery "/workspace/container/project.dhall" deliveryPayload))

projectDescriptorRoot :: FilePath -> FilePath
projectDescriptorRoot = hostPathAsPosixDescriptor

{- | The local process fixture represents POSIX guest frames. Where that row
cannot execute locally, assert its actual refusal and then prove that the
native receiver rejects the incompatible canonical root before child work.
CoverageManifest reports these outcomes separately from recursive execution.
-}
withLocalGuestFrame :: [TestName] -> IO () -> IO ()
withLocalGuestFrame family action =
    conditionalAction family posixOwnershipSupported action $
        withFixtureEnvironment False $ \root _ -> do
            observed <- withOwnershipRow posixOwnershipRow $ \row -> rowObserveIdentity row (root </> "vm")
            case observed of
                Left (OwnershipUnsupported _) -> pure ()
                other -> assertFailure ("expected the guest row's declared refusal, got " ++ show other)
            executable <- fixtureExecutable root
            childEnvironment <- recursiveFixtureEnvironment root False False
            (status, _, diagnostic) <-
                readCreateProcessWithExitCode
                    (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"]){env = Just childEnvironment}
                    ""
            status @?= ExitFailure 1
            assertBool
                ("the native receiver refuses the different guest-root snapshot; diagnostic: " ++ diagnostic)
                ( ( "PlanHandoffEvidenceMismatch" `Text.isInfixOf` Text.pack diagnostic
                        && "stable plan digest" `Text.isInfixOf` Text.pack diagnostic
                  )
                    || "ProjectRootEscapesAnchor" `Text.isInfixOf` Text.pack diagnostic
                )

{- | The container step's recovery observer. It reports the effect absent only
when the fixture has verified that absence, and is otherwise inconclusive, so an
unverified interruption still refuses recovery.
-}
fixtureContainerObserver :: RecoveryObserver
fixtureContainerObserver =
    either error id $
        mkRecoveryObserver "fixture-container-observer" 1 NoDelayedEffect $ \_operation _frame -> do
            verified <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_OBSERVE_ABSENT"
            pure $
                if verified == Just "1"
                    then RecoveryEffectAbsent
                    else RecoveryInconclusive "the fixture has not verified the container effect's absence"

node :: String -> String -> StepObservation -> Step
node name frame observation =
    projectStep (stepId name) ProjectManagedReverse name (StepFrame frame frame) $ \execution -> do
        markerRoot <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
        when (name `elem` ["vm", "container"]) $
            mapM_ (\root -> appendFile (root </> "forward-frames") (frame <> "\n")) markerRoot
        blockContainer <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_BLOCK_CONTAINER"
        when (name == "container" && blockContainer == Just "1") $ do
            root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
            identity <- currentFixtureProcessId
            writeFile (root </> "interrupt-container.pid") (show identity <> "\n")
            let awaitSentinel = do
                    ready <- doesFileExist (root </> "interrupt-container.release")
                    if ready then pure () else threadDelay 25000 >> awaitSentinel
            awaitSentinel
        blocked <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_BLOCK"
        if name == "vm" && blocked == Just "1"
            then do
                fixtureRoot <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
                fixturePid <- currentFixtureProcessId
                writeFile (fixtureRoot </> "cancellation-child.pid") (show fixturePid <> "\n")
                threadDelay (60 * 1000000)
            else pure ()
        if frame == "vm-project-container-2"
            then do
                putStrLn "recursive fixture: child stdout is diagnostic"
                input <- hGetContents stdin
                Exception.evaluate (length input) >>= (@?= 0)
                fixtureRoot <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
                writeFile (fixtureRoot </> "stdio-probe") "stdout redirected; stdin EOF\n"
            else pure ()
        crash <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CRASH"
        replaceReservation <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_REPLACE_RESERVATION"
        when (name == "container") (mapM_ replaceFixtureExecuteReservation replaceReservation)
        activation <- lookupEnv "HOSTBOOTSTRAP_RECURSIVE_ACTIVATION"
        when (name == "container") (mapM_ (runFixtureActivation execution) activation)
        case (name, crash) of
            ("container", Just "1") -> ioError (userError "fixture interrupted after preparation")
            ("container", Just "refusal") -> Exception.throwIO (SafetyRefusal "fixture safety refusal")
            _ -> pure observation

-- After the unrecorded fixture cluster settles, publish a released record for
-- it, as an external writer would: the next node that depends on the cluster
-- now finds a recorded but released prerequisite at the root.
staleClusterNode :: Step
staleClusterNode =
    projectStep (stepId "stale-cluster") ProjectManagedReverse "stale-cluster" (StepFrame "vm-project-container-2" "vm-project-container-2") $ \execution -> do
        root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
        executable <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE"
        let project = normalizeExecutableIdentity executable
            digest = stepExecutionPlanDigest execution
            frame = "vm-project-container-2"
            operation = "core:deploy-kind"
            released = ByteStringChar8.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 digest, frame, operation, "1", operation, "2", "released", "fixture", "released"])
        store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack project)
        keyText <- expectRight (Reconcile.resourceRecordKey digest (TextEncoding.decodeUtf8 frame) (TextEncoding.decodeUtf8 operation))
        key <- expectRight (mkRecordKey keyText)
        _ <- expectRight =<< withProtectedEntry store (\entry -> compareAndSwapProtectedRecord entry key ExpectAbsent released)
        TextIO.writeFile (root </> "cluster-released") keyText
        pure StepChanged

-- Model an external writer replacing the root's exact one-shot reservation.
replaceFixtureExecuteReservation :: String -> IO ()
replaceFixtureExecuteReservation mode = do
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    executable <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE"
    let project = normalizeExecutableIdentity executable
    store <- expectRight =<< openProtectedStore (root </> ".hostbootstrap" </> "authority" </> Text.unpack project)
    key <- expectRight =<< withProtectedEntry store (\entry -> do
        keys <- expectRight =<< listProtectedRecords entry
        records <- mapM (\key -> do
            record <- expectRight =<< readProtectedRecord entry key
            pure (key, record)) keys
        case [(key, record) | (key, Just record) <- records
                , "invocation." `Text.isPrefixOf` recordKeyText key
                , "2:up7:execute" `ByteStringChar8.isSuffixOf` protectedRecordBytes record] of
            [(key, record)] -> do
                let expected = ExpectVersion (protectedRecordVersion record)
                case mode of
                    "replace" -> do
                        _ <- expectRight =<< compareAndSwapProtectedRecord entry key expected "foreign reservation"
                        pure (Right key)
                    "same-bytes" -> do
                        _ <- expectRight =<< compareAndSwapProtectedRecord entry key expected (protectedRecordBytes record)
                        pure (Right key)
                    "delete" -> do
                        _ <- expectRight =<< compareAndDeleteProtectedRecord entry key expected
                        pure (Right key)
                    _ -> assertFailure "unknown reservation mutation"
            matches -> assertFailure ("expected one root Execute reservation, got " <> show (length matches)))
    TextIO.writeFile (root </> "reservation-replaced") (recordKeyText key)
    pure ()

runFixtureActivation :: StepExecution scope planId -> String -> IO ()
runFixtureActivation execution mode = do
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    let input = Activation.ActivationManifestInput
            { Activation.manifestInputScope = "Production"
            , Activation.manifestInputPlanDigest = if mode == "plan" then "foreign-plan" else stepExecutionPlanDigest execution
            , Activation.manifestInputSpecDigest = "fixture-spec"
            , Activation.manifestInputBinaryDigest = "fixture-binary"
            , Activation.manifestInputFrame = if mode == "frame" then "foreign-frame" else "fixture-service-frame"
            , Activation.manifestInputRevision = "fixture-revision"
            , Activation.manifestInputConfigDigest = "fixture-config"
            , Activation.manifestInputSecretDigest = Activation.activationSecretDigestFromBytes "fixture-secret"
            , Activation.manifestInputService = if mode == "service" then "foreign-service" else "fixture-service"
            , Activation.manifestInputRolePlanDigest = "fixture-role"
            , Activation.manifestInputPermittedEffects = if mode == "effects" then ["foreign-effect"] else ["service-port"]
            , Activation.manifestInputSecretChannel = "fixture-secret-channel"
            }
    manifest <- expectRight (Activation.activationManifest input)
    let wire = Activation.renderActivationManifest manifest
    result <- stepExecutionSignActivationManifest execution wire
    case result of
        Left failure -> TextIO.writeFile (root </> "activation-refusal") failure
        Right signature -> do
            ByteStringChar8.writeFile (root </> "activation-manifest") wire
            ByteStringChar8.writeFile (root </> "activation-signature") signature

currentFixtureProcessId :: IO Int
#if defined(mingw32_HOST_OS)
currentFixtureProcessId = ioError (userError "POSIX cancellation observation is unavailable on Windows")
#else
currentFixtureProcessId = fromIntegral <$> getProcessID
#endif

stepId :: String -> ProjectStepId
stepId = either error id . projectStepId

passingSuite :: TestSuite
passingSuite = TestSuite (pure (Right ())) (\_ _ -> pure ()) [Case (either (error . show) id (mkCaseId "ok")) AssertOnce] (\_ _ -> pure Pass) (pure ())

fixtureTestInit :: a -> Fixture.TestConfig
fixtureTestInit _ = Fixture.defaultTestConfig (Fixture.Resources 1 "1GiB" "1GiB")

fixtureAssemble :: forall projectId scope. AssemblyRequest projectId Fixture.TestConfig Text.Text scope -> ConfigAssembly scope (Fixture.ProjectConfig scope)
fixtureAssemble request = case request of
    ProductionAssembly args -> Fixture.projectInit "recursive" args
    HarnessAssembly _ _ _ _ -> pureConfigAssembly (Fixture.defaultProjectConfig "recursive" "/workspace" HostOrchestrator)
