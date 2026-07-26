{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module BudgetSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.Reconcile (LifecyclePlan, withLifecyclePlan)
import HostBootstrap.Reconcile (ChangeView (..), ChangedKind (..))
import HostBootstrap.Step (StepFrame (StepFrame), StepPlan, contextInitStep, mkStepPlan)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

exactEnvelope :: ResourceEnvelope
exactEnvelope = ResourceEnvelope 8 "16GiB" "100GiB"

tests :: TestTree
tests =
  testGroup
    "BudgetSpec"
    [ testCase "provider admission rejects upward rounding" $ do
        let inexact = ResourceEnvelope 4 "8589934593" "20GiB"
        admissionSummary inexact LimaBackend
          @?= Left (InexactProviderQuantity LimaBackend "memory" (8 * gib + 1)),
      testCase "provider wall argv consumes admitted exact values" $
        admissionSummary exactEnvelope IncusBackend
          @?= Right ["limits.cpu=8", "limits.memory=16GiB", "root,size=100GiB"],
      testCase "bare Linux reports unsupported instead of pretending to cordon storage" $
        admissionSummary exactEnvelope BareLinuxBackend
          @?= Left (UnsupportedBudgetWall BareLinuxBackend "bare Linux has no quota/image-GC storage wall"),
      testCase "workload set must be non-empty" $
        withTestLifecyclePlan
          ( \plan ->
              withValidatedBudget plan exactEnvelope
                (\_ -> withPlannedWorkloadSet [] (const ()))
          )
          @?= Right (Left EmptyWorkloadSet),
      testCase "workload fit and constructive partition share the admitted budget" $ do
        result <- pure successfulPartition
        result @?= Right [("vm", "metal", (6, 10 * gib, 80 * gib))],
      testCase "partition rejects slices plus overhead above effective budget" $
        overflowingPartition
          @?= Left (PartitionOverflow "cpu" 9 8),
      testCase "slice request rejects provider-minimum violations" $ do
        tiny <- pure (mkResourceBudget 1 gib gib)
        minimumBudget <- pure (mkResourceBudget 2 (2 * gib) (2 * gib))
        case (tiny, minimumBudget) of
          (Right actual, Right required) ->
            assertBool "expected below-minimum rejection" (isLeft (mkSliceRequest "node" "cluster" actual required))
          other -> assertBool ("unexpected fixture construction failure: " ++ show other) False,
      testCase "WSL wall settlement returns the live authority and global lease inseparably" $
        wallSettlementSummary Wsl2Backend (WallAlreadyExact 9)
          @?= Right (Unchanged, 9, 1, True),
      testCase "ordinary provider migration returns repaired live authority without a WSL lease" $
        wallSettlementSummary LimaBackend (WallMigrated 12 "resized")
          @?= Right (Changed Repaired, 12, 1, False),
      testCase "an uncertain wall call yields no live authority" $
        assertBool
          "uncertain acquisition must fail closed"
          (isLeft (wallSettlementSummary Wsl2Backend (WallAcquireUncertain "lost acknowledgement")))
    ]

admissionSummary :: ResourceEnvelope -> ProviderBackend -> Either BudgetError [String]
admissionSummary envelope backend =
  withTestLifecyclePlan $ \plan ->
    joinBudget $ withValidatedBudget plan envelope $ \validated ->
      withProviderKeyForBackend backend $ \providerKey ->
        withProviderBudgetCapability plan providerKey $ \capability ->
          joinBudget $
            admitProviderBudget validated capability $ \wall effective -> do
              workload <- mkWorkload "admission-check" 1 1 gib gib
              overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
              sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
              minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
              request <- mkSliceRequest "vm" "metal" sliceBudget minimumBudget
              joinBudget $
                withPlannedWorkloadSet [workload] $ \workloads -> do
                  fit <- verifyPlannedWorkloadFit effective workloads
                  joinBudget $
                    withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                      joinBudget $
                        withProviderWallReservation wall partition 1 $ \reservation ->
                          providerWallCallArgs
                            <$> prepareProviderWallCall "demo" wall partition reservation

successfulPartition :: Either BudgetError [(String, String, (Integer, Integer, Integer))]
successfulPartition = do
  workload <- mkWorkload "web" 2 1 gib gib
  overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
  vmBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
  vmMinimum <- mapBudgetError (mkResourceBudget 1 gib gib)
  request <- mkSliceRequest "vm" "metal" vmBudget vmMinimum
  withTestLifecyclePlan $ \plan ->
    joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
      withProviderBudgetCapability plan LimaProviderKey $ \capability -> do
        joinBudget $
          admitProviderBudget validated capability $ \_wall effective ->
            joinBudget $
              withPlannedWorkloadSet [workload] $ \workloads -> do
                fit <- verifyPlannedWorkloadFit effective workloads
                withBudgetPartition effective fit overhead (request :| []) $ \_partition slices ->
                  forResourceSlices slices $ \slice ->
                    let budget = resourceSliceBudget slice
                     in ( resourceSliceName slice,
                          resourceSliceFrame slice,
                          ( toInteger (budgetCpu budget),
                            budgetMemoryBytes budget,
                            budgetStorageBytes budget
                          )
                        )

overflowingPartition :: Either BudgetError ()
overflowingPartition = do
  workload <- mkWorkload "web" 1 1 gib gib
  overhead <- mapBudgetError (mkResourceBudget 3 gib gib)
  sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
  minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
  request <- mkSliceRequest "vm" "metal" sliceBudget minimumBudget
  withTestLifecyclePlan $ \plan ->
    joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
      withProviderBudgetCapability plan LimaProviderKey $ \capability -> do
        joinBudget $
          admitProviderBudget validated capability $ \_wall effective ->
            joinBudget $
              withPlannedWorkloadSet [workload] $ \workloads -> do
                fit <- verifyPlannedWorkloadFit effective workloads
                fmap (const ()) $
                  withBudgetPartition effective fit overhead (request :| []) $ \_ _ -> ()

wallSettlementSummary ::
  ProviderBackend ->
  WallAcquireObservation ->
  Either BudgetError (ChangeView, Word64, Word64, Bool)
wallSettlementSummary backend observation = do
  workload <- mkWorkload "wall-check" 1 1 gib gib
  overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
  sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
  minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
  request <- mkSliceRequest "vm" "metal" sliceBudget minimumBudget
  withTestLifecyclePlan $ \plan ->
    joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
      withProviderKeyForBackend backend $ \providerKey ->
        withProviderBudgetCapability plan providerKey $ \capability ->
          joinBudget $
            admitProviderBudget validated capability $ \wall effective ->
              joinBudget $
                withPlannedWorkloadSet [workload] $ \workloads -> do
                  fit <- verifyPlannedWorkloadFit effective workloads
                  joinBudget $
                    withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                      joinBudget $
                        withProviderWallReservation wall partition 1 $ \reservation -> do
                          prepared <- prepareProviderWallCall "demo" wall partition reservation
                          case
                            settleProviderWallCall prepared observation $ \live ->
                              withLiveProviderWall
                                live
                                ( \authority change ->
                                    (change, providerWallEpoch authority, providerWallFence authority, False)
                                )
                                ( \authority _lease change ->
                                    (change, providerWallEpoch authority, providerWallFence authority, True)
                                ) of
                            Left err -> Left (InvalidWallReservation (show err))
                            Right summary -> Right summary

mapBudgetError :: Either String a -> Either BudgetError a
mapBudgetError = either (Left . InvalidBudget) Right

joinBudget :: Either BudgetError (Either BudgetError a) -> Either BudgetError a
joinBudget = either Left id

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    (mkStepPlan [contextInitStep "context" (StepFrame "host" "Host") (const (pure ()))])

withTestLifecyclePlan ::
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlan consume =
  withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
    withLifecyclePlan codec testPlan consume
