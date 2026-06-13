# Phase 15: Binary Context Config and Command Gating

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [binary_context_config](../documents/architecture/binary_context_config.md)

> **Purpose**: Make every project binary explicitly know where it is in the composed
> host/VM/container/cluster chain by reading a sibling `project-binary-context-config.dhall`, and make
> normal commands fail fast when the context is missing or does not authorize the command.

## Phase Status

**Status**: Done

Phases 6, 8, 11, 13, and 14 provide the needed substrate: the thin Python bootstrapper, typed Dhall
generation, the self-reference lift, the worked demo chain, and the composition methodology. This phase
turns the implicit context carried by lift composition into an explicit runtime precondition for every
binary process.

Sprints 15.1 through 15.4 are done. The core normal command tree and demo project verbs gate through the
sibling binary context, context creation surfaces exist for host/VM/container/service placement, and
normal cluster lifecycle commands use the active context instead of a `hostbootstrap.dhall` path.

## Remaining Work

None.

## Phase Objective

Introduce the runtime binary-context contract:

- `hostbootstrap.dhall` is the static bootstrap input read only by the Python wrapper.
- Every normal binary command reads `project-binary-context-config.dhall` from next to the executable
  before dispatch.
- The Python wrapper idempotently creates the host-level context after building `./.build/<project>`.
- Each nested boundary receives or creates its own context before the nested binary runs.
- Dockerfiles use `--create-container-config` after installing the binary and before `check-code`.
- Kubernetes service pods receive the context from their owning controller; durable services use a
  `StatefulSet`.
- Missing, undecodable, wrong-project, wrong-capability, or wrong-command contexts fail fast with exit
  code 1.

## Sprints

### Sprint 15.1: Context schema, loader, and command gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/hostbootstrap-core.cabal`
**Docs to update**: `documents/architecture/binary_context_config.md`, `documents/engineering/dhall_topology.md`, `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Define the `project-binary-context-config.dhall` type and land the Haskell substrate that loads it from
next to the running executable before normal optparse dispatch.

#### Deliverables

- `HostBootstrap.Context`: context type, Dhall decoder/encoder, sibling-file discovery, and validation.
- Command-gating API that checks project/binary identity, context kind, local capabilities, allowed
  command classes, and resource envelope before invoking command handlers.
- Exit-code-1 fail-fast behavior with one-line diagnostics for missing or invalid contexts.

#### Validation

- Unit tests for successful context load, missing file, decode failure, project mismatch, unavailable
  capability, and command/context mismatch.
- CLI tests proving normal commands fail before side effects when the context is absent or invalid.

#### Remaining Work

None. `cabal test all` passes with `ContextSpec` covering render/decode, sibling path discovery, missing
and malformed context files, project/binary/command/capability mismatches, exit-code-1 fail-fast behavior,
and no-side-effect command gating.

### Sprint 15.2: Python host-context bootstrap [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`, `documents/architecture/build_and_run_model.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Have the Python wrapper create the first runtime context because it is the only component that can bridge
from static `hostbootstrap.dhall` to an already-built host binary.

#### Deliverables

- The Python bootstrapper reads `hostbootstrap.dhall`, builds `./.build/<project>`, and idempotently
  writes `./.build/project-binary-context-config.dhall` before exec.
- The host context carries project/binary identity, host-orchestrator context kind, initial resource
  envelope, and the child-context rules needed by the project binary.
- `hostbootstrap.dhall` remains the only Python-facing Dhall file.

#### Validation

- Python tests for idempotent creation, unchanged reruns, malformed static bootstrap input, and correct
  host-context path.
- End-to-end bootstrap test proving the execed binary starts from the host context rather than a normal
  runtime read of `hostbootstrap.dhall`.

#### Remaining Work

None. The Python bootstrapper now writes `./.build/project-binary-context-config.dhall` idempotently
after the host-native binary build. Validation: `poetry run python -m hostbootstrap.test_all -q` passes
(140 tests), and `cabal test all` passes (145 tests).

### Sprint 15.3: Nested context creation surfaces [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `demo/docker/Dockerfile`, `core/hostbootstrap-core/test/ContextSpec.hs`
**Docs to update**: `documents/engineering/derived_dockerfile.md`, `documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

Expose project-binary entrypoints for creating contexts at each nested boundary without weakening normal
command gating.

#### Deliverables

- A context creation command surface, including the Dockerfile-oriented
  `--create-container-config /usr/local/bin/project-binary-context-config.dhall`.
- VM-context creation before invoking the binary inside an incus VM.
- Container-context creation after the binary is installed and before `check-code`.
- Kubernetes service-context generation/mounting guidance for StatefulSets and other controllers.

#### Validation

- Unit tests for host -> VM and host/VM -> container context derivation.
- Dockerfile fixture or integration test proving `check-code` runs only after the container context
  exists.
- Rendering or manifest tests for StatefulSet context placement when a project defines a cluster service.

#### Remaining Work

None. `HostBootstrap.Context` provides host/VM/container/service context constructors and a standalone
container bootstrap context. The core CLI exposes `context create vm|container|service OUTPUT` and the
top-level Dockerfile shortcut `--create-container-config OUTPUT`; the demo Dockerfile runs the shortcut
before `check-code`. Validation: `cabal test all` passes (151 tests), and a direct
`cabal run hostbootstrap -- --create-container-config <tmp>/project-binary-context-config.dhall` smoke
test writes a non-empty file.

### Sprint 15.4: Remove normal runtime static-base reads [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/architecture/dhall_generation.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

#### Objective

Complete the migration so `hostbootstrap.dhall` is not a normal binary runtime input.

#### Deliverables

- Replace command handlers that accept `hostbootstrap.dhall` paths with context-backed execution or an
  explicit inspection-only path.
- Keep static-base schema validation for Python/bootstrap support and `config show`-style inspection, but
  remove it from normal lifecycle command preconditions.
- Update the demo so host, VM, container, and cluster-service copies of the binary each use their own
  context and reject non-commensurate commands.

#### Validation

- Tests proving lifecycle, test, daemon/service, and host-orchestrator commands are accepted only in
  contexts that authorize them.
- Demo dry-run output and unit tests proving the lifted sequence still has one representation while each
  nested process receives the expected context.
- `cabal test` and the Python `test_all` runner pass after the migration.

#### Remaining Work

None. Normal core commands (`ensure`, `config schema/render`, `cluster`, `test`, and `check-code`) now
load and validate the sibling context before dispatch; `config show FILE`, context creation, and the
Dockerfile shortcut remain the explicit inspection/bootstrap exceptions. `cluster up/down/delete/status`
no longer accepts a `hostbootstrap.dhall` path and instead derives project, source root, and resources
from the active context. The demo project verbs declare their command classes through the same gate.

Validation: `cabal test all` passes (152 tests), `poetry run python -m hostbootstrap.test_all -q` passes
(140 tests), `poetry run python -m hostbootstrap.check_code` passes, `git diff --check` passes, the
Dockerfile `--create-container-config` smoke writes a non-empty context file, and a normal `check-code`
CLI smoke exits 1 when the sibling context is absent.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` - canonical context contract and command-gating rules.
- `documents/architecture/python_haskell_boundary.md` - Python creates only the host-level context.
- `documents/architecture/build_and_run_model.md` - host-native build followed by host-context creation.
- `documents/architecture/composition_methodology.md` - self-reference lift plus explicit local context.

**Engineering docs to create/update:**
- `documents/engineering/dhall_topology.md` - static bootstrap, runtime context, and generated Dhall roles.
- `documents/engineering/schema.md` - static-base file is Python/bootstrap-only.
- `documents/engineering/resource_budgeting.md` - budget flows through context envelopes.
- `documents/engineering/derived_dockerfile.md` - `--create-container-config` before normal commands.
- `documents/engineering/derived_project_standards.md` - derived projects materialize runtime contexts.
- `documents/operations/demo_runbook.md` - host, VM, VM-container, and cluster-service contexts.

**Cross-references to add:**
- `README.md`, `documents/README.md`, `DEVELOPMENT_PLAN/README.md`, `00-overview.md`,
  `system-components.md`, and `development_plan_standards.md` name Phase 15 and link to the context
  contract.
