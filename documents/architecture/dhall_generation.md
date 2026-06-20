# Dhall Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md), [binary context](binary_context_config.md)

> **Purpose**: Define the generated Dhall configuration model — `.dhall` as **parameters + context +
> witness** (never the chain shape), the context-init step that mints child configs inside `project up`,
> and the load-bearing nuance that vocabulary types are reflected from the decoders while the budget
> functions are hand-written and assert-controlled.

## TL;DR

- `.dhall` carries **parameters + context + witness**, never the chain. The lift chain
  (`chain :: ProjectConfig -> [Step]`) is code and is the project's identity; the `.dhall` is the typed data
  a binary reads to learn *which frame it is in* and *what budget it may spend*. The
  [composition_methodology](composition_methodology.md) is the canonical home of that model; this doc
  describes the Dhall it consumes and emits.
- **Parameters** are the root resource knobs (`--cpu/--memory/--storage/--ha-replicas`). **Context**
  names the binary's position in the topology (`topologyFrames`/`currentFrame`). **Witness** is the set
  of locally checkable `runtimeWitnesses` a binary proves before it acts. See
  [binary_context_config](binary_context_config.md).
- The root `<project>.dhall` is written by `project init`; child `<project>.dhall` projections are minted
  by a **context-init step** that the recursive interpreter runs inside `project up` before it hands off
  into the next frame.
- The binary-generated tiers are composed from **three vocabulary layers** — `Core.dhall` (L0),
  `Daemon.dhall` (L1), `App.dhall` (L2) — each embedding the one below (`let C = ./Core.dhall`).
- The vocabulary **types** (`Budget`, `PodResources`, `KindNode`, `Mount`) are **reflected from the
  Haskell decoders**, so the emitted schema equals the type the decoder accepts and cannot drift.
- The budget **functions** (`fitsWithin`, `split`) are **hand-written Dhall** in `Core.dhall` and
  drift-controlled by evaluation tests, not reflection. Every generated config carries
  `assert : C.fitsWithin budget pods === True`, so an over-budget config fails to type-check.

## Three Roles Of `.dhall`: Parameters, Context, Witness

A `.dhall` value is the typed data a binary reads — it is **not** the lift chain, which lives in Haskell
as `chain :: ProjectConfig -> [Step]`. Each `.dhall` plays three roles:

| Role | What it carries | Read for |
|------|-----------------|----------|
| Parameters | the root resource knobs | the chain is a pure function of these, so `chain rootCfg` is fully determined by the root `.dhall` |
| Context | the binary's `topologyFrames` + `currentFrame` — its position in the global lift composition | the binary reasons about which segment of the chain it owns |
| Witness | the `runtimeWitnesses` a binary must verify locally before acting | per-frame fail-fast on handoff: a binary that cannot witness its declared frame exits non-zero |

The resource knobs are **root parameters**, so `chain` is a pure function of root params rather than
branching on ambient state. The context and witness fields are the `binary_context_config` "know your
place" authority; this doc owns how they are generated and projected. See
[dhall_topology](../engineering/dhall_topology.md) for where the context/witness fields sit in the
configuration model.

## Configuration Roles

| Role | File | Produced by | Read by |
|------|------|-------------|---------|
| Root runtime config | `<project>.dhall` | `project init` on a fresh host-level binary, then user-edited for host-level settings | the project binary before normal command dispatch |
| Child runtime config | `<project>.dhall` at the child executable location | the context-init step inside `project up`, as a projection of the root | the child binary before normal command dispatch |
| Binary-generated | static registry examples plus rich project/deploy + per-case test Dhall | the project binary, from the reusable vocabulary | the project binary / test harness |

Python has no Dhall-facing role. The local config is the runtime authority for where the already-built
binary is running and which commands it may accept. Read-only `context` is the inspection surface for the
sibling `.dhall` and the rendered lift composition; runtime deploy and child projections are minted as
steps that first validate the active local config. Everything richer is binary-generated. See
[dhall_topology](../engineering/dhall_topology.md), [schema](../engineering/schema.md), and
[binary_context_config](binary_context_config.md).

## Generated Tiers

The binary-generated role has two tiers:

1. **Rich project/deploy tier** — the runtime/deploy config the binary renders from the vocabulary,
   carrying the budget assertion.
2. **Per-case test tier** — one typed record per test case, rendered by the binary under
   `./.test_data/<case>/`.

These are artifacts the binary emits; `hostbootstrap-core` does not hand-author project-specific
instances. The binary also emits its own schema for the generated tiers and the reflected `ProjectConfig`
schema for the local `<project>.dhall`, so the schema flows from the binary's types rather than being
maintained by hand. These schema/example surfaces are introspection under the read-only `context`
command.

## Root Init And The Context-Init Step

The root `<project>.dhall` is minted by `project init`: it writes the host-orchestrator root config (no
parent frame) with optional `--cpu/--memory/--storage/--ha-replicas` parameters and fails fast unless run
by a fresh host-level binary with no sibling `.dhall`. The default frame is the host orchestrator.

Child configs are **projections, not copies**, and they are minted by a **context-init step** the
recursive interpreter runs inside `project up` at each frame boundary, before handing off `pb project up`
into the next frame. The step reads the active config, derives a narrower context for the child frame,
carries only the needed parameter/budget slice, writes the child witnesses, and emits a local
`<project>.dhall` at the child executable location. The generated context's allowed command classes make
illegal functions unrepresentable: a service config can serve but cannot launch host VMs; a container
config can run build/test work but cannot perform host orchestration. Project Dockerfiles bake the narrow
`image-build-container` config so build-time commands run during the image build, before any runtime child
config is mounted. See [config_generation](../engineering/config_generation.md) for the step's projection
helpers and [binary_context_config](binary_context_config.md) for the per-frame witness contract.

## Three Vocabulary Layers

The binary-generated tiers are composed from a three-level Dhall vocabulary that tracks the
[library hierarchy](library_hierarchy.md):

| Layer | File | Embeds | In repo |
|-------|------|--------|---------|
| L0 | `Core.dhall` | — | `core/hostbootstrap-core/dhall/Core.dhall` |
| L1 | `Daemon.dhall` | `Core.dhall` | Downstream (`daemon-substrate`) |
| L2 | `App.dhall` | `Daemon.dhall` | Downstream (`jitML`, `infernix`) |

`Core.dhall` is the reusable L0 vocabulary. It is **self-contained** — no Prelude import — so it
evaluates with no network access, both in-process via the Haskell `dhall` library and via
`dhall-to-json`. It exports the record/union types `Resources`, `Budget`, `PodResources`, `KindNode`,
`Mount`, `Substrate`, `RunModel`, `ClusterProfile`, and `Weight`, plus the budget functions
`fitsWithin` and `split` (also under the aliases `Budget/fitsWithin` and `Budget/split`). Higher
layers embed it via `let C = ./Core.dhall` and extend it; they never redefine the L0 types (the Dhall
stream of the extension-stream contract — see [library_hierarchy](library_hierarchy.md)).

## The Load-Bearing Nuance: Reflected Types, Hand-Written Functions

The vocabulary splits into two halves with **different** drift-control disciplines. This is the key
nuance of the model:

- **Types are reflected from the decoders — they cannot drift.** The Haskell mirrors in
  `HostBootstrap.Config.Vocab` (`Budget`, `PodResources`, `KindNode`, `Mount`) derive `FromDhall` and
  `ToDhall`. The emitted schema is the `ToDhall` encoder's `declared` field — the exact Dhall type the
  `FromDhall` decoder accepts. Because the printed type *is* the decoder's accepted type, the schema
  cannot diverge from what the binary will read. An anti-drift test asserts each reflected type equals
  the matching `Core.dhall` type, keeping the hand-written vocabulary and the decoders aligned.

- **Functions are hand-written and assert-controlled.** `fitsWithin` and `split` are written by hand
  in `Core.dhall` (Dhall has no facility to reflect a Haskell function into a Dhall function). They
  are drift-controlled by **evaluation tests** that run them against fixtures — an over-budget input is
  rejected. At render time, every generated deploy config embeds
  `assert : C.fitsWithin budget pods === True`, so the assertion is checked when Dhall evaluates the
  config: an over-budget deploy **fails to type-check** rather than reaching the cluster.

- **WRONG**: hand-write the schema type next to the decoder (`schemaText = "{ cpu : Natural, … }"`) to
  "document" what the decoder accepts. This is wrong because the literal and the decoder are two
  sources that drift independently; a field added to the Haskell record silently disagrees with the
  literal, so the printed schema stops describing what is actually decoded.
- **RIGHT**: reflect the schema from the type via the `ToDhall` encoder's `declared` field, so the
  printed schema is definitionally the decoder's accepted type.

This split is why the model is robust: the part that *can* be reflected (types) is, eliminating an
entire class of drift; the part that *cannot* (functions) is pinned by evaluation tests and enforced
whenever a deploy config is rendered by a Dhall-level assert. See
[config_generation](../engineering/config_generation.md) for the `ConfigArtifact` registry and the
context-init projection that realize this, and
[resource_budgeting](../engineering/resource_budgeting.md) for the budget the assertion guards.

## Current Status

The built binary exposes the Dhall surface through the `project` chain. `project init` renders the root
config from root parameters only — `--cpu/--memory/--storage/--ha-replicas`. The **context-init step**
that the recursive `project up` interpreter runs at each frame boundary mints the child projections at
the VM/container/service boundaries (Dockerfiles bake the narrow `image-build-container` config so
build-time commands run during the image build). The read-only `context` command introspects the sibling
`.dhall` and renders the lift composition via
`context inspect`/`context path`/`context show`/`context schema`/`context render`. The three-layer
vocabulary, the reflected-type/hand-written-function split, and the budget assertion are gated by core
tests. The parameters/context/witness data model is the `binary_context_config` authority.

A single `project up` on Incus/Linux interprets `demoChain :: ProjectConfig -> [Step]` across the
three-frame fractal descent and stands up the live persistent stack: the cordoned kind cluster, the
in-cluster Harbor registry, the project image pushed to that registry, and the web chart pod serving
`localhost:30080`. `project down` stops it and `project destroy` deletes it, both preserving durable host
`.data`. The schema and example surfaces are introspection under the read-only `context` command.
