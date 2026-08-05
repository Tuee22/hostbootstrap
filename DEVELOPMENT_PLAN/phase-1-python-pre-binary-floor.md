# Phase 1 — Python pre-binary floor

**Status**: Done
**Depends on**: Phase 0 (governance and documentation standards)
**Substrates**: linux-cpu
**Gate**: `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root

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

Both commands pass from the repository root. Dated evidence: `231 passed`, and `ruff`/`black`/`mypy`
clean, on macOS 25.5.0 arm64 (2026-08-05).

#### Remaining Work

None.

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
