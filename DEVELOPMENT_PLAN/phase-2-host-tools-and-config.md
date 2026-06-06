# Phase 2: Host Tools and Config

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md)

> **Purpose**: Lift infernix's `HostTools` / `HostConfig` / `HostPrereqs` trio and substrate
> detection into `HostBootstrap.*`, establishing closed-enumeration host-tool resolution and typed
> substrate detection as the foundation the reconcilers build on.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-1 (these modules need the `hostbootstrap-core` cabal stanza and the command-tree
entrypoint to live in).

No code in this phase is written. Substrate detection and prerequisite checks exist today only in
Python (`hostbootstrap/substrate.py`, `hostbootstrap/prereqs.py`).

## Phase Objective

Lift the host trio from [`infernix`](https://github.com/Tuee22/infernix) — the source of
`HostTools` / `HostConfig` / `HostPrereqs` — into `HostBootstrap.*`, and move substrate detection
(`apple-silicon`, `linux-cpu`, `linux-gpu`) into typed Haskell. Establish the host-tool-resolution
doctrine: a closed `HostTool` enumeration resolved to absolute paths, with no `$PATH`-resolved bare
command names (see [development_plan_standards.md § K](development_plan_standards.md)).

## Sprints

### Sprint 2.1: HostTool resolution + HostConfig [Blocked]

**Status**: Blocked
**Blocked by**: phase-1, sprint 1.2
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/prerequisites.md`, `system-components.md`

#### Objective

Land `HostBootstrap.HostTool` (the closed `HostTool` enumeration and absolute-path resolution) and
`HostBootstrap.HostConfig` (typed host configuration), lifted from infernix.

#### Deliverables

- `HostBootstrap.HostTool` with a closed `HostTool` sum type and a resolver that returns absolute
  paths from typed configuration; no `proc "<bare-name>"` `$PATH` lookups.
- `HostBootstrap.HostConfig` carrying the typed host configuration the resolver and reconcilers read.

#### Module Surface

- `HostBootstrap.HostTool` — `data HostTool = Docker | Colima | Brew | Ghc | Kubectl | Helm | Kind |
  NvidiaSmi | Tart | …`; `resolve :: HostConfig -> HostTool -> IO (Path Abs File)`.

#### Validation

- `cabal build all` succeeds.
- A unit check asserts resolution returns absolute paths and never a bare command name.

#### Remaining Work

- All of it; blocked on phase-1.

### Sprint 2.2: HostPrereqs + substrate detection [Blocked]

**Status**: Blocked
**Blocked by**: sprint 2.1
**Docs to update**: `documents/engineering/prerequisites.md`, `system-components.md`

#### Objective

Land `HostBootstrap.HostPrereqs` (the typed host-minimum checks) and `HostBootstrap.Substrate`
(substrate detection), porting the logic currently in `hostbootstrap/prereqs.py` and
`hostbootstrap/substrate.py` into Haskell.

#### Deliverables

- `HostBootstrap.Substrate` detecting `apple-silicon` / `linux-cpu` / `linux-gpu` plus the
  Docker-style arch (`amd64` / `arm64`), pure where the Python original is pure.
- `HostBootstrap.HostPrereqs` carrying the fail-fast host minimums (passwordless sudo, Ubuntu 24.04
  for Linux, Xcode CLT + Homebrew for Apple, Docker reachability, NVIDIA runtime for `linux-gpu`).

#### Validation

- `cabal build all` succeeds.
- Detection unit tests cover each substrate branch.

#### Remaining Work

- All of it; blocked on sprint 2.1. The pure-Python `prereqs.py` / `substrate.py` remain the live
  implementation until phase-6 reclaims the residual fail-fast subset into the thin bootstrapper; see
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - adds the host-tool-resolution doctrine and
  the substrate-detection ownership statement.

**Engineering docs to create/update:**
- `documents/engineering/prerequisites.md` - records the fail-fast host minimums and the move of
  richer host logic into Haskell.

**Cross-references to add:**
- `system-components.md` marks the `HostBootstrap.HostTool` / `HostConfig` / `HostPrereqs` /
  `Substrate` rows present once they land; `legacy-tracking-for-deletion.md` keeps the
  `prereqs.py` / `substrate.py` removal owning-phase aligned.
