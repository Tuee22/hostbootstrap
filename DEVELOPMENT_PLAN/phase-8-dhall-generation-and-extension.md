# Phase 8: Dhall Generation and the Extension Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Land the binary-generated Dhall model — each project binary emits its own schema/default
> config and renders child/deploy/test configs from a reusable Dhall vocabulary — and formalize the
> extension-stream contract every library level composes.

## Phase Status

**Status**: Done

The binary-generated rich tiers are implemented: `HostBootstrap.Config.Vocab` mirrors the reusable
`Core.dhall` vocabulary; `HostBootstrap.Dhall.Gen` carries the `ConfigArtifact` registry whose
`schemaText` is reflected from the decoder type (so it cannot drift) and whose `renderText` is the
`ToDhall` embedding; `config schema` prints the in-scope schema union (guarded by a committed snapshot)
and `config render` materializes static registry examples. The hand-written `Core.dhall` `fitsWithin`/`split` are
evaluation-tested, and a deploy config carries the `fitsWithin` assert so an over-budget render fails to
type-check. The **extension-stream contract** is complete: the CLI-tree, Dhall-vocabulary,
schema-gen-registry, and test-harness `Seams` streams are implemented, and the `hostbootstrap-demo`
consumer
([Phase 13](phase-13-hostbootstrap-demo.md)) exercises all four end-to-end (`--help` CLI append,
`config schema` / `config render --artifact demoWeb` registry concat, `test all` harness). `config init`
generates role-specific project-local configs without an existing context, `config schema` includes the
reflected `ProjectConfig` type, and pure projection helpers derive narrower child configs from a parent
config. This phase is `Done`.

**Naming forward-note (phases 4/16).** The flat `config schema` / `config render` / `config init` and
`test all` verb spellings used present-tense throughout this phase document were later renamed on the
fixed command surface: `config schema` → `context schema`, `config render` → `context render [--artifact
NAME]`, `config init` → `project init`, and `test all` → `test run all`. The surfaces they describe are
unchanged — only the verb spellings moved (§ P; phases 4/16).

## Remaining Work

[Phase 19](phase-19-generic-project-model.md) builds **forward** on this surface (the generic project
model, § BB): it parameterizes `ProjectSpec` as `ProjectSpec cfg tcfg` over a project's own
config/test-config types, adds the project-owned `psInit` / `psTestInit` / `psTestConfig` seams, and adds a
pure `SecretRef` vocabulary. The superseded fixed-`ProjectConfig` surface is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. **This phase is
not reopened.**

None. Phase 13 applies these helpers to the worked demo, and Phase 15 wires normal command gating to the
context section inside `<project>.dhall`.

## Phase Objective

Realize the binary-generated-configuration half of the Dhall model (see
[development_plan_standards.md § P, Q](development_plan_standards.md)) and the extension contract
contract (see [development_plan_standards.md § T](development_plan_standards.md)). The binary generates
the default local config, generated child configs, and richer deploy/test configs from reusable
vocabulary and decoder-owned schema, so the schema and the configs flow from the binary's types and
round-trip byte-stably.

## Sprints

### Sprint 8.1: `Core.dhall` vocabulary and budget helpers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/dhall/Core.dhall`, `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/architecture/dhall_generation.md`, `system-components.md`

#### Objective

Export the reusable Dhall vocabulary every project composes from, plus the budget helper functions.

#### Deliverables

- `Core.dhall` exporting `Resources`, `Budget`, `Substrate`, `RunModel`, `ClusterProfile`, `Mount`,
  `PodResources {replicas, cpuRequest, cpuLimit, memoryRequest, memoryLimit}`, `KindNode`.
- `Budget/fitsWithin : Budget -> List PodResources -> Bool` and `Budget/split : Budget -> List Weight ->
  List Budget`, hand-written and drift-controlled by a render-round-trip (not reflection).
- The matching Haskell decoder types so `config schema`'s reflection matches the vocabulary.

#### Validation

- A unit test evaluates `Budget/fitsWithin` and `Budget/split` against fixtures; an over-budget input is
  rejected. `cabal test` passes.

#### Remaining Work

None. The `Daemon.dhall` and `App.dhall` vocabulary layers are downstream consumer-repository work, not
`hostbootstrap` phase work.

### Sprint 8.2: `HostBootstrap.Dhall.Gen` and the `ConfigArtifact` registry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/engineering/config_generation.md`, `system-components.md`

#### Objective

Land the schema-generation substrate: a registry whose entries carry a reflected schema and a renderer.

#### Deliverables

- `data ConfigArtifact = ConfigArtifact { artifactName :: Text, schemaText :: Text, renderText :: Text }`
  where `schemaText` is reflected from the Haskell type via `Dhall.Encoder` (so it equals the decoder
  type) and `renderText` is the deterministic `ToDhall` embedding of a canonical value.
- A registry the command tree concatenates across library levels (L0 registers core artifacts; project
  binaries append their own).

#### Validation

- A test reflects a sample decoder type and asserts the emitted schema decodes a value of that type.

#### Remaining Work

None.

### Sprint 8.3: `config schema` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/golden/config_schema.dhall`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/engineering/config_generation.md`

#### Objective

Wire the `config schema` subcommand into the `config` group so the binary prints the transitive union
of its in-scope `ConfigArtifact` schemas, guarded by a committed CI snapshot.

#### Command Surface

- `<project> config schema` — print the Dhall type the binary's decoders accept (the L0->L1->L2
  concatenation of in-scope `ConfigArtifact` schemas).

#### Deliverables

- The `config schema` subcommand wired into the `config` group, printing the transitive union.
- A CI snapshot of the emitted schema, diffed for stability.

#### Validation

- `<project> config schema` output matches the committed snapshot; a decoder-type change that is not
  re-snapshotted fails the diff.

#### Remaining Work

None.

### Sprint 8.4: `config render` and the round-trip guarantee [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/engineering/config_generation.md`, `documents/architecture/dhall_generation.md`

#### Objective

Materialize concrete static Dhall examples from the reusable vocabulary via `config render`,
deterministic and idempotent. Rich deploy renders use `deployConfigText` to carry the
`Budget/fitsWithin` assertion so an over-budget config fails to type-check.

#### Command Surface

- `<project> config render [--artifact NAME]` — materialize the registry's static example renders: with
  no flag every in-scope `ConfigArtifact`, or just the named one with `--artifact NAME`. The rich deploy
  tier is rendered by `deployConfigText coreImport budget pods` (a budget plus a concurrent pod set
  composed into a config carrying the `Budget/fitsWithin` assertion); the per-case test tier is rendered
  by the project binary / test harness under `./.test_data/<case>/` (Phase 10), not an L0 `config render`
  flag.

#### Deliverables

- Deterministic, idempotent render composing the reusable vocabulary; every generated config carries the
  hand-written `Budget/fitsWithin` assertion, so an over-budget render fails at Dhall evaluation.

#### Validation

- A `render -> decode -> re-render` round-trip is byte-identical; an over-budget render fails to
  type-check. `cabal test` passes.

#### Remaining Work

None.

### Sprint 8.5: The extension-stream contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `documents/architecture/library_hierarchy.md`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/library_hierarchy.md`, `documents/engineering/derived_project_standards.md`

#### Objective

Document and exercise the one merge idiom per stream that makes the three-level hierarchy DRY.

#### Deliverables

- The contract is stated for all four streams in
  [`documents/architecture/library_hierarchy.md`](../documents/architecture/library_hierarchy.md): CLI
  tree (`runHostBootstrapCLI progName projectSpec` — a project extends the fixed core tree only through
  the `ProjectSpec` streams (`withChain` lift chain, `withServices`, test suite), never by appending
  named `ProjectCommand`s),
  Dhall vocabulary (`let C = ./Core.dhall`, embed-not-redefine), schema-gen (`ConfigArtifact` registry
  concatenation through `ProjectSpec`), and test harness (`Seams` through a non-empty `TestSuite`). All
  four streams are implemented in L0 — the CLI tree via `runHostBootstrapCLI`, the `Core.dhall`
  vocabulary, the `ConfigArtifact` registry concatenation, and the `Seams` record + the L0
  `oneShotRunArgs` (Phase 10). The contract is worked end-to-end by the `hostbootstrap-demo` consumer
  (Phase 13).

#### Validation

- The `hostbootstrap-demo` binary exercises all four streams: `hostbootstrap-demo --help` shows the
  inherited core verbs plus the appended demo verbs (CLI tree, no shadowing); `hostbootstrap-demo config
  schema` / `hostbootstrap-demo config render --artifact demoWeb` print the `coreArtifacts ++
  demoArtifacts` registry (schema-gen concatenation); `hostbootstrap-demo test all` drives `runMatrix`
  over the demo's case matrix with `demoSeams` (the harness `Seams`, bound to the inherited `test` verb).
  `cabal test` and the demo `--help`/verbs pass.

#### Remaining Work

None.

### Sprint 8.6: Default local config and child projections [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/DhallGenSpec.hs`, `core/hostbootstrap-core/test/golden/config_schema.dhall`
**Docs to update**: `documents/architecture/dhall_generation.md`,
`documents/engineering/config_generation.md`, `documents/engineering/dhall_topology.md`,
`documents/engineering/schema.md`, `system-components.md`

#### Objective

Make the project binary the generator for the default local `<project>.dhall` and for every downstream
child `<project>.dhall` used across VM, ad-hoc container, and service/daemon boundaries.

#### Deliverables

- `<project> config init [--role ROLE] [--output FILE] [--force] [--if-missing]` emits a default config for
  the selected local role without requiring an existing config; `--if-missing` is the idempotent
  no-op-if-present mode the Python bootstrapper triggers post-build. The rendered Dhall hoists the repeated
  `ContextKind`/`Capability`/`CommandClass` unions into top-level `let` bindings (`HostBootstrap.Dhall.Hoist`,
  shared with context rendering) so the output stays compact and standalone.
- Help and schema output explain the fields users are expected to edit and the fields managed by parent
  projection.
- Parent-to-child projection helpers project the child-needed values from the active parent config:
  resource envelopes, HA replicas, Dockerfile/build defaults, service role identity, and allowed command
  classes. Phase 15 wires those helpers into the runtime `<project>.dhall` gate and command surfaces.
- Generated child configs are deterministic and do not let a child represent an illegal function.

#### Validation

- The committed `config_schema.dhall` golden now includes the reflected `ProjectConfig` schema.
- `SchemaSpec` proves generated defaults decode and re-render stably, child projections preserve project
  settings while narrowing authority, and generated roles cannot authorize illegal command families.
- `ContextSpec` proves `config init` writes a project-local config before sibling context gating.
- Validation: `cabal test all` passes with 158 tests.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/library_hierarchy.md` - the three additive library levels and the extension-stream
  extension contract.
- `documents/architecture/dhall_generation.md` - local runtime config generation, child projections, the
  three-vocabulary model, and the reflect-from-decoders vs hand-written-assert nuance.

**Engineering docs to create/update:**
- `documents/engineering/config_generation.md` - the `ConfigArtifact` registry, `config init`,
  `config schema`/`render`, child projections, and the round-trip guarantee.

**Cross-references to add:**
- `system-components.md` adds the `HostBootstrap.Dhall.Gen` and `config init`/`schema`/`render` rows.
- `documents/engineering/schema.md` and `documents/engineering/dhall_topology.md` distinguish local
  runtime configs, generated child configs, and binary-generated rich tiers.
