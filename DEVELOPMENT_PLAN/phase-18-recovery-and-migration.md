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
- An ordinary open revision whose records prove the run acquired **nothing** is resolved: it reclaims both owned
  objects and closes the lease and mode under the reopening's own authority.
- A persisted `Closing` epoch is **resumed**, not refused. `authorizeHarnessClose` persists the epoch before the
  terminal projection precisely so the gap is recoverable, so recovery finishes that close rather than reopening
  the run: `resumeHarnessClose` is the only route to a close authorization that does not persist a new epoch,
  it re-reads the durable disposition and admits exactly the epoch the dead run recorded, and it needs no fresh
  all-sessions-closed proof because the close it resumes already consumed one. A run with no persisted close, or
  a different epoch, is refused.
- An **incomplete** migration is resolved the same way, and for the same reason. Its recorded kind is a durable
  observation that the activation barrier was never crossed, so there is no new revision to follow through and
  the staging is discarded rather than resumed. What makes that safe is `verifyNoProjectResourcesAcquired`, not
  the classification: a staging that acquired anything wrote an effect record and the proof refuses it on either
  side of the barrier.
- A **completed** migration is **resumed**. Its activation compare-and-swap committed, so the project's live
  revision is the new one and the only correct continuation is to follow that activation through — a
  resumption, not a close. The reopening yields everything that resumption needs, as one consistent set taken
  inside its own protected entry:
  - the **authority broker** it allocated, so every retained record and the resumption itself run under one
    generation;
  - the **old-permit fence set**. `fenceOldPermits` completes the stable initial-fence protocol idempotently
    when a kill left it unsettled, enumerates the exact operation keys that can still receive authority
    *before* rotating, and only then supersedes the epoch — so a delayed backend call from the dead run fails
    the prepare gate's equality check instead of landing as though it were current. An operation already
    settled or terminal holds no authority and is not a member;
  - the **verified session/operation manifest**. `verifySessionManifest` enumerates the session set and the
    operation set independently, from their own key spaces, and then *checks* the pairing — so an orphan
    operation, a duplicate session, and a declared membership that disagrees with the store are three named
    refusals rather than an unnoticed divergence. A zero-operation Open session is a required member;
  - the **protected recorded-session interpreter**. `interpretRecordedSessions` handles every operation by its
    recorded disposition, compare-and-swap rebinds each still-Open session record onto the fresh generation
    *while it is still Open*, and only then closes it. Committed and terminal work is left byte-for-byte
    alone; a pre-call or observed-absent operation is recorded terminal at `RecoveryAbandoned`; an
    unrecognised phase refuses the whole interpretation rather than being swept.
  - `CurrentBrokerSessionAdmission` is minted only from all three together, and re-proves every session Closed
    at the store version it mints on.
- The resumption is `withCompletedMigrationRecovery` → `activateMigratedPlan`. The superseded revision is read
  out of the durable stable migration key, never inferred from the current config, so an operator who edited or
  deleted the config between the crash and the sweep cannot change which revision gets activated.
- The lease and the run's persisted snapshot are *expected* to disagree across a committed barrier: the
  snapshot record is immutable by construction, so the activation could not have rewritten it even in
  principle. The reopening treats that one divergence as evidence the barrier was crossed. Every other
  divergence is still a substitution and still refuses.

#### Validation

`AuthoritySpec` covers the yielded shape, the fresh generation, the unbound refusal, the closed-lease recheck,
the typed `Closing` branch, the resolvable branch's full settlement, and the resumed close: the wrong epoch is an
epoch mismatch, a run with no persisted close has nothing to resume, and the resumed close settles the run so
the sweep's own recheck then sees an empty set.

`SessionSpec`'s `abandoned-run admission` group covers the four new pieces against a real protected store, with
every case abandoning a session the way a kill does — stopping between two durable writes and reopening the
store. It covers the fence set's enumeration and rotation, that a settled operation is not a member, the
idempotent completion of an unsettled fence protocol, the manifest's pairing, the required zero-operation
member, the orphan-operation and membership-mismatch refusals, the interpreter settling pre-call work and
closing the session so a fresh one then opens, committed work being left alone, the unrecognised-phase refusal,
an interrupted effect settling as abandoned, and evidence taken over one plan being unusable for another.

`HarnessSpec` covers the migration branches through the **production ownership bracket** rather than its
pieces — the run is abandoned the way a killed one is, and what is observed is whether the next run is admitted.
An incomplete migration is swept and the successor starts; a **completed one is now resumed and the successor
also starts**; and an incomplete migration that recorded an effect still blocks it, which is what shows the
proof rather than the classification is the gate.

#### Remaining Work

Two items, and both are about a run that acquired something rather than about the classification.

Child-first teardown at a recovery boundary is open: a resumed run whose records show it acquired resources
still refuses by name, because releasing them needs the recursive teardown forest driven from a recovery
boundary, which is a different capability from closing a lease.

That boundary is admitted by the same recovery wire the recursive teardown descent uses — a nested
teardown and a nested recovery are one edge, so they share one tag rather than each minting a private
one. The tag, its `RecoveryProjectionBinding`, and its `VerifiedRecoveryWire` belong to the
[authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md), which owns every v1
protocol tag; what this phase owns is deriving the signed non-secret adapter wire from the bound snapshot
and consuming it at the recovery boundary, where the old config may be edited or absent.

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
- The **migration profile builders** exist and each has exactly one producer:
  - `withProjectUpMigrationProfile` revalidates the exact Production `ProjectUp` root, the active mode under
    the same broker generation, the old bound lease, the verified snapshot, and — the load-bearing one —
    `NormalActiveRecovery`. A migration may only start from a binding that was *fresh*, so an abandoned
    invocation's revision has to be recovered before anything is carried forward from it. It carries no plan.
  - `withProspectiveMigrationPlan` persists one candidate under a fresh **stable migration key**, reads it back
    authoritatively, and yields a `ProspectivePlanSnapshot` that authorizes nothing. A crash here is harmless
    by construction: the live revision is untouched and the store gains only an unreferenced record. A
    migration onto the same plan digest is refused. The key is a pure function of the run and both digests, so
    a retried migration converges on it rather than proposing a second one.
  - `withPlanMigration` loads the candidate back under its own key, records the run as an **incomplete**
    revision, and only then compare-and-swaps the lease from `bound` to `frozen`. That ordering is what makes
    the window recoverable: a crash between the record and the freeze leaves a run whose recorded kind says the
    barrier was not crossed. Freezing is what stops old-revision preparation — a frozen lease is not bindable,
    so old- and new-bound authority cannot coexist.
- The **activation transition** is `commitMigrationActivation` → `activateMigratedPlan`:
  - the compare-and-swap replaces the frozen state with a lease bound to the *candidate's* digests, and only
    after it commits is the run recorded a **completed** migration. A crash before the swap leaves a frozen
    lease and an incomplete record, so recovery discards the staging; a crash after it leaves a new-bound lease
    and a completed record, so recovery resumes activation. Re-running against the same frozen capability
    observes the already-bound candidate and finishes the record rather than refusing, so the dangerous middle
    state converges instead of stranding.
  - `activateMigratedPlan` settles the **old** revision's recorded sessions first and only then admits the new
    revision's broker, so the committed-new activation window cannot open a session. The admission it returns
    is the new revision's, minted from that plan's own complete session and operation sets.
- `withCompletedMigrationRecovery` is the configless post-CAS path. It is reachable only from a run whose
  recorded kind is `CompletedMigration`, and it recovers the superseded revision from the durable stable key
  rather than from any config. Only the *old* plan index is bound generatively — that is the revision recovery
  can name from nothing else — while the new one is the caller's own bound lease, still compared at the term
  level before anything is admitted.
- A recovered `Production` `up` reaches only `RecoveredProductionLifecycleProfile`, which can rebuild the same
  plan identity and nothing else — no fresh profile, no harness scope, no teardown authority.

#### Validation

`AuthoritySpec`'s `plan migration` group covers the protocol in the order the protocol runs, each case naming
the state a crash at that point would leave: an already-bound lease yields no `NormalActiveRecovery` so a
migration cannot be proposed from it at all; a same-digest migration is refused; a candidate is persisted, read
back, and carries the derived stable key; freezing records the incomplete side of the barrier; the
compare-and-swap switches the lineage and records the completed side; a second commit against the same frozen
capability converges rather than refusing; activation admits the new revision's broker; and completed-migration
recovery loads both digests from the durable key and drives the activation through, while a run with no
completed migration has nothing to recover.

`SessionSpec` covers the recorded-session machinery the activation transition consumes.

#### Remaining Work

The **configful forward** path is open: `withProspectiveMigrationPlan` takes the candidate's digests rather
than consuming a scope-correct new config plus non-empty plan drafts, and `withCompletedMigrationPlan` — the
rebuild that may only proceed when the supplied config renders the persisted bytes — is not built. What exists
is the digest-level spine and the configless recovery half, which is what the sweep's resumption needs.

The complete `VerifiedResourceRecordSet` rehydration is also open, so activation proves prior-session
settlement but not yet the complete resource-record set beside it.

The native interruption runs that confirm resumption on a real lane are owed to the linux-cpu acceptance phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — recovery classification and the migration barrier.
- `documents/architecture/harness_workflow.md` — the sweep's place before a new run.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption and kill-point matrix.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of recovery.
