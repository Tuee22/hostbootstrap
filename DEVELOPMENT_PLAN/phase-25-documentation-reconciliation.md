# Phase 25 — Documentation reconciliation and drift guards

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-10-22 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 Home
10.0.26300.9457, GHC 9.12.4, Cabal 3.16.1.0 ;
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` ;
pass ; covers in-gate
**Gate evidence**: 2026-09-14 ; `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from `core/` ; pass ; covers in-gate

> **Purpose**: After the baseline narrative is built, reconcile the governed `documents/` suite, comments, and help
> text with what the code actually does — and install the guards that keep them reconciled.

## Phase Objective

The governed documents describe supported behaviour, and § J requires them to agree with the plan. While phases
are still open they legitimately describe contracts that are not yet fully wired. This phase is the sweep that
closes that gap once, and then makes it mechanically hard to reopen.

It is the last baseline phase because its subject is every phase below it, and it precedes the terminal
acceptance phases because its drift guards are source: landing them after a hardware run would expire that
run's evidence. Each acceptance phase keeps its own documents aligned under § C; this phase's guards then
hold every page, including theirs. It adds nothing else to the build.

## Sprints

### Sprint 25.1: Reconcile the governed documents [Done]

**Status**: Done
**Implementation**: `documents/**`
**Substrates**: none
**Docs to update**: every governed document

#### Objective

Make each governed document describe what the code does.

#### Deliverables

- Every architecture document's contracts match the implemented surfaces, with no target-only statement left
  presented as current behaviour.
- Every engineering document's commands and paths are the real ones.
- Each document's `**Referenced by**` list is accurate, and each family's canonical home is the one
  `documents/README.md` names.
- Every `documents/` reference to a phase is **by name and link** (§ J). A bare number in prose is an
  execution position that a renumbering falsifies, and a bare *sprint* number falsifies faster still —
  a citation naming a sprint the owning phase no longer declares points at nothing at all.
- Duration and capacity figures are the observed ones, and any figure another document *derives* from them is
  recomputed rather than left resting on a stale input.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) is empty, because every shape it named
  has been deleted by the phase that owned it. An empty ledger is this phase's closing condition for that
  document, not a document to keep populated.
- Every ledger row that still exists names a deleting phase that resolves, which `DocValidatorSpec`
  enforces mechanically — an unowned row is how a ledger rots into the repair log § I forbids.

#### Validation

`DocValidatorSpec` plus a read-through of each family against its implementation. The validator checks the
ledger's rows resolve; the read-through checks the ledger is empty.

The 2026-09-05 source audit confirms that receiver admission introduces scope only through
`withAuthenticatedRootScopeFromWire`, and `ReceivedRecoveryDescent` retains both the complete
`RecoveryChildPackage` and its distinct `RootedPayloadBinding`. Provider records describe primitives;
`Provider.Ownership` holds the shared transactions, and the substrate tag is matched once for provider
selection. `Handoff.Process.Route.sanitizedLaunch` derives its dispatch from `Lift.foldLeaf`. Their
corresponding ledger shapes are absent. The service-handler and root-closure owners have also deleted
their listed shapes, leaving the ledger empty.

On 2026-10-22, a further source/document read-through reconciles the Apple demo's Lima
selection with the separately accepted direct-Colima adapter, removes stale completed-phase
and prerequisite-gap claims, and narrows the cluster phase's downstream adoption statement.
Sprint 15.32's stale owed-coverage prose is replaced with the completion already recorded in
Sprints 15.33 and 15.36 and held by the current `ProviderSpec` record-tape guard. Windows
run-duration and idle-timeout prose is aligned with the measured 4-hour acceptance.
Completed phase documents also gain the missing phase-level Remaining Work sections,
and older completed-sprint markers are normalized to the required `None.` spelling.
No source implementation changes. The complete native Windows core gate passes 2,548/2,548,
including `DocValidatorSpec`; the final plan carries both completed Windows evidence rows.

#### Remaining Work

None.

### Sprint 25.2: Reconcile comments and help text [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/**`, `demo/src/**`, `hostbootstrap/**`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Make in-code references and operator-visible text accurate.

#### Deliverables

- Source comments cite phases by name and link, never by execution number.
- Command help and refusal messages use the actual typed vocabulary.
- Operator entry refusals identify the installed root command as the supported route.
- Convenience actions describe the completion observations they actually provide and do not claim managed
  ownership, readiness, or idempotence evidence.

#### Validation

`CLISpec` exercises help, dispatch, missing-config guidance, and signed runtime selection. The documentation
validator scans governed documents and production source for numeric phase citations and proves the refusal
with negative prose and source fixtures. Both are included in the complete gate recorded below.

#### Remaining Work

None.

### Sprint 25.3: Install the drift guards [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Make the reconciled state mechanically hard to lose.

#### Deliverables

- Architecture absence guards name the owning constructive phase and the matching rationale entry.
- Existing doctrine checks enforce dependency order, reversal vocabulary, sprint structure, substrate budget,
  status harmony, and contiguous phase numbering.
- Script/interpreter (§ KK), frame-table (§ LL), path-frame (§ MM), and host-harness (§ JJ) guards remain
  in their lower owning suites and run in the aggregate gate.
- A new architecture fixture detects removed authority modules, unbounded service definitions, and obsolete
  root closure tokens; a valid named-phase link is accepted while numeric prose/source references refuse.
- Provider nonce replay is a behavioral assertion: the second request refuses before another observation,
  rather than a test that merely searches its own source for claimed coverage labels.

#### Validation

The malformed-repository and architecture fixtures make each new validator guard fail for its named reason.
The full gate also runs the existing effect, provider, path, ownership, and compile-fail guard families listed
below. `RecursiveLifecycleSpec` keeps the eight-case accounting `CoverageManifest` pins for it
(`familyCases = 8`) and directly observes one-use nonce behavior.

The close of Sprints 25.1 through 25.3 is recorded here. On 2026-09-05, Linux x86_64 with GHC 9.12.4 and
Cabal 3.16.1.0 passed the complete `cabal test all --ghc-options=-Werror` gate: 2,494/2,494 in 148.63
seconds. `cabal build all` also passed. That gate included the three `DocValidatorSpec` cases the suite
then carried, actual signed CLI service dispatch, fixed host coverage accounting, and the provider nonce
replay case that refuses before a second observation. The native macOS full suite passed 2,494/2,494 in
402.88 seconds, and native Windows passed 2,489/2,489 in 886.48 seconds with the five declared
platform-selection differences. The Linux documentation selection passed its three cases in 0.95 seconds,
and a macOS documentation check passed 3/3 over the reconciled standards, composition, Dhall, and
provider guides. The phase header's later `**Gate evidence**` rows are the current record.

The governed lifecycle, binary-context, budget, configuration, secret, ownership, service, and operator
guides describe their source owners. The component inventory resolves to actual modules. Root operator
refusals name the installed root entry as the remedy. Production source and governed-document phase
references use durable names and links.

The guard families keep their constructive owners:

| Rejected shape / doctrine | Executable guard |
|---|---|
| Plan order, reversal, status, sprint structure, substrate budget, ledger ownership | `DocValidatorSpec` malformed-repository fixture |
| Child durable-store route, root-only closure token, unbounded service handler | `DocValidatorSpec` architecture fixture, `AuthoritySpec`, `SpecIndexSpec`, compile-fail boundaries |
| Scripts and duplicate effect/quoter/interpreter sites (§ KK) | `EffectSpec`, including extension and shebang negative fixtures |
| Duplicate provider/crossing workflows (§ LL) | `ProviderSpec`, `LiftSpec`, `RegistrySpec` and exact crossing arguments |
| Host grammar over guest paths and duplicate path helpers (§ MM/§ JJ) | `EffectSpec`, `LiftContextSpec`, `PortabilitySpec`, and shared source-guard fixtures |
| Forged ownership, stale lease/receipt, incomplete traversal or migration, and premature close | Ownership, Authority, Session, ProjectPlan, recovery and compile-fail suites |
| Numeric phase references outside the plan | `DocValidatorSpec` positive named link and negative prose/source fixtures |

Every new architecture violation names its constructive phase to rewrite and its rationale. Existing lower
boundary guards stay with their owners; this phase adds no second interpreter or authority surface.

#### Remaining Work

None. The sprint-structure, header-block, ledger and contract-heading gaps in the doctrine checks are
Sprint 25.18.

### Sprint 25.4: The reachability page describes the algebra that exists [Active]

**Status**: Active
**Implementation**: `documents/architecture/network_reachability.md`,
`documents/documentation_standards.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

This page is cited as the canonical contract for scope-indexed endpoints and clients, and its Haskell
blocks describe types the compiler has never seen: a client sum, an exposure type, and a reachability
witness that are not in the tree, two delivery constructors under names that do not exist, and a scope
set of four tags where the code has three. A reader designing against it designs against nothing. The
cardinality is the part to fix first, because it is the part someone would build on.

#### Deliverables

- The scope set on the page is the three the code has, and the two tags that exist nowhere are gone.
- The client, exposure, reachability, plan and route types are named and parameterised as they are in the source.
- The delivery strategy constructors are the real ones.
- The page adopts the policy its sibling already states: describe the contract, do not carry a second set of signatures that can drift from the compiled API.
- Every identifier the page names in backticks resolves in the tree.
- Every count the page states matches the table or source beside it: the exposure mints are the three
  `HostBootstrap.Network` exports, `resolvedHostExposure`, `resolvedVmExposure` and `clusterServiceExposure`.

#### Validation

The host static gate. The identifier-resolution check lands later in this phase; until it does, the
check is reading the page against the source by hand, and this sprint records that it was done. Every
backticked identifier on the page was resolved against the tree, and the page now carries no Haskell
block at all: the two owning modules are linked as the signature reference, the three-scope table, the
four-constructor reachability table, the three-row exposure-mint table, the two plan constructors, and the
two-case rendering rule replace the sketches. The rendering rule also changed meaning — a redirecting
plan renders *nothing* and leaves Distribution's default, where the page had claimed it renders
`disable: false`. `documents/documentation_standards.md` now states the signature-reference rule the
page adopted.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

The sprint closes when the page's § Exposure identity prose counts the three mints its table lists and the
host static gate passes again with `DocValidatorSpec` green.

#### Remaining Work

- In `documents/architecture/network_reachability.md` § Exposure identity, the sentence ending "because
  the only mints are the two below" names three mints — the two local mints `resolvedHostExposure` and
  `resolvedVmExposure`, and the cluster mint `clusterServiceExposure` — matching the three-row table under
  it. The page's later "the two local mints consume" stays, because it names the two local ones. Proof is
  a read of the page against the `HostBootstrap.Network` export list and the host static gate.

### Sprint 25.5: Governed prose names what exists [Active]

**Status**: Active
**Implementation**: `documents/architecture/run_models.md`,
`documents/architecture/generic_project_model.md`, `documents/architecture/durable_state.md`,
`documents/architecture/harness_workflow.md`, `documents/architecture/unrepresentable_state.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/engineering/derived_project_standards.md`,
`documents/engineering/in_cluster_registry.md`, `documents/engineering/accelerator_daemon.md`,
`documents/engineering/secrets.md`, `documents/engineering/testing.md`,
`documents/engineering/wsl2.md`, `documents/operations/demo_runbook.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Beyond the reachability page, four service entry points, a POSIX wall module, a cluster
specification type, a run-lease name in a boundary table, and a chain signature are all named in
governed prose and absent from the tree. Several are in pages that describe them as current behaviour,
and one phase describes a closed piece of work in the future tense.

#### Deliverables

- The service entry points named across three pages are the ones the source exports.
- The wall module, the cluster specification, the boundary-table lease row, and the chain signature name real things.
- A page describing closed work says so in the present tense.
- Where two governed pages disagree about one signature, the one that matches the source survives.
- A Haskell construction is named by its Haskell name: harness plaintext is built by the smart constructor
  `testPlaintextSecret` into the hidden `ScopedTestPlaintext` constructor of `HostBootstrap.Config.Vocab`,
  and `TestPlaintext` names only the Dhall wire alternative of `Core.dhall`.

#### Validation

The host static gate; each corrected name was checked against the tree as it was written. The
substitutions were `runVerifiedRuntimeRole` to `runRoleLifecycle`, `selectAndRunService` to
`withDecodedServiceProgram`, `SelectedService`/`ServiceSelection` to `VerifiedServicePlacement` and
`RolePlan`, `RoleAdvance` to `RoleServeOutcome` and `RoleExitReport`, `roleField` to `roleParamsValue`,
`withServices` to `addServices`, `verifyHarnessPreconditions` to `harnessPreconditions`,
`VerifiedNoProjectResourcesAcquired` to `PreEffectProductionClosure` plus
`verifyNoProjectResourcesAcquired`, `FreshGeneration` to the `IntentOrigin` cases `NoHistory` and
`ReleasedReacquisition`, `HarnessConfigWire` to `HarnessSecretRefWire`, `TestPlaintext` to
`ScopedTestPlaintext` in `generic_project_model.md`'s secrets-strict paragraph, `ProxyThroughRegistry`
to `proxyThroughRegistry`, `psTestMatrix` to `psTestSuite` and `mkTestMatrix`, `posixGlobalWallSupported` to `posixOwnershipSupported` and
`windowsOwnershipSupported`, `RunLease` to `UnboundRunLease` and `BoundRunLease`, `AddResult` to
`AcceleratorAddResult`, the four `Created`/`Healthy`/`Unhealthy`/`Foreign` answers to the five
`ClusterReconcileResultView` constructors, and the runbook's `chain :: ProjectConfig -> [Step]` to the
real `demoChainFor`. Two named shapes had no real counterpart at all and the prose was rewritten rather
than renamed: the WSL alias backend's `GuestFlock`/`GuestLockf` choice, which the shipped
`StrongAliasBackend` does not make because it ships a closed act instead of discovering a lock front
end, and the caller-selected `LoopbackExposure`, whose absence the page now states without naming a
type. `ProjectionBinding` likewise named nothing; the parent link is the `childConfigDigest` and
`PlanDigestBinding` joined at projection. The service-runtime paragraph also moved from future to
present tense, because that phase is closed.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

The sprint closes when no governed page uses `TestPlaintext` as a Haskell value or construction. The check
is the whole-word search `grep -rnw TestPlaintext documents/`, which does not match `ScopedTestPlaintext`,
`HarnessTestPlaintext` or `testPlaintextSecret`. Its only hits are Dhall-wire uses: in `secrets.md`, the
`| TestPlaintext : Text` union line, the "Where Harness plaintext lives" sentence naming the wire
alternative `harnessSecretRefWire` renders to, and the `DhallGenSpec` and `SchemaSpec` bullets of its
Validation section ("omits and rejects `TestPlaintext`"); in `schema.md`, the sentence "Production has no
`TestPlaintext` branch". The host static gate passes with `DocValidatorSpec` green.

#### Remaining Work

- `documents/architecture/generic_project_model.md`: the `SecretRef scope` bullet ("`TestPlaintext`
  requires exact `HarnessConfigAuthority projectId runId`") and the secrets-strict sentence ("can construct
  `TestPlaintext` only with the matching Harness config authority") name `testPlaintextSecret`, which takes
  the `HarnessConfigAuthority` and builds `ScopedTestPlaintext`.
- `documents/engineering/secrets.md`: the bullet "`TestPlaintext` construction requires the exact
  generative `HarnessConfigAuthority projectId runId`" and the `HarnessAssembly` paragraph ("substitute
  `TestPlaintext` for selected production pointers") name `testPlaintextSecret`; the lines naming the
  Dhall wire alternative keep `TestPlaintext`.
- `documents/engineering/secrets.md`, three more lines that name the Haskell value: the sentence "only
  `TestPlaintext` construction is Harness-only, because `testPlaintextSecret` needs
  `HarnessConfigAuthority`" says that `testPlaintextSecret`, which builds `ScopedTestPlaintext`, is the
  Harness-only construction; the `Show` sentence ("showing a Harness reference that holds `TestPlaintext`
  prints the fixture value") says a Harness `SecretRef` built by `testPlaintextSecret` shows as
  `SecretTestPlaintext` through `SecretRefView` and prints the fixture value; and the "Where Harness
  plaintext lives" sentence says `harnessSecretRefWire` renders each `ScopedTestPlaintext` to its
  `HarnessTestPlaintext` alternative, which the rendered Dhall spells `TestPlaintext`.

### Sprint 25.6: Dated evidence lives in the plan [Done]

**Status**: Done
**Implementation**: `documents/engineering/build_release.md`, `documents/engineering/testing.md`,
`documents/architecture/unrepresentable_state.md`, `documents/engineering/incus.md`,
`documents/engineering/warm_store.md`, `documents/engineering/base_image.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

The documentation standard keeps dated implementation evidence in the plan, and eleven governed pages
carry it anyway. Three of those state the rule and then break it within a few lines — one says live
publication evidence belongs in the owning sprint and then records a run and a digest, another says
dated totals belong in phase records and then records dated totals.

#### Deliverables

- The dated runs, totals and digests in governed pages move to the phases that own them.
- Each page keeps the contract and drops the chronology.
- The three self-contradicting pages are done first, because a rule broken beside its own statement is the least defensible instance.

#### Validation

The host static gate. The three self-contradicting pages were corrected first. No governed document
under `documents/` now contains an ISO date at all, which is the mechanical form of the rule and what
a later check can assert. Each page kept its contract and dropped its chronology, and every dated fact
removed was confirmed already recorded by its owning phase before the removal — the provider gate's
run and totals in the host-providers-and-the-lift phase, the publication run and its digest in the
base-image-and-warm-store phase, the Apple matrix in the Apple Silicon acceptance phase, and the
Windows wall cases in the Windows and WSL2 phase.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.7: The three ambiguous terms are defined once [Done]

**Status**: Done
**Implementation**: `documents/README.md`, `documents/documentation_standards.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

The corpus has no glossary, and three load-bearing terms mean different things in different places.
*Substrate* has three vocabularies — a five-value code enumeration, a plan header field whose closed set
includes two tokens that appear nowhere else, and a baseline that means one of them. *Frame* has six
spellings across the documents against an eight-constructor kind in the source and an unbounded string
elsewhere. *Cordon* is defined nowhere and silently inverts the meaning it has in the system this
project drives: here it applies resource limits, there it marks a node unschedulable.

#### Deliverables

- Each of the three terms has one canonical definition with one home.
- The plan's substrate header field is described as what it is — a hardware-context declaration — rather than sharing a word with the code's enumeration unremarked.
- The cordon definition states the divergence from the Kubernetes term explicitly, because a reader who knows that system will otherwise read the page backwards.
- Pages using a term in a narrower sense say which sense they mean.

#### Validation

The host static gate. `documents/README.md` carries a `## Glossary` section that is the one canonical
home for the three terms, and `documents/documentation_standards.md` points at it under its content
rules. *Substrate* is given as a three-row table separating the five-constructor `SubstrateName`
enumeration from the plan header's hardware-context tokens and from the `linux-cpu` baseline, and the
header field is named as a hardware-context declaration rather than the code enumeration. *Frame*
separates the eight-constructor `ContextKind` from the plan-level `ProjectFrame` identity. *Cordon*
states the divergence from the Kubernetes term explicitly: here it applies the plan's resource wall,
where `kubectl cordon` makes a node unschedulable and changes no limit.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.8: The contradictory closure claims are settled [Done]

**Status**: Done
**Implementation**: `documents/architecture/ownership_invariant.md`, `documents/architecture/ownership_seam.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Two contradictions need a decision rather than an edit. The direct-provider boundary is described as
non-closing by one architecture page, as implemented and gate-closed by another, and as closed by a
third. And the seam's three-row structure is argued *from* the premise that every frame this project
reaches is Linux, while the same page — and the source — describe a live Darwin publication branch. If
the premise holds the branch is dead code; if the branch is live the premise is false.

#### Deliverables

- The three closure claims are reconciled to the plan, which is the status authority.
- The Linux-only premise is resolved: either the argument is restated without it, or the Darwin row is accounted for within it.
- Whichever way it goes, the page says why, since this premise carries the whole three-row argument.
- No page states implementation status that the plan does not.

#### Validation

The host static gate. The three closure claims are reconciled to the plan, in which the
cluster-lifecycle-and-cordoning phase is `Done`: the two pages that called the direct-Colima boundary
implemented and gate-closed were right, and `ownership_invariant.md`'s "remains non-closing" was the
one that contradicted the table. It now records the boundary as closed by that phase and points the
remaining live Apple lane at the Apple Silicon acceptance phase, naming the plan index as the authority
for both. The Linux-only premise is resolved by restating what it is actually about — frames reached
*through a crossing*, which are Linux — and then accounting for the Darwin branch within it: the
shipped act is built host-native like every other binary (§ N), so the same POSIX row compiles for a
Darwin outer host, where APFS refuses hard links to symbolic links and the publication step is spelled
`renamex_np(RENAME_EXCL)` instead of `link(2)`. The page says why this leaves the three-row argument
standing: a row may spell a primitive differently per kernel, and what must never be written twice is
the clause order.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.9: The overview agrees with the headers it summarizes [Done]

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/00-overview.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

The overview states three things the phase headers contradict: a dependency edge that says one phase
depends on everything where its header names one, a sprint count of three against four, and a
dependency list of two against four. The dependency field is machine-read, so the prose claim is simply
false rather than a different emphasis.

#### Deliverables

- The dependency claims match the headers.
- The gate-host family count matches the phase's own sprints and the architecture split the testing page states.
- The overview summarizes and points rather than restating what a header owns.

#### Validation

The host static gate. "**28** depends on everything" is replaced by what the header says — the worked
demo and nothing later — with the distinction the false claim was reaching for stated explicitly: the
host-portability phase's relation to every source file is its `**Evidence covers**` set, which is an
evidence relation, not a `Depends on` edge. The worked demo's entry no longer presents two of its four
declared dependencies as the whole list. The acceptance paragraph no longer counts gate-host families
at all; it records each family's run as its own dated `**Gate evidence**` row and defers the families
and the count to the phase's own header, which names four against the three the prose had. A closing line states that each header's
`**Depends on**` field is the authority for its own edges.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.10: The remaining stale references [Done]

**Status**: Done
**Implementation**: `core/cabal.project`, `core/hostbootstrap-core/dhall/Core.dhall`,
`DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Three small stale references with one thing in common: each names a path or a mechanism that does not
exist, and each would send a reader somewhere that is not there. A build configuration cites a sibling
path that exists only inside the container; a phase deliverable describes the configuration vocabulary
as generated from the Haskell types when it is hand-written and held by a judgmental-equality test, and
a source comment names the dependency direction the other way round; and a build configuration explains
one of its settings by citing files in a different repository on one machine.

#### Deliverables

- The build configuration cites the warm-store project by its in-repository path.
- The vocabulary's generation direction is described as the equality test that actually holds it, in the phase deliverable and in the source comment.
- The cross-repository citation is replaced by the reason it was making.
- No governed page or build file names a path that does not resolve.

#### Validation

The host static gate. `core/cabal.project` now names the warm-store project by its in-repository path,
`core/warm-deps/`, beside the documentation link it already carried. The generation direction is
corrected in both places that stated it backwards: the Dhall-configuration phase's deliverable and
`Core.dhall`'s own header now say the file is hand-written, that nothing generates it, and that
`DhallGenSpec` is what holds its exported types equal to the schema the Haskell codecs reflect — with
the budget functions noted as having no Haskell counterpart at all. The cross-repository citation to
another project's `cabal.project.local` and doctrine page is replaced by the reason it was making: a
per-process RTS cap is not a host bound, so the job count is pinned beside it, and the build
configuration is where that bound has to live because nothing downstream can reimpose one.
`documents/engineering/schema.md` needed no change — it makes no claim about the vocabulary's
generation direction, and this sprint's Implementation list records the files actually touched.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.11: The identifier-resolution check [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

A backticked identifier in governed prose names something that exists. This is the check with the
widest reach in this phase: the reachability page could describe a vocabulary the compiler had never
seen while every existing check passed, and the same is true of four other pages. It is also the
hardest, because prose legitimately names types by shortened names — the plan standard says so about
its own — so the check carries an explicit reviewed allowlist rather than a silent skip.

#### Deliverables

- Backticked module, type, function and constructor names in governed documents resolve against the tree.
- The allowlist for deliberately abbreviated names is explicit, reviewed, and small.
- A negative fixture proves the check fires on a name that does not exist.
- A positive fixture proves an allowlisted abbreviation produces no violation, because a check that flags everything means nothing.

#### Validation

The host static gate. `checkIdentifierResolution` reads every backticked span of every governed page,
outside fenced blocks, takes the identifier each span starts with, and resolves it against the words and
module names of the source tree. It fired on the repaired corpus once more than the hand read had found —
a `clusterUp` reconciler that `HostBootstrap.Cluster.Lifecycle` does not export — which is the argument
for the check in one line. The allowlist is `identifierAllowlist`, grouped by the reason each entry is
there: taxonomy labels the page using them declares are not dispatch values, names a page's own
illustrative sketch defines, names another system owns, names the agent harness owns, and one name cited
precisely because it must not exist. The positive half of the fixture asserts an allowlisted abbreviation
and a fenced block produce no violation; the negative half asserts a name nothing declares does, and that
the refusal names the allowlist as the reviewed escape.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None. This sprint's check reads `documents/` against a word corpus. Resolution against exact declarations,
over `DEVELOPMENT_PLAN/` and the root documents, is Sprint 25.21, and a fenced-block fixture that can fail
is Sprint 25.17.

### Sprint 25.12: The root-document status check [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

A root document may summarize status and must not restate it. Nothing compares root-document prose
against the plan's table, which is how the front page came to describe eight closed contracts as
planned repairs while every phase header and the table agreed they were done.

#### Deliverables

- A root document's status claims are checked against the plan's status table.
- A negative fixture proves the check fires on a root document that contradicts the table.
- A positive fixture proves that a root document pointing at the table without restating it is clean.

#### Validation

The host static gate. `checkRootDocStatus` reads the plan's own status table and compares it against every line of
`README.md`, `AGENTS.md` and `CLAUDE.md` that links a phase and names a status in the same breath. The
corpus was already clean, so the fixture carries the whole proof: a root document pointing at the table
without restating it produces nothing, and one calling a `Done` phase `Active` produces a refusal naming
both statuses.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None. The agreeing-restatement fixture is Sprint 25.17, and pairing each status word with its own phase
reference on a line naming several phases is Sprint 25.19.

### Sprint 25.13: The entry-document agreement check [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

The two agent entry documents are one document with two audiences, kept in step by hand. They are
in step today and nothing enforces it; the pair is long enough that a one-sided edit would not be
obvious.

#### Deliverables

- The two entry documents are compared modulo the words naming their audience.
- The audience-word mapping is declared rather than inferred.
- A negative fixture proves the check fires on a one-sided edit.

#### Validation

The host static gate. `checkEntryDocAgreement` projects `AGENTS.md` through the declared `audienceMapping` and compares the
result with `CLAUDE.md` line by line, reporting a length difference and the first few divergences. The
mapping is a list of ordered rules, longest first, and a replacement is never rescanned. It found one
real divergence the pair had carried: `CLAUDE.md` said "LLM assistants must never" where every other
occurrence mapped `Agents` to `Assistants`, so the two documents were one hand-edit apart from a
mapping nothing could state.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.14: The link-anchor check [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Relative links are validated by stripping the anchor and resolving the path, so a link to a heading
that does not exist resolves clean. Two such links exist today, and both point at headings that were
renamed.

#### Deliverables

- A link carrying a fragment resolves that fragment against the target document's own headings.
- The two existing dead anchors are corrected in the same change.
- A negative fixture proves the check fires on a fragment naming no heading.

#### Validation

The host static gate. `checkLinkAnchors` resolves a cross-document link's `#fragment` against the target
document's own headings under `headingSlug`. It found both dead anchors the sprint predicted — a `warm_store.md` section
renamed to `Consumer project` and a `base_image.md` section renamed to `Host-sized warm-store budget` —
each of which the existing path check had resolved clean because it strips the fragment first.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None. Same-page fragments, headings inside fenced blocks, and the renderer's underscore and
duplicate-heading slug rules are Sprint 25.19.

### Sprint 25.15: The phase-header field-set check [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

A phase header carries the fields the standard declares. Six phases carry an undeclared field in
three different spellings, two of which restate the status field beside it — a convention one phase
invented and the others do not share.

#### Deliverables

- A phase header carrying a field the standard does not declare is a violation.
- The six undeclared fields are removed in the same change.
- A negative fixture proves the check fires on an invented field.

#### Validation

The host static gate. `checkPhaseHeaderFields` refuses a `**Field**:` line in a phase header that § G does not declare. It
found the six `**Current sprint**` fields, in the three spellings the sprint predicted — `None`,
`None — every sprint is closed`, and `None — phase complete`, the last two restating the status field
beside them. All six are removed.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 25.16: The gate-evidence completeness check, and the drift guard's reach [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

§ G says an evidence row records every leg its gate names, and a row parser that checks only that the
command contains a backtick lets a phase name a composed gate and record one half of it. Separately, an
architecture drift guard that reads the source tree and not the test tree lets a phase citation by number
sit in a spec file against the rule that forbids it.

#### Deliverables

- Every command leg a gate names — one `&&`-separated part of a backticked span whose first word is
  `cabal`, `poetry`, `hostbootstrap`, `python`, `python3` or `docker` — appears in some evidence row of
  that phase.
- The drift guard reads the suites as well as the source, with `DocValidatorSpec.hs` the one by-name
  exemption.
- The composed gates of the test-harness, test-and-context-commands, service-runtime and worked-demo
  phases have evidence rows recording each of their command legs, and the one numeric citation is
  corrected in the same change.
- A negative fixture proves the gate-leg check fires.

#### Validation

The host static gate. `checkGateEvidenceLegs` compares the command legs a `**Gate**` names against the legs its
`**Gate evidence**` rows record, on the non-flag tokens of each as a subsequence, so a row may add
`--ghc-options=-Werror` or run the same command through the repository's Poetry environment without
counting as a different leg. `gateLegCase` proves it: a deferred phase whose gate names `cabal test all`
and `hostbootstrap run -- project up` passes with both recorded and yields one refusal naming
`project up` when only the `cabal` leg is recorded. The four composed gates' rows — the test-harness and
test-and-context-commands phases' focused-pattern legs, the service-runtime phase's live `service run`
leg, and the worked demo's four live verbs — each record every command leg. The architecture drift guard
reads the suites, with one reviewed by-name exemption for the validator's own fixture, which authors
synthetic plan documents and so legitimately contains plan text. The citation predicate is a word, a
space and a digit: erasing punctuation and asking for adjacent tokens sees a data literal as a citation,
and admitting a hyphen as the separator sees the durable `phase-NN-…` link target as one. With that
spelling the guard found the one numeric citation in `ProjectPlanSpec`.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None. The drift guard's test-tree fixture is Sprint 25.17; legs through any command, legs qualified by
their directory, and focused spec legs are Sprint 25.20.

### Sprint 25.17: Every validator rule has a fixture that fails without it [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/DocValidatorSpec.hs`, `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

A check nothing has seen fail is a check nobody has tested. `realRepoCase` asserts only that the real tree
produces no violation, so a check whose guard is deleted or inverted keeps it green. Every rule therefore
needs a miniature-repository fixture in `DocValidatorSpec` that turns red when its guard goes. This sprint
completes the fixtures for the deferred-evidence rules of `checkGateEvidence`, the phase-level Remaining Work rules,
the drift guard's reading of the suites, the fence exclusion of `checkIdentifierResolution`, and the
agreeing half of `checkRootDocStatus`. It also makes three violation and comment texts name things that
exist. The drift-guard message names `phase-29-documentation-reconciliation.md`, a file the tree does not
have, and the export list and the reconciliation banner cite a `documentation_standards.md` section,
"Rules the validator grows to enforce", that the standard does not have. And `identifierAllowlist` carries
`DemoConfig`, which no governed page cites, so the reviewed list holds an entry that excuses nothing.

#### Deliverables

- The existing `digestCase` builds a `Done` phase with `**Gate kind**: deferred`, `**Evidence covers**`
  naming a source tree, and a row covering the digest `measurePathSetDigest` returns.
  `checkGateEvidence` returns `[]` for it. Changing one covered source byte makes it return exactly one
  violation containing `now measures`. The case also asserts typed refusals and `cannot be measured`
  evidence violations for missing, empty, and generated-only covers paths.
- Additional deferred-mode fixtures assert exactly one violation for each of these. A deferred `Done` phase whose row
  `covers in-gate` gives `must name the digest it covers`. A self-verifying `Done` phase whose row covers a
  64-hex digest gives `covers 'in-gate'`. A deferred `Done` phase with no `**Evidence covers**` field gives
  `names no '**Evidence covers**' paths`. The existing `digestCase` retains the unmeasurable-path refusal.
- The owed case is built with `phaseDocumentWith "Active" present "The dated run." ""` (no row), and again
  with the `2026-02-30` row. `checkGateEvidence` returns `[]` for both. The repeated
  `checkGateEvidence root intact` assertion under the "no gate evidence" comment is deleted.
- `negativeCase` asserts every branch of `checkActivePhaseOwnsRemainingWork`,
  `checkActivePhaseRemainingWork` and `checkDonePhaseRemainingWork`:
  - phase 11 gives `names no sprint`;
  - an Active fixture citing `Sprint 99.1` gives `which this phase does not define`;
  - an Active fixture citing only a Done sprint gives the no-Active-sprint message;
  - an Active fixture with a blank `## Remaining Work` gives `has an empty '## Remaining Work' section`;
  - a `Done` fixture whose `## Remaining Work` reads `Closes later.` gives `Done phase declares remaining work`.
- `architectureCase` writes a numeric sprint citation into `core/hostbootstrap-core/test/SomeSpec.hs` and
  asserts one refusal naming `SomeSpec.hs`. It writes the same line into
  `core/hostbootstrap-core/test/DocValidatorSpec.hs` inside the fixture tree and asserts that no refusal
  names that file.
- In `identifierCase`, the fence-exclusion fixture is a bare three-backtick fence whose content line begins
  `NoSuchTypeAtAll`, plus a blockquoted `haskell` fence whose content line carries an inline span naming
  `noSuchQuoted`. Removing the `unfenced` step from `inlineCodeSpans` makes the clean-page assertion fail.
- `rootStatusCase` adds a clean root-document line that links the fixture's phase-7 document and calls it
  `Done`, matching the fixture table's row, and asserts `checkRootDocStatus` returns `[]`.
- `checkArchitectureDrift`'s numeric-citation refusal names
  `DEVELOPMENT_PLAN/phase-25-documentation-reconciliation.md`. The `noneActive` refusal reads "cites no
  Active sprint". The export-list heading and the reconciliation-checks banner comment cite
  `documentation_standards.md § Validation`. `realRepoCase`'s sibling asserts that every
  `rewrite DEVELOPMENT_PLAN/<file>` target in `checkArchitectureDrift`'s refusals exists in the real
  repository. `identifierAllowlist` drops `DemoConfig`, and a further sibling asserts that every entry is
  the leading identifier of an inline code span in some page `checkIdentifierResolution` reads.

#### Validation

The sprint closes when every case named above exists in `DocValidatorSpec` and passes in `cabal test all`
from `core/`, and the host static gate passes. Each fixture is proved by mutation, and the run records each
result. With the case in place, each of these edits to `DocValidator.hs` turns `DocValidatorSpec` red:

- replacing `recorded /= unpackText actual` with `False`;
- inverting the `done && deferred` guard;
- replacing `done` with `True` in `missingRow`;
- making `checkActivePhaseOwnsRemainingWork` or `checkDonePhaseRemainingWork` return `pure []`;
- deleting `unfenced` from `inlineCodeSpans`;
- deleting the `claimed /= statusRowStatus row` filter;
- reverting `driftSourceRoots` to the source roots only;
- emptying `driftCitationExemptions`;
- adding an entry no governed page cites to `identifierAllowlist`.

#### Remaining Work

- Reuse `digestCase`'s matching, stale-digest, and unmeasurable-path assertions, and prove the applicable
  guards through the mutations listed under Validation.
- Add the three remaining single-violation deferred and self-verifying cases: `in-gate` on deferred,
  a digest on self-verifying, and no `**Evidence covers**`.
- Rebuild the owed case without an evidence row and with a malformed row, both asserting `[]`. Delete the
  duplicated `intact` assertion.
- Add the five `negativeCase` needles and the three Active and Done phase fixtures they need.
- Add the test-tree citation and the `DocValidatorSpec.hs` exemption to `architectureCase`.
- Replace the identifier fence fixture with the two fences that can fail.
- Add the agreeing restatement to `rootStatusCase`.
- Correct the drift-guard filename in its message, the `noneActive` text, and the two `§ Validation`
  comments. Add the case asserting that every named rewrite target resolves.
- Delete `DemoConfig` from `identifierAllowlist`, and add the case asserting that every allowlist entry
  is cited by some page the check reads.

### Sprint 25.18: The doctrine checks read the plan without gaps [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Each plan-doctrine check reads the plan the way the standard states the rule. Today several checks pass a
shape the rule forbids:

- an Active sprint with no `#### Remaining Work` section at all;
- a sprint with no body `**Status**`, whose title tag nothing reads;
- a missing phase status filled in by a sprint's, because the header block ends only at a literal `## `;
- evidence rows and `**Evidence covers**` taken from anywhere in the document;
- a later phase cited in prose inside a Remaining Work section;
- a renamed contracts heading that leaves nothing to check;
- a malformed ledger row with a missing `Deleted by` cell;
- a combined substrate declaration that the standard permits, which the check refuses.

#### Deliverables

- `checkSprintStructure` refuses an `Active` sprint with no `#### Remaining Work` section ("an Active
  Sprint N.M has no '#### Remaining Work' section"), as `checkDoneSprintRemainingWork` already refuses a
  `Done` sprint without one.
- A `### Sprint` section whose body has no `**Status**` field is refused ("Sprint N.M has no '**Status**'
  field"), so the title tag is never the sprint's only status declaration.
- `phaseHeaderBlock` returns the lines before the first heading of level 2 or deeper, judged by `headingOf`.
  It is what `phaseHeaderFieldValue`, `checkPhaseHeaderFields`, `checkGateEvidenceLegs` and
  `checkGateEvidence` read. `checkGateEvidence` takes its `**Gate evidence**` rows and its
  `**Evidence covers**` from that block, not from the whole document.
- `checkRemainingWorkOrdering` reads phase numbers from each Remaining Work line through
  `referencedPhaseNumbers`. That covers the `phase-NN-` link form, with or without a leading `./`, and
  prose `Phase NN`.
- `checkContractOwnership` refuses a plan standard with no `## hostbootstrap-Specific Contracts` heading,
  and one whose contracts section holds no lettered level-3 section.
- The ledger check treats every pipe-led line of the `## Tracked shapes` table as a tracked row, except the
  header and the separator. Cells are split keeping blank ones, and only the empty fragments outside the
  outer pipes are dropped. A row with other than four cells is refused as malformed. An empty `Deleted by`
  cell gives "names no deleting phase", even when the `Why` cell links a phase.
- `checkSubstrateBudget` splits each declaration on commas. Each token must be in `substrateVocabulary`,
  and the at-most-one-beyond-`linux-cpu` rule applies to the token set. `linux-cpu, nvidia` passes,
  `nvidia, windows` gives only the over-budget violation, and `linux-cpu, banana` gives one unknown-value
  violation naming `banana`.

#### Validation

The sprint closes when `DocValidatorSpec` carries one fixture per deliverable and they pass in
`cabal test all` from `core/`:

- an Active sprint with no section, and a sprint with no body status;
- a phase with no header `**Status**` whose first sprint precedes any `## ` heading, which gives the
  missing-status violation;
- a Done phase whose only `**Gate evidence**` line sits in a sprint body, which gives `records no`;
- a Remaining Work line citing a later phase in prose, and one citing it through a `./` link;
- a standards fixture with the contracts heading renamed;
- the existing `negativeCase` blank-`Deleted by` regression, plus a ledger row with three cells;
- the three substrate declarations above.

The real plan stays green, and the host static gate passes.

#### Remaining Work

- Add the missing-section and missing-body-status refusals to `checkSprintStructure`, each with its fixture.
- Introduce `phaseHeaderBlock`, route the four header readers and `checkGateEvidence` through it, and add the
  two fixtures.
- Read Remaining Work citations through `referencedPhaseNumbers`, and add the prose and `./` fixtures.
- Refuse the missing or empty contracts section in `checkContractOwnership`, with its fixture.
- Extend ledger row splitting, tracking and malformed-row arity checks as stated; preserve `negativeCase`'s
  blank-`Deleted by` regression and add the short-row fixture.
- Tokenize `**Substrates**` declarations, with the three fixtures. The Haddock on `checkSubstrateBudget`
  states the comma-separated form.

### Sprint 25.19: Link, anchor and status reading agree on every host [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

The validator's verdict on a tree is the same on Linux, macOS and Windows, and its link and status checks
hold the reach their Haddocks claim. Today several things vary or fall short:

- path resolution inherits the host filesystem's case rule;
- files decode under the process locale and its native newline mode;
- `checkReadmeRefs` reads lazily and leaves its handle open;
- same-page anchors go unchecked;
- the anchor set counts `#` lines inside fenced code;
- the slug rule drops `_` and has no duplicate suffixes;
- a root-document line naming two phases pairs every phase with every status word.

#### Deliverables

- `existsExactCase root relPath` resolves a path only when every segment matches a directory entry with
  exact case. `checkLinks`, `checkLinkAnchors`, `checkImplementationPaths` and the ledger's `resolveTarget`
  all use it.
- One strict reader takes bytes through `Data.ByteString.readFile`, decodes with
  `Data.Text.Encoding.decodeUtf8'`, and strips a trailing `\r` from each line. Every read in the module
  goes through it: `readLines`, `checkArchitectureDrift`'s two reads, `identifierCorpus`,
  `identifierViolations`, `checkLinkAnchors` and `checkReadmeRefs`. A decode failure becomes a
  `Violation` naming the file ("is not valid UTF-8"), not an exception.
- `checkLinkAnchors` resolves a same-page `#fragment` against the linking file's own headings.
- The anchor set is built from `stripFencedCode`d lines. `headingSlug` keeps `_`, and repeated headings
  take the renderer's `-1`, `-2` suffixes in document order.
- `rootDocStatusViolations` pairs each status word with the nearest phase reference before it on the
  line, and ignores a status word that precedes every reference.

#### Validation

The sprint closes when `DocValidatorSpec` carries these fixtures and they pass in `cabal test all` from
`core/` on a case-sensitive and a case-insensitive host:

- a link to `Target.md` where the file is `target.md`, refused on both;
- an `**Implementation**` path with one segment in the wrong case, refused;
- a page holding a `0xFF` byte, giving one violation naming it, with no exception;
- a CRLF copy of a fixture page, giving the same violations as the LF original;
- `#missing-heading` on its own page, refused, while `#target` under a `# Target` heading passes;
- a link to a slug that exists only as a comment inside a fenced block, refused;
- `#my_heading` for `## my_heading`, accepted;
- `#foo-1` for the second `## Foo`, accepted;
- "Phase 7 is Done and Phase 8 is Active" against a table agreeing with both, giving `[]`, and with phase 8
  `Planned`, giving one violation for phase 8 alone.

The host static gate passes.

#### Remaining Work

- Add `existsExactCase` and route the four resolvers through it, with the case-mismatch fixtures.
- Replace every `Data.Text.IO.readFile` and the Prelude `readFile` in the module with the strict UTF-8
  reader, with the invalid-byte and CRLF fixtures.
- Check same-page anchors, strip fences before collecting headings, keep `_`, and add duplicate suffixes,
  with the four anchor fixtures.
- Pair root-document status words with their nearest preceding phase reference, with the two-phase fixture.

### Sprint 25.20: Gate legs carry where they run and what they focus [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

An evidence row records every leg its gate declares (§ G). `checkGateEvidenceLegs` falls short of that in
three ways:

- it compares only legs whose first word is one of six recognized commands;
- it identifies a leg by its tokens alone, so `cabal test all` from `core/` and from `demo/` collapse into
  one leg that a core-only row satisfies;
- it cannot see a focused spec run the gate names by spec name.

This sprint makes the comparison cover every command a gate declares, where it runs, and what it focuses.

#### Deliverables

- A leg is any `&&`-separated part of a backticked span with at least two tokens whose first token, after
  environment assignments, is an executable name: it does not begin with `-`, contains no `/`, `=` or
  quote, and is not a number. A project binary's leg is therefore compared the same way a `cabal` leg is.
- A leg's identity is its directory plus its command tokens. Reading a field's backticked spans in order, a
  span ending in `/` assigns its directory to every command span since the previous directory span. A `cd
  <dir> &&` prefix inside a span is that span's directory. Both the `**Gate**` and the rows are read this way.
- A gate leg with directory D is satisfied by a row leg with directory D. When the gate names those tokens
  under only one directory, a row leg with no directory also satisfies it. When the gate names the same
  tokens under two directories, each directory needs its own directed row leg.
- A gate span that is a single `CapWords` token ending in `Spec` is a focus leg. A row span containing that
  token satisfies it, for example in `--pattern HandoffSpec` or `-p HandoffSpec`, with quotes allowed. A
  spec span the gate writes as running inside a following command span (`DocValidatorSpec` inside
  `cabal test all`) is covered by that command leg rather than counted as a focus leg.
- The check lands with every phase document passing. A phase whose current row misses a leg under the new
  reading is listed in this sprint's Validation together with the owning phase that re-records it.
- `gateLegCase` fixtures cover each case: a gate naming `cabal test all` from `core/` and from `demo/`
  with a row recording only `core/` gives one refusal naming `demo/`; a gate focus leg `HandoffSpec` with
  no row mention gives one refusal; a project-binary leg such as `hostbootstrap-demo test run all` with no
  row mention gives one refusal; and the fully recorded variants give `[]`.

#### Validation

The sprint closes when the `gateLegCase` fixtures above pass in `cabal test all` from `core/` and
`validateRepo` over the real repository is green. On the current tree the authenticated-handoff phase's
gate names focused `HandoffSpec`, `ProjectPlanSpec` and `DocValidatorSpec` runs that its row does not
record. That phase records those runs in its next evidence row or rewords its gate before this check
lands. The host static gate passes.

#### Remaining Work

- Widen `isCommandLeg` to any executable-shaped first token, with the project-binary fixture.
- Carry a directory with each leg on both the gate side and the row side, and compare (directory, tokens)
  under the single-directory relaxation, with the two-directory fixture.
- Add focus legs for gate `*Spec` spans, including the "inside" exemption, with the focus-leg fixture.
- Run `validateRepo` over the real plan and list every phase row that the new reading refuses, each with the
  phase that re-records it.

### Sprint 25.21: Identifier resolution reads declarations across every governed document [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

A backticked identifier in governed prose names something the tree declares. The standard states that for
modules, types, functions, constructors and CLI flags. `checkIdentifierResolution` covers less:

- it reads only `documents/`;
- it resolves against every word of every source file, comments and string literals included, so a name
  that appears only in the validator's own `identifierAllowlist` literals or in `DocValidatorSpec`'s
  invented fixture names (`vanishedProducer`, `NoSuchTypeAtAll`) resolves, and the allowlist decides
  nothing;
- it never makes a flag or a `snake_case` name a candidate.

#### Deliverables

- The corpus is declarations, not words. It holds:
  - Haskell module names, names on the left of a top-level `::` signature, `data`, `newtype`, `type`,
    `type family` and `class` heads, data constructors in both GADT and `=`/`|` form, record fields, and
    pattern synonyms;
  - Python `def` and `class` names and module-level assignments;
  - Dhall `let` bindings, union alternatives and record fields;
  - PureScript top-level names;
  - Cabal package and component names.

  Comments and string literals contribute nothing.
- `HostBootstrap/DocValidator.hs` and `DocValidatorSpec.hs` are left out of the corpus by name, the way
  `driftCitationExemptions` treats the drift guard.
- Flags such as `--project-root` resolve against the long-option names the Haskell parsers declare through
  `long "..."` and the Python parsers declare through `add_argument("--...")`. A `snake_case` candidate
  resolves against Python declarations.
- The check reads `documents/`, the root `README.md`, `AGENTS.md` and `CLAUDE.md`, and every
  `DEVELOPMENT_PLAN/` document except `rationale.md`, the declared home of rejected names. In a phase
  document it reads only `Done` sprint bodies and the phase sections other than `## Remaining Work`,
  because an Active or Planned sprint names what it is about to build.
- Every `identifierAllowlist` entry is live. A case asserts that each entry resolves nowhere in the
  corpus, so an entry that has become a declaration fails until it is removed.
- Every citation that the wider reach refuses in the real repository is corrected to the declared name, or
  allowlisted with its reason, in the same change.

#### Validation

The sprint closes when `identifierCase` covers each of these and passes in `cabal test all` from `core/`:

- a page citing a name that appears only in a source comment, refused;
- a page citing a name that appears only in `DocValidatorSpec.hs`, refused;
- a Done sprint citing a dead name, refused, while a Planned sprint citing the same name is not;
- a root document citing `--no-such-flag`, refused, while a declared flag passes;
- the allowlist-liveness assertion.

`validateRepo` over the real repository is green, and the host static gate passes.

#### Remaining Work

- Replace `identifierCorpus`'s word split with the declaration extractor, with the comment and
  fixture-name refusals.
- Exempt the validator and its spec from the corpus by name.
- Add flag and `snake_case` candidates with their own corpora, with the flag fixture.
- Extend the read to the root documents and the plan, with the Done-versus-Planned fixture.
- Add the allowlist-liveness case and prune dead entries.
- Correct or allowlist every real citation the wider reach refuses.

### Sprint 25.22: A sprint's Validation cites suites and cases that exist [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

A Done sprint's `#### Validation` is the record of what proved it, and nothing checks that the suites and
cases it names exist. A renamed spec or a deleted case leaves the record citing a proof that is no longer
in the tree, while every status stays coherent.

#### Deliverables

- `checkValidationCitations` reads the `#### Validation` of every `Done` sprint in every phase document.
  An Active or Planned sprint's Validation states closure criteria for cases still to be written, so it
  is not read.
- A backticked `CapWords` token ending in `Spec` resolves to a file `<Name>.hs` under
  `core/hostbootstrap-core/test` or `demo/test`, searched recursively.
- A backticked dotted `<Name>Spec.<binding>` resolves to a top-level binding in that file. A backticked
  `camelCase` token ending in `Case` resolves to a top-level binding in some file under those test roots.
- A backticked `test_...` name resolves to a `def` of that name under `tests/`.
- A backticked path ending in `.hs` or `.py` that contains `/` resolves from the repository root.
- A refusal names the phase file, the sprint, and the unresolved citation.
- Every citation that the real plan's Done sprints fail is corrected to the real spec or case in the same
  change.

#### Validation

The sprint closes when a `validationCitationCase` fixture passes in `cabal test all` from `core/`. Its tree
holds `core/hostbootstrap-core/test/RealSpec.hs` declaring `realCase`. A Done sprint citing `RealSpec` and
`realCase` gives `[]`. Citing `NoSuchSpec`, `goneCase` or `RealSpec.goneBinding` gives one refusal each. A
Planned sprint citing `NoSuchSpec` gives none. `validateRepo` over the real repository is green, and the
host static gate passes.

#### Remaining Work

- Add `checkValidationCitations` with the spec-file, binding, case-name, Python-test and path resolutions,
  and wire it into `validateRepo`.
- Add `validationCitationCase`.
- Correct every real Done-sprint Validation citation it refuses.

### Sprint 25.23: Governed pages carry no Haskell signature sketch [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`,
`documents/architecture/generic_project_model.md`,
`documents/architecture/composition_methodology.md`, `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/library_hierarchy.md`, `documents/architecture/run_models.md`,
`documents/engineering/derived_project_standards.md`, `documents/engineering/linking_and_optimization.md`,
`documents/engineering/testing.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

`documents/documentation_standards.md` says the owning module, linked, is the signature reference, and a
fenced `haskell` block restating declarations is not a supported way to describe an API. No check enforces
that, and the identifier check skips fenced blocks, so a declaration in a fence can name a type or
constructor the tree does not have without any check noticing. 15 `haskell` fences sit across eight governed
pages: `composition_methodology.md` (2), `generic_project_model.md` (4, all inside `>` blockquotes),
`hostbootstrap_core_library.md` (2), `library_hierarchy.md` (1), `run_models.md` (2),
`derived_project_standards.md` (2), `linking_and_optimization.md` (1) and `testing.md` (1).
`secrets.md` and `demo_runbook.md` carry none.

#### Deliverables

- `checkFencedHaskell` reads every Markdown file under `documents/`. It refuses a fenced block opened with
  `haskell` or `hs`, including one opened inside a `>` blockquote, when the block contains a declaration
  line. A declaration line is one whose first token is `data`, `newtype`, `type`, `class` or `instance`,
  or one shaped `name ::` or `Name ::`. The refusal names the page and the fence's line number, and says
  to link the owning module as the signature reference. A usage block with no declaration line passes.
- `secrets.md` describes the `SecretRef scope` surface as a link to `HostBootstrap.Config.Vocab` plus the
  table of its smart constructors (`vaultSecret`, `transitKeySecret`, `promptSecret`,
  `testPlaintextSecret`, `productionSecretRef`, `harnessSecretRef`), with no fenced block; this holds in
  the tree and `checkFencedHaskell` keeps it so.
- Every block the check refuses becomes a link to its owning module plus contract prose or a table.
  The pages are `composition_methodology.md`, `generic_project_model.md`, `hostbootstrap_core_library.md`,
  `library_hierarchy.md`, `run_models.md`, `derived_project_standards.md`,
  `linking_and_optimization.md` and `testing.md`. A block with no declaration line stays as a usage
  example.
- `documentation_standards.md` lists `checkFencedHaskell` in its governed-documents check table and drops
  the fenced-`haskell` row from "Rules held by review".
- `fencedHaskellCase` covers four cases. A `haskell` block holding `foo :: Int` is refused. A blockquoted
  `haskell` block holding `data X = X` is refused. A `haskell` block holding only `main = runDemo`
  passes. A `text` block holding `foo :: Int` passes.

#### Validation

The sprint closes when `fencedHaskellCase` passes in `cabal test all` from `core/`, `validateRepo` over the
real repository is green with `checkFencedHaskell` wired in, every backticked name in the converted prose
resolves under `checkIdentifierResolution`, and the host static gate passes.

#### Remaining Work

- Add `checkFencedHaskell` to `validateRepo`, with `fencedHaskellCase`.
- Convert every refused block among the 15 fences in the eight listed pages.
- Move the rule from "Rules held by review" into the check table of `documentation_standards.md`.

### Sprint 25.24: Digest is the one SHA-256 and framing definition site [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/PortabilitySpec.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports `sha256Hex` and `frameWire`, and the phases that introduced `Authority.Kernel`,
`Lifecycle.Session`, `Lifecycle.Plan`, `Build`, `Handoff`, `Activation`, `Ensure.Colima`,
`Lifecycle.ResourceRecord`, `RoleLifecycle` and `Service` make each of those modules import them. This sprint
adds the drift guard that keeps it so: an absence guard over the production source tree that fails when any
module other than `HostBootstrap.Digest` defines a top-level SHA-256 or length-framing helper.

#### Deliverables

- A `PortabilitySpec` absence guard scans every `.hs` file under `core/hostbootstrap-core/src` and
  `core/hostbootstrap-core/internal` and fails, naming the file and line, when any file other than
  `internal/ownership/HostBootstrap/Digest.hs` has a line opening with `sha256Hex ::`, `sha256Text ::`,
  `digestBytes ::` or `frameWire ::`.

#### Validation

The `PortabilitySpec` guard passes on the live tree and, run over a fixture tree holding one extra module that
defines `sha256Hex :: ByteString -> Text`, reports that module. Both run inside
`cabal test all --ghc-options=-Werror` from `core/`, and the host static gate (§ JJ) passes.

#### Remaining Work

- Add the single-definition absence guard and its fixture case described under Validation to
  `core/hostbootstrap-core/test/PortabilitySpec.hs`.

### Sprint 25.25: Interpreter text lives only in the guest bootstrap [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/EffectSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

§ KK confines interpreter invocation to the one guest-bootstrap module and requires an absence guard that
says so. Each phase that composed a host command through an interpreter removes its own sites; this sprint
lands the repository-wide guard over every Haskell source that may compose a host command, so a shell
string, a compiled-in Python program, or a PowerShell expression cannot appear anywhere else without the
gate naming it.

#### Deliverables

- `EffectSpec` scans `core/hostbootstrap-core/src`, `core/hostbootstrap-core/internal`,
  `core/hostbootstrap-core/app`, `demo/src`, and `demo/app` for interpreter tokens: the string literals
  `"sh"`, `"bash"`, `"/bin/sh"`, `"/bin/bash"`, `"sg"`, `"python"`, `"python3"`, `"pwsh"`, `"powershell"`,
  `"powershell.exe"`, `"cmd"`, and `"cmd.exe"`, and the interpreter-only flag literals `"-lc"`, `"-ec"`,
  `"-Command"`, and `"-EncodedCommand"`.
- The set of files carrying a token equals, exactly, the union of two named lists, so a new site fails the
  gate and a removed site forces its entry out of the list.
- The sanctioned list is `HostBootstrap.Ensure.GuestBootstrap` alone, the one residue § KK names.
- The non-invocation list names files whose tokens are not an interpreter invocation, each with its
  reason: `HostTool.hs` (`powershell.exe` is the enumeration's discovery name), `DocValidator.hs` (the
  gate-command vocabulary it validates), and the Colima resolver modules under
  `internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/` (`python3` is a § K consumer-resolver
  identity candidate, opened and fingerprinted, never handed a program).
- The literal-token scan lives in `SourceGuard` beside `countHaskellIdentifier`, and the guard's failure
  message names the file, the token, and § KK.

#### Validation

The sprint closes when, under `cabal test all` from `core/`, the guard passes over the tree with the two
lists above, and an in-memory fixture source carrying `["bash", "-lc", "true"]` under a path on neither list
is reported with that path and token. The guard passes only once every lower phase's owed interpreter-site
removal has landed, which is why it sits here.

#### Remaining Work

- Add the interpreter-token guard, its two lists, and the in-memory fixture case to `EffectSpec`, with the
  literal-token scan added to `SourceGuard`.

### Sprint 25.26: No suite removes a case under a build symbol [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/PortabilitySpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`, `documents/languages/haskell.md`

#### Objective

§ JJ's fifth rule as a source guard: a case whose subject one gate host lacks stays in the suite there and
asserts what the subject answers, so no CPP conditional in a test source can make a family smaller on one
host while the total stays green. Each phase converts its own suites' case-removing regions; this sprint
closes the route for good with a guard over every test source.

#### Deliverables

- `PortabilitySpec` carries the case "no test source removes a case under a CPP conditional". Over every
  Haskell source in both test-suite `hs-source-dirs` (excluding `test/compile-fail`), it finds each region
  from a line beginning `#if`, `#ifdef`, or `#ifndef` to its matching `#endif` (nesting counted; `#else` and
  `#elif` lines inside the region), tokenizes the region's lines with `SourceGuard.haskellTokens`, and fails
  when a region carries a `testCase`, `testGroup`, `testProperty`, or `TestTree` token, naming the module
  and the region's first line.
- A region that holds only an import, a helper body, or a `Bool` support predicate passes.

#### Validation

Closure requires, under `cabal test all` from `core/`: the guard case above passing over the tree; and
`PortabilitySpec` unit cases over the region scanner with literal fragments: a `#ifndef mingw32_HOST_OS`
region holding `, testCase "x" $ pure ()` is reported, a region holding `windowsResolutionCases = []` under
a `[TestTree]` signature inside the region is reported, and a region holding only
`import System.Posix.Files (setFileCreationMask)` is not. The guard passes only once every lower phase's
owed conversion of its own case-removing regions has landed.

#### Remaining Work

- Write the CPP-region scanner and the guard case in `PortabilitySpec`, with the unit cases named in
  Validation.

### Sprint 25.27: Only SourceGuard walks a source tree [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/PortabilitySpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

`SourceGuard` is the one toolkit a source guard reads this repository's own sources through, and each phase
routes its own suites' walkers through it. This sprint adds the drift guard that keeps it so: a second
walker enumerates a different set of modules, and a guard over that set asserts nothing about the rest.

#### Deliverables

- A `PortabilitySpec` case "only SourceGuard walks a source tree" asserts that no module in either test-suite
  `hs-source-dirs` other than `SourceGuard.hs` carries both a `listDirectory` token and a `".hs"`
  string-literal token, naming each offending module.
- `EffectSpec.trackedScriptFiles`, which walks the repository for scripts and names no `".hs"` literal, is
  not an occurrence.

#### Validation

Closure requires the case above to pass over the tree under `cabal test all` from `core/`, and an in-memory
fixture source carrying both tokens under a module name other than `SourceGuard` to be reported. The guard
passes only once every lower phase's owed walker deletion has landed.

#### Remaining Work

- Add the walker-absence case and its fixture case to `PortabilitySpec`.

## Remaining Work

- Sprint 25.4: the reachability page counts its three exposure mints.
- Sprint 25.5: governed prose names `testPlaintextSecret` where it means the Haskell construction, and
  keeps `TestPlaintext` for the Dhall wire alternative.
- Sprint 25.17: the remaining deferred-mode, phase-level Remaining Work, drift-reach, fence and agreeing-status
  fixtures, mutation checks including the existing `digestCase`, three violation texts naming files and
  sections that exist, and an allowlist with no uncited entry.
- Sprint 25.18: the sprint-structure, header-block, Remaining Work prose-citation, contracts-heading,
  ledger-row and substrate-token gaps in the doctrine checks.
- Sprint 25.19: case-exact path resolution, a strict UTF-8 reader, same-page and fence-aware anchors, and
  per-phase status pairing.
- Sprint 25.20: gate legs for every declared command, qualified by directory, plus focused spec legs.
- Sprint 25.21: identifier resolution against exact declarations, over `DEVELOPMENT_PLAN/` and the root
  documents, with flag candidates and a live allowlist.
- Sprint 25.22: Done-sprint Validation citations resolve to existing specs and cases.
- Sprint 25.23: the fenced-`haskell` ban, enforced, with the refused blocks among the 15 existing fences
  converted.
- Sprint 25.24: a `PortabilitySpec` guard keeps `HostBootstrap.Digest` the only module defining a SHA-256 or
  framing helper.
- Sprint 25.25: an `EffectSpec` guard holds interpreter tokens to the guest-bootstrap module and a named
  non-invocation list.
- Sprint 25.26: a `PortabilitySpec` guard fails when a CPP region in a test source carries a case.
- Sprint 25.27: a `PortabilitySpec` guard keeps `SourceGuard` the only test module that walks a source tree.

## Documentation Requirements

**Architecture docs to create/update:**
- every document under `documents/architecture/` — reconciled against the implemented surfaces.

**Engineering docs to create/update:**
- every document under `documents/engineering/` and `documents/operations/` — reconciled against the real
  commands and observed figures.

**Cross-references to add:**
- `documents/documentation_standards.md` — the surface this phase changes in it.
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `DEVELOPMENT_PLAN/README.md`, `00-overview.md`, and
  `system-components.md` all agree on the phase names and defer status to the README table.
