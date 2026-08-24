# Dhall Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md), [binary context](binary_context_config.md)

> **Purpose**: Define the generated Dhall configuration model — `.dhall` as **parameters + context +
> witness** (never the plan shape), the current split ownership of child projection/delivery and its
> target unification, and the load-bearing distinction between validated codec schemas, hand-written
> vocabulary types, and evaluation-tested functions.

## TL;DR

- `.dhall` carries **parameters + context + witness**, never the plan. The opaque validated `StepPlan`
  is code and is the project's forward identity; the `.dhall` is the typed data
  a binary reads to learn *which frame it is in* and *what budget it may spend*. The
  [composition_methodology](composition_methodology.md) is the canonical home of that model; this doc
  describes the Dhall it consumes and emits.
- **Parameters** are the root resource knobs (`--cpu/--memory/--storage/--ha-replicas`). **Context**
  names the binary's position in the topology (`topologyFrames`/`currentFrame`). **Witness** is the set
  of locally checkable `runtimeWitnesses` a binary proves before it acts. See
  [binary_context_config](binary_context_config.md).
- The root `<project>.dhall` is the fresh-root default of the config-free `project init` writer; explicit
  role/output/policy flags also support other current init uses. In the demo, the named
  **context-init** action body is only a no-op announcement: VM projection and streaming occur in
  the composite `build-pb` action, container projection is carried by the descent that same step
  declares and delivered by the handoff, and service/daemon projection occurs in deployment actions. The target plan makes
  projection plus delivery one typed operation.
- The binary-generated tiers are composed from **three vocabulary layers** — `Core.dhall` (L0),
  `Daemon.dhall` (L1), `App.dhall` (L2) — each embedding the one below (`let C = ./Core.dhall`).
- The lower-layer opaque `CodecWitness a` validates normalized `FromDhall` decoder `expected` and
  `ToDhall` encoder `declared` expressions once and is the only schema/decode/render input.
  `ConfigArtifact` construction and every project/test config IO path consume that witness. The target
  project boundary additionally wraps it with installed identity and lifecycle scope as
  `ProjectCodec scope specDigest cfg`.
- The budget **functions** (`fitsWithin`, `split`) are **hand-written Dhall** in `Core.dhall` and
  drift-controlled by evaluation tests, not reflection. Project configs intentionally do not attach a
  `fitsWithin` assertion: they carry text quantities and no pod set. Typed scalar refinements form the
  decode ring. Haskell `fitsBudget` exists and is unit-tested, but lifecycle bring-up does not yet call
  it with the complete topology-derived workload set.

## Three Roles Of `.dhall`: Parameters, Context, Witness

A `.dhall` value is the typed data a binary reads — it is **not** the lift plan, which lives in Haskell
as an opaque validated `StepPlan`. Each `.dhall` plays three roles:

| Role | What it carries | Read for |
|------|-----------------|----------|
| Parameters | the root resource knobs | plan fragments are pure functions of these, so the finalized plan is determined by the project `.dhall` |
| Context | the binary's `topologyFrames` + `currentFrame` — its position in the global lift composition | the binary reasons about which segment of the plan it owns |
| Witness | the `runtimeWitnesses` a binary must verify locally before acting | per-frame fail-fast on handoff: a binary that cannot witness its declared frame exits non-zero |

The resource knobs are **root parameters**, so plan construction is a pure function of root params rather than
branching on ambient state. The context and witness fields are the `binary_context_config` "know your
place" description and current mismatch gate; opaque authority is a separate target. This doc owns how
the data is generated and projected. See
[dhall_topology](../engineering/dhall_topology.md) for where the context/witness fields sit in the
configuration model.

## Configuration Roles

| Role | File | Produced by | Read by |
|------|------|-------------|---------|
| Root runtime config | `<project>.dhall` | the default `project init` invocation, then user-edited for host-level settings | existing-frame project-binary commands |
| Child runtime config | `<project>.dhall` at the child executable location | current demo: composite VM bootstrap, the plan-declared descent plus handoff, or workload deployment action; target: one plan operation that owns projection and delivery | existing-frame child-binary commands |
| Binary-generated | static registry examples plus standalone typed artifacts | the project binary, from the reusable vocabulary | the project binary / test harness |

Python has no Dhall-facing role. The local config declares where the already-built binary is running and
which commands it may accept; current gates check that description, but the decoded fields are not yet
opaque authority. Read-only `context` is the inspection surface for the
sibling `.dhall` and the rendered lift composition; runtime deploy and child projections are minted as
steps that first validate the active local config. Everything richer is binary-generated. See
[dhall_topology](../engineering/dhall_topology.md), [schema](../engineering/schema.md), and
[binary_context_config](binary_context_config.md).

Config acquisition is command-specific. `project init`, `service init`, and `test init` are config-free
writers; `service schema` and `context path|schema|render` are static and config-free; `context inspect`
reads the executable-sibling config and `context show [FILE]` reads its selected/default file without a
mutation-authority gate. `test run` reads `<project>.test.dhall` and installs/removes each run variant under
`HostBootstrap.Harness.GeneratedConfig`, which holds the four § EE ownership clauses over that file:
a found config is refused before any mutation, and cleanup unlinks only on an exact re-observed identity
and payload. The refusal is the post-sweep one derived from installed project identity, so an
interrupted run's own config is reclaimed rather than blocking the next run. Durable verification and
rehydration of the complete lifecycle resource set belongs to the
[recovery and migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md).
Only the existing-frame commands
`project up|down|destroy`, `service run`, and `check-code` use the sibling project-config command gate.
The exact current-versus-target matrix lives in
[binary_context_config](binary_context_config.md#per-frame-fail-fast-on-handoff).

## Generated Tiers

The binary-generated role has two relevant forms:

1. **Standalone artifact tier** — typed examples such as the numeric budget/pod artifact whose
   `fitsWithin` assertion is meaningful because both operands are present.
2. **Project-owned test override** — one executable-sibling `<project>.test.dhall`. In the demo it
   carries resource overrides and declarative message variants; compiled Haskell owns case bodies, while
   `demoTestMatrix` projects every compiled case across the decoded variants. Each run is admitted under
   exact Harness scope and owns `.test_data/<runId>`.

These are artifacts the binary emits; `hostbootstrap-core` does not hand-author project-specific
instances. The binary emits validated-codec schemas for registered artifacts and the project-owned
config schema for local `<project>.dhall`, so those texts are not separate handwritten string literals.
`context schema|render` exposes the static artifact registry, while the config-free `service schema`
route prints the project-local config schema. Exact command-output snapshots keep those two surfaces
separate and pin both the bare and representative consumer registries.

## Root Init And Child Projection

`project init` is currently a config-free writer. Its no-flag behavior is the **fresh-root default**:
write the executable-sibling `<project>.dhall` as a host orchestrator with no parent, using the project's
defaults, and refuse an existing output. The parser also supports `--role ROLE`, repeatable
`--also-role ROLE`, `--output FILE`, `--force`, and `--if-missing`, alongside optional
`--cpu`/`--memory`/`--storage`/`--ha-replicas` and other project parameter overrides. `--force`
overwrites, `--if-missing` is a no-op when the output exists, and the current parser gives `--force`
precedence when both are supplied. Defaults are **not** core values. `project init` obtains its complete
Production value from `psAssemble (ProductionAssembly args)`; the harness obtains each exact-run-scoped
config from `psAssemble (HarnessAssembly authority tcfg draft)`, and `test init` independently builds
the project-owned `tcfg` through `psTestInit`. The generic type therefore enforces one structural
project-config assembly path.

The shared permissive `InitArgs` representation is the current parser contract. Role additions pass
through the closed `roleAdditionAllowed` relation and `addRole` validating smart constructor; incompatible
primary-role additions are refused during assembly. A project
may carry its own typed Parameters-layer fields on `cfg`: the demo's mandatory `message : Text` (its
`psAssemble` default `"Hello, world!"`) is one such field, rendered into the root `<project>.dhall` and read
by the `Web` service.

Child configs are **projections, not copies**, but the current demo does not give their projection and
delivery to its named `context-init` action. That action prints an announcement and keeps a frame in the
chain. The metal frame's composite `build-pb`/pristine-bootstrap action derives and streams the
VM-orchestrator config; the descent the `context-init` step declares carries the project-container
payload and the recursive handoff streams it over `stdin`; chart and accelerator deployment actions
render ConfigMaps for service/daemon children. Because that descent is a node of the same validated
plan, the announcing step and the container payload can no longer drift apart. The target `ProjectPlan`
additionally creates a single operation node whose permit covers both projection and delivery.

The current projection helpers derive a narrower context for the child frame and include supplied child
witnesses, but they retain the demo's full `ProjectConfig` parameter shape and copy the parent's entire
raw resource envelope. The smaller cluster slice is computed locally for cluster creation and is not
projected into service/daemon configs. VM/container payloads are written at the child's
executable-sibling location before dispatch. Trusted projection narrows the generated context's allowed
command classes so a service config is not intended to launch host VMs and a container config is not
intended to perform host orchestration. `addRole` is a validating smart constructor over a closed
role-addition relation, `service run` rejects a non-leaf primary kind, and lifecycle validation re-derives
placement from the complete topology instead of trusting a declared command-class list. The
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the concrete workload, partition,
and exact frame resource slices; the
[service runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md) owns the narrowed service
request consumed by a registered handler. The
[authenticated handoff and child admission phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
frames the narrowed config wire plus a separate opaque `HandoffToken` issued by the validated parent's
profile-specific broker under the exact
`BoundRunLease scope specDigest planDigest brokerGeneration` on a private duplex session. No token or permit exists
while the lease is still unbound. The binary receiver
returns a fresh challenge; the broker atomically consumes the nonce and authenticates a
child/config-hash-bound grant before the receiver promotes/writes config or mints authority. Recorded
transcripts and broker loss fail, and later invocations use fresh tokens. Authority is never a Dhall
field and neither payload travels through `argv` or environment. Project
Dockerfiles bake the narrow `image-build-container` config so build-time commands run during the image
build, before any runtime child config is streamed in. See
[config_generation](../engineering/config_generation.md) for the projection helpers and
[binary_context_config](binary_context_config.md) for the per-frame witness contract.

## Three Vocabulary Layers

The binary-generated tiers are composed from a three-level Dhall vocabulary that tracks the
[library hierarchy](library_hierarchy.md):

| Layer | File | Embeds | In repo |
|-------|------|--------|---------|
| L0 | `Core.dhall` | — | `core/hostbootstrap-core/dhall/Core.dhall` |
| L1 | `Daemon.dhall` | `Core.dhall` | Downstream (`daemon-substrate`) |
| L2 | `App.dhall` | `Daemon.dhall` | Downstream (`jitML`, `infernix`) |

`Core.dhall` is the reusable L0 vocabulary. It is a committed, hand-written file, not generated wholesale
from Haskell. It is **self-contained**—no Prelude import—so it
evaluates with no network access, both in-process via the Haskell `dhall` library and via
`dhall-to-json`. It exports the record/union types `Resources`, `Budget`, `PodResources`, `KindNode`,
`Mount`, `Substrate`, `ClusterProfile`, and `SecretRef` (plus the `Weight = Natural` synonym), plus the budget functions
`fitsWithin` and `split` (also under the aliases `Budget/fitsWithin` and `Budget/split`). Higher
layers embed it via `let C = ./Core.dhall` and extend it; they never redefine the L0 types (the Dhall
stream of the extension-stream contract—see [library_hierarchy](library_hierarchy.md)). An exhaustive
test derives every type-valued export from the normalized record and requires a named Haskell codec
whose schema is judgmentally equal. Execution shape is deliberately absent from the vocabulary;
lifecycle steps are its sole representation.

## The Load-Bearing Nuance: Validated Types, Hand-Written Functions

The vocabulary splits into two halves with **different** drift-control disciplines. This is the key
nuance of the model:

- **Types share a validated codec witness.** An opaque lower-layer `CodecWitness a` compares
  normalized decoder `expected` and encoder `declared` expressions before it can exist. Schema printing,
  decoding, and rendering accept that value rather than independent constraints; config writers force
  admission before acquiring their ownership lock. `ConfigArtifact` is opaque and can be built only
  from a witness plus a canonical value. Every hand-written `Core.dhall` type is exhaustively named and
  judgmentally equality-gated. This makes type-expression mismatch unrepresentable after admission;
  semantic encode/decode behavior still requires round-trip/property tests. At the target project
  boundary, installed identity and lifecycle scope additionally wrap the witness as
  `ProjectCodec scope specDigest cfg`, required for config promotion and plan construction.

- **Functions are hand-written and evaluation-controlled.** `fitsWithin` and `split` are written by hand
  in `Core.dhall` (Dhall has no facility to reflect a Haskell function into a Dhall function). They
  are drift-controlled by **evaluation tests** that run them against fixtures — an over-budget input is
  rejected. A generated project config cannot use that function for its real fit decision because its
  quantities are Kubernetes `Text` and it contains no resolved pod set. Dhall decoding rejects malformed
  shapes, and demo validation uses private smart-constructed quantities, resources, replicas, and
  service parameters. The single project-owned budget is then subjected to positive and provider-exact
  admission; there is no raw context-budget bypass. The complete
  topology-derived pod set is not yet fed to `fitsBudget` by bring-up: the only production use is the
  demo API's static `demoPods` view, which lists just the web example.

- **WRONG**: hand-write the schema type next to the decoder (`schemaText = "{ cpu : Natural, … }"`) to
  "document" what the decoder accepts. This is wrong because the literal and the decoder are two
  sources that drift independently; a field added to the Haskell record silently disagrees with the
  literal, so the printed schema stops describing what is actually decoded.
- **RIGHT**: construct a validated codec from both encoder and decoder, reject unequal normalized type
  expressions, and derive printed schema plus decode/render operations from that opaque witness.

This split defines the lower-layer drift control: type expressions share a validated witness, while the
part that cannot be reflected (functions) is pinned by evaluation tests. Current decode/validation uses
opaque scalar constructors and one project-owned budget. The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
admits the exact plan-owned generic budget; the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns its concrete workload, overhead,
partition, and slices. The resolved workload fit is enforced by `fitsBudget` before effects once that
complete topology-derived set exists. See
[config_generation](../engineering/config_generation.md) for the `ConfigArtifact` registry and the
current child-projection seams that realize this, and
[resource_budgeting](../engineering/resource_budgeting.md) for the budget the assertion guards.

## Current Status

The built binary exposes the Dhall surface through the `project` chain. The default `project init`
invocation renders a fresh root config from the project's Production assembly defaults (core ships none); its
current `--role` / repeatable `--also-role` / `--output` / `--force` / `--if-missing` surface supports
explicit role and write-policy modes. Child projection is implemented, but
its current operation ownership is split: composite bootstrap owns the VM config, the plan-declared
descent plus handoff owns the container payload, and deployment actions own service/daemon ConfigMaps;
the `context-init` action body only announces the handoff. Dockerfiles separately bake the narrow
`image-build-container` config for build-time commands. On the read-only `context` surface, `inspect` reads the
sibling `.dhall`, `show` reads its selected/default file, and `path`/`schema`/`render` are static and
config-free; `service schema` is likewise static. The three-layer vocabulary and standalone budget
artifact have core tests. One validated codec now owns schema, decode, and render for every artifact and
project/test config path; an exhaustive `Core.dhall` test equality-gates all ten current type exports,
while `fitsWithin` and `split` remain evaluation-tested.
The parameters/context/witness data model and its current-versus-target authority distinction are defined
in `binary_context_config`.

A target recursive `project up` on Incus/Linux interprets the VM-backed branch of
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` across the three-frame fractal descent and stands up
the live persistent stack: the cordoned kind cluster, the in-cluster registry, the project image pushed to
that registry, and the web chart pod serving through its runtime-resolved loopback endpoint. `project down`
deletes kind compute and stops the VM; `project destroy` deletes the VM
too. Static artifact schema/examples remain under read-only `context`; the project-local schema
is under config-free `service schema`.
