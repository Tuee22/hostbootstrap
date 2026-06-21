# Phase 4: Project-Local Dhall and Command Tree

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md)

> **Purpose**: Own the project-binary Dhall schema and the composable optparse command tree project
> binaries extend through `runHostBootstrapCLI`.

## Phase Status

**Status**: Active

`HostBootstrap.Config.Schema` provides the in-process Haskell decoder/encoder for the project-local
`<project>.dhall` shape: project settings, Dockerfile/build inputs, resource budget, deploy knobs, and the
runtime context. That decoder/encoder is built and still valid. `HostBootstrap.Command` composes the core
command tree, and `runHostBootstrapCLI` extends that tree with project commands (demonstrated by the worked
`demo/` consumer). The binary-generated-schema surfaces live in
[Phase 8](phase-8-dhall-generation-and-extension.md); the command gate that reads sibling `<project>.dhall`
before normal dispatch lives in [Phase 15](phase-15-binary-context-config.md).

The phase is reopened because the command tree's contract changed under the "the chain is the project"
model (see [development_plan_standards.md § Y, § Z](development_plan_standards.md)). The surfaced core tree
is no longer the flat `config` verbs plus `ensure`; it is the recursive lifecycle command
`project init|up|down|destroy`, the read-only `context` introspection command, `test init|run`, and
`check-code`. The schema/decoder sprints (4.1, 4.3, 4.4) built a still-valid project-local `<project>.dhall`
shape and stay `Done`; the command-tree sprint (4.2) is now complete — the flat `config init` / `cluster` /
`context create` verbs are removed, the read-only `config` inspection folded into `context`, and the
surfaced tree is `project init|up|down|destroy` / read-only `context` / `test init|run` / `check-code`
(plus hidden-debug `ensure`), validated by `cabal test` (core green) and the migrated Python trigger.

## Remaining Work

**Reopened by [phase 19](phase-19-generic-project-model.md)** (the generic-project-model correction,
development_plan_standards § BB): `ProjectConfig`'s core-owned defaults
(`defaultResources`/`defaultDeployConfig`/`defaultProjectConfig`) and its status as a fixed universal type
are superseded — defaults move to a project-owned `psInit :: InitArgs -> cfg`, and the config type becomes
project-defined under the generic `ProjectSpec cfg tcfg`.
This is documentation-only target work; the superseded surfaces are listed in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner.

None. The command tree is migrated to the new surface (Sprint 4.2): `config init` -> `project init` (with
the Python trigger migrated), `cluster` -> `project up|down|destroy`, `context create` -> the `context-init`
chain step, and `config show|schema|render|path` folded into the read-only `context` command. A project's
primary `ProjectSpec` contribution is its `chain :: RootConfig -> [Step]` value (threaded via `withChain`).
The recursive interpreter and `[Step]` algebra that this tree surfaces are owned by
[Phase 16](phase-16-project-lifecycle-command.md); the removed flat verbs are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Removed Surfaces`.

## Phase Objective

Land the project-local `<project>.dhall` schema and the composable optparse command tree projects extend
(see [development_plan_standards.md § P, Q, Y](development_plan_standards.md)). The schema is owned by the
project binary, not Python. Normal commands read the sibling config through the command gate. Under the
"the chain is the project" model the bootstrap and inspection entrypoints that run without an existing
local config become `help`, `version`, `project init`, and the read-only `context` introspection command
(which absorbs the former `config schema` / `config show FILE` / `config path` / static `config render`
surfaces, § X). The composable tree projects extend surfaces the `project init|up|down|destroy`,
`context`, `test init|run`, and `check-code` core verbs, and a project's primary contribution is its
**lift chain** value (`chain :: RootConfig -> [Step]`), not noun verbs.

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

Land `HostBootstrap.Command` — the core optparse command tree — and confirm `runHostBootstrapCLI progName
projectSpec` extends it with validated project extension points (the project's lift chain, the inherited
test hook, the inherited `check-code` hook, and project config artifacts). The current implementation
composes `ensure <tool>` and the flat project-local `config` verbs and validates named `ProjectCommand`
deltas; the **target** tree surfaces the `project init|up|down|destroy`, read-only `context`,
`test init|run`, and `check-code` verbs, and a project's primary contribution becomes its
`chain :: RootConfig -> [Step]` value rather than noun verbs (§ P, § Y).

#### Command Surface

- `hostbootstrap ensure <tool>` — the Phase 3 reconcilers, retained only as a hidden debug surface;
  reconcilers are normally invoked as chain steps within `project up` (§ L, § Y).
- Target surfaced core tree: `project init|up|down|destroy`, read-only `context`, `test init|run`,
  `check-code` (§ Y, § Z). The flat `config show|schema|render|path` verbs fold into `project init` /
  `context`.
- A project binary calls `runHostBootstrapCLI "<project>" projectSpec` to contribute its lift chain (plus
  any residual project verbs that may never shadow a core verb); the bare `hostbootstrap` binary
  (`hostbootstrap-core`'s own executable) uses `runBareHostBootstrapCLI`.

#### Deliverables

- `HostBootstrap.Command` exposing the composable command value (built; reopened for the verb-surface
  migration).
- A worked project binary demonstrating tree extension without re-implementing core verbs (built; the demo
  must migrate from its noun verbs to a contributed chain value, owned by
  [Phase 13](phase-13-hostbootstrap-demo.md) / Phase 16).

#### Validation

- (Current) `hostbootstrap --help` shows the composed flat core tree (`ensure`, `config`); the worked
  `hostbootstrap-demo` binary (`demo/`) shows the core verbs plus its own appended demo verbs
  (`incus`/`vm`/`harbor`/`web`).
- (Target) `--help` shows `project`, `context`, `test`, `check-code`; the demo contributes a chain value
  rather than noun verbs.

#### Remaining Work

None. The surfaced core tree is `project init|up|down|destroy`, the read-only `context` command (absorbing
`show` / `schema` / `render` / `path`), `test init|run`, and `check-code`, with `ensure <tool>` retained as
a hidden debug surface. `config init` is migrated to `project init` (the Python trigger updated), and a
project's primary `ProjectSpec` contribution is its `chain :: RootConfig -> [Step]` value (threaded via
`withChain` / `withFrameContext`). The recursive `project up` interpreter and the `[Step]` algebra this tree
surfaces are owned by [Phase 16](phase-16-project-lifecycle-command.md); the removed flat verbs are recorded
in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Removed Surfaces`.

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
