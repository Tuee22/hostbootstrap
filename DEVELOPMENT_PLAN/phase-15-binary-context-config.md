# Phase 15: Binary Context Config and Command Gating

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [binary_context_config](../documents/architecture/binary_context_config.md)

> **Purpose**: Make every project binary explicitly know where it is in the composed
> host/VM/container/cluster chain by reading a sibling `<project>.dhall`, and make normal commands fail
> fast when the local config is missing or does not authorize the command.

## Phase Status

**Status**: Done

Phases 6, 8, 11, 13, and 14 provide the needed substrate: the thin Python bootstrapper, typed Dhall
generation, the self-reference lift, the worked demo chain, and the composition methodology. This phase
turns the implicit context carried by lift composition into an explicit runtime precondition for every
binary process.

The runtime context is folded into the project-local `<project>.dhall` file. The core normal command tree
and demo project verbs gate through the sibling project config, context creation surfaces materialize
host/VM/container/service placement configs, and normal cluster lifecycle commands use the active context
instead of any static-base path. The old standalone context filename, Dockerfile shortcut, and Haskell
static-base compatibility API are removed.

## Remaining Work

None.

## Phase Objective

Introduce the runtime binary-context contract:

- Every normal binary command reads `<project>.dhall` from next to the executable before dispatch.
- The project name in the filename is derived from the Cabal file/binary identity; the role is inside the
  file content.
- The built project binary creates defaults through `config init` and emits schema/help for editing.
- Each nested boundary receives or creates its own role-specific local config before the nested binary
  runs.
- Dockerfiles use `<project> config init --role vm-project-container --output /usr/local/bin/<project>.dhall`
  after installing the binary and before `check-code`.
- Kubernetes service pods receive a service/daemon local config from their owning controller; durable
  services use a `StatefulSet`.
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

Record the old temporary Python host-context handoff for the separate-context artifact. This sprint is
superseded by Phase 6 Sprint 6.4, which removed Python's Dhall reader and host-context writer.

#### Deliverables

- The old Python bootstrapper read `hostbootstrap.dhall`, built `./.build/<project>`, and idempotently
  wrote `./.build/project-binary-context-config.dhall` before exec.
- The old host context carried project/binary identity, host-orchestrator context kind, initial resource
  envelope, and the child-context rules needed by the project binary.
- That handoff is no longer supported; Python now derives the project name from the Cabal file and writes
  no Dhall.

#### Validation

- Historical Python tests covered idempotent creation, unchanged reruns, malformed static bootstrap input,
  and correct host-context path.
- Current Python tests prove the bootstrapper writes no `.dhall` artifact under `./.build`.

#### Remaining Work

None for the old separate-context handoff. Phase 6 Sprint 6.4 removed the Python writer; Sprint 15.5
completed the Haskell runtime filename migration to project-local `<project>.dhall`. Validation:
`poetry run python -m hostbootstrap.test_all -q` passes (113 tests), `poetry run python -m
hostbootstrap.check_code` passes, and `cabal test all` passes.

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

None for the old separate-context command surface. `HostBootstrap.Context` provides
host/VM/container/service context constructors and a standalone container bootstrap context. Sprint 15.5
removed the temporary Dockerfile shortcut and replaced it with
`config init --role vm-project-container --output /usr/local/bin/<project>.dhall`. Validation:
`cabal test all` passed for the original command surface, and Sprint 15.5's validation covers the current
project-local replacement.

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

None. Normal core commands (`ensure`, `cluster`, `test`, and `check-code`) now load and validate the
sibling context before dispatch; `config init`, `config schema`, `config show FILE`, `config path`, and
static `config render` remain the explicit inspection/bootstrap exceptions. `cluster up/down/delete/status`
derives project, source root, and resources from the active context. The demo project verbs declare their
command classes through the same gate.

Validation: `cabal test all` passes (152 tests), `poetry run python -m hostbootstrap.test_all -q` passes
(140 tests), `poetry run python -m hostbootstrap.check_code` passes, `git diff --check` passes, the
normal `check-code` CLI smoke exits 1 when the sibling context is absent.

### Sprint 15.5: Fold context into `<project>.dhall` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Container.hs`, `demo/docker/Dockerfile`,
`demo/chart/templates/configmap.yaml`, `demo/chart/templates/deployment.yaml`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/ContainerSpec.hs`
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`documents/engineering/derived_dockerfile.md`, `documents/operations/demo_runbook.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Replace `project-binary-context-config.dhall` with the project-local `<project>.dhall` file as the single
runtime config authority for each binary copy.

#### Deliverables

- Sibling-file discovery looks for `<project>.dhall`, where `<project>` is derived from the running
  binary/Cabal identity.
- The context loader reads the runtime-context section inside that config and enforces the same
  command/capability gate as before.
- `--create-container-config` is removed; Dockerfiles use
  `config init --role vm-project-container --output /usr/local/bin/<project>.dhall`.
- Daemon/service startup logs include project, binary, context kind, role name, config path, config hash,
  source root, and resource envelope, with secrets excluded.
- Config changes during a process lifetime do not mutate the active process; normal commands read once,
  daemons read once and require restart unless a future explicit reload command is added.

#### Validation

- Unit tests cover sibling `<project>.dhall` discovery, missing/malformed file failures, wrong-project
  failures, role/capability mismatches, and no-side-effect command gating.
- Dockerfile ordering installs the baked `/usr/local/bin/<project>.dhall` default before `check-code`;
  record a Docker build smoke here when that image build is run.
- Daemon logging tests verify startup metadata includes the config hash and excludes secret values.
- Python tests already prove no host context file is written by the bootstrapper; Sprint 15.5 keeps that
  invariant while changing the Haskell runtime filename.
- Current validation: `cabal test all` from `core/` passes (159 tests); `cabal build all` from `demo/`
  passes; `helm template hostbootstrap-demo demo/chart` renders only the service-role
  `hostbootstrap-demo.dhall` mount; `cabal run hostbootstrap-demo -- config init --role host-orchestrator
  --source-root /home/matt/hostbootstrap/demo --dockerfile docker/Dockerfile --cpu 6 --memory 10GiB
  --storage 80GiB --ha-replicas 1 --force` creates the host config;
  `cabal run hostbootstrap-demo -- config init --role vm-project-container --output
  <tmp>/hostbootstrap-demo.dhall --source-root /workspace/demo --dockerfile docker/Dockerfile --cpu 6
  --memory 10GiB --storage 80GiB --ha-replicas 1 --force` writes a non-empty
  container-role config with `VMProjectContainer` and `roleName = "vm-project-container"`; and
  `cabal run hostbootstrap-demo -- deploy --dry-run` renders the five-step single lift sequence through
  the new gate.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` - canonical local-config context contract and
  command-gating rules.
- `documents/architecture/python_haskell_boundary.md` - Python does not read or write Dhall.
- `documents/architecture/build_and_run_model.md` - host-native build followed by project-binary config
  initialization when needed.
- `documents/architecture/composition_methodology.md` - self-reference lift plus explicit local context.

**Engineering docs to create/update:**
- `documents/engineering/dhall_topology.md` - local runtime config, generated child configs, and generated
  Dhall roles.
- `documents/engineering/schema.md` - project-local `<project>.dhall` shape.
- `documents/engineering/resource_budgeting.md` - budget flows through local config envelopes and child
  projections.
- `documents/engineering/derived_dockerfile.md` - `config init --role ... --output /usr/local/bin/<project>.dhall`
  before normal commands.
- `documents/engineering/derived_project_standards.md` - derived projects materialize runtime contexts.
- `documents/operations/demo_runbook.md` - host, VM, VM-container, and cluster-service
  `hostbootstrap-demo.dhall` configs.

**Cross-references to add:**
- `README.md`, `documents/README.md`, `DEVELOPMENT_PLAN/README.md`, `00-overview.md`,
  `system-components.md`, and `development_plan_standards.md` name Phase 15 and link to the context
  contract.
