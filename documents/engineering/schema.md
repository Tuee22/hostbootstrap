# Project-Local `<project>.dhall` Schema

**Status**: Authoritative source
**Supersedes**: static-base `hostbootstrap.dhall`; the three-execution-model / substrate-keyed / lifecycle `hostbootstrap.dhall` schema (Container/HostBinary/HostDaemon, Cluster/NoCluster, Mounts, force-target)
**Referenced by**: [../README.md](../README.md), [prerequisites.md](prerequisites.md), [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [dhall_topology.md](dhall_topology.md)

> **Purpose**: Define the project-local Dhall configuration file each project binary reads from beside
> itself.

## TL;DR

- The runtime configuration file is the executable's sibling `<project>.dhall`, for example
  `./.build/hostbootstrap-demo.dhall` beside `./.build/hostbootstrap-demo`.
- The Python bootstrapper currently derives a Cabal-file stem and a single executable-stanza name
  independently, builds `exe:<executable>` into `./.build/<executable>`, and never reads or writes Dhall.
- The project binary owns scope-correct validated-codec schema text, assembly, rendering, decoding/validation,
  downstream projection, and help text for the local config. An opaque `CodecWitness` rejects unequal
  normalized encoder/decoder type expressions before decode or mutation; representative round trips
  separately test semantics.
- Normal commands fail fast when the sibling config is missing or incompatible. Ungated exceptions are
  limited to help and explicit config inspection/initialization commands, including static
  `context render`.
- Host, VM, ad-hoc container, daemon, and service copies use the same filename rule but different file
  contents. The role is a field inside the Dhall value, not part of the filename.

## Current Status

The Python bootstrapper does not read or write Dhall. The Haskell schema has a project-local config shape,
`project init` can generate role-specific defaults through the project-owned restricted assembler,
current pure projection helpers derive context-adjusted full child records, and normal command gating
reads the descriptive context embedded in the sibling `<project>.dhall`.
See
[phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md) and
[phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md).

The schema is topology-aware. Runtime context includes an execution topology, `currentFrame`, and runtime
witnesses that catch many mismatches such as "VM project container command running on the host Docker
daemon" before side effects when the relevant witness is supplied. Current validation has no mandatory
provider/kind witness set and does not prove whole-graph validity. These decoded fields are not yet
opaque authority: callers can still construct or update descriptive context values. Phase 15.9 replaces
those gaps with total graph/witness validation and narrowed opaque
authority/capabilities.

Under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the config type
is project-defined as `cfg :: Type -> Type`, not the fixed `ProjectConfig`. Every field is mandatory and
a missing field fails the strict decode. Core owns no defaults; root and per-variant Harness defaults
come from the single restricted `psAssemble`, while demo service projection preserves its explicit
assembled ports/timeouts and invents no fallbacks. Secret-bearing fields use scope-indexed
`SecretRef scope` (see [secrets.md](secrets.md)), so
raw `Text` cannot occupy a secret-ref field and core never resolves a secret. Production and Harness use
separate untrusted wire schemas; Production has no `TestPlaintext` branch, while Harness plaintext
requires exact run config authority during mapped-codec admission.
See the [generic_project_model.md](../architecture/generic_project_model.md) design and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).
Test configuration is likewise project-defined. Core now owns only opaque validated `CaseId`,
`VariantId`, `VariantDraft`, and `TestMatrix` shapes plus the `TestCfg` projection contract. The demo's
current `<project>.test.dhall` decodes exactly `{ testResources : Resources }`; `all` is a typed parser
selector and is never stored schema data. This typed foundation does not restore a core config type, and
Phase 20 still owns moving the demo's concrete two-message mapping into its test config.

This is why root/harness initialization defaults must be project-owned: a naive one-size `4/8/20`
default (only the sample value of core's `budget` render artifact, not a core-shipped config default)
cannot bootstrap the demo (its `deploy-VM` gate requires `6/10/80`,
`demoFullLifecycleResources`), so the demo's `psAssemble` returns its real budget rather than inheriting
any core default. Service-role parameters are mandatory project fields rather than a second default
source. See
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

## Project And Executable Identity

One spelling is validated at four build/runtime boundaries:

| Name | Validated source | Use |
|---|---|---|
| Cabal-file stem | selected top-level `*.cabal` filename | Python discovery identity |
| Cabal package | top-level `name:` field | must equal the filename stem |
| executable | the sole `executable <name>` stanza | must equal the package; selects `exe:<name>` and `./.build/<name>` |
| CLI program/project name | declared `runHostBootstrapCLI` name plus actual invoked executable | must agree before dispatch; selects sibling config and expected context identity |

Python rejects zero/ambiguous Cabal selection, invalid explicit selection, missing/duplicate package or
executable declarations, and every stem/package/executable mismatch. Haskell rejects a declared CLI name
that differs from the invoked executable (after normalizing a Windows `.exe`) before command dispatch.

This closes the cross-language build/config spelling boundary. The later target makes project identity
an opaque plan-indexed value projected into context, resource prefixes, and ownership records rather than
retaining independent strings inside lifecycle APIs.

## Config Shape

The exact project-level fields are binary-owned and may be extended by a consumer, but every local config
has two conceptual sections:

| Section | Owner | Purpose |
|---|---|---|
| Project settings | project binary | user-editable inputs such as Dockerfile path, resource budget, deploy knobs, replicas, ports, feature flags, and any project-extended field (the demo's `message`) |
| Runtime context | `hostbootstrap-core` / project binary | declared identity, parent chain, topology frames, current frame, runtime witnesses, context kind, role name, capabilities, allowed command classes, and child-context rules; opaque authority remains a target |

The record decode is strict about field presence: every field in the project's config type is mandatory,
so a missing field fails the `FromDhall` decode. That does not make semantic validation total. The demo
now has one project-owned `resources` value; `BinaryContext` carries no independently editable budget
copy, and full child-config projection preserves the already-refined project value. One project-owned
assembler is the structural default source, and finalized service-role projection invents no missing
values. Plan-indexed provider admission and partitioning are implemented as a pure foundation; live
provider adapters still must adopt that authority. See
[config_generation.md](config_generation.md) and the
[generic_project_model.md](../architecture/generic_project_model.md) design). The on-disk config a normal
command reads is therefore a complete value, not a sparse override.

The demo decoder checks field **presence** and selected top-level scalar refinements:
`memory`/`storage` decode through a typed `Quantity`, `haReplicas`, service ports, and timeouts use bounded
newtypes, and `Resources` enforces its CPU floor. Their constructors are private, public smart
constructors are total, and no `Num`/`IsString` bypass remains. Their `ToDhall` instances remain
transparent, so the reflected Dhall schema still shows the underlying `Text`/`Natural` fields while
invalid values are rejected during decode. Quantity grammar, project-resource validity, and
provider-exact admission are distinct checks: the last rejects a valid byte quantity when the selected
provider cannot represent it exactly. Cross-field relations and live lifecycle authority remain
separate checks. See
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
    , service =
        None
          < Web : { publicPort : Natural, acceleratorPort : Natural }
          | Accelerator : { requestTimeoutSeconds : Natural }
          >
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
project codec's admitted type. Both rendering and decoding consume that same `CodecWitness`; do not
hand-maintain a parallel schema in project docs.

In the target, one finalized `specDigest` binds every codec. `context schema|render` exposes separately
named Production/Harness full-config artifact families; `service schema` exposes separately named
Production/Harness role-wire families. Harness role schemas contain typed private-bundle handles rather
than inline `TestPlaintext`. An empty service registry has an explicit empty result for both scopes.

The demo config also owns `service : Optional ServiceType`, where `ServiceType` is the real Dhall union
`Web { publicPort, acceleratorPort } | Accelerator { requestTimeoutSeconds }`. Core sees only the
project-owned selector that maps a config to an internal handler key; `service run` has no positional
variant. The demo selector validates its own payload bounds and role compatibility by convention. Core
currently accepts an arbitrary `cfg -> Either String String` selector and does not prove that it reads
this field, agrees with the registry, or carries the same config value into the handler.

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
artifact union, and `service schema` prints the project's validated-codec config type. Normal
commands do not silently create a missing config. The current shared loader always recommends
`<project> project init`; that is valid root-lifecycle recovery but is wrong for a missing service-leaf
config, because the resulting host-orchestrator config still fails the `service run` gate. The target
diagnostic names the command-specific writer (`service init`) or the exact owning parent projection.

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

Current helpers select a child frame and generate local witnesses, but they retain the full demo
`ProjectConfig` record, the parent's complete resource envelope/topology, and host/build/deploy fields
that a service or daemon does not need. This is structurally a context-adjusted copy, not yet a
least-authority payload.

The target parent reads and validates one config snapshot, computes one typed plan, and emits a
role-specific child payload at the boundary where the child process becomes real. Its validated topology
proof identifies the exact child frame, and its closed required-witness relation cannot be weakened by
omitting a witness. Service/daemon payload types cannot contain host-only settings or authority.

## Mutation And Reload

The target treats each active local file as one immutable startup snapshot. A parent reads/canonicalizes
its full config once, validates it to a fresh parent `configId`, and derives plan inputs plus a
role-specific descriptive wire. The runtime process verifies the exact mounted wire through
`RoleCodec scope specDigest fields` plus the matching verified secret bundle, mints a different fresh
local `configId`, and only then constructs
`ValidatedServiceRequest specDigest configId secretDigest fields service` with matching
`RoleParams specDigest configId secretDigest fields service` for a closed `ServiceProgram`. The hidden field row assigns each
field a closed `VisibleTo consumers` set, so framework/control fields can validate the wire while
plan-only fields never cross and never enter the handler payload. Current `service run` meets that
snapshot/role boundary: it canonically verifies one sibling value and closes the selected handler over
typed role fields plus a safe framework view. General `project up` lifecycle actions do not yet all
consume one plan-owned validated snapshot, so that wider guarantee remains target work.

Allowed writes are explicit and narrow: `project init` (re-run with `--force` to overwrite),
user-requested config-edit commands, and parent commands generating child configs. The canonical example of a parent generating a
child config is project-container handoff inside `project up`: the descent the demo's `context-init`
step declares carries the payload and the lift streams it, while that step's action body only announces
the boundary. The target gives projection and delivery one plan operation. Runtime status, discovered endpoints, locks, leader
election, build IDs, and secrets live in state stores or mounted secrets, not by silently mutating the
active config.

Phase 15.9 removes global reloads and passes
`ValidatedConfig scope specDigest configId (cfg scope)` through parent plan construction/closed operations.
Phase 18.6 verifies the child role wire/private bundle into a different local request and internally
packages it only with its matching closed handler program and
`ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
service effects`. The core-owned masked run-to-Exit operation privately invokes
`selectAndRunService`, consumes identity-indexed ready handles plus the retained receipt/lease package,
and always reaches Drain on selection/run outcomes; mutating effects additionally require journaled
target/operation-key/call-digest/fence authority minted from the live retained lease and exact Ready
session. The adapter receives no raw target/arguments beside its sealed prepared value; prepare or call
unknown retains the indexed session/package for exact reprobe and Drain/recovery. The parent/full config
and raw config-reading `IO` cannot cross that boundary.
Long-running daemons/services then require restart or an explicit typed reconcile to observe changes. A
future live-reload path must never replace authority fields such as context kind, capabilities, allowed
commands, parent chain, or project/binary identity in place.

## See Also

- [dhall_topology.md](dhall_topology.md) - how project-local, generated child, and per-case Dhall relate.
- [binary_context_config](../architecture/binary_context_config.md) - the authority and command-gating
  fields inside the local config.
- [resource_budgeting.md](resource_budgeting.md) - how resource budgets are projected and cordoned.
- [derived_project_standards.md](derived_project_standards.md) - project authoring rules.
