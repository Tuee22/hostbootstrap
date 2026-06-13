# Dhall Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md), [binary context](binary_context_config.md)

> **Purpose**: Define the generated Dhall configuration model, where it sits alongside the static
> bootstrap input and binary-context config, and the load-bearing nuance that vocabulary types are
> reflected from the decoders while the budget functions are hand-written and assert-controlled.

## TL;DR

- Configuration is typed Dhall in distinct roles: the static bootstrap `hostbootstrap.dhall` read
  pre-binary by the Python bootstrapper; the runtime `project-binary-context-config.dhall` each binary
  reads before normal dispatch; and the binary-generated rich project/deploy plus per-case test tiers.
- The binary-context tier is the runtime authority for normal project-binary commands; the static-base
  file remains Python/bootstrap input plus the explicit `config show FILE` inspection path.
- The binary-generated tiers are composed from **three vocabulary layers** — `Core.dhall` (L0),
  `Daemon.dhall` (L1), `App.dhall` (L2) — each embedding the one below (`let C = ./Core.dhall`).
- The vocabulary **types** (`Budget`, `PodResources`, `KindNode`, `Mount`) are **reflected from the
  Haskell decoders**, so the emitted schema equals the type the decoder accepts and cannot drift.
- The budget **functions** (`fitsWithin`, `split`) are **hand-written Dhall** in `Core.dhall` and
  drift-controlled by evaluation tests, not reflection. Every generated config carries
  `assert : C.fitsWithin budget pods === True`, so an over-budget config fails to type-check.

## Configuration Roles

| Role | File | Produced by | Read by |
|------|------|-------------|---------|
| Static bootstrap | `hostbootstrap.dhall` | Hand-authored per project, identical shape across projects | The thin Python bootstrapper, pre-binary, via `dhall-to-json` |
| Binary context | `project-binary-context-config.dhall` | Created during bootstrap or before a nested boundary | The project binary before normal command dispatch |
| Binary-generated | rich project/deploy + per-case test Dhall | The project binary (`config render`), from the reusable vocabulary | The project binary / test harness |

The static bootstrap role is the one Python-facing contract: small, uniform, and decoded before any
binary exists. The binary context is the runtime authority for where the already-built binary is running
and which commands it may accept. Everything richer is binary-generated. See
[dhall_topology](../engineering/dhall_topology.md), [schema](../engineering/schema.md), and
[binary_context_config](binary_context_config.md).

## Generated Tiers

The binary-generated role has two tiers:

1. **Rich project/deploy tier** — the runtime/deploy config the binary renders from the vocabulary,
   carrying the budget assertion.
2. **Per-case test tier** — one typed record per test case, rendered by the binary under
   `./.test_data/<case>/`.

These are artifacts the binary emits; `hostbootstrap-core` does not hand-author project-specific
instances. The binary also emits its own schema for the generated tiers (`config schema`), so the schema
flows from the binary's types rather than being maintained by hand.

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
stream of the four-stream contract — see [library_hierarchy](library_hierarchy.md)).

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
  literal, and the printed schema no longer describes what is actually decoded.
- **RIGHT**: reflect the schema from the type via the `ToDhall` encoder's `declared` field, so the
  printed schema is definitionally the decoder's accepted type.

This split is why the model is robust: the part that *can* be reflected (types) is, eliminating an
entire class of drift; the part that *cannot* (functions) is pinned by evaluation tests and enforced
at every render by a Dhall-level assert. See [config_generation](../engineering/config_generation.md)
for the `ConfigArtifact` registry and the `config schema` / `config render` surface that realize this,
and [resource_budgeting](../engineering/resource_budgeting.md) for the budget the assertion guards.
