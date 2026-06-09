# Phase 4: Skeletal Dhall and Command Tree

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md)

> **Purpose**: Land the skeletal `hostbootstrap.dhall` schema and its in-process Haskell decoder,
> and the composable optparse command tree project binaries extend through `runHostBootstrapCLI`.

## Phase Status

**Status**: Active

`HostBootstrap.Config.Schema` provides the in-process Haskell decoder for the static-base
`hostbootstrap.dhall` (`{ project, dockerfile, resources {cpu, memory, storage} }`), backing
`hostbootstrap config show`. `HostBootstrap.Command` composes the `ensure` and `config` verbs, and
`runHostBootstrapCLI` extends the tree with project commands (demonstrated today by the
`hostbootstrap-example` binary; to be superseded by the worked `demo/` consumer). **Correction:** the
**pre-binary** read of the static base is done by the Python bootstrapper via the pinned `dhall-to-json`
(`python/hostbootstrap/dhall_tool.py`), which is **retained** — it must run before any binary exists —
not removed; the in-process Haskell decoder serves `config show` *after* the binary exists. This phase
reopens against the binary-generated-schema contract (see
[development_plan_standards.md § P, Q](development_plan_standards.md)).

**Remaining Work** (reopened; the generation substrate is tracked in the net-new Phase 8):
- Build `config schema` (the binary emits its own Dhall schema, reflected from its decoder types) and
  `config render` (materialize deploy/per-case configs) over a `HostBootstrap.Dhall.Gen` +
  `ConfigArtifact` registry and the reusable `Core.dhall` vocabulary (`Budget/fitsWithin`,
  `Budget/split`).
- Formalize the four-stream extension contract (CLI append, Dhall embed, schema concat, harness seams)
  and the three-level library hierarchy.
- Rename "skeletal" → "static base" consistently; add a CI check that `Type.dhall` and the Python-side
  `package.dhall` keep the same shape (the anti-drift guarantee).

## Phase Objective

Replace the rich three-execution-model schema with the skeletal `hostbootstrap.dhall`
(`project`, `dockerfile`, `resources {cpu, memory, storage}`) and decode it in-process with the
Haskell `dhall` library — no external `dhall-to-json` binary. Land the composable optparse command
tree projects extend (see [development_plan_standards.md § P, Q](development_plan_standards.md)). The
rich project-level and per-case test Dhall are artifacts the project binary generates; core owns only
the skeletal decoder.

## Sprints

### Sprint 4.1: Skeletal schema + in-process decoder [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`haskell/hostbootstrap-core/dhall/Type.dhall`, `haskell/hostbootstrap-core/dhall/example.dhall`
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

- `SchemaSpec` decode round-trips a valid `hostbootstrap.dhall` (text and the `example.dhall`
  fixture); a malformed config and a wrong-typed field each fail with a typed Dhall error.
- `cabal build all` succeeds; `hostbootstrap config show <file>` prints the decoded fields.

#### Remaining Work

The Haskell decoder is complete. The three-execution-model schema, `dhall_tool.py`, and `spec.py`
remain live until the Python layer is rewritten in phase-6; see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Sprint 4.2: Composable command tree [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`haskell/hostbootstrap-core/example/Main.hs`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Command` — the core optparse command tree composing `ensure <tool>` and the
skeletal `config` verbs — and confirm `runHostBootstrapCLI progName projectCommands` extends it with
project-specific subcommands.

#### Command Surface

- `hostbootstrap ensure <tool>` — the Phase 3 reconcilers.
- `hostbootstrap config <...>` — decode/inspect the skeletal `hostbootstrap.dhall`.
- A project binary calls `runHostBootstrapCLI "<project>" projectCommands` to add its own verbs;
  the skeletal `hostbootstrap` binary (`hostbootstrap-core`'s own executable) passes no project
  commands.

#### Deliverables

- `HostBootstrap.Command` exposing the composable command value.
- A test project binary demonstrating tree extension without re-implementing core verbs.

#### Validation

- `hostbootstrap --help` shows the composed core tree (`ensure`, `config`); the
  `hostbootstrap-example` binary shows the core verbs plus its own `greet` verb.

#### Remaining Work

None.

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
