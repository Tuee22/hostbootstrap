# Phase 7 — Dhall configuration and the generic project model

**Status**: Active
**Depends on**: Phase 6 (canonical quantities and reconcile results)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`, including the schema golden tests
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

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

### Sprint 7.1: The scope vocabulary and scoped codecs [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Authority/Internal.hs`,
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
- `HarnessAuthority projectId runId` and `HarnessConfigAuthority projectId runId` declare
  `type role ... nominal nominal`, so `Data.Coerce.coerce` cannot re-index either one to another run or
  project without the hidden constructor.
- `SecretRef scope` is scope-indexed and `TestPlaintext` inhabits only `Harness`, making a plaintext secret in
  production configuration **unrepresentable** rather than excluded by policy — see [rationale.md](rationale.md).
  The `runId` phantom is the run binding; `ScopedTestPlaintext` carries only the `TestSecret`.
- `ProjectCodec scope specDigest cfg` carries a specification digest, so a value decoded under one schema
  cannot be presented under another.
- The only required accessor is `cfgContext`; core reads nothing else out of a project's config.
- `runConfigAssembly` reads each declared input as bytes and decodes it as UTF-8 with `decodeUtf8'`, so the
  admitted text is independent of the process locale and a non-UTF-8 input is a `Left` diagnostic.

#### Validation

`SchemaSpec` covers each scope, the codec round trip, and the plaintext-secret exclusion; `CompileFailSpec`
carries `CrossRunPlaintext.hs` and `HarnessConfigAsProduction.hs` as the type-level refusals. The sprint
closes when these also exist and pass under `cabal test all` from `core/`:

- `CompileFailSpec` entries `CoerceHarnessAuthorityRun.hs` and `CoerceHarnessConfigAuthorityRun.hs`, each
  `coerce`-ing the authority from `RunA` to `RunB` and rejected with
  "Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'".
- The `DhallGenSpec` case "production schema omits and rejects TestPlaintext" decodes a well-formed harness
  rendering of `V.HarnessTestPlaintext "hunter2"` through the production codec and catches the Dhall type
  error specifically (not `SomeException`), asserting it names `TestPlaintext`.
- The `SchemaSpec` case "secrets-strict production codec omits and rejects TestPlaintext" forces `injected`
  with `evaluate` before the `try`, asserts that `injected` contains the text `TestPlaintext`, and catches the Dhall
  type error specifically.
- A `SchemaSpec` case "ConfigAssembly decodes a declared input as UTF-8 under any locale" writes the UTF-8
  bytes of `"é"`, runs `runConfigAssembly` with `setLocaleEncoding latin1` in a `bracket` that restores the
  prior encoding, and asserts `Right "é"`; a second input of the bytes `[0xff]` yields a `Left` naming the
  path.

#### Remaining Work

- Add `{-# LANGUAGE RoleAnnotations #-}`, `type role HarnessAuthority nominal nominal`, and
  `type role HarnessConfigAuthority nominal nominal` to `Config/Authority/Internal.hs`; add the two
  `compile-fail/` fixtures and their `CompileFailSpec` entries named under Validation.
- Drop the `Text` field from `ScopedTestPlaintext` in `Config/Vocab.hs` (it is never read: `secretRefView`,
  `harnessSecretRefWire`, `Eq`, and `Show` discard it), delete `harnessConfigRunName` from
  `Config/Authority/Internal.hs`, and keep `testPlaintextSecret`'s `HarnessConfigAuthority` argument so the
  phantom remains the binding.
- Delete the two orphan `-- |` comments in `Config/Vocab.hs` ("The historical substrate vocabulary exported
  by @Core.dhall@" and "Production or named test cluster profile"); no such type exists.
- Replace `TIO.readFile` in `runConfigAssembly` (`Config/Class.hs`) with `BS.readFile` plus
  `TE.decodeUtf8'`, returning `Left "config assembly could not decode <path> as UTF-8"` on a decode failure;
  add the locale case under Validation.
- Rewrite the two plaintext-rejection cases as Validation states, and rename the `DhallGenSpec` case
  "scoped plaintext requires matching rank-2 harness authority" to "scoped plaintext under harness authority
  views as TestPlaintext", with a comment pointing at `CrossRunPlaintext.hs` and
  `HarnessConfigAsProduction.hs` as the refusal evidence.

### Sprint 7.2: The hand-written Dhall vocabulary and its equality witness [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Dhall/Hoist.hs`,
`core/hostbootstrap-core/dhall/Core.dhall`, `core/hostbootstrap-core/dhall/example.dhall`,
`core/hostbootstrap-core/test/DhallGenSpec.hs`, `core/hostbootstrap-core/test/golden/`
**Substrates**: none
**Docs to update**: `documents/engineering/schema.md`, `documents/architecture/dhall_generation.md`

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
  forged artifact in `ProjectSpec`.
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

`DhallGenSpec` plus the golden snapshots. A change to a Haskell codec that the hand-written `Core.dhall` does
not mirror fails `DhallGenSpec`'s judgmental-equality witness, and a changed schema-command output fails its
golden.
The sprint closes when these `DhallGenSpec` cases also exist and pass under `cabal test all` from `core/`:

- `fitsWithin` cases for CPU over with memory under (`False`), memory over with CPU under (`False`), totals
  exactly on the budget (`True`), requests under the budget with limits over it (`False`), and a memory
  request above its own memory limit with CPU in order (`False`).
- At least one case each evaluates ``C.`Budget/fitsWithin` `` and ``C.`Budget/split` `` rather than the bare
  names, and the cases named for the aliases call the aliases.
- "an over-budget deploy config fails to type-check" catches the Dhall type error specifically and asserts
  that it is the assertion failure on `_fitsBudget`.
- `CompileFailSpec` entry `UpdateConfigArtifactSchema.hs`, which applies
  `artifact{schemaText = "Bool"}` to an element of `coreArtifacts`, is rejected with GHC's diagnostic that
  `schemaText` is not a record field; the existing `artifactName`/`schemaText`/`renderText` reads in
  `DhallGenSpec`, `CLI.hs`, `Command.hs`, and demo `CommandsSpec` compile unchanged against the accessor
  functions.

#### Remaining Work

- Rewrite the `Core.dhall` header (lines 3-11) and the comments on `requestsWithinLimits` and `fitsWithin`
  to the statements in Deliverables; name `example.dhall` in the header as the byte-exact
  `renderProjectConfig` golden whose `ContextKind`/`ProviderKind`/`CommandClass` unions are context unions,
  not `Core.dhall` exports.
- Change the `dockerfile` of the `SchemaSpec` `expected` fixture and of `example.dhall` from
  `docker/demo.Dockerfile`, which does not exist, to the demo's real `docker/Dockerfile`.
- Add the `DhallGenSpec` cases listed under Validation; delete the "fails to type-check here" comment in
  the request-over-limit case, which asserts a `Bool`.
- In `Dhall/Gen.hs`, rename the `ConfigArtifact` fields to unexported internal labels and export
  `artifactName`, `schemaText`, and `renderText` as plain functions (`NoFieldSelectors` does not close the
  gap, because an exported field still admits record update); add the `UpdateConfigArtifactSchema.hs`
  fixture and its `CompileFailSpec` entry.

### Sprint 7.3: Validated configuration evidence [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`
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

`SchemaSpec` covers ordinary and authenticated admission, exact digest retention, and byte substitution
refusal; `HandoffSpec` covers the digest, UTF-8, codec, and canonicality refusals of authenticated admission.
The sprint closes when these cases also exist and pass under `cabal test all` from `core/`:

- `HandoffSpec`: an authenticated payload whose digest is valid and whose text is `env:HOSTBOOTSTRAP_PROBE`
  (with that variable set to a canonical config) is refused as `Left ConfigWireCodecRejected`.
- `SchemaSpec`: `validateProjectConfigForProject "demo"` on `expected` with `binary = "other"` returns
  `Left "project config: expected binary demo, got other"`.
- `SchemaSpec` "a malformed config fails with a typed error" and "a wrong-typed field fails with a typed
  error" catch the concrete Dhall exception type rather than `SomeException` and assert that its message
  names the offending field (`resources`, `haReplicas`).
- `SchemaSpec` "the scoped writer produces exactly the bytes the ownership protocol installs" reads the file
  with `BS.readFile`, compares it with `TE.encodeUtf8 (renderProjectConfig expected <> "\n")`, and asserts the
  bytes contain no `\r`.

#### Remaining Work

- Make `withAuthenticatedConfigWire` parse the payload with `Dhall.Parser` and refuse any expression containing
  an `Embed` (import) node before calling `decodeProjectCodecWithSettings`; add the `HandoffSpec` case.
- Add the binary-mismatch case and rewrite the three `SchemaSpec` cases as Validation states.
- Delete the `SchemaSpec` assertion "config content is not logged": `renderProjectConfigSnapshotLog` takes a
  path, a hash, and a `BinaryContext`, never the config text, so the assertion cannot fail; the signature is
  the guarantee, and a comment on the case says so.

### Sprint 7.4: Binary context inside the project config [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Install/Native.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

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

`ContextSpec` covers derivation, the witness check, the per-frame refusal, the forged-leaf refusal for both
lifecycle verbs, the non-root refusal of the unwind, the root-kind refusal of a non-host root, and the
closure of `placementAllowsCommand` over every placement and class. `cabal test all --ghc-options=-Werror`
from `core/` passed 935/935 on 2026-08-05 (aarch64-osx, GHC 9.12.4).

The sprint closes when these cases also exist and pass under `cabal test all` from `core/`:

- `ContextSpec` "normal CLI commands fail fast when the sibling context is absent" removes the sibling
  `<project>.dhall` (restoring any prior bytes afterwards in a `bracket`) before calling
  `Schema.withSiblingProjectConfigRoot` with a continuation that sets an `IORef`; with `stderr` redirected to a
  temporary handle through `hDuplicate`/`hDuplicateTo`, it asserts `Left (ExitFailure 1)`, that the
  continuation never ran, and that the captured stderr is exactly
  ``project config: missing <path>; run `<project> project init` `` for the sibling path.
- `ContextSpec` holds no case for the standalone context-file API: the render/decode round trip,
  `readContextFile` missing and decode-failure, `writeContextFile`, `withValidatedContext`, and
  `requireContextFile` cases are gone with the functions, and the gate's absent, undecodable, and
  context-refused branches are each asserted through `Schema.withSiblingProjectConfigRoot` with the
  continuation shown not to run.
- `SchemaSpec` "child projections preserve project settings and narrow authority" asserts
  that `capabilities` and `allowedCommandClasses` of `context vm` equal those of
  `contextForKind "demo" "demo" "/vm/demo" VMOrchestrator`, the same two equalities for `service` against
  `ClusterService`, and that neither child's command classes contain `HostOrchestratorCommand`.
- `SchemaSpec` "child projection rejects direct host-to-runtime-container configs", whose refusal string comes
  from the test `Fixture`'s own guard, is renamed to say it checks the fixture projector and asserts only that
  `childContextKinds (context host)` does not contain `VMProjectContainer`.

#### Remaining Work

- Rewrite the two `SchemaSpec` child-projection cases as Validation states.
- Delete `readContextFile`, `writeContextFile`, `decodeContextFile`, `decodeContextText`, `renderContext`,
  `readAndValidateContextFile`, `requireContextFile`, and `withValidatedContext` from `Context.hs` and its
  export list; none has a caller in core `src`/`app` or the demo, the live gate is
  `Schema.withSiblingProjectConfigRoot`, and the locale-encoded `TIO.writeFile` and the `SomeException` catch
  that maps `UserInterrupt` to `ContextDecodeFailed` go with them. Delete their six `ContextSpec` cases, rewrite
  the `writeProjectConfigFile` Haddock in `Config/Schema.hs` so it names only `Context.vocabUnions`, and add
  the `withSiblingProjectConfigRoot` absent/undecodable/context-refused cases under Validation.
- Rewrite the `ContextSpec` missing-sibling case as Validation states.

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

### Sprint 7.6: Identity-parametric project specification [Active]

**Status**: Active
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
generic builder, shared scope, and absence of core defaults. The sprint closes when the `SchemaSpec` case
"scope API removes the raw context updater and parallel config builders" reads `ProjectSpec`'s field names
from the token stream of `CLI.hs` (`SourceGuard.haskellTokens`) and asserts they equal the exact list
`psTestSuite`, `psCheckCode`, `psArtifacts`, `psTestCodec`, `psAssemblyInputs`, `psServices`, `psStepPlan`,
`psForwardChildPlan`, `psTestInit`, `psAssemble`, and asserts the identifier `cfgWithContext` occurs nowhere in the package sources,
and passes under `cabal test all` from `core/`.

#### Remaining Work

- Replace the four exact-substring checks in that `SchemaSpec` case (`psInit ::`, `psTestConfig ::`,
  `psAssemble ::`, `cfgWithContext`), which a second space, a split signature, or a renamed parallel builder
  evades, with the token-level field-set and identifier checks under Validation.

### Sprint 7.7: Runtime installed-identity adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `core/hostbootstrap-core/test/CLISpec.hs`,
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

`CLISpec`, `SchemaSpec`, `AuthoritySpec`, and `HarnessSpec` cover the matching runtime identity and its
propagation through Production and Harness construction. Compile-fail and exposed-module guards prove that an
installed identity cannot escape, be substituted across two invocations, or be reconstructed through a
compatibility module. The complete phase gate passes.

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1090/1090 on
2026-08-08 (aarch64-osx, GHC 9.12.4), including all 71 public compile-fail boundaries. The integrated
consumer gate `cabal test all --ghc-options=-Werror` from `demo/` also passed the demo's 123/123 cases and
the dependency core suite.

`AuthoritySpec` "installed identity refuses a different declared project" covers the kernel refusal. The
CLI-level case "runtime executable identity must match the declared project" in `CLISpec` calls
`CLI.runHostBootstrapCLI` without `withArgs`, so the tasty runner's own argv fails parsing with the same
`ExitFailure 1` and the case would pass with the identity check removed. The sprint closes when, under
`cabal test all` from `core/`:

- the mismatch case runs `CLI.runHostBootstrapCLI` with the declared name `<actual>-declared-mismatch` under
  `withArgs ["context", "path"]`, in a probe subprocess of the test executable (a new `Spec.hs` probe
  branch), and asserts exit code 1 and that the probe's stderr contains
  `does not match the invoked executable`;
- a positive control runs the same call with the actual executable name under the same `withArgs` and
  returns `Right ()`.

#### Remaining Work

- In `CLISpec`, rewrite "runtime executable identity must match the declared project" as the probe-subprocess
  case under Validation, add the `Spec.hs` probe branch it launches, and add the actual-name positive control
  under `withArgs ["context", "path"]`.

### Sprint 7.8: Configuration-facing cordon facade [Active]

**Status**: Active
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

`CordonSpec` covers Resources/`ResourceEnvelope` conversion, wrapper equivalence with the lower foundation,
and descriptive `fitsBudget` outcomes. A source guard pins the adapter direction and the absence of later
plan/provider/cluster imports. The sprint closes when these `CordonSpec` cases also exist and pass under
`cabal test all` from `core/`: `fitsBudget (V.Budget 4 8 20) [V.PodResources 1 4 1 1 1]` returns
`Left (Overflow "cpuRequest" 4 1)`; `fitsBudget (V.Budget 4 8 20) [V.PodResources 1 1 1 4 1]` returns
`Left (Overflow "memoryRequest" 4 1)`; and `fitsBudget` agrees with `C.fitsWithin` evaluated from `Core.dhall`
on each of those inputs and on the three existing ones.

#### Remaining Work

- Add the requests-within-limits refusal to `fitsBudget` in `Cluster/Cordon.hs` and the `CordonSpec` cases
  under Validation.

### Sprint 7.9: Pure lift-context vocabulary [Active]

**Status**: Active
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
- `execVMArgs`, `shellVMArgs`, and `wslExecArgs` are the single pure inner-transport renderers for the
  command fold. The later provider modules reexport them rather than defining another rendering.
- Each renderer delivers its argv without a guest shell: `wslExecArgs distro argv` is
  `["-d", distro, "--exec"] ++ argv`, because `wsl -d <distro> -- <argv>` hands the command line to the
  distribution's default shell, which re-parses `&`, `;`, `|`, `$`, `*`, and `'`.
- The module header claims only what the module provides: the command fold renders each VM crossing through
  these three functions. It makes no claim about the lifecycle channel of `Lift.foldLeaf`, whose placement
  Phase 8 owns.
- The module imports no Ensure, resolved-tool, provider-lifecycle, Registry, project-plan, or cluster module.

#### Validation

`LiftContextSpec` covers the local context, outermost-first append order, all three provider target records,
exact inner transport argv, container/config-delivery data, and same-root canonical mounts. Compile-fail
fixtures reject raw paths and a path from another root. A source guard pins the lower import boundary and the
public Cabal exposure.

Dated evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), focused `CordonSpec` plus `LiftContextSpec`
passed 61/61 under `-Werror`, the two canonical-mount compile-fail cases passed 2/2, and the exact phase gate
`cabal test all --ghc-options=-Werror` from `core/` passed 1464/1464, including the schema golden tests.

The sprint closes when, under `cabal test all` from `core/`, `LiftContextSpec` "one pure renderer owns each
VM transport" asserts `wslExecArgs "wsl-vm" ["true"] @?= ["-d", "wsl-vm", "--exec", "true"]`; the canonical
mount case runs once with `readOnly = False` and once with `readOnly = True` and asserts the flag reaches the
`Mount`; and the "config delivery remains descriptive context data" case, which repeats the composition case,
is deleted or replaced by one that asserts `clConfigDelivery` survives `inContainer` unchanged.

#### Remaining Work

- Render `wslExecArgs` with `--exec` in `Lift/Context.hs` and update the `LiftContextSpec` argv case.
- Rewrite the `Lift/Context.hs` module header to the boundary stated in Deliverables.
- Add the `readOnly = True` row to the canonical-mount case and replace the redundant config-delivery case, as
  Validation states.

### Sprint 7.10: The role vocabulary is derived from the role type [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
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

The host static gate. Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and
Cabal 3.16.1.0, `cabal test all` from `core/` passed 2,519 tests.

The sprint closes when, under `cabal test all` from `core/`, `SchemaSpec` "the advertised role set is the
accepted role set" asserts `parseConfigRole (T.unpack (defaultRoleName k)) @?= Right k` for every `k` in
`allContextKinds` and asserts each alias against its expected kind, and carries neither of the two lines that
restate `configRoleNames`'s definition (`map defaultRoleName allContextKinds @?= configRoleNames` and the
length equality).

#### Remaining Work

- Rewrite `parseConfigRole` in `Config/Schema.hs` so canonical names resolve through the derived table and
  only the aliases are listed literally, keeping the refusal text.
- Rewrite the `SchemaSpec` role-set case as Validation states.

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

None. Publishing the init output atomically under this policy is Sprint 7.14's.

### Sprint 7.12: The scope index determines its descriptive scope tag [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields/Internal.hs`
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

The sprint closes when `cabal test all` from `core/` passes with `KnownScopeKind` defined in
`Config/Fields/Internal.hs` and re-exported from `Config/Fields.hs`, and Sprint 7.15's admitted full config
reports the codec's scope kind through it.

#### Remaining Work

- Add `KnownScopeKind` with its `scopeKindOf` method and two instances to `Config/Fields/Internal.hs` and
  re-export the class and method from `Config/Fields.hs`.
- Rewrite the `Config/Fields.hs` module Haddock as Deliverables states.

### Sprint 7.13: Placement relations are total and every topology refusal is produced [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

The placement relations in `Context` are closed over every kind, their comments describe what the code
decides, and each `BinaryContextError` constructor is produced by a test.

#### Deliverables

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

The sprint closes when these `ContextSpec` cases exist and pass under `cabal test all` from `core/`:

- One root and a child whose `topologyParentId` is `"ghost"`:
  `validateTopology ctx @?= Left (ContextTopologyParentMissing child "ghost")`.
- `addRole ClusterService` on a `Daemon`/`HostProvider` context returns
  `Left (ContextRoleAdditionRefused Daemon ClusterService)`, and on a `Daemon`/`KubernetesProvider` context
  returns `Right`.
- A context whose declared `HOSTBOOTSTRAP_CURRENT_FRAME` witness value is stale renders a
  `ContextWitnessSetMismatch` message containing both the expected and the declared value.
- The topology termination cases pin the constructor the validator's check order produces:
  "a cyclic parent chain is refused instead of diverging" asserts `Left (ContextTopologyRootCount 0)`,
  "a cycle below a real root is refused, not walked forever" asserts `Left (ContextTopologyCycle "x")`, and
  the island case, renamed "a detached two-frame cycle is refused", asserts
  `Left (ContextTopologyCycle "island-a")`. The two cycle cases run under `localOption (mkTimeout 5000000)`, so
  a lost visited-set guard fails by name instead of hanging the gate.
- "a daemon primary cannot union project or host-orchestrator authority" carries no second
  `addRole HostOrchestrator` block; it asserts `addRole OneShotJob daemon` and `addRole VMProjectContainer
  daemon` return `Left (ContextRoleAdditionRefused Daemon OneShotJob)` and
  `Left (ContextRoleAdditionRefused Daemon VMProjectContainer)`.
- "wrong-frame daemon witness fails before daemon dispatch" runs inside
  `withEnvironmentValue "HOSTBOOTSTRAP_CURRENT_FRAME" (Just "host-orchestrator-0")` with the derived required
  witness set, and asserts `ContextRuntimeWitnessFailed` whose detail contains
  `environment HOSTBOOTSTRAP_CURRENT_FRAME was "host-orchestrator-0"`; the env-decides half of
  "validateRuntimeContext verifies the derived witness set, not a declared one" runs inside
  `withEnvironmentValue "HOSTBOOTSTRAP_CURRENT_FRAME" Nothing` and asserts the detail contains `is unset`.
- "roleAdditionAllowed is closed over every kind pair" draws both sides from `allContextKinds`, and
  "placementAllowsCommand is closed over every placement and class" evaluates every placement and class at
  both `atRoot` values and asserts `placementAllowsCommand HostOrchestratorPlacement False
  HostOrchestratorCommand @?= False` beside `placementAllowsCommand HostOrchestratorPlacement True
  HostOrchestratorCommand @?= True`.

#### Remaining Work

- Make `requiredAncestorError` exhaustive, add the placement check to `addRole`, and render witness values in
  `contextErrorMessage` (`Context.hs`).
- Rewrite the four comments listed in Deliverables.
- Add the three `ContextSpec` cases under Validation.
- In `ContextSpec`, pin the three topology termination constructors and wrap the two cycle cases in a tasty
  timeout; replace the dead second `addRole HostOrchestrator daemon` block with the `OneShotJob` and
  `VMProjectContainer` refusals; pin `HOSTBOOTSTRAP_CURRENT_FRAME` in both daemon witness cases; and iterate
  `allContextKinds` and both `atRoot` values in the two closure cases, all as Validation states.

### Sprint 7.14: Config initialization publishes atomically and leaves defaults to the project [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/dhall_generation.md`, `documents/engineering/config_generation.md`

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
  `Config.Install.Native.linkNoReplace` and map an already-exists failure to their outcome, and
  `OverwriteExistingOutput` publishes with an atomic `renameFile`. The temporary is removed in a `finally`
  that catches `IOException`. The truncating `writeScopedProjectConfigFile`, whose only caller is
  `initAction`, is absent from `Config.Schema` and its export list.
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

The sprint closes when these cases exist and pass under `cabal test all` from `core/`:

- `SchemaSpec` "init publication refuses under a concurrent peer": two threads call
  `publishScopedProjectConfigFile RefuseExistingOutput` on one absent path with two different fixture
  configs, both blocked on a shared start `MVar ()`, repeated 50 times; each round yields exactly one
  `ConfigPublished` and one `ConfigRefusedExisting`, and the file's bytes equal the winner's
  `renderScopedProjectConfigBytes`.
- `SchemaSpec`: `RefuseExistingOutput` on an existing file returns `ConfigRefusedExisting` and
  `KeepExistingOutput` returns `ConfigKeptExisting`, each with the file's bytes unchanged;
  `OverwriteExistingOutput` returns `ConfigPublished` with the new bytes; after every case the directory holds
  only the output file and no `.hostbootstrap-config*.tmp` file.
- A `SchemaSpec` source guard asserts that `publishScopedProjectConfigFile`'s definition in `Config/Schema.hs`
  names no `BS.writeFile`.
- `ContextSpec`: `project init --output <dir>/<project>.dhall` with no `--source-root`, run under
  `withCurrentDirectory` of a different temporary directory, writes a config whose `Context.sourceRoot` is the
  fixture assembler's `"."`, not that working directory.
- The existing `ContextSpec` "project init --if-missing writes when absent and is a no-op when present" case
  still passes unchanged.

#### Remaining Work

- Add `ConfigPublishOutcome` and `publishScopedProjectConfigFile` to `Config/Schema.hs` and route
  `initAction` in `Command.hs` through it with an exhaustive outcome case; delete
  `writeScopedProjectConfigFile` and its export; add the `SchemaSpec` publication cases and the `BS.writeFile`
  source guard.
- Pass `sourceRoot = mroot` in `initAction`, drop its `getCurrentDirectory` call, rewrite the `sourceRoot`
  field comment in `Config/Class.hs`, and add the `ContextSpec` working-directory case.
- Rewrite the `initParserInfo` Haddock's provisioning sentence as Deliverables states.

### Sprint 7.15: Project lifecycle and check-code admit only a full project wire [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
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
  `inspectFullConfig` reports `FullProjectWire`, the codec's scope kind, and its specification digest.

#### Validation

The sprint closes when these pass under `cabal test all` from `core/` and from `demo/`:

- A core case applies the first-stage check to a rendered full project config, which carries no framework
  record, and asserts `FullProjectWire`, and to a rendered role wire and asserts `ServiceRoleWire`.
- A core case writes a rendered role wire (`renderRoleWire` of a fixture `RoleCodec`) at the sibling path
  and calls `Schema.withSiblingProjectConfigRoot` with a continuation that sets an `IORef`; with stderr
  captured through `hDuplicate`/`hDuplicateTo`, it asserts `Left (ExitFailure 1)`, that the continuation
  never ran, and that stderr contains `holds a service role wire` and not `failed to decode`.
- The same role wire under `withArgs ["check-code"]` is refused with the same message before the check
  action runs.
- Every existing sibling-config case (absent, undecodable, context-refused, and the admitted lifecycle
  paths) passes unchanged.

#### Remaining Work

- Add the first-stage envelope check to `Config/Fields.hs` and call it from `withSiblingProjectConfigRoot`
  in `Config/Schema.hs` before the second-stage decode, routing the full-config decode through
  `frameworkEnvelopeCodec`.
- Add the classification case and the role-wire refusal cases for the lifecycle seam and `check-code` named
  under Validation.

### Sprint 7.16: The bare init builder ends an assembly refusal through `die` [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Both entrypoints report a refused `project init` assembly the same way. `runHostBootstrapCLI`'s
`initBuilder` ends the process through `die`; `runBareHostBootstrapCLI` wraps `bareInit` in `either fail
pure`, so the same refusal on the bare binary surfaces as an `IOError` (`user error (...)`).

#### Deliverables

- The bare init builder ends the process through `die` with the refusal's message on standard error and exit
  status 1, and writes no output file. Neither entrypoint lets an assembly refusal escape as an `IOError`.

#### Validation

Closure requires a `CLISpec` case "the bare init builder refuses an incompatible added role through die",
which runs `runBareHostBootstrapCLI` under `withArgs ["project", "init", "--also-role", "cluster-service"]` in
a temporary working directory, catches the result as an `ExitCode` (not an `IOException`), asserts
`ExitFailure 1`, and asserts that no generated config file exists in that directory afterwards, passing under
`cabal test all` from `core/`.

#### Remaining Work

- In `runBareHostBootstrapCLI` (`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`), replace the init
  builder `either fail pure . bareInit progName invocationRoot` with `either die pure`, matching
  `runHostBootstrapCLI`'s `initBuilder`. A `Left` from `bareInit` (for example
  `ContextRoleAdditionRefused` from `Context.addRole ClusterService` over a host-orchestrator context)
  then exits 1 with the refusal text.
- Add the `CLISpec` init-refusal case named in Validation.

## Remaining Work

- Sprint 7.1: Nominal roles on both harness authority types, the dead run-name field removed, locale-free
  assembly reads, and plaintext-refusal cases that catch the Dhall type error.
- Sprint 7.2: `Core.dhall` and `example.dhall` state what they do, the `fitsWithin`, alias, and assert
  cases separate each dimension and boundary, and `ConfigArtifact` exposes accessor functions, not labels.
- Sprint 7.3: Import-closed authenticated decode, the binary-mismatch case, and decode/byte cases that assert
  their cause.
- Sprint 7.4: The whole standalone context-file API deleted, a missing-sibling case that asserts its
  diagnostic, and child-projection cases that test production.
- Sprint 7.6: Token-level guard on the `ProjectSpec` field set.
- Sprint 7.7: The CLI identity-mismatch case runs under real argv in a probe and asserts its diagnostic,
  beside an actual-name positive control.
- Sprint 7.8: `fitsBudget` refuses a request above its own limit, as `fitsWithin` does.
- Sprint 7.9: `wslExecArgs` renders `--exec`, the module header claims only the command fold, and the
  mount case covers `readOnly = True`.
- Sprint 7.10: `parseConfigRole` resolves canonical names through the derived table.
- Sprint 7.12: `KnownScopeKind` derives the descriptive scope tag from the scope index, and the
  `Config.Fields` Haddock states which records are descriptive.
- Sprint 7.13: Exhaustive `requiredAncestorError`, placement-keyed `addRole`, valued witness diagnostics, the
  dangling-parent case, pinned and time-limited topology refusals, environment-pinned witness cases, and
  closure cases over every kind and root-ness.
- Sprint 7.14: `project init` publishes through a no-replace link or atomic rename under its policy, and an
  omitted `--source-root` reaches the project assembler.
- Sprint 7.15: Project lifecycle and `check-code` discriminate the wire kind first, treating a file without a
  framework record as a full project wire, and refuse a role wire with a structured wrong-command message.
- Sprint 7.16: the bare entrypoint's init builder ends an assembly refusal through `die`, with a `CLISpec`
  case.

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
