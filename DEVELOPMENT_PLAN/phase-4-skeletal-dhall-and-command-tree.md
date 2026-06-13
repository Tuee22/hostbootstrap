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
runtime context. `HostBootstrap.Command` composes the `ensure` and `config` verbs, and
`runHostBootstrapCLI` extends the tree with project commands (demonstrated by the worked `demo/`
consumer). The binary-generated-schema items are delivered (see
[development_plan_standards.md § P, Q](development_plan_standards.md)): `config schema` / `config render`
over `HostBootstrap.Dhall.Gen` + the `ConfigArtifact` registry and the reusable `Core.dhall` vocabulary
(`Budget/fitsWithin`, `Budget/split`) landed in
[phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md); the four-stream
contract and the three-level hierarchy are documented (Phase 7 / Phase 8; the harness-`Seams` stream is
Phase 10); and Sprint 4.4 replaced the old static-base contract with the project-local schema.

The `skeletal` → `static-base` rename landed historically (the phase-4 file path retains the historical
token by the § E canonical layout). The old `Type.dhall` ↔ Python `package.dhall` anti-drift check was
then retired when Sprint 4.4 replaced the fixture with the project-local schema and Phase 6 removed the
Python Dhall package.

## Remaining Work

None. The legacy `StaticBase` Haskell compatibility API was removed in Phase 15 and is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Phase Objective

Land the project-local `<project>.dhall` schema and the composable optparse command tree projects extend
(see [development_plan_standards.md § P, Q](development_plan_standards.md)). The schema is owned by the
project binary, not Python. Normal commands read the sibling config through the command gate; bootstrap
and inspection commands (`help`, `version`, `config init`, `config schema`, `config show`, `config path`,
static `config render`) remain available without an existing local config.

## Sprints

### Sprint 4.1: Static-base schema + in-process decoder [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/Type.dhall`, `core/hostbootstrap-core/dhall/example.dhall`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`

#### Objective

Land the historical static-base `hostbootstrap.dhall` schema and `HostBootstrap.Config.Schema`, the
in-process decoder that backed early `config show` inspection. Sprint 4.4 supersedes this as the supported
schema.

#### Deliverables

- The static-base schema: `{ project : Text, dockerfile : Text, resources : { cpu : Natural, memory :
  Text, storage : Text } }`, identical in shape across projects.
- `HostBootstrap.Config.Schema` decoding the static-base config via the Haskell `dhall` library.
- The resource budget exposed as the single static field in the old static-base compatibility shape.

#### Validation

- `SchemaSpec` decode round-trips a valid `hostbootstrap.dhall` (text and the `example.dhall`
  fixture); a malformed config and a wrong-typed field each fail with a typed Dhall error.
- `cabal build all` succeeds; `hostbootstrap config show <file>` prints the decoded fields.

#### Remaining Work

The old static-base decoder is complete. The project-local `<project>.dhall` decoder/generator is Sprint
4.4.

### Sprint 4.2: Composable command tree [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/app/Main.hs` (the bare `hostbootstrap` binary; the worked extension is now
`demo/app/Main.hs` + `demo/src/HostBootstrapDemo/Commands.hs`)
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Command` — the core optparse command tree composing `ensure <tool>` and the
static-base `config` verbs — and confirm `runHostBootstrapCLI progName projectCommands testSuite`
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
  `hostbootstrap-demo` binary (`demo/`, superseding the retired `hostbootstrap-example`) shows the core
  verbs plus its own appended demo verbs (`incus`/`vm`/`harbor`/`web`).

#### Remaining Work

None.

### Sprint 4.3: Static-base rename and anti-drift check [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/Type.dhall`, `hostbootstrap/spec.py`,
`hostbootstrap/dhall/package.dhall`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`

#### Objective

Make the static-base terminology consistent and mechanically prevent the two static-base schema
files (the Haskell `Type.dhall` and the Python `package.dhall`) from drifting apart.

This sprint is historical: Sprint 4.4 replaced `Type.dhall` with the project-local schema, Phase 6
Sprint 6.4 removed the Python Dhall package and reader, and Phase 15 removed the Haskell `StaticBase`
compatibility API.

#### Deliverables

- The `Skeleton`/`Skeletal` token is renamed to `StaticBase`/`static-base` across the Haskell decoder
  (`StaticBase`, `decodeStaticBaseText`/`File`, `renderStaticBase`), the Python reader
  (`StaticBaseSpec`), the Dhall comments, and the governed-docs prose. The bare `hostbootstrap`
  executable (formerly "skeletal executable") is renamed to "bare". The phase-4 file path keeps the
  historical token per the § E canonical layout.
- `SchemaSpec` adds an anti-drift test: `Type.dhall` and `(package.dhall).Config` are imported,
  type-checked, and normalised by the `dhall` library and compared judgmentally (field-order
  insensitive), so a change to one without the other fails `cabal test`.

#### Validation

- `cabal build all` and `cabal test` pass (the anti-drift test confirms `Type.dhall` ≡
  `package.dhall.Config`); the Python suite passes at 100% coverage (`check_code` clean) on the
  renamed identifiers.

#### Remaining Work

None.

### Sprint 4.4: Project-local config schema [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`, `legacy-tracking-for-deletion.md`

#### Objective

Replace the static-base schema as the supported project contract with a sibling `<project>.dhall` schema
owned by the built project binary.

#### Deliverables

- A project-local config type covering project settings, Dockerfile/build inputs, resources, runtime
  context, allowed command classes, role name, and child-config projection defaults.
- Cabal-derived project identity: the config validates against the project name derived from the Cabal
  file and does not require a user-authored `project` field to bootstrap Python.
- Tests proving the new schema decodes, rejects malformed values, and supports the explicit `config show`
  inspection path.

#### Validation

- `cabal test` covers valid/invalid `<project>.dhall` fixtures and command-gate decode failures.
- Legacy static-base fixtures are either removed or retained only under the deletion ledger with tests
  that explain the compatibility window.

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
- `legacy-tracking-for-deletion.md` tracks the remaining static-base compatibility API and records the
  removed Python Dhall reader.
