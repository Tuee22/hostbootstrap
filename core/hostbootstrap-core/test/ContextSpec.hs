{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ContextSpec (tests) where

import Control.Exception (finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Fixture
import HostBootstrap.Authority
    ( InstalledProjectIdentity
    , ProjectVerb (ProjectUp)
    , normalizeExecutableIdentity
    , rootScopeAuthority
    )
import HostBootstrap.CLI (
    ProjectSpec,
    addSteps,
    finalizeProjectSpec,
    projectSpec,
 )
import qualified HostBootstrap.CLI as CLI
import qualified HostBootstrap.Config.Schema as Schema
import HostBootstrap.Config.Class
    ( AssemblyRequest (..)
    , ProjectCfg (withProductionProjectCodec)
    , pureConfigAssembly
    )
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context
import HostBootstrap.Harness (Case (Case), CaseResult (Pass), TestSuite (TestSuite), mkCaseId)
import HostBootstrap.Lifecycle.Mode
    ( ModeError (ModeAuthorityFailure)
    , productionActiveMode
    , productionRootAuthority
    , productionRootModeLease
    , productionRootUnboundLease
    , withProductionLifecycleProfile
    , withProductionRoot
    )
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , planDraftsFromValidatedBuilder
    )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectPlan.Frame
    ( FrameError (..)
    , currentFrameId
    , projectFrameId
    , validatedContextValue
    , withCurrentFrame
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    , withCanonicalProjectRoot
    )
import HostBootstrap.Protected
    ( ProtectedRecord
    , ProtectedStore
    , listProtectedRecords
    , openProtectedStore
    , readProtectedRecord
    , recordKeyText
    , withProtectedEntry
    )
import HostBootstrap.Step
    ( StepFrame (StepFrame)
    , StepObservation (StepChanged)
    , Step
    , StepPlan
    , buildImageStep
    , contextInitStep
    , deployVMStep
    , descendsVia
    , ensureStep
    , mkStepPlan
    )
import System.Directory (removeFile)
import System.Environment (getExecutablePath, withArgs)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

sampleContext :: BinaryContext
sampleContext =
    BinaryContext
        { project = "demo"
        , binary = "demo"
        , sourceRoot = "/workspace/demo"
        , contextKind = VMProjectContainer
        , roleName = "vm-project-container"
        , parentChain =
            [ ContextFrame{frameKind = HostOrchestrator, frameBinary = "demo"}
            , ContextFrame{frameKind = VMOrchestrator, frameBinary = "demo"}
            ]
        , topologyFrames =
            [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
            , TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" LimaVMProvider VMOrchestrator "vm-orchestrator"
            , TopologyFrame "vm-project-container-2" "vm-orchestrator-1" DockerContainerProvider VMProjectContainer "vm-project-container"
            ]
        , currentFrame = "vm-project-container-2"
        , -- exactly the set the VM-backed project-container placement requires
          -- (§ 15.9); an empty list is no longer a context that validates.
          runtimeWitnesses =
            [ RuntimeWitness WitnessUnixSocket "/var/run/docker.sock" ""
            , RuntimeWitness WitnessFileExists "/run/hostbootstrap/vm-provider" ""
            , RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" "vm-project-container-2"
            ]
        , capabilities = [DockerSocket, ContainerRuntime, KindNetwork]
        , allowedCommandClasses = [TestWorkflowCommand, CheckCodeCommand, ConfigGenerationCommand]
        , childContextKinds = [ClusterService]
        }

testRequirement :: ContextRequirement
testRequirement =
    ContextRequirement
        { requiredProject = "demo"
        , requiredBinary = "demo"
        , requiredCommandClass = TestWorkflowCommand
        , requiredCapabilities = [DockerSocket, KindNetwork]
        }

{- | A fixture-backed project spec for the CLI-driving tests: the init builders
write/read a concrete 'Fixture.ProjectConfig' shape (so a written config
decodes back), and the suite is a trivial passing one (these tests never run
@test run@).
-}
fixtureSpec ::
    String ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
fixtureSpec progName =
    either (error . show) id $
        finalizeProjectSpec $
            addSteps
                (\_ _ -> [deployVMStep "fixture step" (StepFrame "host-orchestrator-0" "metal") (const (pure StepChanged))])
                    ( projectSpec
                            passingSuite
                            (pure ())
                            []
                            Fixture.testConfigCodec
                            (const (Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB")))
                            ( \request ->
                                case request of
                                    ProductionAssembly args ->
                                        pureConfigAssembly (Fixture.projectInit (T.pack progName) args)
                                    HarnessAssembly _ _ _ ->
                                        pureConfigAssembly
                                            ( Fixture.defaultProjectConfig
                                                (T.pack progName)
                                                "/workspace/demo"
                                                HostOrchestrator
                                            )
                            )
                    )

runHostBootstrapCLI ::
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig ->
    IO ()
runHostBootstrapCLI spec = do
    projectName <- executableProjectName
    CLI.runHostBootstrapCLI (T.unpack projectName) spec

runBareHostBootstrapCLI :: IO ()
runBareHostBootstrapCLI = do
    projectName <- executableProjectName
    CLI.runBareHostBootstrapCLI (T.unpack projectName)

executableProjectName :: IO T.Text
executableProjectName = normalizeExecutableIdentity <$> getExecutablePath

passingSuite :: TestSuite
passingSuite =
    TestSuite (pure (Right ())) (\_ -> pure ()) [Case (either (error . show) id (mkCaseId "ok")) 1 False] (\_ _ -> pure Pass) (pure ())

tests :: TestTree
tests =
    testGroup
        "ContextSpec"
        [ testCase "rendered context decodes back to the same value" $ do
            decoded <- decodeContextText (renderContext sampleContext)
            decoded @?= sampleContext
        , testCase "renderComposition renders the lift chain with the current frame highlighted" $
            renderComposition sampleContext
                @?= unlines
                    [ "composition (3 frames; current = vm-project-container-2):"
                    , "   . host-orchestrator-0  [HostProvider / HostOrchestrator]"
                    , "   . vm-orchestrator-1  [LimaVMProvider / VMOrchestrator]  (parent: host-orchestrator-0)"
                    , "  -> vm-project-container-2  [DockerContainerProvider / VMProjectContainer]  (parent: vm-orchestrator-1)"
                    ]
        , testCase "projectConfigPathForExecutable uses the executable directory" $ do
            let exe = "/tmp/bin/demo"
            Schema.projectConfigPathForExecutable "demo" exe @?= takeDirectory exe </> "demo.dhall"
        , testCase "readContextFile reports a missing file" $
            withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
                let path = dir </> "context.dhall"
                loaded <- readContextFile path
                loaded @?= Left (ContextMissing path)
        , testCase "readContextFile reports a decode failure" $
            withContextFile "not a dhall record" $ \path -> do
                loaded <- readContextFile path
                case loaded of
                    Left (ContextDecodeFailed failedPath msg) -> do
                        failedPath @?= path
                        assertBool "decode error names the bad input" (not (null msg))
                    other -> assertFailure ("expected ContextDecodeFailed, got " ++ show other)
        , testCase "validateContext accepts a matching command context" $
            validateContext testRequirement sampleContext @?= Right sampleContext
        , testCase "validateContext rejects a project mismatch" $
            validateContext testRequirement{requiredProject = "other"} sampleContext
                @?= Left (ContextProjectMismatch "other" "demo")
        , testCase "validateContext rejects a binary mismatch" $
            validateContext testRequirement{requiredBinary = "other"} sampleContext
                @?= Left (ContextBinaryMismatch "other" "demo")
        , testCase "validateContext rejects a command not allowed in this context" $
            validateContext testRequirement{requiredCommandClass = HostOrchestratorCommand} sampleContext
                @?= Left (ContextCommandNotAllowed HostOrchestratorCommand VMProjectContainer)
        , testCase "validateContext rejects a missing capability" $
            validateContext testRequirement{requiredCapabilities = [KubernetesAPI]} sampleContext
                @?= Left (ContextCapabilityMissing KubernetesAPI)
        , testCase "hostOrchestratorContext records host capabilities and child context rules" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
            contextKind host @?= HostOrchestrator
            roleName host @?= "host-orchestrator"
            capabilities host @?= [HostTools, IncusProvider]
            childContextKinds host @?= [VMOrchestrator, ClusterService, Daemon, OneShotJob, TestHarness]
        , testCase "a cyclic parent chain is refused instead of diverging" $ do
            -- The ancestor walk follows topologyParentId with no memory of
            -- where it has been, so before the total validator a config whose
            -- frames name each other as parents looped forever. This case is
            -- the regression guard: it must terminate with a refusal.
            let cyclic =
                    sampleContext
                        { topologyFrames =
                            [ TopologyFrame "a" "b" HostProvider HostOrchestrator "a"
                            , TopologyFrame "b" "a" HostProvider VMOrchestrator "b"
                            ]
                        , currentFrame = "a"
                        , contextKind = HostOrchestrator
                        , parentChain = []
                        }
            case validateTopology cyclic of
                Left (ContextTopologyRootCount 0) -> pure ()
                Left (ContextTopologyCycle _) -> pure ()
                other -> assertFailure ("expected a cycle refusal, got " ++ show other)
        , testCase "a cycle below a real root is refused, not walked forever" $ do
            let cyclic =
                    sampleContext
                        { topologyFrames =
                            [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                            , TopologyFrame "x" "y" LimaVMProvider VMOrchestrator "x"
                            , TopologyFrame "y" "x" LimaVMProvider VMOrchestrator "y"
                            ]
                        , currentFrame = "host-orchestrator-0"
                        , contextKind = HostOrchestrator
                        , parentChain = []
                        }
            case validateTopology cyclic of
                Left (ContextTopologyCycle _) -> pure ()
                Left (ContextTopologyUnreachable _) -> pure ()
                other -> assertFailure ("expected a cycle refusal, got " ++ show other)
        , testCase "duplicate frame identifiers are refused" $ do
            let duplicated =
                    sampleContext
                        { topologyFrames =
                            topologyFrames sampleContext
                                ++ [TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" LimaVMProvider VMOrchestrator "again"]
                        }
            validateTopology duplicated
                @?= Left (ContextTopologyDuplicateFrame "vm-orchestrator-1")
        , testCase "an empty frame identifier is refused" $ do
            let empty =
                    sampleContext
                        { topologyFrames =
                            TopologyFrame "" "host-orchestrator-0" HostProvider VMOrchestrator "blank"
                                : topologyFrames sampleContext
                        }
            validateTopology empty @?= Left ContextTopologyEmptyFrameId
        , testCase "a topology with two roots is refused" $ do
            let twoRoots =
                    sampleContext
                        { topologyFrames =
                            topologyFrames sampleContext
                                ++ [TopologyFrame "other-root" "" HostProvider HostOrchestrator "other"]
                        }
            validateTopology twoRoots @?= Left (ContextTopologyRootCount 2)
        , testCase "an unreachable frame is refused" $ do
            let orphaned =
                    sampleContext
                        { topologyFrames =
                            topologyFrames sampleContext
                                ++ [ TopologyFrame "island-a" "island-b" HostProvider ClusterService "a"
                                   , TopologyFrame "island-b" "island-a" HostProvider ClusterService "b"
                                   ]
                        }
            case validateTopology orphaned of
                Left (ContextTopologyCycle _) -> pure ()
                Left (ContextTopologyUnreachable _) -> pure ()
                other -> assertFailure ("expected an unreachable/cycle refusal, got " ++ show other)
        , testCase "an illegal child kind is refused" $ do
            let illegal =
                    sampleContext
                        { topologyFrames =
                            topologyFrames sampleContext
                                ++ [TopologyFrame "build-3" "vm-project-container-2" DockerContainerProvider ImageBuildContainer "build"]
                        }
            validateTopology illegal
                @?= Left
                    ( ContextTopologyIllegalChild
                        "build-3"
                        VMProjectContainer
                        ImageBuildContainer
                    )
        , testCase "a parentChain that disagrees with the edges is refused" $ do
            let lying =
                    sampleContext
                        { parentChain =
                            [ContextFrame{frameKind = HostOrchestrator, frameBinary = "demo"}]
                        }
            case validateTopology lying of
                Left (ContextParentChainMismatch declared derived) -> do
                    declared @?= [HostOrchestrator]
                    derived @?= [HostOrchestrator, VMOrchestrator]
                other ->
                    assertFailure ("expected a parentChain mismatch, got " ++ show other)
        , testCase "the well-formed demo topology validates" $
            validateTopology sampleContext @?= Right ()
        , testCase "a non-leaf primary cannot union service-run authority" $ do
            -- The former behaviour unioned any role into any primary, so an
            -- operator could name an extra role and self-grant authority the
            -- placement cannot hold (§ 15.9).
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
            case addRole ClusterService host of
                Left (ContextRoleAdditionRefused HostOrchestrator ClusterService) -> pure ()
                other ->
                    assertFailure
                        ("expected a refused role addition, got " ++ show (fmap contextKind other))
        , testCase "a daemon primary cannot union project or host-orchestrator authority" $ do
            let daemon =
                    contextForKind "demo" "demo" "/workspace/demo" Daemon
            case addRole HostOrchestrator daemon of
                Left (ContextRoleAdditionRefused Daemon HostOrchestrator) -> pure ()
                other ->
                    assertFailure
                        ("expected a refused role addition, got " ++ show (fmap contextKind other))
            -- and the daemon still cannot run project lifecycle verbs
            case addRole HostOrchestrator daemon of
                Right granted ->
                    assertBool
                        "a refused addition must not grant ProjectCommand"
                        (not (commandAllowed granted ProjectCommand))
                Left _ -> pure ()
        , testCase "an image-build container cannot union cluster-lifecycle authority" $ do
            let build =
                    contextForKind "demo" "demo" "/workspace/demo" ImageBuildContainer
            case addRole VMProjectContainer build of
                Left (ContextRoleAdditionRefused ImageBuildContainer VMProjectContainer) -> pure ()
                other ->
                    assertFailure
                        ("expected a refused role addition, got " ++ show (fmap contextKind other))
        , testCase "a leaf service placement may also serve another service role" $ do
            let service =
                    contextForKind "demo" "demo" "/workspace/demo" ClusterService
            case addRole Daemon service of
                Right dual -> do
                    contextKind dual @?= ClusterService
                    commandAllowed dual ServiceCommand @?= True
                    commandAllowed dual DaemonCommand @?= True
                    commandAllowed dual ProjectCommand @?= False
                Left err ->
                    assertFailure ("expected a permitted role addition, got " ++ show err)
        , testCase "adding the primary's own role is an identity" $ do
            let service =
                    contextForKind "demo" "demo" "/workspace/demo" ClusterService
            addRole ClusterService service @?= Right service
        , testCase "roleAdditionAllowed is closed over every kind pair" $ do
            let kinds =
                    [ HostOrchestrator
                    , VMOrchestrator
                    , VMProjectContainer
                    , ImageBuildContainer
                    , ClusterService
                    , Daemon
                    , OneShotJob
                    , TestHarness
                    ]
                permitted =
                    [ (primary, role)
                    | primary <- kinds
                    , role <- kinds
                    , roleAdditionAllowed primary role
                    ]
            -- Exactly the leaf-to-leaf service pairs, and nothing else.
            permitted
                @?= [ (ClusterService, ClusterService)
                    , (ClusterService, Daemon)
                    , (Daemon, ClusterService)
                    , (Daemon, Daemon)
                    ]
        , testCase "deriveContainerContext appends the VM frame without duplicating project resources" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                vm = deriveVMContextWithProvider LimaVMProvider host "/vm/demo"
                ctr = deriveContainerContext vm "/workspace/demo"
            contextKind ctr @?= VMProjectContainer
            roleName ctr @?= "vm-project-container"
            parentChain ctr @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"]
            currentFrame ctr @?= "vm-project-container-2"
            topologyFrames ctr
                @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    , TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" LimaVMProvider VMOrchestrator "vm-orchestrator"
                    , TopologyFrame "vm-project-container-2" "vm-orchestrator-1" DockerContainerProvider VMProjectContainer "vm-project-container"
                    ]
            commandAllowed ctr CheckCodeCommand @?= True
            validateContext testRequirement ctr @?= Right ctr
        , testCase "deriveVMContext and deriveServiceContext preserve identity and enforce narrower roles" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                vm = deriveVMContext host "/workspace/demo"
                svc = deriveServiceContext vm "/srv/demo"
            contextKind vm @?= VMOrchestrator
            roleName vm @?= "vm-orchestrator"
            parentChain vm @?= [ContextFrame HostOrchestrator "demo"]
            contextKind svc @?= ClusterService
            roleName svc @?= "cluster-service"
            parentChain svc @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"]
            commandAllowed svc ServiceCommand @?= True
            commandAllowed svc HostOrchestratorCommand @?= False
        , testCase "daemon contexts are leaf service authorities, not project lifecycle authorities" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                daemon = deriveHostDaemonContext host "/workspace/demo"
                serviceReq = contextRequirement "demo" ServiceCommand []
                projectReq = contextRequirement "demo" ClusterLifecycleCommand []
            contextKind daemon @?= Daemon
            roleName daemon @?= "daemon"
            commandAllowed daemon ServiceCommand @?= True
            commandAllowed daemon DaemonCommand @?= True
            commandAllowed daemon ClusterLifecycleCommand @?= False
            validateContext serviceReq daemon @?= Right daemon
            validateContext projectReq daemon @?= Left (ContextCommandNotAllowed ClusterLifecycleCommand Daemon)
        , testCase "daemon placement constructors distinguish host-resident and in-cluster configs" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                vm = deriveVMContextWithProvider LimaVMProvider host "/vm/demo"
                ctr = deriveContainerContext vm "/workspace/demo"
                hostDaemon = deriveHostDaemonContext host "/workspace/daemon"
                clusterDaemon = deriveClusterDaemonContext ctr "/srv/daemon"
            providerOf hostDaemon @?= Just HostProvider
            providerOf clusterDaemon @?= Just KubernetesProvider
            assertBool
                "host daemon has a frame witness"
                (RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" (currentFrame hostDaemon) `elem` runtimeWitnesses hostDaemon)
            assertBool
                "cluster daemon has the service-account witness"
                ( RuntimeWitness WitnessFileExists "/var/run/secrets/kubernetes.io/serviceaccount/token" ""
                    `elem` runtimeWitnesses clusterDaemon
                )
        , testCase "wrong-frame daemon witness fails before daemon dispatch" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                badWitness = RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" "daemon-1"
                daemon = (deriveHostDaemonContext host "/workspace/daemon"){runtimeWitnesses = [badWitness]}
                req = contextRequirement "demo" ServiceCommand []
            result <- validateRuntimeContext req daemon
            case result of
                Left (ContextRuntimeWitnessFailed witness detail) -> do
                    witness @?= badWitness
                    assertBool "env witness reports a frame mismatch" ("environment HOSTBOOTSTRAP_CURRENT_FRAME" `isInfixOfS` detail)
                other -> assertFailure ("expected runtime witness failure, got " ++ show other)
        , testCase "standaloneContainerContext is the Dockerfile bootstrap context" $ do
            let ctr = standaloneContainerContext "demo" "demo" "/workspace/demo"
            contextKind ctr @?= ImageBuildContainer
            roleName ctr @?= "image-build-container"
            parentChain ctr @?= []
            commandAllowed ctr CheckCodeCommand @?= True
            commandAllowed ctr TestWorkflowCommand @?= False
        , testCase "image-build context rejects direct test workflow execution" $ do
            let img = imageBuildContainerContext "demo" "demo" "/workspace/demo"
            validateContext testRequirement img
                @?= Left (ContextCommandNotAllowed TestWorkflowCommand ImageBuildContainer)
        , testCase "standalone VM-project-container config cannot authorize a VM-scoped workflow" $ do
            let ctr =
                    contextForKind
                        "demo"
                        "demo"
                        "/workspace/demo"
                        VMProjectContainer
            validateContext testRequirement ctr
                @?= Left (ContextRequiredAncestorMissing VMProjectContainer VMOrchestrator)
        , testCase "explicit Linux GPU direct project-container context skips only the VM ancestor" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                direct = deriveLinuxGpuContainerContext host "/workspace/demo"
            contextKind direct @?= VMProjectContainer
            roleName direct @?= "linux-gpu-project-container"
            parentChain direct @?= [ContextFrame HostOrchestrator "demo"]
            currentFrame direct @?= "vm-project-container-1"
            topologyFrames direct
                @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    , TopologyFrame "vm-project-container-1" "host-orchestrator-0" DockerContainerProvider VMProjectContainer "linux-gpu-project-container"
                    ]
            assertBool
                "direct topology is explicitly marked Linux GPU"
                (RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_DIRECT_CONTAINER" "linux-gpu" `elem` runtimeWitnesses direct)
            validateContext testRequirement direct @?= Right direct
        , testCase "host-backed project-container that drops the Linux GPU witness is rejected" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                direct = deriveLinuxGpuContainerContext host "/workspace/demo"
                gpuWitness = RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_DIRECT_CONTAINER" "linux-gpu"
                missingExplicitWitness =
                    direct{runtimeWitnesses = filter (/= gpuWitness) (runtimeWitnesses direct)}
            -- The placement is structural, so dropping the witness no longer
            -- changes which lane the frame is in; it makes the declared set
            -- incomplete for that lane.
            validateContext testRequirement missingExplicitWitness
                @?= Left (ContextWitnessSetMismatch [gpuWitness] [])
        , testCase "declaring the Linux GPU witness cannot fabricate the direct placement" $ do
            let host =
                    hostOrchestratorContext
                        "demo"
                        "demo"
                        "/workspace/demo"
                vm = deriveVMContextWithProvider LimaVMProvider host "/vm/demo"
                gpuWitness = RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_DIRECT_CONTAINER" "linux-gpu"
                -- A VM-backed container asserting the direct-lane fact.
                ctr = deriveContainerContext vm "/workspace/demo"
                selfAsserted = ctr{runtimeWitnesses = gpuWitness : runtimeWitnesses ctr}
            isExplicitLinuxGpuContainer selfAsserted @?= False
            validateContext testRequirement selfAsserted
                @?= Left (ContextWitnessSetMismatch [] [gpuWitness])
        , testCase "a placement's required witness set is exact" $ do
            let host = hostOrchestratorContext "demo" "demo" "/workspace/demo"
                vm = deriveVMContextWithProvider LimaVMProvider host "/vm/demo"
                ctr = deriveContainerContext vm "/workspace/demo"
                req = contextRequirement "demo" CheckCodeCommand []
                frameWitness = RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" (currentFrame ctr)
                dockerWitness = RuntimeWitness WitnessUnixSocket "/var/run/docker.sock" ""
            contextPlacement ctr @?= Right VMBackedProjectContainerPlacement
            contextRequiredWitnesses ctr @?= Right (runtimeWitnesses ctr)
            -- omitted
            validateContext req ctr{runtimeWitnesses = filter (/= dockerWitness) (runtimeWitnesses ctr)}
                @?= Left (ContextWitnessSetMismatch [dockerWitness] [])
            -- empty
            case validateContext req ctr{runtimeWitnesses = []} of
                Left (ContextWitnessSetMismatch missing []) -> length missing @?= 3
                other -> assertFailure ("expected a set mismatch, got " ++ show other)
            -- duplicated
            validateContext req ctr{runtimeWitnesses = frameWitness : runtimeWitnesses ctr}
                @?= Left (ContextWitnessDuplicate frameWitness)
            -- contradictory: the same key required to hold two different values
            let contradictory =
                    RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" "somewhere-else"
            validateContext req ctr{runtimeWitnesses = contradictory : runtimeWitnesses ctr}
                @?= Left (ContextWitnessDuplicate contradictory)
            -- irrelevant
            let irrelevant = RuntimeWitness WitnessExecutable "sudo" ""
            validateContext req ctr{runtimeWitnesses = irrelevant : runtimeWitnesses ctr}
                @?= Left (ContextWitnessSetMismatch [] [irrelevant])
        , testCase "a forged leaf config cannot self-declare orchestration authority" $ do
            -- `allowedCommandClasses` is a DECLARED list: `addRole` refuses the
            -- pair, but the bytes on disk are the operator's. The placement the
            -- validated topology derives is what decides (§ X).
            let host = hostOrchestratorContext "demo" "demo" "/workspace/demo"
                daemon = deriveHostDaemonContext host "/workspace/daemon"
                forged =
                    daemon
                        { allowedCommandClasses =
                            allowedCommandClasses daemon
                                ++ [ClusterLifecycleCommand, HostOrchestratorCommand]
                        }
                upReq = contextRequirement "demo" ClusterLifecycleCommand []
                downReq = contextRequirement "demo" HostOrchestratorCommand []
            -- the declared list now says yes
            commandAllowed forged ClusterLifecycleCommand @?= True
            commandAllowed forged HostOrchestratorCommand @?= True
            -- and the placement still says no, for both verbs
            validateContext upReq forged
                @?= Left
                    (ContextPlacementRefusesCommand ClusterLifecycleCommand HostDaemonPlacement False)
            validateContext downReq forged
                @?= Left
                    (ContextPlacementRefusesCommand HostOrchestratorCommand HostDaemonPlacement False)
        , testCase "down/destroy require the chain root, not merely an orchestration frame" $ do
            let host = hostOrchestratorContext "demo" "demo" "/workspace/demo"
                vm = deriveVMContextWithProvider LimaVMProvider host "/vm/demo"
                forged =
                    vm{allowedCommandClasses = allowedCommandClasses vm ++ [HostOrchestratorCommand]}
                upReq = contextRequirement "demo" ClusterLifecycleCommand []
                downReq = contextRequirement "demo" HostOrchestratorCommand []
            isRootFrame host @?= True
            isRootFrame vm @?= False
            -- a VM orchestrator interprets the chain, so `up` is its verb …
            validateContext upReq vm @?= Right vm
            -- … but the unwind belongs to the root frame alone.
            validateContext downReq forged
                @?= Left
                    ( ContextPlacementRefusesCommand
                        HostOrchestratorCommand
                        (VMOrchestratorPlacement LimaVMProvider)
                        False
                    )
        , testCase "a root frame that is not the host orchestrator cannot unwind the chain" $ do
            -- A single-frame topology rooted at a VM orchestrator is structurally
            -- legal, so the empty-parent half alone would authorize `destroy`.
            -- The root-KIND half is what refuses it.
            let rooted =
                    (contextForKind "demo" "demo" "/workspace/demo" VMOrchestrator)
                        { allowedCommandClasses =
                            allowedCommandClasses
                                (contextForKind "demo" "demo" "/workspace/demo" VMOrchestrator)
                                ++ [HostOrchestratorCommand]
                        }
                downReq = contextRequirement "demo" HostOrchestratorCommand []
            isRootFrame rooted @?= True
            validateTopology rooted @?= Right ()
            validateContext downReq rooted
                @?= Left
                    ( ContextPlacementRefusesCommand
                        HostOrchestratorCommand
                        (VMOrchestratorPlacement IncusVMProvider)
                        True
                    )
        , testCase "the host orchestrator at the chain root hosts every lifecycle verb" $ do
            let host = hostOrchestratorContext "demo" "demo" "/workspace/demo"
            validateContext (contextRequirement "demo" ClusterLifecycleCommand []) host
                @?= Right host
            validateContext (contextRequirement "demo" HostOrchestratorCommand []) host
                @?= Right host
        , testCase "placementAllowsCommand is closed over every placement and class" $ do
            let placements =
                    [ HostOrchestratorPlacement
                    , VMOrchestratorPlacement IncusVMProvider
                    , VMBackedProjectContainerPlacement
                    , DirectLinuxGpuContainerPlacement
                    , ImageBuildContainerPlacement
                    , ClusterServicePlacement
                    , ClusterDaemonPlacement
                    , HostDaemonPlacement
                    , OneShotJobPlacement
                    , TestHarnessPlacement
                    ]
                lifecycleRefused =
                    [ (placement, cls)
                    | placement <- placements
                    , cls <- [ClusterLifecycleCommand, HostOrchestratorCommand]
                    , not (placementAllowsCommand placement True cls)
                    ]
            -- Only the four leaves plus the image-build container are refused
            -- `up`; every non-host placement is refused the unwind.
            map fst (filter ((== ClusterLifecycleCommand) . snd) lifecycleRefused)
                @?= [ ImageBuildContainerPlacement
                    , ClusterServicePlacement
                    , ClusterDaemonPlacement
                    , HostDaemonPlacement
                    , OneShotJobPlacement
                    ]
            map fst (filter ((== HostOrchestratorCommand) . snd) lifecycleRefused)
                @?= filter (/= HostOrchestratorPlacement) placements
            -- and no other class is placement-indexed
            [ (placement, cls)
                | placement <- placements
                , cls <-
                    [ EnsureCommand
                    , ConfigInspectionCommand
                    , ConfigGenerationCommand
                    , ContextCreationCommand
                    , TestWorkflowCommand
                    , CheckCodeCommand
                    , DaemonCommand
                    , ServiceCommand
                    , ProjectCommand
                    ]
                , not (placementAllowsCommand placement False cls)
                ]
                @?= []
        , testCase "a kind its provider cannot own is refused before authorization" $ do
            let host = hostOrchestratorContext "demo" "demo" "/workspace/demo"
                svc = deriveServiceContext host "/srv/demo"
                relabelled =
                    svc
                        { topologyFrames =
                            map
                                ( \f ->
                                    if topologyFrameId f == currentFrame svc
                                        then f{topologyProvider = HostProvider}
                                        else f
                                )
                                (topologyFrames svc)
                        }
                req = contextRequirement "demo" ConfigInspectionCommand []
            validateContext req relabelled
                @?= Left (ContextTopologyIllegalProvider (currentFrame svc) ClusterService HostProvider)
        , testCase "validateRuntimeContext verifies the derived witness set, not a declared one" $
            withSystemTempDirectory "hostbootstrap-witness" $ \dir -> do
                let host = hostOrchestratorContext "demo" "demo" "/workspace/demo"
                    daemon = deriveHostDaemonContext host "/workspace/daemon"
                    req = contextRequirement "demo" ServiceCommand []
                    marker = dir </> "marker"
                    plantedWitness = RuntimeWitness WitnessFileExists (T.pack marker) ""
                TIO.writeFile marker "ok"
                -- A satisfiable witness the placement does not require cannot be
                -- added to stand in for one it does.
                validateRuntimeContext req daemon{runtimeWitnesses = [plantedWitness]}
                    >>= ( @?=
                            Left
                                ( ContextWitnessSetMismatch
                                    (runtimeWitnesses daemon)
                                    [plantedWitness]
                                )
                        )
                -- With the exact required set declared, the environment decides.
                result <- validateRuntimeContext req daemon
                case result of
                    Left (ContextRuntimeWitnessFailed witness detail) -> do
                        witness @?= RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" (currentFrame daemon)
                        assertBool
                            "reports the unset frame variable"
                            ("HOSTBOOTSTRAP_CURRENT_FRAME" `isInfixOfS` detail)
                    other -> assertFailure ("expected a runtime witness failure, got " ++ show other)
        , testCase "writeContextFile writes Dhall that decodes back" $
            withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
                let path = dir </> "context.dhall"
                writeContextFile path sampleContext
                decoded <- decodeContextFile path
                decoded @?= sampleContext
        , testCase "withValidatedContext does not run side effects when the gate fails" $ do
            ran <- newIORef False
            result <-
                withValidatedContext
                    sampleContext
                    testRequirement{requiredCommandClass = HostOrchestratorCommand}
                    (writeIORef ran True)
            result @?= Left (ContextCommandNotAllowed HostOrchestratorCommand VMProjectContainer)
            readIORef ran >>= (@?= False)
        , testCase "requireContextFile exits 1 on a missing context" $
            withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
                let path = dir </> "context.dhall"
                result <- try (requireContextFile path testRequirement) :: IO (Either ExitCode BinaryContext)
                result @?= Left (ExitFailure 1)
        , testCase "normal CLI commands fail fast when the sibling context is absent" $ do
            result <-
                try (withArgs ["check-code"] runBareHostBootstrapCLI) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "normal CLI commands run when the sibling project config authorizes them" $ do
            projectName <- executableProjectName
            path <- Schema.siblingProjectConfigPath projectName
            let cfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
                spec = fixtureSpec (T.unpack projectName)
            ( do
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg
                    result <-
                        try (withArgs ["check-code"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    result @?= Right ()
                )
                `finally` removeFile path
        , testCase "project init writes a project-local config before sibling context gating" $
            withSystemTempDirectory "hostbootstrap-config-init" $ \dir -> do
                projectName <- executableProjectName
                let path = dir </> T.unpack projectName <> ".dhall"
                withArgs
                    [ "project"
                    , "init"
                    , "--role"
                    , "image-build-container"
                    , "--output"
                    , path
                    , "--source-root"
                    , "/workspace/demo"
                    , "--dockerfile"
                    , "demo/docker/Dockerfile"
                    , "--cpu"
                    , "6"
                    , "--memory"
                    , "10GiB"
                    , "--storage"
                    , "80GiB"
                    , "--ha-replicas"
                    , "3"
                    ]
                    (runHostBootstrapCLI (fixtureSpec (T.unpack projectName)))
                decoded <- Fixture.decodeProjectConfigFile path
                let Fixture.ProjectConfig cfgDockerfile cfgResources cfgContext cfgDeploy = decoded
                cfgDockerfile @?= "demo/docker/Dockerfile"
                cfgResources @?= Fixture.Resources 6 "10GiB" "80GiB"
                cfgDeploy @?= Fixture.DeployConfig 3
                project cfgContext @?= projectName
                binary cfgContext @?= projectName
                contextKind cfgContext @?= ImageBuildContainer
                sourceRoot cfgContext @?= "/workspace/demo"
        , testCase "project init supplies the project defaults for omitted knobs" $
            withSystemTempDirectory "hostbootstrap-config-init-defaults" $ \dir -> do
                projectName <- executableProjectName
                let path = dir </> T.unpack projectName <> ".dhall"
                withArgs
                    [ "project"
                    , "init"
                    , "--output"
                    , path
                    , "--source-root"
                    , "/workspace/demo"
                    ]
                    (runHostBootstrapCLI (fixtureSpec (T.unpack projectName)))
                decoded <- Fixture.decodeProjectConfigFile path
                let Fixture.ProjectConfig cfgDockerfile cfgResources _ cfgDeploy = decoded
                -- The fixture's projectInit defaults: cpu 4 / 8GiB / 20GiB,
                -- haReplicas 1, dockerfile docker/Dockerfile (none came from flags).
                cfgDockerfile @?= "docker/Dockerfile"
                cfgResources @?= Fixture.Resources 4 "8GiB" "20GiB"
                cfgDeploy @?= Fixture.DeployConfig 1
        , testCase "project init --if-missing writes when absent and is a no-op when present" $
            withSystemTempDirectory "hostbootstrap-config-init-if-missing" $ \dir -> do
                projectName <- executableProjectName
                let path = dir </> T.unpack projectName <> ".dhall"
                    initArgs root =
                        [ "project"
                        , "init"
                        , "--output"
                        , path
                        , "--if-missing"
                        , "--source-root"
                        , root
                        ]
                -- Absent: --if-missing writes the default config.
                withArgs
                    (initArgs "/workspace/demo")
                    (runHostBootstrapCLI (fixtureSpec (T.unpack projectName)))
                before <- TIO.readFile path
                Fixture.ProjectConfig _ _ ctx0 _ <- Fixture.decodeProjectConfigFile path
                sourceRoot ctx0 @?= "/workspace/demo"
                -- Present: --if-missing is a no-op even with a different source-root, so the
                -- user-owned file is left byte-for-byte untouched.
                withArgs
                    (initArgs "/somewhere/else")
                    (runHostBootstrapCLI (fixtureSpec (T.unpack projectName)))
                after <- TIO.readFile path
                after @?= before
        , frameAdmissionTests
        ]

frameAdmissionTests :: TestTree
frameAdmissionTests =
    testGroup
        "plan-local current frame"
        [ testCase "admits the exact root prefix and jointly exposes semantic evidence" $
            withFramePlan hostFrameContext twoFramePlan $ \plan ->
                withCurrentFrame plan hostFrameContext
                    ( \current projectFrame validated ->
                        ( currentFrameId current
                        , projectFrameId projectFrame
                        , validatedContextValue validated
                        )
                    )
                    @?= Right
                        ( "host-orchestrator-0"
                        , "host-orchestrator-0"
                        , hostFrameContext
                        )
        , testCase "admits the exact deeper topology prefix at its endpoint" $
            withFramePlan vmFrameContext twoFramePlan $ \plan ->
                withCurrentFrame plan vmFrameContext
                    ( \current projectFrame validated ->
                        ( currentFrameId current
                        , projectFrameId projectFrame
                        , currentFrame (validatedContextValue validated)
                        )
                    )
                    @?= Right
                        ( "vm-orchestrator-1"
                        , "vm-orchestrator-1"
                        , "vm-orchestrator-1"
                        )
        , testCase "rejects context other than the exact plan-retained config context" $
            withFramePlan hostFrameContext twoFramePlan $ \plan -> do
                let supplied = hostFrameContext{binary = "other-binary"}
                case withCurrentFrame plan supplied (\_ _ _ -> ()) of
                    Left (FrameConfigContextMismatch expected observed) -> do
                        expected @?= hostFrameContext
                        observed @?= supplied
                    other ->
                        assertFailure
                            ("expected exact config-context mismatch, got " <> show other)
        , testCase "wraps the total context-topology validator's refusal" $ do
            let duplicate =
                    case topologyFrames hostFrameContext of
                        [rootFrame] ->
                            hostFrameContext
                                { topologyFrames = [rootFrame, rootFrame]
                                }
                        _ -> error "host frame fixture invariant violated"
            withFramePlan duplicate twoFramePlan $ \plan ->
                withCurrentFrame plan duplicate (\_ _ _ -> ())
                    @?= Left
                        ( FrameContextTopologyError
                            (ContextTopologyDuplicateFrame "host-orchestrator-0")
                        )
        , testCase "rejects a current frame absent from the validated context topology" $ do
            let absent = hostFrameContext{currentFrame = "absent"}
            withFramePlan absent twoFramePlan $ \plan ->
                withCurrentFrame plan absent (\_ _ _ -> ())
                    @?= Left
                        ( FrameContextTopologyError
                            (ContextCurrentFrameMissing "absent")
                        )
        , testCase "rejects a context current kind that disagrees with its topology frame" $ do
            let wrongKind = hostFrameContext{contextKind = VMOrchestrator}
            withFramePlan wrongKind twoFramePlan $ \plan ->
                withCurrentFrame plan wrongKind (\_ _ _ -> ())
                    @?= Left
                        ( FrameContextTopologyError
                            ( ContextCurrentFrameKindMismatch
                                "host-orchestrator-0"
                                VMOrchestrator
                                HostOrchestrator
                            )
                        )
        , testCase "rejects context frame identifiers outside the plan prefix" $ do
            let renamed =
                    case topologyFrames hostFrameContext of
                        [rootFrame] ->
                            hostFrameContext
                                { topologyFrames =
                                    [rootFrame{topologyFrameId = "other-root"}]
                                , currentFrame = "other-root"
                                }
                        _ -> error "host frame fixture invariant violated"
            withFramePlan renamed twoFramePlan $ \plan ->
                withCurrentFrame plan renamed (\_ _ _ -> ())
                    @?= Left
                        ( FrameTopologyIdsMismatch
                            ["host-orchestrator-0"]
                            ["other-root"]
                        )
        , testCase "rejects valid context parent edges outside the plan prefix" $
            withFramePlan branchedContainerContext threeFramePlan $ \plan ->
                withCurrentFrame plan branchedContainerContext (\_ _ _ -> ())
                    @?= Left
                        ( FrameTopologyParentEdgesMismatch
                            [ ("host-orchestrator-0", "vm-orchestrator-1")
                            , ("vm-orchestrator-1", "vm-project-container-2")
                            ]
                            [ ("host-orchestrator-0", "vm-orchestrator-1")
                            , ("host-orchestrator-0", "vm-project-container-2")
                            ]
                        )
        , testCase "rejects a current frame that is not the topology-prefix endpoint" $
            withFramePlan nonEndpointContext threeFramePlan $ \plan ->
                withCurrentFrame plan nonEndpointContext (\_ _ _ -> ())
                    @?= Left
                        ( FrameCurrentFrameEndpointMismatch
                            "vm-project-container-2"
                            "vm-orchestrator-1"
                        )
        , testCase "admission performs no protected-store transition" $
            withFramePlanAndStore hostFrameContext twoFramePlan $ \store plan -> do
                before <- observeProtectedStore store
                withCurrentFrame plan hostFrameContext
                    (\current _ _ -> currentFrameId current)
                    @?= Right "host-orchestrator-0"
                after <- observeProtectedStore store
                after @?= before
        ]

hostFrameContext :: BinaryContext
hostFrameContext =
    hostOrchestratorContext "demo" "demo" "/workspace/demo"

vmFrameContext :: BinaryContext
vmFrameContext =
    deriveVMContext hostFrameContext "/workspace/demo-vm"

containerFrameContext :: BinaryContext
containerFrameContext =
    deriveContainerContext vmFrameContext "/workspace/demo-container"

branchedContainerContext :: BinaryContext
branchedContainerContext =
    containerFrameContext
        { topologyFrames = map reparentContainer (topologyFrames containerFrameContext)
        , parentChain =
            [ ContextFrame
                { frameKind = HostOrchestrator
                , frameBinary = "demo"
                }
            ]
        }
  where
    reparentContainer frame
        | topologyFrameId frame == "vm-project-container-2" =
            frame{topologyParentId = "host-orchestrator-0"}
        | otherwise = frame

nonEndpointContext :: BinaryContext
nonEndpointContext =
    containerFrameContext
        { contextKind = VMOrchestrator
        , roleName = "vm-orchestrator"
        , parentChain =
            [ ContextFrame
                { frameKind = HostOrchestrator
                , frameBinary = "demo"
                }
            ]
        , currentFrame = "vm-orchestrator-1"
        }

twoFramePlan :: StepPlan
twoFramePlan =
    expectFrameStepPlan
        [ descendsVia
            localContext
            ( contextInitStep
                "context"
                (StepFrame "host-orchestrator-0" "Host")
                (const (pure StepChanged))
            )
        , ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "vm-orchestrator-1" "VM")
            (const (pure StepChanged))
        ]

threeFramePlan :: StepPlan
threeFramePlan =
    expectFrameStepPlan
        [ descendsVia
            localContext
            ( contextInitStep
                "context"
                (StepFrame "host-orchestrator-0" "Host")
                (const (pure StepChanged))
            )
        , descendsVia
            localContext
            ( ensureStep
                "ghc"
                "ensure ghc"
                (StepFrame "vm-orchestrator-1" "VM")
                (const (pure StepChanged))
            )
        , buildImageStep
            "build image"
            (StepFrame "vm-project-container-2" "Container")
            (const (pure StepChanged))
        ]

expectFrameStepPlan :: [Step] -> StepPlan
expectFrameStepPlan = either (error . show) id . mkStepPlan

withFramePlan ::
    BinaryContext ->
    StepPlan ->
    ( forall scope specDigest planId configId.
      ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withFramePlan context plan use =
    withFramePlanAndStore context plan (\_store admittedPlan -> use admittedPlan)

withFramePlanAndStore ::
    BinaryContext ->
    StepPlan ->
    ( forall scope specDigest planId configId.
      ProtectedStore ->
      ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withFramePlanAndStore context plan use =
    withSystemTempDirectory "hostbootstrap-current-frame" $ \directory -> do
        store <-
            openProtectedStore (directory </> "protected")
                >>= either (fail . show) pure
        Fixture.withFixtureInstalledProject $
            \(installed :: InstalledProjectIdentity projectId) -> do
                rooted <-
                    withCanonicalProjectRoot
                        (directory </> "fixture.dhall")
                        directory
                        ( \(root :: CanonicalProjectRoot (Production projectId) rootId) ->
                            withProductionRoot store installed ProjectUp $ \productionRoot -> do
                                opened <-
                                    withProductionLifecycleProfile
                                        (rootScopeAuthority (productionRootAuthority productionRoot))
                                        (productionActiveMode (productionRootModeLease productionRoot))
                                        (productionRootUnboundLease productionRoot)
                                        ( \profile ->
                                            withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                                                let value =
                                                        ( Fixture.defaultProjectConfig
                                                            (project context)
                                                            (T.pack (canonicalProjectRootPath root))
                                                            HostOrchestrator
                                                        )
                                                            { Fixture.context = context
                                                            }
                                                admitted <-
                                                    Schema.withValidatedConfig codec value $ \_wire config -> do
                                                        drafts <-
                                                            either (fail . show) pure
                                                                ( planDraftsFromValidatedBuilder
                                                                    root
                                                                    config
                                                                    (\_ _ -> Right plan)
                                                                )
                                                        action <-
                                                            either (fail . show) pure
                                                                ( withProjectPlan
                                                                    profile
                                                                    root
                                                                    config
                                                                    drafts
                                                                    (use store)
                                                                )
                                                        action
                                                either fail pure admitted
                                        )
                                case opened of
                                    Left failure ->
                                        pure (Left (ModeAuthorityFailure failure))
                                    Right action -> Right <$> action
                        )
                admitted <- either (fail . show) pure rooted
                either (fail . show) pure admitted

observeProtectedStore :: ProtectedStore -> IO [(T.Text, Maybe ProtectedRecord)]
observeProtectedStore store = do
    observed <-
        withProtectedEntry store $ \session -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left failure)
                Right keys -> do
                    records <-
                        traverse
                            ( \key ->
                                fmap
                                    (fmap (\record -> (recordKeyText key, record)))
                                    (readProtectedRecord session key)
                            )
                            keys
                    pure (sequence records)
    either (fail . show) pure observed

withContextFile :: String -> (FilePath -> IO a) -> IO a
withContextFile body action =
    withSystemTempDirectory "hostbootstrap-context" $ \dir -> do
        let path = dir </> "context.dhall"
        TIO.writeFile path (fromString body)
        action path

fromString :: String -> T.Text
fromString = T.pack

providerOf :: BinaryContext -> Maybe ProviderKind
providerOf ctx =
    topologyProvider <$> findCurrent (currentFrame ctx) (topologyFrames ctx)

findCurrent :: T.Text -> [TopologyFrame] -> Maybe TopologyFrame
findCurrent _ [] = Nothing
findCurrent frame (candidate : rest)
    | topologyFrameId candidate == frame = Just candidate
    | otherwise = findCurrent frame rest

isInfixOfS :: String -> String -> Bool
isInfixOfS needle hay =
    T.pack needle `T.isInfixOf` T.pack hay
