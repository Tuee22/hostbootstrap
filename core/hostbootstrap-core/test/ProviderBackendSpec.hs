{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Real-process coverage for the provider ownership backend.

The POSIX cases execute the production lock/Python bracket against a fake
Incus executable and real temporary filesystem.  The fake returns only the raw
CLI shapes Incus would return; it knows nothing about reconciliation outcomes.
-}
#ifdef PROVIDER_BACKEND_STANDALONE
module ProviderBackendSpec (tests, main) where
#else
module ProviderBackendSpec (tests) where
#endif

import Control.Concurrent (MVar, forkIO, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception (IOException, displayException, try)
import Control.Monad (void)
import Data.List (isPrefixOf, isSuffixOf, sort, tails)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Readiness (microsValue)
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Arm64), Substrate (..), SubstrateName (LinuxCpu, LinuxGpu))
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile
import PrepareFixture (gateFor)
import System.Directory
import System.Exit (ExitCode (..))
import PlatformPath (hostFixturePath)
import System.FilePath (isAbsolute, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
#ifdef PROVIDER_BACKEND_STANDALONE
import qualified Test.Tasty as Tasty
#endif
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

#ifdef PROVIDER_BACKEND_STANDALONE
main :: IO ()
main = Tasty.defaultMain tests
#endif

tests :: TestTree
tests =
    testGroup
        "ProviderBackendSpec"
        ( portableCases
            <> includePosix
                [ testCase "provision, fresh boot, share, stop, and conditional delete hold one identity" fullLifecycleCase
                , testCase "concurrent provision enters once and launches once" concurrentProvisionCase
                , testCase "a crash after launch recovers from the durable nonce without relaunch" crashRecoveryCase
                , testCase "readiness retries only NotReady through the injected bounded wait" readinessRetryCase
                , testCase "a replacement is reported and left untouched" replacementCase
                , testCase "an exact share is idempotent and a changed device is a conflict" shareReadbackCase
                , testCase "an exact restarted VM is retryable rather than a replacement" exactRestartBeforeDeleteCase
                , testCase "Ready rechecks identity after the guest observation" readyObservationReplacementCase
                , testCase "Stop rechecks identity after the final state observation" stopObservationReplacementCase
                , testCase "Share rechecks identity after idempotent device readback" shareObservationReplacementCase
                , testCase "Delete rechecks identity after its state observation" deleteObservationReplacementCase
                , testCase "a partial initial origin write is recovered before first mutation" initialPublicationPartialWriteCase
                , testCase "delete recovers a durable manifest whose sidecar and device were never published" manifestPublishedDeleteRecoveryCase
                , testCase "delete cleans exact interrupted main-record staging" mainStagingCleanupCase
                , testCase "delete refuses a missing sidecar while its device is present" missingSidecarWithDeviceCase
                , testCase "recordless deletion refuses and preserves orphan provider metadata" orphanMetadataRefusalCase
                , testCase "delete fsync failures converge without repeating provider deletion" absentDeleteFsyncRetryCase
                , testCase "multi-sidecar deletion resumes after removing staging before base records" multiSidecarDeleteRetryCase
                , testCase "Direct Ready rejects a symlink root with the real Python probe" directReadySymlinkCase
                ]
        )

includePosix :: [TestTree] -> [TestTree]
#ifdef mingw32_HOST_OS
includePosix _ = []
#else
includePosix = id
#endif

portableCases :: [TestTree]
portableCases =
    [ testCase "Incus construction refuses the wrong substrate before discovery" $ do
        let config = emptyHostConfig{hcSubstrate = Substrate LinuxGpu Arm64}
        case mkIncusBackendSpec vmName imageName config "/state" 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected substrate refusal, got " <> showEither other)
    , testCase "Incus construction refuses an instance name whose share socket path cannot fit" $ do
        let config = fakeResolvedHostConfig
            overlong = vmName <> replicate 64 'x'
        case mkIncusBackendSpec overlong imageName config "/state" 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected socket-path bound refusal, got " <> showEither other)
    , testCase "Incus construction refuses unresolved ownership tools" $
        case mkIncusBackendSpec vmName imageName emptyHostConfig "/state" 2 "4GiB" "40GiB" of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected unresolved-tool refusal, got " <> showEither other)
    , testCase "Incus construction refuses a Lockf-only host before discovery" $ do
        let config =
                emptyHostConfig
                    { hcToolPaths =
                        Map.fromList
                            [ (Incus, fixtureExe fixtureIncus)
                            , (Python3, fixtureExe fixturePython)
                            , (Lockf, fixtureExe fixtureLockf)
                            ]
                    }
        case mkIncusBackendSpec vmName imageName config "/state" 2 "4GiB" "40GiB" of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected single-flock-namespace refusal, got " <> showEither other)
    , testCase "Direct backend discovery is structurally non-mutating" $ do
        count <- newCounter
        let config = directHostConfig
            exec = countingSuccessExec count
        spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config "/srv/hostbootstrap" imageName)
        discovered <- discoverStrongProviderBackend exec spec (const (pure ()))
        discovered @?= Right ()
        readCounter count >>= (@?= 0)
    , testCase "Direct Ready validates the exact root then exact egress image" directReadyValidationCase
    , testCase "Direct Ready stops before egress when root validation fails" directReadyPermissionFailureCase
    , testCase "Direct Ready refuses failed egress without minting Running" directReadyEgressFailureCase
    , testCase "provider wire grammar is one canonical bounded line with exact arity" strictWireGrammarCase
    , testCase "an exit-zero discovery report cannot invent a lock proof" $ do
        let rawExec =
                ProviderBackendExec
                    { runProviderBackendExec = const (pure (RawProviderExit ExitSuccess "flock\n" ""))
                    , waitProviderBackendExec = const (pure ())
                    }
        case incusSpecForConfig fakeResolvedHostConfig "/state" of
            Left failure -> assertFailure (show failure)
            Right spec -> do
                discovered <- discoverStrongProviderBackend rawExec spec (const (pure ()))
                case discovered of
                    Left (Unsupported _) -> pure ()
                    other -> assertFailure ("expected fail-closed discovery, got " <> showEither other)
    ]

directReadyValidationCase :: IO ()
directReadyValidationCase = do
    ordered <- newOrderedExec [RawProviderExit ExitSuccess "" "", RawProviderExit ExitSuccess "{}\n" ""]
    result <- runDirectReadyWith directHostConfig (orderedProviderExec ordered) "/srv/hostbootstrap"
    result @?= Right ()
    requests <- readMVar (orderedRequests ordered)
    case requests of
        [ ProviderBackendProcess python ["-c", program, root]
            , ProviderBackendProcess docker ["manifest", "inspect", image]
            ] -> do
                python @?= fixturePython
                docker @?= fixtureDocker
                root @?= "/srv/hostbootstrap"
                image @?= imageName
                assertBool "the closed permission program checks the exact canonical directory" ("os.lstat" `contains` program && "os.path.realpath(root)==root" `contains` program)
        other -> assertFailure ("unexpected Direct Ready request sequence: " <> show other)

directReadyPermissionFailureCase :: IO ()
directReadyPermissionFailureCase = do
    ordered <- newOrderedExec [RawProviderExit (ExitFailure 1) "" "missing-root\n"]
    result <- runDirectReadyWith directHostConfig (orderedProviderExec ordered) "/srv/missing"
    case result of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected Direct permission failure, got " <> showEither other)
    requests <- readMVar (orderedRequests ordered)
    length requests @?= 1

directReadyEgressFailureCase :: IO ()
directReadyEgressFailureCase = do
    ordered <-
        newOrderedExec
            [ RawProviderExit ExitSuccess "" ""
            , RawProviderExit (ExitFailure 1) "" "manifest-missing\n"
            ]
    result <- runDirectReadyWith directHostConfig (orderedProviderExec ordered) "/srv/hostbootstrap"
    case result of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected Direct egress failure, got " <> showEither other)
    requests <- readMVar (orderedRequests ordered)
    length requests @?= 2

directReadySymlinkCase :: IO ()
directReadySymlinkCase =
    withSystemTempDirectory "hostbootstrap-direct-ready" $ \root -> do
        python <- requireExecutable "python3"
        let actual = root </> "actual"
            alias = root </> "alias"
            config =
                directHostConfig
                    { hcToolPaths =
                        Map.fromList
                            [ (Python3, fixtureExe python)
                            , (Docker, fixtureExe (hostFixturePath "/opt/hostbootstrap-test/docker"))
                            ]
                    }
        createDirectory actual
        createDirectoryLink actual alias
        requests <- newMVar []
        let exec =
                ProviderBackendExec
                    { runProviderBackendExec = \request -> do
                        let view = providerBackendRequestView request
                        modifyMVar_ requests (pure . (<> [view]))
                        case view of
                            ProviderBackendProcess commandPath argv
                                | commandPath == python -> do
                                    (code, out, err) <- readProcessWithExitCode commandPath argv ""
                                    pure (RawProviderExit code out err)
                                | otherwise -> pure (RawProviderExit ExitSuccess "{}\n" "")
                    , waitProviderBackendExec = const (pure ())
                    }
        result <- runDirectReadyWith config exec alias
        case result of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected noncanonical Direct root refusal, got " <> showEither other)
        readMVar requests >>= (\observed -> length observed @?= 1)

runDirectReadyWith :: HostConfig -> ProviderBackendExec -> FilePath -> IO (Either ReconcileError ())
runDirectReadyWith config exec root = do
    spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config root imageName)
    discovered <-
        discoverStrongProviderBackend exec spec $ \backend ->
            withProvisionedProvider backend $ \execution planned _ provisioned ->
                (() <$) <$> readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
    pure (discovered >>= id)

data OrderedExec = OrderedExec
    { orderedOutcomes :: MVar [RawProviderOutcome]
    , orderedRequests :: MVar [ProviderBackendRequestView]
    }

newOrderedExec :: [RawProviderOutcome] -> IO OrderedExec
newOrderedExec outcomes = OrderedExec <$> newMVar outcomes <*> newMVar []

orderedProviderExec :: OrderedExec -> ProviderBackendExec
orderedProviderExec ordered =
    ProviderBackendExec
        { runProviderBackendExec = \request -> do
            modifyMVar_ (orderedRequests ordered) (pure . (<> [providerBackendRequestView request]))
            modifyMVar (orderedOutcomes ordered) $ \case
                outcome : rest -> pure (rest, outcome)
                [] -> pure ([], RawProviderFailure "unexpected extra Direct backend request")
        , waitProviderBackendExec = const (pure ())
        }

strictWireGrammarCase :: IO ()
strictWireGrammarCase = do
    expectProvisionFailure "second stdout line" (RawProviderExit ExitSuccess ("CREATED " <> managedIdentity <> "\nREADY\n") "")
    expectProvisionFailure "successful stderr" (RawProviderExit ExitSuccess ("CREATED " <> managedIdentity <> "\n") "warning\n")
    expectProvisionFailure "extra Conflict field" (RawProviderExit ExitSuccess "CONFLICT expected observed reason extra\n" "")
    expectProvisionFailure "extra Unsupported field" (RawProviderExit ExitSuccess "UNSUPPORTED reason extra\n" "")
    expectProvisionFailure "noncanonical spacing" (RawProviderExit ExitSuccess ("CREATED  " <> managedIdentity <> "\n") "")
    expectProvisionFailure "bounded line" (RawProviderExit ExitSuccess ("CREATED " <> replicate 5000 'x' <> "\n") "")
    withScriptedIncusBackend
        [ ("provision", [RawProviderExit ExitSuccess ("CREATED " <> managedIdentity <> "\n") ""])
        , ("ready", [RawProviderExit ExitSuccess "NOTREADY wait extra\n" ""])
        ]
        ( \scripted backend ->
            withProvisionedProvider backend $ \execution planned _ provisioned -> do
                result <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
                expectFailure "extra NotReady field" result
                readCounter (scriptedWaits scripted) >>= (@?= 0)
        )
    withScriptedIncusBackend
        [ ("provision", [RawProviderExit ExitSuccess ("CREATED " <> managedIdentity <> "\n") ""])
        , ("ready", [RawProviderExit ExitSuccess "READY\n" ""])
        , ("stop", [RawProviderExit ExitSuccess "STILL_RUNNING running extra\n" ""])
        ]
        ( \_ backend ->
            withRunningProvider backend $ \execution planned _ running ->
                stopProvider backend execution planned running >>= expectFailure "extra StillRunning field"
        )
    withScriptedIncusBackend
        [ ("provision", [RawProviderExit ExitSuccess ("CREATED " <> managedIdentity <> "\n") ""])
        , ("ready", [RawProviderExit ExitSuccess "READY\n" ""])
        , ("stop", [RawProviderExit ExitSuccess "STOPPED\n" ""])
        , ("delete", [RawProviderExit ExitSuccess "ABSENT\n" ""])
        ]
        ( \_ backend ->
            withRunningProvider backend $ \execution planned _ running -> do
                stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
                deleteProvider backend execution planned stopped >>= expectFailure "Delete ABSENT"
        )
  where
    expectProvisionFailure label raw =
        withScriptedIncusBackend [("provision", [raw])] $ \_ backend ->
            withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
                call <- runProviderProvisionCall backend prepared
                expectFailure label (settleProviderProvision Nothing prepared call)

expectFailure :: String -> Either ReconcileError value -> IO ()
expectFailure label result = case result of
    Left (Failure _) -> pure ()
    other -> assertFailure (label <> " should fail closed, got " <> showEither other)

data ScriptedProviderExec = ScriptedProviderExec
    { scriptedQueues :: MVar (Map.Map String [RawProviderOutcome])
    , scriptedRequests :: MVar [ProviderBackendRequestView]
    , scriptedWaits :: Counter
    }

newScriptedProviderExec :: [(String, [RawProviderOutcome])] -> IO ScriptedProviderExec
newScriptedProviderExec scripts =
    ScriptedProviderExec <$> newMVar (Map.fromList scripts) <*> newMVar [] <*> newCounter

scriptedProviderBackendExec :: ScriptedProviderExec -> ProviderBackendExec
scriptedProviderBackendExec scripted =
    ProviderBackendExec
        { runProviderBackendExec = \request -> do
            let view = providerBackendRequestView request
            modifyMVar_ (scriptedRequests scripted) (pure . (<> [view]))
            case requestOperation view of
                Nothing -> pure (RawProviderExit ExitSuccess "PROVED flock\n" "")
                Just operation ->
                    modifyMVar (scriptedQueues scripted) $ \queues ->
                        case Map.findWithDefault [] operation queues of
                            outcome : rest -> pure (Map.insert operation rest queues, outcome)
                            [] -> pure (queues, RawProviderFailure ("unexpected or repeated provider operation " <> operation))
        , waitProviderBackendExec = const (incrementCounter (scriptedWaits scripted))
        }

requestOperation :: ProviderBackendRequestView -> Maybe String
requestOperation (ProviderBackendProcess _ argv) = case dropWhile (/= "-c") argv of
    "-c" : _program : operation : _
        | operation `elem` ["provision", "ready", "stop", "share", "delete", "guest"] -> Just operation
    _ -> Nothing

withScriptedIncusBackend ::
    [(String, [RawProviderOutcome])] ->
    (forall backendId. ScriptedProviderExec -> StrongProviderBackend backendId -> IO result) ->
    IO ()
withScriptedIncusBackend scripts consume = do
    scripted <- newScriptedProviderExec scripts
    spec <- either (assertFailure . show) pure (incusSpecForConfig fakeResolvedHostConfig "/state")
    discovered <- discoverStrongProviderBackend (scriptedProviderBackendExec scripted) spec (consume scripted)
    either (assertFailure . show) (const (pure ())) discovered

-- End-to-end cases -----------------------------------------------------------

fullLifecycleCase :: IO ()
fullLifecycleCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \execution planned _ _ running preparedShare -> do
            shareCall <- runProviderShareCall backend preparedShare
            case settleProviderShare Nothing preparedShare shareCall of
                Left failure -> assertFailure ("share failed: " <> show failure)
                Right settled ->
                    withProviderShareSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running
            case stopped of
                Left failure -> assertFailure ("stop failed: " <> show failure)
                Right stoppedHandle -> do
                    deleted <- deleteProvider backend execution planned stoppedHandle
                    deleted @?= Right ()
                    doesFileExist (instanceIdentityPath host) >>= (@?= False)
                    doesFileExist (originPath host) >>= (@?= False)
                    entries <- listDirectory (statePath host)
                    assertBool "share sidecars are removed with the exact provider" (not (any (".share.json" `isSuffixOf`) entries))

concurrentProvisionCase :: IO ()
concurrentProvisionCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            leftResult <- newEmptyMVar
            rightResult <- newEmptyMVar
            void (forkIO (runProviderProvisionCall backend prepared >>= putMVar leftResult))
            void (forkIO (runProviderProvisionCall backend prepared >>= putMVar rightResult))
            first <- takeMVar leftResult
            second <- takeMVar rightResult
            let classify result =
                    withProviderProvisionSettlement
                        (either (error . show) id (settleProviderProvision Nothing prepared result))
                        (\_ _ -> "managed" :: String)
                        (\_ _ _ _ -> "foreign")
            assertBool "both calls retain the same owned instance" (sortTwo (classify first) (classify second) == ["managed", "managed"])
            launches <- countOf "launch" <$> readLines (mutationPath host)
            launches @?= 1

crashRecoveryCase :: IO ()
crashRecoveryCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            writeFile (crashAfterLaunchPath host) "once\n"
            first <- runProviderProvisionCall backend prepared
            case settleProviderProvision Nothing prepared first of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected interrupted first call, got " <> showEither (() <$ other))
            durable <- readFile (originPath host)
            assertBool "the exact absent origin and fresh nonce survived the crash" ("\"origin\":\"absent\"" `contains` durable && "\"nonce\":" `contains` durable)
            second <- runProviderProvisionCall backend prepared
            case settleProviderProvision Nothing prepared second of
                Right settled ->
                    withProviderProvisionSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "recovery must retain ownership")
                Left failure -> assertFailure ("retry failed: " <> show failure)
            launches <- countOf "launch" <$> readLines (mutationPath host)
            launches @?= 1

readinessRetryCase :: IO ()
readinessRetryCase = withFakeHost $ \host -> do
    writeFile (readyFailuresPath host) "2\n"
    withBackend host $ \backend ->
        withRunningProvider backend $ \_ _ _ _ -> do
            waits <- readCounter (waitCounter host)
            waits @?= 2

replacementCase :: IO ()
replacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            writeFile (instanceIdentityPath host) replacementIdentity
            result <- stopProvider backend execution planned running
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected replacement conflict, got " <> showEither (() <$ other))
            readFile (instanceIdentityPath host) >>= (@?= replacementIdentity)
            mutations <- readLines (mutationPath host)
            countOf "stop" mutations @?= 0

shareReadbackCase :: IO ()
shareReadbackCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ prepared -> do
            first <- runProviderShareCall backend prepared
            case settleProviderShare Nothing prepared first of
                Left failure -> assertFailure ("first share failed: " <> show failure)
                Right _ -> pure ()
            before <- countOf "device-add" <$> readLines (mutationPath host)
            second <- runProviderShareCall backend prepared
            case settleProviderShare Nothing prepared second of
                Right settled ->
                    withProviderShareSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "exact owned repeat became foreign")
                Left failure -> assertFailure ("exact repeat failed: " <> show failure)
            after <- countOf "device-add" <$> readLines (mutationPath host)
            after @?= before
            device <- onlyDevice host
            writeFile (deviceSourcePath host device) "/srv/replaced"
            changed <- runProviderShareCall backend prepared
            case settleProviderShare Nothing prepared changed of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected changed-device conflict, got " <> showEither (() <$ other))
            readFile (deviceSourcePath host device) >>= (@?= "/srv/replaced")

exactRestartBeforeDeleteCase :: IO ()
exactRestartBeforeDeleteCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            writeFile (instanceStatePath host) "RUNNING\n"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Failure detail) -> recoveryDisposition detail @?= RetrySameOperationKeyAfterFencing
                other -> assertFailure ("expected exact-provider retry, got " <> showEither other)
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 0)
            readFile (instanceIdentityPath host) >>= (@?= (managedIdentity <> "\n"))

readyObservationReplacementCase :: IO ()
readyObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withProvisionedProvider backend $ \execution planned _ provisioned -> do
            writeFile (replaceAfterReadyPath host) "once\n"
            result <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Ready replacement conflict, got " <> showEither other)
            readFile (instanceIdentityPath host) >>= (@?= replacementIdentity)

stopObservationReplacementCase :: IO ()
stopObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            writeFile (replaceAfterStateReadPath host) "2\n"
            result <- stopProvider backend execution planned running
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Stop replacement conflict, got " <> showEither (() <$ other))
            readFile (instanceIdentityPath host) >>= (@?= replacementIdentity)

shareObservationReplacementCase :: IO ()
shareObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ prepared -> do
            first <- runProviderShareCall backend prepared
            settled <- either (assertFailure . show) pure (settleProviderShare Nothing prepared first)
            withProviderShareSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "initial share remained foreign")
            writeFile (replaceAfterDeviceReadPath host) "once\n"
            second <- runProviderShareCall backend prepared
            case settleProviderShare Nothing prepared second of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Share replacement conflict, got " <> showEither (() <$ other))
            readFile (instanceIdentityPath host) >>= (@?= replacementIdentity)
            countOf "device-add" <$> readLines (mutationPath host) >>= (@?= 1)

deleteObservationReplacementCase :: IO ()
deleteObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            writeFile (instanceStatePath host) "RUNNING\n"
            writeFile (replaceAfterStateReadPath host) "1\n"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Delete replacement conflict, got " <> showEither other)
            doesFileExist (originPath host) >>= (@?= True)
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 0)

initialPublicationPartialWriteCase :: IO ()
initialPublicationPartialWriteCase = withFakeHost $ \host ->
    withFaultingBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            armFault host "provision" "write" 1
            first <- runProviderProvisionCall backend prepared
            expectFailure "partial initial origin publication" (settleProviderProvision Nothing prepared first)
            doesFileExist (originPath host) >>= (@?= False)
            entries <- listDirectory (statePath host)
            length (filter (isPrefixOf (takeFileNameForOrigin host <> ".prepare-")) entries) @?= 1
            second <- runProviderProvisionCall backend prepared
            settled <- either (assertFailure . show) pure (settleProviderProvision Nothing prepared second)
            withProviderProvisionSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "recovered provision remained foreign")
            countOf "launch" <$> readLines (mutationPath host) >>= (@?= 1)
            doesFileExist (originPath host) >>= (@?= True)

manifestPublishedDeleteRecoveryCase :: IO ()
manifestPublishedDeleteRecoveryCase = withFakeHost $ \host ->
    withFaultingBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \execution planned _ _ running prepared -> do
            armFault host "share" "fsync" 6
            first <- runProviderShareCall backend prepared
            expectFailure "manifest publication interruption" (settleProviderShare Nothing prepared first)
            readFile (originPath host) >>= (\raw -> assertBool "the share manifest was durable" ("hb-share-" `contains` raw))
            countOf "device-add" <$> readLines (mutationPath host) >>= (@?= 0)
            sidecars <- shareMetadataPaths host
            sidecars @?= []
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            deleteProvider backend execution planned stopped >>= (@?= Right ())
            doesFileExist (originPath host) >>= (@?= False)
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 1)

mainStagingCleanupCase :: IO ()
mainStagingCleanupCase = withFakeHost $ \host ->
    withFaultingBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \execution planned _ _ running prepared -> do
            armFault host "share" "fsync" 3
            first <- runProviderShareCall backend prepared
            expectFailure "main manifest staging interruption" (settleProviderShare Nothing prepared first)
            entries <- listDirectory (statePath host)
            assertBool "the exact main staging file exists" (any (isPrefixOf (takeFileNameForOrigin host <> ".tmp-")) entries)
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            deleteProvider backend execution planned stopped >>= (@?= Right ())
            entriesAfter <- listDirectory (statePath host)
            assertBool "main staging was removed with the exact provider" (not (any (isPrefixOf (takeFileNameForOrigin host <> ".tmp-")) entriesAfter))

missingSidecarWithDeviceCase :: IO ()
missingSidecarWithDeviceCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \execution planned _ _ running prepared -> do
            call <- runProviderShareCall backend prepared
            settled <- either (assertFailure . show) pure (settleProviderShare Nothing prepared call)
            withProviderShareSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "attached share remained foreign")
            [sidecar] <- shareMetadataPaths host
            removeFile sidecar
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected missing-sidecar conflict, got " <> showEither other)
            doesFileExist (instanceIdentityPath host) >>= (@?= True)
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 0)

orphanMetadataRefusalCase :: IO ()
orphanMetadataRefusalCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            let orphan = originPath host <> ".hb-share-" <> replicate 32 'a' <> ".share.json"
                staging = originPath host <> ".prepare-" <> replicate 64 'b'
            mapM_ removeFile [originPath host, instanceIdentityPath host, instanceOwnerPath host, instanceStatePath host]
            writeFile orphan "orphan-sidecar\n"
            writeFile staging "partial-staging"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected orphan-metadata conflict, got " <> showEither other)
            readFile orphan >>= (@?= "orphan-sidecar\n")
            readFile staging >>= (@?= "partial-staging")
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 0)

absentDeleteFsyncRetryCase :: IO ()
absentDeleteFsyncRetryCase = withFakeHost $ \host ->
    withFaultingBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            armFault host "delete" "fsync" 3
            deleteProvider backend execution planned stopped >>= expectFailure "final delete directory fsync"
            doesFileExist (originPath host) >>= (@?= False)
            doesFileExist (instanceIdentityPath host) >>= (@?= False)
            armFault host "delete" "fsync" 1
            deleteProvider backend execution planned stopped >>= expectFailure "absent delete directory fsync"
            deleteProvider backend execution planned stopped >>= (@?= Right ())
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 1)

multiSidecarDeleteRetryCase :: IO ()
multiSidecarDeleteRetryCase = withFakeHost $ \host ->
    withFaultingBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \execution planned shareExecution plannedShare running firstPrepared -> do
            attachProviderShare backend firstPrepared
            secondSpec <- either (assertFailure . show) pure (mkProviderShareSpec (shareRoot host) (shareRoot host </> "second"))
            thirdSpec <- either (assertFailure . show) pure (mkProviderShareSpec (shareRoot host) (shareRoot host </> "third"))
            withPreparedShareFor shareExecution plannedShare running 30 12 secondSpec (attachProviderShare backend)
            withPreparedShareFor shareExecution plannedShare running 31 13 thirdSpec (attachProviderShare backend)
            sidecars <- sort <$> shareMetadataPaths host
            length sidecars @?= 3
            firstSidecar <-
                case sidecars of
                    first : _ -> pure first
                    [] -> assertFailure "expected at least one share sidecar"
            firstRaw <- readFile firstSidecar
            nonce <- shareRecordNonce firstRaw
            let temporary = firstSidecar <> ".tmp-" <> nonce
            writeFile temporary firstRaw
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            armFault host "delete" "unlink" 1
            deleteProvider backend execution planned stopped >>= expectFailure "partial multi-sidecar cleanup"
            doesFileExist temporary >>= (@?= False)
            doesFileExist firstSidecar >>= (@?= True)
            doesFileExist (instanceIdentityPath host) >>= (@?= False)
            deleteProvider backend execution planned stopped >>= (@?= Right ())
            shareMetadataPaths host >>= (@?= [])
            doesFileExist (originPath host) >>= (@?= False)
            countOf "delete" <$> readLines (mutationPath host) >>= (@?= 1)

-- Prepared fixtures ---------------------------------------------------------

withPreparedProviderFixture ::
    StrongProviderBackend backendId ->
    Word64 ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      IO result
    ) ->
    IO result
withPreparedProviderFixture backend generation consume =
    Fixture.withFixtureProjectPlan providerPlan $ \projectPlan ->
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode] -> do
                carrier <- Execution.newResourceCarrier
                runtime <- Execution.newStepRuntime carrier
                let execution = stepExecutionFor projectPlan emptyHostConfig runtime providerNode
                    operationKey = Execution.stepExecutionOperationKey execution
                gate <- providerGate execution
                resolveNested3 $
                    withNodeResourceOfKind execution ProviderResourceKind operationKey $ \planned ->
                        withNodeObservedResource execution planned generation 7 $ \observed ->
                            withPreparedProviderProvision execution (providerBackendBinding backend) planned observed gate $
                                consume execution planned observed
            nodes -> assertFailure ("expected one provider node, got " <> show (length nodes))

withProvisionedProvider ::
    StrongProviderBackend backendId ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Provisioned ->
      IO result
    ) ->
    IO result
withProvisionedProvider backend consume =
    withPreparedProviderFixture backend 17 $ \execution planned _ prepared -> do
        call <- runProviderProvisionCall backend prepared
        settled <- either (assertFailure . show) pure (settleProviderProvision Nothing prepared call)
        withProviderProvisionSettlement
            settled
            (\managed _ -> consume execution planned prepared managed)
            (\_ _ _ _ -> assertFailure "fixture provider unexpectedly remained foreign")

readyProvider ::
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId phase ->
    ProviderStartable scope planId backendId providerId phase ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Running))
readyProvider backend execution planned managed startable = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderReady execution planned managed startable gate $ \prepared -> do
            call <- runProviderReadyCall backend prepared
            pure $ do
                advance <- settleProviderReady prepared call
                pure (withProviderPhaseAdvance advance id)

withRunningProvider ::
    StrongProviderBackend backendId ->
    ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      PreparedProviderProvision (Production projectId) planId backendId providerId operationKey callDigest attempt journalVersion ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      IO result
    ) ->
    IO result
withRunningProvider backend consume =
    withProvisionedProvider backend $ \execution planned preparedProvision provisioned -> do
        ready <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
        either (assertFailure . show) (consume execution planned preparedProvision) ready

stopProvider ::
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Stopped))
stopProvider backend execution planned running = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderStop execution planned running gate $ \prepared -> do
            call <- runProviderStopCall backend prepared
            pure $ do
                advance <- settleProviderStop prepared call
                pure (withProviderPhaseAdvance advance id)

deleteProvider ::
    StrongProviderBackend backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    IO (Either ReconcileError ())
deleteProvider backend execution planned stopped = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderDelete execution planned stopped gate $ \prepared -> do
            call <- runProviderDeleteCall backend prepared
            pure (() <$ settleProviderDelete prepared call)

withRunningProviderAndShare ::
    FakeHost ->
    StrongProviderBackend backendId ->
    ( forall projectId planId providerId providerFrame shareId shareFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      PreparedProviderShare
        (Production projectId)
        planId
        backendId
        providerId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO result
    ) ->
    IO result
withRunningProviderAndShare host backend consume =
    Fixture.withFixtureProjectPlan providerSharePlan $ \projectPlan ->
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode, shareNode] -> do
                carrier <- Execution.newResourceCarrier
                providerRuntime <- Execution.newStepRuntime carrier
                shareRuntime <- Execution.newStepRuntime carrier
                let providerExecution = stepExecutionFor projectPlan emptyHostConfig providerRuntime providerNode
                    shareExecution = stepExecutionFor projectPlan emptyHostConfig shareRuntime shareNode
                    providerKey = Execution.stepExecutionOperationKey providerExecution
                    shareKey = Execution.stepExecutionOperationKey shareExecution
                providerGateValue <- providerGate providerExecution
                shareGateValue <- providerGate shareExecution
                shareSpec <- either (assertFailure . show) pure (mkProviderShareSpec (shareRoot host) (shareRoot host))
                resolveNested3 $
                    withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
                        withNodeObservedResource providerExecution plannedProvider 17 7 $ \observedProvider ->
                            withPreparedProviderProvision providerExecution (providerBackendBinding backend) plannedProvider observedProvider providerGateValue $ \preparedProvision -> do
                                provisionCall <- runProviderProvisionCall backend preparedProvision
                                settled <- either (assertFailure . show) pure (settleProviderProvision Nothing preparedProvision provisionCall)
                                withProviderProvisionSettlement
                                    settled
                                    ( \provisioned _ ->
                                        resolveEitherIO $
                                            withPreparedProviderReady
                                                providerExecution
                                                plannedProvider
                                                provisioned
                                                (providerStartableAfterProvision provisioned)
                                                providerGateValue
                                                ( \preparedReady -> do
                                                    readyCall <- runProviderReadyCall backend preparedReady
                                                    readyAdvance <- either (assertFailure . show) pure (settleProviderReady preparedReady readyCall)
                                                    withProviderPhaseAdvance readyAdvance $ \running ->
                                                        resolveNested2 $
                                                            withNodeResourceOfKind shareExecution DurableShareResourceKind shareKey $ \plannedShare ->
                                                                withNodeObservedResource shareExecution plannedShare 29 11 $ \observedShare -> do
                                                                    preparedResult <-
                                                                        withPreparedProviderShare
                                                                            shareExecution
                                                                            plannedShare
                                                                            observedShare
                                                                            running
                                                                            (dependencyProbe (pure (Right (managedProviderGeneration running))))
                                                                            shareSpec
                                                                            shareGateValue
                                                                            (consume providerExecution plannedProvider shareExecution plannedShare running)
                                                                    either (assertFailure . show) id preparedResult
                                                )
                                    )
                                    (\_ _ _ _ -> assertFailure "fixture provider unexpectedly remained foreign")
            nodes -> assertFailure ("expected two share-plan nodes, got " <> show (length nodes))

withPreparedShareFor ::
    Execution.StepExecution scope planId ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    Word64 ->
    Word64 ->
    ProviderShareSpec ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
      IO result
    ) ->
    IO result
withPreparedShareFor execution planned running generation version spec consume = do
    gate <- providerGate execution
    resolveEitherIO $
        withNodeObservedResource execution planned generation version $ \observed -> do
            prepared <-
                withPreparedProviderShare
                    execution
                    planned
                    observed
                    running
                    (dependencyProbe (pure (Right (managedProviderGeneration running))))
                    spec
                    gate
                    consume
            either (assertFailure . show) id prepared

attachProviderShare ::
    StrongProviderBackend backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO ()
attachProviderShare backend prepared = do
    call <- runProviderShareCall backend prepared
    settled <- either (assertFailure . show) pure (settleProviderShare Nothing prepared call)
    withProviderShareSettlement
        settled
        (\_ _ -> pure ())
        (\_ _ _ _ -> assertFailure "share unexpectedly remained foreign")

-- Fake host -----------------------------------------------------------------

data FakeHost = FakeHost
    { hostRoot :: FilePath
    , statePath :: FilePath
    , fakeIncusPath :: FilePath
    , fakeFlockPath :: FilePath
    , mutationPath :: FilePath
    , waitCounter :: Counter
    }

withFakeHost :: (FakeHost -> IO result) -> IO result
withFakeHost consume =
    withSystemTempDirectory "hostbootstrap-provider-backend" $ \root -> do
        let state = root </> "state"
            fake = root </> "fake-incus"
            fakeFlock = root </> "flock"
            mutations = state </> "mutations"
        createDirectoryIfMissing True state
        createDirectoryIfMissing True (root </> "share")
        writeFile mutations ""
        writeFile fake (fakeIncusProgram state)
        python <- requireExecutable "python3"
        writeFile fakeFlock (fakeFlockProgram python)
        setExecutable fake
        setExecutable fakeFlock
        waits <- newCounter
        consume (FakeHost root state fake fakeFlock mutations waits)

withBackend :: FakeHost -> (forall backendId. StrongProviderBackend backendId -> IO result) -> IO result
withBackend host consume = do
    config <- resolvedHostConfig host
    spec <- either (assertFailure . show) pure (incusSpecForConfig config (statePath host))
    discovered <- discoverStrongProviderBackend (localExec host) spec consume
    either (assertFailure . show) pure discovered

withFaultingBackend :: FakeHost -> (forall backendId. StrongProviderBackend backendId -> IO result) -> IO result
withFaultingBackend host consume = do
    config <- resolvedHostConfig host
    spec <- either (assertFailure . show) pure (incusSpecForConfig config (statePath host))
    discovered <- discoverStrongProviderBackend (faultingExec host) spec consume
    either (assertFailure . show) pure discovered

localExec :: FakeHost -> ProviderBackendExec
localExec host =
    ProviderBackendExec
        { runProviderBackendExec = \request -> case providerBackendRequestView request of
            ProviderBackendProcess commandPath argv
                | not (isAbsolute commandPath) -> pure (RawProviderFailure ("relative executable: " <> commandPath))
                | otherwise -> do
                    outcome <- try (readProcessWithExitCode commandPath argv "")
                    pure $ case outcome of
                        Left failure -> RawProviderFailure (displayException (failure :: IOException))
                        Right (code, out, err) -> RawProviderExit code out err
        , waitProviderBackendExec = \delay -> do
            assertBool "the backend uses a positive bounded wait" (microsValue delay > 0)
            incrementCounter (waitCounter host)
        }

faultingExec :: FakeHost -> ProviderBackendExec
faultingExec host =
    ProviderBackendExec
        { runProviderBackendExec = \request -> case providerBackendRequestView request of
            ProviderBackendProcess commandPath argv
                | not (isAbsolute commandPath) -> pure (RawProviderFailure ("relative executable: " <> commandPath))
                | otherwise -> do
                    let instrumented = case requestOperation (ProviderBackendProcess commandPath argv) of
                            Just _ -> instrumentPythonProgram (faultMarkerPath host) argv
                            Nothing -> argv
                    outcome <- try (readProcessWithExitCode commandPath instrumented "")
                    pure $ case outcome of
                        Left failure -> RawProviderFailure (displayException (failure :: IOException))
                        Right (code, out, err) -> RawProviderExit code out err
        , waitProviderBackendExec = \delay -> do
            assertBool "the backend uses a positive bounded wait" (microsValue delay > 0)
            incrementCounter (waitCounter host)
        }

instrumentPythonProgram :: FilePath -> [String] -> [String]
instrumentPythonProgram marker argv = case break (== "-c") argv of
    (prefix, "-c" : program : rest) -> prefix <> ["-c", faultPrelude marker <> "\n" <> program] <> rest
    _ -> argv

faultPrelude :: FilePath -> String
faultPrelude marker =
    unlines
        [ "import os as _hb_os"
        , "_hb_marker=" <> show marker
        , "_hb_real_write=_hb_os.write; _hb_real_fsync=_hb_os.fsync; _hb_real_unlink=_hb_os.unlink"
        , "_hb_counts={'write':0,'fsync':0,'unlink':0}; _hb_fault=None"
        , "try:"
        , "    with open(_hb_marker,'r',encoding='utf-8') as _hb_file: _hb_parts=_hb_file.read().split()"
        , "    if len(_hb_parts)==3 and len(__import__('sys').argv)>1 and _hb_parts[0]==__import__('sys').argv[1]: _hb_fault=(_hb_parts[1],int(_hb_parts[2]))"
        , "except FileNotFoundError: pass"
        , "def _hb_trip(kind):"
        , "    _hb_counts[kind]+=1"
        , "    if _hb_fault==(kind,_hb_counts[kind]):"
        , "        try: _hb_real_unlink(_hb_marker)"
        , "        except FileNotFoundError: pass"
        , "        _hb_os._exit(97)"
        , "def _hb_write(fd,data):"
        , "    if _hb_fault==('write',_hb_counts['write']+1):"
        , "        _hb_counts['write']+=1; result=_hb_real_write(fd,data[:max(1,len(data)//2)])"
        , "        try: _hb_real_unlink(_hb_marker)"
        , "        except FileNotFoundError: pass"
        , "        _hb_os._exit(97)"
        , "    _hb_counts['write']+=1; return _hb_real_write(fd,data)"
        , "def _hb_fsync(fd): _hb_real_fsync(fd); _hb_trip('fsync')"
        , "def _hb_unlink(path): _hb_real_unlink(path); _hb_trip('unlink')"
        , "_hb_os.write=_hb_write; _hb_os.fsync=_hb_fsync; _hb_os.unlink=_hb_unlink"
        ]

armFault :: FakeHost -> String -> String -> Int -> IO ()
armFault host operation primitive ordinal =
    writeFile (faultMarkerPath host) (unwords [operation, primitive, show ordinal] <> "\n")

resolvedHostConfig :: FakeHost -> IO HostConfig
resolvedHostConfig host = do
    python <- requireExecutable "python3"
    pure
        emptyHostConfig
            { hcToolPaths =
                Map.fromList
                    [ (Incus, fixtureExe (fakeIncusPath host))
                    , (Python3, fixtureExe python)
                    , (Flock, fixtureExe (fakeFlockPath host))
                    ]
            }

incusSpecForConfig :: HostConfig -> FilePath -> Either ReconcileError ProviderBackendSpec
incusSpecForConfig config state =
    mkIncusBackendSpec vmName imageName config state 2 "4GiB" "40GiB"

originPath :: FakeHost -> FilePath
originPath host = statePath host </> (vmName <> ".provider.origin.json")

instanceIdentityPath :: FakeHost -> FilePath
instanceIdentityPath host = statePath host </> "instance.uuid"

instanceOwnerPath :: FakeHost -> FilePath
instanceOwnerPath host = statePath host </> "instance.owner"

instanceStatePath :: FakeHost -> FilePath
instanceStatePath host = statePath host </> "instance.state"

readyFailuresPath :: FakeHost -> FilePath
readyFailuresPath host = statePath host </> "ready-failures"

crashAfterLaunchPath :: FakeHost -> FilePath
crashAfterLaunchPath host = statePath host </> "crash-after-launch"

faultMarkerPath :: FakeHost -> FilePath
faultMarkerPath host = statePath host </> "fault-provider-operation"

replaceAfterReadyPath :: FakeHost -> FilePath
replaceAfterReadyPath host = statePath host </> "replace-after-ready"

replaceAfterStateReadPath :: FakeHost -> FilePath
replaceAfterStateReadPath host = statePath host </> "replace-after-state-read"

replaceAfterDeviceReadPath :: FakeHost -> FilePath
replaceAfterDeviceReadPath host = statePath host </> "replace-after-device-read"

shareRoot :: FakeHost -> FilePath
shareRoot host = hostRoot host </> "share"

deviceSourcePath :: FakeHost -> FilePath -> FilePath
deviceSourcePath host device = statePath host </> ("device." <> device <> ".source")

onlyDevice :: FakeHost -> IO FilePath
onlyDevice host = do
    entries <- listDirectory (statePath host)
    case [drop 7 (take (length entry - 5) entry) | entry <- entries, "device." `isPrefixOf` entry, ".type" `isSuffixOf` entry] of
        [device] -> pure device
        devices -> assertFailure ("expected one device, saw " <> show devices)

takeFileNameForOrigin :: FakeHost -> FilePath
takeFileNameForOrigin = takeFileName . originPath

shareMetadataPaths :: FakeHost -> IO [FilePath]
shareMetadataPaths host = do
    entries <- listDirectory (statePath host)
    pure [statePath host </> entry | entry <- entries, ".share.json" `contains` entry]

shareRecordNonce :: String -> IO String
shareRecordNonce raw =
    case [take 64 (drop (length marker) suffix) | suffix <- tails raw, marker `isPrefixOf` suffix] of
        [nonce] | length nonce == 64 -> pure nonce
        observed -> assertFailure ("expected one 64-hex share nonce, observed " <> show observed)
  where
    marker = "\"nonce\":\""

fakeIncusProgram :: FilePath -> String
fakeIncusProgram state =
    unlines
        [ "#!/bin/sh"
        , "state=" <> shellLiteral state
        , "mutate() { printf '%s\\n' \"$1\" >> \"$state/mutations\"; }"
        , "present() { test -f \"$state/instance.uuid\"; }"
        , "replace_identity() { printf '%s\\n' " <> shellLiteral (takeWhile (/= '\n') replacementIdentity) <> " > \"$state/instance.uuid\"; }"
        , "replace_once() { marker=$1; if test -f \"$marker\"; then rm -f \"$marker\"; replace_identity; fi; }"
        , "after_state_read() { marker=\"$state/replace-after-state-read\"; if test -f \"$marker\"; then remaining=$(cat \"$marker\"); if test \"$remaining\" -le 1; then rm -f \"$marker\"; replace_identity; else printf '%s\\n' $((remaining-1)) > \"$marker\"; fi; fi; }"
        , "case \"$1\" in"
        , "  list)"
        , "    column=$6"
        , "    if present; then if test \"$column\" = n; then printf '%s\\n' \"$2\"; else cat \"$state/instance.state\"; after_state_read; fi; fi"
        , "    exit 0;;"
        , "  launch)"
        , "    name=$3; owner=''"
        , "    for arg in \"$@\"; do case \"$arg\" in user.hostbootstrap.owner=*) owner=${arg#*=};; esac; done"
        , "    mutate launch"
        , "    printf '%s\\n' " <> shellLiteral managedIdentity <> " > \"$state/instance.uuid\""
        , "    printf '%s\\n' \"$owner\" > \"$state/instance.owner\""
        , "    printf 'STOPPED\\n' > \"$state/instance.state\""
        , "    if test -f \"$state/crash-after-launch\"; then rm -f \"$state/crash-after-launch\"; kill -9 \"$PPID\"; exit 1; fi"
        , "    exit 0;;"
        , "  start) mutate start; printf 'RUNNING\\n' > \"$state/instance.state\"; exit 0;;"
        , "  stop) mutate stop; printf 'STOPPED\\n' > \"$state/instance.state\"; exit 0;;"
        , "  delete)"
        , "    mutate delete"
        , "    rm -f \"$state/instance.uuid\" \"$state/instance.owner\" \"$state/instance.state\" \"$state\"/device.*"
        , "    exit 0;;"
        , "  image) test \"$2\" = info && test \"$3\" = " <> shellLiteral imageName <> "; exit $?;;"
        , "  exec)"
        , "    if ! present; then exit 1; fi"
        , "    if test -f \"$state/ready-failures\" && test \"$4\" = true; then"
        , "      remaining=$(cat \"$state/ready-failures\")"
        , "      if test \"$remaining\" -gt 0; then remaining=$((remaining-1)); printf '%s\\n' \"$remaining\" > \"$state/ready-failures\"; printf 'starting\\n' >&2; exit 1; fi"
        , "    fi"
        , "    shift 3; command=$1; \"$@\"; code=$?; if test \"$code\" -eq 0 && test \"$command\" = true; then replace_once \"$state/replace-after-ready\"; fi; exit \"$code\";;"
        , "  config)"
        , "    case \"$2\" in"
        , "      get) case \"$4\" in volatile.uuid) cat \"$state/instance.uuid\";; user.hostbootstrap.owner) cat \"$state/instance.owner\";; *) exit 1;; esac;;"
        , "      device)"
        , "        case \"$3\" in"
        , "          list) for f in \"$state\"/device.*.type; do test -f \"$f\" || continue; b=${f##*/device.}; printf '%s\\n' \"${b%.type}\"; done;;"
        , "          add)"
        , "            device=$5; mutate device-add; printf 'disk\\n' > \"$state/device.$device.type\""
        , "            for arg in \"$@\"; do case \"$arg\" in source=*) printf '%s\\n' \"${arg#*=}\" > \"$state/device.$device.source\";; path=*) printf '%s\\n' \"${arg#*=}\" > \"$state/device.$device.path\";; esac; done;;"
        , "          get) cat \"$state/device.$5.$6\"; if test \"$6\" = path; then replace_once \"$state/replace-after-device-read\"; fi;;"
        , "          *) exit 1;;"
        , "        esac;;"
        , "      *) exit 1;;"
        , "    esac; exit 0;;"
        , "esac"
        , "exit 1"
        ]

fakeFlockProgram :: FilePath -> String
fakeFlockProgram python =
    unlines
        [ "#!" <> python
        , "import fcntl,subprocess,sys"
        , "if len(sys.argv)<4 or sys.argv[1]!='-x': raise SystemExit(2)"
        , "with open(sys.argv[2],'a+b') as lock:"
        , "    fcntl.flock(lock.fileno(),fcntl.LOCK_EX)"
        , "    result=subprocess.run(sys.argv[3:])"
        , "raise SystemExit(result.returncode)"
        ]

-- Small utilities -----------------------------------------------------------

newtype Counter = Counter (MVar Int)

newCounter :: IO Counter
newCounter = Counter <$> newMVar 0

readCounter :: Counter -> IO Int
readCounter (Counter value) = readMVar value

incrementCounter :: Counter -> IO ()
incrementCounter (Counter value) = modifyMVar_ value (pure . (+ 1))

countingSuccessExec :: Counter -> ProviderBackendExec
countingSuccessExec counter =
    ProviderBackendExec
        { runProviderBackendExec = \_ -> incrementCounter counter >> pure (RawProviderExit ExitSuccess "" "")
        , waitProviderBackendExec = const (pure ())
        }

emptyHostConfig :: HostConfig
emptyHostConfig = HostConfig (Substrate LinuxCpu Arm64) Map.empty

directHostConfig :: HostConfig
directHostConfig =
    emptyHostConfig
        { hcToolPaths = Map.fromList [(Python3, fixtureExe fixturePython), (Docker, fixtureExe fixtureDocker)]
        }

fakeResolvedHostConfig :: HostConfig
fakeResolvedHostConfig =
    emptyHostConfig
        { hcToolPaths =
            Map.fromList
                [ (Incus, fixtureExe fixtureIncus)
                , (Python3, fixtureExe fixturePython)
                , (Flock, fixtureExe fixtureFlock)
                ]
        }

{- | The host tools this suite's fixtures name.

Each is rendered onto the host that runs the suite, so the same total 'AbsExe'
constructor production uses admits it on every supported outer host realization
(§ JJ), and the request assertions compare those same values rather than a
POSIX literal the host would call relative.
-}
fixturePython, fixtureDocker, fixtureIncus, fixtureFlock, fixtureLockf :: FilePath
fixturePython = hostFixturePath "/usr/bin/python3"
fixtureDocker = hostFixturePath "/usr/bin/docker"
fixtureIncus = hostFixturePath "/usr/bin/incus"
fixtureFlock = hostFixturePath "/usr/bin/flock"
fixtureLockf = hostFixturePath "/usr/bin/lockf"

providerGate :: Execution.StepExecution scope planId -> IO PreparedGate
providerGate execution = gateFor (Execution.stepExecutionPlanDigest execution) (Execution.stepExecutionOperationKey execution)

providerPlan :: StepPlan
providerPlan = either (error . show) id (mkStepPlan [deployVMStep "provider" testFrame (const (pure StepChanged))])

providerSharePlan :: StepPlan
providerSharePlan =
    either
        (error . show)
        id
        (mkStepPlan [deployVMStep "provider" testFrame (const (pure StepChanged)), copySourceStep "durable share" testFrame (const (pure StepChanged))])

testFrame :: StepFrame
testFrame = StepFrame "host" "Host"

vmName :: String
vmName = "hostbootstrap-provider-test"

imageName :: String
imageName = "images:ubuntu/24.04"

managedIdentity :: String
managedIdentity = "uuid-managed-1111111111111111"

replacementIdentity :: String
replacementIdentity = "uuid-replaced-9999999999999999\n"

setExecutable :: FilePath -> IO ()
setExecutable path = getPermissions path >>= setPermissions path . setOwnerExecutable True

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

requireExecutable :: String -> IO FilePath
requireExecutable name = findExecutable name >>= maybe (assertFailure ("missing test executable " <> name)) pure

readLines :: FilePath -> IO [String]
readLines path = lines <$> readFile path

countOf :: (Eq value) => value -> [value] -> Int
countOf value = length . filter (== value)

contains :: String -> String -> Bool
contains needle haystack = any (needle `isPrefixOf`) (tails haystack)

sortTwo :: (Ord value) => value -> value -> [value]
sortTwo left right = if left <= right then [left, right] else [right, left]

shellLiteral :: String -> String
shellLiteral value = "'" <> concatMap escape value <> "'"
  where
    escape '\'' = "'\\''"
    escape character = [character]

showEither :: (Show error) => Either error value -> String
showEither = either show (const "Right <opaque>")

resolveEitherIO :: Either ReconcileError (IO result) -> IO result
resolveEitherIO = either (assertFailure . show) id

resolveNested2 :: Either ReconcileError (Either ReconcileError (IO result)) -> IO result
resolveNested2 = either (assertFailure . show) resolveEitherIO

resolveNested3 :: Either ReconcileError (Either ReconcileError (Either ReconcileError (IO result))) -> IO result
resolveNested3 = either (assertFailure . show) (either (assertFailure . show) resolveEitherIO)
