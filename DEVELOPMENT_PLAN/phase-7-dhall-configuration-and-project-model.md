# Phase 7 — Dhall configuration and the generic project model

**Status**: Done
**Depends on**: Phase 6 (canonical quantities and reconcile results)
**Substrates**: none (static)
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, including the schema golden tests

> **Purpose**: Own the project-local Dhall vocabulary, the scope-indexed codec that turns untrusted wire
> into typed configuration, and the generic project model core carries no defaults for.

## Phase Objective

Core is a library of shapes plus an algebra; it owns **no default config values and no fixed config type**.
A project declares its own configuration, and core's job is to decode it into a value whose *scope* is part
of its type — so a test-only secret cannot inhabit production configuration, and a harness plan cannot be
built from a production codec.

The generated Dhall vocabulary is produced from the Haskell types rather than maintained beside them, so the
schema a consumer imports and the type core decodes cannot drift.

## Sprints

### Sprint 7.1: The scope vocabulary and scoped codecs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields/Internal.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Make execution scope part of the configuration's type.

#### Deliverables

- `Production projectId` and `Harness projectId runId` are the two scopes; a `cfg scope` is the project's own
  config type indexed by one of them.
- `ProjectCfg` exposes `withProductionProjectCodec` and `withHarnessProjectCodec`; the harness codec requires
  a harness config authority, so a project cannot obtain one without a run.
- `SecretRef scope` is scope-indexed and `TestPlaintext` inhabits only `Harness`, making a plaintext secret in
  production configuration **unrepresentable** rather than excluded by policy — see [rationale.md](rationale.md).
- `ProjectCodec scope specDigest cfg` carries a specification digest, so a value decoded under one schema
  cannot be presented under another.
- The only required accessor is `cfgContext`; core reads nothing else out of a project's config.

#### Validation

`SchemaSpec` covers each scope, the codec round trip, and the plaintext-secret exclusion.

#### Remaining Work

None.

### Sprint 7.2: The generated Dhall vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Dhall/Hoist.hs`,
`core/hostbootstrap-core/dhall/Core.dhall`, `core/hostbootstrap-core/test/golden/`
**Substrates**: none
**Docs to update**: `documents/engineering/schema.md`, `documents/architecture/dhall_generation.md`

#### Objective

Generate the schema from the types, and prove it judgmentally equal.

#### Deliverables

- `Core.dhall` is generated from the Haskell types; every exported type has a judgmental-equality witness
  against its Haskell counterpart.
- `Dhall.Hoist` provides the one validated lower-layer codec witness a project extends.
- Schema commands emit exact snapshots; golden tests pin them, so a vocabulary change is a visible diff.
- Decoding runs in-process; there is no shelled `dhall-to-json` path, because a second decoder is a second
  semantics.

#### Validation

`DhallGenSpec` plus the golden snapshots. A vocabulary change that is not regenerated fails the golden.

#### Remaining Work

None.

### Sprint 7.3: The generic project specification [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

One opaque, validated project specification with no core defaults.

#### Deliverables

- `ProjectSpec projectId cfg tcfg` is generic over the project's config and test-config types and carries no
  `ProjectCommand` deltas — the command surface is closed.
- The one restricted config assembler permits declared config and secret reads and **no** general `IO` or
  backend mutation, so project-owned assembly cannot perform an effect.
- `CaseId` and `VariantId` are validated opaque identities, and the typed test-config-to-variant projection is
  generic; the demo's own matrix is not modelled here.
- `CanonicalPlanSnapshot` carries the canonical plan bytes plus the spec, config, and plan digests, all
  derived from the snapshot rather than supplied independently.
- `check-code` is supplied by construction rather than defaulted.

#### Validation

`SchemaSpec` covers assembly, the effect exclusion, identity validation, and the canonical snapshot's derived
digests.

#### Remaining Work

None.

### Sprint 7.4: Binary context inside the project config [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Install/Native.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Carry the runtime context inside `<project>.dhall` as parameters plus context plus witness, and let a
command's placement — not the config's own claim — decide which verbs that context hosts.

#### Deliverables

- `BinaryContext` is the descriptive runtime context: the frame this binary occupies, its topology position,
  and its declared role. It is **descriptive only** and authorizes nothing.
- The context lives inside `<project>.dhall`, so there is one file to read rather than a config plus a
  sidecar that can disagree.
- `childContext` derives a child frame's context from the parent's, so a frame cannot invent its own position.
- A runtime witness lets a binary verify it is running in the frame its context claims, with per-frame
  fail-fast.
- `Config.Install.Native` supplies the create-if-absent **hard link** primitive a sibling config install
  needs; a symbolic link is refused by the inspector and leaves a dangling destination — see
  [rationale.md](rationale.md).
- `isRootFrame` derives chain root-ness from the validated topology graph rather than reading it off the
  declared `parentChain`, which `validateTopology` has already proved agrees with the edges.
- `placementAllowsCommand` is the closed (placement, root-ness, command class) relation every gated verb
  passes: `allowedCommandClasses` is a *declared* list, so it is a claim, and the placement the graph
  derives is the fact. `project up` runs only from an orchestration placement; `project down|destroy`
  additionally require the exact root-kind/empty-parent pair.
- A forged leaf config that lists `ClusterLifecycleCommand` or `HostOrchestratorCommand` is refused by its
  placement, so a binary cannot run a verb its context does not place it in.

#### Validation

`ContextSpec` covers derivation, the witness check, the per-frame refusal, the hard-link primitive, the
forged-leaf refusal for both lifecycle verbs, the non-root refusal of the unwind, the root-kind refusal of a
non-host root, and the closure of `placementAllowsCommand` over every placement and class. `cabal test all
--ghc-options=-Werror` from `core/` passed 935/935 on 2026-08-05 (aarch64-osx, GHC 9.12.4).

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/generic_project_model.md` — the generic spec, scoped codecs, and no-core-defaults
  contract.
- `documents/architecture/dhall_generation.md` — generation from the types and judgmental equality.
- `documents/architecture/binary_context_config.md` — parameters plus context plus witness in one file.

**Engineering docs to create/update:**
- `documents/engineering/schema.md` — the schema commands and golden snapshots.
- `documents/engineering/config_generation.md` — how a project declares its vocabulary.

**Cross-references to add:**
- `development_plan_standards.md` § Q and § BB name this phase as the owner of the configuration contracts.
