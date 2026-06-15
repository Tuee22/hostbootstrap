# Phase 4: Project-Local Dhall and Command Tree

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md)

> **Purpose**: Own the project-binary Dhall schema and the composable optparse command tree project
> binaries extend through `runHostBootstrapCLI`.

## Phase Status

**Status**: Done

`HostBootstrap.Config.Schema` provides the in-process Haskell decoder/encoder for the project-local
`<project>.dhall` shape: project settings, Dockerfile/build inputs, resource budget, deploy knobs, and the
runtime context. `HostBootstrap.Command` composes the core command tree, and `runHostBootstrapCLI`
extends that tree with project commands (demonstrated by the worked `demo/` consumer). The
binary-generated-schema surfaces live in [Phase 8](phase-8-dhall-generation-and-extension.md); the
command gate that reads sibling `<project>.dhall` before normal dispatch lives in
[Phase 15](phase-15-binary-context-config.md).

## Remaining Work

None.

## Phase Objective

Land the project-local `<project>.dhall` schema and the composable optparse command tree projects extend
(see [development_plan_standards.md § P, Q](development_plan_standards.md)). The schema is owned by the
project binary, not Python. Normal commands read the sibling config through the command gate; bootstrap
and inspection commands (`help`, `version`, `config init`, `config schema`, `config show`, `config path`,
static `config render`) remain available without an existing local config.

## Sprints

### Sprint 4.1: Project config schema + in-process decoder [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/Type.dhall`, `core/hostbootstrap-core/dhall/example.dhall`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`

#### Objective

Define the project-local `<project>.dhall` schema fixture and the in-process Haskell decoder/encoder used
by config inspection, default generation, and command gating.

#### Deliverables

- The project-local schema fixture in `core/hostbootstrap-core/dhall/Type.dhall`.
- The canonical decode fixture in `core/hostbootstrap-core/dhall/example.dhall`.
- `HostBootstrap.Config.Schema` decoding, rendering, writing, and summarizing `ProjectConfig`.
- Resource, deploy, and runtime-context fields available to the project binary.

#### Validation

- `SchemaSpec` decode round-trips the canonical `example.dhall` fixture and rendered defaults.
- Malformed config and wrong-typed fields fail with typed Dhall errors.
- `hostbootstrap config show <file>` prints the decoded fields.

#### Remaining Work

None.

### Sprint 4.2: Composable command tree [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/app/Main.hs` (the bare `hostbootstrap` binary; the worked extension is now
`demo/app/Main.hs` + `demo/src/HostBootstrapDemo/Commands.hs`)
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Command` — the core optparse command tree composing `ensure <tool>` and the
project-local `config` verbs — and confirm `runHostBootstrapCLI progName projectCommands testSuite`
extends it with project-specific subcommands and the inherited test hook.

#### Command Surface

- `hostbootstrap ensure <tool>` — the Phase 3 reconcilers.
- `hostbootstrap config show` — decode/inspect a project-local config file.
- A project binary calls `runHostBootstrapCLI "<project>" projectCommands` to add its own verbs;
  the bare `hostbootstrap` binary (`hostbootstrap-core`'s own executable) passes no project
  commands.

#### Deliverables

- `HostBootstrap.Command` exposing the composable command value.
- A test project binary demonstrating tree extension without re-implementing core verbs.

#### Validation

- `hostbootstrap --help` shows the composed core tree (`ensure`, `config`); the worked
  `hostbootstrap-demo` binary (`demo/`) shows the core verbs plus its own appended demo verbs
  (`incus`/`vm`/`harbor`/`web`).

#### Remaining Work

None.

### Sprint 4.3: Schema fixture and drift checks [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/Type.dhall`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`

#### Objective

Keep the committed schema fixture aligned with the Haskell `ProjectConfig` decoder and the generated
schema emitted by the binary.

#### Deliverables

- `Type.dhall` describes the project-local record shape consumed by `ProjectConfig`.
- `SchemaSpec` round-trips rendered defaults and the canonical fixture through the Haskell decoder.
- Generated schema output includes the reflected `ProjectConfig` surface.

#### Validation

- `cabal build all` and `cabal test` pass.
- Schema tests reject malformed and wrong-typed values and validate the Cabal-derived project identity.

#### Remaining Work

None.

### Sprint 4.4: Project-local config schema [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`, `legacy-tracking-for-deletion.md`

#### Objective

Define the sibling `<project>.dhall` schema owned by the built project binary.

#### Deliverables

- A project-local config type covering project settings, Dockerfile/build inputs, resources, runtime
  context, allowed command classes, role name, and child-config projection defaults.
- Cabal-derived project identity: the config validates against the project name derived from the Cabal
  file and does not require a user-authored `project` field to bootstrap Python.
- Tests proving the new schema decodes, rejects malformed values, and supports the explicit `config show`
  inspection path.

#### Validation

- `cabal test` covers valid/invalid `<project>.dhall` fixtures and command-gate decode failures.
- The committed fixtures are project-local `<project>.dhall` fixtures.

#### Remaining Work

None. Validation: `cabal test all` passes from `core/` with `SchemaSpec` covering project-local decode,
render/decode round-trip, malformed and wrong-typed configs, the canonical `example.dhall` fixture, and
validation against the Cabal-derived project name.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - the command-tree extension contract.

**Engineering docs to create/update:**
- `documents/engineering/schema.md` - the project-local `<project>.dhall` schema.
- `documents/engineering/dhall_topology.md` - the local runtime config, generated child configs, and
  binary-generated project/test schemas.

**Cross-references to add:**
- `system-components.md` updates the project-local-config and command-tree rows.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces.
