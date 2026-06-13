-- A canonical project-local <project>.dhall instance, used as a decode fixture.
let ContextKind =
      < HostOrchestrator
      | VMOrchestrator
      | VMProjectContainer
      | ClusterService
      | Daemon
      | OneShotJob
      | TestHarness
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
        , capabilities = [ Capability.HostTools, Capability.IncusProvider ]
        , allowedCommandClasses =
            [ CommandClass.EnsureCommand
            , CommandClass.ConfigInspectionCommand
            , CommandClass.ProjectCommand
            ]
        , resourceEnvelope = { cpu = 4, memory = "8GiB", storage = "20GiB" }
        , childContextKinds =
            [ ContextKind.VMOrchestrator, ContextKind.VMProjectContainer ]
        }
    , deploy = { haReplicas = 2 }
    }
