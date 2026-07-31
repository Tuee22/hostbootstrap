{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module ContextSpec (tests) where

import Control.Exception (finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Fixture
import HostBootstrap.CLI (
    ProjectSpec,
    addSteps,
    finalizeProjectSpec,
    projectSpec,
 )
import qualified HostBootstrap.CLI as CLI
import qualified HostBootstrap.Config.Schema as Schema
import HostBootstrap.Config.Class (AssemblyRequest (..), pureConfigAssembly)
import HostBootstrap.Context
import HostBootstrap.Harness (Case (Case), CaseResult (Pass), TestSuite (TestSuite), mkCaseId)
import HostBootstrap.Step (StepFrame (StepFrame), deployVMStep)
import System.Directory (removeFile)
import System.Environment (withArgs, withProgName)
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
    ProjectSpec Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig
fixtureSpec progName =
    either (error . show) id $
        finalizeProjectSpec $
            addSteps
                (\_ _ -> [deployVMStep "fixture step" (StepFrame "host-orchestrator-0" "metal") (const (pure ()))])
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
    String ->
    ProjectSpec Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig ->
    IO ()
runHostBootstrapCLI name spec =
    withProgName name (CLI.runHostBootstrapCLI name spec)

runBareHostBootstrapCLI :: String -> IO ()
runBareHostBootstrapCLI name =
    withProgName name (CLI.runBareHostBootstrapCLI name)

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
                try (withArgs ["check-code"] (runBareHostBootstrapCLI "definitely-missing-context")) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "normal CLI commands run when the sibling project config authorizes them" $ do
            let projectName = "demo-cli-context"
            path <- Schema.siblingProjectConfigPath projectName
            let cfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
            ( do
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg
                    result <-
                        try (withArgs ["check-code"] (runHostBootstrapCLI (T.unpack projectName) (fixtureSpec (T.unpack projectName)))) ::
                            IO (Either ExitCode ())
                    result @?= Right ()
                )
                `finally` removeFile path
        , testCase "project init writes a project-local config before sibling context gating" $
            withSystemTempDirectory "hostbootstrap-config-init" $ \dir -> do
                let path = dir </> "demo.dhall"
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
                    (runHostBootstrapCLI "demo" (fixtureSpec "demo"))
                decoded <- Fixture.decodeProjectConfigFile path
                let Fixture.ProjectConfig cfgDockerfile cfgResources cfgContext cfgDeploy = decoded
                cfgDockerfile @?= "demo/docker/Dockerfile"
                cfgResources @?= Fixture.Resources 6 "10GiB" "80GiB"
                cfgDeploy @?= Fixture.DeployConfig 3
                contextKind cfgContext @?= ImageBuildContainer
                sourceRoot cfgContext @?= "/workspace/demo"
        , testCase "project init supplies the project defaults for omitted knobs" $
            withSystemTempDirectory "hostbootstrap-config-init-defaults" $ \dir -> do
                let path = dir </> "demo.dhall"
                withArgs
                    [ "project"
                    , "init"
                    , "--output"
                    , path
                    , "--source-root"
                    , "/workspace/demo"
                    ]
                    (runHostBootstrapCLI "demo" (fixtureSpec "demo"))
                decoded <- Fixture.decodeProjectConfigFile path
                let Fixture.ProjectConfig cfgDockerfile cfgResources _ cfgDeploy = decoded
                -- The fixture's projectInit defaults: cpu 4 / 8GiB / 20GiB,
                -- haReplicas 1, dockerfile docker/Dockerfile (none came from flags).
                cfgDockerfile @?= "docker/Dockerfile"
                cfgResources @?= Fixture.Resources 4 "8GiB" "20GiB"
                cfgDeploy @?= Fixture.DeployConfig 1
        , testCase "project init --if-missing writes when absent and is a no-op when present" $
            withSystemTempDirectory "hostbootstrap-config-init-if-missing" $ \dir -> do
                let path = dir </> "demo.dhall"
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
                withArgs (initArgs "/workspace/demo") (runHostBootstrapCLI "demo" (fixtureSpec "demo"))
                before <- TIO.readFile path
                Fixture.ProjectConfig _ _ ctx0 _ <- Fixture.decodeProjectConfigFile path
                sourceRoot ctx0 @?= "/workspace/demo"
                -- Present: --if-missing is a no-op even with a different source-root, so the
                -- user-owned file is left byte-for-byte untouched.
                withArgs (initArgs "/somewhere/else") (runHostBootstrapCLI "demo" (fixtureSpec "demo"))
                after <- TIO.readFile path
                after @?= before
        ]

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
