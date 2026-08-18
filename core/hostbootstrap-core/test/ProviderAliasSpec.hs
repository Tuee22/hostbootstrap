{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ProviderAliasSpec (tests) where

import Data.Char (isAlphaNum, ord)
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Flock, Incus, Python3), mkAbsExe)
import PlatformPath (hostFixturePath)
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
import Numeric (showHex)
import PrepareFixture (gateFor)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
#ifndef mingw32_HOST_OS
import Control.Exception (IOException, displayException, try)
import Data.List (isInfixOf, isPrefixOf)
import System.Directory (createDirectory, createFileLink, doesPathExist, listDirectory, pathIsSymbolicLink, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
#endif

type HostRunner = [String] -> IO RawProviderOutcome

type GuestRunner = [String] -> IO RawProviderOutcome

tests :: TestTree
tests =
    testGroup
        "ProviderAliasSpec"
        ( portableCases
            ++ posixCases
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
        calls <- newIORef []
        let guest argv = do
                modifyIORef' calls (++ [argv])
                fallbackGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "fallback")
                portableAliasSpec
                successfulHost
                guest
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Unsupported _) -> pure ()
            other -> assertFailure ("expected lockf-only Unsupported, got " ++ show other)
        invoked <- readIORef calls
        assertBool "lockf remains a descriptive discovery fallback" (["which", "lockf"] `elem` invoked)
        assertBool "no alias command ran under lockf" (not (any isAliasInvocation invoked))
    , testCase "raw discovery retains the exact flock, BSD stat, and Python executables" $ do
        calls <- newIORef []
        let guest argv = do
                modifyIORef' calls (++ [argv])
                bsdGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "bsd-tools")
                portableAliasSpec
                successfulHost
                guest
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    pure (Right (aliasCallResultView result)))
        outcome @?= Right (AliasResultCreated 23)
        invoked <- readIORef calls
        assertBool "GNU stat unavailability falls through to BSD" (["/opt/hb/stat", "-f", "%d:%i", "/"] `elem` invoked)
        case filter isAliasInvocation invoked of
            [argv] -> assertExactRetainedTools argv
            other -> assertFailure ("expected one alias invocation, got " ++ show other)
    , testCase "a transport failure is terminal and never falls through" $ do
        calls <- newIORef []
        let guest argv = do
                modifyIORef' calls (++ [argv])
                if argv == ["which", "flock"]
                    then pure (RawProviderFailure "locked provider identity changed")
                    else supportedGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "transport-failure")
                portableAliasSpec
                successfulHost
                guest
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected terminal discovery Failure, got " ++ show other)
        invoked <- readIORef calls
        assertBool "lockf was not tried after a transport failure" (["which", "lockf"] `notElem` invoked)
    , testCase "Python discovery requires one exact marker" $ do
        let guest argv
                | isPythonMarker argv = pure (RawProviderExit ExitSuccess "prefix-hostbootstrap-python3-suffix\n" "")
                | otherwise = supportedGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "bad-python-marker")
                portableAliasSpec
                successfulHost
                guest
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected malformed Python marker Failure, got " ++ show other)
    , testCase "tool discovery rejects extra lines and successful stderr" $ do
        let extraLine argv
                | argv == ["which", "flock"] = pure (RawProviderExit ExitSuccess "/opt/hb/flock\n\n" "")
                | otherwise = supportedGuest argv
            successfulStderr argv
                | argv == ["/opt/hb/python3", "-c", "print('hostbootstrap-python3')"] =
                    pure (RawProviderExit ExitSuccess "hostbootstrap-python3\n" "warning\n")
                | otherwise = supportedGuest argv
            oversized argv
                | argv == ["which", "flock"] = pure (RawProviderExit ExitSuccess ('/' : replicate 1020 'x' ++ "/flock\n") "")
                | otherwise = supportedGuest argv
        forDiscoveryFailure "extra discovery line" extraLine
        forDiscoveryFailure "successful discovery stderr" successfulStderr
        forDiscoveryFailure "oversized discovery line" oversized
    , testCase "guest tools are not probed until the managed VM is freshly ready" $ do
        calls <- newIORef []
        let guest argv = do
                modifyIORef' calls (++ [argv])
                if argv == ["true"]
                    then pure (RawProviderExit (ExitFailure 1) "" "starting\n")
                    else supportedGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "vm-not-ready-order")
                portableAliasSpec
                successfulHost
                guest
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Failure _) -> pure ()
            other -> assertFailure ("expected retained NotReady to refuse Alias admission, got " ++ show other)
        invoked <- readIORef calls
        assertBool "the VM probe was attempted" (["true"] `elem` invoked)
        assertBool "no guest tool probe ran before readiness" (not (any isGuestToolProbe invoked))
    , testCase "an outer provider conflict remains Conflict through discovery" $ do
        calls <- newIORef []
        let guest argv = do
                modifyIORef' calls (++ [argv])
                if argv == ["which", "flock"]
                    then pure (RawProviderFailure "HB_PROVIDER_CONFLICT owner=provider replacement=9 provider-replaced")
                    else supportedGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "provider-conflict-discovery")
                portableAliasSpec
                successfulHost
                guest
                (\_ _ _ _ -> pure (Right ()))
        case outcome of
            Left (Conflict _) -> pure ()
            other -> assertFailure ("expected structured provider Conflict, got " ++ show other)
        invoked <- readIORef calls
        assertBool "lockf fallback did not erase Conflict" (["which", "lockf"] `notElem` invoked)
    , testCase "an outer provider conflict remains an indexed alias Conflict" $ do
        let guest argv
                | isAliasInvocation argv = pure (RawProviderFailure "HB_PROVIDER_CONFLICT owner=provider replacement=9 provider-replaced")
                | otherwise = supportedGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "provider-conflict-alias")
                portableAliasSpec
                successfulHost
                guest
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    pure (Right (aliasCallResultView result)))
        case outcome of
            Right (AliasResultConflict _) -> pure ()
            other -> assertFailure ("expected AliasResultConflict, got " ++ show other)
    , testCase "alias result parsing rejects a second verdict and successful stderr" $ do
        let secondVerdict argv
                | isAliasInvocation argv = pure (RawProviderExit ExitSuccess "CREATED 1:2\nCONFLICT x y z\n" "")
                | otherwise = supportedGuest argv
            successfulStderr argv
                | isAliasInvocation argv = pure (RawProviderExit ExitSuccess "CREATED 1:2\n" "warning\n")
                | otherwise = supportedGuest argv
            oversized argv
                | isAliasInvocation argv = pure (RawProviderExit ExitSuccess (replicate 1025 'x' ++ "\n") "")
                | otherwise = supportedGuest argv
        forAliasResultFailure "second alias verdict" secondVerdict
        forAliasResultFailure "alias successful stderr" successfulStderr
        forAliasResultFailure "oversized alias verdict" oversized
    , testCase "release result parsing rejects a second verdict and successful stderr" $ do
        let secondVerdict argv
                | isReleaseInvocation argv = pure (RawProviderExit ExitSuccess "RELEASED 1:2\nRELEASED_ALREADY\n" "")
                | otherwise = supportedGuest argv
            successfulStderr argv
                | isReleaseInvocation argv = pure (RawProviderExit ExitSuccess "RELEASED 1:2\n" "warning\n")
                | otherwise = supportedGuest argv
            oversized argv
                | isReleaseInvocation argv = pure (RawProviderExit ExitSuccess (replicate 1025 'x' ++ "\n") "")
                | otherwise = supportedGuest argv
        forReleaseFailure "second release verdict" secondVerdict
        forReleaseFailure "release successful stderr" successfulStderr
        forReleaseFailure "oversized release verdict" oversized
    , testCase "an outer provider conflict remains Conflict through release" $ do
        let guest argv
                | isReleaseInvocation argv = pure (RawProviderFailure "HB_PROVIDER_CONFLICT owner=provider replacement=9 provider-replaced")
                | otherwise = supportedGuest argv
        outcome <- releaseOutcome "provider-conflict-release" guest
        case outcome of
            Left (Conflict _) -> pure ()
            other -> assertFailure ("expected release Conflict, got " ++ show other)
    , testCase "provisioning egress Unavailable is descriptive for an already-running alias" $ do
        let host argv
                | isEgressRequest argv = pure (RawProviderExit (ExitFailure 1) "" "not found\n")
                | otherwise = successfulHost argv
        outcome <-
            withAliasFixture
                (aliasPlan "egress-unavailable")
                portableAliasSpec
                host
                supportedGuest
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    pure (Right (aliasCallResultView result)))
        outcome @?= Right (AliasResultCreated 23)
    , testCase "a retained daemon failure cannot mint a Strong alias backend" $ do
        let host argv
                | isListRequest argv = pure (RawProviderFailure "provider transport failed")
                | otherwise = successfulHost argv
        outcome <-
            withAliasFixture
                (aliasPlan "daemon-failure")
                portableAliasSpec
                host
                supportedGuest
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
        withAliasFixture
            (aliasPlan "settlement")
            portableAliasSpec
            successfulHost
            supportedGuest
            (\_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                pure $ do
                    settled <- settlePreparedGuestAliasCall Nothing call result
                    pure $
                        withGuestAliasCallSettlement
                            settled
                            (\_ change -> change)
                            (\_ _ _ _ -> error "created backend result must settle managed"))
            >>= (@?= Right (Changed Created))
    , testCase "a stale conditional release version refuses before guest execution" $ do
        calls <- newIORef (0 :: Int)
        let guest argv = do
                modifyIORef' calls (+ 1)
                supportedGuest argv
        outcome <-
            withAliasFixture
                (aliasPlan "stale-release-fence")
                portableAliasSpec
                successfulHost
                guest
                (\_ backend _ call -> do
                    result <- runPreparedGuestAliasCall backend call
                    case settlePreparedGuestAliasCall Nothing call result of
                        Left failure -> pure (Left failure)
                        Right settled ->
                            withGuestAliasCallSettlement
                                settled
                                ( \managed _ -> do
                                    before <- readIORef calls
                                    let stale = managedGuestAliasObservationVersion managed + 1
                                    case withPreparedGuestAliasRelease managed stale (runPreparedGuestAliasRelease backend) of
                                        Left (Conflict _) -> do
                                            after <- readIORef calls
                                            pure
                                                ( if after == before
                                                    then Right ()
                                                    else Left (Failure (FailureDetail "stale release test" "the guest executor ran" DoNotRetry))
                                                )
                                        Left failure -> pure (Left failure)
                                        Right _ -> pure (Left (Failure (FailureDetail "stale release test" "a stale version prepared" DoNotRetry)))
                                )
                                (\_ _ _ _ -> pure (Left (Failure (FailureDetail "stale release test" "unexpected foreign alias" DoNotRetry))))
                )
        outcome @?= Right ()
    ]

posixCases :: [TestTree]
#ifdef mingw32_HOST_OS
posixCases = []
#else
posixCases =
    [ testCase "the locked guest protocol creates, releases, and confirms already released" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            outcome <-
                withAliasFixture
                    (aliasPlan "real-create-release")
                    spec
                    successfulHost
                    localGuest
                    createAndRelease
            outcome @?= Right ()
            doesPathExist alias >>= assertBool "released alias is absent" . not
    , testCase "conditional release refuses a foreign replacement" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                foreignTarget = directory </> "foreign"
                alias = directory </> "alias"
            createDirectory target
            createDirectory foreignTarget
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            outcome <-
                withAliasFixture
                    (aliasPlan "real-release-conflict")
                    spec
                    successfulHost
                    localGuest
                    (createTamperAndRelease alias foreignTarget)
            case outcome of
                Left (Conflict _) -> do
                    pathIsSymbolicLink alias >>= assertBool "foreign replacement remains"
                other -> assertFailure ("expected release Conflict, got " ++ show other)
    , testCase "an existing managed record reports AlreadyExact, never fabricates creation" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            outcome <-
                withAliasFixture
                    (aliasPlan "real-retry")
                    spec
                    successfulHost
                    localGuest
                    (\_ backend _ call -> do
                        first <- runPreparedGuestAliasCall backend call
                        case settlePreparedGuestAliasCall Nothing call first of
                            Left failure -> pure (Left failure)
                            Right _ -> do
                                second <- runPreparedGuestAliasCall backend call
                                pure (Right (aliasCallResultView second)))
            outcome @?= Right (AliasResultAlreadyExact 23)
    , testCase "a crash after origin publication resumes the same alias generation" $
        acquireCrashResumeCase
            "after-origin"
            "pass  # HB_ALIAS_AFTER_ORIGIN"
            "os._exit(97)  # HB_ALIAS_AFTER_ORIGIN"
    , testCase "a partial prepared origin stage is completed before publication" $
        acquireCrashResumeCase
            "partial-origin-stage"
            "create_full(stage, payload, 'prepared-stage')"
            "fd = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, payload[:17]); os.fsync(fd); os.close(fd); os._exit(97)"
    , testCase "a crash after alias publication binds the published inode on retry" $
        acquireCrashResumeCase
            "after-publish"
            "pass  # HB_ALIAS_AFTER_PUBLISH"
            "os._exit(97)  # HB_ALIAS_AFTER_PUBLISH"
    , testCase "a partial managed transition record is completed on acquisition retry" $
        acquireCrashResumeCase
            "partial-managed-transition"
            "create_full(temporary, payload, state_value + '-temp')"
            "fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, payload[:17]); os.fsync(fd); os.close(fd); os._exit(97)"
    , testCase "a crash after foreign-stage cleanup resumes the origin unwind" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                foreignTarget = directory </> "foreign"
                alias = directory </> "alias"
            createDirectory target
            createDirectory foreignTarget
            createFileLink foreignTarget alias
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            guest <-
                crashOnceReplacing
                    "reconcile"
                    "pass  # HB_ALIAS_AFTER_FOREIGN_CLEANUP"
                    "os._exit(97)  # HB_ALIAS_AFTER_FOREIGN_CLEANUP"
            outcome <-
                withAliasFixture
                    (aliasPlan "foreign-unwind")
                    spec
                    successfulHost
                    guest
                    crashAndRetryAlias
            case outcome of
                Right (AliasResultForeign _ _) -> pure ()
                other -> assertFailure ("expected resumed foreign observation, got " ++ show other)
            pathIsSymbolicLink alias >>= assertBool "foreign alias remains untouched"
            entries <- stateEntries target
            entries @?= []
            assertNoAliasStage directory
    , testCase "an external unlink before release intent is a retained Conflict" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            outcome <-
                withAliasFixture
                    (aliasPlan "release-unlinked-before-intent")
                    spec
                    successfulHost
                    localGuest
                    (createUnlinkAndRelease alias)
            case outcome of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected release Conflict, got " ++ show other)
            entries <- stateEntries target
            assertBool "managed origin survives the refused release" (not (null entries))
    , testCase "release refuses a different-nonce alias staging residue without mutation" $
        withSystemTempDirectory "hb-alias" $ \directory -> do
            let target = directory </> "share"
                alias = directory </> "alias"
                residue = alias ++ ".hb-alias-stage-" ++ replicate 64 'a'
            createDirectory target
            spec <- either (assertFailure . show) pure (mkGuestAliasSpec alias target)
            outcome <-
                withAliasFixture
                    (aliasPlan "release-stage-residue")
                    spec
                    successfulHost
                    localGuest
                    (createResidueAndRelease residue target)
            case outcome of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected staging-residue Conflict, got " ++ show other)
            pathIsSymbolicLink alias >>= assertBool "managed alias survives the refused release"
            pathIsSymbolicLink residue >>= assertBool "foreign staging residue remains untouched"
            entries <- stateEntries target
            assertBool "managed origin survives the refused release" (not (null entries))
    , testCase "a crash after release intent resumes the exact release fence" $
        releaseCrashResumeCase
            "after-release-intent"
            "pass  # HB_ALIAS_AFTER_RELEASE_INTENT"
            "os._exit(97)  # HB_ALIAS_AFTER_RELEASE_INTENT"
    , testCase "a partial releasing transition record is completed on release retry" $
        releaseCrashResumeCase
            "partial-releasing-transition"
            "create_full(temporary, payload, state_value + '-temp')"
            "fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, payload[:17]); os.fsync(fd); os.close(fd); os._exit(97)"
    , testCase "a crash after unlink finishes record deletion without re-unlinking" $
        releaseCrashResumeCase
            "after-release-unlink"
            "pass  # HB_ALIAS_AFTER_RELEASE_UNLINK"
            "os._exit(97)  # HB_ALIAS_AFTER_RELEASE_UNLINK"
    ]
#endif

#ifndef mingw32_HOST_OS
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
        guest <- crashOnceReplacing "reconcile" needle replacement
        outcome <-
            withAliasFixture
                (aliasPlan salt)
                spec
                successfulHost
                guest
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
        guest <- crashOnceReplacing "release" needle replacement
        outcome <-
            withAliasFixture
                (aliasPlan salt)
                spec
                successfulHost
                guest
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

crashOnceReplacing :: String -> String -> String -> IO GuestRunner
crashOnceReplacing mode needle replacement = do
    armed <- newIORef True
    pure $ \argv ->
        if mode `elem` argv
            then do
                shouldCrash <- readIORef armed
                if shouldCrash
                    then do
                        let rewritten = map (replaceFirst needle replacement) argv
                        if rewritten == argv
                            then pure (RawProviderFailure ("missing alias checkpoint: " ++ needle))
                            else do
                                modifyIORef' armed (const False)
                                localGuest rewritten
                    else localGuest argv
            else localGuest argv

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
#endif

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
    owners <- newIORef []
    let guest argv
            | isAliasInvocation argv = do
                case ownerFromArgv argv of
                    Just owner -> modifyIORef' owners (++ [owner])
                    Nothing -> pure ()
                pure (RawProviderExit ExitSuccess "CREATED 1:2\n" "")
            | otherwise = supportedGuest argv
    outcome <-
        withAliasFixture
            plan
            portableAliasSpec
            successfulHost
            guest
            (\_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                pure (Right (aliasCallResultView result)))
    case outcome of
        Left failure -> assertFailure (show failure)
        Right _ -> pure ()
    readIORef owners >>= \case
        [owner] -> pure owner
        observed -> assertFailure ("expected one owner, got " ++ show observed)

withAliasFixture ::
    StepPlan ->
    GuestAliasSpec ->
    HostRunner ->
    GuestRunner ->
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
    IO (Either ReconcileError summary)
withAliasFixture plan aliasSpec host guest consume =
    case mkIncusBackendSpec "test-vm" "images:ubuntu/24.04" backendHostConfig "/test/provider-state" 4 "8GiB" "40GiB" of
        Left failure -> pure (Left failure)
        Right spec -> do
            discovered <-
                discoverStrongProviderBackend (fixtureBackendExec host guest) spec $ \backend ->
                    Fixture.withFixtureProjectPlan plan $ \projectPlan ->
                        prepareProject backend projectPlan
            pure (joinReconcile discovered)
  where
    prepareProject backend projectPlan =
        case NonEmpty.toList (ProjectPlan.forward projectPlan) of
            [providerNode, shareNode] -> do
                carrier <- Execution.newResourceCarrier
                providerRuntime <- Execution.newStepRuntime carrier
                shareRuntime <- Execution.newStepRuntime carrier
                let providerExecution = stepExecutionFor projectPlan backendHostConfig providerRuntime providerNode
                    shareExecution = stepExecutionFor projectPlan backendHostConfig shareRuntime shareNode
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
                        shareSpec <- pure (mkProviderShareSpec "/srv/hostbootstrap/data" "/srv/hostbootstrap/data")
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

fixtureBackendExec :: HostRunner -> GuestRunner -> ProviderBackendExec
fixtureBackendExec host guest =
    ProviderBackendExec
        { runProviderBackendExec = \request -> case providerBackendRequestView request of
            ProviderBackendProcess _ argv
                | Just "provision" <- providerMode argv -> pure (successfulReport "CREATED provider-17")
                | Just "ready" <- providerMode argv -> pure (successfulReport "READY")
                | Just "share" <- providerMode argv -> pure (successfulReport "SHARE_ATTACHED")
                | Just "guest" <- providerMode argv ->
                    case guestExtra argv of
                        Nothing -> pure (RawProviderFailure "malformed locked guest request")
                        Just inner -> guest inner >>= pure . guestWire
                | isOwnershipProbe argv -> pure (successfulReport "PROVED flock")
                | otherwise -> host argv
        , waitProviderBackendExec = \_ -> pure ()
        }

providerMode :: [String] -> Maybe String
providerMode argv = firstPresent ["provision", "ready", "share", "guest"]
  where
    firstPresent [] = Nothing
    firstPresent (candidate : rest)
        | candidate `elem` argv = Just candidate
        | otherwise = firstPresent rest

guestExtra :: [String] -> Maybe [String]
guestExtra argv = case dropWhile (/= "guest") argv of
    "guest" : boundFields -> Just (drop 8 boundFields)
    _ -> Nothing

guestWire :: RawProviderOutcome -> RawProviderOutcome
guestWire outcome = case outcome of
    RawProviderFailure reason -> RawProviderFailure reason
    RawProviderExit code out err ->
        RawProviderExit
            ExitSuccess
            ("GUEST " ++ show (exitNumber code) ++ " " ++ hexField out ++ " " ++ hexField err ++ "\n")
            ""

exitNumber :: ExitCode -> Int
exitNumber ExitSuccess = 0
exitNumber (ExitFailure code) = code

hexField :: String -> String
hexField "" = "-"
hexField value = concatMap hexCharacter value
  where
    hexCharacter character =
        case showHex (ord character) "" of
            [digit] -> ['0', digit]
            digits -> digits

successfulReport :: String -> RawProviderOutcome
successfulReport report = RawProviderExit ExitSuccess (report ++ "\n") ""

successfulHost :: HostRunner
successfulHost _ = pure (RawProviderExit ExitSuccess "" "")

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

forDiscoveryFailure :: String -> GuestRunner -> IO ()
forDiscoveryFailure label guest = do
    outcome <-
        withAliasFixture
            (aliasPlan (fixtureSalt label))
            portableAliasSpec
            successfulHost
            guest
            (\_ _ _ _ -> pure (Right ()))
    case outcome of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected discovery Failure for " ++ label ++ ", got " ++ show other)

forAliasResultFailure :: String -> GuestRunner -> IO ()
forAliasResultFailure label guest = do
    outcome <-
        withAliasFixture
            (aliasPlan (fixtureSalt label))
            portableAliasSpec
            successfulHost
            guest
            ( \_ backend _ call -> do
                result <- runPreparedGuestAliasCall backend call
                pure (Right (aliasCallResultView result))
            )
    case outcome of
        Right (AliasResultFailed _) -> pure ()
        other -> assertFailure ("expected alias result Failure for " ++ label ++ ", got " ++ show other)

forReleaseFailure :: String -> GuestRunner -> IO ()
forReleaseFailure label guest = do
    outcome <- releaseOutcome label guest
    case outcome of
        Left (Failure _) -> pure ()
        other -> assertFailure ("expected release Failure for " ++ label ++ ", got " ++ show other)

releaseOutcome :: String -> GuestRunner -> IO (Either ReconcileError ())
releaseOutcome label guest =
    withAliasFixture
        (aliasPlan (fixtureSalt label))
        portableAliasSpec
        successfulHost
        guest
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

isOwnershipProbe :: [String] -> Bool
isOwnershipProbe argv = case reverse argv of
    "flock" : _ -> True
    _ -> False

isListRequest :: [String] -> Bool
isListRequest ("list" : _) = True
isListRequest _ = False

isEgressRequest :: [String] -> Bool
isEgressRequest ("image" : "info" : _) = True
isEgressRequest _ = False

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

backendHostConfig :: HostConfig
backendHostConfig =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64
        , hcToolPaths =
            Map.fromList
                [ (Incus, fixtureExe fixtureIncus)
                , (Python3, fixtureExe fixturePython)
                , (Flock, fixtureExe fixtureFlock)
                ]
        }

{- | The host tools this suite's fixtures name.

Each is rendered onto the host that runs the suite, so the same total 'AbsExe'
constructor production uses admits it on every supported outer host realization
(§ JJ).

The guest paths above are a different thing entirely: an in-VM @which@ result
and a guest argument vector name files on the machine the provider dispatches
into, reached through one absolute host-provider command (§ K), and they stay
POSIX on every host.
-}
fixtureIncus, fixturePython, fixtureFlock :: FilePath
fixtureIncus = hostFixturePath "/test/bin/incus"
fixturePython = hostFixturePath "/test/bin/python3"
fixtureFlock = hostFixturePath "/test/bin/flock"

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
