{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ReconcileSpec (tests) where

import qualified TestDependency
import Control.Monad (forM, forM_)
import Data.Bits (shiftR)
import qualified Data.ByteString as ByteString
import Data.Char (isAlphaNum, isLower, isUpper)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find, nub, sort)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Incus (IncusVM (..))
import qualified HostBootstrap.Readiness as Readiness
import qualified HostBootstrap.Readiness.Kernel as ProbeKernel
import qualified HostBootstrap.Lifecycle.Execution as Execution
import qualified HostBootstrap.Lifecycle.Execution.Core as ExecutionCore (
    carriedResourceGeneration,
    carriedResourceKey,
    carriedResourceObservationVersion,
    carriedResourceOwnershipOperation,
    carriedResourceSettlement,
    newResourceCarrierCore,
    newStepRuntimeCore,
    readCarriedResources,
 )
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateJournalVersion)
import HostBootstrap.Lift (
    ConfigDelivery (..),
    ContainerLift (..),
    ContainerPlacement (ProviderGuestContainer),
    inContainer,
    inVM,
    localContext,
 )
import HostBootstrap.Lift.Context (emptyVMStack, vmContext)
import HostBootstrap.ProjectPlan (
    PlanError,
    PlannedStepObservation,
    ProjectPlan,
    forward,
    plannedEdgeDependencyKey,
    plannedEdgeTargetKey,
    plannedStepDependencyOperations,
    plannedStepFrameId,
    plannedStepIdentity,
    plannedStepObservationDetail,
    plannedStepObservationSucceeded,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    renderSnapshot,
    runPlannedStep,
    stablePlanSnapshotConfigDigest,
    stablePlanSnapshotDigest,
    stablePlanSnapshotRoot,
    stablePlanSnapshotSpecDigest,
    withChartWorkloadResource,
    withPlannedEdge,
    withPlannedResourceOfKind,
 )
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (
    Arch (Arm64),
    Substrate (..),
    SubstrateName (LinuxCpu),
 )
import PrepareFixture (gateFor, gateForValues)
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

tests :: TestTree
tests =
    testGroup
        "ReconcileSpec"
        [ testGroup
            "canonical lifecycle plan snapshot"
            [ testCase "step order and its derived dependency topology are digest material" $ do
                (ordered, reordered) <- canonicalPairSummaries orderedCanonicalPlan reorderedCanonicalPlan
                assertBool
                    "a reordered plan retained the same snapshot"
                    (ordered /= reordered)
            , testCase "provider and explicit implementation/adapter revisions change the snapshot" $ do
                (ubuntu, debian) <-
                    canonicalPairSummaries
                        (providerCanonicalPlan "images:ubuntu/24.04")
                        (providerCanonicalPlan "images:debian/13")
                assertBool
                    "an Incus image substitution retained the same snapshot"
                    (ubuntu /= debian)
                (defaultImplementation, revisedImplementation) <- canonicalPairSummaries defaultReversePlan revisedImplementationPlan
                assertBool
                    "a forward implementation revision retained the same snapshot"
                    (defaultImplementation /= revisedImplementation)
                (defaultAdapter, revisedAdapter) <- canonicalPairSummaries declaredReversePlan revisedReverseAdapterPlan
                assertBool
                    "a reverse-adapter revision retained the same snapshot"
                    (defaultAdapter /= revisedAdapter)
            , testCase "the exact admitted config digest is substitution-sensitive" $ do
                (first, second) <-
                    Fixture.withFixtureCanonicalSnapshotVariants
                        canonicalFixturePlan
                        canonicalFixturePlan
                        (\config -> config{Fixture.dockerfile = "changed.Dockerfile"})
                        (\base _ changed -> pure (canonicalSnapshotSummary base, canonicalSnapshotSummary changed))
                assertBool
                    "a config digest substitution retained the same snapshot"
                    (first /= second)
            , testCase "child config contributes only its digest, never payload bytes" $ do
                let secret = "fixture-secret-payload"
                (first, second) <-
                    canonicalPairSummaries
                        (containerCanonicalPlan secret)
                        (containerCanonicalPlan "replacement-payload")
                let firstBytes = fst first
                assertBool
                    "the raw child config entered the canonical snapshot"
                    (not (TextEncoding.encodeUtf8 secret `ByteString.isInfixOf` firstBytes))
                assertBool "a child config substitution retained the same snapshot bytes" (fst first /= fst second)
                assertBool "a child config substitution retained the same snapshot digest" (snd first /= snd second)
            , testCase "delivery destination changes canonical bytes and digest" $ do
                (first, second) <-
                    canonicalPairSummaries
                        (containerCanonicalPlanAt "/app/config.dhall" "fixture-secret-payload")
                        (containerCanonicalPlanAt "/other/config.dhall" "fixture-secret-payload")
                assertBool "a delivery destination substitution retained the same snapshot bytes" (fst first /= fst second)
                assertBool "a delivery destination substitution retained the same snapshot digest" (snd first /= snd second)
            , testCase "delivery binding is exactly the two-field filesystem projection" $
                assertCanonicalDeliveryRecord
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
            , testCase "another operation's descriptor in the same plan refuses before the callback" $
                assertSamePlanDescriptorOperationBoundary
            , testCase "another frame's descriptor with the same operation refuses before the callback" $
                assertDescriptorFrameBoundary
            , testCase "owned settlement carries the exact managed receipt under the same plan" $
                assertExactResourceCarrier
            , testCase "a dependent node cannot replace its dependency's carried settlement" $
                assertDependencySettlementBoundary
            , testCase "a declared projected alias carries canonical settlement in its declaring frame" $
                assertProjectedAliasSettlement
            , testCase "a typed carried-resource opener refuses a later resource outside the node prefix" $
                assertTypedCarrierPrefixBoundary
            , testCase "every opaque reconciliation and execution index has a nominal role" $
                assertNominalRoleInventory
            , testCase "the neutral package has one producer and introduces no Plan import cycle" $
                assertPlanExecutionPackageBoundary
            ]
        , testCase "observed resources require stable positive identity versions" $ do
            observed <-
                withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned ->
                    pure $
                        withObservedPlannedResource plan planned 0 0 (const ())
            observed
                @?= Left
                    (Failure (FailureDetail "observe resource" "generation must be positive" DoNotRetry))
        , testCase "positive generations still require a positive observation version" $ do
            observed <-
                withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned ->
                    pure (withObservedPlannedResource plan planned 1 0 (const ()))
            observed
                @?= Left
                    (Failure (FailureDetail "observe resource" "observation version must be positive" DoNotRetry))
        , testCase "chart preparation seals exactly its ready cluster dependency" $
            chartPreparationSummary True False >>= (@?= Right ("core:deploy-chart", ["core:deploy-kind"]))
        , testCase "a GPU-plugin readiness probe cannot satisfy a cluster-API edge" $ do
            calls <- newIORef (0 :: Int)
            outcome <- chartPreparationWithTaggedProbe (Just ProbeKernel.GpuPluginKind)
                (modifyIORef' calls (+ 1) >> pure (Right 8)) False (\_ _ -> ())
            case outcome of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected readiness-kind conflict, got " ++ show other)
            readIORef calls >>= (@?= 0)
        , testCase "chart preparation refuses a failed readiness reprobe" $ do
            outcome <- chartPreparationSummary False False
            case outcome of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected readiness refusal, got " ++ show other)
        , testCase "chart preparation refuses a gate from another operation" $ do
            outcome <- chartPreparationSummary True True
            case outcome of
                Left (Conflict _) -> pure ()
                other -> assertFailure ("expected gate conflict, got " ++ show other)
        , testCase "prepared created result mints managed handle and receipt together" $
            createdSummary >>= (@?= Right (Changed Created, 7))
        , testCase "foreign observation exposes only the unmanaged branch" $
            foreignSummary >>= (@?= Right "foreign:manual-vm")
        , testCase "explicit matching foreign-origin authority is the only adoption path" $
            adoptionSummary >>= (@?= Right (Changed Adopted))
        , testGroup "backend observations and dispositions" backendObservationCases
        , testGroup "adoption origin identity" adoptionOriginCases
        , testCase "journal verification rejects another plan digest" $ do
            (digest, outcome) <- journalMismatch
            outcome
                @?= Left
                    ( Conflict
                        ( ConflictDetail
                            "core:deploy-kind"
                            ("plan digest=" <> digest)
                            "plan digest=other"
                            "load the matching protected journal record"
                        )
                    )
        , testCase "journal verification rejects another frame in the same plan" $
            assertJournalFrameMismatch
        , testCase "only a committed verified record can prove Unchanged" $
            unchangedSummary >>= (@?= Right Unchanged)
        , testGroup "prior commit phases" priorCommitCases
        , testGroup "receipt validation and planned rebinding" receiptCases
        , testGroup "empty durable ownership operations" emptyOperationCases
        , testCase "receipt rebinding has only the plan-bound opener" assertPlannedReceiptRebindingBoundary
        , testCase "managed phase transition retains receipt generation" $
            phaseSummary 9 >>= (@?= Right 9)
        , testCase "managed phase transition refuses the pre-creation generation" $
            phaseSummary 3
                >>= ( @?=
                        Left
                            (Conflict (ConflictDetail "core:deploy-kind" "9" "3" "reprobe the phase transition"))
                    )
        , testCase "provider force destroy is journal-prepared from the exact running handle" $
            providerForceDestroyChecks
                >>= ( @?=
                        Right
                            ( 7
                            , "core:deploy-vm:provider:create"
                            , True
                            , True
                            , True
                            )
                    )
        , testCase "planned edges retain the exact target and dependency identities" $
            plannedEdgeSummary
                >>= (@?= Right ("core:copy-source", "core:deploy-vm"))
        , testCase "operation preparation rejects an omitted plan dependency" $ do
            outcome <- missingDependencyPreparation
            outcome
                @?= Left
                    ( Failure
                        ( FailureDetail
                            "seal operation preconditions"
                            "no managed resource for plan dependency core:deploy-vm of core:copy-source"
                            ReprobeBeforeRetry
                        )
                    )
        , testCase "a gate recorded for another operation cannot prepare this one" $ do
            outcome <- createdSummaryWithGate (\digest -> gateFor digest "core:deploy-vm")
            case outcome of
                Left (Conflict _) -> pure ()
                other -> fail ("expected a wrong-operation refusal, got " ++ show other)
        , testCase "a gate recorded in another plan's journal cannot prepare" $ do
            outcome <- createdSummaryWithGate (\_ -> gateFor "some-other-plan-digest" "core:deploy-kind")
            case outcome of
                Left (Conflict _) -> pure ()
                other -> fail ("expected a wrong-plan refusal, got " ++ show other)
        , testCase "the plan edge set names only the resource-bearing prefix" $ do
            -- The demo's own project `ensure` fragment precedes `deploy-vm` and owns
            -- no plan resource, so it contributes no edge; including it would make
            -- `core:copy-source` unsatisfiable rather than stricter (§ CC).
            copySourceDependencies >>= (@?= Right ["core:deploy-vm"])
        , testCase "the traversal seals the resource-bearing edge set it derived" $
            sealedCopySourceKeys >>= (@?= Right ["core:deploy-vm"])
        , testGroup "explicit zero-dependency preparation" zeroDependencyPreparationCases
        , testGroup "fresh snapshot preparation" freshSnapshotPreparationCases
        , testCase "canonical preparation has exactly the fresh and pure zero-edge entry families" $
            assertCanonicalPreparationSurface
        , testCase "journal graphs admit only observed success into commit" $ do
            legalJournalTransition ObservedManaged Committed @?= True
            legalJournalTransition ReservationAbsent Committed @?= False
            legalJournalTransition AdoptionObservedManaged AdoptionCommitted @?= True
            legalJournalTransition AdoptionObservedForeign AdoptionCommitted @?= False
            legalJournalTransition RepairObservedTarget RepairCommitted @?= True
            legalJournalTransition RepairObservedOriginal RepairCommitted @?= False
            legalJournalTransition PhaseObservedTo PhaseCommitted @?= True
            legalJournalTransition PhaseObservedFrom PhaseCommitted @?= False
        , testCase "journal advancement increments the durable version and refuses illegal edges" $ do
            let initial = journalRecord "spec" "metal" IntentRecorded
            fmap persistedRecordVersion (advancePersistedJournalRecord initial ReservationOutcomeUnknown)
                @?= Right 5
            case advancePersistedJournalRecord initial Committed of
                Left (SafetyRefusal _) -> pure ()
                other -> fail ("expected illegal-transition refusal, got " ++ show other)
        ]

assertExactDescriptorContinuity :: IO ()
assertExactDescriptorContinuity =
    Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
        carrier <- ExecutionCore.newResourceCarrierCore
        let snapshot = renderSnapshot plan
        executions <-
            forM (NonEmpty.toList (forward plan)) $ \node -> do
                runtime <- ExecutionCore.newStepRuntimeCore carrier
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

assertPlanExecutionPackageBoundary :: IO ()
assertPlanExecutionPackageBoundary =
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- SourceGuard.readPackageDescription
        sources <- SourceGuard.mainImplementationSources packageRoot description
        let modules = [(name, body) | (name, _, body) <- sources]
            planModule = "HostBootstrap.Lifecycle.Plan"
            internalModule = "HostBootstrap.Lifecycle.Execution.Internal"
            reconcileModule = "HostBootstrap.Reconcile"
            expectedSites = [(internalModule, "mintPlanExecutionPackage", 1), (reconcileModule, "stepExecutionFor", 1)]
            internalFixture = "module HostBootstrap.Lifecycle.Execution.Internal where\nmintPlanExecutionPackage = Package\n"
            reconcileFixture = "module HostBootstrap.Reconcile where\nimport HostBootstrap.Lifecycle.Execution.Internal (mintPlanExecutionPackage)\nstepExecutionFor = mintPlanExecutionPackage\n"
        execution <- maybe (assertFailure "Execution.Internal source missing") pure (lookup internalModule modules)
        child <- maybe (assertFailure "Command.Child source missing") pure (lookup "HostBootstrap.Command.Child" modules)
        assertBool "Execution.Internal imports the plan kernel" (not (SourceGuard.importsModule planModule execution))
        sites <- either assertFailure pure (executionPackageSites modules)
        sites @?= expectedSites
        forM_
            [ "import qualified HostBootstrap.Lifecycle.Plan as Plan"
            , "import {-# SOURCE #-} qualified HostBootstrap.Lifecycle.Plan as Plan"
            ] $ \actualImport ->
                SourceGuard.importsModule planModule actualImport @?= True
        SourceGuard.importsModule planModule "-- import HostBootstrap.Lifecycle.Plan\ntext = \"import HostBootstrap.Lifecycle.Plan\"" @?= False
        executionPackageSites [(internalModule, internalFixture), (reconcileModule, reconcileFixture)] @?= Right expectedSites
        executionPackageSites [(internalModule, internalFixture), (reconcileModule, reconcileFixture <> "-- mintPlanExecutionPackage\ntext = \"mintPlanExecutionPackage\"\n")]
            @?= Right expectedSites
        executionPackageSites [(reconcileModule, "module HostBootstrap.Reconcile (mintPlanExecutionPackage) where\nimport HostBootstrap.Lifecycle.Execution.Internal (mintPlanExecutionPackage)\nstepExecutionFor = ()\n")]
            @?= Right []
        executionPackageSites [("Extra", "module Extra where\nimport qualified HostBootstrap.Lifecycle.Execution.Internal as Execution\nextra = Execution.mintPlanExecutionPackage\n")]
            @?= Right [("Extra", "extra", 1)]
        executionPackageSites [("Extra", "module Extra where\nextra True = ()\nextra False = mintPlanExecutionPackage\n")]
            @?= Right [("Extra", "extra", 1)]
        assertBool "the recursive forward frame uses its plan-indexed opener" ("withOpenedFrameExecutorForPlanKernel" `elem` SourceGuard.haskellTokens child)
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "(ExecutionNode, Step, PlannedStep scope planId configId (cfg scope))") child @?= 1
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "stepExecutionFor plan host stepRuntime planned") child @?= 1

-- DEVELOPMENT_PLAN/rationale.md#reconciliation-guards-inspect-actual-producers
-- Imports, exports and signatures cannot stand in for a real producer body.
executionPackageSites :: [(String, String)] -> Either String [(String, String, Int)]
executionPackageSites sources = sort . concat <$> traverse moduleSites sources
  where
    moduleSites (_, source)
        | SourceGuard.countHaskellIdentifier "mintPlanExecutionPackage" source == 0 = Right []
    moduleSites (moduleName, source) = do
        names <- SourceGuard.haskellDefinitionNames source
        concat <$> traverse (bindingSites moduleName source) (filter valueName names)
    bindingSites moduleName source name = do
        clauses <- case SourceGuard.haskellDefinitionClauseTokens name source of
            Right tokens -> Right tokens
            Left missing | missing == "value definition missing: " <> name -> Right []
            Left failure -> Left failure
        let occurrences = length (filter (== "mintPlanExecutionPackage") (concat clauses))
        pure [(moduleName, name, occurrences) | occurrences > 0]
    valueName (first : _) = isLower first || first == '_'
    valueName [] = False

assertExactDescriptorOperations :: IO ()
assertExactDescriptorOperations =
    Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
        carrier <- ExecutionCore.newResourceCarrierCore
        executions <-
            forM (NonEmpty.toList (forward plan)) $ \node -> do
                runtime <- ExecutionCore.newStepRuntimeCore carrier
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
        carrier <- ExecutionCore.newResourceCarrierCore
        let snapshot = renderSnapshot plan
        executions <-
            forM (NonEmpty.toList (forward plan)) $ \node -> do
                runtime <- ExecutionCore.newStepRuntimeCore carrier
                let execution = stepExecutionFor plan exactExecutionHostConfig runtime node
                pure
                    ( Execution.stepExecutionNodeIdentity execution
                    , Execution.stepExecutionOperationKey execution
                    , Execution.stepExecutionFrame execution
                    , Execution.stepExecutionDependencyKeys execution
                    , Execution.stepExecutionProjectedOperations execution
                    , Execution.stepExecutionPlanDigest execution
                    , Execution.stepExecutionSpecDigest execution
                    , Execution.stepExecutionConfigDigest execution
                    )
        executions
            @?= [ ( Text.pack (show (plannedStepIdentity node))
                  , Text.pack (operationKeyText (plannedStepOperationKey node))
                  , plannedStepFrameId node
                  , map (Text.pack . operationKeyText . fst) (plannedStepDependencyOperations node)
                  , map (Text.pack . operationKeyText) (plannedStepProjectedOperationKeys node)
                  , stablePlanSnapshotDigest snapshot
                  , stablePlanSnapshotSpecDigest snapshot
                  , stablePlanSnapshotConfigDigest snapshot
                  )
                | node <- NonEmpty.toList (forward plan)
                ]

assertSamePlanDescriptorOperationBoundary :: IO ()
assertSamePlanDescriptorOperationBoundary = do
    firstCallbacks <- newIORef (0 :: Int)
    secondCallbacks <- newIORef (0 :: Int)
    let node name callbacks =
            projectStep
                (either error id (projectStepId name))
                PreserveOnReverse
                name
                exactExecutionFrame
                (\_ -> modifyIORef' callbacks (+ 1) >> pure StepChanged)
        steps = planFrom [node "node-a" firstCallbacks, node "node-b" secondCallbacks]
    Fixture.withFixtureProjectPlan steps $ \plan ->
        case NonEmpty.toList (forward plan) of
            [first, second] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                firstRuntime <- ExecutionCore.newStepRuntimeCore carrier
                secondRuntime <- ExecutionCore.newStepRuntimeCore carrier
                let firstExecution = stepExecutionFor plan exactExecutionHostConfig firstRuntime first
                    secondExecution = stepExecutionFor plan exactExecutionHostConfig secondRuntime second
                (Text.pack (operationKeyText (plannedStepOperationKey first)), plannedStepFrameId first)
                    @?= ("project:node-a", "host")
                (Execution.stepExecutionOperationKey secondExecution, Execution.stepExecutionFrame secondExecution)
                    @?= ("project:node-b", "host")
                refused <- runPlannedStep first secondExecution
                assertPlannedObservation
                    (StepRefused "planned step project:node-a in frame host cannot run descriptor project:node-b in frame host")
                    refused
                readIORef firstCallbacks >>= (@?= 0)
                readIORef secondCallbacks >>= (@?= 0)
                runPlannedStep first firstExecution >>= assertPlannedObservation StepChanged
                readIORef firstCallbacks >>= (@?= 1)
                readIORef secondCallbacks >>= (@?= 0)
                runPlannedStep second secondExecution >>= assertPlannedObservation StepChanged
                readIORef firstCallbacks >>= (@?= 1)
                readIORef secondCallbacks >>= (@?= 1)
            nodes -> assertFailure ("expected two genuine same-frame nodes, got " <> show (length nodes))

assertDescriptorFrameBoundary :: IO ()
assertDescriptorFrameBoundary = do
    firstCallbacks <- newIORef (0 :: Int)
    secondCallbacks <- newIORef (0 :: Int)
    let graph frame callbacks =
            planFrom
                [ contextInitStep
                    "frame-local context"
                    (StepFrame frame "Host")
                    (\_ -> modifyIORef' callbacks (+ 1) >> pure StepChanged)
                ]
    Fixture.withFixtureProjectPlanPair
        (graph "first-frame" firstCallbacks)
        (graph "second-frame" secondCallbacks) $ \firstPlan secondPlan ->
            case (NonEmpty.toList (forward firstPlan), NonEmpty.toList (forward secondPlan)) of
                ([first], [second]) -> do
                    let firstSnapshot = renderSnapshot firstPlan
                        secondSnapshot = renderSnapshot secondPlan
                    stablePlanSnapshotRoot firstSnapshot @?= stablePlanSnapshotRoot secondSnapshot
                    stablePlanSnapshotSpecDigest firstSnapshot @?= stablePlanSnapshotSpecDigest secondSnapshot
                    stablePlanSnapshotConfigDigest firstSnapshot @?= stablePlanSnapshotConfigDigest secondSnapshot
                    firstCarrier <- ExecutionCore.newResourceCarrierCore
                    secondCarrier <- ExecutionCore.newResourceCarrierCore
                    firstRuntime <- ExecutionCore.newStepRuntimeCore firstCarrier
                    secondRuntime <- ExecutionCore.newStepRuntimeCore secondCarrier
                    let firstExecution = stepExecutionFor firstPlan exactExecutionHostConfig firstRuntime first
                        secondExecution = stepExecutionFor secondPlan exactExecutionHostConfig secondRuntime second
                    (Text.pack (operationKeyText (plannedStepOperationKey first)), plannedStepFrameId first)
                        @?= ("core:context-init", "first-frame")
                    (Execution.stepExecutionOperationKey secondExecution, Execution.stepExecutionFrame secondExecution)
                        @?= ("core:context-init", "second-frame")
                    refused <- runPlannedStep first (alignDescriptorPlanForRefusal secondExecution)
                    assertPlannedObservation
                        (StepRefused "planned step core:context-init in frame first-frame cannot run descriptor core:context-init in frame second-frame")
                        refused
                    readIORef firstCallbacks >>= (@?= 0)
                    readIORef secondCallbacks >>= (@?= 0)
                    runPlannedStep first firstExecution >>= assertPlannedObservation StepChanged
                    readIORef firstCallbacks >>= (@?= 1)
                    readIORef secondCallbacks >>= (@?= 0)
                    runPlannedStep second secondExecution >>= assertPlannedObservation StepChanged
                    readIORef firstCallbacks >>= (@?= 1)
                    readIORef secondCallbacks >>= (@?= 1)
                (first, second) -> assertFailure ("expected singleton admitted plans, got " <> show (length first, length second))

-- Only this defensive negative substitutes a plan brand; the genuine scope is retained.
alignDescriptorPlanForRefusal ::
    Execution.StepExecution scope sourcePlanId ->
    Execution.StepExecution scope targetPlanId
alignDescriptorPlanForRefusal = unsafeCoerce

assertPlannedObservation :: StepObservation -> PlannedStepObservation scope planId configId -> IO ()
assertPlannedObservation expected observed = do
    plannedStepObservationSucceeded observed @?= observationSucceeded expected
    plannedStepObservationDetail observed @?= observationDetail expected

assertExactNodeResources :: IO ()
assertExactNodeResources =
    Fixture.withFixtureProjectPlan exactExecutionPlan $ \plan -> do
        carrier <- ExecutionCore.newResourceCarrierCore
        executions <-
            forM (NonEmpty.toList (forward plan)) $ \node -> do
                runtime <- ExecutionCore.newStepRuntimeCore carrier
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
                case withNodeResourceOfKind
                    providerExecution
                    ClusterResourceKind
                    "core:deploy-kind"
                    (const ()) of
                    Left (Failure _) -> pure ()
                    other -> fail ("expected an out-of-prefix refusal, got " ++ show other)
            other -> fail ("expected three exact execution descriptors, got " ++ show (length other))

assertTypedCarrierPrefixBoundary :: IO ()
assertTypedCarrierPrefixBoundary =
    Fixture.withFixtureProjectPlan fixturePlan $ \plan ->
        case NonEmpty.toList (forward plan) of
            [earlyNode, clusterNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                earlyRuntime <- ExecutionCore.newStepRuntimeCore carrier
                clusterRuntime <- ExecutionCore.newStepRuntimeCore carrier
                let earlyExecution = stepExecutionFor plan exactExecutionHostConfig earlyRuntime earlyNode
                    clusterExecution = stepExecutionFor plan exactExecutionHostConfig clusterRuntime clusterNode
                    operationKey = Text.pack (operationKeyText (plannedStepOperationKey clusterNode))
                gate <- gateFor (Execution.stepExecutionPlanDigest clusterExecution) operationKey
                -- Resolve through the plan: narrowing through the early node
                -- would refuse before the carried-resource opener under test.
                case withPlannedResourceOfKind plan ClusterResourceKind (plannedStepOperationKey clusterNode) $ \planned -> do
                    let acquireAndCarry =
                            joinReconcile $
                                withNodeObservedResource clusterExecution planned 5 7 $ \observed -> do
                                    descriptor <- plannedNodeOperation clusterExecution planned observed "cluster:create"
                                    joinReconcile $
                                        withPreparedZeroDependencyOperation descriptor gate $ \prepared sealed -> do
                                            reconciled <- completeReconcile observed prepared sealed (BackendCreated 5)
                                            withReconcileResult
                                                reconciled
                                                ( \managed receipt _ ->
                                                    Right (carryManagedResourceSettlement clusterExecution managed receipt "provisioned" "cluster-adapter-1")
                                                )
                                                (\_ _ -> Left (Failure (FailureDetail "typed carrier fixture" "unexpected foreign resource" DoNotRetry)))
                    carry <- either (assertFailure . show) pure acquireAndCarry
                    carry >>= either (assertFailure . show) pure
                    Execution.carriedResourceKeys carrier >>= (@?= [operationKey])
                    owned <-
                        withCarriedManagedResourceOfKind clusterExecution planned $ \handle ->
                            (resourceHandleKey handle, resourceHandleGeneration handle, resourceHandleObservationVersion handle)
                    owned @?= Right (operationKey, 5, 7)
                    callbacks <- newIORef (0 :: Int)
                    attempted <-
                        withCarriedManagedResourceOfKind earlyExecution planned $ \_ ->
                            modifyIORef' callbacks (+ 1)
                    -- Execute a mistakenly returned IO action before checking it.
                    executed <- traverse id attempted
                    callbackCount <- readIORef callbacks
                    (executed, callbackCount)
                        @?= ( Left
                                ( Conflict
                                    ( ConflictDetail
                                        operationKey
                                        "this node's own operation or a member of its plan dependency prefix"
                                        "an operation this node neither owns nor depends on"
                                        "declare the dependency in the plan before adopting its handle"
                                    )
                                )
                            , 0
                            ) of
                    Left failure -> assertFailure (show failure)
                    Right action -> action
            nodes -> assertFailure ("expected early and cluster nodes, got " ++ show (length nodes))
  where
    fixturePlan =
        planFrom
            [ projectStep (either error id (projectStepId "early")) PreserveOnReverse "early" exactExecutionFrame (const (pure StepChanged))
            , deployKindStep "cluster" exactExecutionFrame (const (pure StepChanged))
            ]

assertExactResourceCarrier :: IO ()
assertExactResourceCarrier =
    Fixture.withFixtureProjectPlan testPlan $ \plan ->
        case NonEmpty.toList (forward plan) of
            [node] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                runtime <- ExecutionCore.newStepRuntimeCore carrier
                let execution = stepExecutionFor plan exactExecutionHostConfig runtime node
                    operationKey = Text.pack (operationKeyText (plannedStepOperationKey node))
                gate <- gateFor (Execution.stepExecutionPlanDigest execution) operationKey
                let acquireAndCarry =
                        joinReconcile $
                            withNodeResourceOfKind execution ClusterResourceKind operationKey $ \planned ->
                                joinReconcile $
                                    withNodeObservedResource execution planned 5 7 $ \observed -> do
                                        descriptor <- plannedNodeOperation execution planned observed "cluster:create"
                                        joinReconcile $
                                            withPreparedZeroDependencyOperation descriptor gate $ \prepared sealed -> do
                                                reconciled <-
                                                    completeReconcile observed prepared sealed (BackendCreated 5)
                                                withReconcileResult
                                                    reconciled
                                                    ( \managed receipt _ ->
                                                        Right
                                                            ( carryManagedResourceSettlement
                                                                execution
                                                                managed
                                                                receipt
                                                                "provisioned"
                                                                "cluster-adapter-1"
                                                            )
                                                    )
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
                    Right carry -> carry >>= either (fail . show) pure
                Execution.carriedResourceKeys carrier >>= (@?= [operationKey])
                readback <-
                    withCarriedManagedResource execution operationKey $ \handle ->
                        ( resourceHandleKey handle
                        , resourceHandleGeneration handle
                        , resourceHandleObservationVersion handle
                        )
                readback @?= Right (operationKey, 5, 7)
                ownedReadback <-
                    withCarriedManagedResourceReceipt execution operationKey $ \handle receipt ->
                        ( resourceHandleKey handle
                        , resourceHandleGeneration handle
                        , resourceHandleObservationVersion handle
                        , ownershipReceiptOperationKey receipt
                        , validateOwnershipReceipt handle receipt
                        )
                ownedReadback @?= Right (operationKey, 5, 7, operationKey <> ":cluster:create", Right ())
                outside <- withCarriedManagedResourceReceipt execution "outside:resource" (\_ _ -> ())
                case outside of
                    Left (Conflict _) -> pure ()
                    other -> assertFailure ("expected foreign carried ownership refusal, got " ++ show other)
                freshCarrier <- ExecutionCore.newResourceCarrierCore
                freshRuntime <- ExecutionCore.newStepRuntimeCore freshCarrier
                let freshExecution = stepExecutionFor plan exactExecutionHostConfig freshRuntime node
                missing <- withCarriedManagedResourceReceipt freshExecution operationKey (\_ _ -> ())
                case missing of
                    Left (Failure _) -> pure ()
                    other -> assertFailure ("expected fresh-carrier ownership refusal, got " ++ show other)
            nodes -> fail ("expected one exact carrier node, got " ++ show (length nodes))

assertDependencySettlementBoundary :: IO ()
assertDependencySettlementBoundary =
    Fixture.withFixtureProjectPlan fixturePlan $ \plan ->
        case NonEmpty.toList (forward plan) of
            [dependencyNode, dependentNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                dependencyRuntime <- ExecutionCore.newStepRuntimeCore carrier
                dependentRuntime <- ExecutionCore.newStepRuntimeCore carrier
                callbacks <- newIORef (0 :: Int)
                let dependencyExecution = stepExecutionFor plan exactExecutionHostConfig dependencyRuntime dependencyNode
                    dependentExecution = stepExecutionFor plan exactExecutionHostConfig dependentRuntime dependentNode
                    key = Text.pack (operationKeyText (plannedStepOperationKey dependencyNode))
                    operation = key <> ":cluster:create"
                    summary handle receipt =
                        ( resourceHandleKey handle
                        , resourceHandleGeneration handle
                        , resourceHandleObservationVersion handle
                        , ownershipReceiptOperationKey receipt
                        , validateOwnershipReceipt handle receipt
                        )
                    expectedSummary = (key, 5, 7, operation, Right ())
                Execution.stepExecutionDependencyKeys dependentExecution @?= [key]
                gate <- gateFor (Execution.stepExecutionPlanDigest dependencyExecution) key
                either (assertFailure . show) id $
                    withNodeResourceOfKind dependencyExecution ClusterResourceKind key $ \planned ->
                        either (assertFailure . show) id $
                            withNodeObservedResource dependencyExecution planned 5 7 $ \observed -> do
                                descriptor <- either (assertFailure . show) pure $
                                    plannedNodeOperation dependencyExecution planned observed "cluster:create"
                                either (assertFailure . show) id $
                                    withPreparedZeroDependencyOperation descriptor gate $ \prepared sealed -> do
                                        result <- either (assertFailure . show) pure $
                                            completeReconcile observed prepared sealed (BackendCreated 5)
                                        withReconcileResult result
                                            ( \managed receipt change -> do
                                                change @?= Changed Created
                                                carryManagedResourceSettlement dependencyExecution managed receipt "provisioned" "cluster-adapter-1"
                                                    >>= either (assertFailure . show) pure
                                                before <- ExecutionCore.readCarriedResources carrier
                                                case before of
                                                    [entry] -> do
                                                        ExecutionCore.carriedResourceOwnershipOperation entry @?= operation
                                                        case ExecutionCore.carriedResourceSettlement entry of
                                                            Just (frame, Nothing, bytes) -> do
                                                                frame @?= Execution.stepExecutionFrame dependencyExecution
                                                                verified <- either (assertFailure . show) pure $
                                                                    verifyResourceRecordBundle plan planned 5 operation 7 "provisioned" "cluster-adapter-1" bytes
                                                                withVerifiedResourceRecordBundle verified
                                                                    (\owned -> validateOwnershipReceipt managed owned @?= Right ())
                                                                    (\_ _ _ _ _ _ _ -> assertFailure "the dependency settlement is released")
                                                            other -> assertFailure ("expected the actual owned dependency settlement, got " ++ show other)
                                                    other -> assertFailure ("expected one carried dependency, got " ++ show other)
                                                withCarriedManagedResourceReceipt dependentExecution key summary
                                                    >>= (@?= Right expectedSummary)
                                                attempted <-
                                                    withCarriedManagedResourceReceipt dependentExecution key $ \dependency dependencyReceipt -> do
                                                        modifyIORef' callbacks (+ 1)
                                                        carryManagedResourcePhaseSettlement
                                                            dependentExecution dependency dependencyReceipt "provisioned" "ready" "cluster-adapter-1"
                                                executed <- traverse id attempted
                                                executed @?= Right
                                                    ( Left
                                                        ( Conflict
                                                            ( ConflictDetail
                                                                key
                                                                "this node's own operation or a declared projected operation"
                                                                "a resource outside this node's settlement view"
                                                                "carry settlement only for a resource owned by this node"
                                                            )
                                                        )
                                                    )
                                                readIORef callbacks >>= (@?= 1)
                                                ExecutionCore.readCarriedResources carrier >>= (@?= before)
                                                withCarriedManagedResourceReceipt dependentExecution key summary
                                                    >>= (@?= Right expectedSummary)
                                            )
                                            (\_ _ -> assertFailure "the prepared dependency did not become managed")
            other -> assertFailure ("expected a dependency and its dependent node, got " ++ show (length other))
  where
    fixturePlan = planFrom
        [ deployKindStep "dependency" exactExecutionFrame (const (pure StepChanged))
        , projectStep (either error id (projectStepId "dependent")) PreserveOnReverse "dependent" exactExecutionFrame (const (pure StepChanged))
        ]

assertProjectedAliasSettlement :: IO ()
assertProjectedAliasSettlement =
    Fixture.withFixtureProjectPlan (planFrom (take 2 (NonEmpty.toList (stepPlanSteps exactExecutionPlan)))) $ \plan ->
        case NonEmpty.toList (forward plan) of
            [providerNode, shareNode] -> do
                carrier <- ExecutionCore.newResourceCarrierCore
                runtime <- ExecutionCore.newStepRuntimeCore carrier
                providerProbes <- newIORef (0 :: Int)
                shareProbes <- newIORef (0 :: Int)
                let execution = stepExecutionFor plan exactExecutionHostConfig runtime shareNode
                    digest = Execution.stepExecutionPlanDigest execution
                    aliasKey = "core:deploy-vm/core:copy-source/guest-alias"
                    aliasOperation = aliasKey <> ":alias:create"
                    phase = "provisioned"
                    adapter = "guest-alias-adapter-1"
                providerGate <- gateFor digest (Text.pack (operationKeyText (plannedStepOperationKey providerNode)))
                shareGate <- gateFor digest (Text.pack (operationKeyText (plannedStepOperationKey shareNode)))
                aliasGate <- gateFor digest aliasKey
                either (assertFailure . show) id $
                    withNodeResourceOfKind execution ProviderResourceKind "core:deploy-vm" $ \provider ->
                        either (assertFailure . show) id $
                            withNodeResourceOfKind execution DurableShareResourceKind "core:copy-source" $ \share ->
                                either (assertFailure . show) id $
                                    withManagedProvider providerGate plan provider $ \managedProvider ->
                                        either (assertFailure . show) id $
                                            withNodeObservedResource execution share 11 13 $ \observedShare -> do
                                                descriptor <- either (assertFailure . show) pure $
                                                    plannedNodeOperation execution share observedShare "share:mount"
                                                sharePrepared <- withPreparedOperation descriptor
                                                    ( withDependencySnapshotEntry managedProvider
                                                        (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (modifyIORef' providerProbes (+ 1) >> pure (Right 7)))
                                                        emptyDependencySnapshot
                                                    )
                                                    shareGate $ \prepared sealed -> do
                                                        reconciled <- either (assertFailure . show) pure $
                                                            completeReconcile observedShare prepared sealed (BackendCreated 11)
                                                        withReconcileResult reconciled
                                                            ( \managedShare _ shareChange -> do
                                                                shareChange @?= Changed Created
                                                                either (assertFailure . show) id $
                                                                    withNodeGuestAliasProjection execution provider share $ \alias edge ->
                                                                        either (assertFailure . show) id $
                                                                            withNodeObservedResource execution alias 307 1 $ \observedAlias -> do
                                                                                aliasDescriptor <- either (assertFailure . show) pure $
                                                                                    plannedGuestAliasOperation alias edge observedAlias "alias:create"
                                                                                aliasPrepared <- withPreparedOperation aliasDescriptor
                                                                                    ( withDependencySnapshotEntry managedShare
                                                                                        (TestDependency.dependencyProbeWithKind ProbeKernel.DurableShareKind (modifyIORef' shareProbes (+ 1) >> pure (Right 13)))
                                                                                        emptyDependencySnapshot
                                                                                    )
                                                                                    aliasGate $ \aliasPreparedOperation aliasSealed -> do
                                                                                        aliasResult <- either (assertFailure . show) pure $
                                                                                            completeReconcile observedAlias aliasPreparedOperation aliasSealed (BackendCreated 307)
                                                                                        withReconcileResult aliasResult
                                                                                            ( \managedAlias receipt aliasChange -> do
                                                                                                aliasChange @?= Changed Created
                                                                                                ownershipReceiptOperationKey receipt @?= aliasOperation
                                                                                                carryManagedResourceSettlement execution managedAlias receipt phase adapter
                                                                                                    >>= either (assertFailure . show) pure
                                                                                                carried <- ExecutionCore.readCarriedResources carrier
                                                                                                case carried of
                                                                                                    [entry] -> do
                                                                                                        ExecutionCore.carriedResourceKey entry @?= aliasKey
                                                                                                        ExecutionCore.carriedResourceGeneration entry @?= 307
                                                                                                        ExecutionCore.carriedResourceObservationVersion entry @?= 1
                                                                                                        ExecutionCore.carriedResourceOwnershipOperation entry @?= aliasOperation
                                                                                                        case ExecutionCore.carriedResourceSettlement entry of
                                                                                                            Just (frame, Nothing, bytes) -> do
                                                                                                                assertBool "the declaring frame is empty" (not (Text.null frame))
                                                                                                                frame @?= Execution.stepExecutionFrame execution
                                                                                                                frame @?= plannedResourceFrame alias
                                                                                                                expected <- either (assertFailure . show) pure $
                                                                                                                    renderResourceRecordBundle plan alias 307 aliasOperation 1 phase adapter True
                                                                                                                bytes @?= expected
                                                                                                                verified <- either (assertFailure . show) pure $
                                                                                                                    verifyResourceRecordBundle plan alias 307 aliasOperation 1 phase adapter bytes
                                                                                                                withVerifiedResourceRecordBundle verified
                                                                                                                    (\owned -> validateOwnershipReceipt managedAlias owned @?= Right ())
                                                                                                                    (\_ _ _ _ _ _ _ -> assertFailure "the projected alias settlement is released")
                                                                                                            other -> assertFailure ("expected a canonical local projection settlement, got " ++ show other)
                                                                                                    other -> assertFailure ("expected one carried projection, got " ++ show other)
                                                                                            )
                                                                                            (\_ _ -> assertFailure "the prepared alias did not become managed")
                                                                                either (assertFailure . show) id aliasPrepared
                                                            )
                                                            (\_ _ -> assertFailure "the prepared durable share did not become managed")
                                                either (assertFailure . show) id sharePrepared
                readIORef providerProbes >>= (@?= 1)
                readIORef shareProbes >>= (@?= 1)
            other -> assertFailure ("expected provider and projecting share nodes, got " ++ show (length other))

chartPreparationSummary :: Bool -> Bool -> IO (Either ReconcileError (Text.Text, [Text.Text]))
chartPreparationSummary probeReady wrongGate =
    chartPreparationWithProbe
        (pure (if probeReady then Right 8 else Left (Failure (FailureDetail "readiness" "not ready" ReprobeBeforeRetry))))
        wrongGate
        (\keys key -> (key, keys))

chartPreparationWithProbe ::
    IO (Either ReconcileError Word64) ->
    Bool ->
    ([Text.Text] -> Text.Text -> result) ->
    IO (Either ReconcileError result)
chartPreparationWithProbe = chartPreparationWithTaggedProbe Nothing

chartPreparationWithTaggedProbe ::
    Maybe ProbeKernel.BackendProbeKind ->
    IO (Either ReconcileError Word64) ->
    Bool ->
    ([Text.Text] -> Text.Text -> result) ->
    IO (Either ReconcileError result)
chartPreparationWithTaggedProbe kind probe wrongGate consume =
    Fixture.withFixtureProjectPlan chartPreparationPlan $ \plan ->
        case NonEmpty.toList (forward plan) of
            [clusterNode, chartNode] -> do
                clusterGate <- gateFor (stablePlanSnapshotDigest (renderSnapshot plan)) "core:deploy-kind"
                chartGate <- gateFor (stablePlanSnapshotDigest (renderSnapshot plan)) (if wrongGate then "core:deploy-kind" else "core:deploy-chart")
                let projected =
                        withPlannedResourceOfKind plan ClusterResourceKind (plannedStepOperationKey clusterNode) $ \cluster ->
                            withChartWorkloadResource plan (plannedStepOperationKey chartNode) $ \chart ->
                                withObservedProjectResource plan cluster 5 7 $ \observed -> do
                                    descriptor <- plannedProjectOperation plan cluster observed "cluster-call"
                                    withPreparedZeroDependencyOperation descriptor clusterGate $ \prepared sealed -> do
                                        created <- completeReconcile observed prepared sealed (BackendCreated 5)
                                        withReconcileResult
                                            created
                                            ( \managed _ _ ->
                                                let prepareChart selected = withPreparedChartWorkloadOperation
                                                        chart managed selected "chart-call" chartGate
                                                        (\keys handle _ _ -> consume keys (resourceHandleKey handle))
                                                 in Right
                                                    ( case kind of
                                                        Nothing -> prepareChart (TestDependency.dependencyProbeWithKind ProbeKernel.ClusterApiKind probe)
                                                        Just _ -> ProbeKernel.withBackendProbe ProbeKernel.GpuPluginProbe cluster
                                                            (\_ -> error "a wrong-kind probe must not run")
                                                            (\gpuProbe -> prepareChart
                                                                (Readiness.planDependencyProbe Readiness.vmBootPoll "gpu" managed gpuProbe
                                                                    (error "a wrong-kind probe must not need host configuration")))
                                                    )
                                            )
                                            (\_ _ -> Left (Failure (FailureDetail "chart fixture" "cluster became foreign" DoNotRetry)))
                case projected of
                    Right (Right (Right (Right (Right action)))) -> action
                    _ -> pure (Left (Failure (FailureDetail "chart fixture" "projection or cluster settlement failed" DoNotRetry)))
            other -> pure (Left (Failure (FailureDetail "chart fixture" (Text.pack (show (length other)) <> " nodes") DoNotRetry)))

chartPreparationPlan :: StepPlan
chartPreparationPlan =
    either (error . show) id $
        mkStepPlan
            [ deployKindStep "cluster" (StepFrame "cluster" "Cluster") (const (pure StepChanged))
            , declaresChartWorkloadResource
                "sha256:chart"
                "demo"
                "demo-system"
                "sha256:values"
                "image@sha256:digest"
                "workload-set:key"
                "sha256:workload"
                "service"
                "api"
                ["deployment:demo"]
                (deployChartStep "chart" (StepFrame "cluster" "Cluster") (const (pure StepChanged)))
            ]

assertNominalRoleInventory :: IO ()
assertNominalRoleInventory = do
    cwd <- getCurrentDirectory
    root <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
    let packageRoot =
            root
                </> "core"
                </> "hostbootstrap-core"
        coreModule = "HostBootstrap.Lifecycle.Execution.Core"
        dependencyModule = "HostBootstrap.Lifecycle.Dependency.Internal"
        preparedModule = "HostBootstrap.Lifecycle.Prepared.Internal"
    description <- SourceGuard.readPackageDescription
    reconcilePath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Reconcile"
    executionPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Lifecycle.Execution.Internal"
    reconcileSource <- TextIO.readFile reconcilePath
    executionSource <- TextIO.readFile executionPath
    corePath <- SourceGuard.libraryModulePath packageRoot description coreModule
    coreSource <- TextIO.readFile corePath
    reconcileDeclarations <- either assertFailure pure (nominalDeclarationRoles (Text.unpack reconcileSource))
    executionDeclarations <- either assertFailure pure (nominalDeclarationRoles (Text.unpack executionSource))
    assertBool "Reconcile has no discovered parameterized declarations" (not (null reconcileDeclarations))
    assertBool "Execution.Internal has no discovered parameterized declarations" (not (null executionDeclarations))
    let ordinary = "data Token scope planId = Token\ntype role Token nominal nominal\n"
        gadt = "data Token scope planId where\n    Token :: Token scope planId\ntype role Token nominal nominal\n"
        missing = Left "missing or invalid nominal roles for Token (arity 2)"
    nominalDeclarationRoles ordinary @?= Right [("Token", 2)]
    nominalDeclarationRoles (ordinary <> "newtype NewToken scope = NewToken Int\ntype role NewToken nominal\n")
        @?= Right [("Token", 2), ("NewToken", 1)]
    nominalDeclarationRoles gadt @?= Right [("Token", 2)]
    nominalDeclarationRoles ("data Empty\n" <> ordinary) @?= Right [("Token", 2)]
    nominalDeclarationRoles "data Token scope planId = Token\n" @?= missing
    nominalDeclarationRoles "newtype Token scope planId = Token Int\n" @?= missing
    nominalDeclarationRoles "data Token scope planId = Token\n-- type role Token nominal nominal\ntext = \"type role Token nominal nominal\"\n" @?= missing
    nominalDeclarationRoles "data Token scope planId = Token\ntype role Token nominal\n" @?= missing
    nominalDeclarationRoles "data Token scope planId = Token\ntype role Token nominal representational\n" @?= missing
    nominalDeclarationRoles (ordinary <> "type role Token nominal nominal\n") @?= missing
    nominalDeclarationRoles "data Token (scope :: Type) = Token\n"
        @?= Left "unsupported data/newtype header for Token"
    sort (roleLines coreSource)
        @?= sort
            [ "type role ResourceCarrierCore nominal nominal nominal"
            , "type role StepRuntimeCore nominal nominal nominal nominal"
            ]
    SourceGuard.countHaskellTokenSequence
        (SourceGuard.haskellTokens "type ResourceCarrier scope planId = ResourceCarrierCore scope planId (RuntimeDependencyPackage scope planId)")
        (Text.unpack executionSource)
        @?= 1
    SourceGuard.countHaskellTokenSequence
        (SourceGuard.haskellTokens "type StepRuntime scope planId = StepRuntimeCore scope planId PreparedGate (RuntimeDependencyPackage scope planId)")
        (Text.unpack executionSource)
        @?= 1
    dependencyImports <-
        maybe (assertFailure "the carrier alias has no exact main dependency-package import") pure $
            SourceGuard.moduleImportTokens dependencyModule (Text.unpack executionSource)
    assertBool "the carrier alias does not specialize the main dependency package" ("RuntimeDependencyPackage" `elem` dependencyImports)
    preparedImports <-
        maybe (assertFailure "the runtime alias has no exact main prepared-gate import") pure $
            SourceGuard.moduleImportTokens preparedModule (Text.unpack executionSource)
    assertBool "the runtime alias does not specialize the main prepared gate" ("PreparedGate" `elem` preparedImports)
    mainLibrary <-
        maybe (assertFailure "the package has no main library") pure $
            SourceGuard.namedStanza "library" description
    implementation <-
        maybe (assertFailure "the production handoff implementation unit is absent") pure $
            SourceGuard.namedStanza "library handoff-implementation-internal" description
    owners <- either assertFailure pure (SourceGuard.mainImplementationOwners description)
    publicModules <- either assertFailure pure (SourceGuard.effectiveMainExposedModules description)
    mapM_
        ( \moduleName -> do
            lookup moduleName owners @?= Just "library handoff-implementation-internal"
            assertBool "the production identity is unavailable to trusted Main" (moduleName `elem` SourceGuard.fieldModules "exposed-modules" implementation)
            assertBool "the production identity escaped through Main's facade" (moduleName `notElem` publicModules)
        )
        [dependencyModule, preparedModule]
    assertBool
        "the carrier alias imports the separate dependency-testing identity"
        ("hostbootstrap-core:lifecycle-dependency-internal" `notElem` SourceGuard.fieldValues "build-depends" mainLibrary)
    assertBool
        "the production implementation imports the separate dependency-testing identity"
        ("hostbootstrap-core:lifecycle-dependency-internal" `notElem` SourceGuard.fieldValues "build-depends" implementation)
  where
    roleLines =
        filter ("type role " `Text.isPrefixOf`)
            . map Text.strip
            . Text.lines

-- Discover the current plain binder grammar with the shared lexer. In
-- particular, an empty nullary declaration must stop before the next one.
-- DEVELOPMENT_PLAN/rationale.md#reconciliation-guards-inspect-actual-producers
nominalDeclarationRoles :: String -> Either String [(String, Int)]
nominalDeclarationRoles source = do
    declarations <- dataDeclarations tokens
    let parameterized = filter ((> 0) . snd) declarations
    if length (map fst declarations) /= length (nub (map fst declarations))
        then Left "duplicate data/newtype declarations"
        else traverse validate parameterized
  where
    tokens = SourceGuard.haskellTokens source
    dataDeclarations [] = Right []
    dataDeclarations (keyword : name : rest)
        | keyword `elem` ["data", "newtype"] = do
            let (header, remaining) = break (`elem` ["=", "where", "data", "newtype", "type", "class", "instance", "deriving"]) rest
            if typeName name && all parameterName header
                then ((name, length header) :) <$> dataDeclarations remaining
                else Left ("unsupported data/newtype header for " <> name)
    dataDeclarations (_ : rest) = dataDeclarations rest
    validate declaration@(name, arity) =
        case [roles | (annotated, roles) <- roleDeclarations tokens, annotated == name] of
            [roles] | roles == replicate arity "nominal" -> Right declaration
            _ -> Left ("missing or invalid nominal roles for " <> name <> " (arity " <> show arity <> ")")
    roleDeclarations ("type" : "role" : name : rest) =
        let (roles, remaining) = span (`elem` ["nominal", "representational", "phantom"]) rest
         in (name, roles) : roleDeclarations remaining
    roleDeclarations (_ : rest) = roleDeclarations rest
    roleDeclarations [] = []
    typeName (first : rest) = isUpper first && all identifierCharacter rest
    typeName [] = False
    parameterName (first : rest) = (isLower first || first == '_') && all identifierCharacter rest
    parameterName [] = False
    identifierCharacter character = isAlphaNum character || character `elem` ("_'" :: String)

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

canonicalSummary :: StepPlan -> IO (ByteString.ByteString, Text.Text)
canonicalSummary plan =
    Fixture.withFixtureProjectPlan plan $
        pure . canonicalSnapshotSummary . Fixture.canonicalSnapshotFromProjectPlan

canonicalPairSummaries :: StepPlan -> StepPlan -> IO ((ByteString.ByteString, Text.Text), (ByteString.ByteString, Text.Text))
canonicalPairSummaries first second =
    Fixture.withFixtureCanonicalSnapshotVariants first second id $ \base changed _ ->
        pure (canonicalSnapshotSummary base, canonicalSnapshotSummary changed)

canonicalSnapshotSummary :: CanonicalPlanSnapshot -> (ByteString.ByteString, Text.Text)
canonicalSnapshotSummary snapshot =
    (canonicalPlanSnapshotBytes snapshot, canonicalPlanSnapshotDigest snapshot)

admittedPlanDigest :: ProjectPlan scope specDigest planId configId cfg -> Text.Text
admittedPlanDigest = stablePlanSnapshotDigest . renderSnapshot

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
            (vmContext (inVM (IncusVM "fixture-vm" image) emptyVMStack))
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
containerCanonicalPlan = containerCanonicalPlanAt "/app/config.dhall"

containerCanonicalPlanAt :: FilePath -> Text.Text -> StepPlan
containerCanonicalPlanAt destination payload =
    planFrom
        [ descendsVia
            (inContainer container emptyVMStack)
            (buildImageStep "image" (StepFrame "host" "Host") (const (pure StepChanged)))
        , contextInitStep "context" (StepFrame "container" "Container") (const (pure StepChanged))
        ]
  where
    container =
        ContainerLift
            { clImage = "fixture:latest"
            , clPlacement = ProviderGuestContainer
            , clMounts = [Vocab.Mount "/host" "/guest" True]
            , clExtraArgs = ["--network=host"]
            , clRemoveAfter = True
            , clConfigDelivery = Just (ConfigDelivery destination payload)
            }

assertCanonicalDeliveryRecord :: IO ()
assertCanonicalDeliveryRecord = do
    (bytes, _) <- canonicalSummary (containerCanonicalPlan "fixture-secret-payload")
    let wrapper = oracleText "config-delivery" <> ByteString.singleton 1
        expected =
            oracleText "config-delivery"
                <> oracleWord64 2
                <> oracleText "write-path"
                <> oracleText "/app/config.dhall"
                <> oracleText "payload-digest"
                <> oracleText "267ecbfaf8cf2b0267b324275cb23a183284677e7bf1acc94da6e194054efda4"
        nextStep = oracleText "step"
    case ByteString.breakSubstring wrapper bytes of
        (_, found)
            | ByteString.null found -> assertFailure "the actual snapshot has no config delivery record"
            | otherwise -> do
                let recordAndRest = ByteString.drop (ByteString.length wrapper) found
                -- The first step ends with this delivery; the second step must
                -- immediately follow its two fields, with no extra coordinate.
                ByteString.take (ByteString.length expected + ByteString.length nextStep) recordAndRest
                    @?= expected <> nextStep
                assertBool "the fixture unexpectedly has another delivery" (not (wrapper `ByteString.isInfixOf` recordAndRest))

-- Independent test framing: no canonical writer or parser builds the oracle.
oracleText :: Text.Text -> ByteString.ByteString
oracleText value =
    let bytes = TextEncoding.encodeUtf8 value
     in oracleWord64 (fromIntegral (ByteString.length bytes)) <> bytes

oracleWord64 :: Word64 -> ByteString.ByteString
oracleWord64 value = ByteString.pack [fromIntegral (value `shiftR` offset) | offset <- [56, 48 .. 0]]

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
            [ descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged)))
            , copySourceStep "durable share" (StepFrame "vm" "VM") (const (pure StepChanged))
            ]
        )

createdSummaryWithGate ::
    (Text.Text -> IO PreparedGate) ->
    IO (Either ReconcileError (ChangeView, Word))
createdSummaryWithGate openGate = reconcileObservationSummary openGate (BackendCreated 7)

reconcileObservationSummary ::
    (Text.Text -> IO PreparedGate) ->
    BackendReconcileObservation ->
    IO (Either ReconcileError (ChangeView, Word))
reconcileObservationSummary openGate observation =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- openGate (admittedPlanDigest plan)
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                            result <- completeReconcile handle prepared preconditions observation
                            pure $
                                withReconcileResult
                                    result
                                    (\managed _receipt change -> (change, fromIntegral (resourceHandleGeneration managed)))
                                    (\_ _ -> error "created resource must not be foreign")

createdSummary :: IO (Either ReconcileError (ChangeView, Word))
createdSummary = createdSummaryWithGate (\digest -> gateFor digest "core:deploy-kind")

foreignSummary :: IO (Either ReconcileError String)
foreignSummary =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
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
adoptionSummary = adoptionObservationSummary (BackendRepaired 7)

adoptionObservationSummary :: BackendReconcileObservation -> IO (Either ReconcileError ChangeView)
adoptionObservationSummary backendObservation =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:observe-foreign"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
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
                                                adopted <- completeAdoption unmanaged origin authority backendObservation
                                                pure $
                                                    withReconcileResult
                                                        adopted
                                                        (\_ _ change -> change)
                                                        (\_ _ -> error "adoption must return managed ownership")
                                )

assertJournalFrameMismatch :: IO ()
assertJournalFrameMismatch =
    withTestResource twoFramePlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        let expectedFrame = plannedResourceFrame planned
            otherFrame = plannedStepFrameId (NonEmpty.head (forward plan))
        map plannedStepFrameId (NonEmpty.toList (forward plan)) @?= ["host", "cluster"]
        expectedFrame @?= "cluster"
        assertBool "the journal frame mutation did not change frames" (otherFrame /= expectedFrame)
        case withObservedPlannedResource plan planned 7 3 $ \handle -> do
            let matching =
                    journalRecord (Text.unpack (admittedPlanDigest plan)) expectedFrame Committed
                verify record = fmap (const ()) (verifyPersistedJournalRecord plan planned handle "acquire" record)
            verify matching @?= Right ()
            verify matching{persistedFrameKey = otherFrame}
                @?= Left
                    ( Conflict
                        ( ConflictDetail
                            "core:deploy-kind"
                            ("frame key=" <> expectedFrame)
                            ("frame key=" <> otherFrame)
                            "load the matching protected journal record"
                        )
                    ) of
            Left failure -> assertFailure ("journal fixture observation failed: " <> show failure)
            Right action -> action
  where
    twoFramePlan =
        planFrom
            [ descendsVia localContext (contextInitStep "host context" (StepFrame "host" "Host") (const (pure StepChanged)))
            , deployKindStep "cluster" (StepFrame "cluster" "Cluster") (const (pure StepChanged))
            ]

journalMismatch :: IO (Text.Text, Either ReconcileError ())
journalMismatch =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        outcome <-
            either (assertFailure . show) pure $
                withObservedPlannedResource plan planned 7 3 $ \handle ->
                    () <$ verifyPersistedJournalRecord plan planned handle "acquire" (journalRecord "other" (plannedResourceFrame planned) Committed)
        pure (admittedPlanDigest plan, outcome)

unchangedSummary :: IO (Either ReconcileError ChangeView)
unchangedSummary = unchangedSummaryFor Committed "core:deploy-kind:call:one"

unchangedSummaryFor :: PersistedJournalPhase -> Text.Text -> IO (Either ReconcileError ChangeView)
unchangedSummaryFor phase operation =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        let semanticOperation = if phase == AdoptionCommitted then "adopt" else "acquire"
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                            verified <-
                                verifyPersistedJournalRecord
                                    plan
                                    planned
                                    handle
                                    semanticOperation
                                    ( (journalRecord (Text.unpack (admittedPlanDigest plan)) (plannedResourceFrame planned) phase)
                                        { persistedOperationKey = operation
                                        , persistedOperation = semanticOperation
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

phaseSummary :: Word64 -> IO (Either ReconcileError Word)
phaseSummary observedGeneration =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        phaseGate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        joinIO $
            joinReconcile $
                withObservedPlannedResource plan planned 3 4 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                            result <- completeReconcile handle prepared preconditions (BackendCreated 9)
                            withReconcileResult
                                result
                                ( \managed receipt _ -> do
                                    transition <- planMarkReady managed
                                    phaseDescriptor <- plannedProjectPhaseOperation plan planned managed receipt transition "cluster:ready"
                                    pure $
                                        fmap joinReconcile $
                                            withPreparedPhaseTransition managed receipt transition phaseDescriptor emptyDependencySnapshot phaseGate $ \preparedPhase -> do
                                                advance <- completePreparedPhaseTransition preparedPhase observedGeneration
                                                pure $
                                                    withPhaseAdvance advance $ \readyHandle _ _ ->
                                                        fromIntegral (resourceHandleGeneration readyHandle)
                                )
                                (\_ _ -> error "created resource must be managed")

backendObservationCases :: [TestTree]
backendObservationCases =
    [ reconcileCase "an absent resource requires a fresh probe" BackendAbsent $
        Left (Failure (FailureDetail "reconcile resource" "resource remained absent" ReprobeBeforeRetry))
    , reconcileCase "unsupported reconciliation retains its reason" (BackendUnsupported "no provider support") $
        Left (Unsupported (UnsupportedDetail "reconcile resource" "no provider support"))
    , reconcileCase "reconcile failure retains fenced-retry disposition" (BackendFailed "effect ambiguous" RetrySameOperationKeyAfterFencing) $
        Left (Failure (FailureDetail "reconcile resource" "effect ambiguous" RetrySameOperationKeyAfterFencing))
    , reconcileCase "reconcile failure retains operator-resolution disposition" (BackendFailed "ownership ambiguous" OperatorResolutionRequired) $
        Left (Failure (FailureDetail "reconcile resource" "ownership ambiguous" OperatorResolutionRequired))
    , reconcileCase "repair retains the exact observed generation" (BackendRepaired 7) $
        Right (Changed Repaired, 7)
    , reconcileCase "repair refuses a replacement generation" (BackendRepaired 9) $
        Left (Conflict (ConflictDetail "core:deploy-kind" "7" "9" "reprobe the resource and resolve replacement ownership"))
    , reconcileCase "creation refuses generation zero" (BackendCreated 0) $
        Left (Failure (FailureDetail "reconcile resource" "created generation must be positive" DoNotRetry))
    , reconcileCase "foreign observation refuses generation zero" (BackendForeign 0 foreignObservation) $
        Left (Failure (FailureDetail "reconcile resource" "foreign generation must be positive" DoNotRetry))
    , adoptionCase "an absent adoption target requires operator resolution" BackendAbsent $
        Left (Failure (FailureDetail "adopt resource" "resource became absent" OperatorResolutionRequired))
    , adoptionCase "unsupported adoption retains its reason" (BackendUnsupported "no adoption support") $
        Left (Unsupported (UnsupportedDetail "adopt resource" "no adoption support"))
    , adoptionCase "adoption failure retains fenced-retry disposition" (BackendFailed "transfer ambiguous" RetrySameOperationKeyAfterFencing) $
        Left (Failure (FailureDetail "adopt resource" "transfer ambiguous" RetrySameOperationKeyAfterFencing))
    , adoptionCase "adoption failure retains operator-resolution disposition" (BackendFailed "transfer refused" OperatorResolutionRequired) $
        Left (Failure (FailureDetail "adopt resource" "transfer refused" OperatorResolutionRequired))
    , adoptionCase "adoption accepts a matching created generation" (BackendCreated 7) $
        Right (Changed Adopted)
    , adoptionCase "adoption refuses a replacement created generation" (BackendCreated 9) $
        Left (Conflict (ConflictDetail "core:deploy-kind" "7" "9" "reprobe the replacement before adoption"))
    , adoptionCase "adoption refuses a replacement repaired generation" (BackendRepaired 9) $
        Left (Conflict (ConflictDetail "core:deploy-kind" "7" "9" "reprobe the replacement before adoption"))
    , adoptionCase "a still-foreign adoption target remains unmanaged" (BackendForeign 7 foreignObservation) $
        Left
            ( Conflict
                ( ConflictDetail
                    "core:deploy-kind"
                    "adoption transferred to managed ownership"
                    "still foreign: not owned"
                    "leave the resource unmanaged and resolve ownership"
                )
            )
    ]
  where
    reconcileCase label observation expected =
        testCase label $
            reconcileObservationSummary (\digest -> gateFor digest "core:deploy-kind") observation
                >>= (@?= expected)
    adoptionCase label observation expected =
        testCase label (adoptionObservationSummary observation >>= (@?= expected))
    foreignObservation = ForeignObservation "manual-vm" "not owned"

adoptionOriginCases :: [TestTree]
adoptionOriginCases =
    [ testCase "a foreign origin from another generation is refused" $
        adoptionAuthoritySummary 8 3 "vm:adopt"
            >>= ( @?=
                    Left
                        ( Conflict
                            ( ConflictDetail
                                "core:deploy-kind"
                                "foreign origin generation=7"
                                "foreign origin generation=8"
                                "reprobe and authorize adoption for the exact foreign origin"
                            )
                        )
                )
    , testCase "a foreign origin from another observation is refused" $
        adoptionAuthoritySummary 7 4 "vm:adopt"
            >>= ( @?=
                    Left
                        ( Conflict
                            ( ConflictDetail
                                "core:deploy-kind"
                                "foreign origin observation=3"
                                "foreign origin observation=4"
                                "reprobe and authorize adoption for the exact foreign origin"
                            )
                        )
                )
    , testCase "adoption cannot mint an empty-operation receipt" $
        adoptionAuthoritySummary 7 3 ""
            >>= (@?= Left (Failure (FailureDetail "authorize adoption" "operation key must not be empty" DoNotRetry)))
    ]

adoptionAuthoritySummary :: Word64 -> Word64 -> Text.Text -> IO (Either ReconcileError ())
adoptionAuthoritySummary originGeneration originVersion operation =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        pure $
            withForeignResource gate plan planned 7 3 $ \target _ ->
                withForeignResource gate plan planned originGeneration originVersion $ \source observation ->
                    withVerifiedForeignOrigin source observation $ \origin ->
                        withAdoptionAuthority plan planned target origin operation (const ())

withForeignResource ::
    PreparedGate ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId resourceId resource frame ->
    Word64 ->
    Word64 ->
    (ResourceHandle scope planId resourceId resource Unmanaged Observed -> ForeignObservation -> Either ReconcileError result) ->
    Either ReconcileError result
withForeignResource gate plan planned generation observationVersion consume =
    joinReconcile $
        withObservedPlannedResource plan planned generation observationVersion $ \observed -> do
            descriptor <- plannedOperation plan planned observed "call:observe-foreign"
            joinReconcile $
                withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                    reconciled <-
                        completeReconcile observed prepared preconditions (BackendForeign generation (ForeignObservation "manual-vm" "not owned"))
                    withReconcileResult
                        reconciled
                        (\_ _ _ -> Left (Failure (FailureDetail "test foreign resource" "expected foreign observation" DoNotRetry)))
                        consume

priorCommitCases :: [TestTree]
priorCommitCases =
    [ testCase "intent alone cannot prove prior commit" $
        unchangedSummaryFor IntentRecorded operation >>= (@?= notCommitted)
    , testCase "observed ownership alone cannot prove prior commit" $
        unchangedSummaryFor ObservedManaged operation >>= (@?= notCommitted)
    , testCase "a matching adoption commit proves Unchanged" $
        unchangedSummaryFor AdoptionCommitted operation >>= (@?= Right Unchanged)
    , testCase "an adoption commit for another exact operation cannot prove Unchanged" $
        unchangedSummaryFor AdoptionCommitted "core:deploy-kind:another-call"
            >>= ( @?=
                    Left
                        ( Conflict
                            ( ConflictDetail
                                "core:deploy-kind"
                                "receipt operation key=core:deploy-kind:call:one"
                                "receipt operation key=core:deploy-kind:another-call"
                                "load the committed record for the exact prepared operation"
                            )
                        )
                )
    ]
  where
    operation = "core:deploy-kind:call:one"
    notCommitted =
        Left (Failure (FailureDetail "rebind ownership" "journal record is not committed" OperatorResolutionRequired))

receiptCases :: [TestTree]
receiptCases =
    [ testCase "matching durable receipts validate and rebind through the plan" $
        receiptGenerationSummary 7 >>= (@?= Right (Right (), Right ()))
    , testCase "a genuine receipt from another generation refuses both validation and planned rebinding" $
        receiptGenerationSummary 8
            >>= (@?= Right (Left generationMismatch, Left generationMismatch))
    , testCase "cross-identity receipt bridges refuse the other planned resource key" $
        receiptKeySummary
            >>= ( @?=
                    Right
                        ( Left (keyMismatch "core:deploy-vm" "core:copy-source")
                        , Left (keyMismatch "core:copy-source" "core:deploy-vm")
                        )
                )
    ]
  where
    generationMismatch =
        Conflict
            ( ConflictDetail
                "core:deploy-kind"
                "generation=7"
                "generation=8"
                "load the ownership receipt for the exact managed generation"
            )
    keyMismatch expected observed =
        Conflict
            ( ConflictDetail
                expected
                ("resource key=" <> expected)
                ("resource key=" <> observed)
                "load the ownership receipt for the exact managed generation"
            )

receiptGenerationSummary ::
    Word64 ->
    IO (Either ReconcileError (Either ReconcileError (), Either ReconcileError ()))
receiptGenerationSummary receiptGeneration =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        pure $
            withCreatedResource gate plan planned 7 3 $ \managed _ ->
                withDurableReceipt plan planned receiptGeneration $ \receipt ->
                    Right
                        ( validateOwnershipReceipt managed receipt
                        , withPlannedReboundManagedResourceEvidence planned managed receipt (\_ _ -> ())
                        )

receiptKeySummary ::
    IO (Either ReconcileError (Either ReconcileError (), Either ReconcileError ()))
receiptKeySummary =
    withTestResource dependentTestPlan ProviderResourceKind "core:deploy-vm" $ \plan provider -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
        case find
            ((== "core:copy-source") . operationKeyText . plannedStepOperationKey)
            (NonEmpty.toList (forward plan)) of
            Nothing -> fail "the receipt fixture plan lacks its durable share"
            Just shareNode ->
                case withPlannedResourceOfKind
                    plan
                    DurableShareResourceKind
                    (plannedStepOperationKey shareNode)
                    ( \share ->
                        pure $
                            withCreatedResource gate plan provider 7 3 $ \managed providerReceipt ->
                                withDurableReceipt plan share 7 $ \shareReceipt ->
                                    Right
                                        ( () <$ rebindOwnershipReceipt managed shareReceipt
                                        , withPlannedReboundManagedResourceEvidence share managed providerReceipt (\_ _ -> ())
                                        )
                    ) of
                    Left failure -> fail (show failure)
                    Right action -> action

withCreatedResource ::
    PreparedGate ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId resourceId resource frame ->
    Word64 ->
    Word64 ->
    ( ResourceHandle scope planId resourceId resource Managed Provisioned ->
      OwnershipReceipt scope planId resourceId resource ->
      Either ReconcileError result
    ) ->
    Either ReconcileError result
withCreatedResource gate plan planned generation observationVersion consume =
    joinReconcile $
        withObservedPlannedResource plan planned generation observationVersion $ \observed -> do
            descriptor <- plannedOperation plan planned observed "call:one"
            joinReconcile $
                withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                    reconciled <- completeReconcile observed prepared preconditions (BackendCreated generation)
                    withReconcileResult
                        reconciled
                        (\managed receipt _ -> consume managed receipt)
                        (\_ _ -> Left (Failure (FailureDetail "test receipt" "expected managed ownership" DoNotRetry)))

-- The receipt comes from the same public durable evidence path as recovery.
withDurableReceipt ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId resourceId resource frame ->
    Word64 ->
    (OwnershipReceipt scope planId resourceId resource -> Either ReconcileError result) ->
    Either ReconcileError result
withDurableReceipt plan planned generation consume = do
    raw <- renderResourceRecordBundle plan planned generation "ownership:acquire" 1 "provisioned" "adapter-v1" True
    verified <- verifyResourceRecordBundle plan planned generation "ownership:acquire" 1 "provisioned" "adapter-v1" raw
    withVerifiedResourceRecordBundle
        verified
        consume
        (\_ _ _ _ _ _ _ -> Left (Failure (FailureDetail "test receipt" "expected an owned durable record" DoNotRetry)))

emptyOperationCases :: [TestTree]
emptyOperationCases =
    [ testCase "durable rendering refuses an empty ownership operation" $
        withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned ->
            renderResourceRecordBundle plan planned 7 "" 3 "provisioned" "adapter-v1" True
                @?= Left emptyDurableOperation
    , testCase "durable parsing refuses an empty ownership operation" $
        withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
            canonical <-
                either (assertFailure . show) pure $
                    renderResourceRecordBundle plan planned 7 "ownership:acquire" 3 "provisioned" "adapter-v1" True
            let verify = verifyResourceRecordBundle plan planned 7 "ownership:acquire" 3 "provisioned" "adapter-v1"
            (() <$ verify canonical) @?= Right ()
            withoutOperation <- emptyRecordOwnershipOperation canonical
            (() <$ verify withoutOperation) @?= Left emptyDurableOperation
    , testCase "journal ingress refuses an empty stable ownership operation" $ do
        outcome <-
            withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned ->
                pure $
                    joinReconcile $
                        withObservedPlannedResource plan planned 7 3 $ \handle ->
                            ()
                                <$ verifyPersistedJournalRecord
                                    plan
                                    planned
                                    handle
                                    "acquire"
                                    ( (journalRecord (Text.unpack (admittedPlanDigest plan)) (plannedResourceFrame planned) Committed)
                                        { persistedOperationKey = ""
                                        }
                                    )
        outcome @?= Left (Failure (FailureDetail "verify journal" "stable frame/operation keys are required" DoNotRetry))
    ]
  where
    emptyDurableOperation =
        Failure (FailureDetail "verify resource record bundle" "resource record ownership operation key is empty" DoNotRetry)

-- Keep every other canonical field intact, including all of its length framing.
emptyRecordOwnershipOperation :: ByteString.ByteString -> IO ByteString.ByteString
emptyRecordOwnershipOperation = replaceOperation (6 :: Int)
  where
    replaceOperation index raw
        | ByteString.length raw < 8 = assertFailure "the canonical receipt fixture has a truncated field header"
        | size > fromIntegral (ByteString.length body) = assertFailure "the canonical receipt fixture has a truncated field"
        | index == 0 = pure (ByteString.replicate 8 0 <> trailing)
        | otherwise = (\rest -> prefix <> field <> rest) <$> replaceOperation (index - 1) trailing
      where
        (prefix, body) = ByteString.splitAt 8 raw
        size = ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 prefix :: Word64
        (field, trailing) = ByteString.splitAt (fromIntegral size) body

assertPlannedReceiptRebindingBoundary :: IO ()
assertPlannedReceiptRebindingBoundary =
    -- DEVELOPMENT_PLAN/rationale.md: "Receipt rebinding follows the planned resource".
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- SourceGuard.readPackageDescription
        path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Reconcile"
        source <- readFile path
        definitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
        exports <-
            maybe
                (assertFailure "could not parse the Reconcile export list")
                pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Reconcile" source)
        assertBool "the unplanned rebinding opener is still defined" $
            "withReboundManagedResourceEvidence" `notElem` definitions
        assertBool "the unplanned rebinding opener is still exported" $
            "withReboundManagedResourceEvidence" `notElem` exports
        assertBool "the plan-bound rebinding opener is not exported" $
            "withPlannedReboundManagedResourceEvidence" `elem` exports

assertCanonicalPreparationSurface :: IO ()
assertCanonicalPreparationSurface =
    -- DEVELOPMENT_PLAN/rationale.md: "Preparation owns fresh dependency observations".
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- SourceGuard.readPackageDescription
        path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Reconcile"
        source <- readFile path
        definitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
        exports <-
            maybe
                (assertFailure "could not parse the Reconcile export list")
                pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Reconcile" source)
        let required =
                [ "withPreparedOperation"
                , "withPreparedPhaseTransition"
                , "withPreparedZeroDependencyOperation"
                , "withPreparedZeroDependencyPhaseTransition"
                ]
            retired = ["withFreshPreparedOperation", "operationPreconditionKeys"]
            privateSetSurface = ["OperationPreconditionSet", "withOperationPreconditions", "zeroDependencyPreconditions"]
        sort (filter (`elem` (required <> retired)) definitions) @?= required
        sort (filter (`elem` (required <> retired <> privateSetSurface)) exports) @?= required
        rationale <- readFile (takeDirectory (takeDirectory packageRoot) </> "DEVELOPMENT_PLAN" </> "rationale.md")
        assertBool
            "the canonical preparation guard names an existing rationale heading"
            ("### Preparation owns fresh dependency observations" `elem` lines rationale)

providerForceDestroyChecks ::
    IO (Either ReconcileError (Word, Text.Text, Bool, Bool, Bool))
providerForceDestroyChecks =
    withTestResource dependentTestPlan ProviderResourceKind "core:deploy-vm" $ \plan planned -> do
        let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
            operationKey = "core:deploy-vm"
        createGate <- gateFor planDigest operationKey
        bootGate <- gateFor planDigest operationKey
        replacementGate <- gateFor planDigest operationKey
        destroyGate <- gateFor planDigest operationKey
        joinIO $
            joinReconcile $
                withObservedProjectResource plan planned 7 3 $ \observed -> do
                    createDescriptor <- plannedProjectOperation plan planned observed "provider:create"
                    joinReconcile $
                        withPreparedZeroDependencyOperation createDescriptor createGate $ \prepared sealed -> do
                            created <- completeReconcile observed prepared sealed (BackendCreated 7)
                            withReconcileResult
                                created
                                ( \provisioned receipt _ -> do
                                    boot <- planProviderBoot provisioned
                                    bootDescriptor <- plannedProjectPhaseOperation plan planned provisioned receipt boot "provider:boot"
                                    pure $
                                        fmap joinReconcile $
                                            withPreparedPhaseTransition provisioned receipt boot bootDescriptor emptyDependencySnapshot bootGate $ \preparedBoot -> do
                                                runningAdvance <- completePreparedPhaseTransition preparedBoot 7
                                                withPhaseAdvance runningAdvance $ \running runningReceipt _ ->
                                                    joinReconcile $
                                                        withObservedProjectResource plan planned 8 4 $ \replacementObserved -> do
                                                            replacementDescriptor <-
                                                                plannedProjectOperation plan planned replacementObserved "provider:replacement"
                                                            joinReconcile $
                                                                withPreparedZeroDependencyOperation
                                                                    replacementDescriptor
                                                                    replacementGate
                                                                    ( \replacementPrepared replacementSealed -> do
                                                                        replacement <-
                                                                            completeReconcile
                                                                                replacementObserved
                                                                                replacementPrepared
                                                                                replacementSealed
                                                                                (BackendCreated 8)
                                                                        withReconcileResult
                                                                            replacement
                                                                            ( \_ replacementReceipt _ -> do
                                                                                destroy <- planProviderForceDestroy running
                                                                                destroyDescriptor <-
                                                                                    plannedProjectPhaseOperation
                                                                                        plan
                                                                                        planned
                                                                                        running
                                                                                        runningReceipt
                                                                                        destroy
                                                                                        "provider:destroy-force"
                                                                                joinReconcile $
                                                                                    withPreparedZeroDependencyPhaseTransition
                                                                                        running
                                                                                        runningReceipt
                                                                                        destroy
                                                                                        destroyDescriptor
                                                                                        destroyGate
                                                                                        ( \preparedDestroy -> do
                                                                                            advance <- completePreparedPhaseTransition preparedDestroy 7
                                                                                            let exactSummary =
                                                                                                    withPhaseAdvance advance $ \destroyed destroyedReceipt _ ->
                                                                                                        ( fromIntegral (resourceHandleGeneration destroyed)
                                                                                                        , ownershipReceiptOperationKey destroyedReceipt
                                                                                                        )
                                                                                                wrongGenerationRefused =
                                                                                                    isConflict (completePreparedPhaseTransition preparedDestroy 8)
                                                                                                emptyDigestRefused =
                                                                                                    isFailure
                                                                                                        ( plannedProjectPhaseOperation
                                                                                                            plan
                                                                                                            planned
                                                                                                            running
                                                                                                            runningReceipt
                                                                                                            destroy
                                                                                                            ""
                                                                                                        )
                                                                                                replacementReceiptRefused =
                                                                                                    isConflict
                                                                                                        ( plannedProjectPhaseOperation
                                                                                                            plan
                                                                                                            planned
                                                                                                            running
                                                                                                            replacementReceipt
                                                                                                            destroy
                                                                                                            "provider:destroy-force"
                                                                                                        )
                                                                                            pure
                                                                                                ( fst exactSummary
                                                                                                , snd exactSummary
                                                                                                , wrongGenerationRefused
                                                                                                , emptyDigestRefused
                                                                                                , replacementReceiptRefused
                                                                                                )
                                                                                        )
                                                                            )
                                                                            (\_ _ -> error "replacement provider must be managed")
                                                                    )
                                )
                                (\_ _ -> error "created provider must be managed")
  where
    isConflict outcome = case outcome of
        Left (Conflict _) -> True
        _ -> False

    isFailure outcome = case outcome of
        Left (Failure _) -> True
        _ -> False

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
                (const (pure StepChanged))
            , descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure StepChanged)))
            , copySourceStep "durable share" (StepFrame "vm" "VM") (const (pure StepChanged))
            ]
        )

-- | The exact ordered edge set the plan derives for @core:copy-source@.
copySourceDependencies :: IO (Either ReconcileError [Text.Text])
copySourceDependencies =
    withTestResource projectPrefixedPlan DurableShareResourceKind "core:copy-source" $ \plan planned ->
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle ->
                    operationDescriptorDependencies
                        <$> plannedOperation plan planned handle "share:mount"

{- | The resource-bearing edge set prepared through the canonical fresh boundary.
The project-owned @ensure@ step has no resource, so the genuine snapshot needs
only the managed provider rather than an invented handle for that step.
-}
sealedCopySourceKeys :: IO (Either ReconcileError [Text.Text])
sealedCopySourceKeys =
    withFreshShareFixture $ \digest observed descriptor _provider managedProvider -> do
        gate <- freshShareGate digest
        prepared <-
            withPreparedOperation
                descriptor
                (withDependencySnapshotEntry managedProvider (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (pure (Right 17))) emptyDependencySnapshot)
                gate
                ( \operation preconditions -> do
                    acquired <- completeReconcile observed operation preconditions (BackendCreated 11)
                    withReconcileResult
                        acquired
                        (\_ _ _ -> Right (operationDescriptorDependencies descriptor))
                        (\_ _ -> Left (Failure (FailureDetail "prepared edge fixture" "share became foreign" DoNotRetry)))
                )
        pure (joinReconcile prepared)

-- | Own the provider so the share has a managed dependency to observe.
withManagedProvider ::
    PreparedGate ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ( ResourceHandle scope planId providerId ProviderResource Managed Provisioned ->
      result
    ) ->
    Either ReconcileError result
withManagedProvider gate plan planned consume =
    joinReconcile $
        withObservedPlannedResource plan planned 5 7 $ \observed -> do
            descriptor <- plannedOperation plan planned observed "provider:create"
            joinReconcile $
                withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                    reconciled <- completeReconcile observed prepared preconditions (BackendCreated 5)
                    withReconcileResult
                        reconciled
                        (\managed _ _ -> Right (consume managed))
                        (\_ _ -> Left (Failure (FailureDetail "test provider" "unexpected foreign provider" DoNotRetry)))

freshSnapshotPreparationCases :: [TestTree]
freshSnapshotPreparationCases =
    [ testCase "a readiness edge refuses an untagged probe without running it" $ do
        result <- withFreshShareFixture $ \digest _observed descriptor _provider managedProvider -> do
            gate <- freshShareGate digest
            probes <- newIORef (0 :: Int)
            let untagged = TestDependency.dependencyProbe (modifyIORef' probes (+ 1) >> pure (Right 17))
                snapshot = withDependencySnapshotEntry managedProvider untagged emptyDependencySnapshot
            outcome <- withPreparedOperation descriptor snapshot gate (\_ _ -> ())
            case outcome of
                Left (Conflict _) -> pure ()
                _ -> assertFailure "untagged readiness was accepted"
            readIORef probes >>= (@?= 0)
            pure (Right ())
        result @?= Right ()
    , testCase "fresh preparation runs the ready dependency once and yields its matching pair" $ do
        (_, outcome, probes, callbacks) <-
            freshPreparationSummary freshShareGate FreshMemberPresent (Right 17)
        outcome @?= Right ("core:copy-source", 11, "core:copy-source:share:mount", Changed Created)
        (probes, callbacks) @?= (1, 1)
    , testCase "fresh preparation takes the empty-edge branch without probing an unused snapshot member" $
        withTestResource projectPrefixedPlan ProviderResourceKind "core:deploy-vm" $ \plan planned -> do
            managedGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
            gate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
            preparedGateJournalVersion gate @?= 1
            probes <- newIORef (0 :: Int)
            callbacks <- newIORef (0 :: Int)
            prepared <-
                joinIO $
                    withManagedProvider managedGate plan planned $ \managedProvider ->
                        joinIO $
                            withObservedPlannedResource plan planned 5 7 $ \observed ->
                                case plannedOperation plan planned observed "provider:empty-snapshot" of
                                    Left failure -> pure (Left failure)
                                    Right descriptor -> do
                                        operationDescriptorDependencies descriptor @?= []
                                        let snapshot =
                                                withDependencySnapshotEntry
                                                    managedProvider
                                                    (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (modifyIORef' probes (+ 1) >> pure (Right 17)))
                                                    emptyDependencySnapshot
                                        readIORef probes >>= (@?= 0)
                                        withPreparedOperation descriptor snapshot gate $ \operation preconditions -> do
                                            modifyIORef' callbacks (+ 1)
                                            pure $ do
                                                acquired <- completeReconcile observed operation preconditions (BackendCreated 5)
                                                withReconcileResult
                                                    acquired
                                                    ( \managed receipt change ->
                                                        Right
                                                            ( resourceHandleKey managed
                                                            , resourceHandleGeneration managed
                                                            , ownershipReceiptOperationKey receipt
                                                            , change
                                                            )
                                                    )
                                                    (\_ _ -> Left (Failure (FailureDetail "fresh empty-edge fixture" "provider became foreign" DoNotRetry)))
            settled <- traverse id prepared
            joinReconcile settled @?= Right ("core:deploy-vm", 5, "core:deploy-vm:provider:empty-snapshot", Changed Created)
            readIORef probes >>= (@?= 0)
            readIORef callbacks >>= (@?= 1)
    , testCase "provider network readiness cannot satisfy a provider responding edge" $ do
        result <- withFreshShareFixture $ \digest _observed descriptor provider managed -> do
            gate <- freshShareGate digest
            ProbeKernel.withBackendProbe ProbeKernel.ProviderNetworkProbe provider
                (\_ -> error "a wrong-kind provider probe must not run") $ \networkProbe -> do
                    let probe = Readiness.planDependencyProbe Readiness.vmBootPoll "network" managed networkProbe
                            (error "a wrong-kind provider probe must not need host configuration")
                        snapshot = withDependencySnapshotEntry managed probe emptyDependencySnapshot
                    outcome <- withPreparedOperation descriptor snapshot gate (\_ _ -> ())
                    case outcome of
                        Left (Conflict _) -> pure (Right ())
                        other -> assertFailure ("expected provider readiness-kind conflict, got " ++ show other)
        result @?= Right ()
    , testCase "fresh preparation refuses the dependency's first not-ready observation" $ do
        let refusal = Failure (FailureDetail "fresh dependency" "not ready at preparation" ReprobeBeforeRetry)
        (_, outcome, probes, callbacks) <-
            freshPreparationSummary freshShareGate FreshMemberPresent (Left refusal)
        (outcome, probes, callbacks) @?= (Left refusal, 1, 0)
    , testCase "fresh preparation refuses another plan's gate before probing" $ do
        (digest, outcome, probes, callbacks) <-
            freshPreparationSummary
                (\_ -> gateFor "some-other-plan-digest" "core:copy-source")
                FreshMemberPresent
                (Right 17)
        outcome
            @?= Left
                ( Conflict
                    ( ConflictDetail
                        "core:copy-source"
                        ("a prepare gate from plan " <> digest)
                        "a prepare gate from plan some-other-plan-digest"
                        "prepare each operation through its own plan's journal"
                    )
                )
        (probes, callbacks) @?= (0, 0)
    , testCase "fresh preparation refuses another operation's gate before probing" $ do
        (_, outcome, probes, callbacks) <-
            freshPreparationSummary
                (\digest -> gateFor digest "core:deploy-vm")
                FreshMemberPresent
                (Right 17)
        outcome
            @?= Left
                ( Conflict
                    ( ConflictDetail
                        "core:copy-source"
                        "a prepare gate recorded for core:copy-source"
                        "a prepare gate recorded for core:deploy-vm"
                        "record this operation's unknown phase before preparing it"
                    )
                )
        (probes, callbacks) @?= (0, 0)
    , testCase "fresh preparation refuses a zero attempt before probing" $ do
        (_, outcome, probes, callbacks) <-
            freshPreparationSummary
                (\digest -> gateForValues digest "core:copy-source" "session-1" 1 0)
                FreshMemberPresent
                (Right 17)
        (outcome, probes, callbacks)
            @?= (Left (Failure (FailureDetail "prepare operation" "attempt must be positive" DoNotRetry)), 0, 0)
    , testCase "fresh preparation refuses a missing member through its own traversal" $ do
        (_, outcome, probes, callbacks) <-
            freshPreparationSummary freshShareGate FreshMemberMissing (Right 17)
        outcome
            @?= Left
                ( Failure
                    ( FailureDetail
                        "seal operation preconditions"
                        "no managed resource for plan dependency core:deploy-vm of core:copy-source"
                        ReprobeBeforeRetry
                    )
                )
        (probes, callbacks) @?= (0, 0)
    , testCase "fresh preparation refuses a duplicate member before running its probe" $ do
        (_, outcome, probes, callbacks) <-
            freshPreparationSummary freshShareGate FreshMemberDuplicated (Right 17)
        outcome
            @?= Left
                ( Conflict
                    ( ConflictDetail
                        "core:deploy-vm"
                        "one managed resource per plan dependency"
                        "the dependency snapshot carries the key more than once"
                        "register each acquired resource under its plan operation key exactly once"
                    )
                )
        (probes, callbacks) @?= (0, 0)
    , testCase "chart preparation runs its ready cluster probe exactly once" $ do
        (outcome, probes, callbacks) <- countedChartPreparation (Right 8) False
        outcome @?= Right ("core:deploy-chart", ["core:deploy-kind"])
        (probes, callbacks) @?= (1, 1)
    , testCase "chart preparation refuses its first not-ready cluster observation" $ do
        let refusal = Failure (FailureDetail "readiness" "not ready" ReprobeBeforeRetry)
        (outcome, probes, callbacks) <- countedChartPreparation (Left refusal) False
        (outcome, probes, callbacks) @?= (Left refusal, 1, 0)
    , testCase "chart preparation checks its gate before its cluster probe" $ do
        (outcome, probes, callbacks) <- countedChartPreparation (Right 8) True
        outcome
            @?= Left
                ( Conflict
                    ( ConflictDetail
                        "core:deploy-chart"
                        "a prepare gate recorded for core:deploy-chart"
                        "a prepare gate recorded for core:deploy-kind"
                        "record this operation's unknown phase before preparing it"
                    )
                )
        (probes, callbacks) @?= (0, 0)
    ]

data FreshSnapshotMembers = FreshMemberPresent | FreshMemberMissing | FreshMemberDuplicated

freshShareGate :: Text.Text -> IO PreparedGate
freshShareGate digest = gateFor digest "core:copy-source"

freshPreparationSummary ::
    (Text.Text -> IO PreparedGate) ->
    FreshSnapshotMembers ->
    Either ReconcileError Word64 ->
    IO (Text.Text, Either ReconcileError (Text.Text, Word64, Text.Text, ChangeView), Int, Int)
freshPreparationSummary openGate members answer = do
    result <- withFreshShareFixture $ \digest observed descriptor _provider managedProvider -> do
        gate <- openGate digest
        -- Every supplied gate is a real fresh-store CAS, including refusals
        -- with caller-selected attempts. No caller supplies a journal version.
        preparedGateJournalVersion gate @?= 1
        probes <- newIORef (0 :: Int)
        callbacks <- newIORef (0 :: Int)
        let probe = TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (modifyIORef' probes (+ 1) >> pure answer)
            entry = withDependencySnapshotEntry managedProvider probe
            snapshot = case members of
                FreshMemberPresent -> entry emptyDependencySnapshot
                FreshMemberMissing -> emptyDependencySnapshot
                FreshMemberDuplicated -> entry (entry emptyDependencySnapshot)
        readIORef probes >>= (@?= 0)
        readIORef callbacks >>= (@?= 0)
        prepared <- withPreparedOperation descriptor snapshot gate $ \operation preconditions -> do
            modifyIORef' callbacks (+ 1)
            pure $ do
                acquired <- completeReconcile observed operation preconditions (BackendCreated 11)
                withReconcileResult
                    acquired
                    ( \managed receipt change ->
                        Right
                            ( resourceHandleKey managed
                            , resourceHandleGeneration managed
                            , ownershipReceiptOperationKey receipt
                            , change
                            )
                    )
                    (\_ _ -> Left (Failure (FailureDetail "fresh preparation fixture" "share became foreign" DoNotRetry)))
        -- Run any returned callback action even when refusal was expected.
        settled <- traverse id prepared
        probeCount <- readIORef probes
        callbackCount <- readIORef callbacks
        pure (Right (digest, joinReconcile settled, probeCount, callbackCount))
    either (assertFailure . show) pure result

withFreshShareFixture ::
    ( forall scope planId providerId providerFrame shareId.
      Text.Text ->
      ResourceHandle scope planId shareId DurableShareResource Unclassified Observed ->
      OperationDescriptor scope planId shareId DurableShareResource Observed Provisioned ->
      PlannedResource scope planId providerId ProviderResource providerFrame ->
      ResourceHandle scope planId providerId ProviderResource Managed Provisioned ->
      IO (Either ReconcileError result)
    ) ->
    IO (Either ReconcileError result)
withFreshShareFixture consume =
    withTestResource projectPrefixedPlan ProviderResourceKind "core:deploy-vm" $ \plan provider -> do
        providerGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
        case find
            ((== "core:copy-source") . Text.pack . operationKeyText . plannedStepOperationKey)
            (NonEmpty.toList (forward plan)) of
            Nothing -> assertFailure "copy-source node missing from fresh preparation fixture"
            Just shareNode ->
                case withPlannedResourceOfKind
                    plan
                    DurableShareResourceKind
                    (plannedStepOperationKey shareNode)
                    ( \share ->
                        joinIO $
                            withManagedProvider providerGate plan provider $ \managedProvider ->
                                joinIO $
                                    withObservedPlannedResource plan share 11 13 $ \observed ->
                                        case plannedOperation plan share observed "share:mount" of
                                            Left failure -> pure (Left failure)
                                            Right descriptor -> consume (admittedPlanDigest plan) observed descriptor provider managedProvider
                    ) of
                    Left failure -> pure (Left (planProjectionFailure failure))
                    Right action -> action

countedChartPreparation ::
    Either ReconcileError Word64 ->
    Bool ->
    IO (Either ReconcileError (Text.Text, [Text.Text]), Int, Int)
countedChartPreparation answer wrongGate = do
    probes <- newIORef (0 :: Int)
    callbacks <- newIORef (0 :: Int)
    let probe = modifyIORef' probes (+ 1) >> pure answer
    readIORef probes >>= (@?= 0)
    readIORef callbacks >>= (@?= 0)
    prepared <-
        chartPreparationWithProbe probe wrongGate $ \keys key -> do
            modifyIORef' callbacks (+ 1)
            pure (key, keys)
    outcome <- traverse id prepared
    probeCount <- readIORef probes
    callbackCount <- readIORef callbacks
    pure (outcome, probeCount, callbackCount)

zeroDependencyPreparationCases :: [TestTree]
zeroDependencyPreparationCases =
    [ testCase "the zero operation entry completes an unchanged resource" $
        zeroOperationUnchangedSummary >>= (@?= Right Unchanged)
    , testCase "the zero-dependency branch refuses an operation that declares edges" $
        zeroBranchOnDependentOperation
    , testCase "the zero operation entry refuses another plan's gate" $
        zeroOperationRefusal
            (\_ -> gateFor "some-other-plan-digest" "core:deploy-kind")
            ( \digest ->
                Conflict
                    ( ConflictDetail
                        "core:deploy-kind"
                        ("a prepare gate from plan " <> digest)
                        "a prepare gate from plan some-other-plan-digest"
                        "prepare each operation through its own plan's journal"
                    )
            )
    , testCase "the zero operation entry refuses another operation's gate" $
        zeroOperationRefusal
            (\digest -> gateFor digest "core:deploy-vm")
            ( const
                ( Conflict
                    ( ConflictDetail
                        "core:deploy-kind"
                        "a prepare gate recorded for core:deploy-kind"
                        "a prepare gate recorded for core:deploy-vm"
                        "record this operation's unknown phase before preparing it"
                    )
                )
            )
    , testCase "the zero operation entry requires a positive attempt" $
        zeroOperationRefusal
            (\digest -> gateForValues digest "core:deploy-kind" "session-1" 5 0)
            (const (Failure (FailureDetail "prepare operation" "attempt must be positive" DoNotRetry)))
    , testCase "the zero phase entry completes force destroy from the managed running handle" $
        zeroPhaseDestroySummary >>= (@?= Right (7, "core:deploy-vm:call:one"))
    , testCase "dependent phases retain generic preparation and refuse the zero phase entry" $
        zeroPhaseDependencyRefusal
    ]

zeroOperationUnchangedSummary :: IO (Either ReconcileError ChangeView)
zeroOperationUnchangedSummary =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:deploy-kind"
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                            verified <-
                                verifyPersistedJournalRecord
                                    plan
                                    planned
                                    handle
                                    "acquire"
                                    (journalRecord (Text.unpack (admittedPlanDigest plan)) (plannedResourceFrame planned) Committed)
                            joinReconcile $
                                withPriorCommitProof verified $ \proof -> do
                                    result <- completePreparedUnchanged handle prepared preconditions proof
                                    withReconcileResult
                                        result
                                        (\_ _ change -> Right change)
                                        (\_ _ -> Left (Failure (FailureDetail "test unchanged resource" "expected managed ownership" DoNotRetry)))

zeroOperationRefusal ::
    (Text.Text -> IO PreparedGate) ->
    (Text.Text -> ReconcileError) ->
    IO ()
zeroOperationRefusal openGate expectedFailure =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \plan planned -> do
        gate <- openGate (admittedPlanDigest plan)
        delivered <- newIORef (0 :: Int)
        let outcome =
                joinReconcile $
                    withObservedPlannedResource plan planned 7 3 $ \handle -> do
                        descriptor <- plannedOperation plan planned handle "call:one"
                        withPreparedZeroDependencyOperation descriptor gate $ \_ _ ->
                            modifyIORef' delivered (+ 1)
        assertPreparationNotDelivered delivered (expectedFailure (admittedPlanDigest plan)) outcome

assertPreparationNotDelivered :: IORef Int -> ReconcileError -> Either ReconcileError (IO ()) -> IO ()
assertPreparationNotDelivered delivered expectedFailure outcome = do
    -- Execute any mistakenly delivered callback action before inspecting the refusal.
    executed <- traverse id outcome
    executed @?= Left expectedFailure
    readIORef delivered >>= (@?= 0)

zeroDependencyConflict :: ReconcileError
zeroDependencyConflict =
    Conflict
        ( ConflictDetail
            "core:copy-source"
            "an operation with no plan dependencies"
            "the plan declares core:deploy-vm"
            "seal this operation through the plan dependency-snapshot traversal"
        )

-- | The public zero entry must reject a genuine edge-bearing descriptor itself.
zeroBranchOnDependentOperation :: IO ()
zeroBranchOnDependentOperation =
    withTestResource projectPrefixedPlan DurableShareResourceKind "core:copy-source" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:copy-source"
        delivered <- newIORef (0 :: Int)
        let outcome =
                joinReconcile $
                    withObservedPlannedResource plan planned 7 3 $ \handle -> do
                        descriptor <- plannedOperation plan planned handle "share:mount"
                        withPreparedZeroDependencyOperation descriptor gate $ \_ _ ->
                            modifyIORef' delivered (+ 1)
        assertPreparationNotDelivered delivered zeroDependencyConflict outcome

zeroPhaseDestroySummary :: IO (Either ReconcileError (Word64, Text.Text))
zeroPhaseDestroySummary =
    withTestResource dependentTestPlan ProviderResourceKind "core:deploy-vm" $ \plan planned -> do
        createGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
        bootGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
        destroyGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
        joinIO $
            withCreatedResource createGate plan planned 7 3 $ \provisioned receipt -> do
                boot <- planProviderBoot provisioned
                bootDescriptor <- plannedProjectPhaseOperation plan planned provisioned receipt boot "provider:boot"
                pure $
                    fmap joinReconcile $
                        withPreparedPhaseTransition provisioned receipt boot bootDescriptor emptyDependencySnapshot bootGate $ \preparedBoot -> do
                            runningAdvance <- completePreparedPhaseTransition preparedBoot 7
                            withPhaseAdvance runningAdvance $ \running runningReceipt _ -> do
                                destroy <- planProviderForceDestroy running
                                descriptor <-
                                    plannedProjectPhaseOperation plan planned running runningReceipt destroy "provider:destroy-force"
                                joinReconcile $
                                    withPreparedZeroDependencyPhaseTransition running runningReceipt destroy descriptor destroyGate $ \prepared -> do
                                        advance <- completePreparedPhaseTransition prepared 7
                                        pure $
                                            withPhaseAdvance advance $ \destroyed destroyedReceipt _ ->
                                                (resourceHandleGeneration destroyed, ownershipReceiptOperationKey destroyedReceipt)

zeroPhaseDependencyRefusal :: IO ()
zeroPhaseDependencyRefusal =
    withTestResource projectPrefixedPlan ProviderResourceKind "core:deploy-vm" $ \plan provider -> do
        providerGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
        shareGate <- gateFor (admittedPlanDigest plan) "core:copy-source"
        phaseGate <- gateFor (admittedPlanDigest plan) "core:copy-source"
        probes <- newIORef (0 :: Int)
        delivered <- newIORef (0 :: Int)
        case find
            ((== "core:copy-source") . Text.pack . operationKeyText . plannedStepOperationKey)
            (NonEmpty.toList (forward plan)) of
            Nothing -> assertFailure "copy-source node missing from dependent phase fixture"
            Just shareNode -> do
                outcome <-
                    case withPlannedResourceOfKind
                        plan
                        DurableShareResourceKind
                        (plannedStepOperationKey shareNode)
                        ( \share ->
                            joinIO $
                                withManagedProvider providerGate plan provider $ \managedProvider ->
                                    joinIO $
                                        withObservedPlannedResource plan share 11 13 $ \observed ->
                                            case plannedOperation plan share observed "share:mount" of
                                                Left failure -> pure (Left failure)
                                                Right descriptor -> do
                                                    let snapshot =
                                                            withDependencySnapshotEntry
                                                                managedProvider
                                                                (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (modifyIORef' probes (+ 1) >> pure (Right 17)))
                                                                emptyDependencySnapshot
                                                    acquired <-
                                                        withPreparedOperation descriptor snapshot shareGate $ \prepared sealed -> do
                                                            original <- completeReconcile observed prepared sealed (BackendCreated 11)
                                                            replacement <- completeReconcile observed prepared sealed (BackendCreated 12)
                                                            pure (original, replacement)
                                                    case joinReconcile acquired of
                                                        Left failure -> pure (Left failure)
                                                        Right (original, replacement) ->
                                                            withReconcileResult
                                                                original
                                                                ( \managed receipt _ ->
                                                                    withReconcileResult
                                                                        replacement
                                                                        ( \replaced replacementReceipt _ ->
                                                                            case do
                                                                                ready <- planMarkReady managed
                                                                                replacementReady <- planMarkReady replaced
                                                                                phaseDescriptor <- plannedProjectPhaseOperation plan share managed receipt ready "share:ready"
                                                                                pure (ready, replacementReady, phaseDescriptor) of
                                                                                Left failure -> pure (Left failure)
                                                                                Right (ready, replacementReady, phaseDescriptor) -> do
                                                                                    operationDescriptorDependencies phaseDescriptor @?= ["core:deploy-vm"]
                                                                                    readIORef probes >>= (@?= 1)
                                                                                    phaseCallbacks <- newIORef (0 :: Int)
                                                                                    generic <-
                                                                                        withPreparedPhaseTransition managed receipt ready phaseDescriptor snapshot phaseGate $ \preparedPhase -> do
                                                                                            modifyIORef' phaseCallbacks (+ 1)
                                                                                            pure $ do
                                                                                                advance <- completePreparedPhaseTransition preparedPhase 11
                                                                                                pure $
                                                                                                    withPhaseAdvance advance $ \readyShare readyReceipt _ ->
                                                                                                        (resourceHandleGeneration readyShare, ownershipReceiptOperationKey readyReceipt)
                                                                                    settled <- traverse id generic
                                                                                    joinReconcile settled @?= Right (11, "core:copy-source:share:mount")
                                                                                    readIORef probes >>= (@?= 2)
                                                                                    readIORef phaseCallbacks >>= (@?= 1)

                                                                                    wrongGate <- gateFor (admittedPlanDigest plan) "core:deploy-vm"
                                                                                    wrongReceipt <-
                                                                                        withPreparedPhaseTransition managed replacementReceipt ready phaseDescriptor snapshot wrongGate $ \_ ->
                                                                                            modifyIORef' delivered (+ 1)
                                                                                    assertPreparationNotDelivered
                                                                                        delivered
                                                                                        (Conflict (ConflictDetail "core:copy-source" "generation=11" "generation=12" "load the ownership receipt for the exact managed generation"))
                                                                                        wrongReceipt
                                                                                    wrongTransition <-
                                                                                        withPreparedPhaseTransition managed receipt replacementReady phaseDescriptor snapshot wrongGate $ \_ ->
                                                                                            modifyIORef' delivered (+ 1)
                                                                                    assertPreparationNotDelivered
                                                                                        delivered
                                                                                        (Conflict (ConflictDetail "core:copy-source" "transition generation=11" "transition generation=12" "replan the phase transition from the current managed generation"))
                                                                                        wrongTransition
                                                                                    wrongOperation <-
                                                                                        withPreparedPhaseTransition managed receipt ready phaseDescriptor snapshot wrongGate $ \_ ->
                                                                                            modifyIORef' delivered (+ 1)
                                                                                    assertPreparationNotDelivered
                                                                                        delivered
                                                                                        (Conflict (ConflictDetail "core:copy-source" "a prepare gate recorded for core:copy-source" "a prepare gate recorded for core:deploy-vm" "record this operation's unknown phase before preparing it"))
                                                                                        wrongOperation
                                                                                    readIORef probes >>= (@?= 2)

                                                                                    notReadyProbes <- newIORef (0 :: Int)
                                                                                    let refusal = Failure (FailureDetail "phase dependency" "not ready at phase preparation" ReprobeBeforeRetry)
                                                                                        notReadySnapshot =
                                                                                            withDependencySnapshotEntry
                                                                                                managedProvider
                                                                                                (TestDependency.dependencyProbeWithKind ProbeKernel.ProviderRespondingKind (modifyIORef' notReadyProbes (+ 1) >> pure (Left refusal)))
                                                                                                emptyDependencySnapshot
                                                                                    notReady <-
                                                                                        withPreparedPhaseTransition managed receipt ready phaseDescriptor notReadySnapshot phaseGate $ \_ ->
                                                                                            modifyIORef' delivered (+ 1)
                                                                                    assertPreparationNotDelivered delivered refusal notReady
                                                                                    readIORef notReadyProbes >>= (@?= 1)

                                                                                    let zero =
                                                                                            withPreparedZeroDependencyPhaseTransition managed receipt ready phaseDescriptor phaseGate $ \_ ->
                                                                                                modifyIORef' delivered (+ 1)
                                                                                    assertPreparationNotDelivered delivered zeroDependencyConflict zero
                                                                                    readIORef probes >>= (@?= 2)
                                                                                    pure (Right ())
                                                                        )
                                                                        (\_ _ -> pure (Left (Failure (FailureDetail "test share" "expected managed replacement ownership" DoNotRetry))))
                                                                )
                                                                (\_ _ -> pure (Left (Failure (FailureDetail "test share" "expected managed ownership" DoNotRetry))))
                        ) of
                        Left failure -> pure (Left (planProjectionFailure failure))
                        Right action -> action
                outcome @?= Right ()

missingDependencyPreparation :: IO (Either ReconcileError ())
missingDependencyPreparation =
    withTestResource dependentTestPlan DurableShareResourceKind "core:copy-source" $ \plan planned -> do
        gate <- gateFor (admittedPlanDigest plan) "core:copy-source"
        callbacks <- newIORef (0 :: Int)
        prepared <-
            joinIO $
                withObservedPlannedResource plan planned 7 3 $ \handle ->
                    case plannedOperation plan planned handle "share:mount" of
                        Left failure -> pure (Left failure)
                        Right descriptor -> do
                            operationDescriptorDependencies descriptor @?= ["core:deploy-vm"]
                            withPreparedOperation descriptor emptyDependencySnapshot gate $ \_ _ ->
                                modifyIORef' callbacks (+ 1)
        -- Execute any wrongly returned action before checking that none ran.
        outcome <- traverse id prepared
        readIORef callbacks >>= (@?= 0)
        pure outcome

journalRecord :: String -> Text.Text -> PersistedJournalPhase -> PersistedJournalRecord
journalRecord digest frame phase =
    PersistedJournalRecord
        { persistedPlanDigest = text digest
        , persistedFrameKey = frame
        , persistedResourceKey = "core:deploy-kind"
        , persistedGeneration = 7
        , persistedOperation = "acquire"
        , persistedOperationKey = "core:deploy-kind:call:one"
        , persistedRecordVersion = 4
        , persistedPhase = phase
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
      PlannedResource (Production projectId) planId resourceId resource frame ->
      IO result
    ) ->
    IO result
withTestResource stepPlan resourceKind expectedKey use =
    Fixture.withFixtureProjectPlan stepPlan $ \plan ->
        case find
            ( (== expectedKey)
                . Text.pack
                . operationKeyText
                . plannedStepOperationKey
            )
            (NonEmpty.toList (forward plan)) of
            Nothing -> fail ("resource operation missing from fixture plan: " ++ Text.unpack expectedKey)
            Just node ->
                case withPlannedResourceOfKind
                    plan
                    resourceKind
                    (plannedStepOperationKey node)
                    (use plan) of
                    Left failure -> fail (show failure)
                    Right action -> action
