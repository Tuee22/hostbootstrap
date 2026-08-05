# Phase 9 — Lifecycle modes, run leases, and profiles

**Status**: Active
**Depends on**: Phase 5 (operator, root, and command authority), Phase 7 (Dhall configuration and the
generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Make a project be in exactly one lifecycle mode at a time, and make every invocation hold a
> durable, classifiable lease that a crash leaves in a recoverable state.

## Phase Objective

Production and a test run must never overlap, and a crashed invocation must leave behind something a
successor can classify. Both are one protected record apiece: a project-wide **mode** both openers contend
on, and a per-invocation **lease** that is recorded before a plan exists and bound to one once it does.

That pair is what replaces an opaque lock: an unbound lease can be closed once it is proved to have recorded
no effect, and a bound lease names the exact snapshot its invocation reached.

## Sprints

### Sprint 9.1: The project-wide mode [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

One mode record, two contending openers, exactly one winner.

#### Deliverables

- `ProjectMode` is `ProductionMode` or `HarnessMode runId`; `projectModeName` renders it for refusals.
- `acquireMode` is a compare-and-swap on one record. Production **retains** an already-held Production mode —
  which is what makes `down` keep the exclusion — and a harness run may take the mode only when it is absent.
- Two harness runs, or a harness run against live Production, contend on that exact record and exactly one
  wins, with the loser refused by a message naming the held mode.
- `releaseMode` compares the mode before deleting, so one profile cannot release another's.
- `ProjectModeLease projectId brokerGeneration` is opaque and carries the generation it was taken under.

#### Validation

`AuthoritySpec` covers the retain branch, the harness exclusion, the cross-profile refusal, and a
four-process race proving exactly one winner and that a live run's lease is never taken.

#### Remaining Work

The **cross-profile** exclusion is proved deterministically in-process, not across processes. The mode
transaction it turns on is a single compare-and-swap inside one protected entry, and the discriminating
observable — whether a competitor resolved the other profile's state — is not visible to another process
without exporting a read-only lease observer, which § EE's clause set rules out. The remaining item is
therefore an out-of-process cross-profile probe built the way the four-process reservation race is: a real
competitor binary whose only report is its own outcome.

### Sprint 9.2: Plan snapshots and run leases [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A bound lease always names a snapshot that exists durably.

#### Deliverables

- `persistPlanSnapshot` and `persistCanonicalPlanSnapshot` write an **immutable** snapshot record; repeating
  the exact bytes is idempotent and does not advance the version, and any attempted replacement is refused.
- `verifyPlanSnapshot` reads it back and yields `VerifiedPlanSnapshot projectId specDigest planDigest` inside
  a continuation, so the digests a lease is bound to are the store's rather than a caller's.
- `UnboundRunLease` authorizes no effect; its only powers are to be bound or to be closed after proof.
- `bindRunLease` compare-and-swaps the lease onto the verified snapshot and yields `RunLeaseBinding`: a
  `FreshRunLeaseBinding` with proof that no recovery is owed, or an `ExistingRunLeaseBinding` carrying the
  recovery classification. An already-bound lease is not an error — it is the abandoned-invocation case.
- A lease bound to *different* digests is refused: that is snapshot substitution, not resumption.

#### Validation

`AuthoritySpec` covers idempotent persistence, the replacement refusal, both binding branches, and the
substitution refusal. The bound-snapshot assertion reads the record back through the production decoder
rather than a second copy of the wire format.

#### Remaining Work

None.

### Sprint 9.3: The lifecycle profile openers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Open a profile only from the exact mode and lease that authorize it, inside one transaction.

#### Deliverables

- `withProductionRoot` and `withHarnessRoot` run the operator check, the precondition recheck, and the mode
  compare-and-swap **inside one protected entry**, so nothing can slip between the check and ownership.
- `withHarnessRoot` mints the run identity itself and binds it in a rank-2 continuation, so a value from one
  run cannot be presented in another.
- `withProductionLifecycleProfile` and `withHarnessLifecycleProfile` require the exact active mode and a
  still-unbound lease. A test component receives only the harness opener, so there is no route from harness
  code to a production profile.
- `HarnessPreconditions` holds its probe privately and derives the sibling-config half from installed project
  identity, so a caller cannot inject a successful observation.
- Production's lease is recorded under one reserved run identity, distinguished structurally from a generated
  one.

#### Validation

`AuthoritySpec` covers both openers, the in-transaction recheck, the wrong-mode refusals, and the compile-fail
fixture proving a test component cannot reach the production planner.

#### Remaining Work

None.

### Sprint 9.4: Closure evidence and terminal close [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Close a project only on proof, and release the mode last.

#### Deliverables

- `verifyNoProjectResourcesAcquired` is the true-pre-effect verifier: a single effect-shaped record refuses,
  so partial work can never be relabelled as a refusal that preceded acquisition.
- `destroySettledClosure` converts a settled-destroy proof plus a complete-session proof into the other
  branch of `ProjectClosureEvidence`, comparing both against the bound lease's own plan digest.
- `releaseProductionMode` requires the root half and the matching evidence half to agree; a settled-destroy
  root cannot be paired with pre-effect evidence.
- `HarnessCloseRoot` is the harness counterpart of the production close root, with exactly two producers — the
  live root, and abandoned-run recovery — and it records the project name.
- `authorizeHarnessClose` persists the Closing epoch before the terminal projection runs;
  `finalizeHarnessClose` closes the lease and releases the exact mode epoch **last**.
- `closeHarnessRun` is the short close and accepts only pre-effect evidence; a settled destroy must persist a
  Closing epoch first — see [rationale.md](rationale.md).
- `ProductionInvocationCompleted` / `closeCompletedProductionInvocation` end an *invocation* without clearing
  Production mode, which is what lets `down` retain the exclusion. An uncertain acknowledgment is its own
  constructor, so the only sound continuation is resuming the same stable close key.

#### Validation

`AuthoritySpec` covers each verifier, the root/evidence disagreement, the settled-evidence refusal on the
short close, the cross-project close refusal, and that mode is released only after the lease closes.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — modes, leases, snapshots, profiles, and closure.
- `documents/architecture/harness_workflow.md` — the harness profile's place in the model.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the out-of-process mode and lease races.

**Cross-references to add:**
- `development_plan_standards.md` § Y and § Z name this phase as the owner of the mode/lease contracts.
