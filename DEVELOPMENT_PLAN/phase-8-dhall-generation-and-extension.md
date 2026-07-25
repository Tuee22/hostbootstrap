# Phase 8: Dhall generation and extension contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Land the binary-generated Dhall model — each project binary emits its own schema/default
> config and renders child/deploy/test configs from a reusable Dhall vocabulary — and formalize the
> extension-stream contract every library level composes.

## Phase Status

**Status**: Active

**Reopened 2026-07-24.** The generator currently obtains `schemaText` from the `ToDhall` encoder's
`declared` expression, while decoding uses a separately supplied `FromDhall` instance. Those expressions
are not definitionally identical by construction, and the hand-written `Core.dhall` vocabulary has an
explicit judgmental-equality test for only part of its exported type surface. Sprint 8.7 owns one
validated codec/schema witness and complete `Core.dhall` drift coverage.

The binary-generated rich tiers otherwise exist: `HostBootstrap.Config.Vocab` mirrors part of the
reusable `Core.dhall` vocabulary; `HostBootstrap.Dhall.Gen` carries the `ConfigArtifact` registry whose
`schemaText` currently comes from `ToDhall.declared` and whose `renderText` is the `ToDhall` embedding;
the current `context schema` command prints the in-scope static-artifact schema union, and `context
render` materializes static registry examples. Only the helper-generated `coreArtifacts` portion
participates in the current synthetic committed schema fixture; neither the literal command output nor a
consumer's appended artifact delta has a command-level snapshot. The hand-written
`Core.dhall` `fitsWithin`/`split` functions and the standalone numeric `deployConfigText` artifact are
evaluation-tested. Runtime project configs instead carry Kubernetes quantities as `Text` and no pod set,
so they do not and cannot carry that assertion; their pod-set check belongs at bring-up. The
**extension-stream foundation** is complete: Dhall vocabulary, schema-gen registry, test harness, and the
fixed CLI entrypoint are implemented, and later phases add the chain and service streams without
reopening this substrate. `project init` generates the root project-local config, `service schema`
prints the `ToDhall` encoder-declared project config type, `context schema` prints the separate
static-artifact registry, and current pure projection helpers derive context-adjusted full child records
from a parent config. The phase remains
`Active` until Sprint 8.7 removes the schema-witness seam and closes the command-output drift gap.

**Historical naming note (phases 4/16/19).** The original Sprint 8 landing used flat `config schema` /
`config render` / `config init` and `test all` spellings. The supported commands are now `context schema`,
`context render [--artifact NAME]`, explicit `project init`, and `test run all`. The old Python
post-build `config init --if-missing` trigger was removed, not renamed: Python does not invoke
`project init`.

## Remaining Work

[Phase 19](phase-19-generic-project-model.md) built **forward** on this surface (the generic project
model, § BB): it parameterized `ProjectSpec` as `ProjectSpec cfg tcfg` over a project's own
config/test-config types, added the project-owned `psInit` / `psTestInit` / `psTestConfig` seams, and added a
pure `SecretRef` vocabulary. The superseded fixed-`ProjectConfig` surface is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner.

Sprint 8.7 replaces the independent encoder/decoder schema claims with a validated shared witness and
audits every committed `Core.dhall` type. Phase 13 applies the helpers to the worked demo, and Phase 15
wires normal command gating to the context section inside `<project>.dhall`.

## Phase Objective

Realize the binary-generated-configuration half of the Dhall model (see
[development_plan_standards.md § P, Q](development_plan_standards.md)) and the extension contract
contract (see [development_plan_standards.md § T](development_plan_standards.md)). The binary generates
the default local config, generated child configs, and richer deploy/test configs from reusable
vocabulary. Current emitted schema comes from each `ToDhall` encoder while decoding has a separate
`FromDhall` expression; selected canonical values have stable render/decode/re-render tests, but neither
schema equality nor universal byte stability follows from the current API. Sprint 8.7 replaces those
independent claims with a validated codec witness and explicit semantic round-trip properties.

## Sprints

### Sprint 8.1: `Core.dhall` vocabulary and budget helpers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/dhall/Core.dhall`, `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/architecture/dhall_generation.md`, `system-components.md`

#### Objective

Export the reusable Dhall vocabulary every project composes from, plus the budget helper functions.

#### Deliverables

- Historical initial vocabulary: `Core.dhall` exported `Resources`, `Budget`, `Substrate`, `RunModel`,
  `ClusterProfile`, `Mount`,
  `PodResources {replicas, cpuRequest, cpuLimit, memoryRequest, memoryLimit}`, `KindNode`.
- `Budget/fitsWithin : Budget -> List PodResources -> Bool` and `Budget/split : Budget -> List Weight ->
  List Budget`, hand-written and drift-controlled by evaluation/property tests (not reflection).
- The matching Haskell encoder/decoder types; current schema text comes from the encoder, while Sprint
  8.7 owns equality with the decoder and exhaustive committed-vocabulary coverage.

#### Validation

- A unit test evaluates `Budget/fitsWithin` and `Budget/split` against fixtures; an over-budget input is
  rejected. `cabal test` passes.

#### Remaining Work

None in this vocabulary sprint. Later audit found `RunModel` is never consumed and duplicates the
definition-only Haskell selector; Phase 10.10 removes that union so the lifecycle plan remains the one
execution representation. The `Daemon.dhall` and `App.dhall` vocabulary layers are downstream
consumer-repository work, not `hostbootstrap` phase work.

### Sprint 8.2: `HostBootstrap.Dhall.Gen` and the `ConfigArtifact` registry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/engineering/config_generation.md`, `system-components.md`

#### Objective

Land the schema-generation substrate: a registry whose entries carry a reflected schema and a renderer.

#### Deliverables

- `data ConfigArtifact = ConfigArtifact { artifactName :: Text, schemaText :: Text, renderText :: Text }`
  where `schemaText` is reflected from the Haskell type via the `ToDhall` encoder's `declared`
  expression and `renderText` is the deterministic embedding of a canonical value. This historical
  implementation did not make the separately supplied decoder expression equal by construction;
  Sprint 8.7 owns that repair.
- A registry the command tree concatenates across library levels (L0 registers core artifacts; project
  binaries append their own).

#### Validation

- A test reflects a sample decoder type and asserts the emitted schema decodes a value of that type.

#### Remaining Work

None for the historical registry landing. Sprint 8.7 owns the validated-codec successor.

### Sprint 8.3: `context schema` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/golden/config_schema.dhall`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/engineering/config_generation.md`

#### Objective

Expose the binary's transitive union of in-scope `ConfigArtifact` schemas. This originally landed as
`config schema`; its supported location is now `context schema`. The historical snapshot goal landed
only for a synthetic fixture containing the helper-generated L0 registry plus
`projectConfigSchemaText`, not for the literal command or a consumer artifact delta.

#### Command Surface

- `<project> context schema` — print the current encoder-declared Dhall types in the L0→L1→L2
  concatenation of in-scope `ConfigArtifact` schemas. Once Sprint 8.7 lands, this output comes only from
  codecs whose encoder/decoder type expressions were validated equal.

#### Deliverables

- The `context schema` subcommand wired into the read-only `context` group, printing the transitive union.
- A committed synthetic fixture that pins `schemaUnion coreArtifacts` followed by the separately
  reflected project-config schema. That fixture is not represented as command-output coverage.

#### Validation

- `DhallGenSpec` proves the helper-generated L0 union contains every core artifact and compares the
  synthetic L0-plus-project-config text with `config_schema.dhall`. It does not invoke `<project>
  context schema`, cover a project's appended registry, or prove decoder equality. Sprint 8.7 owns
  those missing command-level and codec gates.

#### Remaining Work

None for the historical command landing. Sprint 8.7 owns the command-output drift test that the original
snapshot wording overstated.

### Sprint 8.4: `context render` and the round-trip guarantee [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`, `core/hostbootstrap-core/test/DhallGenSpec.hs`
**Docs to update**: `documents/engineering/config_generation.md`, `documents/architecture/dhall_generation.md`

#### Objective

Materialize concrete static Dhall examples from the reusable vocabulary via `context render`,
deterministic and idempotent. The standalone numeric `deployConfigText` artifact uses
`Budget/fitsWithin` so an over-budget fixture fails to type-check; this is not the runtime
`<project>.dhall` schema and is not an assertion attached to every generated config.

#### Command Surface

- `<project> context render [--artifact NAME]` — materialize the registry's static example renders: with
  no flag every in-scope `ConfigArtifact`, or just the named one with `--artifact NAME`. The rich deploy
  fixture is rendered by `deployConfigText coreImport budget pods` (a numeric budget plus a concurrent
  pod set composed into an artifact carrying the `Budget/fitsWithin` assertion). Runtime project/test
  configs are separate project-owned values; they are not represented as this artifact.

#### Deliverables

- Deterministic, idempotent render composing the reusable vocabulary; the standalone numeric deploy
  artifact carries the hand-written `Budget/fitsWithin` assertion, so an over-budget fixture fails at
  Dhall evaluation.

#### Validation

- A `render -> decode -> re-render` round-trip is byte-identical; an over-budget
  `deployConfigText` fixture fails to type-check. Tests do not claim that runtime project configs carry
  this assertion. `cabal test` passes.

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

- The `hostbootstrap-demo` binary exercises the extension foundation without appending verbs:
  `hostbootstrap-demo --help` shows the fixed inherited tree; `hostbootstrap-demo context schema` /
  `hostbootstrap-demo context render --artifact demoWeb` expose the `coreArtifacts ++ demoArtifacts`
  registry; and `hostbootstrap-demo test run all` drives the compiled case matrix. The sprint's dated
  validation used the then-current spellings; the naming forward-note above is authoritative for their
  replacements.

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

- `<project> project init [--role ROLE] [--also-role ROLE]... [--output FILE] [--force|--if-missing]`
  emits a config for the selected primary/additional roles without requiring an existing config; with no
  role/output/overwrite flags its default is the fresh root host-orchestrator config. The current parser
  permits combinations that Phase 15.9 must replace with role-specific opaque init requests. It is an explicit binary command;
  Python does not trigger it. The rendered Dhall hoists the repeated
  `ContextKind`/`Capability`/`CommandClass` unions into top-level `let` bindings (`HostBootstrap.Dhall.Hoist`,
  shared with context rendering) so the output stays compact and standalone.
- Help and schema output explain the fields users are expected to edit and the fields managed by parent
  projection.
- Parent-to-child projection helpers derive child context/role declarations while retaining the full
  project record, including the parent's raw resource envelope, HA replicas, Dockerfile/build defaults,
  service role identity, and deploy knobs. This historical landing did not provide least-privilege
  parameter types or the computed cluster slice; Phases 9.10 and 19.8 own those repairs. Phase 15 wires
  the helpers into the runtime `<project>.dhall` gate and command surfaces.
- Generated child configs are deterministic and preserve the then-defined per-kind mapping. This sprint
  did not make arbitrary `--also-role` combinations or widened command authority unrepresentable;
  Phase 15.9 owns that stronger invariant.

#### Validation

- The committed synthetic `config_schema.dhall` golden includes the encoder-declared project-owned
  `cfg` schema; it is not literal output from either schema command.
- `SchemaSpec` proves generated defaults decode and re-render stably and child projections preserve
  project settings plus the mapped per-kind authority. It does not prove that arbitrary added-role
  combinations cannot widen a leaf into an illegal command family; Phase 15.9 owns that negative gate.
- `ContextSpec` proves `project init` writes a project-local config before sibling context gating.
- Validation: `cabal test all` passes with 158 tests.

#### Remaining Work

None.

### Sprint 8.7: One validated Dhall codec and vocabulary witness [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/dhall/Core.dhall`,
`core/hostbootstrap-core/test/DhallGenSpec.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/golden/config_schema.dhall`
**Docs to update**: `documents/architecture/dhall_generation.md`,
`documents/engineering/config_generation.md`, `documents/engineering/schema.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make schema generation and decoding consume one validated type witness, and make every hand-written
`Core.dhall` type either generated or explicitly equality-gated.

#### Deliverables

- Replace independent `FromDhall`/`ToDhall` constraints at the artifact/config boundary with an opaque
  lower-layer `CodecWitness a` whose constructor compares normalized decoder `expected` and encoder
  `declared` expressions once. Schema printing, decoding, and rendering all consume that validated
  witness. Phase 19.7 wraps it with installed project identity and scope as the final
  `ProjectCodec scope specDigest cfg`; the same type name must not be used at two incompatible arities.
- Reject a mismatched encoder/decoder pair before config decode or command side effects; do not describe
  Haskell encode/decode semantics as proven merely because their Dhall type expressions match.
- Inventory every type exported by committed hand-written `Core.dhall`. Generate it from the validated
  codec where practical; otherwise add an explicit judgmental-equality test against the matching Haskell
  codec. Remove stale types such as `RunModel` under their owning phase rather than silently exempting
  them.
- Keep hand-written Dhall functions (`fitsWithin`, `split`) under evaluation/property tests; a type
  witness does not prove function behavior.

#### Validation

- A deliberately mismatched `Encoder`/`Decoder` fixture cannot construct `CodecWitness` and fails before
  mutation.
- Every `ConfigArtifact` schema comes from a validated codec; render → decode → re-render tests cover
  representative values but are not misreported as a proof for all values.
- Command-level tests capture the exact `context schema` output for the bare core binary and a
  representative consumer registry (`coreArtifacts ++ projectArtifacts`); a changed, omitted, or
  reordered consumer artifact fails its owning snapshot. The project-local `cfg` snapshot is exercised
  through `service schema`, never smuggled into the `context schema` expectation.
- A coverage test enumerates all `Core.dhall` exported types and requires a generated source or explicit
  judgmental-equality owner; no unlisted hand-written type passes.

#### Remaining Work

Implement the codec witness, migrate artifact/project config call sites, expand `Core.dhall` coverage,
and replace the synthetic-only evidence with surface-specific command snapshots/tests.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/library_hierarchy.md` - the three additive library levels and the extension-stream
  extension contract.
- `documents/architecture/dhall_generation.md` - local runtime config generation, child projections, the
  three-vocabulary model, the current encoder-`declared` schema surface, and the target validated
  encoder/decoder codec witness versus explicit equality gates for hand-written types.

**Engineering docs to create/update:**
- `documents/engineering/config_generation.md` - the `ConfigArtifact` registry, explicit `project init`,
  `context schema`/`render`, child projections, and the round-trip guarantee.

**Cross-references to add:**
- `system-components.md` adds the `HostBootstrap.Dhall.Gen`, `project init`, and
  `context schema`/`render` rows.
- `documents/engineering/schema.md` and `documents/engineering/dhall_topology.md` distinguish local
  runtime configs, generated child configs, and binary-generated rich tiers.
