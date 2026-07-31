{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ClusterReconcileSpec (tests, FixtureScope, withClusterFixtureM, withPlannedClusterFixture) where

import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Reconcile
import HostBootstrap.Lift (localContext)
import HostBootstrap.Step
import PrepareFixture (gateFor)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

type FixtureScope = Production Fixture.FixtureProject

tests :: TestTree
tests =
    testGroup
        "ClusterReconcileSpec"
        [ testCase "an absent cluster is created and managed" $
            withClusterFixture 17 (\_ _ prepared -> settleCreated prepared) >>= \case
                Right (Changed Created, operationKey) ->
                    assertBool "the receipt carries a real operation key" (not (Text.null operationKey))
                other -> assertFailure ("expected managed creation, got " ++ show other)
        , testCase "a healthy cluster without prior proof is foreign, never adopted" $
            withClusterFixture 17 (\_ _ prepared -> settleForeign prepared) >>= \case
                Right identity -> identity @?= "core:deploy-kind"
                other -> assertFailure ("expected a foreign observation, got " ++ show other)
        , testCase "a healthy cluster with matching committed proof is Unchanged" $
            withClusterFixture 17 unchangedAfterCommit >>= \case
                Right (Unchanged, createdKey, unchangedKey) -> createdKey @?= unchangedKey
                other -> assertFailure ("expected receipt-preserving Unchanged, got " ++ show other)
        , testCase "an unhealthy same-named cluster is a Conflict, never deleted" $
            withClusterFixture 17 (\_ _ prepared -> asError prepared (ClusterUnhealthy 17)) >>= \case
                Left (Conflict detail) ->
                    assertBool
                        "the conflict refuses an auto-delete"
                        ("never auto-deleted" `Text.isInfixOf` conflictRemedy detail)
                other -> assertFailure ("expected a conflict, got " ++ show other)
        , testCase "a probe failure is a typed Failure, not a false absence" $
            withClusterFixture 17 (\_ _ prepared -> asError prepared (ClusterProbeFailed "kubectl timed out")) >>= \case
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected a failure, got " ++ show other)
        , testCase "a generation mismatch on a healthy observation is a Conflict" $
            withClusterFixture 17 (\_ _ prepared -> asError prepared (ClusterHealthy 99)) >>= \case
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a generation conflict, got " ++ show other)
        , testCase "conditional cleanup removes only our generation and refuses a replacement" $
            withClusterFixture 17 cleanupCases >>= \case
                Right (removed, replaced) -> do
                    removed @?= Right ()
                    case replaced of
                        Left (Conflict _) -> pure ()
                        other -> assertFailure ("expected a cleanup conflict, got " ++ show other)
                other -> assertFailure ("expected cleanup outcomes, got " ++ show other)
        , testCase "the traversal refuses to prepare when the plan dependency is not managed" $
            withClusterFixtureUsing
                17
                (const emptyDependencySnapshot)
                (\_ _ prepared -> settleCreated prepared)
                >>= \case
                    Left (Failure detail) ->
                        assertBool
                            "the refusal names the unmanaged plan dependency"
                            ("core:deploy-vm" `Text.isInfixOf` failureCause detail)
                    other ->
                        assertFailure
                            ("expected an unsatisfied plan dependency, got " ++ show other)
        , testCase "a dependency registered twice is a Conflict, not a silent first-wins" $
            withClusterFixtureUsing
                17
                ( \managedVM ->
                    withDependencySnapshotEntry managedVM (dependencyProbe (pure (Right 23))) $
                        withDependencySnapshotEntry
                            managedVM
                            (dependencyProbe (pure (Right 23)))
                            emptyDependencySnapshot
                )
                (\_ _ prepared -> settleCreated prepared)
                >>= \case
                    Left (Conflict _) -> pure ()
                    other -> assertFailure ("expected a duplicate-entry conflict, got " ++ show other)
        , testCase "a dependency probe that does not observe readiness refuses the prepare" $
            withClusterFixtureUsing
                17
                ( \managedVM ->
                    withDependencySnapshotEntry
                        managedVM
                        ( dependencyProbe
                            ( pure
                                ( Left
                                    ( Failure
                                        (FailureDetail "probe provider" "vm stopped answering" ReprobeBeforeRetry)
                                    )
                                )
                            )
                        )
                        emptyDependencySnapshot
                )
                (\_ _ prepared -> settleCreated prepared)
                >>= \case
                    Left (Failure detail) -> failedOperation detail @?= "probe provider"
                    other -> assertFailure ("expected the probe's own failure, got " ++ show other)
        ]

-- | Settle @ClusterCreated@ into (change, receipt operation key).
settleCreated ::
    PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ChangeView, Text.Text)
settleCreated prepared = do
    settled <- settleClusterReconcile Nothing prepared (ClusterCreated 17)
    pure $
        withReconcileResult
            settled
            (\_ receipt change -> (change, ownershipReceiptOperationKey receipt))
            (\_ _ -> error "a created cluster must be managed")

-- | Settle a healthy-without-proof observation into the foreign identity.
settleForeign ::
    PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
    Either ReconcileError Text.Text
settleForeign prepared = do
    settled <- settleClusterReconcile Nothing prepared (ClusterHealthy 17)
    pure $
        withReconcileResult
            settled
            (\_ _ _ -> error "a healthy cluster without proof must not be adopted")
            (\_ foreignState -> foreignIdentity foreignState)

asError ::
    PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
    ClusterObservation ->
    Either ReconcileError ()
asError prepared observation = settleClusterReconcile Nothing prepared observation >> Right ()

unchangedAfterCommit ::
    LifecyclePlan FixtureScope planId ->
    ResourceHandle FixtureScope planId clusterId ClusterResource Unclassified Observed ->
    PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (ChangeView, Text.Text, Text.Text)
unchangedAfterCommit plan handle prepared = do
    created <- settleClusterReconcile Nothing prepared (ClusterCreated 17)
    withReconcileResult
        created
        ( \_ receipt _ -> do
            let operationKey = ownershipReceiptOperationKey receipt
                record =
                    PersistedJournalRecord
                        { persistedPlanDigest = lifecyclePlanDigest plan
                        , persistedFrameKey = "provider"
                        , persistedResourceKey = resourceHandleKey handle
                        , persistedGeneration = resourceHandleGeneration handle
                        , persistedOperation = "reconcile cluster"
                        , persistedOperationKey = operationKey
                        , persistedRecordVersion = 41
                        , persistedPhase = Committed
                        }
            verified <-
                verifyPersistedJournalRecord plan handle "reconcile cluster" record
            joinReconcile $
                withPriorCommitProof verified $ \proof -> do
                    unchanged <-
                        settleClusterReconcile (Just proof) prepared (ClusterHealthy 17)
                    pure $
                        withReconcileResult
                            unchanged
                            ( \_ unchangedReceipt change ->
                                (change, operationKey, ownershipReceiptOperationKey unchangedReceipt)
                            )
                            (\_ _ -> error "matching prior commit must remain managed")
        )
        (\_ _ -> Left (Failure (FailureDetail "test unchanged" "created cluster became foreign" DoNotRetry)))

{- | Create, own, then exercise conditional cleanup with a matching and a
replaced generation.
-}
cleanupCases ::
    LifecyclePlan FixtureScope planId ->
    ResourceHandle FixtureScope planId clusterId ClusterResource Unclassified Observed ->
    PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
    Either ReconcileError (Either ReconcileError (), Either ReconcileError ())
cleanupCases _ _ prepared = do
    created <- settleClusterReconcile Nothing prepared (ClusterCreated 17)
    withReconcileResult
        created
        ( \managed receipt _ ->
            joinReconcile $
                withPreparedClusterCleanup managed receipt $ \cleanup ->
                    Right
                        ( settleClusterCleanup cleanup ClusterCleanupRemoved
                        , settleClusterCleanup cleanup (ClusterCleanupReplaced 99)
                        )
        )
        (\_ _ -> Left (Failure (FailureDetail "test cleanup" "created cluster became foreign" DoNotRetry)))

{- | The planned cluster resource alone, for operations that bind to the plan
without preparing a reconcile (the loopback exposure renderer).
-}
withPlannedClusterFixture ::
    ( forall planId clusterId clusterFrame.
      PlannedResource FixtureScope planId clusterId ClusterResource clusterFrame ->
      Either ReconcileError result
    ) ->
    Either ReconcileError result
withPlannedClusterFixture consume =
    withTestLifecyclePlan $ \plan ->
        joinReconcile $
            withPlannedResourceOfKind plan ClusterResourceKind "core:deploy-kind" consume

{- | The IO-returning peer of 'withClusterFixture', so a backend spec can run
real effects inside the same plan-scoped prepared operation.
-}
withClusterFixtureM ::
    Word64 ->
    ( forall planId clusterId operationKey callDigest attempt journalVersion.
      LifecyclePlan FixtureScope planId ->
      ResourceHandle FixtureScope planId clusterId ClusterResource Unclassified Observed ->
      PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
      IO (Either ReconcileError summary)
    ) ->
    IO (Either ReconcileError summary)
withClusterFixtureM observedGeneration consume =
    withClusterFixture observedGeneration wrap >>= either (pure . Left) id
  where
    wrap plan observed prepared = Right (consume plan observed prepared)

{- | The cluster fixture, sealed through the plan-owned dependency-snapshot
traversal.  It registers the managed provider under its plan operation key and
lets the traversal decide the edge set; a probe run is IO, so the fixture is.
-}
withClusterFixture ::
    Word64 ->
    ( forall planId clusterId operationKey callDigest attempt journalVersion.
      LifecyclePlan FixtureScope planId ->
      ResourceHandle FixtureScope planId clusterId ClusterResource Unclassified Observed ->
      PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
      Either ReconcileError summary
    ) ->
    IO (Either ReconcileError summary)
withClusterFixture observedGeneration = withClusterFixtureUsing observedGeneration providerSnapshot
  where
    providerSnapshot managedVM =
        withDependencySnapshotEntry
            managedVM
            (dependencyProbe (pure (Right 23)))
            emptyDependencySnapshot

{- | The same fixture with the snapshot supplied by the caller, so a test can
prove what happens when the plan's managed provider is missing from it.
-}
withClusterFixtureUsing ::
    Word64 ->
    ( forall planId providerId.
      ResourceHandle FixtureScope planId providerId ProviderResource Managed Provisioned ->
      DependencySnapshot FixtureScope planId
    ) ->
    ( forall planId clusterId operationKey callDigest attempt journalVersion.
      LifecyclePlan FixtureScope planId ->
      ResourceHandle FixtureScope planId clusterId ClusterResource Unclassified Observed ->
      PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
      Either ReconcileError summary
    ) ->
    IO (Either ReconcileError summary)
withClusterFixtureUsing observedGeneration snapshotOf consume = do
    providerGate <- gateFor testPlanDigest "core:deploy-vm"
    clusterGate <- gateFor testPlanDigest "core:deploy-kind"
    withTestLifecyclePlan $ \plan ->
        joinIO $
            withPlannedResourceOfKind plan ProviderResourceKind "core:deploy-vm" $ \vm ->
                joinIO $
                    withPlannedResourceOfKind plan ClusterResourceKind "core:deploy-kind" $ \cluster ->
                        joinIO $
                            withManagedProvider providerGate plan vm $ \managedVM ->
                                joinIO $
                                    withObservedPlannedResource plan cluster observedGeneration 29 $ \observed ->
                                        flattenIO $
                                            withPreparedClusterReconcile
                                                plan
                                                cluster
                                                observed
                                                (snapshotOf managedVM)
                                                clusterGate
                                                (consume plan observed)

-- | Build a managed provider/VM handle for the cluster's dependency edge.
withManagedProvider ::
    PreparedGate ->
    LifecyclePlan FixtureScope planId ->
    PlannedResource FixtureScope planId providerId ProviderResource providerFrame ->
    ( ResourceHandle FixtureScope planId providerId ProviderResource Managed Provisioned ->
      result
    ) ->
    Either ReconcileError result
withManagedProvider gate plan planned consume =
    joinReconcile $
        withObservedPlannedResource plan planned 5 7 $ \observed -> do
            descriptor <- plannedOperation plan planned observed "provider:create"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
                withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
                    reconciled <-
                        completeReconcile observed prepared preconditions (BackendCreated 5)
                    withReconcileResult
                        reconciled
                        (\managed _ _ -> Right (consume managed))
                        (\_ _ -> Left (Failure (FailureDetail "test provider" "unexpected foreign provider" DoNotRetry)))

testPlan :: StepPlan
testPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia localContext (deployVMStep "provider" (StepFrame "host" "Host") (const (pure ())))
            , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure ()))
            ]
        )

testPlanDigest :: Text.Text
testPlanDigest = withTestLifecyclePlan lifecyclePlanDigest

withTestLifecyclePlan ::
    (forall planId. LifecyclePlan FixtureScope planId -> result) ->
    result
withTestLifecyclePlan consume =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec testPlan consume

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id

joinIO :: Either ReconcileError (IO (Either ReconcileError value)) -> IO (Either ReconcileError value)
joinIO = either (pure . Left) id

flattenIO ::
    IO (Either ReconcileError (Either ReconcileError value)) ->
    IO (Either ReconcileError value)
flattenIO = fmap joinReconcile
