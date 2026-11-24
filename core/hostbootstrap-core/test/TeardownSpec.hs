{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The verb-indexed reverse projection and its teardown forest (the recursive-lifecycle-command phase).

The plan under test is the demo's own shape: a metal frame that ensures the
provider (preserve-on-reverse) and launches the VM, a VM frame that builds, and
a container frame that stands up the cluster and the chart. That shape is what
makes the child-first and pre-descent properties observable rather than
hypothetical.
-}
module TeardownSpec (tests, validPreparation, withNestedRootedCatalog) where

import qualified BudgetSpec as BudgetFixture
import qualified CompileFailSpec
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.MVar (newMVar, readMVar)
import Control.Monad (forM_)
import qualified Control.Exception as Exception
import qualified HostBootstrap.Authority.FailedUp.Internal as FailedUp
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, sort)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import qualified Fixture
import qualified HandoffSpec as HandoffFixture
import qualified LifecycleSpec as LivePrepareFixture
import qualified RecursiveLifecycleSpec as RecursiveFixture
import Expect (expectRight)
import qualified HostBootstrap.Authority as Authority
import qualified HostBootstrap.Authority.Testing as AuthorityFixture
import qualified HostBootstrap.Authority.ProjectPlan as ProjectAuthority
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Schema (withValidatedConfig)
import qualified HostBootstrap.Lifecycle.Context as LifecycleContext
import qualified HostBootstrap.Lifecycle.Session as Session
import HostBootstrap.Lifecycle.Prepared (decodeFields, encodeFields)
import HostBootstrap.Lifecycle.Mode (LifecycleCursor, productionActiveMode, productionRootAuthority, productionRootModeLease, productionRootUnboundLease, withAcquisitionJournal, withExecuteLifecycleCursor, withLifecycleCursor, withProductionLifecycleProfile, withProductionRoot)
import qualified HostBootstrap.Lift.Context as LiftContext
import HostBootstrap.ProjectPlan.Construct (finalizedProjectCodec, projectPlanDrafts, withFinalizedProjectSpec, withProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot (withPersistedPlanSnapshot)
import HostBootstrap.ProjectRoot (canonicalProjectRootPath, withCanonicalProjectRoot)
import HostBootstrap.Protected
import qualified HostBootstrap.Reconcile as Reconcile
import HostBootstrap.Service (emptyServiceRegistry)
import qualified TestCatalogFixtures
import qualified TestForwardHandoff
import qualified TestHandoffRuntime
import qualified TestRootedSession
import qualified TestRootedNode
import qualified TestFrameExecutor
import qualified TestPreparedGate
import qualified TestRootedReceipt
import qualified HostBootstrap.Handoff.Rooted as Rooted
import qualified TestLifecyclePlan
import qualified TestRootedPlan
import qualified TestTeardown
import qualified TestReversePolicy
import qualified TestTeardownExecutor
import qualified TestTeardownInternal
import HostBootstrap.Authority (
    ProjectVerb (..),
    VerbDestroy,
    VerbDown,
    projectVerbName,
 )
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Handoff (frameWire, harnessScopeTagFor, productionScopeTag, renderLifecycleObservations)
import qualified HostBootstrap.Handoff as Handoff
import qualified HostBootstrap.Handoff.Completion as Completion
import qualified HostBootstrap.Handoff.TerminalReport as TerminalReport
import qualified HostBootstrap.Handoff.Internal as HandoffInternal
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    plannedStepOperationKey,
    plannedStepReversePolicy,
    renderSnapshot,
    stablePlanSnapshotDigest,
 )
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.ProjectPlan.Frame (CurrentFrame, currentFrameId, withCurrentFrame)
import HostBootstrap.Step
import HostBootstrap.Substrate (detect)
import HostBootstrap.Teardown
import HostBootstrap.Teardown.Preparation (PreparationFacts (..), classifyPreparedRecord, renderReverseAdapterKernel, validatePreparation, validateRecoveryOfferScope)
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

data ExecutorFixtureNode = ExecutorFixtureNode Text Text [(Text, Text)] [Text] (Maybe ())

data ZeroGenerationRuntime = ZeroGenerationRuntime (Authority.ProjectVerb Authority.VerbUp) Text Text Text Word64 ByteString.ByteString
data DownFixtureRuntime = DownFixtureRuntime (Authority.ProjectVerb Authority.VerbDown) Text Text Text Word64 ByteString.ByteString

tests :: TestTree
tests =
    testGroup
        "TeardownSpec"
        [ testGroup "prepared descent kernel" preparedKernelTests
        , CompileFailSpec.withPrivateEntryKernel privateFailedUpEntrySource $ \getExecutable ->
            testCase "failed-Up entry wrappers reject a foreign catalog" $ do
                executable <- getExecutable
                (code, output, diagnostic) <- readProcessWithExitCode executable [] ""
                assertBool (output <> diagnostic) (code == ExitSuccess)
        , testGroup "preparation admission" preparationTests
        , testGroup "rooted frame openings"
            [ testCase "nested canonical and direct openings retain catalog lineage in distinct rows" $
                withNestedRootedCatalog $ \store project root catalog -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 36))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        let expected = TestRootedPlan.withRootedPlanCatalogRootKernel catalog (\_ _ plan _ _ -> stablePlanSnapshotDigest (renderSnapshot plan))
                            inspect path session = TestRootedSession.withRootedFrameSessionKernel session $ \_ _ lineage _ frame actualPath _ _ _ _ -> do
                                lineage @?= expected
                                frame @?= "vm-project-container-2"
                                actualPath @?= path
                                pure (Right ())
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-project-container-2" $ \canonical -> do
                            expectRight =<< inspect ["vm-orchestrator-1", "vm-project-container-2"] canonical
                            TestRootedSession.withRootOpenedDirectFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-project-container-2" $ \direct -> do
                                expectRight =<< inspect ["vm-project-container-2"] direct
                                rows <- protectedImage store
                                length (filter (Text.isPrefixOf "rooted-frame-session" . first3) rows) @?= 2
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "direct openings require a non-root admitted frame and use a distinct row" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 37))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        let refuse name = TestRootedSession.withRootOpenedDirectFrameSessionKernel runtime catalog store Authority.ProjectUp name (\_ -> assertFailure "an unadmitted frame opened")
                        before <- protectedImage store
                        refuse "host-orchestrator-0" >>= (@?= Left "rooted frame session: the root frame has no rooted requester path")
                        refuse "unadmitted" >>= (@?= Left "rooted frame session: no admitted descent edge names the requested frame")
                        protectedImage store >>= (@?= before)
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \canonical ->
                            TestRootedSession.withRootOpenedDirectFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \direct ->
                                TestRootedSession.withRootedFrameSessionKernel canonical $ \_ _ lineage identity frame canonicalPath canonicalToken _ _ _ ->
                                    TestRootedSession.withRootedFrameSessionKernel direct $ \_ _ _ _ _ directPath directToken _ _ _ -> do
                                        canonicalPath @?= directPath
                                        assertBool "opening modes mint distinct session tokens" (canonicalToken /= directToken)
                                        canonicalKey <- expectRight (Session.rootedSettlementKeyKernel lineage identity frame canonicalToken "operation" 1)
                                        directKey <- expectRight (Session.rootedSettlementKeyKernel lineage identity frame directToken "operation" 1)
                                        assertBool "opening modes address different settlement rows" (canonicalKey /= directKey)
                                        inserted <- withProtectedEntry store $ \protected -> do
                                            first <- expectRight =<< Session.publishRootedSettlementRowKernel protected canonicalKey "canonical"
                                            replay <- expectRight =<< Session.publishRootedSettlementRowKernel protected canonicalKey "canonical"
                                            first @?= replay
                                            _ <- expectRight =<< Session.publishRootedSettlementRowKernel protected directKey "direct"
                                            pure (Right ())
                                        expectRight inserted
                                        rows <- protectedImage store
                                        length (filter (Text.isPrefixOf "rooted-frame-session" . first3) rows) @?= 2
                                        length (filter (Text.isPrefixOf "rooted-node-settlement" . first3) rows) @?= 2
                                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \reopened ->
                                            TestRootedSession.withRootedFrameSessionKernel reopened $ \_ _ _ _ _ _ token _ _ _ -> do
                                                token @?= canonicalToken
                                                TestRootedSession.withRootOpenedDirectFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \reopenedDirect ->
                                                    TestRootedSession.withRootedFrameSessionKernel reopenedDirect $ \_ _ _ _ _ _ directReplay _ _ _ -> do
                                                        directReplay @?= directToken
                                                        protectedImage store >>= (@?= rows)
                                                        pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "an exact rooted opening replay converges and changed requests refuse" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 38))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        request <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 9))
                        changed <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                        let wire = Rooted.renderRootedLifecycleRequestKernel request
                            changedWire = Rooted.renderRootedLifecycleRequestKernel changed
                            sign exact unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker exact unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session -> do
                            responses <- newIORef []
                            let capture _ signed = modifyIORef' responses (<> [signed]) >> pure (Right ())
                                open path exact = TestRootedSession.withRootedFrameOpeningKernel runtime session store path exact (sign exact) capture
                            open ["vm-orchestrator-1"] wire >>= (@?= Right ())
                            afterFirst <- protectedImage store
                            open ["vm-orchestrator-1"] wire >>= (@?= Right ())
                            observed <- readIORef responses
                            case observed of
                                [first, replay] -> replay @?= first
                                _ -> assertFailure "the exact opening was not answered twice"
                            protectedImage store >>= (@?= afterFirst)
                            open ["vm-orchestrator-1"] changedWire >>= (@?= Left "rooted frame session: session: the the rooted frame session row conflicts record is unreadable")
                            open ["other-frame"] wire >>= (@?= Left "rooted frame session: the sealed external envelope is not the session's own path")
                            protectedImage store >>= (@?= afterFirst)
                            pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "a faulty signer cannot attach a rooted opening" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 38))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        request <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 9))
                        let wire = Rooted.renderRootedLifecycleRequestKernel request
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session -> do
                            before <- protectedImage store
                            result <- TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire (\_ -> pure (Right "invalid")) (\_ _ -> assertFailure "a faulty signature attached")
                            assertBool "the invalid signed response was refused" (case result of Left _ -> True; Right _ -> False)
                            protectedImage store >>= (@?= before)
                            pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "signed openings with foreign coordinates refuse before attachment" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 39))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        request <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 9))
                        let wire = Rooted.renderRootedLifecycleRequestKernel request
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Handoff.renderRootedLifecycleResponse response)
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameSessionKernel session $ \_ _ _ _ _ path token stage ordinal _ -> do
                                before <- protectedImage store
                                let variants =
                                        [ ("ancestry", ["foreign", "vm-orchestrator-1"], token, stage, ordinal)
                                        , ("frame", ["foreign-frame"], token, stage, ordinal)
                                        , ("session", path, token <> "-foreign", stage, ordinal)
                                        , ("stage", path, token, "foreign", ordinal)
                                        , ("ordinal", path, token, stage, ordinal + 1)
                                        ]
                                forM_ variants $ \(label, foreignPath, foreignToken, foreignStage, foreignOrdinal) -> do
                                    unsigned <- expectRight (Rooted.rootedOpenedResponseUnsignedKernel (Handoff.childConfigDigest wire) foreignPath foreignToken foreignStage foreignOrdinal)
                                    signed <- sign unsigned
                                    result <- TestRootedSession.withRootedFrameOpeningKernel runtime session store path wire (\_ -> pure (Right signed)) (\_ _ -> assertFailure "a foreign signed opening attached")
                                    result @?= Left "rooted frame session: the signed opening differs from the rendered Opened response"
                                    protectedImage store >>= (@?= before)
                                    assertBool ("tested " <> label) (not (null label))
                                postRequest <- expectRight (Rooted.rootedNextNodeRequestKernel path token stage ordinal (ByteString.replicate 32 12) (Text.replicate 64 "a"))
                                let postWire = Rooted.renderRootedLifecycleRequestKernel postRequest
                                postDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest postWire))
                                checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                checkedStage <- expectRight (Rooted.mkLifecycleStage "refused")
                                checkedOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                foreignFamily <- expectRight (Rooted.rootedRefusedResponseUnsignedKernel postDigest path checkedToken checkedStage checkedOrdinal (ByteString.replicate 32 12) "foreign family")
                                foreignSigned <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker postWire foreignFamily
                                wrongFamily <- TestRootedSession.withRootedFrameOpeningKernel runtime session store path wire (\_ -> pure (Right (Handoff.renderRootedLifecycleResponse foreignSigned))) (\_ _ -> assertFailure "a foreign response family attached")
                                wrongFamily @?= Left "rooted frame session: the signed opening is not an Opened response"
                                protectedImage store >>= (@?= before)
                                wrongEnvelope <- TestRootedSession.withRootedFrameOpeningKernel runtime session store ["foreign-frame"] wire (\_ -> assertFailure "a foreign envelope reached signing") (\_ _ -> assertFailure "a foreign envelope attached")
                                wrongEnvelope @?= Left "rooted frame session: the sealed external envelope is not the session's own path"
                                protectedImage store >>= (@?= before)
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "forward node observations bind projected use and resource evidence" $ do
                let taken = Rooted.RootedProjectedObservation "image" True (Just ("vm", Just "old", "new"))
                    unused = Rooted.RootedProjectedObservation "cache" False Nothing
                    own = Rooted.RootedProjectedObservation "build" True Nothing
                    report = Rooted.RootedNodeObservation "build" True "" [own, taken, unused]
                wire <- expectRight (Rooted.renderRootedNodeObservationKernel report)
                Rooted.readRootedNodeObservationKernel wire @?= Right report
                Rooted.readRootedNodeObservationForPlanKernel "vm" "build" ["image", "cache"] wire @?= Right report
                noOwnWire <- expectRight (Rooted.renderRootedNodeObservationKernel (Rooted.RootedNodeObservation "build" True "" [Rooted.RootedProjectedObservation "build" False Nothing, taken, unused]))
                assertBool "untaken node refused" (case Rooted.readRootedNodeObservationForPlanKernel "vm" "build" ["image", "cache"] noOwnWire of Left _ -> True; Right _ -> False)
                assertBool "foreign resource frame refused" (case Rooted.readRootedNodeObservationForPlanKernel "foreign-frame" "build" ["image", "cache"] wire of Left _ -> True; Right _ -> False)
                assertBool "foreign node refused" (case Rooted.readRootedNodeObservationForPlanKernel "vm" "foreign" ["image", "cache"] wire of Left _ -> True; Right _ -> False)
                assertBool "foreign projections refused" (case Rooted.readRootedNodeObservationForPlanKernel "vm" "build" ["image", "other"] wire of Left _ -> True; Right _ -> False)
                assertBool "reordered projections refused" (case Rooted.readRootedNodeObservationForPlanKernel "vm" "build" ["cache", "image"] wire of Left _ -> True; Right _ -> False)
                assertBool "trailing data refused" (case Rooted.readRootedNodeObservationKernel (wire <> "x") of Left _ -> True; Right _ -> False)
                assertBool "truncated observation refused" (case Rooted.readRootedNodeObservationKernel (ByteString.take (ByteString.length wire - 1) wire) of Left _ -> True; Right _ -> False)
                assertBool "duplicate projection refused" (case Rooted.renderRootedNodeObservationKernel (Rooted.RootedNodeObservation "build" True "" [taken, taken]) of Left _ -> True; Right _ -> False)
                assertBool "unused settlement refused" (case Rooted.renderRootedNodeObservationKernel (Rooted.RootedNodeObservation "build" True "" [Rooted.RootedProjectedObservation "image" False (Just ("vm", Nothing, "new"))]) of Left _ -> True; Right _ -> False)
            , testCase "reverse resource observations bind exact frame and ordered membership" $ do
                let first = Rooted.RootedReverseResource "vm" "cluster" "old" "released"
                    second = Rooted.RootedReverseResource "vm" "chart" "old-chart" "released-chart"
                    report = Rooted.RootedReverseObservation "destroy" "observation" [first, second]
                wire <- expectRight (Rooted.renderRootedReverseObservationKernel report)
                Rooted.readRootedReverseObservationForPlanKernel "vm" "destroy" ["cluster", "chart"] wire @?= Right report
                assertBool "foreign frame refused" (case Rooted.readRootedReverseObservationForPlanKernel "other" "destroy" ["cluster", "chart"] wire of Left _ -> True; Right _ -> False)
                assertBool "foreign operation refused" (case Rooted.readRootedReverseObservationForPlanKernel "vm" "other" ["cluster", "chart"] wire of Left _ -> True; Right _ -> False)
                assertBool "foreign resource refused" (case Rooted.readRootedReverseObservationForPlanKernel "vm" "destroy" ["cluster", "other"] wire of Left _ -> True; Right _ -> False)
                assertBool "reordered resource refused" (case Rooted.readRootedReverseObservationForPlanKernel "vm" "destroy" ["chart", "cluster"] wire of Left _ -> True; Right _ -> False)
                assertBool "trailing bytes refused" (case Rooted.readRootedReverseObservationForPlanKernel "vm" "destroy" ["cluster", "chart"] (wire <> "x") of Left _ -> True; Right _ -> False)
                assertBool "truncation refused" (case Rooted.readRootedReverseObservationForPlanKernel "vm" "destroy" ["cluster", "chart"] (ByteString.take (ByteString.length wire - 1) wire) of Left _ -> True; Right _ -> False)
                assertBool "duplicate resources refused" (case Rooted.renderRootedReverseObservationKernel (Rooted.RootedReverseObservation "destroy" "observation" [first, first]) of Left _ -> True; Right _ -> False)
                assertBool "empty predecessor refused" (case Rooted.renderRootedReverseObservationKernel (Rooted.RootedReverseObservation "destroy" "observation" [Rooted.RootedReverseResource "vm" "cluster" "" "new"]) of Left _ -> True; Right _ -> False)
            , testCase "forward journal rechecks the retained acquisition before each grant" $
                forM_ (["valid", "mode", "broker", "missing-lease", "versioned-lease", "frozen-lease", "snapshot"] :: [Text]) $ \mutation ->
                    withPreparedKernelFixture $ \store project root authority cursor catalog _ _ _ -> do
                        signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 39))
                        brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                            runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                            opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 38))
                            let wire = Rooted.renderRootedLifecycleRequestKernel opening
                                sign unsigned = do
                                    response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                    pure (Right (Handoff.renderRootedLifecycleResponse response))
                                selectedPlans = [digest | Just digest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)]
                            planDigest <- case selectedPlans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                            TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                                TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ ->
                                    TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                        journal <- TestRootedSession.newForwardRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit authority cursor
                                        initial <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal planDigest "initial-operation" [] [] [] [] Nothing $ \_ -> pure (Right ())
                                        initial @?= Right ()
                                        expected <- case mutation of
                                            "valid" -> pure Nothing
                                            "mode" -> Just <$> LivePrepareFixture.changePrepareModeEpoch store authority
                                            "broker" -> do
                                                allocated <- withProtectedEntry store $ \protected -> fmap Right $
                                                    AuthorityFixture.withFreshBrokerEpochKernel protected project $ \_ -> pure (Right ())
                                                _ <- expectRight =<< expectRight allocated
                                                pure (Just (Session.SessionAuthorityFailure (Authority.AuthorityInvalidIdentity "the recorded broker generation does not match the allocated counter")))
                                            "missing-lease" -> do
                                                (key, _, _) <- LivePrepareFixture.solePrepareRecord store "lease."
                                                LivePrepareFixture.deleteRecord store key
                                                pure (Just (Session.SessionAcquisitionBindingMismatch "live lease record" (recordKeyText key) "absent"))
                                            "versioned-lease" -> do
                                                (key, version, _) <- LivePrepareFixture.solePrepareRecord store "lease."
                                                LivePrepareFixture.advanceRecordVersion store key
                                                pure (Just (Session.SessionAcquisitionBindingMismatch "live lease record version" (Text.pack (show version)) (Text.pack (show (version + 1)))))
                                            "frozen-lease" -> do
                                                (key, _, bytes) <- LivePrepareFixture.solePrepareRecord store "lease."
                                                frozen <- case decodeFields bytes of
                                                    ["bound", epoch, spec, digest] -> pure (encodeFields ["frozen", epoch, "observed-freeze", "observed-resource-set", spec, digest, spec, digest])
                                                    fields -> assertFailure ("expected a bound lease, got " <> show fields)
                                                LivePrepareFixture.replaceRawRecord store key frozen
                                                pure (Just (Session.SessionAcquisitionBindingMismatch "live lease state" "bound" "frozen"))
                                            "snapshot" -> do
                                                retainedFailure <- newIORef Nothing
                                                withPreparedKernelFixture $ \otherStore _ _ _ _ otherCatalog _ _ _ -> do
                                                    let retained = TestRootedPlan.withRootedPlanCatalogRootKernel catalog (\_ _ plan _ _ -> stablePlanSnapshotDigest (renderSnapshot plan))
                                                        replacement = TestRootedPlan.withRootedPlanCatalogRootKernel otherCatalog (\_ _ plan _ _ -> stablePlanSnapshotDigest (renderSnapshot plan))
                                                    assertBool "the independent snapshot differs" (retained /= replacement)
                                                    (key, _, _) <- LivePrepareFixture.solePrepareRecord store "snapshot."
                                                    (_, _, bytes) <- LivePrepareFixture.solePrepareRecord otherStore "snapshot."
                                                    LivePrepareFixture.replaceRawRecord store key bytes
                                                    writeIORef retainedFailure (Just (Session.SessionAcquisitionBindingMismatch "live snapshot plan digest" retained replacement))
                                                readIORef retainedFailure
                                            _ -> assertFailure "unknown mutation"
                                        before <- protectedImage store
                                        callbacks <- newIORef (0 :: Int)
                                        outcome <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal planDigest "routed-operation" [] [] [] [] Nothing $ \_ -> do
                                            modifyIORef' callbacks (+ 1)
                                            pure (Right ())
                                        case expected of
                                            Nothing -> do
                                                outcome @?= Right ()
                                                readIORef callbacks >>= (@?= 1)
                                                after <- protectedImage store
                                                assertBool "a successful grant prepares its operation" (before /= after)
                                            Just failure -> do
                                                outcome @?= Left (Text.pack (Session.sessionErrorMessage failure))
                                                readIORef callbacks >>= (@?= 0)
                                                protectedImage store >>= (@?= before)
                                        pure (Right ())
                        expectRight =<< expectRight brokered
            , testCase "admitted root coordinates select an already recorded resource without proving readiness" $
                withPreparedKernelFixture $ \store _ _ _ _ catalog _ _ _ -> do
                    let (planDigest, projected, probeIdentities) = TestRootedPlan.withRootedPlanCatalogRootKernel catalog $ \_ _ plan _ _ ->
                            let node = NonEmpty.head (TestLifecyclePlan.forwardKernel plan)
                             in ( stablePlanSnapshotDigest (renderSnapshot plan)
                                , TestLifecyclePlan.plannedResourceCoordinatesKernel plan node "core:deploy-vm"
                                , TestLifecyclePlan.plannedRootProbeIdentitiesKernel plan node "core:deploy-vm"
                                )
                    ((operation, frame), dependencies) <- expectRight projected
                    (operation, frame, dependencies) @?= ("core:deploy-vm", "host-orchestrator-0", [])
                    (identity, prerequisiteIdentities) <- expectRight probeIdentities
                    TestLifecyclePlan.rootProbeIdentityCoordinatesKernel identity @?= (planDigest, frame, operation, "provider")
                    prerequisiteIdentities @?= []
                    let bytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 planDigest, TextEncoding.encodeUtf8 frame, TextEncoding.encodeUtf8 operation, "1", TextEncoding.encodeUtf8 operation, "1", "active", "fixture", "owned"])
                    keyText <- expectRight (Reconcile.resourceRecordKey planDigest frame operation)
                    key <- expectRight (mkRecordKey keyText)
                    _ <- expectRight =<< withProtectedEntry store (\protected -> compareAndSwapProtectedRecord protected key ExpectAbsent bytes)
                    captured <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame planDigest operation)
                    observation <- expectRight captured
                    selected <- expectRight (TestRootedSession.selectRootedProbeObservationsKernel store [identity] [observation])
                    case selected of
                        [exact] -> do
                            unchanged <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected exact)
                            unchanged @?= Right ()
                            owned <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedProbePrerequisiteInEntryKernel protected identity exact)
                            owned @?= Right ()
                            generation <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedProviderGenerationInEntryKernel protected identity exact)
                            generation @?= Right 1
                            wrongFamily <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedShareGenerationInEntryKernel protected identity exact)
                            wrongFamily @?= Left "rooted durable share observation: resource has the wrong family"
                        _ -> assertFailure "the existing resource was not selected exactly once"
                    case TestRootedSession.selectRootedProbeObservationsKernel store [identity, identity] [observation] of
                        Left failure -> failure @?= "rooted resource observation: duplicate required resource"
                        Right _ -> assertFailure "duplicate probe identities selected a record"
                    withPreparedKernelFixture $ \_ _ _ _ _ foreignCatalog _ _ _ -> do
                        let foreignIdentity = TestRootedPlan.withRootedPlanCatalogRootKernel foreignCatalog $ \_ _ plan _ _ ->
                                TestLifecyclePlan.plannedRootProbeIdentitiesKernel plan (NonEmpty.head (TestLifecyclePlan.forwardKernel plan)) "core:deploy-vm"
                        (otherIdentity, _) <- expectRight foreignIdentity
                        case TestRootedSession.selectRootedProbeObservationsKernel store [otherIdentity] [observation] of
                            Left failure -> failure @?= "rooted resource observation: required resource was not observed"
                            Right _ -> assertFailure "a foreign plan selected the existing record"
                        wrongIdentity <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedProbePrerequisiteInEntryKernel protected otherIdentity observation)
                        wrongIdentity @?= Left "rooted probe prerequisite: resource identity differs"
                        foreignGeneration <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedProviderGenerationInEntryKernel protected otherIdentity observation)
                        foreignGeneration @?= Left "rooted probe prerequisite: resource identity differs"
                    case TestRootedSession.selectRootedResourceObservationsKernel store [(planDigest, "other-frame", operation)] [observation] of
                        Left failure -> failure @?= "rooted resource observation: required resource was not observed"
                        Right _ -> assertFailure "a different frame selected the existing record"
                    let releasedBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 planDigest, TextEncoding.encodeUtf8 frame, TextEncoding.encodeUtf8 operation, "1", TextEncoding.encodeUtf8 operation, "2", "released", "fixture", "released"])
                    _ <- expectRight =<< withProtectedEntry store (\protected -> do
                        found <- readProtectedRecord protected key
                        case found of
                            Right (Just current) -> compareAndSwapProtectedRecord protected key (ExpectVersion (protectedRecordVersion current)) releasedBytes
                            Left failure -> pure (Left failure)
                            Right Nothing -> pure (Left (ProtectedInvalid "resource disappeared")))
                    stale <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedProbePrerequisiteInEntryKernel protected identity observation)
                    staleGeneration <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedProviderGenerationInEntryKernel protected identity observation)
                    staleGeneration @?= Left "rooted resource observation: physical version changed"
                    stale @?= Left "rooted resource observation: physical version changed"
                    releasedCapture <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame planDigest operation)
                    released <- expectRight releasedCapture
                    beforeReleased <- protectedImage store
                    rejected <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedProbePrerequisiteInEntryKernel protected identity released)
                    rejected @?= Left "rooted probe prerequisite: resource is released"
                    releasedGeneration <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedProviderGenerationInEntryKernel protected identity released)
                    releasedGeneration @?= Left "rooted probe prerequisite: resource is released"
                    protectedImage store >>= (@?= beforeReleased)
            , testCase "root resource observation refuses same-byte physical replacement" $
                withPreparedKernelFixture $ \store _ _ _ _ _ _ _ _ -> do
                    let plan = "root-resource-observation-plan"
                        frame = "fixture-frame"
                        operation = "fixture-resource"
                        bytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, TextEncoding.encodeUtf8 frame, TextEncoding.encodeUtf8 operation, "1", TextEncoding.encodeUtf8 operation, "1", "active", "fixture", "owned"])
                    keyText <- expectRight (Reconcile.resourceRecordKey plan frame operation)
                    key <- expectRight (mkRecordKey keyText)
                    absent <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame plan operation)
                    case absent of
                        Left failure -> failure @?= "rooted resource observation: resource record is absent"
                        Right _ -> assertFailure "an absent resource was observed"
                    _ <- expectRight =<< withProtectedEntry store (\protected -> compareAndSwapProtectedRecord protected key ExpectAbsent bytes)
                    captured <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame plan operation)
                    observation <- expectRight captured
                    unchanged <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected observation)
                    unchanged @?= Right ()
                    withPreparedKernelFixture $ \foreignStore _ _ _ _ _ _ _ _ -> do
                        foreignBefore <- protectedImage foreignStore
                        foreignResult <- expectRight =<< withProtectedEntry foreignStore (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected observation)
                        foreignResult @?= Left "rooted resource observation: protected store differs"
                        protectedImage foreignStore >>= (@?= foreignBefore)
                    _ <- expectRight =<< withProtectedEntry store (\protected -> do
                        found <- readProtectedRecord protected key
                        case found of
                            Right (Just current) -> compareAndSwapProtectedRecord protected key (ExpectVersion (protectedRecordVersion current)) bytes
                            Left failure -> pure (Left failure)
                            Right Nothing -> pure (Left (ProtectedInvalid "resource disappeared")))
                    before <- protectedImage store
                    stale <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected observation)
                    stale @?= Left "rooted resource observation: physical version changed"
                    protectedImage store >>= (@?= before)
                    latestResult <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame plan operation)
                    latest <- expectRight latestResult
                    let retained = TestRootedSession.retainRootedResourceObservationsKernel [observation] [latest]
                    case retained of
                        [single] -> do
                            current <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected single)
                            current @?= Right ()
                            let select coordinates rows = TestRootedSession.selectRootedResourceObservationsKernel store coordinates rows
                                requireFailure expected result = case result of
                                    Left failure -> failure @?= expected
                                    Right _ -> assertFailure "invalid resource selection succeeded"
                            case select [(plan, frame, operation)] retained of
                                Right [_] -> pure ()
                                _ -> assertFailure "the exact resource was not selected"
                            requireFailure "rooted resource observation: required resource was not observed" (select [(plan, frame, "foreign-resource")] retained)
                            requireFailure "rooted resource observation: duplicate required resource" (select [(plan, frame, operation), (plan, frame, operation)] retained)
                            requireFailure "rooted resource observation: duplicate retained resource" (select [(plan, frame, operation)] [single, single])
                            withPreparedKernelFixture $ \foreignStore _ _ _ _ _ _ _ _ -> do
                                _ <- expectRight =<< withProtectedEntry foreignStore (\protected -> compareAndSwapProtectedRecord protected key ExpectAbsent bytes)
                                foreignCaptured <- expectRight =<< withProtectedEntry foreignStore (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame plan operation)
                                foreignObservation <- expectRight foreignCaptured
                                let both = TestRootedSession.retainRootedResourceObservationsKernel [single] [foreignObservation]
                                length both @?= 2
                                forM_ [store, foreignStore] $ \selectedStore ->
                                    case TestRootedSession.selectRootedResourceObservationsKernel selectedStore [(plan, frame, operation)] both of
                                        Right [selected] -> do
                                            result <- expectRight =<< withProtectedEntry selectedStore (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected selected)
                                            result @?= Right ()
                                        _ -> assertFailure "the resource was not selected from its exact store"
                            let other = "second-resource"
                                otherBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, TextEncoding.encodeUtf8 frame, TextEncoding.encodeUtf8 other, "1", TextEncoding.encodeUtf8 other, "1", "active", "fixture", "owned"])
                            otherKeyText <- expectRight (Reconcile.resourceRecordKey plan frame other)
                            otherKey <- expectRight (mkRecordKey otherKeyText)
                            _ <- expectRight =<< withProtectedEntry store (\protected -> compareAndSwapProtectedRecord protected otherKey ExpectAbsent otherBytes)
                            otherCaptured <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected frame plan other)
                            otherObservation <- expectRight otherCaptured
                            _ <- expectRight =<< withProtectedEntry store (\protected -> do
                                found <- readProtectedRecord protected key
                                case found of
                                    Right (Just record) -> compareAndSwapProtectedRecord protected key (ExpectVersion (protectedRecordVersion record)) bytes
                                    Left failure -> pure (Left failure)
                                    Right Nothing -> pure (Left (ProtectedInvalid "resource disappeared")))
                            ordered <- expectRight (select [(plan, frame, other), (plan, frame, operation)] [single, otherObservation])
                            results <- mapM (\selected -> expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected selected)) ordered
                            results @?= [Right (), Left "rooted resource observation: physical version changed"]
                        _ -> assertFailure "the latest observation did not replace the earlier resource version"
            , testCase "frame journal uses its catalog plan and rejects session replay" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 39))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 38))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                let selectedPlans = [ planDigest
                                                    | Just planDigest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)
                                                    ]
                                before <- protectedImage store
                                withPreparedKernelFixture $ \foreignStore _ _ _ _ foreignCatalog _ _ _ -> do
                                    foreignBefore <- protectedImage foreignStore
                                    wrongCatalog <- TestRootedNode.withRootedFrameJournalKernel runtime root attached (unsafeCoerce foreignCatalog) store $ \_ _ _ -> assertFailure "foreign catalog admitted"
                                    assertBool "foreign catalog refused" (case wrongCatalog of Left _ -> True; Right _ -> False)
                                    wrongStore <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog foreignStore $ \_ _ _ -> assertFailure "foreign store admitted"
                                    assertBool "foreign store refused" (case wrongStore of Left _ -> True; Right _ -> False)
                                    protectedImage foreignStore >>= (@?= foreignBefore)
                                    protectedImage store >>= (@?= before)
                                journalRef <- newIORef Nothing
                                staleJournalRef <- newIORef Nothing
                                releasedJournalRef <- newIORef Nothing
                                grantJournalRef <- newIORef Nothing
                                admitted <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    Session.fenceEpochWord fence @?= 1
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    staleJournal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    releasedJournal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    writeIORef journalRef (Just journal)
                                    writeIORef staleJournalRef (Just staleJournal)
                                    writeIORef releasedJournalRef (Just releasedJournal)
                                    grantJournal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    writeIORef grantJournalRef (Just grantJournal)
                                    pure (Right ())
                                expectRight admitted
                                journal <- readIORef journalRef >>= maybe (assertFailure "frame journal was not retained") pure
                                staleJournal <- readIORef staleJournalRef >>= maybe (assertFailure "stale journal was not retained") pure
                                releasedJournal <- readIORef releasedJournalRef >>= maybe (assertFailure "released journal was not retained") pure
                                grantJournal <- readIORef grantJournalRef >>= maybe (assertFailure "grant journal was not retained") pure
                                duplicate <- TestRootedSession.prepareRootedOperationJournalKernel journal ["routed-operation", "routed-operation"]
                                assertBool "duplicate preparations refused" (case duplicate of Left _ -> True; Right _ -> False)
                                plan <- case selectedPlans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                                let probeResult = TestRootedPlan.withRootedPlanCatalogRootKernel catalog $ \_ _ rootPlan _ _ ->
                                        TestLifecyclePlan.plannedRootProbeIdentitiesKernel rootPlan (NonEmpty.head (TestLifecyclePlan.forwardKernel rootPlan)) "core:deploy-vm"
                                (prerequisiteIdentity, _) <- expectRight probeResult
                                let (prerequisitePlan, prerequisiteFrame, prerequisite, _) = TestLifecyclePlan.rootProbeIdentityCoordinatesKernel prerequisiteIdentity
                                    prerequisiteBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 prerequisitePlan, TextEncoding.encodeUtf8 prerequisiteFrame, TextEncoding.encodeUtf8 prerequisite, "1", TextEncoding.encodeUtf8 prerequisite, "1", "active", "fixture", "owned"])
                                prerequisiteKeyText <- expectRight (Reconcile.resourceRecordKey prerequisitePlan prerequisiteFrame prerequisite)
                                prerequisiteKey <- expectRight (mkRecordKey prerequisiteKeyText)
                                _ <- expectRight =<< withProtectedEntry store (\protected -> compareAndSwapProtectedRecord protected prerequisiteKey ExpectAbsent prerequisiteBytes)
                                capturedPrerequisite <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected prerequisiteFrame prerequisitePlan prerequisite)
                                prerequisiteObservation <- expectRight capturedPrerequisite
                                beforeMissing <- protectedImage store
                                missingPrerequisite <- TestRootedSession.prepareRootedOperationJournalForPrerequisitesKernel journal [prerequisiteIdentity] [] ["missing-prerequisite-operation"]
                                case missingPrerequisite of
                                    Left failure -> failure @?= "rooted resource observation: required resource was not observed"
                                    Right _ -> assertFailure "a missing resource observation prepared a gate"
                                protectedImage store >>= (@?= beforeMissing)
                                _ <- expectRight =<< withProtectedEntry store (\protected -> do
                                    found <- readProtectedRecord protected prerequisiteKey
                                    case found of
                                        Right (Just current) -> compareAndSwapProtectedRecord protected prerequisiteKey (ExpectVersion (protectedRecordVersion current)) prerequisiteBytes
                                        Left failure -> pure (Left failure)
                                        Right Nothing -> pure (Left (ProtectedInvalid "prerequisite disappeared")))
                                beforeStalePrerequisite <- protectedImage store
                                stalePrerequisite <- TestRootedSession.prepareRootedOperationJournalForPrerequisitesKernel staleJournal [prerequisiteIdentity] [prerequisiteObservation] ["stale-prerequisite-operation"]
                                case stalePrerequisite of
                                    Left failure -> failure @?= "rooted resource observation: physical version changed"
                                    Right _ -> assertFailure "a stale resource observation prepared a gate"
                                protectedImage store >>= (@?= beforeStalePrerequisite)
                                let releasedBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 prerequisitePlan, TextEncoding.encodeUtf8 prerequisiteFrame, TextEncoding.encodeUtf8 prerequisite, "1", TextEncoding.encodeUtf8 prerequisite, "2", "released", "fixture", "released"])
                                _ <- expectRight =<< withProtectedEntry store (\protected -> do
                                    found <- readProtectedRecord protected prerequisiteKey
                                    case found of
                                        Right (Just current) -> compareAndSwapProtectedRecord protected prerequisiteKey (ExpectVersion (protectedRecordVersion current)) releasedBytes
                                        Left failure -> pure (Left failure)
                                        Right Nothing -> pure (Left (ProtectedInvalid "prerequisite disappeared")))
                                releasedResult <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected prerequisiteFrame prerequisitePlan prerequisite)
                                releasedObservation <- expectRight releasedResult
                                beforeReleasedPrerequisite <- protectedImage store
                                releasedPrerequisite <- TestRootedSession.prepareRootedOperationJournalForPrerequisitesKernel releasedJournal [prerequisiteIdentity] [releasedObservation] ["released-prerequisite-operation"]
                                case releasedPrerequisite of
                                    Left failure -> failure @?= "rooted probe prerequisite: resource is released"
                                    Right _ -> assertFailure "a released prerequisite prepared a gate"
                                protectedImage store >>= (@?= beforeReleasedPrerequisite)
                                _ <- expectRight =<< withProtectedEntry store (\protected -> do
                                    found <- readProtectedRecord protected prerequisiteKey
                                    case found of
                                        Right (Just current) -> compareAndSwapProtectedRecord protected prerequisiteKey (ExpectVersion (protectedRecordVersion current)) prerequisiteBytes
                                        Left failure -> pure (Left failure)
                                        Right Nothing -> pure (Left (ProtectedInvalid "prerequisite disappeared")))
                                refreshedResult <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.observeRootedResourceInEntryKernel protected prerequisiteFrame prerequisitePlan prerequisite)
                                refreshed <- expectRight refreshedResult
                                preparedGates <- expectRight =<< TestRootedSession.prepareRootedOperationJournalForPrerequisitesKernel journal [prerequisiteIdentity] [refreshed] ["routed-operation"]
                                length preparedGates @?= 1
                                beforeForeignGrant <- protectedImage store
                                foreignGrant <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal (plan <> "-foreign") "routed-operation" [] [] [] [] Nothing $ \_ -> assertFailure "foreign plan received a grant"
                                assertBool "foreign plan refused" (case foreignGrant of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= beforeForeignGrant)
                                granted <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal plan "routed-operation" [] [] [] [] Nothing $ \grant ->
                                    TestPreparedGate.withPreparedNodeGrantKernel grant $ \operation dependencies gateBytes projectedBytes -> do
                                        operation @?= "routed-operation"
                                        dependencies @?= []
                                        (gatePlan, _, gateFrame, _, gateOperation, _, gateFence, gateAttempt, gateVersion) <- expectRight (TestPreparedGate.readFencedPreparedGatePackageKernel gateBytes)
                                        gateFence @?= 1
                                        gatePlan @?= plan
                                        gateFrame @?= "vm-orchestrator-1"
                                        gateOperation @?= operation
                                        assertBool "the journal provides a positive attempt and version" (gateAttempt > 0 && gateVersion > 0)
                                        TestPreparedGate.readPreparedGatePackagesKernel projectedBytes @?= Right []
                                        pure (Right ())
                                granted @?= Right ()
                                callbacks <- newIORef (0 :: Int)
                                beforeStaleGrant <- protectedImage store
                                staleNodeGrant <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached grantJournal plan "prerequisite-operation" [] [] [prerequisiteIdentity] [prerequisiteObservation] Nothing $ \_ ->
                                    modifyIORef' callbacks (+ 1) >> pure (Right ())
                                case staleNodeGrant of
                                    Left failure -> failure @?= "rooted resource observation: physical version changed"
                                    Right () -> assertFailure "a stale prerequisite admitted a node grant"
                                readIORef callbacks >>= (@?= 0)
                                protectedImage store >>= (@?= beforeStaleGrant)
                                missingNodeGrant <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal plan "routed-operation" [] [] [prerequisiteIdentity] [] Nothing $ \_ ->
                                    modifyIORef' callbacks (+ 1) >> pure (Right ())
                                case missingNodeGrant of
                                    Left failure -> failure @?= "rooted resource observation: required resource was not observed"
                                    Right () -> assertFailure "a missing prerequisite admitted a node grant"
                                readIORef callbacks >>= (@?= 0)
                                protectedImage store >>= (@?= beforeStaleGrant)
                                currentNodeGrant <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal plan "routed-operation" [] [] [prerequisiteIdentity] [refreshed] Nothing $ \_ ->
                                    modifyIORef' callbacks (+ 1) >> pure (Right ())
                                currentNodeGrant @?= Right ()
                                readIORef callbacks >>= (@?= 1)
                                wrappedGrant <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal plan "routed-operation" [] [] [] [] (Just (Just "predecessor")) $ \grant ->
                                    TestPreparedGate.withPreparedNodeGrantKernel grant $ \_ _ gateBytes _ -> do
                                        (gate, predecessor) <- expectRight (Rooted.readReversePreparedGateEnvelopeKernel gateBytes)
                                        predecessor @?= Just "predecessor"
                                        (gatePlan, _, gateFrame, _, gateOperation, _, _, _, _) <- expectRight (TestPreparedGate.readFencedPreparedGatePackageKernel gate)
                                        (gatePlan, gateFrame, gateOperation) @?= (plan, "vm-orchestrator-1", "routed-operation")
                                        pure (Right ())
                                wrappedGrant @?= Right ()
                                let resourceBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", "routed-operation", "1", "routed-operation", "1", "active", "fixture", "owned"])
                                report <- expectRight (Rooted.renderRootedNodeObservationKernel
                                    (Rooted.RootedNodeObservation "routed-operation" True "" [Rooted.RootedProjectedObservation "routed-operation" True (Just ("vm-orchestrator-1", Nothing, resourceBytes))]))
                                retained <- newMVar [refreshed]
                                beforeForeign <- protectedImage store
                                foreignResult <- TestRootedSession.settleRootedOperationJournalRetainingKernel retained journal "vm-orchestrator-1" "foreign-operation" [] report
                                assertBool "foreign observation refused" (case foreignResult of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= beforeForeign)
                                readMVar retained >>= (\rows -> length rows @?= 1)
                                first <- TestRootedSession.settleRootedOperationJournalRetainingKernel retained journal "vm-orchestrator-1" "routed-operation" [] report
                                first @?= Right ()
                                captured <- readMVar retained
                                selected <- expectRight (TestRootedSession.selectRootedResourceObservationsKernel store
                                    [(prerequisitePlan, prerequisiteFrame, prerequisite), (plan, "vm-orchestrator-1", "routed-operation")] captured)
                                case selected of
                                    [_, resourceObservation] -> do
                                        valid <- expectRight =<< withProtectedEntry store (\protected -> Right <$> TestRootedSession.validateRootedResourceObservationInEntryKernel protected resourceObservation)
                                        valid @?= Right ()
                                    _ -> assertFailure "settlement did not retain both exact resource observations"
                                _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["failed-operation"]
                                let failedBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", "failed-operation", "1", "failed-operation", "1", "active", "fixture", "owned"])
                                failedReport <- expectRight (Rooted.renderRootedNodeObservationKernel
                                    (Rooted.RootedNodeObservation "failed-operation" False "fixture failure" [Rooted.RootedProjectedObservation "failed-operation" True (Just ("vm-orchestrator-1", Nothing, failedBytes))]))
                                failedSettlement <- TestRootedSession.settleRootedOperationJournalRetainingKernel retained journal "vm-orchestrator-1" "failed-operation" [] failedReport
                                failedSettlement @?= Right ()
                                afterFailed <- readMVar retained
                                length afterFailed @?= 2
                                case TestRootedSession.selectRootedResourceObservationsKernel store [(plan, "vm-orchestrator-1", "failed-operation")] afterFailed of
                                    Left failure -> failure @?= "rooted resource observation: required resource was not observed"
                                    Right _ -> assertFailure "a failed node supplied retained readiness evidence"
                                _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["parallel-one", "parallel-two"]
                                let parallelReport operation =
                                        let bytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", TextEncoding.encodeUtf8 operation, "1", TextEncoding.encodeUtf8 operation, "1", "active", "fixture", "owned"])
                                         in Rooted.renderRootedNodeObservationKernel
                                                (Rooted.RootedNodeObservation operation True "" [Rooted.RootedProjectedObservation operation True (Just ("vm-orchestrator-1", Nothing, bytes))])
                                firstReport <- expectRight (parallelReport "parallel-one")
                                secondReport <- expectRight (parallelReport "parallel-two")
                                finished <- newEmptyMVar
                                _ <- forkFinally (TestRootedSession.settleRootedOperationJournalRetainingKernel retained journal "vm-orchestrator-1" "parallel-one" [] firstReport) (putMVar finished)
                                _ <- forkFinally (TestRootedSession.settleRootedOperationJournalRetainingKernel retained journal "vm-orchestrator-1" "parallel-two" [] secondReport) (putMVar finished)
                                firstResult <- takeMVar finished
                                secondResult <- takeMVar finished
                                forM_ [firstResult, secondResult] $ \result -> case result of
                                    Left failure -> assertFailure (show failure)
                                    Right settled -> settled @?= Right ()
                                afterParallel <- readMVar retained
                                parallelSelected <- expectRight (TestRootedSession.selectRootedResourceObservationsKernel store
                                    [(plan, "vm-orchestrator-1", "parallel-one"), (plan, "vm-orchestrator-1", "parallel-two")] afterParallel)
                                length parallelSelected @?= 2
                                let effectCoordinates = [("effect-operation", "ReservationOutcomeUnknown", "effect-digest")]
                                beforeEffectRefusal <- protectedImage store
                                wrongEffect <- TestRootedNode.withJournalPreparedRootedEffectNodeGrantKernel runtime attached journal plan "effect-operation" [] [] [] [] [("other-operation", "ReservationOutcomeUnknown", "effect-digest")] $ \_ -> assertFailure "other operation received a grant"
                                assertBool "effect grant refuses another operation" (case wrongEffect of Left _ -> True; Right () -> False)
                                refusedEffect <- TestRootedNode.withJournalPreparedRootedEffectNodeGrantKernel runtime attached journal plan "effect-operation" [] [] [prerequisiteIdentity] [] effectCoordinates $ \_ -> assertFailure "missing prerequisite granted an effect"
                                assertBool "effect grant refuses a missing prerequisite" (case refusedEffect of Left _ -> True; Right () -> False)
                                protectedImage store >>= (@?= beforeEffectRefusal)
                                grantedEffect <- TestRootedNode.withJournalPreparedRootedEffectNodeGrantKernel runtime attached journal plan "effect-operation" [] [] [] [] effectCoordinates $ \grant ->
                                    TestPreparedGate.withPreparedNodeGrantKernel grant $ \operation _ gateBytes _ -> do
                                        operation @?= "effect-operation"
                                        (fenced, phase, digest) <- expectRight (TestPreparedGate.readEffectPreparedGatePackageKernel gateBytes)
                                        phase @?= TestPreparedGate.GateUnknownPhase "ReservationOutcomeUnknown"
                                        digest @?= TestPreparedGate.GateCallDigest "effect-digest"
                                        (gatePlan, _, gateFrame, _, gateOperation, _, _, _, _) <- expectRight (TestPreparedGate.readFencedPreparedGatePackageKernel fenced)
                                        (gatePlan, gateFrame, gateOperation) @?= (plan, "vm-orchestrator-1", operation)
                                        pure (Right ())
                                grantedEffect @?= Right ()
                                effects <- expectRight =<< TestRootedSession.prepareRootedEffectJournalKernel journal effectCoordinates
                                case effects of
                                    [gate] -> TestPreparedGate.preparedGateEffect gate @?= Just
                                        (TestPreparedGate.GateUnknownPhase "ReservationOutcomeUnknown", TestPreparedGate.GateCallDigest "effect-digest")
                                    _ -> assertFailure "expected one effect gate"
                                imageBeforeReuse <- protectedImage store
                                reused <- expectRight =<< TestRootedSession.prepareRootedEffectJournalKernel journal effectCoordinates
                                reused @?= effects
                                protectedImage store >>= (@?= imageBeforeReuse)
                                invalidEffect <- TestRootedSession.prepareRootedEffectJournalKernel journal [("bad-effect", "ReservationOutcomeUnknown", "")]
                                invalidEffect @?= Left "rooted operation journal: invalid effect coordinates"
                                protectedImage store >>= (@?= imageBeforeReuse)
                                TestRootedSession.settleRootedReverseOperationJournalKernel journal "effect-operation" TeardownReleased >>= (@?= Right ())
                                closed <- TestRootedSession.closeRootedOperationJournalKernel journal
                                closed @?= Right ()
                                afterClose <- protectedImage store
                                TestRootedSession.closeRootedOperationJournalKernel journal >>= (@?= Right ())
                                protectedImage store >>= (@?= afterClose)
                                after <- protectedImage store
                                assertBool "resource settlement was persisted" (any (\(_, _, bytes) -> bytes == resourceBytes) after)
                                closedPreparation <- TestRootedSession.prepareRootedOperationJournalKernel journal ["after-close"]
                                assertBool "closed journal cannot prepare" (case closedPreparation of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= after)
                                assertBool "journal session was persisted" (after /= before)
                                case selectedPlans of
                                    [digest] -> do
                                        name <- expectRight (mkRecordName digest)
                                        assertBool "selected plan journal exists" (any (\(key, _, _) -> key == "project." <> name) after)
                                    _ -> assertFailure "fixture did not select exactly one child plan"
                                replay <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \_ _ _ -> assertFailure "closed session reopened"
                                assertBool "replay refused" (case replay of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= after)
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "reverse journal records each distinct teardown outcome" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 28))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 27))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ ->
                                TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["released", "foreign", "refused", "failed"]
                                    mapM_ (\(operation, outcome) ->
                                        TestRootedSession.settleRootedReverseOperationJournalKernel journal operation outcome >>= (@?= Right ()))
                                        [("released", TeardownReleased), ("foreign", TeardownForeignRetained "foreign"), ("refused", TeardownRefused "policy"), ("failed", TeardownFailed "failure")]
                                    TestRootedSession.closeRootedOperationJournalKernel journal >>= (@?= Right ())
                                    rows <- protectedImage store
                                    mapM_ (\(operation, phase) -> assertBool ("missing reverse phase for " <> Text.unpack operation)
                                        (any (\(key, _, bytes) -> operation `Text.isSuffixOf` key && ByteString.isInfixOf phase bytes) rows))
                                        [("released", "Released"), ("foreign", "ObservedForeign"), ("refused", "StepObservedTerminal"), ("failed", "StepObservedTerminal")]
                                    pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "rooted effect gate refuses reuse for a different digest" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 28))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 27))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ ->
                                TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    _ <- expectRight =<< TestRootedSession.prepareRootedEffectJournalKernel journal [("effect-operation", "ReservationOutcomeUnknown", "first-digest")]
                                    beforeMismatch <- protectedImage store
                                    mismatch <- TestRootedSession.prepareRootedEffectJournalKernel journal [("effect-operation", "ReservationOutcomeUnknown", "other-digest")]
                                    mismatch @?= Left "rooted operation journal: pending gate names another effect"
                                    protectedImage store >>= (@?= beforeMismatch)
                                    pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "frame journal refuses a superseded fence and retains interrupted work" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 36))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 35))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                interrupted <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    checked <- withProtectedEntry store $ \protected -> do
                                        registered <- expectRight =<< Session.registerOperationIntent protected operationSession "routed-operation" Session.NoHistory permit
                                        newer <- expectRight =<< Session.rotateFence protected registered fence
                                        assertBool "fence advanced" (Session.fenceEpochWord newer > Session.fenceEpochWord fence)
                                        stale <- Session.withPreparedGate protected operationSession (Authority.rootAuthorityEpoch root) fence "routed-operation" "EffectOutcomeUnknown" registered $ \_ _ -> assertFailure "superseded fence prepared work"
                                        assertBool "stale fence refused" (case stale of Left _ -> True; Right _ -> False)
                                        pure (Right ())
                                    expectRight checked
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    let plans = [digest | Just digest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)]
                                    plan <- case plans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                                    beforeStale <- protectedImage store
                                    staleGrant <- TestRootedNode.withJournalPreparedRootedNodeGrantKernel runtime attached journal plan "stale-operation" [] [] [] [] Nothing $ \_ -> assertFailure "stale fence received a grant"
                                    assertBool "stale fence refused before preparation" (case staleGrant of Left _ -> True; Right _ -> False)
                                    protectedImage store >>= (@?= beforeStale)
                                    atomicJournal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    atomicStale <- TestRootedSession.prepareRootedOperationJournalKernel atomicJournal ["stale-operation"]
                                    assertBool "atomic fence check refused before registration" (case atomicStale of Left _ -> True; Right _ -> False)
                                    protectedImage store >>= (@?= beforeStale)
                                    thrown <- Exception.try (TestRootedSession.withRootedOperationJournalKernel journal $ \_ _ _ _ _ _ -> Exception.throwIO (userError "interrupted journal callback")) :: IO (Either Exception.SomeException (Either Text ()))
                                    assertBool "callback interruption rethrown" (case thrown of Left _ -> True; Right _ -> False)
                                    poisoned <- TestRootedSession.withRootedOperationJournalKernel journal $ \_ _ _ _ _ _ -> assertFailure "interrupted handle reused"
                                    assertBool "interrupted handle refused" (case poisoned of Left _ -> True; Right _ -> False)
                                    pure (Left "interrupted" :: Either Text ())
                                interrupted @?= Left "interrupted"
                                beforeRetry <- protectedImage store
                                retried <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \_ _ _ -> assertFailure "interrupted session reopened without recovery"
                                assertBool "open interrupted session blocks reopening" (case retried of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= beforeRetry)
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "a remote cleanup lease holds root supersession until release" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 25))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 24))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                tested <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["core:deploy-kind"]
                                    rivalStore <- expectRight =<< openProtectedStore (protectedStoreRoot store)
                                    go <- newEmptyMVar
                                    finished <- newEmptyMVar
                                    spawned <- TestRootedSession.withRootedOperationJournalKernel journal $ \_ _ _ currentFence current pending -> do
                                        _ <- forkFinally (takeMVar go >> withProtectedEntry rivalStore (\protected -> do
                                            rotated <- Session.rotateFence protected current currentFence
                                            pure (Right (Session.fenceEpochWord <$> rotated)))) (putMVar finished)
                                        pure (Right (current, pending, ()))
                                    expectRight spawned
                                    lease <- expectRight =<< TestRootedNode.acquireRootedCleanupLeaseKernel journal "core:deploy-kind"
                                    self <- getExecutablePath
                                    let probe = readProcessWithExitCode self ["--hostbootstrap-protected-entry-probe", protectedStoreRoot store] ""
                                    processHeld <- timeout 10000000 probe `Exception.onException` (TestRootedNode.releaseRootedCleanupLeaseKernel lease >> pure ())
                                    putMVar go ()
                                    early <- timeout 200000 (takeMVar finished)
                                    TestRootedNode.releaseRootedCleanupLeaseKernel lease >>= (@?= Right ())
                                    TestRootedNode.releaseRootedCleanupLeaseKernel lease >>= (@?= Right ())
                                    assertBool "another process sees the cleanup lease as contention" (case processHeld of Just (ExitFailure 3, "", "") -> True; _ -> False)
                                    case early of
                                        Just _ -> assertFailure "supersession entered during remote cleanup"
                                        Nothing -> pure ()
                                    later <- timeout 10000000 (takeMVar finished)
                                    assertBool "supersession proceeded after cleanup" (case later of Just (Right (Right (Right _))) -> True; _ -> False)
                                    processReleased <- timeout 10000000 probe
                                    assertBool "another process enters after cleanup" (case processReleased of Just (ExitSuccess, "", "") -> True; _ -> False)
                                    afterRotation <- protectedImage store
                                    staleLease <- TestRootedNode.acquireRootedCleanupLeaseKernel journal "core:deploy-kind"
                                    assertBool "old cleanup refused after root supersession" (case staleLease of Left _ -> True; Right _ -> False)
                                    protectedImage store >>= (@?= afterRotation)
                                    pure (Left "interrupted" :: Either Text ())
                                tested @?= Left "interrupted"
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "cancelled cleanup lease acquisition leaves no root lock behind" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 23))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 22))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                tested <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["core:deploy-kind"]
                                    started <- newEmptyMVar
                                    finished <- newEmptyMVar
                                    held <- withProtectedEntry store $ \_ -> do
                                        requester <- forkFinally (putMVar started () >> TestRootedNode.acquireRootedCleanupLeaseKernel journal "core:deploy-kind" >> pure ()) (putMVar finished)
                                        takeMVar started
                                        threadDelay 100000
                                        killThread requester
                                        cancelled <- timeout 10000000 (takeMVar finished)
                                        assertBool "acquisition was cancelled" (case cancelled of Just (Left _) -> True; _ -> False)
                                        pure (Right ())
                                    expectRight held
                                    _ <- protectedImage store
                                    pure (Left "interrupted" :: Either Text ())
                                tested @?= Left "interrupted"
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "frame journal serializes fence supersession before registration" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 30))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 29))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                tested <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    started <- newEmptyMVar
                                    finished <- newEmptyMVar
                                    snapshot <- expectRight =<< withProtectedEntry store (\protected -> do
                                        _ <- forkFinally (putMVar started () >> TestRootedSession.prepareRootedOperationJournalKernel journal ["raced-operation"]) (putMVar finished)
                                        takeMVar started
                                        _ <- expectRight =<< Session.rotateFence protected permit fence
                                        keys <- expectRight =<< listProtectedRecords protected
                                        rows <- mapM (\key -> do
                                            observed <- expectRight =<< readProtectedRecord protected key
                                            record <- maybe (assertFailure "protected record disappeared") pure observed
                                            pure (recordKeyText key, recordVersionWord (protectedRecordVersion record), protectedRecordBytes record)) keys
                                        pure (Right rows))
                                    outcome <- timeout 10000000 (takeMVar finished)
                                    assertBool "queued preparation refused the superseded fence" (case outcome of Just (Right (Left _)) -> True; _ -> False)
                                    protectedImage store >>= (@?= snapshot)
                                    pure (Left "interrupted" :: Either Text ())
                                tested @?= Left "interrupted"
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "frame journal rejects a stale gate before writing resource evidence" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 34))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 33))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                            plans = [digest | Just digest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)]
                        plan <- case plans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                journalRef <- newIORef Nothing
                                admitted <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    writeIORef journalRef (Just journal)
                                    pure (Right ())
                                expectRight admitted
                                journal <- readIORef journalRef >>= maybe (assertFailure "frame journal was not retained") pure
                                _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["resource"]
                                consumed <- TestRootedSession.withRootedOperationJournalKernel journal $ \journalStore _ operationSession _ permit pending -> do
                                    gate <- case pending of [("resource", found)] -> pure found; _ -> assertFailure "prepared gate missing"
                                    result <- withProtectedEntry journalStore $ \protected -> do
                                        advanced <- Session.acknowledgeOutcome protected operationSession gate "Committed" () permit
                                        case advanced of
                                            Left failure -> pure (Right (Left failure))
                                            Right value -> Session.withOperationAdvance value (\() next -> pure (Right (Right next)))
                                    pure $ case result of
                                        Left failure -> Left (Text.pack (show failure))
                                        Right (Left failure) -> Left (Text.pack (show failure))
                                        Right (Right next) -> Right (next, pending, ())
                                consumed @?= Right ()
                                let wordOne = "1"
                                    resourceBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", "resource", wordOne, "resource", wordOne, "active", "fixture", "owned"])
                                report <- expectRight (Rooted.renderRootedNodeObservationKernel (Rooted.RootedNodeObservation "resource" True "" [Rooted.RootedProjectedObservation "resource" True (Just ("vm-orchestrator-1", Nothing, resourceBytes))]))
                                before <- protectedImage store
                                result <- TestRootedSession.settleRootedOperationJournalKernel journal "vm-orchestrator-1" "resource" [] report
                                assertBool "stale prepared gate refused" (case result of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= before)
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "cleanup lease rechecks the exact prepared resource predecessor" $
                forM_ (["absent", "present", "changed", "malformed", "interrupted"] :: [String]) $ \mode ->
                    withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                        signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 38))
                        brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                            runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                            opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 37))
                            let wire = Rooted.renderRootedLifecycleRequestKernel opening
                                sign unsigned = do
                                    response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                    pure (Right (Handoff.renderRootedLifecycleResponse response))
                                plans = [digest | Just digest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)]
                            plan <- case plans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                            TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                                TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                    tested <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                        journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                        let record version = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", "resource", "1", "resource", version, "active", "fixture", "owned"])
                                        keyText <- expectRight (Reconcile.resourceRecordKey plan "vm-orchestrator-1" "resource")
                                        key <- expectRight (mkRecordKey keyText)
                                        if mode == "absent" then pure () else do
                                            let bytes = if mode == "malformed" then "malformed" else record "1"
                                            _ <- expectRight =<< withProtectedEntry store (\protected -> fmap (fmap (const ())) (compareAndSwapProtectedRecord protected key ExpectAbsent bytes))
                                            pure ()
                                        _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["resource"]
                                        selected <- newIORef Nothing
                                        readResult <- TestRootedSession.withRootedPreparedResourcePredecessorKernel journal attached "resource" (\value -> writeIORef selected (Just value) >> pure (Right ()))
                                        if mode == "malformed"
                                            then assertBool "malformed predecessor refused" (case readResult of Left _ -> True; Right () -> False)
                                            else do
                                                readResult @?= Right ()
                                                expected <- readIORef selected >>= maybe (assertFailure "no predecessor result") pure
                                                expected @?= if mode == "absent" then Nothing else Just (record "1")
                                                if mode == "changed" then do
                                                    _ <- expectRight =<< withProtectedEntry store (\protected -> do
                                                        found <- readProtectedRecord protected key
                                                        case found of
                                                            Right (Just current) -> fmap (fmap (const ())) (compareAndSwapProtectedRecord protected key (ExpectVersion (protectedRecordVersion current)) (record "2"))
                                                            Left failure -> pure (Left failure)
                                                            Right Nothing -> pure (Left (ProtectedInvalid "resource disappeared")))
                                                    pure ()
                                                  else pure ()
                                                before <- protectedImage store
                                                if mode == "interrupted"
                                                    then do
                                                        thrown <- Exception.try (TestRootedNode.withRootedCleanupLeaseForPredecessorKernel journal attached "resource" expected (\_ -> Exception.throwIO (userError "interrupted predecessor lease"))) :: IO (Either Exception.SomeException (Either Text ()))
                                                        assertBool "interruption propagated" (case thrown of Left _ -> True; Right _ -> False)
                                                    else do
                                                        result <- TestRootedNode.withRootedCleanupLeaseForPredecessorKernel journal attached "resource" expected (\lease -> TestRootedNode.releaseRootedCleanupLeaseKernel lease)
                                                        if mode == "changed"
                                                            then assertBool "changed predecessor refused" (case result of Left _ -> True; Right () -> False)
                                                            else result @?= Right ()
                                                protectedImage store >>= (@?= before)
                                        pure (Left "interrupted" :: Either Text ())
                                    tested @?= Left "interrupted"
                                    pure (Right ())
                        expectRight brokered >>= expectRight
            , testCase "reverse resource settlement validates the gate and exact owned successor" $
                forM_ ["released", "response-interrupted", "interrupted", "interrupted-conflict", "checkpoint-conflict", "foreign", "tampered", "malformed", "foreign-plan", "foreign-frame", "foreign-resource", "wrong-plan", "wrong-frame", "wrong-resource", "wrong-generation", "wrong-operation", "wrong-version", "wrong-phase", "wrong-adapter", "stale-predecessor", "stale-gate"] $ \mode ->
                    withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                        signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 36))
                        brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                            runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                            opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 35))
                            let wire = Rooted.renderRootedLifecycleRequestKernel opening
                                sign unsigned = do
                                    response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                    pure (Right (Handoff.renderRootedLifecycleResponse response))
                                plans = [digest | Just digest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)]
                            plan <- case plans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                            TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                                TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                    tested <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                        journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                        let record version disposition = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", "resource", "1", "resource", version, "active", "fixture", disposition])
                                            previous = record "1" "owned"
                                            successor = record "1" "released"
                                            foreignRecord disposition = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", if mode == "foreign-plan" then "other" else TextEncoding.encodeUtf8 plan, if mode == "foreign-frame" then "other" else "vm-orchestrator-1", if mode == "foreign-resource" then "other" else "resource", "1", "resource", "1", "active", "fixture", disposition])
                                            changed = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", if mode == "wrong-plan" then "other" else TextEncoding.encodeUtf8 plan, if mode == "wrong-frame" then "other" else "vm-orchestrator-1", if mode == "wrong-resource" then "other" else "resource", if mode == "wrong-generation" then "2" else "1", if mode == "wrong-operation" then "other" else "resource", if mode == "wrong-version" then "2" else "1", if mode == "wrong-phase" then "other" else "active", if mode == "wrong-adapter" then "other" else "fixture", "released"])
                                        keyText <- expectRight (Reconcile.resourceRecordKey plan "vm-orchestrator-1" "resource")
                                        key <- expectRight (mkRecordKey keyText)
                                        coordinatesRef <- newIORef Nothing
                                        _ <- expectRight =<< TestRootedSession.withRootedFrameSessionKernel attached (\_ _ l c f p t s o prior -> writeIORef coordinatesRef (Just (l, c, f, p, t, s, o, prior)) >> pure (Right ()))
                                        (lineage, catalogIdentity, attachedFrame, framePath, token, stage, ordinal, framePrior) <- readIORef coordinatesRef >>= maybe (assertFailure "frame coordinates unavailable") pure
                                        settlementToken <- maybe (assertFailure "attachment identity unavailable") pure (TestRootedSession.rootedSettlementSessionTokenKernel attached)
                                        checkpointKey <- expectRight (Session.rootedSettlementKeyKernel lineage catalogIdentity attachedFrame settlementToken "resource" ordinal)
                                        releaseBody <- expectTeardownRight (renderTeardownObservations [("resource", TeardownReleased)])
                                        observation <- expectRight (Rooted.renderRootedReverseObservationKernel (Rooted.RootedReverseObservation "resource" releaseBody [Rooted.RootedReverseResource attachedFrame "resource" previous successor]))
                                        let word value = LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64BE value))
                                            checkpointRow = ByteString.concat (map frameWire ["hostbootstrap/rooted-node-settlement", word 1, "settled", TextEncoding.encodeUtf8 lineage, TextEncoding.encodeUtf8 catalogIdentity, TextEncoding.encodeUtf8 attachedFrame, TextEncoding.encodeUtf8 settlementToken, "resource", word ordinal, observation])
                                        if mode == "checkpoint-conflict" then do
                                            _ <- expectRight =<< withProtectedEntry store (\protected -> compareAndSwapProtectedRecord protected checkpointKey ExpectAbsent "foreign checkpoint")
                                            pure ()
                                          else pure ()
                                        _ <- expectRight =<< withProtectedEntry store (\protected -> fmap (fmap (const ())) (compareAndSwapProtectedRecord protected key ExpectAbsent previous))
                                        _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["resource"]
                                        if mode == "interrupted" || mode == "interrupted-conflict" then do
                                            _ <- expectRight =<< withProtectedEntry store (\protected -> do
                                                found <- readProtectedRecord protected key
                                                case found of
                                                    Right (Just current) -> fmap (fmap (const ())) (compareAndSwapProtectedRecord protected key (ExpectVersion (protectedRecordVersion current)) successor)
                                                    Left failure -> pure (Left failure)
                                                    Right Nothing -> pure (Left (ProtectedInvalid "resource disappeared")))
                                            pure ()
                                          else pure ()
                                        if mode == "stale-gate" then do
                                            _ <- expectRight =<< TestRootedSession.withRootedOperationJournalKernel journal (\journalStore _ _ currentFence current pending -> do
                                                rotated <- withProtectedEntry journalStore (\protected -> do
                                                    result <- Session.rotateFence protected current currentFence
                                                    pure (either (Left . ProtectedInvalid . Text.pack . show) (const (Right ())) result))
                                                pure (case rotated of Left failure -> Left (Text.pack (show failure)); Right () -> Right (current, pending, ())))
                                            pure ()
                                          else pure ()
                                        before <- protectedImage store
                                        let outcome = if mode == "foreign" then TeardownForeignRetained "foreign" else TeardownReleased
                                            old = if mode == "malformed" then "malformed" else if mode == "stale-predecessor" || mode == "interrupted-conflict" then record "2" "owned" else if "foreign-" `isInfixOf` mode then foreignRecord "owned" else previous
                                            new = if mode == "tampered" then record "1" "owned" else if mode == "stale-predecessor" || mode == "interrupted-conflict" then record "2" "released" else if "foreign-" `isInfixOf` mode then foreignRecord "released" else changed
                                        result <- if mode == "response-interrupted" then do
                                            prior <- maybe (assertFailure "attached frame has no predecessor") pure framePrior
                                            let nonce = ByteString.replicate 32 34
                                            request <- expectRight (Rooted.rootedSettleNodeRequestKernel framePath token stage ordinal nonce prior observation)
                                            let requestWire = Rooted.renderRootedLifecycleRequestKernel request
                                            digest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest requestWire))
                                            checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                            settledStage <- expectRight (Rooted.mkLifecycleStage "settled")
                                            nextOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                            unsigned <- expectRight (Rooted.rootedSettledResponseUnsignedKernel digest framePath checkedToken settledStage nextOrdinal nonce (TextEncoding.encodeUtf8 (Handoff.childConfigDigest observation)))
                                            response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker requestWire unsigned
                                            let signed = Handoff.renderRootedLifecycleResponse response
                                            interrupted <- TestRootedNode.withSettledRootedNodeKernel runtime attached store "resource" requestWire signed
                                                (\key' row -> TestRootedSession.settleRootedReverseResourceJournalKernel journal attached (Just (key', row)) "resource" outcome old new)
                                                (\_ -> pure (Left "response interrupted"))
                                            interrupted @?= Left "response interrupted"
                                            pure (Right ())
                                          else TestRootedSession.settleRootedReverseResourceJournalKernel journal attached (Just (checkpointKey, checkpointRow)) "resource" outcome old new
                                        if mode `elem` ["released", "response-interrupted", "interrupted"]
                                            then do
                                                result @?= Right ()
                                                saved <- expectRight =<< withProtectedEntry store (\protected -> readProtectedRecord protected key)
                                                fmap protectedRecordBytes saved @?= Just successor
                                                checkpoint <- expectRight =<< withProtectedEntry store (\protected -> readProtectedRecord protected checkpointKey)
                                                fmap protectedRecordBytes checkpoint @?= Just checkpointRow
                                                if mode == "released" then do
                                                    afterAcknowledgement <- protectedImage store
                                                    retried <- TestRootedSession.settleRootedReverseResourceJournalKernel journal attached Nothing "resource" outcome old new
                                                    assertBool "acknowledged release is not yet replayable" (case retried of Left _ -> True; Right () -> False)
                                                    protectedImage store >>= (@?= afterAcknowledgement)
                                                  else pure ()
                                            else do
                                                assertBool ("refused " <> mode) (case result of Left _ -> True; Right () -> False)
                                                protectedImage store >>= (@?= before)
                                        pure (Left "interrupted" :: Either Text ())
                                    tested @?= Left "interrupted"
                                    pure (Right ())
                        expectRight brokered >>= expectRight
            , testCase "frame journal validates all resource evidence before any write" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 32))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 31))
                        let wire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Right (Handoff.renderRootedLifecycleResponse response))
                            plans = [digest | Just digest <- TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ -> if child == "vm-orchestrator-1" then Just (stablePlanSnapshotDigest (renderSnapshot plan)) else Nothing)]
                        plan <- case plans of [selected] -> pure selected; _ -> assertFailure "fixture did not select a child plan"
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] wire sign $ \attached _ -> do
                                journalRef <- newIORef Nothing
                                admitted <- TestRootedNode.withRootedFrameJournalKernel runtime root attached catalog store $ \operationSession fence permit -> do
                                    journal <- TestRootedSession.newRootedOperationJournalKernel attached store (Authority.rootAuthorityEpoch root) operationSession fence permit
                                    writeIORef journalRef (Just journal)
                                    pure (Right ())
                                expectRight admitted
                                journal <- readIORef journalRef >>= maybe (assertFailure "frame journal was not retained") pure
                                _ <- expectRight =<< TestRootedSession.prepareRootedOperationJournalKernel journal ["node", "projection"]
                                let validBytes = ByteString.concat (map frameWire ["hostbootstrap/resource-record-bundle", "1", TextEncoding.encodeUtf8 plan, "vm-orchestrator-1", "node", "1", "node", "1", "active", "fixture", "owned"])
                                    own = Rooted.RootedProjectedObservation "node" True (Just ("vm-orchestrator-1", Nothing, validBytes))
                                    bad = Rooted.RootedProjectedObservation "projection" True (Just ("vm-orchestrator-1", Nothing, "malformed"))
                                report <- expectRight (Rooted.renderRootedNodeObservationKernel (Rooted.RootedNodeObservation "node" True "" [own, bad]))
                                before <- protectedImage store
                                result <- TestRootedSession.settleRootedOperationJournalKernel journal "vm-orchestrator-1" "node" ["projection"] report
                                assertBool "malformed later resource refused" (case result of Left _ -> True; Right _ -> False)
                                protectedImage store >>= (@?= before)
                                pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "legacy settlement address replays only exact bytes" $
                withPreparedKernelFixture $ \store _project _root _authority _cursor _catalog _prepare _probe _ -> do
                    oldKey <- expectRight (mkRecordKey "legacy-settlement-test")
                    newKey <- expectRight (mkRecordKey "scoped-settlement-test")
                    empty <- protectedImage store
                    TestRootedSession.selectRootedSettlementAddressKernel store oldKey "old" newKey "new"
                        >>= (@?= Right (newKey, "new"))
                    protectedImage store >>= (@?= empty)
                    _ <- expectRight =<< withProtectedEntry store (\entry -> compareAndSwapProtectedRecord entry oldKey ExpectAbsent "old")
                    before <- protectedImage store
                    TestRootedSession.selectRootedSettlementAddressKernel store oldKey "old" newKey "new"
                        >>= (@?= Right (oldKey, "old"))
                    refused <- TestRootedSession.selectRootedSettlementAddressKernel store oldKey "different" newKey "new"
                    refused @?= Left "the legacy durable settlement row conflicts"
                    protectedImage store >>= (@?= before)
            , testCase "settlement binds signed response and replays only the exact observation" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 41))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                        let openingWire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign wire unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Handoff.renderRootedLifecycleResponse response)
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] openingWire (\unsigned -> Right <$> sign openingWire unsigned) $ \attached _ ->
                                TestRootedSession.withRootedFrameSessionKernel attached $ \_ _ _ _ _ path token stage ordinal predecessor -> do
                                    prior <- maybe (assertFailure "an attached session has no predecessor") pure predecessor
                                    let nonce = ByteString.replicate 32 11
                                        observation = "settled observation"
                                        makeRequest p t o n b = Rooted.rootedSettleNodeRequestKernel p t stage o n prior b
                                    request <- expectRight (makeRequest path token ordinal nonce observation)
                                    let wire = Rooted.renderRootedLifecycleRequestKernel request
                                    digest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest wire))
                                    checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                    checkedStage <- expectRight (Rooted.mkLifecycleStage "settled")
                                    nextOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                    let responseBody = TextEncoding.encodeUtf8 (Handoff.childConfigDigest observation)
                                        makeResponse d p t o n b = Rooted.rootedSettledResponseUnsignedKernel d p t checkedStage o n b
                                    unsigned <- expectRight (makeResponse digest path checkedToken nextOrdinal nonce responseBody)
                                    signed <- sign wire unsigned
                                    called <- newIORef (0 :: Int)
                                    let settle candidate candidateSigned = TestRootedNode.withSettledRootedNodeKernel runtime attached store "node" candidate candidateSigned (\_ _ -> pure (Right ())) $ \_ -> modifyIORef' called (+ 1) >> pure (Right ())
                                        reject label candidate candidateSigned before = do
                                            result <- settle candidate candidateSigned
                                            assertBool label (case result of Left _ -> True; Right _ -> False)
                                            protectedImage store >>= (@?= before)
                                    before <- protectedImage store
                                    refusedBefore <- TestRootedNode.withSettledRootedNodeKernel runtime attached store "node" wire signed (\_ _ -> pure (Left "journal refused")) (\_ -> assertFailure "refused journal published")
                                    assertBool "journal refusal is returned" (case refusedBefore of Left _ -> True; Right () -> False)
                                    protectedImage store >>= (@?= before)
                                    badBody <- expectRight (makeResponse digest path checkedToken nextOrdinal nonce "wrong observation") >>= sign wire
                                    reject "wrong response body" wire badBody before
                                    refusedStage <- expectRight (Rooted.mkLifecycleStage "refused")
                                    refused <- expectRight (Rooted.rootedRefusedResponseUnsignedKernel digest path checkedToken refusedStage nextOrdinal nonce "refused") >>= sign wire
                                    reject "signed refusal" wire refused before
                                    wrongOrdinal <- expectRight (Rooted.mkLifecycleOrdinal ordinal)
                                    stale <- expectRight (makeResponse digest path checkedToken wrongOrdinal nonce responseBody) >>= sign wire
                                    reject "non-successor response" wire stale before
                                    forM_ [("ancestry", ["foreign", "vm-orchestrator-1"], token, ordinal, nonce), ("frame", ["foreign-frame"], token, ordinal, nonce), ("session", path, "foreign-session", ordinal, nonce), ("ordinal", path, token, ordinal + 1, nonce), ("nonce", path, token, ordinal, ByteString.replicate 32 12)] $ \(label, p, t, o, n) -> do
                                        changed <- expectRight (makeRequest p t o n observation)
                                        reject label (Rooted.renderRootedLifecycleRequestKernel changed) signed before
                                    other <- expectRight (makeRequest path token ordinal nonce "different observation")
                                    let otherWire = Rooted.renderRootedLifecycleRequestKernel other
                                    otherDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest otherWire))
                                    otherUnsigned <- expectRight (makeResponse otherDigest path checkedToken nextOrdinal nonce responseBody)
                                    otherSigned <- sign otherWire otherUnsigned
                                    reject "another signed request" wire otherSigned before
                                    nextRequest <- expectRight (Rooted.rootedNextNodeRequestKernel path token stage ordinal nonce prior)
                                    let nextWire = Rooted.renderRootedLifecycleRequestKernel nextRequest
                                    nextDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest nextWire))
                                    descendStage <- expectRight (Rooted.mkLifecycleStage "descend")
                                    foreignFamily <- expectRight (Rooted.rootedDescendResponseUnsignedKernel nextDigest path checkedToken descendStage nextOrdinal nonce "foreign family") >>= sign nextWire
                                    reject "foreign response family" wire foreignFamily before
                                    let zeroRuntime = unsafeCoerce (ZeroGenerationRuntime Authority.ProjectUp "project" "tag" "store" 0 "key")
                                    zero <- TestRootedNode.withSettledRootedNodeKernel zeroRuntime attached store "node" wire signed (\_ _ -> pure (Right ())) $ \_ -> assertFailure "zero generation settled"
                                    assertBool "zero generation refused" (case zero of Left _ -> True; Right _ -> False)
                                    protectedImage store >>= (@?= before)
                                    readIORef called >>= (@?= 0)
                                    settle wire signed >>= (@?= Right ())
                                    committed <- protectedImage store
                                    settle wire signed >>= (@?= Right ())
                                    protectedImage store >>= (@?= committed)
                                    readIORef called >>= (@?= 2)
                                    otherBody <- expectRight (makeResponse otherDigest path checkedToken nextOrdinal nonce (TextEncoding.encodeUtf8 (Handoff.childConfigDigest "different observation"))) >>= sign otherWire
                                    preflightCalls <- newIORef (0 :: Int)
                                    conflict <- TestRootedNode.withSettledRootedNodeKernel runtime attached store "node" otherWire otherBody (\_ _ -> modifyIORef' preflightCalls (+ 1) >> pure (Right ())) (\_ -> pure (Right ()))
                                    assertBool "conflicting row refuses before journal transition" (case conflict of Left _ -> True; Right () -> False)
                                    readIORef preflightCalls >>= (@?= 0)
                                    reject "conflicting observation" otherWire otherBody committed
                                    pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "frame executor binds signed grants to current coordinates and exact packages" $
                BudgetFixture.withRoutedReservationFixture $ \budgetPlan budgetOperation reserve ->
                  withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 43))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        authenticated <- expectRight =<< Handoff.signAuthenticatedRootScopeKernel HandoffInternal.recoverySigningKernel broker (Handoff.productionHandoffScope project)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                        let openingWire = Rooted.renderRootedLifecycleRequestKernel opening
                            key = Handoff.rootBrokerVerificationKey broker
                            nodes = unsafeCoerce [ExecutorFixtureNode budgetOperation "vm-orchestrator-1" [] ["projection-a", "projection-b"] Nothing]
                            sign wire unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Handoff.renderRootedLifecycleResponse response)
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] openingWire (\unsigned -> Right <$> sign openingWire unsigned) $ \attached signedOpened ->
                                TestRootedSession.withRootedFrameSessionKernel attached $ \_ _ _ _ _ path token stage ordinal _ -> do
                                    foreignUnsigned <- expectRight (Rooted.rootedOpenedResponseUnsignedKernel (Handoff.childConfigDigest openingWire) ["foreign-frame"] token stage ordinal)
                                    foreignOpened <- sign openingWire foreignUnsigned
                                    wrongOpen <- TestFrameExecutor.withOpenedFrameExecutorKernel key authenticated Authority.ProjectUp "vm-orchestrator-1" budgetPlan nodes openingWire foreignOpened (\_ -> assertFailure "foreign frame opened")
                                    assertBool "foreign opening frame refused" (case wrongOpen of Left _ -> True; Right _ -> False)
                                    TestFrameExecutor.withOpenedFrameExecutorKernel key authenticated Authority.ProjectUp "vm-orchestrator-1" budgetPlan nodes openingWire signedOpened $ \executor -> do
                                        let nonce = ByteString.replicate 32 11
                                            gate plan catalogName frameName sessionName operation generation = gateWithFence plan catalogName frameName sessionName operation generation 9
                                            gateWithFence plan catalogName frameName sessionName operation generation fence = TestPreparedGate.renderFencedPreparedGatePackageKernel
                                                (TestPreparedGate.GatePlanDigest plan) (TestPreparedGate.GateCatalogIdentity catalogName)
                                                (TestPreparedGate.GateFrame frameName) (TestPreparedGate.GateSession sessionName)
                                                (TestPreparedGate.GateOperationKey operation) (TestPreparedGate.GateSupersessionGeneration generation)
                                                (TestPreparedGate.GateFence fence) (TestPreparedGate.GateAttempt 1) (TestPreparedGate.GateJournalVersion 1)
                                            own = gate budgetPlan "catalog" "vm-orchestrator-1" token budgetOperation 1
                                            first = gate budgetPlan "catalog" "vm-orchestrator-1" token "projection-a" 1
                                            second = gate budgetPlan "catalog" "vm-orchestrator-1" token "projection-b" 1
                                        TestFrameExecutor.withFrameExecutorRequestKernel executor TestFrameExecutor.FrameNextNode nonce $ \wire -> do
                                            digest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest wire))
                                            checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                            preparedStage <- expectRight (Rooted.mkLifecycleStage "prepared")
                                            nextOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                            let makeSigned gateBytes projections = do
                                                    unsigned <- expectRight (Rooted.rootedPreparedResponseUnsignedKernel digest path checkedToken preparedStage nextOrdinal nonce (TextEncoding.encodeUtf8 budgetOperation) (TestPreparedGate.renderPreparedNodeKeysKernel []) gateBytes (TestPreparedGate.renderPreparedGatePackagesKernel projections))
                                                    sign wire unsigned
                                            good <- makeSigned own [first, second]
                                            calls <- newIORef (0 :: Int)
                                            let invoke current request response = TestFrameExecutor.withExecutedFrameNodeKernel current key request response
                                                    (\_ _ _ _ _ -> modifyIORef' calls (+ 1) >> pure (Right "observation"))
                                                    (\_ -> pure (Right ()))
                                                reject label response = do
                                                    result <- invoke executor wire response
                                                    assertBool label (case result of Left _ -> True; Right _ -> False)
                                            reject "wrong plan" =<< makeSigned (gate "foreign" "catalog" "vm-orchestrator-1" token budgetOperation 1) [first, second]
                                            reject "wrong frame" =<< makeSigned (gate budgetPlan "catalog" "foreign" token budgetOperation 1) [first, second]
                                            reject "wrong session" =<< makeSigned (gate budgetPlan "catalog" "vm-orchestrator-1" "foreign" budgetOperation 1) [first, second]
                                            reject "zero generation" =<< makeSigned (gate budgetPlan "catalog" "vm-orchestrator-1" token budgetOperation 0) [first, second]
                                            reject "zero fence" =<< makeSigned (gateWithFence budgetPlan "catalog" "vm-orchestrator-1" token budgetOperation 1 0) [first, second]
                                            reject "foreign projected fence" =<< makeSigned own [first, gateWithFence budgetPlan "catalog" "vm-orchestrator-1" token "projection-b" 1 10]
                                            reject "foreign projected generation" =<< makeSigned own [first, gate budgetPlan "catalog" "vm-orchestrator-1" token "projection-b" 2]
                                            reject "wrong operation" =<< makeSigned (gate budgetPlan "catalog" "vm-orchestrator-1" token "other" 1) [first, second]
                                            reject "reordered projections" =<< makeSigned own [second, first]
                                            reject "foreign projection catalog" =<< makeSigned own [first, gate budgetPlan "other-catalog" "vm-orchestrator-1" token "projection-b" 1]
                                            descendStage <- expectRight (Rooted.mkLifecycleStage "descend")
                                            wrongFamily <- expectRight (Rooted.rootedDescendResponseUnsignedKernel digest path checkedToken descendStage nextOrdinal nonce "child") >>= sign wire
                                            reject "wrong response family" wrongFamily
                                            nonSuccessor <- expectRight (Rooted.mkLifecycleOrdinal ordinal)
                                            staleUnsigned <- expectRight (Rooted.rootedPreparedResponseUnsignedKernel digest path checkedToken preparedStage nonSuccessor nonce (TextEncoding.encodeUtf8 budgetOperation) (TestPreparedGate.renderPreparedNodeKeysKernel []) own (TestPreparedGate.renderPreparedGatePackagesKernel [first, second]))
                                            reject "non-successor ordinal" =<< sign wire staleUnsigned
                                            forM_ [("ancestry", ["foreign-frame"], token, ordinal), ("session coordinate", path, "foreign-session", ordinal), ("ordinal coordinate", path, token, ordinal + 1)] $ \(label, foreignPath, foreignToken, foreignOrdinal) -> do
                                                changed <- expectRight (Rooted.rootedNextNodeRequestKernel foreignPath foreignToken stage foreignOrdinal nonce (Handoff.childConfigDigest signedOpened))
                                                let changedWire = Rooted.renderRootedLifecycleRequestKernel changed
                                                changedDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest changedWire))
                                                changedToken <- expectRight (Rooted.mkLifecycleSession foreignToken)
                                                changedResponse <- expectRight (Rooted.rootedPreparedResponseUnsignedKernel changedDigest foreignPath changedToken preparedStage nextOrdinal nonce (TextEncoding.encodeUtf8 budgetOperation) (TestPreparedGate.renderPreparedNodeKeysKernel []) own (TestPreparedGate.renderPreparedGatePackagesKernel [first, second])) >>= sign changedWire
                                                result <- invoke executor changedWire changedResponse
                                                assertBool label (case result of Left _ -> True; Right _ -> False)
                                            readIORef calls >>= (@?= 0)
                                            valid <- TestFrameExecutor.withExecutedFrameNodeKernel executor key wire good
                                                (\_ ownGate projectedGates carrier resourcePrevious -> do
                                                    resourcePrevious @?= Nothing
                                                    TestPreparedGate.preparedGateFence ownGate @?= 9
                                                    reserve ownGate @?= Right 9
                                                    TestPreparedGate.preparedGateSupersessionGeneration ownGate @?= Just 1
                                                    map TestPreparedGate.preparedGateFence projectedGates @?= [9, 9]
                                                    reopened <- TestFrameExecutor.withOpenedFrameExecutorForPlanKernel key authenticated Authority.ProjectUp "vm-orchestrator-1" budgetPlan nodes carrier openingWire signedOpened $ \forPlan ->
                                                        TestFrameExecutor.withFrameExecutorRequestKernel forPlan TestFrameExecutor.FrameNextNode nonce $ \firstWire -> do
                                                            decoded <- expectRight (Rooted.rootedLifecycleRequestFromWireKernel firstWire)
                                                            let found = Rooted.withRootedLifecycleRequestKernel decoded
                                                                    (const Nothing) (\_ _ _ _ _ previous -> Just previous)
                                                                    (\_ _ _ _ _ _ _ -> Nothing) (\_ _ _ _ _ _ _ -> Nothing)
                                                                    (\_ _ _ _ _ _ -> Nothing) (\_ _ _ _ _ _ -> Nothing)
                                                            found @?= Just (Handoff.childConfigDigest signedOpened)
                                                            pure (Right ())
                                                    expectRight reopened
                                                    modifyIORef' calls (+ 1)
                                                    pure (Right "observation"))
                                                (\_ -> pure (Right ()))
                                            valid @?= Right ()
                                            advanced <- TestFrameExecutor.withAdvancedFrameExecutorKernel executor key wire good $ \next -> do
                                                replay <- invoke next wire good
                                                assertBool "replayed Prepared refused" (case replay of Left _ -> True; Right _ -> False)
                                                TestFrameExecutor.withFrameExecutorRequestKernel next TestFrameExecutor.FrameNextNode nonce $ \nextWire -> do
                                                    nextDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest nextWire))
                                                    laterOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 2))
                                                    let foreignOwn = gate budgetPlan "later-catalog" "vm-orchestrator-1" token budgetOperation 1
                                                        foreignFirst = gate budgetPlan "later-catalog" "vm-orchestrator-1" token "projection-a" 1
                                                        foreignSecond = gate budgetPlan "later-catalog" "vm-orchestrator-1" token "projection-b" 1
                                                    laterUnsigned <- expectRight (Rooted.rootedPreparedResponseUnsignedKernel nextDigest path checkedToken preparedStage laterOrdinal nonce (TextEncoding.encodeUtf8 budgetOperation) (TestPreparedGate.renderPreparedNodeKeysKernel []) foreignOwn (TestPreparedGate.renderPreparedGatePackagesKernel [foreignFirst, foreignSecond]))
                                                    laterSigned <- sign nextWire laterUnsigned
                                                    result <- invoke next nextWire laterSigned
                                                    assertBool "later foreign catalog refused" (case result of Left _ -> True; Right _ -> False)
                                                    pure (Right ())
                                            expectRight advanced
                                            readIORef calls >>= (@?= 1)
                                            reverseCheck <- TestFrameExecutor.withOpenedReverseFrameExecutorKernel key authenticated Authority.ProjectDown "vm-orchestrator-1" budgetPlan nodes openingWire signedOpened $ \reverseExecutor -> do
                                                wrapped <- expectRight (Rooted.renderReversePreparedGateEnvelopeKernel own (Just "predecessor"))
                                                signedReverse <- makeSigned wrapped [first, second]
                                                let execute response = TestFrameExecutor.withExecutedFrameNodeKernel reverseExecutor key wire response
                                                        (\_ _ _ _ previous -> (previous @?= Just "predecessor") >> pure (Right "observation")) (\_ -> pure (Right ()))
                                                execute signedReverse >>= (@?= Right ())
                                                rawReverse <- execute good
                                                assertBool "reverse executor rejects an unwrapped gate" (case rawReverse of Left _ -> True; Right () -> False)
                                                TestFrameExecutor.withAdvancedFrameExecutorKernel reverseExecutor key wire signedReverse (\_ -> pure (Right ()))
                                            expectRight reverseCheck
                                            failedUpCheck <- TestFrameExecutor.withOpenedReverseFrameExecutorKernel key authenticated Authority.ProjectUp "vm-orchestrator-1" budgetPlan nodes openingWire signedOpened $ \reverseExecutor -> do
                                                wrapped <- expectRight (Rooted.renderReversePreparedGateEnvelopeKernel own (Just "predecessor"))
                                                signedReverse <- makeSigned wrapped [first, second]
                                                executed <- TestFrameExecutor.withExecutedFrameNodeKernel reverseExecutor key wire signedReverse
                                                    (\_ _ _ _ previous -> (previous @?= Just "predecessor") >> pure (Right "observation")) (\_ -> pure (Right ()))
                                                executed @?= Right ()
                                                TestFrameExecutor.withAdvancedFrameExecutorKernel reverseExecutor key wire signedReverse (\_ -> pure (Right ()))
                                            expectRight failedUpCheck
                                            pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "receipt confirmation refuses a stale completion before receiving" $
                withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 42))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                        let openingWire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign wire unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                pure (Handoff.renderRootedLifecycleResponse response)
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session ->
                            TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] openingWire (\unsigned -> Right <$> sign openingWire unsigned) $ \attached _ ->
                                TestRootedSession.withRootedFrameSessionKernel attached $ \_ _ _ _ _ path token stage ordinal predecessor -> do
                                    let stale = Text.replicate 64 "a"
                                        nonce = ByteString.replicate 32 13
                                    assertBool "fixture completion differs from recorded predecessor" (predecessor /= Just stale)
                                    request <- expectRight (Rooted.rootedReceiptConfirmRequestKernel path token stage ordinal nonce stale)
                                    let wire = Rooted.renderRootedLifecycleRequestKernel request
                                    digest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest wire))
                                    checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                    receiptStage <- expectRight (Rooted.mkLifecycleStage "receipt-recorded")
                                    nextOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                    completion <- expectRight (Rooted.mkPredecessorDigest stale)
                                    unsigned <- expectRight (Rooted.rootedReceiptRecordedResponseUnsignedKernel digest path checkedToken receiptStage nextOrdinal nonce completion)
                                    signed <- sign wire unsigned
                                    before <- protectedImage store
                                    result <- TestRootedReceipt.withRootedReceiptConfirmationKernel runtime attached wire stale signed (assertFailure "stale receipt reached durable receive") (\_ -> assertFailure "stale receipt reached continuation")
                                    result @?= Left "rooted terminal receipt: the completion differs from the session predecessor"
                                    protectedImage store >>= (@?= before)
                                    pure (Right ())
                    expectRight brokered >>= expectRight
            , testCase "forward terminal reports require the root-issued settled stage" $
                HandoffFixture.withForwardLifecycleFixture 72 $ \binding origin ->
                    withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                        signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 40))
                        brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                            runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                            opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                            let openingWire = Rooted.renderRootedLifecycleRequestKernel opening
                                sign wire unsigned = do
                                    response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker wire unsigned
                                    pure (Handoff.renderRootedLifecycleResponse response)
                            called <- newIORef (0 :: Int)
                            let publish _ = modifyIORef' called (+ 1) >> pure (Right ())
                                completed session = TerminalReport.withForwardRootedTerminalReportKernel session catalog origin publish
                                failed session = TerminalReport.withFailedForwardRootedTerminalReportKernel session binding [("node", "failed", "boom")] "boom" publish
                            TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp "vm-orchestrator-1" $ \session -> do
                                completed session >>= (@?= Left "an unopened frame has no terminal settlement")
                                failed session >>= (@?= Left "an unopened frame has no terminal failure")
                                TestRootedSession.withRootedFrameOpeningKernel runtime session store ["vm-orchestrator-1"] openingWire (\unsigned -> Right <$> sign openingWire unsigned) $ \attached _ -> do
                                    before <- protectedImage store
                                    completed attached >>= (@?= Left "the rooted frame session has not advanced through settlement")
                                    failed attached >>= (@?= Left "the rooted frame session has not advanced through failure settlement")
                                    readIORef called >>= (@?= 0)
                                    protectedImage store >>= (@?= before)
                                    -- An unstarted nonempty frame is no empty frame, and an absent one has no entry.
                                    TestRootedSession.rootedEmptyFrameProofKernel catalog "vm-orchestrator-1" @?= Left "the catalog-selected frame has admitted work"
                                    TestRootedSession.rootedEmptyFrameProofKernel catalog "absent-frame" @?= Left "the frame is not exactly one catalog entry"
                                    TestRootedSession.withRootedFrameSessionKernel attached $ \_ _ _ _ _ path token stage ordinal predecessor -> do
                                        prior <- maybe (assertFailure "an attached session has no predecessor") pure predecessor
                                        request <- expectRight (Rooted.rootedNextNodeRequestKernel path token stage ordinal (ByteString.replicate 32 11) prior)
                                        let wire = Rooted.renderRootedLifecycleRequestKernel request
                                            nonce = ByteString.replicate 32 11
                                        digest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest wire))
                                        checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                        nextOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                        descendStage <- expectRight (Rooted.mkLifecycleStage "descend")
                                        descend <- expectRight (Rooted.rootedDescendResponseUnsignedKernel digest path checkedToken descendStage nextOrdinal nonce "child") >>= sign wire
                                        unfinishedResult <- TestRootedSession.withAdvancedRootedFrameSessionKernel attached wire descend $ \unfinished -> do
                                            completed unfinished >>= (@?= Left "the rooted frame session has not advanced through settlement")
                                            failed unfinished >>= (@?= Left "the rooted frame session has not advanced through failure settlement")
                                            readIORef called >>= (@?= 0)
                                            protectedImage store >>= (@?= before)
                                            pure (Right ())
                                        expectRight unfinishedResult
                                        settleRequest <- expectRight (Rooted.rootedSettleNodeRequestKernel path token stage ordinal nonce prior "observation")
                                        let settleWire = Rooted.renderRootedLifecycleRequestKernel settleRequest
                                        settleDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest settleWire))
                                        settledStage <- expectRight (Rooted.mkLifecycleStage "settled")
                                        settled <- expectRight (Rooted.rootedSettledResponseUnsignedKernel settleDigest path checkedToken settledStage nextOrdinal nonce "observation") >>= sign settleWire
                                        finishedResult <- TestRootedSession.withAdvancedRootedFrameSessionKernel attached settleWire settled $ \finished -> do
                                            completed finished >>= (@?= Right ())
                                            failed finished >>= (@?= Right ())
                                            pure (Right ())
                                        expectRight finishedResult
                                        readIORef called >>= (@?= 2)
                                        pure (Right ())
                        expectRight brokered >>= expectRight
            , testCase "forward terminal reports refuse a non-Up session" $
                HandoffFixture.withForwardLifecycleFixture 74 $ \binding origin ->
                    withPreparedKernelFixture $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                        signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 40))
                        brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                            upRuntime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                            opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                            let openingWire = Rooted.renderRootedLifecycleRequestKernel opening
                                sign unsigned = do
                                    response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker openingWire unsigned
                                    pure (Right (Handoff.renderRootedLifecycleResponse response))
                            TestHandoffRuntime.withRecursiveHandoffRuntimeKernel upRuntime $ \_ runtimeProject tag storeId generation _ key _ -> do
                                let downRuntime = unsafeCoerce (DownFixtureRuntime Authority.ProjectDown runtimeProject tag storeId generation key)
                                TestRootedSession.withRootOpenedFrameSessionKernel downRuntime catalog store Authority.ProjectDown "vm-orchestrator-1" $ \session ->
                                    TestRootedSession.withRootedFrameOpeningKernel downRuntime session store ["vm-orchestrator-1"] openingWire sign $ \attached _ -> do
                                        before <- protectedImage store
                                        TestRootedSession.withFailedRootedFrameSessionKernel attached (\_ _ _ _ _ _ -> ())
                                            @?= Left "rooted frame session: the failed session is not an Up session"
                                        let forgedUp = unsafeCoerce attached
                                            reject _ = assertFailure "a non-Up session produced a report"
                                        TerminalReport.withForwardRootedTerminalReportKernel forgedUp catalog origin reject
                                            >>= (@?= Left "a forward terminal report requires the Up session")
                                        TerminalReport.withFailedForwardRootedTerminalReportKernel forgedUp binding [] "boom" reject
                                            >>= (@?= Left "a forward failure report requires the Up session")
                                        protectedImage store >>= (@?= before)
                                        pure (Right ())
                        expectRight brokered >>= expectRight
            , testCase "an empty child is not an admitted step-plan frame" $ do
                let rootOnly =
                        [ descendsVia (LiftContext.vmContext (LiftContext.inVM (LiftContext.IncusVM "fixture-vm" "fixture:image") LiftContext.emptyVMStack))
                            (deployVMStep "launch" metalFrame noop)
                        ]
                case mkStepPlan rootOnly of
                    Left (DescentFromInnermostFrame frame) -> frame @?= "host-orchestrator-0"
                    Left other -> assertFailure ("unexpected plan refusal: " ++ show other)
                    Right _ -> assertFailure "a descent into an undeclared empty child was admitted"
            , testCase "each admitted child frame retains a forward node" $
                withPreparedKernelFixture $ \_store _project _root _authority _cursor catalog _prepare _probe _ -> do
                    let entries = TestRootedPlan.withRootedPlanCatalogEntriesKernel catalog $
                            \plan _ current _ (TestRootedPlan.ChildFrameId child) _ _ _ _ _ _ ->
                                ( child
                                , currentFrameId current
                                , [ TestLifecyclePlan.plannedStepFrameIdKernel step
                                  | step <- NonEmpty.toList (TestLifecyclePlan.forwardKernel plan)
                                  , TestLifecyclePlan.plannedStepFrameIdKernel step == child
                                  ]
                                )
                    assertBool "the fixture admits a child" (not (null entries))
                    forM_ entries $ \(child, current, nodes) -> do
                        current @?= child
                        assertBool "the admitted child has no forward node" (not (null nodes))
            , testCase "advancement requires one ordinal and refuses terminal stages" $
              mapM_ (\(child, expectedPath) ->
                withPreparedKernelFixtureWith True $ \store project root _authority _cursor catalog _prepare _probe _ -> do
                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 40))
                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing root $ \broker -> do
                        runtime <- expectRight (TestHandoffRuntime.rootRecursiveHandoffRuntimeKernel broker (Handoff.productionHandoffScope project) (Handoff.rootBrokerRoute broker) root Authority.ProjectUp)
                        opening <- expectRight (Rooted.rootedOpenFrameRequestKernel (ByteString.replicate 32 10))
                        let openingWire = Rooted.renderRootedLifecycleRequestKernel opening
                            sign request unsigned = do
                                response <- expectRight =<< Handoff.signRootedLifecycleResponseKernel HandoffInternal.recoverySigningKernel broker request unsigned
                                pure (Handoff.renderRootedLifecycleResponse response)
                        TestRootedSession.withRootOpenedFrameSessionKernel runtime catalog store Authority.ProjectUp child $ \session ->
                            do
                              TestRootedSession.withFailedRootedFrameSessionKernel session (\_ _ _ _ _ _ -> ())
                                  @?= Left "rooted frame session: the failed session was never attached"
                              TestRootedSession.withRootedFrameOpeningKernel runtime session store expectedPath openingWire (\unsigned -> Right <$> sign openingWire unsigned) $ \attached _ -> do
                                TestRootedSession.withFailedRootedFrameSessionKernel attached (\_ _ _ _ _ _ -> ())
                                    @?= Left "rooted frame session: the failed session has not reached a terminal failure stage"
                                TestRootedSession.withRootedFrameSessionKernel attached $ \_ _ _ _ _ path token stage ordinal predecessor -> do
                                    prior <- maybe (assertFailure "an attached session has no predecessor") pure predecessor
                                    request <- expectRight (Rooted.rootedNextNodeRequestKernel path token stage ordinal (ByteString.replicate 32 11) prior)
                                    let wire = Rooted.renderRootedLifecycleRequestKernel request
                                    digest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest wire))
                                    checkedToken <- expectRight (Rooted.mkLifecycleSession token)
                                    refusedStage <- expectRight (Rooted.mkLifecycleStage "refused")
                                    jumpOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 2))
                                    jumpUnsigned <- expectRight (Rooted.rootedRefusedResponseUnsignedKernel digest path checkedToken refusedStage jumpOrdinal (ByteString.replicate 32 11) "test refusal")
                                    jump <- sign wire jumpUnsigned
                                    TestRootedSession.withAdvancedRootedFrameSessionKernel attached wire jump (\_ -> assertFailure "a skipped ordinal advanced")
                                        >>= (@?= Left "rooted frame session: the response does not advance the ordinal by exactly one")
                                    nextOrdinal <- expectRight (Rooted.mkLifecycleOrdinal (ordinal + 1))
                                    terminalUnsigned <- expectRight (Rooted.rootedRefusedResponseUnsignedKernel digest path checkedToken refusedStage nextOrdinal (ByteString.replicate 32 11) "test refusal")
                                    terminal <- sign wire terminalUnsigned
                                    refusedResult <- TestRootedSession.withAdvancedRootedFrameSessionKernel attached wire terminal $ \refused -> do
                                        case TestRootedSession.withFailedRootedFrameSessionKernel refused (\_ _ frame actualPath _ _ -> (frame, actualPath)) of
                                            Right (actualFrame, actualPath) | actualFrame == child && actualPath == expectedPath -> pure ()
                                            other -> assertFailure ("terminal Up session refused: " <> show other)
                                        HandoffFixture.withForwardLifecycleFixture 118 $ \binding _ -> do
                                            report <- expectRight (Handoff.renderForwardFailedLifecycleReportWithObservations binding [("project:root", "failed", "failure")] "failure")
                                            FailedUp.withFailedUpUnwindAuthorityKernel root catalog refused report binding ["project:root"] ["project:root"]
                                                (\authority -> FailedUp.withFailedUpCleanupOperationsKernel authority id)
                                                @?= Right ["project:root"]
                                            FailedUp.withFailedUpUnwindAuthorityKernel root catalog refused report "foreign binding" ["project:root"] [] (const ())
                                                @?= Left "failed-Up unwind authority: the failed report names another admitted binding"
                                            withNestedRootedCatalog $ \_ _ _ foreignPlan ->
                                                FailedUp.withFailedUpUnwindAuthorityKernel root (unsafeCoerce foreignPlan) refused report binding ["project:root"] [] (const ())
                                                    @?= Left "failed-Up unwind authority: the failed session names another root plan"
                                            withNestedRootedCatalogAtEpoch True $ \_ _ foreignRoot foreignCatalog -> do
                                                FailedUp.withFailedUpUnwindAuthorityKernel root (unsafeCoerce foreignCatalog) refused report binding ["project:root"] [] (const ())
                                                    @?= Left "failed-Up unwind authority: the failed session names another catalog"
                                                FailedUp.withFailedUpUnwindAuthorityKernel (unsafeCoerce foreignRoot) catalog refused report binding ["project:root"] [] (const ())
                                                    @?= Left "failed-Up unwind authority: the catalog root names another broker generation"
                                                FailedUp.withRootFailedUpUnwindAuthorityKernel (unsafeCoerce foreignRoot) catalog report binding "host-orchestrator-0" ["project:root"] [] (const ())
                                                    @?= Left "failed-Up unwind authority: the catalog root names another broker generation"
                                            foreignProjectAction <- expectRight $
                                                AuthorityFixture.withInstalledProjectKernel "foreign-fixture-project" $ \foreignProject ->
                                                    withNestedRootedCatalogForProject False foreignProject $ \_ _ foreignRoot _ -> do
                                                        FailedUp.withFailedUpUnwindAuthorityKernel (unsafeCoerce foreignRoot) catalog refused report binding ["project:root"] [] (const ())
                                                            @?= Left "failed-Up unwind authority: the catalog root names another project"
                                                        FailedUp.withRootFailedUpUnwindAuthorityKernel (unsafeCoerce foreignRoot) catalog report binding "host-orchestrator-0" ["project:root"] [] (const ())
                                                            @?= Left "failed-Up unwind authority: the catalog root names another project"
                                            foreignProjectAction
                                        TestRootedSession.withAdvancedRootedFrameSessionKernel refused wire terminal (\_ -> assertFailure "a refused session advanced")
                                            >>= (@?= Left "rooted frame session: a terminal rooted frame session cannot advance")
                                        pure (Right ())
                                    expectRight refusedResult
                                    receiptRequest <- expectRight (Rooted.rootedReceiptConfirmRequestKernel path token stage ordinal (ByteString.replicate 32 13) prior)
                                    let receiptWire = Rooted.renderRootedLifecycleRequestKernel receiptRequest
                                    receiptDigest <- expectRight (Rooted.mkRequestDigest (Handoff.childConfigDigest receiptWire))
                                    receiptStage <- expectRight (Rooted.mkLifecycleStage "receipt-recorded")
                                    completion <- expectRight (Rooted.mkPredecessorDigest prior)
                                    receiptUnsigned <- expectRight (Rooted.rootedReceiptRecordedResponseUnsignedKernel receiptDigest path checkedToken receiptStage nextOrdinal (ByteString.replicate 32 13) completion)
                                    receipt <- sign receiptWire receiptUnsigned
                                    TestRootedSession.withAdvancedRootedFrameSessionKernel attached receiptWire receipt $ \recorded -> do
                                        TestRootedSession.withAdvancedRootedFrameSessionKernel recorded receiptWire receipt (\_ -> assertFailure "a recorded session advanced")
                                            >>= (@?= Left "rooted frame session: a terminal rooted frame session cannot advance")
                                        pure (Right ())
                    expectRight brokered >>= expectRight
              ) [("vm-orchestrator-1", ["vm-orchestrator-1"]), ("vm-project-container-2", ["vm-orchestrator-1", "vm-project-container-2"])]
            ]
        , testGroup "catalog forward-package rechecks"
            [ testCase label $
                withPreparedKernelFixture $ \store _project _root _authority _cursor catalog _prepare _probe _ -> do
                    called <- newIORef (0 :: Int)
                    let invoke candidate = TestForwardHandoff.withCatalogForwardHandoffKernel
                            candidate "host-orchestrator-0" "vm-orchestrator-1"
                            (\_ -> modifyIORef' called (+ 1) >> pure (Right ()))
                    invoke catalog >>= (@?= Right ())
                    readIORef called >>= (@?= 1)
                    before <- protectedImage store
                    invoke (TestCatalogFixtures.driftCatalogEdge drift catalog)
                        >>= (@?= Left ("catalog forward handoff: " <> expected))
                    readIORef called >>= (@?= 1)
                    protectedImage store >>= (@?= before)
            | (label, drift, expected) <-
                [ ("foreign child current frame", TestCatalogFixtures.ChildFrameDrift, "the admitted child frame differs from its own retained current frame")
                , ("configuration endpoint", TestCatalogFixtures.ConfigEndpointDrift, "the admitted child configuration does not end at the admitted child frame")
                , ("configuration digest", TestCatalogFixtures.ConfigDigestDrift, "the admitted child configuration digest differs from the target plan's own")
                , ("payload digest", TestCatalogFixtures.PayloadDigestDrift, "the admitted configuration and payload digests differ")
                , ("canonical payload bytes", TestCatalogFixtures.PayloadBytesDrift, "the admitted canonical payload no longer hashes to its retained digest")
                , ("bound child plan digest", TestCatalogFixtures.PlanBindingDrift, "the admitted child plan digest differs from the target plan's own")
                , ("route with no lift layer", TestCatalogFixtures.RouteDrift, "the admitted route is not exactly one lift layer")
                , ("route with composed lift layers", TestCatalogFixtures.ComposedRouteDrift, "the admitted route is not exactly one lift layer")
                ]
            ]
        , testGroup "the reverse projection" projectionTests
        , testGroup "the forest" forestTests
        , testGroup "the observation codec" observationCodecTests
        , testGroup "settlement" settlementTests
        , testGroup "the production driver" driverTests
        , testGroup "source shape" sourceShapeTests
        ]

-- Build the same two-level catalog used by the recursive process fixture.
withNestedRootedCatalog ::
    (forall projectId planId generation catalogId.
      ProtectedStore -> Authority.InstalledProjectIdentity projectId ->
      Authority.RootInvocationAuthority (Production projectId) generation Authority.VerbUp ->
      TestRootedPlan.RootedPlanCatalog (Production projectId) planId generation catalogId -> IO ()) -> IO ()
withNestedRootedCatalog = withNestedRootedCatalogAtEpoch False

-- A prior allocation gives a second genuine catalog a different profile epoch.
withNestedRootedCatalogAtEpoch ::
    Bool ->
    (forall projectId planId generation catalogId.
      ProtectedStore -> Authority.InstalledProjectIdentity projectId ->
      Authority.RootInvocationAuthority (Production projectId) generation Authority.VerbUp ->
      TestRootedPlan.RootedPlanCatalog (Production projectId) planId generation catalogId -> IO ()) -> IO ()
withNestedRootedCatalogAtEpoch priorAllocation use =
    Fixture.withFixtureInstalledProject $ \project -> withNestedRootedCatalogForProject priorAllocation project use

withNestedRootedCatalogForProject ::
    forall projectId.
    Bool ->
    Authority.InstalledProjectIdentity projectId ->
    (forall planId generation catalogId.
      ProtectedStore -> Authority.InstalledProjectIdentity projectId ->
      Authority.RootInvocationAuthority (Production projectId) generation Authority.VerbUp ->
      TestRootedPlan.RootedPlanCatalog (Production projectId) planId generation catalogId -> IO ()) -> IO ()
withNestedRootedCatalogForProject priorAllocation project use =
        withSystemTempDirectory "hostbootstrap-nested-rooted" $ \directory -> do
            rooted <- withCanonicalProjectRoot (directory </> "fixture.dhall") directory $ \root -> do
                let name = Authority.installedProjectName project
                    value = Fixture.defaultProjectConfig name (Text.pack (canonicalProjectRootPath root)) Context.HostOrchestrator
                store <- expectRight =<< openProtectedStore (directory </> ".hostbootstrap" </> "authority" </> Text.unpack name)
                if priorAllocation
                    then do
                        allocated <- expectRight =<< withProtectedEntry store (\protected -> Right <$> AuthorityFixture.withFreshBrokerEpochKernel protected project (\_ -> pure (Right ())))
                        expectRight allocated
                    else pure ()
                opened <- withProductionRoot store project Authority.ProjectUp $ \production -> do
                    let authority = productionRootAuthority production
                    profiled <- expectRight =<< withProductionLifecycleProfile
                        (Authority.rootScopeAuthority authority)
                        (productionActiveMode (productionRootModeLease production))
                        (productionRootUnboundLease production)
                        (\profile -> withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec ->
                            withFinalizedProjectSpec codec emptyServiceRegistry
                                (\_ config -> mkStepPlan (RecursiveFixture.fixtureSteps directory False False config))
                                (RecursiveFixture.projectChild directory False False) $ \spec -> do
                                    validated <- withValidatedConfig (finalizedProjectCodec spec) value $ \_ config -> do
                                        drafts <- expectRight (projectPlanDrafts spec root config)
                                        action <- expectRight $ withProjectPlan profile root config drafts $ \plan -> do
                                            contextual <- LifecycleContext.withValidatedLifecycleContext root store plan value.context $ \context -> do
                                                currentAction <- expectRight $ withCurrentFrame plan value.context $ \current _ _ ->
                                                    TestRootedPlan.withRootedPlanCatalogKernel spec authority plan (unsafeCoerce current) context $ \catalog ->
                                                        use store project authority catalog >> pure (Right ())
                                                expectRight =<< currentAction
                                            expectRight contextual
                                        action
                                    expectRight validated)
                    result <- profiled
                    pure (Right result)
                expectRight opened
            expectRight rooted

-- Each fixture carries a genuine root reservation and the production preparation
-- kernel. Only the negative cross-store case aligns its generative indices.
withPreparedKernelFixture ::
    ( forall projectId planId frame generation catalogId.
      ProtectedStore ->
      Authority.InstalledProjectIdentity projectId ->
      Authority.RootInvocationAuthority (Production projectId) generation Authority.VerbUp ->
      Authority.CommandAuthority (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
      LifecycleCursor (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
      TestRootedPlan.RootedPlanCatalog (Production projectId) planId generation catalogId ->
      ( Authority.CommandAuthority (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
        LifecycleCursor (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
        IO () ->
        IO (Either Text ())
      ) ->
      IO (Either Text ()) ->
      IO () ->
      IO ()
    ) -> IO ()
withPreparedKernelFixture = withPreparedKernelFixtureWith False

withPreparedKernelFixtureWith ::
    Bool ->
    ( forall projectId planId frame generation catalogId.
      ProtectedStore ->
      Authority.InstalledProjectIdentity projectId ->
      Authority.RootInvocationAuthority (Production projectId) generation Authority.VerbUp ->
      Authority.CommandAuthority (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
      LifecycleCursor (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
      TestRootedPlan.RootedPlanCatalog (Production projectId) planId generation catalogId ->
      ( Authority.CommandAuthority (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
        LifecycleCursor (Production projectId) planId frame generation Authority.VerbUp Authority.ExecutePhase ->
        IO () -> IO (Either Text ())
      ) ->
      IO (Either Text ()) -> IO () -> IO ()
    ) -> IO ()
withPreparedKernelFixtureWith includeSecond use =
    Fixture.withFixtureInstalledProject $ \(project :: Authority.InstalledProjectIdentity projectId) ->
        withSystemTempDirectory "hostbootstrap-prepared-kernel" $ \directory -> do
            rooted <- withCanonicalProjectRoot (directory </> "fixture.dhall") directory $ \root -> do
                let rootPath = canonicalProjectRootPath root
                    name = Authority.installedProjectName project
                    value = Fixture.defaultProjectConfig name (Text.pack rootPath) Context.HostOrchestrator
                    exactContext = value.context
                    steps =
                        if includeSecond
                            then RecursiveFixture.fixtureSteps rootPath False False value
                            else
                                [ descendsVia (LiftContext.vmContext (LiftContext.inVM (LiftContext.IncusVM "fixture-vm" "fixture:image") LiftContext.emptyVMStack))
                                    (deployVMStep "launch" metalFrame noop)
                                , buildPbStep "build" vmFrame noop
                                ]
                graph <- expectRight (mkStepPlan steps)
                store <- expectRight =<< openProtectedStore (rootPath </> ".hostbootstrap" </> "authority" </> Text.unpack name)
                opened <- withProductionRoot store project Authority.ProjectUp $ \production -> do
                    let rootAuthority = productionRootAuthority production
                        unbound = productionRootUnboundLease production
                    profiled <- expectRight =<< withProductionLifecycleProfile
                        (Authority.rootScopeAuthority rootAuthority)
                        (productionActiveMode (productionRootModeLease production))
                        unbound
                        (\profile -> withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                            withFinalizedProjectSpec baseCodec emptyServiceRegistry
                                (\_ _ -> Right graph)
                                (if includeSecond then RecursiveFixture.projectChild rootPath False False else Fixture.projectingForwardChildPlan "/workspace/demo" steps) $ \spec -> do
                                    validated <- withValidatedConfig (finalizedProjectCodec spec) value $ \_wire config -> do
                                        drafts <- expectRight (projectPlanDrafts spec root config)
                                        planAction <- expectRight $ withProjectPlan profile root config drafts $ \plan -> do
                                            persisted <- withPersistedPlanSnapshot rootAuthority unbound plan $ \verified bound binding lease _ -> do
                                                contextual <- LifecycleContext.withValidatedLifecycleContext root store plan exactContext $ \lifecycleContext -> do
                                                    frameAction <- expectRight $ withCurrentFrame plan exactContext $ \current frame _ -> do
                                                        journaled <- withAcquisitionJournal rootAuthority lease bound binding plan $ \journal -> do
                                                            cursored <- withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                                                                executed <- withExecuteLifecycleCursor prepareCursor $ \cursor -> do
                                                                    let aligned = unsafeCoerce cursor
                                                                        reauthorize = ProjectAuthority.authorizeRootProject rootAuthority Authority.ProjectUp verified bound binding lease plan journal aligned lifecycleContext project
                                                                        reached = map (Text.pack . ProjectPlan.operationKeyText . plannedStepOperationKey) (NonEmpty.toList (forward plan))
                                                                    authority <- expectRight =<< reauthorize
                                                                    cataloged <- TestRootedPlan.withRootedPlanCatalogKernel spec rootAuthority plan (unsafeCoerce current) lifecycleContext $ \catalog -> do
                                                                        projection <- expectRight (TestTeardown.failedUpTeardownPlanKernel plan current reached)
                                                                        forest <- expectRight (openTeardownForest projection)
                                                                        let seek pending = eliminateTeardownProgress (nextTeardownWork pending)
                                                                                (\_ -> assertFailure "the fixture has no descent")
                                                                                (\point -> withTeardownAuthorization point
                                                                                    (\pre -> seek (attemptPreDescentStep pre TeardownReleased))
                                                                                    (\_ work -> eliminateTeardownWork work
                                                                                        (\local -> seek (attemptLocalWork local TeardownReleased))
                                                                                        (\descent -> do
                                                                                            let prepare candidate candidateCursor callback = do
                                                                                                    result <- TestTeardownInternal.withPreparedReverseDescentKernel
                                                                                                        TestLifecyclePlan.acquisitionJournalAdmissionKernel rootAuthority Authority.ProjectUp plan catalog lifecycleContext journal candidateCursor candidate (pure (Right candidate)) descent (\_ -> callback)
                                                                                                    pure $ case result of
                                                                                                        Left (TeardownReverseDescentRefused detail, _) -> Left detail
                                                                                                        Left (failure, _) -> Left (Text.pack (teardownErrorMessage failure))
                                                                                                        Right () -> Right ()
                                                                                                boundForwardProbe = do
                                                                                                    signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 61))
                                                                                                    captured <- newIORef Nothing
                                                                                                    brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope project) store signing rootAuthority $ \broker -> do
                                                                                                        let forwardPayload = "forward-config"
                                                                                                            forwardInput = Handoff.HandoffBindingInput
                                                                                                                { Handoff.requestedSpecDigest = "fixture-spec"
                                                                                                                , Handoff.requestedPayloadKind = Handoff.NarrowedProjectConfig
                                                                                                                , Handoff.requestedPlanRevision = "fixture-plan"
                                                                                                                , Handoff.requestedParentFrame = "host-orchestrator-0"
                                                                                                                , Handoff.requestedChildFrame = "vm-orchestrator-1"
                                                                                                                , Handoff.requestedChildConfigDigest = Handoff.childConfigDigest forwardPayload
                                                                                                                , Handoff.requestedPhase = "execute"
                                                                                                                }
                                                                                                        (forwardRelay, forwardToken) <- expectRight =<< Handoff.registerHandoffEdge broker forwardInput
                                                                                                        forwardOffer <- expectRight (Handoff.mkHandoffOffer forwardRelay forwardPayload forwardToken)
                                                                                                        prepared <- TestTeardownInternal.withPreparedReverseDescentKernel
                                                                                                            TestLifecyclePlan.acquisitionJournalAdmissionKernel rootAuthority Authority.ProjectUp plan catalog lifecycleContext journal aligned authority (pure (Right authority)) descent $ \preparedDescent -> do
                                                                                                                attached <- TestTeardownInternal.withBoundReverseDescentKernel HandoffInternal.recoverySigningKernel preparedDescent
                                                                                                                    (\input payload -> do
                                                                                                                        registered <- Handoff.registerHandoffEdge broker input
                                                                                                                        pure $ case registered of
                                                                                                                            Left failure -> Left (Text.pack (Handoff.handoffErrorMessage failure))
                                                                                                                            Right (relay, token) -> either (Left . Text.pack . Handoff.handoffErrorMessage) Right (Handoff.mkHandoffOffer relay payload token))
                                                                                                                    (\boundDescent offer -> do
                                                                                                                        beforeReplay <- protectedImage store
                                                                                                                        pendingReplay <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "unadopted Bound row minted settlement")
                                                                                                                        case pendingReplay of
                                                                                                                            Right (Right False) -> pure ()
                                                                                                                            _ -> assertFailure "unadopted Bound row did not resume"
                                                                                                                        protectedImage store >>= (@?= beforeReplay)
                                                                                                                        keys <- withDescentWorkSubtree descent $ \childProjection ->
                                                                                                                            teardownForestOutstanding <$> expectRight (openTeardownForest childProjection)
                                                                                                                        assertBool "the fixture's child has observable work" (not (null keys))
                                                                                                                        let observedBinding = Handoff.renderHandoffBinding (Handoff.handoffOfferBinding offer)
                                                                                                                            exactRows = [(key, TeardownReleased) | key <- keys]
                                                                                                                            verify rows = TestTeardownInternal.withVerifiedBoundReverseDescentObservationsKernel
                                                                                                                                boundDescent observedBinding "up" rows (\_ -> assertFailure "invalid rows minted settlement")
                                                                                                                            mismatch rows = Left (Text.pack (teardownErrorMessage (TeardownTerminalObservationsMismatch keys (map fst rows))))
                                                                                                                        beforeVerification <- protectedImage store
                                                                                                                        TestTeardownInternal.withVerifiedBoundReverseDescentObservationsKernel boundDescent "foreign-binding" "up" exactRows
                                                                                                                            (\_ -> assertFailure "foreign binding minted settlement")
                                                                                                                            >>= (@?= Left "the observed binding differs")
                                                                                                                        TestTeardownInternal.withVerifiedBoundReverseDescentObservationsKernel boundDescent observedBinding "down" exactRows
                                                                                                                            (\_ -> assertFailure "foreign verb minted settlement")
                                                                                                                            >>= (@?= Left "the observed reverse verb differs")
                                                                                                                        verify [] >>= (@?= mismatch [])
                                                                                                                        verify (exactRows ++ [("foreign", TeardownReleased)]) >>= (@?= mismatch (exactRows ++ [("foreign", TeardownReleased)]))
                                                                                                                        if includeSecond
                                                                                                                            then do
                                                                                                                                assertBool "the child fixture has at least two rows" (length exactRows >= 2)
                                                                                                                                assertBool "the child fixture includes the nested container" (any (Text.isInfixOf "container") keys)
                                                                                                                                verify (reverse exactRows) >>= (@?= mismatch (reverse exactRows))
                                                                                                                                let withoutNested = filter (not . Text.isInfixOf "container" . fst) exactRows
                                                                                                                                verify withoutNested >>= (@?= mismatch withoutNested)
                                                                                                                            else pure ()
                                                                                                                        case exactRows of
                                                                                                                            [] -> assertFailure "the fixture has no rows to fail"
                                                                                                                            (key, _) : rest -> do
                                                                                                                                let failedRows = (key, TeardownFailed "fixture failure") : rest
                                                                                                                                verify failedRows >>= (@?= Left (Text.pack (teardownErrorMessage (TeardownNonTerminalObservations failedRows))))
                                                                                                                        protectedImage store >>= (@?= beforeVerification)
                                                                                                                        let forwardBinding = Handoff.renderHandoffBinding (Handoff.handoffOfferBinding forwardOffer)
                                                                                                                        report <- expectRight (Handoff.renderForwardRefusedLifecycleReport forwardBinding "policy")
                                                                                                                        result <- Completion.withAcknowledgedBoundReverseLifecycleCompletionKernel boundDescent report
                                                                                                                            (\_ _ -> assertFailure "a forward report was persisted")
                                                                                                                            (\_ -> assertFailure "a forward report minted reverse completion")
                                                                                                                        writeIORef captured (Just result)
                                                                                                                        origin <- expectRight (TestTeardownInternal.renderPreparedReverseTerminalOriginKernel preparedDescent observedBinding)
                                                                                                                        observations <- expectRight (renderTeardownObservations exactRows)
                                                                                                                        reverseReport <- expectRight (Handoff.renderReverseCompletedLifecycleReport origin observations)
                                                                                                                        acknowledgement <- expectRight (Handoff.renderLifecycleAcknowledgement reverseReport)
                                                                                                                        challenge <- Handoff.freshChallenge
                                                                                                                        _ <- expectRight =<< Handoff.grantHandoff broker offer challenge
                                                                                                                        let noEffect = pure (Right ()) :: IO (Either () ())
                                                                                                                        preparedAck <- Handoff.prepareLifecycleAcknowledgementKernel HandoffInternal.recoverySigningKernel broker offer challenge reverseReport acknowledgement (const noEffect) (const noEffect)
                                                                                                                        expectRight preparedAck >>= (@?= Right ())
                                                                                                                        adoptedAck <- Handoff.adoptLifecycleAcknowledgementKernel HandoffInternal.recoverySigningKernel broker offer challenge reverseReport acknowledgement noEffect noEffect
                                                                                                                        expectRight adoptedAck >>= (@?= Right ())
                                                                                                                        beforeAdoptedReplay <- protectedImage store
                                                                                                                        replayed <- newIORef False
                                                                                                                        recovered <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> writeIORef replayed True >> pure (Right ()))
                                                                                                                        case recovered of
                                                                                                                            Right (Right True) -> pure ()
                                                                                                                            _ -> assertFailure "the exact Adopted report was not rehydrated"
                                                                                                                        readIORef replayed >>= (@?= True)
                                                                                                                        protectedImage store >>= (@?= beforeAdoptedReplay)
                                                                                                                        pure (Right ()))
                                                                                                                case attached of
                                                                                                                    Left (failure, _) -> assertFailure (teardownErrorMessage failure)
                                                                                                                    Right (Left failure) -> assertFailure (Text.unpack failure)
                                                                                                                    Right (Right ()) -> pure ()
                                                                                                        case prepared of
                                                                                                            Left (failure, _) -> assertFailure (teardownErrorMessage failure)
                                                                                                            Right () -> pure ()
                                                                                                    _ <- expectRight brokered
                                                                                                    readIORef captured >>= maybe (assertFailure "the bound completion was not checked") pure
                                                                                                preparedReplayProbe = do
                                                                                                    result <- TestTeardownInternal.withPreparedReverseDescentKernel
                                                                                                        TestLifecyclePlan.acquisitionJournalAdmissionKernel rootAuthority Authority.ProjectUp plan catalog lifecycleContext journal aligned authority (pure (Right authority)) descent $ \preparedDescent -> do
                                                                                                            resumed <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "Prepared minted settlement")
                                                                                                            case resumed of
                                                                                                                Right (Right False) -> pure ()
                                                                                                                _ -> assertFailure "exact Prepared row did not resume"
                                                                                                            rows <- protectedImage store
                                                                                                            (keyText, preparedBytes) <- case filter (Text.isPrefixOf "reverse-descent." . first3) rows of
                                                                                                                [(key, _, bytes)] -> pure (key, bytes)
                                                                                                                _ -> assertFailure "expected one Prepared row"
                                                                                                            key <- expectRight (mkRecordKey keyText)
                                                                                                            changed <- withProtectedEntry store $ \session -> do
                                                                                                                found <- expectRight =<< readProtectedRecord session key
                                                                                                                record <- maybe (assertFailure "Prepared row disappeared") pure found
                                                                                                                compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) "malformed-bound"
                                                                                                            _ <- expectRight changed
                                                                                                            before <- protectedImage store
                                                                                                            refused <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "malformed row minted settlement")
                                                                                                            case refused of
                                                                                                                Left (TeardownReverseDescentRefused "the bound record is malformed", _) -> pure ()
                                                                                                                _ -> assertFailure "malformed Bound row was not refused"
                                                                                                            protectedImage store >>= (@?= before)
                                                                                                            let versionBytes = LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64BE 1))
                                                                                                                conflictingBound = ByteString.concat (map frameWire ["hostbootstrap/reverse-descent", versionBytes, "bound", "foreign-prepared", "binding"])
                                                                                                                trailingBound = ByteString.concat (map frameWire ["hostbootstrap/reverse-descent", versionBytes, "bound", preparedBytes, "binding"]) <> "trailing"
                                                                                                            conflicting <- withProtectedEntry store $ \session -> do
                                                                                                                found <- expectRight =<< readProtectedRecord session key
                                                                                                                record <- maybe (assertFailure "Bound row disappeared") pure found
                                                                                                                compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) conflictingBound
                                                                                                            _ <- expectRight conflicting
                                                                                                            conflictingImage <- protectedImage store
                                                                                                            conflict <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "conflicting row minted settlement")
                                                                                                            case conflict of
                                                                                                                Left (TeardownReverseDescentRefused "the bound record is not canonical", _) -> pure ()
                                                                                                                _ -> assertFailure "conflicting Bound row was not refused exactly"
                                                                                                            protectedImage store >>= (@?= conflictingImage)
                                                                                                            trailed <- withProtectedEntry store $ \session -> do
                                                                                                                found <- expectRight =<< readProtectedRecord session key
                                                                                                                record <- maybe (assertFailure "Bound row disappeared") pure found
                                                                                                                compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) trailingBound
                                                                                                            _ <- expectRight trailed
                                                                                                            trailingImage <- protectedImage store
                                                                                                            trailing <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "non-canonical row minted settlement")
                                                                                                            case trailing of
                                                                                                                Left (TeardownReverseDescentRefused "the bound record is not canonical", _) -> pure ()
                                                                                                                _ -> assertFailure "non-canonical Bound row was not refused exactly"
                                                                                                            protectedImage store >>= (@?= trailingImage)
                                                                                                            deleted <- withProtectedEntry store $ \session -> do
                                                                                                                found <- expectRight =<< readProtectedRecord session key
                                                                                                                record <- maybe (assertFailure "Bound row disappeared") pure found
                                                                                                                compareAndDeleteProtectedRecord session key (ExpectVersion (protectedRecordVersion record))
                                                                                                            _ <- expectRight deleted
                                                                                                            absent <- protectedImage store
                                                                                                            missing <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "missing row minted settlement")
                                                                                                            case missing of
                                                                                                                Left (TeardownReverseDescentRefused _, _) -> pure ()
                                                                                                                _ -> assertFailure "missing row was not refused"
                                                                                                            protectedImage store >>= (@?= absent)
                                                                                                            recreated <- withProtectedEntry store $ \session ->
                                                                                                                compareAndSwapProtectedRecord session key ExpectAbsent "foreign-prepared"
                                                                                                            _ <- expectRight recreated
                                                                                                            foreignImage <- protectedImage store
                                                                                                            foreignPrepared <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "foreign Prepared row minted settlement")
                                                                                                            case foreignPrepared of
                                                                                                                Left (TeardownReverseDescentRefused _, _) -> pure ()
                                                                                                                _ -> assertFailure "foreign version-one row resumed"
                                                                                                            protectedImage store >>= (@?= foreignImage)
                                                                                                            let recordPath = protectedStoreRoot store </> "records" </> Text.unpack keyText <> ".rec"
                                                                                                            originalEnvelope <- ByteString.readFile recordPath
                                                                                                            ByteString.writeFile recordPath "malformed protected envelope"
                                                                                                            readFailure <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "unreadable row minted settlement")
                                                                                                            case readFailure of
                                                                                                                Left (TeardownReverseDescentRefused "the exact bound record is absent", _) -> pure ()
                                                                                                                _ -> assertFailure "unreadable Bound row did not remain a refusal"
                                                                                                            ByteString.readFile recordPath >>= (@?= "malformed protected envelope")
                                                                                                            ByteString.writeFile recordPath originalEnvelope
                                                                                                            advanced <- Session.withTeardownLifecycleCursor cursor (\_ -> pure ())
                                                                                                            _ <- expectRight advanced
                                                                                                            staleImage <- protectedImage store
                                                                                                            stale <- TestTeardownInternal.withRehydratedSettledReverseDescentKernel preparedDescent (\_ -> assertFailure "stale cursor minted settlement")
                                                                                                            case stale of
                                                                                                                Left (TeardownReverseDescentRefused "the lifecycle cursor is stale", _) -> pure ()
                                                                                                                _ -> assertFailure "stale lifecycle cursor was not refused exactly"
                                                                                                            protectedImage store >>= (@?= staleImage)
                                                                                                            -- The adopted rebind checks the cursor in its own entry: with a rotated adopted
                                                                                                            -- binding and the advanced cursor it refuses exactly and writes nothing.
                                                                                                            currentRow <- withProtectedEntry store (\session -> readProtectedRecord session key)
                                                                                                            currentRecord <- either (assertFailure . show) (maybe (assertFailure "the row disappeared") pure) currentRow
                                                                                                            rebound <- TestTeardownInternal.rebindAdoptedReverseDescentKernel preparedDescent "binding" (protectedRecordVersion currentRecord) (protectedRecordBytes currentRecord) "rotated-binding"
                                                                                                            case rebound of
                                                                                                                Left failure -> failure @?= "the lifecycle cursor is stale"
                                                                                                                Right _ -> assertFailure "a stale cursor rebound the adopted descent"
                                                                                                            protectedImage store >>= (@?= staleImage)
                                                                                                            -- The classifiers decide by type: exact Prepared bytes, a canonical Bound row,
                                                                                                            -- and every other row, absence or read failure.
                                                                                                            let canonicalBound = ByteString.concat (map frameWire ["hostbootstrap/reverse-descent", versionBytes, "bound", preparedBytes, "binding"])
                                                                                                            TestTeardownInternal.parseBoundRecord preparedBytes canonicalBound @?= Right "binding"
                                                                                                            case TestTeardownInternal.parseBoundRecord preparedBytes conflictingBound of
                                                                                                                Left (TeardownReverseDescentRefused "the bound record is not canonical") -> pure ()
                                                                                                                other -> assertFailure ("a conflicting Bound row parsed: " <> show (fmap (const ()) other))
                                                                                                            case TestTeardownInternal.parseBoundRecord preparedBytes trailingBound of
                                                                                                                Left _ -> pure ()
                                                                                                                Right _ -> assertFailure "a trailing Bound row parsed"
                                                                                                            rewritten <- withProtectedEntry store $ \session -> compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion currentRecord)) canonicalBound
                                                                                                            _ <- expectRight rewritten
                                                                                                            boundObserved <- withProtectedEntry store (\session -> Right <$> readProtectedRecord session key)
                                                                                                            boundRead <- expectRight boundObserved
                                                                                                            case TestTeardownInternal.classifyRehydratedBoundRecordKernel preparedBytes boundRead of
                                                                                                                Right (Just (boundBinding, boundVersion, boundBytes)) -> (boundBinding, recordVersionWord boundVersion > 1, boundBytes) @?= ("binding", True, canonicalBound)
                                                                                                                _ -> assertFailure "a canonical Bound row was not classified as Bound"
                                                                                                            case TestTeardownInternal.classifyRehydratedBoundRecordKernel preparedBytes (Right Nothing) of
                                                                                                                Left (TeardownReverseDescentRefused "the exact bound record is absent") -> pure ()
                                                                                                                _ -> assertFailure "an absent row was not a refusal"
                                                                                                            case TestTeardownInternal.classifyRehydratedBoundRecordKernel preparedBytes (Left (ProtectedInvalid "unreadable")) of
                                                                                                                Left (TeardownReverseDescentRefused "the exact bound record is absent") -> pure ()
                                                                                                                _ -> assertFailure "a read failure was not a refusal"
                                                                                                            -- Preparation accepts its exact Prepared bytes or a canonical Bound row of the same preparation.
                                                                                                            boundRecord <- either (assertFailure . show) (maybe (assertFailure "the Bound row disappeared") pure) boundRead
                                                                                                            TestTeardownInternal.classifyPrepared preparedBytes boundRecord @?= Right (protectedRecordVersion boundRecord)
                                                                                                    case result of
                                                                                                        Left (failure, _) -> assertFailure (teardownErrorMessage failure)
                                                                                                        Right () -> pure ()
                                                                                            use store project rootAuthority authority aligned catalog prepare boundForwardProbe preparedReplayProbe)))
                                                                        seek forest
                                                                        pure (Right ())
                                                                    expectRight cataloged
                                                                expectRight executed
                                                            expectRight cursored
                                                        expectRight journaled
                                                    frameAction
                                                expectRight contextual
                                            expectRight persisted
                                        planAction
                                    expectRight validated)
                    result <- profiled
                    pure (Right result)
                expectRight opened
            expectRight rooted

preparedKernelTests :: [TestTree]
preparedKernelTests =
    [ testCase "the actual bound reverse verifier refuses foreign coordinates, invalid observations, and a forward report" $
        withPreparedKernelFixture $ \_store _project _root _authority _cursor _catalog _prepare probe _ ->
            probe >>= (@?= Left "lifecycle completion: a reverse descent refuses a forward report")
    , testCase "the actual bound reverse verifier refuses reordered and incomplete nested child observations" $
        withPreparedKernelFixtureWith True $ \_ _ _ _ _ _ _ probe _ ->
            probe >>= (@?= Left "lifecycle completion: a reverse descent refuses a forward report")
    , testCase "rehydration resumes exact Prepared and refuses malformed, missing, foreign, or stale state without writing" $
        withPreparedKernelFixture $ \_ _ _ _ _ _ _ _ probe -> probe
    , testCase "the preparation callback observes the exact persisted version after readback" $
        withPreparedKernelFixture $ \store _project _root authority cursor _catalog prepare _ _ -> do
            before <- protectedImage store
            filter (Text.isPrefixOf "reverse-descent." . firstOf3) before @?= []
            during <- newIORef Nothing
            prepare authority cursor (protectedImage store >>= writeIORef during . Just) >>= (@?= Right ())
            observed <- readIORef during >>= maybe (assertFailure "the preparation callback did not run") pure
            after <- protectedImage store
            observed @?= after
            case filter (Text.isPrefixOf "reverse-descent." . firstOf3) observed of
                [(_, version, bytes)] -> do
                    version @?= 1
                    assertBool "the prepared row has canonical bytes" (not (ByteString.null bytes))
                rows -> assertFailure ("expected one prepared row at the callback, got " <> show (length rows))
    , testCase "a conflicting prepared row refuses through the kernel without changing its image" $
        withPreparedKernelFixture $ \store _project _root authority cursor _catalog prepare _ _ -> do
            prepare authority cursor (pure ()) >>= (@?= Right ())
            first <- protectedImage store
            (keyText, _, _) <- case filter (Text.isPrefixOf "reverse-descent." . firstOf3) first of
                [row] -> pure row
                rows -> assertFailure ("expected one prepared row, got " <> show (length rows))
            key <- expectRight (mkRecordKey keyText)
            replaced <- withProtectedEntry store $ \session -> do
                found <- expectRight =<< readProtectedRecord session key
                record <- maybe (assertFailure "prepared row disappeared") pure found
                compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) "foreign-prepared"
            _ <- expectRight replaced
            before <- protectedImage store
            prepare authority cursor (pure ()) >>= (@?= Left "a conflicting prepared record exists")
            protectedImage store >>= (@?= before)
    , testCase "foreign command authority refuses through the kernel before writing the target store" $
        withPreparedKernelFixture $ \_storeA _projectA _rootA authorityA cursorA _ _ _ _ ->
            withPreparedKernelFixture $ \storeB _projectB _rootB _authorityB _cursorB _catalog prepareB _ _ -> do
                before <- protectedImage storeB
                prepareB (unsafeCoerce authorityA) (unsafeCoerce cursorA) (pure ())
                    >>= (@?= Left "the command belongs to a different store")
                protectedImage storeB >>= (@?= before)
    ]
  where
    firstOf3 (key, _, _) = key

first3 :: (a, b, c) -> a
first3 (value, _, _) = value

protectedImage :: ProtectedStore -> IO [(Text, Word64, ByteString.ByteString)]
protectedImage store = expectRight =<< withProtectedEntry store (\session -> do
    keys <- expectRight =<< listProtectedRecords session
    rows <- mapM (\key -> do
        observed <- expectRight =<< readProtectedRecord session key
        record <- maybe (assertFailure "protected record disappeared") pure observed
        pure (recordKeyText key, recordVersionWord (protectedRecordVersion record), protectedRecordBytes record)) keys
    pure (Right rows))

preparationTests :: [TestTree]
preparationTests =
    [ testCase "accepts the coherent facts from a reverse descent" $
        validatePreparation validPreparation @?= Right ()
    , testCase "refuses equal frames, empty and duplicate observations, and a foreign store" $ do
        let cases =
                [ (validPreparation {preparationParent = "child"}, "the parent and child frames are equal")
                , (validPreparation {preparationObservations = []}, "the child observation order is empty")
                , (validPreparation {preparationObservations = ["one", "one"]}, "the child observation order contains duplicates")
                , (validPreparation {preparationCommandMatchesStore = False}, "the command belongs to a different store")
                ]
        forM_ cases $ \(facts, detail) -> validatePreparation facts @?= Left detail
    , testCase "recovery offer scopes admit only the canonical production or harness spelling" $ do
        let validate = validateRecoveryOfferScope productionScopeTag harnessScopeTagFor
        validate "production" productionScopeTag @?= Right ()
        validate "harness:run" (harnessScopeTagFor "run") @?= Right ()
        validate "unrecognised" "unrecognised" @?= Left "the recovery offer scope differs"
        validate "unrecognised" productionScopeTag @?= Left "the recovery offer scope differs"
        validate "harness:run" productionScopeTag @?= Left "the recovery offer scope differs"
    , testCase "prepared journals retain a scope generated by the closed lifecycle mode" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            modePath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Lifecycle.Mode"
            preparationPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Teardown.Preparation"
            modeSource <- readFile modePath
            preparationSource <- readFile preparationPath
            let contains fragment source = SourceGuard.haskellTokens fragment `isInfixOf` SourceGuard.haskellTokens source
            assertBool "mode wire has only production and harness constructors"
                (contains "data ModeWire = WireProduction | WireHarness RunKey" modeSource)
            assertBool "mode wire has only the canonical scope spellings"
                (contains "modeWireName WireProduction = \"production\" modeWireName (WireHarness run) = \"harness:\" <> runKeyText run" modeSource)
            assertBool "acquisition scope derives from the bound lease mode"
                (contains "acquisitionBindingStableScope = modeWireName (runIdentityMode (boundRunLeaseIdentity bound))" modeSource)
            assertBool "preparation requires plan and journal scope equality"
                (contains "preparationPlanScope f == preparationJournalScope f" preparationSource)
            assertBool "journal admission checks the plan against the same mode-derived scope"
                (contains "requireText \"plan stable scope\" expectedProfileName profileName" modeSource)
            sources <- SourceGuard.readLibrarySources packageRoot description
            let callers = sort [name | (name, _, source) <- sources, SourceGuard.countHaskellIdentifier "openAcquisitionJournalKernel" source > 0]
            callers @?= ["HostBootstrap.Lifecycle.Mode", "HostBootstrap.Lifecycle.Session"]
    , testCase "prepared record classification admits only exact prepared or decoded bound rows" $ do
        classifyPreparedRecord "expected" 1 "expected" Nothing @?= Right ()
        classifyPreparedRecord "expected" 1 "foreign" Nothing @?= Left "a conflicting prepared record exists"
        classifyPreparedRecord "expected" 2 "bound" (Just "binding") @?= Right ()
        classifyPreparedRecord "expected" 2 "malformed" Nothing @?= Left "a conflicting prepared record exists"
        classifyPreparedRecord "expected" 0 "expected" Nothing @?= Left "a conflicting prepared record exists"
    , testCase "refuses an oversized adapter and prepared record" $ do
        validatePreparation (validPreparation {preparationAdapter = "12345"}) @?= Left "the recovery adapter exceeds the handoff bound"
        validatePreparation (validPreparation {preparationRecord = "12345"}) @?= Left "the prepared record exceeds the handoff bound"
    ]

validPreparation :: PreparationFacts
validPreparation =
    PreparationFacts
        { preparationVerb = "down"
        , preparationRootVerb = "down"
        , preparationJournalVerb = "down"
        , preparationCursorVerb = "down"
        , preparationCommandVerb = "down"
        , preparationCursorPhase = "teardown"
        , preparationCommandPhase = "teardown"
        , preparationProject = "project"
        , preparationRootProject = "project"
        , preparationStore = "store"
        , preparationRootStore = "store"
        , preparationPlanStore = "store"
        , preparationPlanScope = "scope"
        , preparationJournalScope = "scope"
        , preparationPlanDigest = "plan"
        , preparationJournalDigest = "plan"
        , preparationCanonicalPlan = "plan"
        , preparationRootEpoch = 1
        , preparationJournalEpoch = 1
        , preparationPlanEpoch = 1
        , preparationCommandEpoch = 1
        , preparationCurrentFrame = "parent"
        , preparationProjectFrame = "parent"
        , preparationCursorFrame = "parent"
        , preparationCommandFrame = "parent"
        , preparationChildProjectionFrame = "child"
        , preparationChildProjectionVerb = "down"
        , preparationParent = "parent"
        , preparationChild = "child"
        , preparationTopologyFrames = ["parent", "child"]
        , preparationTopologyEdges = [("parent", "child")]
        , preparationCursorMatchesCommand = True
        , preparationCommandMatchesStore = True
        , preparationRun = "run"
        , preparationInvocation = "invocation"
        , preparationAcquisitionVersion = 1
        , preparationCursorVersion = 1
        , preparationObservations = ["one"]
        , preparationAdapter = "a"
        , preparationChildConfig = "c"
        , preparationConfigDigest = "config"
        , preparationActualConfigDigest = "config"
        , preparationPackage = "p"
        , preparationRenderedPackage = "p"
        , preparationPackageDigest = "package"
        , preparationRecord = "r"
        , preparationWireBound = 4
        }

observationCodecTests :: [TestTree]
observationCodecTests =
    [ testCase "all four teardown outcomes round-trip in exact order on the shared wire" $ do
        let observations =
                [ ("release", TeardownReleased)
                , ("foreign", TeardownForeignRetained "owned elsewhere")
                , ("refusal", TeardownRefused "policy")
                , ("failure", TeardownFailed "provider")
                ]
            structuralRows =
                [ ("release", "released", "none")
                , ("foreign", "foreign-retained", "owned elsewhere")
                , ("refusal", "refused", "policy")
                , ("failure", "failed", "provider")
                ]
        wire <- expectTeardownRight (renderTeardownObservations observations)
        structural <- expectHandoffRight (renderLifecycleObservations structuralRows)
        wire @?= structural
        teardownObservationsFromWire wire @?= Right observations
    , testCase "typed rendering preserves lower key and detail refusals" $ do
        let malformed =
                [ ("empty key", [("", TeardownReleased)])
                , ("duplicate key", [("same", TeardownReleased), ("same", TeardownReleased)])
                , ("empty foreign detail", [("one", TeardownForeignRetained "")])
                , ("none foreign detail", [("one", TeardownForeignRetained "none")])
                , ("empty refusal detail", [("one", TeardownRefused "")])
                , ("none refusal detail", [("one", TeardownRefused "none")])
                , ("empty failure detail", [("one", TeardownFailed "")])
                , ("none failure detail", [("one", TeardownFailed "none")])
                ]
        forM_ malformed $ \(label, observations) ->
            case renderTeardownObservations observations of
                Left (TeardownObservationWireRefused _) -> pure ()
                other -> assertFailure (label <> " was not refused: " <> show other)
    , testCase "typed decoding refuses malformed, truncated, and trailing structural wires" $ do
        wire <- expectTeardownRight (renderTeardownObservations [("one", TeardownReleased)])
        let malformed =
                [ ("truncated", ByteString.init wire)
                , ("trailing", wire <> frameWire "extra")
                , ("malformed UTF-8", malformedTeardownObservationWire)
                ]
        forM_ malformed $ \(label, candidate) ->
            case teardownObservationsFromWire candidate of
                Left (TeardownObservationWireRefused _) -> pure ()
                other -> assertFailure (label <> " wire was not refused: " <> show other)
    , testCase "typed decoding refuses a well-framed row whose status is not a teardown status" $ do
        -- "succeeded" is a structural status of the completion wire, never a teardown one.
        wire <- expectHandoffRight (renderLifecycleObservations [("one", "succeeded", "none")])
        case teardownObservationsFromWire wire of
            Left (TeardownObservationWireRefused _) -> pure ()
            other -> assertFailure ("an unknown teardown status was not refused: " <> show other)
    ]

expectTeardownRight :: (Show error) => Either error value -> IO value
expectTeardownRight (Right value) = pure value
expectTeardownRight (Left failure) = assertFailure ("expected teardown codec success: " <> show failure)

expectHandoffRight :: (Show error) => Either error value -> IO value
expectHandoffRight (Right value) = pure value
expectHandoffRight (Left failure) = assertFailure ("expected structural codec success: " <> show failure)

malformedTeardownObservationWire :: ByteString.ByteString
malformedTeardownObservationWire =
    ByteString.concat
        [ frameWire "hostbootstrap/lifecycle-observations"
        , frameWire (ByteString.replicate 7 0 <> ByteString.singleton 1)
        , frameWire (ByteString.replicate 7 0 <> ByteString.singleton 1)
        , frameWire (ByteString.pack [0xff])
        , frameWire "released"
        , frameWire "none"
        ]

{- | Pin the exact frame lineage from the projection through every recursive
forest package. Keeping this as a source-shape check makes a dropped frame
index, a representationally coercible phantom, or a restored second opener
argument fail mechanically.
-}
sourceShapeTests :: [TestTree]
sourceShapeTests =
    [ testCase "the complete forest pipeline retains the projection frame" $ do
        cwd <- getCurrentDirectory
        root <-
            findRepoRoot cwd
                >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let packageRoot = root </> "core" </> "hostbootstrap-core"
        description <- SourceGuard.readPackageDescription
        sourcePath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Teardown"
        commandPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Command"
        entryPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Command.LifecycleEntry"
        childPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Command.Child.Reverse"
        internalPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Teardown.Internal"
        source <- TextIO.readFile sourcePath
        commandSource <- TextIO.readFile commandPath
        entrySource <- TextIO.readFile entryPath
        childSource <- TextIO.readFile childPath
        internalSource <- TextIO.readFile internalPath
        commandModules <- SourceGuard.readHaskellSources (packageRoot </> "src" </> "HostBootstrap" </> "Command")
        assertBool "the command module tree is not empty" (not (null commandModules))
        exports <- maybe (assertFailure "Teardown must have an explicit export list") pure $
            SourceGuard.moduleExportTokens "HostBootstrap.Teardown" (Text.unpack source)
        let has fragment body = SourceGuard.haskellTokens (Text.unpack fragment) `isInfixOf` SourceGuard.haskellTokens (Text.unpack body)
            commandSources = (commandPath, Text.unpack commandSource) : commandModules
        assertBool "commented code cannot satisfy a source guard" (not (has "teardownPlan plan current verb" "-- teardownPlan plan current verb"))
        assertBool "a quoted literal cannot satisfy a source guard" (not (has "teardownPlan plan current verb" "\"teardownPlan plan current verb\""))
        collector <-
            either assertFailure pure $
                SourceGuard.haskellDefinitionTokens
                    "withReverseDescentLiftContextKernel"
                    (Text.unpack internalSource)
        let collectorContains label fragment =
                assertBool label (SourceGuard.haskellTokens fragment `isInfixOf` collector)
        -- rationale.md: Reverse routes are reconstructed from retained plan edges.
        -- Catalog admission owns the opaque input; this pins the real collector's
        -- checked adoption without adding a producer for malformed authority.
        collectorContains
            "the collector checks the complete collected route"
            "rootedRouteTo derived target = do layers <- collect target [] case liftContextFromLayers layers of"
        collectorContains
            "the collector returns the checked context"
            "Right context -> Right context"
        collectorContains
            "the collector preserves the checked refusal as a route diagnostic"
            "Left failure -> Left (\"the retained topology route is invalid: \" <> Text.pack failure)"
        collectorContains
            "the collector reads the retained edge's ordinary layer view"
            "liftLayers context | (edgeParent, edgeChild, context) <- topologyDescentEdges derived"
        collectorContains
            "the prepared boundary passes only the collected context to its continuation"
            "Right context -> context `seq` use context"
        mapM_
            ( \forbidden ->
                assertBool
                    ("the collector retains raw construction or a local fallback: " <> forbidden)
                    (forbidden `notElem` collector)
            )
            ["LiftContext", "localContext", "error", "undefined", "fromJust"]
        let normalized = source
            declaration name expected =
                assertBool ("missing or duplicated teardown declaration: " ++ Text.unpack name) $
                    SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens (Text.unpack expected)) (Text.unpack source) == 1
            exactSignatures =
                [ "teardownPlan :: ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId frame -> ProjectVerb verb -> TeardownPlan scope planId frame verb"
                , "openTeardownForest :: TeardownPlan scope planId frame verb -> Either TeardownError (TeardownForest scope planId frame verb)"
                , "nextTeardownWork :: TeardownForest scope planId frame verb -> TeardownProgress scope planId frame verb"
                , "eliminateTeardownWork :: TeardownWork scope planId frame verb -> (LocalWork scope planId frame verb -> result) -> (forall (childFrame :: Type). DescentWork scope planId frame childFrame verb -> result) -> result"
                , "attemptLocalWork :: LocalWork scope planId frame verb -> TeardownOutcome -> TeardownForest scope planId frame verb"
                , "withDescentWorkSubtree :: DescentWork scope planId frame childFrame verb -> (TeardownPlan scope planId childFrame verb -> result) -> result"
                , "settleDescentWork :: DescentWork scope planId frame childFrame verb -> SubtreeSettled scope planId childFrame verb -> Either TeardownError (TeardownForest scope planId frame verb)"
                , "driveTeardownForest :: TeardownForest scope planId frame verb -> (PreDescentStep scope planId frame verb -> IO TeardownOutcome) -> (SettledChildren scope planId frame -> LocalWork scope planId frame verb -> IO TeardownOutcome) -> ( forall (childFrame :: Type). SettledChildren scope planId frame -> DescentWork scope planId frame childFrame verb -> IO (Either Text (SubtreeSettled scope planId childFrame verb)) ) -> (Text -> TeardownOutcome -> IO ()) -> IO (Either [Text] (CompletedTeardownForest scope planId frame verb))"
                , "verifySubtreeSettled :: TeardownPlan scope planId frame verb -> CompletedTeardownForest scope planId frame verb -> Either TeardownError (SubtreeSettled scope planId frame verb)"
                , "verifyDestroySettled :: ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId frame -> SubtreeSettled scope planId frame VerbDestroy -> Either TeardownError (DestroySettled scope planId)"
                ]
            exactRoles =
                [ "type role TeardownPlan nominal nominal nominal nominal"
                , "type role TeardownForest nominal nominal nominal nominal"
                , "type role TeardownProgress nominal nominal nominal nominal"
                , "type role CompletedTeardownForest nominal nominal nominal nominal"
                , "type role TeardownAuthorizationPoint nominal nominal nominal nominal"
                , "type role PreDescentStep nominal nominal nominal nominal"
                , "type role SettledChildren nominal nominal nominal"
                , "type role SubtreeSettled nominal nominal nominal nominal"
                , "type role DestroySettled nominal nominal"
                ]
        declaration
            "TeardownPlan"
            "data TeardownPlan scope planId frame verb"
        declaration
            "TeardownForest"
            "data TeardownForest scope planId frame verb"
        declaration
            "TeardownProgress"
            "data TeardownProgress scope planId frame verb"
        declaration
            "CompletedTeardownForest"
            "data CompletedTeardownForest scope planId frame verb"
        declaration
            "TeardownAuthorizationPoint"
            "data TeardownAuthorizationPoint scope planId frame verb"
        declaration
            "PreDescentStep"
            "newtype PreDescentStep scope planId frame verb"
        declaration
            "SettledChildren"
            "newtype SettledChildren scope planId frame = SettledChildren [Text]"
        declaration
            "TeardownWork"
            "data TeardownWork scope planId frame verb where"
        declaration
            "LocalWork"
            "data LocalWork scope planId frame verb"
        declaration
            "DescentWork"
            "data DescentWork scope planId frame (childFrame :: Type) verb"
        declaration
            "SubtreeSettled"
            "data SubtreeSettled scope planId frame verb"
        declaration
            "DestroySettled"
            "data DestroySettled scope planId"
        mapM_
            ( \signature ->
                assertBool
                    ("missing exact teardown signature: " ++ Text.unpack signature)
                    (signature `has` normalized)
            )
            exactSignatures
        mapM_
            ( \role ->
                assertBool
                    ("missing exact teardown role declaration: " ++ Text.unpack role)
                    (role `has` normalized)
            )
            exactRoles
        assertBool
            "the former TeardownCursor type must not remain public"
            ("TeardownCursor" `notElem` exports)
        mapM_
            ( \formerProjection ->
                assertBool
                    ("former public cursor projection remains: " ++ Text.unpack formerProjection)
                    (not (formerProjection `has` source))
            )
            [ "teardownCursorAction"
            , "teardownCursorKey"
            , "teardownCursorFrame"
            , "teardownCursorPolicy"
            , "teardownCursorRun"
            , "attemptTeardownStep"
            , "teardownPlanStepKeys"
            , "teardownPlanStepIdentities"
            , "teardownPlanOperationKeys"
            , "teardownPlanActions"
            , "runTeardownProjection"
            , "attemptDescentWork"
            ]
        mapM_
            ( \required ->
                assertBool
                    ("lifecycle entry is missing the closed teardown-work boundary: " ++ Text.unpack required)
                    (required `has` entrySource)
            )
            [ "teardownPlan plan current verb"
            , "driveTeardownForest"
            , "descentWorkChildFrame"
            ]
        forM_ commandSources $ \(path, body) -> do
            let commandModule = Text.pack body
            assertBool (path <> " retains the former public cursor route")
                (not ("TeardownCursor" `has` commandModule))
            if path == entryPath
                then pure ()
                else assertBool (path <> " receives an unclassified teardown authorization point")
                    (not ("withTeardownAuthorization" `has` commandModule))
            assertBool (path <> " retains parallel command and teardown verb parameters")
                (not ("commandVerb" `has` commandModule) && not ("teardownVerb" `has` commandModule))
            assertBool (path <> " accepts an external cluster teardown callback")
                (not ("(ClusterPlan -> IO TeardownOutcome)" `has` commandModule))
        assertBool
            "the driver must not expose the former generic authorization-point handler"
            ( not
                ( "(TeardownAuthorizationPoint scope planId frame verb -> IO TeardownOutcome)"
                    `has` normalized
                )
            )
        assertBool
            "Teardown must consume only the public project-plan facade"
            (not ("import HostBootstrap.Lifecycle.Plan" `has` source))
        assertBool
            "Teardown must not retain the deleted LifecyclePlan compatibility projection"
            (not ("withCompatibilityTeardownPlan" `has` source))
        mapM_
            ( \legacyVerb ->
                assertBool
                    ("legacy teardown verb remains: " ++ Text.unpack legacyVerb)
                    (not (legacyVerb `has` source))
            )
            [ "DownVerb"
            , "DestroyVerb"
            , "TeardownVerb"
            , "downVerb"
            , "destroyVerb"
            , "teardownVerbName"
            ]
        mapM_
            ( \required ->
                assertBool
                    ("missing canonical ProjectVerb behavior: " ++ Text.unpack required)
                    (required `has` normalized)
            )
            [ "= TeardownPlan (ProjectVerb verb) Bool Text Text [Text] [[ReverseStep]]"
            , "= TeardownForest (TeardownPlan scope planId frame verb) [Node]"
            , "= CompletedTeardownForest (ProjectVerb verb) Text Text [(OperationKey, TeardownOutcome)]"
            , "actionFor ProjectUp _ = Nothing"
            , "actionFor ProjectDown (CoreStepIdentity DeployVMId) = Just StopFrame"
            , "actionFor ProjectDestroy (CoreStepIdentity DeployVMId) = Just DeleteFrame"
            , "openTeardownForest projection@(TeardownPlan verb failedUp _ _ _ levels) | ProjectUp <- verb, not failedUp = Left TeardownProjectUpHasNoReverse"
            , "ProjectUp -> Nothing ProjectDown -> Nothing ProjectDestroy -> Just (verifyDestroySettled plan current settled)"
            ]
        assertBool
            "the exact Harness destroy route must use retained cluster ownership internally"
            ( "releaseRetainedClusterLifecycle cfg (planForRootWithProfile profile root ctx)"
                `has` commandSource
            )
        assertBool
            "the exact Harness destroy route must derive that profile from its admitted plan"
            ( "profileFromPlanName (ProjectPlan.projectPlanProfileName destroyPlan)"
                `has` commandSource
            )
        assertBool
            "the recursive child adapter passes its admitted plan to cluster cleanup"
            ( "releaseRetainedClusterFenced host plan gate"
                `has` childSource
            )
        assertBool
            "Harness recovery offers compare the canonical signed scope, not the lifecycle journal spelling"
            ( "validateRecoveryOfferScope productionScopeTag harnessScopeTagFor" `has` internalSource
                && "(acquisitionJournalStableScope journal) (handoffScope binding)" `has` internalSource
            )
    ]

{- | The loop a lifecycle verb runs (the recursive-lifecycle-command phase).

The verb supplies only one node's effect and one node's row; the ordering, the
retry policy, and the outstanding report are the forest's. These are the
properties the live verb depends on, taken here without a provider.
-}
driverTests :: [TestTree]
driverTests =
    [ testCase "the driver visits every node child-first and completes" $
        withPlan $ \plan current -> do
            visited <- newIORef []
            rows <- newIORef []
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            let expectedKeys = teardownForestOutstanding forest
            driven <-
                driveWithOffered
                    forest
                    ( \work -> do
                        modifyIORef' visited (++ [work])
                        pure TeardownReleased
                    )
                    (\key outcome -> modifyIORef' rows (++ [(key, outcome)]))
            case driven of
                Left outstanding -> assertFailure ("did not complete: " ++ show outstanding)
                Right completed ->
                    assertBool
                        "every projected identity settled"
                        ( all
                            (`elem` terminalKeyTexts (completedForestTerminalObservations completed))
                            expectedKeys
                        )
            -- the provider's pre-descent step first, then the deepest frame,
            -- then outwards; every node reports exactly one row
            readIORef visited
                >>= ( @?=
                        [ OfferedPreDescent "core:deploy-vm" "host-orchestrator-0"
                        , OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                        , OfferedDescent "vm-orchestrator-1" "vm-project-container-2"
                        , OfferedLocal "core:deploy-chart" ReleaseResource
                        , OfferedLocal "core:deploy-kind" DeleteCluster
                        , OfferedLocal "core:build-pb" ReleaseResource
                        , OfferedLocal "core:deploy-vm" DeleteFrame
                        ]
                    )
            observedRows <- readIORef rows
            map fst observedRows
                @?= [ "core:deploy-vm"
                    , "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
            assertBool "every row is released" (all ((== TeardownReleased) . snd) observedRows)
    , testCase "a failed node stops the run and names every node left outstanding" $
        withPlan $ \plan current -> do
            attempts <- newIORef (0 :: Int)
            failedFirstDescent <- newIORef False
            rows <- newIORef []
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            driven <-
                driveWithOffered
                    forest
                    ( \work -> do
                        modifyIORef' attempts (+ 1)
                        case work of
                            OfferedDescent _ _ -> do
                                alreadyFailed <- readIORef failedFirstDescent
                                if alreadyFailed
                                    then pure TeardownReleased
                                    else do
                                        writeIORef failedFirstDescent True
                                        pure (TeardownFailed "boom")
                            _ -> pure TeardownReleased
                    )
                    (\key outcome -> modifyIORef' rows (<> [(key, outcome)]))
            case driven of
                Right _ -> assertFailure "a forest with a failing node must not complete"
                Left outstanding -> outstanding @?= ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]
            observedRows <- readIORef rows
            lookup "core:deploy-chart" observedRows @?= Just (TeardownFailed "boom")
            -- The pre-descent step and one failed child-subtree attempt. The
            -- exact child continuation fails as a unit, so no sibling can
            -- bypass it and no raw-success retry spins in this run.
            readIORef attempts >>= (@?= 2)
    , testCase "foreign and refused child observations remain distinct and do not block completion" $
        withPlan $ \plan current -> do
            retainedChart <- newIORef False
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            driven <-
                driveWithOffered
                    forest
                    ( \work -> case work of
                        OfferedLocal "core:deploy-chart" _ -> do
                            alreadyRetained <- readIORef retainedChart
                            if alreadyRetained
                                then pure (TeardownRefused "policy retained the chart")
                                else do
                                    writeIORef retainedChart True
                                    pure (TeardownForeignRetained "not this run's release")
                        OfferedLocal "core:deploy-kind" _ ->
                            pure (TeardownRefused "policy retained the cluster")
                        _ -> pure TeardownReleased
                    )
                    (\_ _ -> pure ())
            case driven of
                Left outstanding -> assertFailure ("did not complete: " ++ show outstanding)
                Right completed -> do
                    subtree <-
                        either
                            (assertFailure . teardownErrorMessage)
                            pure
                            (verifySubtreeSettled (teardownPlan plan current ProjectDestroy) completed)
                    map snd (subtreeSettledTerminalObservations subtree)
                        @?= [ TeardownForeignRetained "not this run's release"
                            , TeardownRefused "policy retained the cluster"
                            , TeardownReleased
                            , TeardownReleased
                            ]
    , testCase "only a destroy run can mint settled-destroy evidence" $
        withPlan $ \plan current -> do
            let destroyProjection = teardownPlan plan current ProjectDestroy
                downProjection = teardownPlan plan current ProjectDown
            destroyForest <- openOrFail destroyProjection
            downForest <- openOrFail downProjection
            destroyDone <- driveWithOffered destroyForest (const (pure TeardownReleased)) (\_ _ -> pure ())
            downDone <- driveWithOffered downForest (const (pure TeardownReleased)) (\_ _ -> pure ())
            case (destroyDone, downDone) of
                (Right destroyed, Right downed) -> do
                    downSubtree <-
                        either
                            (assertFailure . teardownErrorMessage)
                            pure
                            (verifySubtreeSettled downProjection downed)
                    destroySubtree <-
                        either
                            (assertFailure . teardownErrorMessage)
                            pure
                            (verifySubtreeSettled destroyProjection destroyed)
                    case settledDestroyEvidence plan current downSubtree of
                        Nothing -> pure ()
                        Just _ -> assertFailure "a down run minted settled-destroy evidence"
                    case settledDestroyEvidence plan current destroySubtree of
                        Just (Right settled) ->
                            destroySettledPlanDigest settled @?= planDigestOf plan
                        other ->
                            assertFailure
                                ("expected settled-destroy evidence, got " ++ describeEvidence other)
                _ -> assertFailure "both forests must complete"
    ]

describeEvidence :: Maybe (Either TeardownError a) -> String
describeEvidence Nothing = "no evidence (a down projection)"
describeEvidence (Just (Left err)) = teardownErrorMessage err
describeEvidence (Just (Right _)) = "settled"

-- ---------------------------------------------------------------------------
-- Projection

projectionTests :: [TestTree]
projectionTests =
    [ testCase "the projection retains the exact canonical project verb" $
        withPlan $ \plan current -> do
            teardownPlanVerbName (teardownPlan plan current ProjectUp)
                @?= projectVerbName ProjectUp
            teardownPlanVerbName (teardownPlan plan current ProjectDown)
                @?= projectVerbName ProjectDown
            teardownPlanVerbName (teardownPlan plan current ProjectDestroy)
                @?= projectVerbName ProjectDestroy
    , testCase "the forest report uses only the plan's exact operation keys" $
        withPlan $ \plan current -> do
            let forwardReverseNodes =
                    reverse
                        [ node
                        | node <- NonEmpty.toList (forward plan)
                        , plannedStepReversePolicy node /= PreserveOnReverse
                        ]
                expectedKeys =
                    map
                        (Text.pack . ProjectPlan.operationKeyText . plannedStepOperationKey)
                        forwardReverseNodes
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            teardownForestOutstanding downForest @?= expectedKeys
            teardownForestOutstanding destroyForest @?= expectedKeys
    , testCase "root, VM, and container projections open exact frame-bound suffixes" $ do
        assertPlanSuffix
            id
            "host-orchestrator-0"
            ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]
        assertPlanSuffix
            (\root -> Context.deriveVMContext root "/fixture/vm")
            "vm-orchestrator-1"
            ["core:deploy-chart", "core:deploy-kind", "core:build-pb"]
        assertPlanSuffix
            ( \root ->
                Context.deriveContainerContext
                    (Context.deriveVMContext root "/fixture/vm")
                    "/fixture/container"
            )
            "vm-project-container-2"
            ["core:deploy-chart", "core:deploy-kind"]
    , testCase "same-frame bootstrap work cannot precede its child subtree" $
        withExactPlan id workedDemoReversePlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            teardownForestOutstanding forest
                @?= [ "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:context-init"
                    , "core:copy-source"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
    , testCase "a preserve-on-reverse step is in neither projection" $
        withPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            assertBool
                "the preserved provider-ensure step is absent"
                ( "project:ensure-vm-provider"
                    `notElem` teardownForestOutstanding forest
                )
            assertBool
                "the preserved provider-ensure step is absent from down"
                ("project:ensure-vm-provider" `notElem` teardownForestOutstanding downForest)
    , testCase "the provider is stopped by down and deleted by destroy" $
        withPlan $ \plan current -> do
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            localActionFor "core:deploy-vm" downForest @?= Just StopFrame
            localActionFor "core:deploy-vm" destroyForest @?= Just DeleteFrame
    , testCase "the kind cluster is deleted by both verbs, because kind has no stop" $
        withExactPlan inContainer demoShapedPlan $ \plan current -> do
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            localActionFor "core:deploy-kind" downForest @?= Just DeleteCluster
            localActionFor "core:deploy-kind" destroyForest @?= Just DeleteCluster
    , testCase "the recovery profile and core-managed reverse policy classify by value" $ do
        TestReversePolicy.recoveryProfileNameKernel "Production" @?= Right "production"
        TestReversePolicy.recoveryProfileNameKernel "Harness r" @?= Right "harness:r"
        TestReversePolicy.recoveryProfileNameKernel "Harness " @?= Left "reverse child: the authenticated handoff carries an unknown lifecycle scope"
        TestReversePolicy.recoveryProfileNameKernel "Staging" @?= Left "reverse child: the authenticated handoff carries an unknown lifecycle scope"
        calls <- newIORef ([] :: [String])
        let release name result = modifyIORef' calls (++ [name]) >> pure result
            ok = Right () :: Either String ()
            failed = Left "exposure busy" :: Either String ()
        foreignOutcome <- TestReversePolicy.coreManagedReverseKernel ProjectManagedReverse DeleteCluster (release "exposure" ok) (release "cluster" ok)
        foreignOutcome @?= TeardownForeignRetained "the node acquired nothing this frame must release"
        contained <- TestReversePolicy.coreManagedReverseKernel CoreManagedReverse DeleteFrame (release "exposure" ok) (release "cluster" ok)
        contained @?= TeardownForeignRetained "released with the cluster that contains it"
        readIORef calls >>= (@?= [])
        exposureFailure <- TestReversePolicy.coreManagedReverseKernel CoreManagedReverse DeleteCluster (release "exposure" failed) (release "cluster" ok)
        exposureFailure @?= TeardownFailed (show ("exposure busy" :: String))
        readIORef calls >>= (@?= ["exposure"])
        writeIORef calls []
        released <- TestReversePolicy.coreManagedReverseKernel CoreManagedReverse DeleteCluster (release "exposure" ok) (release "cluster" ok)
        released @?= TeardownReleased
        readIORef calls >>= (@?= ["exposure", "cluster"])
    , testCase "the storeless reverse executor refuses non-canonical failed-Up adapters exactly" $ do
        let word = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE
            header = map frameWire ["hostbootstrap/reverse-descent-adapter", word 1, "digest", "parent", "child", "up", "teardown"]
            suffix = [frameWire (word 3), frameWire "released", frameWire "foreign-retained", frameWire "refused"]
            refusal raw expected = case TestTeardownExecutor.failedUpExpectedOperations (ByteString.concat raw) of
                Left (TeardownReverseDescentRefused detail) -> detail @?= expected
                other -> assertFailure ("expected " <> Text.unpack expected <> ", got " <> show (fmap (const ()) other))
        refusal (map frameWire ["other-domain", word 1] ++ drop 2 header ++ [frameWire (word 0)] ++ suffix) "the failed-Up adapter header differs"
        refusal (header ++ [frameWire (word 0)] ++ take 3 suffix) "the failed-Up adapter suffix differs"
        refusal (header ++ [frameWire (word 1), frameWire "\xff\xfe"] ++ suffix) "the failed-Up adapter operation is not UTF-8"
        refusal (header ++ [frameWire "abc"] ++ suffix) "the failed-Up adapter count is not a word"
        TestTeardownExecutor.failedUpExpectedOperations (ByteString.concat (header ++ [frameWire (word 1), frameWire "core:deploy-vm"] ++ suffix))
            @?= Right ["core:deploy-vm"]
    , testCase "the storeless reverse executor admits only the canonical adapter of one exact topology child" $ do
        let containerContext root =
                Context.deriveContainerContext (Context.deriveVMContext root "/fixture/vm") "/fixture/container"
            refused label expected outcome = case outcome of
                Left (TeardownReverseDescentRefused detail) -> detail @?= expected
                Left other -> assertFailure (label <> ": " <> teardownErrorMessage other)
                Right () -> assertFailure (label <> " was admitted")
        withExactPlan containerContext demoShapedPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDown)
            let expected = teardownForestOutstanding forest
                digest = stablePlanSnapshotDigest (renderSnapshot plan)
                adapter verb operations = renderReverseAdapterKernel digest verb "vm-orchestrator-1" "vm-project-container-2" operations
                admit bytes = TestTeardownExecutor.withStorelessReverseExecutorKernel plan current ProjectDown bytes (const ())
            admit (adapter "down" expected) @?= Right ()
            refused "a Destroy adapter" "the supplied reverse child adapter is not canonical" (admit (adapter "destroy" expected))
            refused "an extra operation" "the supplied reverse child adapter is not canonical" (admit (adapter "down" (expected ++ ["project:extra"])))
            refused "a duplicate operation" "the supplied reverse child adapter is not canonical" (admit (adapter "down" (expected ++ take 1 expected)))
            refused "a duplicated failed-Up operation" "the failed-Up adapter names duplicate or unadmitted operations"
                (TestTeardownExecutor.withStorelessReverseExecutorKernel plan current ProjectUp (adapter "up" (take 1 expected ++ take 1 expected)) (const ()))
        withPlan $ \plan current ->
            refused "the root frame" "the reverse child frame is not one exact topology child"
                (TestTeardownExecutor.withStorelessReverseExecutorKernel plan current ProjectDown "any adapter" (const ()))
    , testCase "the storeless reverse executor refuses mismatched Prepared and Descend responses without running work" $ do
        let containerContext root =
                Context.deriveContainerContext (Context.deriveVMContext root "/fixture/vm") "/fixture/container"
            gate plan operation session =
                TestPreparedGate.mintPreparedGate
                    (TestPreparedGate.GatePlanDigest (stablePlanSnapshotDigest (renderSnapshot plan)))
                    (TestPreparedGate.GateOperationKey operation) (TestPreparedGate.GateSession session)
                    (TestPreparedGate.GateFence 1) (TestPreparedGate.GateAttempt 1) (TestPreparedGate.GateJournalVersion 1)
            noRun _ _ = assertFailure "the executor ran reverse work after a refusal"
            refused label expected outcome = case outcome of
                Left (TeardownReverseDescentRefused detail) -> detail @?= expected
                Left other -> assertFailure (label <> ": " <> teardownErrorMessage other)
                Right _ -> assertFailure (label <> " was admitted")
        withExactPlan containerContext demoShapedPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDown)
            refused "a gate for another operation" "the gate names another reverse operation"
                =<< TestTeardownExecutor.runStorelessReversePreparedKernel hostConfigFixture noRun Right forest (gate plan "project:a" "session") "project:b"
            refused "a gate without durable authority" "the reverse gate is missing durable authority"
                =<< TestTeardownExecutor.runStorelessReversePreparedKernel hostConfigFixture noRun Right forest (gate plan "project:a" "") "project:a"
            refused "a Prepared response for another operation" "the Prepared response names another reverse operation"
                =<< TestTeardownExecutor.runStorelessReversePreparedKernel hostConfigFixture noRun Right forest (gate plan "project:other" "session") "project:other"
        withExactPlan id workedDemoReversePlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            refused "root-owned pre-descent work" "a pre-descent reachability step is root-owned"
                =<< TestTeardownExecutor.runStorelessReversePreparedKernel hostConfigFixture noRun Right forest (gate plan "core:deploy-vm" "session") "core:deploy-vm"
        withPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDown)
            refused "a descent result for another child" "the Descend response names another child frame"
                (TestTeardownExecutor.withStorelessReverseDescentResultKernel forest "another-frame" "" (const ()))
    , testCase "the durable share survives down and releases only after destroy's child subtree" $
        withExactPlan id workedDemoReversePlan $ \plan current -> do
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            localActionFor "core:copy-source" downForest @?= Just RetainResource
            localActionFor "core:copy-source" destroyForest @?= Just ReleaseResource
            localActionFor "core:deploy-vm" downForest @?= Just StopFrame
            localActionFor "core:deploy-vm" destroyForest @?= Just DeleteFrame
            teardownForestOutstanding downForest @?= teardownForestOutstanding destroyForest
    , testCase "project up refuses before exposing reverse work from a removable plan" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectUp
            teardownPlanVerbName projection @?= projectVerbName ProjectUp
            case openTeardownForest projection of
                Left TeardownProjectUpHasNoReverse -> pure ()
                other -> assertFailure ("expected the project-up refusal, got " ++ describeOpen other)
    , testCase "project up refusal takes precedence over the empty-plan error" $
        withPreservedPlan $ \plan current ->
            case openTeardownForest (teardownPlan plan current ProjectUp) of
                Left TeardownProjectUpHasNoReverse -> pure ()
                other -> assertFailure ("expected the project-up refusal, got " ++ describeOpen other)
    , testCase "failed-Up cleanup retains Up while projecting only an exact ordered subset" $
        withPlan $ \plan current -> do
            projected <-
                either
                    (assertFailure . teardownErrorMessage)
                    pure
                    (failedUpTeardownPlanKernel plan current ["core:deploy-vm", "core:build-pb"])
            teardownPlanVerbName projected @?= projectVerbName ProjectUp
            forest <- openOrFail projected
            teardownForestOutstanding forest @?= ["core:build-pb", "core:deploy-vm"]
            localActionFor "core:deploy-vm" forest @?= Just DeleteFrame
            case failedUpTeardownPlanKernel plan current ["core:deploy-vm", "core:deploy-vm"] of
                Left (TeardownReverseDescentRefused "the failed-Up reached set contains a duplicate") -> pure ()
                other -> assertFailure ("duplicate reached operations were accepted: " ++ showProjection other)
            case failedUpTeardownPlanKernel plan current ["project:not-in-plan"] of
                Left (TeardownReverseDescentRefused detail) ->
                    assertBool (Text.unpack detail) ("is not an ordered subset of the admitted plan" `Text.isInfixOf` detail)
                other -> assertFailure ("a foreign reached operation was accepted: " ++ showProjection other)
            skipped <- either (assertFailure . teardownErrorMessage) pure $
                failedUpTeardownPlanKernel plan current ["core:build-pb"]
            skippedForest <- openOrFail skipped
            teardownForestOutstanding skippedForest @?= ["core:build-pb"]
            case failedUpTeardownPlanKernel plan current ["core:build-pb", "core:deploy-vm"] of
                Left (TeardownReverseDescentRefused detail) ->
                    assertBool (Text.unpack detail) ("is not an ordered subset of the admitted plan" `Text.isInfixOf` detail)
                other -> assertFailure ("reordered reached operations were accepted: " ++ showProjection other)
    , testCase "failed-Up cleanup filters reached preserved nodes and projected relations" $
        withExactPlan id failedUpObservedPlan $ \plan current -> do
            projected <-
                either (assertFailure . teardownErrorMessage) pure $
                    failedUpTeardownPlanKernel
                        plan
                        current
                        [ "project:ensure-vm-provider"
                        , "project:ensure-vm-provider/guest-alias"
                        , "core:deploy-vm"
                        ]
            forest <- openOrFail projected
            teardownForestOutstanding forest @?= ["core:deploy-vm"]
    , testCase "a plan whose every step preserves projects nothing and cannot open" $
        withPreservedPlan $ \plan current ->
            case openTeardownForest (teardownPlan plan current ProjectDestroy) of
                Left (TeardownPlanEmpty "destroy") -> pure ()
                other -> assertFailure ("expected an empty projection, got " ++ describeOpen other)
    ]
  where
    showProjection = either teardownErrorMessage (const "projection")
    inContainer root =
        Context.deriveContainerContext
            (Context.deriveVMContext root "/fixture/vm")
            "/fixture/container"

-- ---------------------------------------------------------------------------
-- The forest

forestTests :: [TestTree]
forestTests =
    [ testCase "worked demo destroy waits for its child before all parent cleanup" $
        withExactPlan id workedDemoReversePlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            firstWork forest @?= Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")
            drainOrder forest
                @?= [ OfferedPreDescent "core:deploy-vm" "host-orchestrator-0"
                    , OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                    , OfferedLocal "core:copy-source" ReleaseResource
                    , OfferedLocal "core:build-pb" ReleaseResource
                    , OfferedLocal "core:deploy-vm" DeleteFrame
                    ]
    , testCase "failed worked demo descent blocks every parent cleanup" $
        withExactPlan id workedDemoReversePlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            let reached = attempt forest TeardownReleased
            firstWork reached @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
            let failed = attempt reached (TeardownFailed "child failed")
            firstWork failed @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
            let keys = teardownForestOutstanding failed
            assertBool "share, build, and provider remain outstanding" $
                all (`elem` keys) ["core:copy-source", "core:build-pb", "core:deploy-vm"]
    , testCase "destroy offers the provider's pre-descent step before any child" $
        withDestroyForest $ \forest ->
            firstWork forest
                @?= Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")
    , testCase "down never offers a pre-descent step" $
        withDownForest $ \forest -> do
            -- A down stops the provider and never reaches across it first.
            firstWork forest
                @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
            [key | OfferedPreDescent key _ <- drainOrder forest] @?= []
    , testCase "the pre-descent step exposes the children, not the provider itself" $
        withDestroyForest $ \forest -> do
            let afterReach = attempt forest TeardownReleased
            firstWork afterReach
                @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
    , testCase "failed provider reachability retains its children without offering guest descent" $
        withDestroyForest $ \forest -> do
            let failed = attempt forest (TeardownFailed "provider frame is absent")
            teardownForestOutstanding failed
                @?= [ "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
            teardownForestFailures failed
                @?= [("core:deploy-vm", "provider frame is absent")]
            teardownForestForeign failed @?= []
            -- Retry work names only the same failed provider. The production
            -- driver sees its failed key and stops before dispatching it.
            -- No completed forest or guest continuation is exposed here.
            firstWork failed
                @?= Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")
    , testCase "preDescentStepRun returns the provider's declared reverse" $ do
        -- The reachability step is not a marker the driver can tick: it carries
        -- the same callback the forward step declared, and the driver invokes it
        -- with the one action that means "open this frame". A driver that
        -- answered TeardownReleased without calling it would descend into a
        -- stopped provider, which is exactly the live failure this asserts away.
        seen <- newIORef []
        let recorder _cfg action = modifyIORef' seen (++ [action]) >> pure TeardownReleased
        withExactPlan id (reachablePlan recorder) $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            case nextPreDescent forest of
                Nothing -> assertFailure "destroy offered no pre-descent step"
                Just pre -> do
                    preDescentStepKey pre @?= "core:deploy-vm"
                    case preDescentStepRun pre of
                        Nothing -> assertFailure "the pre-descent step carries no declared reverse"
                        Just declared -> do
                            _ <- declared hostConfigFixture ReachFrame
                            readIORef seen >>= (@?= [ReachFrame])
    , testCase "the reverse driver reaches the provider before child descent" $ do
        seen <- newIORef ([] :: [String])
        let recorder _cfg action = do
                action @?= ReachFrame
                modifyIORef' seen (<> ["reach"])
                pure TeardownReleased
        withExactPlan id (reachablePlan recorder) $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            result <- driveTeardownForest forest (runPreDescentReachability hostConfigFixture)
                (\_ _ -> pure TeardownReleased)
                (\_ _ -> modifyIORef' seen (<> ["descent"]) >> pure (Left "stop after observation"))
                (\_ _ -> pure ())
            case result of
                Left _ -> pure ()
                Right _ -> assertFailure "the intentionally refused descent completed"
            readIORef seen >>= (@?= ["reach", "descent"])
    , testCase "unreachable provider prevents the reverse driver from descending" $ do
        descents <- newIORef (0 :: Int)
        let recorder _cfg _action = pure (TeardownFailed "provider unreachable")
        withExactPlan id (reachablePlan recorder) $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            result <- driveTeardownForest forest (runPreDescentReachability hostConfigFixture)
                (\_ _ -> pure TeardownReleased)
                (\_ _ -> modifyIORef' descents (+ 1) >> pure (Left "unexpected descent"))
                (\_ _ -> pure ())
            case result of
                Left outstanding -> assertBool "the failed provider is named" ("core:deploy-vm" `elem` outstanding)
                Right _ -> assertFailure "an unreachable provider completed"
            readIORef descents >>= (@?= 0)
    , testCase "a nested pre-descent refusal names the provider" $
        withDestroyForest $ \forest -> case nextPreDescent forest of
            Nothing -> assertFailure "destroy offered no pre-descent step"
            Just pre -> do
                outcome <- nestedPreDescentRefusal pre
                case outcome of
                    TeardownFailed detail -> assertBool "the refusal names the step" ("core:deploy-vm" `isInfixOf` detail)
                    other -> assertFailure ("expected a nested refusal, got " <> show other)
    , testCase "a node that declared no reverse has no reachability effect to run" $
        withDestroyForest $ \forest ->
            case nextPreDescent forest of
                Nothing -> assertFailure "destroy offered no pre-descent step"
                Just pre ->
                    assertBool
                        "a plan whose provider declares no reverse offers no reachability effect"
                        (isNothing (preDescentStepRun pre))
    , testCase "root, VM, and container openings classify only their immediate edge" $ do
        assertFirstOrdinaryPlacement
            id
            demoShapedPlan
            (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
        assertFirstOrdinaryPlacement
            (\root -> Context.deriveVMContext root "/fixture/vm")
            demoShapedPlan
            (OfferedDescent "vm-orchestrator-1" "vm-project-container-2")
        assertFirstOrdinaryPlacement
            ( \root ->
                Context.deriveContainerContext
                    (Context.deriveVMContext root "/fixture/vm")
                    "/fixture/container"
            )
            demoShapedPlan
            (OfferedLocal "core:deploy-chart" ReleaseResource)
    , testCase "an empty removable intermediate level still binds the immediate edge" $
        assertFirstOrdinaryPlacement
            id
            emptyIntermediateReversePlan
            (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
    , testCase "only local work projects and runs a declared reverse" $ do
        observed <- newIORef []
        let plan = executableContainerPlan observed
            containerContext root =
                Context.deriveContainerContext
                    (Context.deriveVMContext root "/fixture/vm")
                    "/fixture/container"
        withExactPlan containerContext plan $ \exactPlan current -> do
            forest <- openOrFail (teardownPlan exactPlan current ProjectDestroy)
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (\_ -> assertFailure "the local forest completed before its declared reverse")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "container-local work became pre-descent")
                        ( \_ work ->
                            eliminateTeardownWork
                                work
                                ( \local -> do
                                    localWorkKey local @?= "core:deploy-chart"
                                    localWorkAction local @?= ReleaseResource
                                    case localWorkRun local of
                                        Nothing -> assertFailure "the declared local reverse was lost"
                                        Just run -> do
                                            outcome <- run hostConfigFixture (localWorkAction local)
                                            outcome @?= TeardownReleased
                                    readIORef observed
                                        >>= (@?= [("core:deploy-chart", ReleaseResource)])
                                    teardownForestOutstanding
                                        (attemptLocalWork local TeardownReleased)
                                        @?= []
                                )
                                (\_ -> assertFailure "container-local work became descent")
                        )
                )
    , testCase "a parent is not offered until its exact child set settles" $
        withDestroyForest $ \forest -> do
            let order = drainOrder forest
            order
                @?= [ OfferedPreDescent "core:deploy-vm" "host-orchestrator-0"
                    , OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                    , OfferedLocal "core:deploy-vm" DeleteFrame
                    ]
    , testCase "the ordinary branch carries the settled-child proof" $
        withDestroyForest $ \forest -> do
            -- Open reachability, then join the exact child subtree proof.
            let ready =
                    drainUntil
                        (== OfferedLocal "core:deploy-vm" DeleteFrame)
                        (attempt forest TeardownReleased)
            teardownForestOutstanding ready @?= ["core:deploy-vm"]
            eliminateTeardownProgress
                (nextTeardownWork ready)
                (\_ -> assertFailure "the forest completed before the provider step")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "a second pre-descent step was offered")
                        ( \settled work -> do
                            settledChildrenKeys settled @?= ["core:build-pb"]
                            eliminateTeardownWork
                                work
                                (\local -> localWorkAction local @?= DeleteFrame)
                                (\_ -> assertFailure "the provider was classified as descent work")
                        )
                )
    , testCase "a failed descent blocks the exact child continuation as a unit" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failedChart = attempt reached (TeardownFailed "helm uninstall timed out")
            -- The same exact edge is outstanding; no sibling raw outcome may
            -- bypass the missing child-subtree proof.
            firstWork failedChart
                @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
            teardownForestFailures failedChart
                @?= [ ("core:deploy-chart", "helm uninstall timed out")
                    , ("core:deploy-kind", "helm uninstall timed out")
                    , ("core:build-pb", "helm uninstall timed out")
                    ]
    , testCase "a failed branch does not starve an independent sibling" $
        withExactPlan id siblingCleanupPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            firstWork forest
                @?= Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")
            let reached = attempt forest TeardownReleased
            firstWork reached @?= Just (OfferedLocal "project:cleanup-b" ReleaseResource)
            let failed = attempt reached (TeardownFailed "boom")
                siblingReleased = attempt failed TeardownReleased
                retryFailed = attempt siblingReleased (TeardownFailed "boom")
            forM_
                [ ( failed
                  , ["project:cleanup-b", "project:cleanup-a", "core:deploy-vm"]
                  , OfferedLocal "project:cleanup-a" ReleaseResource
                  )
                , ( siblingReleased
                  , ["project:cleanup-b", "core:deploy-vm"]
                  , OfferedLocal "project:cleanup-b" ReleaseResource
                  )
                , ( retryFailed
                  , ["project:cleanup-b", "core:deploy-vm"]
                  , OfferedLocal "project:cleanup-b" ReleaseResource
                  )
                ]
                ( \(blocked, outstanding, expectedWork) -> do
                    teardownForestFailures blocked @?= [("project:cleanup-b", "boom")]
                    teardownForestOutstanding blocked @?= outstanding
                    eliminateTeardownProgress
                        (nextTeardownWork blocked)
                        (\_ -> assertFailure "a failed sibling must keep the parent blocked and the forest incomplete")
                        (\point -> offeredWork point @?= expectedWork)
                )
    , testCase "foreign and refused observations settle without being torn down" $
        withExactPlan forestContainerContext demoShapedPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            let foreignChart = attempt forest (TeardownForeignRetained "an operator's release")
            teardownForestForeign foreignChart
                @?= [("core:deploy-chart", "an operator's release")]
            teardownForestFailures foreignChart @?= []
            firstWork foreignChart
                @?= Just (OfferedLocal "core:deploy-kind" DeleteCluster)
            let refusedCluster = attempt foreignChart (TeardownRefused "operator-held cluster")
            teardownForestForeign refusedCluster
                @?= [ ("core:deploy-chart", "an operator's release")
                    , ("core:deploy-kind", "operator-held cluster")
                    ]
            teardownForestFailures refusedCluster @?= []
    , testCase "every attempt returns a successor forest, including a failure" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failed = attempt reached (TeardownFailed "boom")
            teardownForestFailures reached @?= []
            teardownForestFailures failed
                @?= [ ("core:deploy-chart", "boom")
                    , ("core:deploy-kind", "boom")
                    , ("core:build-pb", "boom")
                    ]
            assertBool
                "the failed node stays outstanding"
                ("core:deploy-chart" `elem` teardownForestOutstanding failed)
            length (teardownForestOutstanding failed) @?= 4
    ]
  where
    forestContainerContext root =
        Context.deriveContainerContext
            (Context.deriveVMContext root "/fixture/vm")
            "/fixture/container"

settlementTests :: [TestTree]
settlementTests =
    [ testCase "a completed destroy forest settles every projected identity" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            let expectedKeys = teardownForestOutstanding forest
            completed <- drainToCompletion forest
            case verifySubtreeSettled projection completed of
                Right subtree -> case verifyDestroySettled plan current subtree of
                    Right settled -> do
                        destroySettledPlanDigest settled @?= planDigestOf plan
                        terminalKeyTexts (destroySettledTerminalObservations settled)
                            @?= expectedKeys
                        terminalKeyTexts
                            [ (key, TeardownReleased)
                            | key <- destroySettledReleasedOperationKeys settled
                            ]
                            @?= expectedKeys
                    Left failure -> assertFailure (teardownErrorMessage failure)
                Left failure -> assertFailure (teardownErrorMessage failure)
    , testCase "a node that keeps failing keeps the forest from ever completing" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failedChart = attempt reached (TeardownFailed "boom")
                failedAttempts =
                    take 4 (iterate (\failed -> attempt failed (TeardownFailed "boom")) failedChart)
            forM_ failedAttempts $ \failed -> do
                eliminateTeardownProgress
                    (nextTeardownWork failed)
                    (\_ -> assertFailure "a forest with a failing descendant must not complete")
                    ( \point ->
                        offeredWork point
                            @?= OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                    )
                teardownForestFailures failed
                    @?= [ ("core:deploy-chart", "boom")
                        , ("core:deploy-kind", "boom")
                        , ("core:build-pb", "boom")
                        ]
                teardownForestOutstanding failed
                    @?= [ "core:deploy-chart"
                        , "core:deploy-kind"
                        , "core:build-pb"
                        , "core:deploy-vm"
                        ]
    , testCase "a pre-descent foreign result cannot hide unobserved child nodes" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            let truncated = attempt forest (TeardownForeignRetained "provider is foreign")
            firstWork truncated @?= Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")
            teardownForestForeign truncated @?= [("core:deploy-vm", "provider is foreign")]
            let reached = attempt truncated TeardownReleased
            teardownForestForeign reached @?= []
            firstWork reached @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
            forM_ [TeardownForeignRetained "provider is foreign", TeardownRefused "provider refused"] $ \refusal -> do
                result <- driveWithOffered forest
                    (\work -> case work of
                        OfferedPreDescent _ _ -> pure refusal
                        _ -> assertFailure "unreached child work was offered")
                    (\_ _ -> pure ())
                case result of
                    Left outstanding -> outstanding @?= ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]
                    Right _ -> assertFailure "a refused reachability step completed the forest"
    , testCase "the exact child proof bulk-settles only its matching parent continuation" $
        withPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            let reached = attempt forest TeardownReleased
            eliminateTeardownProgress
                (nextTeardownWork reached)
                (\_ -> assertFailure "the root forest completed before child descent")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "the child edge became pre-descent")
                        ( \_ work ->
                            eliminateTeardownWork
                                work
                                (\_ -> assertFailure "the child edge became local work")
                                ( \descent ->
                                    withDescentWorkSubtree descent $ \childProjection -> do
                                        teardownPlanFrameId childProjection @?= "vm-orchestrator-1"
                                        childForest <- openOrFail childProjection
                                        childCompleted <- drainToCompletion childForest
                                        childSettled <-
                                            either
                                                (assertFailure . teardownErrorMessage)
                                                pure
                                                (verifySubtreeSettled childProjection childCompleted)
                                        terminalKeyTexts
                                            (subtreeSettledTerminalObservations childSettled)
                                            @?= [ "core:deploy-chart"
                                                , "core:deploy-kind"
                                                , "core:build-pb"
                                                ]
                                        let foreignChild =
                                                forgeSubtree ProjectDestroy "foreign-digest" (teardownPlanFrameId childProjection)
                                                    (subtreeSettledTerminalObservations childSettled)
                                        case settleDescentWork descent foreignChild of
                                            Left (TeardownPlanDigestMismatch _ "foreign-digest") -> pure ()
                                            Left failure -> assertFailure ("wrong child-proof refusal: " ++ show failure)
                                            Right _ -> assertFailure "foreign child proof was accepted"
                                        joined <-
                                            either
                                                (assertFailure . teardownErrorMessage)
                                                pure
                                                (settleDescentWork descent childSettled)
                                        firstWork joined
                                            @?= Just (OfferedLocal "core:deploy-vm" DeleteFrame)
                                        teardownForestOutstanding joined @?= ["core:deploy-vm"]
                                )
                        )
                )
    , testCase "nested down settlement cannot validate as the root" $
        withExactPlan inVM demoShapedPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDown
            forest <- openOrFail projection
            completed <- drainToCompletion forest
            subtree <- either (assertFailure . teardownErrorMessage) pure (verifySubtreeSettled projection completed)
            validateRootSubtreeSettled plan current subtree
                @?= Left (TeardownRootFrameMismatch "vm-orchestrator-1" ["host-orchestrator-0"])
    , testCase "root down settlement validates at the root" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDown
            forest <- openOrFail projection
            completed <- drainToCompletion forest
            subtree <- either (assertFailure . teardownErrorMessage) pure (verifySubtreeSettled projection completed)
            validateRootSubtreeSettled plan current subtree @?= Right ()
    , testCase "nested destroy settlement cannot promote to project-wide closure" $
        withExactPlan inVM demoShapedPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            completed <- drainToCompletion forest
            subtree <-
                either
                    (assertFailure . teardownErrorMessage)
                    pure
                    (verifySubtreeSettled projection completed)
            case verifyDestroySettled plan current subtree of
                Left (TeardownRootFrameMismatch "vm-orchestrator-1" ["host-orchestrator-0"]) -> pure ()
                other -> assertFailure ("nested subtree promoted to root destroy: " ++ show other)
    , testCase "exact terminal validation rejects missing, extra, duplicate, reordered, and failed observations" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
                digest = planDigestOf plan
                frame = currentFrameId current
                keys =
                    reverse
                        [ plannedStepOperationKey step
                        | step <- NonEmpty.toList (forward plan)
                        , plannedStepReversePolicy step /= PreserveOnReverse
                        ]
                exact = [(key, TeardownReleased) | key <- keys]
                malformed =
                    [ ("missing", drop 1 exact)
                    , ("extra", exact ++ take 1 exact)
                    ,
                        ( "duplicate"
                        , case exact of
                            first : _second : rest -> first : first : rest
                            _ -> exact
                        )
                    ,
                        ( "reordered"
                        , case exact of
                            first : second : rest -> second : first : rest
                            _ -> exact
                        )
                    ]
            case verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest frame exact) of
                Right settled -> subtreeSettledTerminalObservations settled @?= exact
                Left failure -> assertFailure ("the exact terminal sequence was refused: " ++ show failure)
            case verifySubtreeSettled projection (unsafeCoerce (forgeCompleted ProjectDown digest frame exact)) of
                Left (TeardownProjectVerbMismatch "destroy" "down") -> pure ()
                other -> assertFailure ("wrong-verb completion was accepted: " ++ show other)
            case verifySubtreeSettled projection (forgeCompleted ProjectDestroy "foreign-digest" frame exact) of
                Left (TeardownPlanDigestMismatch expected "foreign-digest") -> expected @?= digest
                other -> assertFailure ("wrong-digest completion was accepted: " ++ show other)
            case verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest "foreign-frame" exact) of
                Left (TeardownOpeningFrameMismatch expected "foreign-frame") -> expected @?= frame
                other -> assertFailure ("wrong-frame completion was accepted: " ++ show other)
            case verifyDestroySettled plan current (forgeSubtree ProjectDestroy "foreign-digest" frame exact) of
                Left (TeardownPlanDigestMismatch expected "foreign-digest") -> expected @?= digest
                other -> assertFailure ("wrong-digest root proof was accepted: " ++ show other)
            forM_ malformed $ \(label, observations) ->
                case verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest frame observations) of
                    Left (TeardownTerminalObservationsMismatch _ _) -> pure ()
                    other -> assertFailure (label ++ " terminal sequence was accepted: " ++ show other)
            let failed = case exact of
                    (key, _) : rest -> (key, TeardownFailed "boom") : rest
                    [] -> []
            case verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest frame failed) of
                Left (TeardownNonTerminalObservations _) -> pure ()
                other -> assertFailure ("failed terminal sequence was accepted: " ++ show other)
    ]
  where
    inVM root = Context.deriveVMContext root "/fixture/vm"

-- ---------------------------------------------------------------------------
-- Driving the forest

data OfferedWork
    = OfferedPreDescent Text Text
    | OfferedLocal Text TeardownAction
    | OfferedDescent Text Text
    deriving (Eq, Show)

{- | Test-only representation mirror used to adversarially exercise the
runtime exact-sequence checks behind the opaque constructor. Ordinary client
code is separately required to fail compilation when it tries to construct or
coerce a completion/proof.
-}
data CompletedShape verb
    = CompletedShape
        (ProjectVerb verb)
        Text
        Text
        [(OperationKey, TeardownOutcome)]

forgeCompleted ::
    ProjectVerb verb ->
    Text ->
    Text ->
    [(OperationKey, TeardownOutcome)] ->
    CompletedTeardownForest scope planId frame verb
forgeCompleted verb digest frame observations =
    unsafeCoerce (CompletedShape verb digest frame observations)

-- Match the hidden subtree representation to exercise its defensive joins.
forgeSubtree ::
    ProjectVerb verb ->
    Text ->
    Text ->
    [(OperationKey, TeardownOutcome)] ->
    SubtreeSettled scope planId frame verb
forgeSubtree verb digest frame observations =
    unsafeCoerce (CompletedShape verb digest frame observations)

terminalKeyTexts :: [(OperationKey, TeardownOutcome)] -> [Text]
terminalKeyTexts = map (Text.pack . ProjectPlan.operationKeyText . fst)

driveWithOffered ::
    TeardownForest scope planId frame verb ->
    (OfferedWork -> IO TeardownOutcome) ->
    (Text -> TeardownOutcome -> IO ()) ->
    IO (Either [Text] (CompletedTeardownForest scope planId frame verb))
driveWithOffered forest attemptOffered =
    driveTeardownForest
        forest
        ( \pre ->
            attemptOffered
                (OfferedPreDescent (preDescentStepKey pre) (preDescentStepFrame pre))
        )
        ( \_ local ->
            attemptOffered (OfferedLocal (localWorkKey local) (localWorkAction local))
        )
        ( \_ descent ->
            do
                edge <-
                    attemptOffered
                        ( OfferedDescent
                            (descentWorkParentFrame descent)
                            (descentWorkChildFrame descent)
                        )
                case edge of
                    TeardownReleased ->
                        withDescentWorkSubtree descent $ \childProjection ->
                            case openTeardownForest childProjection of
                                Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                                Right childForest -> do
                                    childDriven <-
                                        driveWithOffered
                                            childForest
                                            attemptOffered
                                            (\_ _ -> pure ())
                                    pure $ case childDriven of
                                        Left outstanding ->
                                            Left
                                                ( "child subtree remained outstanding: "
                                                    <> Text.intercalate ", " outstanding
                                                )
                                        Right childCompleted ->
                                            either
                                                (Left . Text.pack . teardownErrorMessage)
                                                Right
                                                (verifySubtreeSettled childProjection childCompleted)
                    TeardownFailed detail -> pure (Left (Text.pack detail))
                    TeardownForeignRetained detail ->
                        pure (Left ("raw foreign descent cannot settle a subtree: " <> Text.pack detail))
                    TeardownRefused detail ->
                        pure (Left ("raw refused descent cannot settle a subtree: " <> Text.pack detail))
        )

offeredWork :: TeardownAuthorizationPoint scope planId frame verb -> OfferedWork
offeredWork point =
    withTeardownAuthorization
        point
        (\pre -> OfferedPreDescent (preDescentStepKey pre) (preDescentStepFrame pre))
        ( \_ work ->
            eliminateTeardownWork
                work
                (\local -> OfferedLocal (localWorkKey local) (localWorkAction local))
                ( \descent ->
                    OfferedDescent
                        (descentWorkParentFrame descent)
                        (descentWorkChildFrame descent)
                )
        )

advancePoint ::
    TeardownAuthorizationPoint scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
advancePoint point outcome =
    withTeardownAuthorization
        point
        (`attemptPreDescentStep` outcome)
        ( \_ work ->
            eliminateTeardownWork
                work
                (`attemptLocalWork` outcome)
                (\descent -> advanceDescent descent outcome)
        )

advanceDescent ::
    DescentWork scope planId frame childFrame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
advanceDescent descent outcome = case outcome of
    TeardownReleased ->
        withDescentWorkSubtree descent $ \childProjection ->
            case openTeardownForest childProjection of
                Left failure -> failDescentWork descent (Text.pack (teardownErrorMessage failure))
                Right childForest ->
                    case completedAfterReleased childForest of
                        Left detail -> failDescentWork descent detail
                        Right childCompleted ->
                            case verifySubtreeSettled childProjection childCompleted of
                                Left failure ->
                                    failDescentWork descent (Text.pack (teardownErrorMessage failure))
                                Right childSettled ->
                                    either
                                        (failDescentWork descent . Text.pack . teardownErrorMessage)
                                        id
                                        (settleDescentWork descent childSettled)
    TeardownFailed detail -> failDescentWork descent (Text.pack detail)
    TeardownForeignRetained detail ->
        failDescentWork descent ("raw foreign descent cannot settle a subtree: " <> Text.pack detail)
    TeardownRefused detail ->
        failDescentWork descent ("raw refused descent cannot settle a subtree: " <> Text.pack detail)

completedAfterReleased ::
    TeardownForest scope planId frame verb ->
    Either Text (CompletedTeardownForest scope planId frame verb)
completedAfterReleased = go (0 :: Int)
  where
    go depth forest
        | depth > 64 = Left "released subtree traversal exceeded its finite bound"
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                Right
                (\point -> go (depth + 1) (advancePoint point TeardownReleased))

attempt ::
    TeardownForest scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
attempt forest outcome =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const forest)
        (`advancePoint` outcome)

firstWork :: TeardownForest scope planId frame verb -> Maybe OfferedWork
firstWork forest =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const Nothing)
        (Just . offeredWork)

localActionFor ::
    Text ->
    TeardownForest scope planId frame verb ->
    Maybe TeardownAction
localActionFor target = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = Nothing
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const Nothing)
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\pre -> go (depth + 1) (attemptPreDescentStep pre TeardownReleased))
                        ( \_ work ->
                            eliminateTeardownWork
                                work
                                ( \local ->
                                    if localWorkKey local == target
                                        then Just (localWorkAction local)
                                        else go (depth + 1) (attemptLocalWork local TeardownReleased)
                                )
                                ( \descent ->
                                    go (depth + 1) (advanceDescent descent TeardownReleased)
                                )
                        )
                )

-- | Release every offered step, recording the order they were offered in.
drainOrder :: TeardownForest scope planId frame verb -> [OfferedWork]
drainOrder = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = []
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const [])
                ( \point ->
                    offeredWork point
                        : go (depth + 1) (advancePoint point TeardownReleased)
                )

-- | Release steps until the next offered branch satisfies the predicate.
drainUntil ::
    (OfferedWork -> Bool) ->
    TeardownForest scope planId frame verb ->
    TeardownForest scope planId frame verb
drainUntil matches = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = forest
        | Just work <- firstWork forest
        , matches work =
            forest
        | otherwise = go (depth + 1) (attempt forest TeardownReleased)

-- | Release everything still offered.
drainAll :: TeardownForest scope planId frame verb -> TeardownForest scope planId frame verb
drainAll = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = forest
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const forest)
                (\point -> go (depth + 1) (advancePoint point TeardownReleased))

drainToCompletion ::
    TeardownForest scope planId frame verb ->
    IO (CompletedTeardownForest scope planId frame verb)
drainToCompletion forest =
    eliminateTeardownProgress
        (nextTeardownWork (drainAll forest))
        pure
        ( \point ->
            assertFailure
                ("the forest did not complete; still offering " ++ show (offeredWork point))
        )

{- | A real 'HostConfig' for the host the suite runs on. The reverse effects
under test never touch a tool, so its resolved set is irrelevant; what matters
is that the driver threads the production value rather than a stub.
-}
hostConfigFixture :: HostConfig
hostConfigFixture = unsafePerformIO (detect >>= either fail pure >>= buildHostConfig)
{-# NOINLINE hostConfigFixture #-}

-- ---------------------------------------------------------------------------
-- Plans

{- | The demo shape with a reverse effect actually declared on the provider, so
the reachability step has something to carry.
-}
reachablePlan :: (HostConfig -> TeardownAction -> IO TeardownOutcome) -> StepPlan
reachablePlan reverseEffect =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , reversedBy reverseEffect (descendsVia localContext (deployVMStep "launch" metalFrame noop))
        , descendsVia localContext (buildPbStep "build" vmFrame noop)
        , deployKindStep "cluster" containerFrame noop
        , deployChartStep "chart" containerFrame noop
        ]

-- | The forest's next offer, when it is a pre-descent reachability step.
nextPreDescent ::
    TeardownForest scope planId frame verb ->
    Maybe (PreDescentStep scope planId frame verb)
nextPreDescent forest =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const Nothing)
        (\point -> withTeardownAuthorization point Just (\_ _ -> Nothing))

{- | The demo's own shape: an ensure step that preserves on reverse, the VM
launch, the in-VM build, and the in-container cluster and chart.
-}
demoShapedPlan :: StepPlan
demoShapedPlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , descendsVia localContext (deployVMStep "launch" metalFrame noop)
        , descendsVia localContext (buildPbStep "build" vmFrame noop)
        , deployKindStep "cluster" containerFrame noop
        , deployChartStep "chart" containerFrame noop
        ]

-- These local cleanup nodes are siblings under the provider in the reverse
-- forest, while the forward plan retains its ordered dependency prefixes.
siblingCleanupPlan :: StepPlan
siblingCleanupPlan =
    mkPlan
        [ deployVMStep "parent" metalFrame noop
        , projectStep (demoStep "cleanup-a") ProjectManagedReverse "A" metalFrame noop
        , projectStep (demoStep "cleanup-b") ProjectManagedReverse "B" metalFrame noop
        ]

-- The worked demo has multiple host-local bootstrap nodes before the provider
-- and declares its two frame boundaries on later nodes. Its reverse forest is
-- the regression shape for preserving the flat projection's child-first order.
workedDemoReversePlan :: StepPlan
workedDemoReversePlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , deployVMStep "launch" metalFrame noop
        , buildPbStep "build" metalFrame noop
        , descendsVia localContext (copySourceStep "share" metalFrame noop)
        , descendsVia localContext (contextInitStep "context" vmFrame noop)
        , deployKindStep "cluster" containerFrame noop
        , deployChartStep "chart" containerFrame noop
        ]

allPreservedPlan :: StepPlan
allPreservedPlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        ]

failedUpObservedPlan :: StepPlan
failedUpObservedPlan =
    mkPlan
        [ projectsOperation "project:ensure-vm-provider/guest-alias" $
            projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , deployVMStep "launch" metalFrame noop
        ]

{- | The VM level exists in the exact topology but contributes no removable
reverse node. Descendant work opened at the root must still bind root→VM,
never skip directly to the container.
-}
emptyIntermediateReversePlan :: StepPlan
emptyIntermediateReversePlan =
    mkPlan
        [ descendsVia localContext (deployVMStep "launch" metalFrame noop)
        , descendsVia
            localContext
            (projectStep (demoStep "preserved-vm-bridge") PreserveOnReverse "bridge" vmFrame noop)
        , deployChartStep "chart" containerFrame noop
        ]

executableContainerPlan :: IORef [(Text, TeardownAction)] -> StepPlan
executableContainerPlan observed =
    mkPlan
        [ descendsVia localContext (deployVMStep "launch" metalFrame noop)
        , descendsVia localContext (buildPbStep "build" vmFrame noop)
        , reversedBy
            ( \_cfg action -> do
                modifyIORef' observed (++ [("core:deploy-chart", action)])
                pure TeardownReleased
            )
            (deployChartStep "chart" containerFrame noop)
        ]

mkPlan :: [Step] -> StepPlan
mkPlan = either (error . show) id . mkStepPlan

demoStep :: String -> ProjectStepId
demoStep = either (error . show) id . projectStepId

noop :: p -> IO StepObservation
noop _ = pure StepChanged

metalFrame :: StepFrame
metalFrame = StepFrame "host-orchestrator-0" "Host"

vmFrame :: StepFrame
vmFrame = StepFrame "vm-orchestrator-1" "VM"

containerFrame :: StepFrame
containerFrame = StepFrame "vm-project-container-2" "Container"

withExactPlan ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    StepPlan ->
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IO result
    ) ->
    IO result
withExactPlan selectContext stepPlan use =
    Fixture.withFixtureProjectPlanContext selectContext stepPlan $ \plan exactContext ->
        case withCurrentFrame plan exactContext (\current _projectFrame _validated -> use plan current) of
            Left failure -> assertFailure (show failure)
            Right action -> action

withPlan ::
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IO ()
    ) ->
    IO ()
withPlan = withExactPlan id demoShapedPlan

-- | A plan every one of whose steps preserves on reverse.
withPreservedPlan ::
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IO ()
    ) ->
    IO ()
withPreservedPlan = withExactPlan id allPreservedPlan

planDigestOf :: ProjectPlan scope specDigest planId configId cfg -> Text
planDigestOf = stablePlanSnapshotDigest . renderSnapshot

openOrFail ::
    TeardownPlan scope planId frame verb ->
    IO (TeardownForest scope planId frame verb)
openOrFail projection =
    either (assertFailure . teardownErrorMessage) pure (openTeardownForest projection)

withDestroyForest ::
    ( forall projectId planId frame.
      TeardownForest (Production projectId) planId frame VerbDestroy ->
      IO ()
    ) ->
    IO ()
withDestroyForest use =
    withPlan $ \plan current -> openOrFail (teardownPlan plan current ProjectDestroy) >>= use

withDownForest ::
    ( forall projectId planId frame.
      TeardownForest (Production projectId) planId frame VerbDown ->
      IO ()
    ) ->
    IO ()
withDownForest use =
    withPlan $ \plan current -> openOrFail (teardownPlan plan current ProjectDown) >>= use

assertPlanSuffix ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    Text ->
    [Text] ->
    IO ()
assertPlanSuffix selectContext expectedFrame expectedKeys =
    withExactPlan selectContext demoShapedPlan $ \plan current -> do
        let projection = teardownPlan plan current ProjectDestroy
        forest <- openOrFail projection
        currentFrameId current @?= expectedFrame
        teardownPlanFrameId projection @?= expectedFrame
        teardownForestOutstanding forest @?= expectedKeys

assertFirstOrdinaryPlacement ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    StepPlan ->
    OfferedWork ->
    IO ()
assertFirstOrdinaryPlacement selectContext stepPlan expected =
    withExactPlan selectContext stepPlan $ \plan current -> do
        forest <- openOrFail (teardownPlan plan current ProjectDestroy)
        firstOrdinary (0 :: Int) forest @?= Just expected
  where
    firstOrdinary depth forest
        | depth > 4 = Nothing
        | otherwise = case firstWork forest of
            Just (OfferedPreDescent _ _) ->
                firstOrdinary (depth + 1) (attempt forest TeardownReleased)
            offered -> offered

describeOpen :: Either TeardownError (TeardownForest scope planId frame verb) -> String
describeOpen = either teardownErrorMessage (const "an opened forest")

-- Compiled with the actual private Main-unit interface by withPrivateEntryKernel.
privateFailedUpEntrySource :: String
privateFailedUpEntrySource =
    unlines
        [ "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , "{-# LANGUAGE RankNTypes #-}"
        , "{-# LANGUAGE ScopedTypeVariables #-}"
        , "{-# LANGUAGE TypeApplications #-}"
        , ""
        , "-- Compiled in the Main library's unit only by the private-entry test harness."
        , "module Main (main) where"
        , ""
        , "import qualified Data.ByteString as ByteString"
        , "import Data.IORef (newIORef, readIORef, writeIORef)"
        , "import qualified Data.List.NonEmpty as NonEmpty"
        , "import Data.Text (Text)"
        , "import qualified Data.Text as Text"
        , "import qualified Fixture"
        , "import Expect (expectRight)"
        , "import qualified HostBootstrap.Authority as Authority"
        , "import qualified HostBootstrap.Authority.FailedUp.Internal as FailedUp"
        , "import qualified HostBootstrap.Authority.Testing as AuthorityFixture"
        , "import qualified HostBootstrap.Command.LifecycleEntry as Entry"
        , "import HostBootstrap.Config.Class (withProductionProjectCodec)"
        , "import HostBootstrap.Config.Schema (withValidatedConfig)"
        , "import HostBootstrap.Config.Vocab (Production)"
        , "import qualified HostBootstrap.Context as Context"
        , "import qualified HostBootstrap.Handoff as Handoff"
        , "import qualified HostBootstrap.Lifecycle.Context as LifecycleContext"
        , "import HostBootstrap.Lifecycle.Mode (productionActiveMode, productionRootAuthority, productionRootModeLease, productionRootUnboundLease, withProductionLifecycleProfile, withProductionRoot)"
        , "import qualified HostBootstrap.Lift.Context as LiftContext"
        , "import HostBootstrap.ProjectPlan (forward, plannedStepOperationKey)"
        , "import qualified HostBootstrap.ProjectPlan as ProjectPlan"
        , "import HostBootstrap.ProjectPlan.Construct (finalizedProjectCodec, projectPlanDrafts, withFinalizedProjectSpec, withProjectPlan)"
        , "import HostBootstrap.ProjectPlan.Frame (withCurrentFrame)"
        , "import HostBootstrap.ProjectPlan.Snapshot (withPersistedPlanSnapshot)"
        , "import HostBootstrap.ProjectRoot (canonicalProjectRootPath, withCanonicalProjectRoot)"
        , "import HostBootstrap.Protected"
        , "import HostBootstrap.Service (emptyServiceRegistry)"
        , "import HostBootstrap.Step"
        , "import HostBootstrap.Teardown"
        , "import qualified TestRootedPlan"
        , "import System.FilePath ((</>))"
        , "import System.IO.Temp (withSystemTempDirectory)"
        , "import Test.Tasty.HUnit (assertFailure, (@?=))"
        , "import Unsafe.Coerce (unsafeCoerce)"
        , ""
        , "main :: IO ()"
        , "main = withEntry False $ \\store _project root catalog entry reached ->"
        , "    withEntry True $ \\foreignStore foreignProject foreignRoot foreignCatalog _ _ -> do"
        , "        signing <- expectRight (Handoff.projectSigningKeyFromBytes (ByteString.replicate 32 91))"
        , "        brokered <- Handoff.withRootBroker (Handoff.productionHandoffScope foreignProject) foreignStore signing foreignRoot $ \\broker -> do"
        , "            token <- Handoff.freshHandoffToken"
        , "            let input = Handoff.HandoffBindingInput"
        , "                    { Handoff.requestedSpecDigest = \"fixture-spec\""
        , "                    , Handoff.requestedPayloadKind = Handoff.NarrowedProjectConfig"
        , "                    , Handoff.requestedPlanRevision = \"fixture-plan\""
        , "                    , Handoff.requestedParentFrame = \"host-orchestrator-0\""
        , "                    , Handoff.requestedChildFrame = \"vm-orchestrator-1\""
        , "                    , Handoff.requestedChildConfigDigest = Handoff.childConfigDigest \"payload\""
        , "                    , Handoff.requestedPhase = \"execute\""
        , "                    }"
        , "            binding <- Handoff.renderHandoffBinding <$> expectRight (Handoff.mkHandoffBinding broker input token)"
        , "            foreignReport <- expectRight (Handoff.renderForwardFailedLifecycleReportWithObservations binding [(\"project:root\", \"failed\", \"failure\")] \"failure\")"
        , "            let operation = case reached of"
        , "                    first : _ -> first"
        , "                    [] -> error \"the fixture plan has no reached operations\""
        , "            matchingReport <- expectRight (Handoff.renderForwardFailedLifecycleReportWithObservations binding [(operation, \"failed\", \"failure\")] \"failure\")"
        , "            action <- expectRight $ FailedUp.withRootFailedUpUnwindAuthorityKernel foreignRoot foreignCatalog foreignReport binding \"host-orchestrator-0\" [\"project:root\"] [] $ \\foreignAuthority ->"
        , "                FailedUp.withRootFailedUpUnwindAuthorityKernel root catalog matchingReport binding \"host-orchestrator-0\" reached reached $ \\matching -> do"
        , "                    let foreignAligned = unsafeCoerce foreignAuthority"
        , "                    before <- storeImage store"
        , "                    Entry.withFailedUpTeardownForestForEntryKernel entry foreignAligned (const ())"
        , "                        @?= Left \"the failure authority names another catalog\""
        , "                    forest <- expectRight (Entry.withFailedUpTeardownForestForEntryKernel entry matching id)"
        , "                    seekDescent store before entry foreignAligned forest"
        , "            matchingAction <- expectRight action"
        , "            matchingAction"
        , "            pure (Right () :: Either Text ())"
        , "        expectRight brokered >>= expectRight"
        , ""
        , "seekDescent ::"
        , "    ProtectedStore -> [(Text, Maybe (RecordVersion, ByteString.ByteString))] ->"
        , "    Entry.LifecycleEntry scope planId frame generation Authority.VerbUp ->"
        , "    FailedUp.FailedUpUnwindAuthority scope planId generation catalogId ->"
        , "    TeardownForest scope planId frame Authority.VerbUp -> IO ()"
        , "seekDescent store before entry foreignAuthority forest ="
        , "    eliminateTeardownProgress (nextTeardownWork forest)"
        , "        (\\_ -> assertFailure \"the matching forest has no descent\")"
        , "        (\\point -> withTeardownAuthorization point"
        , "            (\\pre -> seekDescent store before entry foreignAuthority (attemptPreDescentStep pre TeardownReleased))"
        , "            (\\_ work -> eliminateTeardownWork work"
        , "                (\\local -> seekDescent store before entry foreignAuthority (attemptLocalWork local TeardownReleased))"
        , "                (\\descent -> do"
        , "                    called <- newIORef False"
        , "                    outcome <- Entry.withPreparedFailedUpReverseDescentKernel entry foreignAuthority descent (\\_ -> writeIORef called True)"
        , "                    case outcome of"
        , "                        Left (TeardownReverseDescentRefused \"the failure authority names another catalog\", _) -> pure ()"
        , "                        _ -> assertFailure \"the descent wrapper did not refuse the foreign catalog\""
        , "                    readIORef called >>= (@?= False)"
        , "                    storeImage store >>= (@?= before))))"
        , ""
        , "storeImage :: ProtectedStore -> IO [(Text, Maybe (RecordVersion, ByteString.ByteString))]"
        , "storeImage store = expectRight =<< withProtectedEntry store (\\session -> do"
        , "    keys <- expectRight =<< listProtectedRecords session"
        , "    rows <- mapM (\\key -> do record <- expectRight =<< readProtectedRecord session key; pure (recordKeyText key, fmap (\\r -> (protectedRecordVersion r, protectedRecordBytes r)) record)) keys"
        , "    pure (Right rows))"
        , ""
        , "withEntry ::"
        , "    Bool ->"
        , "    (forall projectId planId generation catalogId frame."
        , "      ProtectedStore -> Authority.InstalledProjectIdentity projectId ->"
        , "      Authority.RootInvocationAuthority (Production projectId) generation Authority.VerbUp ->"
        , "      TestRootedPlan.RootedPlanCatalog (Production projectId) planId generation catalogId ->"
        , "      Entry.LifecycleEntry (Production projectId) planId frame generation Authority.VerbUp ->"
        , "      [Text] -> IO ()) -> IO ()"
        , "withEntry priorAllocation use ="
        , "    Fixture.withFixtureInstalledProject $ \\(project :: Authority.InstalledProjectIdentity projectId) ->"
        , "        withSystemTempDirectory \"hostbootstrap-failed-up-entry\" $ \\directory -> do"
        , "            rooted <- withCanonicalProjectRoot (directory </> \"fixture.dhall\") directory $ \\root -> do"
        , "                let name = Authority.installedProjectName project"
        , "                    value = Fixture.defaultProjectConfig name (Text.pack (canonicalProjectRootPath root)) Context.HostOrchestrator"
        , "                    noop _ = pure StepChanged"
        , "                    node label frame = reversedBy (\\_ _ -> pure TeardownReleased) $"
        , "                        projectStep (either error id (projectStepId label)) ProjectManagedReverse label frame noop"
        , "                    steps ="
        , "                        [ descendsVia (LiftContext.vmContext (LiftContext.inVM (LiftContext.IncusVM \"fixture-vm\" \"fixture:image\") LiftContext.emptyVMStack))"
        , "                            (node \"launch\" (StepFrame \"host-orchestrator-0\" \"Host\"))"
        , "                        , node \"build\" (StepFrame \"vm-orchestrator-1\" \"VM\")"
        , "                        ]"
        , "                graph <- expectRight (mkStepPlan steps)"
        , "                store <- expectRight =<< openProtectedStore (directory </> \".hostbootstrap\" </> \"authority\" </> Text.unpack name)"
        , "                if priorAllocation"
        , "                    then do"
        , "                        allocated <- expectRight =<< withProtectedEntry store (\\protected -> Right <$> AuthorityFixture.withFreshBrokerEpochKernel protected project (\\_ -> pure (Right ())))"
        , "                        expectRight allocated"
        , "                    else pure ()"
        , "                opened <- withProductionRoot store project Authority.ProjectUp $ \\production -> do"
        , "                    let rootAuthority = productionRootAuthority production"
        , "                        unbound = productionRootUnboundLease production"
        , "                    profiled <- expectRight =<< withProductionLifecycleProfile"
        , "                        (Authority.rootScopeAuthority rootAuthority)"
        , "                        (productionActiveMode (productionRootModeLease production)) unbound"
        , "                        (\\profile -> withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \\codec ->"
        , "                            withFinalizedProjectSpec codec emptyServiceRegistry"
        , "                                (\\_ _ -> Right graph) (Fixture.projectingForwardChildPlan \"/workspace/demo\" steps) $ \\spec -> do"
        , "                                    validated <- withValidatedConfig (finalizedProjectCodec spec) value $ \\_ config -> do"
        , "                                        drafts <- expectRight (projectPlanDrafts spec root config)"
        , "                                        planned <- expectRight $ withProjectPlan profile root config drafts $ \\plan -> do"
        , "                                            persisted <- withPersistedPlanSnapshot rootAuthority unbound plan $ \\verified bound binding lease _ -> do"
        , "                                                contextual <- LifecycleContext.withValidatedLifecycleContext root store plan value.context $ \\context -> do"
        , "                                                    currentAction <- expectRight $ withCurrentFrame plan value.context $ \\current _ _ -> do"
        , "                                                        cataloged <- TestRootedPlan.withRootedPlanCatalogKernel spec rootAuthority plan (unsafeCoerce current) context $ \\catalog -> do"
        , "                                                            let reached = map (Text.pack . ProjectPlan.operationKeyText . plannedStepOperationKey) (NonEmpty.toList (forward plan))"
        , "                                                            admitted <- Entry.withRootProjectUpLifecycleEntry spec rootAuthority Authority.ProjectUp verified bound binding lease plan context project $ \\entry -> do"
        , "                                                                use store project rootAuthority catalog entry reached"
        , "                                                                pure (Right ())"
        , "                                                            pure (either (Left . Text.pack) Right admitted)"
        , "                                                        expectRight cataloged"
        , "                                                    currentAction"
        , "                                                expectRight contextual"
        , "                                            expectRight persisted"
        , "                                        planned"
        , "                                    expectRight validated)"
        , "                    result <- profiled"
        , "                    pure (Right result)"
        , "                expectRight opened"
        , "            expectRight rooted"
        , ""
        ]
