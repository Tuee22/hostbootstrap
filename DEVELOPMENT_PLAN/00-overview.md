# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [system-components.md](system-components.md)

> **Purpose**: Tell the cross-phase narrative — from the current pure-Python CLI to the target
> Haskell `hostbootstrap-core` library plus thin Python bootstrapper — naming what each phase
> produces, why this order, and the dependency edges between them.

## Where the repository is today

The inversion is complete. `hostbootstrap` is the Haskell `hostbootstrap-core` library (under
`haskell/`) plus a thin Python bootstrapper (under `python/`). `hostbootstrap-core` owns
host-tool resolution, substrate detection, the `ensure` reconcilers, the skeletal-Dhall decoder,
cluster lifecycle and cordoning, and the composable optparse command tree project binaries extend.
The Python layer is the thin five-step bootstrapper (`doctor` / `up` / `base`): it asserts the
fail-fast host minimums, ensures Docker, builds the project container as the `check-code` gate, copies
the binary to `./.build/`, and execs it — and still builds and publishes the
`basecontainer-<flavor>-<arch>` base images. The three-execution-model machinery is gone; the residual
Dhall read (`python/hostbootstrap/dhall_tool.py`, `python/hostbootstrap/spec.py`) decodes only the
skeletal config tier. The narrative below records how each phase delivered this shape.

## Where the repository is going

The target inverts the language split. A Haskell `hostbootstrap-core` library owns essentially all
host-management logic; Python shrinks to the minimum that must run before any project binary exists.

The buildout reads as one ordered narrative:

### Phase 0 — documentation and governance

Convert the existing YAML-front-matter `documents/` suite to the unified metadata-block standard,
create this `DEVELOPMENT_PLAN/` tree, and land the documentation validator. No code-writing phase may
be marked `Active` or `Done` before Phase 0 closes. This phase is `Done`: the metadata-block
conversion, the plan tree, and the `HostBootstrap.DocValidator` code-check gate are all in place.

### Phase 1 — hostbootstrap-core scaffolding

Stand up the `hostbootstrap-core` Cabal package: a `library` stanza for the `HostBootstrap.*` module
surface and a skeletal executable. Pin GHC to the base-image toolchain, take
`optparse-applicative` and `dhall` as dependencies, and expose the generic entrypoint
`runHostBootstrapCLI progName projectCommands` over an empty-but-buildable command tree. No host
logic lands yet; this is the structural shell every later phase fills in. This phase is `Done`:
`cabal build all` and `cabal test` pass against the warm store and `hostbootstrap --help` exits 0.

### Phase 2 — host tools and config

Lift `infernix`'s `HostTools` / `HostConfig` / `HostPrereqs` trio and substrate detection into
`HostBootstrap.*`. Host-tool resolution becomes a closed `HostTool` enumeration resolved to absolute
paths; substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) moves into typed Haskell.
`infernix` (https://github.com/Tuee22/infernix) is the source of the lifted trio. This phase is
`Done`: the trio and substrate detection are implemented and unit-tested in `hostbootstrap-core`.

### Phase 3 — ensure reconcilers

Land each host dependency as an idempotent `ensure` reconciler — a host-applicability predicate plus
a reconcile action — exposed as an optparse subcommand: `ensure docker`, `ensure colima`,
`ensure cuda`, `ensure homebrew`, `ensure ghc`, `ensure tart`. A reconciler run on the wrong host
fails fast with a one-line diagnostic and a non-zero exit. This phase is `Done`: the six reconcilers
are implemented, wired into the command tree, and validated end-to-end.

### Phase 4 — skeletal Dhall and command tree

Land the skeletal `hostbootstrap.dhall` schema (`project`, `dockerfile`, `resources {cpu, memory,
storage}`) and its in-process Haskell decoder, replacing the shelled `dhall-to-json` path. Land the
composable optparse command tree that project binaries extend through `runHostBootstrapCLI`. This
phase is `Active`: the in-process `config show` decoder and the composable tree (with a worked
extending binary) are implemented, but the binary-generated `config schema` / `config render` and the
four-stream extension contract are net-new (Phase 8), and the pre-binary static-base read remains
Python-via-`dhall-to-json` (retained, not removed).

### Phase 5 — cluster lifecycle and resource cordoning

Land kind/Helm cluster-lifecycle semantics and resource-budget verification and cordoning: on Apple
by sizing a dedicated per-project Colima VM, on Linux by applying kind node resource limits. Land
the never-delete-`.data` invariant and the production-vs-test cluster profile distinction. This phase
is `Active`: the kind/Helm lifecycle (with the `.data` invariant and the profile distinction, test data
under `./.test_data/<case>/`) and the pure cordon cores are implemented and unit-tested, but the cordon
is computed and only **reported** — not yet applied — and `verifyBudget` is unwired, so the declared
budget ceiling is not enforced (the applied cordon is net-new, Phase 9).

### Phase 6 — base image and thin Python bootstrapper

Warm the `hostbootstrap-core` dependencies into the frozen Cabal store. The base image bakes **no**
`hostbootstrap` binary — a Linux ELF cannot run on Apple silicon, so it could not be copied out to
every host; instead every project builds its own binary host-native and in-container, accelerated by
the warm store. Shrink the Python layer to the bootstrapper: assert fail-fast host minimums, ensure
Docker (provision the per-project Colima VM on Apple sized to the budget), build the project container
as the `check-code` gate, copy the built binary to `./.build/`, and exec it. This phase is `Done`: the
warm store carries the closure (no Dockerfile change, no baked binary), and the Python CLI is the thin
`doctor` / `up` / `base` bootstrapper — the three-execution-model machinery is removed and the suite
passes at 100% coverage.

### Phase 7 — consumer migration

Outline the migration of consumers onto `hostbootstrap-core`: `daemon-substrate` and `mcts` first,
with `infernix` and `jitML` as future work. Each consumer ships one optparse binary that extends the
core rather than re-implementing core verbs. This phase is `Active`: `hostbootstrap-core` is consumable
and the derived-project standard is documented, but the phase reopens against the **three-level library
hierarchy** (L0 core ◄ L1 `daemon-substrate` ◄ L2 `{jitML, infernix}`; `mcts` L0-direct) and the worked
consumer is now `hostbootstrap-demo` (superseding the thin example binary). The consumer-side wiring is
each consuming repository's own work.

## Where the architecture extends the plan

The global family architecture adds six net-new phases on top of the inversion buildout. Each owns a
named slice of the architecture; see [system-components.md](system-components.md) and each phase doc.

### Phase 8 — Dhall generation and the four-stream extension

The project binary generates its own schema (reflected from its decoder types, so it cannot drift) and
renders all deploy/test configs from a reusable `Core.dhall` vocabulary; the four-stream extension
contract (CLI append, Dhall embed, schema concatenation, harness seams) is formalized. `Blocked by`
phase-0 and phase-4.

### Phase 9 — Applied budget cordon and one canonical parser

The declared budget becomes an enforced ceiling: one canonical quantity parser shared across Python and
Haskell, the applied Linux `docker update` kind-node cordon wired into `cluster up`, and the
`verifyBudget`/`fitsBudget` gates run before bring-up. `Blocked by` phase-5 and phase-8.

### Phase 10 — Standardized test harness and run-models

One `hostbootstrap-core` harness (`runMatrix` over a `Seams` record, with isolated per-case profiles, the
prefix delete-guard, and budget-slicing) and the minimal four run-models
(`OneShot`/`HostNative`/`HostDaemon`/`Cluster`) the system selects between. `Blocked by` phase-8 and
phase-9.

### Phase 11 — incus first-class host-provider

`incus` becomes a host-provider axis (`HostTarget = Local | InVM`): `ensure incus` installs and verifies,
and the existing build/cluster/run/harness machinery runs inside a budget-sized incus VM with no per-call
branching. `Blocked by` phase-3, phase-9, and phase-10.

### Phase 12 — Layered warm store

The warm-store freeze splits into `core.freeze` (base + core; for `mcts` and `daemon-substrate`) and
`daemon.freeze` (daemon-family deps), both generated in-image and never committed; `purescript-bridge` is
added. `Blocked by` phase-6 and phase-8.

### Phase 13 — hostbootstrap-demo worked app

A self-contained worked consumer under `demo/` whose test suite demonstrates every main feature, centered
on a from-zero pristine-host bootstrap performed inside an incus VM (`apt install pipx` → `pipx install
hostbootstrap` → `hostbootstrap up`). It supersedes `example/Main.hs`. `Blocked by` phases 8–12.

## Dependency edges

```text
phase-0  →  phase-1  →  phase-2  →  phase-3  →  phase-4  →  phase-5  →  phase-6  →  phase-7
                                                                                          │
the global-architecture phases fan in on the inversion buildout and converge on the demo: │
  phase-8  (Blocked by 0, 4)                                                               │
  phase-9  (Blocked by 5, 8)                                                               │
  phase-10 (Blocked by 8, 9)                                                               │
  phase-11 (Blocked by 3, 9, 10)                                                           │
  phase-12 (Blocked by 6, 8)                                                               │
  phase-13 (Blocked by 8, 9, 10, 11, 12)  ← the demo exercises all of them ───────────────┘
```

Each edge is a hard prerequisite: the later phase consumes a surface the earlier phase delivers. The
edges are restated as `Blocked by` lines in each phase document.

## What is intentionally not a phase

- A separate doc-validator phase. The validator is a Phase-0 quality-gate deliverable, tracked in
  [phase-0-documentation-and-governance.md](phase-0-documentation-and-governance.md), not its own
  phase.
- A consumer product-feature phase. `hostbootstrap` borrows the governance shape from its consumers
  but adopts none of their runtime surfaces, daemon-role models, or hardware-correctness cadence;
  those remain consumer concerns (see [development_plan_standards.md § S](development_plan_standards.md)).
- A separate "release" phase. The library is consumed by sibling path with deps served from the
  base-image warm store; there is no
  Hackage release ceremony.
