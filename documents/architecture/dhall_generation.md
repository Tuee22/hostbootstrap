# Dhall Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md), [binary context](binary_context_config.md)

> **Purpose**: Define the generated Dhall configuration model — `.dhall` as **parameters + context +
> witness** (never the chain shape), the current split ownership of child projection/delivery and its
> target unification, and the load-bearing distinction between encoder-declared schemas, decoder
> validation, hand-written vocabulary, and evaluation-tested functions.

## TL;DR

- `.dhall` carries **parameters + context + witness**, never the chain. The lift chain
  (`chain :: cfg -> [Step]`) is code and is the project's identity; the `.dhall` is the typed data
  a binary reads to learn *which frame it is in* and *what budget it may spend*. The
  [composition_methodology](composition_methodology.md) is the canonical home of that model; this doc
  describes the Dhall it consumes and emits.
- **Parameters** are the root resource knobs (`--cpu/--memory/--storage/--ha-replicas`). **Context**
  names the binary's position in the topology (`topologyFrames`/`currentFrame`). **Witness** is the set
  of locally checkable `runtimeWitnesses` a binary proves before it acts. See
  [binary_context_config](binary_context_config.md).
- The root `<project>.dhall` is the fresh-root default of the config-free `project init` writer; explicit
  role/output/policy flags also support other current init uses. In the demo, the named
  **context-init** action is only a no-op announcer/frame anchor: VM projection and streaming occur in
  the composite `build-pb` action, container projection is computed by `psFrameContext` and carried by
  the handoff, and service/daemon projection occurs in deployment actions. The target plan makes
  projection plus delivery one typed operation.
- The binary-generated tiers are composed from **three vocabulary layers** — `Core.dhall` (L0),
  `Daemon.dhall` (L1), `App.dhall` (L2) — each embedding the one below (`let C = ./Core.dhall`).
- Current generated schema text comes from the `ToDhall` encoder's `declared` expression; `FromDhall`
  supplies a separate decoder. Matching derived instances usually agree, but that equality is not
  guaranteed by the current API. The target lower-layer `CodecWitness a` validates normalized
  encoder/decoder type expressions once and becomes the only schema/decode/render input; installed
  identity and lifecycle scope wrap it as `ProjectCodec scope specDigest cfg` at the project boundary.
- The budget **functions** (`fitsWithin`, `split`) are **hand-written Dhall** in `Core.dhall` and
  drift-controlled by evaluation tests, not reflection. Project configs intentionally do not attach a
  `fitsWithin` assertion: they carry text quantities and no pod set. Typed scalar refinements form the
  decode ring. Haskell `fitsBudget` exists and is unit-tested, but lifecycle bring-up does not yet call
  it with the complete topology-derived workload set.

## Three Roles Of `.dhall`: Parameters, Context, Witness

A `.dhall` value is the typed data a binary reads — it is **not** the lift chain, which lives in Haskell
as `chain :: cfg -> [Step]`. Each `.dhall` plays three roles:

| Role | What it carries | Read for |
|------|-----------------|----------|
| Parameters | the root resource knobs | the chain is a pure function of these, so `chain cfg` is fully determined by the project `.dhall` |
| Context | the binary's `topologyFrames` + `currentFrame` — its position in the global lift composition | the binary reasons about which segment of the chain it owns |
| Witness | the `runtimeWitnesses` a binary must verify locally before acting | per-frame fail-fast on handoff: a binary that cannot witness its declared frame exits non-zero |

The resource knobs are **root parameters**, so `chain` is a pure function of root params rather than
branching on ambient state. The context and witness fields are the `binary_context_config` "know your
place" description and current mismatch gate; opaque authority is a separate target. This doc owns how
the data is generated and projected. See
[dhall_topology](../engineering/dhall_topology.md) for where the context/witness fields sit in the
configuration model.

## Configuration Roles

| Role | File | Produced by | Read by |
|------|------|-------------|---------|
| Root runtime config | `<project>.dhall` | the default `project init` invocation, then user-edited for host-level settings | existing-frame project-binary commands |
| Child runtime config | `<project>.dhall` at the child executable location | current demo: composite VM bootstrap, `psFrameContext`/handoff, or workload deployment action; target: one plan operation that owns projection and delivery | existing-frame child-binary commands |
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
mutation-authority gate. `test run` reads `<project>.test.dhall`, refuses a pre-existing sibling
`<project>.dhall`, and writes/removes each run variant under the current cooperative sidecar and
matching-byte cleanup guard; Phase 10.9 owns resource-authoritative reservations and verified receipts.
Only the existing-frame commands
`project up|down|destroy`, `service run`, and `check-code` use the sibling project-config command gate.
The exact current-versus-target matrix lives in
[binary_context_config](binary_context_config.md#per-frame-fail-fast-on-handoff).

## Generated Tiers

The binary-generated role has two relevant forms:

1. **Standalone artifact tier** — typed examples such as the numeric budget/pod artifact whose
   `fitsWithin` assertion is meaningful because both operands are present.
2. **Project-owned test override** — one executable-sibling `<project>.test.dhall`. In the demo it
   carries a redundant suite-name list plus resource overrides; compiled Haskell owns cases and config
   variants. The live demo planner currently selects Production/`.data`, not `.test_data`.

These are artifacts the binary emits; `hostbootstrap-core` does not hand-author project-specific
instances. The binary also emits encoder-declared schemas for registered artifacts and the project-owned
config schema for local `<project>.dhall`, so those texts are not separate handwritten string literals.
Until the validated-codec target lands, encoder/decoder agreement remains a tested invariant, not a
definitionally shared source. `context schema|render` exposes the static artifact registry, while the
config-free `service schema` route prints the project-local config schema.

## Root Init And Child Projection

`project init` is currently a config-free writer. Its no-flag behavior is the **fresh-root default**:
write the executable-sibling `<project>.dhall` as a host orchestrator with no parent, using the project's
defaults, and refuse an existing output. The parser also supports `--role ROLE`, repeatable
`--also-role ROLE`, `--output FILE`, `--force`, and `--if-missing`, alongside optional
`--cpu`/`--memory`/`--storage`/`--ha-replicas` and other project parameter overrides. `--force`
overwrites, `--if-missing` is a no-op when the output exists, and the current parser gives `--force`
precedence when both are supplied. Defaults are **not** core values. `project init` obtains its complete
value from the project's `psInit`; the harness obtains generated run configs from the independent
`psTestConfig`, and `test init` independently builds the project-owned `tcfg` through `psTestInit`.
The demo calls `demoInitWithMessage` from both `demoInit` and `demoTestConfig` by convention, but the
current generic type does not enforce that reuse. Target `psAssemble` makes the shared structural
assembly path explicit.

The shared permissive `InitArgs` representation is current implementation, not the finished contract.
The development plan assigns opaque writer-specific init requests and the explicit overwrite-policy
type to Phase 17 Sprint 17.4, and smart construction of compatible role/class authority to Phase 15
Sprint 15.9. A project
may carry its own typed Parameters-layer fields on `cfg`: the demo's mandatory `message : Text` (its
`psInit` default `"Hello, world!"`) is one such field, rendered into the root `<project>.dhall` and read
by the `Web` service.

Child configs are **projections, not copies**, but the current demo does not give their projection and
delivery to its named `context-init` action. That action prints an announcement and keeps a frame in the
chain. The metal frame's composite `build-pb`/pristine-bootstrap action derives and streams the
VM-orchestrator config; `psFrameContext` derives the project-container payload and the recursive handoff
streams it over `stdin`; chart and accelerator deployment actions render ConfigMaps for service/daemon
children. The target `ProjectPlan` creates a single operation node whose permit covers both projection
and delivery, so a no-op step cannot drift from the independent callback that performs the real effect.

The current projection helpers derive a narrower context for the child frame and include supplied child
witnesses, but they retain the demo's full `ProjectConfig` parameter shape and copy the parent's entire
raw resource envelope. The smaller cluster slice is computed locally for cluster creation and is not
projected into service/daemon configs. VM/container payloads are written at the child's
executable-sibling location before dispatch. Trusted projection narrows the generated context's allowed
command classes so a service config is not intended to launch host VMs and a container config is not
intended to perform host orchestration. Phase 9.10 owns exact resource slices and Phase 19.8 owns
role-specific parameter payloads. Current declarations are still
constructible/widenable data: current `addRole` unions an added role's command classes and capabilities
while retaining the primary context kind. `service run` separately rejects a non-leaf primary kind, but
`project up` checks only `ClusterLifecycleCommand`, so an orchestration-widened `Daemon` or
`ImageBuildContainer` can incorrectly pass. Phase 15.9 makes those incompatible combinations
unrepresentable with opaque role-specific authorities and smart constructors. Its transport target frames
the narrowed config wire plus a separate opaque `HandoffToken` issued by the validated parent's
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
`Mount`, `Substrate`, `RunModel`, `ClusterProfile`, and `SecretRef` (plus the `Weight = Natural` synonym), plus the budget functions
`fitsWithin` and `split` (also under the aliases `Budget/fitsWithin` and `Budget/split`). Higher
layers embed it via `let C = ./Core.dhall` and extend it; they never redefine the L0 types (the Dhall
stream of the extension-stream contract—see [library_hierarchy](library_hierarchy.md)). Current explicit
judgmental-equality coverage is incomplete across that exported type list; the target requires every type
to be generated or named by an equality test.

## The Load-Bearing Nuance: Validated Types, Hand-Written Functions

The vocabulary splits into two halves with **different** drift-control disciplines. This is the key
nuance of the model:

- **Current types are encoder-declared and separately decoded.** The Haskell mirrors in
  `HostBootstrap.Config.Vocab` (`Budget`, `PodResources`, `KindNode`, `Mount`, `SecretRef`) derive
  `FromDhall` and `ToDhall`. The emitted schema is the `ToDhall` encoder's `declared` field; the decoder's
  `expected` expression is a separate value. Round-trip tests and selected equality tests reduce drift,
  but neither derivation nor one successful round trip proves universal agreement, and current
  `Core.dhall` coverage is not exhaustive.

- **Target types share a validated codec witness.** An opaque lower-layer `CodecWitness a` compares
  normalized decoder `expected` and encoder `declared` expressions before it can exist. Schema printing,
  decoding, and rendering accept that value rather than independent constraints. At the project boundary,
  installed identity and lifecycle scope wrap it as `ProjectCodec scope specDigest cfg`, which is also required for
  config promotion and plan construction. Every hand-written `Core.dhall` type is either generated from
  the witness or covered by an explicit judgmental-equality test. This makes type-expression mismatch
  unrepresentable after validation; semantic encode/decode behavior still requires
  round-trip/property tests.

- **Functions are hand-written and evaluation-controlled.** `fitsWithin` and `split` are written by hand
  in `Core.dhall` (Dhall has no facility to reflect a Haskell function into a Dhall function). They
  are drift-controlled by **evaluation tests** that run them against fixtures — an over-budget input is
  rejected. A generated project config cannot use that function for its real fit decision because its
  quantities are Kubernetes `Text` and it contains no resolved pod set. Dhall decoding rejects malformed
  shapes, and demo validation rejects selected top-level quantities/replicas/service parameters, but
  bare-byte/zero/provider-minimum-invalid quantities and the raw `context.resourceEnvelope` can still
  bypass the refined top-level resource path. The complete
  topology-derived pod set is not yet fed to `fitsBudget` by bring-up: the only production use is the
  demo API's static `demoPods` view, which lists just the web example.

- **WRONG**: hand-write the schema type next to the decoder (`schemaText = "{ cpu : Natural, … }"`) to
  "document" what the decoder accepts. This is wrong because the literal and the decoder are two
  sources that drift independently; a field added to the Haskell record silently disagrees with the
  literal, so the printed schema stops describing what is actually decoded.
- **RIGHT**: construct a validated codec from both encoder and decoder, reject unequal normalized type
  expressions, and derive printed schema plus decode/render operations from that opaque witness.

This split defines the target drift control: type expressions share a validated witness, while the part
that cannot be reflected (functions) is pinned by evaluation tests. Current decode/validation covers
only selected scalar paths; Sprint 9.10's opaque constructors make provider-valid budget quantities and
the one raw/applied authority unrepresentable outside validation. The target resolved workload fit is
enforced by `fitsBudget` before effects once the complete topology-derived set exists. See
[config_generation](../engineering/config_generation.md) for the `ConfigArtifact` registry and the
current child-projection seams that realize this, and
[resource_budgeting](../engineering/resource_budgeting.md) for the budget the assertion guards.

## Current Status

The built binary exposes the Dhall surface through the `project` chain. The default `project init`
invocation renders a fresh root config from the project's `psInit` defaults (core ships none); its
current `--role` / repeatable `--also-role` / `--output` / `--force` / `--if-missing` surface supports
explicit role and write-policy modes pending the typed replacement. Child projection is implemented, but
its current operation ownership is split: composite bootstrap owns the VM config,
`psFrameContext`/handoff owns the container payload, and deployment actions own service/daemon ConfigMaps;
the named `context-init` action only announces the handoff. Dockerfiles separately bake the narrow
`image-build-container` config for build-time commands. On the read-only `context` surface, `inspect` reads the
sibling `.dhall`, `show` reads its selected/default file, and `path`/`schema`/`render` are static and
config-free; `service schema` is likewise static. The three-layer vocabulary and standalone budget
artifact have core tests. The encoder/decoder type expressions are not yet forced through one validated
codec, and committed `Core.dhall` type coverage is incomplete; the development plan owns that repair.
The parameters/context/witness data model and its current-versus-target authority distinction are defined
in `binary_context_config`.

A single `project up` on Incus/Linux interprets the VM-backed branch of
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` across the three-frame fractal descent and stands up
the live persistent stack: the cordoned kind cluster, the in-cluster registry, the project image pushed to
that registry, and the web chart pod serving
`localhost:30080`. `project down` deletes kind compute and stops the VM; `project destroy` deletes the VM
too. Static artifact schema/examples remain under read-only `context`; the project-local schema
is under config-free `service schema`.
