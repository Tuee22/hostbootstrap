# Phase 18 — Recovery and migration

**Status**: Active
**Depends on**: Phase 17 (the recursive lifecycle command)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus live interruption runs on linux-cpu

> **Purpose**: Let the next invocation resolve whatever a killed predecessor left, without ever adopting state
> it cannot attribute.

## Phase Objective

Every durable record the lower phases write exists so that this phase can act on it. An interrupted invocation
leaves a mode, a lease, ownership records, sessions, fences, and possibly real resources. Recovery classifies
each of those totally, resolves the branches it can prove safe, and stays fail-closed on the rest — naming
exactly what an operator must resolve rather than deleting on a guess.

## Sprints

### Sprint 18.1: The abandoned-run sweep [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

Enumerate every incomplete lease at one store version and settle it, under the liveness lock.

#### Deliverables

- The sweep runs inside `withRunLiveness`, which is the only thing that can tell it a lease's owner is dead.
- `VerifiedIncompleteRunLease` has a private constructor, so a caller cannot manufacture a run to skip.
- Separate rank-2 fold callbacks receive the unbound and bound kinds; an unbound member's owned objects are
  reclaimed from their durable origin records **before** its lease closes, while the run is still identifiable.
- An unbound lease closes only behind `verifyUnboundLeaseHasNoEffects`; a stray effect-shaped record refuses.
- The sweep re-reads the set after the callbacks, so a fold that resolved nothing cannot report a vacuous
  success, and only an empty final set mints the versioned proof `withHarnessRoot` consumes.
- The sweep enumerates only harness leases: the reserved Production invocation lease is shaped identically but
  belongs to the other profile's recovery — see [rationale.md](rationale.md).

#### Validation

`AuthoritySpec` covers the unbound close, the effect-record refusal, the vacuous-success refusal, the
live-Production exclusion, and a four-process race proving a live run's lease is never swept.

#### Remaining Work

None.

### Sprint 18.2: Reopening a bound abandoned run [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Give a bound abandoned run a typed reopening with destroy-only authority.

#### Deliverables

- `withAbandonedHarnessRun` rechecks the lease is still bound to the digests the sweep observed, reads the old
  snapshot back, classifies the durable invocation record — all before minting any authority — then allocates a
  **fresh** broker generation and retains the mode and lease onto it.
- It yields the old snapshot, the already-bound lease, the run's own mode, a `VerbDestroy`-only root, the
  recovery classification, and a `RecoveredHarnessClose` close root, and nothing else: no fresh profile, no
  harness authority, no unbound lease to rebind.
- `classifyAbandonedBoundRun` is reachable only from a sweep-minted lease and reads the digests off the record.
- The one branch this sprint resolves is an ordinary open revision whose records prove the run acquired
  **nothing**; it reclaims both owned objects and closes the lease and mode under the reopening's own authority.
- A persisted `Closing` epoch and either migration revision stay fail-closed and name why.

#### Validation

`AuthoritySpec` covers the yielded shape, the fresh generation, the unbound refusal, the closed-lease recheck,
the typed `Closing` branch, and the resolvable branch's full settlement.

#### Remaining Work

The opener does not yet yield the authority broker, the old-permit fence set, or the verified
session/operation manifest, and it does not run the protected recorded-session interpreter — so the
`Closing`, incomplete-migration, and completed-migration branches are typed but not resumable. Child-first
teardown at a recovery boundary, and the signed recovery-wire handoff a boundary with an edited or missing old
config needs, are also open.

### Sprint 18.3: Migration and interruption gates [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Resume the correct side of the migration activation barrier.

#### Deliverables

- `recordOpenRevisionMigration` makes which side of the barrier a revision is on a **durable observation**
  rather than an inference from the current config.
- An incomplete migration resumes its staging; a completed one resumes activation. The committed-new activation
  window cannot open a session.
- Both normal and completed-migration activation verify the complete rehydrated resource set and prior-session
  settlement before yielding current-broker admission.
- A recovered `Production` `up` reaches only `RecoveredProductionLifecycleProfile`, which can rebuild the same
  plan identity and nothing else — no fresh profile, no harness scope, no teardown authority.

#### Validation

`AuthoritySpec` and `SessionSpec` cover the recorded barrier, both resumption sides, the no-session window, and
the recovered-profile narrowness.

#### Remaining Work

The recorded barrier and the recovered production profile exist and are gated. The migration profile builders
and the activation transition itself are not built, and the native interruption runs that confirm resumption on
a real lane are owed to the linux-cpu acceptance phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — recovery classification and the migration barrier.
- `documents/architecture/harness_workflow.md` — the sweep's place before a new run.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption and kill-point matrix.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of recovery.
