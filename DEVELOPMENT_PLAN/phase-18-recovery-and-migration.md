# Phase 18 — Recovery and migration

**Status**: Active
**Depends on**: Phase 17 (the recursive lifecycle command)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

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

### Sprint 18.2: Reopening a bound abandoned run [Done]

**Status**: Done
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
- Snapshot/lease divergence is admitted only for the durable completed-migration barrier; every other mismatch
  remains a substitution refusal.

#### Validation

`AuthoritySpec`, `SessionSpec`, and `HarnessSpec` cover the yielded shape, close resumption, no-effect
settlement, all recovery kinds, exact-set session interpretation, wrong bindings and epochs, and successor
admission through the production ownership bracket.

#### Remaining Work

None.

### Sprint 18.3: The durable migration barrier [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Persist and classify both sides of the migration activation barrier.

#### Deliverables

- `withProjectUpMigrationProfile` revalidates the Production `ProjectUp` root, active mode, old bound lease,
  verified snapshot, broker generation, and `NormalActiveRecovery`; it carries no plan.
- `withProspectiveMigrationPlan` records a non-authorizing digest candidate under the stable migration key and
  reads it back; the same-plan case refuses and retry converges on the same key.
- `withPlanMigration` records `IncompleteMigration` before compare-and-swapping the lease from bound to frozen,
  so a pre-barrier crash retains the old lineage and cannot prepare through the frozen lease.
- `commitMigrationActivation` switches the frozen lineage to the candidate-bound lease, records
  `CompletedMigration`, and idempotently completes the record after a post-swap crash.
- `withCompletedMigrationRecovery` selects only the completed branch and recovers the superseded digest from
  the stable key; `RecoveredProductionLifecycleProfile` cannot become a fresh or teardown profile.

#### Validation

`AuthoritySpec` covers profile admission, stable candidate identity, same-plan refusal, incomplete freeze,
completed lineage switch, idempotent commit, both crash classifications, and configless digest recovery.
`SessionSpec` covers the recorded-session evidence retained beside the barrier.

#### Remaining Work

None.

### Sprint 18.4: Verified resource-record bundles [Planned]

**Status**: Planned
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

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.5: Resource settlement recording [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`
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

#### Validation

`ChainSpec` and `ReconcileSpec` cover owned, adopted, released, repaired, and phase-transition records,
idempotent retry, and kills on both sides of the protected settlement write.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.6: The complete resource-record set [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/ResourceRecordSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Prove that recovery and migration hold exactly the resource members declared by the bound snapshot.

#### Deliverables

- Opaque `VerifiedResourceRecordSet` is minted only by a protected exact-set fold over the bound snapshot and
  resource key space; versioned snapshot decoding defines membership.
- Missing, duplicate, extra, unknown, wrong-bound or disposition-inconsistent members refuse, and the set
  carries a canonical `recordSetDigest` over sorted bundles.
- Raw records, caller-selected lists, unknown snapshot versions, and evidence for another snapshot cannot enter
  the fold.

#### Validation

`ResourceRecordSpec` covers every completeness refusal, ordering-independent digest stability, immutable
read-back, and evidence from one snapshot being unusable for another.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.7: Broker-bound resource rehydration [Planned]

**Status**: Planned
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
  broker generation, after re-verifying every journal and receipt or tombstone at one store version.
- The owned eliminator alone yields the rebound handle/receipt; the released eliminator alone yields the
  tombstone. Any stale or unresolved member refuses the whole set.
- Raw receipts and persisted bytes cannot mint handles, teardown steps, session admission, or rollover
  authority.

#### Validation

`ResourceRecordSpec` covers successful owned and released rebinding, every stale-store refusal, all-or-nothing
failure, and fresh broker separation. `CompileFailSpec` pins that raw receipt bytes have no recovery edge.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.8: Scope-correct prospective migration [Planned]

**Status**: Planned
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

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.9: Configful completed-plan reconstruction [Planned]

**Status**: Planned
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

`AuthoritySpec` covers exact reconstruction and changed config, changed draft, wrong implementation revision,
wrong stable key, missing record, malformed record, and unknown-version refusals.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.10: Complete-set migration freeze [Planned]

**Status**: Planned
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
- The exact-set fold stages each owned or released member once; incomplete/inconsistent sets retain the old
  revision, while retry converges only for the same stable key, candidate, and set digest.

#### Validation

`AuthoritySpec` and `SessionSpec` cover session/freeze races, prepared-operation drainage, every exact-set
refusal, retry convergence, and kills before and after the atomic freeze.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.11: Frozen migration recovery [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Resume or cancel the exact frozen old-active migration after a pre-commit process death.

#### Deliverables

- `withRecoveredMigrationPlanSnapshot` is reachable only from `IncompleteMigration` with the matching frozen
  lease; it loads the prospective snapshot and resource-set digest named by the durable stable key.
- A fresh rank-2 migration identity rebuilds only byte-identical supplied config/drafts, while typed
  down/destroy cancellation consumes the inactive staging set and restores only the old-bound lineage.
- Missing, changed, or unknown candidate/set state retains the freeze; neither recovery branch opens a session,
  issues preparation authority, or creates a second candidate.

#### Validation

`AuthoritySpec` covers post-freeze resume and cancellation, edited/deleted config, every stable-key/snapshot/set
substitution, retry convergence, and absence of preparation authority before commit.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.12: Complete-set migration commit [Planned]

**Status**: Planned
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
- One protected compare-and-swap archives the old active records, switches lineage old-to-new, binds the new
  lease, and records the barrier with the same set digest; owned receipts and released tombstones retain their
  dispositions.
- Either crash side classifies wholly as incomplete-old-active or completed-new-bound, retry converges, and old
  and new preparation authority never coexist.

#### Validation

`AuthoritySpec` covers the atomic lineage switch, owned and released members, every frozen/candidate/set
substitution, both crash sides, and idempotent completion.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.13: Complete-set migrated activation [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Admit the new revision only from its local plan binding and the complete set carried across the barrier.

#### Deliverables

- `activateMigratedPlan` consumes the exact barrier, new-bound lease and active revision, local plan and
  persisted binding, and complete rehydrated set before exposing journal or preparation authority.
- It rechecks that every old session is Closed and no old prepared operation remains before minting the new
  revision's `CurrentBrokerSessionAdmission`; no commit-to-activation kill can issue a prepared operation.
- Configful and configless completion share the same set digest and postcondition; any plan, broker, lineage,
  completeness, or disposition mismatch refuses before a session opens.

#### Validation

`AuthoritySpec` and `SessionSpec` cover both activation producers, every binding refusal, old-session and
prepared-operation exclusion, and kill injection between commit and admission.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.14: Snapshot-derived recovery frames [Planned]

**Status**: Planned
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
- Completed configless recovery loads the exact prospective snapshot named by its stable key and supplies that
  snapshot plus the complete set to `withRecoveredProjectFrame`; it never stops at parsed digest text.
- `withRecoveredProjectFrame` accepts only the bound verified snapshot and complete rehydrated set, and resolves
  adapters through the project-owned closed table; old config is never read and unknown versions refuse.
- Resource eliminators expose only the owned handle/receipt or released tombstone at the forest's exact point;
  raw bytes, frame text, receipts, and adapter names cannot construct the frame.

#### Validation

`RecoverySpec` covers root and nested frames with the config present, edited, and absent; unknown versions and
adapters; wrong resource membership; and owned/released elimination. `CompileFailSpec` pins the hidden frame
constructor.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.15: Recovery-wire boundary admission [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Recovery.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/RecoverySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Use the authenticated-handoff phase's recovery wire as the sole nested entry from a recovered parent frame.

#### Deliverables

- The root builds `RecoveryProjectionBindingInput` from the bound snapshot's plan and exact edge, encodes the
  recovered set digest in the adapter bytes, and alone calls `mkRecoveryProjectionBinding`.
- `withVerifiedRecoveryWire` verifies those exact bytes and grant; `withVerifiedRecoveryHandoff` joins the
  binding to the typed down/destroy handoff, which the descent entry consumes with the forest authorization
  point. Immediate parents receive no signing key.
- Replay or any plan/edge/frame/digest/payload/verb/phase mismatch refuses before dispatch; the boundary has no
  config handoff and no route to `ProjectUp`.

#### Validation

`RecoverySpec` pins the exact round trip and every wrong-binding or replay refusal across a real process
boundary. `CompileFailSpec` pins that config handoff and recovery handoff are not interchangeable.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.16: Child-first abandoned-run teardown [Planned]

**Status**: Planned
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
- Only settled destroy plus all sessions Closed authorizes harness closure and reclamation; every unresolved
  outcome retains the lease, mode, snapshot, and records.

#### Validation

`HarnessSpec` and `RecoverySpec` cover multi-frame child-before-parent release, released tombstones, failures
that retain ownership, successful settled closure, repeated recovery, and config deletion between kill and
recovery.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.17: Production lifecycle ownership adoption [Planned]

**Status**: Planned
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

#### Validation

`LifecycleSpec` and `AuthoritySpec` cover the composite entry, snapshot read-back, exact lease binding,
true-pre-effect close, recoverable post-bind failure, and every scope/plan/broker substitution.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.18: Settled Production destroy closure [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Consume the recursive destroy proof at the Production closure boundary and nowhere else.

#### Deliverables

- Reverse projection returns its typed terminal result to the production ownership bracket instead of
  discarding `DestroySettled` after reporting.
- A completed destroy independently proves all sessions Closed, then `destroySettledClosure` combines that
  proof with the lease so only the destroy root and `ProjectClosureEvidence SettledDestroyClose` can call
  `releaseProductionMode`.
- Down, partial destroy, retained resources, or open sessions cannot release; retry observes the durable
  terminal state without minting a second invocation close or mode release.

#### Validation

`LifecycleSpec` and `AuthoritySpec` cover settled destroy closure, down and partial-destroy refusal, wrong-lease
and open-session refusal, retry convergence, and absence of a second close or mode release.

#### Remaining Work

All deliverables in this sprint.

### Sprint 18.19: Deterministic interruption fixtures [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/RecoveryInterruptionSpec.hs`,
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

#### Remaining Work

All deliverables in this sprint.

## Phase Remaining Work

Sprints 18.4–18.19. Phase 18 closes when they pass the host-static gate and its governed documentation aligns;
the later test-harness phase owns live linux-cpu infrastructure confirmation.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — recovery classification and the migration barrier.
- `documents/architecture/harness_workflow.md` — the sweep's place before a new run.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the interruption and kill-point matrix.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the owner of recovery.
