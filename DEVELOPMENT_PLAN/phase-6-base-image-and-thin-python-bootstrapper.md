# Phase 6: Base Image and Thin Python Bootstrapper

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-7-consumer-migration.md](phase-7-consumer-migration.md)

> **Purpose**: Bake the skeletal `hostbootstrap` binary and warm `hostbootstrap-core` deps into the
> base image, and shrink the Python layer to the pre-binary bootstrapper that ensures Docker, builds
> the container, copies the binary out, and execs it.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-5 (the baked binary must already carry the full core command tree, including
cluster lifecycle and cordoning) and phases 1–4 for the binary itself.

No code in this phase is written. The Python CLI is still the full host-management layer; the base
image bakes no `hostbootstrap` binary.

## Phase Objective

Complete the inversion. The base image bakes the skeletal `hostbootstrap` binary (the core command
tree with no project commands) and warms the `hostbootstrap-core` dependencies into the frozen Cabal
store. The Python layer shrinks to the bootstrapper that does only what must run before any project
binary exists (see [development_plan_standards.md § M, N](development_plan_standards.md)): assert the
fail-fast host minimums, ensure Docker (per-project Colima VM on Apple sized to the budget), build
the project container as the `check-code` gate, copy the binary to `./.build/`, and exec it.

## Sprints

### Sprint 6.1: Base image bakes the binary + warm store [Blocked]

**Status**: Blocked
**Blocked by**: phase-5
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/warm_store.md`,
`system-components.md`

#### Objective

Bake the skeletal `hostbootstrap` binary into the base image and warm the `hostbootstrap-core`
dependencies into the frozen Cabal store.

#### Deliverables

- The base Dockerfile builds and installs the skeletal `hostbootstrap` binary (core tree, no project
  commands) so it is exec-ready before any project build.
- The warm Cabal store + `cabal.project.freeze` carry `hostbootstrap-core`'s prebuilt dependencies
  for derived project builds.
- `ormolu`/`fourmolu` and `hlint` remain pinned in the base for the quality gate.

#### Validation

- A fresh base image runs `hostbootstrap --help` (the baked core tree).
- A derived project build resolves against the warm store.

#### Remaining Work

- All of it; blocked on phase-5.

### Sprint 6.2: Shrink Python to the bootstrapper [Blocked]

**Status**: Blocked
**Blocked by**: sprint 6.1
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/build_and_run_model.md`, `system-components.md`

#### Objective

Reduce the Python CLI to the thin bootstrapper, removing the three-execution-model dispatch and the
`--force-target` model branching.

#### Deliverables

- The Python bootstrapper runs the five-step path: fail-fast minimums → ensure Docker (per-project
  Colima VM on Apple sized to the budget) → build the project container (`check-code` gate) → copy
  the binary to `./.build/` → ensure host runtimes and exec.
- Linux builds the binary in-container and copies it out (shared glibc family); Apple builds natively
  on the host (Python ensures host GHC via Homebrew) because a Linux ELF cannot exec on macOS; Tart
  is build-only.
- `hostbootstrap/models/*`, the `--force-target` model dispatch, and the model-keyed `cli.py`
  branching are removed; the residual fail-fast subset of `prereqs.py` is reclaimed into the
  bootstrapper.

#### Validation

- On each substrate, the bootstrapper leaves a `./.build/<binary>` and execs it; the container image
  builds on every substrate as the code-check gate.

#### Remaining Work

- All of it; blocked on sprint 6.1. Move the removed surfaces from Pending to Completed in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) as they land.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/python_haskell_boundary.md` - the thin-bootstrapper vs core ownership
  boundary.
- `documents/architecture/build_and_run_model.md` - substrate-dependent build/run; Tart build-only;
  Linux-ELF-cannot-run-on-macOS → Apple host-GHC.

**Engineering docs to create/update:**
- `documents/engineering/base_image.md` - the baked skeletal binary.
- `documents/engineering/warm_store.md` - the warmed `hostbootstrap-core` deps.

**Cross-references to add:**
- `system-components.md` updates the base-image and thin-bootstrapper sections.
- `legacy-tracking-for-deletion.md` moves `models/*` and the `--force-target` dispatch to Completed.
