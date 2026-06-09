# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [system-components.md](system-components.md)

> **Purpose**: Tell the cross-phase narrative — from the current pure-Python CLI to the target
> Haskell `hostbootstrap-core` library plus thin Python bootstrapper — naming what each phase
> produces, why this order, and the dependency edges between them.

## Where the repository is today

The inversion is well advanced. `hostbootstrap` is the Haskell `hostbootstrap-core` library (under
`haskell/`) plus a Python bootstrapper (under `python/`). `hostbootstrap-core` owns
host-tool resolution, substrate detection, the `ensure` reconcilers, the static-base Dhall decoder,
cluster lifecycle and cordoning, and the composable optparse command tree project binaries extend.
The Python CLI is reduced to `doctor` / `up` / `base`: it asserts the fail-fast host minimums,
ensures a host toolchain, builds the project binary, and execs it — and still builds and publishes the
`basecontainer-<flavor>-<arch>` base images. The three-execution-model machinery is gone; the residual
Dhall read (`python/hostbootstrap/dhall_tool.py`, `python/hostbootstrap/spec.py`) decodes only the
static-base config tier.

The Python layer has **converged** on the thin pre-binary boundary that § M / § N define: `bootstrap.py`
is the four-step path — assert the fail-fast minimums, ensure the host build toolchain, build the project
binary **host-native on every substrate** (Linux included; there is no build-in-container-and-copy-out
path), and `exec` it. Ensuring Docker, building the project container, sizing the VM, and the cordon are
all the **project binary's** job once it is running, not the Python layer's. The inversion-side Python
work is therefore complete; the net-new layered warm store (§ V) was carved out to
[Phase 12](phase-12-layered-warm-store.md), now `Done`. The narrative below records how each phase
delivered this shape.

## Where the repository is going

The target inverts the language split. A Haskell `hostbootstrap-core` library owns essentially all
host-management logic; Python shrinks to the minimum that must run before any project binary exists.

The buildout reads as one ordered narrative:

### Phase 0 — documentation and governance

Convert the existing YAML-front-matter `documents/` suite to the unified metadata-block standard,
create this `DEVELOPMENT_PLAN/` tree, and land the documentation validator. No code-writing phase may
be marked `Active` or `Done` before Phase 0 closes. This phase's foundational deliverables have
**landed** — the metadata-block conversion, the plan tree, and the `HostBootstrap.DocValidator`
code-check gate are all in place — and the expanded doc-coverage obligations that reopened it have also
closed: the family doc-floor and taxonomy gate (Sprint 0.4) and the **doctrine-clarity sweep**
(Sprint 0.5, the Python wrapper's minimum-to-build role and the never-blocked `ensure`-suite purpose,
plus reconciling the inventory to the now-`Done` Phases 6/9). All five sprints are `Done`, so Phase 0 is
`Done`; per § A it may reopen to `Active` only when a future architecture contract adds a new
doc-coverage obligation, without reverting any code phase.

### Phase 1 — hostbootstrap-core scaffolding

Stand up the `hostbootstrap-core` Cabal package: a `library` stanza for the `HostBootstrap.*` module
surface and a bare executable. Pin GHC to the base-image toolchain, take
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
fails fast with a one-line diagnostic and a non-zero exit. This phase is `Done`: each reconciler is
**install-and-verify** (installs the dependency if absent, verified no-op if present), wired into the
command tree, with the cross-substrate `ensure incus` host-provider reconciler added in Phase 11 (§ U).

### Phase 4 — static-base Dhall and command tree

Land the static-base `hostbootstrap.dhall` schema (`project`, `dockerfile`, `resources {cpu, memory,
storage}`) and its in-process Haskell decoder, replacing the shelled `dhall-to-json` path. Land the
composable optparse command tree that project binaries extend through `runHostBootstrapCLI`. This
phase is `Done`: the in-process `config show` decoder and the composable tree (with the worked
extending demo binary) are implemented; the binary-generated `config schema` / `config render` and the
four-stream extension contract landed in Phase 8; and the pre-binary static-base read remains
Python-via-`dhall-to-json` (retained by design, not removed).

### Phase 5 — cluster lifecycle and resource cordoning

Land kind/Helm cluster-lifecycle semantics and resource-budget verification and cordoning: on Apple
by sizing a dedicated per-project Colima VM, on Linux by applying kind node resource limits. Land
the never-delete-`.data` invariant and the production-vs-test cluster profile distinction. This phase
is `Done`: the kind/Helm lifecycle (with the `.data` invariant and the profile distinction, test data
under `./.test_data/<case>/`) and the cordon cores are implemented and unit-tested; the **applied** cordon
and the `verifyBudget` spare-capacity preflight landed in Phase 9 and are exercised in real runs (the demo
brings up a per-case kind cluster, applies the `docker update` node cap, and tears it down).

### Phase 6 — base image and thin Python bootstrapper

Warm the `hostbootstrap-core` dependencies into the frozen Cabal store. The base image bakes **no**
`hostbootstrap` binary — a Linux ELF cannot run on Apple silicon, so it could not be copied out to
every host; instead every project builds its own binary **host-native**, and the project container the
binary later builds (`FROM` the base image) is accelerated by the warm store. Shrink the Python layer to
the pre-binary bootstrapper: assert fail-fast host minimums, ensure the host toolchain prerequisites to
build the binary, build the project binary host-native, and exec it — leaving Docker, the project
container, and cordoning to the project binary. This phase is `Done`: the warm store carries the
closure (no baked binary), the Python CLI is reduced to `doctor` / `up` / `base`, and the bootstrapper
has **converged** on the thin pre-binary boundary (the four-step path above, building host-native on
every substrate with no Docker-ensure, container build, VM sizing, or copy-out). The **layering** of the
warm-store freeze into `core.freeze`/`daemon.freeze` is a net-new deliverable owned by Phase 12, not this
phase.

### Phase 7 — consumer migration

Outline the migration of consumers onto `hostbootstrap-core`: `daemon-substrate` and `mcts` first,
with `infernix` and `jitML` as future work. Each consumer ships one optparse binary that extends the
core rather than re-implementing core verbs. This phase is `Done`: `hostbootstrap-core` is consumable,
the derived-project standard and the **three-level library hierarchy** (L0 core ◄ L1 `daemon-substrate`
◄ L2 `{jitML, infernix}`; `mcts` L0-direct) are documented, and the worked consumer is `hostbootstrap-demo`
(Phase 13, superseding the retired thin example binary). The consumer-side wiring of each sibling project
is that repository's own work.

## Where the architecture extends the plan

The global family architecture adds six net-new phases on top of the inversion buildout. Each owns a
named slice of the architecture; see [system-components.md](system-components.md) and each phase doc.

### Phase 8 — Dhall generation and the four-stream extension

The project binary generates its own schema (reflected from its decoder types, so it cannot drift) and
renders all deploy/test configs from a reusable `Core.dhall` vocabulary; the four-stream extension
contract (CLI append, Dhall embed, schema concatenation, harness seams) is formalized. This phase is
`Done`: `Core.dhall`, `HostBootstrap.Config.Vocab`, `HostBootstrap.Dhall.Gen`, and the
`config schema`/`render` verbs are implemented and tested; all four streams are implemented (the
harness `Seams` landed in Phase 10) and the demo (Phase 13) exercises them end-to-end.

### Phase 9 — Applied budget cordon and one canonical parser

The declared budget becomes an enforced ceiling: one canonical `parseQuantity` feeding every argument
builder, the applied Linux `docker update` kind-node cordon wired into `cluster up` (after `kind
create`, before Helm, fail-closed), and the `verifyBudget`/`fitsBudget` gates run before bring-up. This
phase is `Done`: all of the above are implemented and tested; the incus VM storage cordon
(`incusSizingArgs`) landed with Phase 11 (Sprint 11.4).

### Phase 10 — Standardized test harness and run-models

One `hostbootstrap-core` harness (`runMatrix` over a `Seams` record, with isolated per-case profiles, the
prefix delete-guard, and budget-slicing) and the minimal four run-models
(`OneShot`/`HostNative`/`HostDaemon`/`Cluster`) the system selects between. This phase is `Done`: the L0
engine, the pure cores, the `selectRunModel` key, the L0 OneShot seam (`oneShotRunArgs` + the IO-wired
`oneShotSeams`), and the `test`/`check-code` verbs are implemented and unit-tested; the live container/
cluster run is exercised in real runs (the demo), the same standard the cluster lifecycle (Phase 5)
follows.

### Phase 11 — incus first-class host-provider

`incus` becomes a host-provider axis (`HostTarget = Local | InVM`): `ensure incus` installs and verifies,
and the existing build/cluster/run/harness machinery runs inside a budget-sized incus VM with no per-call
branching. This phase is `Done`: the `Incus` host tool, the cross-substrate `ensure incus` reconciler,
`runInTarget`, the VM lifecycle argv + name-guard, `classifyDockerReadiness`, and `incusSizingArgs` are
implemented and unit-tested; the live in-VM run is exercised in real runs (the demo), the same standard
Phase 5 follows. GPU passthrough is a documented future follow-on.

### Phase 12 — Layered warm store

The warm-store freeze splits into `core.freeze` (base + core + shared web-build extras; for `mcts`,
`daemon-substrate`, and any L0-direct consumer) and `daemon.freeze` (daemon-family deps), both generated
in-image and never committed; `purescript-bridge` is added. This phase is `Done`: the warm-store package
is two layer manifests (`basecontainer-core-deps.cabal` / `basecontainer-daemon-deps.cabal`), the base
build projects the shared store into the two freezes via `core.project`/`daemon.project`, and the split
is validated — `core.freeze` carries no daemon-distinctive package and a core-only `cabal build
--dry-run` of `hostbootstrap-core` resolves without the daemon closure, confirmed on the host toolchain
and in a `ghc-9.12.4` container. The shared web-server packages (`warp`/`wai*`/`network`) are settled
into `core.freeze`. The published tag's full warm-store compile is the operator's `base build-and-push`
(the real-build standard Phases 5/10/11 follow).

### Phase 13 — hostbootstrap-demo worked app

A self-contained worked consumer under `demo/` whose test suite demonstrates every main feature, centered
on a from-zero pristine-host bootstrap performed inside an incus VM (`apt install pipx` → `pipx install
hostbootstrap` → `hostbootstrap up`). It supersedes the retired `example/Main.hs`. This phase is `Done`:
the demo has been **exercised in a real run** on a bare-metal host. Every verb is real (no narrate stubs)
and validated live — `incus ensure`/`vm up`/`vm down` (cordon #1), `vm pristine-bootstrap` (build #2
host-native + build #3 the project container `FROM` the pulled base), `vm test` (the harness brings up a
per-case kind cluster, applies cordon #2, and tears it down with no leftovers), `web bridge`/`web serve`
(the `warp`/`wai` + `purescript-bridge`/Halogen stack, Playwright e2e 3/3), and `harbor install`/`push`
(registry push/pull validated). The operator-scale real runs — the multi-arch published base tags, the
full 8-pod Harbor Helm deployment, and the multi-GB image push — follow the same real-run standard
Phases 5/10/11/12 use.

## Dependency edges

```text
phase-0  →  phase-1  →  phase-2  →  phase-3  →  phase-4  →  phase-5  →  phase-6  →  phase-7
                                                                                          │
the global-architecture phases fan in on the inversion buildout and converge on the demo: │
  phase-8  (Blocked by 4)                                                                  │
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
