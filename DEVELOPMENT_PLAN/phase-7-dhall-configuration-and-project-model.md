# Phase 7 — Dhall configuration and the generic project model

**Status**: Done
**Depends on**: Phase 6 (canonical quantities and reconcile results)
**Substrates**: none (static)
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, including the schema golden tests

> **Purpose**: Own the project-local Dhall vocabulary, the scope-indexed codec that turns untrusted wire
> into typed configuration, its adapter to the lower canonical budget foundation, the generic project model
> core carries no defaults for, and the public pure context vocabulary used to describe nested execution
> targets.

## Phase Objective

Core is a library of shapes plus an algebra; it owns **no default config values and no fixed config type**.
A project declares its own configuration, and core's job is to decode it into a value whose *scope* is part
of its type — so a test-only secret cannot inhabit production configuration, and a harness plan cannot be
built from a production codec.

The generated Dhall vocabulary is produced from the Haskell types rather than maintained beside them, so the
schema a consumer imports and the type core decodes cannot drift.

The same layer also owns the plan-independent description of a nested execution context. Target records and
inner transport argument rendering are pure data here; resolved host-tool effects and provider lifecycle
realizations are added by later phases.

Configuration-facing budget conversion also lives here: the facade adapts `Resources`/`ResourceEnvelope` to
Phase 6's opaque provider-neutral `ResourceBudget` without pulling configuration imports into that lower
foundation. Phase 12 separately owns plan-indexed workload/fit/partition/slice evidence.

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

- Phase 5's `Production projectId` and `Harness projectId runId` are the two scopes; a `cfg scope` is the
  project's own config type indexed by one of them.
- `ProjectCfg cfg` exposes a production codec continuation that quantifies `projectId` and a harness codec
  tied to the exact generative run authority. A project config family does not declare or fix installed
  identity.
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

### Sprint 7.3: Validated configuration evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Retain the canonical configuration digest in the exact validated value that later plan construction consumes.

#### Deliverables

- `ValidatedConfig scope specDigest configId config` retains both the admitted value and the digest derived
  from its exact canonical bytes.
- Ordinary codec admission and authenticated-wire admission populate that one field from the same bytes that
  mint `VerifiedConfigWire`; no caller supplies an independent digest.
- `validatedConfigDigest` observes the retained digest without weakening the scope, specification, or config
  identities.

#### Validation

`SchemaSpec` covers ordinary and authenticated admission, exact digest retention, and byte substitution
refusal.

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

### Sprint 7.5: Config-family service registry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Let one statically validated service registry instantiate under the runtime-selected project scope.

#### Deliverables

- `ServiceDefinition cfg` projects fields through `forall scope. cfg scope` rather than fixing a Production
  project marker.
- `ServiceRegistry cfg` stores those definitions without an impredicative list or partial runtime merge.
- `withFinalizedServiceRegistry` instantiates the registry only after the exact scope codec is selected and
  retains that scope and final `specDigest` in every finalized definition.
- Core fixtures and the demo declare one config-family registry and no identity-selected registry.

#### Validation

`CLISpec`, the service role-schema cases, and demo `CommandsSpec` cover duplicate validation, selection, and
finalization under the runtime Production scope.

#### Remaining Work

None.

### Sprint 7.6: Identity-parametric project specification [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`, `demo/app/Main.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/authoring_project_binaries.md`

#### Objective

Make the static project specification independent of the installed identity selected at runtime.

#### Deliverables

- `ProjectSpec cfg tcfg` and `ProjectSpecBuilder cfg tcfg` carry no `projectId` parameter or project-authored
  identity marker.
- Config assembly quantifies `projectId`, while one shared `scope` indexes both `CanonicalProjectRoot` and
  `cfg scope`; an independently scoped root/config pair is unrepresentable.
- The specification stores `ServiceRegistry cfg`, and finalization validates its additive fragments without
  selecting a runtime identity.
- The restricted config assembler permits declared config and secret reads and **no** general `IO` or backend
  mutation; `check-code` and the typed test projection remain supplied by construction.

#### Validation

`CLISpec`, `ContextSpec`, and the existing unfinished-builder/root-scope compile-fail fixtures cover the
generic builder, shared scope, and absence of core defaults.

#### Remaining Work

None.

### Sprint 7.7: Runtime installed-identity adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`demo/src/HostBootstrapDemo/Config.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/authoring_project_binaries.md`

#### Objective

Open the executable-verified installed identity once and retain it through every production and harness
dispatch boundary.

#### Deliverables

- `runHostBootstrapCLI` opens Phase 5's rank-2 installed identity before it instantiates the production codec,
  services, config assembler, plan, or run.
- CLI and command construction receive that exact `InstalledProjectIdentity projectId`; no command recreates
  identity from a rendered project name or config-family phantom.
- The installed-project compatibility adapter is absent from the exposed package and every runtime/test
  consumer uses the executable-verified continuation.
- The demo declares services and config assembly parametrically in `projectId` and carries no project-authored
  installed-identity marker type.
- Test fixtures acquire the actual test executable identity through continuations and cannot let a generative
  `projectId` escape.

#### Validation

`CLISpec`, `SchemaSpec`, `AuthoritySpec`, and `HarnessSpec` cover the matching runtime identity and its
propagation through Production and Harness construction. Compile-fail and exposed-module guards prove that an
installed identity cannot escape, be substituted across two invocations, or be reconstructed through a
compatibility module. The complete phase gate passes.

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1090/1090 on
2026-08-08 (aarch64-osx, GHC 9.12.4), including all 71 public compile-fail boundaries. The integrated
consumer gate `cabal test all --ghc-options=-Werror` from `demo/` also passed the demo's 123/123 cases and
the dependency core suite.

#### Remaining Work

None.

### Sprint 7.8: Configuration-facing cordon facade [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Adapt the project configuration vocabulary to Phase 6's provider-neutral budget foundation without moving
configuration or plan identities into that lower module.

#### Deliverables

- `HostBootstrap.Cluster.Cordon` publicly reexports the lower foundation and owns conversion from
  `Config.Vocab.Resources` and descriptive `ResourceEnvelope` into opaque `ResourceBudget`.
- Configuration-facing preflight wrappers preserve the lower exact parse/verify/sizing behavior and return
  its descriptive refusals without constructing an independent budget representation.
- `fitsBudget` remains a pure descriptive configuration calculation in this facade; it is not the opaque
  plan-indexed workload-fit proof owned by Phase 12.
- The facade imports no `ProjectPlan`, provider realization, Registry, or cluster lifecycle module.

#### Validation

`CordonSpec` covers Resources/`ResourceEnvelope` conversion, wrapper equivalence with the lower foundation,
and descriptive `fitsBudget` outcomes. A source guard pins the adapter direction and the absence of later
plan/provider/cluster imports.

#### Remaining Work

None.

### Sprint 7.9: Pure lift-context vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Expose one public, plan-independent data vocabulary for the frame targets and transport shapes that later
Lift, plan, and provider modules share.

#### Deliverables

- Public `HostBootstrap.Lift.Context` owns `IncusVM`, `LimaVM`, and `Wsl2VM` target records.
- `ConfigDelivery`, `ContainerLift`, `LiftLayer`, and `LiftContext` describe the outermost-first frame stack
  without resolving tools or performing effects.
- `localContext`, `inVM`, `inLimaVM`, `inWsl2VM`, and `inContainer` are the canonical incremental constructors;
  the public data constructors remain available for direct inspection and exact fixture construction.
- `canonicalHostMount` accepts only a canonical root/path pair carrying the same hidden root identity; raw or
  cross-root paths cannot be used as a mount.
- `execVMArgs`, `shellVMArgs`, and `wslExecArgs` are the single pure inner-transport renderers. The later
  provider modules reexport them rather than defining another rendering.
- The module imports no Ensure, resolved-tool, provider-lifecycle, Registry, project-plan, or cluster module.

#### Validation

`LiftContextSpec` covers the local context, outermost-first append order, all three provider target records,
exact inner transport argv, container/config-delivery data, and same-root canonical mounts. Compile-fail
fixtures reject raw paths and a path from another root. A source guard pins the lower import boundary and the
public Cabal exposure.

Dated evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), focused `CordonSpec` plus `LiftContextSpec`
passed 61/61 under `-Werror`, the two canonical-mount compile-fail cases passed 2/2, and the exact phase gate
`cabal test all --ghc-options=-Werror` from `core/` passed 1464/1464, including the schema golden tests.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/generic_project_model.md` — the generic spec, scoped codecs, and no-core-defaults
  contract.
- `documents/architecture/dhall_generation.md` — generation from the types and judgmental equality.
- `documents/architecture/binary_context_config.md` — parameters plus context plus witness in one file.
- `documents/architecture/hostbootstrap_core_library.md` — the pure lift-context module boundary.
- `documents/architecture/composition_methodology.md` — context data beneath generic dispatch.

**Engineering docs to create/update:**
- `documents/engineering/schema.md` — the schema commands and golden snapshots.
- `documents/engineering/config_generation.md` — how a project declares its vocabulary.
- `documents/engineering/resource_budgeting.md` and `documents/engineering/applied_cordon.md` — the
  configuration facade over the lower provider-neutral budget foundation.

**Cross-references to add:**
- `development_plan_standards.md` §§ O, Q, U, and BB name this phase as the owner of the configuration-facing
  cordon adapter, configuration contracts, and pure lift-context vocabulary.
