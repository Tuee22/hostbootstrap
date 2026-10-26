# Phase 10 — Versioned sessions, the project journal, and durable fences

**Status**: Active
**Depends on**: Phase 9 (lifecycle modes and run leases)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-16 ; native x86_64 Windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` ; pass ; covers in-gate

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

### Sprint 10.1: The project journal and versioned sessions [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

One journal version that both session opening and project close advance.

#### Deliverables

- `openProjectJournal` yields the sole `ProjectPermit` for a plan digest; opening a session and closing the
  project compare-and-swap the same version, so exactly one wins.
- `openOperationSession` records a session at a version and returns the sole successor state/permit pair; a
  retained pre-open permit cannot open a second session.
- `registerOperationIntent` writes an operation's initial intent and its exact session membership in one
  transaction and advances both versions, so no orphan intent and no recordless member can exist. Its origin
  is either `NoHistory`, accepted only when the operation key has no record, or a released-reacquisition
  origin: an opaque value minted only from an observed ordinary `Released` operation record, naming that
  record's exact key and version, which registration re-reads and refuses unless it is still that release at
  that version. An `AdoptionReleased` record mints no origin, and a caller cannot assert a reacquisition it
  did not observe.
- `beginClosingProject` moves the journal to `ClosingProject` at a fresh positive epoch; a closing project
  admits no new session, and only the persisted epoch resumes. `recordClosedProject` moves Closing to Closed
  only for the matching closing epoch and refuses an Open journal; a Closed journal is terminal and returns
  its Closed permit.
- The journal decodes only bytes its encoder writes: a Closing epoch is canonical decimal (digits only, no
  leading zero, within `Word64`), so any other spelling is `SessionRecordCorrupt "project journal"`.
- `verifyAllSessionsClosed` enumerates every session record for the plan independently and refuses while any
  is open — including a **zero-operation** open session, which is exactly what a kill right after open leaves.
- `Lifecycle.Transaction` supplies the crash-consistent redo coordinator every multi-record transition runs
  behind.
- Local journal and cursor helpers carry explicit scoped result types across GADT branches, so supported
  compilers preserve the same scope, plan, broker, and result indices.

#### Validation

`AuthoritySpec` covers the zero-operation session refusal ("the session-completeness proof refuses while any
session is open"), idempotent closing-epoch resumption, the foreign-epoch refusal, and that a closing project
admits nothing new ("a closing project admits no new session, and only its own epoch resumes"), and the
matching-epoch close ("only the matching closing epoch can become closed").

Closure criteria, run by `cabal test all` from `core/`: the `SessionSpec` cases named in Remaining Work exist
and pass — both orders of the session-open/project-close race on one permit, a stale permit refused by
`openOperationSession` with no older session open, each closed-session and close-journal refusal by its
exact constructor, the released-reacquisition origin's acceptance and refusals, and the non-canonical
Closing-epoch refusals — and the existing cases still pass.

On 2026-09-09, the complete native Windows core gate passes 2,492/2,492 in 675.12 seconds with
GHC 9.12.4 and Cabal 3.16.1.0. The library and both executables also build with `-Werror` using
GHC 9.10.3 from published CPU/amd64 base digest
`e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`.
The explicit scoped journal/cursor signatures preserve the indexed branch behavior, and their
production modules pass the base's formatter check.

#### Remaining Work

- One-winner race, both orders (`SessionSpec`). Case "a session open wins against a close presented the same
  permit": take `P` from `openProjectJournal`, open `session-a` with `P`, then `beginClosingProject plan 7 P`
  returns `Left (SessionStaleProjectPermit v)` with `v == projectPermitVersion P`, and
  `readProjectJournalState` is still `OpenProject`. Case "a close wins against a session open presented the same
  permit": `beginClosingProject plan 7 P` succeeds, then `openOperationSession ... "session-a" P` returns
  `Left (SessionProjectClosing plan)` and no `session.` record exists.
- Stale-permit open (`SessionSpec`). Rewrite "a retained older permit cannot advance the journal a second
  time": open `session-a` with `P0`, close it with the successor `P1`, then present `P0` to open `session-b`.
  Assert `Left (SessionStaleProjectPermit v)` with `v == projectPermitVersion P0`, and an unchanged
  `protectedImage`. As written the case is refused by `SessionOlderStillOpen` before the permit check runs.
- Closed-session and close-journal refusals (`SessionSpec`), each by exact constructor: reopening a closed
  `session-a` with the live permit gives `SessionNotOpen "session-a"`; `registerOperationIntent` on a closed
  session gives `SessionNotOpen`; a second `closeOperationSession` gives `SessionNotOpen`;
  `beginClosingProject` with epoch 0 gives `SessionRecordCorrupt "closing epoch must be positive"`;
  `beginClosingProject` for a plan digest with no project record gives `SessionProjectMissing`; and
  `recordClosedProject` against an Open journal (with a Closing permit from a second plan) gives
  `SessionRecordCorrupt "project is not closing"`.
- Released-reacquisition origin (`Session.hs`, about 80 lines). Delete the caller-chosen, publicly exported
  `ReleasedReacquisition` constructor of `IntentOrigin`, which no production caller uses, and replace it with
  an opaque origin value whose only producer reads an operation record at phase `Released` and captures its
  exact key and record version. `registerOperationIntent` re-reads that key inside its protected entry and
  refuses with `SessionIntentOriginRefused` when the record is absent, at another version, or at a phase other
  than `Released`, so a reacquisition with no prior record is refused rather than registered fresh.
  `SessionSpec` cases: a released record yields an origin that registers and joins the session; the same
  origin after the released record moves refuses; the producer refuses to mint an origin from an
  `AdoptionReleased` record; and "reacquisition is refused from a phase that is not Released" becomes the
  producer refusing to mint an origin from an `IntentRecorded` record, with `SessionIntentOriginRefused`.
- Canonical decimal decoding (`Session.hs`). `readWord` accepts digits only, no leading zero other than `"0"`,
  and values within `maxBound :: Word64` through an overflow-checked `Integer` parse, so `decodeJournalState`,
  `decodeFenceRecord`, and `gateMatchesRecord` refuse `"-1"`, `"0x7"`, `" 7"`, `"(7)"`, `"07"`, and
  `"18446744073709551623"`. `SessionSpec` case: each spelling written as a Closing epoch over the project
  target with `Session.Testing.stampTarget` makes `readProjectJournalState` return
  `Left (SessionRecordCorrupt "project journal")`.

### Sprint 10.2: Durable fence creation and rotation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

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

#### Validation

`SessionSpec` covers creation, strictly increasing rotation, re-establishment over an already-observed fence,
and both the rejection and the deduplication of a delayed old permit. The resume cases ("re-establishing
resumes the persisted epoch, not the caller's" and "a resumed establishment survives reopening the store")
start from a settled `FenceObserved` record, so they exercise only the observed branch of
`establishInitialFence`.

Closure criteria, run by `cabal test all` from `core/`: each fence phase is entered from the durable record
that phase leaves — the `FenceIntentRecorded` and `FenceOutcomeUnknown` resume cases, the `currentFence`
refusals, the rotation refusals, the unsettled `fenceOldPermits` completion, and the delayed prepare refused
after `fenceOldPermits` named in Remaining Work exist and pass, so both sides of every fence write are covered
by a state rather than by a throw; and no fence-set case discards its setup entry's result.

The out-of-process half is `--hostbootstrap-fence-delay-probe`: a competitor process takes the plan's
generation token in one entry, **releases the store** while the parent rotates the fence in an ordinary
protected transaction, and presents the now-delayed token in a second entry. The two entries are what make
the boundary real rather than simulated, and the competitor's only report is its own outcome. Both
distinguished outcomes are covered — a delayed prepare is refused as superseded, naming the presented and
live epochs, and a delayed initial-fence proposal is deduplicated to the observed epoch rather than opening
a second generation. A control case runs the same probe across an *uncrossed* boundary and requires the
retained token to prepare, so the refusal cannot be satisfied vacuously. `cabal test all
--ghc-options=-Werror` from `core/` passed 941/941 on 2026-08-05 (aarch64-osx, GHC 9.12.4).

#### Remaining Work

- Interrupted-establishment resume (`SessionSpec`). Seed the plan's fence key (`"fence." <> mkRecordName plan`)
  with `compareAndSwapProtectedRecord ... ExpectAbsent` holding the bytes `fenceRecord` writes for
  `(FenceIntentRecorded, 4)` (`encodeFields ["FenceIntentRecorded", "4"]`), reopen the store, call
  `establishInitialFence s plan 77`, and assert epoch 4 and a final record decoding to `(FenceObserved, 4)`.
  Repeat from `(FenceOutcomeUnknown, 4)`. Rename the two settled-fence resume cases so their names claim only
  the observed branch.
- `currentFence` refusals (`SessionSpec`): over a seeded `(FenceIntentRecorded, 3)` record `currentFence`
  returns `Left (SessionFenceUnsettled FenceIntentRecorded)`, and over `(FenceOutcomeUnknown, 3)` it returns
  `Left (SessionFenceUnsettled FenceOutcomeUnknown)`. With a prepared session whose fence record is then
  compare-and-swapped to `(FenceIntentRecorded, 2)`, `withPreparedGate` returns the same unsettled refusal and
  the operation record is byte-identical. With no fence record, `currentFence` and `rotateFence` each return
  `Left (SessionFenceMissing plan)`.
- Unsettled completion through `fenceOldPermits` (`SessionSpec`). Rewrite "the fence protocol is completed
  idempotently when it was left unsettled" (which starts with no fence record) to seed
  `(FenceIntentRecorded, 3)`, call `fenceOldPermits`, and assert `oldPermitsFencedFrom == 3` and
  `oldPermitsFencedTo == 4`; call it a second time and assert `from == 4` and `to == 5`. Keep the absent-fence
  case under its own name.
- Rotation overflow (`Session.hs`, about 5 lines): `rotateFence` refuses with
  `SessionFenceInvalid "a fence epoch cannot rotate past its maximum"` when the observed epoch is `maxBound`.
  `SessionSpec` case: seed `(FenceObserved, 18446744073709551615)`, call `rotateFence`, and assert that refusal
  and a byte-identical fence record.
- Delayed prepare after `fenceOldPermits` (`SessionSpec`). New case "a prepare presenting the fence that
  fenceOldPermits superseded is refused": in one entry, open `session-a`, take `F1` from
  `establishInitialFence s plan 1`, register op-1 with `NoHistory`, call `fenceOldPermits s plan`, then call
  `withPreparedGate` for op-1 with the retained `F1`, the session, its broker epoch and the live permit. Assert
  `Left (SessionFenceSuperseded 1 2)` and that op-1's record still decodes to phase `IntentRecorded`. Delete
  the comment "A permit minted under the superseded epoch is now refused" from "fencing enumerates the
  outstanding permits and then supersedes them", which asserts only the live epoch.
- Refused setup fails the fence-set cases (`SessionSpec`). In "fencing enumerates the outstanding permits and
  then supersedes them" and "a settled operation holds no authority, so it is not in the fence set", run the
  setup entry through `runEntry` (or `expect =<< inEntry ...`) instead of `_ <- inEntry ...`, so a `Left` from
  `withOpenSession`, `withPrepared`, `establishInitialFence` or `registerOperationIntent` fails the case rather
  than leaving no operation and an empty fence set that passes `oldPermitsFencedOperations fenced @?= []`.

### Sprint 10.3: Session-scoped operation state [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Classify every persisted operation totally, so recovery has no default branch.

#### Deliverables

- One total classifier, `classifyRecordedPhase`, decodes the recorded phase text into a closed phase type
  naming every phase the session journal writes, then maps each constructor by an exhaustive case with no
  wildcard to exactly one of: unknown, one of the five pre-call continuable phases, already-observed
  retryable, successful, or terminal. Only text that fails to decode is unknown through that failure; every
  named phase reaches its class by its own case arm.
- Only continuable phases receive current-fence prepare authority; successful and terminal branches receive no
  effect authority at all. A session member whose operation record is absent is refused as
  `SessionOperationUnregistered`, so neither `closeOperationSession` nor `recoverAbandonedSessions` counts it
  settled.
- The retryable whitelist is closed: reservation/effect absence, adoption absence, repair-original, and
  managed-phase-from, plus their explicit fenced-retry states — and only under the same operation key after
  old permits are fenced. A recorded fence that does not decode is corrupt, never a fence of 0. A
  same-identity teardown observation returns the record to `Committed` (§ EE), which is settled, not retryable.
- `withPreparedGate` revalidates the caller's broker generation against the session record's durable marker,
  accepts as its unknown phase only an outcome-unknown phase, and records it before the adapter runs.
  `acknowledgeOutcome` revalidates the live observed fence and the Open session, requires the recorded phase to
  be an outcome-unknown phase, and records only a successful, terminal, or retryable outcome, so an
  acknowledgment cannot rewind an operation to a pre-call phase or land after its fence is superseded.
- Closing a session first verifies every registered outcome settled, then compare-and-swaps the exact session
  record closed under the project-journal permit; a prepare consumes that same permit, so a concurrent prepare
  or a retained proof cannot win.
- The classifier is the **input** the recovery phase's protected recorded-session interpreter consumes: this
  sprint owns the total classification of a persisted operation, and the phase that has a reopened run's
  records owns rebinding and closing them.

#### Validation

`SessionSpec` covers the classifier branches for the phases it lists, the whitelist, and the
no-effect-authority branches.

Closure criteria, run by `cabal test all` from `core/`: the `SessionSpec` cases named in Remaining Work exist
and pass — one classifier case per phase constructor, the two deterministic prepare/close exclusion cases,
the prepare and acknowledgment refusals by exact constructor with the operation record byte-identical, the
durable unknown phase read back inside the adapter, and the recordless-member refusal — the cases that
acknowledge `"SomeFuturePhase"` instead write that record directly, and no sweep case discards its setup
entry's result.

#### Remaining Work

- Exhaustive classifier (`Session.hs`). Decode the recorded text into a closed phase type covering every
  `Reconcile.PersistedJournalPhase` name plus `StepObservedTerminal` and `RecoveryAbandoned`, and classify by an
  exhaustive case with no wildcard. The phases the current list match sends to unknown each get an explicit arm:
  `RepairObservedAbsent`, `PhaseObservedAbsent`, and `AdoptionTeardownObservedForeign` are terminal (no
  successor in `Reconcile.legalJournalTransition`); `Reserved`, `ObservedManaged`, `AdoptionObservedManaged`,
  `RepairObservedTarget`, and `PhaseObservedTo` each get a named arm whose class follows their sole § EE
  successor. `SessionSpec`: one case per constructor asserting its class, and undecodable text asserting
  `UnknownDisposition`. Correct the classifier Haddock so its whitelist names exactly the phases in `fencedRetryablePhases`
  (it lists a teardown-presence retry that has no phase).
- Outcome-phase validation (`Session.hs`). `withPreparedGate` refuses an `unknownPhase` that is not an
  outcome-unknown phase (`ReservationOutcomeUnknown`, `EffectOutcomeUnknown`, `AdoptionOutcomeUnknown`,
  `RepairEffectOutcomeUnknown`, `PhaseEffectOutcomeUnknown`, `TeardownOutcomeUnknown`,
  `AdoptionTeardownOutcomeUnknown`); `acknowledgeOutcome` refuses when the recorded phase is not one of those or
  when `observedPhase` classifies as anything other than settled, terminal, or fenced-retryable. Both refuse
  with a new `SessionOutcomePhaseRefused opKey recorded presented` constructor. `SessionSpec`: acknowledging
  `"IntentRecorded"` and `"ReservationRetryFenced"` refuses; preparing with unknown phase `"Committed"` refuses;
  each leaves the operation record byte-identical. Rewrite the cases that acknowledge `"SomeFuturePhase"` to
  seed that record with `compareAndSwapProtectedRecord`, as `writeOrphanOperation` does, instead of
  acknowledging it.
- Acknowledgment revalidation (`Session.hs`). `acknowledgeOutcome` reads `currentFence` and refuses with
  `SessionFenceSuperseded (preparedGateFence gate) live` when they differ, and refuses `SessionNotOpen` when the
  session record is closed. `SessionSpec`: prepare op-1, rotate the fence with `fenceOldPermits`, then
  acknowledge with the retained gate and permit, asserting the superseded refusal and that op-1 still reads
  `EffectOutcomeUnknown`.
- Prepare revalidation (`Session.hs`). `withPreparedGate` compares the session record's marker with
  `brokerEpochWord epoch` and refuses `SessionBrokerEpochMismatch` on disagreement. `SessionSpec`: open a session
  under one epoch and prepare with an epoch from a second broker store, asserting
  `Left (SessionBrokerEpochMismatch opened presented)` and an unchanged `protectedImage`; settle and close a
  session, then prepare with the successor permit, asserting `Left (SessionNotOpen sid)`.
- Corrupt recorded fence and attempt (`Session.hs`). `recordedFenceOf` and `recordedAttempt` return `Maybe`;
  `withPreparedGate` and the recovery abandon write refuse with `SessionRecordCorrupt "operation record"` when
  either field is missing or does not decode. `SessionSpec`: an `EffectAbsent` record with fence field `"x"`
  refuses to prepare.
- Recordless member (`Session.hs`). `unsettledOperations` and `classifySessionOperations` treat a listed member
  whose operation record is absent as `SessionOperationUnregistered name`, as `withPreparedGate` does.
  `SessionSpec`: delete op-1's record from a session that lists it; `closeOperationSession` and
  `recoverAbandonedSessions` both refuse with that constructor and the session stays Open.
- Gate mismatch and durable unknown phase (`SessionSpec`). Acknowledge with a gate prepared in another session
  and with a gate from another plan digest, asserting `Left (SessionPreparedGateMismatch "session")` and
  `Left (SessionPreparedGateMismatch "plan")` and no `op.` record changed. Inside the adapter of "a prepare
  records the unknown phase before the adapter runs", read op-1's record and assert fields
  `["EffectOutcomeUnknown", sid, fence, "1"]`.
- Deterministic prepare/close exclusion (`SessionSpec`). Replace `prepareCloseRaceCase`, whose close always
  refuses with `SessionOperationUnsettled` in either order, with two sequential cases in which the permit is the
  only reason to refuse. (a) Prepare op-1 with `P1` and acknowledge it `Committed`, yielding `P2`; present the
  retained `P1` to `closeOperationSession` and assert `Left (SessionStaleProjectPermit v1)` with the session
  still Open; then closing with `P2` succeeds. (b) Close that settled session with `P2`, yielding `P3`; present
  `P2` to `withPreparedGate` for op-1 and assert `Left (SessionStaleProjectPermit v2)` with op-1's record
  byte-identical. Assert the winner's exact durable state in place of the final `isRight`. Correct the
  `closeOperationSession` Haddock to say the exclusion comes from the shared project-journal permit, not the
  session record version.
- Refused setup fails the sweep cases (`SessionSpec`). In "an abandoned session is closed and its continuable
  work counted" and "a sweep with nothing open reports no work", run the setup entry through `runEntry` (or
  `expect =<< inEntry ...`) instead of `_ <- inEntry ...`, so a refused `withOpenSession`,
  `registerOperationIntent` or `openProjectJournal` fails the case instead of letting an empty store satisfy
  the sweep's counts.

### Sprint 10.4: The interrupted coordinator state is a value [Active]

**Status**: Active
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

Let a fixture reach every point the redo coordinator can be interrupted at without the coordinator
carrying a branch that exists for the fixture (§ NN).

#### Deliverables

- What an interruption leaves behind is a **value**: the coordinator record at `Applying` naming a
  descriptor, plus the first *n* of that descriptor's targets already stamped. A fixture writes exactly
  that through the protected store's own compare-and-swap and then re-enters the ordinary entry point,
  so the recovery driver under test is the one production runs and nothing in it knows a fixture exists.
- The descriptor a fixture writes is the **transition's own**, not one it invented. The fixture runs the
  real transition once, reads the records it stamped — their keys, their roles, their exact payloads, and
  its transaction id — restores the store's directory from the snapshot taken before it ran, and rebuilds
  the descriptor against those same pre-transition versions. A snapshot restore is what makes the
  expectations faithful: a store rebuilt through the API would carry later record versions than the
  coordinator saw.
- `Session.Testing` holds the vocabulary that state is written in — the coordinator record's two states,
  the descriptor, the closed transaction kind, the target constructors, and the two encoders — plus the
  read-back helpers a fixture uses to inspect what it wrote (`TransactionRecord`, `readTransactionRecord`,
  `TransactionError`, `transactionErrorMessage`), none of which mints authority. It is the encoding production writes rather than a second implementation that could agree
  with itself while disagreeing with the writer, and it mints no authority: there is no permit
  constructor, no record-key minter beyond the coordinator's own, and no transaction runner. It is
  reached by this package's own suite and by nothing downstream
  ([phase 5](phase-5-installed-identity-and-authority-kernels.md) holds that boundary).
- `runLifecycleTransaction`, `recoverApplying`, and `applyTargets` carry no crash point, and the library
  exposes no module whose purpose is to install one. The per-target counter goes with them, because it
  existed only to name a crash point.
- Recovery redoes a descriptor only when the record round-trips the encoder (text fields as UTF-8, numbers as
  canonical decimal within `Word64`) and names the plan of the coordinator key it was read from; it refuses an
  out-of-plan target, a role order that does not match the kind, and a target in neither its expected nor its
  applied state, naming the descriptor's own sequence. `Session` maps each `TransactionError` constructor
  explicitly, with `TransactionMalformed` as `SessionRecordCorrupt`.
- `PortabilitySpec` gains the § NN absence guard this sprint's work makes true, naming its
  [rationale.md](rationale.md) § Gates and validation entry: no module the package ships names a
  transaction crash point.
- The eight recovery families keep every case they had — open project, open session, register intent,
  prepare, acknowledge, close session, begin project close, and record project closed, at each
  interruption point — so what changed is what the evidence is worth, not how much of it there is. A
  ninth case pins the faithfulness the other twenty-five rest on: the reproduced state carries the exact
  bytes the completed transition wrote, under the same transaction id.

#### Validation

`SessionSpec`'s twenty-six recovery cases, run against constructed durable state rather than an injected
exception; `ForgeTransactionPermitFromDescriptor.hs` proving a downstream consumer cannot reach the
vocabulary at all, which subsumes reaching a permit through it; and the new absence guard proved
non-vacuous by naming the shape and finding none.

Closure criteria, run by `cabal test all` from `core/`: the coordinator refusal cases, the UTF-8 round trip,
the foreign-plan descriptor refusal, the faithful-descriptor read-back, the open-project recovery
assertions, and the target-count assertion in `installApplying` named in Remaining Work exist and pass
alongside the twenty-six recovery cases.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 237.07 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

#### Remaining Work

- Coordinator refusal cases (`SessionSpec`, built with the `Session.Testing` vocabulary). Install, for one plan,
  an `Applying` descriptor whose target key lies outside the plan; one whose role order does not match its
  `TxnKind`; one whose target sits in a third state (neither the expectation nor the stamped desired bytes);
  and raw coordinator bytes that do not decode. For each, `openProjectJournal` refuses with the mapped
  constructor naming the reason (`TransactionInvalidTargets` and `TransactionTargetConflict` text through
  `SessionTransactionFailure`, the undecodable record as `SessionRecordCorrupt`), and no target record changes.
- Explicit error mapping (`Session.hs`). `transactionFailure` matches every `TransactionError` constructor with
  no wildcard and maps `TransactionMalformed reason` to `SessionRecordCorrupt reason`.
- UTF-8 coordinator codec (`Transaction.hs`). `encodeLine`/`decodeLine` encode text as UTF-8
  (`encodeUtf8`/`decodeUtf8'`, a decode failure being `TransactionMalformed`) instead of
  `ByteStringChar8.pack . Text.unpack`. `SessionSpec` case: interrupt `TxnOpenSession` after `Applying` for a
  session id containing U+0441, reopen, and assert the recovered `session.` record sits under the real key and
  no other `session.` record exists.
- Strict coordinator numbers (`Transaction.hs`). `readWord` and `decodeStampedTarget` accept canonical decimal
  only (digits, no leading zero other than `"0"`, at most `maxBound :: Word64`). `SessionSpec` case: an Idle
  coordinator with sequence `18446744073709551616`, and a target stamped `18446744073709551617`, each refuse as
  malformed rather than decoding to 0 or 1.
- Plan-bound redo (`Transaction.hs`). `ensureTransactionCoordinator` refuses with
  `TransactionMalformed "a descriptor names another coordinator"` when `descriptorPlan` differs from the plan it
  was asked for, as `recoverProductionTransactions` already does. `SessionSpec` case: plan A's coordinator holds
  a descriptor for plan B; entering plan A refuses and writes neither plan's targets.
- Real conflict sequence (`Transaction.hs`). `applyProductionTarget` takes the descriptor sequence and reports it
  in `TransactionTargetConflict` instead of 0. `SessionSpec` case: a Production descriptor at sequence `n` with a
  conflicting target reports `n` in the message.
- Faithful descriptor read-back (`SessionSpec`). `faithfulDescriptorCase` reads the coordinator record at
  `coordinatorKey plan` before recovery and asserts `CoordinatorApplying` with the published sequence, kind
  `TxnOpenProject`, and one project target whose desired bytes and expectation equal those captured from the
  uninterrupted run.
- Open-project recovery is observed, not re-created (`SessionSpec`). In `openProjectRecoveryCase`, read
  `readProjectJournalState` before calling `openProjectJournal` and assert `OpenProject`, and assert the
  permit version equals the committed successor version the uninterrupted transition produced.
- Interruption points name real prefixes (`SessionSpec`). `installApplying` asserts that the published target
  count equals the kind's role count (2 for `TxnRegisterIntent`, 1 for each other kind in the eight recovery
  families), and that an `AfterTarget n` point has `n` at most that count, failing the case otherwise instead
  of letting `take` turn an over-long prefix into the `BeforeCommit` state.

### Sprint 10.5: Recover complete namespaced operation identities [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Recover operation identities without treating namespace and relation-path separators as the boundary
between a session and its operation. A failed Windows run exposes the defect when its ordinary recovery
sweep mistakes `project:ensure-vm-provider` for an operation owned by session `project`.

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

#### Remaining Work

- Exact ownership refusal (`SessionSpec`). In "operation enumeration refuses a payload naming another
  session", replace the `Left (SessionRecordCorrupt _)` match with
  `Left (SessionRecordCorrupt detail)` and assert
  `detail @?= "operation ownership at op." <> planKeyDigest <> ".session-a.op-1"`, the text
  `readOperationRecordAt` builds, so a refusal from a session-record or journal decode cannot satisfy the
  case.

### Sprint 10.6: The session journal hashes through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`, and the session journal derives its plan-bound
journal and record names with that export rather than with a byte-identical local copy, so a name recomputed
by a reader cannot drift from the one the journal wrote.

#### Deliverables

- `Lifecycle.Session` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its
  own.
- Every plan-bound journal and record name the module derives keeps the bytes `SessionSpec` pins.

#### Validation

`SessionSpec` passes unchanged inside `cabal test all --ghc-options=-Werror` from `core/`, and the host static
gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Hex` from `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs` and import it from
  `HostBootstrap.Digest`.

### Sprint 10.7: The transaction testing sublibrary exposes no transaction runner [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The private `lifecycle-transaction-internal` sublibrary holds the session testing seam so recovery fixtures can
write the coordinator's interrupted-state vocabulary. A component that depends on it reaches that vocabulary
and no permit producer or transaction runner, so a fixture can describe a store state but cannot drive a
lifecycle transaction outside the ordinary entry point.

#### Deliverables

- `HostBootstrap.Lifecycle.Session.Testing` is the sublibrary's only exposed module.
- `HostBootstrap.Lifecycle.Transaction`, which exports `ensureTransactionCoordinator` (the `TransactionPermit`
  producer), `runLifecycleTransaction`, and `recoverProductionTransactions`, is one of the sublibrary's
  `other-modules`, so a component depending on the sublibrary cannot import it. The main library compiles its
  own copy from `src` as one of its `other-modules`, so the move does not change it.
- The "no transaction runner" statement in `Session/Testing.hs` and in the stanza's Cabal comment holds by the
  stanza's module lists, not only by the seam's re-export list.

#### Validation

The sprint closes when a `SessionSpec` stanza guard reads `hostbootstrap-core.cabal` with `SourceGuard` and
asserts that the `library lifecycle-transaction-internal` stanza's `exposed-modules` is exactly
`[HostBootstrap.Lifecycle.Session.Testing]` and that `HostBootstrap.Lifecycle.Transaction` appears in its
`other-modules`, passing under `cabal test all` from `core/`. Listing `HostBootstrap.Lifecycle.Transaction`
under `exposed-modules` again turns the guard red (checked once by hand when the sprint closes, then reverted).

#### Remaining Work

- The `lifecycle-transaction-internal` stanza lists `HostBootstrap.Lifecycle.Transaction` under
  `exposed-modules` beside `HostBootstrap.Lifecycle.Session.Testing`, so the test suite, which depends on the
  sublibrary, can import `ensureTransactionCoordinator` and `runLifecycleTransaction` and run arbitrary lifecycle
  transactions against a store. Move `HostBootstrap.Lifecycle.Transaction` to the stanza's `other-modules` and
  add the `SessionSpec` stanza guard named in Validation.

## Remaining Work

- Sprint 10.1: journal race, stale-permit and closed-session refusal tests; the caller-chosen
  `ReleasedReacquisition` constructor deleted for an opaque origin minted from an observed `Released` record;
  canonical decimal decoding of journal numbers.
- Sprint 10.2: interrupted-fence resume, `currentFence`/`rotateFence` refusals, unsettled `fenceOldPermits`
  completion, rotation overflow, the delayed prepare refused after `fenceOldPermits`, and fence-set cases that
  fail on a refused setup.
- Sprint 10.3: exhaustive classifier, outcome-phase validation, acknowledgement and prepare revalidation,
  corrupt fence fields, recordless-member refusal, gate-mismatch and exclusion tests, and sweep cases that
  fail on a refused setup.
- Sprint 10.4: coordinator refusal tests, explicit error mapping, UTF-8 codec, strict numbers, plan-bound redo,
  real conflict sequence, faithful-descriptor and open-project read-back, and interruption points checked
  against the published target count.
- Sprint 10.5: the foreign-owner refusal asserts the exact ownership detail.
- Sprint 10.6: `Lifecycle.Session` takes `sha256Hex` from `HostBootstrap.Digest`.
- Sprint 10.7: `HostBootstrap.Lifecycle.Transaction` is an `other-modules` entry of
  `lifecycle-transaction-internal`, with a stanza guard pinning `Session.Testing` as its only exposed module.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — the journal, sessions, fences, and the total classifier.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption matrix built from durable values, and what
  in-process coverage cannot reach.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of the session/fence protocol.
