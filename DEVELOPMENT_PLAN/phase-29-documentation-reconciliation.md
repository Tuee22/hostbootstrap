# Phase 29 — Documentation reconciliation and drift guards

**Status**: Done
**Depends on**: Phase 28 (host-portability acceptance)
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-14 ; `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from `core/` ; pass ; covers in-gate

> **Purpose**: After the narrative is fully built, reconcile the governed `documents/` suite, comments, and help
> text with what the code actually does — and install the guards that keep them reconciled.

## Phase Objective

The governed documents describe supported behaviour, and § J requires them to agree with the plan. While phases
are still open they legitimately describe contracts that are not yet fully wired. This phase is the sweep that
closes that gap once, and then makes it mechanically hard to reopen.

It is last because it is the only phase whose subject is every other phase. It adds nothing to the build.

## Sprints

### Sprint 29.1: Reconcile the governed documents [Done]

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

#### Remaining Work

None.

### Sprint 29.2: Reconcile comments and help text [Done]

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

### Sprint 29.3: Install the drift guards [Done]

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
below. `RecursiveLifecycleSpec` preserves its seven-case accounting and directly observes one-use nonce behavior.

#### Remaining Work

None.

## Completion Evidence

On 2026-09-05, Linux x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed the complete
`cabal test all --ghc-options=-Werror` gate: 2,494/2,494 in 148.63 seconds. `cabal build all` also passed.
The full gate includes the three `DocValidatorSpec` cases, actual signed CLI service dispatch, fixed host
coverage accounting, and the provider nonce replay case that refuses before a second observation.

The final native macOS full suite also passed 2,494/2,494 in 402.88 seconds, and native Windows passed
2,489/2,489 in 886.48 seconds with the five declared platform-selection differences. The Linux documentation
selection passed all three cases in 0.95 seconds after status reconciliation. A final macOS documentation
check also passed 3/3 after the standards, composition, Dhall, and provider guides were reconciled; obsolete
current-versus-target passages and the duplicate composition API sketch have been removed.

The governed lifecycle, binary-context, budget, configuration, secret, ownership, service, and operator
guides describe their current source owners. The component inventory resolves to actual modules. Obsolete
illustrative API sketches and completed-work backlog claims are absent; the legacy ledger is empty.
Root operator refusals name the installed root entry as the remedy. Production source and governed-document
phase references use durable names and links.

The guard families retain their constructive owners:

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
boundary guards stay with their owners; the final phase adds no second interpreter or authority surface.

### Sprint 29.4: The reachability page describes the algebra that exists [Done]

**Status**: Done
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

#### Validation

The host static gate. The identifier-resolution check lands later in this phase; until it does, the
check is reading the page against the source by hand, and this sprint records that it was done. Every
backticked identifier on the page was resolved against the tree, and the page now carries no Haskell
block at all: the two owning modules are linked as the signature reference, the three-scope table, the
four-constructor reachability table, the two exposure mints, the two plan constructors, and the
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

#### Remaining Work

None. The remaining dead identifiers across the other governed pages were Sprint 29.5.

### Sprint 29.5: Governed prose names what exists [Done]

**Status**: Done
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

#### Validation

The host static gate; each corrected name was checked against the tree as it was written. The
substitutions were `runVerifiedRuntimeRole` to `runRoleLifecycle`, `selectAndRunService` to
`withDecodedServiceProgram`, `SelectedService`/`ServiceSelection` to `VerifiedServicePlacement` and
`RolePlan`, `RoleAdvance` to `RoleServeOutcome` and `RoleExitReport`, `roleField` to `roleParamsValue`,
`withServices` to `addServices`, `verifyHarnessPreconditions` to `harnessPreconditions`,
`VerifiedNoProjectResourcesAcquired` to `PreEffectProductionClosure` plus
`verifyNoProjectResourcesAcquired`, `FreshGeneration` to the `IntentOrigin` cases `NoHistory` and
`ReleasedReacquisition`, `HarnessConfigWire` to `HarnessSecretRefWire`, `TestPlaintext` to
`ScopedTestPlaintext`, `ProxyThroughRegistry` to `proxyThroughRegistry`, `psTestMatrix` to `psTestSuite`
and `mkTestMatrix`, `posixGlobalWallSupported` to `posixOwnershipSupported` and
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

#### Remaining Work

None.

### Sprint 29.6: Dated evidence lives in the plan [Done]

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

### Sprint 29.7: The three ambiguous terms are defined once [Done]

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

### Sprint 29.8: The contradictory closure claims are settled [Done]

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

### Sprint 29.9: The overview agrees with the headers it summarizes [Done]

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
at all; it says one sprint per family and defers the families and the count to the phase's own header,
which names four against the three the prose had. A closing line states that each header's
`**Depends on**` field is the authority for its own edges.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,536/2,536, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 29.10: The remaining stale references [Done]

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

### Sprint 29.11: The identifier-resolution check [Done]

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

None.

### Sprint 29.12: The root-document status check [Done]

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

None.

### Sprint 29.13: The entry-document agreement check [Done]

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

### Sprint 29.14: The link-anchor check [Done]

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

The host static gate. `checkLinkAnchors` resolves a link's `#fragment` against the target document's own headings under the
renderer's slug rule. It found both dead anchors the sprint predicted — a `warm_store.md` section
renamed to `Consumer project` and a `base_image.md` section renamed to `Host-sized warm-store budget` —
each of which the existing path check had resolved clean because it strips the fragment first.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

### Sprint 29.15: The phase-header field-set check [Done]

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

### Sprint 29.16: The gate-evidence completeness check, and the drift guard's reach [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/documentation_standards.md`

#### Objective

§ G now says an evidence row records every leg its gate names, and the row parser checks only that
the command contains a backtick — so four phases name a composed gate and record one half of it.
Separately, the architecture drift guard reads the source tree and not the test tree, which is why a
phase citation by number sits in a spec file against the rule that forbids it.

#### Deliverables

- Every leg a gate names appears in that phase's evidence row.
- The drift guard reads the suites as well as the source.
- The four incomplete rows and the one numeric citation are corrected in the same change.
- A negative fixture proves each check fires.

#### Validation

The host static gate. `checkGateEvidenceLegs` compares the command legs a `**Gate**` names against the legs its
`**Gate evidence**` rows record, on the non-flag tokens of each as a subsequence, so a row may add
`--ghc-options=-Werror` or run the same command through the repository's Poetry environment without
counting as a different leg. It found the worked demo naming four live verbs and recording one, which is
the shape § G's new sentence forbids; that row now records all four. The architecture drift guard also
reads the suites now, with one reviewed by-name exemption for the validator's own fixture, which authors
synthetic plan documents and so legitimately contains plan text. Reaching the suites required tightening
the citation predicate itself: the old reading erased punctuation and asked for adjacent tokens, which
sees a data literal as a citation, and admitting a hyphen as the separator would have seen the durable
`phase-NN-…` link target as one. A space is what a citation in prose actually uses, and with that
spelling the guard found the one numeric citation sitting in `ProjectPlanSpec`.

On 2026-09-14 the host static gate passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1: `cabal build all`
and `cabal test all` from `core/` passed 2,546/2,546 in 200.71 seconds, `cabal build all` and
`cabal test hostbootstrap-demo-test` from `demo/` passed 151/151, and from the repository root
`poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 251/251.

#### Remaining Work

None.

## Remaining Work

None. The governed corpus is reconciled to the source, and each of the seven rules the standard states is
now a check with a negative fixture beside it. The reconciliation found what the checks were written to
find: a canonical contract page describing a vocabulary the compiler had never seen, dated evidence in
eleven pages that state the rule against carrying it, three load-bearing terms with no definition, a
closure claim contradicting the status table, an overview contradicting the headers it summarises, six
invented header fields, two dead link anchors, one one-sided edit between the two entry documents, and a
gate recording one of its four legs. Each is repaired, and each repair is now the thing a check refuses.

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
