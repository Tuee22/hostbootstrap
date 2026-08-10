{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ReconcileSpec (tests) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import qualified Fixture
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Schema (verifiedConfigDigest, withValidatedConfig)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Config.Vocab as Vocab
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Incus (IncusVM (..))
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lift
    ( ConfigDelivery (..)
    , ContainerLift (..)
    , inContainer
    , inVM
    , localContext
    )
import HostBootstrap.ProjectPlan
    ( PlanError
    , ProjectPlan
    , forward
    , plannedEdgeDependencyKey
    , plannedEdgeTargetKey
    , plannedStepDependencyOperations
    , plannedStepFrameId
    , plannedStepIdentity
    , plannedStepOperationKey
    , plannedStepProjectedOperationKeys
    , renderSnapshot
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotDigest
    , withPlannedEdge
    , withPlannedResourceOfKind
    )
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate
    ( Arch (Arm64)
    , Substrate (..)
    , SubstrateName (LinuxCpu)
    )
import PrepareFixture (gateFor)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ReconcileSpec"
    [ testGroup
        "canonical lifecycle plan snapshot"
        [ testCase "is deterministic for the same closed plan vocabulary" $ do
            first <- canonicalSummary "config-a" canonicalFixturePlan
            second <- canonicalSummary "config-a" canonicalFixturePlan
            first @?= second
        , testCase "uses the reserved non-absolute root for compatibility plans" $
            withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \codec ->
              withLifecyclePlan codec canonicalFixturePlan $ \lifecycle ->
                canonicalPlanSnapshotRoot (lifecyclePlanSnapshot lifecycle)
                  @?= "<hostbootstrap:unrooted-lifecycle-plan>"
        , testCase "length framing separates delimiter-shaped field boundaries" $ do
            first <- canonicalSummary "config-a" (singleStepPlan "a|b:c" "frame|one" "label:two")
            second <- canonicalSummary "config-a" (singleStepPlan "a" "frame|one" "b:c|label:two")
            assertBool "distinct framed labels collapsed" (first /= second)
        , testCase "step order and its derived dependency topology are digest material" $ do
            ordered <- canonicalSummary "config-a" orderedCanonicalPlan
            reordered <- canonicalSummary "config-a" reorderedCanonicalPlan
            assertBool
                "a reordered plan retained the same snapshot"
                (ordered /= reordered)
        , testCase "provider and explicit implementation/adapter revisions change the snapshot" $ do
            ubuntu <- canonicalSummary "config-a" (providerCanonicalPlan "images:ubuntu/24.04")
            debian <- canonicalSummary "config-a" (providerCanonicalPlan "images:debian/13")
            assertBool
                "an Incus image substitution retained the same snapshot"
                (ubuntu /= debian)
            defaultImplementation <- canonicalSummary "config-a" defaultReversePlan
            revisedImplementation <- canonicalSummary "config-a" revisedImplementationPlan
            assertBool
                "a forward implementation revision retained the same snapshot"
                (defaultImplementation /= revisedImplementation)
            defaultAdapter <- canonicalSummary "config-a" declaredReversePlan
            revisedAdapter <- canonicalSummary "config-a" revisedReverseAdapterPlan
            assertBool
                "a reverse-adapter revision retained the same snapshot"
                (defaultAdapter /= revisedAdapter)
        , testCase "the exact admitted config digest is substitution-sensitive" $ do
            first <- canonicalSummary "config-a" canonicalFixturePlan
            second <- canonicalSummary "config-b" canonicalFixturePlan
            assertBool
                "a config digest substitution retained the same snapshot"
                (first /= second)
        , testCase "child config contributes only its digest, never payload bytes" $ do
            let secret = "fixture-secret-payload"
            first <- canonicalSummary "config-a" (containerCanonicalPlan secret)
            second <- canonicalSummary "config-a" (containerCanonicalPlan "replacement-payload")
            let firstBytes = fst first
            assertBool
                "the raw child config entered the canonical snapshot"
                (not (TextEncoding.encodeUtf8 secret `ByteString.isInfixOf` firstBytes))
            assertBool "a child config substitution retained the same snapshot" (first /= second)
        ]
    , testGroup
        "exact project-plan execution descriptors"
        [ testCase "retain exact plan, configuration, node, frame, and operation identity" $
            assertExactDescriptorContinuity
        , testCase "retain the projected operations and ordered resource prefix of each node" $
            assertExactDescriptorOperations
        , testCase "the plan-owned producer is total over its exact forward projection" $
            assertExactDescriptorProduction
        , testCase "node resource projection admits own and prefix resources only" $
            assertExactNodeResources
        , testCase "the descriptor runtime carries a managed resource under the same plan" $
            assertExactResourceCarrier
        , testCase "every opaque reconciliation and execution index has a nominal role" $
            assertNominalRoleInventory
        ]
    , testCase "observed resources require stable positive identity versions" $ do
        observed <-
          withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned ->
            pure $
              withObservedPlannedResource plan planned 0 0 (const ())
        observed
          @?= Left
            (Failure (FailureDetail "observe resource" "generation must be positive" DoNotRetry)),
      testCase "prepared created result mints managed handle and receipt together" $
        createdSummary >>= (@?= Right (Changed Created, 7)),
      testCase "foreign observation exposes only the unmanaged branch" $
        foreignSummary >>= (@?= Right "foreign:manual-vm"),
      testCase "explicit matching foreign-origin authority is the only adoption path" $
        adoptionSummary >>= (@?= Right (Changed Adopted)),
      testCase "journal verification rejects another plan digest" $
        journalMismatch >>= (@?= True),
      testCase "only a committed verified record can prove Unchanged" $
        unchangedSummary >>= (@?= Right Unchanged),
      testCase "managed phase transition retains receipt generation" $
        phaseSummary >>= (@?= Right 7),
      testCase "planned edges retain the exact target and dependency identities" $
        plannedEdgeSummary
          >>= (@?= Right ("core:copy-source", "core:deploy-vm")),
      testCase "operation preparation rejects an omitted plan dependency" $ do
        outcome <- missingDependencyPreparation
        case outcome of
          Left (Conflict _) -> pure ()
          other -> fail ("expected dependency conflict, got " ++ show other),
      testCase "a gate recorded for another operation cannot prepare this one" $ do
        outcome <- createdSummaryWithGate (\digest -> gateFor digest "core:deploy-vm")
        case outcome of
          Left (Conflict _) -> pure ()
          other -> fail ("expected a wrong-operation refusal, got " ++ show other),
      testCase "a gate recorded in another plan's journal cannot prepare" $ do
        outcome <- createdSummaryWithGate (\_ -> gateFor "some-other-plan-digest" "core:deploy-kind")
        case outcome of
          Left (Conflict _) -> pure ()
          other -> fail ("expected a wrong-plan refusal, got " ++ show other),
      testCase "the plan edge set names only the resource-bearing prefix" $ do
        -- The demo's own project `ensure` fragment precedes `deploy-vm` and owns
        -- no plan resource, so it contributes no edge; including it would make
        -- `core:copy-source` unsatisfiable rather than stricter (§ CC).
        copySourceDependencies >>= (@?= Right ["core:deploy-vm"]),
      testCase "the traversal seals the resource-bearing edge set it derived" $
        sealedCopySourceKeys >>= (@?= Right ["core:deploy-vm"]),
      testCase "the zero-dependency branch refuses an operation that declares edges" $ do
        outcome <- zeroBranchOnDependentOperation
        case outcome of
          Left (Conflict _) -> pure ()
          other -> fail ("expected a refusal of the zero-dependency branch, got " ++ show other),
      testCase "journal graphs admit only observed success into commit" $ do
        legalJournalTransition ObservedManaged Committed @?= True
        legalJournalTransition ReservationAbsent Committed @?= False
        legalJournalTransition AdoptionObservedManaged AdoptionCommitted @?= True
        legalJournalTransition AdoptionObservedForeign AdoptionCommitted @?= False
        legalJournalTransition RepairObservedTarget RepairCommitted @?= True
        legalJournalTransition RepairObservedOriginal RepairCommitted @?= False
        legalJournalTransition PhaseObservedTo PhaseCommitted @?= True
        legalJournalTransition PhaseObservedFrom PhaseCommitted @?= False,
      testCase "journal advancement increments the durable version and refuses illegal edges" $ do
        let initial = journalRecord "spec" IntentRecorded
        fmap persistedRecordVersion (advancePersistedJournalRecord initial ReservationOutcomeUnknown)
          @?= Right 5
        case advancePersistedJournalRecord initial Committed of
          Left (SafetyRefusal _) -> pure ()
          other -> fail ("expected illegal-transition refusal, got " ++ show other)
    ]

assertExactDescriptorContinuity :: IO ()
assertExactDescriptorContinuity =
  Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
    carrier <- Execution.newResourceCarrier
    let snapshot = renderSnapshot plan
    executions <-
      forM (NonEmpty.toList (forward plan)) $ \node -> do
        runtime <- Execution.newStepRuntime carrier
        pure (node, stepExecutionFor plan exactExecutionHostConfig runtime node)
    mapM_
      ( \(node, execution) ->
          ( Execution.stepExecutionPlanDigest execution
          , Execution.stepExecutionConfigDigest execution
          , Execution.stepExecutionNodeIdentity execution
          , Execution.stepExecutionFrame execution
          , Execution.stepExecutionOperationKey execution
          )
            @?= ( stablePlanSnapshotDigest snapshot
                , stablePlanSnapshotConfigDigest snapshot
                , Text.pack (show (plannedStepIdentity node))
                , plannedStepFrameId node
                , Text.pack (operationKeyText (plannedStepOperationKey node))
                )
      )
      executions

assertExactDescriptorOperations :: IO ()
assertExactDescriptorOperations =
  Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
    carrier <- Execution.newResourceCarrier
    executions <-
      forM (NonEmpty.toList (forward plan)) $ \node -> do
        runtime <- Execution.newStepRuntime carrier
        pure (node, stepExecutionFor plan exactExecutionHostConfig runtime node)
    mapM_
      ( \(node, execution) ->
          ( Execution.stepExecutionDependencyKeys execution
          , Execution.stepExecutionProjectedOperations execution
          )
            @?= ( map
                    (Text.pack . operationKeyText . fst)
                    (plannedStepDependencyOperations node)
                , map
                    (Text.pack . operationKeyText)
                    (plannedStepProjectedOperationKeys node)
                )
      )
      executions

assertExactDescriptorProduction :: IO ()
assertExactDescriptorProduction =
  Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
    carrier <- Execution.newResourceCarrier
    executions <-
      forM (NonEmpty.toList (forward plan)) $ \node -> do
        runtime <- Execution.newStepRuntime carrier
        pure (stepExecutionFor plan exactExecutionHostConfig runtime node)
    length executions @?= NonEmpty.length (forward plan)

assertExactNodeResources :: IO ()
assertExactNodeResources =
  Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
    carrier <- Execution.newResourceCarrier
    executions <-
      forM (NonEmpty.toList (forward plan)) $ \node -> do
        runtime <- Execution.newStepRuntime carrier
        pure (stepExecutionFor plan exactExecutionHostConfig runtime node)
    case executions of
      [providerExecution, _shareExecution, clusterExecution] -> do
        withNodeResourceOfKind
          clusterExecution
          ProviderResourceKind
          "core:deploy-vm"
          (\resource -> (plannedResourceKey resource, plannedResourceFrame resource))
          @?= Right ("core:deploy-vm", "host")
        withNodeResourceOfKind
          clusterExecution
          DurableShareResourceKind
          "core:copy-source"
          (\resource -> (plannedResourceKey resource, plannedResourceFrame resource))
          @?= Right ("core:copy-source", "host")
        withNodeResourceOfKind
          clusterExecution
          ClusterResourceKind
          "core:deploy-kind"
          (\resource -> (plannedResourceKey resource, plannedResourceFrame resource))
          @?= Right ("core:deploy-kind", "host")
        case
            withNodeResourceOfKind
              providerExecution
              ClusterResourceKind
              "core:deploy-kind"
              (const ())
          of
            Left (Failure _) -> pure ()
            other -> fail ("expected an out-of-prefix refusal, got " ++ show other)
      other -> fail ("expected three exact execution descriptors, got " ++ show (length other))

assertExactResourceCarrier :: IO ()
assertExactResourceCarrier =
  Fixture.withFixtureProjectPlan testPlan $ \plan ->
    case NonEmpty.toList (forward plan) of
      [node] -> do
        carrier <- Execution.newResourceCarrier
        runtime <- Execution.newStepRuntime carrier
        let execution = stepExecutionFor plan exactExecutionHostConfig runtime node
            operationKey = Text.pack (operationKeyText (plannedStepOperationKey node))
        gate <- gateFor (Execution.stepExecutionPlanDigest execution) operationKey
        let acquireAndCarry =
              joinReconcile $
                withNodeResourceOfKind execution ClusterResourceKind operationKey $ \planned ->
                  joinReconcile $
                    withNodeObservedResource execution planned 5 7 $ \observed -> do
                      descriptor <- plannedNodeOperation execution planned observed "cluster:create"
                      preconditions <- zeroDependencyPreconditions descriptor
                      joinReconcile $
                        withPreparedOperation descriptor preconditions gate $ \prepared sealed -> do
                          reconciled <-
                            completeReconcile observed prepared sealed (BackendCreated 5)
                          withReconcileResult
                            reconciled
                            (\managed _ _ -> Right (carryManagedResource execution managed))
                            ( \_ _ ->
                                Left
                                  ( Failure
                                      ( FailureDetail
                                          "exact carrier fixture"
                                          "unexpected foreign resource"
                                          DoNotRetry
                                      )
                                  )
                            )
        case acquireAndCarry of
          Left failure -> fail (show failure)
          Right carry -> carry
        Execution.carriedResourceKeys carrier >>= (@?= [operationKey])
        readback <-
          withCarriedManagedResource execution operationKey $ \handle ->
            ( resourceHandleKey handle
            , resourceHandleGeneration handle
            , resourceHandleObservationVersion handle
            )
        readback @?= Right (operationKey, 5, 7)
      nodes -> fail ("expected one exact carrier node, got " ++ show (length nodes))

assertNominalRoleInventory :: IO ()
assertNominalRoleInventory = do
  cwd <- getCurrentDirectory
  root <-
    findRepoRoot cwd
      >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
  let sourceRoot =
        root
          </> "core"
          </> "hostbootstrap-core"
          </> "src"
          </> "HostBootstrap"
  reconcileSource <- TextIO.readFile (sourceRoot </> "Reconcile.hs")
  executionSource <-
    TextIO.readFile
      (sourceRoot </> "Lifecycle" </> "Execution" </> "Internal.hs")
  roleLines reconcileSource @?= reconcileRoleInventory
  roleLines executionSource @?= executionRoleInventory
  where
    roleLines =
      filter ("type role " `Text.isPrefixOf`)
        . map Text.strip
        . Text.lines

reconcileRoleInventory :: [Text.Text]
reconcileRoleInventory =
  [ "type role LifecyclePlan nominal nominal"
  , "type role ResourceHandle nominal nominal nominal nominal nominal nominal"
  , "type role OwnershipReceipt nominal nominal nominal nominal"
  , "type role VerifiedForeignOrigin nominal nominal nominal nominal nominal"
  , "type role AdoptionAuthority nominal nominal nominal nominal nominal nominal"
  , "type role OperationDescriptor nominal nominal nominal nominal nominal nominal"
  , "type role DependencyObservation nominal nominal nominal nominal"
  , "type role DependencyProbe nominal nominal nominal nominal"
  , "type role DependencySnapshotEntry nominal nominal"
  , "type role DependencySnapshot nominal nominal"
  , "type role OperationPreconditionSet nominal nominal nominal nominal"
  , "type role PreparedOperation nominal nominal nominal nominal nominal nominal nominal nominal"
  , "type role PreparedPreconditions nominal nominal nominal nominal nominal nominal nominal nominal"
  , "type role SomeDependencyObservation nominal nominal"
  , "type role ReconcileResult nominal nominal nominal nominal nominal"
  , "type role VerifiedJournalRecord nominal nominal nominal nominal"
  , "type role PriorCommitProof nominal nominal nominal nominal"
  , "type role PhaseTransition nominal nominal nominal nominal nominal nominal"
  , "type role PreparedPhaseTransition nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal"
  , "type role VerifiedAtPhase nominal nominal nominal nominal nominal"
  , "type role PhaseAdvance nominal nominal nominal nominal nominal"
  ]

executionRoleInventory :: [Text.Text]
executionRoleInventory =
  [ "type role StepExecution nominal nominal"
  , "type role StepRuntime nominal nominal"
  , "type role ResourceCarrier nominal nominal"
  ]

exactExecutionHostConfig :: HostConfig
exactExecutionHostConfig =
  HostConfig
    { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Arm64}
    , hcToolPaths = Map.empty
    }

exactExecutionPlan :: StepPlan
exactExecutionPlan =
  planFrom
    [ deployVMStep "provider" exactExecutionFrame (const (pure StepChanged))
    , projectsOperation "core:deploy-vm/core:copy-source/guest-alias" $
        copySourceStep "durable share" exactExecutionFrame (const (pure StepChanged))
    , deployKindStep "cluster" exactExecutionFrame (const (pure StepChanged))
    ]

exactExecutionFrame :: StepFrame
exactExecutionFrame = StepFrame "host" "Host"

canonicalSummary :: Text.Text -> StepPlan -> IO (ByteString.ByteString, Text.Text)
canonicalSummary configRoot plan =
  withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \codec ->
    do
      admitted <-
        withValidatedConfig
          codec
          (Fixture.defaultProjectConfig "hostbootstrap-demo" configRoot Context.HostOrchestrator)
          ( \wire _ ->
              pure
                ( withLifecyclePlanForConfig codec (verifiedConfigDigest wire) plan $ \lifecycle ->
                    (lifecyclePlanSnapshotBytes lifecycle, lifecyclePlanDigest lifecycle)
                )
          )
      either fail pure admitted

canonicalFixturePlan :: StepPlan
canonicalFixturePlan = singleStepPlan "context" "host" "Host"

singleStepPlan :: String -> String -> String -> StepPlan
singleStepPlan label fid frameName =
  either
    (error . show)
    id
    (mkStepPlan [contextInitStep label (StepFrame fid frameName) (const (pure StepChanged))])

orderedCanonicalPlan :: StepPlan
orderedCanonicalPlan =
  planFrom
    [ ensureStep "ghc" "ensure" (StepFrame "host" "Host") (const (pure StepChanged))
    , contextInitStep "context" (StepFrame "host" "Host") (const (pure StepChanged))
    ]

reorderedCanonicalPlan :: StepPlan
reorderedCanonicalPlan =
  planFrom
    [ contextInitStep "context" (StepFrame "host" "Host") (const (pure StepChanged))
    , ensureStep "ghc" "ensure" (StepFrame "host" "Host") (const (pure StepChanged))
    ]

providerCanonicalPlan :: String -> StepPlan
providerCanonicalPlan image =
  planFrom
    [ descendsVia
        (inVM (IncusVM "fixture-vm" image) localContext)
        (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged)))
    , contextInitStep "context" (StepFrame "vm" "VM") (const (pure StepChanged))
    ]

defaultReversePlan :: StepPlan
defaultReversePlan =
  singleStepCore (deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged)))

declaredReversePlan :: StepPlan
declaredReversePlan =
  singleStepCore
    ( reversedBy
        (\_ _ -> pure TeardownReleased)
        (deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged)))
    )

revisedImplementationPlan :: StepPlan
revisedImplementationPlan =
  singleStepCore
    ( implementedAt
        (either error id (mkStepImplementationRevision 2))
        (deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged)))
    )

revisedReverseAdapterPlan :: StepPlan
revisedReverseAdapterPlan =
  singleStepCore
    ( reversedByAt
        (either error id (mkStepReverseAdapterRevision 2))
        (\_ _ -> pure TeardownReleased)
        (deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged)))
    )

containerCanonicalPlan :: Text.Text -> StepPlan
containerCanonicalPlan payload =
  planFrom
    [ descendsVia
        (inContainer container localContext)
        (buildImageStep "image" (StepFrame "host" "Host") (const (pure StepChanged)))
    , contextInitStep "context" (StepFrame "container" "Container") (const (pure StepChanged))
    ]
  where
    container =
      ContainerLift
        { clImage = "fixture:latest"
        , clMounts = [Vocab.Mount "/host" "/guest" True]
        , clExtraArgs = ["--network=host"]
        , clRemoveAfter = True
        , clConfigDelivery = Just (ConfigDelivery "/app/config.dhall" "/app/pb" payload)
        }

singleStepCore :: Step -> StepPlan
singleStepCore step = planFrom [step]

planFrom :: [Step] -> StepPlan
planFrom = either (error . show) id . mkStepPlan

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    (mkStepPlan [deployKindStep "cluster" (StepFrame "host" "Host") (const (pure StepChanged))])

dependentTestPlan :: StepPlan
dependentTestPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged))),
          copySourceStep "durable share" (StepFrame "vm" "VM") (const (pure StepChanged))
        ]
    )

createdSummaryWithGate ::
  (Text.Text -> IO PreparedGate) ->
  IO (Either ReconcileError (ChangeView, Word))
createdSummaryWithGate openGate =
  withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
    gate <- openGate (lifecyclePlanDigest plan)
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "call:one"
          preconditionSet <- zeroDependencyPreconditions descriptor
          joinReconcile $
            withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
              result <- completeReconcile handle prepared preconditions (BackendCreated 7)
              pure $
                withReconcileResult
                  result
                  (\managed _receipt change -> (change, fromIntegral (resourceHandleGeneration managed)))
                  (\_ _ -> error "created resource must not be foreign")

createdSummary :: IO (Either ReconcileError (ChangeView, Word))
createdSummary = createdSummaryWithGate (\digest -> gateFor digest "core:deploy-kind")

foreignSummary :: IO (Either ReconcileError String)
foreignSummary =
  withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
    gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "call:one"
          preconditionSet <- zeroDependencyPreconditions descriptor
          joinReconcile $
            withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
              result <-
                completeReconcile
                  handle
                  prepared
                  preconditions
                  (BackendForeign 9 (ForeignObservation "manual-vm" "not owned"))
              pure $
                withReconcileResult
                  result
                  (\_ _ _ -> error "foreign resource must not be managed")
                  (\_ observation -> "foreign:" ++ Text.unpack (foreignIdentity observation))

adoptionSummary :: IO (Either ReconcileError ChangeView)
adoptionSummary =
  withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
    gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "call:observe-foreign"
          preconditionSet <- zeroDependencyPreconditions descriptor
          joinReconcile $
            withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
              foreignResult <-
                completeReconcile
                  handle
                  prepared
                  preconditions
                  (BackendForeign 7 (ForeignObservation "manual-vm" "not owned"))
              withReconcileResult
                foreignResult
                (\_ _ _ -> Left (Failure (FailureDetail "test adoption" "expected foreign observation" DoNotRetry)))
                ( \unmanaged observation ->
                    withVerifiedForeignOrigin unmanaged observation $ \origin ->
                      joinReconcile $
                        withAdoptionAuthority plan planned unmanaged origin "vm:adopt" $ \authority -> do
                          adopted <- completeAdoption unmanaged origin authority (BackendRepaired 7)
                          pure $
                            withReconcileResult
                              adopted
                              (\_ _ change -> change)
                              (\_ _ -> error "adoption must return managed ownership")
                )

journalMismatch :: IO Bool
journalMismatch =
  withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned ->
    pure $
      case
        withObservedPlannedResource plan planned 7 3 $ \handle ->
          case verifyPersistedJournalRecord plan handle "acquire" (journalRecord "other" Committed) of
            Left _ -> True
            Right _ -> False of
        Left _ -> True
        Right mismatched -> mismatched

unchangedSummary :: IO (Either ReconcileError ChangeView)
unchangedSummary =
  withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
    gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "call:one"
          preconditionSet <- zeroDependencyPreconditions descriptor
          joinReconcile $
            withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
              verified <-
                verifyPersistedJournalRecord
                  plan
                  handle
                  "acquire"
                  ( (journalRecord (Text.unpack (lifecyclePlanDigest plan)) Committed)
                      { persistedOperationKey = "core:deploy-kind:call:one"
                      }
                  )
              joinReconcile $
                withPriorCommitProof verified $ \proof -> do
                  result <- completePreparedUnchanged handle prepared preconditions proof
                  pure $
                    withReconcileResult
                      result
                      (\_ _ change -> change)
                      (\_ _ -> error "committed unchanged resource must be managed")

phaseSummary :: IO (Either ReconcileError Word)
phaseSummary =
  withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
    gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "call:one"
          preconditionSet <- zeroDependencyPreconditions descriptor
          joinReconcile $
            withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
              result <- completeReconcile handle prepared preconditions (BackendCreated 7)
              withReconcileResult
                result
                ( \managed receipt _ -> do
                    transition <- planMarkReady managed
                    advance <- verifyPhaseTransition managed receipt transition 7
                    pure $
                      withPhaseAdvance advance $ \readyHandle _ _ ->
                        fromIntegral (resourceHandleGeneration readyHandle)
                )
                (\_ _ -> error "created resource must be managed")

plannedEdgeSummary :: IO (Either PlanError (Text.Text, Text.Text))
plannedEdgeSummary =
  Fixture.withFixtureProjectPlan dependentTestPlan $ \plan ->
    case NonEmpty.toList (forward plan) of
      [providerNode, shareNode] ->
        pure $
          joinPlan $
            withPlannedResourceOfKind
              plan
              ProviderResourceKind
              (plannedStepOperationKey providerNode)
              ( \provider ->
                  joinPlan $
                    withPlannedResourceOfKind
                      plan
                      DurableShareResourceKind
                      (plannedStepOperationKey shareNode)
                      ( \share ->
                          withPlannedEdge plan share provider $ \edge ->
                            (plannedEdgeTargetKey edge, plannedEdgeDependencyKey edge)
                      )
              )
      nodes -> fail ("expected two dependency-plan nodes, got " ++ show (length nodes))

{- | A plan shaped like the worked demo's: a project-owned @ensure@ fragment that
carries no plan resource, then the provider, then the durable share.
-}
projectPrefixedPlan :: StepPlan
projectPrefixedPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ projectStep
            (either error id (projectStepId "ensure-vm-provider"))
            PreserveOnReverse
            "ensure the VM provider"
            (StepFrame "host" "Host")
            (const (pure StepChanged)),
          descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged))),
          copySourceStep "durable share" (StepFrame "vm" "VM") (const (pure StepChanged))
        ]
    )

-- | The exact ordered edge set the plan derives for @core:copy-source@.
copySourceDependencies :: IO (Either ReconcileError [Text.Text])
copySourceDependencies =
  withTestResource projectPrefixedPlan DurableShareResourceKind "core:copy-source" $ \_ plan planned ->
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle ->
          operationDescriptorDependencies
            <$> plannedOperation plan planned handle "share:mount"

{- | The same edge set, sealed through the traversal against a snapshot holding
only the managed provider.  Before the resource-bearing filter this could not
succeed at all: the descriptor demanded an observation for the project's own
@ensure@ step, and no 'PlannedResource' — hence no managed handle — exists for it.
-}
sealedCopySourceKeys :: IO (Either ReconcileError [Text.Text])
sealedCopySourceKeys =
  withTestResource projectPrefixedPlan ProviderResourceKind "core:deploy-vm" $
    \projectPlan plan provider -> do
      providerGate <- gateFor (lifecyclePlanDigest plan) "core:deploy-vm"
      case
        find
          ( (== "core:copy-source")
              . Text.pack
              . operationKeyText
              . plannedStepOperationKey
          )
          (NonEmpty.toList (forward projectPlan))
        of
          Nothing -> fail "copy-source node missing from prefixed fixture plan"
          Just shareNode ->
            case
              withPlannedResourceOfKind
                projectPlan
                DurableShareResourceKind
                (plannedStepOperationKey shareNode)
                ( \share ->
                    joinIO $
                      withManagedProvider providerGate plan provider $ \managedProvider ->
                        joinIO $
                          withObservedPlannedResource plan share 11 13 $ \shareHandle ->
                            case plannedOperation plan share shareHandle "share:mount" of
                              Left failure -> pure (Left failure)
                              Right descriptor ->
                                fmap (fmap operationPreconditionKeys) $
                                  withOperationPreconditions
                                    descriptor
                                    ( withDependencySnapshotEntry
                                        managedProvider
                                        (dependencyProbe (pure (Right 17)))
                                        emptyDependencySnapshot
                                    )
                )
              of
                Left failure -> pure (Left (planProjectionFailure failure))
                Right action -> action

-- | Own the provider so the share has a managed dependency to observe.
withManagedProvider ::
  PreparedGate ->
  LifecyclePlan scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ( ResourceHandle scope planId providerId ProviderResource Managed Provisioned ->
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
          reconciled <- completeReconcile observed prepared preconditions (BackendCreated 5)
          withReconcileResult
            reconciled
            (\managed _ _ -> Right (consume managed))
            (\_ _ -> Left (Failure (FailureDetail "test provider" "unexpected foreign provider" DoNotRetry)))

-- | The zero-dependency branch is not a route around the snapshot.
zeroBranchOnDependentOperation :: IO (Either ReconcileError ())
zeroBranchOnDependentOperation =
  withTestResource projectPrefixedPlan DurableShareResourceKind "core:copy-source" $ \_ plan planned ->
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "share:mount"
          () <$ zeroDependencyPreconditions descriptor

missingDependencyPreparation :: IO (Either ReconcileError ())
missingDependencyPreparation =
  withTestResource dependentTestPlan DurableShareResourceKind "core:copy-source" $ \_ plan planned -> do
    gate <- gateFor (lifecyclePlanDigest plan) "core:copy-source"
    pure $
      joinReconcile $
        withObservedPlannedResource plan planned 7 3 $ \handle -> do
          descriptor <- plannedOperation plan planned handle "share:mount"
          preconditionSet <- zeroDependencyPreconditions descriptor
          withPreparedOperation descriptor preconditionSet gate (\_ _ -> ())

journalRecord :: String -> PersistedJournalPhase -> PersistedJournalRecord
journalRecord digest phase =
  PersistedJournalRecord
    { persistedPlanDigest = text digest,
      persistedFrameKey = "metal",
      persistedResourceKey = "core:deploy-kind",
      persistedGeneration = 7,
      persistedOperation = "acquire",
      persistedOperationKey = "core:deploy-kind:call:one",
      persistedRecordVersion = 4,
      persistedPhase = phase
    }

joinReconcile :: Either ReconcileError (Either ReconcileError a) -> Either ReconcileError a
joinReconcile = either Left id

joinPlan :: Either PlanError (Either PlanError a) -> Either PlanError a
joinPlan = either Left id

joinIO :: Either ReconcileError (IO (Either ReconcileError a)) -> IO (Either ReconcileError a)
joinIO = either (pure . Left) id

planProjectionFailure :: PlanError -> ReconcileError
planProjectionFailure failure =
  Failure
    ( FailureDetail
        "project plan projection"
        (Text.pack (show failure))
        DoNotRetry
    )

text :: String -> Text.Text
text = Text.pack

withTestResource ::
  StepPlan ->
  PlannedResourceKind resource ->
  Text.Text ->
  ( forall projectId specDigest planId configId resourceId frame.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    LifecyclePlan (Production projectId) planId ->
    PlannedResource (Production projectId) planId resourceId resource frame ->
    IO result
  ) ->
  IO result
withTestResource stepPlan resourceKind expectedKey use =
  Fixture.withFixtureProjectPlan stepPlan $ \projectPlan ->
    case
      find
        ( (== expectedKey)
            . Text.pack
            . operationKeyText
            . plannedStepOperationKey
        )
        (NonEmpty.toList (forward projectPlan))
      of
        Nothing -> fail ("resource operation missing from fixture plan: " ++ Text.unpack expectedKey)
        Just node ->
          case
            withPlannedResourceOfKind
              projectPlan
              resourceKind
              (plannedStepOperationKey node)
              (use projectPlan (lifecyclePlanFromProjectPlan projectPlan))
            of
              Left failure -> fail (show failure)
              Right action -> action
