{-# LANGUAGE OverloadedStrings #-}

module StepSpec (tests) where

import Data.List (isPrefixOf, nub)
import qualified Data.List.NonEmpty as NonEmpty
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Lift (localContext)
import HostBootstrap.Step
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "StepSpec"
        [ testGroup "stepKindName" kindNameCases
        , testGroup "project step identities" projectIdentityCases
        , testGroup "named core step identities" namedCoreIdentityCases
        , testGroup "renderStep / renderChainPlan" renderCases
        , testGroup "frame segmentation" frameCases
        , testGroup "stable implementation identities" implementationIdentityCases
        , testGroup "plan validation" validationCases
        , testGroup "projected operations" projectionCases
        , testGroup "provider resource declarations" providerDeclarationCases
        , testGroup "step observations" observationCases
        ]

providerDeclarationCases :: [TestTree]
providerDeclarationCases =
    [ testCase "duplicate provider declarations are retained and refused" $ do
        let step =
                declaresProviderResource providerResourceAtCurrentFrame $
                    declaresProviderResource providerResourceAtCurrentFrame $
                        deployVMStep "provider" metal noop
        case mkStepPlan [step] of
            Left failure -> failure @?= DuplicateProviderResourceDeclaration (CoreStepIdentity DeployVMId) 2
            Right _ -> assertFailure "duplicate provider declarations were admitted"
    , testCase "an immediate-child provider requires one validated descent" $
        case mkStepPlan
            [ declaresProviderResource
                providerResourceAtImmediateChild
                (deployVMStep "provider" metal noop)
            ] of
            Left failure -> failure @?= ProviderResourceChildWithoutUniqueDescent (CoreStepIdentity DeployVMId)
            Right _ -> assertFailure "an immediate-child provider without a descent was admitted"
    ]

{- | A node's __projected__ operations (§ CC).

A relating resource's operation key is derived from the keys it relates, so it
is nobody's own key. The plan is where a node claims one. Validation requires the
claiming node to be the /last/ resource the key names, with every earlier one in
its own dependency prefix — which is what makes the relation performable — and
requires the claim to be unique across the plan.
-}
projectionCases :: [TestTree]
projectionCases =
    [ testCase "a core tool name cannot extend another operation key" $
        assertPlanRefusal
            (InvalidCoreStepName (CoreStepIdentity (EnsureToolId "z/core:copy-source")))
            [ensureStep "z/core:copy-source" "ensure" metal noop]
    , testCase "a step declares nothing by default and keeps what it declares, in order" $ do
        map operationKeyText (stepProjectedOperations (copySourceStep "b" metal noop)) @?= []
        let declared =
                projectsOperation "core:deploy-vm/core:copy-source/guest-alias" $
                    projectsOperation "core:copy-source/warm-cache" $
                        copySourceStep "b" metal noop
        map operationKeyText (stepProjectedOperations declared)
            @?= ["core:copy-source/warm-cache", "core:deploy-vm/core:copy-source/guest-alias"]
    , testCase "a validated plan carries each node's declared projections" $ do
        plan <- either (assertFailure . show) pure (mkStepPlan aliasProjectionSteps)
        map (map operationKeyText . stepProjectedOperations) (NonEmpty.toList (stepPlanSteps plan))
            @?= [[], ["core:deploy-vm/core:copy-source/guest-alias"]]
    , testCase "the declaring node is the last resource the key names" $ do
        let refuse steps expected =
                case mkStepPlan steps of
                    Left err -> err @?= expected
                    Right _ -> assertFailure "a projection outside its node was validated"
        -- the provider node cannot claim it: the share is not behind it
        refuse
            [ projectsOperation
                "core:deploy-vm/core:copy-source/guest-alias"
                (deployVMStep "a" metal noop)
            , copySourceStep "b" metal noop
            ]
            ( ProjectionOutsideStep
                (CoreStepIdentity DeployVMId)
                "core:deploy-vm/core:copy-source/guest-alias"
            )
        -- a resource named before the node must be one the plan ordered ahead
        refuse
            [ copySourceStep "b" metal noop
            , projectsOperation "core:build-image/core:build-pb/x" (buildPbStep "c" metal noop)
            ]
            ( ProjectionOutsideStep
                (CoreStepIdentity BuildPbId)
                "core:build-image/core:build-pb/x"
            )
        -- another node's key alone is not this node's projection
        refuse
            [ deployVMStep "a" metal noop
            , projectsOperation "core:deploy-vm/guest-alias" (copySourceStep "b" metal noop)
            ]
            (ProjectionOutsideStep (CoreStepIdentity CopySourceId) "core:deploy-vm/guest-alias")
        -- the node's own key with nothing under it is not a projection
        refuse
            [projectsOperation "core:copy-source" (copySourceStep "b" metal noop)]
            (ProjectionOutsideStep (CoreStepIdentity CopySourceId) "core:copy-source")
        refuse
            [projectsOperation "core:copy-source/" (copySourceStep "b" metal noop)]
            (ProjectionOutsideStep (CoreStepIdentity CopySourceId) "core:copy-source/")
        -- a shared textual stem is not the same node
        refuse
            [projectsOperation "core:copy-source-extra/guest-alias" (copySourceStep "b" metal noop)]
            ( ProjectionOutsideStep
                (CoreStepIdentity CopySourceId)
                "core:copy-source-extra/guest-alias"
            )
    , testCase "a projected operation is claimed exactly once in the plan" $
        case mkStepPlan
            [ projectsOperation
                "core:copy-source/alias"
                (projectsOperation "core:copy-source/alias" (copySourceStep "b" metal noop))
            ] of
            Left err -> err @?= DuplicateProjectedOperation "core:copy-source/alias"
            Right _ -> assertFailure "one node claiming a projection twice was validated"
    , testCase "a suffixed tool name cannot impersonate its valid projected operation" $ do
        let declared =
                projectsOperation
                    "core:ensure-docker/warm"
                    (ensureStep "docker" "ensure docker" metal noop)
        valid <- either (assertFailure . show) pure (mkStepPlan [declared])
        map (map operationKeyText . stepProjectedOperations) (NonEmpty.toList (stepPlanSteps valid))
            @?= [["core:ensure-docker/warm"]]
        assertPlanRefusal
            (InvalidCoreStepName (CoreStepIdentity (EnsureToolId "docker/warm")))
            [ declared
            , ensureStep "docker/warm" "ensure the warm store" metal noop
            ]
    ]

{- | The shape the guest alias needs: the provider, then the durable share that
claims the relation between them.
-}
aliasProjectionSteps :: [Step]
aliasProjectionSteps =
    [ deployVMStep "launch the VM" metal noop
    , projectsOperation
        "core:deploy-vm/core:copy-source/guest-alias"
        (copySourceStep "stage source into the VM" metal noop)
    ]

{- | What a step's action reports about its own node. Every returned category
remains distinct through rendering and higher-level classification.
-}
observationCases :: [TestTree]
observationCases =
    [ testCase "reaching the target state is a success; not reaching it is not" $ do
        map observationSucceeded [StepUnchanged, StepChanged] @?= [True, True]
        map
            observationSucceeded
            [ StepConflict "a" "b" "c"
            , StepUnsupported "no backend"
            , StepRefused "pre-existing state"
            ]
            @?= [False, False, False]
    , testCase "each outcome renders a distinct row, not one undifferentiated failure" $ do
        let rows =
                map
                    observationDetail
                    [ StepUnchanged
                    , StepChanged
                    , StepConflict "the run's VM" "a foreign VM" "delete it or rename the project"
                    , StepUnsupported "bare Linux has no storage quota"
                    , StepRefused "the cluster holds state this run does not own"
                    ]
        length (nub rows) @?= length rows
        rows
            @?= [ "unchanged"
                , "changed"
                , "conflict: expected the run's VM, observed a foreign VM; delete it or rename the project"
                , "unsupported: bare Linux has no storage quota"
                , "refused: the cluster holds state this run does not own"
                ]
    , testCase "the step algebra owns its observation markers below the harness" $ do
        [conflictObservationMarker, unsupportedObservationMarker, refusedObservationMarker]
            @?= ["conflict:", "unsupported:", "refused:"]
        cwd <- getCurrentDirectory
        root <-
            findRepoRoot cwd
                >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let packageRoot = root </> "core" </> "hostbootstrap-core"
        description <- SourceGuard.readPackageDescription
        sourcePath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Step"
        source <- readFile sourcePath
        -- Token-level: a qualified, aliased, or SOURCE import is still an import, and a
        -- commented or quoted mention is not one.
        let harnessImports = [name | name <- SourceGuard.haskellImports source, isHarnessModule name]
            isHarnessModule name = name == "HostBootstrap.Harness" || "HostBootstrap.Harness." `isPrefixOf` name
        harnessImports @?= []
        SourceGuard.haskellImports "import qualified HostBootstrap.Harness.GeneratedConfig as G\n"
            @?= ["HostBootstrap.Harness.GeneratedConfig"]
        SourceGuard.haskellImports "import {-# SOURCE #-} HostBootstrap.Harness\n"
            @?= ["HostBootstrap.Harness"]
        assertBool
            "the lower Step module imports the higher Harness module"
            (not (any isHarnessModule (SourceGuard.haskellImports source)))
    ]

-- Fixtures: frames and a representative chain interleaving host and project steps.
metal :: StepFrame
metal = StepFrame{frameId = "host-orchestrator-0", frameLabel = "metal"}

vmFrame :: StepFrame
vmFrame = StepFrame{frameId = "vm-orchestrator-1", frameLabel = "VM"}

ctrFrame :: StepFrame
ctrFrame = StepFrame{frameId = "vm-project-container-2", frameLabel = "container"}

noop :: a -> IO StepObservation
noop _ = pure StepChanged

implementationIdentityCases :: [TestTree]
implementationIdentityCases =
    [ testCase "every constructor starts at explicit revision one" $
        map
            ( \step ->
                ( stepImplementationRevisionNumber (stepImplementationRevision step)
                , stepReverseAdapterRevisionNumber (stepReverseAdapterRevision step)
                )
            )
            [ deployVMStep "provider" metal noop
            , ensureStep "ghc" "tool" metal noop
            , copySourceStep "source" metal noop
            , buildPbStep "binary" metal noop
            , buildImageStep "image" metal noop
            , contextInitStep "context" metal noop
            , deployKindStep "cluster" metal noop
            , deployChartStep "chart" metal noop
            , exposePortStep "port" metal noop
            , postHandoffStep "hook" "hook" metal noop
            , projectStep (fixtureProjectStepId "project-node") ProjectManagedReverse "project" metal noop
            ]
            @?= replicate 11 (1, 1)
    , testCase "forward and reverse revisions are independently replaceable" $ do
        let implementation = either error id (mkStepImplementationRevision 2)
            reverseAdapter = either error id (mkStepReverseAdapterRevision 3)
            step = reverseAdapterAt reverseAdapter (implementedAt implementation (deployKindStep "cluster" metal noop))
        stepImplementationRevisionNumber (stepImplementationRevision step) @?= 2
        stepReverseAdapterRevisionNumber (stepReverseAdapterRevision step) @?= 3
    , testCase "attaching a reverse effect preserves an already declared adapter revision" $ do
        let revision = either error id (mkStepReverseAdapterRevision 3)
            noReverse _ _ = pure TeardownReleased
            step = deployVMStep "provider" metal noop
            decorated =
                [ reversedBy noReverse (reverseAdapterAt revision step)
                , reverseAdapterAt revision (reversedBy noReverse step)
                ]
        map (stepReverseAdapterRevisionNumber . stepReverseAdapterRevision) decorated @?= [3, 3]
        map (length . stepReverses) decorated @?= [1, 1]
    , testCase "an explicitly named reverse-effect revision replaces the existing revision" $ do
        let initialRevision = either error id (mkStepReverseAdapterRevision 3)
            replacementRevision = either error id (mkStepReverseAdapterRevision 5)
            noReverse _ _ = pure TeardownReleased
            step =
                reversedByAt replacementRevision noReverse $
                    reverseAdapterAt initialRevision (deployVMStep "provider" metal noop)
        stepReverseAdapterRevisionNumber (stepReverseAdapterRevision step) @?= 5
        length (stepReverses step) @?= 1
    , testCase "revision zero is outside the closed vocabulary" $ do
        case mkStepImplementationRevision 0 of
            Left _ -> pure ()
            Right _ -> assertFailure "accepted forward implementation revision zero"
        case mkStepReverseAdapterRevision 0 of
            Left _ -> pure ()
            Right _ -> assertFailure "accepted reverse-adapter revision zero"
    ]

projectIdentityCases :: [TestTree]
projectIdentityCases =
    [ testCase "an empty project identity is refused" $
        projectStepId "" @?= Left "project step identity must not be empty"
    , testCase "a path separator is outside a project identity" $
        projectStepId "a/b" @?= Left ("project step identity is not a stable token: " ++ show ("a/b" :: String))
    , testCase "a namespace separator is outside a project identity" $
        projectStepId "a:b" @?= Left ("project step identity is not a stable token: " ++ show ("a:b" :: String))
    , testCase "a non-ASCII character is outside a project identity" $
        projectStepId "é" @?= Left ("project step identity is not a stable token: " ++ show ("é" :: String))
    ]

namedCoreIdentityCases :: [TestTree]
namedCoreIdentityCases =
    [ testCase "an empty core tool name is refused" $
        assertPlanRefusal
            (InvalidCoreStepName (CoreStepIdentity (EnsureToolId "")))
            [ensureStep "" "ensure" metal noop]
    , testCase "an empty post-handoff name is refused after a valid normal node" $
        assertPlanRefusal
            (InvalidCoreStepName (CoreStepIdentity (PostHandoffId "")))
            [ deployVMStep "provider" metal noop
            , postHandoffStep "" "hook" metal noop
            ]
    , testCase "a ghc tool name still validates" $ do
        plan <- either (assertFailure . show) pure (mkStepPlan [ensureStep "ghc" "ensure" metal noop])
        map (operationKeyText . stepOperationKey) (NonEmpty.toList (stepPlanSteps plan)) @?= ["core:ensure-ghc"]
    , testCase "tool and post-handoff names share the project identity ASCII alphabet" $
        mapM_ checkCharacter tokenCharacters
    , testCase "existing frame and label refusals precede core name validation" $ do
        assertPlanRefusal
            (EmptyFrameId 1)
            [ensureStep "bad/name" "ensure" (StepFrame "" "empty") noop]
        assertPlanRefusal
            (EmptyStepLabel 1)
            [ensureStep "bad/name" "" metal noop]
        assertPlanRefusal
            (ConflictingFrameLabels "host-orchestrator-0" ["metal", "other"])
            [ ensureStep "bad/name" "ensure" metal noop
            , copySourceStep "source" (metal{frameLabel = "other"}) noop
            ]
    ]
  where
    tokenCharacters =
        [ ('-', True)
        , ('_', True)
        , ('.', True)
        , ('0', True)
        , ('9', True)
        , ('A', True)
        , ('Z', True)
        , ('a', True)
        , ('z', True)
        , ('/', False)
        , (':', False)
        , (' ', False)
        , ('\t', False)
        , ('\n', False)
        , ('é', False)
        ]
    checkCharacter (character, admitted) = do
        let name = ['a', character, 'b']
            tool = ensureStep name "ensure" metal noop
            hook = postHandoffStep name "hook" metal noop
        if admitted
            then do
                toolPlan <- either (assertFailure . show) pure (mkStepPlan [tool])
                map (operationKeyText . stepOperationKey) (NonEmpty.toList (stepPlanSteps toolPlan)) @?= ["core:ensure-" ++ name]
                hookPlan <- either (assertFailure . show) pure (mkStepPlan [deployVMStep "provider" metal noop, hook])
                map (operationKeyText . stepOperationKey) (NonEmpty.toList (stepPlanSteps hookPlan)) @?= ["core:deploy-vm", "core:post-handoff-" ++ name]
            else do
                assertPlanRefusal (InvalidCoreStepName (CoreStepIdentity (EnsureToolId name))) [tool]
                assertPlanRefusal
                    (InvalidCoreStepName (CoreStepIdentity (PostHandoffId name)))
                    [deployVMStep "provider" metal noop, hook]

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
    [ testCase "NonEmpty.toList (chainFrames lists) the descent frames in first-appearance order" $
        map frameId (NonEmpty.toList (chainFrames demoPlan))
            @?= ["host-orchestrator-0", "vm-orchestrator-1", "vm-project-container-2"]
    , testCase "stepsForFrame selects exactly this frame's steps in order" $
        map stepLabel (stepsForFrame "vm-project-container-2" demoPlan)
            @?= ["bring up kind", "install harbor", "expose the NodePort"]
    , testCase "post-handoff hooks are not part of the pre-handoff segment" $ do
        map stepLabel (preHandoffStepsForFrame "host-orchestrator-0" demoPlan)
            @?= ["launch the VM", "stage source into the VM", "ensure GHC in the VM", "build the binary in the VM"]
        map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" demoPlan)
            @?= ["start the host accelerator daemon"]
    , testCase "the post-handoff classifier covers every core and project constructor" $
        map
            (\step -> (stepIdentity step, isPostHandoffStep step))
            [ deployVMStep "provider" metal noop
            , ensureStep "ghc" "tool" metal noop
            , copySourceStep "source" metal noop
            , buildPbStep "binary" metal noop
            , buildImageStep "image" metal noop
            , contextInitStep "context" metal noop
            , deployKindStep "cluster" metal noop
            , deployChartStep "chart" metal noop
            , exposePortStep "port" metal noop
            , postHandoffStep "hook" "hook" metal noop
            , projectStep (fixtureProjectStepId "project-node") ProjectManagedReverse "project" metal noop
            ]
            @?= [ (CoreStepIdentity DeployVMId, False)
                , (CoreStepIdentity (EnsureToolId "ghc"), False)
                , (CoreStepIdentity CopySourceId, False)
                , (CoreStepIdentity BuildPbId, False)
                , (CoreStepIdentity BuildImageId, False)
                , (CoreStepIdentity ContextInitId, False)
                , (CoreStepIdentity DeployKindId, False)
                , (CoreStepIdentity DeployChartId, False)
                , (CoreStepIdentity ExposePortId, False)
                , (CoreStepIdentity (PostHandoffId "hook"), True)
                , (ProjectStepIdentity (fixtureProjectStepId "project-node"), False)
                ]
    , testCase "stepsForFrame is empty for a frame the chain never enters" $
        map stepLabel (stepsForFrame "no-such-frame" demoPlan) @?= []
    , testCase "a non-contiguous frame return is rejected without reordering" $
        case mkStepPlan
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
    , testCase "an empty frame identity reports its exact step position" $
        assertPlanRefusal
            (EmptyFrameId 1)
            [deployVMStep "provider" (StepFrame "" "empty frame") noop]
    , testCase "an empty step label reports its exact step position" $
        assertPlanRefusal (EmptyStepLabel 1) [deployVMStep "" metal noop]
    , testCase "one semantic frame cannot carry conflicting presentation labels" $
        assertPlanRefusal
            (ConflictingFrameLabels "host-orchestrator-0" ["metal", "other"])
            [ deployVMStep "provider" metal noop
            , copySourceStep "source" (metal{frameLabel = "other"}) noop
            ]
    , testCase "a post-handoff hook reports an undeclared frame and its exact position" $
        assertPlanRefusal
            (PostHandoffForUnknownFrame 2 "vm-orchestrator-1")
            [ deployVMStep "provider" metal noop
            , postHandoffStep "unknown-frame" "late hook" vmFrame noop
            ]
    , testCase "duplicate typed identities are rejected" $
        case mkStepPlan
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
        map stepKindName (map stepKind (NonEmpty.toList (stepPlanSteps plan)))
            @?= ["context-init", "context-init"]
        case NonEmpty.toList (stepPlanSteps plan) of
            [coreContextInit, projectContextInit'] ->
                assertBool
                    "typed identities differ"
                    (stepIdentity coreContextInit /= stepIdentity projectContextInit')
            actual -> assertFailure ("expected two validated steps, got " ++ show (length actual))
    , testCase "post-handoff hooks form only a final suffix" $
        case mkStepPlan
            [ postHandoffStep "late" "late hook" metal noop
            , projectStep (fixtureProjectStepId "after-hook") ProjectManagedReverse "normal" metal noop
            ] of
            Left err -> err @?= PostHandoffBeforeDescentComplete 2
            other -> assertFailure ("expected post-handoff ordering rejection, got " ++ either show (const "validated") other)
    , testCase "post-handoff hooks unwind from deeper frames toward the root" $ do
        let normal =
                [ descendsVia localContext (deployVMStep "outer" metal noop)
                , contextInitStep "inner" vmFrame noop
                ]
            deepestFirst =
                normal
                    ++ [ postHandoffStep "inner-hook" "after inner" vmFrame noop
                       , postHandoffStep "outer-hook" "after outer" metal noop
                       ]
            outerFirst =
                normal
                    ++ [ postHandoffStep "outer-hook" "after outer" metal noop
                       , postHandoffStep "inner-hook" "after inner" vmFrame noop
                       ]
        case mkStepPlan deepestFirst of
            Left err -> assertFailure ("deepest-to-root post-handoff order was rejected: " ++ show err)
            Right _ -> pure ()
        case mkStepPlan outerFirst of
            Left err ->
                err
                    @?= PostHandoffOutOfDescentOrder
                        4
                        "host-orchestrator-0"
                        "vm-orchestrator-1"
            Right _ -> assertFailure "root-to-deepest post-handoff order was validated"
    , testCase "every smart constructor retains an explicit reverse policy" $
        map
            stepReversePolicy
            [ ensureStep "ghc" "ensure" metal noop
            , deployVMStep "deploy" vmFrame noop
            , copySourceStep "source" vmFrame noop
            , buildPbStep "binary" vmFrame noop
            , buildImageStep "image" vmFrame noop
            , contextInitStep "context" vmFrame noop
            , deployKindStep "cluster" ctrFrame noop
            , deployChartStep "chart" ctrFrame noop
            , exposePortStep "port" ctrFrame noop
            , postHandoffStep "hook" "hook" metal noop
            , projectStep (fixtureProjectStepId "mutate") ProjectManagedReverse "mutate" ctrFrame noop
            ]
            @?= [ PreserveOnReverse
                , ProjectManagedReverse
                , ProjectManagedReverse
                , ProjectManagedReverse
                , ProjectManagedReverse
                , ProjectManagedReverse
                , CoreManagedReverse
                , CoreManagedReverse
                , CoreManagedReverse
                , ProjectManagedReverse
                , ProjectManagedReverse
                ]
    , testCase "a frame that descends into another must declare exactly one descent" $ do
        case mkStepPlan [deployVMStep "a" metal noop, contextInitStep "b" vmFrame noop] of
            Left err -> err @?= MissingFrameDescent "host-orchestrator-0"
            Right _ -> assertFailure "a frame with a successor and no descent was validated"
        case mkStepPlan
            [ descendsVia localContext (deployVMStep "a" metal noop)
            , descendsVia localContext (copySourceStep "a2" metal noop)
            , contextInitStep "b" vmFrame noop
            ] of
            Left err -> err @?= DuplicateFrameDescent "host-orchestrator-0" 2
            Right _ -> assertFailure "two descents out of one frame were validated"
        case mkStepPlan
            [ descendsVia localContext (descendsVia localContext (deployVMStep "a" metal noop))
            , contextInitStep "b" vmFrame noop
            ] of
            Left err -> err @?= DuplicateFrameDescent "host-orchestrator-0" 2
            Right _ -> assertFailure "a step declaring two descents was validated"
    , testCase "the innermost frame and post-handoff hooks declare no descent" $ do
        case mkStepPlan
            [ descendsVia localContext (deployVMStep "a" metal noop)
            , descendsVia localContext (contextInitStep "b" vmFrame noop)
            ] of
            Left err -> err @?= DescentFromInnermostFrame "vm-orchestrator-1"
            Right _ -> assertFailure "a descent out of the innermost frame was validated"
        case mkStepPlan
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
    , testCase "a project-managed node may declare no reverse effect" $ do
        plan <- either (assertFailure . show) pure (mkStepPlan [deployVMStep "a" metal noop])
        let steps = NonEmpty.toList (stepPlanSteps plan)
        map stepReversePolicy steps @?= [ProjectManagedReverse]
        map (length . stepReverses) steps @?= [0]
    , testCase "validated plans derive one operation key and exact dependency prefix per step" $ do
        let steps = NonEmpty.toList (stepPlanSteps demoPlan)
            keys = map (operationKeyText . stepOperationKey) steps
        assertBool "operation keys are non-empty" (all (not . null) keys)
        assertBool "operation keys are unique" (and [left /= right | (index, left) <- zip [0 :: Int ..] keys, right <- drop (index + 1) keys])
        map (stepDependencies demoPlan) steps
            @?= [take index (map stepIdentity steps) | index <- [0 .. length steps - 1]]
    ]
  where
    duplicateId = fixtureProjectStepId "duplicate"

assertPlanRefusal :: StepPlanError -> [Step] -> IO ()
assertPlanRefusal expected steps = case mkStepPlan steps of
    Left failure -> failure @?= expected
    Right _ -> assertFailure ("expected plan refusal " ++ show expected ++ ", got a validated plan")

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
            map (frameId . stepFrame) (NonEmpty.toList (stepPlanSteps plan)) @?= frameIds
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
