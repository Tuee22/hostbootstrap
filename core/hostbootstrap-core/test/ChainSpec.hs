{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ChainSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Fixture
import HostBootstrap.Authority (InstalledProject, installedProjectFor)
import HostBootstrap.Chain
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Incus))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lifecycle.Execution (
    stepExecutionDependencyKeys,
    stepExecutionFrame,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
 )
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lifecycle.Prepared (decodeFields)
import HostBootstrap.Protected (
    ProtectedError,
    ProtectedRecord (protectedRecordBytes),
    ProtectedSession,
    ProtectedStore,
    listProtectedRecords,
    openProtectedStore,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (lifecyclePlanDigest, withLifecyclePlan)
import HostBootstrap.Substrate (
    Arch (Arm64),
    Substrate (..),
    SubstrateName (LinuxCpu),
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
import System.FilePath ((</>))
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
        , testGroup "the plan mints each step's execution descriptor (§ U)" descriptorCases
        , testGroup "the interpreter converts each node's observation" observationCases
        , testGroup "the interpreter's durable transaction" transactionCases
        ]

-- Fixtures.
metal :: StepFrame
metal = StepFrame{frameId = "host-orchestrator-0", frameLabel = "metal"}

vmFrame :: StepFrame
vmFrame = StepFrame{frameId = "vm-orchestrator-1", frameLabel = "VM"}

ctrFrame :: StepFrame
ctrFrame = StepFrame{frameId = "vm-project-container-2", frameLabel = "container"}

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
        nextFrameAfter "host-orchestrator-0" demoPlan @?= Just vmFrame
    , testCase "hands off from the VM frame to the container frame" $
        nextFrameAfter "vm-orchestrator-1" demoPlan @?= Just ctrFrame
    , testCase "bottoms out at the innermost frame" $
        nextFrameAfter "vm-project-container-2" demoPlan @?= Nothing
    , testCase "a frame the chain never enters has no next frame" $
        nextFrameAfter "no-such-frame" demoPlan @?= Nothing
    , -- The descent the interpreter dispatches is read off the plan, not from a
      -- separately supplied per-frame resolver (§ W), so this is the same value
      -- 'handoffCases' asserts the argv of.
      testCase "each frame's handoff context is a node of the same plan" $ do
        fmap (handoffDispatch self) (frameDescent "host-orchestrator-0" demoPlan)
            @?= Just (DispatchTool Incus ["exec", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "project", "up"])
        fmap (handoffDispatch self) (frameDescent "vm-orchestrator-1" demoPlan)
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
    , testCase "the innermost frame declares no descent" $
        fmap (handoffDispatch self) (frameDescent "vm-project-container-2" demoPlan) @?= Nothing
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
    [ testCase "the dry-run plan lists every step the interpreter would run, in order" $
        renderChain demoPlan
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
    , testCase "frame-segmenting the chain across the descent preserves every step in order" $
        concatMap (\f -> map stepLabel (stepsForFrame (frameId f) demoPlan)) (chainFrames demoPlan)
            @?= map stepLabel demoSteps
    , testCase "post-handoff hook stays after the container exposes the ingress" $ do
        renderChain acceleratorPlan
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
        map stepLabel (preHandoffStepsForFrame (frameId metal) acceleratorPlan)
            @?= ["launch the VM", "stage source into the VM", "build the binary in the VM"]
        map stepLabel (postHandoffStepsForFrame (frameId metal) acceleratorPlan)
            @?= ["start the host accelerator daemon"]
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
            @?= [ ("core:deploy-kind", "vm-project-container-2")
                , ("project:deploy-harbor", "vm-project-container-2")
                , ("core:expose-port", "vm-project-container-2")
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
    , testCase "each non-success outcome names its own node and its own kind" $ do
        let expectRow observation fragment = do
                ran <- newIORef (0 :: Int)
                outcome <- runInnermostWith [countingStep "deploy-kind-probe" ran observation, countingStep "later" ran StepChanged]
                case outcome of
                    Left err -> do
                        assertBool
                            ("the row names the node: " ++ err)
                            ("deploy-kind-probe" `isInfixOf` err)
                        assertBool
                            ("the row names the outcome: " ++ err)
                            (fragment `isInfixOf` err)
                        -- the later node did not run
                        readIORef ran >>= (@?= 1)
                    Right () -> assertFailure "expected the chain to stop at the node"
        expectRow (StepConflict "the run's cluster" "a foreign cluster" "delete it") "conflict:"
        expectRow (StepUnsupported "no kube toolchain in this frame") "unsupported:"
        expectRow (StepRefused "the cluster holds state this run does not own") "refused:"
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
            let probe _ = do
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
            case outcome of
                Left err -> assertBool ("names the outcome: " ++ err) ("unsupported:" `isInfixOf` err)
                Right () -> assertFailure "expected the chain to stop at the node"
            -- Terminal, not unknown: an operator resolves it, and a successor
            -- refuses to retry it rather than blocking on an unclassifiable
            -- record.
            settled <- withProtectedEntry store readOperationPhases
            either (assertFailure . show) (@?= ["StepObservedTerminal"]) settled
    ]

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

-- | One container-frame node running an explicit action.
countingProbe :: String -> (forall scope planId. StepExecution scope planId -> IO StepObservation) -> Step
countingProbe name action =
    projectStep (fixtureProjectStepId name) ProjectManagedReverse "probe node" ctrFrame action

-- | Interpret the innermost frame against a caller-supplied store.
runFrom ::
    ProtectedStore ->
    InstalledProject Fixture.FixtureProject ->
    [Step] ->
    IO (Either String ())
runFrom store project steps = do
    let plan = expectPlan steps
        cfg = HostConfig{hcSubstrate = descriptorSubstrate, hcToolPaths = Map.empty}
    run <-
        withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
            withLifecyclePlan codec plan $ \lifecycle ->
                pure (runChainFromFrame cfg self (frameId ctrFrame) store project lifecycle)
    run

-- | A container-frame node that records that it ran and reports @observation@.
-- Each carries its own project identity, so two can share a plan.
countingStep :: String -> IORef Int -> StepObservation -> Step
countingStep name ran observation =
    projectStep
        (fixtureProjectStepId name)
        ProjectManagedReverse
        "counting node"
        ctrFrame
        (\_ -> modifyIORef' ran (+ 1) >> pure observation)

-- | Interpret the innermost frame over an explicit step list.
runInnermostWith :: [Step] -> IO (Either String ())
runInnermostWith steps =
    withChainStore $ \store project -> do
        let plan = expectPlan steps
            cfg = HostConfig{hcSubstrate = descriptorSubstrate, hcToolPaths = Map.empty}
        run <-
            withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
                withLifecyclePlan codec plan $ \lifecycle ->
                    pure (runChainFromFrame cfg self (frameId ctrFrame) store project lifecycle)
        run

{- | A throwaway protected store plus the fixture's installed identity.

The interpreter runs every node as a real prepared operation, so these cases
drive the production transaction against a real store on a real filesystem
rather than a stand-in. -}
withChainStore ::
    (ProtectedStore -> InstalledProject Fixture.FixtureProject -> IO result) ->
    IO result
withChainStore use =
    withSystemTempDirectory "hostbootstrap-chain" $ \directory -> do
        opened <- openProtectedStore (directory </> "authority")
        store <- either (assertFailure . show) pure opened
        project <-
            either
                (assertFailure . show)
                pure
                (installedProjectFor @Fixture.FixtureProject @Fixture.ProjectConfig "hostbootstrap-demo")
        use store project

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

{- | Interpret the innermost frame, which runs its steps and then ends the
descent, so the recorded descriptors are exactly this frame's. Returns the
plan's own digest alongside them, read from the same opened plan the interpreter
ran, so the assertion compares the descriptor against the plan rather than
against a second computation of it.
-}
runInnermost :: [IORef [ObservedExecution] -> Step] -> IO (T.Text, [ObservedExecution])
runInnermost build = do
    sink <- newIORef []
    let plan = expectPlan (map ($ sink) build)
        cfg = HostConfig{hcSubstrate = descriptorSubstrate, hcToolPaths = Map.empty}
    (planDigest, run) <-
        withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
            withLifecyclePlan codec plan $ \lifecycle ->
                pure
                    ( lifecyclePlanDigest lifecycle
                    , \store project ->
                        runChainFromFrame cfg self (frameId ctrFrame) store project lifecycle
                    )
    outcome <- withChainStore run
    outcome @?= Right ()
    observed <- readIORef sink
    pure (planDigest, observed)

descriptorSubstrate :: Substrate
descriptorSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Arm64}

descriptorSteps :: [IORef [ObservedExecution] -> Step]
descriptorSteps =
    [ \sink -> deployKindStep "bring up kind" ctrFrame (observing sink)
    , \sink ->
        projectStep
            (fixtureProjectStepId "deploy-harbor")
            ProjectManagedReverse
            "install harbor"
            ctrFrame
            (observing sink)
    , \sink -> exposePortStep "expose the NodePort" ctrFrame (observing sink)
    ]

otherDescriptorSteps :: [IORef [ObservedExecution] -> Step]
otherDescriptorSteps =
    [\sink -> deployKindStep "bring up a different cluster" ctrFrame (observing sink)]

fixtureProjectStepId :: String -> ProjectStepId
fixtureProjectStepId = either error id . projectStepId

expectPlan :: [Step] -> StepPlan
expectPlan = either (error . show) id . mkStepPlan
