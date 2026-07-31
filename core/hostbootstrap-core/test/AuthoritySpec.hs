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
module AuthoritySpec (tests, runEntryProbe) where

import Data.Text (Text)
import qualified Data.Text as Text
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
import HostBootstrap.Reconcile (LifecyclePlan, withLifecyclePlan)
import HostBootstrap.Lift (localContext)
import HostBootstrap.Step (
    StepFrame (..),
    StepPlan,
    contextInitStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
 )
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
    , testCase "a harness run cannot take the mode while production holds it" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                _ <-
                    withProductionRoot store project ProjectUp $ \_ -> pure (Right ())
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
                                (\_ -> pure (Right ()))
                        case outcome of
                            Left (ModeHeldByAnother held requested) -> do
                                held @?= "production"
                                assertBool
                                    "the requested mode is the harness run"
                                    ("harness:" `isPrefix` requested)
                            other ->
                                assertFailure ("expected a mode conflict, got " <> show other)
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
    , testCase "a lease bound to different digests refuses rather than resuming" $
        withStore $ \store ->
            withProject "hostbootstrap-demo" $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withProtectedEntry' store $ \session -> do
                            let run = unboundRunLeaseRun (productionRootUnboundLease root)
                            _ <- expectRight =<< persistPlanSnapshot session project run 1 "spec-1" "plan-1"
                            _ <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease
                                        session
                                        project
                                        (productionRootUnboundLease root)
                                        snapshot
                                        (\_ -> pure (Right ()))
                            -- A substituted snapshot under the same run is a
                            -- snapshot swap, not a resumption.
                            _ <- expectRight =<< persistPlanSnapshot session project run 2 "spec-1" "plan-2"
                            again <-
                                verifyPlanSnapshot session project run $ \snapshot ->
                                    bindRunLease
                                        session
                                        project
                                        (productionRootUnboundLease root)
                                        snapshot
                                        (\_ -> pure (Right ()))
                            case again of
                                Left (ModeSnapshotMismatch expected observed) -> do
                                    expected @?= "plan-2"
                                    observed @?= "plan-1"
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected a snapshot mismatch, got " <> show other)
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
                        withProtectedEntry' store $ \session -> do
                            evidence <-
                                verifyNoProjectResourcesAcquired
                                    session
                                    project
                                    (incompleteRunLeaseRun lease)
                            case evidence of
                                Left failure -> pure (Left failure)
                                Right proof ->
                                    closeHarnessRun
                                        session
                                        project
                                        (incompleteRunLeaseRun lease)
                                        proof
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> closedAbandonedHarnessRunsCount proof @?= 1
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
                closing <- expectRight =<< beginClosingProject session closePlanDigest 7 permit
                state <- expectRight =<< readProjectJournalState session closePlanDigest
                state @?= ClosingProject 7
                resumed <- beginClosingProject session closePlanDigest 7 closing
                assertBool "the same closing epoch resumes idempotently" (not (isLeft resumed))
                second <- beginClosingProject session closePlanDigest 9 closing
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
    , testCase "an open project cannot jump straight to closed" $
        withStore $ \store -> do
            outcome <- withProtectedEntry store $ \session -> do
                permit <- expectRight =<< openProjectJournal session closePlanDigest
                straight <- recordClosedProject session closePlanDigest 7 permit
                assertBool "Open cannot become Closed directly" (isLeft straight)
                closing <- expectRight =<< beginClosingProject session closePlanDigest 7 permit
                wrong <- recordClosedProject session closePlanDigest 8 closing
                case wrong of
                    Left (SessionProjectClosing _) -> pure ()
                    other ->
                        assertFailure ("a foreign closing epoch must refuse, got " <> show other)
                _ <- expectRight =<< recordClosedProject session closePlanDigest 7 closing
                state <- expectRight =<< readProjectJournalState session closePlanDigest
                state @?= ClosedProject
                pure (Right ())
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
                                                        (harnessRootModeLease root)
                                                        bound
                                                        sessions
                                                        11
                                            harnessCloseEpoch authorized @?= 11
                                            harnessCloseRun authorized @?= run
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

testStepPlan :: StepPlan
testStepPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure ())))
            , contextInitStep "context" (StepFrame "vm" "VM") (const (pure ()))
            ]
        )

satisfiedPreconditions :: InstalledProject projectId -> HarnessPreconditions
satisfiedPreconditions project =
    harnessPreconditions project "/nonexistent-hostbootstrap-dir" (pure False)

{- | A fold callback that resolves nothing, so the sweep must refuse rather than
report a vacuous success.
-}
neverResolves :: VerifiedIncompleteRunLease projectId -> IO (Either ModeError ())
neverResolves _ = pure (Right ())

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

-- | The same, but bound to a plan snapshot before the kill.
abandonBoundHarnessRun :: ProtectedStore -> InstalledProject projectId -> IO RunId
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
                                    (\_ -> pure (Right run))
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
