# Phase 6: Base Image and Python CLI Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-7-consumer-migration.md](phase-7-consumer-migration.md)

> **Purpose**: Warm `hostbootstrap-core`'s dependencies into the base image (no `hostbootstrap`
> binary is baked), and expose the thin Python CLI surface that consumes Phase 2's pre-binary
> build-toolchain bootstrap to build the binary host-native and exec it.

## Phase Status

**Status**: Done

The base image bakes **no** `hostbootstrap` binary — a Linux ELF cannot run on Apple silicon — so every
project builds its own binary **host-native**. The project container the binary builds later is
accelerated by the warm Cabal store. The Python CLI exposes `doctor` / `build` / `run` / `update` /
`base`, and consumes Phase 2's thin pre-binary boundary (§ M, § N): derive the project from the single
Cabal file, assert host minimums, ensure the host build toolchain, build the binary host-native on every
substrate, and exec it (the binary owns config init — see the forward-pointer below). Docker, the
project-container build, VM sizing, cordoning, and Dhall read/write are project-binary responsibilities.
The `core.freeze` / `daemon.freeze` layering is owned by
[phase-12-layered-warm-store.md](phase-12-layered-warm-store.md) (§ V), not this phase.

Forward-pointer: the bootstrapper's post-build `config init --if-missing` auto-init is dropped under the
generic project model — Python builds the host-native binary and execs it without triggering config
creation, and the binary fails fast when no sibling `<project>.dhall` exists. That removal is owned by
[phase-19-generic-project-model.md](phase-19-generic-project-model.md) (Sprint 19.5) and tracked in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

Sprint 6.5 adds the explicit `hostbootstrap update` command that reinstalls the pipx-managed Python
bootstrapper from the canonical VCS source. That command is not automatic and does not become a
latest-version gate for `doctor`, `build`, `run`, or `base`.

Windows does not reopen this phase. The Windows host floor, winget-driven Haskell toolchain bootstrap, and
native `hostbootstrap.exe` build validation are owned by Phase 2 so they precede all Haskell-gated work.
WSL2 is not pre-binary work; it is owned by Phase 11's provider reconciler.

## Remaining Work

None.

## Phase Objective

Complete the inversion. The base image warms the `hostbootstrap-core` dependencies into the frozen
Cabal store and bakes **no** `hostbootstrap` binary (a Linux ELF cannot run on Apple silicon, so it
could not be copied out to every host; every project builds its own binary host-native instead). The
Python CLI surface consumes Phase 2's pre-binary bootstrap (see
[development_plan_standards.md § M, N](development_plan_standards.md)): derive the project name from the
Cabal file, assert the fail-fast host minimums, ensure the host toolchain prerequisites to **build** the
binary, build the project binary host-native, and exec it. Ensuring Docker, building the project
container, initializing/editing Dhall config, provider setup, and cordoning are left to the project
binary, once it is running.

The Python layer also owns the bootstrapper's own explicit pipx self-update command. That command updates
the wrapper itself, not any project resource, and therefore stays outside the Haskell `ensure` suite.

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
- `base` drives the operator-directed base-image build/publish path; on Linux it measures host CPU/RAM
  (`hostbootstrap/resources.py`), refuses below a floor, and applies docker `--memory`/`--cpus` caps plus a
  host-sized `cabal -j` to the base-image build container (a build-phase limit, not a project cordon — § O).
- `prereqs.py` carries only the residual fail-fast host minimum checks; the Linux minimums are Ubuntu 24.04
  + passwordless sudo (one floor for `build`/`doctor`/`run`). `/dev/kvm` and the `linux-gpu` NVIDIA
  container runtime are runtime preconditions the binary owns (`ensure incus` / `ensure cuda`), not
  wrapper checks.

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
binary, and exec it — all without Python itself decoding, writing, or triggering Dhall initialization (the
binary owns that surface).

#### Deliverables

- Cabal-file project-name derivation, including a fail-fast diagnostic when zero or multiple Cabal files
  make the project name ambiguous.
- Python derives the project name from the Cabal file and has no Dhall decoder.
- Initial config creation is a project-binary command (`<project> project init`); Python does not trigger
  it. Normal missing-config errors are emitted by the project binary.

#### Validation

- Python tests cover Cabal-name discovery and ambiguity failures.
- Python tests prove `hostbootstrap run` invokes no `dhall-to-json` and writes no Dhall artifact.
- Existing bootstrap command-builder tests still prove host-native build and exec argv behavior.

#### Remaining Work

None. Validation: `poetry run python -m hostbootstrap.check_code` passes; `poetry run python -m
hostbootstrap.test_all -q` passes with 113 tests. The tests cover Cabal-file project discovery,
zero/multiple-Cabal diagnostics, host-native build/exec argv, and the absence of Python-written Dhall
artifacts.

### Sprint 6.5: Explicit pipx self-update [Done]

**Status**: Done
**Implementation**: `hostbootstrap/cli.py`, `hostbootstrap/self_update.py`,
`tests/test_cli.py`, `tests/test_self_update.py`
**Docs to update**: `documents/engineering/self_update.md`,
`documents/architecture/python_haskell_boundary.md`, `documents/architecture/build_and_run_model.md`,
`documents/engineering/prerequisites.md`, `documents/languages/python.md`, `README.md`,
`system-components.md`, `legacy-tracking-for-deletion.md`

#### Objective

Add an explicit `hostbootstrap update` command for the pipx-installed Python bootstrapper without
turning wrapper freshness into a hidden precondition for normal commands.

#### Deliverables

- `hostbootstrap update` runs a forced pipx reinstall from the canonical direct VCS requirement:
  `hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main`.
- The command is Python-owned because it replaces the pipx-installed wrapper itself; it is not a
  Haskell `ensure` reconciler and contains no Docker, Dhall, VM, cluster, resource, or cordon logic.
- Optional operator controls may include `--ref`, `--spec`, and explicit `--check`.
- `--check`, if implemented, reads installed direct URL metadata and compares it to the requested remote
  ref only when the user invokes the check. Non-VCS/local installs report unknown freshness cleanly.
- `doctor`, `build`, `run`, `base build`, and `base build-and-push` do not self-update, do not check
  GitHub freshness, and do not fail merely because a newer commit exists.

#### Validation

- Unit tests cover the generated pipx argv without mutating the user's pipx environment.
- Failure tests cover missing `pipx`, failed subprocesses, and local/non-VCS installs for freshness
  checks.
- CLI smoke tests prove `hostbootstrap --help` lists `update` after implementation and still lists only
  the intended thin Python surface.
- `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
  pass.

#### Remaining Work

None. Validation: `poetry run python -m hostbootstrap.check_code` passes; `poetry run python -m
hostbootstrap.test_all -q` passes with 139 tests. The tests cover generated pipx argv, Click wiring,
subprocess failures, direct URL metadata parsing, unknown local/non-VCS freshness, and read-only remote
commit comparison seams.

### Sprint 6.6: Consume the Phase-2 Windows bootstrap in the CLI surface [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py` (`toolchain_ensure_steps` Windows branch,
`native_build_command` / `binary_path` / `exec_argv` for `hostbootstrap.exe`), `hostbootstrap/prereqs.py`
(Windows host minimums: winget only), `hostbootstrap/cli.py`, `tests/test_bootstrap.py`,
`tests/test_prereqs.py`, `tests/test_cli.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/engineering/prerequisites.md`, `documents/engineering/base_image.md`, `system-components.md`

#### Objective

Keep the CLI surface uniform on Windows while consuming Phase 2's pre-binary bootstrap. Phase 6 owns the
`doctor` / `build` / `run` command wiring and the no-baked-binary/base-image inversion; Phase 2 owns the
host-floor/toolchain bootstrap that makes the native `.exe` build possible.

#### Deliverables

- `prereqs.py` treats **winget** as the Windows pre-binary package-manager root. The wrapper itself reaches
  a fresh Windows host through a one-time pipx-via-winget install (winget installs Python + pipx, pipx
  installs `hostbootstrap`), the only step that must precede any project binary.
- `toolchain_ensure_steps` consumes Phase 2's **Windows branch** (winget-rooted GHCup → GHC/Cabal),
  probing each tool first and installing only when absent, alongside the existing Apple (Homebrew →
  `ghcup` → GHC/Cabal) and Linux (`ghcup` → GHC/Cabal) branches. MSVC belongs to the binary-owned
  `ensure cudawin` reconciler, where nvcc needs a host C++ compiler.
- `native_build_command` / `binary_path` / `exec_argv` build and exec the native **`hostbootstrap.exe`**
  host-native on Windows exactly as the Apple arm64 peer builds and execs `./.build/<binary>` — no
  copy-out, no container build (§ N). On native Windows GHC `System.Info.os` is `mingw32`, the substrate
  the core's conditionalized POSIX-only `unix` dependency targets.
- WSL2 is intentionally absent from the Python pre-binary gate. The binary's WSL2 host provider is owned
  by [phase-11](phase-11-incus-host-provider.md) and may classify a host reboot there.
- `run` still does not ensure Docker, build the project container, size a VM, apply a cordon, or evaluate
  Dhall on Windows; those are project-binary responsibilities (§ M).

#### Validation

- The command wiring and pure command-builders are unit-tested via mocked subprocess seams (no winget/host
  mutation); `test_all` and `check_code` are clean.

#### Remaining Work

None. Validation: `poetry run python -m hostbootstrap.check_code` passes; `poetry run python -m
hostbootstrap.test_all` passes. Live Windows toolchain/bootstrap validation is Phase 2; WSL2 real-run
validation is Phase 11.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/python_haskell_boundary.md` - the thin-bootstrapper vs core ownership
  boundary.
- `documents/architecture/build_and_run_model.md` - substrate-dependent build/run; the Windows native
  `hostbootstrap.exe` host-native build; Linux-ELF-cannot-run-on-macOS → Apple host-GHC.

**Engineering docs to create/update:**
- `documents/engineering/base_image.md` - the warm store and the no-baked-binary rationale.
- `documents/engineering/warm_store.md` - the warmed `hostbootstrap-core` deps.
- `documents/engineering/self_update.md` - the explicit pipx self-update doctrine and no hidden
  latest-version gate.
- `documents/engineering/prerequisites.md` - wrapper freshness is not a host minimum.
- `documents/languages/python.md` - pipx install/update command forms.

**Cross-references to add:**
- `system-components.md` updates the base-image and thin-bootstrapper sections.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces.
