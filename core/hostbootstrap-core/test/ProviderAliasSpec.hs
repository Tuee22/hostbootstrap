{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ProviderAliasSpec (tests) where

import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Readiness
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Amd64), Substrate (Substrate), SubstrateName (LinuxCpu))
import HostBootstrap.Substrate.Provider
import HostBootstrap.Substrate.Provider.Alias
import HostBootstrap.Wsl2 (Wsl2VM (..))
import System.Directory (createDirectory, doesPathExist, pathIsSymbolicLink)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

type FixtureScope = Production Fixture.FixtureProject

tests :: TestTree
tests =
    testGroup
        "ProviderAliasSpec"
        [ testCase "guest alias specs require distinct absolute POSIX paths" $ do
            assertBool "relative alias rejected" (isLeft (mkGuestAliasSpec "tmp/alias" "/srv/data"))
            assertBool "relative target rejected" (isLeft (mkGuestAliasSpec "/tmp/alias" "srv/data"))
            assertBool "same normalized path rejected" (isLeft (mkGuestAliasSpec "/srv/data/" "/srv/data"))
            fmap guestAliasPath (mkGuestAliasSpec "/var/tmp/project-data" "/srv/project/data")
                @?= Right "/var/tmp/project-data"
        , testCase "provider/share prefix derives one stable alias identity" $
            projectionSummary
                @?= Right "core:deploy-vm/core:copy-source/guest-alias"
        , testCase "prepared create retains its actual operation key in the receipt" $ do
            result <-
                withPreparedAliasFixture 13 $ \_ _ prepared -> do
                    settled <-
                        settlePreparedGuestAliasCall
                            Nothing
                            prepared
                            (AliasCallCreated 23)
                    pure $
                        withReconcileResult
                            settled
                            (\_ receipt change -> (change, ownershipReceiptOperationKey receipt))
                            (\_ _ -> error "created alias must be managed")
            case result of
                Right (Changed Created, operationKey) -> do
                    assertBool
                        "receipt retains the plan-derived alias operation"
                        ("core:deploy-vm/core:copy-source/guest-alias:" `Text.isPrefixOf` operationKey)
                    assertBool "legacy fabricated key is gone" (operationKey /= "ordinary-acquire")
                other -> assertFailure ("expected managed creation, got " ++ show other)
        , testCase "an exact-looking alias without prior proof remains foreign" $ do
            result <-
                withPreparedAliasFixture 13 $ \_ _ prepared -> do
                    settled <-
                        settlePreparedGuestAliasCall
                            Nothing
                            prepared
                            (AliasCallAlreadyExact 23)
                    pure $
                        withReconcileResult
                            settled
                            (\_ _ _ -> error "appearance alone must not establish ownership")
                            (\_ foreignState -> foreignIdentity foreignState)
            result @?= Right "/var/tmp/hostbootstrap-data"
        , testCase "matching committed proof preserves the receipt for Unchanged" $ do
            result <-
                withPreparedAliasFixture 13 unchangedAfterCommit
            case result of
                Right (Unchanged, createdKey, unchangedKey) -> createdKey @?= unchangedKey
                other -> assertFailure ("expected receipt-preserving Unchanged, got " ++ show other)
        , testCase "readiness from another observation snapshot cannot prepare" $ do
            result <- withPreparedAliasFixture 14 (\_ _ _ -> Right ())
            case result of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected readiness conflict, got " ++ show other)
        , testCase "unsupported settlement cannot return a handle or receipt" $ do
            result <-
                withPreparedAliasFixture 13 $ \_ _ prepared ->
                    case settlePreparedGuestAliasCall
                        Nothing
                        prepared
                        ( AliasCallUnsupported
                            (UnsupportedDetail "create guest alias" "protected backend unavailable")
                        ) of
                        Left err -> Left err
                        Right _ -> Right ()
            case result of
                Left (Unsupported _) -> pure ()
                Left other -> assertFailure ("expected Unsupported, got " ++ show other)
                Right _ -> assertFailure "unsupported settlement unexpectedly returned ownership"
        , testCase "conditional release requires the managed handle and matching receipt" $ do
            result <-
                withPreparedAliasFixture 13 $ \_ _ prepared -> do
                    settled <-
                        settlePreparedGuestAliasCall
                            Nothing
                            prepared
                            (AliasCallCreated 23)
                    withReconcileResult
                        settled
                        ( \managed receipt _ ->
                            withPreparedGuestAliasRelease
                                aliasSpec
                                managed
                                receipt
                                31
                                (const ())
                        )
                        (\_ _ -> Left (Failure (FailureDetail "test release" "expected managed alias" DoNotRetry)))
            result @?= Right ()
        , testCase "backend discovery is Unsupported when the guest lacks the ownership tools" $ do
            discovered <- discoverStrongAliasBackend testProvider toollessGuestExec
            case discovered of
                Left (Unsupported (UnsupportedDetail _ reason)) ->
                    assertBool
                        "diagnostic names the missing POSIX ownership tools"
                        ("POSIX ownership tool" `Text.isInfixOf` reason)
                Left other -> assertFailure ("expected Unsupported, got " ++ show other)
                Right _ -> assertFailure "a guest without the tools must not mint a backend"
        , testCase "backend discovery mints a capability when the guest holds the tools" $ do
            discovered <- discoverStrongAliasBackend testProvider localGuestExec
            case discovered of
                Right _ -> pure ()
                Left err -> assertFailure ("expected a strong backend, got " ++ show err)
        , testCase "the guest backend creates, owns, and conditionally releases the alias" $
            withRealAlias $ \spec dir backend -> do
                outcome <- createOwnRelease spec backend
                case outcome of
                    Right () -> do
                        stillThere <- doesPathExist (dir </> "alias")
                        assertBool "the released alias is unlinked" (not stillThere)
                    Left err -> assertFailure ("expected create then release, got " ++ show err)
        , testCase "release refuses a foreign-replaced alias and leaves it intact" $
            withRealAlias $ \spec dir backend -> do
                -- Create + own the alias, then repoint it at a foreign target between
                -- ownership and release.  Clause 4 re-observes and must refuse the
                -- unlink, returning a structured conflict and leaving the alias alone.
                createDirectory (dir </> "other")
                released <-
                    createThen
                        spec
                        backend
                        (tamperRepoint (dir </> "alias") (dir </> "other"))
                case released of
                    Left (Conflict _) -> do
                        stillLink <- pathIsSymbolicLink (dir </> "alias")
                        assertBool "the foreign-replaced alias is left intact" stillLink
                    other -> assertFailure ("expected a release conflict, got " ++ show other)
        , testCase "an occupying non-symlink is reported foreign, never adopted" $
            withRealAlias $ \spec dir backend -> do
                writeFile (dir </> "alias") "not our link\n"
                observation <- reconcileOnce spec backend
                case observation of
                    AliasCallForeign _ foreignState ->
                        foreignIdentity foreignState @?= Text.pack (dir </> "alias")
                    other -> assertFailure ("expected a foreign observation, got " ++ show other)
        ]

{- | A guest command runner that executes the argv against the test host's real
POSIX filesystem, so the four-clause protocol is exercised for real on every
substrate this suite runs on.
-}
localGuestExec :: GuestExec
localGuestExec = GuestExec runLocal
  where
    runLocal [] = pure (GuestCommandResult False "" "empty guest command")
    runLocal (cmd : args) = do
        (code, out, err) <- readProcessWithExitCode cmd args ""
        pure (GuestCommandResult (code == ExitSuccess) out err)

{- | A guest that reports every command as failed, standing in for a guest that
lacks the ownership tools.
-}
toollessGuestExec :: GuestExec
toollessGuestExec =
    GuestExec (\_ -> pure (GuestCommandResult False "" "no ownership tools"))

{- | Set up a real temp directory with a share, a valid alias spec pointing into
it, and a discovered backend over 'localGuestExec'.
-}
withRealAlias ::
    (GuestAliasSpec -> FilePath -> StrongAliasBackend -> IO a) ->
    IO a
withRealAlias action =
    withSystemTempDirectory "hb-alias" $ \dir -> do
        let share = dir </> "share"
        createDirectory share
        spec <-
            either (assertFailure . ("alias spec: " ++) . show) pure $
                mkGuestAliasSpec (dir </> "alias") share
        discovered <- discoverStrongAliasBackend testProvider localGuestExec
        backend <- either (assertFailure . ("discover: " ++) . show) pure discovered
        action spec dir backend

-- | Prepare an alias reconcile over a real spec and run it once.
reconcileOnce :: GuestAliasSpec -> StrongAliasBackend -> IO AliasCallObservation
reconcileOnce spec backend = do
    outer <-
        withPreparedAliasFixtureFor spec 13 $ \_ _ prepared ->
            Right (runPreparedGuestAliasCall backend prepared)
    either (assertFailure . ("prepare: " ++) . show) id outer

{- | Create + own the alias, run @between@ to perturb the guest state, then
attempt the conditional release; returns the release outcome.
-}
createThen ::
    GuestAliasSpec ->
    StrongAliasBackend ->
    IO () ->
    IO (Either ReconcileError ())
createThen spec backend between = do
    outer <-
        withPreparedAliasFixtureFor spec 13 $ \_ _ prepared ->
            Right (createSettleThenRelease spec backend between prepared)
    either (pure . Left) id outer

-- | The happy path: create, settle to a managed receipt, release; no tamper.
createOwnRelease :: GuestAliasSpec -> StrongAliasBackend -> IO (Either ReconcileError ())
createOwnRelease spec backend = createThen spec backend (pure ())

createSettleThenRelease ::
    GuestAliasSpec ->
    StrongAliasBackend ->
    IO () ->
    PreparedGuestAliasCall FixtureScope planId aliasId shareId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
createSettleThenRelease spec backend between prepared = do
    observation <- runPreparedGuestAliasCall backend prepared
    case settlePreparedGuestAliasCall Nothing prepared observation of
        Left err -> pure (Left err)
        Right settled ->
            withReconcileResult
                settled
                ( \managed receipt _ -> do
                    between
                    case withPreparedGuestAliasRelease
                        spec
                        managed
                        receipt
                        31
                        (runPreparedGuestAliasRelease backend) of
                        Left err -> pure (Left err)
                        Right release -> release
                )
                ( \_ foreignState ->
                    pure
                        ( Left
                            ( Failure
                                ( FailureDetail
                                    "create own release"
                                    ("unexpected foreign at create: " <> foreignIdentity foreignState)
                                    DoNotRetry
                                )
                            )
                        )
                )

{- | Repoint the alias at a foreign target, standing in for a peer that replaces
the managed link between ownership and release.
-}
tamperRepoint :: FilePath -> FilePath -> IO ()
tamperRepoint alias foreignTarget = do
    _ <-
        readProcessWithExitCode
            "sh"
            ["-c", "rm -f \"$1\" && ln -s \"$2\" \"$1\"", "hb", alias, foreignTarget]
            ""
    pure ()

aliasSpec :: GuestAliasSpec
aliasSpec =
    either
        (error . show)
        id
        (mkGuestAliasSpec "/var/tmp/hostbootstrap-data" "/srv/hostbootstrap/data")

unchangedAfterCommit ::
    LifecyclePlan FixtureScope planId ->
    ResourceHandle
        FixtureScope
        planId
        aliasId
        DurableAliasResource
        Unclassified
        Observed ->
    PreparedGuestAliasCall
        FixtureScope
        planId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    Either ReconcileError (ChangeView, Text.Text, Text.Text)
unchangedAfterCommit plan handle prepared = do
    created <-
        settlePreparedGuestAliasCall
            Nothing
            prepared
            (AliasCallCreated 23)
    withReconcileResult
        created
        ( \_ receipt _ -> do
            let operationKey = ownershipReceiptOperationKey receipt
                record =
                    PersistedJournalRecord
                        { persistedPlanDigest = lifecyclePlanDigest plan
                        , persistedFrameKey = "provider-guest"
                        , persistedResourceKey = resourceHandleKey handle
                        , persistedGeneration = resourceHandleGeneration handle
                        , persistedOperation = "reconcile guest alias"
                        , persistedOperationKey = operationKey
                        , persistedRecordVersion = 41
                        , persistedPhase = Committed
                        }
            verified <-
                verifyPersistedJournalRecord
                    plan
                    handle
                    "reconcile guest alias"
                    record
            joinReconcile $
                withPriorCommitProof verified $ \proof -> do
                    unchanged <-
                        settlePreparedGuestAliasCall
                            (Just proof)
                            prepared
                            (AliasCallAlreadyExact 23)
                    pure $
                        withReconcileResult
                            unchanged
                            ( \_ unchangedReceipt change ->
                                (change, operationKey, ownershipReceiptOperationKey unchangedReceipt)
                            )
                            (\_ _ -> error "matching prior commit must remain managed")
        )
        (\_ _ -> Left (Failure (FailureDetail "test unchanged" "created alias became foreign" DoNotRetry)))

projectionSummary :: Either ReconcileError Text.Text
projectionSummary =
    withTestLifecyclePlan $ \plan ->
        joinReconcile $
            withPlannedResourceOfKind plan ProviderResourceKind "core:deploy-vm" $ \provider ->
                joinReconcile $
                    withPlannedResourceOfKind plan DurableShareResourceKind "core:copy-source" $ \share ->
                        withProviderGuestAliasProjection plan provider share $ \alias _ ->
                            plannedResourceKey alias

withPreparedAliasFixture ::
    Word64 ->
    ( forall planId aliasId shareId operationKey callDigest attempt journalVersion.
      LifecyclePlan FixtureScope planId ->
      ResourceHandle
        FixtureScope
        planId
        aliasId
        DurableAliasResource
        Unclassified
        Observed ->
      PreparedGuestAliasCall
        FixtureScope
        planId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      Either ReconcileError summary
    ) ->
    IO (Either ReconcileError summary)
withPreparedAliasFixture = withPreparedAliasFixtureFor aliasSpec

withPreparedAliasFixtureFor ::
    GuestAliasSpec ->
    Word64 ->
    ( forall planId aliasId shareId operationKey callDigest attempt journalVersion.
      LifecyclePlan FixtureScope planId ->
      ResourceHandle
        FixtureScope
        planId
        aliasId
        DurableAliasResource
        Unclassified
        Observed ->
      PreparedGuestAliasCall
        FixtureScope
        planId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      Either ReconcileError summary
    ) ->
    IO (Either ReconcileError summary)
withPreparedAliasFixtureFor spec shareObservationVersion consume =
    case fixtureAction of
        Left err -> pure (Left err)
        Right action -> action
  where
    fixtureAction =
        withTestLifecyclePlan $ \plan ->
            joinReconcile $
                withPlannedResourceOfKind plan ProviderResourceKind "core:deploy-vm" $ \provider ->
                    joinReconcile $
                        withPlannedResourceOfKind plan DurableShareResourceKind "core:copy-source" $ \share ->
                            joinReconcile $
                                withManagedProvider plan provider $ \managedProvider ->
                                    joinReconcile $
                                        withManagedShare plan share managedProvider $ \managedShare ->
                                            joinReconcile $
                                                withProviderGuestAliasProjection plan provider share $ \alias edge ->
                                                    withObservedPlannedResource plan alias 23 29 $ \aliasHandle ->
                                                        runReadyProbe
                                                            plan
                                                            share
                                                            alias
                                                            edge
                                                            aliasHandle
                                                            managedShare

    runReadyProbe plan share alias edge aliasHandle managedShare =
        case withBackendProbe
            DurableShareProbe
            share
            11
            19
            shareObservationVersion
            (const (pure (ProbeReady ())))
            ( \probe -> do
                readyResult <-
                    awaitPlanReady
                        rolloutPoll
                        "durable share"
                        probe
                        (error "the injected probe does not inspect HostConfig" :: HostConfig)
                pure $ case readyResult of
                    Left pollError ->
                        Left
                            ( Failure
                                ( FailureDetail
                                    "await durable share"
                                    (Text.pack (renderPollError pollError))
                                    DoNotRetry
                                )
                            )
                    Right ready ->
                        joinReconcile $
                            withPreparedGuestAliasCall
                                alias
                                edge
                                aliasHandle
                                managedShare
                                ready
                                spec
                                1
                                37
                                (consume plan aliasHandle)
            ) of
            Left constructionError ->
                pure
                    ( Left
                        ( Failure
                            ( FailureDetail
                                "construct durable-share probe"
                                (Text.pack (show constructionError))
                                DoNotRetry
                            )
                        )
                    )
            Right action -> action

withManagedProvider ::
    LifecyclePlan FixtureScope planId ->
    PlannedResource FixtureScope planId providerId ProviderResource providerFrame ->
    ( ResourceHandle
        FixtureScope
        planId
        providerId
        ProviderResource
        Managed
        Provisioned ->
      result
    ) ->
    Either ReconcileError result
withManagedProvider plan planned consume =
    joinReconcile $
        withObservedPlannedResource plan planned 5 7 $ \observed -> do
            descriptor <- plannedOperation plan planned observed "provider:create"
            joinReconcile $
                withPreparedOperation descriptor [] 1 3 $ \prepared preconditions -> do
                    reconciled <-
                        completeReconcile
                            observed
                            prepared
                            preconditions
                            (BackendCreated 5)
                    withReconcileResult
                        reconciled
                        (\managed _ _ -> Right (consume managed))
                        (\_ _ -> Left (Failure (FailureDetail "test provider" "unexpected foreign provider" DoNotRetry)))

withManagedShare ::
    LifecyclePlan FixtureScope planId ->
    PlannedResource FixtureScope planId shareId DurableShareResource shareFrame ->
    ResourceHandle
        FixtureScope
        planId
        providerId
        ProviderResource
        Managed
        Provisioned ->
    ( ResourceHandle
        FixtureScope
        planId
        shareId
        DurableShareResource
        Managed
        Provisioned ->
      result
    ) ->
    Either ReconcileError result
withManagedShare plan planned managedProvider consume =
    joinReconcile $
        withObservedPlannedResource plan planned 11 13 $ \observed -> do
            descriptor <- plannedOperation plan planned observed "share:mount"
            providerObservation <- dependencyObservation managedProvider 17
            joinReconcile $
                withPreparedSingleDependencyOperation
                    descriptor
                    providerObservation
                    1
                    9
                    ( \prepared preconditions -> do
                        reconciled <-
                            completeReconcile
                                observed
                                prepared
                                preconditions
                                (BackendCreated 11)
                        withReconcileResult
                            reconciled
                            (\managed _ _ -> Right (consume managed))
                            (\_ _ -> Left (Failure (FailureDetail "test durable share" "unexpected foreign share" DoNotRetry)))
                    )

testPlan :: StepPlan
testPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ deployVMStep "provider" (StepFrame "host" "Host") (const (pure ()))
            , copySourceStep "durable share" (StepFrame "provider" "Provider") (const (pure ()))
            ]
        )

withTestLifecyclePlan ::
    (forall planId. LifecyclePlan FixtureScope planId -> result) ->
    result
withTestLifecyclePlan consume =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec testPlan consume

testProvider :: SubstrateProvider
testProvider =
    either
        (error . ("selectSubstrateProvider failed: " ++))
        id
        ( selectSubstrateProvider
            (Substrate LinuxCpu Amd64)
            VMHandles
                { vmhIncus = IncusVM "test-vm" "images:ubuntu/24.04"
                , vmhLima = LimaVM "test-vm"
                , vmhWsl2 = Wsl2VM "test-vm"
                , vmhGuardPrefix = "test"
                , vmhWslConfigPath = "C:\\Users\\test\\.wslconfig"
                }
        )

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id

isLeft :: Either left right -> Bool
isLeft = either (const True) (const False)
