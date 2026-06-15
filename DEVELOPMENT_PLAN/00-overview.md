# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [system-components.md](system-components.md)

> **Purpose**: Tell the cross-phase narrative — from the current pure-Python CLI to the target
> Haskell `hostbootstrap-core` library plus thin Python bootstrapper — naming what each phase
> produces, why this order, and the dependency edges between them.

## Where the repository is today

The inversion is well advanced. `hostbootstrap` is the Haskell `hostbootstrap-core` library (under
`core/`) plus a Python bootstrapper (rooted at the repository root). `hostbootstrap-core` owns
host-tool resolution, substrate detection, the `ensure` reconcilers, cluster lifecycle and cordoning, the
project-local Dhall schema machinery, the binary-context command gate, and the composable optparse command
tree project binaries extend.
The Python CLI is reduced to `doctor` / `build` / `run` / `base`: the target boundary is that it derives
the project name from the Cabal file, asserts the fail-fast host minimums, ensures a host toolchain,
builds the project binary, and execs it — and still builds and publishes the
`basecontainer-<flavor>-<arch>` base images when directed by the operator.

The previous runtime-context split is removed. Phase 4 replaced the supported schema surface with
project-local config types, Phase 6 removed Python's Dhall reader/writer, Phase 8 added binary-owned
default generation and child projection helpers, and Phases 13 and 15 wired that surface into normal
runtime dispatch. Normal commands now fail fast when sibling `<project>.dhall` is missing or invalid;
bootstrap/inspection config surfaces, including static `config render`, remain ungated. The demo uses
`hostbootstrap-demo.dhall` in all runtime contexts, and daemons read one immutable config snapshot at
process start.

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
`runHostBootstrapCLI progName projectCommands testSuite` over an empty-but-buildable command tree. No host
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

### Phase 4 — project-local Dhall and command tree

The implemented phase originally landed the static-base `hostbootstrap.dhall` schema and the composable
optparse command tree that project binaries extend through `runHostBootstrapCLI`. It is now `Done` again:
the supported schema is `ProjectConfig` for project-local `<project>.dhall`, project identity validates
against the Cabal-derived name, Dockerfile/resources/runtime context live in the binary-owned config, and
the old static-base compatibility API is tracked in the legacy ledger for removal during the Python
migration.

### Phase 5 — cluster lifecycle and resource cordoning

Land kind/Helm cluster-lifecycle semantics and resource-budget verification and cordoning: on Apple
by sizing a dedicated per-project Colima VM, on Linux by applying kind node resource limits. Land
the never-delete-`.data` invariant and the production-vs-test cluster profile distinction. This phase is
`Done` (Sprint 5.4 closed): the kind/Helm lifecycle (with the `.data` invariant and the profile
distinction, test data under `./.test_data/<case>/`) and the cordon cores are implemented and unit-tested,
and the **applied** cordon + the `verifyBudget` spare-capacity preflight landed in Phase 9; the reopen
makes `cluster up` **fail-closed** on its helm/kind steps (`requireStep` replacing the swallowed
`reportStep`), run in the in-container path via the self-reference lift.

### Phase 6 — base image and thin Python bootstrapper

Warm the `hostbootstrap-core` dependencies into the frozen Cabal store. The base image bakes **no**
`hostbootstrap` binary — a Linux ELF cannot run on Apple silicon, so it could not be copied out to
every host; instead every project builds its own binary **host-native**, and the project container the
binary later builds (`FROM` the base image) is accelerated by the warm store. This phase is `Done`: Python
derives the project name from the Cabal file, builds the host-native binary, triggers the binary's
idempotent `config init --if-missing` (so a default `./.build/<project>.dhall` always exists), and execs
it — without Python itself reading or writing Dhall. Docker, the project container, config writing/decoding,
VM sizing, and cordoning stay with the project binary. The
`core.freeze`/`daemon.freeze` layering remains Phase 12 and is still `Done`.

### Phase 7 — consumer migration

Outline the migration of consumers onto `hostbootstrap-core`: `daemon-substrate` and `mcts` first,
with `infernix` and `jitML` as future work. Each consumer ships one optparse binary that extends the
core rather than re-implementing core verbs. This phase is `Done`: `hostbootstrap-core` is consumable,
the derived-project standard and the **three-level library hierarchy** (L0 core ◄ L1 `daemon-substrate`
◄ L2 `{jitML, infernix}`; `mcts` L0-direct) are documented, and the worked consumer is `hostbootstrap-demo`
(Phase 13, superseding the retired thin example binary). The consumer-side wiring of each sibling project
is that repository's own work.

## Where the architecture extends the plan

The global family architecture adds seven net-new phases on top of the inversion buildout. Each owns a
named slice of the architecture; see [system-components.md](system-components.md) and each phase doc.

### Phase 8 — Dhall generation and the four-stream extension

The project binary generates its own schema (reflected from its decoder types, so it cannot drift) and
renders deploy/test configs from a reusable `Core.dhall` vocabulary; the four-stream extension contract
(CLI append, Dhall embed, schema concatenation, harness seams) is formalized. The existing
`Core.dhall`, `HostBootstrap.Config.Vocab`, `HostBootstrap.Dhall.Gen`, `config schema`/`render`, and
`config init` work is implemented and tested. This phase is `Done`: `config init` emits role-specific
project-local configs without requiring an existing config, `config schema` includes the reflected
`ProjectConfig` type, and the pure child projection helpers generate narrower configs for VM, container,
service, daemon, one-shot, and test-harness roles. Phase 15 wired those generated configs into the normal
runtime gate through sibling `<project>.dhall`.

### Phase 9 — Applied budget cordon and one canonical parser

The declared budget becomes an enforced ceiling: one canonical `parseQuantity` feeding every argument
builder, the applied Linux `docker update` kind-node cordon wired into `cluster up` (after `kind
create`, before Helm, fail-closed), and the `verifyBudget`/`fitsBudget` gates run before bring-up. This
phase is `Done`: all of the above are implemented and tested; the incus VM storage cordon
(`incusSizingArgs`) landed with Phase 11 (Sprint 11.4).

### Phase 10 — Standardized test harness and run-models

One `hostbootstrap-core` harness (`runMatrix` over a `Seams` record, with isolated per-case profiles, the
prefix delete-guard, and budget-slicing) and the minimal four run-models
(`OneShot`/`HostNative`/`HostDaemon`/`Cluster`) the system selects between. This phase is `Done`
(Sprint 10.7 closed): the L0 engine, the pure cores, the `selectRunModel` key, the L0 OneShot seam
(`oneShotRunArgs` + the IO-wired `oneShotSeams`), and the `test`/`check-code` verbs are implemented and
unit-tested; the reopen isolates a throwing `seamSetup` to its own case (`try`-wrapped in `runMatrix`,
so a failed setup fails that case rather than crashing the matrix) and replaces the hollow demo seams
with real per-case assertions (phase-13).

### Phase 11 — incus first-class host-provider

`incus` becomes a host-provider axis (`HostTarget = Local | InVM`): `ensure incus` installs and verifies,
and the existing build/cluster/run/harness machinery runs inside a budget-sized incus VM with no per-call
branching. This phase is `Done` (Sprint 11.5 closed): the `Incus` host tool, the cross-substrate
`ensure incus` reconciler, `runInTarget`, the VM lifecycle argv + name-guard, `classifyDockerReadiness`,
and `incusSizingArgs` are implemented and unit-tested; the reopen adds the **self-reference lift**
(`HostBootstrap.Lift`), generalizing the two-case `HostTarget` to the n-level `Local | InVM | InContainer`
stack — a binary crosses a boundary by invoking its own subcommand there. GPU passthrough is a documented
future follow-on.

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
on a from-zero pristine-host bootstrap performed inside an incus VM (`apt install pipx` -> `pipx install
hostbootstrap` -> `hostbootstrap run`). It supersedes the retired `example/Main.hs`. This phase is `Done`:
the live demo and single-representation deploy chain are implemented and validated, and the worked app now
uses sibling `hostbootstrap-demo.dhall` configs for the host, VM, ad-hoc VM container, and
cluster-service/daemon contexts.

### Phase 14 — Composable-operation algebra and composition methodology

`hostbootstrap-core` composes host management as **operations**; a binary crosses an execution-context
boundary by invoking its own subcommand in the nested context (the self-reference lift, Phase 11), and the
same algebra expresses both deployment and runtime business logic (stateless roles over durable external
stores). This phase is `Done`: the composition **methodology** and cookbook are documented
([composition_methodology.md](../documents/architecture/composition_methodology.md),
[composition_patterns.md](../documents/engineering/composition_patterns.md),
[authoring_project_binaries.md](../documents/engineering/authoring_project_binaries.md)) and § U is
rewritten to the n-level lift (Sprint 14.1); the L0 role-lifecycle skeleton
(`HostBootstrap.RoleLifecycle`, consumed by the demo's F2 role) is landed (Sprint 14.2); and the
**single-representation doctrine** (§ W) — one operation, one representation; the standardized test
harness is the one representation, **lifted** into the project container in the VM, with **no** parallel
deploy chain alongside it — is captured (Sprint 14.3) and **realized**: Phase 13 **Sprint 13.12**
collapsed the demo to the single lift sequence and live-validated it (kind on the VM's Docker, `3/3`, none
on metal). The concrete bus/store/role primitives are
**L1 (`daemon-substrate`)** work, out of scope here.

### Phase 15 — Binary context config and command gating

Make the self-reference lift explicit at runtime by giving each copy of a project binary a sibling
`<project>.dhall`. The role is data inside the file rather than part of the filename, so the host binary,
VM binary, ad-hoc container binary, and service/daemon binary all use the same local lookup rule while
carrying different allowed commands and capabilities. Normal commands fail fast with exit code 1 when the
local config is missing, malformed, for another project, or not commensurate with the command; help,
version, `config init`, `config schema`, `config show`, `config path`, and static `config render` remain
the inspection/bootstrap exceptions. This phase is `Done`: the old standalone context filename and Dockerfile shortcut are removed,
normal command gating reads the context section of `<project>.dhall`, and the legacy static-base
compatibility API is deleted.

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
  phase-14 (builds on 11; the composition methodology the demo's chain exercises via 13)
  phase-15 (builds on 6, 8, 11, 13, 14; makes each lifted/runtime context explicit)
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
