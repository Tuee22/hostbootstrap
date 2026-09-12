# Phase 1 — Python pre-binary floor

**Status**: Active
**Depends on**: Phase 0 (governance and documentation standards)
**Substrates**: linux-cpu
**Gate**: `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root
**Gate kind**: deferred
**Gate evidence**: 2026-09-09 ; x86_64 Ubuntu 24.04.4 LTS, Python 3.12.3, Poetry 2.4.1 ;
`poetry run python -m hostbootstrap.check_code && poetry run python -m hostbootstrap.test_all` ; pass ;
covers 94d3d28830984fd65f6e9382db6b7a813a125122936ecb0f354209420557eaba
**Evidence covers**: `hostbootstrap` `tests` `pyproject.toml`

> **Purpose**: Assert the irreducible host floor, prepare the native Haskell toolchain, build the project
> binary host-native, and hand control to it.

## Phase Objective

Something has to run before the Haskell binary exists. That something is a thin Python bootstrapper whose
whole job is to make the binary buildable and then get out of the way: assert the host floor, install the
pinned toolchain, build host-native, and invoke the result. It owns no lifecycle, no configuration model,
and no second implementation of anything the Haskell core owns.

Two operator-invoked surfaces stay in Python because they exist *before* or *outside* a project binary:
the base-image build/publish surface and the pipx self-update surface.

## Sprints

### Sprint 1.1: Host floor assertion and prerequisites [Done]

**Status**: Done
**Implementation**: `hostbootstrap/prereqs.py`, `hostbootstrap/substrate.py`,
`hostbootstrap/resources.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

Refuse early and legibly when the host cannot host the build.

#### Deliverables

- `prereqs.py` asserts the pre-binary floor and names the exact missing prerequisite.
- `substrate.py` classifies the host so the floor is substrate-correct rather than lowest-common-denominator.
- `resources.py` reads host capacity for the pre-binary decisions that need it.
- A refusal names the prerequisite and the remedy; it never partially proceeds.

#### Validation

`hostbootstrap.test_all` covers the floor and each classification branch.

#### Remaining Work

None.

### Sprint 1.2: Native toolchain preparation and binary build [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `hostbootstrap/process.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/engineering/build_release.md`

#### Objective

Build the project binary host-native and invoke it.

#### Deliverables

- `bootstrap.py` prepares the pinned GHC/Cabal toolchain and builds the project binary for the host's own
  architecture — never cross-built, never fetched pre-built.
- The build is idempotent: an up-to-date binary is not rebuilt.
- Invocation is process replacement (`exec`) on POSIX and a child subprocess on Windows, so the binary's
  exit status is the operator's exit status.
- `process.py` is the single place a subprocess is launched, with explicit stdio disposition.

#### Validation

`hostbootstrap.test_all` covers the build decision, the idempotent path, and both invocation shapes.

#### Remaining Work

None.

### Sprint 1.3: The operator CLI surface [Done]

**Status**: Done
**Implementation**: `hostbootstrap/cli.py`, `hostbootstrap/base_image.py`,
`hostbootstrap/docker_ops.py`, `hostbootstrap/self_update.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/build_release.md`

#### Objective

Expose exactly the surfaces that must exist outside a project binary.

#### Deliverables

- `hostbootstrap run -- <args>` prepares and invokes the project binary.
- `hostbootstrap base build-and-push --flavor <f> --arch <a>` is the canonical base publication command:
  plain single-architecture `docker build` plus `docker push`, host-native, no buildx.
- `hostbootstrap self-update` is the explicit pipx update surface.
- `docker_ops.py` is the only place Docker is invoked.
- The bootstrapper implements no project lifecycle or configuration verb; those belong to the binary.

#### Validation

`hostbootstrap.test_all` covers argument routing, the publication command shape, and the self-update
surface.

#### Remaining Work

None.

### Sprint 1.4: The Python quality gate [Done]

**Status**: Done
**Implementation**: `hostbootstrap/check_code.py`, `hostbootstrap/test_all.py`, `pyproject.toml`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Make the Python half's gate one command with no bypass.

#### Deliverables

- `check_code` runs `ruff check`, then `black --check`, then `mypy`, over `hostbootstrap` and `stubs`.
- `test_all` sets the `HOSTBOOTSTRAP_TEST_ALL` sentinel and invokes `pytest tests` in-process; forwarded
  pytest arguments are supported.
- `tests/conftest.py` requires the sentinel, so there is one supported suite entry point.
- Coverage is configured with `fail_under = 100`.

#### Validation

Both commands pass from the repository root. Dated evidence: `235 passed` in 1.43 seconds, and
`ruff`/`black`/`mypy` clean, on x86_64 Ubuntu 24.04.4 LTS with Python 3.12.3 and Poetry 2.4.1
(2026-09-09).

#### Remaining Work

None.

### Sprint 1.5: One architecture value in the bootstrapper [Active]

**Status**: Active
**Implementation**: `hostbootstrap/substrate.py`, `hostbootstrap/base_image.py`, `hostbootstrap/docker_ops.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

The bootstrapper already names substrates and image flavors with closed enumerations. Architecture is
the third member of that vocabulary and is carried as a bare string, so every function that takes one
accepts any string and re-derives validity, or does not. One `Arch` value makes the two supported
architectures the only ones expressible, and makes the alias table a single mapping into it.

#### Deliverables

- `Arch` joins `SubstrateName` and `Flavor` as a closed enumeration in `hostbootstrap/substrate.py`.
- `Substrate.arch` and every tag, reference, build-argument, and download-URL producer take `Arch`.
- The alias table maps host machine strings into `Arch` once; the repeated membership test at the build-argument boundary is gone because its input is already narrowed.
- `normalize_architecture` in `docker_ops.py` reads the same table rather than carrying its own copy, and the copy is deleted.
- The mapping tables keyed by architecture are keyed by `Arch`, so a lookup cannot miss.
- `stubs/` no longer appears as a check target: it holds no stubs, and its presence needs a comment in the check runner explaining why one tool must skip it.

#### Validation

The host static gate. `poetry run python -m hostbootstrap.check_code` type-checks the narrowed
signatures under strict `mypy`, and `poetry run python -m coverage run -m hostbootstrap.test_all`
holds the 100% line gate — which means the tests must exercise both architectures rather than the one
the host happens to be.

#### Remaining Work

The subprocess vocabulary and the detection boundary are Sprint 1.6 and Sprint 1.7.

### Sprint 1.6: One way to run a command in the bootstrapper [Planned]

**Status**: Planned
**Implementation**: `hostbootstrap/process.py`, `hostbootstrap/prereqs.py`, `hostbootstrap/self_update.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

`process.py` is the bootstrapper's declared subprocess wrapper and only the Docker operations use it,
because it offers an asynchronous interface and most callers are synchronous. The rest reach for
`subprocess.run` directly, so the package carries four unrelated conventions for the same act: run a
command, decide whether it failed, and say so in this module's own vocabulary. A synchronous sibling
lets each caller keep its own error type and stop re-deriving the mechanics.

#### Deliverables

- `process.py` gains a synchronous probe that returns a result or reports that the command could not be executed at all, and a synchronous checked runner.
- The prerequisite checks, substrate detection, and self-update paths call them and wrap one result into their own error type.
- No module outside `process.py` imports `subprocess`.
- The distinction between 'ran and failed' and 'could not be run' survives in the result rather than in which exception was caught.

#### Validation

The host static gate, with coverage still at 100%. The prerequisite and self-update suites already
assert on the failure text each module produces; those assertions are the regression test that the
error vocabulary did not change when the mechanics did.

#### Remaining Work

None beyond the phase's own.

### Sprint 1.7: The bootstrapper's detection is the one the binary uses [Planned]

**Status**: Planned
**Implementation**: `hostbootstrap/substrate.py`, `hostbootstrap/bootstrap.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

Something must detect the host before the binary exists, and § M gives that job to the bootstrapper.
What does not follow is that the binary should detect it again: the two implementations agree today
down to their error strings, which is the shape a second implementation has right up until it drifts.
The bootstrapper passes what it found to the binary it launches.

#### Deliverables

- The bootstrapper hands its detected substrate and architecture to the binary through the documented invocation-context seam.
- The seam is typed and explicit, not an inherited environment value read opportunistically.
- `documents/architecture/python_haskell_boundary.md` states which side detects and which side receives.

#### Validation

The host static gate. The consuming half is Sprint 3.10 and the two land together; until it does, the
binary's own detection remains the fallback and nothing regresses.

#### Remaining Work

None beyond the phase's own.

## Remaining Work

The bootstrapper's architecture vocabulary is owed. **Sprint 1.5** owns it: architecture
is a closed value rather than a string, and the alias table has one home. Sprints 1.6 and 1.7 follow with
the subprocess vocabulary and the detection boundary.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/python_haskell_boundary.md` — the ownership boundary between the two halves.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the Python gate and the one supported suite entry point.
- `documents/engineering/build_release.md` — host-native build and invocation.
- `documents/engineering/base_image.md` — the operator publication command.

**Cross-references to add:**
- root `README.md` describes the two-language architecture and links to the boundary document.
- `CLAUDE.md` and `AGENTS.md` name the canonical development commands.
