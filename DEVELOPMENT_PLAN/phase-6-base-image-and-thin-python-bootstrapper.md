# Phase 6: Base Image and Thin Python Bootstrapper

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-7-consumer-migration.md](phase-7-consumer-migration.md)

> **Purpose**: Warm `hostbootstrap-core`'s dependencies into the base image (no `hostbootstrap`
> binary is baked), and shrink the Python layer to the pre-binary bootstrapper that ensures Docker,
> builds the container, copies the binary out, and execs it.

## Phase Status

**Status**: Active

The base image bakes **no** `hostbootstrap` binary — a Linux ELF cannot run on Apple silicon — so every
project builds its own binary host-native and in-container (the build-twice / copy-out model), accelerated
by the warm Cabal store (Sprint 6.1). The Python CLI is the thin five-step bootstrapper; the
three-execution-model machinery is removed and the Python suite passes at 100% coverage (Sprint 6.2). This
phase reopens against the layered-warm-store and in-image-freeze contract.

**Remaining Work** (reopened; the freeze split is tracked in the net-new
[phase-12-layered-warm-store.md](phase-12-layered-warm-store.md)):
- Split the warm store into `core.freeze` / `daemon.freeze` so a non-daemon consumer is not coupled to
  the daemon dependency closure (Phase 12).
- Generate both freezes in-image by `cabal freeze`, never committed (`.dockerignore`/`.gitignore`
  exclude them); FIX the dep-add "commit the freeze" doc claim.
- Add `purescript-bridge` to the warm store (the demo's web build).
- The baked-binary source comments are corrected.

## Phase Objective

Complete the inversion. The base image warms the `hostbootstrap-core` dependencies into the frozen
Cabal store and bakes **no** `hostbootstrap` binary (a Linux ELF cannot run on Apple silicon, so it
could not be copied out to every host; every project builds its own binary host-native and
in-container instead). The Python layer shrinks to the bootstrapper that does only what must run
before any project binary exists (see [development_plan_standards.md § M, N](development_plan_standards.md)):
assert the fail-fast host minimums, ensure Docker (per-project Colima VM on Apple sized to the
budget), build the project container as the `check-code` gate, copy the binary to `./.build/`, and
exec it.

## Sprints

### Sprint 6.1: Base image warm store (no baked binary) [Done]

**Status**: Done
**Implementation**: `docker/basecontainer.Dockerfile` (unchanged),
`haskell/haskell-deps/basecontainer-haskell-deps.cabal`
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/warm_store.md`,
`system-components.md`

#### Objective

Warm the `hostbootstrap-core` dependency closure into the frozen Cabal store, and establish that the
base image bakes **no** `hostbootstrap` binary.

#### Deliverables

- The base image bakes no `hostbootstrap` binary: a Linux ELF cannot run on Apple silicon, so it
  could not be copied out to every host. Every project builds its own binary host-native and
  in-container, accelerated by the warm store.
- The warm Cabal store + `cabal.project.freeze` carry `hostbootstrap-core`'s prebuilt dependencies
  for every project's host-native and in-container build. The warm-store manifest
  (`haskell/haskell-deps/basecontainer-haskell-deps.cabal`) already lists the full
  `hostbootstrap-core` dependency closure, so **no Dockerfile change is required**.
- `ormolu`/`fourmolu` and `hlint` remain pinned in the base for the quality gate.

#### Validation

- The warm-store manifest covers every `hostbootstrap-core` dependency, so a derived build resolves
  them from the warm store rather than recompiling (verifiable by pulling a published base tag and
  running `cabal build --dry-run` for `hostbootstrap-core` inside a throwaway `FROM`-it image — no
  from-scratch rebuild needed).

#### Remaining Work

None.

### Sprint 6.2: Shrink Python to the bootstrapper [Done]

**Status**: Done
**Implementation**: `python/hostbootstrap/cli.py` (thin `doctor` / `up` / `base` surface),
`python/hostbootstrap/bootstrap.py` (the five-step path), `python/hostbootstrap/spec.py`
(skeletal `SkeletalSpec` reader), `python/hostbootstrap/prereqs.py` (trimmed), skeletal
`python/hostbootstrap/dhall/package.dhall`; `python/hostbootstrap/models/` removed.
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/build_and_run_model.md`, `system-components.md`

#### Objective

Reduce the Python CLI to the thin bootstrapper, removing the three-execution-model dispatch and the
`--force-target` model branching.

#### Design Decision: skeletal config read

With no baked binary, the Python bootstrapper cannot read the skeletal `hostbootstrap.dhall` by
running a baked `hostbootstrap config show`. The cordon step (sizing the Apple Colima VM from
`resources`) and the container build (needing `dockerfile`) provably run **before** any project
binary exists, so the pre-binary layer (Python) must decode the skeletal Dhall itself — which the
ownership boundary already permits ("Python reads only the skeletal tier"). The decision: **retain a
minimized `python/hostbootstrap/dhall_tool.py`** (the in-process Haskell decoder still owns the rich
project/test tiers via the project binary). This reverses the earlier ledger intent to remove
`dhall_tool.py` in phase-6, a direct consequence of the no-baked-binary decision; the legacy ledger
is updated to match.

#### Deliverables

- The Python bootstrapper runs the five-step path: fail-fast minimums → ensure Docker (per-project
  Colima VM on Apple sized to the budget) → build the project container (`check-code` gate) → copy
  the binary to `./.build/` → ensure host runtimes and exec.
- Linux builds the binary in-container and copies it out (shared glibc family); Apple builds natively
  on the host (Python ensures host GHC via Homebrew) because a Linux ELF cannot exec on macOS; Tart
  is build-only.
- `python/hostbootstrap/models/*`, the `--force-target` model dispatch, and the model-keyed `cli.py`
  branching are removed; the residual fail-fast subset of `prereqs.py` is reclaimed into the
  bootstrapper.

#### Validation

- `poetry run python -m hostbootstrap.check_code` is clean (ruff + black + mypy `--strict`); the test
  suite passes and `coverage report` is at **100%** (`fail_under = 100`), the only `# pragma: no cover`
  being the terminal `os.execv`. `hostbootstrap --help` lists `doctor` / `up` / `base` and the
  removed `cluster` / `daemon` / `build` / `run` / `--force-target` surfaces are gone.
- The bootstrapper's per-substrate build/copy/exec command construction is unit-tested via mocked
  subprocess seams (no real Docker/host mutation in tests); live per-substrate execution is exercised
  during real bootstrap runs.

#### Remaining Work

None. The removed surfaces are moved to **Completed** in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/python_haskell_boundary.md` - the thin-bootstrapper vs core ownership
  boundary.
- `documents/architecture/build_and_run_model.md` - substrate-dependent build/run; Tart build-only;
  Linux-ELF-cannot-run-on-macOS → Apple host-GHC.

**Engineering docs to create/update:**
- `documents/engineering/base_image.md` - the warm store and the no-baked-binary rationale.
- `documents/engineering/warm_store.md` - the warmed `hostbootstrap-core` deps.

**Cross-references to add:**
- `system-components.md` updates the base-image and thin-bootstrapper sections.
- `legacy-tracking-for-deletion.md` moves `models/*` and the `--force-target` dispatch to Completed.
