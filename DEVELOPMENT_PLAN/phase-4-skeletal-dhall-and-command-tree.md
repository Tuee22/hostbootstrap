# Phase 4: Static-Base Dhall and Command Tree

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md)

> **Purpose**: Land the static-base `hostbootstrap.dhall` schema and its in-process Haskell decoder,
> and the composable optparse command tree project binaries extend through `runHostBootstrapCLI`.

## Phase Status

**Status**: Done

`HostBootstrap.Config.Schema` provides the in-process Haskell decoder for the static-base
`hostbootstrap.dhall` (`{ project, dockerfile, resources {cpu, memory, storage} }`), backing
`hostbootstrap config show`. `HostBootstrap.Command` composes the `ensure` and `config` verbs, and
`runHostBootstrapCLI` extends the tree with project commands (demonstrated by the worked `demo/`
consumer). **Correction:** the **pre-binary** read of the static base is done by the Python bootstrapper
via the pinned `dhall-to-json` (`hostbootstrap/dhall_tool.py`), which is **retained** — it must run
before any binary exists — not removed; the in-process Haskell decoder serves `config show` *after* the
binary exists. The reopened binary-generated-schema items are delivered (see
[development_plan_standards.md § P, Q](development_plan_standards.md)), so this phase is closed: `config
schema` / `config render` over `HostBootstrap.Dhall.Gen` + the `ConfigArtifact` registry and the reusable
`Core.dhall` vocabulary (`Budget/fitsWithin`, `Budget/split`) **landed** in
[phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md); the four-stream
contract and the three-level hierarchy are documented (Phase 7 / Phase 8; the harness-`Seams` stream is
Phase 10); and the `skeletal` → `static-base` rename + the `Type.dhall` ↔ Python `package.dhall`
anti-drift check landed (Sprint 4.3).

The `skeletal` → `static-base` rename (code identifiers, comments, and the governed-docs prose; the
phase-4 file path retains the historical token by the § E canonical layout) and the `Type.dhall` ↔
Python `package.dhall` anti-drift check have **landed** (Sprint 4.3).

## Phase Objective

Land the static-base `hostbootstrap.dhall` (`project`, `dockerfile`, `resources {cpu, memory, storage}`)
and the composable optparse command tree projects extend (see
[development_plan_standards.md § P, Q](development_plan_standards.md)). The static base is read pre-binary
by the Python bootstrapper via the pinned `dhall-to-json` (`dhall_tool.py`, retained); the in-process
Haskell decoder backs `config show`. The rich project-level and per-case test Dhall are artifacts the
project binary generates; core owns only the static-base decoder.

## Sprints

### Sprint 4.1: Static-base schema + in-process decoder [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/dhall/Type.dhall`, `core/hostbootstrap-core/dhall/example.dhall`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`,
`system-components.md`

#### Objective

Land the static-base `hostbootstrap.dhall` schema and `HostBootstrap.Config.Schema`, the in-process
decoder that backs `config show`. (The pre-binary read is done by the Python bootstrapper via the pinned
`dhall-to-json`, `dhall_tool.py`, which is retained — see this phase's Phase Status.)

#### Deliverables

- The static-base schema: `{ project : Text, dockerfile : Text, resources : { cpu : Natural, memory :
  Text, storage : Text } }`, identical in shape across projects.
- `HostBootstrap.Config.Schema` decoding the static-base config via the Haskell `dhall` library.
- The resource budget exposed as the single static field that the Python layer reads pre-binary; Phase 15
  carries it into the runtime binary-context config consumed by normal project-binary commands.

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
- `hostbootstrap config show` — decode/inspect the static-base `hostbootstrap.dhall`.
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

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - the command-tree extension contract.

**Engineering docs to create/update:**
- `documents/engineering/schema.md` - the static-base `hostbootstrap.dhall` schema.
- `documents/engineering/dhall_topology.md` - the three Dhall tiers; the binary-generated project/test
  schemas.

**Cross-references to add:**
- `system-components.md` updates the static-base-schema and command-tree rows.
- `legacy-tracking-for-deletion.md` keeps the three-execution-model schema, `dhall_tool.py`, and
  `spec.py` owning-phase set to this phase.
