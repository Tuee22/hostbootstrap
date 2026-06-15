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
as their runtime authority.

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

Define the runtime context fields inside `<project>.dhall` and the Haskell substrate that loads the
sibling config before normal optparse dispatch.

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

### Sprint 15.2: Python stays outside Dhall ownership [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`, `documents/architecture/build_and_run_model.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Keep the Python bootstrapper outside Dhall ownership while still ensuring a default local config exists
after the host-native binary build.

#### Deliverables

- Python derives the project name from the Cabal file and writes no Dhall.
- After building `./.build/<project>` host-native, Python triggers
  `<project> config init --if-missing`; the binary creates the default sibling `<project>.dhall`.
- The project binary owns decoding, rendering, validation, and command gating for the local config.

#### Validation

- Python tests prove Cabal-file project discovery, zero/multiple-Cabal diagnostics, host-native
  build/exec argv, and the absence of Python-written Dhall artifacts.

#### Remaining Work

None. Validation:
`poetry run python -m hostbootstrap.test_all -q` passes (113 tests), `poetry run python -m
hostbootstrap.check_code` passes, and `cabal test all` passes.

### Sprint 15.3: Nested context creation surfaces [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `demo/docker/Dockerfile`, `core/hostbootstrap-core/test/ContextSpec.hs`
**Docs to update**: `documents/engineering/derived_dockerfile.md`, `documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

Expose project-binary entrypoints for creating role-specific project-local configs at each nested
boundary without weakening normal command gating.

#### Deliverables

- `context create vm|container|service OUTPUT` derives child `<project>.dhall` files from the active
  parent config.
- Dockerfiles call `config init --role vm-project-container --output /usr/local/bin/<project>.dhall`
  after installing the binary and before `check-code`.
- VM-context creation happens before invoking the binary inside an incus VM.
- Kubernetes service-context generation/mounting guidance covers StatefulSets and other controllers.

#### Validation

- Unit tests for host -> VM and host/VM -> container context derivation.
- Dockerfile fixture or integration test proving `check-code` runs only after the container context
  exists.
- Rendering or manifest tests for StatefulSet context placement when a project defines a cluster service.

#### Remaining Work

None. `HostBootstrap.Context` provides host/VM/container/service context constructors and a standalone
container bootstrap context. Dockerfiles use
`config init --role vm-project-container --output /usr/local/bin/<project>.dhall`.

### Sprint 15.4: Normal runtime config reads [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/architecture/dhall_generation.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

#### Objective

Ensure normal runtime dispatch uses the sibling project-local config.

#### Deliverables

- Normal command handlers execute through context-backed dispatch or an explicit inspection-only path.
- `config show FILE` remains an explicit inspection surface.
- Update the demo so host, VM, container, and cluster-service copies of the binary each use their own
  context and reject non-commensurate commands.

#### Validation

- Tests proving lifecycle, test, daemon/service, and host-orchestrator commands are accepted only in
  contexts that authorize them.
- Demo dry-run output and unit tests proving the lifted sequence still has one representation while each
  nested process receives the expected context.
- `cabal test` and the Python `test_all` runner pass.

#### Remaining Work

None. Normal core commands (`ensure`, `cluster`, `test`, and `check-code`) load and validate the
sibling context before dispatch; `config init`, `config schema`, `config show FILE`, `config path`, and
static `config render` remain the explicit inspection/bootstrap exceptions. `cluster up/down/delete/status`
derives project, source root, and resources from the active context. The demo project verbs declare their
command classes through the same gate.

Validation: `cabal test all` passes (152 tests), `poetry run python -m hostbootstrap.test_all -q` passes
(140 tests), `poetry run python -m hostbootstrap.check_code` passes, `git diff --check` passes, the
normal `check-code` CLI smoke exits 1 when the sibling context is absent.

### Sprint 15.5: Context lives in `<project>.dhall` [Done]

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

Use the project-local `<project>.dhall` file as the single runtime config authority for each binary copy.

#### Deliverables

- Sibling-file discovery looks for `<project>.dhall`, where `<project>` is derived from the running
  binary/Cabal identity.
- The context loader reads the runtime-context section inside that config and enforces the
  command/capability gate.
- Dockerfiles use `config init --role vm-project-container --output /usr/local/bin/<project>.dhall`.
- Daemon/service startup logs include project, binary, context kind, role name, config path, config hash,
  source root, and resource envelope, with secrets excluded.
- Config changes during a process lifetime do not mutate the active process; normal commands read once,
  and daemons read once and require restart to observe changes.

#### Validation

- Unit tests cover sibling `<project>.dhall` discovery, missing/malformed file failures, wrong-project
  failures, role/capability mismatches, and no-side-effect command gating.
- Dockerfile ordering installs the baked `/usr/local/bin/<project>.dhall` default before `check-code`;
  record a Docker build smoke here when that image build is run.
- Daemon logging tests verify startup metadata includes the config hash and excludes secret values.
- Python tests prove no host context file is written by the bootstrapper.
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
