# Project-Local `<project>.dhall` Schema

**Status**: Authoritative source
**Supersedes**: static-base `hostbootstrap.dhall`; the three-execution-model / substrate-keyed / lifecycle `hostbootstrap.dhall` schema (Container/HostBinary/HostDaemon, Cluster/NoCluster, Mounts, force-target)
**Referenced by**: [../README.md](../README.md), [prerequisites.md](prerequisites.md), [derived_project_standards.md](derived_project_standards.md), [dhall_topology.md](dhall_topology.md), [authoring_project_binaries.md](authoring_project_binaries.md), [secrets.md](secrets.md), [../architecture/dhall_generation.md](../architecture/dhall_generation.md), [../architecture/generic_project_model.md](../architecture/generic_project_model.md)

> **Purpose**: Define the project-local Dhall configuration file each project binary reads from beside
> itself.

## TL;DR

- The runtime configuration file is the executable's sibling `<project>.dhall`, for example
  `./.build/hostbootstrap-demo.dhall` beside `./.build/hostbootstrap-demo`.
- The Python bootstrapper derives the Cabal-file stem, the package name, and the single executable-stanza
  name, requires all three to be equal, builds `exe:<executable>` into `./.build/<executable>`, and never
  reads or writes Dhall.
- The project binary owns scope-correct validated-codec schema text, assembly, rendering, decoding/validation,
  downstream projection, and help text for the local config. An opaque `CodecWitness` rejects unequal
  normalized encoder/decoder type expressions before decode or mutation; representative round trips
  separately test semantics.
- Normal commands fail fast when the sibling config is missing or incompatible. Ungated exceptions are
  limited to help and explicit config inspection/initialization commands, including static
  `context render`. `service run` never reads the sibling: it is configured by its signed activation
  revision.
- Host, VM, ad-hoc container, daemon, and service copies use the same filename rule but different file
  contents. The role is a field inside the Dhall value, not part of the filename.

## Current Status

The Python bootstrapper does not read or write Dhall. The Haskell schema has a project-local config shape,
`project init` can generate role-specific defaults through the project-owned restricted assembler,
current pure projection helpers derive context-adjusted full child records, and normal command gating
reads the descriptive context embedded in the sibling `<project>.dhall`.
See
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) and
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md).

The schema is topology-aware. Runtime context includes an execution topology, `currentFrame`, and runtime
witnesses that catch mismatches such as "VM project container command running on the host Docker daemon"
before side effects. The
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)
implements complete graph validation, the exact required-witness set, and closed role-addition checks.
Those decoded fields remain descriptive rather than opaque authority: callers can still construct or
update a context value, and an effectful command gate must independently admit it.

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
current `<project>.test.dhall` decodes `testResources` plus a declarative `testVariants` list;
`demoTestMatrix` projects every compiled case across those decoded variants. `all` is a typed parser
selector and is never stored schema data. This typed foundation does not restore a core config type. The
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the matrix.

This is why root/harness initialization defaults must be project-owned: a naive one-size `4/8/20`
default (only the sample value of core's `budget` render artifact, not a core-shipped config default)
cannot bootstrap the demo (its `deploy-vm` gate requires `6/10/80`,
`demoFullLifecycleResources`), so the demo's `psAssemble` returns its real budget rather than inheriting
any core default. Service-role parameters are mandatory project fields rather than a second default
source. See
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md).

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
| Cluster service or daemon binary | none read by `service run`; it reads the signed activation revision named by `HOSTBOOTSTRAP_SERVICE_ACTIVATION` |

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
| Runtime context | `hostbootstrap-core` / project binary | declared identity, parent chain, topology frames, current frame, runtime witnesses, context kind, role name, capabilities, allowed command classes, and child-context rules; independent installed or authenticated evidence supplies opaque authority |

The record decode is strict about field presence: every field in the project's config type is mandatory,
so a missing field fails the `FromDhall` decode. That does not make semantic validation total. The demo
now has one project-owned `resources` value; `BinaryContext` carries no independently editable budget
copy, and full child-config projection preserves the already-refined project value. One project-owned
assembler is the structural default source, and finalized service-role projection invents no missing
values. Plan-indexed provider admission and partitioning are implemented as a pure foundation; no
production lifecycle path consumes that authority to apply a budget wall, a gap
[resource_budgeting.md](resource_budgeting.md#current-status) records and the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owes. The lifecycle provider boundary is separate:
`SubstrateProvider` is an opaque Haskell descriptor selected from the closed provider kind, and its
opaque nominal managed provider/share/alias authorities are minted only by prepared backend settlement.
The Dhall `ProviderKind` below is descriptive topology data; it cannot construct a provider descriptor,
choose a raw probe, mint a managed wrapper, or turn Direct into physical-host stop/delete/guest authority.
The demo's prepared provider/alias consumer is owned by the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). See
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

A host-level config has the same top-level shape as the project's config type (for the demo, its own
`ProjectConfig scope` type; core defines no config type). A project may add its own mandatory fields with
no core change: the demo carries a `message : Text` field its web service renders, a `runProfile` that
selects Production or Harness cluster identity (`ProductionRun` or `HarnessRun` with the run's name), and
the service parameters `webServiceConfig` and `acceleratorServiceConfig`. The example below shows the
demo's root host-orchestrator config with every field; `project init` emits the exact text, whose field
order and formatting may differ.

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
    , runProfile = < HarnessRun : Text | ProductionRun >.ProductionRun
    , webServiceConfig = { publicPort = 8080, acceleratorPort = 8081 }
    , acceleratorServiceConfig = { requestTimeoutSeconds = 30 }
    , context =
      { project = "hostbootstrap-demo"
      , binary = "hostbootstrap-demo"
      , sourceRoot = "/path/to/hostbootstrap/demo"
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
project config's admitted type. Each printed schema comes from the codec that also decodes and renders the
same value, so the printed text is the type the decoder accepts:

| Command | Prints | Derived from |
|---|---|---|
| `context schema` | each registered artifact's schema, labelled by name | that artifact's own `CodecWitness`, through `artifactOf` (see [config_generation.md](config_generation.md#the-configartifact-registry)) |
| `service schema` | the full project config schema | the project's `ProjectCodec`, which wraps the `CodecWitness` that `project init` renders with and the sibling loader decodes with |
| `service schema` | one role-wire schema per registered service | each service's `CodecWitness` over its `RuntimeRoleWire` fields, which `service run` decodes |

Do not hand-maintain a parallel schema in project docs.

The project codec and the finalized service registry carry the same `specDigest` type index, so the role
wires belong to the same finalized specification as the full config. `service schema` prints the role-wire
schemas under two labelled families, Production and Harness; both are rendered from the one finalized
registry and are identical. An empty service registry prints an explicit `services = []` and
`schemas = []` under both labels. `context schema|render` prints one unscoped artifact registry.

The demo's service parameters are ordinary mandatory fields, `webServiceConfig` and
`acceleratorServiceConfig`; the demo's `ServiceType` union is a validation and schema vocabulary, not a
config field. Core registers each service through `serviceProgramDefinition`: a `ServiceDefinition` pairs
a per-service projection `forall scope. cfg scope -> Either String (Maybe fields)` with a `CodecWitness`
over `RuntimeRoleWire fields` and a typed program over those same fields. `service run` has no positional
variant. `withSelectedServiceProgram` runs every projection on the effective config and refuses when none
or more than one selects it, and the selected projection's fields are exactly what the program receives.
What core does not prove is the projection's content: the demo's `selectWeb` and `selectAccelerator`
choose by context kind and check port and timeout bounds through `configuredServiceVariant` by convention.

The `message : Text` field is a worked example of a project-extended field flowing all the way to the
workload, with no core-owned slot. `<project>.dhall` carries `message`; the demo's `selectWeb` projection
copies it into `WebRoleFields.servedMessage`; service deployment installs that narrowed role wire as
`role.dhall` inside the signed activation revision; `service run` decodes it there and `runWeb` passes
`servedMessage` to `serveWebWithConfig`; the API's `BudgetView.message` carries it across the
`purescript-bridge` round-trip; and the SPA renders it into its `#message` element. Editing a sibling file
or a ConfigMap does not change the served message; a new activation revision does. It is a mandatory field
on the demo's OWN config type — core owns no project-specific field and ships no generic extra slot.

## Default Generation

The project binary provides an ungated initialization command, for example:

```bash
<project> project init --output ./.build/<project>.dhall
```

The generated file is a valid default; `project init --help` names the editable options (`--dockerfile`,
`--cpu`, `--memory`, `--storage`, `--ha-replicas`, `--source-root`), `context schema` prints the in-scope
artifact union, and `service schema` prints the project's validated-codec config type. Normal
commands do not silently create a missing config. The shared sibling loader behind
`withSiblingProjectConfigContext` reports a missing sibling with the recovery `<project> project init`,
which is the right writer for the root-lifecycle and inspection commands that use it. `service run` does
not use that loader: it requires the absolute runtime coordinates `HOSTBOOTSTRAP_SERVICE_ACTIVATION`,
`HOSTBOOTSTRAP_ACTIVATION_KEY`, and `HOSTBOOTSTRAP_AUTHORITY_STORE`, refuses a missing one by name, and
verifies the signed activation revision rather than any sibling `<project>.dhall`. A broken service pod is
diagnosed from its activation revision and runtime coordinates, not from a sibling config.

The derived Dockerfile never runs `project init`. It installs the coordinator-supplied image-build config
from the `hostbootstrap-build-config` BuildKit secret beside the builder binary, so the image cannot mint its
own build config or authority; the canonical home of that protocol is
[derived_dockerfile.md](derived_dockerfile.md#the-check-code-gate).

A lifted project container receives its parent-generated VM-project-container config, with topology
witnesses, streamed in place over the handoff channel; it does not rely on the image-build config. Services
and daemons receive a narrowed role wire in a signed activation revision instead of a full config.

## Downstream Projection

Values may need to flow from the host config to children: resource limits, image names, ports, HA replica
counts, chart values, storage sizes, and feature flags. The child must not read the host config directly.

The root catalog derives each lifecycle child configuration from the exact admitted parent plan and
validates its frame, topology, payload digest, and one-layer route. Lifecycle children may retain project
fields needed to rebuild their plan; they receive no root store or signing authority.

Service and daemon activation instead carries a narrowed role wire. Its codec contains only framework
validation and the selected service's projected fields. The handler receives that exact immutable
`RoleParams` bundle and cannot inspect the sibling full project configuration.

## Mutation And Reload

A lifecycle invocation validates one exact configuration and retains its plan/snapshot lineage through
root coordination. A child independently decodes the authenticated projected payload and compares its
reconstructed plan with the catalog binding. Editing a sibling file does not mutate an already admitted plan.

A service opens one immutable signed activation revision. Runtime verification measures the role wire,
private bundle, executable, and instance before typed selection constructs its request and program from the
same decoded role fields. The declared effect row is checked against the signed ceiling, and Ready supplies
its acquired resource handles. There is no second config projection beside the request and no unrestricted
IO handler selector.

Reload requires the supported new revision/admission path; changed files or a mixed activation revision
refuse. See [binary context](../architecture/binary_context_config.md),
[composition methodology](../architecture/composition_methodology.md), and the
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Validation

- `DhallGenSpec` (core) rejects a mismatched decoder/encoder pair before decode or side effects, proves an
  artifact's schema and rendering come from one witness, compares every `Core.dhall` type with its admitted
  codec, and checks byte-identical render → decode → re-render for representative values.
- `SchemaSpec` (core) decodes valid project-local configs, refuses malformed and wrong-typed fields with
  typed errors, re-renders every default role config stably, and checks child projection and role
  authority.
- `CLISpec` (core) pins `context schema` and `service schema` output against the committed snapshots under
  `core/hostbootstrap-core/test/golden/`.
- `ConfigSpec` (demo) round-trips the demo's `ProjectConfig` and `<project>.test.dhall`, checks the
  demo's defaults and flag overrides, child projections, and service-role selection and bounds.

All four run in the host static gate defined by
[development_plan_standards.md § JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness).

## See Also

- [dhall_topology.md](dhall_topology.md) - how project-local, generated child, and per-case Dhall relate.
- [binary_context_config](../architecture/binary_context_config.md) - the authority and command-gating
  fields inside the local config.
- [resource_budgeting.md](resource_budgeting.md) - how resource budgets are projected and cordoned.
- [derived_project_standards.md](derived_project_standards.md) - project authoring rules.
