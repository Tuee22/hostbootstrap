# Phase 4: Project-local Dhall and command tree

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md)

> **Purpose**: Own the project-binary Dhall schema and the fixed optparse command tree project binaries
> enter through `runHostBootstrapCLI`.

## Phase Status

**Status**: Done

`HostBootstrap.Config.Schema` now provides generic sibling-config IO and validation over a project's
`ProjectCfg projectId cfg`; it does not own a concrete `ProjectConfig`. The former universal project/resource/deploy/
test records moved to `demo/src/HostBootstrapDemo/Config.hs` as that consumer's concrete `cfg`/`tcfg`.
`HostBootstrap.Command` composes the core command tree, and `runHostBootstrapCLI` attaches project behavior
through `ProjectSpec projectId cfg tcfg` without adding verbs (demonstrated by the worked `demo/`
consumer). The
binary-generated-schema surfaces live in [Phase 8](phase-8-dhall-generation-and-extension.md); the command
gate and its command-specific config inputs live in
[Phase 15](phase-15-binary-context-config.md).

The command tree's contract changed under the "the chain is the project"
model (see [development_plan_standards.md § Y, § Z](development_plan_standards.md)); that migration landed and is validated. The surfaced core tree
is no longer the flat `config` verbs plus an `ensure` command; it is the recursive lifecycle command
`project init|up|down|destroy`, `test init|run`, `service init|schema|run`, the read-only `context`
introspection command, and `check-code`. The schema/decoder sprints (4.1, 4.3, 4.4) built the still-valid
generic project-local config machinery and stay `Done`; their original core-owned concrete record was
subsequently removed by Phase 19. The command-tree sprint (4.2) is now complete — the flat `config init` /
`cluster` / `context create` verbs are removed, their writer/inspection responsibilities are distributed
across `project init`, `service schema`, and the read-only `context` routes, and the surfaced tree is
`project init|up|down|destroy` / `test init|run` / `service init|schema|run` / read-only `context` /
`check-code`, validated by `cabal test` (core green). The former Python post-build config-init trigger was
removed rather than migrated.

The implemented tree does **not** apply one sibling-config rule to every verb:

| Surface | Current config behavior |
|---|---|
| Help | Config-free |
| `project init`, `service init`, `test init` | Config-free writers |
| `service schema`, `context path`, `context schema`, `context render` | Static and config-free |
| `context inspect` | Reads the executable-sibling `<project>.dhall` without a command-authority gate |
| `context show [FILE]` | Reads the selected/default file without a command-authority gate |
| `test run <case-id>\|all` | Reads `<project>.test.dhall` and installs each run variant through the four § EE ownership clauses of `HostBootstrap.Harness.GeneratedConfig` — a found config is refused before any mutation, and cleanup unlinks only on an exact re-observed kernel identity and payload |
| `project up\|down\|destroy`, `service run`, `check-code` | Read and gate on the sibling `<project>.dhall` |

`project init` currently supports `--role`, repeatable `--also-role`, `--output`, `--force`, and
`--if-missing`; its default is a fresh sibling host-orchestrator root and an existing output is refused.
Phase 17 Sprint 17.4 owns opaque writer-specific init requests and the target overwrite policy. Phase 15
Sprint 15.9 owns opaque command authorities and compatible role/class construction. Those blocked
follow-ons do not reopen this phase's delivered fixed command tree.

## Remaining Work

[Phase 19](phase-19-generic-project-model.md) built **forward** on this surface (the generic project
model, § BB): it generalized the config type to a project-defined `cfg` under `ProjectSpec cfg tcfg` and
initially moved defaults to a project-owned `psInit`; Sprint 19.7 subsequently scope-indexed the
boundary as `ProjectSpec projectId cfg tcfg` and replaced that callback with `psAssemble`. The
superseded core-owned sub-surfaces
(`defaultResources`/`defaultDeployConfig`/`defaultProjectConfig` and the fixed universal type) are recorded
in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. **This phase
is not reopened.**

None. The command tree is migrated to the new surface (Sprint 4.2): `config init` -> `project init` (with
the Python post-build trigger removed), `cluster` -> `project up|down|destroy`, and `context create` ->
internal `project up` child-projection/delivery work. That work is currently separate from the announcing
`context-init` row; Sprint 16.6 owns their unification in one plan operation. The former
`config show|schema|render|path` routes are distributed across read-only `context` and static
`service schema` according to the matrix above. A project contributes additive steps through
`ProjectSpecBuilder`; finalization yields the opaque `StepPlan`.
The recursive interpreter and step algebra that this tree surfaces are owned by
[Phase 16](phase-16-project-lifecycle-command.md); the removed flat verbs are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Removed Surfaces`.
The command-input and authority refinements remain explicitly owned by blocked Sprints 17.4 and 15.9,
respectively; Phase 4 remains `Done`.

## Phase Objective

Land the generic project-local `<project>.dhall` machinery and the fixed optparse command tree projects enter through
(see [development_plan_standards.md § P, Q, Y](development_plan_standards.md)). The schema is owned by the
project's binary through its `cfg`/`tcfg` types, not by core or Python. Existing-frame commands read the
sibling config through the generic command gate; config-free writers, static schema/path/render output,
decode-only inspection, and harness-managed `test run` follow the explicit matrix above. Under the "the
chain is the project" model the removed `config` surfaces are distributed across `project init`,
`service schema`, and the read-only `context` subcommands rather than making the entire `context` group
config-free. The fixed tree surfaces the `project init|up|down|destroy`, `test init|run`,
`service init|schema|run`, `context`, and `check-code` core verbs, and a project's primary contribution is
its validated lift plan, not noun verbs.

## Sprints

### Sprint 4.1: Project config schema + in-process decoder [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/example.dhall`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`

#### Objective

**Historical Sprint 4.1 landing (superseded in concrete-type ownership by Phase 19):** define the original
project-local `<project>.dhall` fixture and in-process Haskell decoder/encoder used by config inspection,
default generation, and command gating. The retained core surface is now generic over `ProjectCfg cfg`;
the demo owns the concrete records.

#### Deliverables

- The project-local config schema declared by the project's `ToDhall cfg` encoder and printed by
  `service schema` is the emitted schema source; `context schema` prints the separate in-scope
  `ConfigArtifact` registry. The matching decoder expression remains independently supplied and is
  reopened in Sprint 8.7.
- The canonical decode fixture in `core/hostbootstrap-core/dhall/example.dhall`.
- The original `HostBootstrap.Config.Schema` decoding, rendering, writing, and summarizing the then-core
  `ProjectConfig`; Phase 19 replaced this with generic `ProjectCfg cfg` IO and moved the concrete demo
  records to `HostBootstrapDemo.Config`.
- Resource, deploy, and runtime-context fields available through the project-owned config type.

#### Validation

- `SchemaSpec` decode round-trips the canonical `example.dhall` fixture and rendered defaults.
- Malformed config and wrong-typed fields fail with typed Dhall errors.
- Historical validation used `hostbootstrap config show <file>`; that verb is removed. The current
  read-only equivalent is `<project> context show <file>`.

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
projectSpec` extends it with project extension points (the project's lift plan, inherited
test hook, service handlers, inherited `check-code` hook, and project config artifacts). The current tree
surfaces `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, read-only `context`,
and `check-code`; a project's primary contribution is its opaque validated `StepPlan` rather than noun
verbs (§ P, § Y). The `ensure` reconcilers are library primitives composed as `ensure-*` plan steps.
Sprint 19.8 subsequently added topology, non-empty, replacement-loss, and typed identity validation
without reopening this Done command-tree sprint.

#### Command Surface

- Surfaced core tree: `project init|up|down|destroy`, `test init|run`, `service init|schema|run`,
  read-only `context`, and `check-code` (§ Y, § Z, § AA). The flat `config show|schema|render|path` verbs
  are absorbed by `project init`, static `service schema`, and the input-specific `context` subcommands.
- A project binary calls `runHostBootstrapCLI "<project>" projectSpec` to contribute its lift chain (plus
  service/test/schema extension streams, never new verbs); the bare `hostbootstrap` binary
  (`hostbootstrap-core`'s own executable) uses `runBareHostBootstrapCLI`.

#### Deliverables

- `HostBootstrap.Command` exposing the composable command value; the verb-surface migration is landed.
- A worked project binary demonstrating tree extension without re-implementing core verbs; the demo's
  contributed chain migration landed through [Phase 13](phase-13-hostbootstrap-demo.md) / Phase 16.

#### Validation

- `--help` shows `project`, `test`, `service`, `context`, and `check-code`; the demo contributes a chain
  value rather than noun verbs.

#### Remaining Work

None. The surfaced core tree is `project init|up|down|destroy`, `test init|run`,
`service init|schema|run`, the read-only `context` command (absorbing `show` / `schema` / `render` /
`path` with the config inputs in the phase-level matrix), and `check-code`. `config init` is migrated to
the config-free `project init` writer (the Python post-build trigger was removed), and a
project's primary `ProjectSpec` contribution is its opaque validated `StepPlan`, assembled through
checked builder operations. The recursive `project up` interpreter and the step algebra this tree
surfaces are owned by [Phase 16](phase-16-project-lifecycle-command.md); the removed flat verbs are recorded
in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Removed Surfaces`.

### Sprint 4.3: Schema fixture and drift checks [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/example.dhall`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`

#### Objective

Keep the committed example fixture aligned with the project config decoder and the validated-codec
schema emitted by the binary.

#### Deliverables

- `service schema` describes the validated-codec project-local record shape for the project's `cfg`;
  `context schema` describes the registered static `ConfigArtifact` union. Closed Sprint 8.7 proves the
  decoder and encoder claim the same normalized expression.
- `SchemaSpec` round-trips rendered defaults and the canonical fixture through the Haskell decoder.
- Generated schema output includes the validated-codec project-local config surface.

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

Define the sibling `<project>.dhall` contract owned by the built project binary. The original sprint used
a core-owned concrete record; Phase 19 subsequently made the core generic and moved the concrete record
to the project.

#### Deliverables

- A project-owned config type covering project settings, Dockerfile/build inputs, resources, runtime
  context, allowed command classes, role name, and child-config projection defaults, consumed by core
  through `ProjectCfg cfg`.
- Cabal-derived project identity: the config validates against the project name derived from the Cabal
  file and does not require a user-authored `project` field to bootstrap Python.
- Tests proving the schema decodes, rejects malformed values, and supports the explicit `context show`
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
