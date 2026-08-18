{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ColimaSpec (tests) where

import Control.Concurrent
  ( MVar,
    forkIO,
    killThread,
    newEmptyMVar,
    putMVar,
    takeMVar,
    threadDelay,
    tryReadMVar,
  )
import Control.Exception (SomeAsyncException, SomeException, fromException, try)
#if !defined(mingw32_HOST_OS)
import Control.Exception (IOException, bracket)
#endif
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon (mkResourceBudget)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure.Colima
import HostBootstrap.Ensure.Colima.Backend.Internal
import HostBootstrap.Ensure.Colima.Backend.Resolver.Testing
import HostBootstrap.Lifecycle.Prepared (
  PreparedGate,
  preparedGateAttempt,
  preparedGateFence,
  preparedGateJournalVersion,
  preparedGateSession,
 )
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan
  ( ClusterResource,
    PlannedResource,
    PlannedResourceKind (ClusterResourceKind, ProviderResourceKind),
    ProjectPlan,
    ProviderResource,
    forward,
    plannedStepOperationKey,
    plannedResourceKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    withPlannedResourceOfKind,
  )
import HostBootstrap.Reconcile
  ( ChangeView (..),
    ChangedKind (..),
    Destroyed,
    PhaseAdvance,
    ReconcileError (..),
    ownershipReceiptOperationKey,
    resourceHandleGeneration,
    resourceHandleObservationVersion,
    withObservedProjectResource,
    withPhaseAdvance,
  )
import PrepareFixture (gateForValues, withSuccessorGate)
import HostBootstrap.Step
  ( StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
  )
import System.Directory
  ( Permissions (executable),
#if !defined(mingw32_HOST_OS)
    copyFile,
    createDirectory,
#endif
    createDirectoryIfMissing,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    findExecutable,
    getPermissions,
    listDirectory,
#if !defined(mingw32_HOST_OS)
    removePathForcibly,
#endif
    removeFile,
    renameDirectory,
    setPermissions,
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (searchPathSeparator, takeDirectory, (</>))
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
#if !defined(mingw32_HOST_OS)
import Numeric (showHex)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
#endif
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

profileName :: String
profileName = "h-012345"

namespaceKey :: String
namespaceKey = "0123456789abcdef0123456789abcdef"

ownerToken :: String
ownerToken =
  "v2-68-70-72-66-63-64-1-65-74-75-76"

otherOwnerToken :: String
otherOwnerToken =
  "v2-68-70-73-66-63-64-1-65-74-75-76"

acquireInvocation :: String
acquireInvocation = replicate 64 'a'

cleanupInvocation :: String
cleanupInvocation = replicate 64 'b'

exactEnvelope :: Context.ResourceEnvelope
exactEnvelope = Context.ResourceEnvelope 8 "16GiB" "100GiB"

canonicalStartArgs :: [String]
canonicalStartArgs =
  [ "start",
    "--profile",
    profileName,
    "--runtime",
    "docker",
    "--activate=false",
    "--template=false",
    "--ssh-config=false",
    "--mount",
    "none",
    "--kubernetes=false",
    "--network-address=false",
    "--mount-inotify=false",
    "--cpus",
    "8",
    "--memory",
    "16",
    "--root-disk",
    "20",
    "--disk",
    "80"
  ]

tests :: TestTree
tests =
  testGroup
    "ColimaSpec"
    [ testCase "the public exact consumer derives a fixed opaque provider profile" $ do
        result <-
          withPreparedTestCall $ \expectedProject call ->
            (Text.unpack expectedProject, preparedColimaProfileName call)
        case result of
          Left failure -> assertFailure failure
          Right (project, profile) -> do
            assertBool "the provider profile is not the caller-visible project name" (profile /= project)
            assertBool "the provider profile is a fixed lowercase local label" (isPrefixOf "h-" profile && length profile == 8),
      testCase "the shared default profile is outside the exact boundary" $
        assertBool
          "default must never become project authority"
          (not (validColimaProjectProfileName "default")),
      testCase "the public adapter settles acquisition, routed Docker, and journaled force-destroy cleanup" $
        onOwnershipHost $ withShortResolverHarness $ \resolver effectiveHome markerRoot -> do
          initialExecution <- executeResolverFixtureAt resolver effectiveHome
          (_resolverOutput, resolverProtocol) <- requireReadyResolver resolver initialExecution
          let layout = resolverHarnessLayout resolver
              (pythonDevice, pythonInode) = resolverPythonIdentity resolverProtocol
              executeFresh = resolverExecutionFixture <$> executeResolverFixtureAt resolver effectiveHome
          bracketed <-
            withTrustedResolverFixture
              (resolverFixtureRoot layout)
              effectiveHome
              pythonDevice
              pythonInode
              executeFresh
              ( do
                  prepared <-
                    withPreparedPublicTestCallM $ \plan provider cluster acquireGate nextAcquireGate _expectedProject call -> do
                      firstObservation <- runPreparedColimaWallCall call
                      let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
                          operation = plannedResourceKey provider
                          fence = preparedGateFence acquireGate
                      case
                          settleColimaWallCall call firstObservation $ \firstLive -> do
                            liveColimaWallChange firstLive @?= Changed Created
                            liveColimaProviderChange firstLive @?= Changed Created
                            routed <- runLiveColimaDocker firstLive ["info"]
                            routed @?= Right (ExitSuccess, "docker-ok\n", "")
                            secondObservation <- runPreparedColimaWallCall call
                            case
                                settleColimaWallCall call secondObservation $ \secondLive -> do
                                  liveColimaWallChange secondLive @?= Unchanged
                                  liveColimaProviderChange secondLive @?= Changed Repaired
                                  writeFile (markerRoot </> "mismatch") ""
                                  conflictedObservation <- runPreparedColimaWallCall call
                                  case settleColimaWallCall call conflictedObservation (const ()) of
                                    Left Conflict {} -> pure ()
                                    Left other -> assertFailure ("unowned conflict settled unexpectedly: " ++ show other)
                                    Right () -> assertFailure "unowned conflict minted live wall authority"
                                  removeFile (markerRoot </> "mismatch")
                                  writeFile (markerRoot </> "list-exit") ""
                                  failedObservation <- runPreparedColimaWallCall call
                                  case settleColimaWallCall call failedObservation (const ()) of
                                    Left Failure {} -> pure ()
                                    Left other -> assertFailure ("unowned failure settled unexpectedly: " ++ show other)
                                    Right () -> assertFailure "unowned failure minted live wall authority"
                                  removeFile (markerRoot </> "list-exit")
                                  case withColimaCleanupAuthority secondLive id of
                                    Nothing -> assertFailure "settled public Colima wall lacked cleanup authority"
                                    Just cleanupAuthority -> do
                                      wrongFenceGate <- gateForValues planDigest operation "wrong-fence-cleanup-session" (fence + 1) 2
                                      wrongFence <- prepareColimaCleanupCall plan provider wrongFenceGate cleanupAuthority
                                      case wrongFence of
                                        Left Conflict {} -> pure ()
                                        Left other -> assertFailure ("wrong-fence cleanup preparation failed unexpectedly: " ++ show other)
                                        Right _ -> assertFailure "wrong-fence cleanup preparation minted a mutation call"
                                      cleanupGate <- gateForValues planDigest operation "cleanup-session" fence 2
                                      preparedCleanup <-
                                        prepareColimaCleanupCall plan provider cleanupGate cleanupAuthority
                                          >>= either (assertFailure . ("prepare public Colima cleanup: " ++) . show) pure
                                      writeFile (markerRoot </> "fail-delete") ""
                                      failedCleanup <- runColimaCleanup preparedCleanup
                                      case failedCleanup of
                                        Left Failure {} -> pure ()
                                        Left other -> assertFailure ("expected public cleanup failure, got " ++ show other)
                                        Right _ -> assertFailure "expected structured public cleanup failure, got typed completion"
                                      removeFile (markerRoot </> "fail-delete")
                                      changedGate <- gateForValues planDigest operation "other-cleanup-session" fence 3
                                      changedCleanup <-
                                        prepareColimaCleanupCall plan provider changedGate cleanupAuthority
                                          >>= either (assertFailure . ("prepare changed public cleanup: " ++) . show) pure
                                      changedResult <- runColimaCleanup changedCleanup
                                      case changedResult of
                                        Left Conflict {} -> pure ()
                                        Left other -> assertFailure ("changed cleanup invocation failed unexpectedly: " ++ show other)
                                        Right _ -> assertFailure "changed cleanup invocation adopted retained releasing state"
                                      completed <-
                                        runColimaCleanup preparedCleanup
                                          >>= either (assertFailure . ("complete public cleanup: " ++) . show) pure
                                      assertDestroyedProvider operation completed
                                      replayed <-
                                        runColimaCleanup preparedCleanup
                                          >>= either (assertFailure . ("replay public cleanup: " ++) . show) pure
                                      assertDestroyedProvider operation replayed
                                      staleGate <- nextAcquireGate
                                      assertBool
                                        "the stale call must belong to a distinct session"
                                        (preparedGateSession staleGate /= preparedGateSession acquireGate)
                                      assertBool
                                        "the stale call must belong to a distinct attempt"
                                        (preparedGateAttempt staleGate /= preparedGateAttempt acquireGate)
                                      assertBool
                                        "the stale call must belong to a successor journal version"
                                        (preparedGateJournalVersion staleGate /= preparedGateJournalVersion acquireGate)
                                      staleReplay <-
                                        withPreparedTestCallForGate plan provider cluster staleGate $ \staleCall ->
                                          case settleColimaWallCall staleCall firstObservation (const ()) of
                                            Left Failure {} -> pure ()
                                            Left other -> assertFailure ("stale acquire observation failed unexpectedly: " ++ show other)
                                            Right () -> assertFailure "stale acquire observation settled a different invocation"
                                      either assertFailure pure staleReplay
                              of
                                Left failure -> assertFailure ("exact public Colima settlement failed: " ++ show failure)
                                Right action -> action
                        of
                          Left failure -> assertFailure ("initial public Colima settlement failed: " ++ show failure)
                          Right action -> action
                  either assertFailure pure prepared
              )
          either (assertFailure . ("private resolver bracket refused public flow: " ++)) pure bracketed,
      testGroup
        "trusted resolver"
        [ testCase "the fixture program and strict facade settle one closed ready toolchain" $
            onOwnershipHost $ withResolverHarness "ready" $ \harness -> do
              execution <- executeResolverFixture harness
              (output, protocol) <- requireReadyResolver harness execution
              case protocol of
                ResolverProtocolReadyView
                  (ResolverToolView pythonPath pythonDevice pythonInode)
                  (ResolverToolView colimaPath _ _)
                  (ResolverToolView dockerPath _ _)
                  (ResolverToolView limaPath _ _)
                  helperPath
                  helperFingerprint -> do
                    let layout = resolverHarnessLayout harness
                    pythonPath @?= resolverFixturePython layout
                    colimaPath @?= resolverFixtureColimaTarget layout
                    dockerPath @?= resolverFixtureDockerTarget layout
                    limaPath @?= resolverFixtureLimaTarget layout
                    assertBool "the ready helper path is closed and nonempty" (not (null helperPath))
                    assertBool "helper identities contribute a canonical fingerprint" (not (null helperFingerprint))
                    case
                        settleResolverFixtureExecutionView
                          (resolverFixtureRoot layout)
                          (resolverFixtureHome layout)
                          pythonDevice
                          pythonInode
                          (ResolverExecutionCompleted ExitSuccess output "")
                      of
                        ResolverSettlementReady settledPython settledColima settledDocker settledLima settledPath fingerprint -> do
                          settledPython @?= pythonPath
                          settledColima @?= colimaPath
                          settledDocker @?= dockerPath
                          settledLima @?= limaPath
                          settledPath @?= helperPath
                          assertBool "the complete toolchain has one deterministic fingerprint" (not (null fingerprint))
                        other -> assertFailure ("expected ready resolver settlement, got " ++ show other)
                other -> assertFailure ("expected ready resolver protocol, got " ++ show other),
          testCase "the resolver rejects malformed, decorated, truncated, and cross-branch reports" $
            onOwnershipHost $ withResolverHarness "protocol" $ \harness -> do
              execution <- executeResolverFixture harness
              (output, _protocol) <- requireReadyResolver harness execution
              let malformed =
                    [ "",
                      init output,
                      "noise\n" ++ output,
                      output ++ "noise\n",
                      map (\character -> if character == '\n' then '\r' else character) output,
                      takeWhile (/= '\t') output ++ "\n",
                      "MISSING_COLIMA" ++ dropWhile (/= '\t') output,
                      init output ++ "\textra\n"
                    ]
              mapM_ (assertResolverRejected (resolverFixtureRoot (resolverHarnessLayout harness))) malformed
              assertResolverRejected (resolverFixtureRoot (resolverHarnessLayout harness)) (output ++ output),
          testCase "missing Colima retains only the trusted bounded Brew install route" $
            onOwnershipHost $ withResolverHarness "missing" $ \harness -> do
              let layout = resolverHarnessLayout harness
              removeFile (resolverFixtureColimaAlias layout)
              execution <- executeResolverFixture harness
              case execution of
                BoundedToolCompleted ExitSuccess output "" ->
                  case parseResolverFixtureProtocolView (resolverFixtureRoot layout) output of
                    Right
                      protocol@(ResolverProtocolMissingColimaView (ResolverToolView _ pythonDevice pythonInode) (ResolverToolView brewPath _ _) helperPath helperFingerprint) -> do
                        brewPath @?= resolverFixtureBrew layout
                        assertBool "install helper path is closed" (not (null helperPath))
                        assertBool "install helper identities are bound" (not (null helperFingerprint))
                        settleResolverFixtureExecutionView
                          (resolverFixtureRoot layout)
                          (resolverFixtureHome layout)
                          pythonDevice
                          pythonInode
                          (ResolverExecutionCompleted ExitSuccess output "")
                          @?= ResolverSettlementMissingColima brewPath helperPath
                        assertBool "the missing branch carries no ready Colima tool" (not (isReadyProtocol protocol))
                    other -> assertFailure ("expected missing-Colima report, got " ++ show other)
                other -> assertFailure ("expected completed missing-Colima resolver, got " ++ show other),
          testCase "the trusted install kernel revalidates, installs, and rediscovers in one closed order" $
            onOwnershipHost $ withResolverHarness "install" $ \harness -> do
              let layout = resolverHarnessLayout harness
              readyExecution <- executeResolverFixture harness
              (readyOutput, _readyProtocol) <- requireReadyResolver harness readyExecution
              removeFile (resolverFixtureColimaAlias layout)
              missingExecution <- executeResolverFixture harness
              (missingOutput, pythonDevice, pythonInode) <-
                case missingExecution of
                  BoundedToolCompleted ExitSuccess output "" ->
                    case parseResolverFixtureProtocolView (resolverFixtureRoot layout) output of
                      Right (ResolverProtocolMissingColimaView (ResolverToolView _ device inode) _ _ _) ->
                        pure (output, device, inode)
                      other -> assertFailure ("expected a strict missing-Colima install input, got " ++ show other)
                  other -> assertFailure ("expected completed missing-Colima resolution, got " ++ show other)
              createFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
              let runScenario revalidation installExecution rediscoveryExecution =
                    runResolverInstallScenario
                      (resolverFixtureRoot layout)
                      (resolverFixtureHome layout)
                      pythonDevice
                      pythonInode
                      missingOutput
                      revalidation
                      installExecution
                      rediscoveryExecution
                  completed = ResolverExecutionCompleted ExitSuccess "" ""
              installed <-
                runScenario
                  (Right ())
                  completed
                  (ResolverExecutionCompleted ExitSuccess readyOutput "")
              case resolverInstallOutcome installed of
                ResolverInstallReadyView fingerprint ->
                  assertBool "rediscovery retained the complete ready-toolchain fingerprint" (not (null fingerprint))
                other -> assertFailure ("expected installed ready toolchain, got " ++ show other)
              resolverInstallTrace installed @?= ["revalidate", "install", "rediscover"]
              brewChanged <- runScenario (Left "brew-drift") completed ResolverExecutionTimedOut
              brewChanged
                @?= ResolverInstallScenarioView
                  (ResolverInstallBrewChangedView "brew-drift")
                  ["revalidate"]
              exitFailed <-
                runScenario
                  (Right ())
                  (ResolverExecutionCompleted (ExitFailure 9) "" "brew-error")
                  ResolverExecutionTimedOut
              exitFailed
                @?= ResolverInstallScenarioView
                  (ResolverInstallExitFailureView (ExitFailure 9) "brew-error")
                  ["revalidate", "install"]
              timedOut <- runScenario (Right ()) ResolverExecutionTimedOut completed
              timedOut
                @?= ResolverInstallScenarioView
                  ResolverInstallTimedOutView
                  ["revalidate", "install"]
              executionFailed <- runScenario (Right ()) (ResolverExecutionFailed "launch") completed
              executionFailed
                @?= ResolverInstallScenarioView
                  (ResolverInstallExecutionFailedView "launch")
                  ["revalidate", "install"]
              stillMissing <-
                runScenario
                  (Right ())
                  completed
                  (ResolverExecutionCompleted ExitSuccess missingOutput "")
              stillMissing
                @?= ResolverInstallScenarioView
                  ResolverInstallStillMissingView
                  ["revalidate", "install", "rediscover"]
              unsupported <-
                runScenario
                  (Right ())
                  completed
                  (ResolverExecutionCompleted ExitSuccess "UNSUPPORTED\trediscovery-layout\n" "")
              unsupported
                @?= ResolverInstallScenarioView
                  (ResolverInstallUnsupportedView "rediscovery-layout")
                  ["revalidate", "install", "rediscover"],
          testCase "the fixed resolver refuses an effective home outside its admitted user root" $
            onOwnershipHost $ withResolverHarness "home-shape" $ \harness -> do
              let outsideHome = resolverFixtureRoot (resolverHarnessLayout harness) </> "outside-home"
              createDirectoryIfMissing True outsideHome
              execution <- executeResolverFixtureAt harness outsideHome
              requireUnsupportedResolver harness execution "home-shape",
          testCase "fixed candidates ignore hostile ambient home, path, and working directory" $
            onOwnershipHost $ withResolverHarness "ambient" $ \harness -> do
              let layout = resolverHarnessLayout harness
                  namespace = resolverHarnessNamespace harness
              assertBool "ambient HOME differs from the admitted fixture home" (namespaceHomeDirectory namespace /= resolverFixtureHome layout)
              assertBool "ambient PATH omits the fixture formula directories" (not (takeDirectory (resolverFixtureColimaTarget layout) `isInfixOf` namespaceExecutablePath namespace))
              execution <- executeResolverFixture harness
              _ <- requireReadyResolver harness execution
              pure (),
          testCase "formula, mode, Docker fallback, and helper-directory identity changes are explicit" $
            onOwnershipHost $ do
              withResolverHarness "bad-formula" $ \harness -> do
                let layout = resolverHarnessLayout harness
                removeFile (resolverFixtureColimaAlias layout)
                createFileLink (resolverFixtureBrew layout) (resolverFixtureColimaAlias layout)
                execution <- executeResolverFixture harness
                requireUnsupportedResolver harness execution "colima-formula-root"
              withResolverHarness "bad-mode" $ \harness -> do
                let layout = resolverHarnessLayout harness
                chmodPath harness (resolverFixtureColimaTarget layout) "0777"
                execution <- executeResolverFixture harness
                requireUnsupportedResolver harness execution "executable-write-mode"
              withResolverHarness "docker-app" $ \harness -> do
                let layout = resolverHarnessLayout harness
                removeFile (resolverFixtureDockerAlias layout)
                execution <- executeResolverFixture harness
                (_output, protocol) <- requireReadyResolver harness execution
                case protocol of
                  ResolverProtocolReadyView _ _ (ResolverToolView dockerPath _ _) _ _ _ ->
                    dockerPath @?= resolverFixtureDockerApp layout
                  other -> assertFailure ("expected Docker Desktop fallback, got " ++ show other)
              withResolverHarness "helper-drift" $ \harness -> do
                firstExecution <- executeResolverFixture harness
                (_firstOutput, firstProtocol) <- requireReadyResolver harness firstExecution
                let layout = resolverHarnessLayout harness
                    helper = last (resolverFixtureSystemHelpers layout)
                    moved = helper ++ ".old"
                renameDirectory helper moved
                createDirectoryIfMissing True helper
                secondExecution <- executeResolverFixture harness
                (_secondOutput, secondProtocol) <- requireReadyResolver harness secondExecution
                assertBool
                  "same-path helper-directory replacement changes the retained fingerprint"
                  (resolverFingerprint firstProtocol /= resolverFingerprint secondProtocol),
          testCase "timeout, execution failure, stderr, exit failure, and bootstrap mismatch mint no facade" $
            onOwnershipHost $ withResolverHarness "settlement-errors" $ \harness -> do
              execution <- executeResolverFixture harness
              (output, protocol) <- requireReadyResolver harness execution
              let layout = resolverHarnessLayout harness
                  (pythonDevice, pythonInode) = resolverPythonIdentity protocol
                  settle =
                    settleResolverFixtureExecutionView
                      (resolverFixtureRoot layout)
                      (resolverFixtureHome layout)
              settle pythonDevice pythonInode ResolverExecutionTimedOut @?= ResolverSettlementUnsupported "resolver-timeout"
              settle pythonDevice pythonInode (ResolverExecutionFailed "fixture") @?= ResolverSettlementUnsupported "resolver-execution-failed"
              settle pythonDevice pythonInode (ResolverExecutionCompleted ExitSuccess output "stderr") @?= ResolverSettlementUnsupported "resolver-stderr"
              settle pythonDevice pythonInode (ResolverExecutionCompleted (ExitFailure 7) output "") @?= ResolverSettlementUnsupported "resolver-exit-failure"
              settle (pythonDevice + 1) pythonInode (ResolverExecutionCompleted ExitSuccess output "") @?= ResolverSettlementUnsupported "resolver-python-identity"
        ],
      testCase "raw Colima JSONL remains plan-independent observation data" $
        parseColimaInstances
          ( unlines
              [ "{\"name\":\"demo\",\"status\":\"Running\",\"cpus\":8,\"memory\":17179869184,\"disk\":107374182400,\"runtime\":\"docker\"}",
                "{\"name\":\"other\",\"status\":\"Stopped\",\"cpus\":2,\"memory\":2147483648,\"disk\":107374182400,\"runtime\":\"incus\"}"
              ]
          )
          @?= Right
            [ ColimaInstance "demo" "Running" 8 (16 * gib) (100 * gib) "docker",
              ColimaInstance "other" "Stopped" 2 (2 * gib) (100 * gib) "incus"
            ],
      testCase "absent, exact-running, and exact-stopped observations classify before mutation" $ do
        result <-
          withPreparedTestCall $ \_ call ->
            let profile = preparedColimaProfileName call
                decide = first show . classifyColimaWall call
             in ( decide [],
                  decide [exactInstance profile "Running"],
                  decide [exactInstance profile "Stopped"]
                )
        case result of
          Left failure -> assertFailure failure
          Right (absent, running, stopped) -> do
            absent @?= Right CreateColimaWall
            running @?= Right KeepExactColimaWall
            stopped @?= Right StartStoppedColimaWall,
      testCase "an incompatible same-name profile is refused as data" $ do
        result <-
          withPreparedTestCall $ \_ call ->
            first show $
              classifyColimaWall
                call
                [ ColimaInstance
                    (preparedColimaProfileName call)
                    "Running"
                    4
                    (16 * gib)
                    (80 * gib)
                    "docker"
                ]
        case result of
          Right (Right (RefuseColimaWall _)) -> pure ()
          other -> assertFailure ("expected refusal, got " ++ show other),
      testCase "initial acquisition atomically publishes one nonce-bearing managed record" $
        onOwnershipHost $ withBackendHarness "atomic-create" $ \harness -> do
          acquireStartArgs (acquireRequest harness) @?= canonicalStartArgs
          receipt <- acquireReceipt harness
          receiptOwner receipt @?= ownerToken
          length (receiptNonce receipt) @?= 64
          contents <- strictReadFile (backendRecordPath harness)
          recordField "state" contents @?= Just "managed"
          recordField "owner" contents @?= Just (receiptOwner receipt)
          recordField "nonce" contents @?= Just (receiptNonce receipt)
          recordField "machine" contents @?= Just (receiptMachine receipt)
          recordField "epoch" contents @?= Just (show (receiptEpoch receipt))
          stages <- stageEntries harness
          length stages @?= 1
          assertBool "the only retained stage is the reserved lineage anchor" (any (isInfixOf ".reserved.") stages),
      testCase "a crash after isolated-home creation resumes only the exact nonce-bound stage" $
        onOwnershipHost $ withBackendHarness "home-stage-crash" $ \harness -> do
          crashed <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireTestingCrashPoint = Just CrashAfterHomeStageCreation
                }
          crashed @?= AcquireFailed "backend-process"
          contents <- strictReadFile (backendRecordPath harness)
          recordField "state" contents @?= Just "reserved"
          nonce <- requireRecordNonce contents
          let stagedHome = namespaceColimaHome (backendNamespace harness) ++ ".init." ++ nonce ++ ".stage"
          staged <- doesDirectoryExist stagedHome
          assertBool "the exact home stage survived the killed backend" staged
          recovered <- runAcquireBackend (acquireRequest harness)
          assertBool "the same invocation recovered the self-bound home stage" (ownedAcquire recovered)
          events <- backendEvents harness
          length (filter (isPrefixOf "start ") events) @?= 1,
      testCase "a crash after Docker-config creation resumes only the exact empty context stage" $
        onOwnershipHost $ withBackendHarness "context-stage-crash" $ \harness -> do
          crashed <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireTestingCrashPoint = Just CrashAfterContextStageCreation
                }
          crashed @?= AcquireFailed "backend-process"
          contents <- strictReadFile (backendRecordPath harness)
          recordField "state" contents @?= Just "home-ready"
          nonce <- requireRecordNonce contents
          let contextStage = backendRecordPath harness ++ ".docker." ++ nonce ++ ".stage"
          staged <- doesDirectoryExist contextStage
          assertBool "the exact empty context stage survived the killed backend" staged
          recovered <- runAcquireBackend (acquireRequest harness)
          assertBool "the same invocation recovered the empty context stage" (ownedAcquire recovered)
          events <- backendEvents harness
          length (filter (isPrefixOf "start ") events) @?= 1,
      testCase "an exact rerun retains the same owner, nonce, and epoch without restarting" $
        onOwnershipHost $ withBackendHarness "exact-rerun" $ \harness -> do
          receipt <- acquireReceipt harness
          second <- runAcquireBackend (acquireRequest harness)
          case second of
            AcquireExact owner nonce machine context epoch lock record docker colima disk chain ->
              BackendReceipt owner nonce machine context epoch lock record docker colima disk chain @?= receipt
            other -> assertFailure ("expected an exact backend receipt, got " ++ show other)
          events <- backendEvents harness
          length (filter (isPrefixOf "start ") events) @?= 1
          assertBool "the first receipt was populated" (receiptNonce receipt /= ""),
      testCase "two acquirers share one profile lock and perform only one start" $
        onOwnershipHost $ withBackendHarness "acquire-exclusion" $ \harness -> do
          firstCompletion <- newEmptyMVar
          secondCompletion <- newEmptyMVar
          _ <- forkIO $ runAcquireBackend (acquireRequest harness) >>= putMVar firstCompletion
          _ <- forkIO $ runAcquireBackend (acquireRequest harness) >>= putMVar secondCompletion
          firstResult <- takeMVarWithin "first acquisition" firstCompletion
          secondResult <- takeMVarWithin "second acquisition" secondCompletion
          assertBool "both serialized acquisitions returned owned authority" (ownedAcquire firstResult && ownedAcquire secondResult)
          events <- backendEvents harness
          length (filter (isPrefixOf "start ") events) @?= 1,
      testCase "hard backend death retains the profile flock until its descendant group is gone" $
        onOwnershipHost $ withBackendHarness "hard-death-lock" $ \harness -> do
          writeMarker harness "block-start" ""
          firstCompletion <- newEmptyMVar
          _ <-
            forkIO $
              runAcquireBackend
                (acquireRequest harness)
                  { acquireTestingCrashPoint = Just CrashWhileStartRunning
                  }
                >>= putMVar firstCompletion
          waitForMarker harness "start-descendant-pid"
          descendantPid <- readPidFile harness "start-descendant-pid"
          waitForMarker harness "backend-killed"
          removeMarker harness "block-start"
          secondCompletion <- newEmptyMVar
          _ <- forkIO $ runAcquireBackend (acquireRequest harness) >>= putMVar secondCompletion
          threadDelay 25000
          enteredBeforeQuiescence <- isJust <$> tryReadMVar secondCompletion
          assertBool "a competing owner stayed outside while the old descendant held the inherited flock" (not enteredBeforeQuiescence)
          waitForPidGone (backendPythonPath harness) descendantPid
          firstResult <- takeMVarWithin "hard-dead acquisition" firstCompletion
          firstResult @?= AcquireFailed "backend-process"
          secondResult <- takeMVarWithin "post-death acquisition" secondCompletion
          assertBool "the serialized replacement acquired only after child-group quiescence" (ownedAcquire secondResult),
      testCase "a pre-existing unbound provider namespace is refused before mutation" $
        onOwnershipHost $ withBackendHarness "foreign-profile" $ \harness -> do
          let home = namespaceColimaHome (backendNamespace harness)
          createDirectoryIfMissing True (home </> "cache")
          createDirectoryIfMissing True (home </> "tmp")
          createDirectoryIfMissing True (home </> "_lima")
          result <- runAcquireBackend (acquireRequest harness)
          result @?= AcquireConflict "namespace-present"
          recordPresent <- doesFileExist (backendRecordPath harness)
          assertBool "unbound namespace creates no record" (not recordPresent)
          events <- backendEvents harness
          assertBool "unbound namespace was not started" (null (filter (isPrefixOf "start ") events)),
      testCase "a record bound to another exact owner is rejected" $
        onOwnershipHost $ withBackendHarness "owner-mismatch" $ \harness -> do
          _ <- acquireReceipt harness
          before <- backendEvents harness
          result <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireExpectedOwner = otherOwnerToken
                }
          case result of
            AcquireConflict _ -> pure ()
            other -> assertFailure ("expected changed-owner conflict, got " ++ show other)
          after <- backendEvents harness
          after @?= before,
      testCase "a failed start leaves a canonical prepared record and retries the same nonce" $
        onOwnershipHost $ withBackendHarness "failed-start" $ \harness -> do
          writeMarker harness "fail-start" ""
          firstResult <- runAcquireBackend (acquireRequest harness)
          firstResult @?= AcquireFailed "start"
          prepared <- strictReadFile (backendRecordPath harness)
          nonce <- requireRecordNonce prepared
          recordField "state" prepared @?= Just "prepared"
          recordField "owner" prepared @?= Just ownerToken
          removeMarker harness "fail-start"
          recovered <- acquireReceipt harness
          receiptOwner recovered @?= ownerToken
          receiptNonce recovered @?= nonce,
      testCase "a crash after start remains outcome-unknown without a managed stage" $
        onOwnershipHost $ withBackendHarness "crash-recovery" $ \harness -> do
          firstResult <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireTestingCrashPoint = Just CrashAfterStartBeforeSettlement
                }
          firstResult @?= AcquireFailed "backend-process"
          prepared <- strictReadFile (backendRecordPath harness)
          nonce <- requireRecordNonce prepared
          profilePresent <- markerPresent harness "present"
          assertBool "the unknown start outcome really created the profile" profilePresent
          secondResult <- runAcquireBackend (acquireRequest harness)
          secondResult @?= AcquireConflict "prepared-profile-present"
          retained <- strictReadFile (backendRecordPath harness)
          recordField "state" retained @?= Just "prepared"
          recordField "nonce" retained @?= Just nonce,
      testCase "a changed invocation cannot adopt an unknown start outcome" $
        onOwnershipHost $ withBackendHarness "crash-replay" $ \harness -> do
          firstResult <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireTestingCrashPoint = Just CrashAfterStartBeforeSettlement
                }
          firstResult @?= AcquireFailed "backend-process"
          before <- backendEvents harness
          secondResult <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireInvocationDigest = replicate 64 'c'
                }
          case secondResult of
            AcquireConflict _ -> pure ()
            other -> assertFailure ("expected changed-invocation conflict, got " ++ show other)
          after <- backendEvents harness
          after @?= before,
      testCase "a symlinked origin record fails no-follow validation before mutation" $
        onOwnershipHost $ withBackendHarness "record-symlink" $ \harness -> do
          ensureOriginDirectory harness
          let target = backendDirectory harness </> "foreign-origin"
          writeFile target "foreign-origin\n"
          createFileLink target (backendRecordPath harness)
          result <- runAcquireBackend (acquireRequest harness)
          result @?= AcquireConflict "record-open"
          targetContents <- strictReadFile target
          targetContents @?= "foreign-origin\n"
          present <- markerPresent harness "present"
          assertBool "record symlink was refused before start" (not present),
      testCase "a symlinked lock cannot redirect profile exclusion" $
        onOwnershipHost $ withBackendHarness "lock-symlink" $ \harness -> do
          let target = backendDirectory harness </> "foreign-lock"
          writeFile target "foreign-lock\n"
          createFileLink target (backendLockPath harness)
          result <- runAcquireBackend (acquireRequest harness)
          case result of
            AcquireConflict _ -> pure ()
            other -> assertFailure ("expected symlink-lock conflict, got " ++ show other)
          targetContents <- strictReadFile target
          targetContents @?= "foreign-lock\n"
          present <- markerPresent harness "present"
          assertBool "lock symlink was refused before start" (not present),
      testCase "a foreign stage-shaped file is retained and blocks recovery" $
        onOwnershipHost $ withBackendHarness "foreign-stage" $ \harness -> do
          ensureOriginDirectory harness
          let nonce = replicate 64 'b'
              stage = backendRecordPath harness ++ ".prepared." ++ nonce ++ ".stage"
          writeFile stage "foreign-stage"
          setMode600 harness stage
          result <- runAcquireBackend (acquireRequest harness)
          result @?= AcquireConflict "stage-content"
          stagePresent <- doesFileExist stage
          assertBool "foreign stage evidence was not erased" stagePresent
          present <- markerPresent harness "present"
          assertBool "foreign stage blocked mutation" (not present),
      testCase "cleanup validates owner, nonce, and epoch under the same lock and removes the record" $
        onOwnershipHost $ withBackendHarness "cleanup" $ \harness -> do
          receipt <- acquireReceipt harness
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          cleanup @?= CleanupDeleted
          profilePresent <- markerPresent harness "present"
          recordPresent <- doesFileExist (backendRecordPath harness)
          assertBool "cleanup deleted the profile" (not profilePresent)
          assertBool "cleanup durably removed the record" (not recordPresent)
          events <- backendEvents harness
          assertBool "destroy semantics explicitly remove persistent data" (any (isInfixOf "delete --profile" ) events && any (isSuffixOf "--force --data") events),
      testCase "cleanup accepts Colima removing its exact context and releases socket/symlink state" $
        onOwnershipHost $ withBackendHarness "cleanup-context" $ \harness -> do
          writeMarker harness "runtime-specials" ""
          writeMarker harness "delete-removes-context" ""
          receipt <- acquireReceipt harness
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          cleanup @?= CleanupDeleted
          homePresent <- doesDirectoryExist (namespaceColimaHome (backendNamespace harness))
          dockerPresent <- doesDirectoryExist (namespaceDockerConfig (backendNamespace harness))
          assertBool "exact Colima namespace was removed" (not homePresent)
          assertBool "exact Docker namespace was removed" (not dockerPresent),
      testCase "released-marker publication recovers the exact anchor and permits a later invocation" $
        onOwnershipHost $ withBackendHarness "released-marker-crash" $ \harness -> do
          receipt <- acquireReceipt harness
          crashed <-
            runCleanupBackend
              (cleanupRequest harness receipt)
                { cleanupTestingCrashPoint = Just CrashAfterReleasedMarkerPublication
                }
          crashed @?= CleanupFailed "backend-process"
          canonicalPresent <- doesFileExist (backendRecordPath harness)
          markerPresentAfterCrash <- doesFileExist (backendRecordPath harness ++ ".released")
          assertBool "released publication removed the canonical record" (not canonicalPresent)
          assertBool "the exact released marker survived the crash" markerPresentAfterCrash
          stagesAfterCrash <- stageEntries harness
          assertBool "the reserved lineage anchor survives until recovery" (any (isInfixOf ".reserved.") stagesAfterCrash)
          replayed <- runCleanupBackend (cleanupRequest harness receipt)
          replayed @?= CleanupReleased
          stagesAfterReplay <- stageEntries harness
          assertBool "released replay conditionally removed the exact anchor" (not (any (isInfixOf ".reserved.") stagesAfterReplay))
          reacquired <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireInvocationDigest = replicate 64 'c'
                }
          assertBool "a new invocation reused the synchronization-only lock after exact release" (ownedAcquire reacquired),
      testCase "a same-name machine replacement is refused before delete" $
        onOwnershipHost $ withBackendHarness "machine-replacement" $ \harness -> do
          receipt <- acquireReceipt harness
          writeMarker harness "machine" "fedcba9876543210fedcba9876543210\n"
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          case cleanup of
            CleanupConflict reason ->
              assertBool "the conflict names identity" (isPrefixOf "identity-" reason)
            other -> assertFailure ("expected identity conflict, got " ++ show other)
          events <- backendEvents harness
          assertBool "replacement refusal never called delete" (null (filter (isPrefixOf "delete ") events))
          present <- markerPresent harness "present"
          assertBool "replacement remains present" present,
      testCase "a failed delete retains releasing evidence and retries safely" $
        onOwnershipHost $ withBackendHarness "failed-delete" $ \harness -> do
          receipt <- acquireReceipt harness
          writeMarker harness "fail-delete" ""
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          cleanup @?= CleanupFailed "delete"
          profilePresent <- markerPresent harness "present"
          recordPresent <- doesFileExist (backendRecordPath harness)
          assertBool "failed delete retains profile" profilePresent
          assertBool "failed delete retains record" recordPresent
          record <- strictReadFile (backendRecordPath harness)
          recordField "state" record @?= Just "releasing"
          removeMarker harness "fail-delete"
          retried <- runCleanupBackend (cleanupRequest harness receipt)
          retried @?= CleanupDeleted,
      testCase "a different teardown invocation cannot adopt an interrupted delete" $
        onOwnershipHost $ withBackendHarness "cleanup-replay" $ \harness -> do
          receipt <- acquireReceipt harness
          writeMarker harness "fail-delete" ""
          firstResult <- runCleanupBackend (cleanupRequest harness receipt)
          firstResult @?= CleanupFailed "delete"
          removeMarker harness "fail-delete"
          replayed <-
            runCleanupBackend
              (cleanupRequest harness receipt)
                { cleanupInvocationDigest = replicate 64 'd'
                }
          replayed @?= CleanupConflict "teardown-invocation"
          present <- markerPresent harness "present"
          assertBool "changed cleanup invocation left the profile intact" present,
      testCase "a byte-identical data disk on a replacement inode cannot authorize delete" $
        onOwnershipHost $ withBackendHarness "disk-replacement" $ \harness -> do
          receipt <- acquireReceipt harness
          replaceSparseFile
            harness
            (namespaceLimaHome (backendNamespace harness) </> "_disks" </> ("colima-" ++ profileName) </> "datadisk")
            (80 * gib)
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          cleanup @?= CleanupConflict "disk-identity"
          events <- backendEvents harness
          assertBool "disk replacement refusal called no delete" (null (filter (isPrefixOf "delete ") events)),
      testCase "cleanup never recreates a missing state subtree" $
        onOwnershipHost $ withBackendHarness "state-missing" $ \harness -> do
          receipt <- acquireReceipt harness
          let state = backendStateRoot harness </> ".hostbootstrap"
              moved = backendStateRoot harness </> ".hostbootstrap-moved"
          renameDirectory state moved
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          cleanup @?= CleanupConflict "state-directory"
          recreated <- doesDirectoryExist state
          assertBool "cleanup did not recreate the missing state directory" (not recreated)
          events <- backendEvents harness
          assertBool "missing state failed before delete" (null (filter (isPrefixOf "delete ") events)),
      testCase "cleanup never unlinks a record path replaced during delete" $
        onOwnershipHost $ withBackendHarness "record-replacement" $ \harness -> do
          receipt <- acquireReceipt harness
          writeMarker harness "swap-record-on-delete" (backendRecordPath harness)
          cleanup <- runCleanupBackend (cleanupRequest harness receipt)
          case cleanup of
            CleanupConflict _ -> pure ()
            other -> assertFailure ("expected retained-descriptor conflict, got " ++ show other)
          replacement <- strictReadFile (backendRecordPath harness)
          replacement @?= "foreign-record\n",
      testCase "acquisition cannot enter while cleanup owns the same descriptor lock" $
        onOwnershipHost $ withBackendHarness "lock-exclusion" $ \harness -> do
          firstReceipt <- acquireReceipt harness
          writeMarker harness "block-delete" ""
          cleanupResult <- newEmptyMVar
          _ <- forkIO $ runCleanupBackend (cleanupRequest harness firstReceipt) >>= putMVar cleanupResult
          waitForMarker harness "delete-entered"
          acquireResult <- newEmptyMVar
          _ <- forkIO $ runAcquireBackend (acquireRequest harness) >>= putMVar acquireResult
          threadDelay 200000
          enteredEarly <- maybe False (const True) <$> tryReadMVar acquireResult
          assertBool "acquisition stayed outside the cleanup bracket" (not enteredEarly)
          writeMarker harness "allow-delete" ""
          cleanup <- takeMVarWithin "cleanup" cleanupResult
          cleanup @?= CleanupDeleted
          reacquired <- takeMVarWithin "acquisition" acquireResult
          reacquired @?= AcquireConflict "invocation-released",
      testCase "every Colima subprocess is bounded and timeout failure retains ownership evidence" $
        onOwnershipHost $ withBackendHarness "timeouts" $ \harness -> do
          writeMarker harness "hang-list" ""
          acquire <- runAcquireBackend (acquireRequest harness) {acquireCommandTimeoutSeconds = 1}
          acquire @?= AcquireFailed "timeout-list"
          removeMarker harness "hang-list"
          receipt <- acquireReceipt harness
          writeMarker harness "block-delete" ""
          cleanup <-
            runCleanupBackend
              (cleanupRequest harness receipt)
                { cleanupCommandTimeoutSeconds = 1
                }
          cleanup @?= CleanupFailed "timeout-delete"
          profilePresent <- markerPresent harness "present"
          recordPresent <- doesFileExist (backendRecordPath harness)
          assertBool "timed-out delete retains profile" profilePresent
          assertBool "timed-out delete retains record" recordPresent,
      testCase "an owned stopped profile cannot be re-adopted without stable identity" $
        onOwnershipHost $ withBackendHarness "stopped-owned" $ \harness -> do
          _ <- acquireReceipt harness
          writeMarker harness "status" "Stopped"
          result <- runAcquireBackend (acquireRequest harness)
          result @?= AcquireUnsupported "stable-identity"
          events <- backendEvents harness
          length (filter (isPrefixOf "start ") events) @?= 1,
      testCase "malformed provider output fails closed as data" $
        onOwnershipHost $ withBackendHarness "malformed-list" $ \harness -> do
          writeMarker harness "malformed-list" ""
          result <- runAcquireBackend (acquireRequest harness)
          result @?= AcquireFailed "list-decode",
      testCase "failed, blank, and duplicate total profile observations refuse mutation" $
        onOwnershipHost $ do
          let check marker expected =
                withBackendHarness ("strict-" ++ marker) $ \harness -> do
                  writeMarker harness marker ""
                  result <- runAcquireBackend (acquireRequest harness)
                  result @?= expected
                  events <- backendEvents harness
                  assertBool "strict observation failed before start" (null (filter (isPrefixOf "start ") events))
          check "list-exit" (AcquireFailed "list")
          check "blank-list" (AcquireFailed "list-framing")
          check "duplicate-list" (AcquireConflict "list-duplicate"),
      testCase "failed and blank Lima disk observations refuse mutation" $
        onOwnershipHost $ do
          let check marker expected =
                withBackendHarness ("strict-" ++ marker) $ \harness -> do
                  writeMarker harness marker ""
                  result <- runAcquireBackend (acquireRequest harness)
                  result @?= expected
                  events <- backendEvents harness
                  assertBool "strict disk observation failed before start" (null (filter (isPrefixOf "start ") events))
          check "disk-list-exit" (AcquireFailed "disk-list")
          check "blank-disk-list" (AcquireFailed "disk-list-framing"),
      testCase "a hidden profile artifact appearing after prepare blocks retry" $
        onOwnershipHost $ withBackendHarness "hidden-profile" $ \harness -> do
          writeMarker harness "fail-start" ""
          firstResult <- runAcquireBackend (acquireRequest harness)
          firstResult @?= AcquireFailed "start"
          createDirectoryIfMissing True (namespaceColimaHome (backendNamespace harness) </> profileName)
          removeMarker harness "fail-start"
          secondResult <- runAcquireBackend (acquireRequest harness)
          secondResult @?= AcquireConflict "residual-profile-data"
          events <- backendEvents harness
          length (filter (isPrefixOf "start ") events) @?= 1,
      testCase "live Docker uses the retained route and rejects all caller route/config mutations" $
        onOwnershipHost $ withBackendHarness "live-docker" $ \harness -> do
          receipt <- acquireReceipt harness
          completed <- runLiveDockerBackend (liveDockerRequest harness receipt ["info"])
          completed @?= LiveDockerCompleted ExitSuccess "docker-ok\n" ""
          let rejects =
                [ ["info", "--context=foreign"],
                  ["info", "--host=tcp://foreign"],
                  ["info", "--config=/foreign"],
                  ["info", "--tls=false"],
                  ["info", "--tlsverify=false"],
                  ["context", "rm", "colima-" ++ profileName]
                ]
          mapM_
            ( \arguments -> do
                refused <- runLiveDockerBackend (liveDockerRequest harness receipt arguments)
                case refused of
                  LiveDockerConflict _ -> pure ()
                  other -> assertFailure ("expected routed Docker refusal, got " ++ show other)
            )
            rejects
          mutated <- markerPresent harness "context-mutated"
          assertBool "rejected Docker commands had no effect" (not mutated),
      testCase "the bounded runner quiesces descendants after a successful leader exit" $
        onOwnershipHost $ withBackendHarness "runner-leader-exit" $ \harness -> do
          prepareRunnerNamespace harness
          let pidPath = backendDirectory harness </> "runner-descendant-pid"
          result <-
            runBoundedTool
              3
              (backendNamespace harness)
              (backendPythonPath harness)
              (backendPythonPath harness)
              ["-c", descendantProgram True, pidPath]
          result @?= BoundedToolCompleted ExitSuccess "" ""
          pid <- readPidFile harness "runner-descendant-pid"
          waitForPidGone (backendPythonPath harness) pid,
      testCase "the bounded runner kills a descendant that retains both pipes" $
        onOwnershipHost $ withBackendHarness "runner-retained-pipes" $ \harness -> do
          prepareRunnerNamespace harness
          let pidPath = backendDirectory harness </> "runner-descendant-pid"
          result <-
            runBoundedTool
              1
              (backendNamespace harness)
              (backendPythonPath harness)
              (backendPythonPath harness)
              ["-c", descendantProgram False, pidPath]
          result @?= BoundedToolTimedOut
          pid <- readPidFile harness "runner-descendant-pid"
          waitForPidGone (backendPythonPath harness) pid,
      testCase "the bounded runner preserves async cancellation after killing its process group" $
        onOwnershipHost $ withBackendHarness "runner-async" $ \harness -> do
          prepareRunnerNamespace harness
          let pidPath = backendDirectory harness </> "runner-leader-pid"
              program =
                "import os,signal,sys,time; "
                  ++ "open(sys.argv[1],'w').write(str(os.getpid())); "
                  ++ "signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"
          completed <- newEmptyMVar
          worker <-
            forkIO $ do
              attempted <-
                try
                  ( runBoundedTool
                      30
                      (backendNamespace harness)
                      (backendPythonPath harness)
                      (backendPythonPath harness)
                      ["-c", program, pidPath]
                  ) :: IO (Either SomeException BoundedToolResult)
              putMVar completed attempted
          waitForMarker harness "runner-leader-pid"
          pid <- readPidFile harness "runner-leader-pid"
          killThread worker
          attempted <- takeMVarWithin "runner cancellation" completed
          case attempted of
            Left err ->
              assertBool
                "runner propagated the asynchronous exception"
                (isJust (fromException err :: Maybe SomeAsyncException))
            Right other -> assertFailure ("runner swallowed cancellation as " ++ show other)
          waitForPidGone (backendPythonPath harness) pid,
      testCase "the bounded runner caps captured output and kills the producer" $
        onOwnershipHost $ withBackendHarness "runner-output-limit" $ \harness -> do
          prepareRunnerNamespace harness
          result <-
            runBoundedTool
              1
              (backendNamespace harness)
              (backendPythonPath harness)
              (backendPythonPath harness)
              ["-c", "import sys; sys.stdout.write('x'*(17*1024*1024)); sys.stdout.flush()"]
          result @?= BoundedToolFailed "output-limit",
      testCase "owner grammar, timeout bounds, and process exceptions fail structurally" $
        onOwnershipHost $ withBackendHarness "closed-errors" $ \harness -> do
          invalidOwner <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireExpectedOwner = "not-an-owner"
                }
          invalidOwner @?= AcquireUnsupported "owner-token"
          invalidTimeout <-
            runAcquireBackend
              (acquireRequest harness)
                { acquireCommandTimeoutSeconds = 121
                }
          invalidTimeout @?= AcquireUnsupported "command-timeout"
          processFailure <-
            runAcquireBackend
              (acquireRequest harness)
                { acquirePythonPath = backendDirectory harness </> "missing-python"
                }
          processFailure @?= AcquireFailed "backend-exception"
    ]

data ResolverHarness = ResolverHarness
  { resolverHarnessLayout :: ResolverFixtureLayout,
    resolverHarnessProgram :: String,
    resolverHarnessPython :: FilePath,
    resolverHarnessNamespace :: BackendNamespace
  }

withResolverHarness :: String -> (ResolverHarness -> IO a) -> IO a
withResolverHarness label action =
  withSystemTempDirectory ("hostbootstrap-colima-resolver-" ++ label) $ \root ->
    setupResolverHarness root >>= action

setupResolverHarness :: FilePath -> IO ResolverHarness
setupResolverHarness root = do
  python <- requireExecutable "python3" =<< findExecutable "python3"
  let layout = resolverFixtureLayout root
      ambient = root </> "ambient"
      namespace =
        BackendNamespace
          { namespaceHomeDirectory = ambient </> "home",
            namespaceColimaHome = ambient </> "colima",
            namespaceLimaHome = ambient </> "lima",
            namespaceColimaCacheHome = ambient </> "cache",
            namespaceTemporaryDirectory = ambient </> "tmp",
            namespaceDockerConfig = ambient </> "docker",
            namespaceWorkingDirectory = ambient </> "cwd",
            namespaceExecutablePath = ambient </> "bin"
          }
      directories =
        [ resolverFixtureHome layout,
          takeDirectory (resolverFixturePython layout),
          takeDirectory (resolverFixtureBrew layout),
          takeDirectory (resolverFixtureColimaTarget layout),
          takeDirectory (resolverFixtureDockerTarget layout),
          takeDirectory (resolverFixtureLimaTarget layout),
          takeDirectory (resolverFixtureDockerApp layout),
          namespaceHomeDirectory namespace,
          namespaceColimaHome namespace,
          namespaceLimaHome namespace,
          namespaceColimaCacheHome namespace,
          namespaceTemporaryDirectory namespace,
          namespaceDockerConfig namespace,
          namespaceWorkingDirectory namespace,
          namespaceExecutablePath namespace
        ]
          ++ resolverFixtureSystemHelpers layout
  mapM_ (createDirectoryIfMissing True) directories
  mapM_
    writeResolverTool
    [ resolverFixturePython layout,
      resolverFixtureBrew layout,
      resolverFixtureColimaTarget layout,
      resolverFixtureDockerTarget layout,
      resolverFixtureLimaTarget layout,
      resolverFixtureDockerApp layout
    ]
  createFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
  createFileLink (resolverFixtureDockerTarget layout) (resolverFixtureDockerAlias layout)
  createFileLink (resolverFixtureLimaTarget layout) (resolverFixtureLimaAlias layout)
  program <- either assertFailure pure (resolverFixtureProgram root)
  pure
    ResolverHarness
      { resolverHarnessLayout = layout,
        resolverHarnessProgram = program,
        resolverHarnessPython = python,
        resolverHarnessNamespace = namespace
      }

withShortResolverHarness :: (ResolverHarness -> FilePath -> FilePath -> IO a) -> IO a
#if defined(mingw32_HOST_OS)
withShortResolverHarness _ = fail "the direct-Colima resolver fixture requires a Unix host"
#else
withShortResolverHarness action =
  bracket createShortFixtureRoot removePathForcibly $ \root -> do
    harness <- setupResolverHarness root
    let effectiveHome = root </> "u"
    createDirectory effectiveHome
    setFileMode effectiveHome 0o700
    program <- either assertFailure pure (resolverFixtureProgramForHomeRoot root root)
    let configured = harness {resolverHarnessProgram = program}
    markerRoot <- preparePublicFlowTools configured
    action configured effectiveHome markerRoot

createShortFixtureRoot :: IO FilePath
createShortFixtureRoot = do
  process <- fromIntegral <$> getProcessID
  let base = if os == "darwin" then "/private/tmp" else "/tmp"
      candidates =
        [ base </> ("h" ++ fixedHex ((process + attempt) `mod` 0x10000))
          | attempt <- [0 .. 255 :: Integer]
        ]
  createFirst candidates
  where
    fixedHex value =
      let rendered = showHex value ""
       in replicate (4 - length rendered) '0' ++ rendered
    createFirst [] = fail "could not allocate a short direct-Colima fixture root"
    createFirst (candidate : remaining) = do
      created <- try (createDirectory candidate) :: IO (Either IOException ())
      case created of
        Left _ -> createFirst remaining
        Right () -> setFileMode candidate 0o700 >> pure candidate
#endif

#if !defined(mingw32_HOST_OS)
preparePublicFlowTools :: ResolverHarness -> IO FilePath
preparePublicFlowTools harness = do
  let layout = resolverHarnessLayout harness
      markerRoot = resolverFixtureRoot layout </> "markers"
      python = resolverFixturePython layout
      sharedColima = markerRoot </> "fake-colima.py"
      sharedDocker = markerRoot </> "fake-docker.py"
      sharedLima = markerRoot </> "fake-lima.py"
  createDirectory markerRoot
  copyFile (resolverHarnessPython harness) python
  makeExecutable python
  writeFile sharedColima fakeColimaProgram
  writeFile sharedDocker fakeDockerProgram
  writeFile sharedLima fakeLimaProgram
  mapM_
    ( \(target, script) -> do
        writeFile target (pythonToolWrapper python script)
        makeExecutable target
    )
    [ (resolverFixtureColimaTarget layout, sharedColima),
      (resolverFixtureDockerTarget layout, sharedDocker),
      (resolverFixtureLimaTarget layout, sharedLima)
    ]
  pure markerRoot

pythonToolWrapper :: FilePath -> FilePath -> String
pythonToolWrapper python script =
  unlines
    [ "#!" ++ python,
      "import os,sys",
      "os.execv(" ++ show python ++ ",[" ++ show python ++ "," ++ show script ++ "]+sys.argv[1:])"
    ]
#endif

resolverExecutionFixture :: BoundedToolResult -> ResolverExecutionFixture
resolverExecutionFixture result = case result of
  BoundedToolCompleted exitCode output errors -> ResolverExecutionCompleted exitCode output errors
  BoundedToolTimedOut -> ResolverExecutionTimedOut
  BoundedToolFailed reason -> ResolverExecutionFailed reason

assertDestroyedProvider ::
  Text.Text ->
  PhaseAdvance scope planId providerResourceId ProviderResource Destroyed ->
  IO ()
assertDestroyedProvider expectedOperation advance =
  withPhaseAdvance advance $ \handle receipt _verified -> do
    resourceHandleGeneration handle @?= 17
    resourceHandleObservationVersion handle @?= 8
    assertBool
      "the force-destroy receipt remains rooted in the exact provider operation"
      ((expectedOperation <> ":") `Text.isPrefixOf` ownershipReceiptOperationKey receipt)

writeResolverTool :: FilePath -> IO ()
writeResolverTool path = do
  writeFile path "#!/bin/sh\nexit 0\n"
  makeExecutable path

executeResolverFixture :: ResolverHarness -> IO BoundedToolResult
executeResolverFixture harness =
  executeResolverFixtureAt harness (resolverFixtureHome (resolverHarnessLayout harness))

executeResolverFixtureAt :: ResolverHarness -> FilePath -> IO BoundedToolResult
executeResolverFixtureAt harness effectiveHome =
  runBoundedTool
    5
    (resolverHarnessNamespace harness)
    (resolverHarnessPython harness)
    (resolverHarnessPython harness)
    [ "-I",
      "-S",
      "-c",
      resolverHarnessProgram harness,
      effectiveHome
    ]

requireReadyResolver :: ResolverHarness -> BoundedToolResult -> IO (String, ResolverProtocolView)
requireReadyResolver harness execution =
  case execution of
    BoundedToolCompleted ExitSuccess output "" -> do
      protocol <-
        either
          (assertFailure . ("fixture resolver report failed strict decoding: " ++))
          pure
          (parseResolverFixtureProtocolView (resolverFixtureRoot (resolverHarnessLayout harness)) output)
      case parseResolverProtocolView output of
        Left _ -> pure ()
        Right _ -> assertFailure "the production-layout parser accepted fixture-root authority"
      case protocol of
        ResolverProtocolReadyView {} -> pure (output, protocol)
        other -> assertFailure ("expected ready fixture resolver, got " ++ show other)
    other -> assertFailure ("expected a successful fixture resolver, got " ++ show other)

requireUnsupportedResolver :: ResolverHarness -> BoundedToolResult -> String -> IO ()
requireUnsupportedResolver harness execution reason =
  case execution of
    BoundedToolCompleted ExitSuccess output "" ->
      parseResolverFixtureProtocolView (resolverFixtureRoot (resolverHarnessLayout harness)) output
        @?= Right (ResolverProtocolUnsupportedView reason)
    other -> assertFailure ("expected a structured unsupported resolver report, got " ++ show other)

assertResolverRejected :: FilePath -> String -> IO ()
assertResolverRejected root output =
  case parseResolverFixtureProtocolView root output of
    Left _ -> pure ()
    Right value -> assertFailure ("malformed resolver report was accepted as " ++ show value)

resolverFingerprint :: ResolverProtocolView -> String
resolverFingerprint protocol = case protocol of
  ResolverProtocolReadyView _ _ _ _ _ fingerprint -> fingerprint
  ResolverProtocolMissingColimaView _ _ _ fingerprint -> fingerprint
  ResolverProtocolUnsupportedView reason -> "unsupported:" ++ reason

resolverPythonIdentity :: ResolverProtocolView -> (Word64, Word64)
resolverPythonIdentity protocol = case protocol of
  ResolverProtocolReadyView (ResolverToolView _ device inode) _ _ _ _ _ -> (device, inode)
  ResolverProtocolMissingColimaView (ResolverToolView _ device inode) _ _ _ -> (device, inode)
  ResolverProtocolUnsupportedView reason -> error ("unsupported resolver has no Python identity: " ++ reason)

isReadyProtocol :: ResolverProtocolView -> Bool
isReadyProtocol ResolverProtocolReadyView {} = True
isReadyProtocol _ = False

chmodPath :: ResolverHarness -> FilePath -> String -> IO ()
chmodPath harness path mode = do
  (exitCode, _out, errOut) <-
    readProcessWithExitCode
      (resolverHarnessPython harness)
      ["-c", "import os,sys; os.chmod(sys.argv[1],int(sys.argv[2],8))", path, mode]
      ""
  case exitCode of
    ExitSuccess -> pure ()
    _ -> assertFailure ("fixture chmod failed: " ++ errOut)

data BackendHarness = BackendHarness
  { backendDirectory :: FilePath,
    backendPythonPath :: FilePath,
    backendColimaPath :: FilePath,
    backendDockerPath :: FilePath,
    backendLimaPath :: FilePath,
    backendLockPath :: FilePath,
    backendStateRoot :: FilePath,
    backendRecordPath :: FilePath
  }

data BackendReceipt = BackendReceipt
  { receiptOwner :: String,
    receiptNonce :: String,
    receiptMachine :: String,
    receiptContext :: String,
    receiptEpoch :: Word64,
    receiptLock :: BackendIdentity,
    receiptRecord :: BackendIdentity,
    receiptDocker :: BackendIdentity,
    receiptColima :: BackendIdentity,
    receiptDisk :: BackendIdentity,
    receiptChain :: BackendDirectoryChain
  }
  deriving (Eq, Show)

withBackendHarness :: String -> (BackendHarness -> IO a) -> IO a
withBackendHarness label action =
  withSystemTempDirectory ("hostbootstrap-colima-" ++ label) $ \directory ->
    setupBackendHarness directory >>= action

setupBackendHarness :: FilePath -> IO BackendHarness
setupBackendHarness directory = do
  python <- requireExecutable "python3" =<< findExecutable "python3"
  let colima = directory </> "fake-colima"
      docker = directory </> "docker"
      lima = directory </> "limactl"
      stateRoot = directory </> "plan-root"
      record = stateRoot </> ".hostbootstrap" </> "colima" </> "provider.origin"
      lock = directory </> "profile.lock"
  writeFile colima fakeColimaProgram
  writeFile docker fakeDockerProgram
  writeFile lima fakeLimaProgram
  makeExecutable colima
  makeExecutable docker
  makeExecutable lima
  createDirectoryIfMissing True stateRoot
  pure
    BackendHarness
      { backendDirectory = directory,
        backendPythonPath = python,
        backendColimaPath = colima,
        backendDockerPath = docker,
        backendLimaPath = lima,
        backendLockPath = lock,
        backendStateRoot = stateRoot,
        backendRecordPath = record
      }

makeExecutable :: FilePath -> IO ()
makeExecutable path = do
  permissions <- getPermissions path
  setPermissions path permissions {executable = True}

backendNamespace :: BackendHarness -> BackendNamespace
backendNamespace harness =
  BackendNamespace
    { namespaceHomeDirectory = backendDirectory harness,
      namespaceColimaHome = backendDirectory harness </> (".h" ++ namespaceKey),
      namespaceLimaHome = backendDirectory harness </> (".h" ++ namespaceKey) </> "_lima",
      namespaceColimaCacheHome = backendDirectory harness </> (".h" ++ namespaceKey) </> "cache",
      namespaceTemporaryDirectory = backendDirectory harness </> (".h" ++ namespaceKey) </> "tmp",
      namespaceDockerConfig = backendRecordPath harness ++ ".docker",
      namespaceWorkingDirectory = backendDirectory harness,
      namespaceExecutablePath =
        intercalate
          [searchPathSeparator]
          (nub [backendDirectory harness, takeDirectory (backendPythonPath harness)])
    }

acquireRequest :: BackendHarness -> AcquireBackendRequest
acquireRequest harness =
  AcquireBackendRequest
    { acquirePythonPath = backendPythonPath harness,
      acquireColimaPath = backendColimaPath harness,
      acquireDockerPath = backendDockerPath harness,
      acquireLimaPath = backendLimaPath harness,
      acquireProfileName = profileName,
      acquireLockPath = backendLockPath harness,
      acquireStateRoot = backendStateRoot harness,
      acquireRecordPath = backendRecordPath harness,
      acquireNamespace = backendNamespace harness,
      acquireExpectedOwner = ownerToken,
      acquireInvocationDigest = acquireInvocation,
      acquireExpectedCpu = 8,
      acquireExpectedMemory = 16 * gib,
      acquireExpectedDisk = 80 * gib,
      acquireExpectedRootDisk = 20 * gib,
      acquireCommandTimeoutSeconds = 2,
      acquireTestingCrashPoint = Nothing,
      acquireStartArgs = canonicalStartArgs
    }

cleanupRequest :: BackendHarness -> BackendReceipt -> CleanupBackendRequest
cleanupRequest harness receipt =
  CleanupBackendRequest
    { cleanupPythonPath = backendPythonPath harness,
      cleanupColimaPath = backendColimaPath harness,
      cleanupDockerPath = backendDockerPath harness,
      cleanupLimaPath = backendLimaPath harness,
      cleanupProfileName = profileName,
      cleanupLockPath = backendLockPath harness,
      cleanupStateRoot = backendStateRoot harness,
      cleanupRecordPath = backendRecordPath harness,
      cleanupNamespace = backendNamespace harness,
      cleanupExpectedOwner = receiptOwner receipt,
      cleanupAcquireInvocationDigest = acquireInvocation,
      cleanupInvocationDigest = cleanupInvocation,
      cleanupNonce = receiptNonce receipt,
      cleanupExpectedMachineId = receiptMachine receipt,
      cleanupExpectedContextDigest = receiptContext receipt,
      cleanupExpectedCpu = 8,
      cleanupExpectedMemory = 16 * gib,
      cleanupExpectedDisk = 80 * gib,
      cleanupExpectedRootDisk = 20 * gib,
      cleanupExpectedLockIdentity = receiptLock receipt,
      cleanupExpectedRecordIdentity = receiptRecord receipt,
      cleanupExpectedDockerIdentity = receiptDocker receipt,
      cleanupExpectedColimaIdentity = receiptColima receipt,
      cleanupExpectedDiskIdentity = receiptDisk receipt,
      cleanupExpectedDirectoryChain = receiptChain receipt,
      cleanupCommandTimeoutSeconds = 2,
      cleanupExpectedEpoch = receiptEpoch receipt,
      cleanupTestingCrashPoint = Nothing
    }

liveDockerRequest :: BackendHarness -> BackendReceipt -> [String] -> LiveDockerBackendRequest
liveDockerRequest harness receipt arguments =
  LiveDockerBackendRequest
    { liveDockerPythonPath = backendPythonPath harness,
      liveDockerColimaPath = backendColimaPath harness,
      liveDockerExecutablePath = backendDockerPath harness,
      liveDockerLimaPath = backendLimaPath harness,
      liveDockerProfileName = profileName,
      liveDockerLockPath = backendLockPath harness,
      liveDockerStateRoot = backendStateRoot harness,
      liveDockerRecordPath = backendRecordPath harness,
      liveDockerNamespace = backendNamespace harness,
      liveDockerExpectedOwner = receiptOwner receipt,
      liveDockerInvocationDigest = acquireInvocation,
      liveDockerNonce = receiptNonce receipt,
      liveDockerExpectedMachineId = receiptMachine receipt,
      liveDockerExpectedContextDigest = receiptContext receipt,
      liveDockerExpectedCpu = 8,
      liveDockerExpectedMemory = 16 * gib,
      liveDockerExpectedDisk = 80 * gib,
      liveDockerExpectedRootDisk = 20 * gib,
      liveDockerExpectedLockIdentity = receiptLock receipt,
      liveDockerExpectedRecordIdentity = receiptRecord receipt,
      liveDockerExpectedDockerIdentity = receiptDocker receipt,
      liveDockerExpectedColimaIdentity = receiptColima receipt,
      liveDockerExpectedDiskIdentity = receiptDisk receipt,
      liveDockerExpectedDirectoryChain = receiptChain receipt,
      liveDockerCommandTimeoutSeconds = 2,
      liveDockerExpectedEpoch = receiptEpoch receipt,
      liveDockerArgs = arguments
    }

acquireReceipt :: BackendHarness -> IO BackendReceipt
acquireReceipt harness = do
  result <- runAcquireBackend (acquireRequest harness)
  case result of
    AcquireApplied owner nonce machine context epoch lock record docker colima disk chain ->
      pure (BackendReceipt owner nonce machine context epoch lock record docker colima disk chain)
    AcquireExact owner nonce machine context epoch lock record docker colima disk chain ->
      pure (BackendReceipt owner nonce machine context epoch lock record docker colima disk chain)
    other -> assertFailure ("expected a managed acquisition receipt, got " ++ show other)

ownedAcquire :: AcquireBackendResult -> Bool
ownedAcquire result = case result of
  AcquireApplied {} -> True
  AcquireExact {} -> True
  _ -> False

recordField :: String -> String -> Maybe String
recordField name contents =
  case [drop (length prefix) line | line <- lines contents, prefix `isPrefixOf` line] of
    [value] -> Just value
    _ -> Nothing
  where
    prefix = name ++ " "

requireRecordNonce :: String -> IO String
requireRecordNonce contents =
  case recordField "nonce" contents of
    Just nonce | length nonce == 64 -> pure nonce
    other -> assertFailure ("expected one canonical nonce, got " ++ show other)

ensureOriginDirectory :: BackendHarness -> IO ()
ensureOriginDirectory =
  createDirectoryIfMissing True . takeDirectory . backendRecordPath

stageEntries :: BackendHarness -> IO [FilePath]
stageEntries harness = do
  entries <- listDirectory (takeDirectory (backendRecordPath harness))
  pure (filter (isSuffixOf ".stage") entries)

setMode600 :: BackendHarness -> FilePath -> IO ()
setMode600 harness path = do
  (exitCode, _out, errOut) <-
    readProcessWithExitCode
      (backendPythonPath harness)
      ["-c", "import os,sys; os.chmod(sys.argv[1],0o600)", path]
      ""
  case exitCode of
    ExitSuccess -> pure ()
    _ -> assertFailure ("chmod failed: " ++ errOut)

writeMarker :: BackendHarness -> FilePath -> String -> IO ()
writeMarker harness name = writeFile (backendDirectory harness </> name)

removeMarker :: BackendHarness -> FilePath -> IO ()
removeMarker harness name = do
  let path = backendDirectory harness </> name
  present <- doesFileExist path
  if present then removeFile path else pure ()

markerPresent :: BackendHarness -> FilePath -> IO Bool
markerPresent harness name = doesFileExist (backendDirectory harness </> name)

backendEvents :: BackendHarness -> IO [String]
backendEvents harness = do
  let path = backendDirectory harness </> "events"
  present <- doesFileExist path
  if present then lines <$> strictReadFile path else pure []

replaceSparseFile :: BackendHarness -> FilePath -> Integer -> IO ()
replaceSparseFile harness path size = do
  (exitCode, _out, errOut) <-
    readProcessWithExitCode
      (backendPythonPath harness)
      [ "-c",
        "import os,sys; path=sys.argv[1]; replacement=path+'.replacement'; stream=open(replacement,'wb'); stream.truncate(int(sys.argv[2])); stream.close(); os.replace(replacement,path)",
        path,
        show size
      ]
      ""
  case exitCode of
    ExitSuccess -> pure ()
    _ -> assertFailure ("sparse replacement failed: " ++ errOut)

exactInstance :: String -> String -> ColimaInstance
exactInstance profile status =
  ColimaInstance profile status 8 (16 * gib) (80 * gib) "docker"

onOwnershipHost :: IO () -> IO ()
onOwnershipHost action = unless (os == "mingw32") action

strictReadFile :: FilePath -> IO String
strictReadFile path = do
  contents <- readFile path
  seq (length contents) (pure contents)

waitForMarker :: BackendHarness -> FilePath -> IO ()
waitForMarker harness name = do
  let path = backendDirectory harness </> name
  result <- timeout 5000000 loop
  case result of
    Just () -> pure ()
    Nothing -> assertFailure ("timed out waiting for " ++ path)
  where
    loop = do
      present <- markerPresent harness name
      if present then pure () else threadDelay 10000 >> loop

prepareRunnerNamespace :: BackendHarness -> IO ()
prepareRunnerNamespace harness =
  mapM_
    (createDirectoryIfMissing True)
    [ namespaceColimaHome namespace,
      namespaceLimaHome namespace,
      namespaceColimaCacheHome namespace,
      namespaceTemporaryDirectory namespace,
      namespaceDockerConfig namespace
    ]
  where
    namespace = backendNamespace harness

descendantProgram :: Bool -> String
descendantProgram closePipes =
  unlines
    [ "import os,signal,sys,time",
      "child=os.fork()",
      "if child == 0:",
      "    signal.signal(signal.SIGTERM,signal.SIG_IGN)",
      if closePipes
        then "    target=os.open(os.devnull,os.O_WRONLY); os.dup2(target,1); os.dup2(target,2); os.close(target)"
        else "    pass",
      "    with open(sys.argv[1],'w') as stream: stream.write(str(os.getpid()))",
      "    time.sleep(30)",
      "    os._exit(0)",
      "os._exit(0)"
    ]

readPidFile :: BackendHarness -> FilePath -> IO String
readPidFile harness name = do
  waitForMarker harness name
  value <- strictReadFile (backendDirectory harness </> name)
  case reads value :: [(Integer, String)] of
    [(pid, "")] | pid > 0 -> pure (show pid)
    _ -> assertFailure ("invalid runner pid fixture: " ++ show value)

waitForPidGone :: FilePath -> String -> IO ()
waitForPidGone python pid = do
  result <- timeout 5000000 loop
  case result of
    Just () -> pure ()
    Nothing -> assertFailure ("runner left process " ++ pid ++ " alive")
  where
    loop = do
      (exitCode, _out, _errOut) <-
        readProcessWithExitCode
          python
          [ "-c",
            "import os,sys\ntry: os.kill(int(sys.argv[1]),0)\nexcept ProcessLookupError: raise SystemExit(1)\nexcept PermissionError: pass",
            pid
          ]
          ""
      case exitCode of
        ExitSuccess -> threadDelay 10000 >> loop
        _ -> pure ()

takeMVarWithin :: String -> MVar a -> IO a
takeMVarWithin label variable = do
  result <- timeout 10000000 (takeMVar variable)
  case result of
    Just value -> pure value
    Nothing -> assertFailure ("timed out waiting for Colima " ++ label)

requireExecutable :: String -> Maybe FilePath -> IO FilePath
requireExecutable _label (Just path) = pure path
requireExecutable label Nothing = assertFailure ("missing test executable: " ++ label)

fakeColimaProgram :: String
fakeColimaProgram =
  unlines
    [ "#!/usr/bin/env python3",
      "import json,os,shutil,signal,socket,sys,time",
      "root=os.path.dirname(os.path.realpath(__file__))",
      "def path(name): return os.path.join(root,name)",
      "def exists(name): return os.path.exists(path(name))",
      "def touch(name,value=''):",
      "    with open(path(name),'w') as stream: stream.write(value)",
      "def remove(name):",
      "    try: os.unlink(path(name))",
      "    except FileNotFoundError: pass",
      "args=sys.argv[1:]",
      "with open(path('events'),'a') as stream: stream.write(' '.join(args)+'\\n')",
      "if args[:2] == ['list','--json']:",
      "    if exists('hang-list'): time.sleep(5)",
      "    if exists('list-exit'): raise SystemExit(23)",
      "    if exists('blank-list'): print(); raise SystemExit(0)",
      "    if exists('malformed-list'): print('{not-json}'); raise SystemExit(0)",
      "    if exists('noninteger-list'):",
      "        print(json.dumps({'name':'" ++ profileName ++ "','status':'Running','cpus':True,'memory':17179869184,'disk':85899345920,'runtime':'docker'})); raise SystemExit(0)",
      "    if exists('duplicate-list') and not exists('present'):",
      "        value={'name':'" ++ profileName ++ "','status':'Running','cpus':8,'memory':17179869184,'disk':85899345920,'runtime':'docker'}; print(json.dumps(value)); print(json.dumps(value)); raise SystemExit(0)",
      "    if exists('present'):",
      "        status=open(path('status')).read().strip() if exists('status') else 'Running'",
      "        cpus=4 if exists('mismatch') else 8",
      "        name=open(path('profile')).read().strip() if exists('profile') else '" ++ profileName ++ "'",
      "        value={'name':name,'status':status,'cpus':cpus,'memory':17179869184,'disk':85899345920,'runtime':'docker'}",
      "        print(json.dumps(value))",
      "        if exists('duplicate-list'): print(json.dumps(value))",
      "    raise SystemExit(0)",
      "if args and args[0] == 'start':",
      "    if exists('fail-start'): raise SystemExit(17)",
      "    if exists('block-start'):",
      "        child=os.fork()",
      "        if child == 0:",
      "            signal.signal(signal.SIGTERM,signal.SIG_IGN); touch('start-descendant-pid',str(os.getpid())); time.sleep(30); os._exit(0)",
      "        signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)",
      "    profile=args[args.index('--profile')+1]",
      "    cpu=int(args[args.index('--cpus')+1]); memory=int(args[args.index('--memory')+1]); data=int(args[args.index('--disk')+1]); root_disk=int(args[args.index('--root-disk')+1])",
      "    touch('present'); touch('status','Running'); touch('profile',profile)",
      "    if not exists('machine'): touch('machine','0123456789abcdef0123456789abcdef\\n')",
      "    home=os.environ['COLIMA_HOME']; disk_name='colima-'+profile; instance=os.path.join(os.environ['LIMA_HOME'],disk_name); disk_dir=os.path.join(os.environ['LIMA_HOME'],'_disks',disk_name); profile_dir=os.path.join(home,profile); store_dir=os.path.join(home,'_store')",
      "    for directory in (profile_dir,instance,disk_dir,store_dir): os.makedirs(directory,mode=0o700,exist_ok=True)",
      "    config_text='cpu: %d\\nmemory: %d\\ndisk: %d\\nrootDisk: %d\\n' % (cpu,memory,data,root_disk)",
      "    for target,value in ((os.path.join(profile_dir,'colima.yaml'),config_text),(os.path.join(instance,'colima.yaml'),config_text),(os.path.join(instance,'lima.yaml'),'memory: %dGiB\\ndisk: %dGiB\\n' % (memory,root_disk)),(os.path.join(store_dir,disk_name+'.json'),'{}\\n')):",
      "        with open(target,'w') as stream: stream.write(value)",
      "    with open(os.path.join(instance,'diffdisk'),'wb') as stream: stream.truncate(root_disk*1024**3)",
      "    try: os.symlink('diffdisk',os.path.join(instance,'disk'))",
      "    except FileExistsError: pass",
      "    with open(os.path.join(disk_dir,'datadisk'),'wb') as stream: stream.truncate(data*1024**3)",
      "    try: os.symlink(instance,os.path.join(disk_dir,'in_use_by'))",
      "    except FileExistsError: pass",
      "    if exists('runtime-specials'):",
      "        previous=os.getcwd(); os.chdir(instance)",
      "        try: special=socket.socket(socket.AF_UNIX); special.bind('ha.sock'); special.close()",
      "        finally: os.chdir(previous)",
      "    config=os.environ['DOCKER_CONFIG']; os.makedirs(config,exist_ok=True)",
      "    context_path=os.path.join(config,'context-owned')",
      "    if not os.path.exists(context_path):",
      "        with open(context_path,'w') as stream: stream.write('colima-'+profile+'\\n')",
      "    raise SystemExit(0)",
      "if args and args[0] == 'ssh':",
      "    if not exists('present') or (exists('status') and open(path('status')).read().strip().lower() != 'running'): raise SystemExit(18)",
      "    if exists('machine-stderr'): sys.stderr.write('identity warning\\n')",
      "    sys.stdout.write(open(path('machine')).read()); raise SystemExit(0)",
      "if args and args[0] == 'delete':",
      "    if exists('fail-delete'): raise SystemExit(19)",
      "    if exists('block-delete'):",
      "        touch('delete-entered')",
      "        deadline=time.time()+5",
      "        while not exists('allow-delete') and time.time() < deadline: time.sleep(0.01)",
      "        if not exists('allow-delete'): raise SystemExit(20)",
      "    if exists('swap-record-on-delete'):",
      "        record=open(path('swap-record-on-delete')).read()",
      "        replacement=record+'.foreign'",
      "        with open(replacement,'w') as stream: stream.write('foreign-record\\n')",
      "        os.chmod(replacement,0o600); os.replace(replacement,record)",
      "    profile=args[args.index('--profile')+1]; disk_name='colima-'+profile; home=os.environ['COLIMA_HOME']",
      "    if '--data' not in args: raise SystemExit(24)",
      "    for directory in (os.path.join(home,profile),os.path.join(os.environ['LIMA_HOME'],disk_name),os.path.join(os.environ['LIMA_HOME'],'_disks',disk_name)): shutil.rmtree(directory,ignore_errors=True)",
      "    try: os.unlink(os.path.join(home,'_store',disk_name+'.json'))",
      "    except FileNotFoundError: pass",
      "    if exists('delete-removes-context'):",
      "        try: os.unlink(os.path.join(os.environ['DOCKER_CONFIG'],'context-owned'))",
      "        except FileNotFoundError: pass",
      "    remove('present'); remove('status'); raise SystemExit(0)",
      "raise SystemExit(21)"
    ]

fakeLimaProgram :: String
fakeLimaProgram =
  unlines
    [ "#!/usr/bin/env python3",
      "import json,os,sys",
      "root=os.path.dirname(os.path.realpath(__file__))",
      "def exists(name): return os.path.exists(os.path.join(root,name))",
      "args=sys.argv[1:]",
      "if args != ['disk','list','--json']: raise SystemExit(41)",
      "if exists('disk-list-exit'): raise SystemExit(42)",
      "if exists('blank-disk-list'): print(); raise SystemExit(0)",
      "profile=open(os.path.join(root,'profile')).read().strip() if exists('profile') else '" ++ profileName ++ "'",
      "name='colima-'+profile; directory=os.path.join(os.environ['LIMA_HOME'],'_disks',name); instance=os.path.join(os.environ['LIMA_HOME'],name)",
      "if os.path.isdir(directory):",
      "    value={'name':name,'size':os.stat(os.path.join(directory,'datadisk')).st_size,'format':'raw','dir':directory,'instance':name,'instanceDir':instance,'mountPoint':'/mnt/lima-'+name}",
      "    print(json.dumps(value))",
      "    if exists('duplicate-disk-list'): print(json.dumps(value))",
      "raise SystemExit(0)"
    ]

fakeDockerProgram :: String
fakeDockerProgram =
  unlines
    [ "#!/usr/bin/env python3",
      "import json,os,sys",
      "root=os.path.dirname(os.path.realpath(__file__))",
      "def path(name): return os.path.join(root,name)",
      "args=sys.argv[1:]",
      "context_path=os.path.join(os.environ['DOCKER_CONFIG'],'context-owned')",
      "with open(path('docker-events'),'a') as stream: stream.write(' '.join(args)+'\\n')",
      "if args[:2] == ['context','inspect']:",
      "    if os.path.exists(path('fail-context')): raise SystemExit(31)",
      "    if not os.path.exists(context_path): raise SystemExit(1)",
      "    if open(context_path).read().strip() != args[2]: raise SystemExit(1)",
      "    print(json.dumps([{'Name':args[2],'Endpoints':{'docker':{'Host':'unix:///owned.sock'}}}],sort_keys=True,separators=(',',':')))",
      "    raise SystemExit(0)",
      "if args[:2] == ['context','ls']:",
      "    print(json.dumps({'Name':'default'}))",
      "    if os.path.exists(context_path): print(json.dumps({'Name':open(context_path).read().strip()}))",
      "    raise SystemExit(0)",
      "if args[:3] == ['context','rm','--force']:",
      "    try: os.unlink(context_path)",
      "    except FileNotFoundError: pass",
      "    raise SystemExit(0)",
      "if args and args[0] == 'context':",
      "    with open(path('context-mutated'),'w') as stream: stream.write('mutated\\n')",
      "    raise SystemExit(0)",
      "if args[:2] == ['--context','colima-" ++ profileName ++ "'] or (len(args) >= 2 and args[0] == '--context'):",
      "    sys.stdout.write('docker-ok\\n'); raise SystemExit(0)",
      "raise SystemExit(32)"
    ]

withPreparedPublicTestCallM ::
  ( forall
      projectId
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      clusterResourceId
      clusterFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    PlannedResource
      (Production projectId)
      planId
      providerResourceId
      ProviderResource
      providerFrame ->
    PlannedResource
      (Production projectId)
      planId
      clusterResourceId
      ClusterResource
      clusterFrame ->
    PreparedGate ->
    IO PreparedGate ->
    Text.Text ->
    PreparedColimaWallCall
      (Production projectId)
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedPublicTestCallM consume = do
  withTestProjectResources $ \plan expectedProject providerResource clusterResource -> do
    let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
        operation = plannedResourceKey providerResource
    withSuccessorGate planDigest operation "session-1" "stale-acquire-session" 1 1 2 $ \gate nextGate ->
      withPreparedTestCallForGate plan providerResource clusterResource gate $
        consume plan providerResource clusterResource gate nextGate expectedProject

withPreparedTestCallForGate ::
  ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  PlannedResource scope planId clusterResourceId ClusterResource clusterFrame ->
  PreparedGate ->
  ( forall
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    PreparedColimaWallCall
      scope
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedTestCallForGate plan providerResource clusterResource gate consume = do
  let prepared = do
        workload <- first show (mkWorkload clusterResource 1 1 gib gib)
        overhead <- first show (mkResourceBudget 1 gib gib)
        sliceBudget <- first show (mkResourceBudget 6 (10 * gib) (80 * gib))
        minimumBudget <- first show (mkResourceBudget 1 gib gib)
        request <- first show (mkSliceRequest providerResource sliceBudget minimumBudget)
        flattenBudget $
          withValidatedBudget plan exactEnvelope $ \validated ->
            withProviderBudgetCapability plan providerResource ColimaProviderKey $ \capability ->
              flattenBudget $
                admitProviderBudget validated capability $ \wall effective ->
                  flattenBudget $
                    withPlannedWorkloadSet plan [workload] $ \workloads -> do
                      fit <- first show (verifyPlannedWorkloadFit effective workloads)
                      flattenBudget $
                        withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                          flattenBudget $
                            withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                              first show $
                                withObservedProjectResource plan providerResource 17 7 $ \providerHandle -> do
                                  result <-
                                    prepareColimaWallCall
                                      plan
                                      providerResource
                                      providerHandle
                                      (topology plan)
                                      validated
                                      capability
                                      wall
                                      fit
                                      partition
                                      reservation
                                      gate
                                  case result of
                                    Left failure -> pure (Left (show failure))
                                    Right call -> Right <$> consume call
  case prepared of
    Left failure -> pure (Left failure)
    Right action -> action

withPreparedTestCallM ::
  ( forall
      projectId
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    Text.Text ->
    PreparedColimaWallCall
      (Production projectId)
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    IO result
  ) ->
  IO (Either String result)
withPreparedTestCallM consume =
  withPreparedPublicTestCallM (\_plan _provider _cluster _gate _nextGate project call -> consume project call)

withPreparedTestCall ::
  ( forall
      projectId
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence.
    Text.Text ->
    PreparedColimaWallCall
      (Production projectId)
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    result
  ) ->
  IO (Either String result)
withPreparedTestCall consume =
  withPreparedTestCallM (\project call -> pure (consume project call))

flattenBudget :: Either BudgetError (Either String a) -> Either String a
flattenBudget = either (Left . show) id

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ descendsVia
            localContext
            (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))),
          deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
        ]
    )

withTestProjectResources ::
  ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    Text.Text ->
    PlannedResource
      (Production projectId)
      planId
      providerId
      ProviderResource
      providerFrame ->
    PlannedResource
      (Production projectId)
      planId
      clusterId
      ClusterResource
      clusterFrame ->
    IO result
  ) ->
  IO result
withTestProjectResources consume =
  Fixture.withFixtureProjectPlanContext id testPlan $ \plan context ->
    case NonEmpty.toList (forward plan) of
      [providerNode, clusterNode] ->
        case
          withPlannedResourceOfKind
            plan
            ProviderResourceKind
            (plannedStepOperationKey providerNode)
            ( \providerResource ->
                withPlannedResourceOfKind
                  plan
                  ClusterResourceKind
                  (plannedStepOperationKey clusterNode)
                  (consume plan (Context.project context) providerResource)
            ) of
          Left failure -> fail ("provider projection failed: " ++ show failure)
          Right (Left failure) -> fail ("cluster projection failed: " ++ show failure)
          Right (Right action) -> action
      nodes -> fail ("expected provider and cluster plan nodes, got " ++ show (length nodes))
