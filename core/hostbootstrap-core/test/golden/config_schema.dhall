-- budget
{ cpu : Natural, memory : Natural, storage : Natural }

-- podResources
{ replicas : Natural
, cpuRequest : Natural
, cpuLimit : Natural
, memoryRequest : Natural
, memoryLimit : Natural
}

-- kindNode
{ cpus : Natural, memory : Natural, storage : Natural }

-- projectConfig
{ dockerfile : Text
, resources : { cpu : Natural, memory : Text, storage : Text }
, context :
    { project : Text
    , binary : Text
    , sourceRoot : Text
    , contextKind :
        < HostOrchestrator
        | VMOrchestrator
        | VMProjectContainer
        | ImageBuildContainer
        | ClusterService
        | Daemon
        | OneShotJob
        | TestHarness
        >
    , roleName : Text
    , parentChain :
        List
          { frameKind :
              < HostOrchestrator
              | VMOrchestrator
              | VMProjectContainer
              | ImageBuildContainer
              | ClusterService
              | Daemon
              | OneShotJob
              | TestHarness
              >
          , frameBinary : Text
          }
    , topologyFrames :
        List
          { topologyFrameId : Text
          , topologyParentId : Text
          , topologyProvider :
              < HostProvider
              | IncusVMProvider
              | LimaVMProvider
              | Wsl2VMProvider
              | DockerContainerProvider
              | KubernetesProvider
              | ExternalProvider
              >
          , topologyKind :
              < HostOrchestrator
              | VMOrchestrator
              | VMProjectContainer
              | ImageBuildContainer
              | ClusterService
              | Daemon
              | OneShotJob
              | TestHarness
              >
          , topologyRoleName : Text
          }
    , currentFrame : Text
    , runtimeWitnesses :
        List
          { witnessKind :
              < WitnessFileExists
              | WitnessUnixSocket
              | WitnessEnvEquals
              | WitnessExecutable
              >
          , witnessName : Text
          , witnessValue : Text
          }
    , capabilities :
        List
          < HostTools
          | IncusProvider
          | DockerSocket
          | ContainerRuntime
          | KubernetesAPI
          | KindNetwork
          | DurableStore
          | ServicePort
          >
    , allowedCommandClasses :
        List
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
    , resourceEnvelope : { cpu : Natural, memory : Text, storage : Text }
    , childContextKinds :
        List
          < HostOrchestrator
          | VMOrchestrator
          | VMProjectContainer
          | ImageBuildContainer
          | ClusterService
          | Daemon
          | OneShotJob
          | TestHarness
          >
    }
, deploy : { haReplicas : Natural }
}
