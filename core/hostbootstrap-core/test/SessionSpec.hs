{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The protected operation session, fence rotation, and prepare
compare-and-swap.

Every case here runs against a real protected store on a real filesystem, so a
"crash" is modelled the only honest way: by stopping between two durable writes
and then reopening the store, exactly as an interrupted invocation leaves it.
-}
module SessionSpec (tests, runFenceDelayProbe, withInterruptedProductionTransaction) where

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeException, evaluate, try)
import qualified Crypto.Hash as Hash
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (find, nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import qualified Fixture
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
import HostBootstrap.Authority.Kernel (commandReservationKernel)
import qualified HostBootstrap.Authority.Testing as AuthorityFixture
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
import HostBootstrap.Lifecycle.Mode (
    AcquisitionJournal,
    BoundRunLease,
    LifecycleCursor,
    LifecycleError,
    ModeError (ModeMalformedRecord),
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    acquisitionJournalRunLease,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalStableScope,
    bindRunLease,
    boundRunLeasePlanDigest,
    boundRunLeaseRunText,
    boundRunLeaseSpecDigest,
    lifecycleCursorFrame,
    lifecycleCursorPhase,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    lifecycleErrorMessage,
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
    withProductionLifecycleProfile,
    withProductionRoot,
    withRecoveredProductionLifecycleProfile,
    withTeardownLifecycleCursor,
 )
import HostBootstrap.Lifecycle.Prepared (decodeFields, encodeFields)
import qualified HostBootstrap.Lifecycle.Prepared as Prepared
import HostBootstrap.Lifecycle.Session hiding (
    AcquisitionJournal,
    LifecycleCursor,
    LifecycleError,
    acquisitionJournalBrokerGeneration,
    acquisitionJournalRecordVersion,
    acquisitionJournalRootVerb,
    acquisitionJournalRunLease,
    acquisitionJournalSnapshotDigest,
    acquisitionJournalStableScope,
    lifecycleCursorFrame,
    lifecycleCursorPhase,
    lifecycleCursorRecordVersion,
    lifecycleCursorVerb,
    lifecycleErrorMessage,
    withAcquisitionJournalPhase,
    withCurrentLifecycleCursor,
    withExecuteLifecycleCursor,
    withLifecycleCursor,
    withTeardownLifecycleCursor,
 )
import HostBootstrap.Lifecycle.Session.Testing
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
import HostBootstrap.ProjectPlan.Frame (
    ProjectFrame,
    withCurrentFrame,
 )
import HostBootstrap.ProjectPlan.Snapshot (
    BoundPlanSnapshot,
    PlanDigestBinding,
    SnapshotError (SnapshotVerificationError),
    withBoundPlanSnapshot,
    withFreshBoundPlanSnapshot,
 )
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError (ProtectedInvalid),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    mkRecordName,
    openProtectedStore,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    protectedStoreRoot,
    readProtectedRecord,
    recordKeyText,
    recordNameIdentity,
    recordTupleSeparator,
    recordVersionWord,
    sessionStoreRoot,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (
    lifecyclePlanFromProjectPlan,
    lifecyclePlanSnapshot,
    stepExecutionFor,
 )
import HostBootstrap.Service (emptyServiceRegistry)
import HostBootstrap.Step (
    Step,
    StepFrame (..),
    StepObservation (StepChanged),
    StepPlan,
    contextInitStep,
    deployKindStep,
    deployVMStep,
    mkStepPlan,
    stepIdentity,
 )
import HostBootstrap.Substrate (
    Arch (Arm64),
    Substrate (..),
    SubstrateName (LinuxCpu),
 )
import qualified PrepareFixture
import qualified SourceGuard
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
        , testGroup "recorded operation numeric admission" numericOperationTests
        , testGroup "prepared record field codec" preparedRecordCodecTests
        , testGroup "prepared fixture addresses" preparedFixtureAddressTests
        , testGroup "the prepare compare-and-swap" prepareTests
        , testGroup "live operation admission" liveOperationAdmissionTests
        , testGroup "recovery" recoveryTests
        , testGroup "recordless session members" recordlessMemberTests
        , testGroup "abandoned-run admission" admissionTests
        , testGroup "canonical transaction wire" transactionWireTests
        , testGroup "transaction recovery" transactionRecoveryTests
        , testCase "the transaction testing unit exposes only descriptor data" $ do
            description <- SourceGuard.readPackageDescription
            let requiredStanza name =
                    maybe (assertFailure ("missing stanza: " <> name)) pure
                        (SourceGuard.namedStanza name description)
                transactionModule = "HostBootstrap.Lifecycle.Transaction"
            testingUnit <- requiredStanza "library lifecycle-transaction-internal"
            SourceGuard.fieldValues "visibility" testingUnit @?= ["private"]
            SourceGuard.fieldModules "exposed-modules" testingUnit
                @?= ["HostBootstrap.Lifecycle.Session.Testing"]
            assertBool "the testing unit retains its hidden Transaction implementation"
                (transactionModule `elem` SourceGuard.fieldModules "other-modules" testingUnit)
            mainLibrary <- requiredStanza "library"
            assertBool "the main library retains its own hidden Transaction implementation"
                (transactionModule `elem` SourceGuard.fieldModules "other-modules" mainLibrary)
            assertBool "the main library does not expose Transaction"
                (transactionModule `notElem` SourceGuard.fieldModules "exposed-modules" mainLibrary)
        , testGroup "encoded record identities" encodedRecordIdentityTests
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
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> recordTupleSeparator <> "production")
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
                    <> recordTupleSeparator <> "production" <> recordTupleSeparator
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
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> recordTupleSeparator <> "production")
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
                snapshotKey <- recordKeyFor ("snapshot." <> installedProjectName project <> recordTupleSeparator <> "production")
                otherSnapshotKey <- recordKeyFor ("snapshot." <> installedProjectName otherProject <> recordTupleSeparator <> "production")
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
    , testCase "recovery refuses a noncanonical lease epoch before acquisition" $
        withAcquisitionPlanFixture $ \store project _root _lease _bound _binding _projectPlan _projectRoot -> do
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> recordTupleSeparator <> "production")
            leaseRecord <- readRequiredRecord store leaseKey
            let fields = decodeFields (protectedRecordBytes leaseRecord)
            _ <-
                rewriteRecordFields
                    store
                    leaseKey
                    (replaceField 1 ("0" <> fields !! 1))
            reopened <- reopenStore store
            before <- protectedImage reopened
            terminalCallbacks <- newIORef (0 :: Int)
            openCallbacks <- newIORef (0 :: Int)
            -- Strict decoding refuses before current-version recovered evidence
            -- exists; retained-evidence and CAS controls above hold the journal.
            refused <-
                withBoundPlanSnapshot
                    reopened
                    project
                    (countingCallback terminalCallbacks)
                    (\_ _ _ _ _ _ _ -> countingCallback openCallbacks ())
            refused @?= Left (SnapshotVerificationError (ModeMalformedRecord (recordKeyText leaseKey)))
            readIORef terminalCallbacks >>= (@?= 0)
            readIORef openCallbacks >>= (@?= 0)
            image <- protectedImage reopened
            image @?= before
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
            leaseKey <- recordKeyFor ("lease." <> installedProjectName project <> recordTupleSeparator <> "production")
            leaseRecord <- readRequiredRecord store leaseKey
            let canonical = protectedRecordBytes canonicalRecord
                differentPlan = "different-plan-digest"
                mutations =
                    [ ("stable scope", replaceField 1 "production-drift")
                    ,
                        ( "lease version"
                        , replaceField
                            6
                            (Text.pack (show (recordVersionWord (protectedRecordVersion leaseRecord) + 1)))
                        )
                    , ("specification digest", replaceField 8 "different-spec-digest")
                    ,
                        ( "snapshot and lease-plan digest"
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

foreignProjectReservationCase :: IO ()
foreignProjectReservationCase =
    Fixture.withFixtureInstalledProject $ \verifiedProject -> do
        let verifiedName = installedProjectName verifiedProject
            foreignName = if verifiedName == "foreign-installed-project" then "other-installed-project" else "foreign-installed-project"
        exercise <-
            expect $
                AuthorityFixture.withInstalledProjectKernel foreignName $ \foreignProject ->
                    withAcquisitionPlanFixtureForConfigUsing
                        (\use -> use foreignProject)
                        cursorStepPlan
                        (\name rootPath -> projectConfigForFrame name rootPath "host-orchestrator-0")
                        Authority.ProjectUp
                        $ \store project root lease bound binding projectPlan projectRoot -> do
                            installedProjectName project @?= foreignName
                            assertBool "the two raw installed project names differ" (verifiedName /= foreignName)
                            let supplied =
                                    Fixture.context $
                                        projectConfigForFrame
                                            foreignName
                                            (Text.pack (canonicalProjectRootPath projectRoot))
                                            "host-orchestrator-0"
                            frameAction <-
                                expect $
                                    withCurrentFrame projectPlan supplied $ \_current frame _validated -> do
                                        opened <- withAcquisitionJournal root lease bound binding projectPlan $ \journal -> do
                                            cursored <- withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                                                executed <- withExecuteLifecycleCursor prepareCursor $ \cursor -> do
                                                    let reservation =
                                                            commandReservationKernel
                                                                root
                                                                (acquisitionJournalSnapshotDigest journal)
                                                                (lifecycleCursorPhase cursor)
                                                                (lifecycleCursorFrame cursor)
                                                        invocations = Map.filterWithKey (\key _ -> "invocation." `Text.isPrefixOf` key)
                                                    before <- protectedImage store
                                                    refused <- reserveCurrentLifecycleCommandKernel verifiedProject journal cursor reservation
                                                    case refused of
                                                        Left (Authority.AuthorityStoreNotOurs expected observed) -> do
                                                            expected @?= verifiedName
                                                            observed @?= foreignName
                                                        Left failure -> assertFailure ("the reservation bridge refused before the exact project comparison: " <> show failure)
                                                        Right _ -> assertFailure "the reservation bridge adopted the journal's foreign project identity"
                                                    after <- protectedImage store
                                                    after @?= before
                                                    invocations after @?= invocations before
                                                    admitted <- expect =<< reserveCurrentLifecycleCommandKernel project journal cursor reservation
                                                    Authority.commandAuthorityFrame admitted @?= lifecycleCursorFrame cursor
                                                    lifecyclePhaseName (Authority.commandAuthorityPhase admitted) @?= "execute"
                                                    committed <- protectedImage store
                                                    Map.size (invocations committed) @?= Map.size (invocations before) + 1
                                                expect executed
                                            expect cursored
                                        expect opened
                            frameAction
        exercise

lifecycleCursorTests :: [TestTree]
lifecycleCursorTests =
    [ testCase "the reservation bridge refuses a foreign journal against the independently verified executable identity" foreignProjectReservationCase
    , testCase "fresh admission atomically hands the acquisition seed to one exact frame" $
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
        withLifecycleCursorFixture $ \store _root _lease _bound _binding _projectPlan journal frame ->
            do
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
        withLifecycleCursorFixture $ \store root lease bound binding projectPlan journal frame ->
            do
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
        ( \projectName rootPath ->
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
withAcquisitionPlanFixtureForConfig =
    withAcquisitionPlanFixtureForConfigUsing Fixture.withFixtureInstalledProject

withAcquisitionPlanFixtureForConfigUsing ::
    ((forall projectId. InstalledProjectIdentity projectId -> IO result) -> IO result) ->
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
withAcquisitionPlanFixtureForConfigUsing openIdentity stepPlan configFor verb use =
    withSystemTempDirectory "hostbootstrap-acquisition-journal" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= expect
        openIdentity $ \(project :: InstalledProjectIdentity projectId) -> do
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
plan under that identity, and only then attempts acquisition admission.
-}
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
                                  ,
                                      ( recordVersionWord (protectedRecordVersion record)
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

encodedRecordIdentityTests :: [TestTree]
encodedRecordIdentityTests =
    [ testCase "session and operation tuple fields recover exact independent identities" $
        withStore $ \store -> do
            let identities = [("a:b", "c"), ("a", "b:c"), ("Session_A", "Op_A"), ("session_a", "op_a")]
            mapM_
                ( \(sid, operation) -> do
                    runEntry store $ \session -> withEpoch session $ \epoch -> do
                        permit <- expect' =<< openProjectJournal session plan
                        (opened, next) <- expect' =<< openOperationSession session epoch plan sid permit
                        _ <- expect' =<< registerOperationIntent session opened operation NoHistory next
                        pure (Right ())
                    _ <- expect =<< inEntry store interpretHere
                    pure ()
                )
                identities
            reopened <- reopenStore store
            manifest <- expect =<< inEntry reopened (\session -> verifySessionManifest session plan)
            [ (sessionIdText (manifestSessionId member), manifestSessionOperations member)
              | member <- manifestSessions manifest
              ] @?= sortOn fst [(sid, [operation]) | (sid, operation) <- identities]
            manifestOperationCount manifest @?= length identities
            image <- protectedImage reopened
            let operations = Map.keys (Map.filterWithKey (\key _ -> "op." `Text.isPrefixOf` key) image)
            length operations @?= length identities
            expected <- traverse (\(sid, operation) -> expect (testOperationKey sid operation)) identities
            sortOn id operations @?= sortOn id (map recordKeyText expected)
    , testCase "session enumeration refuses a noncanonical identity instead of adopting its inverse" $
        withStore $ \store -> do
            runEntry store $ \session -> do
                _ <- expect' =<< openProjectJournal session plan
                pure (Right ())
            encoded <- expect (mkRecordName plan)
            key <- recordKeyFor ("session." <> encoded <> recordTupleSeparator <> "_")
            _ <- expect =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent "not adopted")
            before <- protectedImage store
            refused <- inEntry store (\session -> (() <$) <$> verifySessionManifest session plan)
            refused @?= Left (SessionRecordCorrupt "record identity")
            protectedImage store >>= (@?= before)
    , testCase "invalid and oversized session addresses refuse before durable effects" $
        withStore $ \store -> do
            runEntry store $ \session -> do
                _ <- expect' =<< openProjectJournal session plan
                pure (Right ())
            before <- protectedImage store
            mapM_
                ( \sid -> do
                    refused <- inEntry store $ \session -> withEpoch session $ \epoch -> do
                        permit <- expect' =<< openProjectJournal session plan
                        result <- openOperationSession session epoch plan sid permit
                        pure (() <$ result)
                    assertInvalidAddress refused
                    protectedImage store >>= (@?= before)
                )
                ["session..bad", Text.replicate 100 "A"]
            mapM_
                ( \oversized -> do
                    refused <- inEntry store (\session -> (() <$) <$> verifySessionManifest session oversized)
                    assertInvalidAddress refused
                    protectedImage store >>= (@?= before)
                )
                ["plan..bad", Text.replicate 100 "A"]
    , testCase "invalid and oversized operation addresses leave the open session unchanged" $
        withStore $ \store -> do
            SomeOpenSession opened permit <- openSessionFixture store
            before <- protectedImage store
            mapM_
                ( \operation -> do
                    refused <- inEntry store $ \session ->
                        (() <$) <$> registerOperationIntent session opened operation NoHistory permit
                    assertInvalidAddress refused
                    protectedImage store >>= (@?= before)
                )
                ["vendor:operation..bad", Text.replicate 100 "A"]
    ]
  where
    assertInvalidAddress :: Either SessionError () -> IO ()
    assertInvalidAddress (Left (SessionStoreFailure (ProtectedInvalid _))) = pure ()
    assertInvalidAddress other = assertFailure ("expected an invalid encoded address refusal, got " <> show other)

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
        withStore $ \store -> do
            (old, live) <- expect =<< inEntry store (\s -> do
                permit <- expect' =<< openProjectJournal s plan
                withEpoch s $ \epoch -> do
                    (sess, afterOpen) <- expect' =<< openOperationSession s epoch plan "session-a" permit
                    afterClose <- expect' =<< closeOperationSession s sess afterOpen
                    pure (Right (permit, afterClose)))
            manifest <- expect =<< inEntry store (\s -> verifySessionManifest s plan)
            [(sessionIdText (manifestSessionId member), manifestSessionIsOpen member) | member <- manifestSessions manifest]
                @?= [("session-a", False)]
            before <- protectedImage store
            again <- inEntry store $ \s -> withEpoch s $ \epoch ->
                (() <$) <$> openOperationSession s epoch plan "session-b" old
            again @?= Left (SessionStaleProjectPermit (projectPermitVersion old))
            protectedImage store >>= (@?= before)
            -- With no older Open session, the actual successor still admits work.
            runEntry store $ \s -> withEpoch s $ \epoch ->
                (() <$) <$> openOperationSession s epoch plan "session-b" live
    , testCase "a session open wins against a close presented the same permit" $
        withStore $ \store -> do
            (old, successor) <- expect =<< inEntry store (\s -> do
                permit <- expect' =<< openProjectJournal s plan
                withEpoch s $ \epoch -> do
                    (_, next) <- expect' =<< openOperationSession s epoch plan "session-a" permit
                    pure (Right (permit, next)))
            assertBool "session opening advances the shared version" (projectPermitVersion successor > projectPermitVersion old)
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> beginClosingProject s plan 7 old
            refused @?= Left (SessionStaleProjectPermit (projectPermitVersion old))
            inEntry store (\s -> readProjectJournalState s plan) >>= (@?= Right OpenProject)
            observed <- expect =<< inEntry store (\s -> openProjectJournal s plan)
            projectPermitVersion observed @?= projectPermitVersion successor
            manifest <- expect =<< inEntry store (\s -> verifySessionManifest s plan)
            [(sessionIdText (manifestSessionId member), manifestSessionIsOpen member) | member <- manifestSessions manifest]
                @?= [("session-a", True)]
            protectedImage store >>= (@?= before)
    , testCase "a close wins against a session open presented the same permit" $
        withStore $ \store -> do
            old <- expect =<< inEntry store (\s -> do
                permit <- expect' =<< openProjectJournal s plan
                _ <- expect' =<< beginClosingProject s plan 7 permit
                pure (Right permit))
            before <- protectedImage store
            refused <- inEntry store $ \s -> withEpoch s $ \epoch ->
                (() <$) <$> openOperationSession s epoch plan "session-a" old
            refused @?= Left (SessionProjectClosing plan)
            inEntry store (\s -> readProjectJournalState s plan) >>= (@?= Right (ClosingProject 7))
            assertBool "the losing opener created no session record" (all (not . Text.isPrefixOf "session.") (Map.keys before))
            protectedImage store >>= (@?= before)
    , closedSessionRefusalCase "a closed session cannot be reopened with the live permit" $ \s sess permit ->
        withEpoch s $ \epoch ->
            (() <$) <$> openOperationSession s epoch plan (sessionIdText (operationSessionId sess)) permit
    , closedSessionRefusalCase "a closed session cannot register an operation intent" $ \s sess permit ->
        (() <$) <$> registerOperationIntent s sess "op-after-close" NoHistory permit
    , closedSessionRefusalCase "a closed session cannot be closed a second time" $ \s sess permit ->
        (() <$) <$> closeOperationSession s sess permit
    , testCase "beginning project close refuses a zero epoch" $
        withStore $ \store -> do
            SomeProjectPermit permit <- openProjectFixture store
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> beginClosingProject s plan 0 permit
            refused @?= Left (SessionRecordCorrupt "closing epoch must be positive")
            inEntry store (\s -> readProjectJournalState s plan) >>= (@?= Right OpenProject)
            protectedImage store >>= (@?= before)
    , testCase "beginning project close refuses a missing project" $
        withStore $ \store -> do
            SomeProjectPermit permit <- openProjectFixture store
            let missingPlan = "missing-project-plan"
            -- A missing read initializes only the coordinator; baseline afterwards.
            inEntry store (\s -> readProjectJournalState s missingPlan)
                >>= (@?= Left (SessionProjectMissing missingPlan))
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> beginClosingProject s missingPlan 7 permit
            refused @?= Left (SessionProjectMissing missingPlan)
            protectedImage store >>= (@?= before)
    , testCase "an Open project cannot be recorded Closed with another plan's Closing permit" $
        withStore $ \store -> do
            runEntry store $ \s -> (() <$) <$> openProjectJournal s plan
            let otherPlan = "another-project-plan"
            closing <- expect =<< inEntry store (\s -> do
                permit <- expect' =<< openProjectJournal s otherPlan
                beginClosingProject s otherPlan 7 permit)
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> recordClosedProject s plan 7 closing
            refused @?= Left (SessionRecordCorrupt "project is not closing")
            inEntry store (\s -> readProjectJournalState s plan) >>= (@?= Right OpenProject)
            inEntry store (\s -> readProjectJournalState s otherPlan) >>= (@?= Right (ClosingProject 7))
            protectedImage store >>= (@?= before)
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
    , testGroup "observed Released origins" releasedIntentOriginTests
    , testGroup "canonical Closing epochs" closingEpochRecordTests
    ]

releasedIntentOriginTests :: [TestTree]
releasedIntentOriginTests =
    [ testCase "a Released observation registers exactly once against its live successor" $
        withStore $ \store -> do
            SomeOpenSession sess permit <- terminalSessionFixture store "TeardownOutcomeUnknown" "Released"
            (_, original, released) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload released @?= encodeFields ["Released", sessionIdText (operationSessionId sess), "1", "1"]
            beforeObservation <- protectedImage store
            origin <- expect =<< inEntry store (\s -> readReleasedIntentOrigin s sess "op-1")
            protectedImage store >>= (@?= beforeObservation)
            successor <- expect =<< inEntry store (\s -> registerOperationIntent s sess "op-1" origin permit)
            assertBool "registration returns a newer journal permit" (projectPermitVersion successor > projectPermitVersion permit)
            (_, updated, intent) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload intent @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
            assertBool "registration replaces the observed physical record" (protectedRecordVersion updated /= protectedRecordVersion original)
            manifest <- expect =<< inEntry store (\s -> verifySessionManifest s plan)
            [ (sessionIdText (manifestSessionId member), manifestSessionIsOpen member, manifestSessionOperations member)
              | member <- manifestSessions manifest
              ] @?= [("session-a", True, ["op-1"])]
            manifestOperationCount manifest @?= 1
            live <- expect =<< inEntry store (\s -> openProjectJournal s plan)
            projectPermitVersion live @?= projectPermitVersion successor
            -- Reusing the ordinary value reaches the phase check on the live permit.
            assertIntentOriginRefusal store sess "op-1" origin successor "IntentRecorded"
    , testCase "reacquisition is refused from a phase that is not Released" $
        withStore $ \store -> do
            SomeOpenSession sess permit <- openSessionFixture store
            _ <- expect =<< inEntry store (\s -> registerOperationIntent s sess "op-1" NoHistory permit)
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> readReleasedIntentOrigin s sess "op-1"
            refused @?= Left (SessionIntentOriginRefused "op-1" "IntentRecorded")
            protectedImage store >>= (@?= before)
    , testCase "an AdoptionReleased record cannot mint a Released origin" $
        withStore $ \store -> do
            SomeOpenSession sess _ <- terminalSessionFixture store "AdoptionTeardownOutcomeUnknown" "AdoptionReleased"
            (_, _, adopted) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload adopted @?= encodeFields ["AdoptionReleased", sessionIdText (operationSessionId sess), "1", "1"]
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> readReleasedIntentOrigin s sess "op-1"
            refused @?= Left (SessionIntentOriginRefused "op-1" "AdoptionReleased")
            protectedImage store >>= (@?= before)
    , testCase "a same-content operation rewrite invalidates a Released origin" $
        withStore $ \store -> do
            SomeOpenSession sess permit <- terminalSessionFixture store "TeardownOutcomeUnknown" "Released"
            origin <- expect =<< inEntry store (\s -> readReleasedIntentOrigin s sess "op-1")
            (key, original, _) <- sessionOperationRecord store sess "op-1"
            version <- rewriteRecordBytes store key id
            rewritten <- readRequiredRecord store key
            protectedRecordBytes rewritten @?= protectedRecordBytes original
            recordVersionWord (protectedRecordVersion rewritten) @?= version
            assertBool "the same-content CAS changes only the physical version" (version > recordVersionWord (protectedRecordVersion original))
            assertIntentOriginRefusal store sess "op-1" origin permit "a changed record version"
            -- A fresh observation of that new version is accepted by the same live permit.
            fresh <- expect =<< inEntry store (\s -> readReleasedIntentOrigin s sess "op-1")
            _ <- expect =<< inEntry store (\s -> registerOperationIntent s sess "op-1" fresh permit)
            (_, _, intent) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload intent @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
    , testCase "a Released origin is refused after its record disappears" $
        withStore $ \store -> do
            SomeOpenSession sess permit <- terminalSessionFixture store "TeardownOutcomeUnknown" "Released"
            origin <- expect =<< inEntry store (\s -> readReleasedIntentOrigin s sess "op-1")
            (key, original, _) <- sessionOperationRecord store sess "op-1"
            _ <- expect =<< withProtectedEntry store (\s -> compareAndDeleteProtectedRecord s key (ExpectVersion (protectedRecordVersion original)))
            missing <- expect =<< withProtectedEntry store (\s -> readProtectedRecord s key)
            fmap protectedRecordBytes missing @?= Nothing
            assertIntentOriginRefusal store sess "op-1" origin permit "absent"
    , testCase "a Released origin cannot name another Released operation" $
        withStore $ \store -> do
            (SomeOpenSession sess permit, origin) <- expect =<< inEntry store (\s ->
                withOpenSession s $ \epoch opened afterOpen -> do
                    fence <- expect =<< establishInitialFence s plan 1
                    afterOne <- expect =<< recordTerminalOperation s epoch opened fence "op-1" "TeardownOutcomeUnknown" "Released" afterOpen
                    observed <- expect =<< readReleasedIntentOrigin s opened "op-1"
                    afterTwo <- expect =<< recordTerminalOperation s epoch opened fence "op-2" "TeardownOutcomeUnknown" "Released" afterOne
                    pure (Right (SomeOpenSession opened afterTwo, observed)))
            (firstKey, first, firstTarget) <- sessionOperationRecord store sess "op-1"
            (secondKey, second, secondTarget) <- sessionOperationRecord store sess "op-2"
            assertBool "the actual operation keys differ" (firstKey /= secondKey)
            protectedRecordVersion first @?= protectedRecordVersion second
            let released = encodeFields ["Released", sessionIdText (operationSessionId sess), "1", "1"]
            transactionRecordPayload firstTarget @?= released
            transactionRecordPayload secondTarget @?= released
            live <- expect =<< inEntry store (\s -> openProjectJournal s plan)
            projectPermitVersion live @?= projectPermitVersion permit
            assertIntentOriginRefusal store sess "op-2" origin permit "another operation key"
    , testCase "a Released origin cannot cross stores with matching key and version" $
        withStore $ \firstStore -> withStore $ \secondStore -> do
            SomeOpenSession firstSession _ <- terminalSessionFixture firstStore "TeardownOutcomeUnknown" "Released"
            origin <- expect =<< inEntry firstStore (\s -> readReleasedIntentOrigin s firstSession "op-1")
            SomeOpenSession secondSession permit <- terminalSessionFixture secondStore "TeardownOutcomeUnknown" "Released"
            (firstKey, first, _) <- sessionOperationRecord firstStore firstSession "op-1"
            (secondKey, second, _) <- sessionOperationRecord secondStore secondSession "op-1"
            firstKey @?= secondKey
            protectedRecordVersion first @?= protectedRecordVersion second
            protectedRecordBytes first @?= protectedRecordBytes second
            assertBool "the two protected stores have different identities" (protectedStoreIdentity firstStore /= protectedStoreIdentity secondStore)
            firstImage <- protectedImage firstStore
            assertIntentOriginRefusal secondStore secondSession "op-1" origin permit "another protected store"
            protectedImage firstStore >>= (@?= firstImage)
    , testCase "a Released origin is refused when its recorded phase changes" $
        withStore $ \store -> do
            SomeOpenSession sess permit <- terminalSessionFixture store "TeardownOutcomeUnknown" "Released"
            origin <- expect =<< inEntry store (\s -> readReleasedIntentOrigin s sess "op-1")
            (key, original, target) <- sessionOperationRecord store sess "op-1"
            stamp <- maybe (assertFailure "the released operation has no transaction stamp") pure (transactionRecordStamp target)
            let changedPayload = encodeFields ["AdoptionReleased", sessionIdText (operationSessionId sess), "1", "1"]
            version <- rewriteRecordBytes store key (const (stampTarget stamp changedPayload))
            assertBool "the phase mutation also advances the physical version" (version > recordVersionWord (protectedRecordVersion original))
            (_, changed, readable) <- sessionOperationRecord store sess "op-1"
            recordVersionWord (protectedRecordVersion changed) @?= version
            transactionRecordStamp readable @?= Just stamp
            transactionRecordPayload readable @?= changedPayload
            assertIntentOriginRefusal store sess "op-1" origin permit "AdoptionReleased"
    ]

-- These are genuine journal transitions; no provider/backend release is claimed.
terminalSessionFixture :: ProtectedStore -> Text -> Text -> IO SomeOpenSession
terminalSessionFixture store unknownPhase observedPhase =
    expect =<< inEntry store (\session ->
        withOpenSession session $ \epoch sess permit -> do
            fence <- expect =<< establishInitialFence session plan 1
            next <- expect =<< recordTerminalOperation session epoch sess fence "op-1" unknownPhase observedPhase permit
            pure (Right (SomeOpenSession sess next)))

recordTerminalOperation ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    OperationSession scope planId ->
    FenceEpoch scope planId ->
    Text ->
    Text ->
    Text ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ProjectPermit scope planId))
recordTerminalOperation session epoch sess fence operation unknownPhase observedPhase permit = do
    registered <- expect =<< registerOperationIntent session sess operation NoHistory permit
    withPreparedGate session sess epoch fence operation unknownPhase registered $ \gate prepared -> do
        advance <- expect =<< acknowledgeOutcome session sess gate observedPhase () prepared
        withOperationAdvance advance (\() next -> pure (Right next))

sessionOperationRecord ::
    ProtectedStore ->
    OperationSession scope planId ->
    Text ->
    IO (RecordKey, ProtectedRecord, TransactionRecord)
sessionOperationRecord store sess operation = do
    key <- expect (testOperationKey (sessionIdText (operationSessionId sess)) operation)
    raw <- readRequiredRecord store key
    observed <- expect =<< inEntry store (\session -> either (Left . SessionRecordCorrupt . transactionErrorMessage) Right <$> readTransactionRecord session key)
    target <- maybe (assertFailure "the fixture operation target is missing") pure observed
    transactionRecordVersion target @?= protectedRecordVersion raw
    stamp <- maybe (assertFailure "the fixture operation target is unstamped") pure (transactionRecordStamp target)
    assertBool "the operation's actual transaction stamp is positive" (stamp > 0)
    protectedRecordBytes raw @?= stampTarget stamp (transactionRecordPayload target)
    pure (key, raw, target)

assertIntentOriginRefusal ::
    ProtectedStore ->
    OperationSession scope planId ->
    Text ->
    IntentOrigin ->
    ProjectPermit scope planId ->
    Text ->
    IO ()
assertIntentOriginRefusal store sess operation origin permit detail = do
    live <- expect =<< inEntry store (\session -> openProjectJournal session plan)
    projectPermitVersion live @?= projectPermitVersion permit
    before <- protectedImage store
    refused <- inEntry store $ \session -> (() <$) <$> registerOperationIntent session sess operation origin permit
    refused @?= Left (SessionIntentOriginRefused operation detail)
    protectedImage store >>= (@?= before)

closingEpochRecordTests :: [TestTree]
closingEpochRecordTests =
    [ closingEpochRecordCase label raw (Left (SessionRecordCorrupt "project journal"))
    | (label, raw) <-
        [ ("refuses a negative decimal", "-1")
        , ("refuses an explicit positive sign", "+7")
        , ("refuses hexadecimal", "0x7")
        , ("refuses leading whitespace", " 7")
        , ("refuses trailing whitespace", "7 ")
        , ("refuses parenthesized decimal", "(7)")
        , ("refuses a leading zero", "07")
        , ("refuses Word64 overflow", "18446744073709551623")
        , ("refuses an overlong decimal", "100000000000000000000")
        ]
    ]
        <> [ closingEpochRecordCase "refuses zero as a Closing epoch" "0" (Left (SessionRecordCorrupt "project journal"))
           , closingEpochRecordCase "accepts canonical seven" "7" (Right (ClosingProject 7))
           , closingEpochRecordCase "accepts maximum Word64" "18446744073709551615" (Right (ClosingProject 18446744073709551615))
           ]

closingEpochRecordCase :: String -> Text -> Either SessionError ProjectJournalState -> TestTree
closingEpochRecordCase label raw expected =
    testCase label $
        withStore $ \store -> do
            SomeClosingPermit _ <- closingProjectFixture store
            inEntry store (\s -> readProjectJournalState s plan) >>= (@?= Right (ClosingProject 7))
            (key, original) <- soleRecordWithPrefix store "project."
            encodedPlan <- expect (mkRecordName plan)
            recordKeyText key @?= "project." <> encodedPlan
            originalTarget <- expect =<< inEntry store readProjectTarget
            target <- maybe (assertFailure "the actual Closing target is missing") pure originalTarget
            transactionRecordPayload target @?= encodeFields ["closing", "7"]
            transactionRecordVersion target @?= protectedRecordVersion original
            stamp <- maybe (assertFailure "the actual Closing target has no transaction stamp") pure (transactionRecordStamp target)
            assertBool "the real transaction stamp is positive" (stamp > 0)
            let payload = encodeFields ["closing", raw]
                seededBytes = stampTarget stamp payload
            seededVersion <- rewriteRecordBytes store key (const seededBytes)
            assertBool "the fixture CAS advances the target's physical version" (seededVersion > recordVersionWord (protectedRecordVersion original))
            seeded <- readRequiredRecord store key
            protectedRecordBytes seeded @?= seededBytes
            recordVersionWord (protectedRecordVersion seeded) @?= seededVersion
            decodedSeed <- expect =<< inEntry store readProjectTarget
            readable <- maybe (assertFailure "the seeded Closing target is missing") pure decodedSeed
            transactionRecordStamp readable @?= Just stamp
            transactionRecordPayload readable @?= payload
            recordVersionWord (transactionRecordVersion readable) @?= seededVersion
            before <- protectedImage store
            inEntry store (\s -> readProjectJournalState s plan) >>= (@?= expected)
            after <- readRequiredRecord store key
            protectedRecordBytes after @?= seededBytes
            recordVersionWord (protectedRecordVersion after) @?= seededVersion
            protectedImage store >>= (@?= before)

closedSessionRefusalCase ::
    String ->
    ( forall session scope planId.
      ProtectedSession session ->
      OperationSession scope planId ->
      ProjectPermit scope planId ->
      IO (Either SessionError ())
    ) ->
    TestTree
closedSessionRefusalCase name action =
    testCase name $
        withStore $ \store -> do
            (sess, live) <- expect =<< inEntry store (\s -> do
                permit <- expect' =<< openProjectJournal s plan
                withEpoch s $ \epoch -> do
                    (opened, afterOpen) <- expect' =<< openOperationSession s epoch plan "session-a" permit
                    afterClose <- expect' =<< closeOperationSession s opened afterOpen
                    pure (Right (opened, afterClose)))
            before <- protectedImage store
            refused <- inEntry store $ \s -> action s sess live
            refused @?= Left (SessionNotOpen (operationSessionId sess))
            protectedImage store >>= (@?= before)

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
    , testCase "re-establishing an observed fence keeps its persisted epoch" $
        withStore $ \store -> do
            first <- expect =<< inEntry store (\s -> establishInitialFence s plan 1)
            fenceEpochWord first @?= 1
            before <- protectedImage store
            -- The settled durable epoch wins over a later caller's proposal.
            resumed <- inEntry store (\s -> establishInitialFence s plan 99)
            fence <- expect resumed
            fenceEpochWord fence @?= 1
            protectedImage store >>= (@?= before)
    , testCase "an observed establishment survives reopening the store" $
        withStore $ \store -> do
            first <- expect =<< inEntry store (\s -> establishInitialFence s plan 4)
            fenceEpochWord first @?= 4
            before <- protectedImage store
            reopened <- reopenStore store
            fence <- expect =<< inEntry reopened (\s -> establishInitialFence s plan 77)
            fenceEpochWord fence @?= 4
            protectedImage reopened >>= (@?= before)
    , resumeFenceCase "FenceIntentRecorded"
    , resumeFenceCase "FenceOutcomeUnknown"
    , unsettledCurrentFenceCase "FenceIntentRecorded" FenceIntentRecorded
    , unsettledCurrentFenceCase "FenceOutcomeUnknown" FenceOutcomeUnknown
    , testCase "currentFence refuses an absent fence" $
        withStore $ \store -> do
            before <- protectedImage store
            refused <- inEntry store $ \s -> (() <$) <$> currentFence s plan
            refused @?= Left (SessionFenceMissing plan)
            protectedImage store >>= (@?= before)
    , testCase "rotation refuses after its observed fence record disappears" $
        withStore $ \store -> do
            fence <- expect =<< inEntry store (\s -> establishInitialFence s plan 1)
            fenceEpochWord fence @?= 1
            (key, record) <- soleRecordWithPrefix store "fence."
            _ <- expect =<< withProtectedEntry store (\s -> compareAndDeleteProtectedRecord s key (ExpectVersion (protectedRecordVersion record)))
            missing <- expect =<< withProtectedEntry store (\s -> readProtectedRecord s key)
            fmap protectedRecordBytes missing @?= Nothing
            before <- protectedImage store
            refused <- inEntry store $ \s -> fmap (fmap fenceEpochWord) (rotateFence s plan fence)
            refused @?= Left (SessionFenceMissing plan)
            protectedImage store >>= (@?= before)
    , testCase "rotation refuses the maximum observed fence epoch without wrapping" $
        withStore $ \store -> do
            (key, original) <- seedFenceRecord store "FenceObserved" "18446744073709551615"
            fence <- expect =<< inEntry store (\s -> currentFence s plan)
            fenceEpochWord fence @?= 18446744073709551615
            before <- protectedImage store
            refused <- inEntry store $ \s -> fmap (fmap fenceEpochWord) (rotateFence s plan fence)
            refused @?= Left (SessionFenceInvalid "a fence epoch cannot rotate past its maximum")
            after <- readRequiredRecord store key
            protectedRecordBytes after @?= protectedRecordBytes original
            protectedRecordVersion after @?= protectedRecordVersion original
            protectedImage store >>= (@?= before)
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

-- Fence rows are plain codec records, not transaction-stamped targets.
seedFenceRecord :: ProtectedStore -> Text -> Text -> IO (RecordKey, ProtectedRecord)
seedFenceRecord store phase epoch = do
    name <- expect (mkRecordName plan)
    key <- recordKeyFor ("fence." <> name)
    let bytes = encodeFields [phase, epoch]
    version <- expect =<< withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent bytes)
    record <- readRequiredRecord store key
    protectedRecordBytes record @?= bytes
    protectedRecordVersion record @?= version
    pure (key, record)

resumeFenceCase :: Text -> TestTree
resumeFenceCase phase =
    testCase ("resuming " <> Text.unpack phase <> " keeps the persisted proposal") $
        withStore $ \store -> do
            (key, seeded) <- seedFenceRecord store phase "4"
            reopened <- reopenStore store
            resumed <- expect =<< inEntry reopened (\session -> establishInitialFence session plan 77)
            fenceEpochWord resumed @?= 4
            observed <- expect =<< inEntry reopened (\session -> currentFence session plan)
            fenceEpochWord observed @?= 4
            final <- readRequiredRecord reopened key
            protectedRecordBytes final @?= encodeFields ["FenceObserved", "4"]
            assertBool "resumption advances the seeded physical record" (protectedRecordVersion final > protectedRecordVersion seeded)

unsettledCurrentFenceCase :: Text -> FencePhase -> TestTree
unsettledCurrentFenceCase rawPhase phase =
    testCase ("currentFence refuses " <> Text.unpack rawPhase) $
        withStore $ \store -> do
            _ <- seedFenceRecord store rawPhase "3"
            before <- protectedImage store
            refused <- inEntry store $ \session -> (() <$) <$> currentFence session plan
            refused @?= Left (SessionFenceUnsettled phase)
            protectedImage store >>= (@?= before)

-- ---------------------------------------------------------------------------
-- Classification

classificationTests :: [TestTree]
classificationTests =
    [ testGroup
        "recorded phase dispositions"
        [ testCase (Text.unpack phase) (classifyRecordedPhase phase @?= expected)
        | (phase, expected) <- recordedPhaseRows
        ]
    , testCase "an unrecognised phase is Unknown, not optimistically safe" $ do
        classifyRecordedPhase "SomethingThisBinaryDoesNotKnow" @?= UnknownDisposition
        classifyRecordedPhase "" @?= UnknownDisposition
    , testCase "phase spellings are exact rather than normalized" $
        mapM_
            (\raw -> classifyRecordedPhase raw @?= UnknownDisposition)
            [ "intentRecorded"
            , " IntentRecorded"
            , "IntentRecorded "
            , "\tIntentRecorded"
            , "IntentRecorded\n"
            , "(IntentRecorded)"
            , "\"IntentRecorded\""
            , "Reconcile.IntentRecorded"
            ]
    , testCase "the literal phase rows cover both authoritative declarations" phaseVocabularyParity
    , testGroup "nullary phase vocabulary reader" nullaryPhaseReaderTests
    ]

recordedPhaseRows :: [(Text, OperationDisposition)]
recordedPhaseRows =
    [ ("IntentRecorded", Continuable)
    , ("ReservationOutcomeUnknown", UnknownDisposition)
    , ("ReservationAbsent", FencedRetryable)
    , ("ReservationRetryFenced", Continuable)
    , ("Reserved", Continuable)
    , ("EffectOutcomeUnknown", UnknownDisposition)
    , ("EffectAbsent", FencedRetryable)
    , ("EffectRetryFenced", FencedRetryable)
    , ("ObservedManaged", Settled)
    , ("ObservedForeign", TerminalDisposition)
    , ("Committed", Settled)
    , ("TeardownOutcomeUnknown", UnknownDisposition)
    , ("TeardownObservedForeign", TerminalDisposition)
    , ("Released", Settled)
    , ("AdoptionIntentRecorded", Continuable)
    , ("AdoptionOutcomeUnknown", UnknownDisposition)
    , ("AdoptionObservedManaged", Settled)
    , ("AdoptionObservedAbsent", FencedRetryable)
    , ("AdoptionRetryFenced", FencedRetryable)
    , ("AdoptionObservedForeign", TerminalDisposition)
    , ("AdoptionRefused", TerminalDisposition)
    , ("AdoptionCommitted", Settled)
    , ("AdoptionTeardownOutcomeUnknown", UnknownDisposition)
    , ("AdoptionTeardownObservedForeign", TerminalDisposition)
    , ("AdoptionReleased", Settled)
    , ("RepairIntentRecorded", Continuable)
    , ("RepairEffectOutcomeUnknown", UnknownDisposition)
    , ("RepairObservedOriginal", FencedRetryable)
    , ("RepairRetryFenced", FencedRetryable)
    , ("RepairObservedTarget", Settled)
    , ("RepairObservedAbsent", TerminalDisposition)
    , ("RepairObservedUnexpected", TerminalDisposition)
    , ("RepairObservedForeign", TerminalDisposition)
    , ("RepairCommitted", Settled)
    , ("PhaseIntentRecorded", Continuable)
    , ("PhaseEffectOutcomeUnknown", UnknownDisposition)
    , ("PhaseObservedFrom", FencedRetryable)
    , ("PhaseRetryFenced", FencedRetryable)
    , ("PhaseObservedTo", Settled)
    , ("PhaseObservedAbsent", TerminalDisposition)
    , ("PhaseObservedUnexpected", TerminalDisposition)
    , ("PhaseObservedForeign", TerminalDisposition)
    , ("PhaseCommitted", Settled)
    , ("StepObservedTerminal", TerminalDisposition)
    , ("RecoveryAbandoned", TerminalDisposition)
    ]

-- DEVELOPMENT_PLAN/rationale.md#unresolved-outcomes-are-classified-explicitly
-- Declaration parity detects new vocabulary without deriving its expected class.
phaseVocabularyParity :: IO ()
phaseVocabularyParity =
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- SourceGuard.readPackageDescription
        reconcilePath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Reconcile"
        sessionPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Lifecycle.Session"
        reconcileSource <- readFile reconcilePath
        sessionSource <- readFile sessionPath
        produced <- expect (SourceGuard.nullaryDataConstructorNames "PersistedJournalPhase" reconcileSource)
        recorded <- expect (SourceGuard.nullaryDataConstructorNames "RecordedPhase" sessionSource)
        let allNames = map (Text.unpack . fst) recordedPhaseRows
            producerNames = filter (`notElem` ["StepObservedTerminal", "RecoveryAbandoned"]) allNames
        length allNames @?= 45
        length (nub allNames) @?= 45
        sort produced @?= sort producerNames
        sort recorded @?= sort allNames

nullaryPhaseReaderTests :: [TestTree]
nullaryPhaseReaderTests =
    [ testCase "comments, strings and another datatype do not enter the ordered sum" $ do
        let source = unlines
                [ "-- data Phase = CommentPretender"
                , "description = \"data Phase = StringPretender\""
                , "data Other = OtherFirst | OtherSecond"
                , "data Phase"
                , "    = First {- | FalseAlternative -}"
                , "    | Second"
                , "    deriving (Eq, Show, Enum, Bounded)"
                ]
        SourceGuard.nullaryDataConstructorNames "Phase" source @?= Right ["First", "Second"]
        SourceGuard.nullaryDataConstructorNames "Phase" "data Phase = Only deriving Eq" @?= Right ["Only"]
    , testCase "a missing datatype refuses" $
        assertRefused "missing" "data Other = First | Second"
    , testCase "ambiguous datatype declarations refuse" $
        assertRefused "ambiguous" "data Phase = First\ndata Phase = Second\n"
    , testCase "non-nullary and unfamiliar declaration shapes refuse" $
        mapM_ (uncurry assertRefused)
            [ ("payload", "data Phase = First Int | Second")
            , ("record", "data Phase = First { field :: Int }")
            , ("GADT", "data Phase where\n    First :: Phase\n")
            , ("parameterized", "data Phase a = First | Second")
            , ("newtype", "newtype Phase = First Int")
            ]
    , testCase "empty data declarations refuse" $
        mapM_ (assertRefused "empty") ["data Phase", "data Phase =", "data Phase = | First"]
    , testCase "duplicate constructors refuse" $
        assertRefused "duplicate constructor" "data Phase = First | First deriving (Eq, Show)"
    , testCase "malformed delimiters and trailing alternatives refuse" $
        mapM_ (uncurry assertRefused)
            [ ("unbalanced deriving", "data Phase = First | Second deriving (Eq, Show")
            , ("trailing alternative", "data Phase = First | Second |")
            , ("extra deriving tokens", "data Phase = First deriving (Eq) Other")
            ]
    ]
  where
    assertRefused :: String -> String -> IO ()
    assertRefused label source = case SourceGuard.nullaryDataConstructorNames "Phase" source of
        Left _ -> pure ()
        Right names -> assertFailure (label <> " was accepted as " <> show names)

-- ---------------------------------------------------------------------------
-- Prepared record field codec

preparedRecordCodecTests :: [TestTree]
preparedRecordCodecTests =
    [ testCase "Unicode fields encode to independently pinned UTF-8 bytes" $
        encodeFields ["phase", "\x0100", "tail"]
            @?= ByteString.pack [112, 104, 97, 115, 101, 9, 0xc4, 0x80, 9, 116, 97, 105, 108]
    , testCase "literal UTF-8 field bytes decode exactly and re-encode unchanged" $ do
        let bytes = ByteString.pack [0xc4, 0x80] <> "\tleft  right\t"
            fields = ["\x0100", "left  right", ""]
            decoded = decodeFields bytes
        decoded @?= fields
        encodeFields decoded @?= bytes
    , testCase "malformed UTF-8 fields return the failure sentinel" $
        mapM_
            (\bytes -> decodeFields (ByteString.pack bytes) @?= [])
            [[0xff], [0xc3, 0x28], [0xc4]]
    , testCase "ASCII whitespace and empty fields retain exact spelling" $
        -- Only nonempty field lists are in this round-trip domain. Empty
        -- bytes denote one empty field; they cannot also identify an empty list.
        mapM_
            ( \(fields, bytes) -> do
                encodeFields fields @?= bytes
                decodeFields bytes @?= fields
            )
            [ (["IntentRecorded", "session-1", "0"], "IntentRecorded\tsession-1\t0")
            , ([" leading ", "trailing "], " leading \ttrailing ")
            , ([""], "")
            , (["", ""], "\t")
            , (["", "middle", ""], "\tmiddle\t")
            ]
    ]

-- ---------------------------------------------------------------------------
-- Prepared fixture addresses

preparedFixtureAddressTests :: [TestTree]
preparedFixtureAddressTests =
    [ testCase "the fixture writes each exact independently derived operation key" $ do
        let coordinates =
                [ ("spec:plan.v1", "core:deploy-vm", "session-1", "session-1", "core.deploy-vm")
                , ("spec:other.v1", "core:deploy-vm", "session-1", "session-1", "core.deploy-vm")
                , ("spec:plan.v1", "core:deploy-vm", "vendor:session.v2/child", "vendor.session.v2..child", "core.deploy-vm")
                , ("spec:plan.v1", "core:deploy-vm/core:copy-source/guest-alias", "session-1", "session-1", "core.deploy-vm..core.copy-source..guest-alias")
                , ("spec:plan.v1", "Vendor:Thing_v2.part", "Session_A", "_session___a", "_vendor._thing__v2.part")
                ]
        observedKeys <- newIORef ([] :: [Text])
        mapM_
            ( \(requestedPlan, requestedOperation, requestedSession, encodedSession, encodedOperation) ->
                PrepareFixture.withGateForValuesStore requestedPlan requestedOperation requestedSession 3 4 $ \store gate -> do
                    -- The expected key uses literal identity spellings and a
                    -- separate Crypto.Hash digest, never the fixture's key helper.
                    let digest = Text.pack (show (Hash.hash (TextEncoding.encodeUtf8 requestedPlan) :: Hash.Digest Hash.SHA256))
                        expectedKey = "op." <> digest <> "." <> encodedSession <> "..." <> encodedOperation
                    keys <- expect =<< withProtectedEntry store listProtectedRecords
                    map recordKeyText keys @?= [expectedKey]
                    key <- recordKeyFor expectedKey
                    record <- readRequiredRecord store key
                    protectedRecordBytes record @?= "EffectOutcomeUnknown\t" <> TextEncoding.encodeUtf8 requestedSession <> "\t3\t4"
                    recordVersionWord (protectedRecordVersion record) @?= 1
                    ( Prepared.preparedGatePlan gate, Prepared.preparedGateOperation gate, Prepared.preparedGateSession gate
                        , Prepared.preparedGateFence gate, Prepared.preparedGateAttempt gate, Prepared.preparedGateJournalVersion gate
                        ) @?= (requestedPlan, requestedOperation, requestedSession, 3, 4, recordVersionWord (protectedRecordVersion record))
                    modifyIORef' observedKeys (<> map recordKeyText keys)
            )
            coordinates
        keys <- readIORef observedKeys
        length keys @?= length coordinates
        length (nub keys) @?= length coordinates
    , testCase "the successor advances the same canonical record from version one to two" $ do
        let requestedPlan = "spec:plan.v1"
            requestedOperation = "core:deploy-vm/core:copy-source/guest-alias"
            requestedSession = "vendor:session.v2/child"
            digest = Text.pack (show (Hash.hash (TextEncoding.encodeUtf8 requestedPlan) :: Hash.Digest Hash.SHA256))
            expectedKey = "op." <> digest <> ".vendor.session.v2..child...core.deploy-vm..core.copy-source..guest-alias"
        PrepareFixture.withSuccessorGate requestedPlan requestedOperation requestedSession 3 4 5 $ \store initial nextGate -> do
            let inspect gate attempt version = do
                    keys <- expect =<< withProtectedEntry store listProtectedRecords
                    map recordKeyText keys @?= [expectedKey]
                    key <- recordKeyFor expectedKey
                    record <- readRequiredRecord store key
                    protectedRecordBytes record
                        @?= "EffectOutcomeUnknown\t" <> TextEncoding.encodeUtf8 requestedSession <> "\t3\t" <> ByteStringChar8.pack (show attempt)
                    recordVersionWord (protectedRecordVersion record) @?= version
                    ( Prepared.preparedGatePlan gate, Prepared.preparedGateOperation gate, Prepared.preparedGateSession gate
                        , Prepared.preparedGateFence gate, Prepared.preparedGateAttempt gate, Prepared.preparedGateJournalVersion gate
                        ) @?= (requestedPlan, requestedOperation, requestedSession, 3, attempt, recordVersionWord (protectedRecordVersion record))
                    pure record
            initialRecord <- inspect initial 4 1
            successor <- nextGate
            successorRecord <- inspect successor 5 2
            recordVersionWord (protectedRecordVersion successorRecord)
                @?= recordVersionWord (protectedRecordVersion initialRecord) + 1
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
                key <- expect (testOperationKey (sessionIdText (operationSessionId sess)) "op-1")
                recorded <- expect =<< readTransactionRecord s key
                target <- maybe (assertFailure "the adapter entered without a durable unknown record") pure recorded
                let sid = sessionIdText (operationSessionId sess)
                    version = recordVersionWord (transactionRecordVersion target)
                    expectedFields = [plan, "op-1", sid, "1", "1", Text.pack (show version)]
                    expectedShow =
                        "PreparedGate {preparedGatePlan = " <> show plan
                            <> ", preparedGateOperation = " <> show ("op-1" :: Text)
                            <> ", preparedGateSession = " <> show sid
                            <> ", preparedGateFence = 1, preparedGateAttempt = 1, preparedGateJournalVersion = "
                            <> show version
                            <> "}"
                transactionRecordPayload target @?= encodeFields ["EffectOutcomeUnknown", sid, "1", "1"]
                Prepared.preparedGatePlan gate @?= plan
                Prepared.preparedGateOperation gate @?= "op-1"
                Prepared.preparedGateSession gate @?= sid
                Prepared.preparedGateJournalVersion gate @?= version
                Prepared.preparedGateFields gate @?= expectedFields
                show gate @?= expectedShow
                showsPrec 10 gate "" @?= expectedShow
                showsPrec 11 gate "" @?= "(" <> expectedShow <> ")"
                show (Just gate) @?= "Just (" <> expectedShow <> ")"
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
    , testCase "a prepare refuses an unsettled fence without changing its operation" $
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- prepareInputFixture store
            (fenceKey, _) <- soleRecordWithPrefix store "fence."
            let unsettled = encodeFields ["FenceIntentRecorded", "2"]
            _ <- rewriteRecordBytes store fenceKey (const unsettled)
            seeded <- readRequiredRecord store fenceKey
            protectedRecordBytes seeded @?= unsettled
            (operationKey, original, target) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload target @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
            callbacks <- newIORef (0 :: Int)
            before <- protectedImage store
            refused <- inEntry store $ \session ->
                withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \_ _ -> do
                    modifyIORef' callbacks (+ 1)
                    pure (Right ())
            refused @?= Left (SessionFenceUnsettled FenceIntentRecorded)
            readIORef callbacks >>= (@?= 0)
            after <- readRequiredRecord store operationKey
            protectedRecordBytes after @?= protectedRecordBytes original
            protectedRecordVersion after @?= protectedRecordVersion original
            protectedImage store >>= (@?= before)
    , testCase "a prepare presenting the fence that fenceOldPermits superseded is refused" $
        withStore $ \store -> do
            callbacks <- newIORef (0 :: Int)
            runEntry store $ \session ->
                withOpenSession session $ \epoch sess permit -> do
                    fence <- expect =<< establishInitialFence session plan 1
                    fenceEpochWord fence @?= 1
                    afterIntent <- expect =<< registerOperationIntent session sess "op-1" NoHistory permit
                    key <- expect (testOperationKey (sessionIdText (operationSessionId sess)) "op-1")
                    present <- expect =<< readProtectedRecord session key
                    original <- maybe (assertFailure "the registered operation is missing") pure present
                    fenced <- expect =<< fenceOldPermits session plan
                    oldPermitsFencedFrom fenced @?= 1
                    oldPermitsFencedTo fenced @?= 2
                    refused <-
                        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" afterIntent $ \_ _ -> do
                            modifyIORef' callbacks (+ 1)
                            pure (Right ())
                    refused @?= Left (SessionFenceSuperseded 1 2)
                    readIORef callbacks >>= (@?= 0)
                    observed <- expect =<< readProtectedRecord session key
                    after <- maybe (assertFailure "the refused prepare lost its operation") pure observed
                    protectedRecordBytes after @?= protectedRecordBytes original
                    protectedRecordVersion after @?= protectedRecordVersion original
                    decoded <- expect =<< readTransactionRecord session key
                    target <- maybe (assertFailure "the operation target is missing") pure decoded
                    transactionRecordPayload target @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
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
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- unknownOperationFixture store
            callbacks <- newIORef (0 :: Int)
            before <- protectedImage store
            blocked <- inEntry store $ \session ->
                withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \_ _ -> do
                    modifyIORef' callbacks (+ 1)
                    pure (Right ())
            blocked @?= Left (SessionUnclassifiedPhase "op-1" "SomeFuturePhase")
            readIORef callbacks >>= (@?= 0)
            protectedImage store >>= (@?= before)
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

{- | Open the route fixture's plan, so the descriptor and the digest come from
one interpretation rather than two computations of it.
-}
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
            runEntry store $ \s ->
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
            _ <- unknownOperationFixture store
            before <- protectedImage store
            swept <- inEntry store (\s -> recoverAbandonedSessions s plan)
            swept @?= Left (SessionUnclassifiedPhase "op-1" "SomeFuturePhase")
            protectedImage store >>= (@?= before)
    , testCase "a sweep with nothing open reports no work" $
        withStore $ \store -> do
            runEntry store $ \s -> (() <$) <$> openProjectJournal s plan
            swept <- inEntry store (\s -> recoverAbandonedSessions s plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 0
    ]

-- ---------------------------------------------------------------------------
-- Recordless session members

recordlessMemberTests :: [TestTree]
recordlessMemberTests =
    [ recordlessMemberCase "a listed operation without its record prevents session close" $ \session sess permit ->
        (() <$) <$> closeOperationSession session sess permit
    , recordlessMemberCase "a listed operation without its record prevents abandoned-session recovery" $ \session _ _ ->
        (() <$) <$> recoverAbandonedSessions session plan
    ]

recordlessMemberCase ::
    String ->
    ( forall session scope planId.
      ProtectedSession session ->
      OperationSession scope planId ->
      ProjectPermit scope planId ->
      IO (Either SessionError ())
    ) ->
    TestTree
recordlessMemberCase label action =
    testCase label $
        withStore $ \store -> do
            SomeOpenSession sess opened <- openSessionFixture store
            permit <- expect =<< inEntry store (\session -> registerOperationIntent session sess "op-1" NoHistory opened)
            manifest <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
            [ (sessionIdText (manifestSessionId member), manifestSessionIsOpen member, manifestSessionOperations member)
              | member <- manifestSessions manifest
              ] @?= [("session-a", True, ["op-1"])]
            manifestOperationCount manifest @?= 1
            (operationKey, operation, target) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload target @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
            (sessionKey, sessionRecord) <- soleRecordWithPrefix store "session."
            sessionTarget <- readLiveTarget store sessionKey
            let openMembers = encodeFields ["open", "1", "members", "op-1"]
            transactionRecordPayload sessionTarget @?= openMembers
            _ <- expect =<< withProtectedEntry store (\session ->
                compareAndDeleteProtectedRecord session operationKey (ExpectVersion (protectedRecordVersion operation)))
            absent <- expect =<< withProtectedEntry store (\session -> readProtectedRecord session operationKey)
            fmap protectedRecordBytes absent @?= Nothing
            live <- expect =<< inEntry store (\session -> openProjectJournal session plan)
            projectPermitVersion live @?= projectPermitVersion permit
            before <- protectedImage store
            refused <- inEntry store $ \session -> action session sess permit
            refused @?= Left (SessionOperationUnregistered "op-1")
            -- A manifest query would itself refuse this recordless state. Read
            -- the actual retained session row instead, without minting evidence.
            after <- readRequiredRecord store sessionKey
            protectedRecordBytes after @?= protectedRecordBytes sessionRecord
            protectedRecordVersion after @?= protectedRecordVersion sessionRecord
            retained <- readLiveTarget store sessionKey
            transactionRecordPayload retained @?= openMembers
            protectedImage store >>= (@?= before)

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
            runEntry store $ \s ->
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
            live <- expect =<< inEntry reopened (\s -> currentFence s plan)
            fenceEpochWord live @?= 2
    , testCase "a settled operation holds no authority, so it is not in the fence set" $
        withStore $ \store -> do
            runEntry store $ \s ->
                withPrepared s $ \_ sess _ gate permit -> do
                    _ <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                    pure (Right ())
            reopened <- reopenStore store
            fenced <- expect =<< inEntry reopened (\s -> fenceOldPermits s plan)
            oldPermitsFencedOperations fenced @?= []
    , testCase "fencing completes an unsettled proposal before successive rotations" $
        withStore $ \store -> do
            runEntry store $ \s -> (() <$) <$> openProjectJournal s plan
            (key, _) <- seedFenceRecord store "FenceIntentRecorded" "3"
            first <- expect =<< inEntry store (\s -> fenceOldPermits s plan)
            oldPermitsFencedFrom first @?= 3
            oldPermitsFencedTo first @?= 4
            afterFirst <- readRequiredRecord store key
            protectedRecordBytes afterFirst @?= encodeFields ["FenceObserved", "4"]
            second <- expect =<< inEntry store (\s -> fenceOldPermits s plan)
            oldPermitsFencedFrom second @?= 4
            oldPermitsFencedTo second @?= 5
            afterSecond <- readRequiredRecord store key
            protectedRecordBytes afterSecond @?= encodeFields ["FenceObserved", "5"]
    , testCase "fencing establishes an absent fence before rotating" $
        withStore $ \store -> do
            runEntry store $ \s -> (() <$) <$> openProjectJournal s plan
            before <- protectedImage store
            assertBool "the fence is genuinely absent" (all (not . Text.isPrefixOf "fence.") (Map.keys before))
            fenced <- expect =<< inEntry store (\s -> fenceOldPermits s plan)
            oldPermitsFencedFrom fenced @?= 1
            oldPermitsFencedTo fenced @?= 2
            live <- expect =<< inEntry store (\s -> currentFence s plan)
            fenceEpochWord live @?= 2
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
    , testGroup
        "namespaced operation recovery"
        [ testCase (Text.unpack sessionName) $
            withStore $ \store -> do
                _ <-
                    expect
                        =<< inEntry
                            store
                            ( \s -> withEpoch s $ \epoch -> do
                                permit <- expect' =<< openProjectJournal s plan
                                (sess, opened) <- expect' =<< openOperationSession s epoch plan sessionName permit
                                first <- expect' =<< registerOperationIntent s sess "core:deploy-vm/core:copy-source/guest-alias" NoHistory opened
                                second <- expect' =<< registerOperationIntent s sess "project:ensure-vm-provider" NoHistory first
                                _ <- expect' =<< registerOperationIntent s sess "vendor:thing.v2" NoHistory second
                                pure (Right ())
                            )
                reopened <- reopenStore store
                manifest <- expect =<< inEntry reopened (\s -> verifySessionManifest s plan)
                map (sessionIdText . manifestSessionId) (manifestSessions manifest) @?= [sessionName]
                let operations = ["core:deploy-vm/core:copy-source/guest-alias", "project:ensure-vm-provider", "vendor:thing.v2"]
                map manifestSessionOperations (manifestSessions manifest) @?= [operations]
                fenced <- expect =<< inEntry reopened (\s -> fenceOldPermits s plan)
                oldPermitsFencedOperations fenced @?= operations
                interpreted <- expect =<< inEntry reopened interpretHere
                map sessionIdText (interpretedRecoverySessions interpreted) @?= [sessionName]
                interpretedRecoveryOperations interpreted
                    @?= map (\name -> OperationAbandonedPreCall name "IntentRecorded") operations
                closed <- inEntry reopened (\s -> verifyAllSessionsClosed s plan)
                assertBool "recovered namespaced operations leave the session closed" (isRight closed)
        | sessionName <- ["session-a", "vendor:session.v2/child", "Vendor:Session_A.v2/Child"]
        ]
    , testCase "operation enumeration refuses a payload naming another session" $
        withStore $ \store -> do
            _ <-
                expect
                    =<< inEntry
                        store
                        ( \s -> withOpenSession s $ \_ sess permit -> do
                            _ <- expect' =<< registerOperationIntent s sess "op-1" NoHistory permit
                            key <- expect' (either (Left . SessionStoreFailure) Right (testOperationKey "session-a" "op-1"))
                            observed <- readProtectedRecord s key
                            case observed of
                                Right (Just record) -> do
                                    changed <- compareAndSwapProtectedRecord s key (ExpectVersion (protectedRecordVersion record)) (encodeFields ["IntentRecorded", "session-other", "0"])
                                    _ <- expect' (either (Left . SessionStoreFailure) Right changed)
                                    pure (Right ())
                                other -> assertFailure ("missing operation: " <> show other) >> pure (Right ())
                        )
            manifested <- inEntry store (\s -> verifySessionManifest s plan)
            case manifested of
                Left (SessionRecordCorrupt detail) ->
                    detail @?= "operation ownership at op." <> planKeyDigest <> ".session-a...op-1"
                other -> assertFailure ("expected inconsistent record ownership refusal, got " <> show other)
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
            _ <- unknownOperationFixture store
            fenced <- expect =<< inEntry store (\session -> fenceOldPermits session plan)
            manifest <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
            permit <- expect =<< inEntry store (\session -> openProjectJournal session plan)
            before <- protectedImage store
            outcome <- inEntry store $ \session -> withEpoch session $ \epoch ->
                (() <$) <$> interpretRecordedSessions session epoch manifest fenced permit
            outcome @?= Left (SessionUnclassifiedPhase "op-1" "SomeFuturePhase")
            protectedImage store >>= (@?= before)
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

-- | Run the whole fence → manifest → interpret chain over the fixture plan.
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
testOperationKey :: Text -> Text -> Either ProtectedError RecordKey
testOperationKey sid opKey = do
    sessionName <- mkRecordName sid
    operationName <- mkRecordName opKey
    mkRecordKey ("op." <> planKeyDigest <> "." <> sessionName <> recordTupleSeparator <> operationName)

writeOrphanOperation ::
    ProtectedSession session ->
    Text ->
    Text ->
    IO (Either SessionError ())
writeOrphanOperation session sid opKey =
    case testOperationKey sid opKey of
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
-- Live operation admission

liveOperationAdmissionTests :: [TestTree]
liveOperationAdmissionTests =
    [ testCase ("prepare admits " <> Text.unpack phase) $
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- prepareInputFixture store
            callbacks <- newIORef (0 :: Int)
            _ <- expect =<< inEntry store (\session ->
                withPreparedGate session sess epoch fence "op-1" phase permit $ \_ next -> do
                    key <- expect (testOperationKey (sessionIdText (operationSessionId sess)) "op-1")
                    recorded <- expect =<< readTransactionRecord session key
                    target <- maybe (assertFailure "the admitted unknown target is absent") pure recorded
                    transactionRecordPayload target @?= encodeFields [phase, sessionIdText (operationSessionId sess), "1", "1"]
                    modifyIORef' callbacks (+ 1)
                    pure (Right (projectPermitVersion next)))
            readIORef callbacks >>= (@?= 1)
    | phase <-
        [ "ReservationOutcomeUnknown", "EffectOutcomeUnknown", "AdoptionOutcomeUnknown"
        , "RepairEffectOutcomeUnknown", "PhaseEffectOutcomeUnknown", "TeardownOutcomeUnknown"
        , "AdoptionTeardownOutcomeUnknown"
        ]
    ]
        <> [ testCase ("prepare refuses requested phase " <> label) $
                withStore $ \store -> do
                    SomePrepareInput epoch sess fence permit <- prepareInputFixture store
                    (key, original, target) <- sessionOperationRecord store sess "op-1"
                    transactionRecordPayload target @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
                    callbacks <- newIORef (0 :: Int)
                    before <- protectedImage store
                    refused <- inEntry store $ \session ->
                        withPreparedGate session sess epoch fence "op-1" phase permit $ \_ _ -> do
                            modifyIORef' callbacks (+ 1)
                            pure (Right ())
                    assertOutcomePhaseRefusal "IntentRecorded" phase refused
                    readIORef callbacks >>= (@?= 0)
                    after <- readRequiredRecord store key
                    protectedRecordBytes after @?= protectedRecordBytes original
                    protectedRecordVersion after @?= protectedRecordVersion original
                    protectedImage store >>= (@?= before)
           | (label, phase) <-
                [ ("Committed", "Committed")
                , ("SomeFuturePhase", "SomeFuturePhase")
                , ("containing a tab", "EffectOutcomeUnknown\tbad")
                , ("containing a newline", "EffectOutcomeUnknown\nbad")
                , ("containing U+0100", "EffectOutcomeUnknown\x0100")
                ]
           ]
        <> [ testCase ("acknowledgement refuses target phase " <> Text.unpack phase) $
                withStore $ \store -> do
                    SomeAcknowledgeInput sess gate permit <- acknowledgeInputFixture store
                    before <- protectedImage store
                    refused <- inEntry store $ \session -> (() <$) <$> acknowledgeOutcome session sess gate phase () permit
                    assertOutcomePhaseRefusal "EffectOutcomeUnknown" phase refused
                    protectedImage store >>= (@?= before)
           | phase <- ["IntentRecorded", "ReservationRetryFenced", "EffectOutcomeUnknown"]
           ]
        <> [ testCase "a gate matching a recorded Committed phase cannot acknowledge" $
                withStore $ \store -> do
                    SomePrepareInput _ sess fence permit <- prepareInputFixture store
                    (key, original, _) <- sessionOperationRecord store sess "op-1"
                    -- Adversarial use of the existing public producer; its legacy gap is owned by 17.72.
                    gate <- expect =<< withProtectedEntry store (\session ->
                        Prepared.recordDurableUnknown session key (ExpectVersion (protectedRecordVersion original))
                            "Committed" plan "op-1" (sessionIdText (operationSessionId sess)) (fenceEpochWord fence) 1)
                    actual <- readRequiredRecord store key
                    preparedGateJournalVersion gate @?= recordVersionWord (protectedRecordVersion actual)
                    target <- readLiveTarget store key
                    transactionRecordPayload target @?= encodeFields ["Committed", sessionIdText (operationSessionId sess), "1", "1"]
                    before <- protectedImage store
                    refused <- inEntry store $ \session -> (() <$) <$> acknowledgeOutcome session sess gate "Committed" () permit
                    assertOutcomePhaseRefusal "Committed" "Committed" refused
                    protectedImage store >>= (@?= before)
           , testCase "prepare refuses an actual epoch from a different broker generation" $
                withStore $ \store -> do
                    SomePrepareInput opened sess fence permit <- prepareInputFixture store
                    brokerEpochWord opened @?= 1
                    withForeignBrokerEpoch store $ \presented -> do
                        brokerEpochWord presented @?= 2
                        callbacks <- newIORef (0 :: Int)
                        before <- protectedImage store
                        refused <- inEntry store $ \session ->
                            withPreparedGate session sess presented fence "op-1" "EffectOutcomeUnknown" permit $ \_ _ -> do
                                modifyIORef' callbacks (+ 1)
                                pure (Right ())
                        refused @?= Left (SessionBrokerEpochMismatch 1 2)
                        readIORef callbacks >>= (@?= 0)
                        protectedImage store >>= (@?= before)
           , durableBrokerMarkerCase "prepare revalidates the durable broker marker" "2" (SessionBrokerEpochMismatch 2 1)
           , durableBrokerMarkerCase "prepare refuses a noncanonical durable broker marker" "01" (SessionRecordCorrupt "session")
           , testCase "a closed session refuses prepare with its live close successor" $
                withStore $ \store -> do
                    SomeSettledSession epoch sess fence _ _ acknowledged <- settledSessionFixture store
                    live <- expect =<< inEntry store (\session -> closeOperationSession session sess acknowledged)
                    callbacks <- newIORef (0 :: Int)
                    before <- protectedImage store
                    refused <- inEntry store $ \session ->
                        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" live $ \_ _ -> do
                            modifyIORef' callbacks (+ 1)
                            pure (Right ())
                    refused @?= Left (SessionNotOpen (operationSessionId sess))
                    readIORef callbacks >>= (@?= 0)
                    protectedImage store >>= (@?= before)
           , testCase "a closed session refuses acknowledgement before a stale gate version" $
                withStore $ \store -> do
                    SomeSettledSession _ sess _ gate _ acknowledged <- settledSessionFixture store
                    live <- expect =<< inEntry store (\session -> closeOperationSession session sess acknowledged)
                    before <- protectedImage store
                    refused <- inEntry store $ \session -> (() <$) <$> acknowledgeOutcome session sess gate "Committed" () live
                    refused @?= Left (SessionNotOpen (operationSessionId sess))
                    protectedImage store >>= (@?= before)
           , testCase "acknowledgement refuses the fence superseded by fenceOldPermits" $
                withStore $ \store -> do
                    SomeAcknowledgeInput sess gate permit <- acknowledgeInputFixture store
                    (key, original, target) <- sessionOperationRecord store sess "op-1"
                    transactionRecordPayload target @?= encodeFields ["EffectOutcomeUnknown", sessionIdText (operationSessionId sess), "1", "1"]
                    fenced <- expect =<< inEntry store (\session -> fenceOldPermits session plan)
                    oldPermitsFencedTo fenced @?= 2
                    before <- protectedImage store
                    refused <- inEntry store $ \session -> (() <$) <$> acknowledgeOutcome session sess gate "Committed" () permit
                    refused @?= Left (SessionFenceSuperseded 1 2)
                    assertNumericOperationUnchanged store key original before
           , foreignGateCase "acknowledgement refuses a gate from another plan" "another-plan-digest" "session-a" "plan"
           , foreignGateCase "acknowledgement refuses a gate from another session" plan "session-b" "session"
           ]

assertOutcomePhaseRefusal :: Text -> Text -> Either SessionError () -> IO ()
assertOutcomePhaseRefusal recorded presented outcome = case outcome of
    Left failure -> do
        failure @?= SessionOutcomePhaseRefused "op-1" recorded presented
        sessionErrorMessage failure @?=
            "session: operation op-1 refuses outcome phase " <> Text.unpack presented <> " from " <> Text.unpack recorded
    Right () -> assertFailure ("admitted outcome phase " <> Text.unpack presented <> " from " <> Text.unpack recorded)

durableBrokerMarkerCase :: String -> Text -> SessionError -> TestTree
durableBrokerMarkerCase label marker expected =
    testCase label $
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- prepareInputFixture store
            brokerEpochWord epoch @?= 1
            (key, _) <- soleRecordWithPrefix store "session."
            original <- readLiveTarget store key
            transactionRecordPayload original @?= encodeFields ["open", "1", "members", "op-1"]
            _ <- rewriteStampedPayload store key ["open", marker, "members", "op-1"]
            live <- expect =<< inEntry store (\session -> openProjectJournal session plan)
            projectPermitVersion live @?= projectPermitVersion permit
            callbacks <- newIORef (0 :: Int)
            before <- protectedImage store
            refused <- inEntry store $ \session ->
                withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \_ _ -> do
                    modifyIORef' callbacks (+ 1)
                    pure (Right ())
            refused @?= Left expected
            readIORef callbacks >>= (@?= 0)
            protectedImage store >>= (@?= before)

withForeignBrokerEpoch :: ProtectedStore -> (forall brokerGeneration. BrokerEpoch brokerGeneration -> IO result) -> IO result
withForeignBrokerEpoch store use =
    Fixture.withFixtureInstalledProject $ \project -> do
        broker <- expect =<< openProtectedStore (protectedStoreRoot store </> "foreign-broker")
        first <- withProductionRoot broker project Authority.ProjectUp $ \root ->
            pure (Right (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root))))
        expect first >>= (@?= 1)
        second <- withProductionRoot broker project Authority.ProjectUp $ \root ->
            Right <$> use (rootAuthorityEpoch (productionRootAuthority root))
        expect second

foreignGateCase :: String -> Text -> Text -> Text -> TestTree
foreignGateCase label foreignPlan foreignSession mismatch =
    testCase label $
        withStore $ \foreignStore -> withStore $ \store -> do
            (_, gate) <- gateForSessionFixture foreignStore foreignPlan foreignSession
            (SomePrepareInput _ sess _ permit, _) <- gateForSessionFixture store plan "session-a"
            (_, actual, target) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload target @?= encodeFields ["EffectOutcomeUnknown", "session-a", "1", "1"]
            preparedGateJournalVersion gate @?= recordVersionWord (protectedRecordVersion actual)
            preparedGateFence gate @?= 1
            preparedGateAttempt gate @?= 1
            before <- protectedImage store
            refused <- inEntry store $ \session -> (() <$) <$> acknowledgeOutcome session sess gate "Committed" () permit
            refused @?= Left (SessionPreparedGateMismatch mismatch)
            protectedImage store >>= (@?= before)

gateForSessionFixture :: ProtectedStore -> Text -> Text -> IO (SomePrepareInput, PreparedGate)
gateForSessionFixture store digest sid =
    expect =<< inEntry store (\session -> do
        permit <- expect =<< openProjectJournal session digest
        withEpoch session $ \epoch -> do
            (sess, opened) <- expect =<< openOperationSession session epoch digest sid permit
            fence <- expect =<< establishInitialFence session digest 1
            registered <- expect =<< registerOperationIntent session sess "op-1" NoHistory opened
            withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" registered $ \gate next ->
                pure (Right (SomePrepareInput epoch sess fence next, gate)))

data SomeSettledSession where
    SomeSettledSession ::
        BrokerEpoch brokerGeneration -> OperationSession scope planId -> FenceEpoch scope planId -> PreparedGate ->
        ProjectPermit scope planId -> ProjectPermit scope planId -> SomeSettledSession

settledSessionFixture :: ProtectedStore -> IO SomeSettledSession
settledSessionFixture store = do
    SomePrepareInput epoch sess fence beforePrepare <- prepareInputFixture store
    expect =<< inEntry store (\session ->
        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" beforePrepare $ \gate prepared -> do
            assertBool "prepare consumes the registered permit" (projectPermitVersion prepared > projectPermitVersion beforePrepare)
            advance <- expect =<< acknowledgeOutcome session sess gate "Committed" () prepared
            withOperationAdvance advance $ \() next ->
                pure (Right (SomeSettledSession epoch sess fence gate beforePrepare next)))

readLiveTarget :: ProtectedStore -> RecordKey -> IO TransactionRecord
readLiveTarget store key = do
    observed <- expect =<< inEntry store (\session ->
        either (Left . SessionRecordCorrupt . transactionErrorMessage) Right <$> readTransactionRecord session key)
    maybe (assertFailure "the live target is missing") pure observed

rewriteStampedPayload :: ProtectedStore -> RecordKey -> [Text] -> IO ProtectedRecord
rewriteStampedPayload store key fields = do
    original <- readLiveTarget store key
    stamp <- maybe (assertFailure "the live target has no transaction stamp") pure (transactionRecordStamp original)
    let payload = encodeFields fields
        bytes = stampTarget stamp payload
    version <- rewriteRecordBytes store key (const bytes)
    record <- readRequiredRecord store key
    protectedRecordBytes record @?= bytes
    recordVersionWord (protectedRecordVersion record) @?= version
    target <- readLiveTarget store key
    transactionRecordStamp target @?= Just stamp
    transactionRecordPayload target @?= payload
    transactionRecordVersion target @?= protectedRecordVersion record
    pure record

unknownOperationFixture :: ProtectedStore -> IO SomePrepareInput
unknownOperationFixture store = do
    input@(SomePrepareInput _ sess _ _) <- expect =<< inEntry store (\session ->
        withPrepared session $ \epoch opened fence _ permit ->
            pure (Right (SomePrepareInput epoch opened fence permit)))
    (key, _, _) <- sessionOperationRecord store sess "op-1"
    _ <- rewriteStampedPayload store key ["SomeFuturePhase", sessionIdText (operationSessionId sess), "1", "1"]
    pure input

-- ---------------------------------------------------------------------------
-- Recorded operation numeric admission

numericOperationTests :: [TestTree]
numericOperationTests =
    [ testCase "a genuine three-field initial intent prepares attempt one" $
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- prepareInputFixture store
            (_, _, initial) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload initial @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
            callbacks <- newIORef (0 :: Int)
            advanced <- expect =<< inEntry store (\session ->
                withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \gate next -> do
                    modifyIORef' callbacks (+ 1)
                    preparedGateAttempt gate @?= 1
                    pure (Right (projectPermitVersion next)))
            readIORef callbacks >>= (@?= 1)
            assertBool "the initial prepare advances its journal permit" (advanced > projectPermitVersion permit)
            (_, _, prepared) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload prepared @?= encodeFields ["EffectOutcomeUnknown", sessionIdText (operationSessionId sess), "1", "1"]
    , testCase "a genuine three-field initial intent abandons with attempt zero" $
        withStore $ \store -> do
            SomePrepareInput _ sess _ _ <- prepareInputFixture store
            (_, _, initial) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload initial @?= encodeFields ["IntentRecorded", sessionIdText (operationSessionId sess), "0"]
            fenced <- expect =<< inEntry store (\session -> fenceOldPermits session plan)
            oldPermitsFencedTo fenced @?= 2
            manifest <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
            permit <- expect =<< inEntry store (\session -> openProjectJournal session plan)
            interpreted <- expect =<< inEntry store (\session -> withEpoch session $ \epoch ->
                fmap (fmap fst) (interpretRecordedSessions session epoch manifest fenced permit))
            interpretedRecoveryOperations interpreted @?= [OperationAbandonedPreCall "op-1" "IntentRecorded"]
            (_, _, abandoned) <- sessionOperationRecord store sess "op-1"
            transactionRecordPayload abandoned @?= encodeFields ["RecoveryAbandoned", sessionIdText (operationSessionId sess), "2", "0"]
            closed <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
            map manifestSessionIsOpen (manifestSessions closed) @?= [False]
    ]
        <> concat
            [ [ testCase ("prepare refuses " <> label) (numericPrepareRefusal fields)
              , testCase ("recovery refuses " <> label) (numericRecoveryRefusal fields)
              ]
            | (label, fields) <- numericOperationMutations
            ]
        <> [ testCase "an eligible maximum attempt refuses before recording unknown or entering the adapter" $
                withStore $ \store -> do
                    SomePrepareInput epoch sess fence permit <- numericRetryFixture store True
                    (key, seeded) <- seedNumericOperation store sess ["EffectAbsent", sessionIdText (operationSessionId sess), "1", "18446744073709551615"]
                    callbacks <- newIORef (0 :: Int)
                    before <- protectedImage store
                    outcome <- inEntry store $ \session ->
                        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \gate _ -> do
                            modifyIORef' callbacks (+ 1)
                            pure (Right (preparedGateAttempt gate))
                    -- Pin both the typed refusal and the operator-facing message.
                    case outcome of
                        Left failure -> do
                            failure @?= SessionAttemptExhausted "op-1"
                            sessionErrorMessage failure @?= "session: operation op-1 has exhausted its attempt counter"
                        Right attempt -> do
                            entered <- readIORef callbacks
                            (_, _, written) <- sessionOperationRecord store sess "op-1"
                            assertFailure ("expected exhaustion before effects; gate attempt=" <> show attempt <> ", callbacks=" <> show entered <> ", payload=" <> show (transactionRecordPayload written))
                    readIORef callbacks >>= (@?= 0)
                    assertNumericOperationUnchanged store key seeded before
           , testCase "maximum minus one advances to the maximum attempt exactly" $
                withStore $ \store -> do
                    SomePrepareInput epoch sess fence permit <- numericRetryFixture store True
                    (key, original) <- seedNumericOperation store sess ["EffectAbsent", sessionIdText (operationSessionId sess), "1", "18446744073709551614"]
                    callbacks <- newIORef (0 :: Int)
                    advanced <- expect =<< inEntry store (\session ->
                        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \gate next -> do
                            modifyIORef' callbacks (+ 1)
                            preparedGateAttempt gate @?= 18446744073709551615
                            pure (Right (projectPermitVersion next)))
                    readIORef callbacks >>= (@?= 1)
                    assertBool "the maximum successor advances its journal permit" (advanced > projectPermitVersion permit)
                    after <- readRequiredRecord store key
                    assertBool "the successful maximum attempt advances the operation" (protectedRecordVersion after > protectedRecordVersion original)
                    (_, _, prepared) <- sessionOperationRecord store sess "op-1"
                    transactionRecordPayload prepared @?= encodeFields ["EffectOutcomeUnknown", sessionIdText (operationSessionId sess), "2", "18446744073709551615"]
           , testCase "a same-fence maximum attempt keeps the fresh-fence refusal priority" $
                withStore $ \store -> do
                    SomePrepareInput epoch sess fence permit <- numericRetryFixture store False
                    (key, seeded) <- seedNumericOperation store sess ["EffectAbsent", sessionIdText (operationSessionId sess), "1", "18446744073709551615"]
                    callbacks <- newIORef (0 :: Int)
                    before <- protectedImage store
                    refused <- inEntry store $ \session ->
                        withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \gate _ -> do
                            modifyIORef' callbacks (+ 1)
                            pure (Right (preparedGateAttempt gate))
                    refused @?= Left (SessionRetryNeedsFreshFence "op-1" 1 1)
                    readIORef callbacks >>= (@?= 0)
                    assertNumericOperationUnchanged store key seeded before
           , testCase "recovery preserves a maximum attempt without incrementing it" $
                withStore $ \store -> withNumericRecoveryInput store $ \sess fenced manifest permit -> do
                    _ <- seedNumericOperation store sess ["EffectAbsent", sessionIdText (operationSessionId sess), "1", "18446744073709551615"]
                    interpreted <- expect =<< inEntry store (\session -> withEpoch session $ \epoch ->
                        fmap (fmap fst) (interpretRecordedSessions session epoch manifest fenced permit))
                    interpretedRecoveryOperations interpreted @?= [OperationAbandonedRetryable "op-1" "EffectAbsent"]
                    (_, _, abandoned) <- sessionOperationRecord store sess "op-1"
                    transactionRecordPayload abandoned @?= encodeFields ["RecoveryAbandoned", sessionIdText (operationSessionId sess), "2", "18446744073709551615"]
                    closed <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
                    map manifestSessionIsOpen (manifestSessions closed) @?= [False]
           ]

numericOperationMutations :: [(String, Text -> [Text])]
numericOperationMutations =
    [ ("a corrupt retryable fence", \sid -> ["EffectAbsent", sid, "x", "1"])
    , ("a missing retryable fence", \sid -> ["EffectAbsent", sid, "", "1"])
    , ("a noncanonical retryable fence", \sid -> ["EffectAbsent", sid, "01", "1"])
    , ("a corrupt continuable attempt", \sid -> ["Reserved", sid, "1", "x"])
    , ("a missing continuable attempt", \sid -> ["Reserved", sid, "1"])
    , ("a noncanonical continuable attempt", \sid -> ["Reserved", sid, "1", "01"])
    ]

numericPrepareRefusal :: (Text -> [Text]) -> IO ()
numericPrepareRefusal fields =
    withStore $ \store -> do
        SomePrepareInput epoch sess fence permit <- numericRetryFixture store True
        (key, seeded) <- seedNumericOperation store sess (fields (sessionIdText (operationSessionId sess)))
        live <- expect =<< inEntry store (\session -> openProjectJournal session plan)
        projectPermitVersion live @?= projectPermitVersion permit
        callbacks <- newIORef (0 :: Int)
        before <- protectedImage store
        refused <- inEntry store $ \session ->
            withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" permit $ \gate _ -> do
                modifyIORef' callbacks (+ 1)
                pure (Right (preparedGateAttempt gate))
        refused @?= Left (SessionRecordCorrupt "operation record")
        readIORef callbacks >>= (@?= 0)
        assertNumericOperationUnchanged store key seeded before

numericRecoveryRefusal :: (Text -> [Text]) -> IO ()
numericRecoveryRefusal fields =
    withStore $ \store -> withNumericRecoveryInput store $ \sess fenced manifest permit -> do
        (key, seeded) <- seedNumericOperation store sess (fields (sessionIdText (operationSessionId sess)))
        before <- protectedImage store
        refused <- inEntry store $ \session -> withEpoch session $ \epoch ->
            (() <$) <$> interpretRecordedSessions session epoch manifest fenced permit
        refused @?= Left (SessionRecordCorrupt "operation record")
        assertNumericOperationUnchanged store key seeded before

-- Each fixture starts with a real EffectAbsent acknowledgement and its successor.
numericRetryFixture :: ProtectedStore -> Bool -> IO SomePrepareInput
numericRetryFixture store fresh =
    expect =<< inEntry store (\session ->
        withPrepared session $ \epoch sess fence gate prepared -> do
            advance <- expect =<< acknowledgeOutcome session sess gate "EffectAbsent" () prepared
            withOperationAdvance advance $ \() permit -> do
                liveFence <- if fresh then expect =<< rotateFence session plan fence else pure fence
                fenceEpochWord liveFence @?= if fresh then 2 else 1
                pure (Right (SomePrepareInput epoch sess liveFence permit)))

-- Fence/manifest production precedes corruption; the refusal baseline excludes
-- those legitimate setup writes and covers one session with one operation.
withNumericRecoveryInput ::
    ProtectedStore ->
    ( forall scope planId.
      OperationSession scope planId ->
      OldPermitsFenced scope planId ->
      VerifiedSessionManifest scope planId ->
      ProjectPermit scope planId ->
      IO result
    ) ->
    IO result
withNumericRecoveryInput store use = do
    SomeOpenSession sess _ <- terminalSessionFixture store "EffectOutcomeUnknown" "EffectAbsent"
    fenced <- expect =<< inEntry store (\session -> fenceOldPermits session plan)
    oldPermitsFencedFrom fenced @?= 1
    oldPermitsFencedTo fenced @?= 2
    manifest <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
    [(sessionIdText (manifestSessionId member), manifestSessionOperations member) | member <- manifestSessions manifest]
        @?= [("session-a", ["op-1"])]
    permit <- expect =<< inEntry store (\session -> openProjectJournal session plan)
    use sess fenced manifest permit

seedNumericOperation :: ProtectedStore -> OperationSession scope planId -> [Text] -> IO (RecordKey, ProtectedRecord)
seedNumericOperation store sess fields = do
    (key, original, target) <- sessionOperationRecord store sess "op-1"
    transactionRecordPayload target @?= encodeFields ["EffectAbsent", sessionIdText (operationSessionId sess), "1", "1"]
    stamp <- maybe (assertFailure "the numeric fixture operation has no transaction stamp") pure (transactionRecordStamp target)
    let payload = encodeFields fields
        bytes = stampTarget stamp payload
    version <- rewriteRecordBytes store key (const bytes)
    assertBool "the numeric fixture CAS advances the physical version" (version > recordVersionWord (protectedRecordVersion original))
    (actualKey, seeded, readable) <- sessionOperationRecord store sess "op-1"
    actualKey @?= key
    protectedRecordBytes seeded @?= bytes
    recordVersionWord (protectedRecordVersion seeded) @?= version
    transactionRecordStamp readable @?= Just stamp
    transactionRecordPayload readable @?= payload
    pure (key, seeded)

assertNumericOperationUnchanged :: ProtectedStore -> RecordKey -> ProtectedRecord -> ProtectedImage -> IO ()
assertNumericOperationUnchanged store key seeded before = do
    after <- readRequiredRecord store key
    protectedRecordBytes after @?= protectedRecordBytes seeded
    protectedRecordVersion after @?= protectedRecordVersion seeded
    protectedImage store >>= (@?= before)

-- ---------------------------------------------------------------------------
-- Canonical transaction wire

transactionWireTests :: [TestTree]
transactionWireTests =
    [ testCase "Unicode descriptor data uses exact UTF-8 in both codec directions" unicodeTransactionDataCase
    , testCase "a Cyrillic session identity retains the public ASCII refusal" unicodeSessionIdentityCase
    , testCase "canonical Idle zero and bounded sequences are observed without writes" canonicalIdleWireCase
    , testCase "an actual ASCII Applying session recovers its sole exact target" canonicalApplyingWireCase
    , testCase "stamped and unstamped target payloads preserve opaque bytes" opaqueTransactionTargetCase
    , testCase "invalid coordinator UTF-8 refuses before target observation" $
        withWireProject $ \store coordinator _ ->
            assertJournalWireRefusal store coordinator ("transaction-v1\tidle\t" <> ByteString.pack [0xff]) "transaction text is not UTF-8"
    ]
        <> map
            ( \(label, raw) ->
                testCase ("an Idle sequence refuses " <> label) $
                    withWireProject $ \store coordinator _ ->
                        assertJournalWireRefusal store coordinator ("transaction-v1\tidle\t" <> raw) "the Idle sequence is invalid"
            )
            [ ("a negative sign", "-1")
            , ("a positive sign", "+7")
            , ("hexadecimal", "0x7")
            , ("parentheses", "(7)")
            , ("leading whitespace", " 7")
            , ("trailing whitespace", "7 ")
            , ("a leading zero", "07")
            , ("Word64 overflow", "18446744073709551616")
            , ("twenty-one digits", "100000000000000000000")
            ]
        <> [ testCase "Applying sequence count and expectations require canonical numbers" applyingWireNumbersCase
           , testCase "an overflowing target stamp cannot wrap to one" $
                withWireProject $ \store _ project ->
                    assertJournalWireRefusal store project "hbtx-target-v1\t18446744073709551617\nopen" "a stamped target has an invalid transaction id"
           , testCase "recognized target envelopes require canonical positive stamps and a newline" recognizedStampWireCase
           , testCase "an otherwise valid coordinator refuses a trailing newline" $
                withWireProject $ \store coordinator _ ->
                    assertJournalWireRefusal store coordinator "transaction-v1\tidle\t7\n" "the coordinator record is not canonical"
           , testCase "otherwise valid Applying payload hex must retain its lowercase spelling" uppercaseApplyingHexCase
           ]

unicodeTransactionDataCase :: IO ()
unicodeTransactionDataCase = do
    -- This descriptor is scalar codec data, not an admitted plan or redo request.
    let unicodePlan = "data-с"
        descriptor = TransactionDescriptor 7 unicodePlan TxnOpenSession []
        expected = "transaction-v1\tapplying\t7\topen-session\tdata-" <> ByteString.pack [0xd1, 0x81] <> "\t0"
        actual = encodeCoordinator (CoordinatorApplying descriptor)
    actual @?= expected
    decoded <- expect (decodeCoordinator actual)
    decoded @?= CoordinatorApplying descriptor
    case decoded of
        CoordinatorApplying observed -> descriptorPlan observed @?= unicodePlan
        CoordinatorIdle _ -> assertFailure "Unicode Applying data decoded as Idle"
    encodeCoordinator decoded @?= expected

unicodeSessionIdentityCase :: IO ()
unicodeSessionIdentityCase =
    withStore $ \store -> do
        SomePrepareInput epoch _ _ permit <- prepareInputFixture store
        before <- protectedImage store
        refused <- inEntry store $ \session ->
            (() <$) <$> openOperationSession session epoch plan "session-с" permit
        refused
            @?= Left
                ( SessionStoreFailure
                    (ProtectedInvalid "record name session-с may contain only ASCII alphanumerics, '-', '_', '.', '/', and one ':' per segment")
                )
        protectedImage store >>= (@?= before)

withWireProject :: (ProtectedStore -> RecordKey -> RecordKey -> IO ()) -> IO ()
withWireProject use =
    withStore $ \store -> do
        _ <- openProjectFixture store
        coordinator <- expect (coordinatorKey plan)
        (project, _) <- soleRecordWithPrefix store "project."
        use store coordinator project

canonicalIdleWireCase :: IO ()
canonicalIdleWireCase =
    withWireProject $ \store coordinator _ ->
        mapM_
            ( \(sequenceNumber, expected) -> do
                let encoded = encodeCoordinator (CoordinatorIdle sequenceNumber)
                encoded @?= expected
                version <- rewriteRecordBytes store coordinator (const encoded)
                seeded <- readRequiredRecord store coordinator
                protectedRecordBytes seeded @?= expected
                recordVersionWord (protectedRecordVersion seeded) @?= version
                decodeCoordinator expected @?= Right (CoordinatorIdle sequenceNumber)
                before <- protectedImage store
                permit <- expect =<< inEntry store (\session -> openProjectJournal session plan)
                projectPermitVersion permit @?= version
                protectedImage store >>= (@?= before)
            )
            [ (0, "transaction-v1\tidle\t0")
            , (7, "transaction-v1\tidle\t7")
            , (maxBound, "transaction-v1\tidle\t18446744073709551615")
            ]

assertJournalWireRefusal :: ProtectedStore -> RecordKey -> ByteString -> Text -> IO ()
assertJournalWireRefusal store key bytes reason = do
    version <- rewriteRecordBytes store key (const bytes)
    seeded <- readRequiredRecord store key
    protectedRecordBytes seeded @?= bytes
    recordVersionWord (protectedRecordVersion seeded) @?= version
    before <- protectedImage store
    refused <- inEntry store (\session -> (() <$) <$> openProjectJournal session plan)
    refused @?= Left (SessionRecordCorrupt reason)
    after <- readRequiredRecord store key
    protectedRecordBytes after @?= bytes
    protectedRecordVersion after @?= protectedRecordVersion seeded
    protectedImage store >>= (@?= before)

-- The new session target was absent before this real transition. Rebuilding
-- that expectation needs no existing-target version reconstruction; this case
-- does not certify the other interruption fixtures' faithfulness.
withWireApplying :: (ProtectedStore -> TransactionDescriptor -> PublishedTransaction -> IO ()) -> IO ()
withWireApplying use =
    withStore $ \store -> do
        SomeProjectPermit current <- openProjectFixture store
        published <- newIORef Nothing
        reopened <-
            withInterruptedTransaction AfterApplying TxnOpenSession store $ do
                runEntry store $ \session -> withEpoch session $ \epoch ->
                    (() <$) <$> openOperationSession session epoch plan "session-a" current
                captured <- publishedTransaction store
                modifyIORef' published (const (Just captured))
        captured <- readIORef published >>= maybe (assertFailure "the real session transition was not captured") pure
        coordinator <- expect (coordinatorKey plan)
        applying <- readRequiredRecord reopened coordinator
        decoded <- expect (decodeCoordinator (protectedRecordBytes applying))
        encodeCoordinator decoded @?= protectedRecordBytes applying
        case decoded of
            CoordinatorIdle _ -> assertFailure "the interruption did not retain Applying"
            CoordinatorApplying descriptor -> do
                descriptorSequence descriptor @?= publishedSequence captured
                descriptorPlan descriptor @?= plan
                descriptorKind descriptor @?= TxnOpenSession
                use reopened descriptor captured

canonicalApplyingWireCase :: IO ()
canonicalApplyingWireCase =
    withWireApplying $ \store descriptor captured -> do
        encodedPlan <- expect (mkRecordName plan)
        encodedSession <- expect (mkRecordName "session-a")
        expectedKey <- recordKeyFor ("session." <> encodedPlan <> recordTupleSeparator <> encodedSession)
        (capturedKey, capturedPayload) <- case publishedTargets captured of
            [target] -> pure target
            _ -> assertFailure "the real session transition must publish exactly one target"
        capturedKey @?= expectedKey
        publishedSequence captured @?= 2
        coordinator <- expect (coordinatorKey plan)
        applying <- readRequiredRecord store coordinator
        protectedRecordBytes applying @?= encodeCoordinator (CoordinatorApplying descriptor)
        before <- protectedImage store
        Map.lookup (recordKeyText expectedKey) before @?= Nothing
        permit <- expect =<< inEntry store (\session -> openProjectJournal session plan)
        materialized <- readRequiredRecord store expectedKey
        protectedRecordBytes materialized @?= stampTarget 2 capturedPayload
        targetResult <- withProtectedEntry store (\session -> Right <$> readTransactionRecord session expectedKey)
        target <- expect targetResult >>= expect >>= maybe (assertFailure "the recovered session target disappeared") pure
        transactionRecordStamp target @?= Just 2
        transactionRecordPayload target @?= capturedPayload
        transactionRecordVersion target @?= protectedRecordVersion materialized
        after <- protectedImage store
        Map.keys (Map.filterWithKey (\key _ -> "session." `Text.isPrefixOf` key) after) @?= [recordKeyText expectedKey]
        committed <- readRequiredRecord store coordinator
        protectedRecordBytes committed @?= "transaction-v1\tidle\t2"
        projectPermitVersion permit @?= recordVersionWord (protectedRecordVersion committed)

opaqueTransactionTargetCase :: IO ()
opaqueTransactionTargetCase =
    withStore $ \store -> do
        key <- recordKeyFor "wire-target"
        let payload = ByteString.pack [0xff, 0, 9, 10, 65]
            stamped = stampTarget 7 payload
            maximumStamp = stampTarget maxBound payload
        stamped @?= "hbtx-target-v1\t7\n" <> payload
        maximumStamp @?= "hbtx-target-v1\t18446744073709551615\n" <> payload
        written <- withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent payload)
        _ <- expect written
        mapM_
            ( \(bytes, stamp) -> do
                version <- rewriteRecordBytes store key (const bytes)
                seeded <- readRequiredRecord store key
                protectedRecordBytes seeded @?= bytes
                recordVersionWord (protectedRecordVersion seeded) @?= version
                before <- protectedImage store
                observed <- withProtectedEntry store (\session -> Right <$> readTransactionRecord session key)
                target <- expect observed >>= expect >>= maybe (assertFailure "the opaque target disappeared") pure
                transactionRecordStamp target @?= stamp
                transactionRecordPayload target @?= payload
                transactionRecordVersion target @?= protectedRecordVersion seeded
                protectedImage store >>= (@?= before)
            )
            [(payload, Nothing), (stamped, Just 7), (maximumStamp, Just maxBound)]

applyingWireNumbersCase :: IO ()
applyingWireNumbersCase =
    withWireApplying $ \store descriptor _ -> do
        coordinator <- expect (coordinatorKey plan)
        case map (ByteString.split 9) (ByteStringChar8.lines (encodeCoordinator (CoordinatorApplying descriptor))) of
            [[magic, state, sequenceNumber, kind, planText, count], [target, role, key, expectation, payload]] -> do
                let wire number cardinality expected =
                        ByteString.intercalate "\t" [magic, state, number, kind, planText, cardinality]
                            <> "\n"
                            <> ByteString.intercalate "\t" [target, role, key, expected, payload]
                mapM_
                    (\(bytes, reason) -> assertJournalWireRefusal store coordinator bytes reason)
                    [ (wire "02" count expectation, "the Applying sequence is invalid")
                    , (wire sequenceNumber "01" expectation, "the target count is invalid")
                    , (wire sequenceNumber count "version:01", "a target expectation is invalid")
                    , (wire sequenceNumber count "exact:01:6f70656e", "an exact target expectation is invalid")
                    ]
            _ -> assertFailure "the real one-target Applying encoding has an unexpected shape"

recognizedStampWireCase :: IO ()
recognizedStampWireCase =
    withWireProject $ \store _ project ->
        mapM_
            (\(bytes, reason) -> assertJournalWireRefusal store project bytes reason)
            [ ("hbtx-target-v1\t1", "a stamped target is not canonical")
            , ("hbtx-target-v1\t01\nopen", "a stamped target has an invalid transaction id")
            , ("hbtx-target-v1\t+1\nopen", "a stamped target has an invalid transaction id")
            , ("hbtx-target-v1\t0\nopen", "a stamped target has an invalid transaction id")
            , ("hbtx-target-v1\nopen", "a stamped target has no transaction id")
            ]

uppercaseApplyingHexCase :: IO ()
uppercaseApplyingHexCase =
    withWireApplying $ \store descriptor _ -> do
        coordinator <- expect (coordinatorKey plan)
        case ByteStringChar8.lines (encodeCoordinator (CoordinatorApplying descriptor)) of
            [header, targetLine] -> case ByteString.split 9 targetLine of
                [target, role, key, expectation, payload] -> do
                    let uppercase = ByteString.map (\byte -> if byte >= 97 && byte <= 102 then byte - 32 else byte) payload
                        changed = header <> "\n" <> ByteString.intercalate "\t" [target, role, key, expectation, uppercase]
                    assertBool "the actual valid payload hex contains a changed letter" (uppercase /= payload)
                    assertJournalWireRefusal store coordinator changed "the coordinator record is not canonical"
                _ -> assertFailure "the actual session target does not have five wire fields"
            _ -> assertFailure "the actual Applying encoding does not have one target line"

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
           , testCase "an acknowledged prepare excludes close with its retained permit" acknowledgedPrepareExcludesCloseCase
           , testCase "a closed session excludes prepare with its pre-close permit" closedPermitExcludesPrepareCase
           , testCase "the reproduced interruption is the transition's own descriptor" faithfulDescriptorCase
           , testGroup "plan-bound transaction redo" transactionRedoRefusalTests
           , testGroup
                "Production target identity framing"
                ( [ testCase (show kind <> " " <> Text.unpack identity) $ do
                        encoded <- expect (mkRecordName identity)
                        productionTargetIdentityCase kind encoded encoded encoded recordTupleSeparator True
                  | kind <- [TxnFinalizeProductionProject, TxnFinalizeProductionPreEffect]
                  , identity <- ["Build", "build", "a_b", "aB"]
                  ]
                    <> [ testCase "a case-mixed lease target refuses before materialization" $
                            productionTargetIdentityCase TxnFinalizeProductionPreEffect "_build" "build" "_build" recordTupleSeparator False
                       , testCase "an underscore-mixed lease target refuses before materialization" $
                            productionTargetIdentityCase TxnFinalizeProductionPreEffect "a__b" "a_b" "a__b" recordTupleSeparator False
                       , testCase "a mixed reverse-intent target refuses before materialization" $
                            productionTargetIdentityCase TxnFinalizeProductionProject "_build" "_build" "build" recordTupleSeparator False
                       , testCase "a noncanonical mode identity refuses before materialization" $
                            productionTargetIdentityCase TxnFinalizeProductionProject "a_" "a_" "a_" recordTupleSeparator False
                       , testCase "a historical lease separator refuses before materialization" $
                            productionTargetIdentityCase TxnFinalizeProductionProject "alpha" "alpha" "alpha" "." False
                       ]
                )
           , testCase "a historical session plan separator refuses before materialization" historicalSessionTargetCase
           ]

-- | The package-private seam supplies only an interrupted durable descriptor.
-- Recovery runs through the public journal reader; the fixture creates no
-- transaction permit or installed-project authority.
transactionRedoRefusalTests :: [TestTree]
transactionRedoRefusalTests =
    [ testCase "an Applying descriptor cannot name another coordinator" foreignCoordinatorDescriptorCase
    , testCase "an Applying target cannot escape its transaction plan" outOfPlanRedoTargetCase
    , testCase "RegisterIntent target order matches its closed kind" reversedRegisterTargetsCase
    , testCase "a third-state Session target refuses redo" thirdStateSessionTargetCase
    , testCase "a Production conflict retains the descriptor sequence" productionConflictSequenceCase
    ]

readApplyingDescriptor :: ProtectedStore -> IO (TransactionDescriptor, ProtectedRecord)
readApplyingDescriptor store = do
    key <- expect (coordinatorKey plan)
    record <- readRequiredRecord store key
    decoded <- expect (decodeCoordinator (protectedRecordBytes record))
    encodeCoordinator decoded @?= protectedRecordBytes record
    case decoded of
        CoordinatorApplying descriptor -> pure (descriptor, record)
        CoordinatorIdle _ -> assertFailure "the actual coordinator is not Applying"

assertRedoRefusal :: ProtectedStore -> TransactionDescriptor -> SessionError -> IO ()
assertRedoRefusal store descriptor failure = do
    key <- expect (coordinatorKey plan)
    let bytes = encodeCoordinator (CoordinatorApplying descriptor)
    version <- rewriteRecordBytes store key (const bytes)
    record <- readRequiredRecord store key
    protectedRecordBytes record @?= bytes
    recordVersionWord (protectedRecordVersion record) @?= version
    decodeCoordinator bytes @?= Right (CoordinatorApplying descriptor)
    before <- protectedImage store
    refused <- inEntry store (\session -> (() <$) <$> openProjectJournal session plan)
    refused @?= Left failure
    protectedImage store >>= (@?= before)

withOtherProjectTarget :: (ProtectedStore -> RecordKey -> TransactionRecord -> IO ()) -> IO ()
withOtherProjectTarget use =
    withWireProject $ \store _ _ -> do
        runEntry store $ \session -> (() <$) <$> openProjectJournal session "other-plan"
        encoded <- expect (mkRecordName "other-plan")
        key <- recordKeyFor ("project." <> encoded)
        target <- readLiveTarget store key
        use store key target

foreignCoordinatorDescriptorCase :: IO ()
foreignCoordinatorDescriptorCase =
    withOtherProjectTarget $ \store key target -> do
        let descriptor =
                TransactionDescriptor 17 "other-plan" TxnBeginProjectClose
                    [projectTransactionTarget key (Just target) (encodeFields ["closing", "7"])]
        assertRedoRefusal store descriptor (SessionRecordCorrupt "a descriptor names another coordinator")

outOfPlanRedoTargetCase :: IO ()
outOfPlanRedoTargetCase =
    withOtherProjectTarget $ \store key target -> do
        let descriptor =
                TransactionDescriptor 17 plan TxnOpenProject
                    [projectTransactionTarget key (Just target) (encodeFields ["open"])]
        assertRedoRefusal store descriptor
            (SessionTransactionFailure "transaction: invalid open-project descriptor: a target key is outside the transaction plan")

reversedRegisterTargetsCase :: IO ()
reversedRegisterTargetsCase =
    withStore $ \store -> do
        SomeOpenSession sess permit <- openSessionFixture store
        reopened <-
            withInterruptedTransaction AfterApplying TxnRegisterIntent store $
                runEntry store $ \session -> (() <$) <$> registerOperationIntent session sess "op-1" NoHistory permit
        (descriptor, _) <- readApplyingDescriptor reopened
        descriptorKind descriptor @?= TxnRegisterIntent
        reversed <- case descriptorTargets descriptor of
            [operation, member] -> pure [member, operation]
            _ -> assertFailure "the real RegisterIntent descriptor does not have two targets"
        assertRedoRefusal reopened descriptor{descriptorTargets = reversed}
            (SessionTransactionFailure "transaction: invalid register-intent descriptor: the target roles do not match the closed transaction kind")

thirdStateSessionTargetCase :: IO ()
thirdStateSessionTargetCase =
    withStore $ \store -> do
        SomeProjectPermit permit <- openProjectFixture store
        reopened <-
            withInterruptedTransaction AfterApplying TxnBeginProjectClose store $
                runEntry store $ \session -> (() <$) <$> beginClosingProject session plan 7 permit
        (descriptor, _) <- readApplyingDescriptor reopened
        descriptorKind descriptor @?= TxnBeginProjectClose
        descriptorSequence descriptor @?= 2
        (key, _) <- soleRecordWithPrefix reopened "project."
        _ <- rewriteStampedPayload reopened key ["closed"]
        assertRedoRefusal reopened descriptor
            (SessionTransactionFailure ("transaction: target " <> recordKeyText key <> " conflicts while redoing transaction 2"))

productionConflictSequenceCase :: IO ()
productionConflictSequenceCase =
    withWireProject $ \store _ projectKey -> do
        -- These canonical records are seeded admission inputs. They do not
        -- claim a genuine Production finalizer or any reverse authority.
        modeKey <- recordKeyFor "mode.alpha"
        leaseKey <- recordKeyFor ("lease.alpha" <> recordTupleSeparator <> "production")
        let originalMode = encodeFields ["production", "7"]
            originalLease = encodeFields ["unbound", "7"]
            closedLease = encodeFields ["closed", "7"]
        seeded <- withProtectedEntry store $ \session -> do
            modeVersion <- expect =<< compareAndSwapProtectedRecord session modeKey ExpectAbsent originalMode
            leaseVersion <- expect =<< compareAndSwapProtectedRecord session leaseKey ExpectAbsent originalLease
            mode <- readProtectedRecord session modeKey >>= expect >>= maybe (assertFailure "the seeded Mode record disappeared") pure
            lease <- readProtectedRecord session leaseKey >>= expect >>= maybe (assertFailure "the seeded lease disappeared") pure
            protectedRecordVersion mode @?= modeVersion
            protectedRecordVersion lease @?= leaseVersion
            pure (Right (mode, lease))
        (mode, lease) <- expect seeded
        project <- readLiveTarget store projectKey
        let payload = transactionRecordPayload project
            descriptor =
                TransactionDescriptor 41 plan TxnFinalizeProductionPreEffect
                    [ projectTransactionTarget projectKey (Just project) payload
                    , productionLeaseTransactionTarget leaseKey lease closedLease
                    , productionModeTransactionTarget modeKey mode
                    ]
        prefixVersion <- rewriteRecordBytes store projectKey (const (stampTarget 41 payload))
        prefix <- readLiveTarget store projectKey
        transactionRecordStamp prefix @?= Just 41
        transactionRecordPayload prefix @?= payload
        recordVersionWord (transactionRecordVersion prefix) @?= prefixVersion
        changedVersion <- rewriteRecordBytes store leaseKey id
        changed <- readRequiredRecord store leaseKey
        protectedRecordBytes changed @?= originalLease
        recordVersionWord (protectedRecordVersion changed) @?= changedVersion
        changedVersion @?= recordVersionWord (protectedRecordVersion lease) + 1
        -- The earlier valid project prefix precedes the preservation baseline
        -- inside assertRedoRefusal; this does not assert batch rollback.
        assertRedoRefusal store descriptor
            (SessionTransactionFailure ("transaction: target " <> recordKeyText leaseKey <> " conflicts while redoing transaction 41"))

productionTargetIdentityCase :: TxnKind -> Text -> Text -> Text -> Text -> Bool -> IO ()
productionTargetIdentityCase kind modeProject leaseProject intentProject leaseSeparator admitted =
    withStore $ \store -> do
        runEntry store $ \session -> (() <$) <$> openProjectJournal session plan
        encodedPlan <- expect (mkRecordName plan)
        journalKey <- recordKeyFor ("project." <> encodedPlan)
        modeKey <- recordKeyFor ("mode." <> modeProject)
        leaseKey <- recordKeyFor ("lease." <> leaseProject <> leaseSeparator <> "production")
        intentKey <- recordKeyFor ("reverse-root." <> intentProject <> ".production")
        let originalMode = encodeFields ["production", "7"]
            originalLease = encodeFields ["unbound", "7"]
            closedLease = encodeFields ["closed", "7"]
            originalIntent = "original-intent"
            closedIntent = "closed-intent"
            fullClose = kind == TxnFinalizeProductionProject
        installed <- withProtectedEntry store $ \session -> do
            let seed key bytes = do
                    _ <- expect =<< compareAndSwapProtectedRecord session key ExpectAbsent bytes
                    present <- expect =<< readProtectedRecord session key
                    maybe (assertFailure "a seeded target disappeared") pure present
            modeRecord <- seed modeKey originalMode
            leaseRecord <- seed leaseKey originalLease
            intentTargets <-
                if fullClose
                    then do
                        intentRecord <- seed intentKey originalIntent
                        pure [productionIntentTransactionTarget intentKey intentRecord closedIntent]
                    else pure []
            journal <- expect =<< readTransactionRecord session journalKey
            observedJournal <- maybe (assertFailure "the real project journal disappeared") pure journal
            let targets =
                    [projectTransactionTarget journalKey journal (transactionRecordPayload observedJournal)]
                        <> intentTargets
                        <> [ productionLeaseTransactionTarget leaseKey leaseRecord closedLease
                           , productionModeTransactionTarget modeKey modeRecord
                           ]
            coord <- expect (coordinatorKey plan)
            current <- expect =<< readProtectedRecord session coord
            coordinator <- maybe (assertFailure "the real coordinator disappeared") pure current
            _ <- expect =<< compareAndSwapProtectedRecord session coord (ExpectVersion (protectedRecordVersion coordinator)) (encodeCoordinator (CoordinatorApplying (TransactionDescriptor 2 plan kind targets)))
            pure (Right ())
        _ <- expect installed
        before <- protectedImage store
        recovered <- inEntry store (\session -> readProjectJournalState session plan)
        if admitted
            then do
                recovered @?= Right OpenProject
                after <- protectedImage store
                Map.lookup (recordKeyText modeKey) after @?= Nothing
                fmap snd (Map.lookup (recordKeyText leaseKey) after) @?= Just closedLease
                if fullClose
                    then fmap snd (Map.lookup (recordKeyText intentKey) after) @?= Just closedIntent
                    else pure ()
                coord <- expect (coordinatorKey plan)
                fmap snd (Map.lookup (recordKeyText coord) after) @?= Just (encodeCoordinator (CoordinatorIdle 2))
            else do
                case recovered of
                    Left (SessionTransactionFailure reason) ->
                        assertBool "the exact Production identity guard refused" ("Production targets do not name one exact project generation" `Text.isInfixOf` reason)
                    other -> assertFailure ("expected the exact target identity refusal, got " <> show other)
                protectedImage store >>= (@?= before)

historicalSessionTargetCase :: IO ()
historicalSessionTargetCase =
    withStore $ \store -> do
        runEntry store $ \session -> (() <$) <$> openProjectJournal session plan
        encodedPlan <- expect (mkRecordName plan)
        historical <- recordKeyFor ("session." <> encodedPlan <> ".other")
        installed <- withProtectedEntry store $ \session -> do
            coord <- expect (coordinatorKey plan)
            current <- expect =<< readProtectedRecord session coord
            coordinator <- maybe (assertFailure "the real coordinator disappeared") pure current
            let target = sessionTransactionTarget historical Nothing "not materialized"
                descriptor = TransactionDescriptor 2 plan TxnOpenSession [target]
            _ <- expect =<< compareAndSwapProtectedRecord session coord (ExpectVersion (protectedRecordVersion coordinator)) (encodeCoordinator (CoordinatorApplying descriptor))
            pure (Right ())
        _ <- expect installed
        before <- protectedImage store
        refused <- inEntry store (\session -> readProjectJournalState session plan)
        case refused of
            Left (SessionTransactionFailure reason) ->
                assertBool "the exact plan boundary refused" ("a target key is outside the transaction plan" `Text.isInfixOf` reason)
            other -> assertFailure ("expected historical session target refusal, got " <> show other)
        protectedImage store >>= (@?= before)

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
            completedVersion <- newIORef Nothing
            reopened <-
                withInterruptedTransaction point TxnOpenProject store $
                    runEntry store $ \session -> do
                        permit <- expect =<< openProjectJournal session plan
                        modifyIORef' completedVersion (const (Just (projectPermitVersion permit)))
                        pure (Right ())
            state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
            state @?= OpenProject
            expected <- readIORef completedVersion >>= maybe (assertFailure "the uninterrupted project permit was not captured") pure
            beforeOpen <- protectedImage reopened
            permit <- expect =<< inEntry reopened (\session -> openProjectJournal session plan)
            projectPermitVersion permit @?= expected
            protectedImage reopened >>= (@?= beforeOpen)

openSessionRecoveryCase :: InterruptionPoint -> TestTree
openSessionRecoveryCase point =
    testCase ("open session recovers when " <> show point) $
        withStore $ \store -> do
            SomeProjectPermit current <- openProjectFixture store
            reopened <-
                withInterruptedTransaction point TxnOpenSession store $
                    runEntry store $ \session ->
                        withEpoch session $ \epoch ->
                            fmap
                                (fmap (const ()))
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
                        fmap
                            (fmap (const ()))
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
                        fmap
                            (fmap (const ()))
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
                        fmap
                            (fmap (const ()))
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
                        fmap
                            (fmap (const ()))
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
                        fmap
                            (fmap (const ()))
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
                        (testOperationKey "session-a" "stray")
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

acknowledgedPrepareExcludesCloseCase :: IO ()
acknowledgedPrepareExcludesCloseCase =
    withStore $ \store -> do
        SomeSettledSession _ sess _ _ beforePrepare acknowledged <- settledSessionFixture store
        (key, committed, target) <- sessionOperationRecord store sess "op-1"
        transactionRecordPayload target @?= encodeFields ["Committed", sessionIdText (operationSessionId sess), "1", "1"]
        before <- protectedImage store
        refused <- inEntry store $ \session -> (() <$) <$> closeOperationSession session sess beforePrepare
        refused @?= Left (SessionStaleProjectPermit (projectPermitVersion beforePrepare))
        manifest <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
        map manifestSessionIsOpen (manifestSessions manifest) @?= [True]
        protectedImage store >>= (@?= before)
        closed <- expect =<< inEntry store (\session -> closeOperationSession session sess acknowledged)
        assertBool "the live acknowledgement successor authorizes close" (projectPermitVersion closed > projectPermitVersion acknowledged)
        final <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
        map manifestSessionIsOpen (manifestSessions final) @?= [False]
        after <- readRequiredRecord store key
        protectedRecordBytes after @?= protectedRecordBytes committed
        protectedRecordVersion after @?= protectedRecordVersion committed
        observed <- expect =<< inEntry store (\session -> openProjectJournal session plan)
        projectPermitVersion observed @?= projectPermitVersion closed

closedPermitExcludesPrepareCase :: IO ()
closedPermitExcludesPrepareCase =
    withStore $ \store -> do
        SomeSettledSession epoch sess fence _ _ acknowledged <- settledSessionFixture store
        closed <- expect =<< inEntry store (\session -> closeOperationSession session sess acknowledged)
        assertBool "closing advances the shared project permit" (projectPermitVersion closed > projectPermitVersion acknowledged)
        manifest <- expect =<< inEntry store (\session -> verifySessionManifest session plan)
        map manifestSessionIsOpen (manifestSessions manifest) @?= [False]
        callbacks <- newIORef (0 :: Int)
        before <- protectedImage store
        refused <- inEntry store $ \session ->
            withPreparedGate session sess epoch fence "op-1" "EffectOutcomeUnknown" acknowledged $ \_ _ -> do
                modifyIORef' callbacks (+ 1)
                pure (Right ())
        refused @?= Left (SessionStaleProjectPermit (projectPermitVersion acknowledged))
        readIORef callbacks >>= (@?= 0)
        protectedImage store >>= (@?= before)
        observed <- expect =<< inEntry store (\session -> openProjectJournal session plan)
        projectPermitVersion observed @?= projectPermitVersion closed

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
        encodedPlan <- expect (mkRecordName plan)
        expectedKey <- recordKeyFor ("project." <> encodedPlan)
        capture <- newIORef Nothing
        reopened <-
            withInterruptedTransaction BeforeCommit TxnOpenProject store $ do
                observed <- withProtectedEntry store (\session -> Right <$> readTransactionRecord session expectedKey)
                original <- expect observed >>= expect
                runEntry store $ \session -> (() <$) <$> openProjectJournal session plan
                published <- publishedTransaction store
                modifyIORef' capture (const (Just (original, published)))
        (original, published) <- readIORef capture >>= maybe (assertFailure "the uninterrupted transition was not captured") pure
        original @?= Nothing
        (capturedKey, capturedPayload) <- case publishedTargets published of
            [target] -> pure target
            _ -> assertFailure "the real OpenProject transition must publish one target"
        capturedKey @?= expectedKey
        capturedPayload @?= encodeFields ["open"]
        publishedSequence published @?= 1
        publishedCoordinatorVersion published @?= 3

        -- Read the actual Applying bytes before any ordinary reader recovers it.
        (descriptor, applying) <- readApplyingDescriptor reopened
        descriptorSequence descriptor @?= publishedSequence published
        descriptorPlan descriptor @?= plan
        descriptorKind descriptor @?= TxnOpenProject
        descriptorTargets descriptor @?= [projectTransactionTarget capturedKey original capturedPayload]
        recordVersionWord (protectedRecordVersion applying) @?= 2

        -- The project target carries exactly the bytes the completed transition
        -- wrote, stamped with that transition's own id.
        materialized <- expect =<< inEntry reopened (\session -> readProjectTarget session)
        case materialized of
            Nothing -> assertFailure "expected the project target to be materialized"
            Just record -> do
                transactionRecordPayload record @?= capturedPayload
                transactionRecordStamp record @?= Just (publishedSequence published)
                recordVersionWord (transactionRecordVersion record) @?= 1

        -- Exercise the same fixture publisher with invalid inputs. It must
        -- refuse before a coordinator or target publication, even in this
        -- otherwise valid store.
        mapM_
            ( \(point, kind, captured, reason) -> do
                before <- protectedImage reopened
                refused <- installApplying reopened point kind captured
                refused @?= Left reason
                protectedImage reopened >>= (@?= before)
            )
            [ (AfterTarget (-1), TxnOpenProject, published, "the target prefix is outside the captured transaction")
            , (AfterTarget 2, TxnOpenProject, published, "the target prefix is outside the captured transaction")
            , (AfterApplying, TxnOpenProject, published{publishedTargets = []}, "the captured target count does not match the transaction kind")
            , (AfterApplying, TxnRebindSession, published, "the interruption fixture does not support this transaction kind")
            ]

        -- And the coordinator has not committed. The journal reader drives
        -- recovery itself, so the state it reports is the recovered one.
        state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
        state @?= OpenProject
        permit <- expect =<< inEntry reopened (\session -> openProjectJournal session plan)
        projectPermitVersion permit @?= publishedCoordinatorVersion published

        -- Zero is an actual empty prefix, distinct from a negative take.
        withStore $ \emptyStore -> do
            emptyPrefix <-
                withInterruptedTransaction (AfterTarget 0) TxnOpenProject emptyStore $
                    runEntry emptyStore $ \session -> (() <$) <$> openProjectJournal session plan
            image <- protectedImage emptyPrefix
            Map.lookup (recordKeyText expectedKey) image @?= Nothing
            (emptyDescriptor, _) <- readApplyingDescriptor emptyPrefix
            descriptorKind emptyDescriptor @?= TxnOpenProject
            length (descriptorTargets emptyDescriptor) @?= 1
            recovered <- inEntry emptyPrefix (\session -> readProjectJournalState session plan)
            recovered @?= Right OpenProject

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
    case kind of
        TxnOpenProject -> do
            missing <- inEntry store (\session -> readProjectJournalState session plan)
            missing @?= Left (SessionProjectMissing plan)
            key <- expect (coordinatorKey plan)
            initial <- readRequiredRecord store key
            protectedRecordBytes initial @?= "transaction-v1\tidle\t0"
            recordVersionWord (protectedRecordVersion initial) @?= 1
        _ -> pure ()
    let root = protectedStoreRoot store
        snapshot = takeDirectory root </> "interrupted-snapshot"
    before <- protectedImage store
    copyTree root snapshot
    transition
    published <- publishedTransaction store
    removePathForcibly root
    copyTree snapshot root
    restored <- reopenStore store
    protectedImage restored >>= (@?= before)
    installApplying restored point kind published >>= expect
    reopenStore restored

{- | Reproduce each physical prefix of the actual Production close, retaining
the canonical raw Mode records and the stamped project journal. The fixture
derives desired bytes and versions from a real successful finalizer.
-}
withInterruptedProductionTransaction ::
    Int -> ProtectedStore -> IO () -> IO (ProtectedStore, Text, IO ())
withInterruptedProductionTransaction prefix store transition = do
    before <- records store
    let root = protectedStoreRoot store
        snapshot = takeDirectory root </> "production-close-snapshot"
    copyTree root snapshot
    transition
    after <- records store
    let changed = Map.filterWithKey (\key value -> Map.lookup key before /= Just value) after
        projects = [(key, value) | (key, value) <- Map.toList changed, "project." `Text.isPrefixOf` recordKeyText key]
    (journalKey, _) <- case projects of
        [one] -> pure one
        _ -> assertFailure "the Production finalizer must change exactly one project journal"
    let exactPlan = recordNameIdentity (Text.drop (Text.length "project.") (recordKeyText journalKey))
        keys =
            sortOn
                roleOrder
                ([key | key <- Map.keys changed, roleOrder key < 3] ++ [key | key <- Map.keys before, Map.notMember key after, roleOrder key == 3])
        kind = if any (("reverse-root." `Text.isPrefixOf`) . recordKeyText) keys then TxnFinalizeProductionProject else TxnFinalizeProductionPreEffect
    length keys @?= (if kind == TxnFinalizeProductionProject then 4 else 3)
    removePathForcibly root
    copyTree snapshot root
    restored <- reopenStore store
    outcome <- withProtectedEntry restored $ \session -> do
        liveJournal <- readTransactionRecordFrom after journalKey
        sequenceNumber <- maybe (assertFailure "closed journal has no transaction stamp") pure (transactionRecordStamp liveJournal)
        let target key
                | key == journalKey = projectTransactionTarget key (transactionRecord <$> Map.lookup key before) (transactionRecordPayload liveJournal)
                | "reverse-root." `Text.isPrefixOf` recordKeyText key = productionIntentTransactionTarget key (before Map.! key) (protectedRecordBytes (after Map.! key))
                | "lease." `Text.isPrefixOf` recordKeyText key = productionLeaseTransactionTarget key (before Map.! key) (protectedRecordBytes (after Map.! key))
                | otherwise = productionModeTransactionTarget key (before Map.! key)
            descriptor = TransactionDescriptor sequenceNumber exactPlan kind (map target keys)
        coord <- either (assertFailure . show) pure (coordinatorKey exactPlan)
        current <- readProtectedRecord session coord >>= either (assertFailure . show) pure
        _ <- compareAndSwapProtectedRecord session coord (maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) current) (encodeCoordinator (CoordinatorApplying descriptor)) >>= either (assertFailure . show) pure
        mapM_ (materialize session before after) (take prefix keys)
        pure (Right ())
    either (assertFailure . show) pure outcome
    let verify = do
            recovered <- records restored
            mapM_ (\key -> Map.lookup key recovered @?= Map.lookup key after) keys
    pure (restored, exactPlan, verify)
  where
    roleOrder key
        | "project." `Text.isPrefixOf` recordKeyText key = 0 :: Int
        | "reverse-root." `Text.isPrefixOf` recordKeyText key = 1
        | "lease." `Text.isPrefixOf` recordKeyText key = 2
        | "mode." `Text.isPrefixOf` recordKeyText key = 3
        | otherwise = 4
    records current = do
        outcome <- withProtectedEntry current $ \session -> do
            keys <- listProtectedRecords session >>= either (assertFailure . show) pure
            pairs <-
                mapM
                    ( \key -> do
                        value <- readProtectedRecord session key >>= either (assertFailure . show) pure
                        record <- maybe (assertFailure "listed record disappeared") pure value
                        pure (key, record)
                    )
                    keys
            pure (Right (Map.fromList pairs))
        either (assertFailure . show) pure outcome
    transactionRecord record = TransactionRecord (protectedRecordVersion record) Nothing (protectedRecordBytes record)
    readTransactionRecordFrom values key = do
        let record = values Map.! key
            bytes = protectedRecordBytes record
            (header, payload) = ByteStringChar8.break (== '\n') bytes
        stamp <- case reads (ByteStringChar8.unpack (ByteString.drop (ByteString.length "hbtx-target-v1\t") header)) of
            [(value, "")] -> pure value
            _ -> assertFailure "the finalizer journal has an invalid stamp"
        pure (TransactionRecord (protectedRecordVersion record) (Just stamp) (ByteString.drop 1 payload))
    materialize session before after key = do
        let expectation = maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) (Map.lookup key before)
        case Map.lookup key after of
            Nothing -> compareAndDeleteProtectedRecord session key expectation >>= either (assertFailure . show) pure
            Just record -> do
                _ <- compareAndSwapProtectedRecord session key expectation (protectedRecordBytes record) >>= either (assertFailure . show) pure
                pure ()

{- | Copy a directory tree, so a snapshot is the store itself rather than a
reconstruction of it — record versions and all.
-}
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

-- | What the completed transition wrote: its id, and its targets in order.
data PublishedTransaction = PublishedTransaction
    { publishedSequence :: Word64
    , publishedTargets :: [(RecordKey, ByteString)]
    , publishedCoordinatorVersion :: Word64
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
            key <- expect (coordinatorKey plan)
            committed <- readRequiredRecord store key
            protectedRecordBytes committed @?= encodeCoordinator (CoordinatorIdle latest)
            pure
                PublishedTransaction
                    { publishedSequence = latest
                    , publishedTargets = sortOn (roleOf . fst) mine
                    , publishedCoordinatorVersion = recordVersionWord (protectedRecordVersion committed)
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
installApplying :: ProtectedStore -> InterruptionPoint -> TxnKind -> PublishedTransaction -> IO (Either String ())
installApplying store point kind published = case checkedPrefix of
    Left reason -> pure (Left reason)
    Right materializedCount -> publish materializedCount
  where
    expectedCount = case kind of
        TxnOpenProject -> Right 1
        TxnOpenSession -> Right 1
        TxnRegisterIntent -> Right 2
        TxnPrepareOperation -> Right 1
        TxnAcknowledgeOutcome -> Right 1
        TxnCloseSession -> Right 1
        TxnBeginProjectClose -> Right 1
        TxnRecordProjectClosed -> Right 1
        _ -> Left "the interruption fixture does not support this transaction kind"
    checkedPrefix = do
        count <- expectedCount
        if length (publishedTargets published) /= count
            then Left "the captured target count does not match the transaction kind"
            else case point of
                AfterApplying -> Right 0
                BeforeCommit -> Right count
                AfterTarget prefix
                    | prefix >= 0 && prefix <= count -> Right prefix
                    | otherwise -> Left "the target prefix is outside the captured transaction"

    publish materializedCount = do
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
            coordinator <- maybe (assertFailure "the pre-transition coordinator is missing") pure current
            let expectation = ExpectVersion (protectedRecordVersion coordinator)
            applying <-
                compareAndSwapProtectedRecord
                    session
                    key
                    expectation
                    (encodeCoordinator (CoordinatorApplying descriptor))
            applyingVersion <- either (assertFailure . show) pure applying
            recordVersionWord applyingVersion + 1 @?= publishedCoordinatorVersion published
            observed <- readProtectedRecord session key >>= expect
            actual <- maybe (assertFailure "the reconstructed Applying record disappeared") pure observed
            protectedRecordVersion actual @?= applyingVersion
            protectedRecordBytes actual @?= encodeCoordinator (CoordinatorApplying descriptor)
            decodeCoordinator (protectedRecordBytes actual) @?= Right (CoordinatorApplying descriptor)
            mapM_ (materialize session) (take materializedCount (publishedTargets published))
            pure (Right ())
        _ <- either (assertFailure . show) pure outcome
        pure (Right ())

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
