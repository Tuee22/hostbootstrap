# Phase 6: Base Image and Thin Python Bootstrapper

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-7-consumer-migration.md](phase-7-consumer-migration.md)

> **Purpose**: Warm `hostbootstrap-core`'s dependencies into the base image (no `hostbootstrap`
> binary is baked), and shrink the Python layer to the pre-binary bootstrapper that derives the project
> name from the Cabal file, ensures the host build toolchain, builds the binary host-native, and execs it.

## Phase Status

**Status**: Done

The base image bakes **no** `hostbootstrap` binary — a Linux ELF cannot run on Apple silicon — so every
project builds its own binary **host-native**. The project container the binary builds later is
accelerated by the warm Cabal store. The Python CLI exposes only the `doctor` / `build` / `run` / `base`
surface, and `bootstrap.py` follows the thin pre-binary boundary (§ M, § N): derive the project from the
single Cabal file, assert host minimums, ensure the host build toolchain, build the binary host-native on
every substrate, trigger the binary's idempotent `config init --if-missing`, and exec. Docker, the
project-container build, VM sizing, cordoning, and Dhall read/write are project-binary responsibilities.
The `core.freeze` / `daemon.freeze` layering is owned by
[phase-12-layered-warm-store.md](phase-12-layered-warm-store.md) (§ V), not this phase.

## Remaining Work

None.

## Phase Objective

Complete the inversion. The base image warms the `hostbootstrap-core` dependencies into the frozen
Cabal store and bakes **no** `hostbootstrap` binary (a Linux ELF cannot run on Apple silicon, so it
could not be copied out to every host; every project builds its own binary host-native instead). The
Python layer shrinks to the pre-binary bootstrapper that does only what must run before any project
binary exists (see [development_plan_standards.md § M, N](development_plan_standards.md)): derive the
project name from the Cabal file, assert the fail-fast host minimums, ensure the host toolchain
prerequisites to **build** the binary, build the project binary host-native, and exec it. Ensuring Docker,
building the project container, initializing/editing Dhall config, and cordoning are left to the project
binary, once it is running.

## Sprints

### Sprint 6.1: Base image warm store (no baked binary) [Done]

**Status**: Done
**Implementation**: `docker/basecontainer.Dockerfile`,
`core/warm-deps/core/basecontainer-core-deps.cabal`
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/warm_store.md`,
`system-components.md`

#### Objective

Warm the `hostbootstrap-core` dependency closure into the frozen Cabal store, and establish that the
base image bakes **no** `hostbootstrap` binary.

#### Deliverables

- The base image bakes no `hostbootstrap` binary: a Linux ELF cannot run on Apple silicon, so it
  could not be copied out to every host. Every project builds its own binary **host-native**; the
  project container the binary later builds (`FROM` the base) is accelerated by the warm store.
- The warm Cabal store + the layered freezes carry `hostbootstrap-core`'s prebuilt dependencies
  for every project's in-container project-container build (the host-native binary build uses the host
  toolchain the bootstrapper ensures). The warm-store core manifest
  (`core/warm-deps/core/basecontainer-core-deps.cabal`) lists the full
  `hostbootstrap-core` dependency closure (the freeze layering itself is Phase 12).
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
**Implementation**: `hostbootstrap/cli.py` (thin `doctor` / `build` / `run` / `base` surface),
`hostbootstrap/bootstrap.py` (the pre-binary bootstrap path), `hostbootstrap/prereqs.py` (host
minimums), `hostbootstrap/base_image.py`, `hostbootstrap/docker_ops.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/build_and_run_model.md`, `system-components.md`

#### Objective

Reduce the Python CLI to the thin bootstrapper and base-image operator surface.

#### Deliverables

- The CLI exposes `doctor`, `build`, `run`, and `base`.
- `run` and `build` drive the host-native binary build path.
- `base` drives the operator-directed base-image build/publish path.
- `prereqs.py` carries only the residual fail-fast host minimum checks.

#### Validation

- `poetry run python -m hostbootstrap.check_code` is clean (ruff + black + mypy `--strict`); the test
  suite passes and `coverage report` is at **100%** (`fail_under = 100`), the only `# pragma: no cover`
  being the terminal `os.execv`. `hostbootstrap --help` lists `doctor` / `build` / `run` / `base`.

#### Remaining Work

None. The thin-pre-binary-boundary convergence is Sprint 6.3.

### Sprint 6.3: Converge `bootstrap.py` on the §M/§N boundary [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `hostbootstrap/cli.py`,
`tests/test_bootstrap.py`, `tests/test_cli.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/build_and_run_model.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Reduce `bootstrap.py` to the pre-binary path so the Python layer does only what must run before any
project binary exists (§ M, § N): assert minimums → ensure the host build toolchain → build the binary
**host-native on every substrate** → trigger config initialization → exec it.

#### Deliverables

- `toolchain_ensure_steps` ensures the host build toolchain substrate-branched (Homebrew → `ghcup`
  → GHC/Cabal on Apple; `ghcup` → GHC/Cabal on Linux), **probing each tool first and installing only
  when absent** so the already-provisioned common path is silent and offline; the binary is built
  host-native on **every** substrate (`native_build_command`), then execed.
- `run` does not ensure Docker, build the project container, size a VM, apply a cordon, or evaluate
  Dhall; those operations belong to the project binary.

#### Validation

- The new pure command-builders (`toolchain_ensure_steps`, `native_build_command`, `binary_path`,
  `exec_argv`) and the driver are unit-tested via the mocked subprocess seams (no Docker/host mutation);
  `test_all` passes at **100%** coverage and `check_code` is clean. Live per-substrate execution is
  exercised during real bootstrap runs.

#### Remaining Work

None.

### Sprint 6.4: Remove Python Dhall ownership [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `hostbootstrap/cli.py`, `tests/test_bootstrap.py`,
`tests/test_cli.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/build_and_run_model.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make Python a pure pre-binary bridge: derive the project name from the Cabal file, build the host-native
binary, trigger the binary's idempotent `config init --if-missing` so a default `<project>.dhall` always
exists, and exec it — all without Python itself decoding or writing Dhall (the binary owns that surface).

#### Deliverables

- Cabal-file project-name derivation, including a fail-fast diagnostic when zero or multiple Cabal files
  make the project name ambiguous.
- Python derives the project name from the Cabal file and has no Dhall decoder.
- Initial config creation is a project-binary command
  (`<project> config init`), which Python triggers post-build via the idempotent `--if-missing` mode so a
  default config always exists, and normal missing-config errors are emitted by the project binary.

#### Validation

- Python tests cover Cabal-name discovery and ambiguity failures.
- Python tests prove `hostbootstrap run` invokes no `dhall-to-json` and writes no Dhall artifact.
- Existing bootstrap command-builder tests still prove host-native build and exec argv behavior.

#### Remaining Work

None. Validation: `poetry run python -m hostbootstrap.check_code` passes; `poetry run python -m
hostbootstrap.test_all -q` passes with 113 tests. The tests cover Cabal-file project discovery,
zero/multiple-Cabal diagnostics, host-native build/exec argv, and the absence of Python-written Dhall
artifacts.

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
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces.
