{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The protected operation session, fence rotation, and prepare
compare-and-swap.

Every case here runs against a real protected store on a real filesystem, so a
"crash" is modelled the only honest way: by stopping between two durable writes
and then reopening the store, exactly as an interrupted invocation leaves it.
-}
module SessionSpec (tests, runFenceDelayProbe) where

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeException, evaluate, try)
import qualified Crypto.Hash as Hash
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (find, sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (
    BrokerEpoch,
    InstalledProjectIdentity,
    RootInvocationAuthority,
    VerbUp,
    brokerEpochWord,
    installedProjectName,
    lifecyclePhaseName,
    rootAuthorityEpoch,
    rootScopeAuthority,
 )
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import HostBootstrap.Config.Schema (withValidatedConfig)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    newResourceCarrier,
    newStepRuntime,
    stepExecutionOperationKey,
 )
import HostBootstrap.Lifecycle.Prepared (decodeFields, encodeFields)
import HostBootstrap.Lifecycle.Mode (
    AcquisitionJournal,
    BoundRunLease,
    LifecycleCursor,
    LifecycleError,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    acquisitionJournalRunLease,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalStableScope,
    boundRunLeasePlanDigest,
    boundRunLeaseRunText,
    boundRunLeaseSpecDigest,
    bindRunLease,
    lifecycleErrorMessage,
    lifecycleCursorFrame,
    lifecycleCursorPhase,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    modeErrorMessage,
    persistCanonicalPlanSnapshot,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withAcquisitionJournal,
    withAcquisitionJournalPhase,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withLifecycleCursor,
    withTeardownLifecycleCursor,
    withProductionLifecycleProfile,
    withRecoveredProductionLifecycleProfile,
    withProductionRoot,
 )
import HostBootstrap.Lifecycle.Session hiding (
    AcquisitionJournal,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    acquisitionJournalRunLease,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalStableScope,
    LifecycleError,
    LifecycleCursor,
    lifecycleErrorMessage,
    lifecycleCursorFrame,
    lifecycleCursorPhase,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    withAcquisitionJournalPhase,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withLifecycleCursor,
    withTeardownLifecycleCursor,
 )
import HostBootstrap.Lifecycle.Session.Testing
import HostBootstrap.Reconcile (
    lifecyclePlanFromProjectPlan,
    lifecyclePlanSnapshot,
    stepExecutionFor,
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    plannedStepIdentity,
    renderSnapshot,
    stablePlanSnapshotDigest,
 )
import HostBootstrap.ProjectPlan.Construct (
    finalizedProjectCodec,
    projectPlanDrafts,
    withFinalizedProjectSpec,
    withProjectPlan,
    withRecoveredProductionProjectPlan,
    withRecoveredProductionProjectPlanInputs,
 )
import HostBootstrap.ProjectPlan.Snapshot (
    BoundPlanSnapshot,
    PlanDigestBinding,
    withBoundPlanSnapshot,
    withFreshBoundPlanSnapshot,
 )
import HostBootstrap.ProjectPlan.Frame (
    ProjectFrame,
    withCurrentFrame,
 )
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Service (emptyServiceRegistry)
import HostBootstrap.Step (
    Step,
    StepFrame (..),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    contextInitStep,
    mkStepPlan,
    stepIdentity,
 )
import HostBootstrap.Substrate (
    Arch (Arm64),
    Substrate (..),
    SubstrateName (LinuxCpu),
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError (ProtectedInvalid),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    openProtectedStore,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    protectedStoreRoot,
    readProtectedRecord,
    recordVersionWord,
    recordKeyText,
    sessionStoreRoot,
    withProtectedEntry,
 )
import qualified Fixture
import System.Directory (
    copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removePathForcibly,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitSuccess, exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

plan :: Text
plan = "plan-digest-1"

planKeyDigest :: Text
planKeyDigest = sha256HexTest (TextEncoding.encodeUtf8 plan)

-- ---------------------------------------------------------------------------
-- The out-of-process delayed-permit competitor

{- | A competitor process that takes the plan's generation token, releases the
store, and then presents that now-possibly-delayed token.

The two entries are what make this a *real* generation boundary rather than a
simulated one: the token is acquired in the first entry, the store is free while
another process crosses the boundary, and the token is presented in the second.
Nothing is retained across the gap except the 'FenceEpoch' itself, which is the
generation token the protocol is about.

Its only report is its own outcome. Exit 0 when the delayed token was accepted
(the fence it prepared under is written to @reasonPath@), 3 when it was refused
as superseded (@presented \\t live@), 4 otherwise.

@mode@ selects which delayed presentation is made:

* @prepare@ — present the token to the prepare compare-and-swap;
* @reestablish@ — re-run the initial-fence protocol with a *different* proposed
  epoch, which must be deduplicated to the observed one rather than proposing a
  second generation.
-}
runFenceDelayProbe :: FilePath -> String -> FilePath -> FilePath -> FilePath -> IO ()
runFenceDelayProbe storeRoot mode readyPath goPath reasonPath = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left _ -> exitWith (ExitFailure 4)
        Right store -> do
            -- Entry one: take the generation token, then leave the store free.
            taken <- inEntry store (\s -> establishInitialFence s plan 1)
            case taken of
                Left failure -> failProbe (sessionErrorMessage failure)
                Right fence -> do
                    writeFile readyPath (show (fenceEpochWord fence))
                    awaitFile goPath
                    -- Entry two: present it, on the far side of the boundary.
                    presented <- inEntry store (present fence)
                    case presented of
                        Right used -> do
                            writeFile reasonPath (show used)
                            exitSuccess
                        Left (SessionFenceSuperseded stale live) -> do
                            writeFile reasonPath (show stale <> "\t" <> show live)
                            exitWith (ExitFailure 3)
                        Left failure -> failProbe (sessionErrorMessage failure)
  where
    failProbe detail = writeFile reasonPath detail >> exitWith (ExitFailure 4)

    present ::
        FenceEpoch scope planId ->
        ProtectedSession session ->
        IO (Either SessionError Word64)
    present fence s = case mode of
        "reestablish" ->
            -- A delayed initial-fence proposal must be deduplicated to the
            -- observed epoch, not turned into a second generation.
            fmap (fmap fenceEpochWord) (establishInitialFence s plan 5)
        "prepare" -> withProbeEpoch s $ \epoch -> do
            journal <- openProjectJournal s plan
            case journal of
                Left failure -> pure (Left failure)
                Right permit -> do
                    opened <- openOperationSession s epoch plan "probe-session" permit
                    case opened of
                        Left failure -> pure (Left failure)
                        Right (sess, afterOpen) -> do
                            registered <-
                                registerOperationIntent s sess "op-1" NoHistory afterOpen
                            case registered of
                                Left failure -> pure (Left failure)
                                Right afterIntent ->
                                    withPreparedGate
                                        s
                                        sess
                                        epoch
                                        fence
                                        "op-1"
                                        "EffectOutcomeUnknown"
                                        afterIntent
                                        (\gate _ -> pure (Right (preparedGateFence gate)))
        other -> pure (Left (SessionFenceInvalid (Text.pack ("unknown probe mode " <> other))))

-- | The probe uses the same composite broker opener as every other session case.
withProbeEpoch ::
    ProtectedSession session ->
    (forall brokerGeneration. BrokerEpoch brokerGeneration -> IO (Either SessionError result)) ->
    IO (Either SessionError result)
withProbeEpoch = withEpoch

awaitFile :: FilePath -> IO ()
awaitFile path = do
    present <- doesFileExist path
    if present then pure () else threadDelay 5000 >> awaitFile path

{- | What the competitor process observed when it presented its delayed token.
'FenceRefused' carries the (presented, live) pair the competitor was told, so a
refusal cannot be confused with any other exit.
-}
data FenceProbe
    = FenceAccepted Word64
    | FenceRefused Word64 Word64
    | FenceProbeFailed String
    deriving (Eq, Show)

{- | Run the competitor and cross the generation boundary between its two
entries. @betweenEntries@ runs while the competitor holds no entry, so the
rotation it performs is an ordinary protected transaction rather than a
contention with the probe.
-}
withFenceDelayProbe :: FilePath -> FilePath -> String -> IO () -> IO FenceProbe
withFenceDelayProbe executable storeRoot mode betweenEntries =
    withSystemTempDirectory "hostbootstrap-fence-probe" $ \directory -> do
        let readyPath = directory </> "ready"
            goPath = directory </> "go"
            reasonPath = directory </> "reason"
        finished <- newEmptyMVar
        _ <-
            forkFinally
                ( readProcessWithExitCode
                    executable
                    ["--hostbootstrap-fence-delay-probe", storeRoot, mode, readyPath, goPath, reasonPath]
                    ""
                )
                (putMVar finished)
        awaitFile readyPath
        betweenEntries
        writeFile goPath "go"
        completed <- takeMVar finished
        case (completed :: Either SomeException (ExitCode, String, String)) of
            Left err -> pure (FenceProbeFailed (show err))
            Right (code, out, err) -> do
                reason <- readReasonIfPresent reasonPath
                pure $ case (code, words (map tabToSpace reason)) of
                    (ExitSuccess, [used]) -> maybe (FenceProbeFailed reason) FenceAccepted (readWord64 used)
                    (ExitFailure 3, [stale, live]) ->
                        case (readWord64 stale, readWord64 live) of
                            (Just s, Just l) -> FenceRefused s l
                            _ -> FenceProbeFailed reason
                    _ -> FenceProbeFailed (show code <> " " <> reason <> " " <> out <> " " <> err)
  where
    tabToSpace '\t' = ' '
    tabToSpace c = c

readWord64 :: String -> Maybe Word64
readWord64 raw = case reads raw of
    [(value, "")] -> Just value
    _ -> Nothing

readReasonIfPresent :: FilePath -> IO String
readReasonIfPresent path = do
    present <- doesFileExist path
    if present then readFile path else pure ""

tests :: TestTree
tests =
    testGroup
        "SessionSpec"
        [ testGroup "plan-bound acquisition journal" acquisitionJournalTests
        , testGroup "same-broker lifecycle cursor" lifecycleCursorTests
        , testGroup "the project journal" journalTests
        , testGroup "fence rotation" fenceTests
        , testGroup "phase classification" classificationTests
        , testGroup "the prepare compare-and-swap" prepareTests
        , testGroup "recovery" recoveryTests
        , testGroup "abandoned-run admission" admissionTests
        , testGroup "transaction recovery" transactionRecoveryTests
        ]

-- ---------------------------------------------------------------------------
-- Plan-bound acquisition journal

data AcquisitionEvidence = AcquisitionEvidence
    { evidenceScope :: Text
    , evidenceSnapshot :: Text
    , evidenceRun :: Text
    , evidenceBroker :: Word64
    , evidenceVersion :: Word64
    , evidenceVerb :: Text
    , evidencePhase :: Text
    }
    deriving (Eq, Show)

acquisitionJournalTests :: [TestTree]
acquisitionJournalTests =
    [ testCase "reverse-root source records force hidden admission on partial application" $ do
        forced <-
            try @SomeException
                (evaluate (withReverseRootSourceRecordsKernel (error "forced reverse-root admission")))
        case forced of
            Left _ -> pure ()
            Right _ -> assertFailure "the reverse-root source eliminator accepted a bottom admission"
    , testCase "reverse acquisition reopen forces hidden admission before every recovery input" $ do
        forced <-
            try @SomeException
                ( reopenExistingReverseAcquisitionJournalKernel
                    (error "forced reverse acquisition admission")
                    (error "store evaluated before admission")
                    (error "session evaluated before admission")
                    (\_ _ _ -> error "validator evaluated before admission")
                    "scope"
                    "project"
                    "store"
                    "snapshot"
                    "run"
                    "spec"
                    1
                    (error "frame evaluated before admission")
                    Authority.ProjectUp
                )
        case forced of
            Left _ -> pure ()
            Right _ -> assertFailure "the reverse acquisition opener accepted a bottom admission"
    , testCase "fresh admission persists the exact Prepare binding after releasing the lock" $
        withAcquisitionPlanFixture $ \store project root lease bound binding projectPlan _projectRoot -> do
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> ".production")
            leaseRecord <- readRequiredRecord store leaseKey
            opened <-
                withAcquisitionJournal root lease bound binding projectPlan $ \journal -> do
                    -- Re-entry would be rejected if the opener still held the
                    -- protected store lock while running user code.
                    reentered <- withProtectedEntry store (\_ -> pure (Right ()))
                    case reentered of
                        Left failure -> assertFailure (show failure)
                        Right () -> pure ()
                    pure (journalEvidence journal)
            evidence <- expect opened
            (key, record) <- soleRecordWithPrefix store "acquisition."
            decodeFields (protectedRecordBytes record)
                @?= [ "acquisition-journal-v1"
                    , "production"
                    , installedProjectName project
                    , protectedStoreIdentityText (protectedStoreIdentity store)
                    , boundRunLeasePlanDigest lease
                    , recordKeyText leaseKey
                    , Text.pack (show (recordVersionWord (protectedRecordVersion leaseRecord)))
                    , boundRunLeaseRunText lease
                    , boundRunLeaseSpecDigest lease
                    , boundRunLeasePlanDigest lease
                    , Text.pack (show (brokerEpochWord (rootAuthorityEpoch root)))
                    , "up"
                    , "prepare"
                    ]
            recordKeyText key
                @?= "acquisition."
                    <> installedProjectName project
                    <> ".production."
                    <> Text.pack (show (brokerEpochWord (rootAuthorityEpoch root)))
            evidence
                @?= AcquisitionEvidence
                    "production"
                    (boundRunLeasePlanDigest lease)
                    "production"
                    (brokerEpochWord (rootAuthorityEpoch root))
                    (recordVersionWord (protectedRecordVersion record))
                    "up"
                    "prepare"
    , testCase "an exact retry observes the same version without writing" $
        withAcquisitionPlanFixture $ \store _project root lease bound binding projectPlan _projectRoot -> do
            first <-
                expect
                    =<< withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (pure . journalEvidence)
            before <- protectedImage store
            second <-
                expect
                    =<< withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (pure . journalEvidence)
            after <- protectedImage store
            second @?= first
            after @?= before
    , testCase "exact Execute and Teardown records resume without normalization writes" $
        withAcquisitionPlanFixture $ \store _project root lease bound binding projectPlan _projectRoot -> do
            _ <-
                expect
                    =<< withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (pure . journalEvidence)
            (key, _) <- soleRecordWithPrefix store "acquisition."
            mapM_
                ( \phase -> do
                    version <- rewriteRecordFields store key (replaceField 12 phase)
                    before <- protectedImage store
                    resumed <-
                        expect
                            =<< withAcquisitionJournal
                                root
                                lease
                                bound
                                binding
                                projectPlan
                                (pure . journalEvidence)
                    evidencePhase resumed @?= phase
                    evidenceVersion resumed @?= version
                    after <- protectedImage store
                    after @?= before
                )
                ["execute", "teardown"]
    , testCase "recovered Production reconstructs a fresh plan identity and resumes the same record" $
        withAcquisitionPlanFixture $ \store project root lease bound binding projectPlan projectRoot -> do
            first <-
                expect
                    =<< withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (pure . journalEvidence)
            reopened <- reopenStore store
            before <- protectedImage reopened
            recovered <-
                resumeRecoveredAcquisition
                    reopened
                    project
                    projectRoot
                    (pure . journalEvidence)
            after <- protectedImage reopened
            recovered @?= first
            after @?= before
    , testCase "retained-evidence origin drift refuses before opening a record" $
        withAcquisitionPlanFixture $ \store _project root lease bound binding projectPlan _projectRoot ->
            withAcquisitionPlanFixtureFor acquisitionDriftStepPlan $ \otherStore _otherProject otherRoot otherLease otherBound otherBinding otherPlan _otherRootPath -> do
                callbacks <- newIORef 0
                let refuse targetStore label action = do
                        assertLifecycleRefusalNoMutation targetStore callbacks action
                        image <- protectedImage targetStore
                        assertBool
                            (label <> " unexpectedly opened an acquisition record")
                            (Map.null (Map.filterWithKey (\key _ -> "acquisition." `Text.isPrefixOf` key) image))
                    callback = countingCallback callbacks
                refuse
                    store
                    "root drift"
                    ( withAcquisitionJournal
                        (unsafeCoerce otherRoot)
                        lease
                        bound
                        binding
                        projectPlan
                        callback
                    )
                refuse
                    otherStore
                    "lease drift"
                    ( withAcquisitionJournal
                        root
                        (unsafeCoerce otherLease)
                        bound
                        binding
                        projectPlan
                        callback
                    )
                refuse
                    store
                    "bound-snapshot drift"
                    ( withAcquisitionJournal
                        root
                        lease
                        (unsafeCoerce otherBound)
                        binding
                        projectPlan
                        callback
                    )
                refuse
                    store
                    "digest-binding drift"
                    ( withAcquisitionJournal
                        root
                        lease
                        bound
                        (unsafeCoerce otherBinding)
                        projectPlan
                        callback
                    )
                refuse
                    store
                    "plan drift"
                    ( withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        (unsafeCoerce otherPlan)
                        callback
                    )
    , testCase "live mode and broker drift refuse without minting authority" $
        withAcquisitionPlanFixture $ \store project root lease bound binding projectPlan _projectRoot -> do
            callbacks <- newIORef (0 :: Int)
            modeKey <- recordKeyFor ("mode." <> installedProjectName project)
            canonical <- protectedRecordBytes <$> readRequiredRecord store modeKey
            let epoch = brokerEpochWord (rootAuthorityEpoch root)
                mutations =
                    [ encodeFields ["harness", Text.pack (show epoch), "other-run"]
                    , encodeFields ["production", Text.pack (show (epoch + 1))]
                    ]
            mapM_
                ( \payload -> do
                    _ <- rewriteRecordBytes store modeKey (const payload)
                    assertLifecycleRefusalNoMutation store callbacks $
                        withAcquisitionJournal
                            root
                            lease
                            bound
                            binding
                            projectPlan
                            (countingCallback callbacks)
                    image <- protectedImage store
                    assertBool
                        "mode/broker drift opened an acquisition record"
                        (Map.null (Map.filterWithKey (\key _ -> "acquisition." `Text.isPrefixOf` key) image))
                    _ <- rewriteRecordBytes store modeKey (const canonical)
                    pure ()
                )
                mutations
    , testCase "a same-content lease CAS invalidates retained bound-lease evidence" $
        withAcquisitionPlanFixture $ \store project root lease bound binding projectPlan _projectRoot -> do
            callbacks <- newIORef 0
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> ".production")
            _ <- rewriteRecordBytes store leaseKey id
            assertLifecycleRefusalNoMutation store callbacks $
                withAcquisitionJournal
                    root
                    lease
                    bound
                    binding
                    projectPlan
                    (countingCallback callbacks)
            image <- protectedImage store
            assertBool
                "the stale lease opened an acquisition record"
                (Map.null (Map.filterWithKey (\key _ -> "acquisition." `Text.isPrefixOf` key) image))
    , testCase "a live snapshot from another exact plan refuses without opening a record" $
        withAcquisitionPlanFixture $ \store project root lease bound binding projectPlan _projectRoot ->
            withAcquisitionPlanFixtureFor acquisitionDriftStepPlan $ \otherStore otherProject _otherRoot _otherLease _otherBound _otherBinding _otherPlan _otherProjectRoot -> do
                callbacks <- newIORef 0
                snapshotKey <- recordKeyFor ("snapshot." <> installedProjectName project <> ".production")
                otherSnapshotKey <- recordKeyFor ("snapshot." <> installedProjectName otherProject <> ".production")
                otherSnapshot <- readRequiredRecord otherStore otherSnapshotKey
                _ <- rewriteRecordBytes store snapshotKey (const (protectedRecordBytes otherSnapshot))
                assertLifecycleRefusalNoMutation store callbacks $
                    withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (countingCallback callbacks)
                image <- protectedImage store
                assertBool
                    "snapshot drift opened an acquisition record"
                    (Map.null (Map.filterWithKey (\key _ -> "acquisition." `Text.isPrefixOf` key) image))
    , testCase "recovered current-version evidence still rejects noncanonical live lease bytes" $
        withAcquisitionPlanFixture $ \store project _root _lease _bound _binding _projectPlan projectRoot -> do
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> ".production")
            leaseRecord <- readRequiredRecord store leaseKey
            let fields = decodeFields (protectedRecordBytes leaseRecord)
            _ <-
                rewriteRecordFields
                    store
                    leaseKey
                    (replaceField 1 ("0" <> fields !! 1))
            reopened <- reopenStore store
            callbacks <- newIORef 0
            assertLifecycleRefusalNoMutation reopened callbacks $
                attemptRecoveredAcquisition
                    reopened
                    project
                    projectRoot
                    (countingCallback callbacks)
            image <- protectedImage reopened
            assertBool
                "the noncanonical lease opened an acquisition record"
                (Map.null (Map.filterWithKey (\key _ -> "acquisition." `Text.isPrefixOf` key) image))
    , testCase "key-excluded immutable binding drift collides and is never rewritten" $
        withAcquisitionPlanFixture $ \store project root lease bound binding projectPlan _projectRoot -> do
            _ <-
                expect
                    =<< withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (pure . journalEvidence)
            callbacks <- newIORef 0
            (key, canonicalRecord) <- soleRecordWithPrefix store "acquisition."
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> ".production")
            leaseRecord <- readRequiredRecord store leaseKey
            let canonical = protectedRecordBytes canonicalRecord
                differentPlan = "different-plan-digest"
                mutations =
                    [ ("stable scope", replaceField 1 "production-drift")
                    , ( "lease version"
                      , replaceField
                            6
                            (Text.pack (show (recordVersionWord (protectedRecordVersion leaseRecord) + 1)))
                      )
                    , ("specification digest", replaceField 8 "different-spec-digest")
                    , ( "snapshot and lease-plan digest"
                      , replaceField 9 differentPlan . replaceField 4 differentPlan
                      )
                    , ("recognized root verb", replaceField 11 "down")
                    ]
            mapM_
                ( \(label, mutate) -> do
                    _ <- rewriteRecordFields store key mutate
                    assertLifecycleRefusalNoMutation store callbacks $
                        withAcquisitionJournal
                            root
                            lease
                            bound
                            binding
                            projectPlan
                            (countingCallback callbacks)
                    (sameKey, retained) <- soleRecordWithPrefix store "acquisition."
                    recordKeyText sameKey @?= recordKeyText key
                    assertBool
                        (label <> " mutation was unexpectedly normalized")
                        (protectedRecordBytes retained /= canonical)
                    _ <- rewriteRecordBytes store key (const canonical)
                    pure ()
                )
                mutations
    , testCase "malformed, noncanonical, or extended records refuse without normalization" $
        withAcquisitionPlanFixture $ \store _project root lease bound binding projectPlan _projectRoot -> do
            _ <-
                expect
                    =<< withAcquisitionJournal
                        root
                        lease
                        bound
                        binding
                        projectPlan
                        (pure . journalEvidence)
            callbacks <- newIORef 0
            (key, canonicalRecord) <- soleRecordWithPrefix store "acquisition."
            let canonical = protectedRecordBytes canonicalRecord
                fields = decodeFields canonical
                leadingZero index = replaceField index ("0" <> fields !! index) fields
                mutations =
                    [ ("malformed", encodeFields ["malformed"])
                    , ("schema", encodeFields (replaceField 0 "future-schema" fields))
                    , ("verb", encodeFields (replaceField 11 "sideways" fields))
                    , ("phase", encodeFields (replaceField 12 "future-phase" fields))
                    , ("extra field", encodeFields (fields <> ["extra"]))
                    , ("zero lease version", encodeFields (replaceField 6 "0" fields))
                    , ("zero broker epoch", encodeFields (replaceField 10 "0" fields))
                    , ("noncanonical lease version", encodeFields (leadingZero 6))
                    , ("noncanonical broker epoch", encodeFields (leadingZero 10))
                    ]
            mapM_
                ( \(label, payload) -> do
                    _ <- rewriteRecordBytes store key (const payload)
                    assertLifecycleRefusalNoMutation store callbacks $
                        withAcquisitionJournal
                            root
                            lease
                            bound
                            binding
                            projectPlan
                            (countingCallback callbacks)
                    retained <- protectedRecordBytes <$> readRequiredRecord store key
                    retained @?= payload
                    assertBool (label <> " mutation was unexpectedly accepted") (retained /= canonical)
                    _ <- rewriteRecordBytes store key (const canonical)
                    pure ()
                )
                mutations
    ]

data CursorEvidence = CursorEvidence
    { cursorEvidenceFrame :: Text
    , cursorEvidenceVersion :: Word64
    , cursorEvidenceVerb :: Text
    , cursorEvidencePhase :: Text
    }
    deriving (Eq, Show)

cursorEvidence ::
    LifecycleCursor scope planId frame brokerGeneration verb phase ->
    CursorEvidence
cursorEvidence cursor =
    CursorEvidence
        { cursorEvidenceFrame = lifecycleCursorFrame cursor
        , cursorEvidenceVersion = lifecycleCursorRecordVersion cursor
        , cursorEvidenceVerb = Authority.projectVerbName (lifecycleCursorVerb cursor)
        , cursorEvidencePhase = lifecyclePhaseName (lifecycleCursorPhase cursor)
        }

exerciseReverseLifecycleCursor :: Authority.ProjectVerb verb -> IO ()
exerciseReverseLifecycleCursor verb =
    withLifecycleCursorFixtureForVerb verb $ \store root lease bound binding projectPlan journal frame -> do
        sourceBefore <- snd <$> soleRecordWithPrefix store "acquisition."
        executed <-
            withLifecycleCursor journal frame verb Authority.Prepare $ \prepareCursor -> do
                withExecuteLifecycleCursor prepareCursor $ \executeCursor -> do
                    assertProtectedReentry store
                    pure (cursorEvidence prepareCursor, cursorEvidence executeCursor)
        (prepareEvidence, executeEvidence) <- expect =<< expect executed
        let expectedVerb = Authority.projectVerbName verb
        mapM_
            ((@?= expectedVerb) . cursorEvidenceVerb)
            [prepareEvidence, executeEvidence]
        map cursorEvidencePhase [prepareEvidence, executeEvidence]
            @?= ["prepare", "execute"]
        cursorEvidenceVersion executeEvidence @?= cursorEvidenceVersion prepareEvidence + 1
        sourceAfterExecute <- snd <$> soleRecordWithPrefix store "acquisition."
        sourceAfterExecute @?= sourceBefore
        beforeExecuteResume <- protectedImage store
        tornDown <-
            withAcquisitionJournal root lease bound binding projectPlan $ \resumedJournal -> do
                withAcquisitionJournalPhase resumedJournal lifecyclePhaseName @?= "prepare"
                withCurrentLifecycleCursor
                    resumedJournal
                    frame
                    verb
                    ( \phase cursor -> case phase of
                        Authority.Prepare -> assertFailure "reverse cursor resumed at Prepare"
                        Authority.Execute ->
                            withTeardownLifecycleCursor
                                cursor
                                ( \teardownCursor -> do
                                    assertProtectedReentry store
                                    pure (cursorEvidence teardownCursor)
                                )
                                >>= expect
                        Authority.Teardown -> assertFailure "reverse cursor skipped Execute"
                    )
                    >>= expect
        teardownEvidence <- expect tornDown
        cursorEvidenceVerb teardownEvidence @?= expectedVerb
        cursorEvidencePhase teardownEvidence @?= "teardown"
        cursorEvidenceVersion teardownEvidence @?= cursorEvidenceVersion executeEvidence + 1
        sourceAfterTeardown <- snd <$> soleRecordWithPrefix store "acquisition."
        sourceAfterTeardown @?= sourceBefore
        afterExecuteResume <- protectedImage store
        assertBool
            "the Execute resume did not persist its Teardown successor"
            (afterExecuteResume /= beforeExecuteResume)
        beforeTeardownResume <- protectedImage store
        resumed <-
            withAcquisitionJournal root lease bound binding projectPlan $ \resumedJournal -> do
                withAcquisitionJournalPhase resumedJournal lifecyclePhaseName @?= "prepare"
                withCurrentLifecycleCursor
                    resumedJournal
                    frame
                    verb
                    ( \phase cursor -> do
                        assertProtectedReentry store
                        pure (lifecyclePhaseName phase, cursorEvidence cursor)
                    )
                    >>= expect
        recovered <- expect resumed
        afterTeardownResume <- protectedImage store
        recovered @?= ("teardown", teardownEvidence)
        afterTeardownResume @?= beforeTeardownResume

lifecycleCursorTests :: [TestTree]
lifecycleCursorTests =
    [ testCase "fresh admission atomically hands the acquisition seed to one exact frame" $
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            (sourceKey, sourceBefore) <- soleRecordWithPrefix store "acquisition."
            opened <-
                withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \cursor -> do
                    assertProtectedReentry store
                    pure (cursorEvidence cursor)
            evidence <- expect opened
            (cursorKey, cursorRecord) <- soleRecordWithPrefix store "cursor."
            let keyText = recordKeyText cursorKey
                keyDigest = Text.drop (Text.length "cursor.") keyText
                independentlyDerivedKey =
                    "cursor."
                        <> sha256HexTest
                            ( encodeCursorFields
                                [ TextEncoding.encodeUtf8 "lifecycle-cursor-key-v1"
                                , TextEncoding.encodeUtf8 (recordKeyText sourceKey)
                                , TextEncoding.encodeUtf8 "host-orchestrator-0"
                                ]
                            )
            assertBool "cursor key did not carry one SHA-256 digest" $
                Text.length keyDigest == 64
                    && Text.all (`elem` ("0123456789abcdef" :: String)) keyDigest
            keyText @?= independentlyDerivedKey
            cursorFields <- expectCursorFields (protectedRecordBytes cursorRecord)
            cursorFields
                @?= [ TextEncoding.encodeUtf8 "lifecycle-cursor-v1"
                    , TextEncoding.encodeUtf8 (recordKeyText sourceKey)
                    , TextEncoding.encodeUtf8
                        (Text.pack (show (recordVersionWord (protectedRecordVersion sourceBefore))))
                    , protectedRecordBytes sourceBefore
                    , TextEncoding.encodeUtf8 "host-orchestrator-0"
                    , TextEncoding.encodeUtf8 "up"
                    , TextEncoding.encodeUtf8 "prepare"
                    ]
            sourceAfter <- readRequiredRecord store sourceKey
            sourceAfter @?= sourceBefore
            evidence
                @?= CursorEvidence
                    "host-orchestrator-0"
                    (recordVersionWord (protectedRecordVersion cursorRecord))
                    "up"
                    "prepare"
    , testCase "a canonical non-Prepare acquisition seed starts the absent cursor at that phase" $
        withLifecycleCursorFixture $ \store root lease bound binding projectPlan journal frame -> do
            (sourceKey, _) <- soleRecordWithPrefix store "acquisition."
            _ <- rewriteRecordFields store sourceKey (replaceField 12 "execute")
            sourceBeforeCursor <- readRequiredRecord store sourceKey
            reopened <-
                withAcquisitionJournal root lease bound binding projectPlan $ \executeJournal -> do
                    withAcquisitionJournalPhase executeJournal lifecyclePhaseName @?= "execute"
                    callbacks <- newIORef 0
                    assertLifecycleRefusalNoMutation store callbacks $
                        withLifecycleCursor
                            executeJournal
                            frame
                            Authority.ProjectUp
                            Authority.Prepare
                            (countingCallback callbacks)
                    seeded <-
                        expect
                            =<< withLifecycleCursor
                                executeJournal
                                frame
                                Authority.ProjectUp
                                Authority.Execute
                                (pure . cursorEvidence)
                    readIORef callbacks >>= (@?= 0)
                    pure seeded
            evidence <- expect reopened
            sourceAfterCursor <- readRequiredRecord store sourceKey
            sourceAfterCursor @?= sourceBeforeCursor
            cursorEvidencePhase evidence @?= "execute"
            cursorEvidenceVersion evidence @?= 1
            withAcquisitionJournalPhase journal lifecyclePhaseName @?= "prepare"
    , testCase "wrong verb and absent-seed phase refuse without writing a cursor" $
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            callbacks <- newIORef 0
            before <- protectedImage store
            assertLifecycleRefusalNoMutation store callbacks $
                withLifecycleCursor
                    journal
                    frame
                    Authority.ProjectDown
                    Authority.Prepare
                    (countingCallback callbacks)
            assertLifecycleRefusalNoMutation store callbacks $
                withLifecycleCursor
                    journal
                    frame
                    Authority.ProjectUp
                    Authority.Execute
                    (countingCallback callbacks)
            after <- protectedImage store
            after @?= before
            assertBool
                "a refused expected phase created a cursor row"
                (Map.null (Map.filterWithKey (\key _ -> "cursor." `Text.isPrefixOf` key) after))
            recovered <-
                expect
                    =<< withCurrentLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        (\phase cursor -> pure (lifecyclePhaseName phase, cursorEvidence cursor))
            fst recovered @?= "prepare"
    , testCase "a 4097-byte frame refuses before cursor store I/O" $
        withLifecycleCursorFixtureAt (Text.replicate 4097 "x") $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            callbacks <- newIORef 0
            before <- protectedImage store
            assertLifecycleRefusalNoMutation store callbacks $
                withLifecycleCursor
                    journal
                    frame
                    Authority.ProjectUp
                    Authority.Prepare
                    (countingCallback callbacks)
            after <- protectedImage store
            after @?= before
            assertBool
                "an oversized frame opened a cursor row"
                (Map.null (Map.filterWithKey (\key _ -> "cursor." `Text.isPrefixOf` key) after))
    , testCase "exact expected and discovered current-phase retries are no-write redeliveries" $
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            callbacks <- newIORef (0 :: Int)
            first <-
                expect
                    =<< withLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        Authority.Prepare
                        (\cursor -> modifyIORef' callbacks (+ 1) >> pure (cursorEvidence cursor))
            before <- protectedImage store
            second <-
                expect
                    =<< withLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        Authority.Prepare
                        (\cursor -> modifyIORef' callbacks (+ 1) >> pure (cursorEvidence cursor))
            discovered <-
                expect
                    =<< withCurrentLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        ( \phase cursor -> do
                            modifyIORef' callbacks (+ 1)
                            pure (lifecyclePhaseName phase, cursorEvidence cursor)
                        )
            after <- protectedImage store
            second @?= first
            discovered @?= ("prepare", first)
            after @?= before
            readIORef callbacks >>= (@?= 3)
    , testCase "legal successors are read back before unlocked delivery and acquisition stays the seed" $
        withLifecycleCursorFixture $ \store root lease bound binding projectPlan journal frame -> do
            sourceSeed <- pure (withAcquisitionJournalPhase journal lifecyclePhaseName)
            sourceBefore <- snd <$> soleRecordWithPrefix store "acquisition."
            transitioned <-
                withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                    executed <-
                        withExecuteLifecycleCursor prepareCursor $ \executeCursor -> do
                            assertProtectedReentry store
                            tornDown <-
                                withTeardownLifecycleCursor executeCursor $ \teardownCursor -> do
                                    assertProtectedReentry store
                                    pure
                                        ( cursorEvidence prepareCursor
                                        , cursorEvidence executeCursor
                                        , cursorEvidence teardownCursor
                                        )
                            expect tornDown
                    expect executed
            (prepareEvidence, executeEvidence, teardownEvidence) <- expect transitioned
            cursorEvidencePhase prepareEvidence @?= "prepare"
            cursorEvidencePhase executeEvidence @?= "execute"
            cursorEvidencePhase teardownEvidence @?= "teardown"
            cursorEvidenceVersion executeEvidence @?= cursorEvidenceVersion prepareEvidence + 1
            cursorEvidenceVersion teardownEvidence @?= cursorEvidenceVersion executeEvidence + 1
            sourceSeed @?= "prepare"
            sourceAfter <- snd <$> soleRecordWithPrefix store "acquisition."
            sourceAfter @?= sourceBefore
            reopened <-
                withAcquisitionJournal root lease bound binding projectPlan $ \reopenedJournal -> do
                    withAcquisitionJournalPhase reopenedJournal lifecyclePhaseName @?= "prepare"
                    withCurrentLifecycleCursor
                        reopenedJournal
                        frame
                        Authority.ProjectUp
                        (\phase cursor -> pure (lifecyclePhaseName phase, cursorEvidence cursor))
                        >>= expect
            (recoveredPhase, recoveredEvidence) <- expect reopened
            recoveredPhase @?= "teardown"
            recoveredEvidence @?= teardownEvidence
    , testCase "Down and Destroy cursor foundations advance only Prepare to Execute to Teardown" $ do
        exerciseReverseLifecycleCursor Authority.ProjectDown
        exerciseReverseLifecycleCursor Authority.ProjectDestroy
    , testCase "a physical reopen reconstructs a fresh plan/frame and resumes the same cursor without writing" $
        withAcquisitionPlanFixtureFor cursorStepPlan $ \store project root lease bound binding projectPlan projectRoot -> do
            let supplied =
                    Fixture.context
                        ( Fixture.defaultProjectConfig
                            (installedProjectName project)
                            (Text.pack (canonicalProjectRootPath projectRoot))
                            Context.HostOrchestrator
                        )
            initialAction <-
                either (fail . show) pure $
                    withCurrentFrame projectPlan supplied $ \_current frame _validated ->
                        withAcquisitionJournal root lease bound binding projectPlan $ \journal -> do
                            opened <-
                                withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor ->
                                    withExecuteLifecycleCursor prepareCursor (pure . cursorEvidence) >>= expect
                            expect opened
            initial <- initialAction >>= expect
            cursorEvidencePhase initial @?= "execute"

            reopened <- reopenStore store
            before <- protectedImage reopened
            recovered <-
                resumeRecoveredAcquisitionFor
                    cursorStepPlan
                    reopened
                    project
                    projectRoot
                    ( \recoveredPlan recoveredJournal -> do
                        let recoveredSupplied =
                                Fixture.context
                                    ( Fixture.defaultProjectConfig
                                        (installedProjectName project)
                                        (Text.pack (canonicalProjectRootPath projectRoot))
                                        Context.HostOrchestrator
                                    )
                        currentAction <-
                            either (fail . show) pure $
                                withCurrentFrame recoveredPlan recoveredSupplied $ \_current recoveredFrame _validated ->
                                    withCurrentLifecycleCursor
                                        recoveredJournal
                                        recoveredFrame
                                        Authority.ProjectUp
                                        (\_phase cursor -> pure (cursorEvidence cursor))
                        currentAction >>= expect
                    )
            after <- protectedImage reopened
            recovered @?= initial
            after @?= before
    , testCase "delimiter/Unicode frame ids round-trip and distinct frame rows advance independently" $ do
        let firstFrameId = "host:orchestrator/α-雪\nframe"
            secondFrameId = "host:orchestrator/β-雪\nframe"
        withLifecycleCursorFixtureAt firstFrameId $ \store _root _lease _bound _binding _projectPlan journal firstFrame -> do
            firstExecute <-
                expect
                    =<< withLifecycleCursor
                        journal
                        firstFrame
                        Authority.ProjectUp
                        Authority.Prepare
                        (\prepareCursor -> withExecuteLifecycleCursor prepareCursor (pure . cursorEvidence) >>= expect)
            cursorEvidenceFrame firstExecute @?= firstFrameId
            cursorEvidencePhase firstExecute @?= "execute"

            -- A public caller cannot mix frame evidence across plan identities.
            -- This type-erased adversarial seam deliberately does so to exercise
            -- the durable key codec with a second semantic frame in one source
            -- lineage; the compile-fail suite protects the public boundary.
            withLifecycleCursorFixtureAt secondFrameId $ \_otherStore _otherRoot _otherLease _otherBound _otherBinding _otherPlan _otherJournal secondFrame -> do
                let secondFrameForFirstPlan = unsafeCoerce secondFrame
                secondPrepare <-
                    expect
                        =<< withLifecycleCursor
                            journal
                            secondFrameForFirstPlan
                            Authority.ProjectUp
                            Authority.Prepare
                            (pure . cursorEvidence)
                cursorEvidenceFrame secondPrepare @?= secondFrameId
                cursorEvidencePhase secondPrepare @?= "prepare"

                imageWithTwoFrames <- protectedImage store
                Map.size
                    (Map.filterWithKey (\key _ -> "cursor." `Text.isPrefixOf` key) imageWithTwoFrames)
                    @?= 2
                firstCurrent <-
                    expect
                        =<< withCurrentLifecycleCursor
                            journal
                            firstFrame
                            Authority.ProjectUp
                            (\phase _cursor -> pure (lifecyclePhaseName phase))
                secondCurrent <-
                    expect
                        =<< withCurrentLifecycleCursor
                            journal
                            secondFrameForFirstPlan
                            Authority.ProjectUp
                            (\phase _cursor -> pure (lifecyclePhaseName phase))
                (firstCurrent, secondCurrent) @?= ("execute", "prepare")

                firstTeardown <-
                    expect
                        =<< withLifecycleCursor
                            journal
                            firstFrame
                            Authority.ProjectUp
                            Authority.Execute
                            (\executeCursor -> withTeardownLifecycleCursor executeCursor (pure . cursorEvidence) >>= expect)
                secondExecute <-
                    expect
                        =<< withLifecycleCursor
                            journal
                            secondFrameForFirstPlan
                            Authority.ProjectUp
                            Authority.Prepare
                            (\prepareCursor -> withExecuteLifecycleCursor prepareCursor (pure . cursorEvidence) >>= expect)
                (cursorEvidencePhase firstTeardown, cursorEvidencePhase secondExecute)
                    @?= ("teardown", "execute")
                cursorEvidenceFrame firstTeardown @?= firstFrameId
                cursorEvidenceFrame secondExecute @?= secondFrameId
    , testCase "callback exceptions preserve durable initial and successor phases for redelivery" $
        withLifecycleCursorFixture $ \store root lease bound binding projectPlan journal frame -> do
            initialThrown <-
                try @SomeException $
                    withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \_ ->
                        fail "initial cursor callback interruption"
            case initialThrown of
                Left _ -> pure ()
                Right _ -> assertFailure "initial cursor callback unexpectedly returned"
            initialRecovered <-
                expect
                    =<< withCurrentLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        (\phase _ -> pure (lifecyclePhaseName phase))
            initialRecovered @?= "prepare"
            successorThrown <-
                withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor ->
                    try @SomeException $
                        withExecuteLifecycleCursor prepareCursor $ \_ ->
                            fail "execute cursor callback interruption"
            case successorThrown of
                Left failure -> assertFailure (lifecycleErrorMessage failure)
                Right (Left _) -> pure ()
                Right (Right _) -> assertFailure "execute cursor callback unexpectedly returned"
            reopened <-
                withAcquisitionJournal root lease bound binding projectPlan $ \reopenedJournal ->
                    withCurrentLifecycleCursor
                        reopenedJournal
                        frame
                        Authority.ProjectUp
                        (\phase cursor -> pure (lifecyclePhaseName phase, cursorEvidence cursor))
                        >>= expect
            (recoveredPhase, _) <- expect reopened
            recoveredPhase @?= "execute"
            assertProtectedReentry store
    , testCase "two absent-row Prepare openers serialize onto one exact cursor" $
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            readyA <- newEmptyMVar
            readyB <- newEmptyMVar
            startA <- newEmptyMVar
            startB <- newEmptyMVar
            resultA <- newEmptyMVar
            resultB <- newEmptyMVar
            callbacks <- newIORef (0 :: Int)
            let opener ready start = do
                    putMVar ready ()
                    takeMVar start
                    withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \cursor -> do
                        assertProtectedReentry store
                        atomicModifyIORef' callbacks (\count -> (count + 1, ()))
                        pure (cursorEvidence cursor)
            _ <- forkFinally (opener readyA startA) (putMVar resultA)
            _ <- forkFinally (opener readyB startB) (putMVar resultB)
            takeMVar readyA
            takeMVar readyB
            putMVar startA ()
            putMVar startB ()
            results <- sequence [takeMVar resultA, takeMVar resultB]
            case results of
                [Right (Right first), Right (Right second)] -> first @?= second
                _ -> assertFailure ("concurrent cursor openers failed: " <> show results)
            readIORef callbacks >>= (@?= 2)
            (_, cursorRecord) <- soleRecordWithPrefix store "cursor."
            recordVersionWord (protectedRecordVersion cursorRecord) @?= 1
            image <- protectedImage store
            Map.size (Map.filterWithKey (\key _ -> "cursor." `Text.isPrefixOf` key) image) @?= 1
    , testCase "identical current readers redeliver while transition contenders have one CAS winner" $
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                beforeReaders <- protectedImage store
                readerCallbacks <- newIORef (0 :: Int)
                firstReader <- newEmptyMVar
                secondReader <- newEmptyMVar
                let readCurrent =
                        withCurrentLifecycleCursor journal frame Authority.ProjectUp $ \phase _ -> do
                            atomicModifyIORef' readerCallbacks (\count -> (count + 1, ()))
                            pure (lifecyclePhaseName phase)
                _ <- forkFinally readCurrent (putMVar firstReader)
                _ <- forkFinally readCurrent (putMVar secondReader)
                readerResults <- sequence [takeMVar firstReader, takeMVar secondReader]
                case readerResults of
                    [Right (Right firstPhase), Right (Right secondPhase)] ->
                        (firstPhase, secondPhase) @?= ("prepare", "prepare")
                    _ -> assertFailure ("current cursor readers failed: " <> show readerResults)
                readIORef readerCallbacks >>= (@?= 2)
                protectedImage store >>= (@?= beforeReaders)

                transitionCallbacks <- newIORef (0 :: Int)
                firstTransition <- newEmptyMVar
                secondTransition <- newEmptyMVar
                let transition =
                        withExecuteLifecycleCursor prepareCursor $ \cursor -> do
                            atomicModifyIORef' transitionCallbacks (\count -> (count + 1, ()))
                            pure (cursorEvidencePhase (cursorEvidence cursor))
                _ <- forkFinally transition (putMVar firstTransition)
                _ <- forkFinally transition (putMVar secondTransition)
                transitionResults <- sequence [takeMVar firstTransition, takeMVar secondTransition]
                let successes = [phase | Right (Right phase) <- transitionResults]
                    failures = [failure | Right (Left failure) <- transitionResults]
                successes @?= ["execute"]
                case failures of
                    [SessionStaleCursorVersion _ _] -> pure ()
                    _ -> assertFailure ("expected one stale transition, observed " <> show transitionResults)
                readIORef transitionCallbacks >>= (@?= 1)

                replayCallbacks <- newIORef 0
                executeImage <- protectedImage store
                assertLifecycleRefusalNoMutation store replayCallbacks $
                    withLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        Authority.Prepare
                        (countingCallback replayCallbacks)
                resumedExecute <-
                    expect
                        =<< withLifecycleCursor
                            journal
                            frame
                            Authority.ProjectUp
                            Authority.Execute
                            (pure . cursorEvidence)
                cursorEvidencePhase resumedExecute @?= "execute"
                protectedImage store >>= (@?= executeImage)
                assertLifecycleRefusalNoMutation store replayCallbacks $
                    withExecuteLifecycleCursor prepareCursor (countingCallback replayCallbacks)
                withLifecycleCursor
                    journal
                    frame
                    Authority.ProjectUp
                    Authority.Execute
                    ( \executeCursor -> do
                        tornDown <- withTeardownLifecycleCursor executeCursor (pure . cursorEvidence)
                        teardownEvidence <- expect tornDown
                        cursorEvidencePhase teardownEvidence @?= "teardown"
                        assertLifecycleRefusalNoMutation store replayCallbacks $
                            withTeardownLifecycleCursor executeCursor (countingCallback replayCallbacks)
                    )
                    >>= expect
            >>= expect
    , testCase "same-byte source ABA invalidates both reopen and retained-successor authority" $
        withLifecycleCursorFixture $ \store root lease bound binding projectPlan journal frame -> do
            withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                callbacks <- newIORef 0
                (sourceKey, _) <- soleRecordWithPrefix store "acquisition."
                _ <- rewriteRecordBytes store sourceKey id
                afterAba <- protectedImage store
                assertLifecycleRefusalNoMutation store callbacks $
                    withLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        Authority.Prepare
                        (countingCallback callbacks)
                assertLifecycleRefusalNoMutation store callbacks $
                    withExecuteLifecycleCursor prepareCursor (countingCallback callbacks)
                reopened <-
                    withAcquisitionJournal root lease bound binding projectPlan $ \freshJournal ->
                        assertLifecycleRefusalNoMutation store callbacks $
                            withCurrentLifecycleCursor
                                freshJournal
                                frame
                                Authority.ProjectUp
                                (\_phase cursor -> countingCallback callbacks cursor)
                expect reopened
                protectedImage store >>= (@?= afterAba)
            >>= expect
    , testCase "corrupt, colliding, and broker-mismatched cursor payloads never normalize" $
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame -> do
            _ <-
                expect
                    =<< withLifecycleCursor
                        journal
                        frame
                        Authority.ProjectUp
                        Authority.Prepare
                        (pure . cursorEvidence)
            callbacks <- newIORef 0
            (cursorKey, canonicalRecord) <- soleRecordWithPrefix store "cursor."
            cursorFields <- expectCursorFields (protectedRecordBytes canonicalRecord)
            let canonical = protectedRecordBytes canonicalRecord
                sourceFields = decodeFields (cursorFields !! 3)
                replaceCursorField index value =
                    encodeCursorFields (replaceByteField index value cursorFields)
                brokerMismatch =
                    replaceCursorField
                        3
                        (encodeFields (replaceField 10 "2" sourceFields))
                sourceBindingMismatch =
                    replaceCursorField
                        3
                        (encodeFields (replaceField 1 "production-different" sourceFields))
                mutations =
                    [ ("malformed", "malformed")
                    , ("future schema", replaceCursorField 0 "lifecycle-cursor-v2")
                    , ("noncanonical framed length", "0" <> canonical)
                    , ("zero source version", replaceCursorField 2 "0")
                    , ("noncanonical source version", replaceCursorField 2 ("0" <> cursorFields !! 2))
                    , ("different source key", replaceCursorField 1 "acquisition.different")
                    , ("different canonical source binding", sourceBindingMismatch)
                    , ("different frame collision", replaceCursorField 4 "different-frame")
                    , ("invalid UTF-8 frame", replaceCursorField 4 (ByteString.pack [255]))
                    , ("different broker binding", brokerMismatch)
                    , ("different immutable verb", replaceCursorField 5 "down")
                    , ("unknown phase", replaceCursorField 6 "future-phase")
                    , ("extra framed field", canonical <> "0:")
                    , ("truncated framed payload", ByteString.take (ByteString.length canonical - 1) canonical)
                    , ("oversized payload", ByteString.replicate 65537 120)
                    ]
            mapM_
                ( \(label, payload) -> do
                    _ <- rewriteRecordBytes store cursorKey (const payload)
                    before <- protectedImage store
                    assertLifecycleRefusalNoMutation store callbacks $
                        withLifecycleCursor
                            journal
                            frame
                            Authority.ProjectUp
                            Authority.Prepare
                            (countingCallback callbacks)
                    protectedImage store >>= (@?= before)
                    retained <- protectedRecordBytes <$> readRequiredRecord store cursorKey
                    retained @?= payload
                    assertBool (label <> " mutation was unexpectedly accepted") (retained /= canonical)
                    _ <- rewriteRecordBytes store cursorKey (const canonical)
                    pure ()
                )
                mutations
    ]

assertProtectedReentry :: ProtectedStore -> IO ()
assertProtectedReentry store = do
    reentered <- withProtectedEntry store (\_ -> pure (Right ()))
    case reentered of
        Left failure -> assertFailure (show failure)
        Right () -> pure ()

encodeCursorFields :: [ByteString] -> ByteString
encodeCursorFields =
    ByteString.concat
        . map
            ( \field ->
                ByteStringChar8.pack (show (ByteString.length field))
                    <> ":"
                    <> field
            )

sha256HexTest :: ByteString -> Text
sha256HexTest bytes =
    Text.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

expectCursorFields :: ByteString -> IO [ByteString]
expectCursorFields raw =
    maybe (assertFailure "could not decode lifecycle cursor fields") pure (decodeCursorFields 7 raw)

decodeCursorFields :: Int -> ByteString -> Maybe [ByteString]
decodeCursorFields expected raw = go expected raw []
  where
    go remaining rest fields
        | remaining == 0 =
            if ByteString.null rest then Just (reverse fields) else Nothing
        | otherwise = do
            let (lengthRaw, separatorAndRest) = ByteStringChar8.break (== ':') rest
            (fieldLength, trailingLength) <- ByteStringChar8.readInt lengthRaw
            if fieldLength < 0
                || not (ByteString.null trailingLength)
                || ByteString.null separatorAndRest
                then Nothing
                else do
                    let afterSeparator = ByteString.drop 1 separatorAndRest
                    if ByteString.length afterSeparator < fieldLength
                        then Nothing
                        else do
                            let (field, trailing) = ByteString.splitAt fieldLength afterSeparator
                            go (remaining - 1) trailing (field : fields)

replaceByteField :: Int -> ByteString -> [ByteString] -> [ByteString]
replaceByteField index value fields =
    take index fields <> [value] <> drop (index + 1) fields

journalEvidence :: AcquisitionJournal scope planId brokerGeneration -> AcquisitionEvidence
journalEvidence journal =
    AcquisitionEvidence
        (acquisitionJournalStableScope journal)
        (acquisitionJournalSnapshotDigest journal)
        (acquisitionJournalRunLease journal)
        (acquisitionJournalBrokerGeneration journal)
        (acquisitionJournalRecordVersion journal)
        (acquisitionJournalRootVerb journal)
        (withAcquisitionJournalPhase journal lifecyclePhaseName)

acquisitionStepPlan :: StepPlan
acquisitionStepPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ contextInitStep
                "initialize context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            ]
        )

acquisitionDriftStepPlan :: StepPlan
acquisitionDriftStepPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ contextInitStep
                "initialize a different context"
                (StepFrame "other-host" "Host")
                (const (pure StepChanged))
            ]
        )

cursorStepPlan :: StepPlan
cursorStepPlan = cursorStepPlanFor "host-orchestrator-0"

cursorStepPlanFor :: Text -> StepPlan
cursorStepPlanFor semanticFrameId =
    either
        (error . show)
        id
        ( mkStepPlan
            [ contextInitStep
                "initialize cursor context"
                (StepFrame (Text.unpack semanticFrameId) "Host orchestrator")
                (const (pure StepChanged))
            ]
        )

projectConfigForFrame :: Text -> Text -> Text -> Fixture.ProjectConfig scope
projectConfigForFrame projectName rootPath semanticFrameId =
    base
        { Fixture.context =
            baseContext
                { Context.topologyFrames = map renameTopologyFrame (Context.topologyFrames baseContext)
                , Context.currentFrame = semanticFrameId
                , Context.runtimeWitnesses = map renameFrameWitness (Context.runtimeWitnesses baseContext)
                }
        }
  where
    base = Fixture.defaultProjectConfig projectName rootPath Context.HostOrchestrator
    baseContext = Fixture.context base
    oldFrameId = Context.currentFrame baseContext
    renameId value
        | value == oldFrameId = semanticFrameId
        | otherwise = value
    renameTopologyFrame topologyFrame =
        topologyFrame
            { Context.topologyFrameId = renameId (Context.topologyFrameId topologyFrame)
            , Context.topologyParentId = renameId (Context.topologyParentId topologyFrame)
            }
    renameFrameWitness witness
        | Context.witnessKind witness == Context.WitnessEnvEquals
            && Context.witnessName witness == "HOSTBOOTSTRAP_CURRENT_FRAME" =
            witness{Context.witnessValue = semanticFrameId}
        | otherwise = witness

withLifecycleCursorFixture ::
    ( forall projectId brokerGeneration specDigest planDigest planId configId frame.
      ProtectedStore ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      ProjectFrame (Production projectId) specDigest planId configId frame ->
      IO result
    ) ->
    IO result
withLifecycleCursorFixture use =
    withLifecycleCursorFixtureAt "host-orchestrator-0" use

withLifecycleCursorFixtureAt ::
    Text ->
    ( forall projectId brokerGeneration specDigest planDigest planId configId frame.
      ProtectedStore ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      ProjectFrame (Production projectId) specDigest planId configId frame ->
      IO result
    ) ->
    IO result
withLifecycleCursorFixtureAt semanticFrameId use =
    withAcquisitionPlanFixtureForConfig
        (cursorStepPlanFor semanticFrameId)
        (\projectName rootPath -> projectConfigForFrame projectName rootPath semanticFrameId)
        Authority.ProjectUp
        $ \store project root lease bound binding projectPlan projectRoot -> do
            let supplied =
                    Fixture.context
                        ( projectConfigForFrame
                            (installedProjectName project)
                            (Text.pack (canonicalProjectRootPath projectRoot))
                            semanticFrameId
                        )
            cursorAction <-
                either (fail . show) pure $
                    withCurrentFrame projectPlan supplied $ \_current frame _validated ->
                        withAcquisitionJournal
                            root
                            lease
                            bound
                            binding
                            projectPlan
                            (\journal -> use store root lease bound binding projectPlan journal frame)
            cursorAction >>= expect

withLifecycleCursorFixtureForVerb ::
    Authority.ProjectVerb verb ->
    ( forall projectId brokerGeneration specDigest planDigest planId configId frame.
      ProtectedStore ->
      RootInvocationAuthority (Production projectId) brokerGeneration verb ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      ProjectFrame (Production projectId) specDigest planId configId frame ->
      IO result
    ) ->
    IO result
withLifecycleCursorFixtureForVerb verb use =
    withAcquisitionPlanFixtureForConfig
        cursorStepPlan
        (\projectName rootPath ->
            projectConfigForFrame projectName rootPath "host-orchestrator-0"
        )
        verb
        $ \store project root lease bound binding projectPlan projectRoot -> do
            let supplied =
                    Fixture.context
                        ( projectConfigForFrame
                            (installedProjectName project)
                            (Text.pack (canonicalProjectRootPath projectRoot))
                            "host-orchestrator-0"
                        )
            cursorAction <-
                either (fail . show) pure $
                    withCurrentFrame projectPlan supplied $ \_current frame _validated ->
                        withAcquisitionJournal
                            root
                            lease
                            bound
                            binding
                            projectPlan
                            (\journal -> use store root lease bound binding projectPlan journal frame)
            cursorAction >>= expect

withAcquisitionPlanFixture ::
    ( forall projectId brokerGeneration specDigest planDigest planId rootId configId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CanonicalProjectRoot (Production projectId) rootId ->
      IO result
    ) ->
    IO result
withAcquisitionPlanFixture use =
    withAcquisitionPlanFixtureFor acquisitionStepPlan use

withAcquisitionPlanFixtureFor ::
    StepPlan ->
    ( forall projectId brokerGeneration specDigest planDigest planId rootId configId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CanonicalProjectRoot (Production projectId) rootId ->
      IO result
    ) ->
    IO result
withAcquisitionPlanFixtureFor stepPlan =
    withAcquisitionPlanFixtureForConfig
        stepPlan
        (\projectName rootPath -> Fixture.defaultProjectConfig projectName rootPath Context.HostOrchestrator)
        Authority.ProjectUp

withAcquisitionPlanFixtureForConfig ::
    StepPlan ->
    (forall scope. Text -> Text -> Fixture.ProjectConfig scope) ->
    Authority.ProjectVerb verb ->
    ( forall projectId brokerGeneration specDigest planDigest planId rootId configId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration verb ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
      PlanDigestBinding (Production projectId) specDigest planDigest planId ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CanonicalProjectRoot (Production projectId) rootId ->
      IO result
    ) ->
    IO result
withAcquisitionPlanFixtureForConfig stepPlan configFor verb use =
    withSystemTempDirectory "hostbootstrap-acquisition-journal" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= expect
        Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \(projectRoot :: CanonicalProjectRoot (Production projectId) rootId) -> do
                        started <-
                            withProductionRoot store project verb $ \productionRoot -> do
                                let root = productionRootAuthority productionRoot
                                    unbound = productionRootUnboundLease productionRoot
                                profiled <-
                                    withProductionLifecycleProfile
                                        (rootScopeAuthority root)
                                        (productionActiveMode (productionRootModeLease productionRoot))
                                        unbound
                                        ( \profile ->
                                            withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                                                withFinalizedProjectSpec
                                                    ProductionScope
                                                    baseCodec
                                                    emptyServiceRegistry
                                                    (\_ _ -> Right stepPlan)
                                                    Fixture.refusingForwardChildPlan
                                                    ( \spec -> do
                                                        let value =
                                                                configFor
                                                                    (installedProjectName project)
                                                                    (Text.pack (canonicalProjectRootPath projectRoot))
                                                        validated <-
                                                            withValidatedConfig
                                                                (finalizedProjectCodec spec)
                                                                value
                                                                ( \_ config -> do
                                                                    drafts <- expect (projectPlanDrafts spec projectRoot config)
                                                                    persistedAction <-
                                                                        expect
                                                                            ( withProjectPlan
                                                                                profile
                                                                                projectRoot
                                                                                config
                                                                                drafts
                                                                                ( \projectPlan -> do
                                                                                    _ <-
                                                                                        expect
                                                                                            =<< persistCanonicalPlanSnapshot
                                                                                                unbound
                                                                                                1
                                                                                                ( lifecyclePlanSnapshot
                                                                                                    (lifecyclePlanFromProjectPlan projectPlan)
                                                                                                )
                                                                                    withFreshBoundPlanSnapshot
                                                                                        unbound
                                                                                        projectPlan
                                                                                        ( \verified bound binding -> do
                                                                                            lease <-
                                                                                                expect
                                                                                                    =<< bindRunLease
                                                                                                        unbound
                                                                                                        verified
                                                                                                        pure
                                                                                            use
                                                                                                store
                                                                                                project
                                                                                                root
                                                                                                lease
                                                                                                bound
                                                                                                binding
                                                                                                projectPlan
                                                                                                projectRoot
                                                                                        )
                                                                                )
                                                                            )
                                                                    persistedAction >>= expect
                                                                )
                                                        either fail pure validated
                                                    )
                                        )
                                case profiled of
                                    Left failure -> fail (show failure)
                                    Right action -> Right <$> action
                        expect started
                    )
            either (fail . show) pure rooted

{- | Re-enter the existing Production branch, which generates a fresh local
@planId@, independently re-decodes the configuration, reconstructs the exact
plan under that identity, and only then attempts acquisition admission. -}
resumeRecoveredAcquisition ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot (Production projectId) rootId ->
    ( forall brokerGeneration planId.
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      IO result
    ) ->
    IO result
resumeRecoveredAcquisition store project projectRoot use =
    attemptRecoveredAcquisition store project projectRoot use >>= expect

attemptRecoveredAcquisition ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot (Production projectId) rootId ->
    ( forall brokerGeneration planId.
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      IO result
    ) ->
    IO (Either LifecycleError result)
attemptRecoveredAcquisition store project projectRoot use =
    attemptRecoveredAcquisitionFor
        acquisitionStepPlan
        store
        project
        projectRoot
        (\_recoveredPlan journal -> use journal)

resumeRecoveredAcquisitionFor ::
    StepPlan ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot (Production projectId) rootId ->
    ( forall brokerGeneration specDigest planId configId.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      IO result
    ) ->
    IO result
resumeRecoveredAcquisitionFor stepPlan store project projectRoot use =
    attemptRecoveredAcquisitionFor stepPlan store project projectRoot use >>= expect

attemptRecoveredAcquisitionFor ::
    StepPlan ->
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    CanonicalProjectRoot (Production projectId) rootId ->
    ( forall brokerGeneration specDigest planId configId.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      AcquisitionJournal (Production projectId) planId brokerGeneration ->
      IO result
    ) ->
    IO (Either LifecycleError result)
attemptRecoveredAcquisitionFor stepPlan store project projectRoot use = do
    admitted <-
        withBoundPlanSnapshot
            store
            project
            (\_closeKey -> assertFailure "the acquisition fixture entered the terminal branch")
            ( \root modeLease lease verified bound binding recovery -> do
                profiledAction <-
                    expect
                        ( withRecoveredProductionLifecycleProfile
                            root
                            modeLease
                            lease
                            verified
                            bound
                            binding
                            recovery
                            ( \profile ->
                                withProductionProjectCodec @Fixture.ProjectConfig $ \baseCodec ->
                                    withFinalizedProjectSpec
                                        ProductionScope
                                        baseCodec
                                        emptyServiceRegistry
                                        (\_ _ -> Right stepPlan)
                                        Fixture.refusingForwardChildPlan
                                        ( \spec -> do
                                            let value =
                                                    Fixture.defaultProjectConfig
                                                        (installedProjectName project)
                                                        (Text.pack (canonicalProjectRootPath projectRoot))
                                                        Context.HostOrchestrator
                                            validated <-
                                                withValidatedConfig
                                                    (finalizedProjectCodec spec)
                                                    value
                                                    ( \_ candidateConfig -> do
                                                        inputsAction <-
                                                            expect
                                                                ( withRecoveredProductionProjectPlanInputs
                                                                    profile
                                                                    projectRoot
                                                                    spec
                                                                    candidateConfig
                                                                    ( \_recoveredSpec recoveredConfig recoveredDrafts -> do
                                                                        openedAction <-
                                                                            expect
                                                                                ( withRecoveredProductionProjectPlan
                                                                                    profile
                                                                                    projectRoot
                                                                                    verified
                                                                                    bound
                                                                                    binding
                                                                                    recoveredConfig
                                                                                    recoveredDrafts
                                                                                    ( \recoveredPlan ->
                                                                                        withAcquisitionJournal
                                                                                            root
                                                                                            lease
                                                                                            bound
                                                                                            binding
                                                                                            recoveredPlan
                                                                                            (use recoveredPlan)
                                                                                    )
                                                                                )
                                                                        openedAction
                                                                    )
                                                                )
                                                        inputsAction
                                                    )
                                            either fail pure validated
                                        )
                            )
                        )
                profiledAction
            )
    expect admitted

recordKeyFor :: Text -> IO RecordKey
recordKeyFor = either (assertFailure . show) pure . mkRecordKey

readRequiredRecord :: ProtectedStore -> RecordKey -> IO ProtectedRecord
readRequiredRecord store key = do
    observed <- withProtectedEntry store (\session -> readProtectedRecord session key)
    present <- expect observed
    maybe (assertFailure ("missing protected record " <> Text.unpack (recordKeyText key))) pure present

soleRecordWithPrefix :: ProtectedStore -> Text -> IO (RecordKey, ProtectedRecord)
soleRecordWithPrefix store prefix = do
    image <- protectedImage store
    case Map.keys (Map.filterWithKey (\key _ -> prefix `Text.isPrefixOf` key) image) of
        [raw] -> do
            key <- recordKeyFor raw
            record <- readRequiredRecord store key
            pure (key, record)
        keys -> assertFailure ("expected one " <> Text.unpack prefix <> " record, got " <> show keys)

type ProtectedImage = Map.Map Text (Word64, ByteString)

protectedImage :: ProtectedStore -> IO ProtectedImage
protectedImage store = do
    observed <-
        withProtectedEntry store $ \session -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left failure)
                Right keys -> do
                    records <- traverse (readProtectedRecord session) keys
                    pure $ do
                        present <- sequence records
                        Right
                            ( Map.fromList
                                [ ( recordKeyText key
                                  , ( recordVersionWord (protectedRecordVersion record)
                                    , protectedRecordBytes record
                                    )
                                  )
                                | (key, Just record) <- zip keys present
                                ]
                            )
    expect observed

rewriteRecordBytes ::
    ProtectedStore ->
    RecordKey ->
    (ByteString -> ByteString) ->
    IO Word64
rewriteRecordBytes store key transform = do
    written <-
        withProtectedEntry store $ \session -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left failure)
                Right Nothing -> pure (Left (ProtectedInvalid "the test record is absent"))
                Right (Just record) ->
                    compareAndSwapProtectedRecord
                        session
                        key
                        (ExpectVersion (protectedRecordVersion record))
                        (transform (protectedRecordBytes record))
    recordVersionWord <$> expect written

rewriteRecordFields ::
    ProtectedStore ->
    RecordKey ->
    ([Text] -> [Text]) ->
    IO Word64
rewriteRecordFields store key transform =
    rewriteRecordBytes store key (encodeFields . transform . decodeFields)

replaceField :: Int -> Text -> [Text] -> [Text]
replaceField index value fields =
    take index fields <> [value] <> drop (index + 1) fields

assertLifecycleRefusalNoMutation ::
    ProtectedStore ->
    IORef Int ->
    IO (Either LifecycleError result) ->
    IO ()
assertLifecycleRefusalNoMutation store callbacks action = do
    before <- protectedImage store
    outcome <- action
    case outcome of
        Left failure ->
            assertBool
                "the refusal has a diagnostic"
                (not (null (lifecycleErrorMessage failure)))
        Right _ -> assertFailure "expected acquisition admission to refuse"
    readIORef callbacks >>= (@?= 0)
    after <- protectedImage store
    after @?= before

countingCallback :: IORef Int -> value -> IO ()
countingCallback callbacks _ = modifyIORef' callbacks (+ 1)

-- ---------------------------------------------------------------------------
-- Journal and sessions

journalTests :: [TestTree]
journalTests =
    [ testCase "rooted durable coordinates remain bounded and distinct at maximum input size" $ do
        let long suffix = Text.replicate 4096 suffix
        frameKey <- expect (rootedFrameSessionKeyKernel (long "p") (long "c") (long "f"))
        unknownKey <- expect (rootedNodeUnknownKeyKernel (long "p") (long "c") (long "f") (long "o"))
        settlementKey <- expect (rootedSettlementKeyKernel (long "p") (long "c") (long "f") (long "n") 18446744073709551615)
        changedSettlement <- expect (rootedSettlementKeyKernel (long "p") (long "c") (long "f") (long "n") 18446744073709551614)
        mapM_
            (\key -> assertBool "a rooted record key exceeded the protected-store bound" (Text.length (recordKeyText key) <= 200))
            [frameKey, unknownKey, settlementKey]
        assertBool "different settlement ordinals shared one durable key" (recordKeyText settlementKey /= recordKeyText changedSettlement)
    , testCase "opening the journal twice observes one version, it does not reset it" $
        withStore $ \store -> do
            first <- inEntry store (\s -> openProjectJournal s plan)
            second <- inEntry store (\s -> openProjectJournal s plan)
            firstPermit <- expect first
            secondPermit <- expect second
            projectPermitVersion firstPermit @?= projectPermitVersion secondPermit
    , testCase "a session opens against the live journal version" $
        withStore $ \store -> runEntry store $ \s -> do
            permit <- expect' =<< openProjectJournal s plan
            withEpoch s $ \epoch -> do
                opened <- openOperationSession s epoch plan "session-a" permit
                (sess, next) <- expect' opened
                sessionIdText (operationSessionId sess) @?= "session-a"
                -- Opening advanced the shared journal, so the permit moved on.
                assertBool
                    "the journal version advanced"
                    (projectPermitVersion next > projectPermitVersion permit)
                pure (Right ())
    , testCase "a retained older permit cannot advance the journal a second time" $
        withStore $ \store -> runEntry store $ \s -> do
            permit <- expect' =<< openProjectJournal s plan
            withEpoch s $ \epoch -> do
                (_, _) <- expect' =<< openOperationSession s epoch plan "session-a" permit
                -- The same (now stale) permit is presented again.
                again <- openOperationSession s epoch plan "session-b" permit
                case again of
                    Left (SessionOlderStillOpen sid) -> sessionIdText sid @?= "session-a"
                    other -> assertFailure ("expected an older-open refusal, got " <> show other)
                pure (Right ())
    , testCase "an older Open session blocks a new one even with no operations" $
        withStore $ \store -> runEntry store $ \s -> do
            permit <- expect' =<< openProjectJournal s plan
            withEpoch s $ \epoch -> do
                (_, next) <- expect' =<< openOperationSession s epoch plan "session-a" permit
                blocked <- openOperationSession s epoch plan "session-b" next
                case blocked of
                    Left (SessionOlderStillOpen sid) -> sessionIdText sid @?= "session-a"
                    other -> assertFailure ("expected an older-open refusal, got " <> show other)
                pure (Right ())
    , testCase "a session with an unsettled operation refuses to close" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \epoch sess permit -> do
                afterIntent <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                blocked <- closeOperationSession s sess afterIntent
                case blocked of
                    Left (SessionOperationUnsettled opKey) -> opKey @?= "op-1"
                    other -> assertFailure ("expected an unsettled refusal, got " <> show other)
                epoch `seq` pure (Right ())
    , testCase "an operation cannot register an initial intent twice" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \_ sess permit -> do
                afterIntent <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                again <- registerOperationIntent s sess "op-1" NoHistory afterIntent
                case again of
                    Left (SessionIntentAlreadyRecorded opKey phase) -> do
                        opKey @?= "op-1"
                        phase @?= "IntentRecorded"
                    other -> assertFailure ("expected a duplicate-intent refusal, got " <> show other)
                pure (Right ())
    , testCase "reacquisition is refused from a phase that is not Released" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \_ sess permit -> do
                afterIntent <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                again <- registerOperationIntent s sess "op-1" ReleasedReacquisition afterIntent
                case again of
                    Left (SessionIntentOriginRefused opKey phase) -> do
                        opKey @?= "op-1"
                        phase @?= "IntentRecorded"
                    other -> assertFailure ("expected an origin refusal, got " <> show other)
                pure (Right ())
    ]

-- ---------------------------------------------------------------------------
-- Fences

fenceTests :: [TestTree]
fenceTests =
    [ testCase "establishing a fence settles it at the proposed epoch" $
        withStore $ \store -> runEntry store $ \s -> do
            fence <- expect' =<< establishInitialFence s plan 1
            fenceEpochWord fence @?= 1
            observed <- expect' =<< currentFence s plan
            fenceEpochWord observed @?= 1
            pure (Right ())
    , testCase "re-establishing resumes the persisted epoch, not the caller's" $
        withStore $ \store -> do
            _ <- inEntry store (\s -> establishInitialFence s plan 1)
            -- A later invocation proposes a different epoch; the durable
            -- proposal wins, so an interrupted run converges on one epoch.
            resumed <- inEntry store (\s -> establishInitialFence s plan 99)
            fence <- expect resumed
            fenceEpochWord fence @?= 1
    , testCase "a resumed establishment survives reopening the store" $
        withStore $ \store -> do
            _ <- inEntry store (\s -> establishInitialFence s plan 4)
            reopened <- openProtectedStore (protectedStoreRoot store)
            case reopened of
                Left failure -> assertFailure (show failure)
                Right store' -> do
                    again <- inEntry store' (\s -> establishInitialFence s plan 77)
                    fence <- expect again
                    fenceEpochWord fence @?= 4
    , testCase "rotation is strictly increasing" $
        withStore $ \store -> runEntry store $ \s -> do
            first <- expect' =<< establishInitialFence s plan 1
            second <- expect' =<< rotateFence s plan first
            fenceEpochWord second @?= 2
            -- The superseded epoch cannot rotate again.
            stale <- rotateFence s plan first
            case stale of
                Left (SessionFenceSuperseded presented live) -> do
                    presented @?= 1
                    live @?= 2
                other -> assertFailure ("expected a superseded refusal, got " <> show other)
            pure (Right ())
    , testCase "a zero epoch is refused" $
        withStore $ \store -> do
            outcome <- inEntry store (\s -> establishInitialFence s plan 0)
            case outcome of
                Left (SessionFenceInvalid _) -> pure ()
                other -> assertFailure ("expected an invalid-fence refusal, got " <> show other)
    , -- The control for the two out-of-process cases below. A competitor that
      -- can never prepare would "prove" a refusal just as well against a
      -- boundary that was never crossed, so the same probe must succeed when
      -- nothing rotates between its two entries.
      testCase "a competitor's retained token still prepares when no boundary is crossed" $
        withStore $ \store -> do
            executable <- getExecutablePath
            probed <-
                withFenceDelayProbe executable (protectedStoreRoot store) "prepare" (pure ())
            probed @?= FenceAccepted 1
    , -- The out-of-process half of the delayed-permit case. The competitor takes
      -- the generation token, releases the store, and another process rotates
      -- the fence before it presents. The refusal is therefore against a record
      -- a real competitor advanced, not one the same process advanced.
      testCase "a competitor's delayed token is refused across a real generation boundary" $
        withStore $ \store -> do
            executable <- getExecutablePath
            probed <-
                withFenceDelayProbe executable (protectedStoreRoot store) "prepare" $
                    runEntry store $ \s -> do
                        live <- expect' =<< currentFence s plan
                        rotated <- expect' =<< rotateFence s plan live
                        fenceEpochWord rotated @?= 2
                        pure (Right ())
            probed @?= FenceRefused 1 2
    , -- The other half of the deliverable: a delayed *proposal* is deduplicated
      -- rather than rejected, so a retry that crosses the boundary converges on
      -- the observed epoch instead of opening a second generation.
      testCase "a competitor's delayed proposal is deduplicated to the observed epoch" $
        withStore $ \store -> do
            executable <- getExecutablePath
            probed <-
                withFenceDelayProbe executable (protectedStoreRoot store) "reestablish" $
                    runEntry store $ \s -> do
                        live <- expect' =<< currentFence s plan
                        _ <- expect' =<< rotateFence s plan live
                        pure (Right ())
            -- It proposed 5 and was given the live 2; nothing advanced.
            probed @?= FenceAccepted 2
            runEntry store $ \s -> do
                settled <- expect' =<< currentFence s plan
                fenceEpochWord settled @?= 2
                pure (Right ())
    ]

-- ---------------------------------------------------------------------------
-- Classification

classificationTests :: [TestTree]
classificationTests =
    [ testCase "the five pre-call phases are continuable" $
        mapM_
            (\phase -> classifyRecordedPhase phase @?= Continuable)
            [ "IntentRecorded"
            , "AdoptionIntentRecorded"
            , "RepairIntentRecorded"
            , "PhaseIntentRecorded"
            , "ReservationRetryFenced"
            ]
    , testCase "the observed-absence whitelist is fenced-retryable" $
        mapM_
            (\phase -> classifyRecordedPhase phase @?= FencedRetryable)
            ["ReservationAbsent", "EffectAbsent", "AdoptionObservedAbsent", "RepairObservedOriginal", "PhaseObservedFrom"]
    , testCase "committed and released phases are settled" $
        mapM_
            (\phase -> classifyRecordedPhase phase @?= Settled)
            ["Committed", "AdoptionCommitted", "RepairCommitted", "PhaseCommitted", "Released"]
    , testCase "foreign, refused, and unexpected branches are terminal" $
        mapM_
            (\phase -> classifyRecordedPhase phase @?= TerminalDisposition)
            ["ObservedForeign", "AdoptionRefused", "RepairObservedUnexpected", "PhaseObservedForeign"]
    , testCase "an unrecognised phase is Unknown, not optimistically safe" $ do
        classifyRecordedPhase "SomethingThisBinaryDoesNotKnow" @?= UnknownDisposition
        classifyRecordedPhase "" @?= UnknownDisposition
    ]

-- ---------------------------------------------------------------------------
-- Prepare

prepareTests :: [TestTree]
prepareTests =
    [ testCase "a prepare records the unknown phase before the adapter runs" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \_ sess fence gate permit -> do
                preparedGateAttemptIs gate 1
                preparedGateFenceIs gate (fenceEpochWord fence)
                -- The durable record already says an effect may be in flight.
                advance <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                withOperationAdvance advance (\() next -> pure (Right next)) >>= \_ -> pure ()
                pure (Right ())
    , testCase "the consumed journal version cannot acknowledge twice" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \_ sess _ gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                again <- acknowledgeOutcome s sess gate "Committed" () next
                case again of
                    Left (SessionStaleJournalVersion consumed actual) ->
                        assertBool "the record moved past the consumed version" (actual > consumed)
                    other -> assertFailure ("expected a stale-version refusal, got " <> show other)
                pure (Right ())
    , testCase "a settled operation cannot be prepared again" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \epoch sess fence gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                do
                    blocked <-
                        withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" next $
                            \_ _ -> pure (Right ())
                    case blocked of
                        Left (SessionOperationSettled opKey phase) -> do
                            opKey @?= "op-1"
                            phase @?= "Committed"
                        other -> assertFailure ("expected a settled refusal, got " <> show other)
                pure (Right ())
    , testCase "a terminal operation receives no effect authority" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \epoch sess fence gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "ObservedForeign" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                do
                    blocked <-
                        withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" next $
                            \_ _ -> pure (Right ())
                    case blocked of
                        Left (SessionOperationTerminal opKey phase) -> do
                            opKey @?= "op-1"
                            phase @?= "ObservedForeign"
                        other -> assertFailure ("expected a terminal refusal, got " <> show other)
                pure (Right ())
    , testCase "a fenced-retryable phase needs a fence above the one it was observed at" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \epoch sess fence gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "EffectAbsent" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                do
                    -- Same fence: refused.
                    blocked <-
                        withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" next $
                            \_ _ -> pure (Right ())
                    case blocked of
                        Left (SessionRetryNeedsFreshFence opKey recorded live) -> do
                            opKey @?= "op-1"
                            recorded @?= live
                        other -> assertFailure ("expected a fresh-fence refusal, got " <> show other)
                    -- After rotation the same key may retry.
                    rotated <- expect' =<< rotateFence s plan fence
                    allowed <-
                        withPreparedGate s sess epoch rotated "op-1" "EffectOutcomeUnknown" next $
                            \g p -> pure (Right (preparedGateFence g, p))
                    (usedFence, _) <- expect' allowed
                    usedFence @?= fenceEpochWord rotated
                pure (Right ())
    , testCase "a prepare against a superseded fence is refused" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \epoch sess permit -> do
                stale <- expect' =<< establishInitialFence s plan 1
                afterIntent <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                _ <- expect' =<< rotateFence s plan stale
                blocked <-
                    withPreparedGate s sess epoch stale "op-1" "EffectOutcomeUnknown" afterIntent $
                        \_ _ -> pure (Right ())
                case blocked of
                    Left (SessionFenceSuperseded presented live) -> do
                        presented @?= 1
                        live @?= 2
                    other -> assertFailure ("expected a superseded refusal, got " <> show other)
                pure (Right ())
    , testCase "an unregistered operation cannot prepare" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \epoch sess permit -> do
                fence <- expect' =<< establishInitialFence s plan 1
                blocked <-
                    withPreparedGate s sess epoch fence "never-registered" "EffectOutcomeUnknown" permit $
                        \_ _ -> pure (Right ())
                case blocked of
                    Left (SessionOperationUnregistered opKey) -> opKey @?= "never-registered"
                    other -> assertFailure ("expected an unregistered refusal, got " <> show other)
                pure (Right ())
    , testCase "a stale project permit cannot drive a prepare" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \epoch sess permit -> do
                fence <- expect' =<< establishInitialFence s plan 1
                afterIntent <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                -- `permit` was consumed by intent registration and is now stale.
                blocked <-
                    withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" permit $
                        \_ _ -> pure (Right ())
                case blocked of
                    Left (SessionStaleProjectPermit _) -> pure ()
                    other -> assertFailure ("expected a stale-permit refusal, got " <> show other)
                -- The refusal happened before any operation mutation. The live
                -- successor can still prepare the original IntentRecorded
                -- phase, and this is its first attempt. Before the permit
                -- precheck this second call observed EffectOutcomeUnknown and
                -- refused, exposing the stale call's partial write.
                allowed <-
                    withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" afterIntent $
                        \gate next -> do
                            preparedGateAttemptIs gate 1
                            pure (Right next)
                _ <- expect' allowed
                pure (Right ())
    , testCase "an operation at an unrecognised phase blocks rather than proceeding" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \epoch sess fence gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "SomeFuturePhase" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                do
                    blocked <-
                        withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" next $
                            \_ _ -> pure (Right ())
                    case blocked of
                        Left (SessionUnclassifiedPhase opKey phase) -> do
                            opKey @?= "op-1"
                            phase @?= "SomeFuturePhase"
                        other -> assertFailure ("expected an unclassified refusal, got " <> show other)
                pure (Right ())
    , testCase "a terminally closed project refuses every prepare" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \epoch sess fence gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                afterSession <- expect' =<< closeOperationSession s sess next
                closing <- expect' =<< beginClosingProject s plan 7 afterSession
                closed <- expect' =<< recordClosedProject s plan 7 closing
                state <- expect' =<< readProjectJournalState s plan
                state @?= ClosedProject
                blocked <-
                    withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" afterSession $
                        \_ _ -> pure (Right ())
                case blocked of
                    Left (SessionProjectClosed closedPlan) -> closedPlan @?= plan
                    other -> assertFailure ("expected a closed-project refusal, got " <> show other)
                closed `seq` pure (Right ())
    , -- The route a step action takes to the gate (§ CC). Before it, a plan
      -- operation key could not name a durable record at all — the namespace
      -- separator is outside the store's alphabet — so no step could prepare
      -- anything, and an acquiring step had no gate through which to mint a
      -- managed handle.
      testCase "a step reaches the prepared gate for its own operation" $
        withStore $ \store ->
            withRoutePlan $ \projectPlan -> do
                let digest = stablePlanSnapshotDigest (renderSnapshot projectPlan)
                execution <- expectExecution projectPlan targetStep
                runEntry store $ \s ->
                    -- Opened inline rather than through a rank-2 helper: the
                    -- session's scope/planId are inferred, so they unify with
                    -- the descriptor's and the digest comparison is what decides.
                    routeSession s digest $ \epoch sess fence permit -> do
                        registered <-
                            registerOperationIntent
                                s
                                sess
                                (stepExecutionOperationKey execution)
                                NoHistory
                                permit
                        afterIntent <- expect' registered
                        gated <-
                            withStepPreparedGate s sess epoch fence execution "EffectOutcomeUnknown" afterIntent $
                                \gate _ -> pure (Right (preparedGateOperation gate, preparedGatePlan gate))
                        (gateOperation, gatePlan) <- expect' gated
                        -- The gate names the step's own operation, in the plan's
                        -- own vocabulary — the encoding is the store's business.
                        gateOperation @?= "core:deploy-kind"
                        gatePlan @?= digest
                        -- and the durable record really is the encoded name
                        listed <- listProtectedRecords s
                        case listed of
                            Left failure -> assertFailure (show failure)
                            Right keys ->
                                assertBool
                                    ("no encoded operation record in " <> show (map recordKeyText keys))
                                    ( any
                                        (Text.isSuffixOf ".core.deploy-kind" . recordKeyText)
                                        keys
                                    )
                        pure (Right ())
    , testCase "a descriptor from another plan cannot prepare in this session" $
        withStore $ \store ->
            withRoutePlan $ \projectPlan -> do
                execution <- expectExecution projectPlan targetStep
                -- The session's scope/planId indices are phantom, so they unify
                -- with the descriptor's; only the digest comparison catches it.
                runEntry store $ \s ->
                    routeSession s plan $ \epoch sess fence permit -> do
                        refused <-
                            withStepPreparedGate s sess epoch fence execution "EffectOutcomeUnknown" permit $
                                \_ _ -> pure (Right ())
                        case refused of
                            Left (SessionStepPlanMismatch sessionPlan stepPlan) -> do
                                sessionPlan @?= plan
                                stepPlan @?= stablePlanSnapshotDigest (renderSnapshot projectPlan)
                            other ->
                                assertFailure ("expected a step/plan mismatch, got " <> show other)
                        pure (Right ())
    , -- The encoding is injective because its image and its plain domain are
      -- disjoint: were they not, a plain key could name a namespaced key's
      -- record and two distinct operations would share one durable phase.
      testCase "a plain operation key cannot occupy an encoded key's record" $
        withStore $ \store -> runEntry store $ \s ->
            withOpenSession s $ \_ sess permit -> do
                -- "core.deploy-kind" is what "core:deploy-kind" encodes to, so
                -- a plain key of that shape is refused rather than admitted.
                refused <- registerOperationIntent s sess "core.deploy-kind" NoHistory permit
                case refused of
                    Left (SessionStoreFailure (ProtectedInvalid detail)) ->
                        assertBool
                            ("the refusal names the component: " <> Text.unpack detail)
                            ("core.deploy-kind" `Text.isInfixOf` detail)
                    other -> assertFailure ("expected a plain-component refusal, got " <> show other)
                -- A second namespace would make the separator ambiguous.
                ambiguous <- registerOperationIntent s sess "a:b:c" NoHistory permit
                case ambiguous of
                    Left (SessionStoreFailure (ProtectedInvalid detail)) ->
                        assertBool
                            ("the refusal names the component: " <> Text.unpack detail)
                            ("a:b:c" `Text.isInfixOf` detail)
                    other -> assertFailure ("expected a namespace refusal, got " <> show other)
                -- An unknown namespace is fine: the encoding is general, not a
                -- list of the two the core plan happens to use.
                vendor <- registerOperationIntent s sess "vendor:thing" NoHistory permit
                assertBool "a namespaced vendor key registers" (isRight vendor)
                pure (Right ())
    ]

-- ---------------------------------------------------------------------------
-- The step-to-gate route fixture

routeHostConfig :: HostConfig
routeHostConfig =
    HostConfig
        { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Arm64}
        , hcToolPaths = Map.empty
        }

hostFrame :: StepFrame
hostFrame = StepFrame "host-orchestrator-0" "Host"

targetStep :: Step
targetStep = deployKindStep "deploy the cluster" hostFrame (const (pure StepChanged))

routeStepPlan :: StepPlan
routeStepPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ deployVMStep "launch the VM" hostFrame (const (pure StepChanged))
            , targetStep
            ]
        )

-- | Open the route fixture's plan, so the descriptor and the digest come from
-- one interpretation rather than two computations of it.
withRoutePlan ::
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withRoutePlan = Fixture.withFixtureProjectPlan routeStepPlan

expectExecution ::
    ProjectPlan scope specDigest planId configId cfg ->
    Step ->
    IO (StepExecution scope planId)
expectExecution projectPlan step = do
    runtime <- newResourceCarrier >>= newStepRuntime
    planned <-
        maybe
            (assertFailure "the plan does not contain the fixture step")
            pure
            (find ((== stepIdentity step) . plannedStepIdentity) (forward projectPlan))
    pure (stepExecutionFor projectPlan routeHostConfig runtime planned)

{- | A journal, epoch, session, and settled fence on the given plan digest.

Only @brokerGeneration@ is rank-2 here. The @scope@/@planId@ indices are left
inferred on purpose: they are phantom on the session side, so a test that pairs
a session with a step descriptor must be able to unify them — which is exactly
what makes the digest comparison, rather than the type, the thing under test.
-}
routeSession ::
    ProtectedSession session ->
    Text ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      OperationSession scope planId ->
      FenceEpoch scope planId ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
routeSession session planDigest use = do
    opened <- openProjectJournal session planDigest
    case opened of
        Left failure -> pure (Left failure)
        Right permit -> withEpoch session $ \epoch -> do
            started <- openOperationSession session epoch planDigest "session-route" permit
            case started of
                Left failure -> pure (Left failure)
                Right (sess, afterOpen) -> do
                    settled <- establishInitialFence session planDigest 1
                    case settled of
                        Left failure -> pure (Left failure)
                        Right fence -> use epoch sess fence afterOpen

-- ---------------------------------------------------------------------------
-- Recovery

recoveryTests :: [TestTree]
recoveryTests =
    [ testCase "an abandoned session is closed and its continuable work counted" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ sess permit -> do
                    _ <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                    -- Stop here: the session is Open with one continuable
                    -- operation, exactly as a killed invocation leaves it.
                    pure (Right ())
            reopened <- openProtectedStore (protectedStoreRoot store)
            case reopened of
                Left failure -> assertFailure (show failure)
                Right store' -> do
                    swept <- inEntry store' (\s -> recoverAbandonedSessions s plan)
                    recovered <- expect swept
                    recoveredSessionCount recovered @?= 1
                    recoveredContinuableCount recovered @?= 1
                    -- The sweep cleared the way for a fresh session.
                    opened <- inEntry store' $ \s -> do
                        permit <- expect' =<< openProjectJournal s plan
                        withEpoch s $ \epoch -> do
                            outcome <- openOperationSession s epoch plan "session-b" permit
                            pure (fmap (const ()) outcome)
                    assertBool "a fresh session opens after recovery" (isRight opened)
    , testCase "an unrecognised recorded phase blocks the sweep instead of being swept" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withPrepared s $ \_ sess _ gate permit -> do
                    _ <- expect' =<< acknowledgeOutcome s sess gate "SomeFuturePhase" () permit
                    pure (Right ())
            swept <- inEntry store (\s -> recoverAbandonedSessions s plan)
            case swept of
                Left (SessionUnclassifiedPhase opKey phase) -> do
                    opKey @?= "op-1"
                    phase @?= "SomeFuturePhase"
                other -> assertFailure ("expected an unclassified refusal, got " <> show other)
    , testCase "a sweep with nothing open reports no work" $
        withStore $ \store -> do
            _ <- inEntry store (\s -> openProjectJournal s plan)
            swept <- inEntry store (\s -> recoverAbandonedSessions s plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 0
    ]

-- ---------------------------------------------------------------------------
-- Abandoned-run admission

{- | The fence set, the manifest, the recorded-session interpreter, and the
admission only both complete sets can mint.

Every case here abandons a real session the way a kill does — stopping between
two durable writes and reopening the store — because the whole point of this
machinery is what it does to state nobody closed.
-}
admissionTests :: [TestTree]
admissionTests =
    [ testCase "fencing enumerates the outstanding permits and then supersedes them" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ sess permit -> do
                    _ <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                    pure (Right ())
            reopened <- reopenStore store
            fenced <- expect =<< inEntry reopened (\s -> fenceOldPermits s plan)
            -- The set is the operation that can still receive authority, read
            -- out of the store rather than supplied.
            oldPermitsFencedOperations fenced @?= ["op-1"]
            -- Establishing settled the initial epoch; rotating superseded it.
            oldPermitsFencedFrom fenced @?= 1
            oldPermitsFencedTo fenced @?= 2
            oldPermitsFencedPlanDigest fenced @?= plan
            -- A permit minted under the superseded epoch is now refused.
            live <- expect =<< inEntry reopened (\s -> currentFence s plan)
            fenceEpochWord live @?= 2
    , testCase "a settled operation holds no authority, so it is not in the fence set" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withPrepared s $ \_ sess _ gate permit -> do
                    _ <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                    pure (Right ())
            reopened <- reopenStore store
            fenced <- expect =<< inEntry reopened (\s -> fenceOldPermits s plan)
            oldPermitsFencedOperations fenced @?= []
    , testCase "the fence protocol is completed idempotently when it was left unsettled" $
        withStore $ \store -> do
            -- No fence record at all: the classifier completes the stable
            -- initial-fence protocol rather than refusing.
            _ <- inEntry store (\s -> openProjectJournal s plan)
            fenced <- expect =<< inEntry store (\s -> fenceOldPermits s plan)
            oldPermitsFencedFrom fenced @?= 1
            oldPermitsFencedTo fenced @?= 2
    , testCase "the manifest pairs the independently enumerated session and operation sets" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ sess permit -> do
                    afterOne <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                    _ <- expect' =<< registerOperationIntent s sess "op-2" NoHistory afterOne
                    pure (Right ())
            reopened <- reopenStore store
            manifest <- expect =<< inEntry reopened (\s -> verifySessionManifest s plan)
            manifestPlanDigest manifest @?= plan
            map (sessionIdText . manifestSessionId) (manifestSessions manifest) @?= ["session-a"]
            map manifestSessionOperations (manifestSessions manifest) @?= [["op-1", "op-2"]]
            manifestOperationCount manifest @?= 2
    , testCase "a zero-operation Open session is still a required manifest member" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ _ _ -> pure (Right ())
            reopened <- reopenStore store
            manifest <- expect =<< inEntry reopened (\s -> verifySessionManifest s plan)
            map (sessionIdText . manifestSessionId) (manifestSessions manifest) @?= ["session-a"]
            map manifestSessionOperations (manifestSessions manifest) @?= [[]]
            map manifestSessionIsOpen (manifestSessions manifest) @?= [True]
    , testCase "an operation naming no session record refuses the manifest" $
        withStore $ \store -> do
            _ <- inEntry store (\s -> openProjectJournal s plan)
            -- An operation record whose session has no record at all: the
            -- operation exists and nothing owns it.
            _ <- inEntry store $ \s -> writeOrphanOperation s "session-ghost" "op-1"
            manifested <- inEntry store (\s -> verifySessionManifest s plan)
            case manifested of
                Left (SessionManifestOrphanOperation opKey sid) -> do
                    opKey @?= "op-1"
                    sid @?= "session-ghost"
                other -> assertFailure ("expected an orphan refusal, got " <> show other)
    , testCase "a session whose declared membership disagrees with the store refuses" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ sess permit -> do
                    _ <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                    pure (Right ())
            -- The session record still declares only op-1 while the store now
            -- holds a second operation record for it.
            _ <- inEntry store $ \s -> writeOrphanOperation s "session-a" "op-2"
            manifested <- inEntry store (\s -> verifySessionManifest s plan)
            case manifested of
                Left (SessionManifestMembershipMismatch sid declared enumerated) -> do
                    sessionIdText sid @?= "session-a"
                    declared @?= "op-1"
                    enumerated @?= "op-1,op-2"
                other -> assertFailure ("expected a membership mismatch, got " <> show other)
    , testCase "the interpreter settles pre-call work, closes the session, and admits the broker" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ sess permit -> do
                    _ <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                    pure (Right ())
            reopened <- reopenStore store
            -- The admission is indexed by the broker generation the rank-2
            -- continuation binds, so what leaves the entry is what it says
            -- rather than the value itself.
            outcome <- inEntry reopened $ \s -> do
                fenced <- expect' =<< fenceOldPermits s plan
                manifest <- expect' =<< verifySessionManifest s plan
                permit <- expect' =<< openProjectJournal s plan
                withEpoch s $ \epoch -> do
                    (interpreted, _) <-
                        expect' =<< interpretRecordedSessions s epoch manifest fenced permit
                    admitted <- admitCurrentBroker s epoch manifest fenced interpreted
                    pure $ case admitted of
                        Left failure -> Left failure
                        Right admission ->
                            Right
                                ( interpretedRecoveryOperations interpreted
                                , map sessionIdText (interpretedRecoverySessions interpreted)
                                , admissionPlanDigest admission
                                , admissionSessionCount admission
                                , admissionOperationCount admission
                                )
            (operations, sessions, digest, sessionCount, operationCount) <- expect outcome
            -- The pre-call operation was handled, not left continuable.
            operations @?= [OperationAbandonedPreCall "op-1" "IntentRecorded"]
            sessions @?= ["session-a"]
            digest @?= plan
            sessionCount @?= 1
            operationCount @?= 1
            -- The session really is closed, so a fresh one now opens.
            fresh <- inEntry reopened $ \s -> do
                permit <- expect' =<< openProjectJournal s plan
                withEpoch s $ \epoch ->
                    fmap (fmap (const ())) (openOperationSession s epoch plan "session-b" permit)
            assertBool "a fresh session opens after interpretation" (isRight fresh)
    , testCase "committed work is left alone rather than rewritten" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withPrepared s $ \_ sess _ gate permit -> do
                    _ <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                    pure (Right ())
            reopened <- reopenStore store
            interpreted <- expect =<< inEntry reopened (\s -> interpretHere s)
            interpretedRecoveryOperations interpreted
                @?= [OperationAlreadySettled "op-1" "Committed"]
    , testCase "an unrecognised phase blocks the interpretation instead of being swept" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withPrepared s $ \_ sess _ gate permit -> do
                    _ <- expect' =<< acknowledgeOutcome s sess gate "SomeFuturePhase" () permit
                    pure (Right ())
            reopened <- reopenStore store
            outcome <- inEntry reopened (\s -> interpretHere s)
            case outcome of
                Left (SessionUnclassifiedPhase opKey phase) -> do
                    opKey @?= "op-1"
                    phase @?= "SomeFuturePhase"
                other -> assertFailure ("expected an unclassified refusal, got " <> show other)
    , testCase "an interrupted effect is settled as abandoned under the new fence" $
        withStore $ \store -> do
            -- EffectAbsent is on the fenced-retryable whitelist: an effect was
            -- attempted and observed absent.
            _ <- inEntry store $ \s ->
                withPrepared s $ \_ sess _ gate permit -> do
                    _ <- expect' =<< acknowledgeOutcome s sess gate "EffectAbsent" () permit
                    pure (Right ())
            reopened <- reopenStore store
            interpreted <- expect =<< inEntry reopened (\s -> interpretHere s)
            interpretedRecoveryOperations interpreted
                @?= [OperationAbandonedRetryable "op-1" "EffectAbsent"]
    , testCase "evidence taken over another plan cannot be paired" $
        withStore $ \store -> do
            _ <- inEntry store $ \s ->
                withOpenSession s $ \_ _ _ -> pure (Right ())
            outcome <- inEntry store $ \s -> do
                manifest <- expect' =<< verifySessionManifest s plan
                -- A fence set taken over a different plan digest entirely.
                otherFenced <- expect' =<< fenceOldPermits s "plan-digest-2"
                permit <- expect' =<< openProjectJournal s plan
                withEpoch s $ \epoch ->
                    fmap
                        (fmap (const ()))
                        (interpretRecordedSessions s epoch manifest otherFenced permit)
            case outcome of
                Left (SessionRecoveryPlanMismatch expected presented) -> do
                    expected @?= plan
                    presented @?= "plan-digest-2"
                other -> assertFailure ("expected a plan mismatch, got " <> show other)
    ]

{- | Run the whole fence → manifest → interpret chain over the fixture plan. -}
interpretHere ::
    ProtectedSession session ->
    IO (Either SessionError (InterpretedRecovery scope planId))
interpretHere s = do
    fenced <- fenceOldPermits s plan
    case fenced of
        Left failure -> pure (Left failure)
        Right fencedPermits -> do
            manifested <- verifySessionManifest s plan
            case manifested of
                Left failure -> pure (Left failure)
                Right manifest -> do
                    opened <- openProjectJournal s plan
                    case opened of
                        Left failure -> pure (Left failure)
                        Right permit -> withEpoch s $ \epoch ->
                            fmap
                                (fmap fst)
                                (interpretRecordedSessions s epoch manifest fencedPermits permit)

{- | Write an operation record directly at @op.\<plan\>.\<session\>.\<op\>@,
bypassing 'registerOperationIntent'.

This is how the two manifest refusals are reached: both need the store to hold an
operation record the session-membership path would never have created, which is
exactly the torn state a killed writer can leave.
-}
writeOrphanOperation ::
    ProtectedSession session ->
    Text ->
    Text ->
    IO (Either SessionError ())
writeOrphanOperation session sid opKey =
    case mkRecordKey ("op." <> planKeyDigest <> "." <> sid <> "." <> opKey) of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right key -> do
            written <-
                compareAndSwapProtectedRecord
                    session
                    key
                    ExpectAbsent
                    (encodeFields ["IntentRecorded", sid, "0"])
            pure (either (Left . SessionStoreFailure) (const (Right ())) written)

-- ---------------------------------------------------------------------------
-- Recoverable lifecycle transactions

transactionRecoveryTests :: [TestTree]
transactionRecoveryTests =
    concat
        [ map openProjectRecoveryCase oneTargetPoints
        , map openSessionRecoveryCase oneTargetPoints
        , map registerIntentRecoveryCase twoTargetPoints
        , map prepareRecoveryCase oneTargetPoints
        , map acknowledgeRecoveryCase oneTargetPoints
        , map closeSessionRecoveryCase oneTargetPoints
        , map beginProjectCloseRecoveryCase oneTargetPoints
        , map recordProjectClosedRecoveryCase oneTargetPoints
        ]
        <> [ testCase "exact session membership ignores an unregistered prefix-shaped record" exactMembershipCase
           , testCase "a prepare/session-close race yields exactly one successor permit" prepareCloseRaceCase
           , testCase "the reproduced interruption is the transition's own descriptor" faithfulDescriptorCase
           ]

oneTargetPoints :: [InterruptionPoint]
oneTargetPoints =
    [ AfterApplying
    , AfterTarget 1
    , BeforeCommit
    ]

twoTargetPoints :: [InterruptionPoint]
twoTargetPoints =
    [ AfterApplying
    , AfterTarget 1
    , AfterTarget 2
    , BeforeCommit
    ]

openProjectRecoveryCase :: InterruptionPoint -> TestTree
openProjectRecoveryCase point =
    testCase ("open project recovers when " <> show point) $
        withStore $ \store -> do
            reopened <-
                withInterruptedTransaction point TxnOpenProject store $
                    runEntry store $ \session ->
                        fmap (fmap (const ())) (openProjectJournal session plan)
            permit <- expect =<< inEntry reopened (\session -> openProjectJournal session plan)
            assertBool "recovery returns the committed successor permit" (projectPermitVersion permit > 0)
            state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
            state @?= OpenProject

openSessionRecoveryCase :: InterruptionPoint -> TestTree
openSessionRecoveryCase point =
    testCase ("open session recovers when " <> show point) $
        withStore $ \store -> do
            SomeProjectPermit current <- openProjectFixture store
            reopened <-
                withInterruptedTransaction point TxnOpenSession store $
                    runEntry store $ \session ->
                        withEpoch session $ \epoch ->
                            fmap (fmap (const ()))
                                (openOperationSession session epoch plan "session-a" current)
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 1
            recoveredContinuableCount recovered @?= 0

registerIntentRecoveryCase :: InterruptionPoint -> TestTree
registerIntentRecoveryCase point =
    testCase ("register intent recovers when " <> show point) $
        withStore $ \store -> do
            SomeOpenSession sess oldPermit <- openSessionFixture store
            reopened <-
                withInterruptedTransaction point TxnRegisterIntent store $
                    runEntry store $ \session ->
                        fmap (fmap (const ()))
                            (registerOperationIntent session sess "op-1" NoHistory oldPermit)

            current <- expect =<< inEntry reopened (\session -> openProjectJournal session plan)

            -- Recovery committed exactly one successor. The consumed permit
            -- cannot add another member, while the recovered successor can.
            stale <-
                inEntry reopened $ \session ->
                    registerOperationIntent session sess "stale-op" NoHistory oldPermit
            case stale of
                Left (SessionStaleProjectPermit _) -> pure ()
                other -> assertFailure ("expected the pre-crash permit to be stale, got " <> show other)

            successor <-
                inEntry reopened $ \session ->
                    registerOperationIntent session sess "op-2" NoHistory current
            _ <- expect successor

            -- The recovery sweep reads the exact durable membership rather
            -- than inferring it from the operation-key prefix. Both the
            -- interrupted member and the successor member must be present.
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 1
            recoveredContinuableCount recovered @?= 2

prepareRecoveryCase :: InterruptionPoint -> TestTree
prepareRecoveryCase point =
    testCase ("prepare recovers when " <> show point) $
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- prepareInputFixture store
            reopened <-
                withInterruptedTransaction point TxnPrepareOperation store $
                    runEntry store $ \session ->
                        withPreparedGate
                            session
                            sess
                            epoch
                            fence
                            "op-1"
                            "EffectOutcomeUnknown"
                            permit
                            (\_ _ -> pure (Right ()))
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            case swept of
                Left (SessionUnclassifiedPhase opKey phase) -> do
                    opKey @?= "op-1"
                    phase @?= "EffectOutcomeUnknown"
                other -> assertFailure ("expected the recovered durable unknown phase, got " <> show other)

acknowledgeRecoveryCase :: InterruptionPoint -> TestTree
acknowledgeRecoveryCase point =
    testCase ("acknowledgment recovers when " <> show point) $
        withStore $ \store -> do
            SomeAcknowledgeInput sess gate permit <- acknowledgeInputFixture store
            reopened <-
                withInterruptedTransaction point TxnAcknowledgeOutcome store $
                    runEntry store $ \session ->
                        fmap (fmap (const ()))
                            (acknowledgeOutcome session sess gate "Committed" () permit)
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 1
            recoveredContinuableCount recovered @?= 0

closeSessionRecoveryCase :: InterruptionPoint -> TestTree
closeSessionRecoveryCase point =
    testCase ("session close recovers when " <> show point) $
        withStore $ \store -> do
            SomeOpenSession sess permit <- openSessionFixture store
            reopened <-
                withInterruptedTransaction point TxnCloseSession store $
                    runEntry store $ \session ->
                        fmap (fmap (const ()))
                            (closeOperationSession session sess permit)
            verified <- inEntry reopened (\session -> verifyAllSessionsClosed session plan)
            proof <- expect verified
            allSessionsClosedCount proof @?= 1

beginProjectCloseRecoveryCase :: InterruptionPoint -> TestTree
beginProjectCloseRecoveryCase point =
    testCase ("begin project close recovers when " <> show point) $
        withStore $ \store -> do
            SomeProjectPermit current <- openProjectFixture store
            reopened <-
                withInterruptedTransaction point TxnBeginProjectClose store $
                    runEntry store $ \session ->
                        fmap (fmap (const ()))
                            (beginClosingProject session plan 7 current)
            state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
            state @?= ClosingProject 7

recordProjectClosedRecoveryCase :: InterruptionPoint -> TestTree
recordProjectClosedRecoveryCase point =
    testCase ("record project closed recovers when " <> show point) $
        withStore $ \store -> do
            SomeClosingPermit closePermit <- closingProjectFixture store
            reopened <-
                withInterruptedTransaction point TxnRecordProjectClosed store $
                    runEntry store $ \session ->
                        fmap (fmap (const ()))
                            (recordClosedProject session plan 7 closePermit)
            state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
            state @?= ClosedProject

exactMembershipCase :: IO ()
exactMembershipCase =
    withStore $ \store -> do
        SomeOpenSession sess permit <- openSessionFixture store
        injected <- inEntry store $ \session -> do
            key <-
                pure
                    ( either
                        (Left . SessionStoreFailure)
                        Right
                        (mkRecordKey ("op." <> planKeyDigest <> ".session-a.stray"))
                    )
            case key of
                Left failure -> pure (Left failure)
                Right operationKey -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            operationKey
                            ExpectAbsent
                            "IntentRecorded\tsession-a\t0"
                    pure (either (Left . SessionStoreFailure) (const (Right ())) written)
        _ <- expect injected
        closed <- inEntry store (\session -> closeOperationSession session sess permit)
        _ <- expect closed
        verified <- inEntry store (\session -> verifyAllSessionsClosed session plan)
        proof <- expect verified
        allSessionsClosedCount proof @?= 1

prepareCloseRaceCase :: IO ()
prepareCloseRaceCase =
    withStore $ \store -> do
        SomePrepareInput epoch sess fence permit <- prepareInputFixture store
        start <- newEmptyMVar
        prepareResult <- newEmptyMVar
        closeResult <- newEmptyMVar

        _ <-
            forkFinally
                ( do
                    takeMVar start
                    inEntry store $ \session ->
                        withPreparedGate
                            session
                            sess
                            epoch
                            fence
                            "op-1"
                            "EffectOutcomeUnknown"
                            permit
                            (\_ _ -> pure (Right ()))
                )
                (putMVar prepareResult)
        _ <-
            forkFinally
                ( do
                    takeMVar start
                    inEntry store $ \session ->
                        fmap (fmap (const ())) (closeOperationSession session sess permit)
                )
                (putMVar closeResult)

        putMVar start ()
        putMVar start ()
        preparedThread <- takeMVar prepareResult
        closedThread <- takeMVar closeResult
        prepared <- either (assertFailure . show) pure preparedThread
        closed <- either (assertFailure . show) pure closedThread
        assertBool
            ("expected exactly one successor permit, got prepare=" <> show prepared <> ", close=" <> show closed)
            (isRight prepared /= isRight closed)
        assertBool "the registered continuable operation lets prepare win" (isRight prepared)

        reopened <- reopenStore store
        current <- inEntry reopened (\session -> openProjectJournal session plan)
        assertBool "reopening observes the committed successor" (isRight current)

{- | The reproduction is faithful: it is the transition's own descriptor.

The fixture below never invents a descriptor. It runs the real transition,
reads the records it stamped, and rebuilds the descriptor from those — so this
case pins the property the whole matrix rests on. Interrupting an @open
project@ at 'BeforeCommit' must leave the project record already carrying the
exact bytes the completed transition wrote, under the same transaction id;
anything else would mean the matrix is recovering a state production never
produces.
-}
faithfulDescriptorCase :: IO ()
faithfulDescriptorCase =
    withStore $ \store -> do
        reopened <-
            withInterruptedTransaction BeforeCommit TxnOpenProject store $
                runEntry store $ \session ->
                    fmap (fmap (const ())) (openProjectJournal session plan)

        -- The project target carries exactly the bytes the completed transition
        -- wrote, stamped with that transition's own id.
        materialized <- expect =<< inEntry reopened (\session -> readProjectTarget session)
        case materialized of
            Nothing -> assertFailure "expected the project target to be materialized"
            Just record -> do
                transactionRecordPayload record @?= encodeFields ["open"]
                transactionRecordStamp record @?= Just 1

        -- And the coordinator has not committed. The journal reader drives
        -- recovery itself, so the state it reports is the recovered one.
        state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
        state @?= OpenProject

-- | The project journal record, read through the transaction stamp decoder.
readProjectTarget ::
    ProtectedSession session ->
    IO (Either SessionError (Maybe TransactionRecord))
readProjectTarget session = do
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> case filter (isRole ProjectRole) keys of
            [key] -> do
                observed <- readTransactionRecord session key
                pure (either (Left . SessionRecordCorrupt . transactionErrorMessage) Right observed)
            other ->
                pure
                    ( Left
                        ( SessionRecordCorrupt
                            ("expected one project record, found " <> Text.pack (show (length other)))
                        )
                    )

data SomeOpenSession where
    SomeOpenSession ::
        OperationSession scope planId ->
        ProjectPermit scope planId ->
        SomeOpenSession

data SomePrepareInput where
    SomePrepareInput ::
        BrokerEpoch brokerGeneration ->
        OperationSession scope planId ->
        FenceEpoch scope planId ->
        ProjectPermit scope planId ->
        SomePrepareInput

{- | A permit escaping its entry, so a case can put the transition under test
alone inside the interruption fixture.

The fixture below reproduces one transaction, so anything the case needs
/before/ that transaction has to be durable before the snapshot is taken.
-}
data SomeProjectPermit where
    SomeProjectPermit :: ProjectPermit scope planId -> SomeProjectPermit

data SomeClosingPermit where
    SomeClosingPermit :: ClosingProjectPermit scope planId -> SomeClosingPermit

data SomeAcknowledgeInput where
    SomeAcknowledgeInput ::
        OperationSession scope planId ->
        PreparedGate ->
        ProjectPermit scope planId ->
        SomeAcknowledgeInput

openProjectFixture :: ProtectedStore -> IO SomeProjectPermit
openProjectFixture store = do
    opened <-
        inEntry store $ \session ->
            fmap (fmap SomeProjectPermit) (openProjectJournal session plan)
    expect opened

closingProjectFixture :: ProtectedStore -> IO SomeClosingPermit
closingProjectFixture store = do
    closing <- inEntry store $ \session -> do
        permit <- openProjectJournal session plan
        case permit of
            Left failure -> pure (Left failure)
            Right current ->
                fmap (fmap SomeClosingPermit) (beginClosingProject session plan 7 current)
    expect closing

acknowledgeInputFixture :: ProtectedStore -> IO SomeAcknowledgeInput
acknowledgeInputFixture store = do
    prepared <- inEntry store $ \session ->
        withPrepared session $ \_ sess _ gate permit ->
            pure (Right (SomeAcknowledgeInput sess gate permit))
    expect prepared

openSessionFixture :: ProtectedStore -> IO SomeOpenSession
openSessionFixture store = do
    opened <- inEntry store $ \session ->
        withOpenSession session $ \_ sess permit ->
            pure (Right (SomeOpenSession sess permit))
    expect opened

prepareInputFixture :: ProtectedStore -> IO SomePrepareInput
prepareInputFixture store = do
    prepared <- inEntry store $ \session ->
        withOpenSession session $ \epoch sess permit -> do
            fence <- establishInitialFence session plan 1
            case fence of
                Left failure -> pure (Left failure)
                Right liveFence -> do
                    registered <- registerOperationIntent session sess "op-1" NoHistory permit
                    pure
                        ( fmap
                            (SomePrepareInput epoch sess liveFence)
                            registered
                        )
    expect prepared

-- ---------------------------------------------------------------------------
-- Reproducing an interrupted transaction

{- | Where a process death can leave a lifecycle transaction.

The redo coordinator publishes an @Applying@ descriptor, materializes that
descriptor's targets in order, then publishes @Idle@. Those are the only three
places a death is distinguishable, and each leaves a different durable state.
-}
data InterruptionPoint
    = -- | The descriptor is published and no target is materialized.
      AfterApplying
    | -- | The first @n@ of the descriptor's targets are materialized.
      AfterTarget Int
    | -- | Every target is materialized and the commit has not happened.
      BeforeCommit
    deriving (Eq)

instance Show InterruptionPoint where
    show AfterApplying = "the descriptor is published and no target is materialized"
    show (AfterTarget count) = "the first " <> show count <> " target(s) are materialized"
    show BeforeCommit = "every target is materialized and the commit has not happened"

{- | The role a record key names, which is also the descriptor's target order.

Every record key the journal owns begins with its role, so the role of a
materialized target is a property of the key rather than something the fixture
has to be told. The order below is the order the coordinator applies them in for
the one multi-target transition — an operation's intent is durable before the
session that lists it, so a crash between the two leaves an unlisted member
rather than a member with no record.
-}
data RecordRole = OperationRole | SessionRole | ProjectRole
    deriving (Eq, Ord, Show, Enum, Bounded)

isRole :: RecordRole -> RecordKey -> Bool
isRole role key = roleOf key == Just role

roleOf :: RecordKey -> Maybe RecordRole
roleOf key
    | "op." `Text.isPrefixOf` text = Just OperationRole
    | "session." `Text.isPrefixOf` text = Just SessionRole
    | "project." `Text.isPrefixOf` text = Just ProjectRole
    | otherwise = Nothing
  where
    text = recordKeyText key

{- | Leave the store holding the durable state a death at @point@ leaves.

Nothing in the coordinator participates, because a dead process leaves a record
and nothing else. The transition runs once, normally, so the descriptor is the
one production publishes rather than one the fixture invented: its sequence, its
targets, their roles, and their exact desired payloads all come out of the
records the real transaction wrote. The store's whole directory is then restored
from the snapshot taken before it ran — which is a pre-transition store,
versions included — and the coordinator is compare-and-swapped to @Applying@
with that descriptor, with the first @n@ of its targets stamped.

The returned store is the reopened one, exactly as a fresh invocation finds it.
-}
withInterruptedTransaction ::
    InterruptionPoint ->
    TxnKind ->
    ProtectedStore ->
    IO () ->
    IO ProtectedStore
withInterruptedTransaction point kind store transition = do
    let root = protectedStoreRoot store
        snapshot = takeDirectory root </> "interrupted-snapshot"
    copyTree root snapshot
    transition
    published <- publishedTransaction store
    removePathForcibly root
    copyTree snapshot root
    restored <- reopenStore store
    installApplying restored point kind published
    reopenStore restored

-- | Copy a directory tree, so a snapshot is the store itself rather than a
-- reconstruction of it — record versions and all.
copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
    removePathForcibly to
    createDirectoryIfMissing True to
    entries <- listDirectory from
    mapM_ copyEntry entries
  where
    copyEntry name = do
        let source = from </> name
            destination = to </> name
        nested <- doesDirectoryExist source
        if nested
            then copyTree source destination
            else copyFile source destination

{- | What the completed transition wrote: its id, and its targets in order. -}
data PublishedTransaction = PublishedTransaction
    { publishedSequence :: Word64
    , publishedTargets :: [(RecordKey, ByteString)]
    }

publishedTransaction :: ProtectedStore -> IO PublishedTransaction
publishedTransaction store = do
    stamped <- expect =<< inEntry store stampedRecords
    case stamped of
        [] -> assertFailure "the transition stamped no target"
        _ -> do
            let latest = maximum (map (\(_, sequenceNumber, _) -> sequenceNumber) stamped)
                mine =
                    [ (key, payload)
                    | (key, sequenceNumber, payload) <- stamped
                    , sequenceNumber == latest
                    ]
            pure
                PublishedTransaction
                    { publishedSequence = latest
                    , publishedTargets = sortOn (roleOf . fst) mine
                    }

-- | Every record carrying a transaction stamp, with that stamp and its payload.
stampedRecords ::
    ProtectedSession session ->
    IO (Either SessionError [(RecordKey, Word64, ByteString)])
stampedRecords session = do
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> collect keys []
  where
    collect [] found = pure (Right (reverse found))
    collect (key : rest) found = do
        observed <- readTransactionRecord session key
        case observed of
            Left failure -> pure (Left (SessionRecordCorrupt (transactionErrorMessage failure)))
            Right (Just record)
                | Just sequenceNumber <- transactionRecordStamp record ->
                    collect rest ((key, sequenceNumber, transactionRecordPayload record) : found)
            _ -> collect rest found

{- | Publish the @Applying@ descriptor, then stamp the chosen prefix of it.

The expectation each target carries is read from the restored store, so it is
the expectation the real transition recorded: the descriptor is rebuilt against
the same pre-transition versions the coordinator saw.
-}
installApplying :: ProtectedStore -> InterruptionPoint -> TxnKind -> PublishedTransaction -> IO ()
installApplying store point kind published = do
    outcome <- withProtectedEntry store $ \session -> do
        targets <- traverse (restoredTarget session) (publishedTargets published)
        let descriptor =
                TransactionDescriptor
                    { descriptorSequence = publishedSequence published
                    , descriptorPlan = plan
                    , descriptorKind = kind
                    , descriptorTargets = targets
                    }
        key <-
            either
                (assertFailure . Text.unpack . transactionErrorMessage)
                pure
                (coordinatorKey plan)
        current <- readProtectedRecord session key >>= either (assertFailure . show) pure
        -- A first transition creates the coordinator on the way in, so before
        -- it there is no record at all; every later one finds the committed
        -- Idle record it advances from.
        let expectation = maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) current
        applying <-
            compareAndSwapProtectedRecord
                session
                key
                expectation
                (encodeCoordinator (CoordinatorApplying descriptor))
        _ <- either (assertFailure . show) pure applying
        mapM_ (materialize session) (take materializedCount (publishedTargets published))
        pure (Right ())
    either (assertFailure . show) pure outcome
  where
    restoredTarget ::
        ProtectedSession session ->
        (RecordKey, ByteString) ->
        IO TransactionTarget
    restoredTarget session (key, payload) = do
        observed <- readTransactionRecord session key
        record <-
            either
                (assertFailure . Text.unpack . transactionErrorMessage)
                pure
                observed
        pure (targetFor key record payload)

    targetFor key record payload = case roleOf key of
        Just ProjectRole -> projectTransactionTarget key record payload
        Just SessionRole -> sessionTransactionTarget key record payload
        _ -> operationTransactionTarget key record payload

    materialize ::
        ProtectedSession session ->
        (RecordKey, ByteString) ->
        IO ()
    materialize session (key, payload) = do
        observed <- readProtectedRecord session key >>= either (assertFailure . show) pure
        let expectation = maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) observed
        written <-
            compareAndSwapProtectedRecord
                session
                key
                expectation
                (stampTarget (publishedSequence published) payload)
        _ <- either (assertFailure . show) pure written
        pure ()

    materializedCount = case point of
        AfterApplying -> 0
        AfterTarget count -> count
        BeforeCommit -> length (publishedTargets published)

reopenStore :: ProtectedStore -> IO ProtectedStore
reopenStore store = do
    reopened <- openProtectedStore (protectedStoreRoot store)
    case reopened of
        Left failure -> assertFailure (show failure)
        Right store' -> pure store'

-- ---------------------------------------------------------------------------
-- Harness

withStore :: (ProtectedStore -> IO ()) -> IO ()
withStore use =
    withSystemTempDirectory "hostbootstrap-session" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> use store

{- | Run one action inside the store's exclusive entry. Each call is a separate
entry, so a test that reopens between two of them is modelling two separate
invocations.
-}
{- | Run one action inside the entry and fail the case on a refusal. Used where
the case's point is that the protocol succeeds.
-}
runEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either SessionError ())) ->
    IO ()
runEntry store action =
    inEntry store action >>= either (assertFailure . sessionErrorMessage) pure

inEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either SessionError result)) ->
    IO (Either SessionError result)
inEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . SessionStoreFailure) id outcome)

withEpoch ::
    ProtectedSession session ->
    (forall brokerGeneration. BrokerEpoch brokerGeneration -> IO (Either SessionError result)) ->
    IO (Either SessionError result)
withEpoch session use =
    Fixture.withFixtureInstalledProject $ \project -> do
        opened <- openProtectedStore (sessionStoreRoot session </> "session-broker")
        case opened of
            Left failure -> pure (Left (SessionStoreFailure failure))
            Right brokerStore -> do
                outcome <-
                    withProductionRoot brokerStore project Authority.ProjectUp $ \root ->
                        Right <$> use (rootAuthorityEpoch (productionRootAuthority root))
                pure $ case outcome of
                    Left failure ->
                        Left (SessionRecordCorrupt (modeErrorMessage failure))
                    Right result -> result

-- | An open journal, a fresh broker epoch, and one open session.
withOpenSession ::
    ProtectedSession session ->
    ( forall brokerGeneration scope planId.
      BrokerEpoch brokerGeneration ->
      OperationSession scope planId ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
withOpenSession session use = do
    permit <- openProjectJournal session plan
    case permit of
        Left failure -> pure (Left failure)
        Right p -> withEpoch session $ \epoch -> do
            opened <- openOperationSession session epoch plan "session-a" p
            case opened of
                Left failure -> pure (Left failure)
                Right (sess, next) -> use epoch sess next

-- | An open session with @op-1@ registered, a settled fence, and one prepare done.
withPrepared ::
    ProtectedSession session ->
    ( forall scope planId brokerGeneration.
      BrokerEpoch brokerGeneration ->
      OperationSession scope planId ->
      FenceEpoch scope planId ->
      PreparedGate ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
withPrepared session use =
    withOpenSession session $ \epoch sess permit -> do
        fenceOutcome <- establishInitialFence session plan 1
        case fenceOutcome of
            Left failure -> pure (Left failure)
            Right fence -> do
                registered <- registerOperationIntent session sess "op-1" NoHistory permit
                case registered of
                    Left failure -> pure (Left failure)
                    Right afterIntent ->
                        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" afterIntent $
                            \gate next -> use epoch sess fence gate next

preparedGateAttemptIs :: PreparedGate -> Word64 -> IO ()
preparedGateAttemptIs gate expected = preparedGateAttempt gate @?= expected

preparedGateFenceIs :: PreparedGate -> Word64 -> IO ()
preparedGateFenceIs gate expected = preparedGateFence gate @?= expected

expect :: (Show err) => Either err value -> IO value
expect (Right value) = pure value
expect (Left failure) = assertFailure ("expected success, got " <> show failure)

expect' :: (Show err) => Either err value -> IO value
expect' = expect

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
