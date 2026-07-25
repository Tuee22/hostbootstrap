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
- The project binary owns encoder-declared schema text, default rendering, decoding/validation,
  downstream projection, and help text for the local config. Encoder/decoder type agreement is tested
  for covered values but is not enforced by one current codec witness.
- Normal commands fail fast when the sibling config is missing or incompatible. Ungated exceptions are
  limited to help and explicit config inspection/initialization commands, including static
  `context render`.
- Host, VM, ad-hoc container, daemon, and service copies use the same filename rule but different file
  contents. The role is a field inside the Dhall value, not part of the filename.

## Current Status

The Python bootstrapper does not read or write Dhall. The Haskell schema has a project-local config shape,
`project init` can generate role-specific defaults, current pure projection helpers derive
context-adjusted full child records, and normal command gating reads the descriptive context embedded in
the sibling `<project>.dhall`.
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
is project-defined, not the fixed `ProjectConfig`. Every field is mandatory and a missing field fails the
strict decode. Core owns no defaults; current root/harness initialization defaults come from the
project-owned `psInit`, while demo service projection still has separate fallbacks. Secret-bearing fields use
the pure `SecretRef = <Vault|TransitKey|Prompt|TestPlaintext>` vocabulary (see [secrets.md](secrets.md))
so raw `Text` cannot occupy a secret-ref field and core never resolves a secret. The
`TestPlaintext` branch remains representable and must currently be excluded from production by the
consumer's code-check policy.
See the [generic_project_model.md](../architecture/generic_project_model.md) design and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).
The development plan owns typed test case/variant identity; it does not restore a core config type.

This is why root/harness initialization defaults must be project-owned: a naive one-size `4/8/20`
default (only the sample value of core's `budget` render artifact, not a core-shipped config default)
cannot bootstrap the demo (its `deploy-VM` gate requires `6/10/80`,
`demoFullLifecycleResources`), so the demo's `psInit` returns its real budget rather than inheriting any
core default. The separate service-projection fallbacks are a defect, not a second sanctioned default
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

Three names currently exist at different boundaries:

| Name | Current source | Current use |
|---|---|---|
| Cabal-file stem | the single top-level `*.cabal` filename | stored as Python's `ProjectBuildSpec.project`; it does not select the executable |
| executable | the single `executable <name>` stanza | `cabal build exe:<name>`, `cabal list-bin exe:<name>`, and `./.build/<name>` |
| CLI program/project name | the `String` passed to `runHostBootstrapCLI` | sibling `<name>.dhall` lookup and the expected `project`/`binary` context fields |

Python rejects zero or multiple top-level Cabal files and zero or multiple executable stanzas. It does
**not** currently require the Cabal-file stem, executable stanza, and Haskell CLI program name to match.
The demo chooses `hostbootstrap-demo` for all three, so the defect is latent there rather than absent.

The target has one opaque `ProjectIdentity`. Discovery succeeds only when the Cabal-file stem and sole
executable stanza agree; the Haskell entrypoint derives and validates the same identity from the running
executable instead of accepting an unrelated free `String`. Build target, `./.build/` destination,
sibling config filename, context identity, resource prefix, and ownership records are projections from
that value. APIs do not accept those names independently, so a binary/config/resource identity mismatch
cannot be assembled. Phase 6 owns that cross-language boundary repair.

## Config Shape

The exact project-level fields are binary-owned and may be extended by a consumer, but every local config
has two conceptual sections:

| Section | Owner | Purpose |
|---|---|---|
| Project settings | project binary | user-editable inputs such as Dockerfile path, resource budget, deploy knobs, replicas, ports, feature flags, and any project-extended field (the demo's `message`) |
| Runtime context | `hostbootstrap-core` / project binary | declared identity, parent chain, topology frames, current frame, runtime witnesses, context kind, role name, capabilities, allowed command classes, resource envelope, and child-context rules; opaque authority remains a target |

The record decode is strict about field presence: every field in the project's config type is mandatory,
so a missing field fails the `FromDhall` decode. That does not make semantic validation total. The demo
also keeps independent top-level `resources` and raw `context.resourceEnvelope`, and service projection
currently supplies hard-coded port/timeout fallbacks outside `psInit`. The target has one project-owned
assembler/default source and one validated budget authority; no projection invents missing values. See
[config_generation.md](config_generation.md) and the
[generic_project_model.md](../architecture/generic_project_model.md) design). The on-disk config a normal
command reads is therefore a complete value, not a sparse override.

The demo decoder checks field **presence** and selected top-level scalar refinements:
`memory`/`storage` decode through a typed `Quantity`, `haReplicas`, service ports, and timeouts use bounded
newtypes, and `Resources` enforces its CPU floor. Their `ToDhall` instances remain transparent, so the
reflected Dhall schema still shows the underlying `Text`/`Natural` fields while invalid values are
rejected during decode. Constructors remain public, zero/bare-byte/provider-invalid quantities and the
raw applied envelope remain possible, and cross-field relations/lifecycle authority are separate checks.
The type-level profile/capability/resource repairs remain open. See
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
current `ToDhall` encoder's declared type. The matching `FromDhall` decoder is separate; the target
validated codec refuses unequal normalized type expressions. Do not hand-maintain a parallel schema in
project docs.

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
artifact union, and `service schema` prints the project's `ToDhall` encoder-declared config type. Normal
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
plan-only fields never cross and never enter the handler payload. Current code
does not meet that contract. `project up` constructs its chain/frame projection from the first decode,
then many demo steps reload the sibling file; `service run` selects from the first decode, then both demo
handlers reload it. A replacement can therefore mix two configs in one invocation.

Allowed writes are explicit and narrow: `project init` (re-run with `--force` to overwrite),
user-requested config-edit commands, and parent commands generating child configs. The canonical example of a parent generating a
child config is project-container handoff inside `project up`: the current demo's `psFrameContext`
derives the payload and the lift streams it, while the named `context-init` action only announces that
boundary. The target gives projection and delivery one plan operation. Runtime status, discovered endpoints, locks, leader
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
