{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module BudgetSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.Lift (localContext)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan
  ( ClusterResource,
    PlannedResource,
    PlannedResourceKind (ClusterResourceKind, ProviderResourceKind),
    ProjectPlan,
    ProviderResource,
    forward,
    plannedResourceFrame,
    plannedResourceKey,
    plannedStepOperationKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    withPlannedResourceOfKind,
  )
import HostBootstrap.Reconcile (
  ChangeView (..),
  ChangedKind (..),
  ConflictDetail (..),
  ReconcileError (..),
  UnsupportedDetail (..),
 )
import qualified Data.Text as Text
import HostBootstrap.Step
  ( StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
  )
import PrepareFixture (gateFor, gateForValues)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
        result <- admissionSummary inexact LimaBackend
        result @?= Left (InexactProviderQuantity LimaBackend "memory" (8 * gib + 1)),
      testCase "Colima admission reserves its fixed writable root disk inside the declared ceiling" $ do
        result <- admissionSummary (ResourceEnvelope 8 "16GiB" "20GiB") ColimaBackend
        result
          @?= Left
            ( InvalidBudget
                "Colima storage must exceed the fixed 20 GiB writable root disk; got 20 GiB"
            ),
      testCase "provider wall argv consumes admitted exact values" $ do
        result <- admissionSummary exactEnvelope IncusBackend
        result @?= Right ["limits.cpu=8", "limits.memory=16GiB", "root,size=100GiB"],
      testCase "bare Linux reports unsupported instead of pretending to cordon storage" $ do
        result <- admissionSummary exactEnvelope BareLinuxBackend
        result
          @?= Left (UnsupportedBudgetWall BareLinuxBackend "bare Linux has no quota/image-GC storage wall"),
      testCase "workload set must be non-empty" $ do
        result <-
          withBudgetProjectPlan $ \plan _providerResource _clusterResource ->
            pure $
              withValidatedBudget plan exactEnvelope
                (\_ -> withPlannedWorkloadSet plan [] (const ()))
        result @?= Right (Left EmptyWorkloadSet),
      testCase "workload fit and constructive partition share the admitted budget" $ do
        result <- successfulPartition
        result @?= Right [("core:deploy-vm", "host", (6, 10 * gib, 80 * gib))],
      testCase "workload and slice identity are projected from the admitted plan" $ do
        result <- projectedIdentitySummary
        case result of
          Right (workloadIdentity, projectedWorkloadIdentity, sliceIdentities, projectedSliceIdentity) -> do
            workloadIdentity @?= projectedWorkloadIdentity
            sliceIdentities @?= [projectedSliceIdentity]
          other -> assertFailure ("expected projected workload and slice identities, got " ++ show other),
      testCase "partition rejects slices plus overhead above effective budget" $ do
        result <- overflowingPartition
        result @?= Left (PartitionOverflow "cpu" 9 8),
      testCase "slice request rejects provider-minimum violations" $ do
        tiny <- pure (mkResourceBudget 1 gib gib)
        minimumBudget <- pure (mkResourceBudget 2 (2 * gib) (2 * gib))
        case (tiny, minimumBudget) of
          (Right actual, Right required) -> do
            result <-
              withBudgetProjectPlan $ \_plan providerResource _clusterResource ->
                pure (isLeft (mkSliceRequest providerResource actual required))
            assertBool "expected below-minimum rejection" result
          other -> assertBool ("unexpected fixture construction failure: " ++ show other) False,
      testCase "the exact journal gate mints the provider reservation fence" $ do
        result <- reservationGateSummary ExactReservationGate
        result @?= Right 1,
      testCase "a gate from another plan cannot reserve the provider wall" $ do
        result <- reservationGateSummary WrongReservationPlan
        result @?= Left (InvalidWallReservation "the prepare gate belongs to another project plan"),
      testCase "a gate for another operation cannot reserve the provider wall" $ do
        result <- reservationGateSummary WrongReservationOperation
        result @?= Left (InvalidWallReservation "the prepare gate belongs to another provider operation"),
      testCase "a zero journal fence cannot reserve the provider wall" $ do
        result <- reservationGateSummary ZeroReservationFence
        result @?= Left (InvalidWallReservation "the prepare gate fence must be positive"),
      testCase "every VM provider applies the declared storage ceiling exactly" $ do
        lima <- storageWallSummary LimaBackend storageWallShape
        lima @?= Right (Right (LimaDiskArgument, ["--disk", "100"], 100 * gib))
        colima <- storageWallSummary ColimaBackend storageWallShape
        colima
          @?= Right
            ( Right
                ( ColimaDiskArgument,
                  [ "start",
                    "--profile",
                    "demo",
                    "--runtime",
                    "docker",
                    "--activate=false",
                    "--template=false",
                    "--ssh-config=false",
                    "--mount",
                    "none",
                    "--kubernetes=false",
                    "--network-address=false",
                    "--mount-inotify=false",
                    "--cpus",
                    "8",
                    "--memory",
                    "16",
                    "--root-disk",
                    "20",
                    "--disk",
                    "80"
                  ],
                  100 * gib
                )
            )
        incus <- storageWallSummary IncusBackend storageWallShape
        incus
          @?= Right
            (Right (IncusRootSizeArgument, ["-d", "root,size=100GiB"], 100 * gib))
        wsl <- storageWallSummary Wsl2Backend storageWallShape
        wsl
          @?= Right
            (Right (Wsl2VhdSizeArgument, ["--vhd-size", "100GB"], 100 * gib)),
      testCase "a kind node container is Unsupported, never a silent success" $ do
        result <- storageWallSummary DockerNodeBackend storageWallShape
        case result of
          Right (Left (Unsupported detail)) ->
            assertBool
              "the reason names the missing storage flag"
              ("DockerNodeHasNoStorageFlag" `Text.isInfixOf` unsupportedReason detail)
          other -> assertBool ("expected Unsupported, got " ++ show other) False,
      testCase "bare Linux is refused before a storage wall is even prepared" $ do
        -- Bare Linux has no provider wall at all, so admission refuses it one
        -- step earlier than the storage mechanism does. Either way the caller
        -- gets a typed unsupported result, never a silent success.
        result <- storageWallSummary BareLinuxBackend storageWallShape
        result
          @?= Left
            ( UnsupportedBudgetWall
                BareLinuxBackend
                "bare Linux has no quota/image-GC storage wall"
            ),
      testCase "an exactly applied storage ceiling settles as Changed Created" $ do
        result <-
          storageWallSummary
            LimaBackend
            (\prepared -> settleStorageWallCall prepared (StorageWallApplied 4 (100 * gib)) appliedStorageWallChange)
        result @?= Right (Right (Changed Created)),
      testCase "an already-exact storage ceiling settles as Unchanged" $ do
        result <-
          storageWallSummary
            LimaBackend
            (\prepared -> settleStorageWallCall prepared (StorageWallAlreadyExact 4 (100 * gib)) appliedStorageWallChange)
        result @?= Right (Right Unchanged),
      testCase "a rounded storage ceiling is a Conflict even when the provider succeeded" $ do
        result <-
          storageWallSummary
            LimaBackend
            (\prepared -> settleStorageWallCall prepared (StorageWallApplied 4 (128 * gib)) appliedStorageWallChange)
        case result of
          Right (Left (Conflict detail)) ->
            assertBool
              "the remedy refuses a rounded hard ceiling"
              ("rounded hard ceiling" `Text.isInfixOf` conflictRemedy detail)
          other -> assertBool ("expected a rounding conflict, got " ++ show other) False,
      testCase "a zero wall epoch cannot mint an applied storage wall" $ do
        result <-
          storageWallSummary
            LimaBackend
            (\prepared -> settleStorageWallCall prepared (StorageWallApplied 0 (100 * gib)) appliedStorageWallChange)
        case result of
          Right (Left (Failure _)) -> pure ()
          other -> assertBool ("expected an epoch failure, got " ++ show other) False,
      testCase "an inexact declared ceiling never reaches the storage wall" $ do
        result <-
          storageWallSummaryFor
            (ResourceEnvelope 8 "16GiB" (Text.pack (show (100 * gib + 1))))
            LimaBackend
            storageWallShape
        assertBool
          "admission refuses an inexact storage quantity before any wall call"
          (isLeft result)
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
  IO (Either BudgetError (Either ReconcileError result))
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
  IO (Either BudgetError (Either ReconcileError result))
storageWallSummaryFor envelope backend consume =
  withBudgetProjectPlan $ \plan providerResource clusterResource -> do
    gate <- exactProviderGate plan providerResource
    pure $ do
      workload <- mkWorkload clusterResource 1 1 gib gib
      overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
      sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
      minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
      request <- mkSliceRequest providerResource sliceBudget minimumBudget
      joinBudget $ withValidatedBudget plan envelope $ \validated ->
        withProviderKeyForBackend backend $ \providerKey ->
          withProviderBudgetCapability plan providerResource providerKey $ \capability ->
            joinBudget $
              admitProviderBudget validated capability $ \wall effective ->
                joinBudget $
                  withPlannedWorkloadSet plan [workload] $ \workloads -> do
                    fit <- verifyPlannedWorkloadFit effective workloads
                    joinBudget $
                      withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                        joinBudget $
                          withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                            Right
                              ( prepareStorageWallCall "demo" wall partition reservation
                                  >>= consume
                              )

admissionSummary :: ResourceEnvelope -> ProviderBackend -> IO (Either BudgetError [String])
admissionSummary envelope backend =
  withBudgetProjectPlan $ \plan providerResource clusterResource -> do
    gate <- exactProviderGate plan providerResource
    pure $
      joinBudget $ withValidatedBudget plan envelope $ \validated ->
        withProviderKeyForBackend backend $ \providerKey ->
          withProviderBudgetCapability plan providerResource providerKey $ \capability ->
            joinBudget $
              admitProviderBudget validated capability $ \wall effective -> do
                workload <- mkWorkload clusterResource 1 1 gib gib
                overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
                sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
                minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
                request <- mkSliceRequest providerResource sliceBudget minimumBudget
                joinBudget $
                  withPlannedWorkloadSet plan [workload] $ \workloads -> do
                    fit <- verifyPlannedWorkloadFit effective workloads
                    joinBudget $
                      withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                        joinBudget $
                          withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                            providerWallCallArgs
                              <$> prepareProviderWallCall "demo" wall partition reservation

successfulPartition :: IO (Either BudgetError [(String, String, (Integer, Integer, Integer))])
successfulPartition =
  withBudgetProjectPlan $ \plan providerResource clusterResource ->
    pure $ do
      workload <- mkWorkload clusterResource 2 1 gib gib
      overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
      vmBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
      vmMinimum <- mapBudgetError (mkResourceBudget 1 gib gib)
      request <- mkSliceRequest providerResource vmBudget vmMinimum
      joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
        withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability -> do
          joinBudget $
            admitProviderBudget validated capability $ \_wall effective ->
              joinBudget $
                withPlannedWorkloadSet plan [workload] $ \workloads -> do
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

projectedIdentitySummary ::
  IO
    ( Either
        BudgetError
        ( (String, String),
          (String, String),
          [(String, String)],
          (String, String)
        )
    )
projectedIdentitySummary =
  withBudgetProjectPlan $ \plan providerResource clusterResource ->
    pure $ do
      workload <- mkWorkload clusterResource 1 1 gib gib
      overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
      sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
      minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
      request <- mkSliceRequest providerResource sliceBudget minimumBudget
      joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
        withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability ->
          joinBudget $
            admitProviderBudget validated capability $ \_wall effective ->
              joinBudget $
                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                  fit <- verifyPlannedWorkloadFit effective workloads
                  withBudgetPartition effective fit overhead (request :| []) $ \_partition slices ->
                    ( (workloadName workload, workloadFrame workload),
                      ( Text.unpack (plannedResourceKey clusterResource),
                        Text.unpack (plannedResourceFrame clusterResource)
                      ),
                      forResourceSlices slices $ \slice ->
                        (resourceSliceName slice, resourceSliceFrame slice),
                      ( Text.unpack (plannedResourceKey providerResource),
                        Text.unpack (plannedResourceFrame providerResource)
                      )
                    )

overflowingPartition :: IO (Either BudgetError ())
overflowingPartition =
  withBudgetProjectPlan $ \plan providerResource clusterResource ->
    pure $ do
      workload <- mkWorkload clusterResource 1 1 gib gib
      overhead <- mapBudgetError (mkResourceBudget 3 gib gib)
      sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
      minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
      request <- mkSliceRequest providerResource sliceBudget minimumBudget
      joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
        withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability -> do
          joinBudget $
            admitProviderBudget validated capability $ \_wall effective ->
              joinBudget $
                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                  fit <- verifyPlannedWorkloadFit effective workloads
                  fmap (const ()) $
                    withBudgetPartition effective fit overhead (request :| []) $ \_ _ -> ()

data ReservationGateCase
  = ExactReservationGate
  | WrongReservationPlan
  | WrongReservationOperation
  | ZeroReservationFence

reservationGateSummary :: ReservationGateCase -> IO (Either BudgetError Word64)
reservationGateSummary gateCase =
  withBudgetProjectPlan $ \plan providerResource clusterResource -> do
    let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
        operationKey = plannedResourceKey providerResource
    gate <- case gateCase of
      ExactReservationGate -> gateFor planDigest operationKey
      WrongReservationPlan -> gateFor "another-plan" operationKey
      WrongReservationOperation -> gateFor planDigest "core:another-provider"
      ZeroReservationFence -> gateForValues planDigest operationKey "session-1" 0 1
    pure $ do
      workload <- mkWorkload clusterResource 1 1 gib gib
      overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
      sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
      minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
      request <- mkSliceRequest providerResource sliceBudget minimumBudget
      joinBudget $ withValidatedBudget plan exactEnvelope $ \validated ->
        withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability ->
          joinBudget $
            admitProviderBudget validated capability $ \wall effective ->
              joinBudget $
                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                  fit <- verifyPlannedWorkloadFit effective workloads
                  joinBudget $
                    withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                      joinBudget $
                        withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                          providerWallCallFence
                            <$> prepareProviderWallCall "demo" wall partition reservation

exactProviderGate ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  IO PreparedGate
exactProviderGate plan providerResource =
  gateFor
    (stablePlanSnapshotDigest (renderSnapshot plan))
    (plannedResourceKey providerResource)

mapBudgetError :: Either String a -> Either BudgetError a
mapBudgetError = either (Left . InvalidBudget) Right

joinBudget :: Either BudgetError (Either BudgetError a) -> Either BudgetError a
joinBudget = either Left id

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

budgetPlan :: StepPlan
budgetPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ descendsVia
            localContext
            (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))),
          deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
        ]
    )

withBudgetProjectPlan ::
  ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    PlannedResource
      (Production projectId)
      planId
      providerId
      ProviderResource
      providerFrame ->
    PlannedResource
      (Production projectId)
      planId
      clusterId
      ClusterResource
      clusterFrame ->
    IO result
  ) ->
  IO result
withBudgetProjectPlan consume =
  Fixture.withFixtureProjectPlan budgetPlan $ \plan ->
    case NonEmpty.toList (forward plan) of
      [providerNode, clusterNode] ->
        case
          withPlannedResourceOfKind
            plan
            ProviderResourceKind
            (plannedStepOperationKey providerNode)
            ( \providerResource ->
                withPlannedResourceOfKind
                  plan
                  ClusterResourceKind
                  (plannedStepOperationKey clusterNode)
                  (consume plan providerResource)
            ) of
          Left failure -> fail ("provider projection failed: " ++ show failure)
          Right (Left failure) -> fail ("cluster projection failed: " ++ show failure)
          Right (Right action) -> action
      nodes -> fail ("expected provider and cluster plan nodes, got " ++ show (length nodes))
