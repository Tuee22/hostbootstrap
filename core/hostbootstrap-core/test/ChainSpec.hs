{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ChainSpec (interpretExactSteps, tests) where

import Control.Exception (throwIO)
import qualified Control.Exception as Exception
import Data.ByteString (ByteString)
import Data.Char (isAlphaNum)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    installedProjectName,
 )
import HostBootstrap.Chain
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    pureConfigAssembly,
 )
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Incus))
import qualified HostBootstrap.Harness as Harness
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
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    decodeFields,
    preparedGateOperation,
    preparedGatePlan,
 )
import HostBootstrap.Lifecycle.Session (
    allSessionsClosedCount,
    sessionErrorMessage,
    verifyAllSessionsClosed,
 )
import HostBootstrap.Protected (
    ProtectedError,
    ProtectedRecord (protectedRecordBytes),
    ProtectedSession,
    ProtectedStore,
    listProtectedRecords,
    openProtectedStore,
    protectedStoreRoot,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    plannedStepFrameId,
    plannedStepLabel,
    topology,
 )
import HostBootstrap.ProjectRoot (
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Reconcile (
    BackendReconcileObservation (BackendCreated),
    FailureDetail (FailureDetail),
    PlannedResourceKind (ClusterResourceKind),
    ReconcileError (Conflict, Failure, SafetyRefusal, Unsupported),
    RecoveryDisposition (DoNotRetry),
    carryManagedResource,
    completeReconcile,
    plannedNodeOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
    withCarriedManagedResource,
    withNodeObservedResource,
    withNodeResourceOfKind,
    withPreparedOperation,
    withReconcileResult,
    zeroDependencyPreconditions,
 )
import HostBootstrap.Lift (
    ContainerLift (..),
    LiftDispatch (DispatchTool),
    SelfRef,
    inContainer,
    inVM,
    localContext,
    mkSelfRef,
 )
import HostBootstrap.Step
import System.Directory (doesFileExist, getCurrentDirectory, removeFile)
import System.Environment (withArgs)
import System.Exit (ExitCode)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ChainSpec"
        [ testGroup "nextFrameAfter (descent order)" nextFrameCases
        , testGroup "handoffDispatch (recursive `project up` handoff)" handoffCases
        , testGroup "renderChain is the single representation" renderCases
        , testGroup "exact plan admission" admissionCases
        , testGroup "the plan mints each step's execution descriptor (§ U)" descriptorCases
        , testGroup "the interpreter converts each node's observation" observationCases
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

-- | The one-frame exact fixture used by effectful interpreter cases.
-- Keeping these nodes at the root preserves their local dependency prefixes;
-- the pure multi-frame cases above separately exercise topology descent.
executionFrame :: StepFrame
executionFrame = metal

noop :: a -> IO StepObservation
noop _ = pure StepChanged

demoSteps :: [Step]
demoSteps =
    [ deployVMStep "launch the VM" metal noop
    , copySourceStep "stage source into the VM" metal noop
    , descendsVia (inVM vm localContext) (buildPbStep "build the binary in the VM" metal noop)
    , contextInitStep "mint the container config" vmFrame noop
    , descendsVia (inContainer container localContext) (buildImageStep "build the project image" vmFrame noop)
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

self :: SelfRef
self = mkSelfRef "/proc/self/exe" "/usr/local/bin/hostbootstrap-demo"

vm :: IncusVM
vm = IncusVM "demo-vm" "images:ubuntu/24.04"

sockMount :: V.Mount
sockMount = V.Mount{V.source = "/var/run/docker.sock", V.target = "/var/run/docker.sock", V.readOnly = False}

container :: ContainerLift
container =
    ContainerLift
        { clImage = "demo:local"
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
    , -- The descent the interpreter dispatches is read off the exact plan's
      -- topology, not from a separately supplied per-frame resolver (§ W).
      testCase "each handoff context is projected by the same exact plan" $
        withAdmittedPlan demoPlan $ \plan -> do
            fmap (handoffDispatch self . snd) (nextFrameAfter (topology plan) "host-orchestrator-0")
                @?= Just (DispatchTool Incus ["exec", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "project", "up"])
            fmap (handoffDispatch self . snd) (nextFrameAfter (topology plan) "vm-orchestrator-1")
                @?= Just
                    ( DispatchTool
                        Docker
                        [ "run"
                        , "--rm"
                        , "-v"
                        , "/var/run/docker.sock:/var/run/docker.sock"
                        , "--network=host"
                        , "demo:local"
                        , "project"
                        , "up"
                        ]
                    )
    ]

handoffCases :: [TestTree]
handoffCases =
    [ testCase "into a VM: incus exec -- <in-vm pb> project up" $
        handoffDispatch self (inVM vm localContext)
            @?= DispatchTool Incus ["exec", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "project", "up"]
    , testCase "into a container: docker run --rm img project up (ENTRYPOINT is the pb)" $
        handoffDispatch self (inContainer container localContext)
            @?= DispatchTool
                Docker
                [ "run"
                , "--rm"
                , "-v"
                , "/var/run/docker.sock:/var/run/docker.sock"
                , "--network=host"
                , "demo:local"
                , "project"
                , "up"
                ]
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
            outcome @?= Right ()
            readIORef observed >>= (@?= projectedLabels)
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
                , "authorizeRootProject rootAuthority verb verified bound binding lease plan journal executeCursor lifecycleContext"
                , "use ( RootUpLifecycleEntry rootAuthority verb plan lifecycleContext journal executeCursor authority catalog )"
                , "runRootProjectUpLifecycleEntry cfg self (RootUpLifecycleEntry _rootAuthority _verb plan lifecycleContext _journal cursor authority _catalog)"
                , "withTeardownLifecycleCursor cursor"
                ]
            requiredFacade =
                [ "module HostBootstrap.Command ( coreCommands, coreCommandNames, allReconcilers, LifecycleEntry, lifecycleEntryFrameName, lifecycleEntryVerbName, )"
                , "withRootProjectUpLifecycleEntry exactSpec rootAuthority Authority.ProjectUp verified bound binding lease plan lifecycleContext (runRootProjectUpLifecycleEntry cfg self)"
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
    , testCase "a different plan mints a different digest for the same step kind" $ do
        (oneDigest, oneObserved) <- runInnermost descriptorSteps
        (otherDigest, otherObserved) <- runInnermost otherDescriptorSteps
        map (\(key, _, _, _) -> key) otherObserved @?= ["core:deploy-kind"]
        [dependencies | (_, _, _, dependencies) <- otherObserved] @?= [[]]
        (oneDigest == otherDigest) @?= False
        -- the shared first step still reports its own plan's digest, not the other's
        [digest | (_, _, digest, _) <- take 1 oneObserved] @?= [oneDigest]
    ]

{- | The interpreter turns each node's observation into that node's own outcome
(§ W). A node that did not reach its target state stops the chain and is named
with the kind of outcome it was, so a conflict, an unsupported backend, and a
refusal are told apart rather than reduced to one failure. -}
observationCases :: [TestTree]
observationCases =
    [ testCase "a node that reached its target state lets the chain continue" $ do
        ran <- newIORef (0 :: Int)
        outcome <- runInnermostWith [countingStep "first" ran StepUnchanged, countingStep "second" ran StepChanged]
        outcome @?= Right ()
        readIORef ran >>= (@?= 2)
    , testCase "each non-success observation stops before the later node" $ do
        let expectRow observation = do
                ran <- newIORef (0 :: Int)
                outcome <- runInnermostWith [countingStep "deploy-kind-probe" ran observation, countingStep "later" ran StepChanged]
                assertLeft "expected the public command to stop at the observed node" outcome
                readIORef ran >>= (@?= 1)
        expectRow (StepConflict "the run's cluster" "a foreign cluster" "delete it")
        expectRow (StepUnsupported "no kube toolchain in this frame")
        expectRow (StepRefused "the cluster holds state this run does not own")
    ]

{- | The durable half of the interpreter's transaction (§ EE).

These are the properties the unit-level prepare tests cannot show, because they
are about *when* the record is written relative to the effect and *whether* the
store is locked while the effect runs. -}
transactionCases :: [TestTree]
transactionCases =
    [ testCase "the unknown phase is durable before the effect, and the entry is free while it runs" $
        withChainStore $ \store project -> do
            observed <- newIORef ([] :: [T.Text])
            let probe :: forall scope planId. StepExecution scope planId -> IO StepObservation
                probe _ = do
                    -- Taking the exclusive entry here is itself the assertion
                    -- that the interpreter is not holding it: a provider call
                    -- or a cluster bring-up can take minutes, and the store
                    -- must stay available to a peer for that whole time.
                    phases <- withProtectedEntry store (readOperationPhases)
                    either (assertFailure . show) (writeIORef observed) phases
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
    ]

{- | A node's projected operations (§ CC).

A relating resource's key is not any node's own, so before this no node could
prepare one. The plan is where a node claims the relation, and the interpreter is
what turns that claim into a registered operation, an open gate the node's action
can take, and a settlement that happens with the node. -}
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
                , exposePortStep "an unrelated later node" executionFrame (\execution -> do
                    modifyIORef' seen (++ [stepExecutionProjectedOperations execution])
                    pure StepChanged)
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
        adopted <- newIORef ([] :: [Either T.Text (T.Text, Word64, Word64)])
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
                        modifyIORef' adopted (++ [either (Left . summarizeError) Right result])
                        pure StepChanged
                    )
                ]
        outcome @?= Right ()
        readIORef adopted >>= (@?= [Left "failure"])
    ]

{- | Acquire this node's own cluster resource through the real prepared path and
carry it. The gate is the node's own, opened by the interpreter, so this is the
production route rather than a fixture handle. -}
carryClusterHandle :: StepExecution scope planId -> IO ()
carryClusterHandle execution = do
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
                    withNodeObservedResource execution planned 5 7 $ \observed -> do
                        descriptor <- plannedNodeOperation execution planned observed "cluster:create"
                        preconditionSet <- zeroDependencyPreconditions descriptor
                        joinReconcile $
                            withPreparedOperation descriptor preconditionSet opened $
                                \prepared preconditions -> do
                                    reconciled <-
                                        completeReconcile observed prepared preconditions (BackendCreated 5)
                                    withReconcileResult
                                        reconciled
                                        (\managed _ _ -> Right (carryManagedResource execution managed))
                                        (\_ _ -> Left (unexpectedForeign))
    unexpectedForeign =
        Failure (FailureDetail "acquire cluster" "unexpected foreign cluster" DoNotRetry)

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
tab-separated field of the payload that follows that newline. -}
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
    attempted <-
        Exception.try @ExitCode $
            withArgs ["project", "up"] $
                CLI.runHostBootstrapCLI
                    (T.unpack (installedProjectName project))
                    (chainProjectSpec authorityRoot steps)
    pure (either (Left . show) Right attempted)

-- | A current-frame node that records that it ran and reports @observation@.
-- Each carries its own project identity, so two can share a plan.
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
aligns any phantom index by hand. -}
withChainStore ::
    (forall projectId. ProtectedStore -> InstalledProjectIdentity projectId -> IO result) ->
    IO result
withChainStore use =
    withSystemTempDirectory "hostbootstrap-chain" $ \directory -> do
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
                    use store project
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
        (\_ -> pure ())
        [Harness.Case chainCaseId 1 False]
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
    HarnessAssembly _authority _testConfig _variant ->
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

{- | Interpret the exact one-frame plan through the public root entry.  The
digest comes from the StepExecution minted for that same admitted entry, not a
second independently opened plan. -}
runInnermost :: [IORef [ObservedExecution] -> Step] -> IO (T.Text, [ObservedExecution])
runInnermost build = do
    sink <- newIORef []
    outcome <- runInnermostWith (map ($ sink) build)
    outcome @?= Right ()
    observed <- readIORef sink
    planDigest <- case observed of
        (_, _, digest, _) : _ -> pure digest
        [] -> assertFailure "the exact root entry ran no descriptor action"
    pure (planDigest, observed)

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
otherDescriptorSteps =
    [\sink -> deployKindStep "bring up a different cluster" executionFrame (observing sink)]

-- | Mechanically pin the exact public interpreter boundary.
sourceShapeCases :: [TestTree]
sourceShapeCases =
    [ testCase "the exact entry joins ProjectPlan, CommandAuthority, and Execute cursor indices" $ do
        source <- chainSource
        let normalized = T.unwords (T.words source)
            signatures =
                [ "renderChain :: ProjectPlan scope specDigest planId configId cfg -> String"
                , "nextFrameAfter :: DerivedTopology scope planId -> Text -> Maybe (Text, LiftContext)"
                , "runChainFromFrame :: forall scope specDigest planId configId cfg frame brokerGeneration. HostConfig -> SelfRef -> ProtectedStore -> ProjectPlan scope specDigest planId configId cfg -> CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase -> LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase -> IO (Either String ())"
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
                , "commandAuthorityMatchesStore authority store"
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
                , "plannedStepRefusalObservation :: PlannedStep scope planId configId config -> Text -> PlannedStepObservation scope planId configId"
                , "runPlannedStep :: PlannedStep scope planId configId config -> StepExecution scope planId -> IO (PlannedStepObservation scope planId configId)"
                ]
            interpreterRoute =
                [ "settledPhaseFor :: PlannedStepObservation scope planId configId -> Text"
                , "plannedStepObservationSucceeded observation"
                , "runPlannedStep planned execution"
                , "plannedStepRefusalObservation planned (Text.pack reason)"
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
    ]

chainSource :: IO T.Text
chainSource = publicModuleSource "Chain.hs"

projectPlanSource :: IO T.Text
projectPlanSource = publicModuleSource "ProjectPlan.hs"

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

-- | Shared exact-chain fixture for an adjacent integration spec.
interpretExactSteps :: HostConfig -> SelfRef -> [Step] -> IO (Either String ())
interpretExactSteps _cfg _exactSelf = runInnermostWith
