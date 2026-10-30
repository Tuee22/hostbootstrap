{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ReconcileSpec (tests) where

import Control.Monad (forM)
import Data.Bits (shiftR)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import Data.Word (Word64)
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
    ProjectPlan,
    forward,
    plannedEdgeDependencyKey,
    plannedEdgeTargetKey,
    plannedStepDependencyOperations,
    plannedStepFrameId,
    plannedStepIdentity,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    renderSnapshot,
    stablePlanSnapshotConfigDigest,
    stablePlanSnapshotDigest,
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
                assertBool "a child config substitution retained the same snapshot bytes" (fst first /= fst second)
                assertBool "a child config substitution retained the same snapshot digest" (snd first /= snd second)
            , testCase "delivery destination changes canonical bytes and digest" $ do
                first <- canonicalSummary "config-a" (containerCanonicalPlanAt "/app/config.dhall" "fixture-secret-payload")
                second <- canonicalSummary "config-a" (containerCanonicalPlanAt "/other/config.dhall" "fixture-secret-payload")
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
            , testCase "owned settlement carries the exact managed receipt under the same plan" $
                assertExactResourceCarrier
            , testCase "every opaque reconciliation and execution index has a nominal role" $
                assertNominalRoleInventory
            , testCase "the neutral package has one producer and introduces no Plan import cycle" $
                assertPlanExecutionPackageBoundary
            ]
        , testCase "observed resources require stable positive identity versions" $ do
            observed <-
                withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned ->
                    pure $
                        withObservedPlannedResource plan planned 0 0 (const ())
            observed
                @?= Left
                    (Failure (FailureDetail "observe resource" "generation must be positive" DoNotRetry))
        , testCase "positive generations still require a positive observation version" $ do
            observed <-
                withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned ->
                    pure (withObservedPlannedResource plan planned 1 0 (const ()))
            observed
                @?= Left
                    (Failure (FailureDetail "observe resource" "observation version must be positive" DoNotRetry))
        , testCase "chart preparation seals exactly its ready cluster dependency" $
            chartPreparationSummary True False >>= (@?= Right ("core:deploy-chart", ["core:deploy-kind"]))
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
        , testCase "journal verification rejects another plan digest" $
            journalMismatch >>= (@?= True)
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
            case outcome of
                Left (Conflict _) -> pure ()
                other -> fail ("expected dependency conflict, got " ++ show other)
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

assertPlanExecutionPackageBoundary :: IO ()
assertPlanExecutionPackageBoundary = do
    found <- getCurrentDirectory >>= findRepoRoot
    root <- maybe (assertFailure "repository root not found") pure found
    let source = root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap"
    execution <- TextIO.readFile (source </> "Lifecycle" </> "Execution" </> "Internal.hs")
    reconcile <- TextIO.readFile (source </> "Reconcile.hs")
    child <- TextIO.readFile (source </> "Command" </> "Child.hs")
    assertBool "Execution.Internal imports the plan kernel" (not ("import HostBootstrap.Lifecycle.Plan" `Text.isInfixOf` execution))
    assertBool "the package constructor is absent from recursive command code" (not ("mintPlanExecutionPackage" `Text.isInfixOf` child))
    assertBool "Reconcile is not the package producer" ("mintPlanExecutionPackage" `Text.isInfixOf` reconcile)
    assertBool "the recursive forward frame uses its plan-indexed opener" ("withOpenedFrameExecutorForPlanKernel" `Text.isInfixOf` child)
    assertBool "the recursive child retains the exact planned node" ("(ExecutionNode, Step, PlannedStep scope planId configId (cfg scope))" `Text.isInfixOf` child)
    assertBool "the recursive child uses the sole execution producer" ("stepExecutionFor plan host stepRuntime planned" `Text.isInfixOf` child)

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
                case withNodeResourceOfKind
                    providerExecution
                    ClusterResourceKind
                    "core:deploy-kind"
                    (const ()) of
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
                freshCarrier <- Execution.newResourceCarrier
                freshRuntime <- Execution.newStepRuntime freshCarrier
                let freshExecution = stepExecutionFor plan exactExecutionHostConfig freshRuntime node
                missing <- withCarriedManagedResourceReceipt freshExecution operationKey (\_ _ -> ())
                case missing of
                    Left (Failure _) -> pure ()
                    other -> assertFailure ("expected fresh-carrier ownership refusal, got " ++ show other)
            nodes -> fail ("expected one exact carrier node, got " ++ show (length nodes))

chartPreparationSummary :: Bool -> Bool -> IO (Either ReconcileError (Text.Text, [Text.Text]))
chartPreparationSummary probeReady wrongGate =
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
                                    preconditions <- zeroDependencyPreconditions descriptor
                                    withPreparedOperation descriptor preconditions clusterGate $ \prepared sealed -> do
                                        created <- completeReconcile observed prepared sealed (BackendCreated 5)
                                        withReconcileResult
                                            created
                                            ( \managed _ _ ->
                                                Right
                                                    ( withPreparedChartWorkloadOperation
                                                        chart
                                                        managed
                                                        (dependencyProbe (pure (if probeReady then Right 8 else Left (Failure (FailureDetail "readiness" "not ready" ReprobeBeforeRetry)))))
                                                        "chart-call"
                                                        chartGate
                                                        (\keys handle _ _ -> (resourceHandleKey handle, keys))
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
    , "type role PreparedProviderStart nominal nominal nominal nominal nominal nominal nominal"
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
    [ "type role PlanExecutionPackage nominal nominal"
    , "type role StepExecution nominal nominal"
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
    (bytes, _) <- canonicalSummary "config-a" (containerCanonicalPlan "fixture-secret-payload")
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
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- openGate (lifecyclePlanDigest plan)
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    preconditionSet <- zeroDependencyPreconditions descriptor
                    joinReconcile $
                        withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
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
adoptionSummary = adoptionObservationSummary (BackendRepaired 7)

adoptionObservationSummary :: BackendReconcileObservation -> IO (Either ReconcileError ChangeView)
adoptionObservationSummary backendObservation =
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
                                                adopted <- completeAdoption unmanaged origin authority backendObservation
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
            case withObservedPlannedResource plan planned 7 3 $ \handle ->
                case verifyPersistedJournalRecord plan handle "acquire" (journalRecord "other" Committed) of
                    Left _ -> True
                    Right _ -> False of
                Left _ -> True
                Right mismatched -> mismatched

unchangedSummary :: IO (Either ReconcileError ChangeView)
unchangedSummary = unchangedSummaryFor Committed "core:deploy-kind:call:one"

unchangedSummaryFor :: PersistedJournalPhase -> Text.Text -> IO (Either ReconcileError ChangeView)
unchangedSummaryFor phase operation =
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
        let semanticOperation = if phase == AdoptionCommitted then "adopt" else "acquire"
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
                                    semanticOperation
                                    ( (journalRecord (Text.unpack (lifecyclePlanDigest plan)) phase)
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
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 3 4 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    preconditionSet <- zeroDependencyPreconditions descriptor
                    joinReconcile $
                        withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
                            result <- completeReconcile handle prepared preconditions (BackendCreated 9)
                            withReconcileResult
                                result
                                ( \managed receipt _ -> do
                                    transition <- planMarkReady managed
                                    advance <- verifyPhaseTransition managed receipt transition observedGeneration
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
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
        pure $
            withForeignResource gate plan planned 7 3 $ \target _ ->
                withForeignResource gate plan planned originGeneration originVersion $ \source observation ->
                    withVerifiedForeignOrigin source observation $ \origin ->
                        withAdoptionAuthority plan planned target origin operation (const ())

withForeignResource ::
    PreparedGate ->
    LifecyclePlan scope planId ->
    PlannedResource scope planId resourceId resource frame ->
    Word64 ->
    Word64 ->
    (ResourceHandle scope planId resourceId resource Unmanaged Observed -> ForeignObservation -> Either ReconcileError result) ->
    Either ReconcileError result
withForeignResource gate plan planned generation observationVersion consume =
    joinReconcile $
        withObservedPlannedResource plan planned generation observationVersion $ \observed -> do
            descriptor <- plannedOperation plan planned observed "call:observe-foreign"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
                withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
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
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
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
    withTestResource dependentTestPlan ProviderResourceKind "core:deploy-vm" $ \projectPlan plan provider -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-vm"
        case find
            ((== "core:copy-source") . operationKeyText . plannedStepOperationKey)
            (NonEmpty.toList (forward projectPlan)) of
            Nothing -> fail "the receipt fixture plan lacks its durable share"
            Just shareNode ->
                case withPlannedResourceOfKind
                    projectPlan
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
    LifecyclePlan scope planId ->
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
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
                withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
                    reconciled <- completeReconcile observed prepared preconditions (BackendCreated generation)
                    withReconcileResult
                        reconciled
                        (\managed receipt _ -> consume managed receipt)
                        (\_ _ -> Left (Failure (FailureDetail "test receipt" "expected managed ownership" DoNotRetry)))

-- The receipt comes from the same public durable evidence path as recovery.
withDurableReceipt ::
    LifecyclePlan scope planId ->
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
        withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned ->
            renderResourceRecordBundle plan planned 7 "" 3 "provisioned" "adapter-v1" True
                @?= Left emptyDurableOperation
    , testCase "durable parsing refuses an empty ownership operation" $
        withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
            canonical <-
                either (assertFailure . show) pure $
                    renderResourceRecordBundle plan planned 7 "ownership:acquire" 3 "provisioned" "adapter-v1" True
            let verify = verifyResourceRecordBundle plan planned 7 "ownership:acquire" 3 "provisioned" "adapter-v1"
            (() <$ verify canonical) @?= Right ()
            withoutOperation <- emptyRecordOwnershipOperation canonical
            (() <$ verify withoutOperation) @?= Left emptyDurableOperation
    , testCase "journal ingress refuses an empty stable ownership operation" $ do
        outcome <-
            withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned ->
                pure $
                    joinReconcile $
                        withObservedPlannedResource plan planned 7 3 $ \handle ->
                            ()
                                <$ verifyPersistedJournalRecord
                                    plan
                                    handle
                                    "acquire"
                                    ( (journalRecord (Text.unpack (lifecyclePlanDigest plan)) Committed)
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

providerForceDestroyChecks ::
    IO (Either ReconcileError (Word, Text.Text, Bool, Bool, Bool))
providerForceDestroyChecks =
    withTestResource dependentTestPlan ProviderResourceKind "core:deploy-vm" $ \projectPlan _ planned -> do
        let planDigest = stablePlanSnapshotDigest (renderSnapshot projectPlan)
            operationKey = "core:deploy-vm"
        createGate <- gateFor planDigest operationKey
        replacementGate <- gateFor planDigest operationKey
        destroyGate <- gateFor planDigest operationKey
        pure $
            joinReconcile $
                withObservedProjectResource projectPlan planned 7 3 $ \observed -> do
                    createDescriptor <- plannedProjectOperation projectPlan planned observed "provider:create"
                    createPreconditions <- zeroDependencyPreconditions createDescriptor
                    joinReconcile $
                        withPreparedOperation createDescriptor createPreconditions createGate $ \prepared sealed -> do
                            created <- completeReconcile observed prepared sealed (BackendCreated 7)
                            withReconcileResult
                                created
                                ( \provisioned receipt _ -> do
                                    boot <- planProviderBoot provisioned
                                    runningAdvance <- verifyPhaseTransition provisioned receipt boot 7
                                    withPhaseAdvance runningAdvance $ \running runningReceipt _ ->
                                        joinReconcile $
                                            withObservedProjectResource projectPlan planned 8 4 $ \replacementObserved -> do
                                                replacementDescriptor <-
                                                    plannedProjectOperation projectPlan planned replacementObserved "provider:replacement"
                                                replacementPreconditions <- zeroDependencyPreconditions replacementDescriptor
                                                joinReconcile $
                                                    withPreparedOperation
                                                        replacementDescriptor
                                                        replacementPreconditions
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
                                                                            projectPlan
                                                                            planned
                                                                            running
                                                                            runningReceipt
                                                                            destroy
                                                                            "provider:destroy-force"
                                                                    destroyPreconditions <- zeroDependencyPreconditions destroyDescriptor
                                                                    joinReconcile $
                                                                        withPreparedPhaseTransition
                                                                            running
                                                                            runningReceipt
                                                                            destroy
                                                                            destroyDescriptor
                                                                            destroyPreconditions
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
                                                                                                projectPlan
                                                                                                planned
                                                                                                running
                                                                                                runningReceipt
                                                                                                destroy
                                                                                                ""
                                                                                            )
                                                                                    replacementReceiptRefused =
                                                                                        isConflict
                                                                                            ( plannedProjectPhaseOperation
                                                                                                projectPlan
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
            case find
                ( (== "core:copy-source")
                    . Text.pack
                    . operationKeyText
                    . plannedStepOperationKey
                )
                (NonEmpty.toList (forward projectPlan)) of
                Nothing -> fail "copy-source node missing from prefixed fixture plan"
                Just shareNode ->
                    case withPlannedResourceOfKind
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
                        ) of
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
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:deploy-kind"
        pure $
            joinReconcile $
                withObservedPlannedResource plan planned 7 3 $ \handle -> do
                    descriptor <- plannedOperation plan planned handle "call:one"
                    joinReconcile $
                        withPreparedZeroDependencyOperation descriptor gate $ \prepared preconditions -> do
                            verified <-
                                verifyPersistedJournalRecord
                                    plan
                                    handle
                                    "acquire"
                                    (journalRecord (Text.unpack (lifecyclePlanDigest plan)) Committed)
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
    withTestResource testPlan ClusterResourceKind "core:deploy-kind" $ \_ plan planned -> do
        gate <- openGate (lifecyclePlanDigest plan)
        delivered <- newIORef (0 :: Int)
        let outcome =
                joinReconcile $
                    withObservedPlannedResource plan planned 7 3 $ \handle -> do
                        descriptor <- plannedOperation plan planned handle "call:one"
                        withPreparedZeroDependencyOperation descriptor gate $ \_ _ ->
                            modifyIORef' delivered (+ 1)
        assertPreparationNotDelivered delivered (expectedFailure (lifecyclePlanDigest plan)) outcome

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
    withTestResource projectPrefixedPlan DurableShareResourceKind "core:copy-source" $ \_ plan planned -> do
        gate <- gateFor (lifecyclePlanDigest plan) "core:copy-source"
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
    withTestResource dependentTestPlan ProviderResourceKind "core:deploy-vm" $ \projectPlan plan planned -> do
        createGate <- gateFor (lifecyclePlanDigest plan) "core:deploy-vm"
        destroyGate <- gateFor (lifecyclePlanDigest plan) "core:deploy-vm"
        pure $
            withCreatedResource createGate plan planned 7 3 $ \provisioned receipt -> do
                boot <- planProviderBoot provisioned
                runningAdvance <- verifyPhaseTransition provisioned receipt boot 7
                withPhaseAdvance runningAdvance $ \running runningReceipt _ -> do
                    destroy <- planProviderForceDestroy running
                    descriptor <-
                        plannedProjectPhaseOperation projectPlan planned running runningReceipt destroy "provider:destroy-force"
                    joinReconcile $
                        withPreparedZeroDependencyPhaseTransition running runningReceipt destroy descriptor destroyGate $ \prepared -> do
                            advance <- completePreparedPhaseTransition prepared 7
                            pure $
                                withPhaseAdvance advance $ \destroyed destroyedReceipt _ ->
                                    (resourceHandleGeneration destroyed, ownershipReceiptOperationKey destroyedReceipt)

zeroPhaseDependencyRefusal :: IO ()
zeroPhaseDependencyRefusal =
    withTestResource projectPrefixedPlan ProviderResourceKind "core:deploy-vm" $ \projectPlan plan provider -> do
        providerGate <- gateFor (lifecyclePlanDigest plan) "core:deploy-vm"
        shareGate <- gateFor (lifecyclePlanDigest plan) "core:copy-source"
        phaseGate <- gateFor (lifecyclePlanDigest plan) "core:copy-source"
        delivered <- newIORef (0 :: Int)
        case find
            ((== "core:copy-source") . Text.pack . operationKeyText . plannedStepOperationKey)
            (NonEmpty.toList (forward projectPlan)) of
            Nothing -> assertFailure "copy-source node missing from dependent phase fixture"
            Just shareNode -> do
                outcome <-
                    case withPlannedResourceOfKind
                        projectPlan
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
                                                                (dependencyProbe (pure (Right 17)))
                                                                emptyDependencySnapshot
                                                    acquisitionSet <- withOperationPreconditions descriptor snapshot
                                                    case acquisitionSet of
                                                        Left failure -> pure (Left failure)
                                                        Right preconditions ->
                                                            joinIO $
                                                                joinReconcile $
                                                                    withPreparedOperation descriptor preconditions shareGate $ \prepared sealed -> do
                                                                        acquired <- completeReconcile observed prepared sealed (BackendCreated 11)
                                                                        withReconcileResult
                                                                            acquired
                                                                            ( \managed receipt _ -> do
                                                                                ready <- planMarkReady managed
                                                                                phaseDescriptor <-
                                                                                    plannedProjectPhaseOperation projectPlan share managed receipt ready "share:ready"
                                                                                pure $ do
                                                                                    phaseSet <- withOperationPreconditions phaseDescriptor snapshot
                                                                                    case phaseSet of
                                                                                        Left failure -> pure (Left failure)
                                                                                        Right checkedSet -> do
                                                                                            let generic =
                                                                                                    joinReconcile $
                                                                                                        withPreparedPhaseTransition managed receipt ready phaseDescriptor checkedSet phaseGate $ \preparedPhase -> do
                                                                                                            advance <- completePreparedPhaseTransition preparedPhase 11
                                                                                                            pure $
                                                                                                                withPhaseAdvance advance $ \readyShare readyReceipt _ ->
                                                                                                                    (resourceHandleGeneration readyShare, ownershipReceiptOperationKey readyReceipt)
                                                                                            generic @?= Right (11, "core:copy-source:share:mount")
                                                                                            let zero =
                                                                                                    withPreparedZeroDependencyPhaseTransition managed receipt ready phaseDescriptor phaseGate $ \_ ->
                                                                                                        modifyIORef' delivered (+ 1)
                                                                                            assertPreparationNotDelivered delivered zeroDependencyConflict zero
                                                                                            pure (Right ())
                                                                            )
                                                                            (\_ _ -> Left (Failure (FailureDetail "test share" "expected managed ownership" DoNotRetry)))
                        ) of
                        Left failure -> pure (Left (planProjectionFailure failure))
                        Right action -> action
                outcome @?= Right ()

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
        { persistedPlanDigest = text digest
        , persistedFrameKey = "metal"
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
      LifecyclePlan (Production projectId) planId ->
      PlannedResource (Production projectId) planId resourceId resource frame ->
      IO result
    ) ->
    IO result
withTestResource stepPlan resourceKind expectedKey use =
    Fixture.withFixtureProjectPlan stepPlan $ \projectPlan ->
        case find
            ( (== expectedKey)
                . Text.pack
                . operationKeyText
                . plannedStepOperationKey
            )
            (NonEmpty.toList (forward projectPlan)) of
            Nothing -> fail ("resource operation missing from fixture plan: " ++ Text.unpack expectedKey)
            Just node ->
                case withPlannedResourceOfKind
                    projectPlan
                    resourceKind
                    (plannedStepOperationKey node)
                    (use projectPlan (lifecyclePlanFromProjectPlan projectPlan)) of
                    Left failure -> fail (show failure)
                    Right action -> action
