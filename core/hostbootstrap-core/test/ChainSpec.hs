{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ChainSpec (tests) where

import Control.Exception (throwIO)
import qualified Control.Exception as Exception
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isAlphaNum)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TIO
import Data.Word (Word64)
import qualified Fixture
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import HostBootstrap.Authority (
    ExecutePhase,
    InstalledProjectIdentity,
    VerbUp,
    installedProjectName,
 )
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Chain
import HostBootstrap.Chain.EntryPolicy (validateCurrentFrameEntry)
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    pureConfigAssembly,
 )
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import qualified HostBootstrap.Harness as Harness
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionDependencyKeys,
    stepExecutionFrame,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
    stepExecutionPreparedGate,
    stepExecutionProjectedOperations,
    stepExecutionTakeProjectedGate,
 )
import HostBootstrap.Lifecycle.Mode (
    LifecycleCursor,
    PlanSnapshotView,
    inspectPlanSnapshot,
    lifecycleCursorFrame,
    lifecycleCursorMatchesCommandAuthority,
    planSnapshotViewConfigDigest,
    planSnapshotViewPlanDigest,
    planSnapshotViewSpecDigest,
 )
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    decodeFields,
    preparedGateOperation,
    preparedGatePlan,
 )
import HostBootstrap.Lifecycle.Session (
    SessionError (SessionStoreFailure),
    allSessionsClosedCount,
    sessionErrorMessage,
    verifyAllSessionsClosed,
 )
import HostBootstrap.Lift (
    ContainerLift (..),
    ContainerPlacement (ProviderGuestContainer),
    InVMSelfPath (InVMSelfPath),
    inContainer,
    inVM,
    currentSelfRef,
 )
import HostBootstrap.Lift.Context (emptyVMStack, vmContext)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    plannedStepFrameId,
    plannedStepLabel,
    topology,
    topologyFrameOrder,
    renderSnapshot,
    stablePlanSnapshotDigest,
 )
import HostBootstrap.ProjectRoot (
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedError (ProtectedIOFailure),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    ProtectedStoreIdentity,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    openProtectedStore,
    protectedStoreIdentity,
    protectedStoreRoot,
    readProtectedRecord,
    recordKeyText,
    recordVersionWord,
    tryProtectedEntry,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (
    BackendReconcileObservation (BackendCreated),
    FailureDetail (FailureDetail),
    PlannedResourceKind (ClusterResourceKind),
    ReconcileError (Conflict, Failure, SafetyRefusal, Unsupported),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    carryManagedResourcePhaseSettlement,
    carryManagedResourceSettlement,
    carryReleasedResourceSettlement,
    completePreparedPhaseTransition,
    completeReconcile,
    emptyDependencySnapshot,
    planMarkReady,
    plannedNodeOperation,
    plannedNodePhaseOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
    resourceRecordKey,
    withCarriedManagedResource,
    withNodeObservedResource,
    withNodeResourceOfKind,
    withPhaseAdvance,
    withPreparedPhaseTransition,
    withPreparedZeroDependencyOperation,
    withReconcileResult,
 )
import HostBootstrap.Step
import qualified HostBootstrap.Substrate as Substrate
import qualified SourceGuard
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, getCurrentDirectory, removeDirectory, removeFile, removePathForcibly, renameFile)
import System.Environment (withArgs)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO (SeekMode (AbsoluteSeek), hClose, hFlush, hSeek, stderr)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

tests :: TestTree
tests =
    testGroup
        "ChainSpec"
        [ testGroup "nextFrameAfter (descent order)" nextFrameCases
        , testGroup "renderChain is the single representation" renderCases
        , testGroup "exact plan admission" admissionCases
        , testGroup "the plan mints each step's execution descriptor (§ U)" descriptorCases
        , testGroup "the interpreter converts each node's observation" observationCases
        , testGroup "current-frame entry policy" entryPolicyCases
        , testGroup "the interpreter's durable transaction" transactionCases
        , testGroup "a node's projected operations (§ CC)" projectionCases
        , testGroup "carried managed handles (§ EE)" carrierCases
        , testGroup "source shape" sourceShapeCases
        ]

-- Fixtures.
metal :: StepFrame
metal = StepFrame{frameId = "host-orchestrator-0", frameLabel = "metal"}

vmFrame :: StepFrame
vmFrame = StepFrame{frameId = "vm-orchestrator-1", frameLabel = "VM"}

ctrFrame :: StepFrame
ctrFrame = StepFrame{frameId = "vm-project-container-2", frameLabel = "container"}

{- | The one-frame exact fixture used by effectful interpreter cases.
Keeping these nodes at the root preserves their local dependency prefixes;
the pure multi-frame cases above separately exercise topology descent.
-}
executionFrame :: StepFrame
executionFrame = metal

noop :: a -> IO StepObservation
noop _ = pure StepChanged

demoSteps :: [Step]
demoSteps =
    [ deployVMStep "launch the VM" metal noop
    , copySourceStep "stage source into the VM" metal noop
    , descendsVia (vmContext (inVM vm emptyVMStack)) (buildPbStep "build the binary in the VM" metal noop)
    , contextInitStep "mint the container config" vmFrame noop
    , descendsVia (inContainer container emptyVMStack) (buildImageStep "build the project image" vmFrame noop)
    , deployKindStep "bring up kind" ctrFrame noop
    , projectStep (fixtureProjectStepId "deploy-harbor") ProjectManagedReverse "install harbor" ctrFrame noop
    , exposePortStep "expose the NodePort" ctrFrame noop
    ]

demoPlan :: StepPlan
demoPlan = expectPlan demoSteps

acceleratorPlan :: StepPlan
acceleratorPlan =
    expectPlan $
        demoSteps
            ++ [postHandoffStep "start-accelerator-daemon" "start the host accelerator daemon" metal noop]

vm :: IncusVM
vm = IncusVM "demo-vm" "images:ubuntu/24.04"

sockMount :: V.Mount
sockMount = V.Mount{V.source = "/var/run/docker.sock", V.target = "/var/run/docker.sock", V.readOnly = False}

container :: ContainerLift
container =
    ContainerLift
        { clImage = "demo:local"
        , clPlacement = ProviderGuestContainer
        , clMounts = [sockMount]
        , clExtraArgs = ["--network=host"]
        , clRemoveAfter = True
        , clConfigDelivery = Nothing
        }

nextFrameCases :: [TestTree]
nextFrameCases =
    [ testCase "hands off from the metal frame to the VM frame" $
        withAdmittedPlan demoPlan $ \plan ->
            fmap fst (nextFrameAfter (topology plan) "host-orchestrator-0")
                @?= Just "vm-orchestrator-1"
    , testCase "hands off from the VM frame to the container frame" $
        withAdmittedPlan demoPlan $ \plan ->
            fmap fst (nextFrameAfter (topology plan) "vm-orchestrator-1")
                @?= Just "vm-project-container-2"
    , testCase "bottoms out at the innermost frame" $
        withAdmittedPlan demoPlan $ \plan ->
            nextFrameAfter (topology plan) "vm-project-container-2" @?= Nothing
    , testCase "a frame the plan never enters has no next frame" $
        withAdmittedPlan demoPlan $ \plan ->
            nextFrameAfter (topology plan) "no-such-frame" @?= Nothing

    ]

renderCases :: [TestTree]
renderCases =
    [ testCase "the dry-run lists the exact plan's full forward projection in order" $
        withAdmittedPlan demoPlan $ \plan ->
            renderChain plan
                @?= unlines
                    [ "1. [host-orchestrator-0] deploy-vm — launch the VM"
                    , "2. [host-orchestrator-0] copy-source — stage source into the VM"
                    , "3. [host-orchestrator-0] build-pb — build the binary in the VM"
                    , "4. [vm-orchestrator-1] context-init — mint the container config"
                    , "5. [vm-orchestrator-1] build-image — build the project image"
                    , "6. [vm-project-container-2] deploy-kind — bring up kind"
                    , "7. [vm-project-container-2] deploy-harbor — install harbor"
                    , "8. [vm-project-container-2] expose-port — expose the NodePort"
                    ]
    , testCase "dry rendering and the public forward projection have identical order" $
        withAdmittedPlan demoPlan $ \plan -> do
            let projected =
                    [ (plannedStepFrameId step, plannedStepLabel step)
                    | step <- toList (forward plan)
                    ]
                rendered = T.lines (T.pack (renderChain plan))
            length rendered @?= length projected
            mapM_
                ( \(line, (frame, label)) -> do
                    assertBool "the rendered row retained its projected frame" (frame `T.isInfixOf` line)
                    assertBool "the rendered row retained its projected label" (label `T.isInfixOf` line)
                )
                (zip rendered projected)
    , testCase "post-handoff hook stays after the container exposes the ingress" $ do
        withAdmittedPlan acceleratorPlan $ \plan -> do
            renderChain plan
                @?= unlines
                    [ "1. [host-orchestrator-0] deploy-vm — launch the VM"
                    , "2. [host-orchestrator-0] copy-source — stage source into the VM"
                    , "3. [host-orchestrator-0] build-pb — build the binary in the VM"
                    , "4. [vm-orchestrator-1] context-init — mint the container config"
                    , "5. [vm-orchestrator-1] build-image — build the project image"
                    , "6. [vm-project-container-2] deploy-kind — bring up kind"
                    , "7. [vm-project-container-2] deploy-harbor — install harbor"
                    , "8. [vm-project-container-2] expose-port — expose the NodePort"
                    , "9. [host-orchestrator-0] post-handoff-start-accelerator-daemon — start the host accelerator daemon"
                    ]
            let hostLabels =
                    [ plannedStepLabel step
                    | step <- toList (forward plan)
                    , plannedStepFrameId step == "host-orchestrator-0"
                    ]
            hostLabels
                @?= [ "launch the VM"
                    , "stage source into the VM"
                    , "build the binary in the VM"
                    , "start the host accelerator daemon"
                    ]
    ]

{- | The public root-Up command is the only honest way for an external caller
to obtain and consume a 'LifecycleEntry'.  These cases observe that fixed
boundary through action callbacks and the durable store; the caller never
receives a plan, authority, journal, or cursor that it could recombine.
-}
admissionCases :: [TestTree]
admissionCases =
    [ testCase "one root LifecycleEntry and one reservation drive the full current frame" $
        withChainStore $ \store project -> do
            observed <- newIORef ([] :: [T.Text])
            let record label =
                    projectStep
                        (fixtureProjectStepId (T.unpack label))
                        ProjectManagedReverse
                        (T.unpack label)
                        executionFrame
                        (\_ -> modifyIORef' observed (++ [label]) >> pure StepChanged)
                post =
                    postHandoffStep
                        "third"
                        "third"
                        executionFrame
                        (\_ -> modifyIORef' observed (++ ["third"]) >> pure StepChanged)
                steps = map record ["first", "second"] ++ [post]
                projectedLabels = ["first", "second", "third"]
            before <- invocationRecordCount store
            before @?= 0
            outcome <- runFrom store project steps
            observedLabels <- readIORef observed
            case outcome of
                Left failure ->
                    assertFailure ("the current-frame CLI failed: " ++ failure ++ "; observed callbacks: " ++ show observedLabels)
                Right () -> pure ()
            outcome @?= Right ()
            observedLabels @?= projectedLabels
            after <- invocationRecordCount store
            after @?= 1
    , testCase "a completed root entry is not reconstructed or rerun" $
        withChainStore $ \store project -> do
            effects <- newIORef (0 :: Int)
            let steps = [countingStep "complete-once" effects StepChanged]
                run = runFrom store project steps
            run >>= (@?= Right ())
            readIORef effects >>= (@?= 1)
            completedKeys <- protectedKeyImage store
            completedInvocations <- invocationRecordCount store
            completedInvocations @?= 1
            run >>= (@?= Right ())
            readIORef effects >>= (@?= 1)
            protectedKeyImage store >>= (@?= completedKeys)
            invocationRecordCount store >>= (@?= completedInvocations)
    , testCase "a consumed Execute reservation refuses replay without rerunning its callback" $
        withChainStore $ \store project -> do
            effects <- newIORef (0 :: Int)
            let steps =
                    [ countingStep
                        "consume-once"
                        effects
                        (StepConflict "healthy" "foreign" "repair the fixture")
                    ]
                run = runFrom store project steps
            first <- run
            assertLeft "the first non-success must fail the public command" first
            readIORef effects >>= (@?= 1)
            consumedKeys <- protectedKeyImage store
            consumedInvocations <- invocationRecordCount store
            consumedInvocations @?= 1
            second <- run
            assertLeft "a consumed reservation must refuse replay" second
            readIORef effects >>= (@?= 1)
            protectedKeyImage store >>= (@?= consumedKeys)
            invocationRecordCount store >>= (@?= consumedInvocations)
    , testCase "the package-private Entry fixes root refinement, authorization, and interpretation" $ do
        entrySource <- lifecycleEntrySource
        commandFacade <- commandSource
        let normalizedEntry = T.unwords (T.words entrySource)
            normalizedFacade = T.unwords (T.words commandFacade)
            requiredEntry =
                [ "withValidatedRootLifecycleContext lifecycleContext"
                , "settled <- settleRootedPlanCatalog store catalog"
                , "authorizeRootProject rootAuthority verb verified bound binding lease plan journal executeCursor lifecycleContext project"
                , "withBoundProjectDestroyLifecycleEntry finalized rootAuthority verified bound binding lease plan lifecycleContext project use ="
                , "let reauthorize = ProjectAuthority.authorizeRootProject rootAuthority ProjectDestroy verified bound binding lease plan journal teardownCursor lifecycleContext project reserved <- reauthorize"
                , "use ( RootUpLifecycleEntry rootAuthority verb plan lifecycleContext journal executeCursor authority catalog )"
                , "runRootProjectUpLifecycleEntry cfg self scope loadSigningKey loadActivationSigningKey runFailedLocal entry@(RootUpLifecycleEntry rootAuthority verb plan lifecycleContext journal cursor authority catalog)"
                , "case [(digest, service, effects) | (frame, digest, service, effects) <- admittedActivationPlacements, frame == manifestFrame manifest] of"
                , "activationPlacementsFor plan"
                , "withRootedPlanCatalogEntriesKernel catalog (\\childPlan _ _ _ _ _ _ _ _ _ _ -> activationPlacementsFor childPlan)"
                , "withChartWorkloadResource admittedPlan (plannedStepOperationKey planned)"
                , "(activationFrame, planDigest, role, filter (not . Text.isPrefixOf \"deployment:\") effects)"
                , "(launchChild activationSigningKey link)"
                , "replaceStepRuntimeActivationSigningService activationRuntime"
                , "signed <- signActivation signingKey manifest"
                , "withTeardownLifecycleCursor cursor"
                ]
            requiredFacade =
                [ "module HostBootstrap.Command ( coreCommands, coreCommandNames, allReconcilers, LifecycleEntry, lifecycleEntryFrameName, )"
                , "runExactProjectUp cfg self handoffScope loadSigningKey runFailedLocal exactSpec rootAuthority lease verified bound binding plan lifecycleContext project = withRootProjectUpLifecycleEntry"
                , "withRootProjectUpLifecycleEntry exactSpec rootAuthority Authority.ProjectUp verified bound binding lease plan lifecycleContext project (runRootProjectUpLifecycleEntry cfg self handoffScope loadSigningKey loadActivationSigningKey runFailedLocal)"
                , "runExactHarnessDestroyProjection cfg profile self handoffScope store exactSpec rootAuthority lease verified bound binding plan root ctx lifecycleContext project = do"
                , "withBoundProjectDestroyLifecycleEntry exactSpec rootAuthority verified bound binding lease plan lifecycleContext project ( \\entry current -> runRootProjectReverseLifecycleEntry"
                ]
        mapM_
            (\fragment -> assertBool ("missing fixed Entry route: " ++ T.unpack fragment) (T.isInfixOf fragment normalizedEntry))
            requiredEntry
        mapM_
            (\fragment -> assertBool ("missing opaque Command facade route: " ++ T.unpack fragment) (T.isInfixOf fragment normalizedFacade))
            requiredFacade
        assertBool
            "the public Command facade must not invoke raw Chain"
            (not ("runChainFromFrame" `T.isInfixOf` commandFacade))
    ]

{- | A step no longer receives a bare 'HostConfig'; it receives the descriptor
the plan minted for its own node (§ U). These cases drive the real interpreter
over a one-frame plan and read back exactly what each action was handed, so the
contract is observed rather than asserted about.
-}
descriptorCases :: [TestTree]
descriptorCases =
    [ testCase "each action is handed its own operation key and frame" $ do
        (_, observed) <- runInnermost descriptorSteps
        map (\(key, frame, _, _) -> (key, frame)) observed
            @?= [ ("core:deploy-kind", "host-orchestrator-0")
                , ("project:deploy-harbor", "host-orchestrator-0")
                , ("core:expose-port", "host-orchestrator-0")
                ]
    , testCase "every action sees the one digest of the plan being interpreted" $ do
        (planDigest, observed) <- runInnermost descriptorSteps
        [digest | (_, _, digest, _) <- observed] @?= replicate 3 planDigest
        -- and it is a real derived digest, not an empty placeholder
        T.null planDigest @?= False
    , testCase "the descriptor's edge set is the step's exact ordered plan prefix" $ do
        (_, observed) <- runInnermost descriptorSteps
        [dependencies | (_, _, _, dependencies) <- observed]
            @?= [ []
                , ["core:deploy-kind"]
                , ["core:deploy-kind", "project:deploy-harbor"]
                ]
    , testCase "different graphs at the same root and configuration have different digests" $
        withSystemTempDirectory "hostbootstrap-chain-digests" $ \directory -> do
            let root = directory </> "root"
            one <- runFreshInnermostAtRoot root descriptorSteps
            other <- runFreshInnermostAtRoot root otherDescriptorSteps
            assertMatchingDescriptorInputs one other
            assertDescriptorCallbacks ["core:deploy-kind", "project:deploy-harbor", "core:expose-port"] one
            assertDescriptorCallbacks ["core:deploy-kind"] other
            [dependencies | (_, _, _, dependencies) <- descriptorRunObserved other] @?= [[]]
            (descriptorRunPlanDigest one == descriptorRunPlanDigest other) @?= False
    , testCase "equal graphs at the same root and configuration retain equal digests" $
        withSystemTempDirectory "hostbootstrap-chain-digests" $ \directory -> do
            let root = directory </> "root"
            one <- runFreshInnermostAtRoot root descriptorSteps
            other <- runFreshInnermostAtRoot root descriptorSteps
            assertMatchingDescriptorInputs one other
            let expected = ["core:deploy-kind", "project:deploy-harbor", "core:expose-port"]
            assertDescriptorCallbacks expected one
            assertDescriptorCallbacks expected other
            descriptorRunPlanDigest other @?= descriptorRunPlanDigest one
    ]

{- | The interpreter turns each node's observation into that node's own outcome
(§ W). A node that did not reach its target state stops the chain and is named
with the kind of outcome it was, so a conflict, an unsupported backend, and a
refusal are told apart rather than reduced to one failure.
-}
observationCases :: [TestTree]
observationCases =
    [ testCase "a node that reached its target state lets the chain continue" $ do
        ran <- newIORef (0 :: Int)
        outcome <- runInnermostWith [countingStep "first" ran StepUnchanged, countingStep "second" ran StepChanged]
        outcome @?= Right ()
        readIORef ran >>= (@?= 2)
    , testCase "each non-success observation stops before the later node" $ do
        let expectRow marker observation = do
                ran <- newIORef (0 :: Int)
                outcome <- runInnermostWith [countingStep "deploy-kind-probe" ran observation, countingStep "later" ran StepChanged]
                assertFailureContains marker outcome
                readIORef ran >>= (@?= 1)
        expectRow "conflict:" (StepConflict "the run's cluster" "a foreign cluster" "delete it")
        expectRow "unsupported:" (StepUnsupported "no kube toolchain in this frame")
        expectRow "refused:" (StepRefused "the cluster holds state this run does not own")
    ]

{- | The durable half of the interpreter's transaction (§ EE).

These are the properties the unit-level prepare tests cannot show, because they
are about *when* the record is written relative to the effect and *whether* the
store is locked while the effect runs.
-}
entryPolicyCases :: [TestTree]
entryPolicyCases =
    [ testCase "a two-frame descent runs between pre and post handoff nodes" $ do
        observed <- newIORef ([] :: [T.Text])
        let record :: T.Text -> StepAction
            record label _ = modifyIORef' observed (++ [label]) >> pure StepChanged
            graph _ frame = expectPlan
                [ deployVMStep "launch" frame noop
                , copySourceStep "copy" frame noop
                , descendsVia (vmContext (inVM vm emptyVMStack)) (buildPbStep "pre" frame (record "pre"))
                , contextInitStep "child" vmFrame noop
                , postHandoffStep "post" "post" frame (record "post")
                ]
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            outcome <- runChainFromFrameWithDescentFailure host exactSelf store plan authority cursor $ \_ parent child descent -> do
                parent @?= "host-orchestrator-0"
                child @?= "vm-orchestrator-1"
                descent @?= vmContext (inVM vm emptyVMStack)
                modifyIORef' observed (++ ["child"])
                pure (Right ())
            outcome @?= Right ()
            readIORef observed >>= (@?= ["pre", "child", "post"])
    , testCase "a foreign supplied store refuses before opening the chain journal" $ do
        callbacks <- newIORef (0 :: Int)
        let graph = entryPolicyGraph callbacks
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor ->
            Fixture.withFixtureRootChainEvidence graph $ \foreignStore _foreignPlan _foreignAuthority _foreignCursor -> do
                assertBool "the supplied store actually differs" (protectedStoreIdentity store /= protectedStoreIdentity foreignStore)
                lifecycleCursorMatchesCommandAuthority authority cursor @?= True
                host <- directChainHostConfig
                exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
                assertEntryRefusal [store, foreignStore] callbacks
                    "project up: command authority does not belong to the supplied protected store"
                    (fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf foreignStore plan authority cursor (\_ _ _ _ -> pure (Right ()))))
    , testCase "a foreign cursor origin refuses before opening the chain journal" $ do
        callbacks <- newIORef (0 :: Int)
        let graph = entryPolicyGraph callbacks
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority _cursor ->
            Fixture.withFixtureRootChainEvidence graph $ \foreignStore _foreignPlan _foreignAuthority foreignCursor -> do
                assertBool "the cursor's store actually differs" (protectedStoreIdentity store /= protectedStoreIdentity foreignStore)
                -- Substitute only the indices of an actually admitted foreign
                -- cursor. Its retained store, acquisition and broker remain B's.
                let substituted = alignForeignEntryCursor foreignCursor
                lifecycleCursorMatchesCommandAuthority authority substituted @?= False
                host <- directChainHostConfig
                exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
                assertEntryRefusal [store, foreignStore] callbacks
                    "project up: command authority and lifecycle cursor origins do not match"
                    (fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store plan authority substituted (\_ _ _ _ -> pure (Right ()))))
    , testCase "a second frame in the same acquisition refuses before opening the chain journal" $ do
        callbacks <- newIORef (0 :: Int)
        Fixture.withFixtureRootChainEvidenceVariants (entryPolicyGraph callbacks) $ \store plan authority cursor childCursor _alternatePlan -> do
            lifecycleCursorFrame cursor @?= "host-orchestrator-0"
            lifecycleCursorFrame childCursor @?= "test-harness-1"
            -- The genuine child cursor already shares A's plan and broker.
            -- Only its fresh frame index is aligned for this negative control.
            let substituted = alignEntryCursorFrame childCursor
            lifecycleCursorMatchesCommandAuthority authority substituted @?= True
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            assertEntryRefusal [store] callbacks
                "project up: command authority frame host-orchestrator-0 does not match lifecycle cursor frame test-harness-1"
                (fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store plan authority substituted (\_ _ _ _ -> pure (Right ()))))
    , testCase "an admitted alternative topology refuses before opening the chain journal" $ do
        callbacks <- newIORef (0 :: Int)
        Fixture.withFixtureRootChainEvidenceVariants (entryPolicyGraph callbacks) $ \store _plan authority cursor _childCursor alternatePlan -> do
            lifecycleCursorFrame cursor @?= "host-orchestrator-0"
            map fst (NonEmpty.toList (topologyFrameOrder (topology alternatePlan))) @?= ["host-orchestrator-0-alternate"]
            lifecycleCursorMatchesCommandAuthority authority cursor @?= True
            -- This is the genuinely admitted alternative plan. Only planId
            -- changes; its actual configuration and topology remain intact.
            let substituted = alignEntryPlanId alternatePlan
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            assertEntryRefusal [store] callbacks
                "project up: current frame host-orchestrator-0 is not a frame of the admitted plan (frames: host-orchestrator-0-alternate)"
                (fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store substituted authority cursor (\_ _ _ _ -> pure (Right ()))))
    , testCase "matching evidence shares the private policy and completes the actual chain" $ do
        callbacks <- newIORef (0 :: Int)
        Fixture.withFixtureRootChainEvidence (entryPolicyGraph callbacks) $ \store plan authority cursor -> do
            validateCurrentFrameEntry authority store
                (lifecycleCursorMatchesCommandAuthority authority cursor)
                (lifecycleCursorFrame cursor)
                (fmap fst (topologyFrameOrder (topology plan))) @?= Right ()
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            outcome <- fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store plan authority cursor (\_ _ _ _ -> pure (Right ())))
            outcome @?= Right ()
            readIORef callbacks >>= (@?= 1)
            phases <- expectSuccess =<< withProtectedEntry store readOperationPhases
            phases @?= ["Committed"]
            assertExactlyOneClosedSession store (stablePlanSnapshotDigest (renderSnapshot plan))
    ]

entryPolicyGraph :: IORef Int -> ProtectedStore -> StepFrame -> StepPlan
entryPolicyGraph callbacks _store frame =
    expectPlan
        [ projectStep (fixtureProjectStepId "entry-policy") PreserveOnReverse "entry policy probe" frame
            (\_ -> modifyIORef' callbacks (+ 1) >> pure StepChanged)
        ]

assertEntryRefusal :: [ProtectedStore] -> IORef Int -> String -> IO (Either String ()) -> IO ()
assertEntryRefusal stores callbacks expected attempt = do
    before <- traverse protectedRecordImage stores
    outcome <- attempt
    outcome @?= Left expected
    readIORef callbacks >>= (@?= 0)
    traverse protectedRecordImage stores >>= (@?= before)

-- Defensive substitutions retain real admitted terms and fixed up/execute
-- indices. No authority, acquisition journal or cursor is manufactured here.
alignForeignEntryCursor ::
    LifecycleCursor foreignScope foreignPlan foreignFrame foreignBroker VerbUp ExecutePhase ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase
alignForeignEntryCursor = unsafeCoerce

alignEntryCursorFrame ::
    LifecycleCursor scope planId sourceFrame brokerGeneration verb phase ->
    LifecycleCursor scope planId targetFrame brokerGeneration verb phase
alignEntryCursorFrame = unsafeCoerce

alignEntryPlanId ::
    ProjectPlan scope specDigest sourcePlanId configId cfg ->
    ProjectPlan scope specDigest targetPlanId configId cfg
alignEntryPlanId = unsafeCoerce

transactionCases :: [TestTree]
transactionCases =
    [ testCase "the interpreter rethrows the original safety refusal after terminal settlement and session close" $ do
        callbacks <- newIORef (0 :: Int)
        later <- newIORef (0 :: Int)
        let original = Harness.SafetyRefusal "x"
            graph _store frame = expectPlan
                [ projectsOperation "project:typed-refusal/relation" $
                    projectStep (fixtureProjectStepId "typed-refusal") PreserveOnReverse "typed refusal" frame
                        (\_ -> modifyIORef' callbacks (+ 1) >> throwIO original)
                , projectStep (fixtureProjectStepId "later") PreserveOnReverse "later" frame
                    (\_ -> modifyIORef' later (+ 1) >> pure StepChanged)
                ]
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            attempted <- Exception.try @Exception.SomeException (fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store plan authority cursor (\_ _ _ _ -> pure (Right ()))))
            case attempted of
                Left failure -> Exception.fromException @Harness.SafetyRefusal failure @?= Just original
                Right outcome -> assertFailure ("the original callback exception did not escape: " ++ show outcome)
            readIORef callbacks >>= (@?= 1)
            readIORef later >>= (@?= 0)
            phases <- expectSuccess =<< withProtectedEntry store readOperationPhases
            phases @?= replicate 2 "StepObservedTerminal"
            assertExactlyOneClosedSession store (stablePlanSnapshotDigest (renderSnapshot plan))
    , testCase "a returned refusal terminalizes its untaken projection before session close" $ do
        callbacks <- newIORef (0 :: Int)
        later <- newIORef (0 :: Int)
        let graph _store frame = expectPlan
                [ projectsOperation "project:returned-projection/relation" $
                    projectStep (fixtureProjectStepId "returned-projection") PreserveOnReverse "returned refusal" frame
                        (\_ -> modifyIORef' callbacks (+ 1) >> pure (StepRefused "operator-owned state"))
                , projectStep (fixtureProjectStepId "later") PreserveOnReverse "later" frame
                    (\_ -> modifyIORef' later (+ 1) >> pure StepChanged)
                ]
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            outcome <- fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store plan authority cursor (\_ _ _ _ -> pure (Right ())))
            assertFailureContains "refused: operator-owned state" outcome
            readIORef callbacks >>= (@?= 1)
            readIORef later >>= (@?= 0)
            phases <- expectSuccess =<< withProtectedEntry store readOperationPhases
            phases @?= replicate 2 "StepObservedTerminal"
            assertExactlyOneClosedSession store (stablePlanSnapshotDigest (renderSnapshot plan))
    , testCase "a terminal settlement obstruction retains the original refusal and its secondary failure" $ do
        callbacks <- newIORef (0 :: Int)
        later <- newIORef (0 :: Int)
        blocked <- newIORef Nothing
        secondary <- newIORef Nothing
        let original = Harness.SafetyRefusal "secondary original"
            obstruct :: ProtectedStore -> StepAction
            obstruct store _execution = do
                modifyIORef' callbacks (+ 1)
                keys <- expectSuccess =<< withProtectedEntry store listProtectedRecords
                key <- case filter (T.isPrefixOf "op." . recordKeyText) keys of
                    [one] -> pure one
                    other -> assertFailure ("expected one prepared operation before the effect, got " ++ show other)
                observed <- expectSuccess =<< withProtectedEntry store (\session -> readProtectedRecord session key)
                retained <- maybe (assertFailure "the prepared operation disappeared before obstruction") pure observed
                recordedPhase (protectedRecordBytes retained) @?= "EffectOutcomeUnknown"
                let path = protectedStoreRoot store </> "records" </> T.unpack (recordKeyText key) ++ ".rec"
                    saved = protectedStoreRoot store </> "terminal-settlement-original"
                Exception.mask_ $ do
                    renameFile path saved
                    writeIORef blocked (Just (key, retained, path, saved))
                    createDirectory path
                failedRead <- withProtectedEntry store (\session -> readProtectedRecord session key)
                case failedRead of
                    Left failure@(ProtectedIOFailure "read a protected record" diagnostic) -> do
                        assertBool "the kernel failure does not name the obstructed operation" (recordKeyText key `T.isInfixOf` diagnostic)
                        writeIORef secondary (Just (sessionErrorMessage (SessionStoreFailure failure)))
                    other -> assertFailure ("expected the actual operation read to fail, got " ++ show other)
                throwIO original
            restore = do
                obstruction <- readIORef blocked
                case obstruction of
                    Nothing -> pure ()
                    Just (_, _, path, saved) -> do
                        directory <- doesDirectoryExist path
                        if directory then removeDirectory path else pure ()
                        renameFile saved path
            graph store frame = expectPlan
                [ projectStep (fixtureProjectStepId "secondary-failure") PreserveOnReverse "secondary failure" frame (obstruct store)
                , projectStep (fixtureProjectStepId "later") PreserveOnReverse "later" frame
                    (\_ -> modifyIORef' later (+ 1) >> pure StepChanged)
                ]
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
            host <- directChainHostConfig
            exactSelf <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            outcome <- fmap (either (\(reason, _, _) -> Left reason) Right) (runChainFromFrameWithDescentFailure host exactSelf store plan authority cursor (\_ _ _ _ -> pure (Right ()))) `Exception.finally` restore
            expected <- readIORef secondary >>= maybe (assertFailure "the callback never observed the kernel read failure") pure
            outcome @?= Left
                ( "prepared project step callback for project:secondary-failure raised an exception: "
                    ++ Exception.displayException original
                    ++ "; terminal settlement failed: "
                    ++ expected
                )
            readIORef callbacks >>= (@?= 1)
            readIORef later >>= (@?= 0)
            obstruction <- readIORef blocked
            case obstruction of
                Nothing -> assertFailure "the real operation was never obstructed"
                Just (key, retained, _, _) -> do
                    restored <- expectSuccess =<< withProtectedEntry store (\session -> readProtectedRecord session key)
                    restored @?= Just retained
            phases <- expectSuccess =<< withProtectedEntry store readOperationPhases
            phases @?= ["EffectOutcomeUnknown"]
    , testCase "the unknown phase is durable before the effect, and the entry is free while it runs" $
        withChainStore $ \store project -> do
            observed <- newIORef ([] :: [T.Text])
            let probe :: forall scope planId. StepExecution scope planId -> IO StepObservation
                probe _ = do
                    -- Trying the exclusive entry here is itself the assertion
                    -- that the interpreter is not holding it: a provider call
                    -- or a cluster bring-up can take minutes, and the store
                    -- must stay available to a peer for that whole time.
                    phases <- tryProtectedEntry store readOperationPhases
                    case phases of
                        Left failure -> assertFailure (show failure)
                        Right Nothing -> assertFailure "the interpreter held the protected entry during the effect"
                        Right (Just recorded) -> writeIORef observed recorded
                    pure StepChanged
            outcome <-
                runFrom store project [countingProbe "probe-node" probe]
            outcome @?= Right ()
            -- While the effect ran, its own record already said an attempt may
            -- have happened.
            readIORef observed >>= (@?= ["EffectOutcomeUnknown"])
    , testCase "a node that reached its target state settles at Committed" $
        withChainStore $ \store project -> do
            outcome <- runFrom store project [countingProbe "probe-node" (const (pure StepChanged))]
            outcome @?= Right ()
            settled <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["Committed"]) settled
    , testCase "owned settlement is durable before its matching commit" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "settle cluster"
                        executionFrame
                        (\execution -> carryClusterHandle execution >> pure StepChanged)
                    ]
            outcome @?= Right ()
            keys <- protectedKeyImage store
            length (filter ("resource." `T.isPrefixOf`) keys) @?= 1
    , testCase "retry after a persisted member converges before journal commit" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "resume cluster settlement"
                        executionFrame
                        ( \execution -> do
                            carryClusterHandle execution
                            prewriteCarriedSettlement store execution
                            pure StepChanged
                        )
                    ]
            outcome @?= Right ()
            settled <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["Committed"]) settled
    , testCase "a conflicting stable member refuses the journal commit" $
        withChainStore $ \store project -> do
            retained <- newIORef Nothing
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "conflicting cluster settlement"
                        executionFrame
                        ( \execution -> do
                            carryClusterHandle execution
                            prewriteSettlementBytes store execution "conflicting-member"
                            readOnlyResourceRecord store >>= writeIORef retained . Just
                            pure StepChanged
                        )
                    ]
            assertFailureContains "conflicting resource settlement" outcome
            expected <- readIORef retained >>= maybe (assertFailure "the callback never wrote its conflicting member") pure
            readOnlyResourceRecord store >>= (@?= expected)
            phases <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["EffectOutcomeUnknown"]) phases
    , testCase "a fresh ownership generation replaces the prior released tombstone" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "reacquire released cluster"
                        executionFrame
                        ( \execution -> do
                            carryClusterHandleAt 6 execution
                            prewriteReleasedClusterRecordAt 5 store execution
                            pure StepChanged
                        )
                    ]
            outcome @?= Right ()
            fields <- readOnlyResourceFields store
            fields !! 5 @?= "6"
            fields !! 10 @?= "owned"
    , testCase "a released tombstone refuses a non-advancing ownership generation" $
        withChainStore $ \store project -> do
            retained <- newIORef Nothing
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "refuse stale cluster reacquisition"
                        executionFrame
                        ( \execution -> do
                            carryClusterHandleAt 5 execution
                            prewriteReleasedClusterRecordAt 5 store execution
                            readOnlyResourceRecord store >>= writeIORef retained . Just
                            pure StepChanged
                        )
                    ]
            assertFailureContains "conflicting resource settlement" outcome
            expected <- readIORef retained >>= maybe (assertFailure "the callback never wrote its released tombstone") pure
            readOnlyResourceRecord store >>= (@?= expected)
            phases <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["EffectOutcomeUnknown"]) phases
    , testCase "release keeps the stable member and advances it to a tombstone" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "release cluster"
                        executionFrame
                        ( \execution -> do
                            carryReleasedClusterHandle execution
                            prewriteOwnedClusterRecord store execution
                            pure StepChanged
                        )
                    ]
            outcome @?= Right ()
            fields <- readOnlyResourceFields store
            fields !! 7 @?= "8"
            fields !! 8 @?= "released"
            fields !! 10 @?= "released"
    , testCase "phase settlement retains receipt identity and advances version" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "ready cluster"
                        executionFrame
                        ( \execution -> do
                            carryReadyClusterHandle execution
                            prewriteOwnedClusterRecord store execution
                            pure StepChanged
                        )
                    ]
            outcome @?= Right ()
            fields <- readOnlyResourceFields store
            fields !! 6 @?= "core:deploy-kind:cluster:create"
            fields !! 7 @?= "8"
            fields !! 8 @?= "ready"
            fields !! 10 @?= "owned"
    , testCase "a phase settlement with no durable predecessor refuses the journal commit" $
        withChainStore $ \store project -> do
            callbacks <- newIORef (0 :: Int)
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep
                        "missing cluster predecessor"
                        executionFrame
                        ( \execution -> do
                            modifyIORef' callbacks (+ 1)
                            carryReadyClusterHandle execution
                            pure StepChanged
                        )
                    ]
            assertFailureContains "missing resource settlement predecessor" outcome
            readIORef callbacks >>= (@?= 1)
            phases <- expectSuccess =<< withProtectedEntry store readOperationPhases
            phases @?= ["EffectOutcomeUnknown"]
            invocationRecordCount store >>= (@?= 1)
            keys <- protectedKeyImage store
            filter ("resource." `T.isPrefixOf`) keys @?= []
    , testCase "a node that did not reach it settles terminally, not as unknown" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [countingProbe "probe-node" (const (pure (StepUnsupported "no backend here")))]
            assertLeft "expected the public command to stop at the node" outcome
            -- Terminal, not unknown: an operator resolves it, and a successor
            -- refuses to retry it rather than blocking on an unclassifiable
            -- record.
            settled <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["StepObservedTerminal"]) settled
    , testCase "a returned refusal closes its exact session without registering later nodes" $
        withChainStore $ \store project -> do
            ran <- newIORef (0 :: Int)
            digest <- newIORef Nothing
            let returnedRefusal =
                    countingProbe "returned-refusal" $ \execution -> do
                        modifyIORef' ran (+ 1)
                        writeIORef digest (Just (stepExecutionPlanDigest execution))
                        pure (StepRefused "operator-owned state")
                steps =
                    [ returnedRefusal
                    , countingStep "must-not-register" ran StepChanged
                    ]
            outcome <- runFrom store project steps
            assertLeft "the returned refusal unexpectedly succeeded" outcome
            readIORef ran >>= (@?= 1)
            phases <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["StepObservedTerminal"]) phases
            readRequiredPlanDigest digest >>= assertExactlyOneClosedSession store
    , testCase "a thrown safety refusal closes its exact session before the public command reports failure" $
        withChainStore $ \store project -> do
            ran <- newIORef (0 :: Int)
            digest <- newIORef Nothing
            let reason = "definite provider refusal"
                refusingStep =
                    countingProbe "thrown-refusal" $ \execution -> do
                        modifyIORef' ran (+ 1)
                        writeIORef digest (Just (stepExecutionPlanDigest execution))
                        throwIO (Harness.SafetyRefusal reason)
                steps =
                    [ refusingStep
                    , countingStep "must-not-register" ran StepChanged
                    ]
            attempted <- runFrom store project steps
            assertLeft "the safety refusal unexpectedly succeeded" attempted
            readIORef ran >>= (@?= 1)
            phases <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["StepObservedTerminal"]) phases
            readRequiredPlanDigest digest >>= assertExactlyOneClosedSession store
    , testCase "a synchronous action failure settles terminally before the public command reports it" $
        withChainStore $ \store project -> do
            ran <- newIORef (0 :: Int)
            digest <- newIORef Nothing
            let failingStep =
                    countingProbe "failed-action" $ \execution -> do
                        modifyIORef' ran (+ 1)
                        writeIORef digest (Just (stepExecutionPlanDigest execution))
                        ioError (userError "controlled action failure")
                steps =
                    [ failingStep
                    , countingStep "must-not-register" ran StepChanged
                    ]
            attempted <- runFrom store project steps
            assertLeft "the synchronous action failure unexpectedly succeeded" attempted
            readIORef ran >>= (@?= 1)
            phases <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["StepObservedTerminal"]) phases
            readRequiredPlanDigest digest >>= assertExactlyOneClosedSession store
    , testCase "a synchronous action failure terminalizes an untaken projected gate" $
        withChainStore $ \store project -> do
            digest <- newIORef Nothing
            let failingStep =
                    projectsOperation "project:failed-action/relation" $
                        countingProbe "failed-action" $ \execution -> do
                            writeIORef digest (Just (stepExecutionPlanDigest execution))
                            ioError (userError "failure before projected effect")
            attempted <- runFrom store project [failingStep]
            assertLeft "the synchronous projected action failure unexpectedly succeeded" attempted
            phases <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= replicate 2 "StepObservedTerminal") phases
            readRequiredPlanDigest digest >>= assertExactlyOneClosedSession store
    ]

{- | A node's projected operations (§ CC).

A relating resource's key is not any node's own, so before this no node could
prepare one. The plan is where a node claims the relation, and the interpreter is
what turns that claim into a registered operation, an open gate the node's action
can take, and a settlement that happens with the node.
-}
projectionCases :: [TestTree]
projectionCases =
    [ testCase "an action takes the gate for an operation its node projects" $ do
        seen <- newIORef ([] :: [(T.Text, Bool)])
        outcome <-
            runInnermostWith
                [ deployKindStep "the resource this one relates to" executionFrame (const (pure StepChanged))
                , projectsOperation aliasProjection $
                    projectStep
                        (fixtureProjectStepId "relating-node")
                        ProjectManagedReverse
                        "relate them"
                        executionFrame
                        ( \execution -> do
                            let record key = do
                                    gate <- stepExecutionTakeProjectedGate execution key
                                    modifyIORef' seen (++ [(key, gateNames key gate)])
                            -- its own projection, twice: a prepared gate
                            -- authorises exactly one effect
                            record aliasProjectionKey
                            record aliasProjectionKey
                            -- an operation the plan placed under another node
                            record "core:deploy-kind/something"
                            -- and its own operation key is not a projection
                            record "project:relating-node"
                            pure StepChanged
                        )
                ]
        outcome @?= Right ()
        observed <- readIORef seen
        observed
            @?= [ (aliasProjectionKey, True)
                , (aliasProjectionKey, False)
                , ("core:deploy-kind/something", False)
                , ("project:relating-node", False)
                ]
    , testCase "the descriptor names exactly the projections the plan validated" $ do
        seen <- newIORef ([] :: [[T.Text]])
        outcome <-
            runInnermostWith
                [ deployKindStep "related" executionFrame (const (pure StepChanged))
                , projectsOperation aliasProjection $
                    projectStep
                        (fixtureProjectStepId "relating-node")
                        ProjectManagedReverse
                        "relate them"
                        executionFrame
                        ( \execution -> do
                            modifyIORef' seen (++ [stepExecutionProjectedOperations execution])
                            _ <- stepExecutionTakeProjectedGate execution aliasProjectionKey
                            pure StepChanged
                        )
                , exposePortStep
                    "an unrelated later node"
                    executionFrame
                    ( \execution -> do
                        modifyIORef' seen (++ [stepExecutionProjectedOperations execution])
                        pure StepChanged
                    )
                ]
        outcome @?= Right ()
        readIORef seen >>= (@?= [[aliasProjectionKey], []])
    , testCase "a node's own gate is reachable from its action" $ do
        seen <- newIORef ([] :: [(T.Text, T.Text)])
        outcome <-
            runInnermostWith
                [ projectStep
                    (fixtureProjectStepId "own-gate")
                    ProjectManagedReverse
                    "prepare itself"
                    executionFrame
                    ( \execution -> do
                        gate <- stepExecutionPreparedGate execution
                        case gate of
                            Nothing -> pure (StepUnsupported "no gate was opened for this node")
                            Just opened -> do
                                modifyIORef'
                                    seen
                                    ( ++
                                        [
                                            ( preparedGateOperation opened
                                            , stepExecutionPlanDigest execution
                                            )
                                        ]
                                    )
                                pure StepChanged
                    )
                ]
        outcome @?= Right ()
        observed <- readIORef seen
        map fst observed @?= ["project:own-gate"]
        -- the gate belongs to the same interpretation the descriptor names
        case observed of
            [(_, digest)] -> assertBool "the plan digest is real" (not (T.null digest))
            _ -> assertFailure "expected exactly one observation"
    , testCase "a projection registers and settles with its node" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ deployKindStep "related" executionFrame (const (pure StepChanged))
                    , projectsOperation aliasProjection $
                        projectStep
                            (fixtureProjectStepId "relating-node")
                            ProjectManagedReverse
                            "relate them"
                            executionFrame
                            ( \execution -> do
                                _ <- stepExecutionTakeProjectedGate execution aliasProjectionKey
                                pure StepChanged
                            )
                    ]
            outcome @?= Right ()
            settled <- withProtectedEntry store readOperationPhases
            -- three records: two nodes plus the relation one of them projects
            either (assertFailure . show) (@?= replicate 3 "Committed") settled
    , testCase "a projection settles terminally when its node does" $
        withChainStore $ \store project -> do
            outcome <-
                runFrom
                    store
                    project
                    [ projectsOperation "project:relating-node/relation" $
                        projectStep
                            (fixtureProjectStepId "relating-node")
                            ProjectManagedReverse
                            "relate them"
                            executionFrame
                            ( \execution -> do
                                _ <- stepExecutionTakeProjectedGate execution "project:relating-node/relation"
                                pure (StepUnsupported "the backend cannot hold the relation")
                            )
                    ]
            assertLeft "expected the chain to stop at the node" outcome
            settled <- withProtectedEntry store readOperationPhases
            either
                (assertFailure . show)
                (@?= replicate 2 "StepObservedTerminal")
                settled
    , testCase "a declared projection the node never takes leaves the session unable to close" $ do
        projected <- newIORef ([] :: [[T.Text]])
        outcome <-
            runInnermostWith
                [ projectsOperation "project:relating-node/relation" $
                    projectStep
                        (fixtureProjectStepId "relating-node")
                        ProjectManagedReverse
                        "declare but never perform"
                        executionFrame
                        ( \execution -> do
                            modifyIORef' projected (++ [stepExecutionProjectedOperations execution])
                            pure StepChanged
                        )
                ]
        assertLeft "a session with an unsettled projection was closed" outcome
        readIORef projected >>= (@?= [["project:relating-node/relation"]])
    ]

{- | Managed handles crossing between nodes in process (§ EE).

A generative handle is never serialised, so the node that acquires a resource
hands it to the node that depends on it through the interpretation's own carrier.
-}
carrierCases :: [TestTree]
carrierCases =
    [ testCase "a handle one node acquires is adopted by the node that depends on it" $ do
        adopted <- newIORef ([] :: [Either T.Text (T.Text, Word64, Word64)])
        outcome <-
            runInnermostWith
                [ deployKindStep
                    "acquire the cluster"
                    executionFrame
                    (\execution -> carryClusterHandle execution >> pure StepChanged)
                , projectStep
                    (fixtureProjectStepId "dependent-node")
                    ProjectManagedReverse
                    "adopt the dependency"
                    executionFrame
                    ( \execution -> do
                        result <-
                            withCarriedManagedResource execution "core:deploy-kind" $ \handle ->
                                ( resourceHandleKey handle
                                , resourceHandleGeneration handle
                                , resourceHandleObservationVersion handle
                                )
                        modifyIORef' adopted (++ [either (Left . summarizeError) Right result])
                        pure StepChanged
                    )
                ]
        outcome @?= Right ()
        readIORef adopted >>= (@?= [Right ("core:deploy-kind", 5, 7)])
    , testCase "descriptor, prepared gate, and carried resource stay in one plan interpretation" $ do
        acquired <- newIORef Nothing
        adopted <- newIORef Nothing
        outcome <-
            runInnermostWith
                [ deployKindStep
                    "acquire the exact cluster"
                    executionFrame
                    ( \execution -> do
                        gate <- stepExecutionPreparedGate execution
                        case gate of
                            Nothing -> assertFailure "the exact descriptor had no prepared gate"
                            Just prepared ->
                                writeIORef
                                    acquired
                                    ( Just
                                        ( stepExecutionPlanDigest execution
                                        , preparedGatePlan prepared
                                        )
                                    )
                        carryClusterHandle execution
                        pure StepChanged
                    )
                , projectStep
                    (fixtureProjectStepId "adopt-exact-cluster")
                    ProjectManagedReverse
                    "adopt the exact dependency"
                    executionFrame
                    ( \execution -> do
                        result <-
                            withCarriedManagedResource execution "core:deploy-kind" $ \handle ->
                                ( stepExecutionPlanDigest execution
                                , resourceHandleKey handle
                                , resourceHandleGeneration handle
                                , resourceHandleObservationVersion handle
                                )
                        writeIORef adopted (either (const Nothing) Just result)
                        pure StepChanged
                    )
                ]
        outcome @?= Right ()
        source <- readIORef acquired
        target <- readIORef adopted
        case (source, target) of
            (Just (descriptorPlan, gatePlan), Just (dependentPlan, key, generation, version)) -> do
                assertBool "the exact plan digest is non-empty" (not (T.null descriptorPlan))
                descriptorPlan @?= gatePlan
                dependentPlan @?= descriptorPlan
                (key, generation, version) @?= ("core:deploy-kind", 5, 7)
            _ -> assertFailure "the exact prepared/resource continuity path did not complete"
    , testCase "a node cannot adopt a handle for an operation it does not depend on" $ do
        adopted <- newIORef ([] :: [Either T.Text (T.Text, Word64, Word64)])
        outcome <-
            runInnermostWith
                [ projectStep
                    (fixtureProjectStepId "independent-node")
                    ProjectManagedReverse
                    "reach past its own prefix"
                    executionFrame
                    ( \execution -> do
                        result <-
                            withCarriedManagedResource execution "core:deploy-kind" $ \handle ->
                                ( resourceHandleKey handle
                                , resourceHandleGeneration handle
                                , resourceHandleObservationVersion handle
                                )
                        modifyIORef' adopted (++ [either (Left . summarizeError) Right result])
                        pure StepChanged
                    )
                , deployKindStep "a later, unrelated acquisition" executionFrame (const (pure StepChanged))
                ]
        outcome @?= Right ()
        readIORef adopted >>= (@?= [Left "conflict"])
    , testCase "a dependency nobody carried is a reprobe failure, not an empty success" $ do
        adopted <- newIORef ([] :: [Either ReconcileError (T.Text, Word64, Word64)])
        outcome <-
            runInnermostWith
                [ deployKindStep "acquire nothing" executionFrame (const (pure StepChanged))
                , projectStep
                    (fixtureProjectStepId "dependent-node")
                    ProjectManagedReverse
                    "adopt the dependency"
                    executionFrame
                    ( \execution -> do
                        result <-
                            withCarriedManagedResource execution "core:deploy-kind" $ \handle ->
                                ( resourceHandleKey handle
                                , resourceHandleGeneration handle
                                , resourceHandleObservationVersion handle
                                )
                        modifyIORef' adopted (++ [result])
                        pure StepChanged
                    )
                ]
        outcome @?= Right ()
        captured <- readIORef adopted
        case captured of
            [Left (Failure (FailureDetail "adopt carried dependency" _ ReprobeBeforeRetry))] -> pure ()
            other -> assertFailure ("expected one missing-dependency reprobe refusal, got " ++ show other)
    ]

{- | Acquire this node's own cluster resource through the real prepared path and
carry it. The gate is the node's own, opened by the interpreter, so this is the
production route rather than a fixture handle.
-}
carryClusterHandle :: StepExecution scope planId -> IO ()
carryClusterHandle = carryClusterHandleAt 5

carryClusterHandleAt :: Word64 -> StepExecution scope planId -> IO ()
carryClusterHandleAt generation execution = do
    gate <- stepExecutionPreparedGate execution
    case gate of
        Nothing -> assertFailure "the interpreter opened no gate for this node"
        Just opened ->
            case acquire opened of
                Left err -> assertFailure ("acquiring the cluster failed: " ++ show err)
                Right carry -> carry
  where
    acquire opened =
        joinReconcile $
            withNodeResourceOfKind execution ClusterResourceKind "core:deploy-kind" $ \planned ->
                joinReconcile $
                    withNodeObservedResource execution planned generation 7 $ \observed -> do
                        descriptor <- plannedNodeOperation execution planned observed "cluster:create"
                        joinReconcile $
                            withPreparedZeroDependencyOperation descriptor opened $
                                \prepared preconditions -> do
                                    reconciled <-
                                        completeReconcile observed prepared preconditions (BackendCreated generation)
                                    withReconcileResult
                                        reconciled
                                        ( \managed receipt _ ->
                                            Right $ do
                                                carried <-
                                                    carryManagedResourceSettlement
                                                        execution
                                                        managed
                                                        receipt
                                                        "provisioned"
                                                        "cluster-adapter-1"
                                                either (assertFailure . show) pure carried
                                        )
                                        (\_ _ -> Left (unexpectedForeign))
    unexpectedForeign =
        Failure (FailureDetail "acquire cluster" "unexpected foreign cluster" DoNotRetry)

carryReleasedClusterHandle :: StepExecution scope planId -> IO ()
carryReleasedClusterHandle execution = do
    gate <- stepExecutionPreparedGate execution
    case gate of
        Nothing -> assertFailure "the interpreter opened no release fixture gate"
        Just opened -> case acquire opened of
            Left err -> assertFailure ("acquiring the release fixture failed: " ++ show err)
            Right carry -> carry
  where
    acquire opened =
        joinReconcile $
            withNodeResourceOfKind execution ClusterResourceKind "core:deploy-kind" $ \planned ->
                joinReconcile $
                    withNodeObservedResource execution planned 5 7 $ \observed -> do
                        descriptor <- plannedNodeOperation execution planned observed "cluster:create"
                        joinReconcile $
                            withPreparedZeroDependencyOperation descriptor opened $
                                \prepared preconditions -> do
                                    reconciled <-
                                        completeReconcile observed prepared preconditions (BackendCreated 5)
                                    withReconcileResult
                                        reconciled
                                        ( \managed receipt _ ->
                                            Right $ do
                                                carried <-
                                                    carryReleasedResourceSettlement
                                                        execution
                                                        managed
                                                        receipt
                                                        "provisioned"
                                                        "released"
                                                        "cluster-adapter-1"
                                                either (assertFailure . show) pure carried
                                        )
                                        (\_ _ -> Left unexpectedForeign)
    unexpectedForeign =
        Failure (FailureDetail "release cluster" "unexpected foreign cluster" DoNotRetry)

carryReadyClusterHandle :: StepExecution scope planId -> IO ()
carryReadyClusterHandle execution = do
    gate <- stepExecutionPreparedGate execution
    case gate of
        Nothing -> assertFailure "the interpreter opened no phase fixture gate"
        Just opened -> case acquire opened of
            Left err -> assertFailure ("acquiring the phase fixture failed: " ++ show err)
            Right carry -> carry
  where
    acquire opened =
        joinReconcile $
            withNodeResourceOfKind execution ClusterResourceKind "core:deploy-kind" $ \planned ->
                joinReconcile $
                    withNodeObservedResource execution planned 5 7 $ \observed -> do
                        descriptor <- plannedNodeOperation execution planned observed "cluster:create"
                        joinReconcile $
                            withPreparedZeroDependencyOperation descriptor opened $
                                \prepared preconditions -> do
                                    reconciled <-
                                        completeReconcile observed prepared preconditions (BackendCreated 5)
                                    withReconcileResult
                                        reconciled
                                        ( \managed receipt _ -> do
                                            transition <- planMarkReady managed
                                            phaseDescriptor <-
                                                plannedNodePhaseOperation execution planned managed receipt transition "cluster:ready"
                                            pure $ do
                                                preparedPhase <-
                                                    withPreparedPhaseTransition managed receipt transition phaseDescriptor emptyDependencySnapshot opened $ \preparedTransition -> do
                                                        advance <- completePreparedPhaseTransition preparedTransition 5
                                                        pure $
                                                            withPhaseAdvance advance $ \ready readyReceipt _ -> do
                                                                carried <-
                                                                    carryManagedResourcePhaseSettlement
                                                                        execution
                                                                        ready
                                                                        readyReceipt
                                                                        "provisioned"
                                                                        "ready"
                                                                        "cluster-adapter-1"
                                                                either (assertFailure . show) pure carried
                                                case joinReconcile preparedPhase of
                                                    Left err -> assertFailure ("preparing the phase fixture failed: " ++ show err)
                                                    Right carry -> carry
                                        )
                                        (\_ _ -> Left unexpectedForeign)
    unexpectedForeign =
        Failure (FailureDetail "ready cluster" "unexpected foreign cluster" DoNotRetry)

{- | Materialise the carried member as though the process died after the
resource write and before the operation acknowledgement.  Re-entry through
the ordinary Chain path must accept only the identical bytes.
-}
prewriteCarriedSettlement :: ProtectedStore -> StepExecution scope planId -> IO ()
prewriteCarriedSettlement store execution =
    prewriteSettlementBytes store execution $
        resourceBundleBytes
            (stepExecutionPlanDigest execution)
            (stepExecutionFrame execution)
            (stepExecutionOperationKey execution)
            5
            "core:deploy-kind:cluster:create"
            7
            "provisioned"
            "cluster-adapter-1"
            "owned"

prewriteOwnedClusterRecord :: ProtectedStore -> StepExecution scope planId -> IO ()
prewriteOwnedClusterRecord store execution =
    prewriteSettlementBytes store execution $
        resourceBundleBytes
            (stepExecutionPlanDigest execution)
            (stepExecutionFrame execution)
            (stepExecutionOperationKey execution)
            5
            "core:deploy-kind:cluster:create"
            7
            "provisioned"
            "cluster-adapter-1"
            "owned"

prewriteReleasedClusterRecordAt :: Word64 -> ProtectedStore -> StepExecution scope planId -> IO ()
prewriteReleasedClusterRecordAt generation store execution =
    prewriteSettlementBytes store execution $
        resourceBundleBytes
            (stepExecutionPlanDigest execution)
            (stepExecutionFrame execution)
            (stepExecutionOperationKey execution)
            generation
            "core:deploy-kind:cluster:create"
            8
            "released"
            "cluster-adapter-1"
            "released"

prewriteSettlementBytes :: ProtectedStore -> StepExecution scope planId -> ByteString -> IO ()
prewriteSettlementBytes store execution bytes = do
    let raw =
            either (error . show) id $
                resourceRecordKey (stepExecutionPlanDigest execution) (stepExecutionFrame execution) (stepExecutionOperationKey execution)
    key <- either (assertFailure . show) pure (mkRecordKey raw)
    written <- withProtectedEntry store (\session -> compareAndSwapProtectedRecord session key ExpectAbsent bytes)
    either (assertFailure . show) (const (pure ())) written

resourceBundleBytes :: T.Text -> T.Text -> T.Text -> Word64 -> T.Text -> Word64 -> T.Text -> T.Text -> ByteString -> ByteString
resourceBundleBytes plan frame resource generation operation version phase adapter disposition =
    ByteString.concat . map framed $
        [ "hostbootstrap/resource-record-bundle"
        , "1"
        , TextEncoding.encodeUtf8 plan
        , TextEncoding.encodeUtf8 frame
        , TextEncoding.encodeUtf8 resource
        , number generation
        , TextEncoding.encodeUtf8 operation
        , number version
        , TextEncoding.encodeUtf8 phase
        , TextEncoding.encodeUtf8 adapter
        , disposition
        ]
  where
    number = TextEncoding.encodeUtf8 . T.pack . show
    framed value = ByteString.pack [fromIntegral (shiftR (fromIntegral (ByteString.length value) :: Word64) shift) | shift <- [56, 48 .. 0]] <> value

readOnlyResourceFields :: ProtectedStore -> IO [ByteString]
readOnlyResourceFields store = resourceFrames . protectedRecordBytes . snd <$> readOnlyResourceRecord store

readOnlyResourceRecord :: ProtectedStore -> IO (T.Text, ProtectedRecord)
readOnlyResourceRecord store = do
    result <- withProtectedEntry store $ \session -> do
        listed <- listProtectedRecords session
        case listed of
            Left failure -> pure (Left failure)
            Right keys -> case filter (T.isPrefixOf "resource." . recordKeyText) keys of
                [key] -> do
                    observed <- readProtectedRecord session key
                    pure $ case observed of
                        Left failure -> Left failure
                        Right Nothing -> error "listed resource record disappeared"
                        Right (Just record) -> Right (recordKeyText key, record)
                _ -> error "expected exactly one resource record"
    either (assertFailure . show) pure result

resourceFrames :: ByteString -> [ByteString]
resourceFrames raw
    | ByteString.null raw = []
    | ByteString.length raw < 8 = error "truncated resource frame"
    | otherwise = field : resourceFrames trailing
  where
    (prefix, body) = ByteString.splitAt 8 raw
    size = ByteString.foldl' (\value byte -> shiftL value 8 .|. fromIntegral byte) 0 prefix :: Word64
    (field, trailing) = ByteString.splitAt (fromIntegral size) body

summarizeError :: ReconcileError -> T.Text
summarizeError err = case err of
    Conflict _ -> "conflict"
    SafetyRefusal _ -> "safety"
    Unsupported _ -> "unsupported"
    Failure _ -> "failure"

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id

-- | The relation the fixture's relating node claims.
aliasProjection :: String
aliasProjection = "core:deploy-kind/project:relating-node/relation"

aliasProjectionKey :: T.Text
aliasProjectionKey = T.pack aliasProjection

gateNames :: T.Text -> Maybe PreparedGate -> Bool
gateNames key = maybe False ((== key) . preparedGateOperation)

invocationRecordCount :: ProtectedStore -> IO Int
invocationRecordCount store = do
    listed <- withProtectedEntry store listProtectedRecords >>= expectSuccess
    pure
        ( length
            [ ()
            | key <- listed
            , "invocation." `T.isPrefixOf` recordKeyText key
            ]
        )

protectedKeyImage :: ProtectedStore -> IO [T.Text]
protectedKeyImage store =
    map recordKeyText
        <$> (withProtectedEntry store listProtectedRecords >>= expectSuccess)

protectedRecordImage :: ProtectedStore -> IO [(T.Text, Word64, ByteString)]
protectedRecordImage store = do
    image <- withProtectedEntry store $ \session -> do
        listed <- listProtectedRecords session
        case listed of
            Left failure -> pure (Left failure)
            Right keys -> do
                records <- traverse (readProtectedRecord session) keys
                pure $ do
                    observed <- sequence records
                    traverse retain (zip keys observed)
    expectSuccess image
  where
    retain (key, Just record) =
        Right (recordKeyText key, recordVersionWord (protectedRecordVersion record), protectedRecordBytes record)
    retain (_key, Nothing) = Left (ProtectedIOFailure "read the complete fixture store" "a listed record disappeared")

-- | The recorded phase of every operation record in the store, in key order.
readOperationPhases :: ProtectedSession session -> IO (Either ProtectedError [T.Text])
readOperationPhases s = do
    listed <- listProtectedRecords s
    case listed of
        Left failure -> pure (Left failure)
        Right keys -> traverse phaseOf (filter isOperationKey keys) >>= pure . sequence
  where
    isOperationKey = T.isPrefixOf "op." . recordKeyText
    phaseOf key = do
        record <- readProtectedRecord s key
        pure $ case record of
            Left failure -> Left failure
            Right Nothing -> Right ""
            Right (Just value) -> Right (recordedPhase (protectedRecordBytes value))

{- | The operation phase inside one durable record.

The transaction coordinator stamps every target as
@hbtx-target-v1\t\<sequence\>\n\<payload\>@, so the phase is the first
tab-separated field of the payload that follows that newline.
-}
recordedPhase :: ByteString -> T.Text
recordedPhase raw = case decodeFields raw of
    (_magic : stamped : _) -> T.drop 1 (T.dropWhile (/= '\n') stamped)
    _ -> ""

assertExactlyOneClosedSession :: ProtectedStore -> T.Text -> IO ()
assertExactlyOneClosedSession store planDigest = do
    entered <-
        withProtectedEntry store $ \session -> do
            verified <- verifyAllSessionsClosed session planDigest
            pure (Right (allSessionsClosedCount <$> verified))
    case entered of
        Left failure -> assertFailure (show failure)
        Right (Left failure) -> assertFailure (sessionErrorMessage failure)
        Right (Right count) -> count @?= 1

-- | One exact current-frame node running an explicit action.
countingProbe :: String -> (forall scope planId. StepExecution scope planId -> IO StepObservation) -> Step
countingProbe name action =
    projectStep (fixtureProjectStepId name) ProjectManagedReverse "probe node" executionFrame action

-- | Interpret one exact root-frame plan through the public @project up@ route.
runFrom ::
    forall projectId.
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    [Step] ->
    IO (Either String ())
runFrom store project steps = do
    let authorityRoot =
            takeDirectory
                (takeDirectory (takeDirectory (protectedStoreRoot store)))
    (attempted, diagnostic) <-
        captureCLIExitStderr $
            withArgs ["project", "up"] $
                CLI.runHostBootstrapCLI
                    (T.unpack (installedProjectName project))
                    (chainProjectSpec authorityRoot steps)
    case attempted of
        Left ExitSuccess -> assertFailure "project up threw ExitSuccess instead of returning its outcome"
        Left exitCode -> pure (Left (show exitCode ++ if T.null diagnostic then "" else ": " ++ T.unpack diagnostic))
        Right () -> pure (Right ())

captureCLIExitStderr :: IO () -> IO (Either ExitCode (), T.Text)
captureCLIExitStderr action =
    withSystemTempFile "hostbootstrap-chain-stderr" $ \_ captured -> do
        hFlush stderr
        attempted <-
            Exception.bracket
                (hDuplicate stderr)
                (\saved -> hFlush stderr `Exception.finally` (hDuplicateTo saved stderr `Exception.finally` hClose saved))
                (\_ -> hDuplicateTo captured stderr >> Exception.try @ExitCode action)
        hSeek captured AbsoluteSeek 0
        diagnostic <- TIO.hGetContents captured
        _ <- Exception.evaluate (T.length diagnostic)
        pure (attempted, diagnostic)

{- | A current-frame node that records that it ran and reports @observation@.
Each carries its own project identity, so two can share a plan.
-}
countingStep :: String -> IORef Int -> StepObservation -> Step
countingStep name ran observation =
    projectStep
        (fixtureProjectStepId name)
        ProjectManagedReverse
        "counting node"
        executionFrame
        (\_ -> modifyIORef' ran (+ 1) >> pure observation)

-- | Interpret the exact one-frame plan over an explicit step list.
runInnermostWith :: [Step] -> IO (Either String ())
runInnermostWith steps =
    withChainStore $ \store project -> runFrom store project steps

{- | A throwaway public CLI root plus the fixture's installed identity.

The sibling config names the same canonical root as the store observed by the
callbacks.  The command itself opens that store and constructs the opaque
LifecycleEntry; this fixture never imports its hidden implementation module or
aligns any phantom index by hand.
-}
withChainStore ::
    (forall projectId. ProtectedStore -> InstalledProjectIdentity projectId -> IO result) ->
    IO result
withChainStore use =
    withSystemTempDirectory "hostbootstrap-chain" $ \directory ->
        withChainStoreAtRoot directory (\_root store project -> use store project)

withChainStoreAtRoot ::
    FilePath ->
    (forall projectId. FilePath -> ProtectedStore -> InstalledProjectIdentity projectId -> IO result) ->
    IO result
withChainStoreAtRoot directory use =
    Fixture.withFixtureInstalledProject $ \project -> do
        let projectName = installedProjectName project
        configPath <- Schema.siblingProjectConfigPath projectName
        rooted <-
            withCanonicalProjectRoot
                configPath
                directory
                (pure . canonicalProjectRootPath)
        canonicalRoot <- expectSuccess rooted
        let config =
                Fixture.defaultProjectConfig
                    projectName
                    (T.pack canonicalRoot)
                    Context.HostOrchestrator
            storeRoot =
                canonicalRoot
                    </> ".hostbootstrap"
                    </> "authority"
                    </> T.unpack projectName
            cleanup = do
                present <- doesFileExist configPath
                if present then removeFile configPath else pure ()
        ( do
                Schema.writeProjectConfigFile Fixture.projectConfigCodec configPath config
                opened <- openProtectedStore storeRoot
                store <- either (assertFailure . show) pure opened
                use canonicalRoot store project
            )
            `Exception.finally` cleanup

chainProjectSpec :: FilePath -> [Step] -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
chainProjectSpec root steps =
    either (error . show) id $
        CLI.finalizeProjectSpec $
            CLI.addSteps (\_root _config -> steps) $
                CLI.addForwardChildPlan Fixture.refusingForwardChildPlan $
                    CLI.projectSpec
                        chainSuite
                        (pure ())
                        []
                        Fixture.testConfigCodec
                        (const (Fixture.defaultTestConfig (Fixture.Resources 1 "1GiB" "1GiB")))
                        (chainAssemble root)

chainSuite :: Harness.TestSuite
chainSuite =
    Harness.TestSuite
        (pure (Right ()))
        (\_ _ -> pure ())
        [Harness.Case chainCaseId Harness.AssertOnce]
        (\_ _ -> pure Harness.Pass)
        (pure ())

chainCaseId :: Harness.CaseId
chainCaseId = either (error . show) id (Harness.mkCaseId "chain-fixture")

chainAssemble ::
    FilePath ->
    forall projectId scope.
    AssemblyRequest projectId Fixture.TestConfig T.Text scope ->
    ConfigAssembly scope (Fixture.ProjectConfig scope)
chainAssemble root request = case request of
    ProductionAssembly args ->
        pureConfigAssembly (Fixture.projectInit "chain-fixture" args)
    HarnessAssembly _authority _root _testConfig _variant ->
        pureConfigAssembly
            ( Fixture.defaultProjectConfig
                "chain-fixture"
                (T.pack root)
                Context.HostOrchestrator
            )

-- | A pure exact plan fixture for renderer/topology projections.
withAdmittedPlan ::
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withAdmittedPlan = Fixture.withFixtureProjectPlan

expectSuccess :: (Show failure) => Either failure result -> IO result
expectSuccess = either (assertFailure . ("expected exact fixture success, got " ++) . show) pure

assertLeft :: String -> Either failure result -> IO ()
assertLeft _ (Left _) = pure ()
assertLeft message (Right _) = assertFailure message

assertFailureContains :: String -> Either String result -> IO ()
assertFailureContains marker outcome = case outcome of
    Left failure -> assertBool ("missing failure marker " ++ show marker ++ " in " ++ show failure) (marker `isInfixOf` failure)
    Right _ -> assertFailure ("expected failure containing " ++ show marker)

directChainHostConfig :: IO HostConfig
directChainHostConfig = Substrate.detect >>= expectSuccess >>= buildHostConfig

readRequiredPlanDigest :: IORef (Maybe T.Text) -> IO T.Text
readRequiredPlanDigest sink = do
    observed <- readIORef sink
    maybe (assertFailure "the action did not observe its admitted plan digest") pure observed

-- | What one action observed about itself: key, frame, plan digest, edge set.
type ObservedExecution = (T.Text, T.Text, T.Text, [T.Text])

observing :: IORef [ObservedExecution] -> StepAction
observing sink execution = do
    modifyIORef'
        sink
        ( ++
            [
                ( stepExecutionOperationKey execution
                , stepExecutionFrame execution
                , stepExecutionPlanDigest execution
                , stepExecutionDependencyKeys execution
                )
            ]
        )
    pure StepChanged

{- | Interpret the exact one-frame plan through the public root entry and read
its independently persisted snapshot digest beside the callback observations.
-}
runInnermost :: [IORef [ObservedExecution] -> Step] -> IO (T.Text, [ObservedExecution])
runInnermost build =
    withChainStore $ \store project -> do
        (snapshot, observed) <- runInnermostInStore store project build
        pure (planSnapshotViewPlanDigest snapshot, observed)

runInnermostInStore ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    [IORef [ObservedExecution] -> Step] ->
    IO (PlanSnapshotView, [ObservedExecution])
runInnermostInStore store project build = do
    sink <- newIORef []
    outcome <- runFrom store project (map ($ sink) build)
    outcome @?= Right ()
    observed <- readIORef sink
    assertBool "the exact root entry ran no descriptor action" (not (null observed))
    entered <- withProtectedEntry store $ \session ->
        Right <$> inspectPlanSnapshot session project "production"
    snapshot <- expectSuccess entered >>= expectSuccess
    pure (snapshot, observed)

data DescriptorRun = DescriptorRun
    { descriptorRunRoot :: FilePath
    , descriptorRunConfigBytes :: ByteString
    , descriptorRunConfigDigest :: T.Text
    , descriptorRunSpecDigest :: T.Text
    , descriptorRunPlanDigest :: T.Text
    , descriptorRunStoreIdentity :: ProtectedStoreIdentity
    , descriptorRunObserved :: [ObservedExecution]
    }

{- | Each call owns a new disposable directory at the same supplied pathname.
The public command gets a fresh store and invocation lineage, while its exact
canonical root and serialized configuration can be held fixed across calls.
-}
runFreshInnermostAtRoot :: FilePath -> [IORef [ObservedExecution] -> Step] -> IO DescriptorRun
runFreshInnermostAtRoot directory build =
    Exception.bracket_ (createDirectory directory) (removePathForcibly directory) $
        withChainStoreAtRoot directory $ \canonicalRoot store project -> do
            configPath <- Schema.siblingProjectConfigPath (installedProjectName project)
            configBytes <- ByteString.readFile configPath
            takeDirectory (takeDirectory (takeDirectory (protectedStoreRoot store))) @?= canonicalRoot
            (snapshot, observed) <- runInnermostInStore store project build
            configDigest <- maybe (assertFailure "the admitted snapshot has no config digest") pure (planSnapshotViewConfigDigest snapshot)
            let specDigest = planSnapshotViewSpecDigest snapshot
                planDigest = planSnapshotViewPlanDigest snapshot
            assertBool "the admitted config digest is empty" (not (T.null configDigest))
            assertBool "the admitted specification digest is empty" (not (T.null specDigest))
            assertBool "the admitted plan digest is empty" (not (T.null planDigest))
            pure
                DescriptorRun
                    { descriptorRunRoot = canonicalRoot
                    , descriptorRunConfigBytes = configBytes
                    , descriptorRunConfigDigest = configDigest
                    , descriptorRunSpecDigest = specDigest
                    , descriptorRunPlanDigest = planDigest
                    , descriptorRunStoreIdentity = protectedStoreIdentity store
                    , descriptorRunObserved = observed
                    }

assertMatchingDescriptorInputs :: DescriptorRun -> DescriptorRun -> IO ()
assertMatchingDescriptorInputs one other = do
    descriptorRunRoot other @?= descriptorRunRoot one
    descriptorRunConfigBytes other @?= descriptorRunConfigBytes one
    descriptorRunConfigDigest other @?= descriptorRunConfigDigest one
    descriptorRunSpecDigest other @?= descriptorRunSpecDigest one
    assertBool "the second invocation reused the first protected store" (descriptorRunStoreIdentity one /= descriptorRunStoreIdentity other)

assertDescriptorCallbacks :: [T.Text] -> DescriptorRun -> IO ()
assertDescriptorCallbacks expected run = do
    let observed = descriptorRunObserved run
    [key | (key, _, _, _) <- observed] @?= expected
    [digest | (_, _, digest, _) <- observed] @?= replicate (length expected) (descriptorRunPlanDigest run)

descriptorSteps :: [IORef [ObservedExecution] -> Step]
descriptorSteps =
    [ \sink -> deployKindStep "bring up kind" executionFrame (observing sink)
    , \sink ->
        projectStep
            (fixtureProjectStepId "deploy-harbor")
            ProjectManagedReverse
            "install harbor"
            executionFrame
            (observing sink)
    , \sink -> exposePortStep "expose the NodePort" executionFrame (observing sink)
    ]

otherDescriptorSteps :: [IORef [ObservedExecution] -> Step]
otherDescriptorSteps = take 1 descriptorSteps

-- | Mechanically pin the exact public interpreter boundary.
sourceShapeCases :: [TestTree]
sourceShapeCases =
    [ testCase "lifecycle descent has no argv command route" $ do
        chain <- chainSource
        command <- commandSource
        let exports = fst (T.breakOn ")\nwhere" chain)
        mapM_
            (\name -> assertBool ("legacy export remains: " ++ T.unpack name) (not (name `T.isInfixOf` exports)))
            ["    runChainFromFrame,", "    runChainFromFrameWithDescent,", "    handoffDispatch,"]
        assertBool "Chain cannot launch an argv descent" (not ("liftSubcommandWithStdin" `T.isInfixOf` chain))
        assertBool "Command cannot launch an argv descent" (not ("liftSubcommandWithStdin" `T.isInfixOf` command))
    , testCase "the exact entry joins ProjectPlan, CommandAuthority, and Execute cursor indices" $ do
        source <- chainSource
        let normalized = T.unwords (T.words source)
            signatures =
                [ "renderChain :: ProjectPlan scope specDigest planId configId cfg -> String"
                , "nextFrameAfter :: DerivedTopology scope planId -> Text -> Maybe (Text, LiftContext)"
                , "runChainFromFrameWithDescentFailure :: forall scope specDigest planId configId cfg frame brokerGeneration. HostConfig -> SelfRef -> ProtectedStore -> ProjectPlan scope specDigest planId configId cfg -> CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase -> LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase -> (ResourceCarrier scope planId -> Text -> Text -> LiftContext -> IO (Either String ())) -> IO (Either (String, [Text], [Text]) ())"
                ]
        mapM_
            ( \signature ->
                assertBool
                    ("missing exact Chain signature: " ++ T.unpack signature)
                    (T.isInfixOf signature normalized)
            )
            signatures
    , testCase "the public interpreter traverses only forward/planned-step projections" $ do
        source <- chainSource
        let required =
                [ "orderedProjection = forward"
                , "stepExecutionFor plan cfg runtime planned"
                , "runPlannedStep planned execution"
                , "nextFrameAfter derivedTopology current"
                , "validateCurrentFrameEntry"
                , "lifecycleCursorMatchesCommandAuthority authority cursor"
                , "validateCurrentLifecycleCursor protected cursor"
                ]
            forbidden =
                [ "import HostBootstrap.Step"
                , "import HostBootstrap.Lifecycle.Plan"
                , "LifecyclePlan"
                , "compatibilityStepExecutionFor"
                , "StepPlan"
                , "stepPlanSteps"
                , "preHandoffStepsForFrame"
                , "postHandoffStepsForFrame"
                , "runStep"
                ]
        mapM_
            ( \fragment ->
                assertBool
                    ("the exact planned-step route is missing: " ++ T.unpack fragment)
                    (T.isInfixOf fragment source)
            )
            required
        mapM_
            ( \fragment ->
                assertBool
                    ("the public Chain restored a compatibility/raw-step route: " ++ T.unpack fragment)
                    (not (T.isInfixOf fragment source))
            )
            forbidden
    , testCase "planned observations remain indexed from action through settlement" $ do
        source <- chainSource
        facade <- projectPlanSource
        let normalizedSource = T.unwords (T.words source)
            normalizedFacade = T.unwords (T.words facade)
            facadeContracts =
                [ "type role PlannedStepObservation nominal nominal nominal"
                , "plannedStepObservationSucceeded :: PlannedStepObservation scope planId configId -> Bool"
                , "plannedStepObservationDetail :: PlannedStepObservation scope planId configId -> Text"
                , "runPlannedStep :: PlannedStep scope planId configId config -> StepExecution scope planId -> IO (PlannedStepObservation scope planId configId)"
                ]
            interpreterRoute =
                [ "settledPhaseFor :: PlannedStepObservation scope planId configId -> Text"
                , "plannedStepObservationSucceeded observation"
                , "runPlannedStep planned execution"
                , "tryAny (runPlannedStep planned execution)"
                , "settleNode True runtime session gate afterPrepare \"StepObservedTerminal\""
                , "available <- if includeOpen then stepRuntimeOpenGates runtime else pure []"
                , "renderRow :: PlannedStep scope planId configId config -> PlannedStepObservation scope planId configId -> String"
                , "plannedStepObservationDetail observation"
                ]
            chainIdentifiers =
                T.words
                    ( T.map
                        ( \character ->
                            if isAlphaNum character || character == '_' || character == '\''
                                then character
                                else ' '
                        )
                        source
                    )
        mapM_
            ( \contract ->
                assertBool
                    ("missing indexed observation facade contract: " ++ T.unpack contract)
                    (T.isInfixOf contract normalizedFacade)
            )
            facadeContracts
        mapM_
            ( \fragment ->
                assertBool
                    ("the indexed observation interpreter route is missing: " ++ T.unpack fragment)
                    (T.isInfixOf fragment normalizedSource)
            )
            interpreterRoute
        assertBool
            "the public Chain names the raw plan-independent StepObservation"
            ("StepObservation" `notElem` chainIdentifiers)
    , testCase "authenticated child admission seeds only the shared canonical provider dependency registries" $ do
        child <- publicModuleSource ("Command" </> "Child.hs")
        process <- publicModuleSource ("Handoff" </> "Process.hs")
        let normalizedChild = T.unwords (T.words child)
            normalizedProcess = T.unwords (T.words process)
        mapM_
            (\fragment -> assertBool ("missing authenticated provider admission: " <> T.unpack fragment) (T.isInfixOf fragment normalizedChild))
            [ "withProviderDependencyClientKernel edge"
            , "seedProviderDependencyCarrierKernel carrier admittedPackage"
            , "withCarriedProviderDependencyFromCarrierKernel host link processRoute"
            ]
        mapM_
            (\fragment -> assertBool ("missing Process-owned provider carriage: " <> T.unpack fragment) (T.isInfixOf fragment normalizedProcess))
            [ "providerDependencyProbeRequestFromFields packageWire fields"
            , "withProviderDependencyReprobeEndpointKernel link bundleWire endpoint"
            , "withForwardLifecycleChildProcess config installed"
            , "runtimeDependencyPackageDomain package `notElem` [\"provider\", \"provider-share\"]"
            , "runtimeDependencyPackageBundleWire"
            , "registerStepRuntimeDependencyPackage runtime package"
            , "replaceStepRuntimeDependencyService runtime package"
            , "stepRuntimeDependencyPackages runtime"
            ]
        mapM_
            (\forbidden -> assertBool ("child admission mints a forbidden witness: " <> T.unpack forbidden) (not (T.isInfixOf forbidden normalizedChild)))
            [ "RunningProviderDependency"
            , "ManagedProviderHandle"
            , "ManagedProviderShareHandle"
            , "ClusterReadiness"
            ]
    ]

chainSource :: IO T.Text
chainSource = publicModuleSource "Chain.hs"

projectPlanSource :: IO T.Text
projectPlanSource = SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
    description <- SourceGuard.readPackageDescription
    path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.ProjectPlan"
    TIO.readFile path

commandSource :: IO T.Text
commandSource = publicModuleSource "Command.hs"

lifecycleEntrySource :: IO T.Text
lifecycleEntrySource = publicModuleSource ("Command" </> "LifecycleEntry.hs")

publicModuleSource :: FilePath -> IO T.Text
publicModuleSource moduleName = do
    cwd <- getCurrentDirectory
    root <-
        findRepoRoot cwd
            >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
    TIO.readFile
        ( root
            </> "core"
            </> "hostbootstrap-core"
            </> "src"
            </> "HostBootstrap"
            </> moduleName
        )

fixtureProjectStepId :: String -> ProjectStepId
fixtureProjectStepId = either error id . projectStepId

expectPlan :: [Step] -> StepPlan
expectPlan = either (error . show) id . mkStepPlan
