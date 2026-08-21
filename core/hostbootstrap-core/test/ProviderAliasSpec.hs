{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ProviderAliasSpec (tests, aliasGuest, localGuestAliasSupported) where

import Data.Char (isAlphaNum)
import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import qualified FakeProvider
import FakeProvider (
    ProviderBehaviour (ProviderAnswers, ProviderDaemonUnavailable, ProviderEgressUnavailable),
 )
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Incus), mkAbsExe)
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift (localContext)
import HostBootstrap.Lima (LimaVM (..))
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import HostBootstrap.Substrate.Provider
import HostBootstrap.Substrate.Provider.Alias
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile
import HostBootstrap.Wsl2 (Wsl2VM (..))
import PlatformPath (hostFixturePath)
import PrepareFixture (gateFor)
import System.Directory (
    createDirectory,
    createDirectoryIfMissing,
    createFileLink,
    doesPathExist,
    listDirectory,
    pathIsSymbolicLink,
    removeFile,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
#ifndef mingw32_HOST_OS
import Control.Exception (IOException, displayException, try)
import System.Process (readProcessWithExitCode)
#endif

type GuestRunner = [String] -> IO RawProviderOutcome

tests :: TestTree
tests =
    testGroup
        "ProviderAliasSpec"
        ( portableCases
            ++ [testGroup "the local guest alias driver" guestAliasDriverCases]
        )

portableCases :: [TestTree]
portableCases =
    [ testCase "guest alias specs require distinct canonical absolute POSIX paths" $ do
        assertBool "relative alias rejected" (isLeft (mkGuestAliasSpec "tmp/alias" "/srv/data"))
        assertBool "relative target rejected" (isLeft (mkGuestAliasSpec "/tmp/alias" "srv/data"))
        assertBool "Windows path rejected" (isLeft (mkGuestAliasSpec "C:\\alias" "/srv/data"))
        assertBool "root alias rejected" (isLeft (mkGuestAliasSpec "/" "/srv/data"))
        assertBool "trailing slash rejected" (isLeft (mkGuestAliasSpec "/srv/alias/" "/srv/data"))
        assertBool "dot segment rejected" (isLeft (mkGuestAliasSpec "/srv/./alias" "/srv/data"))
        assertBool "dot-dot segment rejected" (isLeft (mkGuestAliasSpec "/srv/x/../alias" "/srv/data"))
        assertBool "empty segment rejected" (isLeft (mkGuestAliasSpec "/srv//alias" "/srv/data"))
        assertBool "same path rejected" (isLeft (mkGuestAliasSpec "/srv/data" "/srv/data"))
    , testCase "a discovered lockf cannot authorize the flock ownership protocol" $ do
        (outcome, invoked) <-
            withAliasFixture
                (aliasPlan "fallback")
                portableAliasSpec
                ProviderAnswers
                GuestFallback
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected lockf-only Unsupported, got " ++ show other)
        assertBool "lockf remains a descriptive discovery fallback" (["which", "lockf"] `elem` invoked)
        assertBool "no alias command ran under lockf" (not (any isAliasInvocation invoked))
    , testCase "raw discovery retains the exact flock, BSD stat, and Python executables" $ do
        (outcome, invoked) <-
            withAliasFixture
                (aliasPlan "bsd-tools")
                portableAliasSpec
                ProviderAnswers
                GuestBsd
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    pure (Right (aliasCallResultView result)))
        outcome @?= Right (AliasResultCreated 23)
        assertBool "GNU stat unavailability falls through to BSD" (["/opt/hb/stat", "-f", "%d:%i", "/"] `elem` invoked)
        case filter isAliasInvocation invoked of
            [argv] -> assertExactRetainedTools argv
            other -> assertFailure ("expected one alias invocation, got " ++ show other)
    , testCase "a transport failure is terminal and never falls through" $ do
        (outcome, invoked) <-
            withAliasFixture
                (aliasPlan "transport-failure")
                portableAliasSpec
                ProviderAnswers
                GuestTransportFailure
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected terminal discovery Failure, got " ++ show other)
        assertBool "lockf was not tried after a transport failure" (["which", "lockf"] `notElem` invoked)
    , testCase "Python discovery requires one exact marker" $ do
        (outcome, _) <-
            withAliasFixture
                (aliasPlan "bad-python-marker")
                portableAliasSpec
                ProviderAnswers
                GuestBadPythonMarker
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected malformed Python marker Failure, got " ++ show other)
    , testCase "tool discovery rejects extra lines and successful stderr" $ do
        forDiscoveryFailure "extra discovery line" GuestExtraDiscoveryLine
        forDiscoveryFailure "successful discovery stderr" GuestDiscoveryStderr
        forDiscoveryFailure "oversized discovery line" GuestOversizedDiscoveryLine
    , testCase "guest tools are not probed until the managed VM is freshly ready" $ do
        (outcome, invoked) <-
            withAliasFixture
                (aliasPlan "vm-not-ready-order")
                portableAliasSpec
                ProviderAnswers
                GuestVmNotReady
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected retained NotReady to refuse Alias admission, got " ++ show other)
        assertBool "the VM probe was attempted" (["true"] `elem` invoked)
        assertBool "no guest tool probe ran before readiness" (not (any isGuestToolProbe invoked))
    , testCase "an outer provider conflict remains Conflict through discovery" $ do
        (outcome, invoked) <-
            withAliasFixture
                (aliasPlan "provider-conflict-discovery")
                portableAliasSpec
                ProviderAnswers
                GuestConflictOnDiscovery
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Conflict _) -> pure ()
            other -> assertFailure ("expected structured provider Conflict, got " ++ show other)
        assertBool "lockf fallback did not erase Conflict" (["which", "lockf"] `notElem` invoked)
    , testCase "an outer provider conflict remains an indexed alias Conflict" $ do
        (outcome, _) <-
            withAliasFixture
                (aliasPlan "provider-conflict-alias")
                portableAliasSpec
                ProviderAnswers
                GuestConflictOnAlias
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    pure (Right (aliasCallResultView result)))
        case outcome of
            Right (AliasResultConflict _) -> pure ()
            other -> assertFailure ("expected AliasResultConflict, got " ++ show other)
    , testCase "alias result parsing rejects a second verdict and successful stderr" $ do
        forAliasResultFailure "second alias verdict" GuestSecondAliasVerdict
        forAliasResultFailure "alias successful stderr" GuestAliasStderr
        forAliasResultFailure "oversized alias verdict" GuestOversizedAliasVerdict
    , testCase "release result parsing rejects a second verdict and successful stderr" $ do
        forReleaseFailure "second release verdict" GuestSecondReleaseVerdict
        forReleaseFailure "release successful stderr" GuestReleaseStderr
        forReleaseFailure "oversized release verdict" GuestOversizedReleaseVerdict
    , testCase "an outer provider conflict remains Conflict through release" $ do
        outcome <- releaseOutcome "provider-conflict-release" GuestConflictOnRelease
        case outcome of
            Left (Conflict _) -> pure ()
            other -> assertFailure ("expected release Conflict, got " ++ show other)
    , testCase "provisioning egress Unavailable is descriptive for an already-running alias" $ do
        (outcome, _) <-
            withAliasFixture
                (aliasPlan "egress-unavailable")
                portableAliasSpec
                ProviderEgressUnavailable
                GuestSupported
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    pure (Right (aliasCallResultView result)))
        outcome @?= Right (AliasResultCreated 23)
    , testCase "a retained daemon failure cannot mint a Strong alias backend" $ do
        (outcome, _) <-
            withAliasFixture
                (aliasPlan "daemon-failure")
                portableAliasSpec
                ProviderDaemonUnavailable
                GuestSupported
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected prerequisite Failure, got " ++ show other)
    , testCase "the alias owner changes with the exact plan digest" $ do
        first <- capturedOwner (aliasPlan "owner-a")
        second <- capturedOwner (aliasPlan "owner-b")
        assertBool "each owner was captured" (not (null first) && not (null second))
        assertBool "different plans cannot share an alias origin" (first /= second)
    , testCase "settlement accepts only the indexed result returned for its call" $
        (fst <$> withAliasFixture
            (aliasPlan "settlement")
            portableAliasSpec
            ProviderAnswers
            GuestSupported
            (\_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                pure $ do
                    settled <- settlePreparedGuestAliasCall Nothing call result
                    pure $
                        withGuestAliasCallSettlement
                            settled
                            (\_ change -> change)
                            (\_ _ _ _ -> error "created backend result must settle managed")))
            >>= (@?= Right (Changed Created))
    , testCase "a stale conditional release version refuses before guest execution" $ do
        (outcome, invoked) <-
            withAliasFixture
                (aliasPlan "stale-release-fence")
                portableAliasSpec
                ProviderAnswers
                GuestSupported
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    case settlePreparedGuestAliasCall Nothing call result of
                        Left failure -> pure (Left failure)
                        Right settled ->
                            withGuestAliasCallSettlement
                                settled
                                ( \managed _ -> do
                                    let stale = managedGuestAliasObservationVersion managed + 1
                                    case withPreparedGuestAliasRelease managed stale (runPreparedGuestAliasRelease backend) of
                                        Left (Conflict _) -> pure (Right ())
                                        Left failure -> pure (Left failure)
                                        Right _ -> pure (Left (Failure (FailureDetail "stale release test" "a stale version prepared" DoNotRetry)))
                                )
                                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "stale release test" "unexpected foreign alias" DoNotRetry))))
                )
        outcome @?= Right ()
        assertBool "no release reached the guest" (not (any isReleaseInvocation invoked))
    ]

{- | The alias driver run for real, against a real filesystem.

Every case here drives this project's own guest alias driver rather than a
description of it, which is a POSIX contract: the driver opens with
@O_NOFOLLOW@, holds a @flock(2)@ across an @exec@, publishes by a no-replace
hard link, and binds a symlink's exact @device:inode@.

The family is the same size on every gate host. Where the contract cannot be
held, each case records the refusal the driver's own guest makes instead of
disappearing, so a case that vanished is a failed count rather than a smaller
total (§ JJ); 'CoverageManifest' declares that size and reports which of the two
this host did.
-}
guestAliasDriverCases :: [TestTree]
guestAliasDriverCases =
    [ localGuestCase "the locked guest protocol creates, releases, and confirms already released" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            (outcome, _) <-
                withAliasFixture
                    (aliasPlan "real-create-release")
                    spec
                    ProviderAnswers
                    GuestLocal
                    createAndRelease
            outcome @?= Right ()
            doesPathExist alias >>= assertBool "released alias is absent" . not
    , localGuestCase "conditional release refuses a foreign replacement" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                foreignTarget = directory </> "foreign"
                alias = directory </> "alias"
            createDirectory target
            createDirectory foreignTarget
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            (outcome, _) <-
                withAliasFixture
                    (aliasPlan "real-release-conflict")
                    spec
                    ProviderAnswers
                    GuestLocal
                    (createTamperAndRelease alias foreignTarget)
            case outcome of
                Left (Conflict _) -> do
                    pathIsSymbolicLink alias >>= assertBool "foreign replacement remains"
                other -> assertFailure ("expected release Conflict, got " ++ show other)
    , localGuestCase "an existing managed record reports AlreadyExact, never fabricates creation" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            (outcome, _) <-
                withAliasFixture
                    (aliasPlan "real-retry")
                    spec
                    ProviderAnswers
                    GuestLocal
                    (\_ backend _ call -> do
                        first <- runPreparedGuestAliasCall backend call
                        case settlePreparedGuestAliasCall Nothing call first of
                            Left failure -> pure (Left failure)
                            Right _ -> do
                                second <- runPreparedGuestAliasCall backend call
                                pure (Right (aliasCallResultView second)))
            outcome @?= Right (AliasResultAlreadyExact 23)
    , localGuestCase "a crash after origin publication resumes the same alias generation" $
        acquireCrashResumeCase
            "after-origin"
            "pass  # HB_ALIAS_AFTER_ORIGIN"
            "os._exit(97)  # HB_ALIAS_AFTER_ORIGIN"
    , localGuestCase "a partial prepared origin stage is completed before publication" $
        acquireCrashResumeCase
            "partial-origin-stage"
            "create_full(stage, payload, 'prepared-stage')"
            "fd = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, payload[:17]); os.fsync(fd); os.close(fd); os._exit(97)"
    , localGuestCase "a crash after alias publication binds the published inode on retry" $
        acquireCrashResumeCase
            "after-publish"
            "pass  # HB_ALIAS_AFTER_PUBLISH"
            "os._exit(97)  # HB_ALIAS_AFTER_PUBLISH"
    , localGuestCase "a partial managed transition record is completed on acquisition retry" $
        acquireCrashResumeCase
            "partial-managed-transition"
            "create_full(temporary, payload, state_value + '-temp')"
            "fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, payload[:17]); os.fsync(fd); os.close(fd); os._exit(97)"
    , localGuestCase "a crash after foreign-stage cleanup resumes the origin unwind" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                foreignTarget = directory </> "foreign"
                alias = directory </> "alias"
            createDirectory target
            createDirectory foreignTarget
            createFileLink foreignTarget alias
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            (outcome, _) <-
                withAliasFixture
                    (aliasPlan "foreign-unwind")
                    spec
                    ProviderAnswers
                    ( GuestLocalCrashingOnce
                        "reconcile"
                        "pass  # HB_ALIAS_AFTER_FOREIGN_CLEANUP"
                        "os._exit(97)  # HB_ALIAS_AFTER_FOREIGN_CLEANUP"
                    )
                    crashAndRetryAlias
            case outcome of
                Right (AliasResultForeign _ _) -> pure ()
                other -> assertFailure ("expected resumed foreign observation, got " ++ show other)
            pathIsSymbolicLink alias >>= assertBool "foreign alias remains untouched"
            entries <- stateEntries target
            entries @?= []
            assertNoAliasStage directory
    , localGuestCase "an external unlink before release intent is a retained Conflict" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            (outcome, _) <-
                withAliasFixture
                    (aliasPlan "release-unlinked-before-intent")
                    spec
                    ProviderAnswers
                    GuestLocal
                    (createUnlinkAndRelease alias)
            case outcome of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected release Conflict, got " ++ show other)
            entries <- stateEntries target
            assertBool "managed origin survives the refused release" (not (null entries))
    , localGuestCase "release refuses a different-nonce alias staging residue without mutation" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
                residue = alias ++ ".hb-alias-stage-" ++ replicate 64 'a'
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            (outcome, _) <-
                withAliasFixture
                    (aliasPlan "release-stage-residue")
                    spec
                    ProviderAnswers
                    GuestLocal
                    (createResidueAndRelease residue target)
            case outcome of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected staging-residue Conflict, got " ++ show other)
            pathIsSymbolicLink alias >>= assertBool "managed alias survives the refused release"
            pathIsSymbolicLink residue >>= assertBool "foreign staging residue remains untouched"
            entries <- stateEntries target
            assertBool "managed origin survives the refused release" (not (null entries))
    , localGuestCase "a crash after release intent resumes the exact release fence" $
        releaseCrashResumeCase
            "after-release-intent"
            "pass  # HB_ALIAS_AFTER_RELEASE_INTENT"
            "os._exit(97)  # HB_ALIAS_AFTER_RELEASE_INTENT"
    , localGuestCase "a partial releasing transition record is completed on release retry" $
        releaseCrashResumeCase
            "partial-releasing-transition"
            "create_full(temporary, payload, state_value + '-temp')"
            "fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, payload[:17]); os.fsync(fd); os.close(fd); os._exit(97)"
    , localGuestCase "a crash after unlink finishes record deletion without re-unlinking" $
        releaseCrashResumeCase
            "after-release-unlink"
            "pass  # HB_ALIAS_AFTER_RELEASE_UNLINK"
            "os._exit(97)  # HB_ALIAS_AFTER_RELEASE_UNLINK"
    ]

{- | One case of the family above, with its /expectation/ conditional.

§ JJ's fifth rule is that a case whose subject is unavailable on this gate host
asserts the refusal its subject declares rather than being compiled away. The
body below therefore runs where the driver's primitives exist and the declared
refusal is recorded where they do not, and the case is counted either way.
-}
localGuestCase :: TestName -> IO () -> TestTree
localGuestCase name body =
    testCase name $
        if localGuestAliasSupported
            then body
            else expectLocalGuestRefusal

{- | The disposition a host without the driver's primitives owes every caller.

One fixture, driven through the same production route the family's other cases
take, so what is recorded here is the driver refusing rather than a suite
deciding not to ask. The crossing really happens — the argument vector reaches a
real provider client process — and it is the guest on the far side that has
nothing to answer with.
-}
expectLocalGuestRefusal :: IO ()
expectLocalGuestRefusal = do
    (outcome, invoked) <-
        withAliasFixture
            (aliasPlan "unsupported-local-guest")
            portableAliasSpec
            ProviderAnswers
            GuestLocal
            (\_ _ _ _ -> pure (Right ()))
    assertBool
        "the driver really asked this guest for its lock front end"
        (["which", "flock"] `elem` invoked && ["which", "lockf"] `elem` invoked)
    case outcome of
        Left (Unsupported _) -> pure ()
        other ->
            assertFailure
                ("expected this gate host's guest to offer the driver no lock front end, got " ++ show other)

createAndRelease ::
    ProviderCapability scope planId providerId backendId capabilityId ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
createAndRelease _ backend _ call = do
    result <- runPreparedGuestAliasCall backend call
    case settlePreparedGuestAliasCall Nothing call result of
        Left failure -> pure (Left failure)
        Right settled ->
            withGuestAliasCallSettlement
                settled
                ( \managed _ -> do
                    released <- runRelease backend managed
                    case released of
                        Left failure -> pure (Left failure)
                        Right () -> runRelease backend managed
                )
                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "test alias release" "unexpected foreign alias" DoNotRetry))))

createTamperAndRelease ::
    FilePath ->
    FilePath ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
createTamperAndRelease alias foreignTarget _ backend _ call = do
    result <- runPreparedGuestAliasCall backend call
    case settlePreparedGuestAliasCall Nothing call result of
        Left failure -> pure (Left failure)
        Right settled ->
            withGuestAliasCallSettlement
                settled
                ( \managed _ -> do
                    removeFile alias
                    createFileLink foreignTarget alias
                    runRelease backend managed
                )
                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "test alias release" "unexpected foreign alias" DoNotRetry))))

createUnlinkAndRelease ::
    FilePath ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
createUnlinkAndRelease alias _ backend _ call = do
    result <- runPreparedGuestAliasCall backend call
    case settlePreparedGuestAliasCall Nothing call result of
        Left failure -> pure (Left failure)
        Right settled ->
            withGuestAliasCallSettlement
                settled
                ( \managed _ -> do
                    removeFile alias
                    runRelease backend managed
                )
                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "test alias release" "unexpected foreign alias" DoNotRetry))))

createResidueAndRelease ::
    FilePath ->
    FilePath ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
createResidueAndRelease residue target _ backend _ call = do
    result <- runPreparedGuestAliasCall backend call
    case settlePreparedGuestAliasCall Nothing call result of
        Left failure -> pure (Left failure)
        Right settled ->
            withGuestAliasCallSettlement
                settled
                ( \managed _ -> do
                    createFileLink target residue
                    runRelease backend managed
                )
                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "test alias release" "unexpected foreign alias" DoNotRetry))))

crashAndRetryAlias ::
    ProviderCapability scope planId providerId backendId capabilityId ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError AliasCallResultView)
crashAndRetryAlias _ backend _ call = do
    first <- runPreparedGuestAliasCall backend call
    case aliasCallResultView first of
        AliasResultFailed _ -> do
            resumed <- runPreparedGuestAliasCall backend call
            pure (Right (aliasCallResultView resumed))
        observed ->
            pure
                ( Left
                    ( Failure
                        (FailureDetail "alias crash fixture" (Text.pack ("checkpoint did not fail: " ++ show observed)) DoNotRetry)
                    )
                )

acquireCrashResumeCase :: String -> String -> String -> IO ()
acquireCrashResumeCase salt needle replacement =
    withSystemTempDirectory "hb-alias" $ \directory -> do
        let target = directory </> "share"
            alias = directory </> "alias"
        createDirectory target
        spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
        (outcome, _) <-
            withAliasFixture
                (aliasPlan salt)
                spec
                ProviderAnswers
                (GuestLocalCrashingOnce "reconcile" needle replacement)
                crashAndRetryAlias
        outcome @?= Right (AliasResultRepaired 23)
        pathIsSymbolicLink alias >>= assertBool "the resumed alias is the managed symlink"
        entries <- stateEntries target
        length entries @?= 1
        assertNoAliasStage directory

releaseCrashResumeCase :: String -> String -> String -> IO ()
releaseCrashResumeCase salt needle replacement =
    withSystemTempDirectory "hb-alias" $ \directory -> do
        let target = directory </> "share"
            alias = directory </> "alias"
        createDirectory target
        spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
        (outcome, _) <-
            withAliasFixture
                (aliasPlan salt)
                spec
                ProviderAnswers
                (GuestLocalCrashingOnce "release" needle replacement)
                ( \_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    case settlePreparedGuestAliasCall Nothing call result of
                        Left failure -> pure (Left failure)
                        Right settled ->
                            withGuestAliasCallSettlement
                                settled
                                ( \managed _ -> do
                                    interrupted <- runRelease backend managed
                                    case interrupted of
                                        Left (Failure _) -> runRelease backend managed
                                        Left failure -> pure (Left failure)
                                        Right () ->
                                            pure
                                                ( Left
                                                    ( Failure
                                                        (FailureDetail "alias release crash fixture" "checkpoint did not interrupt release" DoNotRetry)
                                                    )
                                                )
                                )
                                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "alias release crash fixture" "unexpected foreign alias" DoNotRetry))))
                )
        outcome @?= Right ()
        doesPathExist alias >>= assertBool "the resumed release leaves the alias absent" . not
        entries <- stateEntries target
        entries @?= []
        assertNoAliasStage directory

replaceFirst :: String -> String -> String -> String
replaceFirst needle replacement = go
  where
    go remaining
        | needle `isPrefixOf` remaining = replacement ++ drop (length needle) remaining
    go [] = []
    go (character : rest) = character : go rest

stateEntries :: FilePath -> IO [FilePath]
stateEntries target = do
    let stateDirectory = target </> ".hostbootstrap-alias-origin-v1"
    exists <- doesPathExist stateDirectory
    if exists then listDirectory stateDirectory else pure []

assertNoAliasStage :: FilePath -> IO ()
assertNoAliasStage directory = do
    entries <- listDirectory directory
    assertBool "no alias staging link remains" (not (any (".hb-alias-stage-" `isInfixOf`) entries))

runRelease ::
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    IO (Either ReconcileError ())
runRelease backend managed =
    case
        withPreparedGuestAliasRelease
            managed
            (managedGuestAliasObservationVersion managed)
            (runPreparedGuestAliasRelease backend)
    of
        Left failure -> pure (Left failure)
        Right action -> action

capturedOwner :: StepPlan -> IO String
capturedOwner plan = do
    (outcome, invoked) <-
        withAliasFixture
            plan
            portableAliasSpec
            ProviderAnswers
            GuestSupported
            (\_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                pure (Right (aliasCallResultView result)))
    case outcome of
        Left failure -> assertFailure (show failure)
        Right _ -> pure ()
    case [owner | argv <- invoked, isAliasInvocation argv, Just owner <- [ownerFromArgv argv]] of
        [owner] -> pure owner
        observed -> assertFailure ("expected one owner, got " ++ show observed)

withAliasFixture ::
    StepPlan ->
    GuestAliasSpec ->
    ProviderBehaviour ->
    GuestStrategy ->
    ( forall projectId planId backendId providerId capabilityId aliasId shareId operationKey callDigest attempt journalVersion.
      ProviderCapability (Production projectId) planId providerId backendId capabilityId ->
      StrongAliasBackend (Production projectId) planId providerId backendId capabilityId ->
      ManagedProviderHandle (Production projectId) planId backendId providerId Running ->
      PreparedGuestAliasCall
        (Production projectId)
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary, [[String]])
withAliasFixture plan aliasSpec host strategy consume =
    withSystemTempDirectory "hb-alias-tools" $ \toolRoot -> do
        self <- getExecutablePath
        let providerState = toolRoot </> "provider-state"
        createDirectoryIfMissing True providerState
        _ <- FakeProvider.newProviderFixture toolRoot (aliasRole strategy) host
        let config =
                HostConfig
                    { hcSubstrate = Substrate LinuxCpu Amd64
                    , hcToolPaths = Map.fromList [(Incus, fixtureExe self)]
                    }
        outcome <-
            FakeProvider.withFakeProviderClient toolRoot $
                case mkIncusBackendSpec "test-vm" "images:ubuntu/24.04" "test-" config providerState 4 "8GiB" "40GiB" of
                    Left failure -> pure (Left failure)
                    Right spec -> do
                        discovered <-
                            discoverStrongProviderBackend config spec $ \backend ->
                                Fixture.withFixtureProjectPlan plan $ \projectPlan ->
                                    prepareProject config backend projectPlan
                        pure (joinReconcile discovered)
        invoked <- FakeProvider.recordedGuestInvocations toolRoot
        pure (outcome, invoked)
  where
    prepareProject config backend projectPlan =
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode, shareNode] -> do
                carrier <- Execution.newResourceCarrier
                providerRuntime <- Execution.newStepRuntime carrier
                shareRuntime <- Execution.newStepRuntime carrier
                let providerExecution = stepExecutionFor projectPlan config providerRuntime providerNode
                    shareExecution = stepExecutionFor projectPlan config shareRuntime shareNode
                    providerKey = Execution.stepExecutionOperationKey providerExecution
                    shareKey = Execution.stepExecutionOperationKey shareExecution
                    binding = providerBackendBinding backend
                providerGate <- executionGate providerExecution
                readyGate <- executionGate providerExecution
                shareGate <- executionGate shareExecution
                aliasGate <- gateFor (Execution.stepExecutionPlanDigest shareExecution) aliasOperation
                joinIO $
                    withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
                        joinIO $
                            withNodeObservedResource providerExecution plannedProvider 17 7 $ \observedProvider ->
                                joinIO $
                                    withPreparedProviderProvision
                                        providerExecution
                                        binding
                                        plannedProvider
                                        observedProvider
                                        providerGate
                                        ( provisionProvider
                                            backend
                                            projectPlan
                                            providerExecution
                                            shareExecution
                                            plannedProvider
                                            shareKey
                                            readyGate
                                            shareGate
                                            aliasGate
                                        )
            nodes -> pure (Left (Failure (FailureDetail "alias fixture" (Text.pack ("expected two nodes, got " ++ show (length nodes))) DoNotRetry)))

    provisionProvider backend projectPlan providerExecution shareExecution plannedProvider shareKey readyGate shareGate aliasGate preparedProvision = do
        rawResult <- runProviderProvisionCall backend preparedProvision
        case settleProviderProvision Nothing preparedProvision rawResult of
            Left failure -> pure (Left failure)
            Right settled ->
                withProviderProvisionSettlement
                    settled
                    ( \provisioned _ -> do
                        let preparedReady =
                                withPreparedProviderReady
                                    providerExecution
                                    plannedProvider
                                    provisioned
                                    (providerStartableAfterProvision provisioned)
                                    readyGate
                                    (\call -> do
                                        result <- runProviderReadyCall backend call
                                        pure (settleProviderReady call result))
                        booted <- joinIO preparedReady
                        case booted of
                            Left failure -> pure (Left failure)
                            Right advance ->
                                withProviderPhaseAdvance advance $ \running ->
                                    openBound backend projectPlan shareExecution plannedProvider shareKey shareGate aliasGate running
                    )
                    (\_ _ _ _ -> pure (Left (Failure (FailureDetail "alias fixture" "unexpected foreign provider" DoNotRetry))))

    openBound backend projectPlan shareExecution plannedProvider shareKey shareGate aliasGate running =
        case withProviderBoundExec backend running $ \bound ->
            discoverProvider running testProvider bound $ \capability ->
                case discoverStrongAliasBackend capability of
                    Left failure -> pure (Left failure)
                    Right aliasBackend ->
                        prepareShare backend projectPlan shareExecution plannedProvider shareKey shareGate aliasGate capability aliasBackend running of
            Left failure -> pure (Left failure)
            Right discoverAction -> do
                discovered <- discoverAction
                pure $ case discovered of
                    Left providerFailure -> Left (providerError providerFailure)
                    Right result -> result

    prepareShare backend projectPlan shareExecution plannedProvider shareKey shareGate aliasGate capability aliasBackend running =
        joinIO $
            withNodeResourceOfKind shareExecution DurableShareResourceKind shareKey $ \plannedShare ->
                joinIO $
                    withNodeObservedResource shareExecution plannedShare 11 13 $ \observedShare -> do
                        shareSpec <- pure (mkProviderShareSpec (hostFixturePath "/srv/hostbootstrap/data") "/srv/hostbootstrap/data")
                        case shareSpec of
                            Left failure -> pure (Left failure)
                            Right declaredShare ->
                                flattenIO $
                                    withPreparedProviderShare
                                        shareExecution
                                        plannedShare
                                        observedShare
                                        running
                                        (dependencyProbe (pure (Right 17)))
                                        declaredShare
                                        shareGate
                                        ( settleShare
                                            backend
                                            projectPlan
                                            shareExecution
                                            plannedProvider
                                            plannedShare
                                            aliasGate
                                            capability
                                            aliasBackend
                                            running
                                        )

    settleShare backend _projectPlan shareExecution plannedProvider plannedShare aliasGate capability aliasBackend running preparedShare = do
        result <- runProviderShareCall backend preparedShare
        case settleProviderShare Nothing preparedShare result of
            Left failure -> pure (Left failure)
            Right settled ->
                withProviderShareSettlement
                    settled
                    (\managedShare _ -> prepareAlias shareExecution plannedProvider plannedShare aliasGate capability aliasBackend running managedShare)
                    (\_ _ _ _ -> pure (Left (Failure (FailureDetail "alias fixture" "unexpected foreign share" DoNotRetry))))
    prepareAlias shareExecution plannedProvider plannedShare aliasGate capability aliasBackend running managedShare =
        joinIO $
            withNodeGuestAliasProjection shareExecution plannedProvider plannedShare $ \plannedAlias edge ->
                joinIO $
                    withNodeObservedResource shareExecution plannedAlias 23 29 $ \observedAlias ->
                        flattenIO $
                            withPreparedGuestAliasCall
                                aliasBackend
                                running
                                managedShare
                                plannedAlias
                                edge
                                observedAlias
                                (dependencyProbe (pure (Right 19)))
                                aliasSpec
                                aliasGate
                                (consume capability aliasBackend running)

providerError :: ProviderError -> ReconcileError
providerError failure =
    Unsupported
        ( UnsupportedDetail
            "discover provider capability"
            (Text.pack (show failure))
        )

executionGate :: Execution.StepExecution scope planId -> IO PreparedGate
executionGate execution =
    gateFor
        (Execution.stepExecutionPlanDigest execution)
        (Execution.stepExecutionOperationKey execution)

{- | Which guest the provider dispatches into.

Named rather than supplied as a function, because the guest now answers from a
process: the lock front end a provider transaction runs under is this same
suite's executable, entered through the argument vector the backend describes,
and it selects its behaviour from the strategy the fixture wrote (§ NN).  A
named strategy is a value both processes can read, which a closure is not.
-}
data GuestStrategy
    = GuestSupported
    | GuestFallback
    | GuestBsd
    | GuestTransportFailure
    | GuestBadPythonMarker
    | GuestExtraDiscoveryLine
    | GuestDiscoveryStderr
    | GuestOversizedDiscoveryLine
    | GuestVmNotReady
    | GuestConflictOnDiscovery
    | GuestConflictOnAlias
    | GuestConflictOnRelease
    | GuestSecondAliasVerdict
    | GuestAliasStderr
    | GuestOversizedAliasVerdict
    | GuestSecondReleaseVerdict
    | GuestReleaseStderr
    | GuestOversizedReleaseVerdict
    | GuestLocal
    | GuestLocalCrashingOnce String String String
    deriving (Eq, Read, Show)

{- | The role this suite's alias fixtures declare themselves under.

Carries the named strategy, because the guest a case is about is a property of
that case and the process that has to answer as it is a different one (§ NN).
-}
aliasRole :: GuestStrategy -> String
aliasRole strategy = aliasRolePrefix <> show strategy

aliasRolePrefix :: String
aliasRolePrefix = "alias:"

{- | What answers inside the instance for this suite's alias fixtures.

Two things happen at a crossing, and they are different in kind: the guest
answers, and — for the strategies whose subject is an outer conflict or a daemon
that stops answering — the /provider/ changes underneath it.  The second is a
property of the object the ownership transaction re-observes on both sides of
the crossing, so it is established here rather than described in a line the guest
prints.
-}
aliasGuest :: FakeProvider.GuestHandler
aliasGuest root name role argv = case stripPrefix aliasRolePrefix role of
    Nothing -> pure (RawProviderFailure ("the alias guest was entered under the role " <> role))
    Just named -> do
        let strategy = read named
        answered <- guestFor (FakeProvider.providerToolStatePath root) strategy argv
        interfereWithProvider root name strategy argv
        pure answered

{- | What a named strategy does to the /provider/ while a guest command runs.

An outer conflict is not a line a guest prints: it is the instance under the name
having been replaced, which the ownership transaction discovers by re-observing
the identity on both sides of the crossing.  A transport failure is the
provider's own daemon ceasing to answer.  Both are properties of the object the
fixture holds, so both are established rather than described.
-}
interfereWithProvider :: FilePath -> String -> GuestStrategy -> [String] -> IO ()
interfereWithProvider root name strategy guest = case strategy of
    GuestConflictOnDiscovery | guest == ["which", "flock"] -> replaced
    GuestConflictOnAlias | isAliasInvocation guest -> replaced
    GuestConflictOnRelease | isReleaseInvocation guest -> replaced
    GuestTransportFailure | guest == ["which", "flock"] -> silent
    _ -> pure ()
  where
    replaced =
        FakeProvider.alterInstance
            root
            name
            (\held -> held{FakeProvider.instanceIdentity = "replacement-9"})
    silent =
        FakeProvider.alterInstance
            root
            name
            (\held -> held{FakeProvider.instanceDaemonAnswers = False})

{- | The guest each named strategy is, applied to the argument vector it was
dispatched with.

Every one of these runs in a child process of this same suite, so a case names
what the guest /is/ rather than closing over the parent's state; the two that
need memory keep it where a second process can see it, in the fixture's own
tool-state directory.
-}
guestFor :: FilePath -> GuestStrategy -> GuestRunner
guestFor toolState strategy argv = case strategy of
    GuestSupported -> supportedGuest argv
    GuestFallback -> fallbackGuest argv
    GuestBsd -> bsdGuest argv
    GuestTransportFailure -> supportedGuest argv
    GuestBadPythonMarker
        | isPythonMarker argv -> pure (RawProviderExit ExitSuccess "prefix-hostbootstrap-python3-suffix\n" "")
        | otherwise -> supportedGuest argv
    GuestExtraDiscoveryLine
        | argv == ["which", "flock"] -> pure (RawProviderExit ExitSuccess "/opt/hb/flock\n\n" "")
        | otherwise -> supportedGuest argv
    GuestDiscoveryStderr
        | argv == ["/opt/hb/python3", "-c", "print('hostbootstrap-python3')"] ->
            pure (RawProviderExit ExitSuccess "hostbootstrap-python3\n" "warning\n")
        | otherwise -> supportedGuest argv
    GuestOversizedDiscoveryLine
        | argv == ["which", "flock"] ->
            pure (RawProviderExit ExitSuccess ('/' : replicate 1020 'x' ++ "/flock\n") "")
        | otherwise -> supportedGuest argv
    -- A guest that answers the readiness probe with something the provider
    -- report vocabulary does not admit.  A guest that merely has not come up
    -- yet is the /retryable/ answer the production poll waits a minute for, and
    -- a suite whose subject is the ordering between readiness and tool
    -- discovery would be asserting that ordering a minute at a time.
    GuestVmNotReady
        | argv == ["true"] -> pure (RawProviderExit ExitSuccess "" "starting\n")
        | otherwise -> supportedGuest argv
    GuestConflictOnDiscovery -> supportedGuest argv
    GuestConflictOnAlias -> supportedGuest argv
    GuestConflictOnRelease -> supportedGuest argv
    GuestSecondAliasVerdict
        | isAliasInvocation argv -> pure (RawProviderExit ExitSuccess "CREATED 1:2\nCONFLICT x y z\n" "")
        | otherwise -> supportedGuest argv
    GuestAliasStderr
        | isAliasInvocation argv -> pure (RawProviderExit ExitSuccess "CREATED 1:2\n" "warning\n")
        | otherwise -> supportedGuest argv
    GuestOversizedAliasVerdict
        | isAliasInvocation argv -> pure (RawProviderExit ExitSuccess (replicate 1025 'x' ++ "\n") "")
        | otherwise -> supportedGuest argv
    GuestSecondReleaseVerdict
        | isReleaseInvocation argv -> pure (RawProviderExit ExitSuccess "RELEASED 1:2\nRELEASED_ALREADY\n" "")
        | otherwise -> supportedGuest argv
    GuestReleaseStderr
        | isReleaseInvocation argv -> pure (RawProviderExit ExitSuccess "RELEASED 1:2\n" "warning\n")
        | otherwise -> supportedGuest argv
    GuestOversizedReleaseVerdict
        | isReleaseInvocation argv -> pure (RawProviderExit ExitSuccess (replicate 1025 'x' ++ "\n") "")
        | otherwise -> supportedGuest argv
    GuestLocal -> localGuest argv
    GuestLocalCrashingOnce mode needle replacement
        | mode `elem` argv -> do
            let armed = toolState </> ("armed-" ++ mode)
            stillArmed <- doesPathExist armed
            if stillArmed
                then localGuest argv
                else do
                    let rewritten = map (replaceFirst needle replacement) argv
                    if rewritten == argv
                        then pure (RawProviderFailure ("missing alias checkpoint: " ++ needle))
                        else do
                            writeFile armed "tripped\n"
                            localGuest rewritten
        | otherwise -> localGuest argv

supportedGuest :: GuestRunner
supportedGuest argv = case argv of
    ["true"] -> pure (RawProviderExit ExitSuccess "" "")
    ["which", "flock"] -> pure (RawProviderExit ExitSuccess "/opt/hb/flock\n" "")
    ["which", "stat"] -> pure (RawProviderExit ExitSuccess "/opt/hb/stat\n" "")
    ["/opt/hb/stat", "-c", "%d:%i", "/"] -> pure (RawProviderExit ExitSuccess "1:2\n" "")
    ["which", "python3"] -> pure (RawProviderExit ExitSuccess "/opt/hb/python3\n" "")
    ["/opt/hb/python3", "-c", "print('hostbootstrap-python3')"] -> pure (RawProviderExit ExitSuccess "hostbootstrap-python3\n" "")
    _ | isAliasInvocation argv -> pure (RawProviderExit ExitSuccess "CREATED 1:2\n" "")
    _ -> pure (RawProviderExit (ExitFailure 127) "" "unsupported fixture command\n")

fallbackGuest :: GuestRunner
fallbackGuest argv = case argv of
    ["which", "flock"] -> pure (RawProviderExit (ExitFailure 1) "" "")
    ["which", "lockf"] -> pure (RawProviderExit ExitSuccess "/opt/hb/lockf\n" "")
    ["which", "stat"] -> pure (RawProviderExit ExitSuccess "/opt/hb/stat\n" "")
    ["/opt/hb/stat", "-c", "%d:%i", "/"] -> pure (RawProviderExit (ExitFailure 1) "" "")
    ["/opt/hb/stat", "-f", "%d:%i", "/"] -> pure (RawProviderExit ExitSuccess "1:2\n" "")
    ["which", "python3"] -> pure (RawProviderExit ExitSuccess "/opt/hb/python3\n" "")
    ["/opt/hb/python3", "-c", "print('hostbootstrap-python3')"] -> pure (RawProviderExit ExitSuccess "hostbootstrap-python3\n" "")
    ["true"] -> pure (RawProviderExit ExitSuccess "" "")
    _ | isAliasInvocation argv -> pure (RawProviderExit ExitSuccess "CREATED 1:2\n" "")
    _ -> pure (RawProviderExit (ExitFailure 127) "" "unsupported fixture command\n")

bsdGuest :: GuestRunner
bsdGuest argv = case argv of
    ["which", "flock"] -> pure (RawProviderExit ExitSuccess "/opt/hb/flock\n" "")
    ["which", "stat"] -> pure (RawProviderExit ExitSuccess "/opt/hb/stat\n" "")
    ["/opt/hb/stat", "-c", "%d:%i", "/"] -> pure (RawProviderExit (ExitFailure 1) "" "")
    ["/opt/hb/stat", "-f", "%d:%i", "/"] -> pure (RawProviderExit ExitSuccess "1:2\n" "")
    ["which", "python3"] -> pure (RawProviderExit ExitSuccess "/opt/hb/python3\n" "")
    ["/opt/hb/python3", "-c", "print('hostbootstrap-python3')"] -> pure (RawProviderExit ExitSuccess "hostbootstrap-python3\n" "")
    ["true"] -> pure (RawProviderExit ExitSuccess "" "")
    _ | isAliasInvocation argv -> pure (RawProviderExit ExitSuccess "CREATED 1:2\n" "")
    _ -> pure (RawProviderExit (ExitFailure 127) "" "unsupported fixture command\n")

forDiscoveryFailure :: String -> GuestStrategy -> IO ()
forDiscoveryFailure label strategy = do
    (outcome, _) <-
        withAliasFixture
            (aliasPlan (fixtureSalt label))
            portableAliasSpec
            ProviderAnswers
            strategy
            (\_ _ _ _ -> pure (Right ()))
    case outcome of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected discovery Failure for " ++ label ++ ", got " ++ show other)

forAliasResultFailure :: String -> GuestStrategy -> IO ()
forAliasResultFailure label strategy = do
    (outcome, _) <-
        withAliasFixture
            (aliasPlan (fixtureSalt label))
            portableAliasSpec
            ProviderAnswers
            strategy
            ( \_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                pure (Right (aliasCallResultView result))
            )
    case outcome of
        Right (AliasResultFailed _) -> pure ()
        other -> assertFailure ("expected alias result Failure for " ++ label ++ ", got " ++ show other)

forReleaseFailure :: String -> GuestStrategy -> IO ()
forReleaseFailure label strategy = do
    outcome <- releaseOutcome label strategy
    case outcome of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected release Failure for " ++ label ++ ", got " ++ show other)

releaseOutcome :: String -> GuestStrategy -> IO (Either ReconcileError ())
releaseOutcome label strategy =
    fst
        <$> withAliasFixture
            (aliasPlan (fixtureSalt label))
            portableAliasSpec
            ProviderAnswers
            strategy
            ( \_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                case settlePreparedGuestAliasCall Nothing call result of
                    Left failure -> pure (Left failure)
                    Right settled ->
                        withGuestAliasCallSettlement
                            settled
                            (\managed _ -> runRelease backend managed)
                            (\_ _ _ _ -> pure (Left (Failure (FailureDetail "release result fixture" "unexpected foreign alias" DoNotRetry))))
            )

fixtureSalt :: String -> String
fixtureSalt = ("failure-" ++) . map replace
  where
    replace character
        | isAlphaNum character = character
        | otherwise = '-'

isGuestToolProbe :: [String] -> Bool
isGuestToolProbe ["true"] = False
isGuestToolProbe _ = True

isPythonMarker :: [String] -> Bool
isPythonMarker (_ : "-c" : "print('hostbootstrap-python3')" : []) = True
isPythonMarker _ = False

isAliasInvocation :: [String] -> Bool
isAliasInvocation argv = isReconcileInvocation argv || isReleaseInvocation argv

isReconcileInvocation :: [String] -> Bool
isReconcileInvocation = elem "reconcile"

isReleaseInvocation :: [String] -> Bool
isReleaseInvocation = elem "release"

ownerFromArgv :: [String] -> Maybe String
ownerFromArgv argv = case dropWhile (/= "reconcile") argv of
    "reconcile" : _alias : _target : _record : owner : _ -> Just owner
    _ -> Nothing

assertExactRetainedTools :: [String] -> IO ()
assertExactRetainedTools argv = do
    take 1 argv @?= ["/opt/hb/flock"]
    assertBool "exact Python path retained" ("/opt/hb/python3" `elem` argv)
    reverse (take 3 (reverse argv)) @?= ["/opt/hb/stat", "-f", "%d:%i"]
    assertBool "no bare lock command" ("flock" `notElem` argv)
    assertBool "no bare Python command" ("python3" `notElem` argv)
    assertBool "no bare stat command" ("stat" `notElem` argv)

{- | Whether this gate host can run the guest alias driver locally.

Not a property of the fixture: the driver opens with @O_NOFOLLOW@, holds a
@flock(2)@ across an @exec@, publishes by a no-replace hard link, and binds a
symlink's exact @device:inode@. A Windows outer host offers none of those, and
'localGuest' below says so rather than pretending.
-}
localGuestAliasSupported :: Bool
#ifdef mingw32_HOST_OS
localGuestAliasSupported = False
#else
localGuestAliasSupported = True
#endif

{- | The guest a POSIX host runs for real, and the refusal a Windows one owes.

The local guest executes this project's alias driver against a real filesystem,
which is a POSIX contract; on a Windows outer host the case is not skipped
silently but answered with a refusal, so a family that vanished is a failed
count rather than a smaller total (§ JJ).
-}
#ifdef mingw32_HOST_OS
localGuest :: GuestRunner
localGuest ["true"] = pure (RawProviderExit ExitSuccess "" "")
localGuest _ = pure (RawProviderFailure "the local guest alias driver is a POSIX contract")
#endif

#ifndef mingw32_HOST_OS
localGuest :: GuestRunner
localGuest ["which", "flock"] = pure (RawProviderExit ExitSuccess "/test/bin/flock\n" "")
localGuest ("/test/bin/flock" : "-x" : lock : executable : argv) =
    runLocal executable (["-c", flockDriver, lock, executable] ++ argv)
localGuest [] = pure (RawProviderFailure "empty guest command")
localGuest (executable : argv) = runLocal executable argv

-- Exercise the real flock(2) namespace without depending on a host-installed
-- flock(1).  The inheritable descriptor holds the lock across exec into the
-- exact alias helper process.  Portable tests separately assert that only the
-- retained Flock front end can authorize this route.
flockDriver :: String
flockDriver =
    unlines
        [ "import fcntl"
        , "import os"
        , "import sys"
        , "lock_path, command, *arguments = sys.argv[1:]"
        , "descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)"
        , "fcntl.flock(descriptor, fcntl.LOCK_EX)"
        , "os.set_inheritable(descriptor, True)"
        , "os.execv(command, [command] + arguments)"
        ]

runLocal :: FilePath -> [String] -> IO RawProviderOutcome
runLocal executable argv = do
    outcome <- try (readProcessWithExitCode executable argv "")
    pure $ case outcome of
        Left failure -> RawProviderFailure (displayException (failure :: IOException))
        Right (code, out, err) -> RawProviderExit code out err
#endif

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

testProvider :: SubstrateProvider
testProvider =
    either
        (error . ("select provider: " ++))
        id
        ( selectSubstrateProvider
            (Substrate LinuxCpu Amd64)
            VMHandles
                { vmhIncus = IncusVM "test-vm" "images:ubuntu/24.04"
                , vmhLima = LimaVM "test-vm"
                , vmhWsl2 = Wsl2VM "test-vm"
                , vmhGuardPrefix = "test"
                }
        )

portableAliasSpec :: GuestAliasSpec
portableAliasSpec = either (error . show) id (mkGuestAliasSpec "/var/tmp/hb-alias" "/srv/hb-share")

aliasOperation :: Text.Text
aliasOperation = "core:deploy-vm/core:copy-source/guest-alias"

aliasPlan :: String -> StepPlan
aliasPlan salt =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia localContext (deployVMStep ("provider-" ++ salt) (StepFrame "host" "Host") (const (pure StepChanged)))
            , projectsOperation
                (Text.unpack aliasOperation)
                (copySourceStep ("share-" ++ salt) (StepFrame "provider" "Provider") (const (pure StepChanged)))
            ]
        )

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id

joinIO :: Either ReconcileError (IO (Either ReconcileError value)) -> IO (Either ReconcileError value)
joinIO = either (pure . Left) id

flattenIO :: IO (Either ReconcileError (IO (Either ReconcileError value))) -> IO (Either ReconcileError value)
flattenIO action = action >>= joinIO
