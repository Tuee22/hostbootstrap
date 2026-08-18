{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ClusterReconcileSpec (tests, FixtureScope, withClusterFixtureM, withHarnessClusterFixtureM, withPlannedClusterFixture) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List (isSuffixOf)
import qualified Data.Text as Text
import Data.Foldable (find)
import Data.IORef (newIORef, atomicModifyIORef')
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Backend
import HostBootstrap.Cluster.Backend.Internal
    ( ClusterCommandResult (..)
    , ClusterExec (..)
    , discoverInjectedStrongClusterBackend
    )
import HostBootstrap.Cluster.Cordon
    ( budgetCpu
    , budgetMemoryBytes
    , budgetStorageBytes
    , mkResourceBudget
    )
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Docker, Python3), mkAbsExe)
import PlatformPath (hostFixturePath)
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lift (localContext)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Reconcile
import HostBootstrap.Substrate (Arch (Arm64), Substrate (..), SubstrateName (LinuxCpu))
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile
import HostBootstrap.Step
import PrepareFixture (gateFor)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

type FixtureScope = Production Fixture.FixtureProject

gib :: Integer
gib = 1024 ^ (3 :: Integer)

exactEnvelope :: ResourceEnvelope
exactEnvelope = ResourceEnvelope 8 "16GiB" "100GiB"

type ClusterPreparedConsumer summary =
    forall projectId specDigest planId configId clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion.
    PreparedClusterReconcile
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig
        clusterId
        clusterFrame
        providerId
        providerFrame
        budgetId
        provider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO (Either ReconcileError summary)

type ClusterPlanPreparedConsumer summary =
    forall projectId specDigest planId configId clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion.
    ProjectPlan.ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
    PreparedClusterReconcile
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig
        clusterId
        clusterFrame
        providerId
        providerFrame
        budgetId
        provider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO (Either ReconcileError summary)

type HarnessClusterPreparedConsumer summary =
    forall projectId runId specDigest planId configId clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion.
    PreparedClusterReconcile
        (Harness projectId runId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig
        clusterId
        clusterFrame
        providerId
        providerFrame
        budgetId
        provider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO (Either ReconcileError summary)

tests :: TestTree
tests = testGroup "ClusterReconcileSpec" (packageCases <> inFrameReconcileCases)

{- | Preparation and projection: what the plan hands the backend.

These read the exact package the plan projects and reach no cluster spec, so
they hold as ordinary static assertions on every supported outer host
realization (§ JJ).
-}
packageCases :: [TestTree]
packageCases =
        [ testCase "preparation projects the complete exact cluster package" $
            withClusterFixture (pure . packageSummary) >>= \case
                Right (name, stateDirectory, durableRoot, ports, placement, providerKey, owner, budget) -> do
                    assertBool "the plan projects a non-empty cluster name" (not (null name))
                    assertBool "the state directory is below the retained root" (durableRoot /= stateDirectory)
                    ports @?= True
                    placement @?= ("host", "provider")
                    providerKey @?= "core:deploy-vm"
                    assertBool "ownership is derived from a stable digest and resource" ("core:deploy-kind" `Text.isSuffixOf` owner)
                    budget @?= (6, 10 * gib, 80 * gib)
                other -> assertFailure ("expected an exact prepared package, got " ++ show other)
        , testCase "Production preparation binds the exact plan-derived config digest" $
            withClusterFixture (\prepared -> pure (Right (preparedClusterConfigPath prepared, preparedClusterConfigDigest prepared))) >>= \case
                Right (Just path, Just digest) -> do
                    assertBool "config path is kind.yaml" ("kind.yaml" `isSuffixOf` path)
                    assertBool "SHA-256 is lowercase hex" (Text.length digest == 64)
                other -> assertFailure ("expected a bound config path/digest, got " ++ show other)
        , testCase "a real Harness plan retains its run key and omits Production config/ports" $
            harnessPackageSummary >>= \case
                Right (profileName, name, durableRoot, configPath, ports) -> do
                    assertBool "fixture admitted a real Harness profile" ("harness:run-" `Text.isPrefixOf` profileName)
                    let runKey = Text.drop (Text.length "harness:") profileName
                    assertBool "cluster name retains the exact Harness run key" (Text.unpack runKey `isSuffixOf` name)
                    assertBool "durable root retains the exact Harness run key" (Text.unpack runKey `isSuffixOf` durableRoot)
                    configPath @?= Nothing
                    ports @?= False
                other -> assertFailure ("expected exact Harness package, got " ++ show other)
        , testCase "an unverifiable same-named cluster fails closed" $
            withClusterFixture (\prepared -> asError prepared "FAILED kubectl-timeout\n") >>= \case
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected a typed failure, got " ++ show other)
        , testCase "the exact provider probe is run internally before preparation is offered" $
            withClusterFixtureUsing
                (pure (Left (Failure (FailureDetail "probe provider" "vm stopped answering" ReprobeBeforeRetry))))
                (pure . const (Right ()))
                >>= \case
                    Left (Failure detail) -> do
                        failedOperation detail @?= "reprobe Direct provider provisioning egress"
                        assertBool
                            "the retained backend probe surfaces its injected failure"
                            ("probe provider" `Text.isInfixOf` failureCause detail)
                    other -> assertFailure ("expected the provider probe failure, got " ++ show other)
        ]

{- | Settlement, readiness, and cleanup: what the backend does with that package.

Each of these admits a 'ClusterSpec', whose state directory is the path the
locked ownership program receives inside the realized Linux substrate. Its
absoluteness check is POSIX for that reason, and the production resolved backend
is itself Linux-only, so the frame these assert about is Linux wherever the
outer host is. The fixture's project root is the outer host's own canonical
root, so a native Windows process cannot present one: it is not a frame that can
hold a cluster. Skipped there rather than failed (§ JJ), because the contract is
unchanged and the gate that proves it is the `linux-cpu` one.
-}
inFrameReconcileCases :: [TestTree]
#if defined(mingw32_HOST_OS)
inFrameReconcileCases = []
#else
inFrameReconcileCases =
        [ testCase "an absent cluster is created and managed" $
            withClusterFixture settleCreated >>= \case
                Right (Changed Created, operationKey) ->
                    assertBool "the receipt carries a real operation key" (not (Text.null operationKey))
                other -> assertFailure ("expected managed creation, got " ++ show other)
        , testCase "a created backend identity stays separate from the prepared journal generation" $
            withClusterFixture createdIdentityWins >>= \case
                Right (managedGeneration, preparedGeneration, observationVersion) -> do
                    managedGeneration @?= preparedGeneration
                    assertBool "the plan-derived generation is positive" (managedGeneration > 0)
                    assertBool "the gate-derived observation version is positive" (observationVersion > 0)
                other -> assertFailure ("expected stable plan/gate-derived identity, got " ++ show other)
        , testCase "a same-named cluster without the exact origin is foreign, never adopted" $
            withClusterFixture settleForeign >>= \case
                Right identity -> identity @?= "core:deploy-kind"
                other -> assertFailure ("expected a foreign observation, got " ++ show other)
        , testCase "an origin-verified healthy cluster repairs post-effect/pre-commit recovery" $
            withClusterFixture settleHealthyRecovery >>= \case
                Right (Changed Repaired) -> pure ()
                other -> assertFailure ("expected a managed repair, got " ++ show other)
        , testCase "an origin-verified healthy cluster with a matching commit proof is unchanged" $
            withClusterPlanFixtureM settleHealthyPriorCommit >>= \case
                Right Unchanged -> pure ()
                other -> assertFailure ("expected a prior-commit rebind, got " ++ show other)
        , testCase "a no-origin cluster stays foreign even when a commit proof is supplied" $
            withClusterPlanFixtureM settleForeignWithPriorCommit >>= \case
                Right identity -> identity @?= "core:deploy-kind"
                other -> assertFailure ("expected a foreign no-origin observation, got " ++ show other)
        , testCase "an unhealthy same-named cluster is a Conflict, never deleted" $
            withClusterFixture (\prepared -> asError prepared "UNHEALTHY unhealthy-node\n") >>= \case
                Left (Conflict detail) ->
                    assertBool "the conflict refuses auto-delete" ("never auto-deleted" `Text.isInfixOf` conflictRemedy detail)
                other -> assertFailure ("expected a conflict, got " ++ show other)
        , testCase "ownership reports require one LF-terminated line and empty stderr" $
            withClusterFixture strictOwnershipReportCases >>= \case
                Right (True, True, True) -> pure ()
                other -> assertFailure ("expected strict ownership report refusals, got " ++ show other)
        , testCase "readiness evidence is unavailable until the managed generation is ready" $
            withClusterFixture readinessCases >>= \case
                Right (notReadyRefused, readyOffered) -> do
                    notReadyRefused @?= True
                    readyOffered @?= True
                other -> assertFailure ("expected readiness ordering, got " ++ show other)
        , testCase "same-identity not-ready retries while a replacement is a Conflict" $
            withClusterFixture readinessIdentityCases >>= \case
                Right (sameIdentityFailure, replacementConflict, cordonConflict) -> do
                    sameIdentityFailure @?= True
                    replacementConflict @?= True
                    cordonConflict @?= True
                other -> assertFailure ("expected identity-sensitive readiness, got " ++ show other)
        , testCase "readiness dependency probes rerun the real backend and return only fresh successful versions" $
            withClusterFixture freshReadinessReprobeCases >>= \case
                Right (versionAdvanced, unreadyFailed, replacementConflicted, probeFailed) -> do
                    versionAdvanced @?= True
                    unreadyFailed @?= True
                    replacementConflicted @?= True
                    probeFailed @?= True
                other -> assertFailure ("expected fresh backend-bound readiness results, got " ++ show other)
        , testCase "cleanup retains the exact package and refuses a replacement" $
            withClusterFixture cleanupCases >>= \case
                Right (removed, replaced) -> do
                    removed @?= Right ()
                    case replaced of
                        Left (Conflict _) -> pure ()
                        other -> assertFailure ("expected a cleanup conflict, got " ++ show other)
                other -> assertFailure ("expected cleanup outcomes, got " ++ show other)
        ]
#endif

packageSummary ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (String, FilePath, FilePath, Bool, (Text.Text, Text.Text), Text.Text, Text.Text, (Integer, Integer, Integer))
packageSummary prepared =
    let budget = preparedClusterBudget prepared
     in Right
            ( preparedClusterName prepared
            , preparedClusterStateDirectory prepared
            , preparedClusterDurableRoot prepared
            , preparedClusterPublishesHostPorts prepared
            , preparedClusterPlacement prepared
            , preparedClusterProviderKey prepared
            , preparedClusterOwnershipIdentity prepared
            , ( toInteger (budgetCpu budget)
              , budgetMemoryBytes budget
              , budgetStorageBytes budget
              )
            )

#if !defined(mingw32_HOST_OS)
settleCreated ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (ChangeView, Text.Text))
settleCreated prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "node-a"] $ \backend -> do
        result <- runClusterReconcileCall backend prepared
        pure $ do
            settled <- settleClusterReconcile Nothing prepared result
            pure $
                withClusterReconcileSettlement
                    settled
                    (\_ receipt change -> (change, ownershipReceiptOperationKey receipt))
                    (\_ _ _ _ -> error "a created cluster must be managed")

settleForeign ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError Text.Text)
settleForeign prepared =
    withStrongClusterReports ["FOREIGN foreign-node\n"] $ \backend -> do
        result <- runClusterReconcileCall backend prepared
        pure $ do
            settled <- settleClusterReconcile Nothing prepared result
            pure $
                withClusterReconcileSettlement
                    settled
                    (\_ _ _ -> error "a no-origin cluster must not be adopted")
                    (\_ _ _ foreignState -> foreignIdentity foreignState)

settleHealthyRecovery ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ChangeView)
settleHealthyRecovery prepared =
    withStrongClusterReports [ownedClusterReport "HEALTHY" "node-a"] $ \backend -> do
        result <- runClusterReconcileCall backend prepared
        pure $ do
            settled <- settleClusterReconcile Nothing prepared result
            withClusterReconcileSettlement
                settled
                (\_ _ change -> Right change)
                (\_ _ _ _ -> Left (fixtureFailure "origin-verified healthy cluster became foreign"))

settleHealthyPriorCommit ::
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ChangeView)
settleHealthyPriorCommit plan prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "node-a", ownedClusterReport "HEALTHY" "node-a"] $ \backend -> do
        createdResult <- runClusterReconcileCall backend prepared
        case settleClusterReconcile Nothing prepared createdResult of
            Left err -> pure (Left err)
            Right created ->
                withClusterReconcileSettlement
                    created
                    ( \_managed receipt _change -> do
                        healthyResult <- runClusterReconcileCall backend prepared
                        pure $ do
                            proof <- matchingClusterPriorCommit plan prepared receipt
                            settled <- settleClusterReconcile (Just proof) prepared healthyResult
                            withClusterReconcileSettlement
                                settled
                                (\_ _ change -> Right change)
                                (\_ _ _ _ -> Left (fixtureFailure "origin-verified healthy cluster became foreign"))
                    )
                    (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

settleForeignWithPriorCommit ::
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError Text.Text)
settleForeignWithPriorCommit plan prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "node-a", "FOREIGN foreign-node\n"] $ \backend -> do
        createdResult <- runClusterReconcileCall backend prepared
        case settleClusterReconcile Nothing prepared createdResult of
            Left err -> pure (Left err)
            Right created ->
                withClusterReconcileSettlement
                    created
                    ( \_managed receipt _change -> do
                        foreignResult <- runClusterReconcileCall backend prepared
                        pure $ do
                            proof <- matchingClusterPriorCommit plan prepared receipt
                            settled <- settleClusterReconcile (Just proof) prepared foreignResult
                            pure $
                                withClusterReconcileSettlement
                                    settled
                                    (\_ _ _ -> error "a no-origin cluster must not be adopted")
                                    (\_ _ _ foreignState -> foreignIdentity foreignState)
                    )
                    (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

matchingClusterPriorCommit ::
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    OwnershipReceipt scope planId clusterId ClusterResource ->
    Either ReconcileError (PriorCommitProof scope planId clusterId ClusterResource)
matchingClusterPriorCommit plan prepared receipt = do
    let lifecycle = lifecyclePlanFromProjectPlan plan
        handle = preparedClusterReconcileHandle prepared
    verified <-
        verifyPersistedJournalRecord
            lifecycle
            handle
            "acquire"
            PersistedJournalRecord
                { persistedPlanDigest = lifecyclePlanDigest lifecycle
                , persistedFrameKey = "provider"
                , persistedResourceKey = resourceHandleKey handle
                , persistedGeneration = resourceHandleGeneration handle
                , persistedOperation = "acquire"
                , persistedOperationKey = ownershipReceiptOperationKey receipt
                , persistedRecordVersion = 1
                , persistedPhase = Committed
                }
    withPriorCommitProof verified id
#endif

asError ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    String ->
    IO (Either ReconcileError ())
asError prepared report =
    withStrongClusterReports [report] $ \backend -> do
        result <- runClusterReconcileCall backend prepared
        pure (settleClusterReconcile Nothing prepared result >> Right ())

#if !defined(mingw32_HOST_OS)
strictOwnershipReportCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool, Bool))
strictOwnershipReportCases prepared = do
    let valid = ownedClusterReport "CREATED" "node-a"
        refused result =
            withStrongClusterCommandResults [result] $ \backend -> do
                observed <- runClusterReconcileCall backend prepared
                pure $ case clusterReconcileResultView observed of
                    ClusterResultProbeFailed _ -> True
                    _ -> False
    missingLf <- refused (ClusterCommandResult True (init valid) "")
    carriageReturn <- refused (ClusterCommandResult True (init valid ++ "\r\n") "")
    stderrPresent <- refused (ClusterCommandResult True valid "unexpected warning\n")
    pure (Right (missingLf, carriageReturn, stderrPresent))

readinessCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool))
readinessCases prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "node-a", "APPLIED\n", "NOTREADY node-a\n", "READY node-a\n"] $ \backend -> do
        createdResult <- runClusterReconcileCall backend prepared
        case settleClusterReconcile Nothing prepared createdResult of
            Left err -> pure (Left err)
            Right created ->
                withClusterReconcileSettlement
                    created
                    ( \managed _receipt _ ->
                        case withPreparedClusterCordon prepared managed id of
                            Left err -> pure (Left err)
                            Right cordon -> do
                                cordonResult <- runClusterCordonCall backend cordon
                                case settleClusterCordon cordon cordonResult of
                                    Left err -> pure (Left err)
                                    Right applied -> do
                                        notReady <- runClusterReadinessCall backend applied
                                        ready <- runClusterReadinessCall backend applied
                                        let notReadyRefused = case settleClusterReadiness applied notReady of
                                                Left _ -> True
                                                Right _ -> False
                                            readyOffered = case settleClusterReadiness applied ready of
                                                Left _ -> False
                                                Right evidence -> clusterReadinessProbe evidence `seq` True
                                        pure (Right (notReadyRefused, readyOffered))
                    )
                    (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

readinessIdentityCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool, Bool))
readinessIdentityCases prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "node-a", "APPLIED\n", "NOTREADY node-a\n", "NOTREADY node-b\n", "REPLACED node-b\n"] $ \backend -> do
        createdResult <- runClusterReconcileCall backend prepared
        case settleClusterReconcile Nothing prepared createdResult of
            Left err -> pure (Left err)
            Right created ->
                withClusterReconcileSettlement
                    created
                    ( \managed _receipt _ ->
                        case withPreparedClusterCordon prepared managed id of
                            Left err -> pure (Left err)
                            Right cordon -> do
                                cordonResult <- runClusterCordonCall backend cordon
                                case settleClusterCordon cordon cordonResult of
                                    Left err -> pure (Left err)
                                    Right applied -> do
                                        sameIdentity <- runClusterReadinessCall backend applied
                                        replacement <- runClusterReadinessCall backend applied
                                        replacementCordon <- runClusterCordonCall backend cordon
                                        let sameIdentityFailure = case settleClusterReadiness applied sameIdentity of
                                                Left (Failure _) -> True
                                                _ -> False
                                            replacementConflict = case settleClusterReadiness applied replacement of
                                                Left (Conflict _) -> True
                                                _ -> False
                                            cordonConflict = case settleClusterCordon cordon replacementCordon of
                                                Left (Conflict _) -> True
                                                _ -> False
                                        pure (Right (sameIdentityFailure, replacementConflict, cordonConflict))
                    )
                    (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

freshReadinessReprobeCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool, Bool, Bool))
freshReadinessReprobeCases prepared =
    withStrongClusterReports
        [ ownedClusterReport "CREATED" "node-a"
        , "APPLIED\n"
        , "READY node-a\n"
        , "READY node-a\n"
        , "NOTREADY node-a\n"
        , "NOTREADY node-b\n"
        , "FAILED node-query\n"
        ]
        $ \backend -> do
            createdResult <- runClusterReconcileCall backend prepared
            case settleClusterReconcile Nothing prepared createdResult of
                Left err -> pure (Left err)
                Right created ->
                    withClusterReconcileSettlement
                        created
                        ( \managed _receipt _ ->
                            case withPreparedClusterCordon prepared managed id of
                                Left err -> pure (Left err)
                                Right cordon -> do
                                    cordonResult <- runClusterCordonCall backend cordon
                                    case settleClusterCordon cordon cordonResult of
                                        Left err -> pure (Left err)
                                        Right applied -> do
                                            initial <- runClusterReadinessCall backend applied
                                            case settleClusterReadiness applied initial of
                                                Left err -> pure (Left err)
                                                Right evidence -> do
                                                    fresh <- reprobeClusterReadiness evidence
                                                    unready <- reprobeClusterReadiness evidence
                                                    replacement <- reprobeClusterReadiness evidence
                                                    failed <- reprobeClusterReadiness evidence
                                                    let initialVersion = case clusterReadinessResultView initial of
                                                            ClusterReadinessResultReady version _ -> version
                                                            _ -> 0
                                                        versionAdvanced = case fresh of
                                                            Right version -> version > initialVersion
                                                            Left _ -> False
                                                        unreadyFailed = case unready of
                                                            Left (Failure _) -> True
                                                            _ -> False
                                                        replacementConflicted = case replacement of
                                                            Left (Conflict _) -> True
                                                            _ -> False
                                                        probeFailed = case failed of
                                                            Left (Failure _) -> True
                                                            _ -> False
                                                    pure (Right (versionAdvanced, unreadyFailed, replacementConflicted, probeFailed))
                        )
                        (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

createdIdentityWins ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Word64, Word64, Word64))
createdIdentityWins prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "backend-identity-99"] $ \backend -> do
        result <- runClusterReconcileCall backend prepared
        pure $ do
            created <- settleClusterReconcile Nothing prepared result
            withClusterReconcileSettlement
                created
                ( \managed _ _ ->
                    let observed = preparedClusterReconcileHandle prepared
                     in Right
                            ( managedClusterGeneration managed
                            , resourceHandleGeneration observed
                            , resourceHandleObservationVersion observed
                            )
                )
                (\_ _ _ _ -> Left (fixtureFailure "created cluster became foreign"))

cleanupCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Either ReconcileError (), Either ReconcileError ()))
cleanupCases prepared =
    withStrongClusterReports [ownedClusterReport "CREATED" "node-a", "REMOVED\n", "REPLACED replacement-node\n"] $ \backend -> do
        createdResult <- runClusterReconcileCall backend prepared
        case settleClusterReconcile Nothing prepared createdResult of
            Left err -> pure (Left err)
            Right created ->
                withClusterReconcileSettlement
                    created
                    ( \managed _receipt _ ->
                        case withPreparedClusterCleanup prepared managed id of
                            Left err -> pure (Left err)
                            Right cleanup -> do
                                removed <- runClusterCleanupCall backend cleanup
                                replaced <- runClusterCleanupCall backend cleanup
                                pure
                                    ( Right
                                        ( settleClusterCleanup cleanup removed
                                        , settleClusterCleanup cleanup replaced
                                        )
                                    )
                    )
                    (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

ownedClusterReport :: String -> String -> String
ownedClusterReport status identity =
    unwords
        [ status
        , identity
        , "1"
        , "2"
        , "3"
        , "4"
        , "5"
        , "6"
        , replicate 64 'a'
        ]
        ++ "\n"
#endif

withStrongClusterReports :: [String] -> (StrongClusterBackend -> IO result) -> IO result
withStrongClusterReports reports =
    withStrongClusterCommandResults (map (\report -> ClusterCommandResult True report "") reports)

withStrongClusterCommandResults :: [ClusterCommandResult] -> (StrongClusterBackend -> IO result) -> IO result
withStrongClusterCommandResults reports consume = do
    pending <- newIORef reports
    let executor =
            ClusterExec $ \arguments ->
                case arguments of
                    "sh" : "-c" : _ ->
                        pure
                            ( ClusterCommandResult
                                True
                                "HB_CLUSTER_TOOLS_V1\n/usr/bin/flock\n/usr/bin/python3\n"
                                ""
                            )
                    _ -> do
                        next <-
                            atomicModifyIORef' pending $ \remaining ->
                                case remaining of
                                    [] -> ([], Nothing)
                                    report : rest -> (rest, Just report)
                        pure $ case next of
                            Just report -> report
                            Nothing -> ClusterCommandResult False "" "unexpected extra strong-cluster call"
    discovered <-
        discoverInjectedStrongClusterBackend
            executor
            -- The injected cluster tools are in-frame paths, not host paths:
            -- the driver, runtime, and kubectl this backend names are files
            -- inside the realized Linux substrate, reached from there. They stay
            -- POSIX on every outer host, and the backend's own absoluteness
            -- check is POSIX for the same reason.
            "/test/bin/kind"
            "/test/bin/docker"
            "/test/bin/kubectl"
    either (fail . show) consume discovered

withPlannedClusterFixture ::
    ( forall projectId planId clusterId clusterFrame.
      PlannedResource (Production projectId) planId clusterId ClusterResource clusterFrame ->
      Either ReconcileError result
    ) ->
    IO (Either ReconcileError result)
withPlannedClusterFixture consume =
    Fixture.withFixtureProjectPlan testPlan $ \projectPlan -> do
        clusterKey <- requireOperationKey "core:deploy-kind" projectPlan
        requirePlanProjection $
            ProjectPlan.withPlannedResourceOfKind
                projectPlan
                ProjectPlan.ClusterResourceKind
                clusterKey
                consume

withClusterFixtureM ::
    ClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureM =
    withClusterFixtureUsingM (pure (Right 23))

#if !defined(mingw32_HOST_OS)
withClusterPlanFixtureM ::
    ClusterPlanPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterPlanFixtureM =
    withClusterFixtureUsingPlanM (pure (Right 23))
#endif

withHarnessClusterFixtureM ::
    HarnessClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withHarnessClusterFixtureM consume =
    Fixture.withFixtureHarnessProjectPlan testPlan $ \plan -> do
        let planDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
        providerGate <- gateFor planDigest "core:deploy-vm"
        clusterGate <- gateFor planDigest "core:deploy-kind"
        providerKey <- requireOperationKey "core:deploy-vm" plan
        clusterKey <- requireOperationKey "core:deploy-kind" plan
        projected <-
            requirePlanProjection $
                ProjectPlan.withPlannedResourceOfKind
                    plan
                    ProjectPlan.ProviderResourceKind
                    providerKey
                    ( \provider ->
                        ProjectPlan.withPlannedResourceOfKind
                            plan
                            ProjectPlan.ClusterResourceKind
                            clusterKey
                            ( \cluster ->
                                prepareExactFixture
                                    (pure (Right 23))
                                    providerGate
                                    clusterGate
                                    plan
                                    provider
                                    cluster
                                    consume
                            )
                    )
        action <- requirePlanProjection projected
        action

withClusterFixture ::
    ClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixture = withClusterFixtureM

withClusterFixtureUsing ::
    IO (Either ReconcileError Word64) ->
    ClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureUsing = withClusterFixtureUsingM

withClusterFixtureUsingM ::
    IO (Either ReconcileError Word64) ->
    ClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureUsingM providerProbeResult consume =
    withClusterFixtureUsingPlanM providerProbeResult (\_plan prepared -> consume prepared)

withClusterFixtureUsingPlanM ::
    IO (Either ReconcileError Word64) ->
    ClusterPlanPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureUsingPlanM providerProbeResult consume =
    Fixture.withFixtureProjectPlan testPlan $ \plan -> do
        let planDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
        providerGate <- gateFor planDigest "core:deploy-vm"
        clusterGate <- gateFor planDigest "core:deploy-kind"
        providerKey <- requireOperationKey "core:deploy-vm" plan
        clusterKey <- requireOperationKey "core:deploy-kind" plan
        projected <-
            requirePlanProjection $
                ProjectPlan.withPlannedResourceOfKind
                    plan
                    ProjectPlan.ProviderResourceKind
                    providerKey
                    ( \provider ->
                        ProjectPlan.withPlannedResourceOfKind
                            plan
                            ProjectPlan.ClusterResourceKind
                            clusterKey
                            ( \cluster ->
                                prepareExactFixture
                                    providerProbeResult
                                    providerGate
                                    clusterGate
                                    plan
                                    provider
                                    cluster
                                    (consume plan)
                            )
                    )
        action <- requirePlanProjection projected
        action

prepareExactFixture ::
    IO (Either ReconcileError Word64) ->
    PreparedGate ->
    PreparedGate ->
    ProjectPlan.ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    ( forall budgetId capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion.
      PreparedClusterReconcile
        scope
        specDigest
        planId
        configId
        Fixture.ProjectConfig
        clusterId
        clusterFrame
        providerId
        providerFrame
        budgetId
        LimaProvider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        operationKey
        callDigest
        attempt
        journalVersion ->
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
prepareExactFixture providerProbeResult providerGate clusterGate plan provider cluster consume =
    withRunningProviderDependencyFixture providerProbeResult providerGate plan provider $ \runningProvider -> do
        let root = ProjectPlan.stablePlanSnapshotRoot (ProjectPlan.renderSnapshot plan)
            configPath = root </> "kind.yaml"
        createDirectoryIfMissing True (takeDirectory configPath)
        writeFile configPath "kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\n"
        workload <- requireBudget (mkWorkload cluster 1 1 gib gib)
        overhead <- requireString (mkResourceBudget 1 gib gib)
        sliceBudget <- requireString (mkResourceBudget 6 (10 * gib) (80 * gib))
        minimumBudget <- requireString (mkResourceBudget 1 gib gib)
        request <- requireBudget (mkSliceRequest cluster sliceBudget minimumBudget)
        let budgetAction =
                joinBudget $
                    withValidatedBudget plan exactEnvelope $ \validated ->
                        withProviderBudgetCapability plan provider LimaProviderKey $ \capability ->
                            joinBudget $
                                admitProviderBudget validated capability $ \_wall effective ->
                                    joinBudget $
                                        withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                            fit <- verifyPlannedWorkloadFit effective workloads
                                            joinBudget $
                                                withBudgetPartition effective fit overhead (request :| []) $ \_partition slices ->
                                                    withResourceSliceFor cluster slices $ \slice ->
                                                        withPreparedClusterReconcile
                                                            plan
                                                            cluster
                                                            provider
                                                            (ProjectPlan.topology plan)
                                                            slice
                                                            runningProvider
                                                            clusterGate
                                                            consume
        case budgetAction of
            Left err -> pure (Left (fixtureFailure (Text.pack (show err))))
            Right action -> do
                prepared <- action
                either (pure . Left) id prepared

withRunningProviderDependencyFixture ::
    IO (Either ReconcileError Word64) ->
    PreparedGate ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    (RunningProviderDependency scope planId providerId -> IO (Either ReconcileError result)) ->
    IO (Either ReconcileError result)
withRunningProviderDependencyFixture reprobeResult gate plan planned consume = do
    manifestCount <- newIORef (0 :: Int)
    let providerExec =
            ProviderBackendExec
                { runProviderBackendExec = \request ->
                    case providerBackendRequestView request of
                        ProviderBackendProcess executable _argv
                            | executable == fixturePython -> pure providerSuccess
                            | executable == fixtureDocker -> do
                                invocation <- atomicModifyIORef' manifestCount (\count -> let next = count + 1 in (next, next))
                                if invocation == 1
                                    then pure (providerSuccessWith "{}")
                                    else do
                                        reprobed <- reprobeResult
                                        pure $ case reprobed of
                                            Right _ -> providerSuccessWith "{}"
                                            Left err -> RawProviderFailure (show err)
                            | otherwise -> pure (RawProviderFailure "unexpected Direct-provider executable")
                , waitProviderBackendExec = \_ -> pure ()
                }
    case mkDirectHostBackendSpec providerHostConfig "/srv/hostbootstrap/data" "alpine:3.22" of
        Left err -> pure (Left err)
        Right backendSpec -> do
            discovered <-
                discoverStrongProviderBackend providerExec backendSpec $ \backend -> do
                    carrier <- Execution.newResourceCarrier
                    runtime <- Execution.newStepRuntime carrier
                    providerNode <-
                        maybe
                            (fail "cluster fixture lacks provider node")
                            pure
                            (find ((== "core:deploy-vm") . ProjectPlan.operationKeyText . ProjectPlan.plannedStepOperationKey) (ProjectPlan.forward plan))
                    let execution = stepExecutionFor plan providerHostConfig runtime providerNode
                    case withObservedProjectResource plan planned 5 7 id of
                        Left err -> pure (Left err)
                        Right observed ->
                            case
                                withPreparedProviderProvision
                                    execution
                                    (providerBackendBinding backend)
                                    planned
                                    observed
                                    gate
                                    ( \preparedProvision -> do
                                        provisionCall <- runProviderProvisionCall backend preparedProvision
                                        case settleProviderProvision Nothing preparedProvision provisionCall of
                                            Left err -> pure (Left err)
                                            Right provisioned ->
                                                withProviderProvisionSettlement
                                                    provisioned
                                                    ( \managed _ ->
                                                        case
                                                            withPreparedProviderReady
                                                                execution
                                                                planned
                                                                managed
                                                                (providerStartableAfterProvision managed)
                                                                gate
                                                                ( \preparedReady -> do
                                                                    readyCall <- runProviderReadyCall backend preparedReady
                                                                    case settleProviderReady preparedReady readyCall of
                                                                        Left err -> pure (Left err)
                                                                        Right advance ->
                                                                            case withRunningProviderDependency backend advance consume of
                                                                                Left err -> pure (Left err)
                                                                                Right action -> action
                                                                )
                                                            of
                                                            Left err -> pure (Left err)
                                                            Right action -> action
                                                    )
                                                    (\_ _ _ _ -> pure (Left (fixtureFailure "unexpected foreign provider")))
                                    )
                            of
                                Left err -> pure (Left err)
                                Right action -> action
            pure (either Left id discovered)

providerHostConfig :: HostConfig
providerHostConfig =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Arm64
        , hcToolPaths =
            Map.fromList
                [ (Python3, fixtureExe fixturePython)
                , (Docker, fixtureExe fixtureDocker)
                ]
        }

{- | The host tools this suite's fixtures name.

Each is rendered onto the host that runs the suite, so the same total 'AbsExe'
constructor production uses admits it wherever the static gate runs (§ JJ). The
runner dispatch below selects its response by comparing these same values, so a
host-neutral fixture cannot weaken the absolute-backend-path projection guard.
-}
fixturePython, fixtureDocker :: FilePath
fixturePython = hostFixturePath "/test/bin/python3"
fixtureDocker = hostFixturePath "/test/bin/docker"

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

providerSuccess :: RawProviderOutcome
providerSuccess = providerSuccessWith ""

providerSuccessWith :: String -> RawProviderOutcome
providerSuccessWith output = RawProviderExit ExitSuccess output ""

testPlan :: StepPlan
testPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia localContext (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
            , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
            ]
        )

requireOperationKey ::
    Text.Text ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    IO ProjectPlan.OperationKey
requireOperationKey expected projectPlan =
    case find ((== Text.unpack expected) . ProjectPlan.operationKeyText . ProjectPlan.plannedStepOperationKey) (ProjectPlan.forward projectPlan) of
        Just plannedStep -> pure (ProjectPlan.plannedStepOperationKey plannedStep)
        Nothing -> fail ("fixture project plan lacks operation " ++ Text.unpack expected)

requirePlanProjection :: Either ProjectPlan.PlanError value -> IO value
requirePlanProjection = either (fail . show) pure

requireBudget :: Either BudgetError value -> IO value
requireBudget = either (fail . show) pure

requireString :: Either String value -> IO value
requireString = either fail pure

joinBudget :: Either BudgetError (Either BudgetError value) -> Either BudgetError value
joinBudget = either Left id

fixtureFailure :: Text.Text -> ReconcileError
fixtureFailure reason = Failure (FailureDetail "cluster fixture" reason DoNotRetry)

harnessPackageSummary ::
    IO (Either ReconcileError (Text.Text, String, FilePath, Maybe FilePath, Bool))
harnessPackageSummary =
    Fixture.withFixtureHarnessProjectPlan testPlan $ \plan -> do
        let planDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
        providerGate <- gateFor planDigest "core:deploy-vm"
        clusterGate <- gateFor planDigest "core:deploy-kind"
        providerKey <- requireOperationKey "core:deploy-vm" plan
        clusterKey <- requireOperationKey "core:deploy-kind" plan
        projected <-
            requirePlanProjection $
                ProjectPlan.withPlannedResourceOfKind
                    plan
                    ProjectPlan.ProviderResourceKind
                    providerKey
                    ( \provider ->
                        ProjectPlan.withPlannedResourceOfKind
                            plan
                            ProjectPlan.ClusterResourceKind
                            clusterKey
                            ( \cluster ->
                                prepareExactFixture
                                    (pure (Right 23))
                                    providerGate
                                    clusterGate
                                    plan
                                    provider
                                    cluster
                                    ( \prepared ->
                                        pure
                                            ( Right
                                                ( ProjectPlan.projectPlanProfileName plan
                                                , preparedClusterName prepared
                                                , preparedClusterDurableRoot prepared
                                                , preparedClusterConfigPath prepared
                                                , preparedClusterPublishesHostPorts prepared
                                                )
                                            )
                                    )
                            )
                    )
        action <- requirePlanProjection projected
        action
