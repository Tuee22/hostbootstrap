{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Real-process coverage for the provider ownership backend.

The lifecycle cases drive the production prepared calls against a real provider
client process and the production protected store, on a real temporary
filesystem.  The client answers only the raw CLI shapes a provider would; it
knows nothing about reconciliation outcomes, and it is this suite's own
executable rather than a wrapper, for the reason "FakeProvider" gives.
-}
module ProviderBackendSpec (tests, backendGuest) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, void, when)
import Data.List (isSuffixOf, sort)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified FakeProvider
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect.Vocabulary (EffectTarget (ToolTarget), HostCommand (commandArguments, commandTarget))
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool
import qualified HostBootstrap.Incus as Incus
import qualified HostBootstrap.Lima as Lima
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Amd64, Arm64), Substrate (..), SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu))
import HostBootstrap.Substrate.Provider (HostPathShare (..), ProviderKind (..), SubstrateProvider, VMHandles (..), selectProviderKind)
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile
import qualified HostBootstrap.Wsl2 as Wsl2
import PlatformPath (hostFixturePath)
import PrepareFixture (gateFor)
import qualified SourceGuard
import System.Directory
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeFileName, (</>))
import System.IO (readFile')
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ProviderBackendSpec"
        (portableCases <> lifecycleCases)

{- | The lifecycle a provider transaction really performs, against a real client.

Every case below drives the production calls through the one interpreter, and
what answers is a real provider client process (see "FakeProvider").  Nothing
here is host-specific: the client is this suite's own executable and its durable
state is ordinary files, so the family runs — and is counted — on every gate host
(§ JJ).
-}
lifecycleCases :: [TestTree]
lifecycleCases =
    [ testCase "provision, fresh boot, share, stop, and conditional delete hold one identity" fullLifecycleCase
    , testCase "retained reverse stops, conditionally deletes, and retires the provider record" retainedReverseCase
    , testCase "concurrent provision enters once and launches once" concurrentProvisionCase
    , testCase "a client that dies after its launch is recovered without relaunching" crashRecoveryCase
    , testCase "readiness retries only a guest that is not answering yet" readinessRetryCase
    , testCase "a replacement between transactions is reported and left untouched" replacementCase
    , testCase "an exact share is idempotent and a changed device is a conflict" shareReadbackCase
    , testCase "an exact restarted VM is retryable rather than a replacement" exactRestartBeforeDeleteCase
    , testCase "Ready rechecks identity across the guest observation" readyObservationReplacementCase
    , testCase "Stop rechecks identity after the stop it issued" stopObservationReplacementCase
    , testCase "a share rechecks its instance after the device readback" shareObservationReplacementCase
    , testCase "a share rechecks its instance after the activating restart" shareRestartReplacementCase
    , testCase "a same-named replacement is left standing rather than forgotten" deleteReplacementLeftStandingCase
    ]

portableCases :: [TestTree]
portableCases =
    [ testCase "Incus construction refuses the wrong substrate before discovery" $ do
        let config = emptyHostConfig{hcSubstrate = Substrate LinuxGpu Arm64}
        case mkIncusBackendSpec vmName imageName vmName config (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected substrate refusal, got " <> showEither other)
    , testCase "Incus construction refuses an instance name whose share socket path cannot fit" $ do
        let config = fakeResolvedHostConfig
            overlong = vmName <> replicate 64 'x'
        case mkIncusBackendSpec overlong imageName vmName config (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected socket-path bound refusal, got " <> showEither other)
    , testCase "Incus construction refuses unresolved ownership tools" $
        case mkIncusBackendSpec vmName imageName vmName emptyHostConfig (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected unresolved-tool refusal, got " <> showEither other)
    , testCase "Lima construction admits only the closed Apple realization" $ do
        case mkLimaBackendSpec fakeResolvedHostConfig limaProvider limaEnvelope limaShare of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Lima host-substrate refusal, got " <> showEither other)
        case mkLimaBackendSpec limaResolvedHostConfig incusProvider limaEnvelope limaShare of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Lima provider-kind refusal, got " <> showEither other)
    , testCase "Lima construction refuses an unresolved Lima tool" $
        case mkLimaBackendSpec limaUnresolvedHostConfig limaProvider limaEnvelope limaShare of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected unresolved Lima-tool refusal, got " <> showEither other)
    , testCase "Lima fingerprints bind the exact budget and writable share" $ do
        baseline <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare)
        retry <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare)
        changedBudget <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope{cpu = 3} limaShare)
        changedShare <- either (assertFailure . show) pure (mkLimaBackendSpec limaResolvedHostConfig limaProvider limaEnvelope limaShare{hpsGuestPath = "/srv/other"})
        baseline @?= retry
        assertBool "a changed Lima budget retained the same backend identity" (baseline /= changedBudget)
        assertBool "a changed Lima share retained the same backend identity" (baseline /= changedShare)
    , testCase "Direct backend discovery is structurally non-mutating" $
        withDirectTools "{}" 0 $ \config root recorded -> do
            spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config root imageName)
            discovered <- discoverStrongProviderBackend config spec (const (pure ()))
            discovered @?= Right ()
            readRecorded recorded >>= (@?= [])
    , testCase "Direct Ready validates the exact root then exact egress image" directReadyValidationCase
    , testCase "Direct Ready stops before egress when root validation fails" directReadyPermissionFailureCase
    , testCase "Direct Ready refuses failed egress without minting Running" directReadyEgressFailureCase
    , testCase "Direct Ready refuses a root that is not this host's canonical path" directReadyNonCanonicalCase
    , testCase "the Incus instance name must carry the project's delete guard prefix" $
        case mkIncusBackendSpec "other-vm" imageName "guarded-" fakeResolvedHostConfig (hostFixturePath "/state") 2 "4GiB" "40GiB" of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected guard-prefix refusal, got " <> showEither other)
    , testCase "the Direct egress probe is a described command" $ do
        commandTarget (directEgressCommand imageName) @?= ToolTarget Docker
        commandArguments (directEgressCommand imageName) @?= ["manifest", "inspect", imageName]
    , testCase "the Direct root admission refuses one observed fact at a time" directRootAdmissionCase
    , testCase "the backend reaches every process through the one interpreter" backendHasNoExecutionSeamCase
    , testCase "settled Ready publishes one pending provider package and live reprobe" providerRuntimePackageCase
    ]

providerRuntimePackageCase :: IO ()
providerRuntimePackageCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withProvisionedProvider backend $ \execution planned _ provisioned -> do
            gate <- providerGate execution
            result <-
                resolveEitherIO $
                    withPreparedProviderReady execution planned provisioned (providerStartableAfterProvision provisioned) gate $ \prepared -> do
                        call <- readyCall backend prepared
                        case settleProviderReady prepared call of
                            Left failure -> pure (Left failure)
                            Right advance ->
                                do
                                    first <- register 100
                                    retry <- register 100
                                    stale <- register 101
                                    carried <- carryRunningProviderSettlement execution advance "provisioned" "provider-adapter-1"
                                    fresh <-
                                        withFreshRunningProviderDependency
                                            execution
                                            "production"
                                            (providerBackendBinding (underTestBackend backend))
                                            "core:deploy-vm"
                                            "runtime://provider/fresh-readiness"
                                            99
                                            "nonce-1"
                                            (const ())
                                    replay <-
                                        withFreshRunningProviderDependency
                                            execution
                                            "production"
                                            (providerBackendBinding (underTestBackend backend))
                                            "core:deploy-vm"
                                            "runtime://provider/fresh-readiness"
                                            99
                                            "nonce-1"
                                            (const ())
                                    expired <-
                                        withFreshRunningProviderDependency
                                            execution
                                            "production"
                                            (providerBackendBinding (underTestBackend backend))
                                            "core:deploy-vm"
                                            "runtime://provider/fresh-readiness"
                                            100
                                            "nonce-2"
                                            (const ())
                                    pure $ do
                                        package <- first
                                        retryPackage <- retry
                                        carried
                                        fresh
                                        if package /= retryPackage
                                            then Left (Failure (FailureDetail "register provider runtime dependency" "exact retry changed the package" DoNotRetry))
                                            else case stale of
                                                Left _
                                                    | either (const True) (const False) replay
                                                        && either (const True) (const False) expired ->
                                                        Right package
                                                    | otherwise -> Left (Failure (FailureDetail "recover provider runtime dependency" "replay or expiry was accepted" DoNotRetry))
                                                Right _ -> Left (Failure (FailureDetail "register provider runtime dependency" "a changed package replaced the pending commitment" DoNotRetry))
                              where
                                register expiry =
                                    registerRunningProviderDependencyPackage
                                        (underTestBackend backend)
                                        execution
                                        "production"
                                        gate
                                        prepared
                                        advance
                                        "runtime://provider/fresh-readiness"
                                        expiry
            void (either (assertFailure . show) pure result)

{- | The Direct root's admission, applied to every observation it refuses.

Five facts and five refusals, each reached by handing the decision a value: the
admission is a total function of what this host answered, so no branch of it
needs a root that actually has the property under test (§ NN).  The observation
itself is taken against the real kernel by 'observeDirectRoot', which the
Direct readiness cases exercise.
-}
directRootAdmissionCase :: IO ()
directRootAdmissionCase = do
    admitDirectRoot root admissible @?= Right ()
    refuses "not absolute" admissible{directRootAbsolute = False}
    refuses "a symbolic link" admissible{directRootSymbolicLink = True}
    refuses "not a directory" admissible{directRootDirectory = False}
    refuses "not canonical" admissible{directRootCanonical = False}
    refuses "not accessible" admissible{directRootAccessible = False}
  where
    root = "/srv/hostbootstrap"
    admissible =
        DirectRootObservation
            { directRootAbsolute = True
            , directRootSymbolicLink = False
            , directRootDirectory = True
            , directRootCanonical = True
            , directRootAccessible = True
            }
    refuses label observed = case admitDirectRoot root observed of
        Left _ -> pure ()
        Right () -> assertFailure ("the Direct root admission admitted " <> label)

{- | The backend holds no execution seam, and the tree carries no name for one.

§ NN's second non-evidence is an injected seam standing in for the subject a gate
claims to cover, so the guard is not that the backend /prefers/ the interpreter
but that there is nothing else it could reach a process through: the module
interprets its described commands, starts no process of its own, and no
production source names the executor record, its request, or either of its
fields.
-}
backendHasNoExecutionSeamCase :: IO ()
backendHasNoExecutionSeamCase = do
    cwd <- getCurrentDirectory
    root <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " <> cwd)) pure
    let sourceRoot = root </> "core" </> "hostbootstrap-core" </> "src"
        backendPath =
            sourceRoot </> "HostBootstrap" </> "Substrate" </> "Provider" </> "Backend.hs"
        executorIdentifiers =
            [ "ProviderBackendExec"
            , "ProviderBackendRequest"
            , "ProviderBackendRequestView"
            , "ProviderBackendProcess"
            , "runProviderBackendExec"
            , "waitProviderBackendExec"
            , "providerBackendRequestView"
            ]
    backendSource <- readFile backendPath
    assertBool
        "the provider backend interprets its described commands"
        (SourceGuard.importsModule "HostBootstrap.Effect.Interpreter" backendSource)
    assertBool
        "the provider backend starts a process of its own"
        (not (SourceGuard.importsModule "System.Process" backendSource))
    productionSources <- listProductionSources sourceRoot
    forM_ productionSources $ \path -> do
        source <- readFile path
        forM_ executorIdentifiers $ \identifier ->
            assertBool
                (takeFileName path <> " names the retired provider executor " <> identifier)
                (SourceGuard.countHaskellIdentifier identifier source == 0)

-- | Every production Haskell source under one root, in a stable order.
listProductionSources :: FilePath -> IO [FilePath]
listProductionSources root = do
    entries <- sort <$> listDirectory root
    concat
        <$> traverse
            ( \entry -> do
                let path = root </> entry
                directory <- doesDirectoryExist path
                if directory
                    then listProductionSources path
                    else pure [path | ".hs" `isSuffixOf` entry]
            )
            entries

directReadyValidationCase :: IO ()
directReadyValidationCase =
    withDirectTools "{\n\t\"schemaVersion\": 2\n}" 0 $ \config root recorded -> do
        result <- runDirectReadyWith config root
        result @?= Right ()
        readRecorded recorded >>= (@?= ["docker"])

directReadyPermissionFailureCase :: IO ()
directReadyPermissionFailureCase =
    withDirectTools "{}" 0 $ \config root recorded -> do
        result <- runDirectReadyWith config (root </> "absent")
        case result of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Direct permission failure, got " <> showEither other)
        readRecorded recorded >>= (@?= [])

directReadyEgressFailureCase :: IO ()
directReadyEgressFailureCase =
    withDirectTools "" 1 $ \config root recorded -> do
        result <- runDirectReadyWith config root
        case result of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected Direct egress failure, got " <> showEither other)
        readRecorded recorded >>= (@?= ["docker"])

{- | A real admissible Direct root, beside a recording egress tool.

The root is a directory this case created, so the admission below runs against
the real kernel rather than against a stand-in for it; the egress probe is the
one described command Direct still issues, and the log is what makes "the
admission ran before the egress" an observation rather than an assumption
(§ NN).
-}
withDirectTools ::
    String ->
    Int ->
    (HostConfig -> FilePath -> FilePath -> IO result) ->
    IO result
withDirectTools egressReport egressStatus use =
    withSystemTempDirectory "hostbootstrap-direct-tools" $ \temporary -> do
        root <- canonicalizePath temporary
        let recorded = root </> "invocations"
            admissible = root </> "data"
        writeFile recorded ""
        createDirectory admissible
        docker <- Fixture.newRecordingFakeTool root "docker" egressReport egressStatus recorded
        use
            emptyHostConfig{hcToolPaths = Map.fromList [(Docker, fixtureExe docker)]}
            admissible
            recorded

readRecorded :: FilePath -> IO [String]
readRecorded path = map trimReturn . lines <$> readFile path
  where
    trimReturn entry = case reverse entry of
        '\r' : rest -> reverse rest
        _ -> entry

{- | A root that is not this host's canonical path for the directory it names.

Taken against the real kernel on every gate host: the path below really does name
the admissible directory and really is not what the host canonicalizes it to, so
the refusal is an observation rather than a stand-in for one (§ NN).  The
symbolic-link refusal the same admission carries is reached by application in
'directRootAdmissionCase', because creating a link is a privilege some outer
hosts withhold and a case that vanished there would be a smaller total rather
than a failed one (§ JJ).
-}
directReadyNonCanonicalCase :: IO ()
directReadyNonCanonicalCase =
    withDirectTools "{}" 0 $ \config root recorded -> do
        let detour = root </> ".." </> takeFileName root
        result <- runDirectReadyWith config detour
        case result of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected noncanonical Direct root refusal, got " <> showEither other)
        readRecorded recorded >>= (@?= [])

runDirectReadyWith :: HostConfig -> FilePath -> IO (Either ReconcileError ())
runDirectReadyWith config root = do
    spec <- either (assertFailure . show) pure (mkDirectHostBackendSpec config root imageName)
    discovered <-
        discoverStrongProviderBackend config spec $ \backend ->
            withProvisionedProvider (ProviderUnderTest backend) $ \execution planned _ provisioned ->
                (() <$)
                    <$> readyProvider
                        (ProviderUnderTest backend)
                        execution
                        planned
                        provisioned
                        (providerStartableAfterProvision provisioned)
    pure (discovered >>= id)

-- End-to-end cases -----------------------------------------------------------

fullLifecycleCase :: IO ()
fullLifecycleCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \execution planned shareExecution _ running shareGate preparedShare -> do
            attached <- shareCall backend preparedShare
            case settleProviderShare Nothing preparedShare attached of
                Left failure -> assertFailure ("share failed: " <> show failure)
                Right settled ->
                    withProviderShareSettlement
                        settled
                        ( \managed _ -> do
                            carried <- carryProviderShareSettlement shareExecution managed "provider-share-v1"
                            carried @?= Right ()
                            registered <-
                                registerProviderShareDependencyPackage
                                    (underTestBackend backend)
                                    shareExecution
                                    "production"
                                    shareGate
                                    preparedShare
                                    managed
                                    "runtime://provider-share/fresh-readiness"
                                    100
                            void (either (assertFailure . show) pure registered)
                            fresh <-
                                withFreshCarriedProviderShareDependency
                                    shareExecution
                                    "production"
                                    (Execution.stepExecutionOperationKey shareExecution)
                                    "runtime://provider-share/fresh-readiness"
                                    99
                                    "share-nonce-1"
                                    (\_ _ -> ())
                            fresh @?= Right ()
                        )
                        (\_ _ _ _ -> assertFailure "share unexpectedly remained foreign")
            stopped <- stopProvider backend execution planned running
            case stopped of
                Left failure -> assertFailure ("stop failed: " <> show failure)
                Right stoppedHandle -> do
                    deleted <- deleteProvider backend execution planned stoppedHandle
                    deleted @?= Right ()
                    heldInstance host vmName >>= (@?= Nothing)
                    durableRecords host >>= (@?= [])

retainedReverseCase :: IO ()
retainedReverseCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \_ _ _ _ -> do
            result <- runRetainedProviderDelete (underTestBackend backend)
            result @?= Right ()
            heldInstance host vmName >>= (@?= Nothing)
            durableRecords host >>= (@?= [])
            mutationsOf host "stop" >>= (@?= 1)
            mutationsOf host "delete" >>= (@?= 1)

{- | Two provisions racing for the same name launch the instance at most once.

The exclusion is the protected store's and is proved across processes by
"AuthoritySpec"; what this case adds is the consequence for the /provider/.  Each
call either entered and now owns the instance or never entered at all — no call
adopts an object it did not create, and the provider is asked to launch exactly
once however the race resolved.
-}
concurrentProvisionCase :: IO ()
concurrentProvisionCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            leftResult <- newEmptyMVar
            rightResult <- newEmptyMVar
            void (forkIO (provisionCall backend prepared >>= putMVar leftResult))
            void (forkIO (provisionCall backend prepared >>= putMVar rightResult))
            first <- takeMVar leftResult
            second <- takeMVar rightResult
            let classify result = case settleProviderProvision Nothing prepared result of
                    Left _ -> "refused" :: String
                    Right settled ->
                        withProviderProvisionSettlement
                            settled
                            (\_ _ -> "managed")
                            (\_ _ _ _ -> "foreign")
                outcomes = sortTwo (classify first) (classify second)
            assertBool
                ("no racing call adopted a foreign instance, got " <> show outcomes)
                ("foreign" `notElem` outcomes)
            assertBool
                ("at least one racing call owns the instance, got " <> show outcomes)
                ("managed" `elem` outcomes)
            mutationsOf host "launch" >>= (@?= 1)

crashRecoveryCase :: IO ()
crashRecoveryCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withPreparedProviderFixture backend 17 $ \_ _ _ prepared -> do
            writeFile (FakeProvider.crashAfterLaunchPath (hostRoot host)) "once\n"
            first <- provisionCall backend prepared
            case settleProviderProvision Nothing prepared first of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected interrupted first call, got " <> showEither (() <$ other))
            durableRecords host >>= (\records -> assertBool "the origin record survived the interruption" (not (null records)))
            second <- provisionCall backend prepared
            case settleProviderProvision Nothing prepared second of
                Right settled ->
                    withProviderProvisionSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "recovery must retain ownership")
                Left failure -> assertFailure ("retry failed: " <> show failure)
            mutationsOf host "launch" >>= (@?= 1)

readinessRetryCase :: IO ()
readinessRetryCase = withFakeHost $ \host -> do
    writeFile (notReadyBudgetPath (hostRoot host)) "2\n"
    withBackend host $ \backend ->
        withRunningProvider backend $ \_ _ _ _ ->
            readFile' (notReadyBudgetPath (hostRoot host)) >>= (\held -> lines held @?= ["0"])

replacementCase :: IO ()
replacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            replaceHeldInstance host vmName
            result <- stopProvider backend execution planned running
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)
            mutationsOf host "stop" >>= (@?= 0)

shareReadbackCase :: IO ()
shareReadbackCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ _ prepared -> do
            first <- shareCall backend prepared
            case settleProviderShare Nothing prepared first of
                Left failure -> assertFailure ("first share failed: " <> show failure)
                Right _ -> pure ()
            before <- mutationsOf host "device-add"
            restartedBefore <- mutationsOf host "restart"
            restartedBefore @?= 1
            second <- shareCall backend prepared
            case settleProviderShare Nothing prepared second of
                Right settled ->
                    withProviderShareSettlement settled (\_ _ -> pure ()) (\_ _ _ _ -> assertFailure "exact owned repeat became foreign")
                Left failure -> assertFailure ("exact repeat failed: " <> show failure)
            after <- mutationsOf host "device-add"
            after @?= before
            mutationsOf host "restart" >>= (@?= restartedBefore)
            device <- onlyDevice host
            retargetDevice host vmName device "/srv/replaced"
            changed <- shareCall backend prepared
            case settleProviderShare Nothing prepared changed of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected changed-device conflict, got " <> showEither (() <$ other))
            deviceSource host vmName device >>= (@?= Just "/srv/replaced")

exactRestartBeforeDeleteCase :: IO ()
exactRestartBeforeDeleteCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            setHeldRunState host vmName "RUNNING"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Failure detail) -> recoveryDisposition detail @?= RetrySameOperationKeyAfterFencing
                other -> assertFailure ("expected exact-provider retry, got " <> showEither other)
            mutationsOf host "delete" >>= (@?= 0)
            heldIdentity host vmName >>= (@?= Just ("instance-" <> vmName))

readyObservationReplacementCase :: IO ()
readyObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withProvisionedProvider backend $ \execution planned _ provisioned -> do
            writeFile (replaceAfterGuestProbePath (hostRoot host)) "once\n"
            result <- readyProvider backend execution planned provisioned (providerStartableAfterProvision provisioned)
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Ready replacement conflict, got " <> showEither other)
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

stopObservationReplacementCase :: IO ()
stopObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            FakeProvider.armReplacementAfter (hostRoot host) "stop"
            result <- stopProvider backend execution planned running
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected Stop replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

{- | Clause 3 binds a device that hangs inside an instance, so the instance is
re-observed after the device readback.

The provider accepts the attachment and something else takes the instance's name
before the record binds.  The device readback answers for the device and for
nothing about whose instance now carries it, so the standing re-taken after it is
what refuses: the transaction reports a conflict rather than binding a record of
this run's to a device inside somebody else's object.
-}
shareObservationReplacementCase :: IO ()
shareObservationReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ _ prepared -> do
            FakeProvider.armReplacementAfter (hostRoot host) "device-add"
            attached <- shareCall backend prepared
            case settleProviderShare Nothing prepared attached of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a share replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

shareRestartReplacementCase :: IO ()
shareRestartReplacementCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProviderAndShare host backend $ \_ _ _ _ _ _ prepared -> do
            FakeProvider.armReplacementAfter (hostRoot host) "restart"
            attached <- shareCall backend prepared
            case settleProviderShare Nothing prepared attached of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a post-restart share replacement conflict, got " <> showEither (() <$ other))
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)

{- | Clause 4 compares the identity, so a same-named replacement is not release.

The provider removes this run's instance and something else immediately takes the
name.  The transaction observes an object present at the name that is not the one
it bound, so it forgets nothing: the record stays, and the replacement is left
exactly as it was found.
-}
deleteReplacementLeftStandingCase :: IO ()
deleteReplacementLeftStandingCase = withFakeHost $ \host ->
    withBackend host $ \backend ->
        withRunningProvider backend $ \execution planned _ running -> do
            stopped <- stopProvider backend execution planned running >>= either (assertFailure . show) pure
            FakeProvider.armReplacementAfter (hostRoot host) "delete"
            result <- deleteProvider backend execution planned stopped
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a replacement refusal, got " <> showEither other)
            heldIdentity host vmName >>= (@?= Just FakeProvider.replacementIdentity)
            durableRecords host >>= (\records -> assertBool "the record was not forgotten over a present name" (not (null records)))

-- Prepared fixtures ---------------------------------------------------------

withPreparedProviderFixture ::
    ProviderUnderTest backendId ->
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
                            withPreparedProviderProvision execution (providerBackendBinding (underTestBackend backend)) planned observed gate $
                                consume execution planned observed
            nodes -> assertFailure ("expected one provider node, got " <> show (length nodes))

withProvisionedProvider ::
    ProviderUnderTest backendId ->
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
        call <- provisionCall backend prepared
        settled <- either (assertFailure . show) pure (settleProviderProvision Nothing prepared call)
        withProviderProvisionSettlement
            settled
            (\managed _ -> consume execution planned prepared managed)
            (\_ _ _ _ -> assertFailure "fixture provider unexpectedly remained foreign")

readyProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId phase ->
    ProviderStartable scope planId backendId providerId phase ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Running))
readyProvider backend execution planned managed startable = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderReady execution planned managed startable gate $ \prepared -> do
            call <- readyCall backend prepared
            pure $ do
                advance <- settleProviderReady prepared call
                pure (withProviderPhaseAdvance advance id)

withRunningProvider ::
    ProviderUnderTest backendId ->
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
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError (ManagedProviderHandle scope planId backendId providerId Stopped))
stopProvider backend execution planned running = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderStop execution planned running gate $ \prepared -> do
            call <- stopCall backend prepared
            pure $ do
                advance <- settleProviderStop prepared call
                pure (withProviderPhaseAdvance advance id)

deleteProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Stopped ->
    IO (Either ReconcileError ())
deleteProvider backend execution planned stopped = do
    gate <- providerGate execution
    resolveEitherIO $
        withPreparedProviderDelete execution planned stopped gate $ \prepared -> do
            call <- deleteCall backend prepared
            pure (() <$ settleProviderDelete prepared call)

withRunningProviderAndShare ::
    FakeHost ->
    ProviderUnderTest backendId ->
    ( forall projectId planId providerId providerFrame shareId shareFrame operationKey callDigest attempt journalVersion.
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      PreparedGate ->
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
                shareSpec <- either (assertFailure . show) pure (mkProviderShareSpec (shareRoot host) shareGuestPath)
                resolveNested3 $
                    withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
                        withNodeObservedResource providerExecution plannedProvider 17 7 $ \observedProvider ->
                            withPreparedProviderProvision providerExecution (providerBackendBinding (underTestBackend backend)) plannedProvider observedProvider providerGateValue $ \preparedProvision -> do
                                provisioned' <- provisionCall backend preparedProvision
                                settled <- either (assertFailure . show) pure (settleProviderProvision Nothing preparedProvision provisioned')
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
                                                    readied <- readyCall backend preparedReady
                                                    readyAdvance <- either (assertFailure . show) pure (settleProviderReady preparedReady readied)
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
                                                                            (consume providerExecution plannedProvider shareExecution plannedShare running shareGateValue)
                                                                    either (assertFailure . show) id preparedResult
                                                )
                                    )
                                    (\_ _ _ _ -> assertFailure "fixture provider unexpectedly remained foreign")
            nodes -> assertFailure ("expected two share-plan nodes, got " <> show (length nodes))

-- The backend under test ----------------------------------------------------

{- | The discovered backend, beside the reports its provider produces.

The backend holds no execution seam: it carries the typed host configuration and
reaches every process through the one interpreter.  A fixture that drives real
programs answers through the production call itself; one whose subject is what a
/report/ means supplies the report as a value and reads it through the exported
classifiers, so no case depends on a substitution point having been reached
(§ NN).
-}
newtype ProviderUnderTest backendId = ProviderUnderTest
    { underTestBackend :: StrongProviderBackend backendId
    }

provisionCall ::
    ProviderUnderTest backendId ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
provisionCall underTest prepared = runProviderProvisionCall (underTestBackend underTest) prepared

readyCall ::
    ProviderUnderTest backendId ->
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    IO (ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion)
readyCall underTest prepared = runProviderReadyCall (underTestBackend underTest) prepared

stopCall ::
    ProviderUnderTest backendId ->
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
stopCall underTest prepared = runProviderStopCall (underTestBackend underTest) prepared

shareCall ::
    ProviderUnderTest backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO (ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion)
shareCall underTest prepared = runProviderShareCall (underTestBackend underTest) prepared

deleteCall ::
    ProviderUnderTest backendId ->
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
deleteCall underTest prepared = runProviderDeleteCall (underTestBackend underTest) prepared

-- The provider this suite drives --------------------------------------------

{- | One fixture root, holding a provider client's state and a protected store.

The client is a real process and the store is the production one, so a lifecycle
case here is the production transaction end to end: nothing between the call and
the object is substituted (§ NN).
-}
data FakeHost = FakeHost
    { hostRoot :: FilePath
    , statePath :: FilePath
    }

withFakeHost :: (FakeHost -> IO result) -> IO result
withFakeHost consume =
    withSystemTempDirectory "hostbootstrap-provider-backend" $ \temporary -> do
        root <- canonicalizePath temporary
        let state = root </> "state"
        createDirectoryIfMissing True state
        createDirectoryIfMissing True (root </> "share")
        _ <- FakeProvider.newProviderFixture root backendRole FakeProvider.ProviderAnswers
        FakeProvider.withFakeProviderClient root (consume (FakeHost root state))

-- | The role this suite declares its provider fixtures under.
backendRole :: String
backendRole = "backend"

{- | What answers inside the instance for this suite's backend fixtures.

The only vector the provider driver crosses with is the readiness probe, so a
different one is a refusal rather than a success: a driver that starts asking the
guest for something new fails this fixture instead of passing through it.
-}
backendGuest :: FakeProvider.GuestHandler
backendGuest root name _role argv
    | argv /= ["true"] =
        pure (RawProviderFailure ("the backend fixture guest was asked to run " <> show argv))
    | otherwise = do
        armed <- doesFileExist (replaceAfterGuestProbePath root)
        when armed $ do
            removeFile (replaceAfterGuestProbePath root)
            FakeProvider.alterInstance
                root
                name
                (\held -> held{FakeProvider.instanceIdentity = FakeProvider.replacementIdentity})
        remaining <- notReadyBudget root
        if remaining > 0
            then do
                writeFile (notReadyBudgetPath root) (show (remaining - 1) <> "\n")
                pure (RawProviderExit (ExitFailure 1) "" "the guest is not answering yet\n")
            else pure (RawProviderExit ExitSuccess "" "")

{- | How many more readiness probes answer "not answering yet".

Durable, because the probe runs in a second process and a poll that retried is a
property of what that process answered rather than of a counter beside it.
-}
notReadyBudgetPath :: FilePath -> FilePath
notReadyBudgetPath root = root </> "not-ready-budget"

notReadyBudget :: FilePath -> IO Int
notReadyBudget root = do
    present <- doesFileExist (notReadyBudgetPath root)
    if present
        then do
            held <- readFile' (notReadyBudgetPath root)
            pure (case reads held of [(value, _)] -> value; _ -> 0)
        else pure 0

-- | Arm the guest to be a different instance's by the time its probe returns.
replaceAfterGuestProbePath :: FilePath -> FilePath
replaceAfterGuestProbePath root = root </> "replace-after-guest-probe"

withBackend :: FakeHost -> (forall backendId. ProviderUnderTest backendId -> IO result) -> IO result
withBackend host consume = do
    config <- resolvedHostConfig
    spec <- either (assertFailure . show) pure (incusSpecForConfig config (statePath host))
    discovered <-
        discoverStrongProviderBackend config spec (\backend -> consume (ProviderUnderTest backend))
    either (assertFailure . show) pure discovered

{- | A host configuration whose provider client is this suite's own executable.

§ KK's one interpreter launches whatever the configuration resolves, and the
guest vectors this project crosses with carry whole programs, so a wrapper
script is not an option: the program has to be one that receives the exact
argument vector.  "FakeProvider" explains the arrangement.
-}
resolvedHostConfig :: IO HostConfig
resolvedHostConfig = do
    self <- getExecutablePath
    pure
        HostConfig
            { hcSubstrate = Substrate LinuxCpu Amd64
            , hcToolPaths = Map.fromList [(Incus, fixtureExe self)]
            }

incusSpecForConfig :: HostConfig -> FilePath -> Either ReconcileError ProviderBackendSpec
incusSpecForConfig config state =
    mkIncusBackendSpec vmName imageName vmName config state 2 "2GiB" "12GiB"

-- What the provider and the store are holding ---------------------------------

heldInstance :: FakeHost -> String -> IO (Maybe FakeProvider.ProviderInstance)
heldInstance host = FakeProvider.instanceNamed (hostRoot host)

heldIdentity :: FakeHost -> String -> IO (Maybe String)
heldIdentity host name = fmap (fmap FakeProvider.instanceIdentity) (heldInstance host name)

replaceHeldInstance :: FakeHost -> String -> IO ()
replaceHeldInstance host name =
    FakeProvider.alterInstance
        (hostRoot host)
        name
        (\held -> held{FakeProvider.instanceIdentity = FakeProvider.replacementIdentity})

setHeldRunState :: FakeHost -> String -> String -> IO ()
setHeldRunState host name state =
    FakeProvider.alterInstance
        (hostRoot host)
        name
        (\held -> held{FakeProvider.instanceRunState = state})

retargetDevice :: FakeHost -> String -> String -> String -> IO ()
retargetDevice host name device source =
    FakeProvider.alterInstance
        (hostRoot host)
        name
        ( \held ->
            held
                { FakeProvider.instanceDevices =
                    [ (key, if key == device then ("source", source) : filter ((/= "source") . fst) properties else properties)
                    | (key, properties) <- FakeProvider.instanceDevices held
                    ]
                }
        )

deviceSource :: FakeHost -> String -> String -> IO (Maybe String)
deviceSource host name device = do
    held <- heldInstance host name
    pure (held >>= lookup device . FakeProvider.instanceDevices >>= lookup "source")

onlyDevice :: FakeHost -> IO String
onlyDevice host = do
    held <- heldInstance host vmName
    case fmap (map fst . FakeProvider.instanceDevices) held of
        Just [device] -> pure device
        other -> assertFailure ("expected exactly one attached device, got " <> show other)

mutationsOf :: FakeHost -> String -> IO Int
mutationsOf host verb = countOf verb <$> FakeProvider.recordedProviderMutations (hostRoot host)

-- | The durable records the protected store is holding, by name.
durableRecords :: FakeHost -> IO [FilePath]
durableRecords host = do
    let records = statePath host </> "records"
    present <- doesDirectoryExist records
    if present then sort <$> listDirectory records else pure []

shareRoot :: FakeHost -> FilePath
shareRoot host = hostRoot host </> "share"

{- | Where the guest sees this suite's share.

POSIX on every outer host, because the frame that reads it is the Linux substrate
the provider realizes; the host side is the outer host's own grammar, because the
provider client that mounts it runs there (§ MM).
-}
shareGuestPath :: FilePath
shareGuestPath = "/srv/hostbootstrap/data"

emptyHostConfig :: HostConfig
emptyHostConfig = HostConfig (Substrate LinuxCpu Arm64) Map.empty

fakeResolvedHostConfig :: HostConfig
fakeResolvedHostConfig =
    emptyHostConfig
        { hcToolPaths =
            Map.fromList
                [(Incus, fixtureExe fixtureIncus)]
        }

limaResolvedHostConfig :: HostConfig
limaResolvedHostConfig =
    HostConfig
        (Substrate AppleSilicon Arm64)
        (Map.fromList [(Lima, fixtureExe fixtureLima)])

limaUnresolvedHostConfig :: HostConfig
limaUnresolvedHostConfig = HostConfig (Substrate AppleSilicon Arm64) Map.empty

limaProvider, incusProvider :: SubstrateProvider
limaProvider = selectProviderKind ProviderLima providerHandles
incusProvider = selectProviderKind ProviderIncus providerHandles

providerHandles :: VMHandles
providerHandles =
    VMHandles
        { vmhIncus = Incus.IncusVM vmName imageName
        , vmhLima = Lima.LimaVM vmName
        , vmhWsl2 = Wsl2.Wsl2VM vmName
        , vmhGuardPrefix = vmName
        }

limaEnvelope :: ResourceEnvelope
limaEnvelope = ResourceEnvelope{cpu = 2, memory = "4GiB", storage = "40GiB"}

limaShare :: HostPathShare
limaShare = HostPathShare (hostFixturePath "/share") "/srv/hostbootstrap/data" Nothing

{- | The host tools this suite's fixtures name.

Each is rendered onto the host that runs the suite, so the same total 'AbsExe'
constructor production uses admits it on every supported outer host realization
(§ JJ), and the request assertions compare those same values rather than a
POSIX literal the host would call relative.
-}
fixtureIncus :: FilePath
fixtureIncus = hostFixturePath "/usr/bin/incus"

fixtureLima :: FilePath
fixtureLima = hostFixturePath "/usr/bin/limactl"

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

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

countOf :: (Eq value) => value -> [value] -> Int
countOf value = length . filter (== value)

sortTwo :: (Ord value) => value -> value -> [value]
sortTwo left right = if left <= right then [left, right] else [right, left]

showEither :: (Show error) => Either error value -> String
showEither = either show (const "Right <opaque>")

resolveEitherIO :: Either ReconcileError (IO result) -> IO result
resolveEitherIO = either (assertFailure . show) id

resolveNested2 :: Either ReconcileError (Either ReconcileError (IO result)) -> IO result
resolveNested2 = either (assertFailure . show) resolveEitherIO

resolveNested3 :: Either ReconcileError (Either ReconcileError (Either ReconcileError (IO result))) -> IO result
resolveNested3 = either (assertFailure . show) (either (assertFailure . show) resolveEitherIO)
