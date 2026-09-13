# Phase 29 — Documentation reconciliation and drift guards

**Status**: Active
**Depends on**: Phase 28 (host-portability acceptance)
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

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

### Sprint 29.4: The reachability page describes the algebra that exists [Active]

**Status**: Active
**Implementation**: `documents/architecture/network_reachability.md`
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
check is reading the page against the source by hand, and this sprint records that it was done.

#### Remaining Work

The remaining dead identifiers across the other governed pages are Sprint 29.5.

### Sprint 29.5: Governed prose names what exists [Planned]

**Status**: Planned
**Implementation**: `documents/architecture/run_models.md`, `documents/architecture/generic_project_model.md`, `documents/operations/demo_runbook.md`
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

The host static gate; each corrected name is checked against the tree as it is written.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.6: Dated evidence lives in the plan [Planned]

**Status**: Planned
**Implementation**: `documents/engineering/build_release.md`, `documents/engineering/testing.md`, `documents/architecture/unrepresentable_state.md`
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

The host static gate.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.7: The three ambiguous terms are defined once [Planned]

**Status**: Planned
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

The host static gate.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.8: The contradictory closure claims are settled [Planned]

**Status**: Planned
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

The host static gate.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.9: The overview agrees with the headers it summarizes [Planned]

**Status**: Planned
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

The host static gate.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.10: The remaining stale references [Planned]

**Status**: Planned
**Implementation**: `core/cabal.project`, `documents/engineering/schema.md`
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

The host static gate.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.11: The identifier-resolution check [Planned]

**Status**: Planned
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

The host static gate. Each check is green against the repaired tree and red against its own negative
fixture; the standard requires the fixture, because a check nothing has seen fail is a check nobody has
tested.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.12: The root-document status check [Planned]

**Status**: Planned
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

The host static gate. Each check is green against the repaired tree and red against its own negative
fixture; the standard requires the fixture, because a check nothing has seen fail is a check nobody has
tested.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.13: The entry-document agreement check [Planned]

**Status**: Planned
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

The host static gate. Each check is green against the repaired tree and red against its own negative
fixture; the standard requires the fixture, because a check nothing has seen fail is a check nobody has
tested.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.14: The link-anchor check [Planned]

**Status**: Planned
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

The host static gate. Each check is green against the repaired tree and red against its own negative
fixture; the standard requires the fixture, because a check nothing has seen fail is a check nobody has
tested.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.15: The phase-header field-set check [Planned]

**Status**: Planned
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

The host static gate. Each check is green against the repaired tree and red against its own negative
fixture; the standard requires the fixture, because a check nothing has seen fail is a check nobody has
tested.

#### Remaining Work

None beyond the phase's own.

### Sprint 29.16: The gate-evidence completeness check, and the drift guard's reach [Planned]

**Status**: Planned
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

The host static gate. Each check is green against the repaired tree and red against its own negative
fixture; the standard requires the fixture, because a check nothing has seen fail is a check nobody has
tested.

#### Remaining Work

None beyond the phase's own.

## Remaining Work

The governed corpus is owed reconciliation to the source, and the validator is owed the
checks that keep it reconciled. **Sprint 29.4** owns the first — the canonical reachability page, whose
vocabulary the compiler has never seen. Sprints 29.5 to 29.10 carry the remaining prose, and Sprints
29.11 to 29.16 add one check each, with the negative fixture the standard requires.

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
