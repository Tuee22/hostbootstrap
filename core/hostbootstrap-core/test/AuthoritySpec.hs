{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The protected store, root/command authority, and the project-wide
lifecycle mode and run leases.

These cases run against a real filesystem and a real kernel lock: the exclusive
entry is proved by contending with an out-of-process @flock@, not by modelling
one. Every mode, lease, and invocation decision is a compare-and-swap over a
durable record, so the crash cases here are the ones an interrupted run
actually leaves behind.
-}
module AuthoritySpec (tests, runEntryProbe, runModeProfileProbe) where

import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Authority
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.Lifecycle.Session (
    ProjectJournalState (ClosedProject, ClosingProject),
    SessionError (SessionProjectClosing, SessionStillOpen),
    VerifiedAllSessionsClosed,
    beginClosingProject,
    openOperationSession,
    openProjectJournal,
    readProjectJournalState,
    recordClosedProject,
    verifyAllSessionsClosed,
 )
import HostBootstrap.Protected
import HostBootstrap.Reconcile (
    CanonicalPlanSnapshot,
    LifecyclePlan,
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotSpecDigest,
    lifecyclePlanSnapshot,
    withLifecyclePlan,
    withLifecyclePlanForConfig,
 )
import HostBootstrap.Lift (localContext)
import HostBootstrap.Step (
    StepFrame (..),
    StepObservation (StepChanged),
    StepPlan,
    contextInitStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
 )
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitSuccess, exitWith)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

{- | The out-of-process half of the exclusive-entry case: open the same store
and attempt its entry without blocking. Exit 0 when the entry was acquired, 3
when another holder has it, 4 when the store could not be opened at all.
-}
runEntryProbe :: FilePath -> IO ()
runEntryProbe storeRoot = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left _ -> exitWith (ExitFailure 4)
        Right store -> do
            outcome <- tryProtectedEntry store (\_ -> pure (Right ()))
            case outcome of
                Right (Just ()) -> exitSuccess
                Right Nothing -> exitWith (ExitFailure 3)
                Left _ -> exitWith (ExitFailure 4)

{- | The out-of-process half of the **cross-profile** exclusion: open the same
project's store in a separate process and attempt the named lifecycle profile.

The composite root brackets take the mode inside one exclusive entry and then
release the entry, so by the time a holder's body runs, the only thing a
competitor can contend on is the durable mode record. That is what makes this a
cross-*profile* probe rather than a second exclusive-entry probe: the competitor
reaches the mode compare-and-swap and is refused there, by name.

Its only report is its own outcome — exit 0 when it took the profile, 3 when the
mode refused it (with the held/wanted pair written to @reasonPath@), 4 otherwise.
It never reports what the holder is doing, so no read-only lease observer is
introduced (§ EE).
-}
runModeProfileProbe :: FilePath -> String -> FilePath -> IO ()
runModeProfileProbe storeRoot profile reasonPath = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left _ -> exitWith (ExitFailure 4)
        Right store ->
            case installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo" of
                Left _ -> exitWith (ExitFailure 4)
                Right project -> report =<< attempt store project
  where
    attempt store project = case profile of
        "production" ->
            withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
        "harness" -> do
            swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
            case swept of
                Left failure -> pure (Left failure)
                Right proof ->
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        proof
                        (\_ -> pure (Right ()))
        _ -> pure (Left (ModeInvalidIdentity (Text.pack ("unknown profile " <> profile))))

    report (Right ()) = exitSuccess
    report (Left failure@(ModeHeldByAnother held wanted)) = do
        writeFile reasonPath (Text.unpack held <> "\t" <> Text.unpack wanted)
        failure `seq` exitWith (ExitFailure 3)
    report (Left failure) = do
        writeFile reasonPath (Text.unpack (modeErrorMessage failure))
        exitWith (ExitFailure 4)

tests :: TestTree
tests =
    testGroup
        "AuthoritySpec"
        [ testGroup "the protected store" storeCases
        , testGroup "root and command authority" authorityCases
        , testGroup "project mode and run leases" modeCases
        , testGroup "invocation and terminal close" closeCases
        , testGroup "abandoned-run recovery" recoveryCases
        ]

-- The protected store ----------------------------------------------------------

storeCases :: [TestTree]
storeCases =
    [ testCase "a record round-trips through one exclusive entry" $
        withStore $ \store -> do
            key <- expectKey "alpha"
            written <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "first"
            recordVersionWord <$> written @?= Right 1
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "first")
    , testCase "a write against a stale version is refused and changes nothing" $
        withStore $ \store -> do
            key <- expectKey "beta"
            first <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            stale <- either (assertFailure . show) pure first
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion stale) "two"
            racing <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion stale) "three"
            case racing of
                Right version ->
                    assertFailure ("expected a version mismatch, wrote " <> show version)
                Left failure -> case failure of
                    ProtectedVersionMismatch{} -> pure ()
                    other -> assertFailure ("expected a version mismatch, got " <> show other)
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "two")
    , testCase "a create-if-absent write refuses an already published record" $
        withStore $ \store -> do
            key <- expectKey "gamma"
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            again <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "two"
            assertBool "the second create is refused" (isLeft again)
    , testCase "a conditional delete removes only the observed version" $
        withStore $ \store -> do
            key <- expectKey "delta"
            first <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            stale <- either (assertFailure . show) pure first
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key (ExpectVersion stale) "two"
            refused <-
                withProtectedEntry store $ \session ->
                    compareAndDeleteProtectedRecord session key (ExpectVersion stale)
            assertBool "a stale delete is refused" (isLeft refused)
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) observed @?= Right (Just "two")
    , testCase "the store identity survives reopening and names one store" $
        withStore $ \store -> do
            reopened <- openProtectedStore (protectedStoreRoot store)
            case reopened of
                Left failure -> assertFailure (show failure)
                Right again ->
                    protectedStoreIdentity again @?= protectedStoreIdentity store
    , testCase "an out-of-process holder is excluded while the entry is held" $
        withStore $ \store -> do
            self <- getExecutablePath
            contended <-
                withProtectedEntry store $ \_ ->
                    Right <$> probeEntry self (protectedStoreRoot store)
            contended @?= Right Contended
            free <- probeEntry self (protectedStoreRoot store)
            free @?= Acquired
    , testCase "a malformed record is reported, never silently ignored" $
        withStore $ \store -> do
            key <- expectKey "torn"
            _ <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "one"
            writeFile (protectedStoreRoot store </> "records" </> "torn.rec") "garbage"
            observed <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            case observed of
                Left (ProtectedMalformedRecord _ _) -> pure ()
                other -> assertFailure ("expected a malformed-record error, got " <> show other)
    , testCase "a key that could escape the store is rejected" $ do
        assertBool "a traversal key is rejected" (isLeft (mkRecordKey "../escape"))
        assertBool "an empty key is rejected" (isLeft (mkRecordKey ""))
        assertBool "a dotfile key is rejected" (isLeft (mkRecordKey ".hidden"))
    ]

-- Root and command authority ------------------------------------------------------

authorityCases :: [TestTree]
authorityCases =
    [ testCase "the root gate mints authority for the exact verb" $
        withStore $ \store ->
            withRoot store ProjectUp $ \_session root -> do
                projectVerbName (rootAuthorityVerb root) @?= "up"
                rootAuthorityProjectName root @?= "hostbootstrap-demo"
                pure (Right ())
    , testCase "a store already bound to another project refuses this one" $
        withStore $ \store -> do
            firstOutcome <-
                withAuthorityEntry store $ \session -> do
                    operator <- verifyOperatorAuthorization session
                    case operator of
                        Left failure -> pure (Left failure)
                        Right authorized ->
                            withOtherProject "other-project" $ \other ->
                                withFreshBrokerEpoch session other $ \epoch ->
                                    withVerifiedRootInvocation
                                        session
                                        other
                                        authorized
                                        epoch
                                        ProjectUp
                                        (\_ -> pure (Right ()))
            assertBool "the first project binds the store" (isRight firstOutcome)
            second <-
                withAuthorityEntry store $ \session -> do
                    operator <- verifyOperatorAuthorization session
                    case operator of
                        Left failure -> pure (Left failure)
                        Right authorized ->
                            withProject "hostbootstrap-demo" $ \ours ->
                                withFreshBrokerEpoch session ours $ \epoch ->
                                    withVerifiedRootInvocation
                                        session
                                        ours
                                        authorized
                                        epoch
                                        ProjectUp
                                        (\_ -> pure (Right ()))
            case second of
                Left (AuthorityStoreNotOurs _ _) -> pure ()
                other -> assertFailure ("expected a store-binding refusal, got " <> show other)
    , testCase "one invocation is consumed exactly once" $
        withStore $ \store ->
            withRoot store ProjectUp $ \session root ->
                    withProject "hostbootstrap-demo" $ \project ->
                        withTestPlan $ \plan -> do
                            first <-
                                authorizeProjectCommand
                                    session
                                    project
                                    root
                                    plan
                                    Execute
                                    "host"
                                    (\authority -> pure (Right (commandAuthorityFrame authority)))
                            first @?= Right "host"
                            again <-
                                authorizeProjectCommand
                                    session
                                    project
                                    root
                                    plan
                                    Execute
                                    "host"
                                    (\_ -> pure (Right ("second" :: Text)))
                            case again of
                                Left (AuthorityInvocationConsumed _) -> pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected a consumed invocation, got " <> show other)
    , testCase "a distinct phase at the same frame is a distinct invocation" $
        withStore $ \store ->
            withRoot store ProjectUp $ \session root ->
                    withProject "hostbootstrap-demo" $ \project ->
                        withTestPlan $ \plan -> do
                            prepare <-
                                authorizeProjectCommand
                                    session
                                    project
                                    root
                                    plan
                                    Prepare
                                    "host"
                                    (\_ -> pure (Right ()))
                            execute <-
                                authorizeProjectCommand
                                    session
                                    project
                                    root
                                    plan
                                    Execute
                                    "host"
                                    (\_ -> pure (Right ()))
                            prepare @?= Right ()
                            execute @?= Right ()
                            pure (Right ())
    , testCase "a frame outside the plan cannot be authorized" $
        withStore $ \store ->
            withRoot store ProjectUp $ \session root ->
                    withProject "hostbootstrap-demo" $ \project ->
                        withTestPlan $ \plan -> do
                            outcome <-
                                authorizeProjectCommand
                                    session
                                    project
                                    root
                                    plan
                                    Execute
                                    "not-a-frame"
                                    (\_ -> pure (Right ()))
                            case outcome of
                                Left (AuthorityUnknownFrame frameName) -> do
                                    frameName @?= "not-a-frame"
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected an unknown-frame refusal, got " <> show other)
    , testCase "the verb vocabulary is closed" $ do
        case parseProjectVerb "up" of
            Right (SomeProjectVerb verb) -> projectVerbName verb @?= "up"
            other -> assertFailure ("expected the up verb, got " <> show other)
        case parseProjectVerb "deploy" of
            Left (AuthorityUnknownVerb raw) -> raw @?= "deploy"
            other -> assertFailure ("expected an unknown verb, got " <> show other)
    , testCase "a settled-destroy close root comes only from a destroy authority" $
        withStore $ \store ->
            withRoot store ProjectDestroy $ \_session root -> do
                productionCloseRootVerb (destroyCloseRoot root) @?= SettledDestroyClose
                productionCloseRootVerb (preEffectCloseRoot root) @?= PreEffectRefusalClose
                pure (Right ())
    ]

-- Project mode and run leases ---------------------------------------------------------

modeCases :: [TestTree]
modeCases =
    [ testCase "production takes the mode and retains it across a second entry" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                first <-
                    withProductionRoot store project ProjectUp $ \root ->
                        pure (Right (projectModeLeaseMode (productionRootModeLease root)))
                first @?= Right ProductionMode
                again <-
                    withProductionRoot store project ProjectDown $ \root ->
                        pure (Right (projectModeLeaseMode (productionRootModeLease root)))
                again @?= Right ProductionMode
    , testCase "a mismatched mode cannot reach the harness planner or snapshot write" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                production <-
                    withProductionRoot store project ProjectUp $ \_ -> pure (Right ())
                production @?= Right ()
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> do
                        outcome <-
                            withHarnessRoot
                                store
                                project
                                ProjectUp
                                (satisfiedPreconditions project)
                                proof
                                ( \_ ->
                                    assertFailure "the mismatched mode reached the harness planner" ::
                                        IO (Either ModeError ())
                                )
                        case outcome of
                            Left (ModeHeldByAnother held requested) -> do
                                held @?= "production"
                                assertBool
                                    "the requested mode is the harness run"
                                    ("harness:" `isPrefix` requested)
                            other ->
                                assertFailure ("expected a mode conflict, got " <> show other)
                        snapshots <-
                            withProtectedEntry' store $ \session -> do
                                records <- listProtectedRecords session
                                pure $ case records of
                                    Left failure -> Left (ModeStoreFailure failure)
                                    Right keys ->
                                        Right
                                            ( filter
                                                ( ("snapshot.hostbootstrap-demo." `Text.isPrefixOf`)
                                                    . recordKeyText
                                                )
                                                keys
                                            )
                        snapshots @?= Right []
    , testCase "the harness bracket refuses when a production config exists" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project ->
                withSystemTempDirectory "hostbootstrap-sibling" $ \siblingDirectory -> do
                    writeFile (siblingDirectory </> "hostbootstrap-demo.dhall") "{=}"
                    swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                    proof <- either (assertFailure . show) pure swept
                    outcome <-
                        withHarnessRoot
                            store
                            project
                            ProjectUp
                            (harnessPreconditions project siblingDirectory (pure False))
                            proof
                            (\_ -> pure (Right ()))
                    case outcome of
                        Left (ModeHarnessRefused (ProductionConfigPresent _)) -> pure ()
                        other -> assertFailure ("expected a safety refusal, got " <> show other)
    , testCase "a lease cannot be bound without a persisted plan snapshot" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let run = unboundRunLeaseRun (productionRootUnboundLease root)
                            observed <-
                                verifyPlanSnapshot session project run (\_ -> pure (Right ()))
                            case observed of
                                Left (ModeSnapshotMissing named) -> do
                                    named @?= runIdText run
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected a missing snapshot, got " <> show other)
                outcome @?= Right ()
    , testCase "a fresh binding proves no recovery is owed" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session ->
                            withBoundSnapshot session project root $ \snapshot ->
                                bindRunLease
                                    session
                                    project
                                    (productionRootUnboundLease root)
                                    snapshot
                                    ( \binding -> case binding of
                                        FreshRunLeaseBinding bound _ ->
                                            pure (Right (boundRunLeasePlanDigest bound))
                                        ExistingRunLeaseBinding _ recovery ->
                                            assertFailure
                                                ("expected a fresh binding, got " <> show recovery)
                                    )
                outcome @?= Right "plan-1"
    , testCase "rebinding an already-bound lease yields bound-invocation recovery" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session ->
                            withBoundSnapshot session project root $ \snapshot -> do
                                let bind = bindRunLease session project (productionRootUnboundLease root) snapshot
                                first <- bind (\_ -> pure (Right ()))
                                first @?= Right ()
                                -- The second binding is *not* an error: it is the
                                -- abandoned-invocation case, and it must arrive as
                                -- recovery authority rather than a fresh binding.
                                bind
                                    ( \binding -> case binding of
                                        ExistingRunLeaseBinding _ recovery -> do
                                            branch <-
                                                eliminateProductionBoundRecovery
                                                    session
                                                    project
                                                    recovery
                                            case branch of
                                                Right (ProductionOpenRevisionRecovery open) -> do
                                                    openRevisionKind open @?= NormalRevision
                                                    pure (Right ())
                                                other ->
                                                    assertFailure
                                                        ("expected Open revision recovery, got " <> show other)
                                        FreshRunLeaseBinding _ _ ->
                                            assertFailure "the second binding must not be fresh"
                                    )
                outcome @?= Right ()
    , testCase "a plan snapshot is byte-identically idempotent and immutable" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let run = unboundRunLeaseRun (productionRootUnboundLease root)
                            key <- expectKey ("snapshot.hostbootstrap-demo." <> runIdText run)
                            _ <- expectRight =<< persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                            firstObserved <- expectRight =<< readProtectedRecord session key
                            first <-
                                maybe
                                    (assertFailure "the first snapshot write was absent")
                                    pure
                                    firstObserved
                            -- Repeating the exact bytes is success without a
                            -- replacement write or record-version advance.
                            _ <- expectRight =<< persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                            identicalObserved <- expectRight =<< readProtectedRecord session key
                            identical <-
                                maybe
                                    (assertFailure "the idempotent snapshot disappeared")
                                    pure
                                    identicalObserved
                            protectedRecordVersion identical @?= protectedRecordVersion first
                            protectedRecordBytes identical @?= protectedRecordBytes first
                            -- A differing revision/digest is rejected at
                            -- persistence, before lease binding can reinterpret
                            -- the same run as a replacement plan.
                            substituted <-
                                persistPlanSnapshot session project run 2 "spec-1" "plan-2"
                            case substituted of
                                Left (ModeSnapshotMismatch expected observed) -> do
                                    expected @?= "revision 2, spec spec-1, plan plan-2"
                                    observed @?= "revision 1, spec spec-1, plan plan-1"
                                other ->
                                    assertFailure
                                        ("expected immutable snapshot refusal, got " <> show other)
                            unchangedObserved <- expectRight =<< readProtectedRecord session key
                            unchanged <-
                                maybe
                                    (assertFailure "the refused snapshot disappeared")
                                    pure
                                    unchangedObserved
                            protectedRecordVersion unchanged @?= protectedRecordVersion first
                            protectedRecordBytes unchanged @?= protectedRecordBytes first
                            verified <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    pure
                                        ( Right
                                            ( planSnapshotRevision snapshot
                                            , planSnapshotSpecDigest snapshot
                                            , planSnapshotPlanDigest snapshot
                                            )
                                        )
                            verified @?= Right (1, "spec-1", "plan-1")
                            pure (Right ())
                outcome @?= Right ()
    , testCase "a canonical snapshot persists exact bytes and refuses config/topology substitution" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let run = unboundRunLeaseRun (productionRootUnboundLease root)
                                firstSnapshot = canonicalTestSnapshot "config-a"
                                configReplacement = canonicalTestSnapshot "config-b"
                                topologyReplacement =
                                    canonicalTestSnapshotFor "config-a" alternateTestStepPlan
                            key <- expectKey ("snapshot.hostbootstrap-demo." <> runIdText run)
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot
                                        session
                                        project
                                        run
                                        1
                                        firstSnapshot
                            firstObserved <- expectRight =<< readProtectedRecord session key
                            firstRecord <-
                                maybe
                                    (assertFailure "the canonical snapshot write was absent")
                                    pure
                                    firstObserved
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot
                                        session
                                        project
                                        run
                                        1
                                        firstSnapshot
                            identicalObserved <- expectRight =<< readProtectedRecord session key
                            identicalRecord <-
                                maybe
                                    (assertFailure "the idempotent canonical snapshot disappeared")
                                    pure
                                    identicalObserved
                            protectedRecordVersion identicalRecord @?= protectedRecordVersion firstRecord
                            protectedRecordBytes identicalRecord @?= protectedRecordBytes firstRecord
                            substituted <-
                                persistCanonicalPlanSnapshot
                                    session
                                    project
                                    run
                                    1
                                    configReplacement
                            case substituted of
                                Left (ModeSnapshotMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected canonical substitution refusal, got " <> show other)
                            topologySubstituted <-
                                persistCanonicalPlanSnapshot
                                    session
                                    project
                                    run
                                    1
                                    topologyReplacement
                            case topologySubstituted of
                                Left (ModeSnapshotMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected topology substitution refusal, got " <> show other)
                            verified <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    pure
                                        ( Right
                                            ( planSnapshotSpecDigest snapshot
                                            , planSnapshotPlanDigest snapshot
                                            , planSnapshotConfigDigest snapshot
                                            , planSnapshotCanonicalBytes snapshot
                                            )
                                        )
                            verified
                                @?= Right
                                    ( canonicalPlanSnapshotSpecDigest firstSnapshot
                                    , canonicalPlanSnapshotDigest firstSnapshot
                                    , Just "config-a"
                                    , Just (canonicalPlanSnapshotBytes firstSnapshot)
                                    )
                            unchangedObserved <- expectRight =<< readProtectedRecord session key
                            unchangedRecord <-
                                maybe
                                    (assertFailure "the refused canonical snapshot disappeared")
                                    pure
                                    unchangedObserved
                            protectedRecordVersion unchangedRecord @?= protectedRecordVersion firstRecord
                            protectedRecordBytes unchangedRecord @?= protectedRecordBytes firstRecord
                            pure (Right ())
                outcome @?= Right ()
    , testCase "a hostile canonical frame length is rejected before allocation" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let run = unboundRunLeaseRun (productionRootUnboundLease root)
                                hostile =
                                    LazyByteString.toStrict
                                        ( Builder.toLazyByteString
                                            ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                                                <> Builder.word64BE 1
                                                <> Builder.word64BE 1
                                                <> Builder.word64BE maxBound
                                            )
                                        )
                            key <- expectKey ("snapshot.hostbootstrap-demo." <> runIdText run)
                            _ <-
                                expectRight
                                    =<< compareAndSwapProtectedRecord
                                        session
                                        key
                                        ExpectAbsent
                                        hostile
                            decoded <-
                                verifyPlanSnapshot session project run (\_ -> pure (Right ()))
                            case decoded of
                                Left (ModeMalformedRecord malformedKey) -> do
                                    malformedKey @?= recordKeyText key
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected bounded malformed-record refusal, got " <> show other)
                outcome @?= Right ()
    , testCase "each scope's recovery eliminator refuses the other's disposition" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let unbound = productionRootUnboundLease root
                                run = unboundRunLeaseRun unbound
                            _ <- expectRight =<< persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                            _ <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease session project unbound snapshot (\_ -> pure (Right ()))
                            -- A Harness Closing epoch is not Production evidence.
                            _ <- expectRight =<< recordHarnessClosingEpoch session project run 7
                            production <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease session project unbound snapshot $ \binding ->
                                        case binding of
                                            ExistingRunLeaseBinding _ recovery ->
                                                Right <$> eliminateProductionBoundRecovery session project recovery
                                            FreshRunLeaseBinding _ _ ->
                                                assertFailure "expected an existing binding"
                            case production of
                                Right (Left (ModeWrongRecoveryScope scope _)) -> scope @?= "production"
                                other ->
                                    assertFailure
                                        ("production recovery must refuse a closing epoch, got " <> show other)
                            -- And symmetrically: a Production acknowledgment is
                            -- not Harness evidence.
                            _ <-
                                expectRight
                                    =<< recordProductionInvocationAcknowledgment
                                        session
                                        project
                                        run
                                        =<< expectCloseKey "close-1"
                            harness <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease session project unbound snapshot $ \binding ->
                                        case binding of
                                            ExistingRunLeaseBinding _ recovery ->
                                                Right <$> eliminateHarnessBoundRecovery session project recovery
                                            FreshRunLeaseBinding _ _ ->
                                                assertFailure "expected an existing binding"
                            case harness of
                                Right (Left (ModeWrongRecoveryScope scope _)) -> do
                                    scope @?= "harness"
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("harness recovery must refuse an acknowledgment, got " <> show other)
                outcome @?= Right ()
    , testCase "the Open branch reports the recorded migration side of the barrier" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let unbound = productionRootUnboundLease root
                                run = unboundRunLeaseRun unbound
                            _ <- expectRight =<< persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                            _ <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease session project unbound snapshot (\_ -> pure (Right ()))
                            _ <-
                                expectRight
                                    =<< recordOpenRevisionMigration
                                        session
                                        project
                                        run
                                        (IncompleteMigration "migration-1")
                            verifyPlanSnapshot session project run $ \snapshot ->
                                bindRunLease session project unbound snapshot $ \binding ->
                                    case binding of
                                        ExistingRunLeaseBinding _ recovery -> do
                                            branch <-
                                                eliminateHarnessBoundRecovery session project recovery
                                            case branch of
                                                Right (HarnessOpenRevisionRecovery open) -> do
                                                    openRevisionKind open
                                                        @?= IncompleteMigration "migration-1"
                                                    pure (Right ())
                                                other ->
                                                    assertFailure
                                                        ("expected Open revision recovery, got " <> show other)
                                        FreshRunLeaseBinding _ _ ->
                                            assertFailure "expected an existing binding"
                outcome @?= Right ()
    , testCase "the recovered production profile needs the Open branch, not an acknowledgment" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let unbound = productionRootUnboundLease root
                                run = unboundRunLeaseRun unbound
                            _ <- expectRight =<< persistPlanSnapshot session project run 3 "spec-1" "plan-1"
                            _ <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease session project unbound snapshot (\_ -> pure (Right ()))
                            verifyPlanSnapshot session project run $ \snapshot ->
                                bindRunLease session project unbound snapshot $ \binding ->
                                    case binding of
                                        ExistingRunLeaseBinding bound recovery -> do
                                            branch <-
                                                eliminateProductionBoundRecovery session project recovery
                                            case branch of
                                                Right (ProductionOpenRevisionRecovery open) -> do
                                                    let recovered =
                                                            withRecoveredProductionLifecycleProfile
                                                                (productionRootAuthority root)
                                                                (productionRootModeLease root)
                                                                bound
                                                                snapshot
                                                                open
                                                                recoveredProductionProfilePlanDigest
                                                    recovered @?= Right "plan-1"
                                                    pure (Right ())
                                                other ->
                                                    assertFailure
                                                        ("expected Open revision recovery, got " <> show other)
                                        FreshRunLeaseBinding _ _ ->
                                            assertFailure "expected an existing binding"
                outcome @?= Right ()
    , testCase "a production profile needs the production mode lease" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        pure
                            ( fmap
                                lifecycleProfileMode
                                ( withProductionLifecycleProfile
                                    (productionRootModeLease root)
                                    (productionRootUnboundLease root)
                                )
                            )
                outcome @?= Right ProductionMode
    , testCase "releasing production mode requires matching closure evidence" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectDestroy $ \root ->
                        withProtectedEntry' store $ \session -> do
                            evidence <-
                                verifyNoProjectResourcesAcquired
                                    session
                                    project
                                    (unboundRunLeaseRun (productionRootUnboundLease root))
                            preEffect <- either (assertFailure . show) pure evidence
                            mismatched <-
                                releaseProductionMode
                                    session
                                    project
                                    (destroyCloseRoot (productionRootAuthority root))
                                    preEffect
                            case mismatched of
                                Left (ModeClosureMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected a closure mismatch, got " <> show other)
                            matched <-
                                releaseProductionMode
                                    session
                                    project
                                    (preEffectCloseRoot (productionRootAuthority root))
                                    preEffect
                            matched @?= Right ()
                            pure (Right ())
                outcome @?= Right ()
    , testCase "production mode is released, so a harness run may then start" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                _ <-
                    withProductionRoot store project ProjectDestroy $ \root ->
                        withProtectedEntry' store $ \session -> do
                            evidence <-
                                verifyNoProjectResourcesAcquired
                                    session
                                    project
                                    (unboundRunLeaseRun (productionRootUnboundLease root))
                            preEffect <- either (assertFailure . show) pure evidence
                            released <-
                                releaseProductionMode
                                    session
                                    project
                                    (preEffectCloseRoot (productionRootAuthority root))
                                    preEffect
                            released @?= Right ()
                            pure (Right ())
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                outcome <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        proof
                        (\root -> pure (Right (projectModeLeaseMode (harnessRootModeLease root))))
                case outcome of
                    Right (HarnessMode _) -> pure ()
                    other -> assertFailure ("expected harness mode, got " <> show other)
    ]

-- Abandoned-run recovery ------------------------------------------------------------------

recoveryCases :: [TestTree]
recoveryCases =
    [ testCase "an abandoned unbound lease is swept and its mode released" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                -- Simulate a killed harness run: the bracket recorded its mode
                -- and unbound lease and then died without closing either.
                _ <- abandonHarnessRun store project
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "a new harness run is refused while an abandoned lease is unresolved" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeRecoveryRequired _) -> pure ()
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , testCase "a bound abandoned lease is resolved through the caller's fold" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease (resolveNothingAcquired store project)
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> closedAbandonedHarnessRunsCount proof @?= 1
    , -- The reopening the sweep's bound callback needs. Before it existed the
      -- bound branch classified the run and closed it through a bare 'RunId', so
      -- nothing said who was allowed to resolve it and no authority was minted
      -- for the branches that cannot be resolved yet.
      testCase "reopening an abandoned bound run yields destroy-only authority on a fresh generation" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                (run, abandonedEpoch) <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened -> do
                            abandonedHarnessRunId reopened @?= run
                            -- The exact old snapshot, read back durably rather
                            -- than reconstructed from the current config.
                            let snapshot = abandonedHarnessSnapshot reopened
                            planSnapshotRun snapshot @?= run
                            planSnapshotSpecDigest snapshot @?= "spec-1"
                            planSnapshotPlanDigest snapshot @?= "plan-1"
                            -- The already-bound lease, not a rebinding: same run,
                            -- same digests.
                            let bound = abandonedHarnessBoundLease reopened
                            boundRunLeaseRun bound @?= run
                            boundRunLeaseSpecDigest bound @?= "spec-1"
                            boundRunLeasePlanDigest bound @?= "plan-1"
                            -- Recovery may release and never acquire.
                            projectVerbName
                                (rootAuthorityVerb (abandonedHarnessDestroyRoot reopened))
                                @?= "destroy"
                            -- Its close authority says it is recovery's, not the
                            -- live run's.
                            let closeRoot = abandonedHarnessCloseRoot reopened
                            harnessCloseRootOrigin closeRoot @?= RecoveredHarnessClose
                            harnessCloseRootRun closeRoot @?= run
                            -- The mode is still the abandoned run's own, and every
                            -- yielded value sits on a strictly fresher broker
                            -- generation, so the dead run's permits are fenced out
                            -- rather than resumed.
                            let modeLease = abandonedHarnessModeLease reopened
                                reopenedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            projectModeLeaseMode modeLease @?= HarnessMode run
                            assertBool
                                ( "generation "
                                    <> show reopenedEpoch
                                    <> " must be fresher than the abandoned "
                                    <> show abandonedEpoch
                                )
                                (reopenedEpoch > abandonedEpoch)
                            pure (Right ())
                -- Reopening resolves nothing on its own, so the sweep still
                -- refuses: the recheck is what makes a no-op callback fail.
                case swept of
                    Left (ModeRecoveryRequired named) ->
                        assertBool
                            ("the refusal names the run: " <> Text.unpack named)
                            (runIdText run `Text.isInfixOf` named)
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , testCase "an unbound lease cannot be reopened; only the sweep may close it" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                _ <- abandonHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns
                        store
                        project
                        ( \lease -> do
                            refused <-
                                withAbandonedHarnessRun store project lease (\_ -> pure (Right ()))
                            case refused of
                                -- No snapshot exists, so there is nothing to
                                -- reopen: 'verifyUnboundLeaseHasNoEffects' is the
                                -- only route for this kind.
                                Left (ModeLeaseNotBindable _ state) -> do
                                    state @?= "unbound"
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected an unbound refusal, got " <> show other)
                        )
                        neverResolves
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
    , -- The exhaustive first branch: a run that persisted its Closing epoch is a
      -- close to resume, never normal revision recovery, and reopening must say
      -- so with the exact epoch rather than leave the caller to guess.
      testCase "a persisted closing epoch is reopened as the closing branch" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                (run, _) <- abandonBoundHarnessRun store project
                _ <-
                    expectRight
                        =<< withProtectedEntry'
                            store
                            (\session -> recordHarnessClosingEpoch session project run 9)
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened ->
                            case abandonedHarnessRecovery reopened of
                                HarnessPersistedClosing epoch -> do
                                    epoch @?= 9
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected the closing branch, got " <> show other)
                -- And it stays fail-closed: a close this sprint cannot resume
                -- must block the next run rather than be swept away.
                case swept of
                    Left (ModeRecoveryRequired named) ->
                        assertBool
                            ("the refusal names the run: " <> Text.unpack named)
                            (runIdText run `Text.isInfixOf` named)
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , -- The sweep observed the lease at an earlier store version, so reopening
      -- rechecks it. A lease another resolver already closed is not a run this
      -- opener may reopen.
      testCase "a lease resolved since the sweep observed it cannot be reopened again" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease -> do
                        first <-
                            withAbandonedHarnessRun
                                store
                                project
                                lease
                                (resolveNothingAcquired store project)
                        _ <- expectRight first
                        again <-
                            withAbandonedHarnessRun store project lease (\_ -> pure (Right ()))
                        case again of
                            Left (ModeLeaseNotBindable _ state) -> do
                                state @?= "closed"
                                pure (Right ())
                            other ->
                                assertFailure
                                    ("expected a closed-lease refusal, got " <> show other)
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "an unbound lease with a recorded effect refuses the no-effect proof" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                run <- abandonHarnessRun store project
                effectKey <-
                    expectKey ("effect.hostbootstrap-demo." <> runIdText run <> ".vm")
                _ <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord session effectKey ExpectAbsent "created"
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeEffectsRecorded _) -> pure ()
                    other ->
                        assertFailure ("expected a recorded-effect refusal, got " <> show other)
    , -- The cross-profile half of the four-process reservation race. Production
      -- has no generative run id and no liveness lock, so its unbound lease is
      -- shaped exactly like an abandoned harness run's. The sweep must not read
      -- it as one: closing a live invocation's lease is the same defect the
      -- harness race exposed, across profiles instead of within one, and here it
      -- would also discard the evidence Production's own bound recovery needs.
      testCase "a live production invocation is never swept, and refuses the harness by mode" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \_root -> do
                        swept <-
                            recoverAbandonedHarnessRuns store project neverResolves neverResolves
                        proof <- either (assertFailure . show) pure swept
                        -- Nothing was abandoned: the only incomplete lease is the
                        -- live Production invocation's, which is not this sweep's
                        -- to resolve.
                        closedAbandonedHarnessRunsCount proof @?= 0
                        refused <-
                            withHarnessRoot
                                store
                                project
                                ProjectUp
                                (satisfiedPreconditions project)
                                proof
                                (\_ -> pure (Right ()))
                        case refused of
                            -- § Z: a harness run against live Production is a
                            -- stated exclusion, not an overlap and not a sweep.
                            Left (ModeHeldByAnother held wanted) -> do
                                held @?= "production"
                                assertBool
                                    ("the harness names itself: " <> Text.unpack wanted)
                                    ("harness:" `Text.isPrefixOf` wanted)
                            other ->
                                assertFailure
                                    ("expected the production mode to refuse, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , -- The control for the two cross-profile races below. Without it, "the
      -- competitor exited 3" proves nothing: a probe that can never take a
      -- profile refuses an empty store just as convincingly as a held one.
      testCase "the competitor process takes either profile when no mode is held" $ do
        executable <- getExecutablePath
        withStore $ \store ->
            probeProfile executable (protectedStoreRoot store) "harness"
                >>= (@?= ProfileAcquired)
        withStore $ \store ->
            probeProfile executable (protectedStoreRoot store) "production"
                >>= (@?= ProfileAcquired)
    , -- The out-of-process half of the cross-profile exclusion. The in-process
      -- case above proves the decision; this one proves it holds against a real
      -- competitor, because the root brackets release the exclusive entry once
      -- the mode transaction commits. What the competitor contends on is
      -- therefore the durable mode record, not the entry.
      testCase "a competitor harness process is refused by live Production, across processes" $ do
        executable <- getExecutablePath
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \_root -> do
                        probed <- probeProfile executable (protectedStoreRoot store) "harness"
                        case probed of
                            ProfileRefusedBy held -> held @?= "production"
                            other ->
                                assertFailure
                                    ("expected the competitor to be refused by production, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a competitor production process is refused by a live harness run, across processes" $ do
        executable <- getExecutablePath
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                outcome <-
                    withHarnessRoot store project ProjectUp (satisfiedPreconditions project) proof $ \root -> do
                        probed <- probeProfile executable (protectedStoreRoot store) "production"
                        case probed of
                            -- The refusal names the exact run holding the mode,
                            -- so the competitor cannot have been refused by some
                            -- other obstacle that also exits 3.
                            ProfileRefusedBy held ->
                                held @?= "harness:" <> runIdText (harnessRootRunId root)
                            other ->
                                assertFailure
                                    ("expected the competitor to be refused by the harness run, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    ]

-- Invocation and terminal close -------------------------------------------------------------

closeCases :: [TestTree]
closeCases =
    [ testCase "the session-completeness proof refuses while any session is open" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            permit <- expectRight =<< openProjectJournal session closePlanDigest
                            _ <-
                                expectRight
                                    =<< openOperationSession
                                        session
                                        (projectModeLeaseEpoch (productionRootModeLease root))
                                        closePlanDigest
                                        "s1"
                                        permit
                            -- A session that registered NO operations is still a
                            -- member of the set: it is exactly what a kill right
                            -- after open leaves behind.
                            still <-
                                verifyAllSessionsClosedHere session
                                    :: IO (Either SessionError (VerifiedAllSessionsClosed () ()))
                            case still of
                                Left (SessionStillOpen _) -> pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected a still-open refusal, got " <> show other)
                outcome @?= Right ()
    , testCase "a closing project admits no new session, and only its own epoch resumes" $
        withStore $ \store -> do
            outcome <- withProtectedEntry store $ \session -> do
                permit <- expectRight =<< openProjectJournal session closePlanDigest
                _closing <- expectRight =<< beginClosingProject session closePlanDigest 7 permit
                state <- expectRight =<< readProjectJournalState session closePlanDigest
                state @?= ClosingProject 7
                -- Retaining the pre-close Open permit is harmless: it can only
                -- resume the exact persisted closing epoch and the result is a
                -- type-distinct Closing permit.
                resumed <- beginClosingProject session closePlanDigest 7 permit
                assertBool "the same closing epoch resumes idempotently" (not (isLeft resumed))
                second <- beginClosingProject session closePlanDigest 9 permit
                case second of
                    Left (SessionProjectClosing _) -> pure ()
                    other ->
                        assertFailure ("a second closing epoch must refuse, got " <> show other)
                reopened <- openProjectJournal session closePlanDigest
                case reopened of
                    Left (SessionProjectClosing _) -> pure (Right ())
                    other ->
                        assertFailure
                            ("a closing project must refuse a new session, got " <> show other)
            outcome @?= Right ()
    , testCase "only the matching closing epoch can become closed" $
        withStore $ \store -> do
            outcome <- withProtectedEntry store $ \session -> do
                permit <- expectRight =<< openProjectJournal session closePlanDigest
                closing <- expectRight =<< beginClosingProject session closePlanDigest 7 permit
                wrong <- recordClosedProject session closePlanDigest 8 closing
                case wrong of
                    Left (SessionProjectClosing _) -> pure ()
                    other ->
                        assertFailure ("a foreign closing epoch must refuse, got " <> show other)
                closed <- expectRight =<< recordClosedProject session closePlanDigest 7 closing
                state <- expectRight =<< readProjectJournalState session closePlanDigest
                state @?= ClosedProject
                closed `seq` pure (Right ())
            outcome @?= Right ()
    , testCase "closing a production invocation retains production mode" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                closed <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session ->
                            withBoundSnapshot session project root $ \snapshot ->
                                bindRunLease
                                    session
                                    project
                                    (productionRootUnboundLease root)
                                    snapshot
                                    ( \binding -> case binding of
                                        FreshRunLeaseBinding bound _ -> do
                                            sessions <-
                                                expectRight =<< verifyAllSessionsClosedHere session
                                            key <- expectCloseKey "close-up-1"
                                            completed <-
                                                expectRight
                                                    (completeProductionInvocation bound sessions)
                                            outcome <-
                                                closeCompletedProductionInvocation
                                                    session
                                                    project
                                                    (productionRootModeLease root)
                                                    completed
                                                    key
                                            case outcome of
                                                Right (ProductionInvocationCloseCommitted done) -> do
                                                    productionInvocationClosedRun done
                                                        @?= boundRunLeaseRun bound
                                                    pure (Right ())
                                                other ->
                                                    assertFailure
                                                        ("expected a committed close, got " <> show other)
                                        ExistingRunLeaseBinding _ _ ->
                                            assertFailure "expected a fresh binding"
                                    )
                closed @?= Right ()
                -- The invocation ended; the PROJECT did not. Production still
                -- holds the mode, which is what makes `down` keep the exclusion,
                -- so a harness run is still refused.
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                refused <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        proof
                        (\_ -> pure (Right ()))
                case refused of
                    Left (ModeHeldByAnother held _) -> held @?= "production"
                    other ->
                        assertFailure
                            ("a harness run must still be refused, got " <> show other)
    , testCase "harness terminal close releases the mode last, so the next run may start" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                proof <- sweep store project
                outcome <-
                    withHarnessRoot store project ProjectUp (satisfiedPreconditions project) proof $
                        \root -> withProtectedEntry' store $ \session -> do
                            let run = harnessRootRunId root
                            _ <-
                                expectRight
                                    =<< persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                            verifyPlanSnapshot session project run $ \snapshot ->
                                bindRunLease session project (harnessRootUnboundLease root) snapshot $
                                    \binding -> case binding of
                                        FreshRunLeaseBinding bound _ -> do
                                            sessions <-
                                                expectRight =<< verifyAllSessionsClosedHere session
                                            authorized <-
                                                expectRight
                                                    =<< authorizeHarnessClose
                                                        session
                                                        project
                                                        (currentHarnessCloseRoot root)
                                                        (harnessRootModeLease root)
                                                        bound
                                                        sessions
                                                        11
                                            harnessCloseEpoch authorized @?= 11
                                            harnessCloseRun authorized @?= run
                                            -- The origin travels onto the
                                            -- authorization, so the terminal
                                            -- record says which way it was reached.
                                            harnessCloseOrigin authorized @?= LiveHarnessClose
                                            done <-
                                                expectRight
                                                    =<< finalizeHarnessClose session project authorized
                                            closedHarnessProjectRun done @?= run
                                            pure (Right ())
                                        ExistingRunLeaseBinding _ _ ->
                                            assertFailure "expected a fresh binding"
                outcome @?= Right ()
                -- Mode was released only after the lease closed, so a fresh run
                -- can now take it.
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                next <- either (assertFailure . show) pure swept
                again <-
                    withHarnessRoot
                        store
                        project
                        ProjectUp
                        (satisfiedPreconditions project)
                        next
                        (\_ -> pure (Right ("second run" :: String)))
                again @?= Right "second run"
    , -- The @projectId@ index is the config family's, so two projects carrying
      -- the same family share it and the type alone cannot separate them. That is
      -- exactly the substitution the close root's recorded project name catches:
      -- without it, a close root minted for one project closed another's run.
      testCase "a close root cannot close a run in a different project" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                proof <- sweep store project
                outcome <-
                    withHarnessRoot store project ProjectUp (satisfiedPreconditions project) proof $
                        \root ->
                            withProject "hostbootstrap-other" $ \other ->
                                withProtectedEntry' store $ \session -> do
                                    evidence <-
                                        expectRight
                                            =<< verifyNoProjectResourcesAcquired
                                                session
                                                project
                                                (harnessRootRunId root)
                                    refused <-
                                        closeHarnessRun
                                            session
                                            other
                                            (currentHarnessCloseRoot root)
                                            (harnessRootModeLease root)
                                            evidence
                                    case refused of
                                        Left (ModeClosureMismatch expected observed) -> do
                                            expected @?= "hostbootstrap-other"
                                            observed @?= "hostbootstrap-demo"
                                            pure (Right ())
                                        other' ->
                                            assertFailure
                                                ("expected a project mismatch, got " <> show other')
                outcome @?= Right ()
    ]

-- | The plan digest the close cases journal under.
closePlanDigest :: Text
closePlanDigest = "plan-1"

{- | The completeness proof at this spec's plan digest, with its phantom indices
pinned so each use site does not need an annotation.
-}
verifyAllSessionsClosedHere ::
    ProtectedSession session ->
    IO (Either SessionError (VerifiedAllSessionsClosed scope planId))
verifyAllSessionsClosedHere session = verifyAllSessionsClosed session closePlanDigest

-- Fixtures -------------------------------------------------------------------------------------

withStore :: (ProtectedStore -> IO ()) -> IO ()
withStore use =
    withSystemTempDirectory "hostbootstrap-authority" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        case opened of
            Left failure -> assertFailure (show failure)
            Right store -> use store

{- | The installed fixture project. Its index is the fixture's own project type,
exactly as a real binary's is, so a plan built from the fixture codec and an
authority minted for the fixture project share one @projectId@.
-}
withProject ::
    Text ->
    (InstalledProject Fixture.FixtureProject -> IO result) ->
    IO result
withProject name use =
    case installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig name of
        Left failure -> assertFailure (show failure)
        Right project -> use project

withRoot ::
    ProtectedStore ->
    ProjectVerb verb ->
    ( forall session brokerGeneration.
      ProtectedSession session ->
      RootInvocationAuthority (Production Fixture.FixtureProject) brokerGeneration verb ->
      IO (Either AuthorityError ())
    ) ->
    IO ()
withRoot store verb use = do
    outcome <-
        withAuthorityEntry store $ \session -> do
            operator <- verifyOperatorAuthorization session
            case operator of
                Left failure -> pure (Left failure)
                Right authorized ->
                    withProject "hostbootstrap-demo" $ \project ->
                        withFreshBrokerEpoch session project $ \epoch ->
                            withVerifiedRootInvocation
                                session
                                project
                                authorized
                                epoch
                                verb
                                (use session)
    case outcome of
        Left failure -> assertFailure (show failure)
        Right () -> pure ()

{- | The authority-error flavoured protected bracket. 'withProtectedEntry'
reports store failures, so a case that works in authority errors wraps them.
-}
withAuthorityEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either AuthorityError result)) ->
    IO (Either AuthorityError result)
withAuthorityEntry store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . AuthorityStoreFailure) id outcome)

{- | The mode-error flavoured protected bracket, so a mode case can run several
record operations under one exclusive entry.
-}
withProtectedEntry' ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ModeError result)) ->
    IO (Either ModeError result)
withProtectedEntry' store action = do
    outcome <- withProtectedEntry store (fmap Right . action)
    pure (either (Left . ModeStoreFailure) id outcome)

withTestPlan ::
    (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> IO result) ->
    IO result
withTestPlan use =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec testStepPlan use

canonicalTestSnapshot :: Text -> CanonicalPlanSnapshot
canonicalTestSnapshot configDigest =
    canonicalTestSnapshotFor configDigest testStepPlan

canonicalTestSnapshotFor :: Text -> StepPlan -> CanonicalPlanSnapshot
canonicalTestSnapshotFor configDigest plan =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlanForConfig codec configDigest plan lifecyclePlanSnapshot

testStepPlan :: StepPlan
testStepPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged)))
            , contextInitStep "context" (StepFrame "vm" "VM") (const (pure StepChanged))
            ]
        )

alternateTestStepPlan :: StepPlan
alternateTestStepPlan =
    either
        (error . show)
        id
        (mkStepPlan [contextInitStep "context" (StepFrame "host" "Host") (const (pure StepChanged))])

satisfiedPreconditions :: InstalledProject projectId -> HarnessPreconditions
satisfiedPreconditions project =
    harnessPreconditions project "/nonexistent-hostbootstrap-dir" (pure False)

{- | A fold callback that resolves nothing, so the sweep must refuse rather than
report a vacuous success.
-}
neverResolves :: VerifiedIncompleteRunLease projectId -> IO (Either ModeError ())
neverResolves _ = pure (Right ())

{- | Resolve a reopened run the one way this sprint can prove is safe: its own
records show it acquired nothing, so its lease and mode close under the
reopening's own 'RecoveredHarnessClose' authority.
-}
resolveNothingAcquired ::
    ProtectedStore ->
    InstalledProject projectId ->
    AbandonedHarnessRun projectId oldRunId specDigest planDigest brokerGeneration ->
    IO (Either ModeError ())
resolveNothingAcquired store project reopened = do
    proved <-
        withProtectedEntry' store $ \session ->
            verifyNoProjectResourcesAcquired session project (abandonedHarnessRunId reopened)
    case proved of
        Left failure -> pure (Left failure)
        Right evidence ->
            withProtectedEntry' store $ \session ->
                closeHarnessRun
                    session
                    project
                    (abandonedHarnessCloseRoot reopened)
                    (abandonedHarnessModeLease reopened)
                    evidence

{- | Open a harness run and abandon it: the mode and unbound lease are recorded
and never closed, exactly as a hard kill leaves them.
-}
abandonHarnessRun :: ProtectedStore -> InstalledProject projectId -> IO RunId
abandonHarnessRun store project = do
    proof <- sweep store project
    outcome <-
        withHarnessRoot
            store
            project
            ProjectUp
            (satisfiedPreconditions project)
            proof
            (\root -> pure (Right (harnessRootRunId root)))
    either (assertFailure . show) pure outcome

-- | The empty-sweep proof a fresh store always yields.
sweep ::
    ProtectedStore ->
    InstalledProject projectId ->
    IO (ClosedAbandonedHarnessRuns projectId)
sweep store project = do
    swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
    either (assertFailure . show) pure swept

{- | The same, but bound to a plan snapshot before the kill. It also hands back
the broker generation the abandoned run held, so a reopening can be shown to run
on a strictly fresher one.
-}
abandonBoundHarnessRun ::
    ProtectedStore ->
    InstalledProject projectId ->
    IO (RunId, Word64)
abandonBoundHarnessRun store project = do
    proof <- sweep store project
    outcome <-
        withHarnessRoot
            store
            project
            ProjectUp
            (satisfiedPreconditions project)
            proof
            ( \root ->
                withProtectedEntry' store $ \session -> do
                    let run = harnessRootRunId root
                    persisted <- persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                    case persisted of
                        Left failure -> pure (Left failure)
                        Right () ->
                            verifyPlanSnapshot session project run $ \snapshot ->
                                bindRunLease
                                    session
                                    project
                                    (harnessRootUnboundLease root)
                                    snapshot
                                    ( \_ ->
                                        pure
                                            ( Right
                                                ( run
                                                , brokerEpochWord
                                                    (projectModeLeaseEpoch (harnessRootModeLease root))
                                                )
                                            )
                                    )
            )
    either (assertFailure . show) pure outcome

-- Helpers ---------------------------------------------------------------------------------------

{- | Persist a run's plan snapshot and hand back the verified value, which is
the only thing 'bindRunLease' accepts.
-}
withBoundSnapshot ::
    ProtectedSession session ->
    InstalledProject Fixture.FixtureProject ->
    ProductionRoot Fixture.FixtureProject brokerGeneration verb ->
    ( forall specDigest planDigest.
      VerifiedPlanSnapshot Fixture.FixtureProject specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withBoundSnapshot session project root use = do
    let run = unboundRunLeaseRun (productionRootUnboundLease root)
    persisted <- persistPlanSnapshot session project run 1 "spec-1" "plan-1"
    case persisted of
        Left failure -> pure (Left failure)
        Right () -> verifyPlanSnapshot session project run use

expectRight :: Show failure => Either failure result -> IO result
expectRight = either (assertFailure . show) pure

expectCloseKey :: Text -> IO InvocationCloseKey
expectCloseKey raw = case mkInvocationCloseKey raw of
    Left failure -> assertFailure (show failure)
    Right key -> pure key

expectKey :: Text -> IO RecordKey
expectKey raw = case mkRecordKey raw of
    Left failure -> assertFailure (show failure)
    Right key -> pure key

{- | A second installed project, for the store-binding refusal. Its index is
generative, which is the point: it is not this binary's project.
-}
withOtherProject ::
    Text ->
    (forall projectId. InstalledProject projectId -> IO result) ->
    IO result
withOtherProject name use =
    case withInstalledProject name use of
        Left failure -> assertFailure (show failure)
        Right action -> action

isLeft :: Either failure success -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either failure success -> Bool
isRight (Right _) = True
isRight _ = False

isPrefix :: Text -> Text -> Bool
isPrefix = Text.isPrefixOf

-- | What a separate process observed when it attempted the same entry.
data EntryProbe = Acquired | Contended | ProbeFailed String
    deriving (Eq, Show)

{- | Attempt the store's exclusive entry from a *different process*, using the
production primitive rather than a lookalike: the test executable re-invokes
itself with the probe argument 'Spec.hs' dispatches.
-}
probeEntry :: FilePath -> FilePath -> IO EntryProbe
probeEntry executable storeRoot = do
    (code, out, err) <-
        readProcessWithExitCode executable ["--hostbootstrap-protected-entry-probe", storeRoot] ""
    pure $ case code of
        ExitSuccess -> Acquired
        ExitFailure 3 -> Contended
        ExitFailure other -> ProbeFailed (show other <> " " <> out <> " " <> err)

{- | What a separate process observed when it attempted a lifecycle profile
against this project's store. 'ProfileRefusedBy' carries the mode name the
competitor was refused by — its own observation, not the holder's state.
-}
data ProfileProbe
    = ProfileAcquired
    | ProfileRefusedBy Text
    | ProfileProbeFailed String
    deriving (Eq, Show)

-- | Attempt a lifecycle profile from a *different process*.
probeProfile :: FilePath -> FilePath -> String -> IO ProfileProbe
probeProfile executable storeRoot profile =
    withSystemTempDirectory "hostbootstrap-profile-probe" $ \directory -> do
        let reasonPath = directory </> "reason"
        (code, out, err) <-
            readProcessWithExitCode
                executable
                ["--hostbootstrap-mode-profile-probe", storeRoot, profile, reasonPath]
                ""
        case code of
            ExitSuccess -> pure ProfileAcquired
            ExitFailure 3 -> do
                reason <- readFile reasonPath
                pure $ case Text.splitOn "\t" (Text.pack reason) of
                    (held : _) -> ProfileRefusedBy held
                    [] -> ProfileProbeFailed reason
            ExitFailure other -> do
                reason <- readReasonIfPresent reasonPath
                pure (ProfileProbeFailed (show other <> " " <> reason <> " " <> out <> " " <> err))

readReasonIfPresent :: FilePath -> IO String
readReasonIfPresent path = do
    present <- doesFileExist path
    if present then readFile path else pure ""
