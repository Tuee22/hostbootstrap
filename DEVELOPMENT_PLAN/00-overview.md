# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [system-components.md](system-components.md)

> **Purpose**: Tell the cross-phase narrative — from the current pure-Python CLI to the target
> Haskell `hostbootstrap-core` library plus thin Python bootstrapper — naming what each phase
> produces, why this order, and the dependency edges between them.

## Where the repository is today

`hostbootstrap` is currently a pure-Python Click application installed on each host (`pipx install
git+…`). It detects the substrate (`hostbootstrap/substrate.py`), validates host prerequisites
(`hostbootstrap/prereqs.py`), parses a project's `hostbootstrap.dhall` by shelling out to a pinned
`dhall-to-json` binary (`hostbootstrap/dhall_tool.py`, `hostbootstrap/spec.py`), and dispatches one
of three execution models — `Container`, `HostBinary`, `HostDaemon` — declared in that Dhall
(`hostbootstrap/models/*`, `hostbootstrap/cli.py`). It also builds and publishes the
`basecontainer-<flavor>-<arch>` base images. This is the working starting point; it is honest, but
it is not the target shape.

## Where the repository is going

The target inverts the language split. A Haskell `hostbootstrap-core` library owns essentially all
host-management logic; Python shrinks to the minimum that must run before any project binary exists.

The buildout reads as one ordered narrative:

### Phase 0 — documentation and governance

Convert the existing YAML-front-matter `documents/` suite to the unified metadata-block standard,
create this `DEVELOPMENT_PLAN/` tree, and name the documentation validator as a deliverable. No
code-writing phase may be marked `Active` or `Done` before Phase 0 closes. This phase is the one the
current documentation refactor advances; it is `Active`.

### Phase 1 — hostbootstrap-core scaffolding

Stand up the `hostbootstrap-core` Cabal package: a `library` stanza for the `HostBootstrap.*` module
surface and a skeletal executable. Pin GHC to the base-image toolchain, take
`optparse-applicative` and `dhall` as dependencies, and expose the generic entrypoint
`runHostBootstrapCLI progName projectCommands` over an empty-but-buildable command tree. No host
logic lands yet; this is the structural shell every later phase fills in.

Blocked by Phase 0 closing the plan and documentation standards so the cabal-layout doc lands
alongside the actual cabal file.

### Phase 2 — host tools and config

Lift `infernix`'s `HostTools` / `HostConfig` / `HostPrereqs` trio and substrate detection into
`HostBootstrap.*`. Host-tool resolution becomes a closed `HostTool` enumeration resolved to absolute
paths; substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) moves into typed Haskell.
`infernix` (https://github.com/Tuee22/infernix) is the source of the lifted trio.

Blocked by Phase 1 because these modules need a cabal stanza and the command-tree entrypoint to live
in.

### Phase 3 — ensure reconcilers

Land each host dependency as an idempotent `ensure` reconciler — a host-applicability predicate plus
a reconcile action — exposed as an optparse subcommand: `ensure docker`, `ensure colima`,
`ensure cuda`, `ensure homebrew`, `ensure ghc`, `ensure tart`. A reconciler run on the wrong host
fails fast with a one-line diagnostic and a non-zero exit.

Blocked by Phase 2 because the reconcilers consume the typed host-tool resolution and substrate
detection.

### Phase 4 — skeletal Dhall and command tree

Land the skeletal `hostbootstrap.dhall` schema (`project`, `dockerfile`, `resources {cpu, memory,
storage}`) and its in-process Haskell decoder, replacing the shelled `dhall-to-json` path. Land the
composable optparse command tree that project binaries extend through `runHostBootstrapCLI`.

Blocked by Phase 3 because the command tree composes the `ensure` subcommands, and by Phase 1 for
the entrypoint shape.

### Phase 5 — cluster lifecycle and resource cordoning

Land kind/Helm cluster-lifecycle semantics and resource-budget verification and cordoning: on Apple
by sizing a dedicated per-project Colima VM, on Linux by applying kind node resource limits. Land
the never-delete-`.data` invariant and the production-vs-test cluster profile distinction.

Blocked by Phase 4 because lifecycle reads the resource budget from the skeletal Dhall and exposes
its verbs through the command tree, and by Phase 3 for `ensure docker` / `ensure colima`.

### Phase 6 — base image and thin Python bootstrapper

Bake the skeletal `hostbootstrap` binary (the core tree with no project commands) into the base
image and warm the `hostbootstrap-core` dependencies into the frozen Cabal store. Shrink the Python
layer to the bootstrapper: assert fail-fast host minimums, ensure Docker (provision the per-project
Colima VM on Apple sized to the budget), build the project container as the `check-code` gate, copy
the built binary to `./.build/`, and exec it.

Blocked by Phase 5 because the baked binary must already carry the full core command tree, and by
Phase 1–4 for the binary itself.

### Phase 7 — consumer migration

Outline the migration of consumers onto `hostbootstrap-core`: `daemon-substrate` and `mcts` first,
with `infernix` and `jitML` as future work. Each consumer ships one optparse binary that extends the
core rather than re-implementing core verbs.

Blocked by Phase 6 because consumers extend the published base image and the baked core binary.

## Dependency edges

```text
phase-0  →  phase-1  →  phase-2  →  phase-3  →  phase-4  →  phase-5  →  phase-6  →  phase-7
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
- A separate "release" phase. The library is consumed by sibling path / base-image bake; there is no
  Hackage release ceremony.
