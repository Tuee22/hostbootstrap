# Phase 7 — Dhall configuration and the generic project model

**Status**: Done
**Depends on**: Phase 6 (canonical quantities and reconcile results)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`, including the schema golden tests
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-27 ; native Windows 11 x86_64, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` ; pass ; covers in-gate
**Gate evidence**: 2026-10-27 ; native-filesystem Ubuntu 24.04.4 x86_64 CPU container, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` ; pass ; covers in-gate

> **Purpose**: Own the project-local Dhall vocabulary, the scope-indexed codec that turns untrusted wire
> into typed configuration, its adapter to the lower canonical budget foundation, the generic project model
> core carries no defaults for, and the public pure context vocabulary used to describe nested execution
> targets.

## Phase Objective

Core is a library of shapes plus an algebra; it owns **no default config values and no fixed config type**.
A project declares its own configuration, and core's job is to decode it into a value whose *scope* is part
of its type — so a test-only secret cannot inhabit production configuration, and a harness plan cannot be
built from a production codec.

The hand-written `Core.dhall` vocabulary is held judgmentally equal to the schema the Haskell codecs reflect,
and each runtime config is rendered from its codec, so the schema a consumer imports and the type core decodes
cannot drift.

The same layer also owns the plan-independent description of a nested execution context. Target records and
inner transport argument rendering are pure data here; resolved host-tool effects and provider lifecycle
realizations are added by later phases. How the lifecycle branch of `Lift.foldLeaf` places its VM crossings
(working directory, non-interactive execution, elevation) is Phase 8's, which builds it over these renderers.

Configuration-facing budget conversion also lives here: the facade adapts `Resources`/`ResourceEnvelope` to
Phase 6's opaque provider-neutral `ResourceBudget` without pulling configuration imports into that lower
foundation. Phase 12 separately owns plan-indexed workload/fit/partition/slice evidence.

## Sprints

### Sprint 7.1: The scope vocabulary and scoped codecs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Authority/Internal.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/DhallGenSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceHarnessAuthorityRun.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceHarnessConfigAuthorityRun.hs`
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
- `HarnessAuthority projectId runId` and `HarnessConfigAuthority projectId runId` declare
  `type role ... nominal nominal`, so `Data.Coerce.coerce` cannot re-index either one to another run or
  project without the hidden constructor. The narrow config authority is a nullary opaque proof; root
  authority retains its descriptive name, and narrowing/plaintext construction evaluate the supplied proof.
- `SecretRef scope` is scope-indexed and `TestPlaintext` inhabits only `Harness`, making a plaintext secret in
  production configuration **unrepresentable** rather than excluded by policy — see [rationale.md](rationale.md).
  The `runId` phantom is the run binding; `ScopedTestPlaintext` carries only the `TestSecret`.
- `ProjectCodec scope specDigest cfg` carries a specification digest, so a value decoded under one schema
  cannot be presented under another.
- The only required accessor is `cfgContext`; core reads nothing else out of a project's config.
- `runConfigAssembly` reads each declared input as bytes and decodes it as UTF-8 with `decodeUtf8'`, so the
  admitted text is independent of the process locale and a non-UTF-8 input is a `Left` diagnostic.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`SchemaSpec` 25 cases, `DhallGenSpec` 22, four individual authority/scope negative fixtures,
sealed checks 60, inventory checks 54, and `DocValidatorSpec` 17. The library build and all components
held package `-Werror`.

Both run-coercion fixtures were captured from the actual public-only compiler and reject RunA/RunB
substitution. Existing cross-run plaintext and Harness-as-Production refusals also pass. Plaintext views,
wire rendering, equality, and the descriptive root run-name API remain intact. The narrow proof stores
no unused name; producer/consumer strictness and a specific ErrorCall case prevent a missing authority
thunk from becoming a plaintext reference. The definition inventory excludes the deleted getter.

Production plaintext rejection is exercised with a well-formed actual harness rendering and successful
harness-decode control. Both schema checks catch only Dhall's concrete TypeError Src Void, assert the
TestPlaintext cause, and force the injected rendering before the catch. Raw UTF-8 C3 A9 succeeds under
bracket-restored Latin1; FF bytes produce the exact path-naming refusal. Production scope is three modules.

#### Remaining Work

None.

### Sprint 7.2: The hand-written Dhall vocabulary and its equality witness [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/dhall/Core.dhall`, `core/hostbootstrap-core/dhall/example.dhall`,
`core/hostbootstrap-core/test/DhallGenSpec.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/UpdateConfigArtifactSchema.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/schema.md`, `documents/architecture/dhall_generation.md`,
`documents/engineering/config_generation.md`

#### Objective

Hold the hand-written vocabulary judgmentally equal to the schema the types reflect.

#### Deliverables

- `Core.dhall` is a committed hand-written file, and every type it exports has a judgmental-equality
  witness against the schema of its Haskell codec. Nothing generates the file; `DhallGenSpec` is what
  holds the two in step, and its inventory case derives the Core side automatically so an added or
  removed export cannot leave the comparison stale.
- `Dhall.Gen` provides the one validated codec witness a project extends (`CodecWitness`,
  `mkCodecWitness`, `autoCodecWitness`, `requireCodecWitness`); `Dhall.Hoist` binds each repeated vocabulary
  union once in a top-level `let` of the rendered Dhall.
- A `ConfigArtifact` is built only by `artifactOf` from a `CodecWitness`: `Dhall.Gen` exports
  `artifactName`, `schemaText`, and `renderText` as ordinary accessor functions over unexported fields, so
  record-update syntax cannot replace an artifact's schema or render text and a project cannot register a
  forged artifact in `ProjectSpec`. Eq and the existing record-style Show field order and precedence remain
  unchanged when the internal field names change.
- Schema commands emit snapshots that golden tests pin: both `context schema` outputs byte-for-byte, and the
  `service schema` output through `serviceSchemaOutline`, which keeps its structural marker lines.
- `Core.dhall`'s comments state what the file does: it is the L0 vocabulary that higher layers and
  standalone numeric artifacts import with `let C = ./Core.dhall`; the runtime `<project>.dhall` and the
  single `<project>.test.dhall` are rendered from Haskell codecs and do not import it; `Budget/fitsWithin`
  checks CPU and memory but not storage; only standalone artifacts such as `deployConfigText` output carry
  `assert : C.fitsWithin ... === True`; and the authoritative plan-indexed fit and partition is
  `Cluster.Budget` (`verifyPlannedWorkloadFit`, `withBudgetPartition`).
- Decoding runs in-process; there is no shelled `dhall-to-json` path, because a second decoder is a second
  semantics.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`DhallGenSpec` 29 cases, `SchemaSpec` 25, `UpdateConfigArtifactSchema.hs` 1, sealed checks 60,
inventory checks 54, and `DocValidatorSpec` 17. The library build and components held package `-Werror`.

Six isolated predicates cover each CPU/memory and request/limit boundary; alias-named cases evaluate the
actual quoted Budget aliases. The deploy failure uses the single generated `_fitsBudget` assertion,
catches concrete Dhall TypeError Src Void, and checks structured AssertionFailed with normalized False/True;
the successful deploy control remains. Existing automatic type/non-type export inventory and schema
goldens pass unchanged. The example golden changes only its real Dockerfile path.

An actual admitted Natural artifact pins the three readers, structural Eq, original record Show field
order, precedence 10/11, and Maybe nesting. The public-only GHC fixture imports the real schema reader and
rejects its record update with `Not in scope: record field 'schemaText'`. CLI/command/consumer reads compile
against the same accessor signatures. Only one production Haskell module changed.

#### Remaining Work

None.

### Sprint 7.3: Validated configuration evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Retain the canonical configuration digest in the exact validated value that later plan construction consumes.

#### Deliverables

- `ValidatedConfig scope specDigest configId config` retains both the admitted value and the digest derived
  from its exact canonical bytes.
- Ordinary codec admission and authenticated-wire admission populate that one field from the same bytes that
  mint `VerifiedConfigWire`; no caller supplies an independent digest.
- `withAuthenticatedConfigWire` decodes the authenticated bytes with import resolution closed: a payload
  whose parsed expression contains any import (`./path`, `env:`, or a URL) is refused as
  `ConfigWireCodecRejected` before resolution, so admission reads no file, environment variable, or network
  resource.
- `validatedConfigDigest` observes the retained digest without weakening the scope, specification, or config
  identities.
- `validateProjectConfigForProject` refuses a config whose `project` or whose `binary` differs from the
  Cabal-derived name, each with its own message.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`SchemaSpec` 26 cases, `HandoffSpec` 112, sealed checks 60, inventory checks 54, and
`DocValidatorSpec` 17. The library build and components held package `-Werror`.

Authenticated direct and unused-let environment imports have genuine matching digests and are refused
as `ConfigWireCodecRejected` with the continuation uncalled. The original parsed expression is checked
before normalization, so an unused binding cannot erase the import. Existing canonical admission,
digest substitution, UTF-8, codec, and canonicality controls pass.

Separate project and binary mismatch cases pin each diagnostic. Malformed and wrong-typed records catch
only Dhall TypeError Src Void and name `resources` and `haReplicas`. The scoped writer compares raw bytes
against UTF-8 rendering plus one LF, excludes CR, and retains its decode round trip. Snapshot logging tests
pin the metadata its signature accepts. Production scope is one module.

#### Remaining Work

None.

### Sprint 7.4: Binary context inside the project config [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/dhall_generation.md`

#### Objective

Carry the runtime context inside `<project>.dhall` as parameters plus context plus witness, and let a
command's placement — not the config's own claim — decide which verbs that context hosts.

#### Deliverables

- `BinaryContext` is the descriptive runtime context: the frame this binary occupies, its topology position,
  and its declared role. It is **descriptive only** and authorizes nothing.
- The context lives inside `<project>.dhall`, so there is one file to read rather than a config plus a
  sidecar that can disagree. `Context` exports no standalone context-file reader or writer.
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

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`ContextSpec` 86 cases, `SchemaSpec` 26, `HandoffSpec` 112, sealed checks 60, inventory checks 54,
and `DocValidatorSpec` 17. Library and test builds held package `-Werror`.

The public `withSiblingProjectConfigContext` gate produces exact missing-path/init, invalid UTF-8,
and unauthorized-context diagnostics, exits 1, and leaves the callback uncalled. Each case restores
any original sibling bytes; the successful CLI control does the same. The context module exposes
pure descriptive vocabulary and validation without a standalone file API or unproducible reader errors.

Child projections retain project settings, match each real child kind's capabilities and command classes,
and exclude host-orchestrator commands. The fixture-projector case pins only its declared legal children.
The existing authenticated sibling-install case proves concurrent create-if-absent, idempotence, exact
bytes, and preservation of a conflicting destination through the native hard-link primitive. Production
scope is two modules; the already-correct native primitive needs no edit.

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
**Implementation**: `core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`
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

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`SchemaSpec` 41 cases, `CLISpec` 64, `ContextSpec` 86, five individual builder/scope negative fixtures,
inventory checks 54, and `DocValidatorSpec` 17. Components held package `-Werror`.

The token-derived ordered `ProjectSpec` field list equals its ten declared slots. Every Cabal component's
Haskell sources, including private libraries, executables, tests, and negative fixtures, are scanned for
the forbidden updater identifier after canonical-path deduplication. Comments and strings do not count.
Fifteen parser cases pin grouped/rank-2/nested signatures and field order, retain renamed extra fields,
and refuse missing or ambiguous declarations, sums, GADTs, malformed records, duplicate labels, and empty
types. The parser reuses the shared balanced source toolkit. No production module changes are needed.

Public-only GHC fixtures `RawProjectSpec`, `DispatchUnfinishedBuilder`, `ReplaceProjectContribution`,
`CrossScopeProjectRoot`, and `CoerceFinalizedProjectSpec` each reject their named boundary.

#### Remaining Work

None.

### Sprint 7.7: Runtime installed-identity adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`
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

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`CLISpec` 65 cases, `SchemaSpec` 41, `AuthoritySpec` 243, `HarnessSpec` 47, three individual installed-identity
negative fixtures, sealed checks 60, inventory checks 54, and `DocValidatorSpec` 17. Components held
package `-Werror`.

The mismatch subprocess invokes the actual test executable, declares its name plus `-declared-mismatch`,
and supplies `context path` through `withArgs`. It exits 1 and its stderr names both declared and actual
identities with `does not match the invoked executable`. The matching-name control supplies identical
arguments and returns `Right ()`. Neither case provisions identity files or modifies sibling configs.

Public-only GHC fixtures `EscapeInstalledProjectIdentity`, `ForgeInstalledProjectIdentity`, and
`CoerceInstalledProjectIdentity` each refuse their named boundary. The sealed export checks hold the
executable-verified continuation and exclude the compatibility surface. Production identity propagation
already satisfies the contract; this sprint changes only the test probe and its assertions.

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
  plan-indexed workload-fit proof owned by Phase 12. It computes the same predicate as `Core.dhall`
  `fitsWithin`: total CPU and memory limits within the budget, and every pod's request within its own limit.
  A pod whose request exceeds its limit is refused as `Overflow "cpuRequest" request limit` or
  `Overflow "memoryRequest" request limit`.
- The facade imports no `ProjectPlan`, provider realization, Registry, or cluster lifecycle module.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`CordonSpec` 99 cases, `DhallGenSpec` 29, inventory checks 54, and `DocValidatorSpec` 17.
Library and components held package `-Werror`.

Seven input cases pin exact Haskell outcomes and independently evaluate the committed `Core.dhall`
`fitsWithin` through the real vocabulary codecs: the successful control, CPU/memory total overflows,
CPU/memory request-over-limit refusals, and both request refusals with zero replicas. Each request
refusal names its own dimension and unreplicated values. Total CPU then memory refusal priority remains.

Before the production change, the focused Windows run failed exactly the four invalid-request cases
(4 of 9, 0.06 seconds): each received `Right ()` instead of its expected `Overflow`. After the change,
all nine focused cases pass inside the complete CordonSpec runs on both hosts. Adapter import guards
and vocabulary conversion/preflight controls also pass. Production scope is one module.

#### Remaining Work

None.

### Sprint 7.9: Pure lift-context vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/composition_methodology.md`, `documents/engineering/wsl2.md`

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
- `execVMArgs`, `shellVMArgs`, and `wslExecArgs` are the single pure inner-transport renderers for the
  command fold. The later provider modules reexport them rather than defining another rendering.
- The WSL renderer delivers its argv without the distribution's default shell: `wslExecArgs distro argv` is
  `["-d", distro, "--exec"] ++ argv`, because `wsl -d <distro> -- <argv>` hands the command line to the
  distribution's default shell, which re-parses `&`, `;`, `|`, `$`, `*`, and `'`.
- The module header claims only what the module provides: the command fold renders each VM crossing through
  these three functions. It makes no claim about the lifecycle channel of `Lift.foldLeaf`, whose placement
  Phase 8 owns.
- The module imports no Ensure, resolved-tool, provider-lifecycle, Registry, project-plan, or cluster module.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`LiftContextSpec` 6 cases, `LiftSpec` 28 on Windows / 33 on Linux, `Wsl2Spec` 4, `ProviderSpec` 27,
`RegistrySpec` 21, two individual canonical-mount negative fixtures, inventory checks 54, and
`DocValidatorSpec` 17. Library and components held package `-Werror`.

Pure rendering pins `wslExecArgs "wsl-vm" ["true"]` to `["-d", "wsl-vm", "--exec", "true"]`.
Helper-derived dispatch, nested lift, leaf reachability, provider readiness/shell, and registry-auth
vectors agree. Canonical mounts preserve both False and True read-only flags; actual `inContainer`
output retains its config delivery. Local/outermost-first composition and the lower import/public
exposure guard pass.

Public-only GHC fixtures `RawCanonicalHostMount` and `CrossRootCanonicalHostMount` reject raw and
foreign-root paths. The pure module header and governed docs describe the command-fold renderers and
the separate lifecycle placement contract. Production scope is one module.

#### Remaining Work

None.

### Sprint 7.10: The role vocabulary is derived from the role type [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

The role names a config may declare are one table, derived from the role type. Help text, the refusal
that enumerates valid roles, and the parser read it, so a role added to the sum is a role the
vocabulary already advertises rather than one that exists and cannot be found.

#### Deliverables

- The role sum derives enumeration and bounds, and `allContextKinds` is every constructor.
- The name list is the total renderer mapped over that enumeration.
- `parseConfigRole` resolves a canonical name by lookup over `zip configRoleNames allContextKinds`; the only
  literal table beside it maps the short aliases (`host`, `vm`, `container`, `ad-hoc-container`, `image-build`,
  `service`, `one-shot`, `test`) to kinds. Help text, the refusal, and the parser therefore enumerate the same
  canonical set, and a constructor added to the sum parses under its rendered name with no parser edit.
- A case asserts that every constructor parses from its rendered name and that every alias resolves to its
  kind.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`SchemaSpec` 41 cases, `ContextSpec` 86, `CLISpec` 65, inventory checks 54, and `DocValidatorSpec` 17.
Library and components held package `-Werror`.

Every actual `ContextKind` parses from its `defaultRoleName`; eight independently listed alias/kind
pairs also pass. Canonical lookup uses `zip configRoleNames allContextKinds`, preserving the alias table,
whitespace/case/underscore normalization, and the exact unknown-role diagnostic. In particular,
`ad-hoc-container` retains its VMProjectContainer mapping. Initialization, help, schema, and child-context
controls pass. Context already has the enumeration contract; production scope is one module.

#### Remaining Work

None.

### Sprint 7.11: One existing-output policy for config initialization [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Initialization carries one `ExistingOutputPolicy` with a case per intended behaviour — refuse,
overwrite, keep — so what to do about an output that is already there is a value rather than a pair of
independent switches a caller has to resolve. The value is handed to each project's own builder, so
one published surface means one answer rather than as many as there are downstream projects.

#### Deliverables

- The pair is one policy value: `RefuseExistingOutput`, `OverwriteExistingOutput`, `KeepExistingOutput`.
- The command surface builds it from mutually exclusive options, so the contradictory combination has no spelling and does not parse.
- The write site cases on the policy directly; no expression resolves two booleans into a behaviour.

#### Validation

The host static gate; the command suite covers each policy and the refusal of the combination that no
longer parses. Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal
3.16.1.0, `cabal test all` from `core/` passed with the policy case asserting refuse, overwrite, and
the unparseable pair in turn.

#### Remaining Work

None.

### Sprint 7.12: The scope index determines its descriptive scope tag [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields/Internal.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

The descriptive `ScopeKind` tag a framework envelope reports is a function of the codec's `scope` index, so
the runtime agreement check that authority-bearing dispatch performs can compare a tag the type determined
rather than one a caller chose. This sprint supplies that function as a class. Its consumers are Sprint 7.15's
full-config route here, Phase 12's `frameworkEnvelopeCodec` signature (Sprint 12.38), and Phase 17's
`withFinalizedProjectSpec` and `withFinalizedProjectSpecKernel` (Sprint 17.69), which read the same class;
`withFinalizedServiceRegistry` takes its scope kind from the codec (Phase 22).

#### Deliverables

- A class `KnownScopeKind scope` in `Config.Fields` with the single method
  `scopeKindOf :: proxy scope -> ScopeKind` has exactly two instances, `Production projectId`
  (`ProductionScope`) and `Harness projectId runId` (`HarnessScope`).
- The `Config.Fields` module Haddock states that `FrameworkValidation`, `LocalContextView`, and
  `RuntimeRoleWire` are descriptive records — decodable through `FromDhall` and updatable through their
  exported selectors — and that the sealed path is `ValidatedServiceRequest`/`RoleParams`.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`SchemaSpec` 43 cases, `DhallGenSpec` 29, sealed checks 60, inventory checks 54, and
`DocValidatorSpec` 17. Library and components held package `-Werror`.

Two pure public Fields observations yield ProductionScope for Production FixtureProject and HarnessScope
for Harness FixtureProject (). The class and both instances live together in Fields.Internal and the
public reexport matches the exact sealed inventory. No authority is minted by the descriptive mapping.
The Fields Haddock and generic-model documentation distinguish descriptive decodable/updatable records
from sealed role requests and parameters. Production scope is two modules.

#### Remaining Work

None.

### Sprint 7.13: Placement relations are total and every topology refusal is produced [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

The placement relations in `Context` are closed over every kind, their comments describe what the code
decides, and each `BinaryContextError` constructor is produced by a test. A unique root plus resolvable,
acyclic parent chains implies reachability, so the validator carries no separate reachability pass or error.

#### Deliverables

- Topology admission establishes reachability through the root, parent-resolution, and acyclicity checks.
  Every published topology error corresponds to an observable refusal.
- `requiredAncestorError` lists every `ContextKind` explicitly, so a new constructor forces a decision under
  `-Wall -Werror`.
- `addRole` refuses `ClusterService` as an additional role unless the primary's `contextPlacement` is
  `ClusterDaemonPlacement` or `ClusterServicePlacement`; a host-resident `Daemon` (`HostDaemonPlacement`)
  cannot take `KubernetesAPI` authority.
- `contextErrorMessage` renders each missing and unexpected witness with its kind, name, and, for
  `WitnessEnvEquals`, its value, so a stale `HOSTBOOTSTRAP_CURRENT_FRAME` shows the value each side holds.
- The Haddock of `deriveContainerContext`/`deriveLinuxGpuContainerContext` states that placement follows
  only the parent kind through `placementFor` and that the role label differs; the `ContextPlacement` Haddock
  states that placement is derived from the declared topology and that the required witnesses prove facts
  about the local environment; the `requireLegalChild` comment states that the host-orchestrator to
  `VMProjectContainer` edge is `DirectLinuxGpuContainerPlacement`, gated by that placement's required-witness
  set; and the `-- |` line describing `defaultRoleName` sits above `defaultRoleName`.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`ContextSpec` 89 cases, `SchemaSpec` 43, `CLISpec` 65, sealed checks 60, inventory checks 54,
and `DocValidatorSpec` 17. Library and components held package `-Werror`.

The ghost-parent case pins ParentMissing; three topology cases pin RootCount 0, Cycle x, and
Cycle island-a, with five-second timeouts for the actual cycles. Genuine host and Kubernetes daemon
contexts validate structurally and respectively refuse/permit the additional cluster-service role.
A stale same-key environment witness produces the exact expected/declared mismatch and its diagnostic
includes kind, name, and both values. Runtime witness cases pin and restore wrong/unset environments.

The complete kind-pair matrix forces all 64 decisions; the placement matrix forces all eleven classes
at twelve realized placements and both root flags, including Incus/Lima/WSL VM controls and exact host
root/nonroot decisions. A producer audit covers all twenty remaining BinaryContextError constructors
through real topology/context/runtime/frame/role admission. Unique-root, resolved-parent, acyclic checks
establish reachability directly. Comments and governed docs describe these current relations.
Production scope is one module.

#### Remaining Work

None.

### Sprint 7.14: Config initialization publishes atomically and leaves defaults to the project [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/dhall_generation.md`, `documents/engineering/config_generation.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

`project init` and `service init` decide the `ExistingOutputPolicy` at the moment the output is published,
not against an earlier existence check, so a refused or kept output is never replaced and a killed init never
leaves a truncated `<project>.dhall`; and an omitted `--source-root` reaches the project's own assembler, which
the `Command` module header names as the only place project-config defaults live. The core test fixture's
assembler reaching the assembly-refusal branch is the recursive lifecycle phase's (Sprint 17.68), because its
callers include that phase's `RecursiveLifecycleSpec`.

#### Deliverables

- `Config.Schema` exports `publishScopedProjectConfigFile :: ExistingOutputPolicy -> ProjectCodec scope
  specDigest cfg -> FilePath -> cfg scope -> IO ConfigPublishOutcome` with `ConfigPublished`,
  `ConfigKeptExisting`, and `ConfigRefusedExisting`. It writes the rendered bytes to a
  `.hostbootstrap-config.tmp` temporary file in the output's directory (the `openBinaryTempFile` and
  `linkNoReplace` publication `createSiblingConfig` already uses) and flushes it, and it never writes the
  output path in place; `RefuseExistingOutput` and `KeepExistingOutput` publish with
  `Config.Install.Native.linkNoReplace` and classify a taken name after a failed link by re-inspecting
  the destination, including a dangling link, as the native primitive requires; an absent name propagates
  the original `IOException`. `OverwriteExistingOutput` publishes with an atomic `renameFile`. The temporary is removed in a `finally`
  that catches `IOException`. The public scoped writer is the policy-driven publisher.
- `initParserInfo`'s `initAction` cases on the returned outcome with one alternative per constructor and no
  wildcard; it keeps the existing `already present` message and the `already exists (pass --force to
  overwrite)` refusal, and it carries no separate `doesFileExist` decision.
- `initAction` builds `InitArgs` with `sourceRoot = mroot`, so the project assembler supplies the default; the
  `sourceRoot` field comment in `Config/Class.hs` says "project default when omitted; a relative root resolves
  against the config's anchor directory", and the `initParserInfo` Haddock's "defaultless 'InitArgs'" claim is
  then true.
- The `initParserInfo` Haddock states that root identity provisioning runs after the config is published and
  is not rolled back with it: a provisioning failure leaves the published config, and a rerun with
  `--if-missing` completes provisioning. It does not call the two steps one transaction.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`SchemaSpec` 55 cases, `ContextSpec` 89, `CLISpec` 65, sealed checks 60, inventory checks 54,
and `DocValidatorSpec` 17. Library and components held package `-Werror`.

Fifty concurrent publication rounds start two genuine codec writers together. Bounded, bracketed workers
produce exactly one publication and one refusal; the output equals that winner's canonical bytes, and
only the output remains in each directory. Refuse/Keep preserve an existing arbitrary binary payload;
Overwrite installs the complete new rendering. Every case checks temporary cleanup.

A balanced definition-token guard excludes in-place writing from the publisher; nine parser cases cover
real nested writes, comments/literals, neighboring declarations, signatures, and malformed or ambiguous
bodies. The exact public export inventory matches the outcome/publisher API. An actual CLI init from a
different working directory leaves the omitted root as the fixture assembler's dot, and existing keep
behavior passes. Documentation separates publication from later identity provisioning and its retry.
Production scope is three modules.

#### Remaining Work

None.

### Sprint 7.15: Project lifecycle and check-code admit only a full project wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/CrossScopeProjectRoot.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/config_generation.md`

#### Objective

Every existing-frame route that reads the sibling `<project>.dhall` for project lifecycle or ordinary
`check-code` discriminates the wire kind before it chooses a second-stage decoder (§ Q). A file that holds
a `ServiceRoleWire` receives a structured wrong-command refusal naming the wire kind, not a malformed-config
decode error, and the full-config route goes through `FrameworkEnvelopeCodec` so the envelope type has its
production caller. It follows Sprint 7.12, whose `KnownScopeKind` supplies the envelope's scope tag. Phase 20's
`context` route (Sprint 20.8) runs the same check before its Production decode and depends on a file without a
framework record reaching that decoder, because a full project wire of either scope carries none.

#### Deliverables

- `Config.Fields` exports a first-stage envelope check that reads only the descriptive framework record a role
  wire carries (`roleFrameworkValidation`), without invoking a `ProjectCodec` or `RoleCodec`, and reports
  `ServiceRoleWire` when the file carries that record declaring it and `FullProjectWire` otherwise. The full
  project wire carries no framework record, so a file without one is a full project wire, whatever its other
  fields hold, and whether it decodes is the second-stage `ProjectCodec`'s judgement: an undecodable file keeps
  that decoder's diagnostic.
- `withSiblingProjectConfigRoot` (and so `withSiblingProjectConfigContext`,
  `withSiblingValidatedProjectConfigContext`, and `withSiblingValidatedProjectConfigRoot`, which the
  lifecycle verbs and `check-code` use) runs that check before `decodeProjectCodecWithSettings`; a
  `ServiceRoleWire` is refused with `project config: <path> holds a service role wire; this command requires
  a full project config` and exit code 1, and the continuation does not run.
- The full-config route decodes through `frameworkEnvelopeCodec`, and the admitted config's
  `inspectFullConfig` reports `FullProjectWire`, the codec's scope kind, and its specification digest. The
  envelope decoder delegates to its retained scoped codec with the same source/root input settings;
  `KnownScopeKind` supplies the descriptive tag at each sibling gate.

#### Validation

On 2026-10-27, native Windows 11 x86_64, GHC 9.12.4/Cabal 3.16.1.0, passed unfiltered
`cabal test all` from `core/` (3,026 core cases, 539.49 seconds) and from `demo/` (164 consumer cases,
5.81 seconds, plus 3,026 dependency core cases, 545.68 seconds). All declared suites exited successfully.
The native-filesystem Ubuntu 24.04.4 x86_64 CPU container passed unfiltered `cabal test all` from `core/`
(3,033 cases, 417.64 seconds) and all declared suites. Package `-Werror` held throughout.

The other host static legs passed: `poetry run python -m hostbootstrap.check_code` (Ruff/Black/mypy,
twelve modules) and `poetry run python -m hostbootstrap.test_all` (376 cases, 7.12 seconds, 100% coverage
of 1,585 statements and 460 branches). Focused runs on both Haskell hosts also passed SchemaSpec 58,
ContextSpec 90, CrossScopeProjectRoot 1, sealed checks 60, inventory 54, and DocValidatorSpec 17.

A genuine finalized service registry supplies the rendered role wire used by the classifier and both
public sibling/actual CLI check-code refusals. Exact diagnostics, exit 1, untouched callbacks, and
unchanged sibling bytes distinguish the wire refusal from decoder failure. Full configs decode through
the retained envelope codec and report the actual wire kind, scope tag, and specification digest.
Nested/comment/string/unused-binding spoofs and malformed framework/input controls preserve the full
route. Existing missing, UTF-8, context-refused, lifecycle, and consumer controls pass.

The public-only compiler rejects the adapted CrossScopeProjectRoot fixture only for ConfigScope versus
ForeignScope, preserving the original boundary despite the new dictionary requirement. Input source/root
settings are forwarded unchanged to both stages. Production scope is three modules.

#### Remaining Work

None.

### Sprint 7.16: The bare init builder ends an assembly refusal through `die` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

The bare and project entrypoints interpret an assembler's refused init result as a normal CLI refusal.
The existing diagnostic reaches standard error with exit status 1 before any config publication.

#### Deliverables

- The bare init builder ends the process through `die` with the refusal's message on standard error and exit
  status 1, and writes no output file. Neither entrypoint lets an assembly refusal escape as an `IOError`.

#### Validation

On 2026-10-27, native Windows 11 x86_64, GHC 9.12.4/Cabal 3.16.1.0, passed unfiltered
`cabal test all` from `core/` (3,028 core cases, 542.22 seconds) and from `demo/` (164 consumer cases,
5.77 seconds, plus 3,028 dependency core cases, 537.18 seconds). Every declared suite exited 0.
The native-filesystem Ubuntu 24.04.4 x86_64 CPU container passed unfiltered `cabal test all` from `core/`
(3,035 cases, 426.32 seconds) and every declared suite. Package `-Werror` held throughout.

The other host static legs passed: `poetry run python -m hostbootstrap.check_code` (Ruff/Black/mypy,
twelve modules) and `poetry run python -m hostbootstrap.test_all` (376 cases, 7.76 seconds, 100% coverage
of 1,585 statements and 460 branches). Focused CLI and documentation groups also passed.

The bare-init regression supplies the exact incompatible-role argv under a temporary working directory,
catches only ExitCode, and pins ExitFailure 1 plus the original refusal on stderr. The temporary directory
stays empty, and all six actual executable sibling images (config and identities) remain byte-identical.
The positive explicit-output control succeeds with one complete config and the same untouched siblings.
The scoped restoration/capture helpers preserve original bytes and standard handles without printing keys.
The typed negative control demonstrated the refusal distinction before the one-line builder change.
Production scope is one module.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/generic_project_model.md` — the generic spec, scoped codecs, and no-core-defaults
  contract.
- `documents/architecture/dhall_generation.md` — the hand-written `Core.dhall` held judgmentally equal to
  the codec schemas by `DhallGenSpec`, and runtime configs rendered from their codecs.
- `documents/architecture/binary_context_config.md` — parameters plus context plus witness in one file.
- `documents/architecture/hostbootstrap_core_library.md` — the pure lift-context module boundary.
- `documents/architecture/composition_methodology.md` — context data beneath generic dispatch.

**Engineering docs to create/update:**
- `documents/engineering/authoring_project_binaries.md` — the surface this phase changes in it.
- `documents/engineering/schema.md` — the schema commands and golden snapshots.
- `documents/engineering/config_generation.md` — how a project declares its vocabulary.
- `documents/engineering/resource_budgeting.md` and `documents/engineering/applied_cordon.md` — the
  configuration facade over the lower provider-neutral budget foundation.

**Cross-references to add:**
- `development_plan_standards.md` §§ O, Q, U, and BB name this phase as the owner of the configuration-facing
  cordon adapter, configuration contracts, and pure lift-context vocabulary.
