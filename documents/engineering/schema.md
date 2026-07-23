# Project-Local `<project>.dhall` Schema

**Status**: Authoritative source
**Supersedes**: static-base `hostbootstrap.dhall`; the three-execution-model / substrate-keyed / lifecycle `hostbootstrap.dhall` schema (Container/HostBinary/HostDaemon, Cluster/NoCluster, Mounts, force-target)
**Referenced by**: [../README.md](../README.md), [prerequisites.md](prerequisites.md), [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [dhall_topology.md](dhall_topology.md)

> **Purpose**: Define the project-local Dhall configuration file each project binary reads from beside
> itself.

## TL;DR

- The runtime configuration file is the executable's sibling `<project>.dhall`, for example
  `./.build/hostbootstrap-demo.dhall` beside `./.build/hostbootstrap-demo`.
- The Python bootstrapper derives the project name from the Cabal file name, builds the project binary,
  and never reads or writes Dhall.
- The project binary owns the schema, default rendering, validation, downstream projection, and help text
  for the local config.
- Normal commands fail fast when the sibling config is missing or incompatible. Ungated exceptions are
  limited to help/version and explicit config inspection/initialization commands, including static
  `context render`.
- Host, VM, ad-hoc container, daemon, and service copies use the same filename rule but different file
  contents. The role is a field inside the Dhall value, not part of the filename.

## Current Status

The Python bootstrapper does not read or write Dhall. The Haskell schema has a project-local config shape,
`project init` can generate role-specific defaults, pure projection helpers derive narrower child configs,
and normal command gating reads the context authority embedded in the sibling `<project>.dhall`.
See
[phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md) and
[phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md).

The schema is topology-aware. Runtime context includes an execution topology, `currentFrame`, and runtime
witnesses so illegal states such as "VM project container command running on the host Docker daemon" fail
before side effects.

Implemented (phase 19, `Done`): under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the config TYPE
is project-defined, not the fixed `ProjectConfig`. Every field is mandatory and a missing field fails the
strict decode; defaults live ONLY in the project-owned `psInit`, never in core. Secret-bearing fields use
the pure `SecretRef = <Vault|TransitKey|Prompt|TestPlaintext>` vocabulary (see [secrets.md](secrets.md))
so a secrets-strict consumer's production configs stay plaintext-free and core never resolves a secret.
See the [generic_project_model.md](../architecture/generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

This is why defaults must live in `psInit`: a naive one-size `4/8/20` default (only the sample value of
core's `budget` render artifact, not a core-shipped config default) cannot bootstrap the demo (its
`deploy-VM` gate requires `6/10/80`, `demoFullLifecycleResources`), so the demo's project-owned `psInit`
returns its real budget rather than inheriting any core default. See
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md).

## File Location

The lookup rule is intentionally singular:

```text
sibling of executable: <project>.dhall
```

Examples:

| Binary copy | Default config path |
|---|---|
| Host binary | `./.build/<project>.dhall` |
| VM host-native binary | sibling of the VM-local executable |
| Project container binary | `/usr/local/bin/<project>.dhall` |
| Cluster service or daemon binary | sibling path mounted or materialized by the controller |

The filename does not encode the role. The binary always knows what to look for; the file tells the binary
what role it has.

## Project Name

The Python bootstrapper derives the project name from the Cabal file name:

```text
hostbootstrap-demo.cabal -> hostbootstrap-demo
```

The bootstrapper should fail fast when a project root has zero or more than one candidate `.cabal` file,
unless the user supplies an explicit Cabal file path. This keeps Python out of Dhall while preserving the
single stable binary name used for `cabal build exe:<project>` and `./.build/<project>`.

## Config Shape

The exact project-level fields are binary-owned and may be extended by a consumer, but every local config
has two conceptual sections:

| Section | Owner | Purpose |
|---|---|---|
| Project settings | project binary | user-editable inputs such as Dockerfile path, resource budget, deploy knobs, replicas, ports, feature flags, and any project-extended field (the demo's `message`) |
| Runtime context | `hostbootstrap-core` / project binary | current local authority: identity, parent chain, topology frames, current frame, runtime witnesses, context kind, role name, capabilities, allowed command classes, resource envelope, child-context rules |

The decode is **strict and total**: every field in the project's config type is mandatory, so a missing
field fails the `FromDhall` decode. The decoder never `//`-merges a partial value against a default and
never `fromMaybe`s a missing field into a fallback at decode time — there is no decode-time optionality.
Defaults are not a property of the schema; they live ONLY in the project-owned `psInit`, which renders a
fully-populated value that `project init` writes and the test harness seeds (see
[config_generation.md](config_generation.md) and the
[generic_project_model.md](../architecture/generic_project_model.md) design). The on-disk config a normal
command reads is therefore a complete value, not a sparse override.

The decode is strict about field **presence** today; field-level **validity** is a **target**, not yet
implemented. The aim is that invalidity is unrepresentable at decode — `memory` / `storage` a typed
`Quantity` (a bad unit rejected at decode), `haReplicas`, the service ports, and timeouts bounded
newtypes, and the lifecycle resource floor a smart constructor — so an unworkable config cannot be
*constructed* rather than decoding cleanly and failing mid-bring-up. This is reopened as phase-9 Sprint
9.9; today those fields are unbounded `Natural`/`Text` validated at runtime. See
[development_plan_standards.md § O](../../DEVELOPMENT_PLAN/development_plan_standards.md) and
[applied_cordon.md](applied_cordon.md).

A host-level config has the same top-level shape as the project's config type (for the demo, the demoted
`ProjectConfig` schema). A project may add its own mandatory fields with no core change: the demo carries a
`message : Text` field its web service renders, shown below.

```dhall
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
      | Wsl2VMProvider
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

let Capability = < HostTools | IncusProvider | DockerSocket | ContainerRuntime | KubernetesAPI | KindNetwork | DurableStore | ServicePort >

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

in  { dockerfile = "docker/Dockerfile"
    , resources = { cpu = 6, memory = "10GiB", storage = "80GiB" }
    , message = "Hello, world!"
    , context =
      { project = "hostbootstrap-demo"
      , binary = "hostbootstrap-demo"
      , sourceRoot = "/home/matt/hostbootstrap/demo"
      , contextKind = ContextKind.HostOrchestrator
      , roleName = "host-orchestrator"
      , parentChain = [] : List { frameKind : ContextKind, frameBinary : Text }
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
      , resourceEnvelope = { cpu = 6, memory = "10GiB", storage = "80GiB" }
      , childContextKinds =
        [ ContextKind.VMOrchestrator
        , ContextKind.ClusterService
        , ContextKind.Daemon
        , ContextKind.OneShotJob
        , ContextKind.TestHarness
        ]
      }
    , deploy = { haReplicas = 1 }
  }
```

The exact generated value is owned by the binary. Use `<project> project init` for a valid default,
`<project> context schema` for the in-scope artifact union, and `<project> service schema` for the
reflected type the decoder accepts; do not hand-maintain a parallel schema in project docs.

The demo config also owns `service : Optional ServiceType`, where `ServiceType` is the real Dhall union
`Web { publicPort, acceleratorPort } | Accelerator { requestTimeoutSeconds }`. Core sees only the
project-owned selector that maps this payload to an internal handler key; `service run` has no positional
variant and validates bounds/role compatibility before dispatch.

The `message : Text` field is a worked example of a project-extended field flowing all the way to the
workload, with no core-owned slot: `<project>.dhall` carries `message`, the binary renders the exact child
config into the web service's dynamically applied ConfigMap, the `serveWeb` handler reads it, the API's
`BudgetView.message` carries it across the `purescript-bridge` round-trip, and the SPA renders it into its
`#message` element. It is a mandatory field on the demo's OWN config type — core owns no project-specific
field and ships no generic extra slot.

## Default Generation

The project binary provides an ungated initialization command, for example:

```bash
<project> project init --output ./.build/<project>.dhall
```

The generated file is a valid default; `project init --help` names the editable options (`--dockerfile`,
`--cpu`, `--memory`, `--storage`, `--ha-replicas`, `--source-root`), `context schema` prints the in-scope
artifact union, and `service schema` prints the reflected `ProjectConfig` type. Normal commands do not
silently create a missing config. They fail fast and tell the user how to run the initialization command.

The Dockerfile creates a build-time image config after installing the binary:

```dockerfile
RUN <project> project init --role image-build-container --output /usr/local/bin/<project>.dhall
```

Runtime, service, or daemon deployments override the baked build-time config by mounting or materializing
a role-specific file at the same canonical path. A lifted `test run all` container must receive a
parent-generated VM-project-container config with topology witnesses; it must not rely on the image-build
default.

## Downstream Projection

Values may need to flow from the host config to children: resource limits, image names, ports, HA replica
counts, chart values, storage sizes, and feature flags. The child must not read the host config directly.

The parent binary reads and validates its own config, computes a typed plan, and writes a narrower child
`<project>.dhall` at the boundary where the child process becomes real. This is a projection, not a copy:
the child receives only the settings and authority it needs for its role.

For topology-aware configs, projection also means selecting the child frame and adding witnesses that the
child can verify locally. The parent does not need to regenerate the entire topology on every command, but
the child must have enough information to prove its current frame before normal dispatch.

## Mutation And Reload

Normal commands treat the active config as an immutable startup snapshot:

- read the sibling config once at process start;
- validate it;
- run against that snapshot;
- ignore later file changes during the same short-lived process.

Allowed writes are explicit and narrow: `project init` (re-run with `--force` to overwrite),
user-requested config-edit commands, and parent commands generating child configs. The canonical example of a parent generating a
child config is the `context-init` chain step inside `project up`, which mints the narrower
`<project>.dhall` for the project-container frame. Runtime status, discovered endpoints, locks, leader
election, build IDs, and secrets live in state stores or mounted secrets, not by silently mutating the
active config.

Long-running daemons and services use the same rule by default: read once at startup, log the config path
and hash, and require restart or reconcile to observe changes. If a project later supports live reload, it
must never live-reload authority fields such as context kind, capabilities, allowed commands, parent chain,
or project/binary identity.

## See Also

- [dhall_topology.md](dhall_topology.md) - how project-local, generated child, and per-case Dhall relate.
- [binary_context_config](../architecture/binary_context_config.md) - the authority and command-gating
  fields inside the local config.
- [resource_budgeting.md](resource_budgeting.md) - how resource budgets are projected and cordoned.
- [derived_project_standards.md](derived_project_standards.md) - project authoring rules.
