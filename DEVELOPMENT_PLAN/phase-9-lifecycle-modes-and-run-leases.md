# Phase 9 — Lifecycle modes and run leases

**Status**: Done
**Depends on**: Phase 5 (installed identity, operator verification, and authority kernels), Phase 7
(Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate
**Gate evidence**: 2026-10-28 ; native Windows 11 x86_64 DESKTOP-R6BTBVS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-28 ; Ubuntu 24.04.4 x86_64 native-filesystem CPU container hostbootstrap-core-gate-20261026, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

> **Purpose**: Establish exact Production and Harness mode, run, lease, snapshot, and lifecycle-profile
> authority before project-plan construction begins.

## Phase Objective

Each installed project holds a protected mode lease whose type identifies Production or one exact Harness
run. Harness acquisition mints its run identity generatively, and every mode, snapshot, and lease value
retains that identity through its phantom indices. Binding changes an unbound lease into a bound lease only
when the verified snapshot has the same scope.

An opaque `ActiveProjectMode` narrows the project-wide lease to its exact lifecycle scope. The Production
and Harness lifecycle-profile openers then consume matching root, mode, and unbound-lease evidence through
separate protected one-use slots. Each opaque profile retains the exact installed-project name,
protected-store identity, and broker epoch observed at that transition, so downstream plan admission can
reject evidence assembled from distinct stores even when their project names and epoch numbers happen to
match. Retaining ordinary Haskell values therefore cannot open a second profile or erase its durable origin.

## Sprints

### Sprint 9.1: Indexed `ProjectModeLease` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/OpenGenericProjectModeMutation.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeProjectModeLease.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

The existing indexed project-mode lease admits only its exact mode transition, retains Production
mode durably between entries and refuses malformed mode records without entering either public root.

#### Deliverables

- Retain the implemented opaque empty ProductionMode/HarnessMode tags, nominal three-index
  ProjectModeLease, private wire/mutation kernels and exact public export pin. No new production
  type, API or module is required; empty phantom tags gain no fictitious constructor-forgery test.
- Revalidate OpenGenericProjectModeMutation against the real private acquireModeWire. That fixture
  and its exact nonexport expectation already exist; reconcile the stale rewrite task without churn.
- Repair ForgeProjectModeLease as a constructor-child import for the actual hidden constructor,
  with the actual compiler diagnostic. An underapplied value binding would remain ill-typed after
  exposure and is not an independent privacy proof. Retain mode-index/run-index coercion fixtures.
- Add two malformed-mode payload cases: not-a-mode and harness<TAB>1<TAB> followed by 49 ASCII
  letters. Derive the real mode key from the encoded installed-project name. Obtain the genuine
  empty harness sweep proof before seeding corruption. Each public Production/Harness opener
  returns the exact ModeMalformedRecord key, enters no callback and preserves the mode record's
  bytes and version after each attempt. Whole-store epoch ordering remains owned by Sprint 9.4.
- Strengthen Production retention by returning the observed root lease epoch, then reading a present
  production<TAB>epoch record between and after two root entries. Each record must match its
  entry's observed epoch; successful reentry legitimately advances the version and epoch.
- Retain public cross-mode and subprocess contention controls. Cite the actual HarnessSpec
  four-process one-winner control rather than attributing it to AuthoritySpec or claiming a
  simultaneous-start barrier. Align lifecycle-state semantics and the already implemented nominal
  Harness authority roles in both declared architecture pages.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed focused AuthoritySpec 245, HarnessSpec 47, each of the four private-kernel/
constructor/mode-index/run-index fixtures 1, inventory 54 and DocValidatorSpec 17. The complete
core gate then passed on both: Windows 3,317 cases in 507.41 seconds; Linux 3,319 in 388.01 seconds,
GHC 9.12.4/Cabal 3.16.1.0 with package -Werror. The Windows child command is plain cabal test all;
Linux uses the same unfiltered all selection with hidden successes. Provider-live components report
their declared not-requested Unsupported result, not live acceptance.

Both malformed payload leaves exercise both public roots, with genuine sweep evidence obtained
before corrupting the encoded mode key. Each exact ModeMalformedRecord refusal retains the target
record's original bytes/version and enters zero callbacks. Retention reads a present Production
record with the actual observed lease epoch between and after root brackets; successful reentry
may legitimately advance epoch/version. Whole-store admission ordering is not claimed here.

The public-only native GHC rejects the real ProjectModeLease constructor-child import with
GHC-10237, pinning the normalized complete child-not-exported phrase. Source inspection confirms
the actual private constructor has four fields; no underapplied value binding can mask a leak.
The already correct acquireModeWire fixture and nominal mode/run coercion fixtures remain. The
existing four-process HarnessSpec control admits one acquisition and reports three stated refusals;
no simultaneous-start barrier is claimed. Empty mode tags gain no invented constructor fixture.

There are no production/API/export changes. Two AuthoritySpec cases and the existing retention
case are strengthened, one genuine fixture/registration is repaired, and the two architecture pages
align durable behavior and previously implemented nominal roles. Complete Phase 9 closure and its
four-command host-static gate remain owed after its other active sprints.

#### Remaining Work

None.

### Sprint 9.2: Generative `RunId runId` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/OpenRunIdFromText.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeRunId.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceRunId.hs`,
`core/hostbootstrap-core/test/compile-fail/OpenRunKeyParser.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

The existing generative run identity and every durable mode-field admission preserve exact text and
accept only their canonical ASCII identity/unsigned-decimal grammar, with strict UTF-8 transport.

#### Deliverables

- Retain the implemented nominal RunId, rank-2 mint, separate Production identity branch and
  scope propagation. parseRunKey already enforces 1–48 ASCII alphanumerics or hyphen; preserve
  that producer instead of rewriting completed work. Add the still-missing ASCII guard to
  mkInvocationCloseKey without changing its other length or punctuation rules.
- Preserve the genuine OpenRunIdFromText fixture for private withReifiedRunId. Add one distinct
  private-parser import fixture for actual parseRunKey, register its real public-GHC diagnostic,
  and add its Implementation path only once created. Repair ForgeRunId as a real RunId(RunId)
  child import with its actual privacy diagnostic; retain CoerceRunId. No duplicate reifier proof
  or fake underapplied constructor binding is added.
- encodeFields uses UTF-8; exactFields and decodeFields decode strictly and return no fields on
  invalid bytes. Preserve exact field text: remove whole-record Text.strip normalization so
  trailing whitespace cannot bypass later grammar. Keep existing private signatures and malformed
  record errors; add no public codec/authority test seam or caller of a legacy test-only producer.
- readWord admits only canonical ASCII unsigned decimal within Word64: nonempty digits, no sign,
  whitespace, parentheses, hex or leading zero except 0. Reject more than 20 digits before bounded
  Integer parsing, enforce maxBound and the showWord round trip, with no wrap or partial extraction.
- Add public ingress controls for the specified non-ASCII run and close keys. Add exact malformed
  mode-number rows for signs, overflow, parentheses, hex, leading zero and surrounding whitespace,
  and the malformed Production lease number. Each target record keeps its bytes/version and each
  refused root callback remains unentered; whole-store epoch ordering stays in 9.4.
  The existing recovery test pins the earlier exact malformed-lease refusal for a leading-zero
  epoch, with neither recovery callback entered, no acquisition record and no protected mutation;
  it requires no invalid
  recovered authority to reach the downstream acquisition journal.
- Exercise invalid-UTF-8 ack through genuine existing-bound admission, pinning the exact project
  invocation key and both callback counts. Independently distinguish UTF-8 from Char8 with a legal
  Unicode incomplete-migration key read back unchanged through the public recovery path, and an
  invalid UTF-8 migration field refused at its exact key. ASCII rejection alone is not proof of
  decoding. Use existing fixtures/raw protected-record mutation, not a new evidence producer.
- Add a declaration-bounded absence guard for Char8 truncation and text trimming in the private
  durable-field codecs, with its named rationale. Writer UTF-8 is source/primitive evidence where
  no legal public Unicode-write route exists; do not claim an unexercised runtime writer path or
  introduce a legacy free-digest/migration authority caller just to test it.
- Align the declared lifecycle/Harness docs, including the resolved nominal-role gap, and the
  canonical-field rationale. Preserve later snapshot/admission/profile work. Reconcile any changed
  legacy-row explanation without deleting a still-standing decoder owned by a later sprint.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed focused AuthoritySpec 260, LifecycleSpec 161/163 respectively, each of the four
RunId/private-parser/reifier/coercion selections 1, inventory 54 and DocValidatorSpec 17. After
aligning the recovery fixture, SessionSpec 127 and DocValidatorSpec 17 passed on both hosts.
The complete unfiltered core gates then passed: Windows 3,336 cases in 510.37 seconds and Linux
3,338 in 389.08 seconds, GHC 9.12.4/Cabal 3.16.1.0 with package -Werror. The native child command
is plain cabal test all; Linux hides successful case output while selecting the same complete all
scope. Provider-live reports its declared not-requested Unsupported result, not live acceptance.

AuthoritySpec names the group "noncanonical mode numbers refuse both public roots", the positive
"canonical mode epochs include zero and the maximum Word64", both "snapshot inspection refuses a
non-ASCII run at ingress" and "invocation close keys refuse a non-ASCII character at ingress", and
"an unbound Production lease refuses a negative epoch without changing its record". The number
rows exercise both public roots with exact malformed mode keys,
zero callback entries and preserved target bytes/version. The zero and max-Word64 rows enter a
genuine Production root. Its non-ASCII identity controls and malformed Production lease row also
pin their exact refusals. LifecycleSpec's invalid UTF-8 ack and migration rows use genuine bound
admission and preserve the full protected image. The independent Unicode incomplete-migration
case "the recovered profile preserves a UTF-8 incomplete migration key" returns the exact text,
distinguishing strict UTF-8 from Char8 independently of ASCII close-key rejection. The negative
LifecycleSpec cases are "invalid UTF-8 in a terminal close key refuses its exact invocation record"
and "invalid UTF-8 in an incomplete migration refuses its exact migration record". The declaration-bounded durable-field guard pins the actual UTF-8
writer/reader primitives and absence of truncation or trimming; runtime Unicode writer admission
is not claimed where no legal public writer route exists.

The public-only native GHC rejects the actual RunId constructor-child import with GHC-10237 and
the private parseRunKey import with GHC-61689; registrations pin their actual normalized phrases.
The genuine private withReifiedRunId fixture and nominal coercion fixture remain unchanged.
Mode.hs changes 25 lines in one production module and adds no public type or export.

The first complete runs each reported one fixture failure: Windows 1 of 3,336 in 516.29 seconds,
Linux 1 of 3,338 in 388.46 seconds. SessionSpec's leading-zero epoch could not mint recovered
current-version authority through the strict decoder. Its case now reads "recovery refuses a
noncanonical lease epoch before acquisition" and directly pins the exact malformed-lease key,
neither recovery callback entered, unchanged protected image and no acquisition record. The
existing retained-evidence, CAS and live-snapshot controls and all generic recovery helpers remain.
The case count is unchanged. Both complete passing reruns above include that aligned assertion.

#### Remaining Work

None.

### Sprint 9.3: Scope-indexed lease binding and canonical snapshots [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeRunLease.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeBoundRunLease.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeVerifiedPlanSnapshot.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

One canonical snapshot writer and one framed record representation supply exact same-scope lease
binding. Canonical config digest and bytes form a single optional unit throughout protected readback.

#### Deliverables

- Retain opaque nominal UnboundRunLease, VerifiedPlanSnapshot and BoundRunLease with the same
  scope, digest and broker-generation indices and existing bindRunLease continuation surface.
  Same-scope CAS success and exact conflict behavior remain; no public authority API is added.
- persistCanonicalPlanSnapshot is the only library snapshot writer; revision is explicit and all
  spec/config/plan digests and bytes derive from its opaque CanonicalPlanSnapshot. Its exact export
  pin and an all-library definition/export absence guard hold that writer boundary, linked to the
  rationale "Snapshot writers consume canonical plans". A deleted-symbol import is not a fixture.
- One private canonical-material type holds config digest and canonical bytes. PlanSnapshotRecord
  and VerifiedPlanSnapshot hold Maybe of that unit; one-sided states cannot be constructed. Preserve
  public accessors, valid record bytes/version, PlanSnapshotView projections and inhabited Show output.
- decodePlanSnapshotRecord admits only the bounded magic-prefixed framed format. The optional unit
  has exhaustive tags 0 and 1; an absent unit remains readable for compatibility, with no claim that
  a generic protected-envelope read independently authenticates a plan. Indexed admission performs
  the exact plan-byte/digest join. All existing total/frame/text/material bounds stay enforced.
- AuthoritySpec's nine and HarnessSpec's three writer calls use genuine canonical snapshots. Derive
  linked expected digests and journal/session/resource keys from fixed canonical fixtures, retaining
  HarnessSpec's forbidden-name guard. Preserve exact idempotency and independent revision/config/
  topology substitution controls; no compatibility evidence producer is added.
- Public inspectPlanSnapshot and verifyPlanSnapshot refuse both ordinary and overflowing revision
  tab-format records at the exact snapshot key, without entering verification or changing protected
  bytes/versions. Ordinary revision 1 distinguishes format removal; overflow already refuses through
  strict numeric admission. Canonical readback pins every view accessor, especially Just config and
  Just canonical bytes. A positive framed tag-0 read through both generic readers pins absent material,
  exact fields, one verification callback and read-only bytes/version. Existing LifecycleSpec digest-only
  bound-admission refusal still passes.
- Fresh binding proves its origin by successfully opening withProjectUpMigrationProfile inside the
  bind continuation; rebinding pins the exact bound-state conflict message. Lease Haddocks sit on
  their actual types; an unbound lease may already have a persisted snapshot before binding.
- Three independent actual constructor-child fixtures protect UnboundRunLease, BoundRunLease and
  VerifiedPlanSnapshot, with real GHC diagnostics. Retain genuine Production/Harness, cross-run and
  digest-pair binding fixtures, and align the canonical writer/readback docs and ledger.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed AuthoritySpec 264, HarnessSpec 47, LifecycleSpec 161/163 respectively, each
of the three constructor-child and three scope/digest fixture selections 1, inventory 54 and
DocValidatorSpec 17. Complete unfiltered core gates then passed: Windows 3,342 cases in 516.53
seconds; Linux 3,344 in 389.97 seconds, GHC 9.12.4/Cabal 3.16.1.0 with package -Werror.
The native child is plain cabal test all; Linux hides successful case output with the same all
selection. Provider-live reports the declared not-requested Unsupported result, not live acceptance.

AuthoritySpec's four new cases are "inspection and verification refuse an ordinary tab-separated
snapshot", "inspection and verification refuse an overflowing tab-separated snapshot revision",
"a framed snapshot without canonical material remains generically readable", and "the library has
one canonical snapshot writer and no alternate snapshot decoder". Refused reads pin the actual
snapshot key, zero verification callbacks and complete protected-image equality after each attempt.
The positive raw tag-0 frame pins every generic view/verified projection, absent material, exactly
one verification callback, and unchanged target bytes/version and complete image. It claims generic
protected-record readback, not indexed plan authentication. Ordinary revision 1 independently proves
format refusal; overflow already refused through strict numeric admission.

The existing "a canonical snapshot persists exact bytes and refuses config/topology substitution"
case pins all five view accessors, including Just config and exact canonical bytes. Independent
revision-only substitution and byte-identical idempotency remain in "a plan snapshot is
byte-identically idempotent and immutable". "a fresh binding proves no recovery is owed" consumes
the actual migration-profile Right, while "rebinding an already-bound lease is not a fresh transition"
pins the exact bound-state conflict. LifecycleSpec's "a legacy digest-only snapshot cannot mint
bound plan evidence" still passes. Twelve actual writer calls and their fixed canonical digest and
journal/session/resource-key expectations are adopted; HarnessSpec's forbidden-name guard remains.

Actual public-only GHC-10237 diagnostics are registered independently for ForgeRunLease,
ForgeBoundRunLease and ForgeVerifiedPlanSnapshot child imports. ProductionLeaseAsHarnessSnapshot,
CrossRunLeaseBinding and CrossDigestLeaseBinding retain full real binding calls; the last proves
a mismatched digest pair, not independent coverage of each digest axis. The complete-library
absence guard and exact sealed export pin hold the sole public writer boundary without a fixture
importing a deleted definition.

Mode.hs changes 162 lines in one production module and introduces one private paired-material type.
Valid version-1 framed bytes, limits, projections and inhabited Show output remain. Independent
source comparison confirms Production-root acquisition and the profile/lease transition tail are
unchanged; their remaining contracts stay in Sprints 9.4 and 9.6. Phase closure still owes its own
full gate and all four host-static commands after the remaining sprints close.

#### Remaining Work

None.

### Sprint 9.4: Production lease admission before fresh allocation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A settled Production root refuses an ineligible existing lease before allocating an epoch or writing
mode or authority records, preserving a bound run's existing admission at its recorded epoch.

#### Deliverables

- After existing mandatory closure recovery and operator verification, withProductionRoot performs
  read-only mode and lease admission under the same exclusive protected entry before withFreshEpoch,
  withVerifiedRoot or acquireProductionMode. Preflight yields only an admission verdict and retains
  no session or authority; the existing root continuation still runs outside the protected entry.
- Shared mode eligibility retains Production and refuses a live Harness before lease classification.
  Shared lease decoding/classification admits absent and exact LeaseUnbound records, or LeaseClosed
  for Production Up only. Bound, Frozen, Migrated and disallowed Closed states preserve their exact
  ModeLeaseNotBindable run/state text; malformed bytes name the exact lease key.
- recordUnboundLease consumes that same classification and retains exact CAS expectations. Actual
  Closed-Up rearming keeps invocation clearing, terminal reverse-root clearing, journal reopening,
  lease writing and profile initialization in the admitted transition; preflight performs no writes.
- On settled stores, every lease-classification refusal enters no root callback and preserves the
  complete protected image, including counter, mode, authority binding, lease, snapshot and profile.
  Mandatory recovery remains prior work; no rollback or read-only guarantee is claimed for recovery
  or for a failure during an admitted Closed-Up rearm.
- Operator-before-mode-before-lease refusal priority stays explicit. A genuine live Harness after a
  closed Production run still yields the mode conflict for Production Down/Destroy. The earlier
  preflight necessarily places mode/lease refusals ahead of allocation or authority-binding faults
  in multiply corrupt stores; no universal error-order preservation is claimed.
- AuthoritySpec pins whole-store bound/malformed refusals and distinct Closed Down/Destroy, Frozen
  and Migrated states, plus genuine Closed-Up success and retained-Harness mode priority. LifecycleSpec
  proves that refused fresh Up leaves the genuine existing Open bound run admissible with its exact
  bytes and epoch, Open callback once and terminal callback never. Align current-state docs.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed AuthoritySpec 270, LifecycleSpec 162/164 respectively, HarnessSpec 47, inventory
54 and DocValidatorSpec 17. Complete unfiltered core gates then passed: Windows 3,349 cases in
519.24 seconds; Linux 3,351 in 395.94 seconds, GHC 9.12.4/Cabal 3.16.1.0 with package -Werror.
The native child is plain cabal test all; Linux hides successful case output with the same all
selection. Provider-live reports its declared not-requested Unsupported result, not live acceptance.

AuthoritySpec's "a second Production root preserves an existing bound lease and snapshot" and
"a Production root preserves and refuses a malformed lease record" retain their exact target
errors, no-entry and bytes/version checks, and capture the complete protected image immediately
before/after each refused fresh root. Four new raw-state cases name "a closed Production lease
refuses Down without changing any record", the matching Destroy case, "a frozen Production lease
refuses fresh Up without changing any record", and the matching migrated case. They pin exact
closed/frozen/migrated-bound errors, zero entries and whole-image equality. These are protected
record classifier controls, not claimed migration execution.

"a genuinely closed Production run can rearm through Up" uses actual public pre-effect closure
and release, then admits one fresh Up with a higher epoch, exact Production/unbound rows and the
available profile slot bound to the new lease version. "a live Harness takes priority over the older
closed Production lease" uses genuine public roots and closure, then pins the actual Harness run's
mode conflict for both Down and Destroy, zero fresh-root entries and unchanged complete images.

LifecycleSpec's "a refused fresh Up preserves the existing Open bound run at its recorded epoch"
starts from the genuine bound fixture with independently seeded counter 40. Refused fresh Up
returns the exact bound-state error with no entry or image change; subsequent withBoundPlanSnapshot
returns exact stable bytes and epoch 41 through Open once, terminal never, with the image preserved.

Mode.hs changes 179 lines in one module with no new type or export. Source comparison verifies the
snapshot boundary, profile consumer and admitted Closed-Up clearing/reopening/CAS sequence remain.
The shared read-only checks run after mandatory recovery and operator verification, before fresh
allocation. Image equality applies to settled classifier refusals; no recovery or failed-rearm rollback
is claimed. Existing root continuations run outside the entry. Phase closure still owes its own full
gate and all four host-static commands after the remaining sprints.

#### Remaining Work

None.

### Sprint 9.5: `ActiveProjectMode` narrowing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeActiveProjectMode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Narrow an indexed project-wide mode lease into the exact lifecycle scope authorized by its mode tag.

#### Deliverables

- `ActiveProjectMode scope brokerGeneration` is opaque and retains the active broker generation.
- Production narrowing has the exact type:

  ```haskell
  productionActiveMode
    :: ProjectModeLease projectId ProductionMode brokerGeneration
    -> ActiveProjectMode (Production projectId) brokerGeneration
  ```

- Harness narrowing has the exact type:

  ```haskell
  harnessActiveMode
    :: ProjectModeLease projectId (HarnessMode runId) brokerGeneration
    -> ActiveProjectMode (Harness projectId runId) brokerGeneration
  ```

- These two scope-specific functions are the only producers of active-mode authority.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container each passed ForgeActiveProjectMode, ProductionActiveModeAsHarness and
CrossRunActiveProjectMode (one case each), inventory 54 and DocValidatorSpec 17. The public-only
native GHC rejects the actual ActiveProjectMode constructor-child import with GHC-10237; its full
normalized child-not-exported phrase is registered. The private constructor has four fields, and the
import becomes well-typed if that constructor is exposed, independently of value-application arity.

The scope/run coercion fixtures remain unchanged. CrossRunActiveProjectMode distinguishes a
representational scope-role weakening because the empty Harness scope's parameters are phantom;
the stored nominal BrokerEpoch structurally enforces the broker role. Exact export and role pins
remain. Epoch projection cases are retained in AuthoritySpec, whose preceding full core gate passed
3,349 Windows and 3,351 Linux cases. This sprint changes only the fixture and its diagnostic, with
no production, API or case-count change. The final complete phase gate still includes these cases
after the remaining profile work, with package -Werror and all four host-static legs.

#### Remaining Work

None.

### Sprint 9.6: Protected one-use lifecycle profiles [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeLifecycleProfile.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceLifecycleProfileScope.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Both lifecycle-profile openers consume one protected slot only while their exact retained lease is
still unbound at its recorded version, and preserve the reason ordinary admission refuses them.

#### Deliverables

- Retain opaque LifecycleProfile with its nominal scope, exact mode/project/store/epoch origin and
  existing Production/Harness opener signatures. A genuine constructor-child fixture and a direct
  newtype-scope-alias coercion fixture independently hold privacy and the nominal role, with observed
  diagnostics. No new public type, evidence producer, API or module is added.
- Existing root, mode and unbound inputs match by scope/generation and retained origin before entry.
  Inside the exclusive entry, mandatory recovery and ordinary reverse-root refusal keep their order.
  A nonstore ordinary refusal retains modeErrorMessage in AuthorityMalformedBinding; store failures
  retain AuthorityStoreFailure. Operator diagnostics therefore identify a durable reverse-root intent.
- Before reading/consuming the profile slot, the shared consumer reads the actual lease key and
  requires decoded LeaseUnbound with record version equal to the retained UnboundRunLease version.
  Missing, malformed, Bound, Closed and re-versioned leases yield no profile. The fresh-root classifier
  is not reused: its absent/Closed-Up eligibility is a different contract.
- Existing available-to-consumed slot CAS retains exact epoch/lease-version checks, one continuation
  and AuthorityInvocationConsumed for a second opener on the same still-unbound evidence. The new
  lease guard runs inside the existing slot-consumption workflow, preserving admission-before-mutation
  and ProjectPlanSpec's scoped ordering guard. Callbacks remain outside durable slot mutation.
- Six AuthoritySpec controls cover Production/Harness times genuine Bound binding, valid Closed
  input and same-content Unbound CAS. The latter independently proves version refusal. Capture the
  actual original available-slot bytes and its own record version, preserve both after refusal, pin
  the authority diagnostic and zero callbacks, and compare the complete post-mutation store image.
  Execute any returned IO action before counts; the public profile continuation itself is pure.
- A valid raw Pending Destroy intent at reverse-root.<encoded project>.production refuses ordinary
  profile admission with the specific reverse-root text and leaves the slot available. A matching
  valid Terminal frame through the same public opener permits one profile, independently proving
  decoder recognition because malformed bytes also refuse. Frames use actual project/store/epoch,
  live record images and canonical data; ordinary fixture acquisition/cursor bytes are not claimed
  reverse-lifecycle authority or execution. No public decoder or test-only authority seam is added.
- The two forkIO cohorts are named "a second Production profile opener with the same evidence is
  refused" and the matching Harness name. They retain exactly one Right and one
  AuthorityInvocationConsumed, and omit counters that only repeat Right counts. No simultaneous
  race/barrier claim is made on the non-threaded core runtime. Existing origin/projection and genuine
  cross-process protected-entry exclusion controls remain.
- Align the declared current-state architecture pages with the live lease check, specific refusal and evidence
  limits. Retain genuine Harness-as-Production, Production-as-Harness, cross-run and cross-broker
  signature fixtures, exact exports and scope roles; later consumers receive the same opaque profile.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed AuthoritySpec 277, HarnessSpec 47, LifecycleSpec 162/164 respectively, each of
the two new privacy/role and five existing opener-input fixture selections 1, inventory 54 and
DocValidatorSpec 17. The initial ProjectPlanSpec module-name selector ran one incidental case;
the corrected actual "indexed project-plan foundation" group then passed all 89 cases on both
hosts, followed by refreshed DocValidatorSpec 17. Its scoped ordinary-admission/slot-order guard
remains. Every declared focused group therefore ran before the complete gates.

All four canonical host-static legs then passed on both hosts, GHC 9.12.4/Cabal 3.16.1.0 with
package -Werror. The final core child commands are exactly cabal test all, with no case filters:
Windows 3,358 cases in 526.64 seconds; Linux 3,360 in 392.85 seconds. From demo/, the same plain
all command passed 165 consumer cases in 5.74/1.86 seconds respectively and its complete core
dependency suite, 3,358 in 502.54 seconds / 3,360 in 380.45 seconds. Each retained failure-context
capture is empty. The two Cabal workspaces run serially within each gate host.

The exact root commands poetry run python -m hostbootstrap.check_code and poetry run python -m
hostbootstrap.test_all passed on both. Ruff, Black and Mypy report success; 376 tests pass with
100% coverage on Windows Python 3.14.7 (7.52 seconds) and Linux Python 3.12.3 (8.25 seconds).
The Linux run selects the existing /repo/.venv with VIRTUAL_ENV; its initial system-Python route
lacked development dependencies and was rerun in that environment without source changes.
Both Python routes import the actual working-tree package. A read-only comparison verifies all
1,023 nonignored source-tree files still match the Linux snapshot after the gates. These static
results claim no live provider/hardware acceptance; the provider-live component reports its
explicit not-requested Unsupported result.

AuthoritySpec's "lifecycle profiles require their exact live unbound lease" group has six public
Production/Harness cases. Genuine canonical binding, valid Closed input and same-content Unbound
CAS each retain the original present available-slot bytes/version, return the exact authority
refusal, enter no executed callback and preserve the complete post-mutation store image. The
same-content row independently distinguishes the retained-version check from state checks.

"a recognized Pending Destroy intent refuses a profile while its matching Terminal permits one"
uses the exact suffixed key and independently framed 23/28-field records with real project/store,
epoch, canonical data and live record images. Pending retains the specific reverse-root cause and
available slot with no callback; the same Terminal common fields permit one executed callback
with the actual Production name/epoch and mutate only the slot to consumed. The ordinary fixture
acquisition/cursor records claim no reverse-lifecycle authority or execution. A malformed sentinel
cannot satisfy the independent Terminal positive. The two same-evidence cohorts retain one Right
and one AuthorityInvocationConsumed with their honest second-opener names; redundant Right-count
counters are removed. Existing first-open origin/projection controls remain.

Actual public GHC rejects ForgeLifecycleProfile's constructor-child import with GHC-10237 and
CoerceLifecycleProfileScope's local newtype-alias coercion with GHC-18872; full normalized phrases
are registered. The latter distinguishes nominal from representational scope. The five existing
cross-scope/run/broker opener fixtures call the real API completely. Exact public exports and
indices remain.

Mode.hs changes 34 lines in one production module with no new type or API. The new guard precedes
the exact unchanged available-slot reader/CAS body, and ordinary refusals retain their cause.
Independent source comparisons preserve canonical snapshots and Production preflight. Three
architecture pages align the implemented order, callback and intent-state limits. The complete
phase gate and all four host-static legs above close the only remaining sprint obligation.

#### Remaining Work

None.

### Sprint 9.7: Protected one-use Harness `LifecycleProfile` slot [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Open a Harness lifecycle profile exactly once from evidence for one generative Harness run.

#### Deliverables

- The Harness opener has the exact type:

  ```haskell
  withHarnessLifecycleProfile
    :: RootScopeAuthority (Harness projectId runId)
    -> HarnessAuthority projectId runId
    -> RunId runId
    -> ActiveProjectMode (Harness projectId runId) brokerGeneration
    -> UnboundRunLease (Harness projectId runId) brokerGeneration
    -> (LifecycleProfile (Harness projectId runId) -> a)
    -> IO (Either AuthorityError a)
  ```

- Root scope, Harness authority, run witness, active mode, and unbound lease share the exact `projectId`,
  `runId`, and broker generation indices.
- The resulting profile retains the exact installed-project name, protected-store identity, and broker epoch
  observed through that Harness lease, just as the Production profile does.
- The opener compare-and-swaps that run's protected Harness profile slot from available to consumed before
  entering the continuation.
- A retained evidence tuple cannot consume the slot again or open a profile for another run.

#### Validation

`AuthoritySpec` proves one successful open and refusal of a second open with the same retained evidence
(`AuthorityInvocationConsumed`, one continuation entry). Cross-process exclusion of the slot
compare-and-swap rests on the exclusive protected entry, as Sprint 9.6's Validation states.
`CompileFailSpec` proves that Production evidence, another Harness run, or another broker generation
cannot inhabit the opener. The phase gate runs with `-Werror`.

Dated evidence for the phase gate and lease-acquisition contract:
`cabal test all --ghc-options=-Werror` from `core/` passed 1169/1169 on 2026-08-09 (aarch64-osx,
GHC 9.12.4), including all 113 public compile-fail boundaries. The same run covered distinct identities
across successive Harness acquisitions, the bound and malformed Production-root refusal/preservation
cases, exact lease/snapshot conflicts, and the Production and Harness same-slot second-opener
refusals. The library and test-suite build also passed with `-Werror`.

Origin-retention revalidation on 2026-08-09 (aarch64-osx, GHC 9.12.4) passed the exact gate at 1194/1194,
including Production and Harness project/store profile projections, an end-to-end two-store/same-project/
same-epoch refusal before snapshot persistence, and all 123 public compile-fail boundaries.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**

- `documents/architecture/lifecycle_state_model.md` — indexed modes, generative run identity,
  scope-indexed lease binding, active-mode narrowing, and protected profile slots.
- `documents/architecture/harness_workflow.md` — Harness run identity and one-use profile admission.
- `documents/architecture/unrepresentable_state.md` — sealed profile proofs and precise active or
  malformed reverse-intent admission limits.

**Engineering docs to create/update:**

- `documents/engineering/testing.md` — protected compare-and-swap races and compile-fail authority
  fixtures.

**Cross-references to add:**

- Keep `development_plan_standards.md` § EE and the Phase 9 README status row aligned with these
  foundations.
