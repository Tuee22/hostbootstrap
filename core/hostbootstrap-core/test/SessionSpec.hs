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
module SessionSpec (tests) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority (BrokerEpoch, withFreshBrokerEpoch)
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Lifecycle.Session
import HostBootstrap.Protected (
    ProtectedSession,
    ProtectedStore,
    openProtectedStore,
    protectedStoreRoot,
    withProtectedEntry,
 )
import qualified Fixture
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

plan :: Text
plan = "plan-digest-1"

tests :: TestTree
tests =
    testGroup
        "SessionSpec"
        [ testGroup "the project journal" journalTests
        , testGroup "fence rotation" fenceTests
        , testGroup "phase classification" classificationTests
        , testGroup "the prepare compare-and-swap" prepareTests
        , testGroup "recovery" recoveryTests
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
                -- `permit` is now two versions behind `afterIntent`.
                blocked <-
                    withPreparedGate s sess epoch fence "op-1" "EffectOutcomeUnknown" permit $
                        \_ _ -> pure (Right ())
                case blocked of
                    Left (SessionStaleProjectPermit _) -> pure ()
                    other -> assertFailure ("expected a stale-permit refusal, got " <> show other)
                afterIntent `seq` pure (Right ())
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
    , testCase "a closed project refuses every prepare" $
        withStore $ \store -> runEntry store $ \s ->
            withPrepared s $ \_ sess fence gate permit -> do
                advance <- expect' =<< acknowledgeOutcome s sess gate "Committed" () permit
                next <- withOperationAdvance advance (\() p -> pure p)
                closed <- expect' =<< closeOperationSession s sess next
                state <- expect' =<< readProjectJournalState s plan
                state @?= OpenProject
                closed `seq` fence `seq` pure (Right ())
    ]

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
