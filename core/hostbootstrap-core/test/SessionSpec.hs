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
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority (BrokerEpoch, withFreshBrokerEpoch)
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lifecycle.Execution (StepExecution, stepExecutionOperationKey)
import HostBootstrap.Lifecycle.Session
import HostBootstrap.Lifecycle.Session.Testing
import HostBootstrap.Reconcile (
    LifecyclePlan,
    lifecyclePlanDigest,
    stepExecutionFor,
    withLifecyclePlan,
 )
import HostBootstrap.Step (
    Step,
    StepFrame (..),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    mkStepPlan,
 )
import HostBootstrap.Substrate (
    Arch (Arm64),
    Substrate (..),
    SubstrateName (LinuxCpu),
 )
import qualified Data.Map.Strict as Map
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedError (ProtectedInvalid),
    ProtectedSession,
    ProtectedStore,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    openProtectedStore,
    protectedStoreRoot,
    recordKeyText,
    withProtectedEntry,
 )
import qualified Fixture
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitSuccess, exitWith)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

plan :: Text
plan = "plan-digest-1"

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

{- | The probe's own broker epoch. It cannot use 'withEpoch': that helper fails
the enclosing test case on a refusal, and a probe must report rather than assert.
-}
withProbeEpoch ::
    ProtectedSession session ->
    (forall brokerGeneration. BrokerEpoch brokerGeneration -> IO (Either SessionError result)) ->
    IO (Either SessionError result)
withProbeEpoch session use =
    case Authority.installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo" of
        Left failure -> pure (Left (authorityAsSession failure))
        Right project -> do
            outcome <- withFreshBrokerEpoch session project (fmap Right . use)
            pure (either (Left . authorityAsSession) id outcome)

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
        [ testGroup "the project journal" journalTests
        , testGroup "fence rotation" fenceTests
        , testGroup "phase classification" classificationTests
        , testGroup "the prepare compare-and-swap" prepareTests
        , testGroup "recovery" recoveryTests
        , testGroup "transaction recovery" transactionRecoveryTests
        ]

-- ---------------------------------------------------------------------------
-- Journal and sessions

journalTests :: [TestTree]
journalTests =
    [ testCase "opening the journal twice observes one version, it does not reset it" $
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
            withRoutePlan $ \lifecycle -> do
                let digest = lifecyclePlanDigest lifecycle
                execution <- expectExecution lifecycle targetStep
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
            withRoutePlan $ \lifecycle -> do
                execution <- expectExecution lifecycle targetStep
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
                                stepPlan @?= lifecyclePlanDigest lifecycle
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
    (forall scope planId. LifecyclePlan scope planId -> IO result) ->
    IO result
withRoutePlan use =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec routeStepPlan use

expectExecution ::
    LifecyclePlan scope planId ->
    Step ->
    IO (StepExecution scope planId)
expectExecution lifecycle step =
    maybe (assertFailure "the plan does not contain the fixture step") pure $
        stepExecutionFor lifecycle routeHostConfig step

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
-- Recoverable lifecycle transactions

transactionRecoveryTests :: [TestTree]
transactionRecoveryTests =
    concat
        [ map openProjectRecoveryCase oneTargetFailpoints
        , map openSessionRecoveryCase oneTargetFailpoints
        , map registerIntentRecoveryCase registerIntentFailpoints
        , map prepareRecoveryCase oneTargetFailpoints
        , map acknowledgeRecoveryCase oneTargetFailpoints
        , map closeSessionRecoveryCase oneTargetFailpoints
        , map beginProjectCloseRecoveryCase oneTargetFailpoints
        , map recordProjectClosedRecoveryCase oneTargetFailpoints
        ]
        <> [ testCase "exact session membership ignores an unregistered prefix-shaped record" exactMembershipCase
           , testCase "a prepare/session-close race yields exactly one successor permit" prepareCloseRaceCase
           , testCase "the failpoint bracket alone cannot mutate protected records" inertFailpointCase
           ]

oneTargetFailpoints :: [TransactionFailpoint]
oneTargetFailpoints =
    [ TransactionAfterApplying
    , TransactionAfterTarget 1
    , TransactionBeforeCommit
    ]

registerIntentFailpoints :: [TransactionFailpoint]
registerIntentFailpoints =
    [ TransactionAfterApplying
    , TransactionAfterTarget 1
    , TransactionAfterTarget 2
    , TransactionBeforeCommit
    ]

openProjectRecoveryCase :: TransactionFailpoint -> TestTree
openProjectRecoveryCase point =
    testCase ("open project recovers after " <> show point) $
        withStore $ \store -> do
            expectInterrupted point $
                inEntry store $ \session ->
                    withTransactionFailpoint point $
                        fmap (fmap (const ())) (openProjectJournal session plan)
            reopened <- reopenStore store
            permit <- expect =<< inEntry reopened (\session -> openProjectJournal session plan)
            assertBool "recovery returns the committed successor permit" (projectPermitVersion permit > 0)
            state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
            state @?= OpenProject

openSessionRecoveryCase :: TransactionFailpoint -> TestTree
openSessionRecoveryCase point =
    testCase ("open session recovers after " <> show point) $
        withStore $ \store -> do
            expectInterrupted point $
                inEntry store $ \session -> do
                    permit <- openProjectJournal session plan
                    case permit of
                        Left failure -> pure (Left failure)
                        Right current ->
                            withEpoch session $ \epoch ->
                                withTransactionFailpoint point $
                                    fmap (fmap (const ()))
                                        (openOperationSession session epoch plan "session-a" current)
            reopened <- reopenStore store
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 1
            recoveredContinuableCount recovered @?= 0

registerIntentRecoveryCase :: TransactionFailpoint -> TestTree
registerIntentRecoveryCase point =
    testCase ("register intent recovers after " <> show point) $
        withStore $ \store -> do
            SomeOpenSession sess oldPermit <- openSessionFixture store
            expectInterrupted point $
                inEntry store $ \session ->
                    withTransactionFailpoint point $
                        fmap (fmap (const ()))
                            (registerOperationIntent session sess "op-1" NoHistory oldPermit)

            reopened <- reopenStore store
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

prepareRecoveryCase :: TransactionFailpoint -> TestTree
prepareRecoveryCase point =
    testCase ("prepare recovers after " <> show point) $
        withStore $ \store -> do
            SomePrepareInput epoch sess fence permit <- prepareInputFixture store
            expectInterrupted point $
                inEntry store $ \session ->
                    withTransactionFailpoint point $
                        withPreparedGate
                            session
                            sess
                            epoch
                            fence
                            "op-1"
                            "EffectOutcomeUnknown"
                            permit
                            (\_ _ -> pure (Right ()))
            reopened <- reopenStore store
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            case swept of
                Left (SessionUnclassifiedPhase opKey phase) -> do
                    opKey @?= "op-1"
                    phase @?= "EffectOutcomeUnknown"
                other -> assertFailure ("expected the recovered durable unknown phase, got " <> show other)

acknowledgeRecoveryCase :: TransactionFailpoint -> TestTree
acknowledgeRecoveryCase point =
    testCase ("acknowledgment recovers after " <> show point) $
        withStore $ \store -> do
            expectInterrupted point $
                inEntry store $ \session ->
                    withPrepared session $ \_ sess _ gate permit ->
                        withTransactionFailpoint point $
                            fmap (fmap (const ()))
                                (acknowledgeOutcome session sess gate "Committed" () permit)
            reopened <- reopenStore store
            swept <- inEntry reopened (\session -> recoverAbandonedSessions session plan)
            recovered <- expect swept
            recoveredSessionCount recovered @?= 1
            recoveredContinuableCount recovered @?= 0

closeSessionRecoveryCase :: TransactionFailpoint -> TestTree
closeSessionRecoveryCase point =
    testCase ("session close recovers after " <> show point) $
        withStore $ \store -> do
            SomeOpenSession sess permit <- openSessionFixture store
            expectInterrupted point $
                inEntry store $ \session ->
                    withTransactionFailpoint point $
                        fmap (fmap (const ()))
                            (closeOperationSession session sess permit)
            reopened <- reopenStore store
            verified <- inEntry reopened (\session -> verifyAllSessionsClosed session plan)
            proof <- expect verified
            allSessionsClosedCount proof @?= 1

beginProjectCloseRecoveryCase :: TransactionFailpoint -> TestTree
beginProjectCloseRecoveryCase point =
    testCase ("begin project close recovers after " <> show point) $
        withStore $ \store -> do
            expectInterrupted point $
                inEntry store $ \session -> do
                    permit <- openProjectJournal session plan
                    case permit of
                        Left failure -> pure (Left failure)
                        Right current ->
                            withTransactionFailpoint point $
                                fmap (fmap (const ()))
                                    (beginClosingProject session plan 7 current)
            reopened <- reopenStore store
            state <- expect =<< inEntry reopened (\session -> readProjectJournalState session plan)
            state @?= ClosingProject 7

recordProjectClosedRecoveryCase :: TransactionFailpoint -> TestTree
recordProjectClosedRecoveryCase point =
    testCase ("record project closed recovers after " <> show point) $
        withStore $ \store -> do
            expectInterrupted point $
                inEntry store $ \session -> do
                    permit <- openProjectJournal session plan
                    case permit of
                        Left failure -> pure (Left failure)
                        Right current -> do
                            closing <- beginClosingProject session plan 7 current
                            case closing of
                                Left failure -> pure (Left failure)
                                Right closePermit ->
                                    withTransactionFailpoint point $
                                        fmap (fmap (const ()))
                                            (recordClosedProject session plan 7 closePermit)
            reopened <- reopenStore store
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
                        (mkRecordKey ("op." <> plan <> ".session-a.stray"))
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

inertFailpointCase :: IO ()
inertFailpointCase =
    withStore $ \store -> do
        before <- expect =<< inEntry store protectedKeys
        withTransactionFailpoint TransactionAfterApplying (pure ())
        after <- expect =<< inEntry store protectedKeys
        after @?= before
  where
    protectedKeys session = do
        listed <- listProtectedRecords session
        pure (either (Left . SessionStoreFailure) Right listed)

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

expectInterrupted :: TransactionFailpoint -> IO result -> IO ()
expectInterrupted point action = do
    outcome <- try @TransactionInterrupted action
    case outcome of
        Left _ -> pure ()
        Right _ -> assertFailure ("expected transaction interruption at " <> show point)

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
    withFixtureProject $ \project -> do
        outcome <- withFreshBrokerEpoch session project (fmap Right . use)
        pure (either (Left . authorityAsSession) id outcome)

authorityAsSession :: Authority.AuthorityError -> SessionError
authorityAsSession = SessionRecordCorrupt . Text.pack . show

withFixtureProject ::
    (Authority.InstalledProject Fixture.FixtureProject -> IO result) ->
    IO result
withFixtureProject use =
    case Authority.installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo" of
        Left failure -> assertFailure (show failure)
        Right project -> use project

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
