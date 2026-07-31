module StepSpec (tests) where

import HostBootstrap.Lift (localContext)
import HostBootstrap.Step
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "StepSpec"
        [ testGroup "stepKindName" kindNameCases
        , testGroup "renderStep / renderChainPlan" renderCases
        , testGroup "frame segmentation" frameCases
        , testGroup "plan validation" validationCases
        ]

-- Fixtures: frames and a representative chain interleaving host and project steps.
metal :: StepFrame
metal = StepFrame{frameId = "host-orchestrator-0", frameLabel = "metal"}

vmFrame :: StepFrame
vmFrame = StepFrame{frameId = "vm-orchestrator-1", frameLabel = "VM"}

ctrFrame :: StepFrame
ctrFrame = StepFrame{frameId = "vm-project-container-2", frameLabel = "container"}

noop :: a -> IO ()
noop _ = pure ()

-- A small demo-shaped chain: metal provisions and builds, then the container
-- frame deploys the cluster, a project step (harbor), and exposes the port.
demoSteps :: [Step]
demoSteps =
    [ deployVMStep "launch the VM" metal noop
    , copySourceStep "stage source into the VM" metal noop
    , ensureStep "ghc" "ensure GHC in the VM" metal noop
    , descendsVia localContext (buildPbStep "build the binary in the VM" metal noop)
    , contextInitStep "mint the container config" vmFrame noop
    , descendsVia localContext (buildImageStep "build the project image" vmFrame noop)
    , deployKindStep "bring up kind" ctrFrame noop
    , projectStep (fixtureProjectStepId "deploy-harbor") ProjectManagedReverse "install harbor" ctrFrame noop
    , exposePortStep "expose the NodePort" ctrFrame noop
    , postHandoffStep "start-accelerator-daemon" "start the host accelerator daemon" metal noop
    ]

demoPlan :: StepPlan
demoPlan = expectPlan demoSteps

kindNameCases :: [TestTree]
kindNameCases =
    [ testCase "core kinds render their stable names" $
        map (stepKindName . stepKind) coreSteps
            @?= [ "deploy-vm"
                , "ensure-ghc"
                , "copy-source"
                , "build-pb"
                , "build-image"
                , "context-init"
                , "deploy-kind"
                , "deploy-chart"
                , "expose-port"
                , "post-handoff-start-accelerator-daemon"
                ]
    , testCase "a project kind renders its own name (the open seam)" $
        stepKindName
            ( stepKind
                (projectStep (fixtureProjectStepId "deploy-harbor") ProjectManagedReverse "install harbor" ctrFrame noop)
            )
            @?= "deploy-harbor"
    ]
  where
    coreSteps =
        [ deployVMStep "" metal noop
        , ensureStep "ghc" "" metal noop
        , copySourceStep "" metal noop
        , buildPbStep "" metal noop
        , buildImageStep "" metal noop
        , contextInitStep "" metal noop
        , deployKindStep "" metal noop
        , deployChartStep "" metal noop
        , exposePortStep "" metal noop
        , postHandoffStep "start-accelerator-daemon" "" metal noop
        ]

renderCases :: [TestTree]
renderCases =
    [ testCase "renderStep tags the frame, the kind, and the label" $
        renderStep (deployKindStep "bring up kind" ctrFrame noop)
            @?= "[vm-project-container-2] deploy-kind — bring up kind"
    , testCase "a project step renders interleaved with host steps in chain order" $
        renderChainPlan demoPlan
            @?= unlines
                [ "1. [host-orchestrator-0] deploy-vm — launch the VM"
                , "2. [host-orchestrator-0] copy-source — stage source into the VM"
                , "3. [host-orchestrator-0] ensure-ghc — ensure GHC in the VM"
                , "4. [host-orchestrator-0] build-pb — build the binary in the VM"
                , "5. [vm-orchestrator-1] context-init — mint the container config"
                , "6. [vm-orchestrator-1] build-image — build the project image"
                , "7. [vm-project-container-2] deploy-kind — bring up kind"
                , "8. [vm-project-container-2] deploy-harbor — install harbor"
                , "9. [vm-project-container-2] expose-port — expose the NodePort"
                , "10. [host-orchestrator-0] post-handoff-start-accelerator-daemon — start the host accelerator daemon"
                ]
    ]

frameCases :: [TestTree]
frameCases =
    [ testCase "chainFrames lists the descent frames in first-appearance order" $
        map frameId (chainFrames demoPlan)
            @?= ["host-orchestrator-0", "vm-orchestrator-1", "vm-project-container-2"]
    , testCase "stepsForFrame selects exactly this frame's steps in order" $
        map stepLabel (stepsForFrame "vm-project-container-2" demoPlan)
            @?= ["bring up kind", "install harbor", "expose the NodePort"]
    , testCase "post-handoff hooks are not part of the pre-handoff segment" $ do
        map stepLabel (preHandoffStepsForFrame "host-orchestrator-0" demoPlan)
            @?= ["launch the VM", "stage source into the VM", "ensure GHC in the VM", "build the binary in the VM"]
        map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" demoPlan)
            @?= ["start the host accelerator daemon"]
    , testCase "stepsForFrame is empty for a frame the chain never enters" $
        map stepLabel (stepsForFrame "no-such-frame" demoPlan) @?= []
    , testCase "a non-contiguous frame return is rejected without reordering" $
        case
            mkStepPlan
                [ deployVMStep "a1" metal noop
                , contextInitStep "b" vmFrame noop
                , copySourceStep "a2" metal noop
                ] of
            Left err ->
                err
                    @?= NonContiguousFrameReturn
                        "host-orchestrator-0"
                        ["host-orchestrator-0", "vm-orchestrator-1", "host-orchestrator-0"]
            Right _ -> error "non-contiguous frame return unexpectedly validated"
    ]

validationCases :: [TestTree]
validationCases =
    [ testCase "generated frame sequences preserve exact order or reject a closed-frame return" $
        mapM_ validateSequence generatedFrameSequences
    , testCase "duplicate typed identities are rejected" $
        case
            mkStepPlan
                [ projectStep duplicateId ProjectManagedReverse "first" metal noop
                , projectStep duplicateId ProjectManagedReverse "second" metal noop
                ] of
            Left (DuplicateStepIdentities identities) ->
                identities @?= [ProjectStepIdentity duplicateId]
            other -> assertFailure ("expected duplicate identity rejection, got " ++ either show (const "validated") other)
    , testCase "core and project identities remain disjoint despite equal presentation" $ do
        let projectContextInit =
                projectStep
                    (fixtureProjectStepId "context-init")
                    ProjectManagedReverse
                    "project context extension"
                    metal
                    noop
        plan <-
            either
                (assertFailure . show)
                pure
                (mkStepPlan [contextInitStep "core context init" metal noop, projectContextInit])
        map stepKindName (map stepKind (stepPlanSteps plan))
            @?= ["context-init", "context-init"]
        case stepPlanSteps plan of
            [coreContextInit, projectContextInit'] ->
                assertBool
                    "typed identities differ"
                    (stepIdentity coreContextInit /= stepIdentity projectContextInit')
            actual -> assertFailure ("expected two validated steps, got " ++ show (length actual))
    , testCase "post-handoff hooks form only a final suffix" $
        case
            mkStepPlan
                [ postHandoffStep "late" "late hook" metal noop
                , projectStep (fixtureProjectStepId "after-hook") ProjectManagedReverse "normal" metal noop
                ] of
            Left (PostHandoffBeforeDescentComplete _) -> pure ()
            other -> assertFailure ("expected post-handoff ordering rejection, got " ++ either show (const "validated") other)
    , testCase "every smart constructor retains an explicit reverse policy" $
        map stepReversePolicy
            [ ensureStep "ghc" "ensure" metal noop
            , deployVMStep "deploy" vmFrame noop
            , projectStep (fixtureProjectStepId "mutate") ProjectManagedReverse "mutate" ctrFrame noop
            ]
            @?= [PreserveOnReverse, ProjectManagedReverse, ProjectManagedReverse]
    , testCase "a frame that descends into another must declare exactly one descent" $ do
        case mkStepPlan [deployVMStep "a" metal noop, contextInitStep "b" vmFrame noop] of
            Left err -> err @?= MissingFrameDescent "host-orchestrator-0"
            Right _ -> assertFailure "a frame with a successor and no descent was validated"
        case
            mkStepPlan
                [ descendsVia localContext (deployVMStep "a" metal noop)
                , descendsVia localContext (copySourceStep "a2" metal noop)
                , contextInitStep "b" vmFrame noop
                ] of
            Left err -> err @?= DuplicateFrameDescent "host-orchestrator-0" 2
            Right _ -> assertFailure "two descents out of one frame were validated"
        case
            mkStepPlan
                [ descendsVia localContext (descendsVia localContext (deployVMStep "a" metal noop))
                , contextInitStep "b" vmFrame noop
                ] of
            Left err -> err @?= DuplicateFrameDescent "host-orchestrator-0" 2
            Right _ -> assertFailure "a step declaring two descents was validated"
    , testCase "the innermost frame and post-handoff hooks declare no descent" $ do
        case
            mkStepPlan
                [ descendsVia localContext (deployVMStep "a" metal noop)
                , descendsVia localContext (contextInitStep "b" vmFrame noop)
                ] of
            Left err -> err @?= DescentFromInnermostFrame "vm-orchestrator-1"
            Right _ -> assertFailure "a descent out of the innermost frame was validated"
        case
            mkStepPlan
                [ deployVMStep "a" metal noop
                , descendsVia localContext (postHandoffStep "late" "late hook" metal noop)
                ] of
            Left err -> err @?= DescentOnPostHandoffStep 2
            Right _ -> assertFailure "a post-handoff descent was validated"
    , testCase "a declared reverse effect must be able to run, and only once" $ do
        let noReverse _ _ = pure TeardownReleased
        case mkStepPlan [reversedBy noReverse (ensureStep "ghc" "ensure" metal noop)] of
            Left err -> err @?= ReverseOnPreservedStep (CoreStepIdentity (EnsureToolId "ghc"))
            Right _ -> assertFailure "a reverse on a preserve-on-reverse step was validated"
        case mkStepPlan [reversedBy noReverse (reversedBy noReverse (deployVMStep "a" metal noop))] of
            Left err -> err @?= DuplicateStepReverse (CoreStepIdentity DeployVMId) 2
            Right _ -> assertFailure "two reverses on one step were validated"
        -- A core-managed node MAY declare one: it then takes precedence over the
        -- core adapter, which is how a cluster in an unreachable frame is
        -- released by the project (the demo's direct Linux GPU lane).
        case mkStepPlan [reversedBy noReverse (deployKindStep "cluster" metal noop)] of
            Left err -> assertFailure ("a core-managed override was rejected: " ++ show err)
            Right _ -> pure ()
    , testCase "validated plans derive one operation key and exact dependency prefix per step" $ do
        let steps = stepPlanSteps demoPlan
            keys = map (operationKeyText . stepOperationKey) steps
        assertBool "operation keys are non-empty" (all (not . null) keys)
        assertBool "operation keys are unique" (and [left /= right | (index, left) <- zip [0 :: Int ..] keys, right <- drop (index + 1) keys])
        map (stepDependencies demoPlan) steps
            @?= [take index (map stepIdentity steps) | index <- [0 .. length steps - 1]]
    ]
  where
    duplicateId = fixtureProjectStepId "duplicate"

generatedFrameSequences :: [[String]]
generatedFrameSequences =
    concatMap (`sequencesOfLength` ["a", "b", "c"]) [1 .. 4]

sequencesOfLength :: Int -> [a] -> [[a]]
sequencesOfLength 0 _ = [[]]
sequencesOfLength n values =
    [value : rest | value <- values, rest <- sequencesOfLength (n - 1) values]

validateSequence :: [String] -> IO ()
validateSequence frameIds =
    case (hasClosedFrameReturn frameIds, mkStepPlan steps) of
        (False, Right plan) ->
            map (frameId . stepFrame) (stepPlanSteps plan) @?= frameIds
        (True, Left (NonContiguousFrameReturn _ actual)) ->
            actual @?= frameIds
        (False, Left err) ->
            assertFailure ("valid generated frame sequence was rejected: " ++ show (frameIds, err))
        (True, Right _) ->
            assertFailure ("invalid generated frame sequence was accepted: " ++ show frameIds)
        (True, Left err) ->
            assertFailure ("invalid sequence failed for the wrong reason: " ++ show (frameIds, err))
  where
    steps =
        withDescents
            [ projectStep
                (fixtureProjectStepId ("generated-" ++ show index))
                ProjectManagedReverse
                ("step " ++ show index)
                (StepFrame fid fid)
                noop
            | (index, fid) <- zip [1 :: Int ..] frameIds
            ]

{- | Attach the one descent every frame but the innermost must declare, to the
last step of each frame's segment. The generated sequences carry no
post-handoff hooks, so every step is a candidate.
-}
withDescents :: [Step] -> [Step]
withDescents steps =
    [ if frame /= innermost && index == lastIndexOf frame
        then descendsVia localContext step
        else step
    | (index, step) <- indexed
    , let frame = frameId (stepFrame step)
    ]
  where
    indexed = zip [0 :: Int ..] steps
    frames = map (frameId . stepFrame) steps
    innermost = case distinct frames of
        [] -> ""
        ordered -> last ordered
    lastIndexOf frame = last [index | (index, step) <- indexed, frameId (stepFrame step) == frame]
    distinct = foldl (\seen value -> if value `elem` seen then seen else seen ++ [value]) []

hasClosedFrameReturn :: [String] -> Bool
hasClosedFrameReturn [] = False
hasClosedFrameReturn (firstFrame : rest) = go firstFrame [] rest
  where
    go _ _ [] = False
    go current closed (next : remaining)
        | next == current = go current closed remaining
        | next `elem` closed = True
        | otherwise = go next (current : closed) remaining

fixtureProjectStepId :: String -> ProjectStepId
fixtureProjectStepId = either error id . projectStepId

expectPlan :: [Step] -> StepPlan
expectPlan = either (error . show) id . mkStepPlan
