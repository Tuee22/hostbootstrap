# Phase 10 — Versioned sessions, the project journal, and durable fences

**Status**: Done
**Depends on**: Phase 9 (lifecycle modes and run leases)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-10-29 ; native x86_64 Windows 11, DESKTOP-R6BTBVS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from `core/` ; pass ; covers in-gate
**Gate evidence**: 2026-10-29 ; native-filesystem Ubuntu 24.04.4 x86_64 CPU container through WSL2, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from `core/` ; pass ; covers in-gate

> **Purpose**: Give an invocation a versioned session inside a single-writer project journal, and give a
> crashed invocation a durable fence that stops its old permits from being mistaken for live ones.

## Phase Objective

A lease says which invocation owns the project; a session says what that invocation is currently doing, at
which version. The journal is the single-writer log both the session opener and the finalizer contend on, so
opening work and closing the project cannot both win.

Fences are the other half. A crash leaves permits outstanding, and the only sound way to resume is to
declare the old generation's permits dead before issuing new ones — durably, so the declaration itself
survives a second crash.

## Sprints

### Sprint 10.1: Indexed journal permits and versioned session refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceProjectPermitScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceProjectPermitPlan.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceClosingProjectPermitScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceClosingProjectPermitPlan.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceClosedProjectPermitScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceClosedProjectPermitPlan.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceOperationSessionScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceOperationSessionPlan.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceOperationAdvanceScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceOperationAdvancePlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Retained journal/session values cannot be re-indexed by coerce, and their live versions enforce
session/open/close exclusion with exact refusals. These are typed-value and concurrency guarantees;
the text-addressed journal producer does not authenticate caller-selected plan identities.

#### Deliverables

- ProjectPermit, ClosingProjectPermit, ClosedProjectPermit and OperationSession have nominal scope
  and plan parameters. OperationAdvance has nominal scope/plan and a representational result.
  Five annotations strengthen existing carriers without new public names, signatures or wire layout.
- openProjectJournal remains an observation/opener for its raw plan Text and current concurrency
  version. Its scope/plan instantiation is caller-selected; nominal roles prevent coerce of an already
  typed value and do not authenticate that text or join it to a canonical plan. Existing higher
  bridges retain their separate plan/authority joins. No producer redesign is introduced here.
- Opening a session and beginning project close consume the same project-journal version. Two
  deterministic same-permit order controls prove each winner's exact successor/refusal and preserved
  state. Existing cross-process protected-entry exclusion remains separate evidence.
- A stale permit is presented after its formerly open session has genuinely closed, so no older-open
  refusal masks SessionStaleProjectPermit. Retain the independent older-open control and assert the
  exact presented version and unchanged protected image.
- Closed-session reopen/register/second-close and zero-epoch/missing-project/Open-journal close
  attempts each pin their exact error. Capture preservation baselines after genuine setup, including
  coordinator initialization for missing-project admission; image reads occur outside held entries.
- Existing atomic intent/session-membership registration, one successor permit and AuthoritySpec's
  zero-operation refusal, closing resumption/foreign epoch and matching-epoch close controls remain.
  Explicit scoped local types preserve GADT branch indices. Numeric admission and observed-release
  origin are supplied by the following independent sprints.
- Ten independent public-GHC fixtures use a local newtype alias on exactly one scope/plan axis of
  each carrier. All ten compile before role strengthening; afterwards each rejects for the actual
  nominal mismatch. A positive public-GHC payload-coercion control preserves OperationAdvance's
  representational result, and existing genuine constructor/state-type fixtures remain.
- Align the lifecycle and unrepresentable-state pages with the nominal-value and runtime-concurrency
  distinction and the actual ordered controls. No race or runtime plan-authentication claim is made
  from these role annotations or sequential permit tests.

#### Validation

SessionSpec has "a session open wins against a close presented the same permit" and "a close wins
against a session open presented the same permit". The stale-permit case closes session-a before
presenting the old permit to session-b, pins SessionStaleProjectPermit at the old version, and retains
the image. Closed-session reopen/register/second-close pin SessionNotOpen; epoch 0 pins
SessionRecordCorrupt "closing epoch must be positive"; a coordinator-initialized missing project pins
SessionProjectMissing; recordClosedProject against Open with a genuine Closing permit from another
text-addressed plan pins SessionRecordCorrupt "project is not closing". Existing Authority closing,
zero-operation and matching-close controls remain.

On 2026-10-28, both native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed all 19 declared focused selections: SessionSpec (135), AuthoritySpec (277), the ten
new alias fixtures, the positive OperationAdvance result-payload control, the genuine constructor/state
controls, inventory (54) and DocValidatorSpec (17). Both libraries/executables built with package
-Werror. The identical ten fixtures compiled against the pre-change public library, then each refused
with actual GHC-18872 scope/plan nominal diagnostics after the five role annotations. The positive
payload control compiled against the strengthened library.

The complete child command `cabal test all` from `core/` then passed on both hosts with GHC 9.12.4 /
Cabal 3.16.1.0 and package -Werror: Windows 3,377 tests in 517.35 seconds; Linux 3,379 in 385.70 seconds.
Both retained failure-context lists were empty. The provider-live component reported its declared
not-requested result; these runs claim no live provider confirmation. Production changes are exactly
five role annotations in Session.hs. Phase closure still runs its own full gate and all four
host-static commands.

#### Remaining Work

None.

### Sprint 10.2: Canonical Session numeric fields [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`DEVELOPMENT_PLAN/rationale.md`

#### Objective

The Session numeric decoder accepts only one bounded ASCII unsigned-decimal Word64 spelling,
with each caller retaining its own positivity rule.

#### Deliverables

- readWord accepts nonempty ASCII digits, no sign/radix/parentheses/whitespace, no leading zero
  except 0, and at most 20 digits before Integer parsing. Bound by maxBound Word64 and the showWord
  round trip, with no wrap or partial extraction. Existing positive-field checks remain.
- Journal Closing records refuse noncanonical numbers with exact SessionRecordCorrupt project-journal
  error and preserve the seeded record. Tests cover the declared malformed spellings and legal 7/maxBound
  positive controls through real stamped targets. No authority producer or testing seam is added.
- The same private decoder remains used by existing fence and gate fields. Journal ingress exercises
  numeric grammar, without claiming independent fence/gate execution or UTF-8 transport; imported
  Prepared field transport is unchanged and does not trim. Transaction codecs remain separately owned.
- Align numeric rationale and lifecycle docs without moving other fence/state/redo work into this sprint.

#### Validation

SessionSpec's "canonical Closing epochs" group seeds the real project key using the existing
Session.Testing.stampTarget, whose byte renderer mints no permit. Actual stamp, payload and physical
record version are read back before the preservation baseline. readProjectJournalState refuses -1,
+7, 0x7, space-prefix/suffix, (7), 07, 18446744073709551623 and the 21-digit decimal
100000000000000000000 at the exact journal error. Each attempt preserves its seeded image.
Legal 7 and maximum Word64 decode to exact ClosingProject values; zero remains refused by the positive
Closing rule. These journal cases do not separately execute gate or fence admission.

On 2026-10-28, the twelve-case focused group against the preceding parser failed seven controls on
both native Windows and the native-filesystem Linux CPU host, including negative/wrapping and
noncanonical admission. Actual stamped-target setup and the legal maximum-value controls passed.

The same twelve controls passed after the one-helper change on both hosts. Focused validation on
2026-10-28 passed canonical Closing epochs (12), SessionSpec (147), inventory (54) and
DocValidatorSpec (17) on each host. The complete child command `cabal test all` from `core/` then
passed with GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64 passed
3,389 tests in 525.85 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container passed
3,391 in 401.76 seconds. Both retained failure-context lists were empty. The provider-live
component reported its declared not-requested result, not a live confirmation.

The production diff changes only readWord (16 changed lines, one module, no new type or API).
Independently replacing that helper with its captured preceding definition reproduces the complete
validated source bytes; caller positivity checks, Prepared transport and Transaction codecs are unchanged.

#### Remaining Work

None.

### Sprint 10.3: Observed Released-origin admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeReleasedIntentOrigin.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`, `documents/architecture/unrepresentable_state.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Reacquisition registration consumes an opaque observation of one exact ordinary Released record,
with the same protected-store identity, operation key and physical record version still current.

#### Deliverables

- IntentOrigin exposes only NoHistory; its private released-origin payload retains protected-store
  identity, exact RecordKey and physical RecordVersion. readReleasedIntentOrigin derives the key
  from the opaque operation session and operation name and reads the protected transaction record.
  Only the exact durable phase Released mints that origin; no raw flag or caller-selected version
  grants it. The observation does not authenticate backend history or arbitrary payload integrity.
- registerOperationIntent re-reads and validates store/key/version plus current Released phase inside
  its protected entry before the existing transaction. Missing, changed, wrong-key/store or other-phase
  observations return SessionIntentOriginRefused with no mutation. Store/key are checked before
  presence, then phase before physical version, independently exposing changed-state and same-content
  CAS refusals. NoHistory retains absent-only admission.
- Existing TxnRegisterIntent operation/session targets, exact CAS expectations, sorted membership and
  successor permit stay intact. There is no new type/module and no production caller adoption: Chain
  already uses only NoHistory.
- Genuine public prepare/acknowledge/advance controls create Released and AdoptionReleased states.
  The former supplies an accepted origin and exact joined membership; IntentRecorded/AdoptionReleased
  mint none. Same-content CAS independently refuses a stale version; absent, key/store mismatch and
  changed-state controls preserve the complete seeded image. Equal key/version in two stores is refused.
- The exact Session export pin and hidden-constructor child import hold the private variant.
  ForgeReleasedIntentOrigin imports the actual constructor as a child of IntentOrigin; its registered
  rejection matches the observed compiler diagnostic rather than an import of a deleted symbol.
- The declared standards and architecture passages describe observed-origin authority and retain
  Session-state/redo boundaries. The resolved public-flag row is absent from the legacy ledger.

#### Validation

SessionSpec's "observed Released origins" group contains:

- "a Released observation registers exactly once against its live successor";
- "reacquisition is refused from a phase that is not Released";
- "an AdoptionReleased record cannot mint a Released origin";
- "a same-content operation rewrite invalidates a Released origin";
- "a Released origin is refused after its record disappears";
- "a Released origin cannot name another Released operation";
- "a Released origin cannot cross stores with matching key and version";
- "a Released origin is refused when its recorded phase changes".

These use matching public teardown unknown/acknowledgement/advance transitions for the genuine
Released and AdoptionReleased setup, actual physical target versions and live successor permits.
The positive case reuses the accepted origin with the actual successor and refuses IntentRecorded;
the same-content case accepts a fresh observation after refusing the stale one. Registration refusals
pin absent, another protected store, another operation key, a changed record version, or the exact
current phase, with unchanged post-setup images. Equal keys/versions/bytes in two stores isolate the
store check, while two Released keys at equal physical versions isolate the key check.

ForgeReleasedIntentOrigin is an actual constructor-child import. On 2026-10-28 the public GHC
invocation compiled it against the preceding public library (exit 0). Both fixed public libraries/
executables then built with package -Werror; the identical fixture refused with actual GHC-10237
(exit 1), naming the unexported ReleasedReacquisition child of IntentOrigin. That observed contiguous
diagnostic is registered. The focused privacy proof passed on both gate hosts. The observation carries
no effect authority before registration revalidates it.

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container each passed the five focused selections: observed Released origins (8), SessionSpec (154),
ForgeReleasedIntentOrigin (1), exact export/inventory controls (54) and DocValidatorSpec (17).
The complete child command `cabal test all` from `core/` then passed with GHC 9.12.4 / Cabal
3.16.1.0 and package -Werror: Windows 3,397 tests in 528.81 seconds; Linux 3,399 in 403.33 seconds.
Both retained failure-context lists were empty. The provider-live component reported its declared
not-requested result; these runs claim no live provider confirmation.

The production diff is 86 changed lines in Session.hs, with no new type/module/dependency. Independent
before/after comparison keeps the entire registration transaction/membership block and all numeric,
phase and gate-state code byte-identical. Chain still registers only NoHistory.

#### Remaining Work

None.

### Sprint 10.4: Durable fence creation and rotation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceFenceEpochScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceFenceEpochPlan.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceOldPermitsFencedScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceOldPermitsFencedPlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Make "the old generation's permits are dead" a durable fact that survives a crash at any point.

#### Deliverables

- An initial fence epoch is created durably before any permit is issued under it.
- Crash-time rotation proceeds `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved`, so a restart at
  any point resumes **the same proposed epoch** rather than proposing a new one. `currentFence` yields an
  epoch only from `FenceObserved`; an unsettled record is `SessionFenceUnsettled` and an absent one
  `SessionFenceMissing`.
- Rotation proposes a strictly greater epoch and refuses with `SessionFenceInvalid` when the observed epoch is
  `maxBound`, so the live fence never wraps to 0.
- A persisted initial intent that has no fence yet cannot prepare; recovery idempotently completes the stable
  initial-fence protocol and threads its sole successor state/permit values before exposing any continuable
  branch.
- A delayed permit from an older generation is rejected, or deduplicated when it is a retry of one already
  observed.
- FenceEpoch and OldPermitsFenced declare nominal scope/plan roles, as the lifecycle-token rule in
  standards sections EE/HH requires. Four independent newtype-alias coercion probes hold the two axes
  of each retained value; the actual ForgeFenceEpoch constructor control remains. Raw-text observation/
  opening producers still let callers choose result indices and do not authenticate runtime plan,
  scope or store identity. No new public names, changed producer signatures, wire spelling or
  caller adoption are introduced.

#### Validation

SessionSpec's fence-rotation group contains "resuming FenceIntentRecorded keeps the persisted
proposal" and "resuming FenceOutcomeUnknown keeps the persisted proposal": each seeds raw epoch 4,
reopens the store, proposes 77 and reads back exact FenceObserved/4 bytes. The renamed observed-only
resume controls independently retain their already-settled epoch and unchanged protected image.

"currentFence refuses FenceIntentRecorded", "currentFence refuses FenceOutcomeUnknown" and
"currentFence refuses an absent fence" pin the exact unsettled phase or missing-plan error.
"rotation refuses after its observed fence record disappears" retains a genuine token before deleting
its actual fence row; "rotation refuses the maximum observed fence epoch without wrapping" obtains
its maxBound token through currentFence and requires the exact SessionFenceInvalid maximum refusal,
unchanged bytes/version and protected image.

The prepare controls "a prepare refuses an unsettled fence without changing its operation" and
"a prepare presenting the fence that fenceOldPermits superseded is refused" use genuine matching
session/broker/fence/permit values, zero adapter callbacks and unchanged operation images. The latter
pins SessionFenceSuperseded 1 2 and retained IntentRecorded bytes. The admission case "fencing
completes an unsettled proposal before successive rotations" seeds Intent/3 and observes 3→4 then
4→5 with exact Observed records; "fencing establishes an absent fence before rotating" separately
checks the genuine absent path. Touched setup entries, including both fence-set cases, fail on refusal.

The out-of-process controls use --hostbootstrap-fence-delay-probe. A competitor takes a token in one
entry, releases the store while the parent rotates, and presents it in a second entry. The delayed
prepare pins its actual presented/live refusal; a delayed establishment deduplicates to the observed
epoch. The identical probe must prepare successfully across an uncrossed boundary. These executed
process controls are distinct from the seeded interruption-state matrix and claim neither killed-at-
each-write coverage nor live provider acceptance. On 2026-08-05, cabal test all --ghc-options=-Werror
from core/ passed 941/941 on aarch64-osx with GHC 9.12.4.

On 2026-10-28, the single maximum-rotation control against the unchanged implementation failed
on both native Windows and the native-filesystem Linux CPU host: expected the exact maximum refusal,
actual Right 0 (Windows 0.08 seconds; Linux 0.10 seconds). The two-line guard is now implemented.
Run fence rotation, SessionSpec, inventory/docs and complete unfiltered core gates on both hosts.

The four independent CoerceFenceEpochScope/Plan and CoerceOldPermitsFencedScope/Plan files each
compiled against the preceding public library on 2026-10-28 (exit 0). Both fixed libraries/executables
then built with package -Werror, and the identical probes each refused with actual GHC-18872 nominal
scope/plan diagnostics (exit 1). All four observed contiguous phrases are registered. Each probe and
the genuine ForgeFenceEpoch constructor control passed on both available gate hosts. The reported from epoch describes this call's fresh rotation after proposal
resumption; retaining the pre-interruption epoch is the separate recovery-evidence contract.

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed all nine refreshed focused selections: fence rotation (15), SessionSpec (164), each
of the four nominal-role fixtures (1), ForgeFenceEpoch (1), inventory (54) and DocValidatorSpec (17).
The complete child command `cabal test all` from `core/` then passed with GHC 9.12.4 / Cabal 3.16.1.0
and package -Werror: Windows 3,411 tests in 531.01 seconds; Linux 3,413 in 404.89 seconds. Both
retained failure-context lists were empty. The provider-live component reported its declared
not-requested result; these gates claim no live provider confirmation.

The source change adds two overflow-guard lines and two nominal-role annotations, and clarifies the
existing fresh-rotation epoch comments. Independent inverse comparisons reproduce the complete
preceding source. Public signatures, representation, wire spelling and caller adoption are unchanged.

#### Remaining Work

None.

### Sprint 10.5: Closed recorded-operation phase classification [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/rationale.md`

#### Objective

Every recorded operation phase has an explicit recovery classification. Recognized unresolved
outcomes and unrecognized spellings both block admission: the former by named closed-case arms,
the latter through decoder failure.

#### Deliverables

- One private, nullary RecordedPhase vocabulary covers all 43 Reconcile.PersistedJournalPhase names
  plus StepObservedTerminal and RecoveryAbandoned. Enum/Bounded enumeration and exact show-based
  lookup provide canonical decoding with no trimming, aliases or omitted private constructors.
  Public OperationDisposition and classifyRecordedPhase signatures remain unchanged.
- Classify all 45 constructors exhaustively without a wildcard. ReservationOutcomeUnknown,
  EffectOutcomeUnknown, TeardownOutcomeUnknown, AdoptionOutcomeUnknown,
  AdoptionTeardownOutcomeUnknown, RepairEffectOutcomeUnknown and PhaseEffectOutcomeUnknown each
  explicitly yield UnknownDisposition; undecodable text separately takes the fallback. No unresolved
  outcome may become continuable or settled merely because its name is recognized.
- Reserved is Continuable before its next backend call. ObservedManaged, AdoptionObservedManaged,
  RepairObservedTarget and PhaseObservedTo are Settled. RepairObservedAbsent, PhaseObservedAbsent
  and AdoptionTeardownObservedForeign are TerminalDisposition, matching the canonical graph.
- Retain the existing five continuable names and add Reserved, giving six. Preserve the nine-member
  fenced-retry whitelist: observed reservation/effect/adoption absence, repair-original and
  managed-phase-from, plus the actual explicit fenced-retry names. Same-identity ordinary/adopted
  teardown returns to Committed/AdoptionCommitted, never an invented teardown-presence retry.
- Settled and terminal classifications grant no further effect authority. Observed-success
  classification alone writes no Committed state and mints no PriorCommitProof or ownership receipt.
  Keep the existing live no-effect controls; numeric fields, live gates and complete membership
  remain separate contracts.
- SessionSpec has an explicit literal expected class for every name, plus unknown-text and canonical
  alias/whitespace controls. A narrow SourceGuard nullary-data-declaration reader reuses the shared
  declaration blocks and lexer, rejects unsupported/ambiguous shapes, and has compact semantic
  controls for comments, strings, other types, missing/duplicate declarations, fields, records,
  GADTs, duplicate/empty constructors and malformed syntax. Compare the 43 producer rows with the
  exact Reconcile declaration and all 45 with the exact private RecordedPhase declaration.
- Correct classifier/disposition Haddocks and the canonical docs: distinguish seven known unresolved
  arms from fallback, remove the obsolete five-only count and teardown-presence retry claim, and
  explain the scoped vocabulary guard in the recovery rationale. The enum-derived decoder and
  exhaustive cases receive source review; equal public Unknown results do not prove private decoding
  versus fallback, and no fake literal inventory or new testing authority seam is introduced.

#### Validation

SessionSpec's "recorded phase dispositions" group contains 45 literal cases. Its sibling
"the literal phase rows cover both authoritative declarations" pins vocabulary parity; "nullary phase
vocabulary reader" contains seven semantic controls. Unknown fallback and "phase spellings are exact
rather than normalized" remain independent. Run the literal matrix against the preceding implementation to expose
the eight missing recognized mappings, then validate all 45 expected classes against the closed
classifier. Run the declaration-reader semantic matrix and exact 43/45 vocabulary parity, canonical
alias/whitespace and unknown fallbacks, existing no-effect branches, inventory and DocValidatorSpec
on both hosts, followed by unfiltered core gates with package -Werror. Review exact enum-derived
lookup and named exhaustive arms for the seven known unresolved cases, whose public Unknown result
cannot distinguish successful decoding from fallback. This is one closed classifier contract,
with no new authority producer or recovery seam.

On 2026-10-28, the literal matrix against the preceding classifier failed exactly eight of 45
cases on both hosts (Windows 0.04 seconds; Linux 0.06 seconds). Reserved, the four observed-success
states and the three added terminal states incorrectly returned UnknownDisposition. The other
37 cases, including all seven known unresolved outcomes, matched their declared dispositions.

The saved private enum-derived decoder covers all 45 canonical names, with a separate decode-failure
fallback and 45 explicit classifier arms. Source review confirms no wildcard and no private decoding
filter; known unresolved cases each reach their named blocking arm. Source outside classification,
including journal/session/fence/prepare/recovery code and public exports, is unchanged.

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container each passed phase classification (55), SessionSpec (214), inventory (54) and
DocValidatorSpec (17). The complete child command `cabal test all` from `core/` then passed with
GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: Windows 3,461 tests in 528.45 seconds;
Linux 3,463 in 402.70 seconds. Both retained failure-context lists were empty. The provider-live
component reported its declared not-requested result; these runs claim no live provider confirmation.

The final production diff changes 194 lines in Session.hs, one private named type and one module.
Independent before/after review preserves source outside the classification block byte-for-byte.
The 45 literal rows and seven declaration-reader controls exercise the closed vocabulary contract;
the known-unresolved decoder/fallback distinction is held by the reviewed exact decoder and exhaustive
named arms, rather than inferred from identical public UnknownDisposition results.

#### Remaining Work

None.

### Sprint 10.6: Exact recorded-operation numeric fields [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A missing or malformed recorded fence or attempt cannot silently become zero during prepare or
recovery abandonment. The actual initial-intent writer remains valid, and a valid maximum attempt
cannot wrap to zero when preparing its successor.

#### Deliverables

- `recordedFenceOf` and `recordedAttempt` return `Maybe` and consume the existing canonical Session
  numeric grammar. Prepare and the recovery abandon write propagate invalid required fields as
  `SessionRecordCorrupt "operation record"` before their transaction; neither defaults corruption to 0.
- Preserve the actual canonical initial writer: `IntentRecorded` has exactly three fields
  `["IntentRecorded", sid, "0"]`, with implicit attempt 0. That admitted initial shape may prepare its
  first attempt or be abandoned in recovery. It is not a malformed later record missing an attempt.
- Later operation records requiring an attempt must carry that field and a decodable fence. Missing,
  noncanonical or corrupt later numeric fields refuse rather than inheriting the initial-shape exception.
  Preserve existing field transport, wire spelling and caller positivity rules.
- Preparing a valid maximum Word64 attempt returns `SessionAttemptExhausted opKey` before addition,
  transaction or callback. Add that constructor to the existing SessionError sum and its exhaustive
  renderer: `session: operation <op> has exhausted its attempt counter`. Preserve the existing
  fresh-retry-fence refusal priority. Maximum-minus-one advances to the maximum; recovery abandonment
  does not increment and therefore preserves a valid maximum attempt.
- SessionSpec prepares a genuine three-field registered intent and observes attempt 1, and covers its
  valid recovery-abandon path. Eligible continuable/retry records with missing, invalid or noncanonical
  required fence/attempt fields refuse prepare and recovery abandonment with exact corruption errors
  and unchanged post-setup images. Cover maximum exhaustion, its same-fence refusal priority,
  maximum-minus-one success and maximum-preserving recovery. No new raw authority producer is introduced.

#### Validation

SessionSpec's "recorded operation numeric admission" group contains 18 cases. The positive cases are
"a genuine three-field initial intent prepares attempt one" and "a genuine three-field initial intent
abandons with attempt zero". Each of corrupt/missing/noncanonical retryable fence and
corrupt/missing/noncanonical continuable attempt has separate "prepare refuses ..." and
"recovery refuses ..." cases. The counter controls are "an eligible maximum attempt refuses before
recording unknown or entering the adapter", "maximum minus one advances to the maximum attempt
exactly", "a same-fence maximum attempt keeps the fresh-fence refusal priority", and
"recovery preserves a maximum attempt without incrementing it".

Run SessionSpec's initial-writer positive, malformed-field refusal and attempt-boundary controls,
inventory/docs and complete core gates on both hosts. Seed malformed eligible records only after
genuine setup, use a genuinely fresher fence for retry cases, assert
`SessionRecordCorrupt "operation record"`, and verify no callback or abandonment write. Capture recovery
refusal baselines after genuine fencing/manifest setup and corruption; this is not batch rollback evidence.
The real three-field writer must continue through both declared positive paths; blanket four-field
rejection cannot satisfy this contract. Canonical maximum attempts must be parsed successfully: a
maximum-minus-one prepare reaches maximum exactly, eligible maximum prepare refuses with the typed
exhaustion error and no mutation/callback, the same-fence retry still reports its existing fence error,
and abandonment retains maximum without increment. Demonstrate semantic numeric/max refusals against
the preceding behavior without mistaking a missing-constructor compilation error for a failing test.
Session's canonical number helper is retained, not independently rewritten. Prepared/Transaction
transport, codecs and caller positivity rules remain outside this contract.

On 2026-10-28, the eighteen-case group compiled against the preceding implementation and failed
exactly thirteen cases on both hosts (Windows 5.77 seconds; Linux 7.48 seconds). All twelve required-field
refusal cases instead succeeded. The eligible maximum case minted a gate at attempt 0, entered its
callback once and persisted `EffectOutcomeUnknown/session-a/2/0`. The two genuine initial-intent
positives, maximum-minus-one success, same-fence priority and maximum-preserving recovery passed.
The maximum refusal staged its exact rendered diagnostic without referencing a constructor absent
from the preceding public sum; its failure was semantic, not a compilation failure.

The saved implementation composes both optional numeric readers before either eligible prepare or
abandonment write. Both continuable and retryable prepare share that pair check; the existing retry-fence
refusal precedes exhaustion. Only the admitted path increments, while abandonment copies the valid attempt.
Independent before/after source review confines the production change to fewer than 100 lines in Session.hs,
with no new named type, import, producer or caller adoption. The existing SessionError sum adds the declared
exhaustion constructor and renderer; canonical readWord, field transport, classifier and transaction bodies
retain their preceding behavior. Later trailing-field extraction remains unchanged.

On 2026-10-28, the fixed eighteen-case numeric group passed on native Windows (5.70 seconds) and
the native-filesystem Linux CPU host (7.30 seconds). The maximum case now pins both
`SessionAttemptExhausted "op-1"` and its exact renderer, with zero callbacks and unchanged seeded image.
All SessionSpec cases passed (232; Windows 43.18 seconds, Linux 45.82 seconds), as did inventory (54)
and DocValidatorSpec (17) on each host.

The complete child command `cabal test all` from `core/` then passed on 2026-10-28 with
GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64 passed 3,479 tests in
535.87 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container passed 3,481 in
416.96 seconds. Both retained failure-context lists were empty. The provider-live component
reported its declared not-requested result; these runs claim no live provider confirmation.

#### Remaining Work

None.

### Sprint 10.7: Live prepare and acknowledgement admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Prepare and acknowledgement admit only the live session, fence, gate and declared phase categories,
while the shared journal permit excludes stale prepare/close attempts. This Session admission policy
is distinct from Reconcile's family-specific persisted-graph edges.

#### Deliverables

- `withPreparedGate` canonically decodes the Open session's durable marker with the existing readWord;
  malformed input refuses `SessionRecordCorrupt "session"`. A mismatch returns
  `SessionBrokerEpochMismatch durableMarker (brokerEpochWord epoch)`. Keep the existing retained-session
  broker comparison and journal-permit refusal priority. A closed session with the live successor
  permit refuses `SessionNotOpen`.
- Prepare accepts only an outcome-unknown phase: `ReservationOutcomeUnknown`, `EffectOutcomeUnknown`,
  `AdoptionOutcomeUnknown`, `RepairEffectOutcomeUnknown`, `PhaseEffectOutcomeUnknown`,
  `TeardownOutcomeUnknown` or `AdoptionTeardownOutcomeUnknown`. Recognize these exact private decoded
  constructors, rather than UnknownDisposition, which also covers unrecognized text. Reject other
  requests after the existing numeric/retry/exhaustion checks and before transaction or callback.
- `acknowledgeOutcome` checks an Open session and the live observed fence after the journal permit and
  before operation mutation. Keep gate plan/session checks and durable gate/version checks. The recorded
  phase must be one of the seven known unknowns; the presented outcome must classify as Settled,
  TerminalDisposition or FencedRetryable. Refuse other pairs with
  `SessionOutcomePhaseRefused opKey recorded presented`, adding that constructor to SessionError and
  rendering `session: operation <op> refuses outcome phase <presented> from <recorded>`. A superseded
  gate refuses `SessionFenceSuperseded (preparedGateFence gate) live`. This is category admission,
  not family-specific graph validation; preserve existing generic Session settlement paths.
- Tests cover all seven admitted prepare names, refused `"Committed"` and unrecognized requests, and
  acknowledgement refusals for `"IntentRecorded"`, `"ReservationRetryFenced"` and a known unknown target.
  Preserve operation bytes and exclude callbacks on refusal. Three cases formerly acknowledging
  `"SomeFuturePhase"` seed their stamped durable record through compare-and-swap instead; the ordinary
  acknowledgement path may no longer create an unlawful target category.
- A genuinely different broker generation pins the existing retained-session refusal. Separately change
  only the durable marker while retaining matching original session/epoch and a live permit, proving the
  new durable comparison; malformed-marker input pins its exact corruption refusal. After fenceOldPermits,
  delayed acknowledgement retains EffectOutcomeUnknown and refuses as superseded. Closed-session prepare
  and acknowledgement use the actual live close successor to isolate SessionNotOpen from stale permits.
- Genuine gates from another session or plan pin `SessionPreparedGateMismatch "session"` or `"plan"`.
  The prepare callback reads through its held ProtectedSession and requires exact durable fields
  `["EffectOutcomeUnknown", sid, fence, "1"]`. Exercise the recorded-phase guard independently using
  the existing public Prepared.recordDurableUnknown producer to install Committed and mint its matching
  physical-version gate, then require the exact category refusal. This adversarial fixture neither adds
  a producer nor closes that existing producer's separately scheduled legacy boundary; a CAS after an
  old gate would only prove stale-version refusal.
- Replace `prepareCloseRaceCase` with deterministic permit-only exclusions. After prepare with P1 and
  acknowledgement as Committed yielding P2, close with P1 refuses `SessionStaleProjectPermit v1` while
  the session stays Open; close with P2 succeeds. After closing with P2 yielding P3, prepare with retained
  P2 refuses `SessionStaleProjectPermit v2` and leaves the operation unchanged. Observe each winner's
  exact durable state, not merely isRight.
- Correct closeOperationSession's Haddock to name the shared project-journal permit, and
  acknowledgeOutcome's Haddock to describe its actual category policy without claiming the full graph.
  Keep successor threading, registration, numeric refusals and complete membership's separate ownership.
  Reconcile withStepPreparedGate's adjacent Haddock with the existing nominal roles: the raw-text producer
  leaves its indices caller-instantiable, so the runtime plan comparison remains required. Align lifecycle
  docs with these admission checks and ordered evidence; add no public authority producer.

#### Validation

SessionSpec's "live operation admission" group contains 21 cases: seven "prepare admits ..." names,
requests for Committed/SomeFuturePhase, acknowledgement targets IntentRecorded/ReservationRetryFenced/
EffectOutcomeUnknown, the matching recorded-Committed gate, an actual different broker generation,
durable-marker drift/noncanonical input, live-permit closed prepare/acknowledgement, a superseded-fence
acknowledgement, and genuine foreign-plan/session gates. "a prepare records the unknown phase before
the adapter runs" now directly reads its held entry's exact operation fields. The ordered cases are
"an acknowledged prepare excludes close with its retained permit" and "a closed session excludes
prepare with its pre-close permit"; the former retains the actual pre-prepare P1 and checks that
prepare advances it before acknowledgement yields P2. Three existing future-phase fixtures now use
stamped durable mutations without asking acknowledgement to publish an unlawful target category.

SessionSpec pins every phase, session, broker, fence and gate refusal above by its exact constructor
and preserves the affected operation bytes/image. Existing Committed, ObservedForeign and EffectAbsent
acknowledgements retain positive coverage of the three admitted target categories; no full graph-edge
claim follows. The durable-marker mutation must retain the original matching opaque session and epoch;
a second broker alone only reaches the earlier comparison. Gate/version coordinates must still match
when the recorded-phase guard is exercised through the existing producer. A live-permit closed-session
refusal is distinct from the stale-permit closed-session control. Run these selections, inventory/docs
and unfiltered core gates on both hosts. The ordered exclusion controls establish the two same-permit
orders, not a simultaneous race. The adapter's direct readback establishes durable unknown-before-effect
ordering. Avoid nested protected entries and record the actual canonical phase cases when they exist.

On 2026-10-28, the 21-case admission group compiled against the preceding implementation and failed
exactly ten cases on both hosts (Windows 5.26 seconds; Linux 7.10 seconds). It wrongly accepted two
invalid prepare requests, three invalid acknowledgement targets, the recorded-Committed acknowledgement,
both durable-marker inputs and the superseded-fence acknowledgement. Closed-session acknowledgement
returned `SessionStaleJournalVersion 2 3` instead of SessionNotOpen. The seven admitted prepare names,
actual foreign broker generation, live-permit closed prepare and two foreign-gate refusals passed.
Phase-error cases staged the exact renderer without referencing the not-yet-existing constructor;
these failures were semantic rather than missing-constructor compilation failures.

The saved implementation recognizes the seven private decoded unknown constructors separately from
unknown-text fallback. Its explicit disposition cases admit only the three declared observation
categories. Prepare keeps numeric/retry/exhaustion priority; acknowledgement retains gate prefix and
journal-permit checks before its live session/fence and durable gate/phase checks. The exact typed
phase-error assertion now accompanies the renderer assertion. Independent before/after review confines
production changes to fewer than 200 lines in Session.hs, with no new type, import, producer or caller
adoption. Numeric readers/recovery abandonment, the classification vocabulary, transaction bodies and
roles retain their preceding behavior. The owned Haddocks now describe shared-journal exclusion,
category admission and the existing nominal roles/raw-text producer boundary accurately.

On 2026-10-28, the fixed 21-case admission group passed on native Windows (6.20 seconds) and the
native-filesystem Linux CPU host (7.82 seconds). The phase refusals now pin both the exact
SessionOutcomePhaseRefused constructor fields and renderer. SessionSpec passed all 254 cases
(Windows 50.31 seconds; Linux 53.89 seconds), including the corrected pre-prepare P1 and closed-session
P2/P3 ordered controls, direct callback readback and three stamped future-phase fixtures. Inventory
(54) and DocValidatorSpec (17) passed on each host.

The complete child command `cabal test all` from `core/` then passed on 2026-10-28 with
GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64 passed 3,501 tests in
544.53 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container passed 3,503 in
419.76 seconds. Both retained failure-context lists were empty. The provider-live component
reported its declared not-requested result; these runs claim no live provider confirmation.

#### Remaining Work

None.

### Sprint 10.8: Complete session operation membership [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceVerifiedAllSessionsClosedScope.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceVerifiedAllSessionsClosedPlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

A listed operation without its record cannot count as settled or disappear from session recovery,
and retained all-sessions-closed evidence cannot be re-indexed by coerce.

#### Deliverables

- VerifiedAllSessionsClosed has nominal scope/plan roles, with independent local-newtype-alias
  public compiler proofs for each axis. Retain its actual abstract-module export pin; a dedicated
  constructor-forgery compiler fixture remains owned by Sprint 18.25, rather than being claimed as
  already executed here. Reconcile allSessionsClosedPlanDigest's adjacent Haddock: held values cannot
  be coerced across nominal indices, while the raw-text producer leaves its result indices caller-chosen
  and the runtime bound-lease plan comparison remains required. The producer is an observation, not
  runtime plan/scope/store authentication. Create the two real role-probe files and record their
  Implementation paths only when they exist.
- `unsettledOperations` and `classifySessionOperations` return `SessionOperationUnregistered name`
  for a listed operation whose record is absent, matching the existing prepare refusal.
- SessionSpec genuinely registers op-1, deletes its record, and requires both `closeOperationSession`
  and `recoverAbandonedSessions` to refuse with that exact constructor while the session stays Open.
  Capture preservation baselines after mutation; do not claim rollback for unrelated recovery work.
- In "an abandoned session is closed and its continuable work counted" and "a sweep with nothing open
  reports no work", check setup through `runEntry` or `expect =<< inEntry ...`. Refused session opening,
  registration or journal setup must fail the case rather than leave an empty store satisfying counts.
- Retain independent session/operation enumeration, exact membership and all existing recovery cases.
  The classifier remains the input to the owning recovery interpreter, not a new producer or test seam.
- ChainSpec's existing root-current-frame fixture retains CLI stderr and observed callback labels on
  failure instead of collapsing every refusal to ExitFailure 1. Reuse the existing portable stderr
  capture pattern in the test harness; preserve the public CLI path and exact success/order assertions.
  This bounded diagnostic support identifies any missing-member refusal during the full gate.

#### Validation

SessionSpec's "recordless session members" group contains "a listed operation without its record
prevents session close" and "a listed operation without its record prevents abandoned-session
recovery". The shared fixture checks actual canonical registration/membership, deletes the exact
operation key at its physical version, and captures a post-deletion image. It reads the retained
Open session target directly for preservation. "an abandoned session is closed and its continuable
work counted" and "a sweep with nothing open reports no work" now require successful setup before
asserting their counts. The two role probes are CoerceVerifiedAllSessionsClosedScope.hs and
CoerceVerifiedAllSessionsClosedPlan.hs, each using a local newtype alias on exactly one axis.

Capture actual before/after public-GHC scope and plan coercion outcomes for the closed-session
witness, register the observed diagnostics, then run both exact recordless-member refusals and the
checked-setup sweep controls with the existing SessionSpec recovery families, inventory/docs and
complete core gates on both hosts. The existing export pin holds abstraction; this run claims no
constructor-forgery proof owned elsewhere. Before deletion verify genuine canonical op-1 membership;
after deletion read the session's durable Open bytes/version directly, since manifest verification
may itself refuse the missing member. An empty-store
result is not evidence for a setup that was refused. Assert the listed session's durable Open state
after each missing-record refusal.

On 2026-10-28, both actual local-newtype role probes compiled against the preceding public main
library on native Windows and native-filesystem Linux (exit 0 for both axes on both hosts), using the
pinned GHC 9.12.4, explicit public package databases and no private sublibrary exposure. The two-case
recordless-member group then failed on both hosts (Windows 0.35 seconds; Linux 0.47 seconds): both
close and recovery returned Right () instead of `SessionOperationUnregistered "op-1"`. Genuine
registration, membership, physical-version deletion and the seeded-state checks completed before
those semantic failures.

Independent before/after source comparison confirms exactly 12 changed production lines in Session.hs:
one role annotation, two listed-member missing-record refusals and the adjacent getter Haddock. The
representation, exports and function signatures, raw-text producer, transaction/recovery order, legacy discovery,
classification and numeric/gate behavior remain unchanged. The two role probes and runtime cases
retain their measured preceding definitions; rejection is measured only after the public library rebuild.

On 2026-10-28, `cabal build all` rebuilt the public library and executable successfully on both
hosts with package -Werror. The identical direct public-GHC commands then rejected both unchanged
alias probes on both hosts (exit 1, GHC-18872), identifying Scope versus ScopeAlias or Plan versus
PlanAlias at the actual use of coerce. Those observed contiguous diagnostic phrases were registered
only after measurement. The preceding exit-0 controls and fixed exit-1 results independently hold
both axes' nominal-role boundary; no constructor-forgery or runtime-origin proof is inferred.

Focused validation completed on 2026-10-29 UTC. Both hosts passed the two recordless-member cases
(0.42 seconds each host), SessionSpec (256; Windows 47.22 seconds, Linux 50.27 seconds), both
registered coercion cases (one each), inventory (54) and DocValidatorSpec (17). The runtime refusals
pin `SessionOperationUnregistered "op-1"`, unchanged direct Open-session bytes/version and the full
post-deletion image. Checked setup in the two sweep controls also passed. The complete gate results are recorded below.

The first complete core gate on 2026-10-29 UTC passed on native-filesystem Linux (3,507 tests in
420.99 seconds) but failed one of 3,505 on native Windows (539.70 seconds). ChainSpec's "one root
LifecycleEntry and one reservation drive the full current frame" returned only Left "ExitFailure 1".
The same unchanged case then passed in isolation on both hosts (Windows 0.69 seconds; Linux
0.68 seconds). Those isolated passes do not close the failed full leg. The cause is not established;
the serial suite and fresh store alone do not prove it transient. That failure owed diagnostic
support plus focused and repeated full validation; the subsequent evidence follows.

The bounded ChainSpec diagnostic change retains the same public CLI call and test cases, brackets
stderr duplication/restoration using an owned system-temporary file, and fully reads the diagnostic
before cleanup. A failed root-current-frame assertion now includes the actual stderr and callback
labels; the exact Right (), expected order and invocation-count assertions remain. This changes no
production behavior and does not explain the preceding unreproduced failure by itself.

With those diagnostics on 2026-10-29 UTC, the root-current-frame case passed on Windows
(0.71 seconds) and Linux (0.64 seconds), followed by all 48 ChainSpec cases on each host
(Windows 23.81 seconds; Linux 20.97 seconds). The earlier failure has not reproduced and its cause
remains unestablished. Those focused passes were not substituted for the failed Windows full leg;
the complete reruns below supply the current gate evidence.

The repeated complete child command `cabal test all` from `core/` passed on both hosts on
2026-10-29 UTC with GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64
passed 3,505 tests in 544.05 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
passed 3,507 in 424.81 seconds. Both retained failure-context lists were empty. The original Windows
failure did not recur; its cause is not claimed resolved by the diagnostic-only change. The provider-live
component reported its declared not-requested result; these runs claim no live provider confirmation.

#### Remaining Work

None.

### Sprint 10.9: Canonical transaction wire admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`

#### Objective

The transaction coordinator admits only its encoder's complete canonical record spelling, with
strict UTF-8 scalar transport, bounded numbers and exact typed Session refusals. Protected identity
admission retains its existing ASCII grammar; Unicode codec data is observed independently of
identity or redo authority.

#### Deliverables

- `encodeLine`/`decodeLine` transport scalar coordinator text as UTF-8 with strict decoding. Invalid
  UTF-8 returns `TransactionMalformed "transaction text is not UTF-8"`. Preserve transaction-v1 and
  the legitimate unstamped-target observation branch. Stamped/unstamped payload bytes remain opaque;
  coordinator desired payloads and exact expectations retain their existing hex transport.
- Coordinator and stamped-target numeric fields admit canonical ASCII unsigned decimal within Word64,
  using a bounded Integer parse rather than wrapping. No sign, alternate base, parentheses, whitespace
  or leading zero other than 0 is admitted. Preserve existing positive-stamp/version/exact-expectation
  rules and canonical Idle 0; add no arbitrary new sequence or count policy.
- The complete decoded coordinator record must round-trip encodeCoordinator to its original bytes;
  otherwise return `TransactionMalformed "the coordinator record is not canonical"`. Independent
  trailing-LF and valid uppercase-hex controls distinguish this from scalar-only checking. Recognized
  stamped envelopes likewise reproduce stampTarget exactly, including their required newline, or
  return `TransactionMalformed "a stamped target is not canonical"`. Keep existing missing/invalid-id
  reasons and all arbitrary payload bytes; preserve the legitimate unstamped branch byte-for-byte.
- transactionFailure explicitly matches all five TransactionError constructors without a wildcard.
  Map TransactionStoreFailure to SessionStoreFailure, TransactionMalformed reason to
  SessionRecordCorrupt reason and TransactionStalePermit to SessionStaleProjectPermit. Explicitly
  retain the existing SessionTransactionFailure diagnostics for TransactionInvalidTargets and
  TransactionTargetConflict. Ordinary openProjectJournal refuses malformed coordinator bytes without
  changing targets.
- Forward the existing pure decodeCoordinator through the internal Transaction export and existing
  Session.Testing value vocabulary, beside encodeCoordinator. It returns descriptive data and mints
  no permit, runner or authority. Add only this forwarding scaffolding before semantic RED, retaining
  the preceding codec implementations and error mapping so tests fail on behavior. A pure Unicode
  descriptor-plan DATA control independently pins U+0441 header bytes D1 81, actual encoder output,
  the decoder's exact Text and complete re-encoding. It claims neither admitted identity nor redo.
- A public openOperationSession request containing U+0441 pins the existing exact Protected ASCII
  refusal and unchanged post-setup image; key admission occurs before its transaction. Separately
  interrupt a genuine ASCII TxnOpenSession after Applying, read back the actual descriptor/encoding,
  reopen through ordinary openProjectJournal and require its exact single session key, captured
  payload/stamp and canonical Idle successor. Its absent new target avoids existing-target version
  reconstruction ambiguity; this does not certify every later redo fixture as faithful.
- SessionSpec covers canonical Idle/Applying/stamped and legitimate unstamped opaque-byte positives,
  strict UTF-8 and numeric refusals, and independent whole-record spelling refusals. Idle sequence
  18446744073709551616 and target stamp 18446744073709551617 refuse instead of wrapping to 0 or 1.
  The stamp case must use an ordinary reader that reaches that target; an Idle coordinator read alone
  cannot prove it. Seed/read back mutations before preservation baselines, pin exact mapped errors
  and full images. Align the two owned docs and the decoder forwarding's data-only Haddock.

#### Validation

SessionSpec's "canonical transaction wire" group contains 20 cases. Its six initial controls are
"Unicode descriptor data uses exact UTF-8 in both codec directions", "a Cyrillic session identity
retains the public ASCII refusal", "canonical Idle zero and bounded sequences are observed without
writes", "an actual ASCII Applying session recovers its sole exact target", "stamped and unstamped
target payloads preserve opaque bytes", and "invalid coordinator UTF-8 refuses before target
observation". Nine independent "an Idle sequence refuses ..." cases cover the declared spellings.
The remaining controls are "Applying sequence count and expectations require canonical numbers",
"an overflowing target stamp cannot wrap to one", "recognized target envelopes require canonical
positive stamps and a newline", "an otherwise valid coordinator refuses a trailing newline", and
"otherwise valid Applying payload hex must retain its lowercase spelling".

Run the complete wire matrix through ordinary entry/target readers, plus the actual pure codec
round-trip observer. Unicode scalar data, public Unicode identity refusal and genuine ASCII interrupted
session recovery are three distinct controls: the existing Protected record-name grammar rejects
non-ASCII session identities before transaction encoding, so a Unicode session recovery assertion
would be uninhabited. The pure observer must preserve U+0441 itself and independently pinned UTF-8
bytes, while accepted runtime identities retain their exact actual key with no extra session record.

Accepted coordinator and recognized stamped-envelope records must reproduce every encoder byte;
invalid UTF-8 or overflowing integers alone do not establish canonical record admission. Verify
canonical binary payloads containing FF/NUL remain opaque. Run inventory/docs and complete core gates
on both hosts. This is one codec/error-projection contract across three production modules, with no
new type, dependency, permit producer, runner or runtime test branch. Full faithful reconstruction,
foreign-plan/target-policy redo and the testing sublibrary's visibility remain separately owned.

The initial forwarding stage on 2026-10-29 UTC adds exactly three declaration lines: the existing
pure decodeCoordinator export in Transaction and its import/re-export in Session.Testing. Independent
before/after comparison preserves every encoder, decoder and Session error-mapping function byte for
byte. The semantic RED stage therefore exercises the preceding codec behavior rather than failing on
an unavailable observer symbol. The two owned docs are prepared; no new validation results are claimed.

An initial test build on both hosts reported GHC-25897 because two new helper signatures were more
general than the existing unit-returning store fixture. Both helpers were specialized to IO (); no
case, assertion or production behavior changed. That compilation failure is not semantic RED evidence.

On 2026-10-29 UTC, the corrected 20-case group executed against the preceding codec and error
mapping (with forwarding only) and failed sixteen cases on both hosts: Windows 1.42 seconds,
Linux 1.92 seconds. The Unicode header encoded U+0441 as ASCII A; malformed numeric/byte spellings
were either admitted or surfaced the wrong typed reason. The overflow stamp wrapped to one, and
otherwise valid trailing-LF/uppercase-hex records were admitted. The public ASCII identity refusal,
canonical Idle bounds, genuine ASCII Applying recovery and opaque stamped/unstamped payload controls
passed. These executed failures, rather than the preliminary build error, are the semantic RED evidence.

The saved candidate uses strict coordinator scalar decoding before complete encoder equality,
canonical bounded Integer-to-Word64 admission, and an exact recognized-stamp reconstruction that
requires its newline while leaving arbitrary payload bytes and unstamped observations unchanged.
All five Session transaction-error arms are explicit. Independent source comparison confines the
change to fewer than 100 production lines across the three declared modules, including the three
forwarding declarations; transaction execution, redo policy, Protected identity grammar and module
visibility are unchanged. Decoder/header refusal categories and the two owned docs match the declared
contract, and the original recovery families/helpers remain unchanged.

Focused validation on 2026-10-29 UTC passed all 20 wire cases on both hosts (Windows 1.51 seconds;
Linux 1.95 seconds), SessionSpec (276; Windows 50.17 seconds, Linux 57.26 seconds), inventory (54)
and DocValidatorSpec (17). The existing recovery families and new Unicode-data/ASCII-identity,
absent-target recovery, opaque-byte, bound/overflow and whole-record cases all passed. A final
wording correction states the existing testing unit is already private and Sprint 10.13 corrects
Transaction's exposed-modules slot; the complete gates include those final docs.

The complete child command `cabal test all` from `core/` passed on both hosts on
2026-10-29 UTC with GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64
passed 3,525 tests in 547.55 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
passed 3,527 in 430.20 seconds. Both retained failure-context lists were empty. These gates include
the final owned documentation and all existing recovery families. The provider-live component
reported its declared not-requested result; these runs claim no live provider confirmation.

#### Remaining Work

None.

### Sprint 10.10: Faithful plan-bound transaction redo [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeTransactionPermitFromDescriptor.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`

#### Objective

A recovery fixture reproduces the actual transition's durable interruption prefix, and ordinary redo
refuses descriptors that do not belong to its plan or exact target states.

#### Deliverables

- Construct interruption as a durable value: Applying plus the first n actually stamped targets.
  Run the real transition once, capture its keys/roles/payloads/transaction id, restore the exact
  pre-transition directory snapshot, and rebuild its descriptor against those original physical
  versions. Rebuilding through APIs would advance versions and is not a faithful expectation.
  Before the first TxnOpenProject snapshot, call public readProjectJournalState, require
  `Left (SessionProjectMissing plan)` and verify the resulting canonical CoordinatorIdle 0 metadata.
  Snapshot after this real coordinator precondition, without creating a project or manufacturing a
  permit, so reconstructed Applying retains the uninterrupted transition's physical version.
- `Session.Testing` supplies only the private coordinator/descriptor/kind/target/encoder/readback
  vocabulary, with no permit constructor, extra key minter or transaction runner. The public fixture
  cannot import it. Its separate Transaction-module visibility correction remains in Sprint 10.13.
- Retain the no-crash-point production path: `runLifecycleTransaction`, `recoverApplying` and
  `applyTargets` carry no injected stop or per-target crash counter. PortabilitySpec's existing
  standards section NN absence guard cites the Gates and validation rationale and checks every shipped
  module. Give `ForgeTransactionPermitFromDescriptor.hs` its required OverloadedStrings pragma,
  then measure a private-unit-visible successful compile and the ordinary public-only hidden-unit
  refusal. The historical filename proves a private DATA-vocabulary import boundary, not permit
  construction or the separate internal Transaction-module exposure boundary.
- `ensureTransactionCoordinator` refuses `TransactionMalformed "a descriptor names another coordinator"`
  when descriptorPlan differs from the requested plan, as `recoverProductionTransactions` already does.
  A plan-A coordinator containing plan-B work must refuse through ordinary entry and write neither
  plan's targets. Preserve validation of target ownership and TxnKind role order.
- Add Applying-descriptor refusals for an out-of-plan target, a role order inconsistent with TxnKind,
  and a target in a third state. Ordinary `openProjectJournal` returns the exact mapped
  `TransactionInvalidTargets` or `TransactionTargetConflict` detail via `SessionTransactionFailure`,
  with no target mutation. `applyProductionTarget` receives/reports the descriptor's real sequence n,
  not 0, in its conflict; canonical malformed-record mapping remains supplied by Sprint 10.9.
  For the seeded Production third-state control, materialize the valid earlier project-target prefix
  before the preservation baseline, then change the exact lease's physical version without changing
  its original bytes. This observes admission/conflict behavior without claiming batch rollback.
- `faithfulDescriptorCase` reads the actual coordinator before recovery: Applying, published sequence,
  TxnOpenProject and one project target whose desired bytes and expectation equal the uninterrupted
  capture. `openProjectRecoveryCase` observes Open via `readProjectJournalState` before reopening and
  checks the permit against the uninterrupted transition's exact committed successor version.
- `installApplying` checks the actual published target count against the kind's role count before
  publication: two for TxnRegisterIntent, one for each other kind among the eight declared families.
  AfterTarget n must satisfy 0 <= n <= that count; zero denotes the empty prefix and negative or
  overlong takes refuse before publication. This bounded fixture does not impose those counts on
  Production or other transaction families.
- Keep all twenty-five prefix cases across open project/session, register intent, prepare,
  acknowledge, close session, begin close and record Closed, plus the shared faithfulDescriptorCase
  (twenty-six checks). The seven single-target families each have three prefixes and register-intent
  has four. Live effects and testing-visibility work are not added to this contract. Align the two
  owned docs with the actual evidence.

#### Validation

Run the existing twenty-five durable-prefix cases plus the shared faithfulDescriptorCase, retaining
all other recovery-group controls. Run the descriptor/ownership/role/third-state refusals, exact
Production conflict-sequence control, faithful Applying readback before recovery, initial public
Missing/Idle 0 precondition, pre-open recovered state and exact uninterrupted-successor permit check,
and bounded target-count/prefix checks. Inventory, both actual private-vocabulary fixture compilation
modes, PortabilitySpec absence guard, DocValidatorSpec and unfiltered core gates run on both hosts.
Fixtures write the coordinator's own encoding and re-enter the ordinary driver; production has no
test branch. The seeded Production conflict control preserves the image after a valid earlier prefix,
not an image before that prefix.

SessionSpec's "plan-bound transaction redo" group names five cases: "an Applying descriptor cannot
name another coordinator", "an Applying target cannot escape its transaction plan", "RegisterIntent
target order matches its closed kind", "a third-state Session target refuses redo", and "a Production
conflict retains the descriptor sequence". The retained "the reproduced interruption is the
transition's own descriptor" case reads the actual Applying descriptor and exercises negative,
overlong, wrong-count and unsupported-kind fixture refusals before publication, plus a real empty
AfterTarget 0 prefix. The eight families retain their existing twenty-five mapped prefix cases.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 237.07 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

On 2026-10-29 UTC, the well-typed ForgeTransactionPermitFromDescriptor fixture compiled successfully
with the actual private unit explicitly exposed on both hosts. The identical public-only dependency
view rejected its Session.Testing import on both hosts (exit 1, GHC-87110), naming the hidden
hostbootstrap-core-0.1.0.0:lifecycle-transaction-internal package. This is a private DATA-vocabulary
boundary proof; it claims no permit construction or internal runner-module sealing.

Before any runtime source change on 2026-10-29 UTC, the complete "transaction recovery" group ran
on both hosts and failed exactly two of 48 cases: Windows 8.80 seconds; Linux 10.56 seconds. The
foreign-coordinator case returned Right () instead of the declared corruption refusal, and the
Production conflict reported transaction 0 instead of 41. All other 46 cases passed, including the
retained prefix families, exact restored/Applying/successor version assertions, actual descriptor
readback and exercised invalid/empty fixture prefixes. These are executed semantic failures with
successful test compilation, not unavailable-symbol or fixture-build failures.

Independent before/after source comparison on 2026-10-29 UTC confines the runtime change to exactly
15 changed lines in Transaction.hs: the requested-plan guard before recovery, and propagation of the
actual descriptor sequence into the Production conflict. Session and Session.Testing are unchanged;
there are no new imports, types, exports, permit producers, runners, codec changes or target-order,
CAS, idempotency or deletion-policy changes. The five added cases retain their measured RED definitions.

Focused validation on 2026-10-29 UTC passed all six declared selections on both hosts: transaction
recovery (48; Windows 8.40 seconds, Linux 9.43 seconds), SessionSpec (281; Windows 52.19 seconds,
Linux 56.19 seconds), the registered ForgeTransactionPermitFromDescriptor fixture (one),
PortabilitySpec (25), inventory (54) and DocValidatorSpec (17). The exact foreign-plan and conflict-41
refusals pass with unchanged post-setup images; the other three new refusals and all retained/shared
fixture controls also pass. The complete gate evidence follows below.

The complete child command `cabal test all` from `core/` passed on both hosts on
2026-10-29 UTC with GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64
passed 3,530 tests in 548.76 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
passed 3,532 in 426.58 seconds. Both retained failure-context lists were empty. The original recovery
families, five exact refusals, strengthened reconstruction controls, compiler/absence boundaries and
aligned documentation are included. The provider-live component reported its declared not-requested
result; these runs claim no live provider confirmation.

#### Remaining Work

None.

### Sprint 10.11: Recover complete namespaced operation identities [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Operation enumeration retains the complete namespace, dotted token and relation path of each
operation identity. The persisted session identity must match the record key's exact encoded owner
prefix; decoding the complete remaining suffix preserves the operation rather than guessing an owner
from separators.

#### Deliverables

- Read the operation record's persisted session identity and validate its exact encoded key prefix.
- Decode and validate the complete operation suffix, including namespaces, dotted tokens, and paths.
- Refuse disagreement between the record payload and its key rather than guessing an owner.
- Add focused regressions for real namespaced operations and inconsistent persisted ownership.
- Keep the existing record encoding; the sprint adds no type and budgets 80 production lines in one module.

#### Validation

On 2026-09-16, both namespaced-operation regressions fail against the preceding parser with
`SessionManifestOrphanOperation`. After the correction, `cabal test hostbootstrap-core-test
--test-show-details=direct --test-options='-p SessionSpec --hide-successes'` passes all 107 session
cases on native Windows in 14.43 seconds. These include complete enumeration and recovery for plain
and namespaced/path session identities, plus refusal of a payload naming a different owner.
Fourmolu 0.20.1.0 checks both changed Haskell files, HLint 3.10 reports no hints in the production
module, and `git diff --check` passes. The complete declared phase gate then passes 2,546/2,546 core
tests in 379.89 seconds, with the provider-live component's declared no-request result. The full Cabal
command exits 0 in 409.15 seconds. The following lifecycle phase owns recovery's resource-closure check.

Closure criteria, run by `cabal test all` from `core/`: the foreign-owner refusal case asserts the ownership
refusal's exact detail, as named in Remaining Work, and passes.

The current SessionSpec case "operation enumeration refuses a payload naming another session"
asserts `SessionRecordCorrupt` with the exact ownership-at-key detail, including the actual
`.session-a...op-1` tuple spelling. The "namespaced operation recovery" group retains its three
existing session rows: session-a, vendor:session.v2/child and Vendor:Session_A.v2/Child. Each registers
and recovers the complete namespaced/path/dotted operation identities through the ordinary driver.

The 2026-10-29 UTC assertion change is exactly two added test lines and one removed line. Independent
inverse comparison restores the validated preceding SessionSpec byte-for-byte. Production Session,
Transaction and Session.Testing are unchanged, as are the setup and case count; no semantic RED or new
runtime behavior is claimed. The lifecycle validation paragraph pins the same exact reason.

Focused validation on 2026-10-29 UTC passed all five selections on both hosts: the exact foreign-owner
case (one; Windows 0.16 seconds, Linux 0.25 seconds), namespaced operation recovery (three; Windows
1.65 seconds, Linux 1.77 seconds), SessionSpec (281; Windows 51.86 seconds, Linux 56.68 seconds),
inventory (54) and DocValidatorSpec (17). These results include the unchanged setup and all three
namespace/path session identities; the exact diagnostic assertion passed as written. Complete gate
evidence follows below.

The complete child command `cabal test all` from `core/` passed on both hosts on
2026-10-29 UTC with GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror: native Windows 11 x86_64
passed 3,530 tests in 548.55 seconds; the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
passed 3,532 in 429.52 seconds. Both retained failure-context lists were empty. The exact ownership
refusal, unchanged namespaced recovery families and aligned documentation are included. The
provider-live component reported its declared not-requested result; these runs claim no live provider
confirmation.

#### Remaining Work

None.

### Sprint 10.12: The session journal hashes through Digest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`, and the session journal derives its plan-bound
journal and record names with that export rather than with a byte-identical local copy, so a name recomputed
by a reader cannot drift from the one the journal wrote.

#### Deliverables

- `Lifecycle.Session` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its
  own.
- Every plan-bound journal and record name the module derives keeps the bytes `SessionSpec` pins.
- The component inventory names Session as a Digest consumer, and the legacy ledger no longer lists
  the removed local helper. Other modules' local copies and the transaction-unit visibility work
  retain their separate owners.

#### Validation

`SessionSpec` passes unchanged inside `cabal test all` from `core/`, with the package's common warnings
stanza holding -Werror. The complete host static gate (§ JJ) passes: `cabal test all` from `core/`,
`cabal test all` from `demo/`, and `poetry run python -m hostbootstrap.check_code` plus
`poetry run python -m hostbootstrap.test_all` from the repository root. The plain Cabal command retains
the package's declared warning policy; all four commands validate the adoption.

The unchanged SessionSpec cases include "fresh admission atomically hands the acquisition seed to
one exact frame" (independent cursor-key SHA-256/framing oracle), the four "encoded record identities"
cases (including exact independent operation keys), and the three "namespaced operation recovery"
rows. "rooted durable coordinates remain bounded and distinct at maximum input size" holds bounds
and distinctness, not an independent exact hash oracle. DocValidatorSpec's "SHA-256 and wire framing
match known-answer vectors" independently pins the shared helper's empty/abc SHA-256 spellings.

On 2026-10-29 UTC, independent source comparison confines the adoption to twelve changed lines in
Session.hs: one shared import, two removed imports and the removed local helper. Its exact inverse
restores the validated preceding source. All four call sites and all other source bytes are unchanged;
there are no new types, exports, dependencies, Cabal changes or test changes. The existing independent
oracles validate the retained names. Inventory/ledger inverses reproduce their preceding snapshots,
with only the actual new consumer clause and resolved Session-local-helper row changed.

Focused validation on 2026-10-29 UTC passed all six selections on both hosts: the independent cursor
oracle (one; 0.15 seconds each), encoded record identities (four; Windows 1.25 seconds, Linux
1.68 seconds), namespaced recovery (three; Windows 1.24 seconds, Linux 1.72 seconds), rooted maximum
coordinates (one; 0.03 seconds each), inventory (54) and DocValidatorSpec (17). The shared helper's
known-answer vectors are included in the documentation group. Complete host-static evidence follows;
these focused runs are not substituted for either Cabal workspace or Python leg.

On 2026-10-29 UTC, all four host-static child commands passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container, with GHC 9.12.4 / Cabal 3.16.1.0 and package
-Werror. `cabal test all` from `core/` passed 3,530 tests on Windows (554.29 seconds) and 3,532 on
Linux (425.63 seconds). The separate `cabal test all` from `demo/` passed all 165 consumer tests
(Windows 5.80 seconds, Linux 1.89 seconds) plus the included core suite (Windows 3,530 in
525.91 seconds; Linux 3,532 in 406.57 seconds). Both root commands
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
exited 0 on each host; the Python suite passed 376 tests (Windows 6.48 seconds, Linux 6.83 seconds).
Every retained stage failure-context list was empty. These commands exercise the unchanged Session
cases and the actual consumer; the provider-live components reported their declared not-requested
results, so these runs claim no live provider confirmation.

#### Remaining Work

None.

### Sprint 10.13: The transaction testing sublibrary exposes no transaction runner [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportTransactionRunnerFromTestingUnit.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/architecture/lifecycle_state_model.md`, `documents/engineering/testing.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

The private `lifecycle-transaction-internal` sublibrary holds the session testing seam so recovery fixtures can
write the coordinator's interrupted-state vocabulary. A component that depends on it reaches that vocabulary
and no permit producer or transaction runner, so a fixture can describe a store state but cannot drive a
lifecycle transaction outside the ordinary entry point.

#### Deliverables

- The already private `lifecycle-transaction-internal` unit exposes only
  `HostBootstrap.Lifecycle.Session.Testing`. `HostBootstrap.Lifecycle.Transaction` is in its
  `other-modules`; the main library retains its own hidden Transaction copy in `other-modules`.
- The Testing facade retains its pure coordinator/descriptor/kind/target/encoder/decoder/readback
  vocabulary and exposes no permit constructor, extra key minter or transaction runner. The Cabal
  comment and facade Haddock describe the guarantee held by the actual module lists.
- A SessionSpec guard uses SourceGuard's named stanza reader to require private visibility, the exact
  single Testing exposed module and Transaction in other-modules, and to retain the main library's
  hidden copy. It constrains this owned stanza rather than freezing the complete shared Cabal file.
- CompileFailSpec resolves a second explicit compiler environment exposing only the actual testing
  unit instead of the main library unit. It reads the real registration's possibly multiline id with
  the existing field reader, refusing missing/ambiguous registration or ids. Preserve the public-only
  environment and pinned compiler, explicit package databases and hide-all-packages flags; use no
  `cabal exec ghc` component context or indiscriminate privileged package exposure.
- The existing well-typed descriptor DATA fixture retains its public hidden-package refusal and
  compiles in the testing-unit-only environment. A new live runner-import fixture binds the actual
  ensureTransactionCoordinator, runLifecycleTransaction and recoverProductionTransactions values:
  it compiles before the module-list change and refuses afterwards because Transaction is a hidden
  module. Pin the observed complete diagnostic before registering it. A private case group reuses
  the matcher/runner; fixture inventory joins public/private negative registrations exactly once per
  file, while the DATA positive reuses its existing fixture without a duplicate negative registration.
- Align the three owned architecture/testing docs and remove only the resolved runner-exposure
  ledger row after the actual move. Keep runtime behavior, wire bytes, target policy, types and
  existing public registrations unchanged. New fixture Implementation paths are listed only once
  the files exist.

#### Validation

First measure the new stanza guard failing against the actual exposed Transaction slot. In the
explicit testing-unit-only compiler environment, the genuine live runner-import fixture must compile
before the move; after rebuilding, it must fail for the observed hidden-module diagnostic. A hidden
package refusal in that privileged control is a failed setup, not evidence of module hiding. The
same existing DATA fixture must still compile in that environment, while its ordinary public-only
hidden-package negative remains. Inventory and live-import checks include the new private negative
registration without changing the old public context.

Then run the stanza/private-compiler controls, SessionSpec, inventory, PortabilitySpec and
DocValidatorSpec on both hosts. The complete phase gate `cabal test all` from `core/` and all four
host-static commands (§ JJ) pass before this final sprint and its phase close. The measured guard RED
precedes the module-list change, so no later edit/revert cycle is needed to establish that exposed
Transaction turns the guard red. No runtime test branch, new authority producer or byte-policy change
is introduced.

On 2026-10-29 UTC, the new live ImportTransactionRunnerFromTestingUnit fixture compiled on both
hosts using the actual testing unit instead of the main unit (exit 0). The same environment compiled
the existing descriptor DATA fixture (exit 0); the ordinary main-only view rejected that DATA import
(exit 1, GHC-87110, the hidden lifecycle-transaction-internal package). The new fixture binds all three
actual permit/runner entry points, so this preceding success is not an unrelated type/import failure.

The persistent private DATA positive then passed through the factored compiler resolver on both
hosts (one; Windows 0.56 seconds, Linux 0.19 seconds). The new SessionSpec stanza guard failed on both
(0.04 seconds each), naming the actual exposed list [Transaction, Testing] where only [Testing] is
required. This measured RED is the real unchanged Cabal exposure, not a contrived parser fixture.
The main compiler's existing arguments/registrations and diagnostic matcher are preserved; the private
resolver reads the actual folded id and refuses missing or ambiguous registrations/ids. The new runner
fixture exists and is listed in Implementation; its negative is registered after the post-move
hidden-module diagnostic is measured.

The module-list change retains private visibility and moves Transaction to other-modules, with only
Testing exposed. Independent inverse comparisons restore the preceding Cabal and facade snapshots:
five changed Cabal lines and three Haddock lines, with no facade export/import/function or runtime
change. The main library's hidden copy remains. The three docs and ledger reflect the actual move;
post-move compilation and measured registration evidence follow below.

On 2026-10-29 UTC, `cabal build all` from `core/` rebuilt the library/executable successfully on
both hosts with the pinned compiler and package -Werror. Fresh registration reads name the same
actual testing-unit id, exposed [Testing] and hidden [Transaction]. The identical runner fixture and
testing-unit-only compiler arguments now reject on both hosts (exit 1, GHC-87110), identifying
Transaction as a hidden module in lifecycle-transaction-internal and in the main library. The observed
contiguous diagnostic begins "Could not load module 'HostBootstrap.Lifecycle.Transaction'. it is a
hidden module in the package 'hostbootstrap-core-0.1.0.0:lifecycle-transaction-internal'". It is not a
hidden-package setup failure. The same DATA fixture still compiles privately (exit 0) and retains its
public hidden-package refusal (exit 1). The preceding runner exit-0 controls prove its ordinary
imports/types are valid; no constructor-forgery or runtime change is inferred.

The measured hidden-module phrase is registered for ImportTransactionRunnerFromTestingUnit only in
the private case list. Its group now contains one existing-DATA positive and one live-runner negative;
combined inventory joins public/private negatives once per file. Public registrations, matcher,
compiler context and fixture bodies are unchanged by this registration step. The observed compiler
refusal is held by the persistent test rather than only by a manual probe.

Focused validation on 2026-10-29 UTC passed all seven selections on both hosts: the stanza guard
(one; 0.03 seconds each), private compiler group (two; Windows 0.75 seconds, Linux 0.30 seconds),
existing public DATA negative (one; Windows 0.45 seconds, Linux 0.15 seconds), SessionSpec (282;
Windows 50.75 seconds, Linux 54.13 seconds), inventory (54), PortabilitySpec (25) and DocValidatorSpec
(17). The measured hidden-module diagnostic matches in the persistent private negative, descriptor
DATA remains usable, and every fixture is registered once with live imports. These focused passes
retain the complete runtime recovery matrix; complete phase/host-static evidence follows below.

On 2026-10-29 UTC, all four host-static child commands passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container with GHC 9.12.4 / Cabal 3.16.1.0 and package
-Werror. The exact `cabal test all` core leg passed 3,533 tests on Windows (558.09 seconds) and 3,535
on Linux (426.38 seconds). The separate demo-workspace `cabal test all` passed all 165 consumer tests
(Windows 5.85 seconds; Linux 2.12 seconds) plus its included core suites (Windows 3,533 in
527.25 seconds; Linux 3,535 in 420.37 seconds). Both root Poetry commands, check_code and test_all,
exited 0 on each host; the Python suites passed 376 tests (Windows 6.46 seconds; Linux 6.84 seconds).
All retained stage failure contexts were empty. Default provider-live components reported their
not-requested results; no live provider confirmation is claimed.

The final owned-document audit identifies an adjacent stale RawProbe no-fixture statement in
unrepresentable_state.md. Its existing fixture/registration are present; the bounded correction names
only the unavailable public Probe term spelling. No source or test behavior changes. The affected
fixture/documentation checks and the exact unfiltered core phase gate are re-run after that doc-only
correction before phase closure; the other host-static legs already exercise the unchanged code.

After both four-command pipelines completed, the owned unrepresentable-state document removed its
false no-fixture bullet and named RawProbe's actual public-term proof. Exact two-hunk inverse checking
restores the preceding document; no source or test changed. The affected RawProbe case passed on both
hosts (Windows 0.57 seconds, Linux 0.23 seconds), followed by all 17 DocValidatorSpec cases (Windows
6.75 seconds, Linux 5.42 seconds). The exact unfiltered core phase gate is run again against that final
document before closure; the previously completed demo/Python legs cover the unchanged code.

The final exact child command `cabal test all` from `core/` passed against the corrected owned
document on both hosts on 2026-10-29 UTC, with GHC 9.12.4 / Cabal 3.16.1.0 and package -Werror:
native Windows 11 x86_64 passed 3,533 tests in 553.25 seconds; the native-filesystem Ubuntu 24.04.4
x86_64 CPU container passed 3,535 in 429.14 seconds. Both retained failure-context lists were empty.
The source and test bytes are unchanged from the four-command host-static runs recorded above.
These final unfiltered runs include every earlier session/journal/fence contract and the persistent
private compiler, public DATA, exact stanza and documentation controls. Provider-live again reported
its declared not-requested result; no live-provider or non-baseline hardware acceptance is inferred.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — the journal, sessions, fences, and the total classifier.
- `documents/architecture/unrepresentable_state.md` — the testing unit's data facade and hidden runner boundary.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption matrix built from durable values, and what
  in-process coverage cannot reach.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of the session/fence protocol.
