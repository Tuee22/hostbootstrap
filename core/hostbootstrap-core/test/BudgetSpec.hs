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
import HostBootstrap.Reconcile (
  ChangeView (..),
  ChangedKind (..),
  ConflictDetail (..),
  ReconcileError (..),
  UnsupportedDetail (..),
 )
import qualified Data.Text as Text
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
          (isLeft (wallSettlementSummary Wsl2Backend (WallAcquireUncertain "lost acknowledgement"))),
      testCase "every VM provider applies the declared storage ceiling exactly" $ do
        storageWallSummary LimaBackend storageWallShape
          @?= Right (Right (LimaDiskArgument, ["--disk", "100"], 100 * gib))
        storageWallSummary ColimaBackend storageWallShape
          @?= Right
            ( Right
                ( ColimaDiskArgument,
                  ["start", "--profile", "demo", "--disk", "100"],
                  100 * gib
                )
            )
        storageWallSummary IncusBackend storageWallShape
          @?= Right
            (Right (IncusRootSizeArgument, ["-d", "root,size=100GiB"], 100 * gib))
        storageWallSummary Wsl2Backend storageWallShape
          @?= Right
            (Right (Wsl2VhdSizeArgument, ["--vhd-size", "100GB"], 100 * gib)),
      testCase "a kind node container is Unsupported, never a silent success" $
        case storageWallSummary DockerNodeBackend storageWallShape of
          Right (Left (Unsupported detail)) ->
            assertBool
              "the reason names the missing storage flag"
              ("DockerNodeHasNoStorageFlag" `Text.isInfixOf` unsupportedReason detail)
          other -> assertBool ("expected Unsupported, got " ++ show other) False,
      testCase "bare Linux is refused before a storage wall is even prepared" $
        -- Bare Linux has no provider wall at all, so admission refuses it one
        -- step earlier than the storage mechanism does. Either way the caller
        -- gets a typed unsupported result, never a silent success.
        storageWallSummary BareLinuxBackend storageWallShape
          @?= Left
            ( UnsupportedBudgetWall
                BareLinuxBackend
                "bare Linux has no quota/image-GC storage wall"
            ),
      testCase "an exactly applied storage ceiling settles as Changed Created" $
        storageWallSummary
          LimaBackend
          (\prepared -> settleStorageWallCall prepared (StorageWallApplied 4 (100 * gib)) appliedStorageWallChange)
          @?= Right (Right (Changed Created)),
      testCase "an already-exact storage ceiling settles as Unchanged" $
        storageWallSummary
          LimaBackend
          (\prepared -> settleStorageWallCall prepared (StorageWallAlreadyExact 4 (100 * gib)) appliedStorageWallChange)
          @?= Right (Right Unchanged),
      testCase "a rounded storage ceiling is a Conflict even when the provider succeeded" $
        case storageWallSummary
          LimaBackend
          (\prepared -> settleStorageWallCall prepared (StorageWallApplied 4 (128 * gib)) appliedStorageWallChange) of
          Right (Left (Conflict detail)) ->
            assertBool
              "the remedy refuses a rounded hard ceiling"
              ("rounded hard ceiling" `Text.isInfixOf` conflictRemedy detail)
          other -> assertBool ("expected a rounding conflict, got " ++ show other) False,
      testCase "a zero wall epoch cannot mint an applied storage wall" $
        case storageWallSummary
          LimaBackend
          (\prepared -> settleStorageWallCall prepared (StorageWallApplied 0 (100 * gib)) appliedStorageWallChange) of
          Right (Left (Failure _)) -> pure ()
          other -> assertBool ("expected an epoch failure, got " ++ show other) False,
      testCase "an inexact declared ceiling never reaches the storage wall" $
        assertBool
          "admission refuses an inexact storage quantity before any wall call"
          ( isLeft
              ( storageWallSummaryFor
                  (ResourceEnvelope 8 "16GiB" (Text.pack (show (100 * gib + 1))))
                  LimaBackend
                  storageWallShape
              )
          )
    ]

-- | The prepared storage wall's mechanism, argv, and exact declared ceiling.
storageWallShape ::
  PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Either ReconcileError (StorageWallMechanism, [String], Integer)
storageWallShape prepared =
  Right
    ( storageWallCallMechanism prepared,
      storageWallCallArgs prepared,
      storageWallCeilingBytes prepared
    )

storageWallSummary ::
  ProviderBackend ->
  ( forall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence.
    PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    Either ReconcileError result
  ) ->
  Either BudgetError (Either ReconcileError result)
storageWallSummary = storageWallSummaryFor exactEnvelope

{- | Prepare the storage wall from already-admitted budget inputs, so no case
can hand the wall a value admission would have refused.
-}
storageWallSummaryFor ::
  ResourceEnvelope ->
  ProviderBackend ->
  ( forall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence.
    PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    Either ReconcileError result
  ) ->
  Either BudgetError (Either ReconcileError result)
storageWallSummaryFor envelope backend consume = do
  workload <- mkWorkload "storage-wall-check" 1 1 gib gib
  overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
  sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
  minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
  request <- mkSliceRequest "vm" "metal" sliceBudget minimumBudget
  withTestLifecyclePlan $ \plan ->
    joinBudget $ withValidatedBudget plan envelope $ \validated ->
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
                        withProviderWallReservation wall partition 1 $ \reservation ->
                          Right
                            ( prepareStorageWallCall "demo" wall partition reservation
                                >>= consume
                            )

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
