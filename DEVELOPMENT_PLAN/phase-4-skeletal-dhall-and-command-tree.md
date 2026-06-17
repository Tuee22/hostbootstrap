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
shape and stay `Done`; the command-tree sprint (4.2) is reopened.

## Remaining Work

Collapse the flat verbs into the `project` lifecycle command plus the `[Step]` chain. The target shape
being built — **not yet implemented** (the code still carries the old flat `config`/`ensure` topology and
the demo's noun verbs) — is:

- `config init` -> `project init` (the host-orchestrator root-config surface, idempotently triggered by
  Python after the host-native build, § M).
- `cluster` -> chain steps interpreted by `project up` (owned with [Phase 5](phase-5-cluster-lifecycle-and-resource-cordoning.md)
  and Phase 16, project lifecycle command and step-chain interpreter).
- `context create` -> the internal `context-init` step inside `project up`; `context` becomes a read-only
  introspection command absorbing `config schema` / `config show` / static `config render`.
- A project contributes a **lift chain** value, `chain :: RootConfig -> [Step]`, as the primary member of
  its `ProjectSpec` (§ T, § Y) rather than noun verbs; host and project step kinds interleave in one
  `[Step]`.

The `project` lifecycle command, the recursive chain interpreter, and the `[Step]` algebra are **not**
implemented here. The new work is owned by Phase 16 (project lifecycle command and step-chain interpreter)
and, for the test/context surface, by Phase 17 (chain-driven test surface and context introspection). This
phase tracks the command-tree contract delta; the removals are recorded `Pending` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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

### Sprint 4.2: Composable command tree [Active]

**Status**: Active
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

Migrate the surfaced command tree from the flat `config`/`ensure` topology to the `project` lifecycle
contract — **not yet implemented** (the code still surfaces the flat verbs and the demo's noun verbs):

- Replace the flat `config init|show|schema|render|path` surface: `config init` -> `project init`;
  `config schema` / `config show FILE` / static `config render` / `config path` fold into the read-only
  `context` introspection command (§ X).
- Surface `project init|up|down|destroy`, `context`, `test init|run`, and `check-code` as the core verbs;
  add the recursive `project up` chain interpreter and the `[Step]` algebra (deploy-VM, `ensure-*`,
  copy-source, build-pb, build-image, `context-init`, deploy-kind, deploy-chart, expose-port). This
  interpreter and step algebra are owned by Phase 16 (project lifecycle command and step-chain
  interpreter).
- Make a project's primary `ProjectSpec` contribution its `chain :: RootConfig -> [Step]` value; keep the
  `ensure <tool>` subcommand only as a hidden debug surface and demote it from the help surface.
- Record the dissolved flat verbs in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending`.

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
