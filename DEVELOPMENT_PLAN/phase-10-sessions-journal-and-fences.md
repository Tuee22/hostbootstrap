# Phase 10 — Versioned sessions, the project journal, and durable fences

**Status**: Done
**Depends on**: Phase 9 (lifecycle modes and run leases)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

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

### Sprint 10.1: The project journal and versioned sessions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

One journal version that both session opening and project close advance.

#### Deliverables

- `openProjectJournal` yields the sole `ProjectPermit` for a plan digest; opening a session and closing the
  project compare-and-swap the same version, so exactly one wins.
- `openOperationSession` records a session at a version and returns the sole successor state/permit pair; a
  retained pre-open permit cannot open a second session.
- Registering an operation's initial intent consumes either the sole no-prior-generation origin or an exact
  released-reacquisition origin, adds its generation to that exact session atomically, and advances both
  versions — so no orphan intent can exist and the caller cannot choose the generation.
- `beginClosingProject` moves the journal to `ClosingProject` at a fresh epoch; a closing project admits no
  new session, and only the persisted epoch resumes.
- `recordClosedProject` accepts only the matching closing epoch.
- `verifyAllSessionsClosed` enumerates every session record for the plan independently and refuses while any
  is open — including a **zero-operation** open session, which is exactly what a kill right after open leaves.
- `Lifecycle.Transaction` supplies the crash-consistent redo coordinator every multi-record transition runs
  behind.

#### Validation

`SessionSpec` covers the one-winner race, the zero-operation session refusal, idempotent closing-epoch
resumption, the foreign-epoch refusal, and that a closing project admits nothing new.

#### Remaining Work

None.

### Sprint 10.2: Durable fence creation and rotation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make "the old generation's permits are dead" a durable fact that survives a crash at any point.

#### Deliverables

- An initial fence epoch is created durably before any permit is issued under it.
- Crash-time rotation proceeds `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved`, so a restart at
  any point resumes **the same proposed epoch** rather than proposing a new one.
- A persisted initial intent that has no fence yet cannot prepare; recovery idempotently completes the stable
  initial-fence protocol and threads its sole successor state/permit values before exposing any continuable
  branch.
- A delayed permit from an older generation is rejected, or deduplicated when it is a retry of one already
  observed.

#### Validation

`SessionSpec` covers creation, each rotation phase, resumption of the persisted epoch, and both the rejection
and the deduplication of a delayed old permit. Each rotation phase is entered from the durable record that
phase leaves, so both sides of every rotation write are covered by a state rather than by a throw.

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

None.

### Sprint 10.3: Session-scoped operation state [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Classify every persisted operation totally, so recovery has no default branch.

#### Deliverables

- One private total classifier maps each persisted operation to exactly one of: unknown, one of the five
  pre-call continuable phases, already-observed retryable, successful, or terminal.
- Only continuable phases receive current-fence prepare authority; successful and terminal branches receive no
  effect authority at all.
- The retryable whitelist is closed: reservation/effect absence, ordinary or adopted same-identity teardown
  presence, adoption absence, repair-original, and managed-phase-from — and only under the same operation key
  after old permits are fenced.
- A terminal acknowledgment first verifies every registered outcome settled, then compare-and-swaps the exact
  session version closed, so a concurrent prepare or a retained proof cannot win.
- The classifier is the **input** the recovery phase's protected recorded-session interpreter consumes: this
  sprint owns the total classification of a persisted operation, and the phase that has a reopened run's
  records owns rebinding and closing them.

#### Validation

`SessionSpec` covers each classifier branch, the whitelist, the no-effect-authority branches, and the
terminal-acknowledgment race.

#### Remaining Work

None.

### Sprint 10.4: The interrupted coordinator state is a value [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
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
  the descriptor, the closed transaction kind, the target constructors, and the two encoders — and
  nothing else. It is the encoding production writes rather than a second implementation that could agree
  with itself while disagreeing with the writer, and it mints no authority: there is no permit
  constructor, no record-key minter beyond the coordinator's own, and no transaction runner.
- `runLifecycleTransaction`, `recoverApplying`, and `applyTargets` carry no crash point, and the library
  exposes no module whose purpose is to install one. The per-target counter goes with them, because it
  existed only to name a crash point.
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
exception; `ForgeTransactionPermitFromDescriptor.hs` proving a descriptor is not a permit; and the new
absence guard proved non-vacuous by naming the shape and finding none.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 237.07 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — the journal, sessions, fences, and the total classifier.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption matrix built from durable values, and what
  in-process coverage cannot reach.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of the session/fence protocol.
