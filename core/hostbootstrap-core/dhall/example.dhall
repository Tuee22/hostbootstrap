-- A canonical project-local <project>.dhall instance, used as a decode fixture.
let ContextKind =
      < HostOrchestrator
      | VMOrchestrator
      | VMProjectContainer
      | ImageBuildContainer
      | ClusterService
      | Daemon
      | OneShotJob
      | TestHarness
      >

let ProviderKind =
      < HostProvider
      | IncusVMProvider
      | LimaVMProvider
      | DockerContainerProvider
      | KubernetesProvider
      | ExternalProvider
      >

let WitnessKind =
      < WitnessFileExists
      | WitnessUnixSocket
      | WitnessEnvEquals
      | WitnessExecutable
      >

let Capability =
      < HostTools
      | IncusProvider
      | DockerSocket
      | ContainerRuntime
      | KubernetesAPI
      | KindNetwork
      | DurableStore
      | ServicePort
      >

let CommandClass =
      < EnsureCommand
      | ConfigInspectionCommand
      | ConfigGenerationCommand
      | ContextCreationCommand
      | ClusterLifecycleCommand
      | TestWorkflowCommand
      | CheckCodeCommand
      | HostOrchestratorCommand
      | DaemonCommand
      | ServiceCommand
      | ProjectCommand
      >

in  { dockerfile = "docker/demo.Dockerfile"
    , resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
    , context =
        { project = "demo"
        , binary = "demo"
        , sourceRoot = "/workspace/demo"
        , contextKind = ContextKind.HostOrchestrator
        , roleName = "host-orchestrator"
        , parentChain =
            [] : List { frameKind : ContextKind, frameBinary : Text }
        , topologyFrames =
            [ { topologyFrameId = "host-orchestrator-0"
              , topologyParentId = ""
              , topologyProvider = ProviderKind.HostProvider
              , topologyKind = ContextKind.HostOrchestrator
              , topologyRoleName = "host-orchestrator"
              }
            ]
        , currentFrame = "host-orchestrator-0"
        , runtimeWitnesses =
            [] : List
                   { witnessKind : WitnessKind
                   , witnessName : Text
                   , witnessValue : Text
                   }
        , capabilities = [ Capability.HostTools, Capability.IncusProvider ]
        , allowedCommandClasses =
            [ CommandClass.EnsureCommand
            , CommandClass.ConfigInspectionCommand
            , CommandClass.ConfigGenerationCommand
            , CommandClass.ContextCreationCommand
            , CommandClass.ClusterLifecycleCommand
            , CommandClass.TestWorkflowCommand
            , CommandClass.CheckCodeCommand
            , CommandClass.HostOrchestratorCommand
            , CommandClass.ProjectCommand
            ]
        , resourceEnvelope = { cpu = 4, memory = "8GiB", storage = "20GiB" }
        , childContextKinds =
            [ ContextKind.VMOrchestrator
            , ContextKind.ClusterService
            , ContextKind.Daemon
            , ContextKind.OneShotJob
            , ContextKind.TestHarness
            ]
        }
    , deploy = { haReplicas = 2 }
    }
