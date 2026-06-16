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
  `config render`.
- Host, VM, ad-hoc container, daemon, and service copies use the same filename rule but different file
  contents. The role is a field inside the Dhall value, not part of the filename.

## Current Status

The Python bootstrapper does not read or write Dhall. The Haskell schema has a project-local config shape,
`config init` can generate role-specific defaults, pure projection helpers derive narrower child configs,
and normal command gating reads the context authority embedded in the sibling `<project>.dhall`.
See
[phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md) and
[phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md).

Phase 15 is active again for topology hardening. The current schema has the flat context fields shown
below; the target schema adds an execution topology, `currentFrame`, and runtime witnesses so illegal
states such as "VM project container command running on the host Docker daemon" fail before side effects.

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
| Project settings | project binary | user-editable inputs such as Dockerfile path, resource budget, deploy knobs, replicas, ports, feature flags |
| Runtime context | `hostbootstrap-core` / project binary | local authority: identity, topology frames, current frame, context kind, role name, runtime witnesses, capabilities, allowed command classes, resource envelope, child-context rules |

A host-level config has the same top-level shape as the generated `ProjectConfig` schema:

```dhall
let ContextKind =
      < HostOrchestrator
      | VMOrchestrator
      | ImageBuildContainer
      | VMProjectContainer
      | ClusterService
      | Daemon
      | OneShotJob
      | TestHarness
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
    , context =
      { project = "hostbootstrap-demo"
      , binary = "hostbootstrap-demo"
      , sourceRoot = "/home/matt/hostbootstrap/demo"
      , topology =
        { frames = [] : List { id : Text, parent : Optional Text, provider : Text }
        , currentFrame = "host"
        }
      , contextKind = ContextKind.HostOrchestrator
      , roleName = "host-orchestrator"
      , parentChain = [] : List { frameKind : ContextKind, frameBinary : Text }
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
        , ContextKind.VMProjectContainer
        , ContextKind.ClusterService
        , ContextKind.Daemon
        , ContextKind.OneShotJob
        , ContextKind.TestHarness
        ]
      }
    , deploy = { haReplicas = 1 }
  }
```

The exact generated value is owned by the binary. Use `<project> config init` for a valid default and
`<project> config schema` for the reflected type the decoder accepts; do not hand-maintain a parallel
schema in project docs. The `topology` fragment above is illustrative until the Phase 15 topology
hardening lands in the reflected schema.

## Default Generation

The project binary provides an ungated initialization command, for example:

```bash
<project> config init --output ./.build/<project>.dhall
```

The generated file is a valid default; `config init --help` names the editable options (`--dockerfile`,
`--cpu`, `--memory`, `--storage`, `--ha-replicas`, `--source-root`) and `config schema` includes the
reflected `ProjectConfig` type. Normal commands do not silently create a missing config. They fail fast
and tell the user how to run the initialization command.

The Dockerfile creates a narrow image-build container config after installing the binary:

```dockerfile
RUN <project> config init --role image-build-container --output /usr/local/bin/<project>.dhall
```

Runtime, service, or daemon deployments override that baked build-time config by mounting or materializing
a role-specific file at the same canonical path. A lifted `test all` container must receive a
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

Allowed writes are explicit and narrow: `config init`, `config upgrade FILE`, user-requested config-edit
commands, and parent commands generating child configs. Runtime status, discovered endpoints, locks,
leader election, build IDs, and secrets live in state stores or mounted secrets, not by silently mutating
the active config.

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
