-- The project-local <project>.dhall record type.
--
-- This is the binary-owned runtime config shape. Python derives the project
-- name from the Cabal file and does not read this file. The runtime context is
-- nested inside the config and is validated by the project binary before
-- normal command dispatch.
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

let Resources = { cpu : Natural, memory : Text, storage : Text }

let ContextFrame = { frameKind : ContextKind, frameBinary : Text }

let BinaryContext =
      { project : Text
      , binary : Text
      , sourceRoot : Text
      , contextKind : ContextKind
      , roleName : Text
      , parentChain : List ContextFrame
      , capabilities : List Capability
      , allowedCommandClasses : List CommandClass
      , resourceEnvelope : Resources
      , childContextKinds : List ContextKind
      }

in  { dockerfile : Text
    , resources : Resources
    , context : BinaryContext
    , deploy : { haReplicas : Natural }
    }
