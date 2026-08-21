{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ClusterReconcileSpec (tests, FixtureScope, withClusterFixtureM, withHarnessClusterFixtureM, withPlannedClusterFixture) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List (isSuffixOf)
import qualified Data.Text as Text
import Data.Foldable (find)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified FakeCluster
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Backend
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
import HostBootstrap.HostTool (AbsExe, HostTool (Docker, Kind, Kubectl, Python3), mkAbsExe)
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lift (localContext)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Protected (
    Expectation (ExpectVersion),
    ProtectedRecord (protectedRecordVersion),
    compareAndDeleteProtectedRecord,
    listProtectedRecords,
    openProtectedStore,
    readProtectedRecord,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile
import HostBootstrap.Substrate (Arch (Arm64), Substrate (..), SubstrateName (LinuxCpu))
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile
import HostBootstrap.Step
import PrepareFixture (gateFor)
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing)
import System.Environment (getExecutablePath)
import System.IO.Temp (withSystemTempDirectory)
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
        , testCase "the exact provider probe is run internally before preparation is offered" $
            withClusterFixtureUsing
                ReprobeStopsAnswering
                (pure . const (Right ()))
                >>= \case
                    Left (Failure detail) -> do
                        failedOperation detail @?= "reprobe Direct provider provisioning egress"
                        assertBool
                            "the retained backend probe surfaces the provider's own diagnostic"
                            ("vm stopped answering" `Text.isInfixOf` failureCause detail)
                    other -> assertFailure ("expected the provider probe failure, got " ++ show other)
        ]

{- | Settlement, readiness, and cleanup: what the backend does with that package.

Each of these runs the real clause-holding driver: a real protected store under
the state directory the plan projects, and a real cluster client process the one
interpreter launches. Nothing is host-specific about either — the store is
ordinary files and the client is this suite's own executable — so the family runs
and is counted on every gate host (§ JJ), and every case reaches its standing by
arranging what the tools report rather than by substituting for a decision
(§ NN).
-}
inFrameReconcileCases :: [TestTree]
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
            withClusterFixture settleUnhealthy >>= \case
                Left (Conflict detail) ->
                    assertBool "the conflict refuses auto-delete" ("never auto-deleted" `Text.isInfixOf` conflictRemedy detail)
                other -> assertFailure ("expected a conflict, got " ++ show other)
        , testCase "a driver that contradicts its own listing fails closed" $
            withClusterFixture settleContradictoryListing >>= \case
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected a typed failure, got " ++ show other)
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

settleCreated ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (ChangeView, Text.Text))
settleCreated prepared =
    withClusterClient prepared $ \backend _root -> do
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
    withClusterClient prepared $ \backend root -> do
        standUpUnclaimedCluster prepared root
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
    withClusterClient prepared $ \backend _root -> do
        _ <- runClusterReconcileCall backend prepared
        result <- runClusterReconcileCall backend prepared
        pure $ do
            settled <- settleClusterReconcile Nothing prepared result
            withClusterReconcileSettlement
                settled
                (\_ _ change -> Right change)
                (\_ _ _ _ -> Left (fixtureFailure "origin-verified healthy cluster became foreign"))

settleUnhealthy ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
settleUnhealthy prepared =
    withClusterClient prepared $ \backend root -> do
        _ <- runClusterReconcileCall backend prepared
        setNodesRunning root False
        result <- runClusterReconcileCall backend prepared
        pure (settleClusterReconcile Nothing prepared result >> Right ())

settleContradictoryListing ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ())
settleContradictoryListing prepared =
    withClusterClient prepared $ \backend root -> do
        FakeCluster.writeClusters root [preparedClusterName prepared, preparedClusterName prepared]
        result <- runClusterReconcileCall backend prepared
        pure (settleClusterReconcile Nothing prepared result >> Right ())

settleHealthyPriorCommit ::
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError ChangeView)
settleHealthyPriorCommit plan prepared =
    withClusterClient prepared $ \backend _root -> do
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
    withClusterClient prepared $ \backend _root -> do
        createdResult <- runClusterReconcileCall backend prepared
        case settleClusterReconcile Nothing prepared createdResult of
            Left err -> pure (Left err)
            Right created ->
                withClusterReconcileSettlement
                    created
                    ( \_managed receipt _change -> do
                        forgetEveryDurableRecord (preparedClusterStateDirectory prepared)
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

readinessCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool))
readinessCases prepared =
    withClusterClient prepared $ \backend root ->
        withAppliedFixtureCordon backend prepared $ \applied -> do
            setNodesRunning root False
            notReady <- runClusterReadinessCall backend applied
            setNodesRunning root True
            ready <- runClusterReadinessCall backend applied
            let notReadyRefused = case settleClusterReadiness applied notReady of
                    Left _ -> True
                    Right _ -> False
                readyOffered = case settleClusterReadiness applied ready of
                    Left _ -> False
                    Right evidence -> clusterReadinessProbe evidence `seq` True
            pure (Right (notReadyRefused, readyOffered))

readinessIdentityCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool, Bool))
readinessIdentityCases prepared =
    withClusterClient prepared $ \backend root ->
        withCordonAndApplied backend prepared $ \cordon applied -> do
            setNodesRunning root False
            sameIdentity <- runClusterReadinessCall backend applied
            setNodesRunning root True
            replaceEveryNode root
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

freshReadinessReprobeCases ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Bool, Bool, Bool, Bool))
freshReadinessReprobeCases prepared =
    withClusterClient prepared $ \backend root ->
        withAppliedFixtureCordon backend prepared $ \applied -> do
            initial <- runClusterReadinessCall backend applied
            case settleClusterReadiness applied initial of
                Left err -> pure (Left err)
                Right evidence -> do
                    fresh <- reprobeClusterReadiness evidence
                    setNodesRunning root False
                    unready <- reprobeClusterReadiness evidence
                    setNodesRunning root True
                    replaceEveryNode root
                    replacement <- reprobeClusterReadiness evidence
                    FakeCluster.writeClusters root []
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

createdIdentityWins ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (Either ReconcileError (Word64, Word64, Word64))
createdIdentityWins prepared =
    withClusterClient prepared $ \backend _root -> do
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
    withClusterClient prepared $ \backend root -> do
        removed <- cleanupOnce backend prepared (pure ())
        case removed of
            Left err -> pure (Left err)
            Right removedOutcome -> do
                replaced <- cleanupOnce backend prepared (FakeCluster.armReplacementAfter root "delete")
                pure (fmap (\replacedOutcome -> (removedOutcome, replacedOutcome)) replaced)

{- | Create the cluster, arrange one external event, and release it once.

Written as one step because a release is only reachable from a settlement, and
each of the two cases wants the same three moves with a different thing
happening between the second and the third.
-}
cleanupOnce ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO () ->
    IO (Either ReconcileError (Either ReconcileError ()))
cleanupOnce backend prepared arrange = do
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
                            arrange
                            observed <- runClusterCleanupCall backend cleanup
                            pure (Right (settleClusterCleanup cleanup observed))
                )
                (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

{- | Create the cluster, apply its wall, and hand back the applied cordon. -}
withAppliedFixtureCordon ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ( AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId Provisioned ->
      IO (Either ReconcileError result)
    ) ->
    IO (Either ReconcileError result)
withAppliedFixtureCordon backend prepared consume =
    withCordonAndApplied backend prepared (\_cordon applied -> consume applied)

{- | The same, keeping the prepared cordon a second application can be run from. -}
withCordonAndApplied ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    ( PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId Provisioned ->
      AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId Provisioned ->
      IO (Either ReconcileError result)
    ) ->
    IO (Either ReconcileError result)
withCordonAndApplied backend prepared consume = do
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
                                Right applied -> consume cordon applied
                )
                (\_ _ _ _ -> pure (Left (fixtureFailure "created cluster became foreign")))

{- | A backend whose three cluster tools are this suite's own executable.

§ KK's one interpreter launches whatever the typed configuration resolves with
the exact argument vector a described command carries, so a fixture that wants
the driver to have answered a particular way supplies a __program__ rather than a
function beside it (§ NN). The program is "FakeCluster", entered by an
environment variable held for exactly the span of this fixture.

The node set the fixture's driver establishes is the plan's own, so the cluster
this backend brings up is the one the prepared package declares rather than a
topology the fixture guessed at.
-}
withClusterClient ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    (StrongClusterBackend -> FilePath -> IO (Either ReconcileError result)) ->
    IO (Either ReconcileError result)
withClusterClient prepared consume =
    withSystemTempDirectory "hostbootstrap-cluster-client" $ \temporary -> do
        root <- canonicalizePath temporary
        _ <- FakeCluster.newClusterFixture root (preparedClusterNodeNames prepared)
        self <- getExecutablePath
        discovered <- discoverStrongClusterBackend (clusterClientHostConfig self)
        case discovered of
            Left err -> pure (Left err)
            Right backend ->
                FakeCluster.withFakeClusterClient root (consume backend root)

clusterClientHostConfig :: FilePath -> HostConfig
clusterClientHostConfig self =
    HostConfig
        { hcSubstrate = Substrate LinuxCpu Arm64
        , hcToolPaths =
            Map.fromList
                [ (Kind, fixtureExe self)
                , (Docker, fixtureExe self)
                , (Kubectl, fixtureExe self)
                ]
        }

{- | Stand a cluster up at this plan's own name under no record of this project's.

Written through the fixture's durable state rather than through the driver,
because the whole point of the case that uses it is a cluster nothing this
project wrote ever claimed.
-}
standUpUnclaimedCluster ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    FilePath ->
    IO ()
standUpUnclaimedCluster prepared root = do
    FakeCluster.writeClusters root [preparedClusterName prepared]
    FakeCluster.writeNodes
        root
        [ (node, FakeCluster.ClusterNode (foreignIdentityFor index) True [])
        | (index, node) <- zip [0 :: Int ..] (preparedClusterNodeNames prepared)
        ]

foreignIdentityFor :: Int -> String
foreignIdentityFor index = replicate 63 'a' <> show (index `mod` 10)

-- | Stop or start every node container the fixture's runtime holds.
setNodesRunning :: FilePath -> Bool -> IO ()
setNodesRunning root running = do
    held <- FakeCluster.readNodes root
    FakeCluster.writeNodes
        root
        [(name, node{FakeCluster.nodeRunning = running}) | (name, node) <- held]

-- | Put a different container at every node's name, outside any transaction.
replaceEveryNode :: FilePath -> IO ()
replaceEveryNode root = do
    held <- FakeCluster.readNodes root
    FakeCluster.writeNodes
        root
        [ (name, node{FakeCluster.nodeIdentity = FakeCluster.replacementIdentity})
        | (name, node) <- held
        ]

{- | Remove every durable record under this run's own state directory.

Through the protected store's own public operations rather than by deleting
files, because what the case needs is the standing an operator leaves by
discarding this project's origin while the cluster it made stays up — and that
standing is "a record is not there", which is exactly what a compare-and-delete
establishes.
-}
forgetEveryDurableRecord :: FilePath -> IO ()
forgetEveryDurableRecord stateDirectory = do
    opened <- openProtectedStore stateDirectory
    store <- either (fail . show) pure opened
    outcome <- withProtectedEntry store $ \session -> do
        listed <- listProtectedRecords session
        case listed of
            Left failure -> pure (Left failure)
            Right keys -> do
                forgotten <- traverse (forgetOne session) keys
                pure (sequence_ forgotten)
    either (fail . show) pure outcome
  where
    forgetOne session key = do
        current <- readProtectedRecord session key
        case current of
            Left failure -> pure (Left failure)
            Right Nothing -> pure (Right ())
            Right (Just record) ->
                fmap (fmap (const ()))
                    (compareAndDeleteProtectedRecord session key (ExpectVersion (protectedRecordVersion record)))

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
    withClusterFixtureUsingM ReprobeAnswers

withClusterPlanFixtureM ::
    ClusterPlanPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterPlanFixtureM =
    withClusterFixtureUsingPlanM ReprobeAnswers

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
                                    ReprobeAnswers
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
    ProviderReprobe ->
    ClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureUsing = withClusterFixtureUsingM

withClusterFixtureUsingM ::
    ProviderReprobe ->
    ClusterPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureUsingM providerReprobe consume =
    withClusterFixtureUsingPlanM providerReprobe (\_plan prepared -> consume prepared)

withClusterFixtureUsingPlanM ::
    ProviderReprobe ->
    ClusterPlanPreparedConsumer summary ->
    IO (Either ReconcileError summary)
withClusterFixtureUsingPlanM providerReprobe consume =
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
                                    providerReprobe
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
    ProviderReprobe ->
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
prepareExactFixture providerReprobe providerGate clusterGate plan provider cluster consume =
    withRunningProviderDependencyFixture providerReprobe providerGate plan provider $ \runningProvider -> do
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

{- | Whether the provider's egress probe still answers when it is reprobed.

The Direct realization observes its root and its provisioning egress through
described commands, so "the probe stopped answering" is a property of the tool
the interpreter launches rather than of an injected runner: an exhausting tool
answers the readiness observation and refuses the reprobe, and both calls are
real processes (§ NN).
-}
data ProviderReprobe
    = ReprobeAnswers
    | ReprobeStopsAnswering
    deriving (Eq, Show)

withRunningProviderDependencyFixture ::
    ProviderReprobe ->
    PreparedGate ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    (RunningProviderDependency scope planId providerId -> IO (Either ReconcileError result)) ->
    IO (Either ReconcileError result)
withRunningProviderDependencyFixture reprobe gate plan planned consume =
  withProviderHostConfig reprobe $ \providerHostConfig directRoot ->
    case mkDirectHostBackendSpec providerHostConfig directRoot "alpine:3.22" of
        Left err -> pure (Left err)
        Right backendSpec -> do
            discovered <-
                discoverStrongProviderBackend providerHostConfig backendSpec $ \backend -> do
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

{- | A host configuration whose Direct-provider tools are real programs.

Both Direct probes are described commands, so the interpreter launches whatever
this configuration resolves and the fixture's control over them is the programs
themselves rather than a seam beside them (§ NN). The paths are absolute because
the fixture writes them, so the same total 'AbsExe' constructor production uses
admits them wherever the static gate runs (§ JJ).
-}
withProviderHostConfig :: ProviderReprobe -> (HostConfig -> FilePath -> IO result) -> IO result
withProviderHostConfig reprobe use =
    withSystemTempDirectory "hostbootstrap-cluster-provider-tools" $ \temporary -> do
        root <- canonicalizePath temporary
        let admissible = root </> "data"
        createDirectory admissible
        python <- Fixture.newFakeTool root "python3" ""
        docker <- case reprobe of
            ReprobeAnswers -> Fixture.newFakeTool root "docker" "{}"
            ReprobeStopsAnswering ->
                Fixture.newExhaustingFakeTool root "docker" "{}" "vm stopped answering"
        use
            HostConfig
                { hcSubstrate = Substrate LinuxCpu Arm64
                , hcToolPaths =
                    Map.fromList
                        [ (Python3, fixtureExe python)
                        , (Docker, fixtureExe docker)
                        ]
                }
            admissible

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

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
                                    ReprobeAnswers
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
