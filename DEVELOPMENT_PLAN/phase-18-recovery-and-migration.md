# Phase 18 — Recovery and migration

**Status**: Active
**Depends on**: Phase 17 (the recursive lifecycle command)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Let the next invocation resolve whatever a killed predecessor left, without ever adopting state
> it cannot attribute.

## Phase Objective

Every durable record the lower phases write exists so that this phase can act on it. An interrupted invocation
leaves a mode, a lease, ownership records, sessions, fences, and possibly real resources. Recovery classifies
each of those totally, resolves the branches it can prove safe, and stays fail-closed on the rest — naming
exactly what an operator must resolve rather than deleting on a guess.

## Sprints

### Sprint 18.1: The abandoned-run sweep [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

Enumerate every incomplete lease at one store version and settle it, under the liveness lock.

#### Deliverables

- The sweep runs inside `withRunLiveness`, which is the only thing that can tell it a lease's owner is dead.
- `VerifiedIncompleteRunLease` has a private constructor, so a caller cannot manufacture a run to skip.
- `recoverAbandonedHarnessRuns` takes two separate callbacks of type
  `VerifiedIncompleteRunLease projectId -> IO (Either ModeError ())`, one for unbound and one for bound
  members; an unbound member's owned objects are reclaimed from their durable origin records **before** its
  lease closes, while the run is still identifiable.
- An unbound lease closes only behind `verifyUnboundLeaseHasNoEffects`; a stray effect-shaped record refuses.
- The sweep re-reads the set after the callbacks, so a fold that resolved nothing cannot report a vacuous
  success, and only an empty final set mints the `ClosedAbandonedHarnessRuns` proof (carrying the swept
  count) that `withHarnessRoot` consumes after `sweptSetStillEmpty` re-checks emptiness in its own entry.
- The sweep enumerates only harness leases: the reserved Production invocation lease is shaped identically but
  belongs to the other profile's recovery — see [rationale.md](rationale.md).
- Closing a harness lease and releasing its Harness mode is one durable step: no store state holds a
  `LeaseClosed` lease beside a `harness:<run>` mode that the sweep cannot reach. An undecodable lease, or a lease
  key whose run segment fails `parseRunKey`, refuses the sweep with `ModeMalformedRecord` naming the key.

#### Validation

`AuthoritySpec` covers the unbound close, the effect-record refusal, the vacuous-success refusal, and the
live-Production exclusion. `HarnessSpec` ("racing harnesses converge on exactly one authoritative
acquisition") starts four real processes together and proves exactly one acquires the run.

The sprint closes when `AuthoritySpec` also carries: a split-close case that leaves a harness lease
`LeaseClosed` while the mode record still reads `harness:<run>` (the state a death between the lease write and
the mode write of `finalizeHarnessClose`, `closeHarnessRun`, or the sweep's unbound branch leaves), then runs
`recoverAbandonedHarnessRuns` and `withHarnessRoot` and asserts the successor is admitted and the mode record is
absent — or, if the two writes become one coordinator transaction, an interrupted-transaction fixture at every
prefix that converges to closed lease plus absent mode; a malformed-lease case writing `not-a-lease` at a harness
lease key and a well-formed lease under a 49-character run segment, each asserting `recoverAbandonedHarnessRuns`
and `withHarnessRoot` refuse with `ModeMalformedRecord` naming the key and leave the record intact; and a
stale-proof case that mints `ClosedAbandonedHarnessRuns` on an empty store, then abandons a bound run and
releases that run's mode (so `acquireHarnessMode` cannot be the refusing guard), then calls `withHarnessRoot`
with the stale proof and asserts `Left (ModeRecoveryRequired <run>)`, that the callback is not entered, and
that the mode and lease records are unchanged. `cabal test all` from `core/` passes.

#### Remaining Work

- Make the harness lease close and mode release one durable step. `finalizeHarnessClose`, `closeHarnessRun`,
  and the unbound branch of `recoverAbandonedHarnessRuns` (`Mode.hs`) compare-and-swap the lease to
  `LeaseClosed` and then delete the mode record in a second, separate write; `incompleteLeases` skips
  `LeaseClosed`, so a death or a `releaseMode` failure between the two leaves `harness:<run>` held with no
  path that clears it, and every later harness and Production root refuses with `ModeHeldByAnother`. Either
  commit both records through the lifecycle redo coordinator that `releaseProductionMode` uses, or have the
  sweep release, inside its own entry, a `WireHarness k` mode whose lease at `k` is `LeaseClosed` or absent.
  Correct the `closeHarnessRun` Haddock, which says a crash between the two writes leaves the run recoverable.
- Add the split-close, malformed-lease, and stale-proof cases named in Validation; rename or replace the
  existing "a new harness run is refused while an abandoned lease is unresolved" case, which never calls
  `withHarnessRoot`.

### Sprint 18.2: Reopening a bound abandoned run [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Classify and reopen one sweep-proved bound run under fresh, destroy-only recovery authority.

#### Deliverables

- `withAbandonedHarnessRun` rechecks the sweep-minted bound lease, immutable snapshot, mode, and durable
  invocation classification before allocating a fresh broker generation.
- Its rank-2 continuation retains the old snapshot, bound lease and mode, destroy-only root, recovery kind,
  close root, broker, old-permit fence set, verified session/operation manifest, recorded-session
  interpretation, and current-broker session admission as one consistent package.
- `Closing` resumes only its recorded epoch. An ordinary or incomplete-migration revision closes only after
  `verifyNoProjectResourcesAcquired`; a completed migration follows the stable migration key rather than
  current config.
- Fence rotation enumerates authority-bearing operation keys before superseding the epoch; manifest verification
  pairs the independent complete session and operation sets, including zero-operation sessions.
- Recorded-session interpretation rebinds Open sessions to the fresh generation, settles each recognized
  disposition, leaves committed and terminal work unchanged, and refuses an unknown phase.
- Snapshot/lease divergence is a substitution refusal (Sprint 18.22 removes the harness migration exception).
- A Production terminal acknowledgment (`InvocationAcknowledged`) under a Harness run refuses with
  `ModeWrongRecoveryScope "harness" _`, and `resumeHarnessClose` refuses it with `ModeClosureMismatch`.

#### Validation

`AuthoritySpec`, `SessionSpec`, and `HarnessSpec` cover the yielded shape, close resumption, no-effect
settlement, all recovery kinds, exact-set session interpretation, wrong bindings and epochs, and successor
admission through the production ownership bracket.

The sprint closes when: `AuthoritySpec` carries a scope-crossing case that abandons a bound Harness run, writes
`ack\t<key>` at its invocation record, and asserts `withAbandonedHarnessRun` and `recoverAbandonedHarnessRuns`
refuse with `ModeWrongRecoveryScope "harness" _` and `resumeHarnessClose` with `ModeClosureMismatch`, mode and
lease unchanged; the cases "reopening an abandoned bound run yields destroy-only authority on a fresh
generation", "a persisted closing epoch is reopened as the closing branch", "a run with no persisted close has
nothing to resume", and "an unbound lease cannot be reopened; only the sweep may close it" each count their
callback invocations in an `IORef` and assert exactly one after the sweep; "a persisted closing epoch is resumed,
and only at its own epoch" also presents `epoch - 1` and asserts the same mismatch; "a closing project admits no
new session, and only its own epoch resumes" also presents epoch 5 against the persisted 7 and snapshots every
protected record (key, version, bytes) before the same-epoch resume and asserts the store is unchanged after it,
and "only the matching closing epoch can become closed" also presents epoch 5; those cases also assert
`harnessCloseRun`, `harnessCloseEpoch`, `harnessCloseOrigin`, `incompleteRunLeaseRunText`, and
`incompleteRunLeaseKind` against the run and epoch they set up; and `HarnessSpec` carries a persisted-Closing
case that drives a Harness run through `authorizeHarnessClose`, abandons it before `finalizeHarnessClose`, runs
the next run through `protectedProjectRunOwnership`, and asserts the successor is admitted, the abandoned run's
data-root generation and generated config are gone, and its lease reads `LeaseClosed`. `cabal test all` from
`core/` passes.

#### Remaining Work

- Add the scope-crossing, callback-count, lower-epoch, unchanged-store, and accessor assertions named in
  Validation to `AuthoritySpec`.
- Add the persisted-Closing `HarnessSpec` case that drives `resolveBoundRun`'s `HarnessPersistedClosing` branch
  (`finishPersistedClose` in `Harness/Ownership.hs`) through `protectedProjectRunOwnership`.

### Sprint 18.3: The durable migration barrier [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Persist and classify both sides of the migration activation barrier.

#### Deliverables

- `withProjectUpMigrationProfile` is a pure check over the Production `ProjectUp` root, mode lease, old bound
  lease, and verified snapshot: it refuses a root/mode broker-epoch mismatch (`ModeEpochMismatch`), a
  run-key mismatch, a bound lease whose binding origin is not `FreshBinding`, and a spec or plan digest that
  differs from the snapshot (each `ModeSnapshotMismatch`); it carries no plan.
- `withProspectiveMigrationPlan` records a non-authorizing digest candidate under the stable migration key and
  reads it back; the same-plan case refuses and retry converges on the same key.
- `withPlanMigration` records `IncompleteMigration` before compare-and-swapping the lease from bound to frozen,
  so a pre-barrier crash retains the old lineage and cannot prepare through the frozen lease.
- `commitMigrationActivation` switches the frozen lineage to the candidate-bound lease, records
  `CompletedMigration`, and idempotently completes the record after a post-swap crash.
- `withCompletedMigrationRecovery` selects only the completed branch and recovers the superseded digest from
  the stable key; `RecoveredProductionLifecycleProfile` cannot become a fresh or teardown profile.

#### Validation

`AuthoritySpec` covers stable candidate identity, same-plan refusal, incomplete freeze, completed lineage
switch, idempotent commit, both crash classifications, and configless digest recovery. `SessionSpec` covers
the recorded-session evidence retained beside the barrier.

The sprint closes when `AuthoritySpec`'s migration group carries one case per `withProjectUpMigrationProfile`
refusal branch, each calling the function directly and matching the exact constructor: broker-epoch mismatch
→ `ModeEpochMismatch`, run-key mismatch → `ModeSnapshotMismatch`, a non-`FreshBinding` bound lease →
`ModeSnapshotMismatch "fresh lease binding" "recovered or migrated lease binding"` (presented twice: once with
the `ExistingBinding` lease `cancelIncompletePlanMigrationForTeardown` returns, once with the `MigratedBinding`
lease `commitMigrationActivation` returns), and spec- and plan-digest mismatch → `ModeSnapshotMismatch`; the
migration cases also assert `migrationProfileRun`, `migrationProfileOldSpecDigest`, `migrationProfileEpoch`,
`frozenMigrationRun`, `migrationBarrierKey`, and `prospectiveSnapshotConfigDigest` against the values their
fixture set up; and `cabal test all` from `core/` passes.

#### Remaining Work

- Add the direct `withProjectUpMigrationProfile` refusal cases named in Validation to `AuthoritySpec`'s
  `migrationCases`, and delete the existing "the migration profile refuses a recovery-owed binding" case: it
  only calls `bindRunLease` twice, duplicating "rebinding an already-bound lease is not a fresh transition".
- Add the migration accessor assertions named in Validation.
- Rewrite the `ProjectUpMigrationProfile` Haddock in `Mode.hs` so it names the `FreshBinding` check the
  function performs instead of a `NormalActiveRecovery` input it does not take.

### Sprint 18.4: Verified resource-record bundles [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ResourceRecordSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Bind each durable resource disposition to the exact plan, frame, operation, generation, and ownership
evidence recovery needs.

#### Deliverables

- Opaque `VerifiedResourceRecordBundle` is the sole verified view of one canonical resource record.
- The canonical bytes carry the plan digest, frame and resource keys, generation, ownership operation key,
  record version, phase, adapter revision, and disposition; protected verification checks every binding.
- Its eliminator yields a receipt only for an owned member and a verified tombstone only for a released member;
  malformed versions and any substitution refuse.

#### Validation

`ResourceRecordSpec` pins canonical round trips and every wrong-binding refusal. `CompileFailSpec` pins the
hidden constructor and the separation between owned receipts and released tombstones.

On 2026-08-22, the focused resource-record group passed all five runtime and compile-fail cases, and
`cabal test all --ghc-options=-Werror` passed all 2,319 tests on linux-cpu.

The sprint closes when `ResourceRecordSpec`'s key case uses identities that share a long common prefix and
differ only in the last character, plus a same-resource-in-two-frames pair and a split-boundary pair
(`("ab", "c")` against `("a", "bc")`), asserting each key is `Right` and the pair differs; and the format,
trailing-byte, and noncanonical-word cases each match the refusal's cause text ("resource record format version
differs", "resource record has trailing bytes", "not a canonical positive word") instead of accepting any
`Left`, with added cases substituting the domain field (index 0, "resource record domain differs"), emptying
the phase field ("resource record phase is empty"), and putting invalid UTF-8 in the frame field ("resource
record frame key is not UTF-8"); and `cabal test all` from `core/` passes.

#### Remaining Work

- Tighten the key collision case and the format/trailing/noncanonical cases, and add the domain, empty-field,
  and invalid-UTF-8 cases, all named in Validation.

### Sprint 18.5: Resource settlement recording [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Write the verified bundle source at the one settlement boundary that changes a managed resource's durable
disposition.

#### Deliverables

- The settlement boundary writes ordinary or adopted ownership with the matching journal commit; release keeps
  the stable member and writes its tombstone instead of deleting it.
- Repair and phase transitions carry the receipt identity while advancing phase/version, and the carrier keeps
  the stable frame/resource/operation binding the writer needs.
- Same-settlement retry converges on byte-identical state; a conflicting member or version refuses.
- The durable phase a settlement writes is derived from the handle's phase index (the source phase from the
  `PhaseAdvance` evidence), never from caller text; a released settlement removes the resource's managed
  authority from the carrier; a key outside the node's view refuses with the out-of-view `Conflict` before any
  bytes are rendered.

#### Validation

`ChainSpec` and `ReconcileSpec` cover owned, adopted, released, repaired, and phase-transition records,
idempotent retry, and kills on both sides of the protected settlement write.

On 2026-08-22, the focused `ChainSpec` gate passed all 43 cases and the focused reconciliation gate passed
all 65 matching cases. `cabal test all --ghc-options=-Werror` then passed all 2,324 tests on linux-cpu,
including governed documentation validation.

The sprint closes when: `CompileFailSpec` carries a fixture that passes a `Managed Stopped` handle to
`carryManagedResourceSettlement` expecting a `running` record and fails to type-check (no phase `Text`
argument remains); `ReconcileSpec` carries a case that settles a release through
`carryReleasedResourceSettlement` and then asserts `withCarriedManagedResource` and
`withCarriedManagedResourceReceipt` refuse that resource; and a case that calls
`carryManagedResourcePhaseSettlement` and `carryReleasedResourceSettlement` with a key outside the node's view
and asserts the out-of-view `Conflict` (not "resource record frame key is empty"); and `cabal test all` from
`core/` passes.

#### Remaining Work

- Derive the settlement phase in `carryManagedResourceSettlement`, `carryManagedResourcePhaseSettlement`, and
  `carryReleasedResourceSettlement` (`Reconcile.hs`) from the handle's phase index through a closed class (for
  example `PhaseName phase`), and take the source phase from the `PhaseAdvance` evidence; delete the free
  `phase`/`sourcePhase`/`targetPhase` `Text` parameters.
- Make a released settlement remove managed authority: mark the `CarriedResource` released (or move the
  released evidence to a slot the `withCarriedManagedResource*` openers cannot read) and have those openers
  refuse it.
- Make `settlementBytes` refuse with the out-of-view `Conflict` when the frame lookup misses instead of
  defaulting the frame to `""` (or resolve the frame and validate the receipt once before rendering).
- Add the compile-fail fixture and the two `ReconcileSpec` cases named in Validation.

### Sprint 18.6: The complete resource-record set [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ResourceRecordSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Prove that recovery and migration hold exactly the resource members declared by the bound snapshot.

#### Deliverables

- Opaque `VerifiedResourceRecordSet` is minted only by a protected exact-set fold over the bound snapshot and
  resource key space; versioned snapshot decoding defines membership.
- Missing, duplicate, extra, unknown, wrong-plan, wrong-key, or disposition-inconsistent members refuse, and
  the set carries a canonical `recordSetDigest` over bundles sorted by (frame, resource). A member is
  disposition-inconsistent when its `owned`/`released` disposition disagrees with the committed journal
  settlement recorded for its ownership operation key.
- Raw records, caller-selected lists, unknown snapshot versions, and evidence for another snapshot cannot enter
  the fold. The `recordSetDigest` preimage carries the plan digest after the domain tag, so sets of different
  plans (including two empty sets) never share a digest.
- Every set verifier fixes the `planId` index from its bound-snapshot witness or a rank-2 continuation, never
  from the call site; a digest-only snapshot refuses with a distinct malformed-snapshot error, not
  `ModeSnapshotMissing`.

#### Validation

`ResourceRecordSpec` covers exact-set success, missing and extra refusal, canonical member refusals, and a
digest that is stable across two immutable read-backs of the same writes. `CompileFailSpec` proves callers
can neither construct `VerifiedResourceRecordSet` nor combine snapshot evidence from distinct plan digests.

On 2026-08-22, all six focused `ResourceRecordSpec` cases passed, including exact-set success, missing and
extra refusal, canonical member refusals, and stable immutable read-back. The two public compile-fail cases
then proved that callers can neither construct `VerifiedResourceRecordSet` nor combine snapshot evidence
from distinct plan digests. `cabal test all --ghc-options=-Werror` passed all 2,329 tests on linux-cpu,
including governed documentation validation.

The sprint closes when `ResourceRecordSpec` also carries: a wrong-plan member case asserting
`ModeMalformedRecord` containing "belongs to another plan"; a forward-versus-reverse write-order case
comparing `exactSetDigest False` with `exactSetDigest True` for equality; and a disposition-inconsistent
case (an `owned` member whose journal settlement is a release, and the converse) asserting
`ModeMalformedRecord`; a different-member case asserting two sets that differ only in one member's
disposition (and, separately, generation) have different digests; a pinned case asserting the exact hex digest
of a fixed two-member set; a partial-set case writing only the provider record of `twoResourcePlan` and
asserting `ModeMalformedRecord` whose text contains "membership differs from the snapshot"; a wrong-key case
storing a valid record under another member's key, asserting `ModeMalformedRecord` containing "key differs from
its canonical member"; a cross-store case and a mismatched-bound-snapshot case calling
`withVerifiedResourceRecordSet` and asserting `ModeSnapshotMismatch`; a digest-only snapshot case asserting the
distinct malformed-snapshot refusal; two empty-membership sets of different plans asserting different digests;
and duplicate-member refusal cases for `canonicalPlanResourceMembersKernel` (a snapshot whose steps declare one
`(frame, resource)` twice, asserting "the canonical resource member set contains a duplicate") and for a
`decodeStepMembers` walk over a field corrupted with the plan digest recomputed, asserting
`ModeMalformedRecord`. The shared `resourceRecords` helper fails the case on a missing operation or a
`withPlannedResourceOfKind` refusal, and every caller (including `withCanonicalResourceFixture` and
`withCanonicalReleasedResourceFixture` as `HarnessSpec` consumes them) asserts the exact record count (1 for
`resourcePlan`, 2 for `twoResourcePlan`). `cabal test all` from `core/` passes.

#### Remaining Work

- Enforce disposition consistency in the protected exact-set fold (`withVerifiedResourceRecordSet` and its
  kernel `verifyResourceRecordSetKernel`): read the committed journal settlement for each member's ownership
  operation key in the same session and refuse a member whose disposition disagrees with it.
- Add `frameWire` of the plan digest to the `recordSetDigest` preimage in `verifyResourceRecordSetKernel`
  (`ResourceRecord.hs`), after the domain tag.
- Make `withVerifiedResourceRecordSetFromSnapshot` (`Mode.hs`) fix `planId` through a rank-2 continuation
  (`forall planId. VerifiedResourceRecordSet scope planId -> result`) or a `BoundPlanSnapshot`/admission witness,
  and express its callers' plan-digest comparisons through that witness.
- Return a distinct refusal for a snapshot that exists but has no canonical config/bytes (for example
  `ModeMalformedRecord` "plan snapshot is digest-only; resource membership needs a canonical snapshot") from
  `withVerifiedResourceRecordSet` and `withVerifiedResourceRecordSetFromSnapshot`, keeping
  `ModeSnapshotMissing` for an absent record.
- Make `resourceRecords` in `ResourceRecordSpec` call `assertFailure` with the refusal instead of dropping the
  record, and add the record-count assertions named in Validation.
- Add the wrong-plan, forward-versus-reverse digest, disposition-inconsistent, different-member, pinned-digest,
  partial-set, wrong-key, cross-store, mismatched-snapshot, digest-only, empty-set, and duplicate-member cases
  named in Validation.

### Sprint 18.7: Broker-bound resource rehydration [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/ResourceRecordSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Rebind the complete durable set to fresh local identities and the recovery broker without recreating
authority from raw bytes.

#### Deliverables

- Opaque `RehydratedResourceSet` binds the verified set, snapshot plan digest, record-set digest, and fresh
  broker generation, after re-reading every member record in the rehydrating session and matching it
  byte-for-byte against the verified set.
- The owned eliminator alone yields the rebound handle/receipt; the released eliminator alone yields the
  tombstone. Any stale or unresolved member refuses the whole set.
- Raw receipts and persisted bytes cannot mint handles, teardown steps, session admission, or rollover
  authority.
- Each rehydrated handle carries its set's plan digest, and the recovered release transition reads the record
  key and released bytes from that digest rather than from a caller-supplied plan.

#### Validation

`ResourceRecordSpec` covers mixed owned/released rehydration under one broker and refusal of a verified set
presented in another protected store. `CompileFailSpec` pins that raw receipt bytes have no recovery edge and
that broker indices are nominal.

On 2026-08-22, all eight focused `ResourceRecordSpec` cases passed, including mixed owned/released
rehydration and wrong-store refusal. Three focused public compile-fail cases proved the rehydrated set is
unforgeable, raw ownership receipts cannot become rehydrated receipts, and broker indices are nominal.
`cabal test all --ghc-options=-Werror` passed all 2,334 tests on linux-cpu, including governed documentation
validation.

The sprint closes when `ResourceRecordSpec` also carries: a stale-member case that verifies the set, then
compare-and-swaps one member's record (owned → released bytes) in the same store, then calls
`withRehydratedResourceSet` and asserts `SessionRecordCorrupt` naming the changed member; a deleted-member
case asserting the same refusal; and an all-or-nothing case asserting that one stale member yields no
handle, receipt, or tombstone for any other member. The mixed owned/released case ("the complete set rehydrates
owned and released members under its broker") does not stop at counting: it passes each owned handle and receipt from
`foldRehydratedResourceSet` to `recordRecoveredResourceReleased` and asserts the provider record then reads back
as its canonical released bytes while the released cluster record's bytes are unchanged, so swapping the owned
and released branches fails it. `cabal test all` from `core/` passes.

#### Remaining Work

- Make `withRehydratedResourceSet` (`Session.hs`) re-read every member key of the `VerifiedResourceRecordSet`
  in the supplied session and refuse with `SessionRecordCorrupt` when any member's stored bytes differ from the
  verified bytes or the record is missing; `rehydrateResourceRecordSetKernel`'s `reverify`, which re-parses the
  member's own in-memory bytes and cannot fail, is replaced by that comparison.
- Copy the set's plan digest into `RehydratedResourceHandle` in `foldRehydratedResourceSetKernel` and drop the
  `plan :: Text` parameter of `recoveredOwnedReleaseTransitionKernel` (`ResourceRecord.hs`) and of
  `recordRecoveredResourceReleased` (`Mode.hs`); the key and released bytes derive from the handle's digest.
- Delete the unused `withVerifiedResourceRecordSetKernel`, `rehydratedHandleResourceKernel`, and
  `rehydratedTombstoneResourceKernel` exports from `ResourceRecord.hs`.
- Rewrite the `ResourceRecord.hs` module header, which says `HostBootstrap.Reconcile` is the only module that
  mints an ownership receipt, to name the second path: `foldRehydratedResourceSetKernel` mints
  `RehydratedOwnershipReceipt` from a complete verified set, reached through `Session.foldRehydratedResourceSet`
  and consumed by `Mode.recordRecoveredResourceReleased`.
- Add the stale-member, deleted-member, all-or-nothing, and owned/released identity assertions named in
  Validation.

### Sprint 18.8: Scope-correct prospective migration [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Build and persist the prospective revision from the scope-correct config and non-empty plan draft before the
old revision freezes.

#### Deliverables

- `withProspectiveMigrationPlan` consumes the exact migration profile and old-bound package together with the
  scope-correct codec, verified config wire, validated config, and non-empty draft.
- The bracket creates one local candidate plan, digest binding, and non-authorizing
  `ProspectivePlanSnapshot`, then fsyncs and authoritatively reads back their exact canonical bytes and binding.
- Same-plan, empty-draft, read-back, or config/draft mismatch refuses before freeze; a pre-freeze crash leaves
  only the stable, unreferenced candidate record.

#### Validation

`AuthoritySpec` covers the scope-correct success path, byte-identical read-back, every mismatch, same-plan and
empty-draft refusal, and a crash after candidate persistence with the old revision still active.

On 2026-08-22, all 12 focused plan-migration authority cases passed, including scope-correct canonical
construction, same-plan refusal, exact authoritative read-back, conflicting persisted bytes, config/draft
mismatch, and the pre-freeze active-revision invariant. Two focused public compile-fail cases proved that an
empty draft list and cross-config wire/config evidence cannot enter the bracket. `cabal test all
--ghc-options=-Werror` passed all 2,339 tests on linux-cpu, including governed documentation validation.

The sprint closes when: "a migration onto the exact same canonical plan is refused before freeze" unwraps both
result layers (`either (assertFailure . show) (either (assertFailure . show) pure) opened`), builds the candidate
at the old plan's exact root and config so its digest equals the old digest, asserts the
`ModeSnapshotMismatch` payload fields both equal the old plan digest, and asserts no `prospective.` record
exists afterwards; "a candidate is persisted, read back, and authorizes nothing" asserts after the continuation
that the lease record still holds the old `LeaseBound` values, the recorded revision kind is `NormalRevision`,
and exactly one `prospective.` record exists holding the candidate's canonical bytes; and the config/draft
mismatch case asserts the exact draft/config mismatch reason inside `ModeInvalidIdentity` and that no
`prospective.` key exists after the refusal; and `cabal test all` from `core/` passes.

#### Remaining Work

- Rewrite the same-plan, candidate-persistence, and config/draft mismatch cases in `AuthoritySpec`'s
  `migrationCases` as named in Validation. The same-plan case discards its inner `Either` and builds its
  candidate at a different root, so it cannot reach the same-plan refusal.

### Sprint 18.9: Configful completed-plan reconstruction [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Rebuild configful forward state only when the supplied config and draft render the exact persisted candidate.

#### Deliverables

- `withCompletedMigrationPlan` loads the prospective snapshot named by the completed migration's stable key;
  no caller supplies candidate bytes or chooses either digest.
- The bracket consumes the exact new-bound recovery profile, scope-correct codec and config, and non-empty
  draft, yielding migration-local plan/binding authority only after exact canonical equality.
- Every metadata or byte mismatch, missing/malformed/unknown candidate, and authority substitution refuses while
  retaining the committed lease and mode.

#### Validation

`AuthoritySpec` ("completed-plan reconstruction refuses changed inputs and missing candidate state") covers
exact reconstruction and changed config, changed draft (`ModeInvalidIdentity`), a candidate overwritten with
arbitrary bytes (`ModeMalformedRecord`), and a deleted candidate (`ModeSnapshotMissing`), with the committed
lease retained.

On 2026-08-22, the focused migration group passed, including exact configful reconstruction, changed
config/draft refusal, malformed and missing candidate refusal, and retention of the committed lease. The
public constructor-forging boundary for the completed recovery profile also passed. `cabal test all
--ghc-options=-Werror` passed all 2,341 tests on linux-cpu, including governed documentation validation.

The sprint closes when `AuthoritySpec` also carries three `withCompletedMigrationPlan` refusal cases, each
asserting that the committed lease is unchanged: drafts built under a different implementation revision →
`ModeInvalidIdentity`; a `CompletedMigrationRecoveryProfile` opened for a different completed migration, so its stable
key differs from the barrier's → `ModeSnapshotMismatch`; and a well-formed candidate record carrying an unknown format version →
`ModeMalformedRecord`. The changed-config sub-case of "completed-plan reconstruction refuses changed inputs and
missing candidate state" rebuilds its drafts from the changed config (so draft/config admission passes and the
completed-migration config guard is the one exercised) and pins its `ModeSnapshotMismatch` payload instead of
accepting any `Left`. `withCompletedMigrationProjectPlanKernel` quantifies `planId` in a rank-2 continuation, as
`withChildProjectPlanKernel` does, and its Haddock says the `planDigest` index is the caller's persisted digest.
`cabal test all` from `core/` passes.

#### Remaining Work

- Add the wrong-implementation-revision, wrong-stable-key, and unknown-candidate-version cases named in
  Validation to `AuthoritySpec`'s `migrationCases`, and rebuild the changed-config sub-case's drafts from the
  changed config with an exact `ModeSnapshotMismatch` match.
- Make the continuation of `withCompletedMigrationProjectPlanKernel` (`Plan.hs`) `forall planId.` so no caller
  chooses the plan identity, keep `planDigest` outer, and document that in its Haddock.

### Sprint 18.10: Complete-set migration freeze [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Freeze the old revision only while holding its exact session, operation, preparation, and resource sets.

#### Deliverables

- `withPlanMigration` derives the complete old `VerifiedResourceRecordSet` internally and records its digest
  with the same stable migration key that freezes the lease and revokes session admission.
- Session opening and freeze contend on the same revision version; freeze settles only after every independently
  enumerated session is Closed and every prepared operation is drained or authoritatively fenced.
- The exact-set fold verifies each owned or released member once and the frozen lease (`LeaseFrozen`) pins
  the resulting set digest, which commit and frozen recovery recompute and compare; no per-member staging
  record is written. Incomplete/inconsistent sets retain the old revision, while retry converges only for the
  same stable key, candidate, and set digest.
- Before it settles the old revision or writes the revision kind, `withPlanMigration` validates the lease (bound
  to the profile's old digests at the profile's epoch, or already frozen under the same key, set digest, and
  epoch) and checks the candidate's key equals `stableMigrationKeyFor profile (prospectiveSnapshotPlanDigest
  candidate)`; a refused freeze leaves the revision kind, sessions, and permits untouched.

#### Validation

`AuthoritySpec` and `SessionSpec` cover session/freeze races, prepared-operation drainage, every exact-set
refusal, retry convergence, and kills before and after the atomic freeze.

On 2026-08-22, the focused migration group passed all 20 cases. The migration fixture now uses a canonical
old plan and its exact protected resource record; freeze derives membership from the snapshot retained by the
sole profile producer, runs the established fence/manifest/interpreter/Closed-session chain, and persists the
64-character SHA-256 set digest in the frozen lease. Exact stable-key/set retry converged. The existing
`ResourceRecordSpec` and `SessionSpec` exact-set, independently enumerated session, prepared-operation fence,
and crash-retry cases passed as part of the full gate. `cabal test all --ghc-options=-Werror` passed all 2,341
tests on linux-cpu, including governed documentation validation.

The sprint closes when `AuthoritySpec`'s migration group carries: "freezing stops the old revision from being
bindable" extended to present the old revision to `bindRunLease` (or the bound-lease admission) after the freeze
and assert `ModeLeaseNotBindable _ "frozen"`, and to read the lease record and assert its exact `LeaseFrozen`
fields; a second-candidate case that freezes under key A, then runs `withPlanMigration` with candidate B and
asserts the refusal leaves the recorded kind `IncompleteMigration` naming A and settles no session of the old
revision; a cross-profile case pairing a candidate minted under one profile with another
Production profile of the same project and asserting `ModeSnapshotMismatch` before any write; and an
epoch-mismatch case whose lease epoch differs from `migrationProfileEpoch profile`, asserting the freeze refuses
in both the `LeaseBound` and the idempotent `LeaseFrozen` branch; and `cabal test all` from `core/` passes.

#### Remaining Work

- Reorder `withPlanMigration` (`Mode.hs`): read and validate the lease (the `freezeLease` checks) before
  `settleRevision` and `recordOpenRevisionMigrationForKey` run, and refuse there. The revision kind is written
  with a blind compare-and-swap before `freezeLease` validates, so a refused freeze leaves a kind naming another
  key and the old sessions already fenced and closed.
- Compare `prospectiveSnapshotKey candidate` with `stableMigrationKeyFor profile (prospectiveSnapshotPlanDigest
  candidate)` in `withPlanMigration` and refuse with `ModeSnapshotMismatch` on a difference; the key is taken
  from the candidate unchecked, contrary to the Haddock.
- In both the `LeaseBound` and `LeaseFrozen` branches of `freezeLease`, require the recorded lease epoch to equal
  `migrationProfileEpoch profile`.
- Add the settle step to `withPlanMigration`'s ordered-step Haddock and correct `settleRevision`'s Haddock,
  which says it is used only at activation.
- Add the four cases named in Validation.

### Sprint 18.11: Frozen migration recovery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Resume or cancel the exact frozen old-active migration named by a `FrozenMigrationRunLease`, rereading every
durable record before acting on it. `withPlanMigration` is the only producer of that capability, so these
functions serve the invocation that froze the lease; the durable-state opener that mints the capability for a
later invocation after a pre-commit process death is Sprint 18.21's.

#### Deliverables

- `withRecoveredMigrationPlanSnapshot` is reachable only from `IncompleteMigration` with the matching frozen
  lease; it loads the prospective snapshot and resource-set digest named by the durable stable key.
- A fresh rank-2 migration identity rebuilds only byte-identical supplied config/drafts. Typed down/destroy
  cancellation (`cancelIncompletePlanMigrationForTeardown`) refuses `ProjectUp`, requires the recorded revision
  kind to be `IncompleteMigration` with the frozen stable key (or `NormalRevision` beside the exact restored
  old-bound lease on retry), compare-and-swaps the frozen lease back to the old-bound lease, and records
  `NormalRevision`; the stable-keyed candidate record stays behind as a non-authorizing, unreferenced record.
- Both readers report a revision kind the same way: `IncompleteMigration` naming another key refuses with
  `ModeSnapshotMismatch <frozen key> <recorded key>`; `NormalRevision` beside a still-frozen lease and
  `CompletedMigration` refuse with `ModeWrongRecoveryScope "incomplete-migration" <openRevisionKindName kind>`.
- Epoch agreement is a type-level fact: the recovery epoch and the frozen lease share the `brokerGeneration`
  index, and every `BrokerEpoch` at one index carries one word, so cancellation's term-level
  `ModeEpochMismatch` comparison is defence in depth that no public caller can reach.
- Missing, changed, or unknown candidate/set state retains the freeze; neither recovery branch opens a session,
  issues preparation authority, or creates a second candidate.

#### Validation

`AuthoritySpec` covers post-freeze configful resume through `withRecoveredMigrationPlanSnapshot` (success
path only) and down/destroy cancellation with retry convergence ("down cancellation restores only the
old-bound lineage and converges").

On 2026-08-22, the focused migration group passed. Frozen reconstruction rereads and matches the incomplete
revision kind, full frozen lease tuple, stable-keyed prospective bytes, canonical old snapshot, and recomputed
exact-set digest before the rank-2 configful plan continuation; it exposes no session/preparation authority.
Typed down/destroy cancellation restored only the old bound digest and converged across both verbs.
`cabal test all --ghc-options=-Werror` passed all 2,342 tests on linux-cpu, including governed documentation
validation.

Every case below starts from the real `withPlanMigration` bracket and uses the `FrozenMigrationRunLease` it
returns. A test changes the revision kind by locating the run's `migration.<project>.<run>` record through
`listProtectedRecords` and compare-and-swapping well-formed bytes into it (`normal`, `incomplete<TAB><key>`,
`completed<TAB><key>`), and replaces the lease by compare-and-swapping `bound<TAB><epoch><TAB><old spec
digest><TAB><candidate plan digest>` into the lease record: a `LeaseBound` that is neither the frozen tuple nor
the restored old-bound lease.

The sprint closes when `AuthoritySpec`'s `migrationCases` carries these `withRecoveredMigrationPlanSnapshot`
refusal cases, each asserting the exact constructor and that the lease record's version and bytes are
unchanged:

- changed config wire → `ModeSnapshotMismatch <persisted config digest> <wire config digest>`;
- candidate record overwritten with undecodable bytes → `ModeMalformedRecord <prospective record key>`;
- candidate record overwritten with the well-formed prospective bytes a second `withProspectiveMigrationPlan`
  call with a changed config persists under its own key →
  `ModeSnapshotMismatch "recovered migration candidate" "changed prospective snapshot"`;
- the single resource bundle re-rendered with a different generation through `renderResourceRecordBundle` →
  `ModeSnapshotMismatch <frozen set digest> <recomputed set digest>`;
- recorded revision kind `NormalRevision`, and separately `CompletedMigration <frozen key>` →
  `ModeWrongRecoveryScope "incomplete-migration" <kind name>`;
- recorded `IncompleteMigration` naming another key → `ModeSnapshotMismatch <frozen key> <recorded key>`;
- lease replaced as above → `ModeSnapshotMismatch "frozen migration lease" "different durable lease"`.

It also carries these `cancelIncompletePlanMigrationForTeardown` refusal cases, each asserting the exact
constructor and that the lease record's version and bytes and the revision-kind record are unchanged:
`ProjectUp` → `ModeWrongRecoveryScope "down-or-destroy" "up"`; a session on another protected store →
`ModeSnapshotMismatch "frozen migration store" "different protected store"`; the lease replaced as above →
`ModeSnapshotMismatch "frozen migration lease" "different durable lease"`; `NormalRevision` over the still-frozen
lease, and separately `CompletedMigration <frozen key>` → `ModeWrongRecoveryScope "incomplete-migration" <kind
name>`; and `IncompleteMigration` naming another key → `ModeSnapshotMismatch <frozen key> <recorded key>`. No
case targets the recovery-epoch comparison, which the shared `brokerGeneration` index makes unreachable.
`cabal test all` from `core/` passes.

#### Remaining Work

- Make `cancelIncompletePlanMigrationForTeardown` read the recorded revision kind before its lease
  compare-and-swap: `IncompleteMigration` naming the frozen stable key proceeds; `IncompleteMigration` naming
  another key refuses with `ModeSnapshotMismatch <frozen key> <recorded key>`; `NormalRevision` proceeds only
  beside the exact restored old-bound lease (the retry case), and otherwise, like `CompletedMigration`, refuses
  with `ModeWrongRecoveryScope "incomplete-migration" (openRevisionKindName kind)`.
- Match `ProjectUp`, `ProjectDown`, and `ProjectDestroy` explicitly in `cancelIncompletePlanMigrationForTeardown`'s
  verb guard instead of the `_ -> False` wildcard, so a new verb is a compile-time decision.
- Add the six cancellation refusal cases named in Validation.
- Add the eight `withRecoveredMigrationPlanSnapshot` refusal cases named in Validation to `AuthoritySpec`'s
  `migrationCases`.

### Sprint 18.12: Complete-set migration commit [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Switch revision lineage only by consuming the frozen lease and the exact staged resource set together.

#### Deliverables

- `commitMigrationActivation` consumes the frozen lease, stable-keyed candidate proof, and exact staged set;
  none can be selected independently.
- One protected transaction swaps the frozen lease to the strict `migrated-bound` lease (`LeaseMigrated`,
  carrying the stable key, set digest, and both old/new spec-plan pairs) and records `CompletedMigration` under
  the same stable key, yielding the new-bound lease and the `PlanMigrationBarrier`. The old resource records
  stay in place under the superseded plan digest with their owned/released dispositions; nothing is archived.
- Either crash side classifies wholly as incomplete-old-active (`LeaseFrozen` + `IncompleteMigration`) or
  completed-new-bound (`LeaseMigrated` + `CompletedMigration`); no third durable state exists, retry converges,
  and old and new preparation authority never coexist.

#### Validation

`AuthoritySpec` covers the lineage switch, a candidate changed after freeze and a resource record changed
after freeze (each `ModeMalformedRecord`, old lineage retained), and idempotent re-commit.

On 2026-08-22, the focused migration group passed all 23 cases, including post-freeze candidate and exact-set
corruption refusal, stable barrier/set-digest equality, the pre-CAS frozen side, and idempotent post-CAS repair.
The commit CAS now writes a strict `migrated-bound` lease frame containing the stable key, set digest, and both
old/new spec-plan pairs; completed recovery recomputes and compares the exact set before yielding its barrier.
Owned/released dispositions remain in their unchanged canonical resource records. `cabal test all
--ghc-options=-Werror` passed all 2,344 tests on linux-cpu, including governed documentation validation.

The sprint closes when `AuthoritySpec` carries a crash-between-writes case: it writes `LeaseMigrated` for the
frozen run while leaving `IncompleteMigration` recorded (the state a death between `commitMigrationActivation`'s
lease write and its revision write leaves), then asserts that the incomplete-migration readers
(`withRecoveredMigrationPlanSnapshot`, `cancelIncompletePlanMigrationForTeardown`) and
`withCompletedMigrationRecovery` all classify it as the completed side and converge to `CompletedMigration`
with one barrier — or, if the two writes are made one transaction, that the intermediate state cannot be
produced by injecting a failure after the lease write. The post-freeze refusal cases write well-formed
changes rather than undecodable bytes: a prospective encoding of a different plan under the same stable key, and
one resource bundle re-rendered with a different generation through `renderResourceRecordBundle`, each
asserting the exact `ModeSnapshotMismatch` payload and that the lease record still holds the exact
`LeaseFrozen` values. "activation is idempotent, so a crash after the swap converges" captures the
`IncompleteMigration` record before the first commit, compare-and-swaps it back after the commit, re-runs
`commitMigrationActivation`, and asserts the kind is `CompletedMigration` and the lease bytes are unchanged.
A stale-lease case presents the old-bound lease (the one `withProjectUpMigrationProfile` consumed) to
`withCompletedMigrationRecovery` after the commit and asserts `ModeSnapshotMismatch` before the continuation
runs, as does a lease whose epoch differs from the durable lease's. `cabal test all` from `core/` passes.

#### Remaining Work

- Make `commitMigrationActivation` commit the `LeaseMigrated` lease and the `CompletedMigration` revision kind
  as one protected multi-record transaction (the lifecycle redo coordinator the Production close uses), or teach
  every incomplete-migration reader to recognise `LeaseMigrated` with the matching stable key and set digest as
  the completed side and finish the `CompletedMigration` record. The lease CAS and the revision write are two
  separate writes, and the readers refuse `LeaseMigrated` + `IncompleteMigration`.
- Add the crash-between-writes case named in Validation.
- Make `withCompletedMigrationRecovery` (`Mode.hs`) require `(boundRunLeaseSpecDigest bound,
  boundRunLeasePlanDigest bound) == (recordedSpec, recordedPlan)` and the bound lease's epoch to equal the
  durable lease's epoch before calling its continuation, refusing with `ModeSnapshotMismatch`; it types the
  yielded `VerifiedPlanSnapshot` and `PlanMigrationBarrier` by the caller's lease indices while their contents
  come from the durable lease.
- Rewrite the two "changed after freeze" commit cases with well-formed changes and the post-swap crash case
  with the restored `IncompleteMigration` record, and add the stale-lease case, all named in Validation.
- Rewrite the `commitMigrationActivation` Haddock so it describes the commit the code performs, and the
  `PlanMigrationBarrier` Haddock so it names both producers (`commitMigrationActivation` and
  `withCompletedMigrationRecovery`) instead of claiming a sole producer.

### Sprint 18.13: Complete-set migrated activation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Admit the new revision only from its local plan binding and the complete set carried across the barrier.

#### Deliverables

- `activateMigratedPlan` consumes the exact barrier, new-bound lease and active revision, local plan and
  persisted binding, and complete rehydrated set before exposing journal or preparation authority.
- It settles the old revision first (`settleRevision` over the old plan digest: fence old permits, verify the
  session manifest, interpret recorded sessions, and drive every old session to Closed, discarding that
  admission) before minting the new revision's `CurrentBrokerSessionAdmission`; no commit-to-activation kill
  can issue a prepared operation.
- Configful and configless completion share one kernel (`activateMigratedPlanConfigless`) and the same set
  digest and postcondition; a rehydrated set whose digest is not the barrier's set digest refuses with
  `ModeSnapshotMismatch` before a session opens.
- Lineage, plan, binding, and epoch agreement are type-level facts. The barrier, the new-bound lease, and the
  binding share the generative `newPlanDigest` index (`commitMigrationActivation` returns the lease and barrier
  together, and `withCompletedMigrationRecovery` reads the barrier from the presented lease's own run), the plan
  and binding share `newPlanId`, every producer of a value at a named index checks its digest text, and the
  lease and epoch share `brokerGeneration`. The kernel's term-level plan-digest and epoch comparisons and
  `activateMigratedPlan`'s plan and binding comparisons are defence in depth, and no runtime run-key comparison
  is added. A barrier from one migration presented with another migration's lease is a compile error.

#### Validation

`AuthoritySpec` covers configful activation from the commit ("activating the plan admits the new revision's
broker") and from completed recovery ("completed-migration recovery loads the candidate from the durable key"),
both success paths. `SessionSpec` covers fence rotation and stale-permit refusal for `withPreparedGate` in
isolation; no case drives them through activation.

On 2026-08-22, the focused migration group passed all 23 cases. Configful activation now requires the exact
candidate `ProjectPlan`, same-index digest binding, migrated-bound lease/barrier, broker epoch, and complete
broker-rehydrated old set. Completed configless recovery yields that same set from its protected exact-set read
and enters the shared activation kernel. The kernel checks lease plan digest, broker epoch, and set digest
before the established old-session/prepared-permit settlement and new-session admission chain. The focused
ordinary-admission source guard passed after being narrowed to the shared kernel. `cabal test all
--ghc-options=-Werror` passed all 2,344 tests on linux-cpu, including `SessionSpec` race/fence coverage and
governed documentation validation.

The sprint closes when these cases exist and pass, and `cabal test all` from `core/` passes:

- `CompileFailSpec` registers `CrossMigrationBarrierActivation.hs`, a fixture whose function takes a
  `PlanMigrationBarrier projectId oldPlanDigest firstNewPlanDigest` and a `BoundRunLease scope newSpecDigest
  secondNewPlanDigest brokerGeneration` as parameters and passes both to `activateMigratedPlanConfigless`; it is
  registered with the "Couldn't match type" phrase naming the two digest variables, copied from actual stderr.
- `AuthoritySpec` set-digest refusal, for `activateMigratedPlanConfigless` and, separately, `activateMigratedPlan`
  with the candidate plan and binding: after `commitMigrationActivation`, the single old resource bundle is
  re-rendered with a different generation through `renderResourceRecordBundle`, the old set is verified with
  `withVerifiedResourceRecordSet` (from the old `VerifiedPlanSnapshot` and `BoundPlanSnapshot`, which
  `withMigrationProfile` passes to its callback) and rehydrated with `withRehydratedResourceSet` under the
  migration epoch, and that set is presented with the commit's barrier and new-bound lease; activation refuses
  with `ModeSnapshotMismatch <barrier set digest> <presented set digest>` and no old-revision session settles.
- `AuthoritySpec` old-session settlement: before `withPlanMigration`, the test opens an old-revision session
  under the old plan digest (`openProjectJournal`, `openOperationSession`), establishes its fence
  (`establishInitialFence`), and registers one operation intent (`registerOperationIntent`), retaining the
  fence token and the post-intent permit; after `commitMigrationActivation` and `activateMigratedPlan`, that
  session reads Closed, and `withPreparedGate` with the retained token and permit refuses with
  `SessionFenceSuperseded`, so no old-revision operation can prepare once the new admission exists.
- The commit-to-activation kill is the `migration-committed` boundary of Sprint 18.19, whose successor converges
  through `withCompletedMigrationRecovery` and `activateMigratedPlanConfigless` and asserts old-permit refusal.

#### Remaining Work

- Add `CrossMigrationBarrierActivation.hs` under `test/compile-fail` and register it in `CompileFailSpec` as named
  in Validation.
- Extend `withMigrationProfile` (`AuthoritySpec`) to pass the old `VerifiedPlanSnapshot` and `BoundPlanSnapshot`
  it already holds, then add the two set-digest refusal cases and the old-session settlement case named in
  Validation to `AuthoritySpec`'s `migrationCases`.

### Sprint 18.14: Snapshot-derived recovery frames [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Recovery.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/RecoverySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Recover executable teardown frames from the bound non-secret snapshot and complete resource set without
reconstructing normal child config.

#### Deliverables

- Opaque `RecoveredProjectFrame` binds one decoded frame, its parent edge, teardown projection, plan digest,
  and exact `RehydratedResourceSet` membership.
- Completed configless recovery loads the exact prospective snapshot named by its stable key together with the
  superseded verified snapshot and supplies both, plus the superseded complete set, to
  `withMigratedRecoveredProjectFrames`, which admits candidate frames only when both snapshots carry identical
  resource membership; it never stops at parsed digest text.
- `withRecoveredProjectFrames` accepts only the bound verified snapshot and the complete rehydrated set of the
  same plan, and admits adapters through a core-fixed closed table (`preserve`, `core-managed`,
  `project-managed`, `step-declared`, each at revision 1); old config is never read and unknown versions
  refuse.
- Each frame's parent edge is read from the snapshot's recorded descents, not inferred from step order, so
  sibling frames under one parent recover with the correct parent; each owned resource carries the reverse
  adapter of the step whose operation acquired it, not the adapter of its frame's first step.
- Resource eliminators expose only the owned handle/receipt or released tombstone at the forest's exact point;
  raw bytes, frame text, receipts, and adapter names cannot construct the frame.

#### Validation

`RecoverySpec` covers root and nested frames over a linear host→vm plan, released-tombstone elimination, and an
unknown adapter revision through `withRecoveredProjectFrames` (accepting any `Left`). `CompileFailSpec` pins
the hidden frame constructor. `AuthoritySpec` ("completed-migration recovery loads the candidate from the
durable key") drives `withMigratedRecoveredProjectFrames` on the success path.

The sprint closes when `RecoverySpec` carries: a foreign-plan case pairing a snapshot from one fixture plan with
a rehydrated set from another (indices coerced as `SessionSpec`'s drift cases do) asserting
`ModeMalformedRecord` containing "belongs to another plan"; a migrated-frames case over two canonical snapshots
with different resource members asserting "different resource membership"; the unknown-adapter case tightened
to `ModeMalformedRecord` containing "closed table"; a sibling-frame case (host with
two child frames) asserting both children's parent is `host`; and a mixed-adapter frame case (a `preserve`
step and a `core-managed` step in one frame) asserting each resource is labelled with its own step's adapter;
and a corrupted-frame case that flips one field the `decodeRecoveryFrame` walk reads (the reverse-adapter kind
or its revision) inside an encoded step, recomputes the plan digest, and asserts `withRecoveredProjectFrames`
refuses with `ModeMalformedRecord`.
The pure "recovery is independent of config presence and contents" case is replaced by the `HarnessSpec` case
named in Remaining Work. `cabal test all` from `core/` passes.

On 2026-08-22, `RecoverySpec` passed all 8 selected cases and the focused migration group passed all 23
cases. Strict canonical decoding now reconstructs the linear root/nested frame topology and reverse-adapter
revision from the verified snapshot. `RecoveredProjectFrame` is nominal and constructor-hidden, retains the
complete broker-rehydrated set, and its fold exposes only an owned handle with its receipt or a released
tombstone at that frame. Completed migration recovery loads both the stable-keyed prospective snapshot and
the superseded verified snapshot; candidate frames are admitted over the superseded set only when their
canonical resource coordinates are identical. The configless harness path performs this frame reconstruction
before migrated activation. Config-present/edited/absent, foreign membership, released disposition, unknown
adapter revision, and constructor-forging cases refuse or eliminate as required. `cabal test all
--ghc-options=-Werror` passed all 2,351 tests on linux-cpu, including governed documentation validation.

#### Remaining Work

- Key the recovery adapter by step operation, not by frame: `canonicalPlanRecoveryFramesKernel` (`Plan.hs`)
  returns each step's `operation` text with its (frame, adapter kind, revision) row, and the three
  `Recovery.hs` entry points (`withRecoveredProjectFramesKernel`, `withMigratedRecoveredProjectFramesKernel`,
  `driveRecoveredForestKernel`) select the adapter for each owned handle by the handle's ownership operation
  key. The `first : _ -> first` collapse and its `("preserve", 1)` default are deleted; a handle whose
  operation has no row refuses.
- Derive each frame's parent from the snapshot's recorded `descents` (lift-layer chains) instead of "the
  previous distinct frame name", refusing a frame whose steps disagree about its parent.
- Fold the three copies of `admitAdapter`/`adapterOf`/`parentOf` in `Recovery.hs` into one shared helper, and
  reword the refusal text, which names a "project-owned" table that is a core-fixed list.
- Add the foreign-plan, different-membership, tightened unknown-adapter, sibling-frame, mixed-adapter, and
  corrupted-frame cases named in Validation to `RecoverySpec`.
- Delete the pure "recovery is independent of config presence and contents" `RecoverySpec` case (it writes a
  config no code reads) and add a `HarnessSpec` case that abandons a bound run holding an owned resource,
  deletes and then corrupts the fixture project's config file before the successor, and asserts the successor
  run through `protectedProjectRunOwnershipWithRecovery` converges with the same release events.

### Sprint 18.15: Recovery-wire boundary admission [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Recovery.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/test/RecoverySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Use the authenticated-handoff phase's recovery wire as the sole nested entry from a recovered parent frame.

#### Deliverables

- The root builds `RecoveryProjectionBindingInput` from the bound snapshot's plan and exact edge through
  `withRecoveredChildProjectionBinding`, encodes the recovered set digest, child frame, adapter kind, and
  revision in the `hostbootstrap/recovered-frame-adapter` wire bytes, and alone calls
  `mkRecoveryProjectionBinding`.
- The child-side receiver (`Handoff/Receiver.hs`) decodes and verifies that recovered-frame adapter wire with
  `withVerifiedRecoveryWire` and its grant, rather than an adapter taken from a child config package;
  `withVerifiedRecoveryHandoff` joins the binding to the typed down/destroy handoff, which the descent entry
  consumes with the forest authorization point. Immediate parents receive no signing key.
- Replay or any plan/edge/frame/digest/payload/verb/phase mismatch refuses before dispatch; the boundary has no
  config handoff and no route to `ProjectUp`.

#### Validation

`RecoverySpec` builds a binding from two recovered frames, checks only that the wire and rendered binding are
non-empty, and refuses a reversed edge. `HandoffSpec` covers the generic recovery-wire refusals (wrong keys,
stores, broker generations, plans, edges, payloads, phases, verbs, replay) over wires that are not
recovered-frame bindings. `CompileFailSpec` pins that config handoff and recovery handoff are not
interchangeable.

The sprint closes when `RecoverySpec` carries: an exact-wire case that rebuilds the expected
`hostbootstrap/recovered-frame-adapter` bytes from the snapshot's set digest, the child frame name, and its
adapter and compares them byte-for-byte, and decodes the rendered binding asserting its plan digest, parent
frame `host`, child frame `vm`, and wire digest; a different-complete-set case asserting
`HandoffBindingMismatch` "the recovered frames do not retain the same complete resource set"; and a round-trip
case that passes the recovered binding and wire through `withVerifiedRecoveryWire` and the receiver, then
refuses a replay and a substituted plan, set digest, and child frame. `HandoffSpec` or `RecursiveLifecycleSpec`
carries one case that crosses a real process boundary with a recovered-frame wire. `cabal test all` from
`core/` passes.

On 2026-08-22, the focused recovery selection passed all 93 cases and `RecoverySpec` passed its 9 cases.
The root-only recovered-edge constructor now checks the exact parent relation and shared complete set, then
canonically frames the set digest, child frame, adapter kind, and revision before calling
`mkRecoveryProjectionBinding` with the root broker. The established authenticated recovery receiver verifies
that wire and its independently signed grant, joins it only to a teardown-phase Down/Destroy handoff, and
refuses wrong keys, stores, broker generations, plans, edges, payloads, phases, verbs, and replay. Existing
compile-fail fixtures keep config grants and recovery grants non-interchangeable. `cabal test all
--ghc-options=-Werror` passed all 2,352 tests on linux-cpu, including governed documentation validation.

#### Remaining Work

- Make the recovery receiver path in `Handoff/Receiver.hs` accept the `hostbootstrap/recovered-frame-adapter`
  wire produced by `withRecoveredChildProjectionBinding`: decode its set digest, child frame, adapter kind, and
  revision, check them against the authenticated binding, and verify it through `withVerifiedRecoveryWire`.
  The receiver verifies only an adapter taken from a child config package, so the recovered-frame wire has a
  producer and no consumer.
- Add the exact-wire, different-complete-set, and verified round-trip/replay/substitution cases named in
  Validation to `RecoverySpec`, and the real-process recovered-frame case to `HandoffSpec` or
  `RecursiveLifecycleSpec`.

### Sprint 18.16: Child-first abandoned-run teardown [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Recovery.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Resolve a bound abandoned run that acquired resources by driving its recovered forest to terminal closure.

#### Deliverables

- The acquired-resource branch of `withAbandonedHarnessRun` opens the recovered frame-indexed forest from the
  bound snapshot and complete rehydrated set.
- The driver consumes one verified recovery handoff for each foreign cursor and settles every child before its
  parent, using exact recovered resources and no backend call for a released member.
- The production `test run` command path (`Command.hs` → `protectedProjectRunOwnership`) installs a real
  `RecoveredResourceExecutor` that dispatches each owned resource of a foreign frame through
  `withRecoveredChildProjectionBinding` and the authenticated recovery handoff (Sprint 18.15), and each
  resource of the root frame through the root's own reverse adapter; after each successful release
  `recordRecoveredResourceReleased` compare-and-swaps the owned record to its released bytes.
- Only settled destroy plus all sessions Closed authorizes harness closure and reclamation; every unresolved
  outcome retains the lease, mode, snapshot, and records, and the sweep reports the recovery failure that
  actually occurred (store, session, snapshot, closure, authorize, or finalize), not the pre-teardown ownership
  refusal.
- The recovered-resource executor seam is not part of the public library: no consumer can install an executor
  that reports a release the backend did not perform.

#### Validation

`RecoverySpec` covers multi-frame (host→vm) child-before-parent order through `driveRecoveredForest` with an
injected callback, released tombstones without a backend call, a backend refusal that stops before the parent
(accepting any `Left`), and a release callback that calls `recordRecoveredResourceReleased` twice (asserting
only that both calls return `Right`). `HarnessSpec` covers a single-frame (`host`) abandoned owned resource
released and closed, a failed release retained for exact retry, and a released tombstone closing without a
backend call — all through `protectedProjectRunOwnershipWithRecovery` with a test executor; the production
`protectedProjectRunOwnership` installs `refusingRecoveredResourceExecutor`.

The sprint closes when: `HarnessSpec` drives an abandoned bound run holding owned resources in two frames
(host→vm) through the production `protectedProjectRunOwnership` bracket and asserts the successor is admitted,
the vm resource is released before the host resource, both resource records read back as released, and the
lease is closed; `RecoverySpec`'s recorded-release case reads each resource key back from the protected store
after `driveRecoveredForest` returns and asserts its bytes equal the canonical released bytes, and also reads
the record between the two `recordRecoveredResourceReleased` calls and asserts it already holds the released
bytes, so idempotent retry is distinguished from a no-op; the backend-refusal case matches
`Left (ModeOwnershipUnresolved _ reason)` with `reason == "seeded child refusal"`; a `driveRecoveredForest` case over a foreign-plan rehydrated set asserts
`ModeOwnershipUnresolved` containing "belongs to another plan" with zero callback invocations; a
`driveRecoveredForest` case over `unknownAdapterPlan` asserts `ModeOwnershipUnresolved` containing "closed
table" with zero callback invocations; `RecoverySpec` carries two `recordRecoveredResourceReleased` refusal
cases inside the `driveRecoveredForest` callback — the member's record compare-and-swapped to different
canonical bytes (a higher generation) first, asserting `ModeSnapshotMismatch "owned recovery resource record" _`
with the record unchanged, and the record deleted first, asserting `ModeSnapshotMissing`; `HarnessSpec`
carries a case whose test executor releases the run's only resource and then rewrites the abandoned run's lease
record to different well-formed bytes, so the forest settles and `authorizeHarnessClose` refuses, asserting the
sweep returns that refusal rather than `ModeOwnershipUnresolved`; and `cabal test all` from `core/` passes.

On 2026-08-22, `RecoverySpec` passed all 13 cases, the abandoned-run selection passed all 33 cases, and the
focused recovered selection passed all 38 cases. The abandoned bound branch now rehydrates the snapshot's
complete resource set at the reopened broker, drives its frames child-first through the installed closed
recovery executor, skips backend dispatch for released tombstones, and CASes each successful owned release to
its canonical released record. Failure leaves the lease, mode, snapshot, and records recoverable; an exact
retry converges. Only the opaque complete-forest result plus an independently enumerated
`VerifiedAllSessionsClosed` can mint recovered settled-Destroy closure, after which the established persisted
Harness close authorization reclaims the run and finalizes it. `cabal test all --ghc-options=-Werror` passed
all 2,359 tests on linux-cpu, including governed documentation validation.

#### Remaining Work

- Replace `refusingRecoveredResourceExecutor` as the executor `protectedProjectRunOwnership` installs (and
  `ownRun` uses) with the real executor described in Deliverables: for a foreign frame it builds the recovered
  edge with `withRecoveredChildProjectionBinding`, sends the recovery handoff, and releases through the child's
  verified recovery descent (Sprint 18.15's receiver); for the root frame it calls the root's reverse adapter.
  With the refusing executor, any abandoned bound `test run` holding one owned resource fails every sweep with
  "no recovered backend is installed" and the lease, mode, and records stay stuck. Delete
  `refusingRecoveredResourceExecutor` once no caller remains.
- Add the production-bracket two-frame `HarnessSpec` case, the read-back assertions in `RecoverySpec`'s
  recorded-release case, the tightened backend-refusal match, and the foreign-plan and unknown-adapter
  `driveRecoveredForest` cases named in Validation.
- Move `RecoveredResourceExecutor (..)` and `protectedProjectRunOwnershipWithRecovery` out of the public
  `HostBootstrap.Harness.Ownership` exports into a Cabal-private module (or a test-support component), or make
  the executor return a typed release proof only a real backend release can produce. Any consumer can install
  an executor that returns `Right ()` without releasing anything, and `closeOrRecoverResources` then records the
  resource released, mints settled-destroy closure, and closes the run.
- Make `closeOrRecoverResources` return the actual recovery failure (`Left failure -> Left failure`, optionally
  carrying the pre-teardown refusal as context); it collapses every failure other than
  `ModeOwnershipUnresolved` into the earlier `verifyBoundRunHasNoProjectResourcesAcquired` refusal.
- Rewrite the `resolveBoundRun` Haddock, its inline comment on the `IncompleteMigration` branch, and step 1 of the
  `Harness/Ownership.hs` module header to describe the branches the code takes: persisted-Closing finish,
  no-resource close, and recovered-forest teardown through the installed executor. They say a run that recorded
  effects stays fail-closed.
- Add the two `recordRecoveredResourceReleased` refusal cases and the post-teardown close-failure case named in
  Validation, and assert `recoveredForestPlanDigest` in the existing forest cases.

### Sprint 18.17: Production lifecycle ownership adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Retain the Production mode, canonical snapshot, binding, and bound invocation lease across the recursive
lifecycle command.

#### Deliverables

- The production command entry uses the composite Production root bracket rather than minting command authority
  beside lifecycle ownership.
- Plan construction persists and authoritatively verifies the exact canonical snapshot before `bindRunLease`
  yields the bound package and normal-active recovery evidence with identical indices through every frame.
- True-pre-effect refusal uses its dedicated close; every later failure remains recoverable, and no callback can
  retain an unbound lease or substitute snapshot/broker identity.
- `closeCompletedProductionInvocation` revalidates the stored Production mode's epoch against the bound lease's
  epoch and closes the invocation lease only at the bound lease's exact version and `LeaseBound` bytes; only an
  uncertain store write maps to `ProductionInvocationCloseUnknown`, and definite refusals return `Left`.

#### Validation

`LifecycleSpec` and `AuthoritySpec` cover the composite entry, snapshot read-back, exact lease binding,
true-pre-effect close, recoverable post-bind failure, and every scope/plan/broker substitution.

On 2026-08-22, the focused Production selection passed all 100 cases. The command's fresh route enters through
one `withProductionRoot`, derives its lifecycle profile and sole `ProjectPlan` beneath that composite root,
and calls `withPersistedPlanSnapshot` before the bound package enters `runExactProjectUp`. The recovered route
admits the existing bound snapshot once, refines the finalized spec/config/drafts under the same generative
plan identity, and threads the root authority, mode, lease, verified snapshot, bound snapshot, digest binding,
plan, current frame, and lifecycle context together. Source-shape and compile-fail cases exclude compatibility
or independently minted plan routes and cover every scope/spec/plan/broker substitution. The unchanged code
was included in the immediately preceding `cabal test all --ghc-options=-Werror` gate, which passed all 2,359
tests on linux-cpu.

The sprint closes when `AuthoritySpec` carries `closeCompletedProductionInvocation` cases for: a mode lease from
an earlier root (`ModeEpochMismatch`); Production mode released before the close (`ModeHeldByAnother "none"
"production"`); a stored Production mode re-epoched by a later invocation, presented with the earlier
invocation's completion proof, asserting refusal with the later invocation's lease untouched; a lease record
rewritten to different well-formed bytes, asserting a definite `Left` rather than
`ProductionInvocationCloseUnknown`; and an uncertain lease-close write, asserting
`ProductionInvocationCloseUnknown key` and that a retry with the same key converges; each successful close also
asserts `productionInvocationCompletedRun`; and `cabal test all` from `core/` passes.

#### Remaining Work

- Make `closeCompletedProductionInvocation` (`Mode.hs`) read the stored mode with its epoch and require it to
  equal `brokerEpochWord (boundRunLeaseEpoch bound)`; `currentMode` discards the epoch, so a stale completion
  proof passes the guard and `closeLeaseForKey` closes whatever lease sits at the shared Production key.
- Replace its `closeLeaseForKey` call with an exact close at `boundRunLeaseRecordVersion` and the `LeaseBound`
  bytes, mapping only an uncertain store write to `ProductionInvocationCloseUnknown`.
- Add the five `closeCompletedProductionInvocation` cases named in Validation.

### Sprint 18.18: Settled Production destroy closure [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Closure.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Consume the recursive destroy proof at the Production closure boundary and nowhere else.

#### Deliverables

- A sealed `ProductionClosureAuthorization` retains the exact Production root and invocation lease.
  Settled closure requires `ProjectDestroy`, the unique-root `DestroySettled` proof, the bound canonical
  snapshot and an independently complete Closed session set. True-pre-effect closure retains the complete
  unbound Production root and verifies that no acquisition or effect record exists.
- The protected finalizer revalidates project, store, broker epoch, lease version and bytes, snapshot,
  current project journal and all sessions before admitting closure. Stale, substituted, partial or
  open-session evidence refuses without releasing ownership.
- The existing lifecycle redo coordinator commits Closed, the invocation lease close, the retained terminal
  intent and mode release as one logical transaction. Session opening competes on the same coordinator
  version, and ordinary admission recovers an interrupted materialization before exposing authority.
- A fresh, authorized Up can begin a new project journal generation after completed Destroy. Retained
  closure evidence cannot close that successor, and exact close retry performs no second transition.
- The public Production bracket consumes true-pre-effect closure on an unbound refusal or exception;
  bound failures retain their durable recovery state. A pre-effect authorization or release failure in that
  close is surfaced to the caller, never discarded.
- Every closure and completion proof compares its value-level plan digest with the bound lease's, and an
  undecodable reverse-root intent refuses with `ModeMalformedRecord`, not `ModeReverseRootInProgress`.

#### Validation

`LifecycleSpec` and `AuthoritySpec` cover settled destroy closure, down and partial-destroy refusal, wrong-lease
and open-session refusal, retry convergence, and absence of a second close or mode release.

On 2026-08-22, the focused Authority (112), Lifecycle excluding the separately named recursive group
(141), and Handoff (107) suites passed; `cabal test all --ghc-options=-Werror` passed all 2,359 tests on
linux-cpu.

On 2026-09-05, the native macOS arm64 warning-clean focused lifecycle, session, handoff and interruption
selection passed all 345 cases in 75.40 seconds. Production close interruption fixtures reconstruct every
physical prefix of the finalizer's own three-target pre-effect transaction, recover through Session and Mode
entries, and compare exact terminal record versions and bytes with uninterrupted completion. The final
Authority, closure compile-fail, documentation and platform manifest selection passed 141/141 in 2.35 seconds.

On 2026-09-05 (America/Toronto), the complete `cabal test all --ghc-options=-Werror` gate passed
2,492/2,492 in 143.58 seconds on native x86_64 Linux, GHC 9.12.4 and Cabal 3.16.1.0. The reverse
protocol guards cover their owned section while the sealed finalizer consumes that protocol through the
existing transaction coordinator. The focused indexed-plan guards passed 92/92 on macOS in 22.16 seconds.
The changed production lines introduce no HLint findings; the wider scanned modules carry 46 existing findings.

The sprint closes when: `AuthoritySpec` carries a plan-digest refusal case for each of `destroySettledClosure`,
`recoveredDestroySettledClosure` (plus its empty-forest `ModeClosureMismatch`), `completeProductionInvocation`,
`authorizeHarnessClose`, and `authorizeProductionDestroy`, each presenting a `verifyAllSessionsClosed` proof (or
forest or destroy proof) taken for `"other-plan"` and asserting `Left (ModeSnapshotMismatch <bound> "other-plan")`
with no store mutation; "production mode is released, so a harness run may then start" binds the Destroy root's
result, asserts `Right ()`, and asserts the mode record is absent before the harness sweep; the
interrupted-Production-close fixture's `verify` also reads `transaction.<plan>` and asserts `CoordinatorIdle` at
the descriptor's sequence, and every prefix runs through both the Mode admission route and the Session route
rather than splitting by parity; `withInterruptedProductionTransaction` drives a settled-destroy
`releaseProductionMode` (`SettledProductionClosure`, the four-target `TxnFinalizeProductionProject` with the
reverse-root intent target) at each prefix 0..4 and `reopenClosedProductionJournalKernel`
(`TxnReopenProductionProject`) at each of its prefixes, each converging to the uninterrupted bytes; a
settled-release case with an undecodable reverse-root intent asserts `ModeMalformedRecord <intent key>`; and a
`withProductionRoot` case whose pre-effect release fails asserts the failure reaches the caller; "the
Production bracket closes a true pre-effect exception" asserts the caught exception is the callback's own
(`ioeGetErrorString e == "pre-effect fixture"`, or a test-local exception type thrown and caught by type), so an
exception raised inside `closeUnbound` cannot replace it unnoticed; and `cabal test all` from `core/` passes.

#### Remaining Work

- In `releaseProductionMode`'s `SettledProductionClosure` branch (`Mode.hs`), match the undecodable intent
  (`Nothing`) as `ModeMalformedRecord (recordKeyText intentKey)` and keep `ModeReverseRootInProgress` for decoded
  non-terminal intents; the catch-all maps both to `ModeReverseRootInProgress`.
- Make `withProductionRoot`'s `closeUnbound` surface an `authorizeProductionPreEffect` refusal and a
  `releaseProductionMode` failure (combined with the original `Left`) instead of discarding both; a failed
  pre-effect release leaves Production mode held with no diagnostic.
- Add the five plan-digest refusal cases, the bound Destroy-root assertion, the coordinator-idle and both-route
  prefix matrix, the `TxnFinalizeProductionProject` and `TxnReopenProductionProject` interruption fixtures, the
  malformed-intent case, and the pre-effect release-failure case named in Validation.
- Tighten `AuthoritySpec`'s "the Production bracket closes a true pre-effect exception", which accepts any
  `IOException`, to assert the callback's own exception reaches the caller, as named in Validation.

### Sprint 18.19: Deterministic interruption fixtures [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/RecoveryInterruptionSpec.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Expose deterministic process-death boundaries for every recovery transition the host-static gate exercises.

#### Deliverables

- A subprocess fixture publishes a durable ready sentinel and can be killed after owned-resource settlement,
  migration freeze, migration commit, destroy settlement, or persisted `Closing`.
- The successor opens the same protected store and verifies exact-once convergence, old-permit refusal,
  child-first release, terminal lease/mode state, and no duplicate effect after real process termination.
- Fixtures use managed temporary artifacts and captured output, create no `.log` or authority bypass, and fail
  loudly on protocol errors, missing sentinels, or unexpected exits.
- The top-level Tasty group is named `recovery-interruption`, giving the later linux-cpu gate one stable,
  targeted test selector.

#### Validation

`cabal test all --ghc-options=-Werror` from `core/` runs the complete deterministic fixture matrix and all
negative protocol cases. The later [test-harness phase](phase-19-test-harness-and-run-ownership.md) reruns it
on linux-cpu from `core/` with
`cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror --test-options='--pattern recovery-interruption'`;
that acceptance is not part of this phase's closure gate.

On 2026-08-22, the named `recovery-interruption` group passed all five subprocess cases. Each producer
publishes readiness and is hard-killed; each successor is a separately exec'd test process opening the same
store. The `owned-resource-settled` producer writes a single-frame (`host`) owned resource and is killed before
any settlement, so its expected events are `["host"]`. The `migration-frozen` and `migration-committed`
producers (`abandonBoundRunWithMigration` in `HarnessSpec`) persist a plan snapshot, bind an ordinary lease,
and write only the `IncompleteMigration` or `CompletedMigration` revision kind; no frozen or migrated lease,
prospective snapshot, or barrier exists, and the successor accepts either "converged" or "refused-exactly"
(the completed side passes through the "plan snapshot is persisted" refusal). The `closing-persisted` case
covers fresh-permit refusal, and the destroy case runs a public root/VM/container Destroy followed by a fresh
Up and Destroy; it pins closed Production-lease reuse: only a fresh Up broker may reopen the fixed Production
lease, clear the prior invocation acknowledgment, and consume an older retained terminal intent; Down,
Destroy, and stale generations cannot rearm it. On 2026-08-22 (linux-cpu, GHC 9.12.4),
`cabal test all --ghc-options=-Werror --test-options='--hide-successes' --test-show-details=direct`
from `core/` passed all 2364 tests in 146.93 seconds.

The sprint closes when the `recovery-interruption` group carries: an `owned-resource-settled` producer over a
two-frame (host→vm) owned forest that is killed after the vm release has been recorded and before the host
release, with the successor asserting events `["vm", "host"]` across both processes (the vm resource is
released exactly once) and a closed lease; a `migration-frozen` producer that runs the real
`withPlanMigration` on a Production root and is killed after the frozen lease is written, with the successor
asserting the run resumes or cancels through the Production migration recovery of Sprint 18.21 and ends with
the exact old-bound or new-bound lease; a `migration-committed` producer that runs the real
`commitMigrationActivation` and is killed after it returns, with the successor asserting convergence through
`withCompletedMigrationRecovery` and `activateMigratedPlanConfigless`; and one exact expected successor result
per boundary instead of accepting either result. The `destroy-settled` probe publishes readiness from inside
`project destroy` at the settled boundary (before the closure finalizer), and the parent, after the kill and
before the next `up`, opens the protected store and asserts the invocation lease's terminal state and the
persisted mode; every boundary whose executor must not fire passes `Just []`, with a missing events file read as
the empty list; the `closing-persisted` producer is killed before its Closing entry returns, and its successor
matches `Left (SessionProjectClosing "interruption-plan")` and dies on any other `Left`; and producers publish
readiness by writing a temporary file and renaming it into place, while `awaitFile` polls until the content is
non-empty or the producer has exited (reporting its exit code), with a longer budget for the destroy probe.
`cabal test all` from `core/` passes.

#### Remaining Work

- Rebuild the `owned-resource-settled` probe over a two-frame owned forest killed between the child and parent
  releases, and pin the cross-process events `["vm", "host"]`.
- Rebuild the `migration-frozen` and `migration-committed` probes on the real `withPlanMigration` and
  `commitMigrationActivation` brackets over a Production root (replacing `abandonBoundRunWithMigration`'s
  synthetic revision records), with successors that assert convergence through the Production migration
  recovery of Sprint 18.21.
- Replace the either-result acceptance in `boundaryCase` with one expected successor result per boundary.
- Move the `destroy-settled` readiness sentinel inside `project destroy` at the settled boundary
  (`runDestroyInterruptionProbe` in `RecursiveLifecycleSpec` writes it after destroy returns, so the kill
  interrupts nothing), and assert the lease's terminal state and the mode from the protected store before the
  next `up`.
- Pass `Just []` for the `migration-frozen`, `migration-committed`, and `closing-persisted` boundaries and read a
  missing events file as empty, so a successor that runs the executor fails.
- Kill the `closing-persisted` producer inside its Closing entry, and match the successor's refusal as
  `SessionProjectClosing "interruption-plan"` (`HarnessSpec`), dying on any other `Left`.
- Publish readiness by atomic rename and make `awaitFile` poll for non-empty content or producer exit, report
  the producer's exit code, and give the destroy probe a longer budget.

### Sprint 18.20: Production up carries a compatible revision through the migration barrier [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make the migration brackets of Sprints 18.3 and 18.8–18.13 reachable from the CLI: a Production `up` whose
freshly built plan differs from the active bound revision carries the revision forward through the freeze,
commit, and activation barrier instead of refusing or rebinding.

#### Deliverables

- The Production `up` route in `Command.hs`, after building the new `ProjectPlan` under the composite
  Production root, compares its canonical digest with the active bound snapshot's plan digest; an equal digest
  proceeds unchanged into `runExactProjectUp`.
- A different digest runs, in order and under the same root, `withProjectUpMigrationProfile`,
  `withProspectiveMigrationPlan`, `withPlanMigration`, `commitMigrationActivation`, and the configful
  `activateMigratedPlan`, and only then enters `runExactProjectUp` with the new-bound lease and the new
  revision's `CurrentBrokerSessionAdmission`.
- Any refusal before commit leaves the old revision active and is reported as a typed migration refusal; a
  refusal after commit leaves the completed-migration state for Sprint 18.21's recovery.
- Down and destroy never start a migration.

#### Validation

`LifecycleSpec` carries a case that runs Production `up` with one fixture config, edits the config to a
compatible variant that renders a different plan, runs `up` again through the public command entry, and asserts
the recorded revision kind is `CompletedMigration` with the stable key, the lease is bound to the new plan
digest, and the barrier's set digest equals the old exact-set digest; a same-plan `up` case asserts no
prospective record is written. `cabal test all` from `core/` passes.

#### Remaining Work

- Wire the migration chain named in Deliverables into the Production `up` route; outside `Mode.hs` the brackets
  are referenced only by tests and source guards, and no command freezes a Production revision.
- Add the two `LifecycleSpec` cases named in Validation.

### Sprint 18.21: Production recovery of an interrupted migration [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Give a killed Production migration a recovery path: the next Production invocation classifies the recorded
revision kind, re-mints the frozen capability from durable state, and reaches Sprint 18.11's resume or cancel,
or the completed-migration activation.

#### Deliverables

- The Production recovered route dispatches on the recorded revision kind of the bound run before any other
  recovery: `NormalRevision` keeps the existing recovered route; `IncompleteMigration` and
  `CompletedMigration` take the branches below.
- `withDurableFrozenMigration` (`Mode.hs`) mints a `FrozenMigrationRunLease` from durable state alone, for an
  invocation that never ran `withPlanMigration`. It takes the `ProtectedSession`, the
  `InstalledProjectIdentity projectId`, and the run's `RunIdentity (Production projectId)`; under one ordinary
  project admission it reads the run's `LeaseFrozen` lease record and requires the recorded revision kind to be
  `IncompleteMigration` naming the lease's stable key, then reifies the lease's recorded epoch through
  `withRecordedEpoch` (which accepts only the currently allocated generation, so the route opens the frozen
  migration before it allocates a fresh epoch) and passes the capability and that `BrokerEpoch` to a
  continuation with fresh rank-2 old/new spec and plan digest indices and `brokerGeneration`. Any other lease state refuses with `ModeLeaseNotBindable <run> <state name>`,
  and any other revision kind refuses with the constructors `withRecoveredMigrationPlanSnapshot` uses.
- `IncompleteMigration` opens the frozen capability through `withDurableFrozenMigration`; under `up` it resumes
  through `withRecoveredMigrationPlanSnapshot` (config and drafts must render the persisted candidate) and then
  `commitMigrationActivation`; under `down`/`destroy` it cancels through
  `cancelIncompletePlanMigrationForTeardown` and continues teardown on the restored old-bound lease.
- `CompletedMigration` under `up` rebuilds through `withCompletedMigrationPlan` and activates with
  `activateMigratedPlan`; under `down`/`destroy` it activates configlessly through
  `withCompletedMigrationRecovery` and `activateMigratedPlanConfigless` before teardown.
- A refusal in any branch retains the frozen or migrated lease, mode, snapshot, and records.

#### Validation

`LifecycleSpec` carries one case per branch (incomplete + `up`, incomplete + `down`, completed + `up`,
completed + `destroy`), each starting from the durable state the real brackets leave after an injected failure
at that point and asserting the terminal lease, revision kind, and mode; and one case per branch with the
config edited or deleted between failure and recovery, asserting the configful branches refuse and the
configless branches converge. The `recovery-interruption` migration boundaries of Sprint 18.19 run against
these branches. `AuthoritySpec`'s `migrationCases` carries opener cases that run the real `withPlanMigration`,
discard the returned capability, and open a fresh protected entry on the same store: `withDurableFrozenMigration`
followed by `withRecoveredMigrationPlanSnapshot` and `commitMigrationActivation` reaches `CompletedMigration`;
followed by `cancelIncompletePlanMigrationForTeardown ProjectDown` it restores the old-bound lease and records
`NormalRevision`; a run whose lease is `LeaseBound` refuses with `ModeLeaseNotBindable <run> "bound"`; and a
`LeaseFrozen` run whose revision kind is `NormalRevision` refuses with
`ModeWrongRecoveryScope "incomplete-migration" "normal revision"`, each refusal leaving the lease and
revision-kind records unchanged. `cabal test all` from `core/` passes.

#### Remaining Work

- Add `withDurableFrozenMigration` to `Mode.hs` and its export list as named in Deliverables, and the four
  `AuthoritySpec` opener cases named in Validation.
- Add the revision-kind dispatch and the four branches named in Deliverables to the Production recovered
  route; no Production recovery path dispatches on `IncompleteMigration` or `CompletedMigration`, and the only
  revision-kind dispatcher is the Harness `resolveBoundRun`, whose migration branches Sprint 18.22 turns into
  refusals (its `resumeCompletedMigration` sequence — `withCompletedMigrationRecovery`,
  `withMigratedRecoveredProjectFrames`, `activateMigratedPlanConfigless` — is the configless order this route
  uses).
- Add the `LifecycleSpec` cases named in Validation.

### Sprint 18.22: Harness recovery admits only harness lease states [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Migration is Production-only: `withProjectUpMigrationProfile` consumes the Production root, and the harness sweep
excludes the Production lease. The harness sweep and reopener therefore accept only the lease states a harness
run can reach, and the public Mode surface carries no producer that forges a migration or classification
observation for a harness run.

#### Deliverables

- `abandonedHarnessLeases` filters the reserved Production key before decoding, and a harness lease key holding
  `LeaseFrozen` or `LeaseMigrated` refuses the sweep with `ModeMalformedRecord` naming the key; a live
  Production migration never affects the harness sweep.
- `withAbandonedHarnessRun` compares the bound lease with the verified snapshot's digests under every recorded
  revision kind; no activation-barrier exception exists on the harness path.
- `resolveBoundRun` refuses a harness run whose recorded revision kind is `IncompleteMigration` or
  `CompletedMigration` with `ModeWrongRecoveryScope`, retaining the lease, mode, snapshot, and records;
  Production migration recovery is Sprint 18.21's.
- `HostBootstrap.Lifecycle.Mode` exports neither `recordOpenRevisionMigration` nor `classifyAbandonedBoundRun`,
  and `retainBoundLeaseGeneration` carries one Haddock that matches its comparison.

#### Validation

`AuthoritySpec` carries: a harness lease key holding well-formed `LeaseFrozen` bytes, asserting
`recoverAbandonedHarnessRuns` refuses with `ModeMalformedRecord` naming the key; a frozen Production lease beside
an empty harness key space, asserting the sweep returns `ClosedAbandonedHarnessRuns 0`; and a bound harness run
whose snapshot digests differ from its lease while its revision record (written by a raw protected-record write)
reads `CompletedMigration`, asserting `ModeSnapshotMismatch`. `HarnessSpec` replaces `abandonBoundRunWithMigration`
and its cases with one that writes `IncompleteMigration` and `CompletedMigration` kinds through raw protected
writes and asserts the successor run refuses with `ModeWrongRecoveryScope` and the lease, mode, and snapshot are
unchanged. `cabal test all` from `core/` passes.

#### Remaining Work

- In `Mode.hs`, filter Production keys in `incompleteLeases`'s caller before decoding and make `kindOf` refuse
  `LeaseFrozen` and `LeaseMigrated` instead of classifying them as `IncompleteBound`: `leaseStillBoundTo` and
  `retainBoundLeaseGeneration` accept only `LeaseBound`, so the classification reaches only refusals.
- Delete `checkSnapshotDigests`'s `crossedActivationBarrier` exception in `withAbandonedHarnessRun`.
- In `Harness/Ownership.hs`, replace the `IncompleteMigration` and `CompletedMigration` branches of
  `resolveBoundRun` with a `ModeWrongRecoveryScope` refusal and delete `resumeCompletedMigration`.
- Delete the `recordOpenRevisionMigration` export (its only caller is `HarnessSpec`) and the unused
  `classifyAbandonedBoundRun`, which skips the `leaseStillBoundTo` recheck.
- Delete the orphan first Haddock block of `retainBoundLeaseGeneration` and rewrite the second to say it compares
  against the digests the sweep classified from the lease record, which the caller has already checked against
  the snapshot; drop the completed-migration rationale.
- Add the `AuthoritySpec` cases and the rewritten `HarnessSpec` migration-kind case named in Validation.

### Sprint 18.23: Invocation dispositions are write-once [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make every terminal invocation disposition a write-once durable fact whose only producer holds the evidence it
names.

#### Deliverables

- `writeInvocationDispositionForKey` admits `Open` → `Acknowledged`/`Closing`; rewriting an identical value is
  an idempotent success, and any other existing terminal disposition refuses with `ModeEvidenceMismatch` instead
  of being overwritten.
- A harness Closing epoch is the epoch the project journal moved to through `Session.beginClosingProject`, carried
  as typed evidence into `authorizeHarnessClose`; no caller passes a raw `Word64`.
- `authorizeHarnessClose` is the sole producer of a persisted Closing disposition: `recordHarnessClosingEpoch` is
  not exported.

#### Validation

`AuthoritySpec` carries: `Acknowledged k1` then `Acknowledged k2`, `Closing 5` then `Closing 7`, and `Closing`
then `Acknowledged`, each refusing with `ModeEvidenceMismatch` with the record bytes and version unchanged; an
identical rewrite returning `Right` with the version unchanged; a second `authorizeHarnessClose` presenting a
different Closing epoch for a run whose epoch is persisted, refusing; and two harness closes whose persisted
epochs equal the epochs `beginClosingProject` returned for their journals. The persisted-Closing cases ("a
persisted closing epoch is reopened as the closing branch", "a persisted closing epoch is resumed, and only at
its own epoch") reach that state through `authorizeHarnessClose`. `cabal test all` from `core/` passes.

#### Remaining Work

- Make `writeInvocationDispositionForKey` (`Mode.hs`) an explicit write-once transition as stated in
  Deliverables; it compare-and-swaps against the version it just read, overwriting any disposition.
- Derive the Closing epoch from `beginClosingProject`'s Closing state and pass it to `authorizeHarnessClose`
  from `Command.hs` and `Harness/Ownership.hs`, which pass the literal `1`; align the
  `HarnessCloseAuthorization` and `authorizeHarnessClose` Haddocks with that evidence.
- Remove `recordHarnessClosingEpoch` from `Mode.hs`'s export list and rewrite the two `AuthoritySpec` cases that
  call it.
- Add the cases named in Validation.

### Sprint 18.24: Recorded-session recovery evidence is entry-bound [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Bind the fence set, session manifest, and interpretation that admit the current broker to the protected entry and
plan that produced them, and prove every admission refusal and every interpreter outcome by its durable effect.

#### Deliverables

- `VerifiedSessionManifest`, `OldPermitsFenced`, and `InterpretedRecovery` are indexed by the `ProtectedSession`
  `session` parameter and declare nominal roles for their scope and plan indices, so they cannot leave
  the entry that produced them or be retagged with `coerce`. `OldPermitsFenced` already has nominal scope
  and plan roles from Sprint 10.4; its protected-entry index remains part of this sprint.
- `CurrentBrokerSessionAdmission scope planId brokerGeneration` declares all three roles nominal, with
  independent newtype-alias compile-fail probes for scope, plan, and broker generation. These roles
  prevent re-indexing a held admission; they do not replace the producer's runtime evidence checks.
- Recorded-session rebinding refuses when the re-read session record's membership differs from the manifest's
  set instead of overwriting it.
- `OldPermitsFenced` carries `(SessionId, operationKey)` pairs, and `interpretRecordedSessions` checks each
  manifest operation that holds authority is a member of that set.
- `oldPermitsFencedFrom` names the last Observed epoch, persisted with the `FenceIntentRecorded` record, so a
  resumed interrupted rotation reports the epoch a delayed permit carries.

#### Validation

`SessionSpec` carries: `admitCurrentBroker` refusals for an interpretation of another plan
(`SessionRecoveryPlanMismatch`), an interpretation of an earlier one-session manifest presented with a later
two-session manifest (`SessionRecoveryIncomplete 2 1`), and a session opened between interpretation and admission
(`SessionRecoveryUnresolved`); `verifySessionManifest` refusals for two record names mapping to one session id
(`SessionManifestDuplicateSession`) and a member record deleted before the interpreter reads it
(`SessionManifestMissingRecord`); a membership-changed case registering an operation into a session after the
manifest is verified, asserting the rebind refuses and the record is unchanged; an interrupted-rotation case
resuming a `FenceIntentRecorded` rotation from E and asserting `oldPermitsFencedFrom` is E; an
`OperationAlreadyTerminal` case over an `ObservedForeign` operation with unchanged bytes and version; and
`withInterruptedProductionTransaction` over the `TxnRebindSession` step at each prefix, converging to the
uninterrupted bytes. The admission happy path asserts `admissionBrokerGeneration admission == brokerEpochWord
epoch` and that the closed session record's marker equals that generation; "committed work is left alone rather
than rewritten" compares op-1's bytes and version before and after interpretation (and does the same for a
`TerminalDisposition` phase); "settled as abandoned under the new fence" reads op-1 back and asserts its fields
are `RecoveryAbandoned`, the session, the new fence epoch, and the attempt; and every setup entry runs through
`expect =<< inEntry` so a refused setup fails the case. `CompileFailSpec` carries a fixture that returns a
`VerifiedSessionManifest` out of its entry and one that `coerce`s an `OldPermitsFenced` to another plan, both
failing to type-check. `cabal test all` from `core/` passes.

#### Remaining Work

- Index `VerifiedSessionManifest`, `OldPermitsFenced`, and `InterpretedRecovery` by the `ProtectedSession`
  parameter and add the remaining nominal role annotations (`Session.hs`), preserving the scope and
  plan roles already present on `OldPermitsFenced`.
- Add nominal scope, plan, and broker-generation roles to `CurrentBrokerSessionAdmission` and register
  one genuine newtype-alias coercion probe per axis in `CompileFailSpec`.
- Make `rebindAndClose` refuse when the re-read membership differs from `manifestSessionOperations member`.
- Make `outstandingOperationKeys` keep the session id, carry the pairs in `OldPermitsFenced`, and fold over them
  in `interpretRecordedSessions`, refusing a manifest operation that holds authority but is not in the set.
- Persist the prior Observed epoch in the `FenceIntentRecorded` record and return it as `oldPermitsFencedFrom`
  when `establishInitialFence` resumes an interrupted rotation.
- Add the `SessionSpec` and `CompileFailSpec` cases named in Validation, retain the checked setup in
  "a settled operation holds no authority", and make the plan-mismatch setup fail on refusal.

### Sprint 18.25: Every sole-producer lifecycle witness has a forge fixture [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Recovery.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The lifecycle modules state a private constructor or a named sole producer for ten witnesses, and the export
lists hide those constructors, but no compile-fail fixture constructs any of them. An export-list edit such as
`ProjectClosureEvidence (..)` would let a consumer forge closure evidence, a sweep proof, or broker admission
with the compile-fail suite still green. The ten witnesses span the session, closure, abandoned-run sweep,
migration, and recovered-forest contracts, the last of which this phase introduces, so the fixtures land here.
This sprint gives each witness a fixture that fails for exactly that reason.

#### Deliverables

- One fixture per witness constructs it directly and is registered with "Illegal term-level use of the type
  constructor '<Type>'" for that type. From `HostBootstrap.Lifecycle.Session`: `CurrentBrokerSessionAdmission`
  (sole producer `admitCurrentBroker`) and `VerifiedAllSessionsClosed`.
- From `HostBootstrap.Lifecycle.Mode`: `ClosedAbandonedHarnessRuns`, `VerifiedIncompleteRunLease`,
  `HarnessCloseRoot` (producers `currentHarnessCloseRoot` and `withAbandonedHarnessRun`),
  `HarnessCloseAuthorization`, `PlanMigrationBarrier`, `ProjectClosureEvidence`, `InvocationCloseKey`, and
  `RecoveredForestSettled` (defined in the hidden `HostBootstrap.Lifecycle.Recovery`, reached through Mode's
  re-export).
- Each fixture takes every other sealed value its constructor needs as a function parameter, so the forged
  constructor is the file's only diagnostic.

#### Validation

The host static gate (`cabal test all` from `core/`). Closure criteria: the ten fixtures are registered in
`CompileFailSpec`, each passes with its phrase copied from actual stderr, and exporting any one of the ten
constructors with `(..)` from its exposed module turns exactly that fixture red (checked once by hand for one
type when the sprint closes, then reverted).

#### Remaining Work

- Add `ForgeCurrentBrokerSessionAdmission.hs`, `ForgeVerifiedAllSessionsClosed.hs`,
  `ForgeClosedAbandonedHarnessRuns.hs`, `ForgeVerifiedIncompleteRunLease.hs`, `ForgeHarnessCloseRoot.hs`,
  `ForgeHarnessCloseAuthorization.hs`, `ForgePlanMigrationBarrier.hs`, `ForgeProjectClosureEvidence.hs`,
  `ForgeInvocationCloseKey.hs`, and `ForgeRecoveredForestSettled.hs` under `test/compile-fail`, and register each
  in `CompileFailSpec` with its "Illegal term-level use of the type constructor '<Type>'" phrase.

## Remaining Work

- Sprint 18.1: harness lease close and mode release as one durable step; split-close, malformed-lease, and
  stale-proof cases.
- Sprint 18.2: scope-crossing, callback-count, lower-epoch, and unchanged-store cases, and the persisted-Closing
  sweep case through `protectedProjectRunOwnership`.
- Sprint 18.3: direct refusal tests for `withProjectUpMigrationProfile` (including recovered and migrated
  bindings), migration accessor assertions, and a Haddock naming its `FreshBinding` check.
- Sprint 18.4: collision, cause-matched format, and domain/empty/UTF-8 resource-record cases.
- Sprint 18.5: settlement phase from the handle's index, release removes managed authority, out-of-view
  `Conflict` before rendering.
- Sprint 18.6: disposition-consistency refusal, plan-bound set digest, rank-2 set verifier, distinct digest-only
  refusal, and the exact-set refusal and digest cases.
- Sprint 18.7: rehydration re-reads every member record; handles carry their plan digest; dead kernels deleted;
  module header names both receipt minting paths.
- Sprint 18.8: same-plan, candidate-persistence, and config/draft mismatch cases that observe their verdicts.
- Sprint 18.9: reconstruction refusal cases and a rank-2 `withCompletedMigrationProjectPlanKernel`.
- Sprint 18.10: freeze validates the lease, key, and epoch before settling or recording; bindability and
  ordering cases.
- Sprint 18.11: cancellation checks the recorded `IncompleteMigration` key and matches verbs exhaustively;
  frozen-recovery and cancellation refusal cases.
- Sprint 18.12: lease swap and `CompletedMigration` commit as one transaction (or classified intermediate
  state), completed recovery checks the presented lease, and well-formed post-freeze and post-swap cases.
- Sprint 18.13: cross-migration barrier compile-fail fixture, set-digest activation refusals, and old-session
  settlement with prepared-gate refusal.
- Sprint 18.14: per-operation recovery adapters, descent-derived parent edges, one shared adapter helper, and
  plan/membership/adapter/sibling/corrupted-frame cases.
- Sprint 18.15: receiver consumes the recovered-frame adapter wire; exact-wire and verified round-trip cases.
- Sprint 18.16: production executor replaces `refusingRecoveredResourceExecutor`, the executor seam leaves the
  public API, recovery failures are reported as they occur, and recorded-release refusal cases.
- Sprint 18.17: invocation close checks the stored mode epoch and the exact lease; close refusal cases.
- Sprint 18.18: malformed reverse-root intent and pre-effect release failures are reported; plan-digest,
  coordinator-idle, Production transaction interruption, and exact pre-effect exception cases.
- Sprint 18.19: interruption probes over a two-frame forest and the real migration brackets, with one exact
  successor result per boundary, in-flight kill points, and race-free sentinels.
- Sprint 18.20: Production `up` carries a differing plan through the migration barrier.
- Sprint 18.21: `withDurableFrozenMigration` re-mints the frozen capability from durable state, and Production
  recovery dispatches interrupted migrations by recorded revision kind.
- Sprint 18.22: harness recovery refuses frozen/migrated leases and migration kinds; forging exports deleted.
- Sprint 18.23: invocation dispositions are write-once, with journal-derived Closing epochs.
- Sprint 18.24: entry-bound session recovery evidence and exact admission/interpreter cases.
- Sprint 18.25: a forge fixture for each of the ten sole-producer lifecycle witnesses.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — recovery classification and the migration barrier.
- `documents/architecture/harness_workflow.md` — the sweep's place before a new run.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption and kill-point matrix.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of recovery.
