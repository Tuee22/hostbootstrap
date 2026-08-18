{-# LANGUAGE CPP #-}
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

import Control.Exception (bracket_)
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (filterM, replicateM)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import Data.Word (Word64)
import Data.List (sort)
import qualified Fixture
import HostBootstrap.Authority
import HostBootstrap.Lifecycle.Closure
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.Lifecycle.Session (
    ProjectJournalState (ClosedProject, ClosingProject),
    SessionError (SessionProjectClosing, SessionStillOpen),
    VerifiedAllSessionsClosed,
    admissionPlanDigest,
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
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotSpecDigest,
    lifecyclePlanSnapshot,
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
import System.Directory (
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
    listDirectory,
    renameDirectory,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitSuccess, exitWith)
import SourceGuard (repoRelativePath)
import System.FilePath (takeExtension, (</>))
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
            Fixture.withFixtureInstalledProject $ \project ->
                report =<< attempt store project
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
        , testGroup "plan migration" migrationCases
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
    , testCase "a losing create contender can reread exact bytes but cannot replace a collision" $
        withStore $ \store -> do
            key <- expectKey "prepared-lower-boundary"
            first <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "canonical-prepared-row"
            version <- either (assertFailure . show) pure first
            identical <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "canonical-prepared-row"
            assertBool "the identical create contender still loses the CAS" (isLeft identical)
            exact <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            case exact of
                Right (Just record) -> do
                    protectedRecordVersion record @?= version
                    protectedRecordBytes record @?= "canonical-prepared-row"
                other -> assertFailure ("expected exact durable readback, got " <> show other)
            collision <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session key ExpectAbsent "conflicting-row"
            assertBool "the conflicting create contender is refused" (isLeft collision)
            unchanged <-
                withProtectedEntry store $ \session ->
                    readProtectedRecord session key
            fmap (fmap protectedRecordBytes) unchanged
                @?= Right (Just "canonical-prepared-row")
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

exactProjectUpAuthorityCases :: [TestTree]
exactProjectUpAuthorityCases =
    [ testCase "the generic root gate consumes one exact root lifecycle context for every closed verb" $ do
        cwd <- getCurrentDirectory
        repoRoot <-
            findRepoRoot cwd
                >>= maybe (assertFailure "could not locate repository root") pure
        source <-
            TextIO.readFile
                ( repoRoot
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "src"
                    </> "HostBootstrap"
                    </> "Authority"
                    </> "ProjectPlan.hs"
                )
        let normalized = Text.unwords (Text.words source)
            require fragment =
                assertBool
                    ("the generic root gate lost " ++ Text.unpack fragment)
                    (fragment `Text.isInfixOf` normalized)
        mapM_
            require
            [ "authorizeRootProject :: RootInvocationAuthority scope brokerGeneration verb -> ProjectVerb verb ->"
            , "LifecycleCursor scope planId frame brokerGeneration verb phase -> ValidatedLifecycleContext scope specDigest planId configId frame ->"
            , "withValidatedRootLifecycleContext lifecycleContext"
            , "expectedVerb = projectVerbName verb"
            , "requireText \"root project verb\" expectedVerb"
            , "requireText \"cursor project verb\" expectedVerb"
            , "requireText \"journal project verb\" expectedVerb"
            ]
        assertBool
            "the former Up-only root gate must be absent"
            (not ("authorizeProjectUp" `Text.isInfixOf` source))
    , testCase "reverse-root reservation replay is closed, root-only, and version-stable" $ do
        cwd <- getCurrentDirectory
        repoRoot <-
            findRepoRoot cwd
                >>= maybe (assertFailure "could not locate repository root") pure
        source <-
            TextIO.readFile
                ( repoRoot
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "src"
                    </> "HostBootstrap"
                    </> "Authority"
                    </> "Kernel.hs"
                )
        let normalized = Text.unwords (Text.words source)
            require fragment =
                assertBool
                    ("the reverse-root reservation gate lost " ++ Text.unpack fragment)
                    (fragment `Text.isInfixOf` normalized)
            commandAuthoritySection =
                fst
                    ( Text.breakOn
                        "instance Show (CommandAuthority"
                        (snd (Text.breakOn "data CommandAuthority" normalized))
                    )
            reservationIdentitySection =
                fst
                    ( Text.breakOn
                        "brokerCounterKey ::"
                        (snd (Text.breakOn "reservationIdentity ::" normalized))
                    )
        mapM_
            require
            [ "data CommandReservation scope planId frame brokerGeneration verb phase = CommandReservation Text Text Text Text (BrokerEpoch brokerGeneration) (ProjectVerb verb) (LifecyclePhase phase) Bool"
            , "phase (reverseRootReplayEligible (rootAuthorityVerb root) phase)"
            , "(BrokerEpoch project store generation) verb phase False"
            , "Right (Just record) | protectedRecordBytes record == identity , replayEligible -> deliver (protectedRecordVersion record)"
            , "| protectedRecordBytes record == identity -> pure (Left (AuthorityInvocationConsumed invocation))"
            , "Right version -> do readback <- readProtectedRecord session recordKey"
            , "protectedRecordVersion record == version , protectedRecordBytes record == identity -> deliver (protectedRecordVersion record)"
            , "reverseRootReplayEligible ProjectDown Teardown = True"
            , "reverseRootReplayEligible ProjectDestroy Teardown = True"
            , "reverseRootReplayEligible _ _ = False"
            , "invocation = \"command-\" <> sha256Hex identity"
            , "Text.pack (show (recordVersionWord version))"
            , "invocationKey identity"
            ]
        assertBool
            "replay policy leaked into CommandAuthority rather than its private reservation"
            (not ("Bool" `Text.isInfixOf` commandAuthoritySection))
        Text.count "field (" reservationIdentitySection @?= 7
        mapM_
            ( \fragment ->
                assertBool
                    ("canonical reservation identity gained " ++ Text.unpack fragment)
                    (not (fragment `Text.isInfixOf` reservationIdentitySection))
            )
            ["replayEligible", "decode", "caller", "wire"]
    ]

authorityCases :: [TestTree]
authorityCases =
    exactProjectUpAuthorityCases
        <> [ testCase "installed identity matches the normalized invoked executable" $ do
        executable <- getExecutablePath
        let invoked = normalizeExecutableIdentity executable
        outcome <-
            withInstalledProjectIdentity
                invoked
                (pure . installedProjectName)
        outcome @?= Right invoked
    , testCase "installed identity normalizes the Windows executable suffix" $ do
        normalizeExecutableIdentity "/installed/authority-project.ExE"
            @?= "authority-project"
    , testCase "installed identity refuses a different declared project" $ do
        executable <- getExecutablePath
        let invoked = normalizeExecutableIdentity executable
        outcome <-
            withInstalledProjectIdentity
                "declared-project"
                (pure . installedProjectName)
        case outcome of
            Left (AuthorityInvalidIdentity reason) ->
                assertBool "the refusal names both identities" $
                    "declared-project" `Text.isInfixOf` reason
                        && invoked `Text.isInfixOf` reason
            other -> assertFailure ("expected an executable-identity refusal, got " <> show other)
    , testCase "installed identity refuses a non-stable project name" $ do
        outcome <-
            withInstalledProjectIdentity
                "not.a.stable.name"
                (pure . installedProjectName)
        case outcome of
            Left (AuthorityInvalidIdentity reason) ->
                assertBool "the stable-name grammar made the decision" $
                    "may contain only alphanumerics, '-', and '_'" `Text.isInfixOf` reason
                        && "not.a.stable.name" `Text.isInfixOf` reason
            other -> assertFailure ("expected an invalid stable name, got " <> show other)
    , testCase "installed identity refuses non-ASCII record names" $ do
        outcome <-
            withInstalledProjectIdentity
                "authority-λ"
                (pure . installedProjectName)
        case outcome of
            Left (AuthorityInvalidIdentity reason) ->
                assertBool "the ASCII stable-name grammar made the decision" $
                    "may contain only alphanumerics, '-', and '_'" `Text.isInfixOf` reason
                        && "authority-λ" `Text.isInfixOf` reason
            other -> assertFailure ("expected a non-ASCII identity refusal, got " <> show other)
    , testCase "OS-principal evidence names the exact protected store" $
        withStore $ \store -> do
            outcome <- withAuthorityEntry store verifyOsPrincipal
            case outcome of
                Left failure -> assertFailure (show failure)
                Right principal ->
                    assertBool "the evidence retained this store identity" $
                        protectedStoreIdentityText (protectedStoreIdentity store)
                            `Text.isInfixOf` Text.pack (show principal)
    , testCase "OS-principal verification refuses an unavailable records directory" $
        withStore $ \store -> do
            outcome <-
                withAuthorityEntry store $ \session -> do
                    let recordsRoot = sessionStoreRoot session </> "records"
                        unavailableRoot = recordsRoot <> ".operator-refusal"
                    bracket_
                        (renameDirectory recordsRoot unavailableRoot)
                        (renameDirectory unavailableRoot recordsRoot)
                        (verifyOsPrincipal session)
            case outcome of
                Left (AuthorityOperatorRefused _) -> pure ()
                other -> assertFailure ("expected an OS-principal refusal, got " <> show other)
    , testCase "broker generations advance monotonically" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                first <-
                    withProductionRoot store project ProjectUp $ \root ->
                        pure (Right (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root))))
                second <-
                    withProductionRoot store project ProjectUp $ \root ->
                        pure (Right (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root))))
                first @?= Right 1
                second @?= Right 2
    , testCase "a malformed broker counter refuses instead of reusing a generation" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                key <-
                    expectKey
                        ("broker." <> installedProjectName project <> ".generation")
                seeded <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord session key ExpectAbsent "not-a-counter"
                assertBool "the malformed counter was seeded" (isRight seeded)
                outcome <-
                    withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                case outcome of
                    Left (ModeAuthorityFailure (AuthorityInvalidIdentity reason)) ->
                        assertBool "the refusal names the malformed counter" ("malformed" `Text.isInfixOf` reason)
                    other -> assertFailure ("expected a malformed-counter refusal, got " <> show other)
    , testCase "an exhausted broker counter refuses instead of wrapping" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                key <-
                    expectKey
                        ("broker." <> installedProjectName project <> ".generation")
                seeded <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord
                            session
                            key
                            ExpectAbsent
                            (ByteStringChar8.pack (show (maxBound :: Word64)))
                assertBool "the exhausted broker counter was seeded" (isRight seeded)
                outcome <-
                    withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                case outcome of
                    Left (ModeAuthorityFailure (AuthorityInvalidIdentity reason)) ->
                        assertBool "the refusal names exhaustion" ("exhausted" `Text.isInfixOf` reason)
                    other -> assertFailure ("expected an exhausted-counter refusal, got " <> show other)
    , testCase "broker counters are separated by store" $
        withStore $ \firstStore ->
            withStore $ \secondStore ->
                Fixture.withFixtureInstalledProject $ \project -> do
                    first <-
                        withProductionRoot firstStore project ProjectUp $ \root ->
                            pure
                                ( Right
                                    (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root)))
                                )
                    second <-
                        withProductionRoot secondStore project ProjectUp $ \root ->
                            pure
                                ( Right
                                    (brokerEpochWord (rootAuthorityEpoch (productionRootAuthority root)))
                                )
                    first @?= Right 1
                    second @?= Right 1
    , testCase "the root gate mints authority for the exact verb and scope" $
        withStore $ \store ->
            withRoot store ProjectUp $ \project _session root -> do
                projectVerbName (rootAuthorityVerb root) @?= "up"
                rootAuthorityProjectName root @?= installedProjectName project
                rootScopeAuthority root `seq` pure ()
                pure (Right ())
    , testCase "the authority kernel has a closed package-internal importer set" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure
        let sourceRoot = root </> "core" </> "hostbootstrap-core" </> "src"
            kernelPath = sourceRoot </> "HostBootstrap" </> "Authority" </> "Kernel.hs"
            expected =
                [ "HostBootstrap/Authority.hs"
                , "HostBootstrap/Authority/ProjectPlan.hs"
                , "HostBootstrap/Command/LifecycleEntry.hs"
                , "HostBootstrap/Handoff.hs"
                , "HostBootstrap/Handoff/Runtime.hs"
                , "HostBootstrap/Lifecycle/Closure.hs"
                , "HostBootstrap/Lifecycle/Mode.hs"
                , "HostBootstrap/Lifecycle/RootedPlan.hs"
                , "HostBootstrap/Lifecycle/Session.hs"
                , "HostBootstrap/ProjectPlan/Child/Internal.hs"
                , "HostBootstrap/Teardown/Internal.hs"
                ]
        sources <- haskellSources sourceRoot
        importers <-
            filterM
                (fmap (Text.isInfixOf "HostBootstrap.Authority.Kernel") . TextIO.readFile)
                (filter (/= kernelPath) sources)
        sort (map (repoRelativePath sourceRoot) importers) @?= expected
        childReservationCallers <-
            filterM
                (fmap (Text.isInfixOf "childCommandReservationKernel") . TextIO.readFile)
                (filter (/= kernelPath) sources)
        sort (map (repoRelativePath sourceRoot) childReservationCallers)
            @?= ["HostBootstrap/ProjectPlan/Child/Internal.hs"]
        facade <- TextIO.readFile (sourceRoot </> "HostBootstrap" </> "Authority.hs")
        authorityFacadeExports facade
            @?= Right
                [ "VerbUp"
                , "VerbDown"
                , "VerbDestroy"
                , "ProjectVerb (..)"
                , "projectVerbName"
                , "SomeProjectVerb (..)"
                , "parseProjectVerb"
                , "PreparePhase"
                , "ExecutePhase"
                , "TeardownPhase"
                , "LifecyclePhase (..)"
                , "lifecyclePhaseName"
                , "InstalledProjectIdentity"
                , "withInstalledProjectIdentity"
                , "normalizeExecutableIdentity"
                , "installedProjectName"
                , "VerifiedOsPrincipal"
                , "verifyOsPrincipal"
                , "BrokerEpoch"
                , "brokerEpochWord"
                , "RootInvocationAuthority"
                , "RootScopeAuthority"
                , "rootScopeAuthority"
                , "rootAuthorityVerb"
                , "rootAuthorityEpoch"
                , "rootAuthorityProjectName"
                , "CommandAuthority"
                , "commandAuthorityVerb"
                , "commandAuthorityPhase"
                , "commandAuthorityFrame"
                , "commandAuthorityEpoch"
                , "commandAuthorityInvocation"
                , "commandAuthorityMatchesStore"
                , "InvocationId"
                , "invocationIdText"
                , "AuthorityError (..)"
                , "authorityErrorMessage"
                ]
        compatibilityExists <-
            doesFileExist
                (sourceRoot </> "HostBootstrap" </> "Config" </> "InstalledProject.hs")
        assertBool "the configuration compatibility module is absent" (not compatibilityExists)
        cabal <- TextIO.readFile (root </> "core" </> "hostbootstrap-core" </> "hostbootstrap-core.cabal")
        assertBool "the configuration compatibility module is not exposed" $
            not ("HostBootstrap.Config.InstalledProject" `Text.isInfixOf` cabal)
        kernel <- TextIO.readFile kernelPath
        assertBool "the kernel has no caller-fixed installed-identity escape" $
            not ("installedProjectForKernel" `Text.isInfixOf` kernel)
        assertBool "the kernel has no configuration dependency" $
            not ("import HostBootstrap.Config" `Text.isInfixOf` kernel)
        assertBool "the kernel has no lifecycle-plan dependency" $
            not ("import HostBootstrap.Reconcile" `Text.isInfixOf` kernel)
        projectPlanAuthority <-
            TextIO.readFile
                (sourceRoot </> "HostBootstrap" </> "Authority" </> "ProjectPlan.hs")
        assertBool "the caller-selected lifecycle-plan authority gate is absent" $
            not ("authorizeProjectCommand" `Text.isInfixOf` projectPlanAuthority)
        assertBool "the Production compatibility authority gate is absent" $
            not ("authorizeProductionProjectCommand" `Text.isInfixOf` projectPlanAuthority)
    , testCase "a store already bound to another project refuses this one" $
        withStore $ \store -> do
            key <- expectKey "authority.binding"
            seeded <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord
                        session
                        key
                        ExpectAbsent
                        (TextEncoding.encodeUtf8 "other-project")
            assertBool "the foreign project binding was seeded" (isRight seeded)
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <- withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
                case outcome of
                    Left (ModeAuthorityFailure (AuthorityStoreNotOurs expected observed)) -> do
                        expected @?= installedProjectName project
                        observed @?= "other-project"
                    other -> assertFailure ("expected a store-binding refusal, got " <> show other)
    , testCase "a malformed authority binding refuses root admission" $
        withStore $ \store -> do
            key <- expectKey "authority.binding"
            seeded <-
                withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord
                        session
                        key
                        ExpectAbsent
                        (ByteString.pack [0xff])
            assertBool "the malformed authority binding was seeded" (isRight seeded)
            outcome <-
                Fixture.withFixtureInstalledProject $ \project ->
                    withProductionRoot store project ProjectUp (\_ -> pure (Right ()))
            case outcome of
                Left (ModeAuthorityFailure AuthorityMalformedBinding{}) -> pure ()
                other -> assertFailure ("expected a malformed-binding refusal, got " <> show other)
    , testCase "the verb vocabulary is closed" $ do
        case parseProjectVerb "up" of
            Right (SomeProjectVerb verb) -> projectVerbName verb @?= "up"
            other -> assertFailure ("expected the up verb, got " <> show other)
        case parseProjectVerb "down" of
            Right (SomeProjectVerb verb) -> projectVerbName verb @?= "down"
            other -> assertFailure ("expected the down verb, got " <> show other)
        case parseProjectVerb "destroy" of
            Right (SomeProjectVerb verb) -> projectVerbName verb @?= "destroy"
            other -> assertFailure ("expected the destroy verb, got " <> show other)
        case parseProjectVerb "deploy" of
            Left (AuthorityUnknownVerb raw) -> raw @?= "deploy"
            other -> assertFailure ("expected an unknown verb, got " <> show other)
    , testCase "a settled-destroy close root comes only from a destroy authority" $
        withStore $ \store ->
            withRoot store ProjectDestroy $ \_project _session root -> do
                productionCloseRootVerb (destroyCloseRoot root) @?= SettledDestroyClose
                productionCloseRootVerb (preEffectCloseRoot root) @?= PreEffectRefusalClose
                pure (Right ())
    ]

-- Project mode and run leases ---------------------------------------------------------

modeCases :: [TestTree]
modeCases =
    [ testCase "production takes the mode and retains it across a second entry" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                first <-
                    withProductionRoot store project ProjectUp $ \root ->
                        pure (Right (projectModeLeaseName (productionRootModeLease root)))
                first @?= Right "production"
                again <-
                    withProductionRoot store project ProjectDown $ \root ->
                        pure (Right (projectModeLeaseName (productionRootModeLease root)))
                again @?= Right "production"
    , testCase "a mismatched mode cannot reach the harness planner or snapshot write" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
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
                                                ( ( ( "snapshot."
                                                        <> installedProjectName project
                                                        <> "."
                                                    )
                                                        `Text.isPrefixOf`
                                                  )
                                                    . recordKeyText
                                                )
                                                keys
                                            )
                        snapshots @?= Right []
    , testCase "the harness bracket refuses when a production config exists" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project ->
                withSystemTempDirectory "hostbootstrap-sibling" $ \siblingDirectory -> do
                    writeFile
                        ( siblingDirectory
                            </> Text.unpack (installedProjectName project) <> ".dhall"
                        )
                        "{=}"
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
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        let unbound = productionRootUnboundLease root
                         in do
                                observed <- verifyPlanSnapshot unbound (\_ -> pure (Right ()))
                                case observed of
                                    Left (ModeSnapshotMissing named) -> do
                                        named @?= unboundRunLeaseRunText unbound
                                        pure (Right ())
                                    other ->
                                        assertFailure
                                            ("expected a missing snapshot, got " <> show other)
                outcome @?= Right ()
    , testCase "a fresh binding proves no recovery is owed" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            planDigest <-
                                expectRight
                                    =<< bindRunLease
                                        (productionRootUnboundLease root)
                                        snapshot
                                        (pure . boundRunLeasePlanDigest)
                            pure (Right planDigest)
                outcome @?= Right "plan-1"
    , testCase "a second Production root preserves an existing bound lease and snapshot" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                let runName = "production"
                leaseKey <-
                    expectKey
                        ( "lease."
                            <> installedProjectName project
                            <> "."
                            <> runName
                        )
                snapshotKey <-
                    expectKey
                        ( "snapshot."
                            <> installedProjectName project
                            <> "."
                            <> runName
                        )
                bound <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            _ <-
                                expectRight
                                    =<< bindRunLease
                                        (productionRootUnboundLease root)
                                        snapshot
                                        (\_ -> pure ())
                            pure (Right ())
                bound @?= Right ()
                beforeLeaseObserved <- expectRight =<< readModeRecord store leaseKey
                beforeLease <-
                    maybe (assertFailure "the bound Production lease disappeared") pure beforeLeaseObserved
                beforeSnapshotObserved <- expectRight =<< readModeRecord store snapshotKey
                beforeSnapshot <-
                    maybe (assertFailure "the Production snapshot disappeared") pure beforeSnapshotObserved
                entries <- newIORef (0 :: Int)
                refused <-
                    withProductionRoot store project ProjectUp $ \_ -> do
                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                        pure (Right ())
                case refused of
                    Left (ModeLeaseNotBindable run state) -> do
                        run @?= runName
                        state @?= "bound"
                    other ->
                        assertFailure
                            ("expected a bound-lease root refusal, got " <> show other)
                readIORef entries >>= (@?= 0)
                afterLeaseObserved <- expectRight =<< readModeRecord store leaseKey
                afterLease <-
                    maybe (assertFailure "the refused root removed the bound lease") pure afterLeaseObserved
                protectedRecordVersion afterLease @?= protectedRecordVersion beforeLease
                protectedRecordBytes afterLease @?= protectedRecordBytes beforeLease
                afterSnapshotObserved <- expectRight =<< readModeRecord store snapshotKey
                afterSnapshot <-
                    maybe (assertFailure "the refused root removed the snapshot") pure afterSnapshotObserved
                protectedRecordVersion afterSnapshot @?= protectedRecordVersion beforeSnapshot
                protectedRecordBytes afterSnapshot @?= protectedRecordBytes beforeSnapshot
    , testCase "a Production root preserves and refuses a malformed lease record" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                leaseKey <-
                    expectKey
                        ( "lease."
                            <> installedProjectName project
                            <> ".production"
                        )
                _ <-
                    expectRight
                        =<< withProtectedEntry' store (\session -> do
                                written <-
                                    compareAndSwapProtectedRecord
                                        session
                                        leaseKey
                                        ExpectAbsent
                                        "not-a-lease"
                                pure
                                    ( either
                                        (Left . ModeStoreFailure)
                                        (const (Right ()))
                                        written
                                    )
                            )
                beforeObserved <- expectRight =<< readModeRecord store leaseKey
                before <-
                    maybe (assertFailure "the malformed Production lease disappeared") pure beforeObserved
                entries <- newIORef (0 :: Int)
                refused <-
                    withProductionRoot store project ProjectUp $ \_ -> do
                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                        pure (Right ())
                case refused of
                    Left (ModeMalformedRecord key) -> key @?= recordKeyText leaseKey
                    other ->
                        assertFailure
                            ("expected a malformed-lease root refusal, got " <> show other)
                readIORef entries >>= (@?= 0)
                afterObserved <- expectRight =<< readModeRecord store leaseKey
                after <-
                    maybe (assertFailure "the refused root removed the malformed lease") pure afterObserved
                protectedRecordVersion after @?= protectedRecordVersion before
                protectedRecordBytes after @?= protectedRecordBytes before
    , testCase "rebinding an already-bound lease is not a fresh transition" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            let unbound = productionRootUnboundLease root
                            first <- bindRunLease unbound snapshot (\_ -> pure ())
                            _ <- expectRight first
                            second <- bindRunLease unbound snapshot (\_ -> pure ())
                            case second of
                                Left _ -> pure (Right ())
                                Right () -> assertFailure "the second binding must not be fresh"
                outcome @?= Right ()
    , testCase "a plan snapshot is byte-identically idempotent and immutable" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        do
                            let unbound = productionRootUnboundLease root
                                runName = unboundRunLeaseRunText unbound
                            key <-
                                expectKey
                                    ( "snapshot."
                                        <> installedProjectName project
                                        <> "."
                                        <> runName
                                    )
                            _ <- expectRight =<< persistPlanSnapshot unbound 1 "spec-1" "plan-1"
                            firstObserved <- expectRight =<< readModeRecord store key
                            first <-
                                maybe
                                    (assertFailure "the first snapshot write was absent")
                                    pure
                                    firstObserved
                            -- Repeating the exact bytes is success without a
                            -- replacement write or record-version advance.
                            _ <- expectRight =<< persistPlanSnapshot unbound 1 "spec-1" "plan-1"
                            identicalObserved <- expectRight =<< readModeRecord store key
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
                                persistPlanSnapshot unbound 2 "spec-1" "plan-2"
                            case substituted of
                                Left (ModeSnapshotMismatch expected observed) -> do
                                    expected @?= "revision 2, spec spec-1, plan plan-2"
                                    observed @?= "revision 1, spec spec-1, plan plan-1"
                                other ->
                                    assertFailure
                                        ("expected immutable snapshot refusal, got " <> show other)
                            unchangedObserved <- expectRight =<< readModeRecord store key
                            unchanged <-
                                maybe
                                    (assertFailure "the refused snapshot disappeared")
                                    pure
                                    unchangedObserved
                            protectedRecordVersion unchanged @?= protectedRecordVersion first
                            protectedRecordBytes unchanged @?= protectedRecordBytes first
                            verified <-
                                verifyPlanSnapshot unbound $ \snapshot ->
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
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        do
                            let unbound = productionRootUnboundLease root
                                runName = unboundRunLeaseRunText unbound
                                firstSnapshot = canonicalTestSnapshot "config-a"
                                configReplacement = canonicalTestSnapshot "config-b"
                                topologyReplacement =
                                    canonicalTestSnapshotFor "config-a" alternateTestStepPlan
                            key <-
                                expectKey
                                    ( "snapshot."
                                        <> installedProjectName project
                                        <> "."
                                        <> runName
                                    )
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot
                                        unbound
                                        1
                                        firstSnapshot
                            firstObserved <- expectRight =<< readModeRecord store key
                            firstRecord <-
                                maybe
                                    (assertFailure "the canonical snapshot write was absent")
                                    pure
                                    firstObserved
                            _ <-
                                expectRight
                                    =<< persistCanonicalPlanSnapshot
                                        unbound
                                        1
                                        firstSnapshot
                            identicalObserved <- expectRight =<< readModeRecord store key
                            identicalRecord <-
                                maybe
                                    (assertFailure "the idempotent canonical snapshot disappeared")
                                    pure
                                    identicalObserved
                            protectedRecordVersion identicalRecord @?= protectedRecordVersion firstRecord
                            protectedRecordBytes identicalRecord @?= protectedRecordBytes firstRecord
                            substituted <-
                                persistCanonicalPlanSnapshot
                                    unbound
                                    1
                                    configReplacement
                            case substituted of
                                Left (ModeSnapshotMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected canonical substitution refusal, got " <> show other)
                            topologySubstituted <-
                                persistCanonicalPlanSnapshot
                                    unbound
                                    1
                                    topologyReplacement
                            case topologySubstituted of
                                Left (ModeSnapshotMismatch _ _) -> pure ()
                                other ->
                                    assertFailure
                                        ("expected topology substitution refusal, got " <> show other)
                            verified <-
                                verifyPlanSnapshot unbound $ \snapshot ->
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
                            unchangedObserved <- expectRight =<< readModeRecord store key
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
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        do
                            let unbound = productionRootUnboundLease root
                                runName = unboundRunLeaseRunText unbound
                                hostile =
                                    LazyByteString.toStrict
                                        ( Builder.toLazyByteString
                                            ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                                                <> Builder.word64BE 1
                                                <> Builder.word64BE 1
                                                <> Builder.word64BE maxBound
                                            )
                                        )
                            key <-
                                expectKey
                                    ( "snapshot."
                                        <> installedProjectName project
                                        <> "."
                                        <> runName
                                    )
                            _ <-
                                expectRight
                                    =<< withProtectedEntry' store (\session -> do
                                            written <-
                                                compareAndSwapProtectedRecord
                                                    session
                                                    key
                                                    ExpectAbsent
                                                    hostile
                                            pure (either (Left . ModeStoreFailure) (const (Right ())) written)
                                        )
                            decoded <-
                                verifyPlanSnapshot unbound (\_ -> pure (Right ()))
                            case decoded of
                                Left (ModeMalformedRecord malformedKey) -> do
                                    malformedKey @?= recordKeyText key
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected bounded malformed-record refusal, got " <> show other)
                outcome @?= Right ()
    , testCase "a Production profile consumes its exact protected slot once" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root -> do
                        let modeLease = productionRootModeLease root
                            active = productionActiveMode modeLease
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            expectedProject = installedProjectName project
                            expectedStore =
                                protectedStoreIdentityText (protectedStoreIdentity store)
                            expectedInvocation =
                                "lifecycle-profile:"
                                    <> installedProjectName project
                                    <> ":production"
                            open =
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority root))
                                    active
                                    (productionRootUnboundLease root)
                        projectModeLeaseName modeLease @?= "production"
                        brokerEpochWord (activeProjectModeEpoch active) @?= expectedEpoch
                        first <-
                            expectRight
                                =<< open
                                    ( \profile ->
                                        ( lifecycleProfileName profile
                                        , lifecycleProfileEpoch profile
                                        , lifecycleProfileProjectName profile
                                        , lifecycleProfileStoreIdentity profile
                                        )
                                    )
                        first @?= ("production", expectedEpoch, expectedProject, expectedStore)
                        second <- open (const ())
                        case second of
                            Left (AuthorityInvocationConsumed invocation) ->
                                invocation @?= expectedInvocation
                            other ->
                                assertFailure
                                    ("expected the Production profile slot to be consumed, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "two Production profile openers race to one continuation entry" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                entries <- newIORef (0 :: Int)
                outcomes <- newEmptyMVar
                outcome <-
                    withProductionRoot store project ProjectUp $ \root -> do
                        let modeLease = productionRootModeLease root
                            active = productionActiveMode modeLease
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            open =
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority root))
                                    active
                                    (productionRootUnboundLease root)
                            worker = do
                                opened <-
                                    open $ \profile -> do
                                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                                        pure (lifecycleProfileName profile, lifecycleProfileEpoch profile)
                                settled <- case opened of
                                    Left failure -> pure (Left failure)
                                    Right continuation -> Right <$> continuation
                                putMVar outcomes settled
                        _ <- forkIO worker
                        _ <- forkIO worker
                        raced <- replicateM 2 (takeMVar outcomes)
                        readIORef entries >>= (@?= 1)
                        [value | Right value <- raced] @?= [("production", expectedEpoch)]
                        case [failure | Left failure <- raced] of
                            [AuthorityInvocationConsumed _] -> pure ()
                            failures ->
                                assertFailure
                                    ("expected one consumed Production opener, got " <> show failures)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a Harness profile consumes its exact run slot once" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let authority = harnessRootHarnessAuthority root
                            run = harnessRootRunId root
                            modeLease = harnessRootModeLease root
                            active = harnessActiveMode modeLease
                            expectedName = "harness:" <> runIdText run
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            expectedProject = installedProjectName project
                            expectedStore =
                                protectedStoreIdentityText (protectedStoreIdentity store)
                            expectedInvocation =
                                "lifecycle-profile:"
                                    <> installedProjectName project
                                    <> ":"
                                    <> runIdText run
                            open =
                                withHarnessLifecycleProfile
                                    (rootScopeAuthority (harnessRootAuthority root))
                                    authority
                                    run
                                    active
                                    (harnessRootUnboundLease root)
                        projectModeLeaseName modeLease @?= expectedName
                        brokerEpochWord (activeProjectModeEpoch active) @?= expectedEpoch
                        first <-
                            expectRight
                                =<< open
                                    ( \profile ->
                                        ( lifecycleProfileName profile
                                        , lifecycleProfileEpoch profile
                                        , lifecycleProfileProjectName profile
                                        , lifecycleProfileStoreIdentity profile
                                        )
                                    )
                        first @?= (expectedName, expectedEpoch, expectedProject, expectedStore)
                        second <- open (const ())
                        case second of
                            Left (AuthorityInvocationConsumed invocation) ->
                                invocation @?= expectedInvocation
                            other ->
                                assertFailure
                                    ("expected the Harness profile slot to be consumed, got " <> show other)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "two Harness profile openers race to one continuation entry" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                entries <- newIORef (0 :: Int)
                outcomes <- newEmptyMVar
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let authority = harnessRootHarnessAuthority root
                            run = harnessRootRunId root
                            modeLease = harnessRootModeLease root
                            active = harnessActiveMode modeLease
                            expectedName = "harness:" <> runIdText run
                            expectedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            open =
                                withHarnessLifecycleProfile
                                    (rootScopeAuthority (harnessRootAuthority root))
                                    authority
                                    run
                                    active
                                    (harnessRootUnboundLease root)
                            worker = do
                                opened <-
                                    open $ \profile -> do
                                        atomicModifyIORef' entries (\count -> (count + 1, ()))
                                        pure (lifecycleProfileName profile, lifecycleProfileEpoch profile)
                                settled <- case opened of
                                    Left failure -> pure (Left failure)
                                    Right continuation -> Right <$> continuation
                                putMVar outcomes settled
                        _ <- forkIO worker
                        _ <- forkIO worker
                        raced <- replicateM 2 (takeMVar outcomes)
                        readIORef entries >>= (@?= 1)
                        [value | Right value <- raced] @?= [(expectedName, expectedEpoch)]
                        case [failure | Left failure <- raced] of
                            [AuthorityInvocationConsumed _] -> pure ()
                            failures ->
                                assertFailure
                                    ("expected one consumed Harness opener, got " <> show failures)
                        pure (Right ())
                outcome @?= Right ()
    , testCase "the normal unbound no-resource proof refuses same-run acquisition ownership" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let run = runIdText (harnessRootRunId root)
                        acquisitionKey <-
                            writeAcquisitionShapedRecord
                                store
                                project
                                run
                                "normal-unbound"
                                "malformed-normal-acquisition"
                        refused <-
                            verifyNoProjectResourcesAcquired
                                (harnessRootUnboundLease root)
                        case refused of
                            Left (ModeEffectsRecorded recorded) ->
                                recorded @?= recordKeyText acquisitionKey
                            other ->
                                assertFailure
                                    ("expected the normal unbound proof to refuse, got " <> show other)
                        persisted <-
                            withProtectedEntry store $ \session ->
                                readProtectedRecord session acquisitionKey
                        fmap (fmap protectedRecordBytes) persisted
                            @?= Right (Just "malformed-normal-acquisition")
                        pure (Right ())
                outcome @?= Right ()
    , testCase "a journal-only bound run remains classified pre-resource" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withFreshHarnessRoot store project $ \root -> do
                        let run = runIdText (harnessRootRunId root)
                            unbound = harnessRootUnboundLease root
                        _ <- expectRight =<< persistPlanSnapshot unbound 1 "spec-1" "plan-1"
                        verifyPlanSnapshot unbound $ \snapshot -> do
                            bound <- expectRight =<< bindRunLease unbound snapshot pure
                            acquisitionKey <-
                                writeAcquisitionShapedRecord
                                    store
                                    project
                                    run
                                    "41"
                                    "journal-with-no-resource-effect"
                            preResource <- verifyBoundRunHasNoProjectResourcesAcquired bound
                            _ <- either (assertFailure . show) pure preResource
                            persisted <-
                                withProtectedEntry store $ \session ->
                                    readProtectedRecord session acquisitionKey
                            fmap (fmap protectedRecordBytes) persisted
                                @?= Right (Just "journal-with-no-resource-effect")
                            pure (Right ())
                outcome @?= Right ()
    , testCase "releasing production mode requires matching closure evidence" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectDestroy $ \root -> do
                        evidence <-
                            verifyNoProjectResourcesAcquired
                                (productionRootUnboundLease root)
                        preEffect <- either (assertFailure . show) pure evidence
                        withProtectedEntry' store $ \session -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <-
                    withProductionRoot store project ProjectDestroy $ \root -> do
                        evidence <-
                            verifyNoProjectResourcesAcquired
                                (productionRootUnboundLease root)
                        preEffect <- either (assertFailure . show) pure evidence
                        withProtectedEntry' store $ \session -> do
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
                        (\root -> pure (Right (projectModeLeaseName (harnessRootModeLease root))))
                case outcome of
                    Right held | "harness:" `Text.isPrefixOf` held -> pure ()
                    other -> assertFailure ("expected harness mode, got " <> show other)
    ]

-- Abandoned-run recovery ------------------------------------------------------------------

recoveryCases :: [TestTree]
recoveryCases =
    [ testCase "an abandoned unbound lease is swept and its mode released" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                -- Simulate a killed harness run: the bracket recorded its mode
                -- and unbound lease and then died without closing either.
                _ <- abandonHarnessRun store project
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left failure -> assertFailure (show failure)
                    Right proof -> closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "a new harness run is refused while an abandoned lease is unresolved" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeRecoveryRequired _) -> pure ()
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , testCase "a bound abandoned lease is resolved through the caller's fold" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
                (run, abandonedEpoch) <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened -> do
                            runIdText (abandonedHarnessRunId reopened) @?= run
                            -- The exact old snapshot, read back durably rather
                            -- than reconstructed from the current config.
                            let snapshot = abandonedHarnessSnapshot reopened
                            planSnapshotRunText snapshot @?= run
                            planSnapshotSpecDigest snapshot @?= "spec-1"
                            planSnapshotPlanDigest snapshot @?= "plan-1"
                            -- The already-bound lease, not a rebinding: same run,
                            -- same digests.
                            let bound = abandonedHarnessBoundLease reopened
                            boundRunLeaseRunText bound @?= run
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
                            runIdText (harnessCloseRootRun closeRoot) @?= run
                            -- The mode is still the abandoned run's own, and every
                            -- yielded value sits on a strictly fresher broker
                            -- generation, so the dead run's permits are fenced out
                            -- rather than resumed.
                            let modeLease = abandonedHarnessModeLease reopened
                                reopenedEpoch = brokerEpochWord (projectModeLeaseEpoch modeLease)
                            projectModeLeaseName modeLease @?= "harness:" <> run
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
                            (run `Text.isInfixOf` named)
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , testCase "an unbound lease cannot be reopened; only the sweep may close it" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
                (run, _) <-
                    abandonBoundHarnessRunWith store project $ \run ->
                        withProtectedEntry' store $ \session ->
                            recordHarnessClosingEpoch session project run 9
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
                -- The callback resolved nothing, so the sweep's recheck still
                -- refuses and names the run.
                case swept of
                    Left (ModeRecoveryRequired named) ->
                        assertBool
                            ("the refusal names the run: " <> Text.unpack named)
                            (run `Text.isInfixOf` named)
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , {- The close was already authorized after settled destroy:
      'authorizeHarnessClose' persists the epoch before terminal finalization so
      the remaining gap is resumable. Recovery therefore finishes that close
      rather than reopening the run — and it can only finish the exact close the
      dead run persisted. -}
      testCase "a persisted closing epoch is resumed, and only at its own epoch" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                (run, _) <-
                    abandonBoundHarnessRunWith store project $ \run ->
                        withProtectedEntry' store $ \session ->
                            recordHarnessClosingEpoch session project run 9
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened ->
                            case abandonedHarnessRecovery reopened of
                                HarnessPersistedClosing epoch -> do
                                    epoch @?= 9
                                    let resume presented =
                                            withProtectedEntry' store $ \session ->
                                                resumeHarnessClose
                                                    session
                                                    project
                                                    (abandonedHarnessCloseRoot reopened)
                                                    (abandonedHarnessModeLease reopened)
                                                    (abandonedHarnessBoundLease reopened)
                                                    presented
                                    -- an epoch this run never persisted resumes nothing
                                    wrong <- resume (epoch + 1)
                                    case wrong of
                                        Left (ModeEpochMismatch persisted presented) -> do
                                            persisted @?= 9
                                            presented @?= 10
                                        other ->
                                            assertFailure
                                                ("expected an epoch mismatch, got " <> show (() <$ other))
                                    authorization <- expectRight =<< resume epoch
                                    finalized <-
                                        withProtectedEntry' store $ \session ->
                                            finalizeHarnessClose session project authorization
                                    closed <- expectRight finalized
                                    runIdText (closedHarnessProjectRun closed) @?= run
                                    pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected the closing branch, got " <> show other)
                -- The resumed close settled the run, so the sweep's recheck sees
                -- an empty set and the next run may start.
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
    , testCase "a run with no persisted close has nothing to resume" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                _ <- abandonBoundHarnessRun store project
                swept <-
                    recoverAbandonedHarnessRuns store project neverResolves $ \lease ->
                        withAbandonedHarnessRun store project lease $ \reopened -> do
                            refused <-
                                withProtectedEntry' store $ \session ->
                                    resumeHarnessClose
                                        session
                                        project
                                        (abandonedHarnessCloseRoot reopened)
                                        (abandonedHarnessModeLease reopened)
                                        (abandonedHarnessBoundLease reopened)
                                        9
                            case refused of
                                Left (ModeRecoveryRequired _) -> pure (Right ())
                                other ->
                                    assertFailure
                                        ("expected no close to resume, got " <> show (() <$ other))
                case swept of
                    Left (ModeRecoveryRequired _) -> pure ()
                    other -> assertFailure ("expected required recovery, got " <> show other)
    , -- The sweep observed the lease at an earlier store version, so reopening
      -- rechecks it. A lease another resolver already closed is not a run this
      -- opener may reopen.
      testCase "a lease resolved since the sweep observed it cannot be reopened again" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
                run <- abandonHarnessRun store project
                effectKey <-
                    expectKey
                        ( "effect."
                            <> installedProjectName project
                            <> "."
                            <> run
                            <> ".vm"
                        )
                _ <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord session effectKey ExpectAbsent "created"
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeEffectsRecorded _) -> pure ()
                    other ->
                        assertFailure ("expected a recorded-effect refusal, got " <> show other)
    , testCase "a same-run acquisition row refuses unbound cleanup and remains durable" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                run <- abandonHarnessRun store project
                acquisitionKey <-
                    expectKey
                        ( "acquisition."
                            <> installedProjectName project
                            <> "."
                            <> run
                            <> ".not-an-epoch"
                        )
                written <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord
                            session
                            acquisitionKey
                            ExpectAbsent
                            "malformed-acquisition-payload"
                _ <- either (assertFailure . show) pure written
                before <- protectedStoreImage store
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                case swept of
                    Left (ModeEffectsRecorded recorded) ->
                        recorded @?= recordKeyText acquisitionKey
                    other ->
                        assertFailure
                            ("expected an acquisition-record refusal, got " <> show other)
                after <- protectedStoreImage store
                after @?= before
                persisted <-
                    withProtectedEntry store $ \session ->
                        readProtectedRecord session acquisitionKey
                fmap (fmap protectedRecordBytes) persisted
                    @?= Right (Just "malformed-acquisition-payload")
    , testCase "another run's acquisition row does not block unbound cleanup" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                run <- abandonHarnessRun store project
                otherRunKey <-
                    expectKey
                        ( "acquisition."
                            <> installedProjectName project
                            <> "."
                            <> run
                            <> "-other.17"
                        )
                written <-
                    withProtectedEntry store $ \session ->
                        compareAndSwapProtectedRecord
                            session
                            otherRunKey
                            ExpectAbsent
                            "unrelated-acquisition"
                _ <- either (assertFailure . show) pure written
                swept <- recoverAbandonedHarnessRuns store project neverResolves neverResolves
                proof <- either (assertFailure . show) pure swept
                closedAbandonedHarnessRunsCount proof @?= 1
                persisted <-
                    withProtectedEntry store $ \session ->
                        readProtectedRecord session otherRunKey
                fmap (fmap protectedRecordBytes) persisted
                    @?= Right (Just "unrelated-acquisition")
    , -- The cross-profile half of the four-process reservation race. Production
      -- has no generative run id and no liveness lock, so its unbound lease is
      -- shaped exactly like an abandoned harness run's. The sweep must not read
      -- it as one: closing a live invocation's lease is the same defect the
      -- harness race exposed, across profiles instead of within one, and here it
      -- would also discard the evidence Production's own bound recovery needs.
      testCase "a live production invocation is never swept, and refuses the harness by mode" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
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
            Fixture.withFixtureInstalledProject $ \project -> do
                closed <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            bound <-
                                expectRight
                                    =<< bindRunLease
                                        (productionRootUnboundLease root)
                                        snapshot
                                        pure
                            withProtectedEntry' store $ \session -> do
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
                                            @?= boundRunLeaseRunText bound
                                        pure (Right ())
                                    other ->
                                        assertFailure
                                            ("expected a committed close, got " <> show other)
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
    , testCase "a pre-effect proof cannot authorize settled close, and its short close releases mode last" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                proof <- sweep store project
                outcome <-
                    withHarnessRoot store project ProjectUp (satisfiedPreconditions project) proof $
                        \root -> do
                            let run = harnessRootRunId root
                                unbound = harnessRootUnboundLease root
                            _ <-
                                expectRight
                                    =<< persistPlanSnapshot unbound 1 "spec-1" "plan-1"
                            verifyPlanSnapshot unbound $ \snapshot -> do
                                bound <- expectRight =<< bindRunLease unbound snapshot pure
                                preEffect <-
                                    expectRight
                                        =<< verifyBoundRunHasNoProjectResourcesAcquired bound
                                withProtectedEntry' store $ \session -> do
                                    sessions <-
                                        expectRight =<< verifyAllSessionsClosedHere session
                                    refused <-
                                        authorizeHarnessClose
                                            session
                                            project
                                            (currentHarnessCloseRoot root)
                                            (harnessRootModeLease root)
                                            bound
                                            sessions
                                            preEffect
                                            11
                                    case refused of
                                        Left (ModeClosureMismatch expected observed) -> do
                                            expected @?= "settled destroy"
                                            observed @?= "pre-effect refusal"
                                        other ->
                                            assertFailure
                                                ("expected settled-close evidence refusal, got " <> show other)
                                    expectRight
                                        =<< closeHarnessRun
                                            session
                                            project
                                            (currentHarnessCloseRoot root)
                                            (harnessRootModeLease root)
                                            preEffect
                                    pure (Right (runIdText run))
                firstRun <- expectRight outcome
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
                        (\root -> pure (Right (runIdText (harnessRootRunId root))))
                secondRun <- expectRight again
                assertBool
                    "successive Harness acquisitions have distinct run identities"
                    (firstRun /= secondRun)
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

withRoot ::
    ProtectedStore ->
    ProjectVerb verb ->
    ( forall projectId session brokerGeneration.
      InstalledProjectIdentity projectId ->
      ProtectedSession session ->
      RootInvocationAuthority (Production projectId) brokerGeneration verb ->
      IO (Either AuthorityError ())
    ) ->
    IO ()
withRoot store verb use = do
    outcome <- Fixture.withFixtureInstalledProject $ \project ->
        withProductionRoot store project verb $ \root -> do
            admitted <-
                withAuthorityEntry store $ \session ->
                    use project session (productionRootAuthority root)
            pure (either (Left . ModeAuthorityFailure) Right admitted)
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

canonicalTestSnapshot :: Text -> CanonicalPlanSnapshot
canonicalTestSnapshot configDigest =
    canonicalTestSnapshotFor configDigest testStepPlan

canonicalTestSnapshotFor :: Text -> StepPlan -> CanonicalPlanSnapshot
canonicalTestSnapshotFor configDigest plan =
    withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \codec ->
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

satisfiedPreconditions :: InstalledProjectIdentity projectId -> HarnessPreconditions
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
    InstalledProjectIdentity projectId ->
    AbandonedHarnessRun projectId oldRunId specDigest planDigest planId brokerGeneration ->
    IO (Either ModeError ())
resolveNothingAcquired store project reopened = do
    proved <-
        verifyBoundRunHasNoProjectResourcesAcquired
            (abandonedHarnessBoundLease reopened)
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
abandonHarnessRun :: ProtectedStore -> InstalledProjectIdentity projectId -> IO Text
abandonHarnessRun store project = do
    proof <- sweep store project
    outcome <-
        withHarnessRoot
            store
            project
            ProjectUp
            (satisfiedPreconditions project)
            proof
            (\root -> pure (Right (runIdText (harnessRootRunId root))))
    either (assertFailure . show) pure outcome

-- | Seed one acquisition-shaped row without relying on its payload codec.
writeAcquisitionShapedRecord ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text ->
    Text ->
    ByteString.ByteString ->
    IO RecordKey
writeAcquisitionShapedRecord store project run suffix payload = do
    key <-
        expectKey
            ( "acquisition."
                <> installedProjectName project
                <> "."
                <> run
                <> "."
                <> suffix
            )
    written <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent payload
    _ <- either (assertFailure . show) pure written
    pure key

-- | Exact key/version/payload image used to prove a refused sweep changed
-- neither the offending row nor its mode and lease ownership records.
protectedStoreImage :: ProtectedStore -> IO [(Text, Word64, ByteString.ByteString)]
protectedStoreImage store = do
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
                            [ ( recordKeyText key
                              , recordVersionWord (protectedRecordVersion record)
                              , protectedRecordBytes record
                              )
                            | (key, Just record) <- zip keys present
                            ]
    either (assertFailure . show) pure observed

-- | The empty-sweep proof a fresh store always yields.
sweep ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
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
    InstalledProjectIdentity projectId ->
    IO (Text, Word64)
abandonBoundHarnessRun store project =
    abandonBoundHarnessRunWith store project (\_ -> pure (Right ()))

abandonBoundHarnessRunWith ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    (forall runId. RunId runId -> IO (Either ModeError ())) ->
    IO (Text, Word64)
abandonBoundHarnessRunWith store project afterBinding = do
    proof <- sweep store project
    outcome <-
        withHarnessRoot
            store
            project
            ProjectUp
            (satisfiedPreconditions project)
            proof
            ( \root -> do
                let run = harnessRootRunId root
                    unbound = harnessRootUnboundLease root
                persisted <- persistPlanSnapshot unbound 1 "spec-1" "plan-1"
                case persisted of
                    Left failure -> pure (Left failure)
                    Right () ->
                        verifyPlanSnapshot unbound $ \snapshot -> do
                            bound <-
                                bindRunLease
                                    unbound
                                    snapshot
                                    ( \_ ->
                                        pure
                                            ( runIdText run
                                            , brokerEpochWord
                                                (projectModeLeaseEpoch (harnessRootModeLease root))
                                            )
                                    )
                            result <- expectRight bound
                            continued <- afterBinding run
                            pure (fmap (const result) continued)
            )
    either (assertFailure . show) pure outcome

-- Helpers ---------------------------------------------------------------------------------------

{- | Persist a run's plan snapshot and hand back the verified value, which is
the only thing 'bindRunLease' accepts.
-}
-- ---------------------------------------------------------------------------
-- Plan migration

{- | The revision-carry algebra: the profile, the candidate, the freeze, the
activation compare-and-swap, and the configless post-CAS recovery.

The cases are ordered the way the protocol is, and each one names the state a
crash at that point would leave — because the whole reason the protocol has this
many durable steps is that every gap between two of them has to be recoverable.
-}
migrationCases :: [TestTree]
migrationCases =
    [ testCase "the migration profile refuses a recovery-owed binding" $
        withStore $ \store ->
            Fixture.withFixtureInstalledProject $ \project -> do
                outcome <-
                    withProductionRoot store project ProjectUp $ \root ->
                        withBoundSnapshot root $ \snapshot -> do
                            let unbound = productionRootUnboundLease root
                            -- Bind once so the second binding is the
                            -- abandoned-invocation case.
                            _ <- expectRight =<< bindRunLease unbound snapshot (\_ -> pure ())
                            second <- bindRunLease unbound snapshot (\_ -> pure ())
                            case second of
                                -- An already-bound lease yields no
                                -- NormalActiveRecovery at all, so a migration
                                -- cannot even be proposed from it.
                                Left _ -> pure (Right ())
                                Right () ->
                                    assertFailure "the second binding must not be fresh"
                outcome @?= Right ()
    , testCase "a migration onto the same plan digest is refused" $
        withMigrationProfile $ \project _ _bound profile session -> do
            outcome <-
                withProspectiveMigrationPlan
                    session
                    project
                    profile
                    "spec-1"
                    "plan-1"
                    (\_ -> pure (Right ()))
            case outcome of
                Left (ModeSnapshotMismatch expected observed) -> do
                    expected @?= "plan-1"
                    observed @?= "plan-1"
                    pure (Right ())
                other -> assertFailure ("expected a same-digest refusal, got " <> show other)
    , testCase "a candidate is persisted, read back, and authorizes nothing" $
        withMigrationProfile $ \project _ _bound profile session ->
            withProspectiveMigrationPlan session project profile "spec-2" "plan-2" $ \candidate -> do
                prospectiveSnapshotSpecDigest candidate @?= "spec-2"
                prospectiveSnapshotPlanDigest candidate @?= "plan-2"
                -- The stable key names the run and both revisions, so a retry
                -- converges on it rather than proposing a second migration.
                stableMigrationKeyText (prospectiveSnapshotKey candidate)
                    @?= "production.plan-1.plan-2"
                pure (Right ())
    , testCase "freezing stops the old revision from being bindable" $
        withMigrationProfile $ \project _ bound profile session ->
            withProspectiveMigrationPlan session project profile "spec-2" "plan-2" $ \candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                stableMigrationKeyText (frozenMigrationKey frozen) @?= "production.plan-1.plan-2"
                -- The recorded kind says the barrier was not crossed.
                kind <- readRecordedRevisionKind session project bound
                kind @?= IncompleteMigration "production.plan-1.plan-2"
                pure (Right ())
    , testCase "the activation compare-and-swap switches the lineage and records it" $
        withMigrationProfile $ \project epoch _oldBound profile session ->
            withProspectiveMigrationPlan session project profile "spec-2" "plan-2" $ \candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, barrier) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                boundRunLeasePlanDigest bound @?= "plan-2"
                migrationBarrierOldPlanDigest barrier @?= "plan-1"
                migrationBarrierNewPlanDigest barrier @?= "plan-2"
                kind <- readRecordedRevisionKind session project bound
                kind @?= CompletedMigration "production.plan-1.plan-2"
                pure (Right ())
    , testCase "activation is idempotent, so a crash after the swap converges" $
        withMigrationProfile $ \project epoch _bound profile session ->
            withProspectiveMigrationPlan session project profile "spec-2" "plan-2" $ \candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (_, first) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                -- Re-running against the same frozen capability observes the
                -- already-bound candidate and completes rather than refusing.
                (_, second) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                migrationBarrierNewPlanDigest first @?= migrationBarrierNewPlanDigest second
                pure (Right ())
    , testCase "activating the plan admits the new revision's broker" $
        withMigrationProfile $ \project epoch _oldBound profile session ->
            withProspectiveMigrationPlan session project profile "spec-2" "plan-2" $ \candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, barrier) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                admission <- expectRight =<< activateMigratedPlan session barrier bound epoch
                admissionPlanDigest admission @?= "plan-2"
                pure (Right ())
    , testCase "completed-migration recovery loads the candidate from the durable key" $
        withMigrationProfile $ \project epoch _oldBound profile session ->
            withProspectiveMigrationPlan session project profile "spec-2" "plan-2" $ \candidate -> do
                frozen <- expectRight =<< withPlanMigration session project profile candidate
                (bound, _) <-
                    expectRight =<< commitMigrationActivation session project frozen epoch
                recovered <-
                    withCompletedMigrationRecovery session project bound $ \barrier -> do
                        -- Both digests came from the stable key and the lease
                        -- record; no config was consulted.
                        migrationBarrierOldPlanDigest barrier @?= "plan-1"
                        migrationBarrierNewPlanDigest barrier @?= "plan-2"
                        fmap (fmap (const ())) (activateMigratedPlan session barrier bound epoch)
                recovered @?= Right ()
                pure (Right ())
    , testCase "a run with no completed migration has nothing to recover" $
        withMigrationProfile $ \project _ bound _profile session -> do
            outcome <-
                withCompletedMigrationRecovery
                    session
                    project
                    bound
                    (\_ -> pure (Right ()))
            case outcome of
                Left (ModeWrongRecoveryScope expected observed) -> do
                    expected @?= "completed-migration"
                    observed @?= "normal revision"
                    pure (Right ())
                other -> assertFailure ("expected a wrong-scope refusal, got " <> show other)
    ]

withMigrationProfile ::
    ( forall projectId brokerGeneration oldSpecDigest oldPlanDigest session.
      InstalledProjectIdentity projectId ->
      BrokerEpoch brokerGeneration ->
      BoundRunLease
        (Production projectId)
        oldSpecDigest
        oldPlanDigest
        brokerGeneration ->
      ProjectUpMigrationProfile
        projectId
        oldSpecDigest
        oldPlanDigest
        brokerGeneration ->
      ProtectedSession session ->
      IO (Either ModeError ())
    ) ->
    IO ()
withMigrationProfile use =
    withStore $ \store ->
        Fixture.withFixtureInstalledProject $ \project -> do
            outcome <-
                withProductionRoot store project ProjectUp $ \root ->
                    withBoundSnapshot root $ \snapshot -> do
                        bound <-
                            expectRight
                                =<< bindRunLease
                                    (productionRootUnboundLease root)
                                    snapshot
                                    pure
                        case
                            withProjectUpMigrationProfile
                                (productionRootAuthority root)
                                (productionRootModeLease root)
                                bound
                                snapshot
                            of
                            Left failure -> pure (Left failure)
                            Right profile ->
                                withProtectedEntry' store $ \session ->
                                    use
                                        project
                                        (rootAuthorityEpoch (productionRootAuthority root))
                                        bound
                                        profile
                                        session
            outcome @?= Right ()

-- | The recorded migration side of the barrier, read back off the durable record.
readRecordedRevisionKind ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BoundRunLease
      (Production projectId)
      specDigest
      planDigest
      brokerGeneration ->
    IO OpenRevisionKind
readRecordedRevisionKind session project bound = do
    observed <- readRecordedOpenRevisionKind session project bound
    expectRight observed

withBoundSnapshot ::
    ProductionRoot projectId brokerGeneration verb ->
    ( forall specDigest planDigest.
      VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withBoundSnapshot root use = do
    let unbound = productionRootUnboundLease root
    persisted <- persistPlanSnapshot unbound 1 "spec-1" "plan-1"
    case persisted of
        Left failure -> pure (Left failure)
        Right () -> verifyPlanSnapshot unbound use

withFreshHarnessRoot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ( forall runId brokerGeneration.
      HarnessRoot projectId runId brokerGeneration VerbUp ->
      IO (Either ModeError result)
    ) ->
    IO (Either ModeError result)
withFreshHarnessRoot store project use = do
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
                use

readModeRecord ::
    ProtectedStore ->
    RecordKey ->
    IO (Either ModeError (Maybe ProtectedRecord))
readModeRecord store key =
    withProtectedEntry' store $ \session -> do
        observed <- readProtectedRecord session key
        pure (either (Left . ModeStoreFailure) Right observed)

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

authorityFacadeExports :: Text -> Either Text [Text]
authorityFacadeExports source = do
    afterMarker <-
        maybe
            (Left "the Authority module header is absent")
            (Right . Text.drop (Text.length marker))
            (nonEmptySuffix marker source)
    let (body, closing) = Text.breakOn "\n) where" afterMarker
    if Text.null closing
        then Left "the Authority export list terminator is absent"
        else
            Right
                [ Text.dropWhileEnd (== ',') (Text.strip line)
                | line <- Text.lines body
                , not (Text.null (Text.strip line))
                ]
  where
    marker = "module HostBootstrap.Authority ("
    nonEmptySuffix needle haystack =
        let suffix = snd (Text.breakOn needle haystack)
         in if Text.null suffix then Nothing else Just suffix

haskellSources :: FilePath -> IO [FilePath]
haskellSources directory = do
    entries <- listDirectory directory
    let paths = map (directory </>) entries
    directories <- filterM doesDirectoryExist paths
    files <- filterM doesFileExist paths
    nested <- concat <$> mapM haskellSources directories
    pure ([path | path <- files, takeExtension path == ".hs"] <> nested)

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
