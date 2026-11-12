{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ProviderReconcileSpec (tests, shareDescriptorRefusalCaseWith) where

import qualified HostBootstrap.Readiness.Kernel as ProbeKernel
import qualified TestDependency
import Data.List (sort)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified FakeProvider
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary (hostCommand)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (..), mkAbsExe)
import qualified HostBootstrap.Lifecycle.Execution as Execution
import qualified HostBootstrap.Lifecycle.Execution.Core as ExecutionCore (newResourceCarrierCore, newStepRuntimeCore)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Ownership.Object (ObjectIdentity, mkObjectIdentity)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Arm64), Substrate (..), SubstrateName (LinuxCpu))
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Ownership (
    ProviderDeleteOutcome (DeleteAlreadyRemoved, DeleteRemoved),
    ProviderOwnershipFault (ProviderOwnershipStanding),
    ProviderProvisionOutcome (ProvisionAlreadyOwned, ProvisionCreated, ProvisionRecovered),
    ProviderReadyOutcome (ReadyAlready, ReadyStarted),
    ProviderShareOutcome (ShareAlreadyAttached, ShareAttached, ShareRepaired),
    ProviderStopOutcome (StopAlreadyStopped, StopStopped),
 )
import HostBootstrap.Substrate.Provider.Reconcile
import HostBootstrap.Substrate.Provider.Resume (
    ProviderStandingConflict (InstanceReplaced, InstanceUnderNoRecord),
 )
import qualified SourceGuard
import PlatformPath (hostFixturePath)
import PrepareFixture (gateFor, gateForValues)
import System.Directory (canonicalizePath, createDirectory, listDirectory)
import System.FilePath (takeFileName, (</>))
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (readFile')
import System.Environment (getExecutablePath)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

literalToolCases :: [TestTree]
literalToolCases =
    [ testCase "a spec-written tool prints literal data without creating redirected files" $
        withSystemTempDirectory "hostbootstrap-literal-tool" $ \temporary -> do
            root <- canonicalizePath temporary
            tool <- Fixture.newFakeTool root "literal-answer" literalToolReport
            before <- sort <$> listDirectory root
            answer <- runLiteralTool tool
            capturedExit answer @?= ExitSuccess
            capturedStdout answer @?= literalToolReport <> nativeToolNewline
            capturedStderr answer @?= ""
            sort <$> listDirectory root >>= (@?= before)
    , testCase "an exhausting tool preserves literal stdout then exact stderr" $
        withSystemTempDirectory "hostbootstrap-literal-exhaustion" $ \temporary -> do
            root <- canonicalizePath temporary
            tool <- Fixture.newExhaustingFakeTool root "literal-exhaustion" literalToolReport literalToolReport
            before <- sort <$> listDirectory root
            first <- runLiteralTool tool
            capturedExit first @?= ExitSuccess
            capturedStdout first @?= literalToolReport <> nativeToolNewline
            capturedStderr first @?= ""
            second <- runLiteralTool tool
            capturedExit second @?= ExitFailure 1
            capturedStdout second @?= ""
            capturedStderr second @?= literalToolReport <> nativeToolNewline
            after <- sort <$> listDirectory root
            after @?= sort (before <> [takeFileName tool <> ".calls"])
    , testCase "a recording tool quotes output and its apostrophe-bearing transcript path" $
        withSystemTempDirectory "hostbootstrap-literal-recording" $ \temporary -> do
            root <- canonicalizePath temporary
            let transcript = root </> "invocations'capture"
            tool <- Fixture.newRecordingFakeTool root "literal-recording" literalToolReport 0 transcript
            before <- sort <$> listDirectory root
            answer <- runLiteralTool tool
            capturedExit answer @?= ExitSuccess
            capturedStdout answer @?= literalToolReport <> nativeToolNewline
            capturedStderr answer @?= ""
            readFile' transcript >>= (@?= "literal-recording\n")
            after <- sort <$> listDirectory root
            after @?= sort (before <> ["invocations'capture"])
    , testCase "the unused refusing helper and generator stay absent from every test source" $
        SourceGuard.withPackageSourceIn ["test"] $ \_ testRoot -> do
            sources <- SourceGuard.readHaskellSources testRoot
            let forbiddenNames = ["newRefusing" <> "FakeTool", "refusing" <> "ToolProgram"]
            mapM_ (\(path, source) -> mapM_ (\name ->
                assertBool (path <> " still names the deleted fixture helper")
                    (not (Text.isInfixOf (Text.pack name) (Text.pack source)))) forbiddenNames) sources
    ]

literalToolBase :: String
literalToolBase = "{\"a\":\"b>c\"} $HOME " <> [toEnum 96] <> " 50% & | ^ 'quoted'"

literalToolReport :: String
nativeToolNewline :: String
#if defined(mingw32_HOST_OS)
literalToolReport = literalToolBase
nativeToolNewline = "\r\n"
#else
literalToolReport = literalToolBase <> " \233"
nativeToolNewline = "\n"
#endif

runLiteralTool :: FilePath -> IO CapturedRun
runLiteralTool tool = do
    let cfg = testHostConfig{hcToolPaths = Map.singleton Docker (fixtureExe tool)}
    interpretHostCommand cfg (hostCommand Docker []) >>= either assertFailure pure

tests :: TestTree
tests = testGroup "ProviderReconcileSpec" (literalToolCases <> providerCases)

providerCases :: [TestTree]
providerCases =
        [ testCase "a prepared provider creation returns its exact backend-indexed wrapper" $
            withIncusProviderFixture 17 createdBackendReport (settledProvision NoPrior)
                >>= \case
                    Right (Changed Created, "core:deploy-vm", 17, 7, owner) ->
                        assertBool
                            "the prepared binding retains the provider origin"
                            ("hostbootstrap/provider-origin/v2" `Text.isInfixOf` owner)
                    other -> assertFailure ("expected a managed provider creation, got " ++ show other)
        , testCase "an explicitly recovered provider settles Repaired" $
            withIncusProviderFixture 17 repairedProvisionBackendReport (settledProvision NoPrior)
                >>= \case
                    Right (Changed Repaired, "core:deploy-vm", 17, 7, _) -> pure ()
                    other -> assertFailure ("expected a repaired provider wrapper, got " ++ show other)
        , testCase "a backend-proved same-origin provider without prior proof settles Repaired" $
            withIncusProviderFixture 17 ownedProvisionBackendReport (settledProvision NoPrior)
                >>= \case
                    Right (Changed Repaired, "core:deploy-vm", 17, 7, _) -> pure ()
                    other -> assertFailure ("expected recovered managed provider authority, got " ++ show other)
        , testCase "a backend-proved same-origin provider with matching proof settles Unchanged" $
            withIncusProviderFixture 17 ownedProvisionBackendReport (settledProvision MatchingPrior)
                >>= \case
                    Right (Unchanged, "core:deploy-vm", 17, 7, _) -> pure ()
                    other -> assertFailure ("expected unchanged provider authority, got " ++ show other)
        , testCase "a foreign provider remains descriptive and grants no wrapper" $
            withIncusProviderFixture 17 foreignProvisionBackendReport foreignProvision >>= \case
                Right (resourceKey, generation, observation) -> do
                    resourceKey @?= "core:deploy-vm"
                    foreignIdentity observation @?= resourceKey
                    foreignDetail observation @?= "provider stable identity=666f726569676e2d70726f7669646572"
                    generation @?= 9743538103680144570
                other -> assertFailure ("expected the settled foreign identity and generation, got " ++ show other)
        , testCase "Direct admission owns only its plan-local journal reservation" $
            withDirectProviderFixture 17 (directAdmission NoPrior) >>= \case
                Right (Changed Created, owner, resourceKey) -> do
                    assertBool "the prepared owner is a framed provider-origin binding" ("hostbootstrap/provider-origin/v2" `Text.isInfixOf` owner)
                    resourceKey @?= "core:deploy-vm"
                other -> assertFailure ("expected a Direct local admission, got " ++ show other)
        , testCase "Direct admission with matching proof settles Unchanged" $
            withDirectProviderFixture 17 (directAdmission MatchingPrior)
                >>= \case
                    Right (Unchanged, _, "core:deploy-vm") -> pure ()
                    other -> assertFailure ("expected an unchanged Direct reservation, got " ++ show other)
        , testCase "stop, restart-to-ready, stop, and delete preserve one managed generation" $
            ( withIncusBackend createdBackendReport $ \backend ->
                withManagedProviderFixture backend lifecycleSequence
            )
                >>= (@?= Right (17, 12))
        , testCase "already-ready/stopped/deleted reports traverse the same wrapper phase path" $
            ( withIncusBackend alreadyPhaseBackendReport $ \backend ->
                withManagedProviderFixture backend lifecycleSequence
            )
                >>= (@?= Right (17, 12))
        , testCase "a replacement cannot settle a prepared stop" $
            ( withIncusBackend replacementStopBackendReport $ \backend ->
                withManagedProviderFixture backend replacedStop
            )
                >>= \case
                    Left (Conflict detail) ->
                        detail
                            @?= ConflictDetail
                                "core:deploy-vm"
                                "owned generation=17"
                                "replacement generation=17435237075782472532; provider stable identity=7265706c6163656d656e742d766d"
                                "stop provider must leave the replacement untouched and require operator resolution"
                    other -> assertFailure ("expected a replacement conflict, got " ++ show other)
        , testCase "a Direct stop refusal mints no successor phase" $
            ( withDirectBackend $ \backend _root ->
                withManagedProviderFixture backend unsupportedStop
            )
                >>= (@?= Right True)
        , testCase "the host-side share seals its managed provider and exact path declaration" $
            withDirectBackend
                ( \backend root ->
                    (fmap . fmap) ((,) root) (withShareFixture backend root (Right 31) (settledShare NoPrior backend))
                )
                >>= \case
                    Right (root, (Changed Created, "core:copy-source", 29, 11, hostPath, guestPath, providerGeneration)) -> do
                        hostPath @?= root
                        guestPath @?= shareGuestPath
                        providerGeneration @?= 17
                    other -> assertFailure ("expected a prepared Direct share admission, got " ++ show other)
        , testCase "a Direct share refuses a sibling of its admitted root" $ do
            result <- withDirectBackend $ \backend root -> do
                let sibling = root <> "-sibling"
                createDirectory sibling
                withShareFixture backend sibling (Right 31) (settledShare NoPrior backend)
            case result of
                Left (Conflict detail) -> conflictResource detail @?= "direct-host-share"
                other -> assertFailure ("expected sibling-root Direct share conflict, got " <> show other)
        , testCase "a Direct share with matching prior proof settles Unchanged" $
            withDirectBackend (\backend root -> withShareFixture backend root (Right 31) (settledShare MatchingPrior backend))
                >>= \case
                    Right (Unchanged, "core:copy-source", 29, 11, _, _, 17) -> pure ()
                    other -> assertFailure ("expected an unchanged Direct share, got " ++ show other)
        , testCase "an attached provider share settles Created" $
            ( withIncusBackend createdBackendReport $ \backend ->
                withShareFixture backend shareHostPath (Right 31) (settledShare NoPrior backend)
            )
                >>= \case
                    Right (Changed Created, "core:copy-source", 29, 11, _, _, 17) -> pure ()
                    other -> assertFailure ("expected a created provider share, got " ++ show other)
        , testCase "an explicitly repaired provider share settles Repaired" $
            ( withIncusBackend repairedShareBackendReport $ \backend ->
                withShareFixture backend shareHostPath (Right 31) (settledShare NoPrior backend)
            )
                >>= \case
                    Right (Changed Repaired, "core:copy-source", 29, 11, _, _, 17) -> pure ()
                    other -> assertFailure ("expected a repaired provider share, got " ++ show other)
        , testCase "a backend-proved ready share without prior proof settles Repaired" $
            ( withIncusBackend readyShareBackendReport $ \backend ->
                withShareFixture backend shareHostPath (Right 31) (settledShare NoPrior backend)
            )
                >>= \case
                    Right (Changed Repaired, "core:copy-source", 29, 11, _, _, 17) -> pure ()
                    other -> assertFailure ("expected recovered share authority, got " ++ show other)
        , testCase "a backend-proved ready share with matching proof settles Unchanged" $
            ( withIncusBackend readyShareBackendReport $ \backend ->
                withShareFixture backend shareHostPath (Right 31) (settledShare MatchingPrior backend)
            )
                >>= \case
                    Right (Unchanged, "core:copy-source", 29, 11, _, _, 17) -> pure ()
                    other -> assertFailure ("expected unchanged share authority, got " ++ show other)
        , testCase "a failed fresh provider probe refuses share preparation" $
            withDirectBackend
                ( \backend root ->
                    withShareFixture
                        backend
                        root
                        (Left (Failure (FailureDetail "probe provider" "provider stopped answering" ReprobeBeforeRetry)))
                        (\_ _ _ _ -> pure (Right ()))
                )
                >>= \case
                    Left (Failure detail) -> failedOperation detail @?= "probe provider"
                    other -> assertFailure ("expected the dependency probe failure, got " ++ show other)
        , testGroup
            "fresh provider-share preparation"
            [ testCase "the actual share preparation probes its ready provider exactly once" $ do
                probes <- newIORef (0 :: Int)
                callbacks <- newIORef (0 :: Int)
                result <- withDirectBackend $ \backend root ->
                    (fmap . fmap) ((,) root) $
                        withShareFixtureProbe
                            backend
                            root
                            (countedProviderProbe probes (Right 31))
                            providerGate
                            (readIORef probes >>= (@?= 0))
                            ( \plan planned observed prepared -> do
                                readIORef probes >>= (@?= 1)
                                modifyIORef' callbacks (+ 1)
                                settledShare NoPrior backend plan planned observed prepared
                            )
                case result of
                    Right (root, summary) ->
                        summary @?= (Changed Created, "core:copy-source", 29, 11, root, shareGuestPath, 17)
                    other -> assertFailure ("expected the counted prepared share, got " ++ show other)
                readIORef probes >>= (@?= 1)
                readIORef callbacks >>= (@?= 1)
            , testCase "a first-run not-ready provider probe yields no prepared-share continuation" $ do
                probes <- newIORef (0 :: Int)
                callbacks <- newIORef (0 :: Int)
                let refusal = Failure (FailureDetail "probe provider" "provider is not ready" ReprobeBeforeRetry)
                result <- withDirectBackend $ \backend root ->
                    withShareFixtureProbe
                        backend
                        root
                        (countedProviderProbe probes (Left refusal))
                        providerGate
                        (readIORef probes >>= (@?= 0))
                        ( \_ _ _ _ -> do
                            modifyIORef' callbacks (+ 1)
                            pure (Right ())
                        )
                result @?= Left refusal
                readIORef probes >>= (@?= 1)
                readIORef callbacks >>= (@?= 0)
            , testCase "a wrong-plan share gate refuses before its provider probe" $
                shareGateRefusalCase ShareGatePlanMismatch
            , testCase "a wrong-operation share gate refuses before its provider probe" $
                shareGateRefusalCase ShareGateOperationMismatch
            , testCase "a zero-attempt share gate refuses before its provider probe" $
                shareGateRefusalCase ShareGateZeroAttempt
            ]
        , testCase "provider share declarations reject relative paths before preparation" $
            case mkProviderShareSpec "relative/source" "/guest/target" of
                Left (Failure detail) -> failedOperation detail @?= "validate provider share"
                other -> assertFailure ("expected absolute-path validation, got " ++ show other)
        ]

countedProviderProbe :: IORef Int -> Either ReconcileError Word64 -> IO (Either ReconcileError Word64)
countedProviderProbe probes result = do
    modifyIORef' probes (+ 1)
    pure result

data ShareGateRefusal = ShareGatePlanMismatch | ShareGateOperationMismatch | ShareGateZeroAttempt

shareGateRefusalCase :: ShareGateRefusal -> IO ()
shareGateRefusalCase refusal = do
    probes <- newIORef (0 :: Int)
    callbacks <- newIORef (0 :: Int)
    expectedRef <- newIORef Nothing
    result <- withDirectBackend $ \backend root ->
        withShareFixtureProbe
            backend
            root
            (countedProviderProbe probes (Right 31))
            ( \execution -> do
                let planDigest = Execution.stepExecutionPlanDigest execution
                    operation = Execution.stepExecutionOperationKey execution
                    (expected, mintGate) = case refusal of
                        ShareGatePlanMismatch ->
                            ( Conflict
                                ( ConflictDetail
                                    operation
                                    ("a prepare gate from plan " <> planDigest)
                                    "a prepare gate from plan another-plan"
                                    "prepare each operation through its own plan's journal"
                                )
                            , gateFor "another-plan" operation
                            )
                        ShareGateOperationMismatch ->
                            ( Conflict
                                ( ConflictDetail
                                    operation
                                    ("a prepare gate recorded for " <> operation)
                                    "a prepare gate recorded for core:deploy-vm"
                                    "record this operation's unknown phase before preparing it"
                                )
                            , gateFor planDigest "core:deploy-vm"
                            )
                        ShareGateZeroAttempt ->
                            ( Failure (FailureDetail "prepare operation" "attempt must be positive" DoNotRetry)
                            , gateForValues planDigest operation "session-1" 1 0
                            )
                writeIORef expectedRef (Just expected)
                mintGate
            )
            (readIORef probes >>= (@?= 0))
            ( \_ _ _ _ -> do
                modifyIORef' callbacks (+ 1)
                pure (Right ())
            )
    readIORef expectedRef >>= \case
        Just expected -> result @?= Left expected
        Nothing -> assertFailure "the fixture never minted the requested share gate"
    readIORef probes >>= (@?= 0)
    readIORef callbacks >>= (@?= 0)

data PriorMode = NoPrior | MatchingPrior

type ProvisionSummary = (ChangeView, Text.Text, Word64, Word64, Text.Text)

settledProvision ::
    PriorMode ->
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ProvisionSummary)
settledProvision priorMode backend plan _ planned observed prepared = do
    callResult <- provisionCall backend prepared
    pure $ do
        settled <- settleProvisionWithPrior priorMode plan planned observed prepared callResult
        pure $
            withProviderProvisionSettlement
                settled
                ( \managed change ->
                    ( change
                    , managedProviderKey managed
                    , managedProviderGeneration managed
                    , managedProviderObservationVersion managed
                    , preparedProviderBindingOwner (preparedProviderProvisionBinding prepared)
                    )
                )
                (\_ _ _ _ -> error "a created provider must be managed")

settleProvisionWithPrior ::
    PriorMode ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ProviderProvisionSettlement scope planId backendId providerId)
settleProvisionWithPrior priorMode plan planned observed prepared callResult =
    case priorMode of
        NoPrior -> settleProviderProvision Nothing prepared callResult
        MatchingPrior ->
            joinReconcile $
                withMatchingPriorCommit
                    plan
                    planned
                    observed
                    (preparedOperationKey observed (preparedProviderProvisionBinding prepared))
                    (\proof -> settleProviderProvision (Just proof) prepared callResult)

foreignProvision ::
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Text.Text, Word64, ForeignObservation))
foreignProvision backend _ _ _ _ prepared = do
    callResult <- provisionCall backend prepared
    pure $ do
        settled <- settleProviderProvision Nothing prepared callResult
        pure $
            withProviderProvisionSettlement
                settled
                (\_ _ -> error "a foreign observation must not establish ownership")
                (\key generation _ foreignState -> (key, generation, foreignState))

directAdmission ::
    PriorMode ->
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (ChangeView, Text.Text, Text.Text))
directAdmission priorMode backend plan _ planned observed prepared = do
    callResult <- provisionCall backend prepared
    pure $ do
        settled <- settleProvisionWithPrior priorMode plan planned observed prepared callResult
        pure $
            withProviderProvisionSettlement
                settled
                ( \managed change ->
                    ( change
                    , preparedProviderBindingOwner (preparedProviderProvisionBinding prepared)
                    , managedProviderKey managed
                    )
                )
                (\_ _ _ _ -> error "a Direct admission must own its local reservation")

lifecycleSequence ::
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    IO (Either ReconcileError (Word64, Word64))
lifecycleSequence backend _ execution planned provisioned =
    bootProvider backend execution planned provisioned >>= \case
        Left failure -> pure (Left failure)
        Right bootedAdvance ->
            withProviderPhaseAdvance bootedAdvance $ \running -> do
                stopGate <- providerGate execution
                stoppedResult <-
                    joinIO $
                        withPreparedProviderStop execution planned running stopGate $ \prepared -> do
                            callResult <- stopCall backend prepared
                            pure (settleProviderStop prepared callResult)
                case stoppedResult of
                    Left failure -> pure (Left failure)
                    Right stoppedAdvance ->
                        withProviderPhaseAdvance stoppedAdvance $ \stopped -> do
                            readyGate <- providerGate execution
                            runningResult <-
                                joinIO $
                                    withPreparedProviderReady
                                        execution
                                        planned
                                        stopped
                                        (providerStartableAfterStop stopped)
                                        readyGate
                                        ( \prepared -> do
                                            callResult <- readyCall backend prepared
                                            pure (settleProviderReady prepared callResult)
                                        )
                            case runningResult of
                                Left failure -> pure (Left failure)
                                Right runningAdvance ->
                                    withProviderPhaseAdvance runningAdvance $ \runningAgain -> do
                                        secondStopGate <- providerGate execution
                                        secondStopResult <-
                                            joinIO $
                                                withPreparedProviderStop
                                                    execution
                                                    planned
                                                    runningAgain
                                                    secondStopGate
                                                    ( \prepared -> do
                                                        callResult <- stopCall backend prepared
                                                        pure (settleProviderStop prepared callResult)
                                                    )
                                        case secondStopResult of
                                            Left failure -> pure (Left failure)
                                            Right secondStoppedAdvance ->
                                                withProviderPhaseAdvance secondStoppedAdvance $ \stoppedAgain -> do
                                                    deleteGate <- providerGate execution
                                                    joinIO $
                                                        withPreparedProviderDelete
                                                            execution
                                                            planned
                                                            stoppedAgain
                                                            deleteGate
                                                            ( \prepared -> do
                                                                callResult <- deleteCall backend prepared
                                                                pure $ do
                                                                    destroyed <- settleProviderDelete prepared callResult
                                                                    pure $
                                                                        withProviderPhaseAdvance destroyed $ \destroyedHandle ->
                                                                            ( managedProviderGeneration destroyedHandle
                                                                            , managedProviderObservationVersion destroyedHandle
                                                                            )
                                                            )

replacedStop ::
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    IO (Either ReconcileError ())
replacedStop backend _ execution planned provisioned =
    bootProvider backend execution planned provisioned >>= \case
        Left failure -> pure (Left failure)
        Right bootedAdvance ->
            withProviderPhaseAdvance bootedAdvance $ \running -> do
                gate <- providerGate execution
                joinIO $
                    withPreparedProviderStop
                        execution
                        planned
                        running
                        gate
                        ( \prepared -> do
                            callResult <- stopCall backend prepared
                            pure (() <$ settleProviderStop prepared callResult)
                        )

unsupportedStop ::
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    IO (Either ReconcileError Bool)
unsupportedStop backend _ execution planned provisioned =
    bootProvider backend execution planned provisioned >>= \case
        Left failure -> pure (Left failure)
        Right bootedAdvance ->
            withProviderPhaseAdvance bootedAdvance $ \running -> do
                stopGate <- providerGate execution
                stopRefusal <-
                    joinIO $
                        withPreparedProviderStop
                            execution
                            planned
                            running
                            stopGate
                            ( \prepared -> do
                                callResult <- stopCall backend prepared
                                pure (settleProviderStop prepared callResult)
                            )
                pure $
                    Right $ case stopRefusal of
                        Left (Unsupported _) -> True
                        _ -> False

bootProvider ::
    ProviderUnderTest backendId ->
    Execution.StepExecution scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Provisioned ->
    IO (Either ReconcileError (ProviderPhaseAdvance scope planId backendId providerId Provisioned Running))
bootProvider backend execution planned provisioned = do
    gate <- providerGate execution
    joinIO $
        withPreparedProviderReady
            execution
            planned
            provisioned
            (providerStartableAfterProvision provisioned)
            gate
            ( \prepared -> do
                callResult <- readyCall backend prepared
                pure (settleProviderReady prepared callResult)
            )

type ShareSummary = (ChangeView, Text.Text, Word64, Word64, FilePath, FilePath, Word64)

settledShare ::
    PriorMode ->
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ResourceHandle scope planId shareId DurableShareResource Unclassified Observed ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ShareSummary)
settledShare priorMode backend plan planned observed prepared = do
    callResult <- shareCall backend prepared
    pure $ do
        settled <- settleShareWithPrior priorMode plan planned observed prepared callResult
        pure $
            withProviderShareSettlement
                settled
                ( \managed change ->
                    let spec = preparedProviderShareSpec prepared
                     in ( change
                        , managedProviderShareKey managed
                        , managedProviderShareGeneration managed
                        , managedProviderShareObservationVersion managed
                        , providerShareHostPath spec
                        , providerShareGuestPath spec
                        , preparedProviderBindingGeneration (preparedProviderShareBinding prepared)
                        )
                )
                (\_ _ _ _ -> error "a Direct share admission must own its plan-local projection")

settleShareWithPrior ::
    PriorMode ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ResourceHandle scope planId shareId DurableShareResource Unclassified Observed ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ProviderShareSettlement scope planId backendId providerId shareId)
settleShareWithPrior priorMode plan planned observed prepared callResult =
    case priorMode of
        NoPrior -> settleProviderShare Nothing prepared callResult
        MatchingPrior ->
            joinReconcile $
                withMatchingPriorCommit
                    plan
                    planned
                    observed
                    (preparedOperationKey observed (preparedProviderShareBinding prepared))
                    (\proof -> settleProviderShare (Just proof) prepared callResult)

preparedOperationKey ::
    ResourceHandle scope planId resourceId resource Unclassified Observed ->
    PreparedProviderBinding scope planId backendId providerId ->
    Text.Text
preparedOperationKey handle binding =
    resourceHandleKey handle <> ":" <> preparedProviderBindingCallDigest binding

withMatchingPriorCommit ::
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId resourceId resource frame ->
    ResourceHandle scope planId resourceId resource Unclassified Observed ->
    Text.Text ->
    (PriorCommitProof scope planId resourceId resource -> result) ->
    Either ReconcileError result
withMatchingPriorCommit plan planned handle operationKey consume = do
    verified <-
        verifyPersistedJournalRecord
            plan
            planned
            handle
            "acquire"
            PersistedJournalRecord
                { persistedPlanDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
                , persistedFrameKey = plannedResourceFrame planned
                , persistedResourceKey = resourceHandleKey handle
                , persistedGeneration = resourceHandleGeneration handle
                , persistedOperation = "acquire"
                , persistedOperationKey = operationKey
                , persistedRecordVersion = 1
                , persistedPhase = Committed
                }
    withPriorCommitProof verified consume

type ProviderFixtureConsumer summary =
    forall backendId projectId specDigest planId configId providerId providerFrame operationKey callDigest attempt journalVersion.
    ProviderUnderTest backendId ->
    ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
    Execution.StepExecution (Production projectId) planId ->
    PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
    ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
    PreparedProviderProvision
        (Production projectId)
        planId
        backendId
        providerId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO (Either ReconcileError summary)

withIncusProviderFixture ::
    Word64 ->
    ProviderAnswers ->
    ProviderFixtureConsumer summary ->
    IO (Either ReconcileError summary)
withIncusProviderFixture generation answers consume =
    withIncusBackend answers $ \backend ->
        withProviderFixture backend generation consume

withDirectProviderFixture ::
    Word64 ->
    ProviderFixtureConsumer summary ->
    IO (Either ReconcileError summary)
withDirectProviderFixture generation consume =
    withDirectBackend $ \backend _root ->
        withProviderFixture backend generation consume

withProviderFixture ::
    ProviderUnderTest backendId ->
    Word64 ->
    ( forall projectId specDigest planId configId providerId providerFrame operationKey callDigest attempt journalVersion.
      ProviderUnderTest backendId ->
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
      PreparedProviderProvision
        (Production projectId)
        planId
        backendId
        providerId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
withProviderFixture backend generation consume =
    Fixture.withFixtureProjectPlan providerPlan $ \projectPlan ->
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                runtime <- ExecutionCore.newStepRuntimeCore carrier
                let execution = stepExecutionFor projectPlan testHostConfig runtime providerNode
                    operationKey = Execution.stepExecutionOperationKey execution
                gate <- providerGate execution
                joinIO $
                    joinReconcile $
                        withNodeResourceOfKind execution ProviderResourceKind operationKey $ \planned ->
                            joinReconcile $
                                withNodeObservedResource execution planned generation 7 $ \observed ->
                                    withPreparedProviderProvision execution (providerBackendBinding (underTestBackend backend)) planned observed gate $
                                        consume backend projectPlan execution planned observed
            nodes -> fail ("expected one provider node, got " ++ show (length nodes))

withManagedProviderFixture ::
    ProviderUnderTest backendId ->
    ( forall projectId specDigest planId configId providerId providerFrame.
      ProviderUnderTest backendId ->
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      Execution.StepExecution (Production projectId) planId ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Provisioned ->
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
withManagedProviderFixture backend consume =
    withProviderFixture backend 17 $ \exactBackend plan execution planned _ prepared -> do
        callResult <- provisionCall exactBackend prepared
        case settleProviderProvision Nothing prepared callResult of
            Left failure -> pure (Left failure)
            Right settled ->
                withProviderProvisionSettlement
                    settled
                    (\managed _ -> consume exactBackend plan execution planned managed)
                    (\_ _ _ _ -> pure (Left (Failure (FailureDetail "provider fixture" "unexpected foreign provider" DoNotRetry))))

withShareFixture ::
    ProviderUnderTest backendId ->
    FilePath ->
    Either ReconcileError Word64 ->
    ( forall projectId specDigest planId configId providerId shareId shareFrame operationKey callDigest attempt journalVersion.
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ResourceHandle (Production projectId) planId shareId DurableShareResource Unclassified Observed ->
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
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
withShareFixture backend hostPath providerProbe consume =
    withShareFixtureProbe backend hostPath (pure providerProbe) providerGate (pure ()) consume

withShareFixtureProbe ::
    ProviderUnderTest backendId ->
    FilePath ->
    IO (Either ReconcileError Word64) ->
    (forall scope planId. Execution.StepExecution scope planId -> IO PreparedGate) ->
    IO () ->
    ( forall projectId specDigest planId configId providerId shareId shareFrame operationKey callDigest attempt journalVersion.
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ResourceHandle (Production projectId) planId shareId DurableShareResource Unclassified Observed ->
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
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
withShareFixtureProbe = withShareFixtureProbeWithExecution id

withShareFixtureProbeWithExecution ::
    (forall scope planId. Execution.StepExecution scope planId -> Execution.StepExecution scope planId) ->
    ProviderUnderTest backendId ->
    FilePath ->
    IO (Either ReconcileError Word64) ->
    (forall scope planId. Execution.StepExecution scope planId -> IO PreparedGate) ->
    IO () ->
    ( forall projectId specDigest planId configId providerId shareId shareFrame operationKey callDigest attempt journalVersion.
      ProjectPlan.ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      PlannedResource (Production projectId) planId shareId DurableShareResource shareFrame ->
      ResourceHandle (Production projectId) planId shareId DurableShareResource Unclassified Observed ->
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
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
withShareFixtureProbeWithExecution changeExecution backend hostPath providerProbe shareGate beforePrepare consume =
    Fixture.withFixtureProjectPlan providerSharePlan $ \projectPlan ->
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode, shareNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                providerRuntime <- ExecutionCore.newStepRuntimeCore carrier
                shareRuntime <- ExecutionCore.newStepRuntimeCore carrier
                let providerExecution = stepExecutionFor projectPlan testHostConfig providerRuntime providerNode
                    shareExecution = changeExecution (stepExecutionFor projectPlan testHostConfig shareRuntime shareNode)
                    providerKey = Execution.stepExecutionOperationKey providerExecution
                    shareKey = Execution.stepExecutionOperationKey shareExecution
                providerPrepareGate <- providerGate providerExecution
                sharePrepareGate <- shareGate shareExecution
                spec <- either (fail . show) pure (mkProviderShareSpec hostPath shareGuestPath)
                joinIO $
                    joinReconcile $
                        withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
                            joinReconcile $
                                withNodeObservedResource providerExecution plannedProvider 17 7 $ \observedProvider ->
                                    withPreparedProviderProvision providerExecution (providerBackendBinding (underTestBackend backend)) plannedProvider observedProvider providerPrepareGate $ \preparedProvider -> do
                                        provisionResult <- provisionCall backend preparedProvider
                                        case settleProviderProvision Nothing preparedProvider provisionResult of
                                            Left failure -> pure (Left failure)
                                            Right providerResult ->
                                                withProviderProvisionSettlement
                                                    providerResult
                                                    ( \managedProvider _ ->
                                                        bootProvider backend providerExecution plannedProvider managedProvider >>= \case
                                                            Left failure -> pure (Left failure)
                                                            Right bootedAdvance ->
                                                                withProviderPhaseAdvance bootedAdvance $ \runningProvider ->
                                                                    joinIO $
                                                                        joinReconcile $
                                                                            withNodeResourceOfKind shareExecution DurableShareResourceKind shareKey $ \plannedShare ->
                                                                                withNodeObservedResource shareExecution plannedShare 29 11 $ \observedShare -> do
                                                                                    beforePrepare
                                                                                    flattenIO $
                                                                                        withPreparedProviderShare
                                                                                            shareExecution
                                                                                            plannedShare
                                                                                            observedShare
                                                                                            runningProvider
                                                                                            (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind providerProbe)
                                                                                            spec
                                                                                            sharePrepareGate
                                                                                            (consume projectPlan plannedShare observedShare)
                                                    )
                                                    (\_ _ _ _ -> pure (Left (Failure (FailureDetail "share fixture" "unexpected foreign provider" DoNotRetry))))
            nodes -> fail ("expected provider/share nodes, got " ++ show (length nodes))

-- The isolated runtime probe supplies the private descriptor transformation.
-- Ordinary spec compilation imports only the public execution facade.
shareDescriptorRefusalCaseWith ::
    (forall scope planId. Execution.StepExecution scope planId -> Execution.StepExecution scope planId) ->
    IO ()
shareDescriptorRefusalCaseWith changeExecution = do
    positiveProbes <- newIORef (0 :: Int)
    positiveCallbacks <- newIORef (0 :: Int)
    positive <- withDirectBackend $ \backend root ->
        withShareFixtureProbe
            backend
            root
            (countedProviderProbe positiveProbes (Right 31))
            providerGate
            (pure ())
            ( \_ _ _ _ -> do
                modifyIORef' positiveCallbacks (+ 1)
                pure (Right ())
            )
    positive @?= Right ()
    readIORef positiveProbes >>= (@?= 1)
    readIORef positiveCallbacks >>= (@?= 1)
    probes <- newIORef (0 :: Int)
    callbacks <- newIORef (0 :: Int)
    result <- withDirectBackend $ \backend root ->
        withShareFixtureProbeWithExecution
            changeExecution
            backend
            root
            (countedProviderProbe probes (Right 31))
            providerGate
            (pure ())
            ( \_ _ _ _ -> do
                modifyIORef' callbacks (+ 1)
                pure (Right ())
            )
    result
        @?= Left
            ( Conflict
                ( ConflictDetail
                    "core:deploy-vm"
                    "provider declared as a dependency of the durable share"
                    "declared dependencies="
                    "declare the provider resource as a dependency before preparing its share"
                )
            )
    readIORef probes >>= (@?= 0)
    readIORef callbacks >>= (@?= 0)

providerGate :: Execution.StepExecution scope planId -> IO PreparedGate
providerGate execution =
    gateFor
        (Execution.stepExecutionPlanDigest execution)
        (Execution.stepExecutionOperationKey execution)

providerPlan :: StepPlan
providerPlan =
    either
        (error . show)
        id
        (mkStepPlan [deployVMStep "provider" testFrame (const (pure StepChanged))])

providerSharePlan :: StepPlan
providerSharePlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ deployVMStep "provider" testFrame (const (pure StepChanged))
            , copySourceStep "durable share" testFrame (const (pure StepChanged))
            ]
        )

testFrame :: StepFrame
testFrame = StepFrame "host" "Host"

testHostConfig :: HostConfig
testHostConfig =
    HostConfig
        { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Arm64}
        , hcToolPaths = Map.empty
        }

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

{- | The discovered backend, beside the reports its provider produces.

The backend itself holds no execution seam: it carries the typed host
configuration and reaches every process through the one interpreter.  What a
suite about /settlement/ still needs is a provider's answer, and an answer is
a value, so the reports arrive as one total function of the verb and are read
through the exported classifiers (§ NN).  A backend whose reports are
'Nothing' answers through the production call itself, which is what the Direct
realization's structural refusals are about.
-}
data ProviderUnderTest backendId = ProviderUnderTest
    { underTestBackend :: StrongProviderBackend backendId
    , underTestAnswers :: Maybe ProviderAnswers
    }

{- | What one provider answers, for a suite whose subject is settlement.

Every verb is a clause-holding /transaction/ and answers in the transaction
vocabulary, so each case below is reached by applying the exported classifier to
an answer rather than by arranging for a stand-in to have been reached (§ NN).
-}
data ProviderAnswers = ProviderAnswers
    { answeredProvision :: Either ProviderOwnershipFault ProviderProvisionOutcome
    , answeredReady :: Either ProviderOwnershipFault ProviderReadyOutcome
    , answeredStop :: Either ProviderOwnershipFault ProviderStopOutcome
    , answeredShare :: Either ProviderOwnershipFault ProviderShareOutcome
    , answeredDelete :: Either ProviderOwnershipFault ProviderDeleteOutcome
    }

provisionCall ::
    ProviderUnderTest backendId ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
provisionCall underTest prepared = case underTestAnswers underTest of
    Nothing -> runProviderProvisionCall (underTestBackend underTest) prepared
    Just answers -> pure (classifyProviderProvisionCall prepared (answeredProvision answers))

readyCall ::
    ProviderUnderTest backendId ->
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    IO (ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion)
readyCall underTest prepared = case underTestAnswers underTest of
    Nothing -> runProviderReadyCall (underTestBackend underTest) prepared
    Just answers -> pure (classifyProviderReadyCall prepared (answeredReady answers))

stopCall ::
    ProviderUnderTest backendId ->
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
stopCall underTest prepared = case underTestAnswers underTest of
    Nothing -> runProviderStopCall (underTestBackend underTest) prepared
    Just answers -> pure (classifyProviderStopCall prepared (answeredStop answers))

shareCall ::
    ProviderUnderTest backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO (ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion)
shareCall underTest prepared = case underTestAnswers underTest of
    Nothing -> runProviderShareCall (underTestBackend underTest) prepared
    Just answers -> pure (classifyProviderShareCall prepared (answeredShare answers))

deleteCall ::
    ProviderUnderTest backendId ->
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
deleteCall underTest prepared = case underTestAnswers underTest of
    Nothing -> runProviderDeleteCall (underTestBackend underTest) prepared
    Just answers -> pure (classifyProviderDeleteCall prepared (answeredDelete answers))

withDirectBackend ::
    (forall backendId. ProviderUnderTest backendId -> FilePath -> IO (Either ReconcileError summary)) ->
    IO (Either ReconcileError summary)
withDirectBackend consume =
    withRealHostTools $ \config root ->
        case mkDirectHostBackendSpec config root "alpine:3.22" of
            Left failure -> pure (Left failure)
            Right spec ->
                joinReconcile
                    <$> discoverStrongProviderBackend config spec (\backend -> consume (ProviderUnderTest backend Nothing) root)

withIncusBackend ::
    ProviderAnswers ->
    (forall backendId. ProviderUnderTest backendId -> IO (Either ReconcileError summary)) ->
    IO (Either ReconcileError summary)
withIncusBackend answers consume =
    withRealHostTools $ \config _root ->
        case mkIncusBackendSpec "provider" "images:ubuntu/24.04" "provider" config (hostFixturePath "/test/provider-state") 4 "8GiB" "40GiB" of
            Left failure -> pure (Left failure)
            Right spec ->
                joinReconcile
                    <$> discoverStrongProviderBackend config spec (\backend -> consume (ProviderUnderTest backend (Just answers)))

{- | A real directory and spec-chosen stand-in clients.

The binary observes the host root through the real kernel. Its interpreter
launches the configured clients, whose chosen status and streams test the code's
reaction to those inputs and establish no real Docker or Incus behaviour.
-}
withRealHostTools :: (HostConfig -> FilePath -> IO result) -> IO result
withRealHostTools use =
    withSystemTempDirectory "hostbootstrap-provider-tools" $ \temporary -> do
        root <- canonicalizePath temporary
        let admissible = root </> "data"
        createDirectory admissible
        docker <- getExecutablePath
        _ <- FakeProvider.newDockerFixture root (Just ["manifest", "inspect", "alpine:3.22"]) "" 0
        incus <- Fixture.newFakeTool root "incus" ""
        FakeProvider.withFakeProviderClient root $
            use
                testHostConfig
                    { hcToolPaths =
                        Map.fromList
                            [ (Docker, fixtureExe docker)
                            , (Incus, fixtureExe incus)
                            ]
                    }
                admissible

{- | The one host directory this suite's share exposes.

Rendered onto the host that runs the suite, because the provider client that
would mount it runs there; the guest side of the same declaration stays POSIX,
because the process that reads it is inside the realized Linux substrate (§ MM).
-}
shareHostPath :: FilePath
shareHostPath = hostFixturePath "/srv/hostbootstrap/data"

shareGuestPath :: FilePath
shareGuestPath = "/srv/hostbootstrap/data"

-- | The identity a provider answers with for this suite's instance.
managedIdentity :: ObjectIdentity
managedIdentity = either (error . show) id (mkObjectIdentity "provider-17")

-- | The identity of an instance this project's records do not claim.
unclaimedIdentity :: ObjectIdentity
unclaimedIdentity = either (error . show) id (mkObjectIdentity "foreign-provider")

createdBackendReport :: ProviderAnswers
createdBackendReport =
    ProviderAnswers
        { answeredProvision = Right (ProvisionCreated managedIdentity)
        , answeredReady = Right (ReadyStarted managedIdentity)
        , answeredStop = Right (StopStopped managedIdentity)
        , answeredShare = Right ShareAttached
        , answeredDelete = Right DeleteRemoved
        }

ownedProvisionBackendReport :: ProviderAnswers
ownedProvisionBackendReport =
    createdBackendReport{answeredProvision = Right (ProvisionAlreadyOwned managedIdentity)}

repairedProvisionBackendReport :: ProviderAnswers
repairedProvisionBackendReport =
    createdBackendReport{answeredProvision = Right (ProvisionRecovered managedIdentity)}

foreignProvisionBackendReport :: ProviderAnswers
foreignProvisionBackendReport =
    createdBackendReport
        { answeredProvision =
            Left (ProviderOwnershipStanding (InstanceUnderNoRecord unclaimedIdentity))
        }

repairedShareBackendReport :: ProviderAnswers
repairedShareBackendReport = createdBackendReport{answeredShare = Right ShareRepaired}

readyShareBackendReport :: ProviderAnswers
readyShareBackendReport = createdBackendReport{answeredShare = Right ShareAlreadyAttached}

alreadyPhaseBackendReport :: ProviderAnswers
alreadyPhaseBackendReport =
    ProviderAnswers
        { answeredProvision = Right (ProvisionCreated managedIdentity)
        , answeredReady = Right (ReadyAlready managedIdentity)
        , answeredStop = Right (StopAlreadyStopped managedIdentity)
        , answeredShare = Right ShareAlreadyAttached
        , answeredDelete = Right DeleteAlreadyRemoved
        }

replacementStopBackendReport :: ProviderAnswers
replacementStopBackendReport =
    createdBackendReport
        { answeredStop =
            Left (ProviderOwnershipStanding (InstanceReplaced managedIdentity replacementIdentity))
        }

-- | The identity of an instance that replaced this run's under the same name.
replacementIdentity :: ObjectIdentity
replacementIdentity = either (error . show) id (mkObjectIdentity "replacement-vm")

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id

joinIO :: Either ReconcileError (IO (Either ReconcileError value)) -> IO (Either ReconcileError value)
joinIO = either (pure . Left) id

flattenIO :: IO (Either ReconcileError (IO (Either ReconcileError value))) -> IO (Either ReconcileError value)
flattenIO action = action >>= joinIO
