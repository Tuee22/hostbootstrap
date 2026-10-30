# Config Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md), [Dhall generation](../architecture/dhall_generation.md), [library hierarchy](../architecture/library_hierarchy.md), [Dhall topology](dhall_topology.md), [schema](schema.md), [authoring project binaries](authoring_project_binaries.md)

> **Purpose**: Describe the validated-codec `ConfigArtifact` registry and sampled render/decode evidence,
> the fresh-root `<project>.dhall` produced by the default `project init` mode, the writer's explicit
> role/output/policy modes, per-command config acquisition, and the plan projection and authenticated
> delivery of child `.dhall` — the parameters/context/witness the chain consumes, never the chain shape.

## TL;DR

- The opaque validated `StepPlan` is **code** — it is the project's single forward representation of
  the lift sequence. The `.dhall` is **parameters + context + witness**, never the plan shape. The
  canonical home of that model is
  [composition_methodology](../architecture/composition_methodology.md); this doc defers to it and
  covers only how the config text is generated.
- `HostBootstrap.Dhall.Gen` defines `ConfigArtifact` (constructor hidden) and opaque `CodecWitness a`. The
  witness validates normalized decoder `expected` and encoder `declared` expressions once;
  `artifactOf name codec value` derives both `schemaText` and `renderText` from it. Schema, decode, render,
  project/test config IO, and artifact registration therefore share one admitted pair. Semantic round
  trips remain sampled tests, not a proof for every value. Project-config writing (`project init`),
  decoding, and plan construction take the installed-identity/scope wrapper
  `ProjectCodec scope specDigest cfg` around that witness.
- `coreArtifacts` is the L0 registry (`budget`, `podResources`, `kindNode`). A project supplies its
  artifact delta through `ProjectSpec`; the read-only `context` command renders the in-scope registry's
  schemas and static example renders; the validated project-local `ProjectConfig` schema is
  printed by `service schema`, not `context`.
- The no-flag `project init` invocation writes the **fresh root** `<project>.dhall` — the
  host-orchestrator config with no parent frame, carrying resource budget and deploy knobs. The current
  writer also supports explicit role/output/write-policy flags. In the current demo,
  `context-init`'s action body is a no-op announcement: the VM config is projected/delivered by the
  composite `build-pb` action, the container config by the descent that same `context-init` step
  declares (`descendsVia`) plus the handoff, and service configs by deployment actions. The announcing
  row and the container payload are therefore one plan node. The root coordinator recursively
  projects every child config and plan into one exact catalog before effects, then gives a storeless
  executor only root-signed grants for that catalog node.
- `deployConfigText` renders a standalone numeric budget/pod artifact carrying a Dhall `fitsWithin`
  assertion. It is not the runtime `<project>.dhall`: that config has text quantities and no resolved pod
  set. Current decode/validation uses private scalar constructors and one project-owned resource value;
  later plan/provider admission rejects zero and backend-inexact budgets. The authoritative complete-workload fit and partition come from `Cluster.Budget`;
  the static `fitsBudget` helper is descriptive.
  Selected fixtures have byte-stable
  render → decode → re-render tests; that is not a universal property of arbitrary `ConfigArtifact`.

## The `ConfigArtifact` Registry

[`HostBootstrap.Dhall.Gen`](../../core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs) is the
generation module. An artifact stores three `Text` values behind ordinary readers:

| Reader | Value `artifactOf name codec value` stores |
|---|---|
| `artifactName` | `name`, the label `context schema` prints |
| `schemaText` | `codecSchemaText codec`, admitted only after the normalized decoder and encoder type expressions are judgmentally equal |
| `renderText` | `renderValue codec value`, using the same admitted encoder |

The constructor and record fields are hidden, so `artifactOf` builds an artifact from its admitted
`CodecWitness`. The exported `artifactName`, `schemaText`, and `renderText` functions inspect it without
exposing record-update syntax; callers cannot replace its admitted schema or rendering.

Matching type expressions do not prove semantic encode/decode behavior. Representative
render → decode → re-render tests retain that separate responsibility.

`coreArtifacts` is the L0 registry:

| Artifact | Type reflected | Sample value |
|----------|----------------|--------------|
| `budget` | `HostBootstrap.Config.Vocab.Budget` | `Budget 4 8 20` |
| `podResources` | `HostBootstrap.Config.Vocab.PodResources` | `PodResources 1 1 1 1 2` |
| `kindNode` | `HostBootstrap.Config.Vocab.KindNode` | `KindNode 4 8 20` |

A project binary supplies its own artifacts in `ProjectSpec`; `HostBootstrap.Command` concatenates them
onto `coreArtifacts` for the inherited inspection surface. Project artifact names must be unique and must
not reuse a core artifact name: `finalizeProjectSpec` refuses the first with `DuplicateProjectArtifacts`
and the second with `CoreArtifactShadowing`, so every label in the `context schema` output names exactly
one artifact. The registry is the schema-gen stream of the extension contract (the command surface itself
is fixed and is not a stream; see [library_hierarchy](../architecture/library_hierarchy.md)). How the
`ProjectCodec` scope/identity wrapper relates to the bare validated codec is described in
[dhall_generation](../architecture/dhall_generation.md).

## `project init`: Fresh-Root Default And Explicit Writes

`project init` is a config-free writer whose default mode bootstraps the **root** config. With no
role/output/write-policy flags it writes the executable-sibling host-orchestrator config — the one frame
with no parent — refuses an existing output, and provisions or validates that installation's identity:
the handoff pair (`<exe>.handoff.key`, `<exe>.handoff.pub`), the distinct build-signing key
(`<exe>.build.key`), and the activation pair (`<exe>.activation.key`, `<exe>.activation.pub`) that signs
service activations:

```sh
<project> project init --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1
```

The parser also supports `--role ROLE`, repeatable `--also-role ROLE`, `--output FILE` (or `-o FILE`),
`--dockerfile PATH` (the Dockerfile path recorded in the config; the project default when omitted),
`--source-root DIR` (the source root recorded in the generated context; the project assembler's default when
omitted), and the resource and deploy overrides `--cpu`, `--memory`, `--storage`, and `--ha-replicas`
(project defaults when omitted). `--force` and `--if-missing` are mutually exclusive spellings of one
`ExistingOutputPolicy`: `--force` overwrites an existing output, `--if-missing` leaves it byte-for-byte
untouched, omitting both refuses an existing output, and supplying both is a parse error. Thus fresh-root behavior is the
default, not a restriction on every explicit writer invocation. The parser uses one shared `InitArgs`
value; role additions pass through the closed `roleAdditionAllowed` relation and `addRole` validating
smart constructor before a config is rendered.

Identity provisioning (`provisionInstalledIdentity`) is narrower than config generation: it runs only for
the root role at the executable's actual sibling config path. It retains valid material across `--force`,
repairs a missing public half of the handoff or activation pair from the retained secret, and refuses an
orphaned public half of either pair, a malformed key, or a mismatched pair. Explicit child roles,
`service init`, and arbitrary output paths never mint root secrets.

The two steps run in order: config publication (or the `--if-missing` keep) comes first, then identity
provisioning. A refused identity therefore exits 1 and leaves the newly written root config in place, and a
plain rerun refuses that existing output. After repairing the identity files, rerun with `--if-missing`,
which keeps the written config and runs identity provisioning again.

`publishScopedProjectConfigFile` renders through the scoped codec into a binary temporary in the output's
directory, flushes and closes it, then decides the policy at publication. The default and `--if-missing`
use a no-replace hard link; a taken name returns `ConfigRefusedExisting` or `ConfigKeptExisting`.
`--force` atomically renames the complete temporary over the output. Success returns `ConfigPublished`;
`initAction` handles those three outcomes without an earlier existence decision. A failed link re-inspects
the destination, including a dangling link; if the name is absent, the original IO failure propagates.
Publication and failure both run temporary-file cleanup.

An omitted source root reaches `psAssemble` unchanged. The project owns its default; a relative root
resolves against the config's anchor directory when admitted, rather than being filled from the writer's
working directory by core.

This ordinary initializer is not resource ownership evidence. Harness-generated config uses the stronger
`HostBootstrap.Harness.GeneratedConfig` bracket. It refuses an object already at the path before any record
is written and never adopts or replaces it, binds the exact file identity and payload it installs, and
rechecks both before cleanup: it removes only a file whose re-observed identity and payload both match,
leaves an edited file intact, and reports a `GeneratedConfigConflict` otherwise.

The values it writes are NOT core defaults: `project init` passes parsed flags to
`psAssemble (ProductionAssembly args)` and renders the resulting complete config. The flags are optional
because the project assembler supplies every field — core ships no default config values, so the no-flag invocation
renders the project's own defaults (for the demo, `6/10/80`, `haReplicas = 1`, `docker/Dockerfile`,
`message = "Hello, world!"`). The same scope-polymorphic assembler handles each Harness request under
fresh exact-run authority; see *The Structural Assembler* below.

The written config shape carries the Dockerfile path, the editable resource budget, the deploy
knobs, any project-extended field (the demo's `message`), and the declared root context (a single
host-orchestrator frame). The rendered Dhall hoists the
repeated `ContextKind`/`ProviderKind`/`WitnessKind`/`Capability`/`CommandClass` unions into top-level
`let` bindings (`HostBootstrap.Dhall.Hoist`) so the file stays compact and standalone — no imports,
decodable in-process. Optional structural variation (for example, skip the VM and descend straight to
Docker) is a flag on this project config, so `chain cfg` stays a pure function of the project parameters.

The root config is the user's editable surface. An existing-frame Production invocation decodes and
admits it once as an immutable `ValidatedConfig ... configId ...` snapshot; plan construction and every
step consume that value without reopening the sibling file. Every deeper frame's config is generated
rather than hand-edited. The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
owns that one-read Production boundary.

## The Structural Assembler

Core stores one `psAssemble` polymorphic over Production/Harness scope. In the demo, `demoAssemble`
handles `ProductionAssembly` with the default message and handles `HarnessAssembly` with the selected
validated variant message. `test init` follows the separate `psTestInit` path because it writes the thin
`<project>.test.dhall` value rather than project config. The harness builds its run config
**functionally** in process and never shells out to `<project> project init`.

`ConfigAssembly` admits only project-declared read-only inputs and no arbitrary `IO`, process, backend,
write, or lifecycle operation. Production and Harness wire schemas are admitted by separate mapped
codecs, and Harness admission closes over exact run config authority. Per-role projection derives a narrowed immutable `RoleParams` bundle from the validated assembly result.
The service registry retains it with the matching typed program, declared effect row, and backend; signed
runtime selection decodes that exact narrowed role wire.

The on-disk config is normally **absent** after a build: nothing creates it as a side effect of building
the binary, and Python does not initialize or trigger config creation. Existing-frame commands
(`project up|down|destroy` and `check-code`) fail fast (exit 1) when their sibling
`<project>.dhall` is missing. They classify the descriptive framework record before full-config decoding.
A positive service-role declaration exits 1 with `project config: <path> holds a service role wire; this
command requires a full project config`, before the command action runs. Missing or malformed framework
records go to the existing full-project decoder, which retains its own diagnostic for invalid input.
That decoder is retained by `FrameworkEnvelopeCodec`; sibling gates derive its descriptive scope tag from
the codec's scope index through `KnownScopeKind` and reuse the same source/import-root settings at both
stages. The other inputs are intentionally different: `project init`,
`service init`, and `test init` are config-free writers; `service schema` and
`context path|schema|render` are static and config-free; `context inspect` reads the sibling;
`context show [FILE]` reads its selected/default file; and `test run` reads `<project>.test.dhall`,
refuses an existing sibling project config after the abandoned-run sweep reclaims an interrupted run's own
config (so only a foreign config blocks the run), and writes/removes its run config under the four § EE
ownership clauses of `HostBootstrap.Harness.GeneratedConfig`. Complete durable resource-record
verification and rehydration belongs to the
[recovery and migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md). `service run` instead consumes platform-installed immutable activation coordinates and never reads the
sibling full project config. There is no auto-init backstop.

## Child `<project>.dhall`: Plan Projection and Authenticated Delivery

The finalized specification supplies the restricted project-owned child projector. The root catalog
reconstructs and validates every exact child plan, configuration payload, digest binding, frame edge, and
one-layer route before effects. The declared descent belongs to its plan node; the node's descriptive action
may announce the boundary while the interpreter performs the authenticated delivery.

VM bootstrap establishes the executable before runtime admission. A container image already carries it.
The receiver verifies the root scope capsule, independently installed key, exact payload binding, and grant
before dispatching local work. Children return observations to the root and receive no durable store or signer.
Services use a separate narrowed role wire installed in an immutable signed activation revision.

## `context`: Read-Only Inspection

`context` is read-only, but not every subcommand reads the same input. `context inspect` reads the
executable-sibling `<project>.dhall`; `context show [FILE]` reads the selected/default file; and
`context path`, `context schema`, and `context render` use static binary-owned information and need no
project config. None applies a mutating command-authority gate or writes a file — minting child configs is
an internal lifecycle responsibility, not a user verb. In the demo that work happens at the composite
bootstrap, the plan-declared descent plus handoff, and the deployment seams described above, each bound to
its node in the root-validated catalog.

The registry surface `context schema` prints is the transitive union of the in-scope artifacts' schemas
(`coreArtifacts ++ project artifacts`), each labelled by name — the validated project-local
`ProjectConfig` schema is printed by `service schema`, not `context schema`. For the bare core registry the
output is exactly the committed snapshot
[`context_schema_core.txt`](../../core/hostbootstrap-core/test/golden/context_schema_core.txt); record
fields appear in normalized (alphabetical) order:

```text
-- budget
{ cpu : Natural, memory : Natural, storage : Natural }

-- podResources
{ cpuLimit : Natural
, cpuRequest : Natural
, memoryLimit : Natural
, memoryRequest : Natural
, replicas : Natural
}

-- kindNode
{ cpus : Natural, memory : Natural, storage : Natural }
```

Literal command output is guarded by three committed snapshots:
`context_schema_core.txt` for the bare core registry, `context_schema_consumer.txt` for an ordered
consumer delta, and `service_schema_consumer.txt` for the project-config schema. A changed, omitted, or
reordered consumer artifact fails its owning snapshot; the project `cfg` cannot be smuggled into the
`context schema` expectation. Every schema in those outputs came from an admitted codec.
The static example renders `context` materializes are each the `renderText` of an artifact — the
`ToDhall` embedding of its canonical value.

## The Standalone Budget Artifact

`deployConfigText coreImport budget pods` composes its explicitly numeric budget and pod arguments into
a standalone artifact carrying a budget assertion:

```dhall
let C = <coreImport>
let budget = { cpu = 4, memory = 8, storage = 20 }
let pods = [ … ]
in  { budget = budget
    , pods = pods
    , _fitsBudget = assert : C.fitsWithin budget pods === True
    }
```

`coreImport` is the Dhall import text for `Core.dhall` — an absolute path in tests or a bundled path in a
deployed binary. Because this artifact contains both numeric operands, Dhall can check it at evaluation.

It must not be confused with the demo's runtime `ProjectConfig`. That config carries Kubernetes
`memory`/`storage` quantities as `Text` and no pod set, so there is nothing meaningful to attach this
assertion to. Its decode ring is the typed `Quantity`, resource-floor, replica, port, and timeout
refinements. The exact plan admission resolves the declared workload and proves its fit through `Cluster.Budget`.
Attaching `fitsWithin` to every generated project config is not meaningful because the config itself has no
resolved pod set. Static `demoPods` output is an API example, not an applied scheduler or wall authority.

## The Round-Trip Invariant

For covered values, a test proves a byte-stable render → decode → re-render round trip. That test is
useful evidence about the exercised values, but it does not prove semantic agreement for every value.
The opaque `CodecWitness a` separately closes the type-expression seam by refusing unequal normalized
expressions; the project boundary wraps it as `ProjectCodec scope specDigest cfg`. Round-trip and
property tests remain necessary for semantic encode/decode behavior. The
standards-level statement of the model lives in
[derived_project_standards](derived_project_standards.md) and
[development_plan_standards § P, Q, T, X](../../DEVELOPMENT_PLAN/development_plan_standards.md); the
Dhall tier topology is in [dhall_topology](dhall_topology.md), and the current-versus-target runtime
authority distinction is in
[binary_context_config](../architecture/binary_context_config.md).

## Current Status

The generation layer comprises the validated-codec `ConfigArtifact` registry, the standalone
`deployConfigText` budget artifact, parent-to-child projection helpers, union hoisting, exact command
snapshots, and representative round-trip tests. An exhaustive inventory derives every type-valued
`Core.dhall` export and judgmentally compares it with its named admitted Haskell codec; hand-written
functions remain under evaluation tests.

The surface that drives them is the recursive lifecycle command: the default `project init` invocation
writes a fresh root host-orchestrator config and refuses an existing output, while
`--role`/`--also-role`/`--output` plus `--force` or `--if-missing` select the explicit writer modes.
Parent-to-child projection happens at composite bootstrap, the plan-declared descent plus handoff, and
workload deployment actions; the chain's `context-init` action body is only an announcement, though it is
the node that carries the container descent. `context schema`/`context render` are ungated static
inspection verbs; `context inspect` and `context show` perform the decode-only reads described above.
Ordinary container config delivery encodes the explicitly supplied stdin as a ustar projection for
`docker cp` into a stopped container, then starts its image entry point; the child binary does not receive
the projection on stdin. Authenticated lifecycle children instead receive their canonical config inside
the Offer over their protocol channel (see
[binary_context_config](../architecture/binary_context_config.md) and the
[ordinary delivery contract](../architecture/composition_methodology.md#the-recursive-project-up-interpreter)).
The root coordinator's
catalog admission, authenticated scope, storeless child execution, and root-signed node grants are built;
see the
[authenticated handoff and child admission phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md).
