# Phase 4: Skeletal Dhall and Command Tree

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md)

> **Purpose**: Land the skeletal `hostbootstrap.dhall` schema and its in-process Haskell decoder,
> and the composable optparse command tree project binaries extend through `runHostBootstrapCLI`.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-3 (the command tree composes the `ensure` subcommands) and phase-1 (the
entrypoint shape).

No code in this phase is written. Today's config is the three-execution-model schema in
`hostbootstrap/dhall/package.dhall`, parsed by shelling out to `dhall-to-json`
(`hostbootstrap/dhall_tool.py`, `hostbootstrap/spec.py`).

## Phase Objective

Replace the rich three-execution-model schema with the skeletal `hostbootstrap.dhall`
(`project`, `dockerfile`, `resources {cpu, memory, storage}`) and decode it in-process with the
Haskell `dhall` library — no external `dhall-to-json` binary. Land the composable optparse command
tree projects extend (see [development_plan_standards.md § P, Q](development_plan_standards.md)). The
rich project-level and per-case test Dhall are artifacts the project binary generates; core owns only
the skeletal decoder.

## Sprints

### Sprint 4.1: Skeletal schema + in-process decoder [Blocked]

**Status**: Blocked
**Blocked by**: phase-1, sprint 1.2
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`

#### Objective

Land the skeletal `hostbootstrap.dhall` schema and `HostBootstrap.Config.Schema`, the in-process
decoder that reads it without provisioning or shelling out to `dhall-to-json`.

#### Deliverables

- The skeletal schema: `{ project : Text, dockerfile : Text, resources : { cpu : Natural, memory :
  Text, storage : Text } }`, identical in shape across projects.
- `HostBootstrap.Config.Schema` decoding the skeletal config via the Haskell `dhall` library.
- The resource budget exposed as the single field both the Python layer and the project binary
  consume.

#### Validation

- Decode round-trips a valid `hostbootstrap.dhall`; a malformed config fails with a typed error.
- `cabal build all` succeeds.

#### Remaining Work

- All of it; blocked on phase-1. The three-execution-model schema, `dhall_tool.py`, and `spec.py`
  stay live until this lands; see [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Sprint 4.2: Composable command tree [Blocked]

**Status**: Blocked
**Blocked by**: sprint 4.1, phase-3, sprint 3.2
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Command` — the core optparse command tree composing `ensure <tool>` and the
skeletal `config` verbs — and confirm `runHostBootstrapCLI progName projectCommands` extends it with
project-specific subcommands.

#### Command Surface

- `hostbootstrap ensure <tool>` — the Phase 3 reconcilers.
- `hostbootstrap config <...>` — decode/inspect the skeletal `hostbootstrap.dhall`.
- A project binary calls `runHostBootstrapCLI "<project>" projectCommands` to add its own verbs;
  the skeletal `hostbootstrap` binary baked into the base image passes no project commands.

#### Deliverables

- `HostBootstrap.Command` exposing the composable command value.
- A test project binary demonstrating tree extension without re-implementing core verbs.

#### Validation

- `hostbootstrap --help` shows the composed core tree; an extending binary shows core verbs plus its
  own.

#### Remaining Work

- All of it; blocked on sprint 4.1 and phase-3.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - the command-tree extension contract.

**Engineering docs to create/update:**
- `documents/engineering/schema.md` - the skeletal `hostbootstrap.dhall` schema.
- `documents/engineering/dhall_topology.md` - the three Dhall tiers; the binary-generated project/test
  schemas.

**Cross-references to add:**
- `system-components.md` updates the skeletal-schema and command-tree rows.
- `legacy-tracking-for-deletion.md` keeps the three-execution-model schema, `dhall_tool.py`, and
  `spec.py` owning-phase set to this phase.
