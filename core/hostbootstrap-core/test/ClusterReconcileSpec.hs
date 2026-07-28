{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ClusterReconcileSpec (tests) where

import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Reconcile
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Reconcile
import HostBootstrap.Step
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

type FixtureScope = Production Fixture.FixtureProject

tests :: TestTree
tests =
    testGroup
        "ClusterReconcileSpec"
        [ testCase "an absent cluster is created and managed" $
            case withClusterFixture 17 (\_ _ prepared -> settleCreated prepared) of
                Right (Changed Created, operationKey) ->
                    assertBool "the receipt carries a real operation key" (not (Text.null operationKey))
                other -> assertFailure ("expected managed creation, got " ++ show other)
        , testCase "a healthy cluster without prior proof is foreign, never adopted" $
            case withClusterFixture 17 (\_ _ prepared -> settleForeign prepared) of
                Right identity -> identity @?= "core:deploy-kind"
                other -> assertFailure ("expected a foreign observation, got " ++ show other)
        , testCase "a healthy cluster with matching committed proof is Unchanged" $
            case withClusterFixture 17 unchangedAfterCommit of
                Right (Unchanged, createdKey, unchangedKey) -> createdKey @?= unchangedKey
                other -> assertFailure ("expected receipt-preserving Unchanged, got " ++ show other)
        , testCase "an unhealthy same-named cluster is a Conflict, never deleted" $
            case withClusterFixture 17 (\_ _ prepared -> asError prepared (ClusterUnhealthy 17)) of
                Left (Conflict detail) ->
                    assertBool
                        "the conflict refuses an auto-delete"
                        ("never auto-deleted" `Text.isInfixOf` conflictRemedy detail)
                other -> assertFailure ("expected a conflict, got " ++ show other)
        , testCase "a probe failure is a typed Failure, not a false absence" $
            case withClusterFixture 17 (\_ _ prepared -> asError prepared (ClusterProbeFailed "kubectl timed out")) of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected a failure, got " ++ show other)
        , testCase "a generation mismatch on a healthy observation is a Conflict" $
            case withClusterFixture 17 (\_ _ prepared -> asError prepared (ClusterHealthy 99)) of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected a generation conflict, got " ++ show other)
        , testCase "conditional cleanup removes only our generation and refuses a replacement" $
            case withClusterFixture 17 cleanupCases of
                Right (removed, replaced) -> do
                    removed @?= Right ()
                    case replaced of
                        Left (Conflict _) -> pure ()
                        other -> assertFailure ("expected a cleanup conflict, got " ++ show other)
                other -> assertFailure ("expected cleanup outcomes, got " ++ show other)
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

withClusterFixture ::
    Word64 ->
    ( forall planId clusterId operationKey callDigest attempt journalVersion.
      LifecyclePlan FixtureScope planId ->
      ResourceHandle FixtureScope planId clusterId ClusterResource Unclassified Observed ->
      PreparedClusterReconcile FixtureScope planId clusterId operationKey callDigest attempt journalVersion ->
      Either ReconcileError summary
    ) ->
    Either ReconcileError summary
withClusterFixture observedGeneration consume =
    withTestLifecyclePlan $ \plan ->
        joinReconcile $
            withPlannedResourceOfKind plan ProviderResourceKind "core:deploy-vm" $ \vm ->
                joinReconcile $
                    withPlannedResourceOfKind plan ClusterResourceKind "core:deploy-kind" $ \cluster ->
                        joinReconcile $
                            withManagedProvider plan vm $ \managedVM ->
                                joinReconcile $
                                    withObservedPlannedResource plan cluster observedGeneration 29 $ \observed ->
                                        joinReconcile $
                                            withPreparedClusterReconcile
                                                plan
                                                cluster
                                                observed
                                                managedVM
                                                23
                                                1
                                                37
                                                (consume plan observed)

-- | Build a managed provider/VM handle for the cluster's dependency edge.
withManagedProvider ::
    LifecyclePlan FixtureScope planId ->
    PlannedResource FixtureScope planId providerId ProviderResource providerFrame ->
    ( ResourceHandle FixtureScope planId providerId ProviderResource Managed Provisioned ->
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
            [ deployVMStep "provider" (StepFrame "host" "Host") (const (pure ()))
            , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure ()))
            ]
        )

withTestLifecyclePlan ::
    (forall planId. LifecyclePlan FixtureScope planId -> result) ->
    result
withTestLifecyclePlan consume =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec testPlan consume

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id
