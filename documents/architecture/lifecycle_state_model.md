# Lifecycle State Model

**Status**: Authoritative source
**Supersedes**: lifecycle-state claims embedded in provider and demo narratives
**Referenced by**: [documents index](../README.md), [readiness](readiness.md), [durable state](durable_state.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [harness workflow](harness_workflow.md)

> **Purpose**: Describe the implemented plan, authority, ownership, recovery, and closure boundaries, with
> the owning source modules providing the exact types and signatures.

## TL;DR

One admitted project plan determines forward execution, topology, snapshot membership, and reverse traversal.
The root process owns the durable lifecycle state. Children receive authenticated, bounded grants for their
local work and return observations; they receive no protected store, signing key, journal, or command authority.
Readiness, ownership, and closure are opaque evidence produced by the boundary that verifies them.

Production and each generative Harness run have distinct scope indices. Plan, frame, resource, operation,
broker generation, fence, and record version are retained at the boundaries where they authorize effects.
Stable serialized bytes identify state for verification; they cannot reconstruct those authorities by themselves.

The [development-plan index](../../DEVELOPMENT_PLAN/README.md) owns phase status and dated gate evidence.
[Ownership invariant](ownership_invariant.md) defines the four clauses every managed backend must hold.
[Composition methodology](composition_methodology.md) explains how a project authors the plan.

## Current Status

The root coordinator drives public Production and Harness lifecycle commands, authenticated forward descent,
child-first reverse traversal, failed-Up unwind, recovery, and terminal closure. The implementation is split
by authority ownership:

| Boundary | Source owner | Retained evidence |
|---|---|---|
| Plan admission and projections | [ProjectPlan](../../core/hostbootstrap-core/src/HostBootstrap/ProjectPlan.hs) | Exact scope, finalized specification, configuration, canonical root, and plan |
| Installed identity and invocation | [Authority](../../core/hostbootstrap-core/src/HostBootstrap/Authority.hs) | Installed executable, protected-store origin, live root, and closed verb |
| Mode, lease, recovery, and migration | [Lifecycle.Mode](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs) | Project/store/epoch, snapshot and lease versions, exact recovery lineage |
| Journals, sessions, fences, and receipts | [Lifecycle.Session](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs) | Exact operation, broker generation, journal version, and terminal state |
| Root command entry | [Command.LifecycleEntry](../../core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs) | One root store, admitted plan and catalog, and verb-specific terminal continuation |
| Recursive catalog | [Lifecycle.RootedPlan](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs) | Exact parent/child edges and independently reproducible child plans |
| Rooted execution | [Lifecycle.Rooted](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs) | Catalog-selected sessions, signed grants, observations, and receipt order |
| Reverse traversal | [Teardown](../../core/hostbootstrap-core/src/HostBootstrap/Teardown.hs) | Same-plan reverse forest and complete settlement evidence |
| Durable multi-record publication | [Lifecycle.Transaction](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs) | Canonical target roles, exact predecessors, and idempotent successors |

The linked modules are the signature reference. This document describes their contracts without maintaining
a second set of illustrative signatures that can drift from the compiled API.

Root command entry carries the original executable-verified `InstalledProjectIdentity` from Command
through the private Entry brackets into `authorizeRootProject`. Before reserving an invocation, the
gate compares its name with the retained root project and uses that verified name for the existing
plan and snapshot project checks. A mismatch returns `AuthorityStoreNotOurs` without consuming the
invocation; the scope, plan, frame, broker, verb and phase indices remain attached to their evidence.
The same identity continues into the Session reservation bridge under its one protected entry.
Live journal/source/current-cursor checks precede the leaf comparison and one-use reservation;
recorded project text cannot supply its own independent comparator.

These boundaries fall short of the contracts below:

- `PreparedGate` has three producers. The two production mints are `withPreparedGate` in
  [Lifecycle.Session](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs) (the root's journal
  admission) and the frame executor's local reification in
  [Lifecycle.FrameExecutor](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs), both
  through the package-private `mintPreparedGate`. The third, `recordDurableUnknown`, is exported unchecked from
  the Cabal-exposed [Lifecycle.Prepared](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs)
  and has no caller under `src/`. A holder of a `ProtectedSession` can call it with a record key and coordinates
  of its own choosing, so a gate does not by itself prove that the interpreter's journal admission prepared that
  operation. The [recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
  owns this gap, because the producer's remaining callers and its compile-fail boundary live in files that
  phase and the providers phase introduce.
- Generic operation and phase preparation still accept a retainable `OperationPreconditionSet` from
  public producers. The pure zero-edge entries derive their own empty set, but complete fresh snapshot
  admission remains a target of the
  [prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md).
- The migration brackets in `Lifecycle.Mode` described under [Recovery and migration](#recovery-and-migration)
  have no command caller: a Production `up` never freezes a revision, and no Production recovery path
  dispatches on an incomplete or completed migration. The only revision-kind dispatcher is the Harness
  abandoned-run resolver `resolveBoundRun`, which resumes a completed migration although migration is
  Production-only. Harness close passes a literal Closing epoch of 1 to `authorizeHarnessClose` rather than the
  epoch `beginClosingProject` recorded, and `writeInvocationDispositionForKey` overwrites an existing terminal
  disposition rather than treating it as write-once. The
  [recovery-and-migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md) owns these gaps.
- Abandoned-run recovery of a bound Harness run that holds owned resources does not complete:
  `protectedProjectRunOwnership` installs `refusingRecoveredResourceExecutor`, so the sweep refuses and retains
  the lease, mode, and records. The recovered-frame adapter wire that `withRecoveredChildProjectionBinding`
  produces has no receiver that consumes it. The
  [recovery-and-migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md) owns both gaps.
- The recoverable-open map (see [Cross-process authority handoff](#cross-process-authority-handoff)) discards a
  compare-and-swap store failure and reports it as a token or map conflict. The
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns this
  gap.

## Plan and operation algebra

`StepPlan` is the validated authoring graph. Scope finalization joins a project's codec, service registry,
plan builder, and child projector into one `FinalizedProjectSpec`. `withProjectPlan` admits that specification,
its validated configuration, canonical root, and lifecycle profile together and generates a fresh plan identity.
A recovered plan instead reproduces the exact persisted snapshot under a verified recovered profile.

The single `PlannedResource` representation and its seven resource-family tags live in
[`Plan.Resource`](../../core/hostbootstrap-core/internal/plan-resource/HostBootstrap/Plan/Resource.hs),
inside the Cabal-private `plan-resource-internal` library. That leaf depends only on `base` and `text`.
It retains the plan digest, operation key, and frame, with all five identity indices nominal.
[`Lifecycle.Plan`](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs) owns validated-graph
projection, resource minting, and the readers; public facades re-export the same opaque identity.

The admitted `ProjectPlan` derives its non-empty forward order, topology, stable snapshot, and verb-indexed
reverse projection from one representation. It rejects duplicate or missing keys, inconsistent edges,
non-contiguous frame segments, and invalid descent structure before execution. `withCurrentFrame` joins the
plan-derived topology to the descriptive binary context and generates matching frame evidence. Decoded
context fields alone grant no lifecycle authority.

An executing step receives `StepExecution`, containing its own operation identity and validated dependency
prefix. Its own and projected prepared gates come from the interpreter's journal admission. A step cannot
choose an unrelated plan operation or replace its dependency set with caller-supplied observations.
`withOperationPreconditions` traverses the complete resource-bearing prefix and runs its registered
probes, returning a set the caller can retain.

`withPreparedZeroDependencyOperation` and `withPreparedZeroDependencyPhaseTransition` are pure entries
for descriptors with no dependencies. They derive the empty set internally, accept no retained set,
and refuse a descriptor that declares any edge. No dependency probe IO is needed in this branch. The
phase entry also preserves the managed receipt and transition checks. Provider start, provision and
phase callers and the existing Colima cleanup caller use these explicit zero-edge paths.

Generic `withPreparedOperation` and `withPreparedPhaseTransition` retain their dependency-aware,
set-taking behavior. Matching such a set does not re-run its probes. The complete target is that
preparation validates the gate and descriptor, then observes the whole ordered snapshot itself;
the [prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md) owns that fresh
admission and its caller adoptions. The generic phase capability remains available for nonempty
dependencies; the pure zero-edge entry does not replace it.

## Opaque capabilities

The lifecycle and reconcile modules keep constructors for handles, readiness, ownership receipts, prepared
operations, and settlement evidence private. Nominal roles prevent coercion across scope, plan, frame,
resource, and broker identities. Rank-2 continuations contain newly introduced identities.

Production preparation takes its dependency evidence from backend reprobes: the `DependencyProbe` registered
for each member — `runningProviderDependencyReprobe`, `providerShareDependencyReprobe`, or
`reprobeClusterReadiness` — runs again inside `withOperationPreconditions`; for a cluster, a different
control-plane or worker container identity is a conflict rather than a retryable not-ready result. `Ready` is
plan/resource/dependency-indexed evidence minted by `awaitPlanReady` from a closed backend `Probe`; polling is
bounded and classifies ready, retryable not-ready, failure, conflict, and unsupported behavior explicitly. That
`Ready` path has no production caller. Its successful `BackendReady` report supplies the generation and
versions, with zero versions refused before `Ready` is constructed. Probe construction and observation
live in the Cabal-private readiness kernel, which shares the single planned-resource identity. Public
`Readiness` specializes its generic-config probe to `HostConfig` and retains the polling and validation.
The public `dependencyProbe` wrapper remains a separate visibility gap;
[readiness](readiness.md#current-status) states its owner.
`ObservedReady` is descriptive compatibility evidence and is not accepted as plan-indexed authority.

Managed provider, share, cluster, and guest-alias wrappers retain their backend origin. The prepared adapter
consumes the matching gate, current handle, and matched dependency observations; settlement verifies that the returned
observation belongs to that exact operation. A readiness value or receipt from another backend cannot be
substituted merely because its fields would have the same shape.

Some convenience actions return `IO ()` and the demo's `changed` wrapper reports only that they returned.
That wrapper does not claim idempotence, ownership, or readiness. Managed effects and destructive release
still pass through their prepared adapters and exact settlement evidence. The effect-indexed service DSL
is a separate, stricter handler boundary described in [composition methodology](composition_methodology.md).

## Ownership and idempotence

The four ownership clauses are exclusive entry, a durable origin record, binding to the created object's
identity, and conditional release of that same identity. The [ownership seam](ownership_seam.md) supplies
POSIX and Windows primitives and ships transactions to the frame that owns an object. A pathname, successful
probe, conventional resource name, or observed absence does not by itself satisfy the clauses.

`ReconcileResult` separates a managed handle, its ownership receipt, and `ChangeView` from an unmanaged
foreign observation. In ordinary reconciliation, `BackendCreated` accepts a positive newly created
generation, which may differ from the observed handle's generation, and retains it in both the managed
handle and receipt. Zero refuses. Repair and adoption keep the exact observed generation; a replacement
requires a fresh observation rather than being treated as the same managed resource. Phase verification
then compares its supplied generation with the managed handle's retained generation.

`PriorCommitProof` comes from a verified `Committed` or `AdoptionCommitted` journal record.
`completePreparedUnchanged` rechecks the exact preparation, resource key, generation, and receipt operation
before returning `Unchanged`; intent and observed-only records cannot establish that prior commit.

The resource carrier keeps canonical settlement bytes and their expected predecessor beside in-process
managed evidence. The root writes the exact resource member before acknowledging its operation journal.
Fresh publication requires absence; exact post-write retry converges; a phase or release transition requires
the byte-identical predecessor at the next version. Release retains a tombstone rather than erasing the
stable membership that recovery needs.

`VerifiedResourceRecordBundle` verifies one canonical member's plan, frame, resource, generation, operation,
record version, phase, adapter revision, and disposition. Owned and released members have disjoint folds.
`VerifiedResourceRecordSet` independently reads the protected namespace and compares complete, duplicate-free
membership against the bound snapshot. Missing, extra, malformed, or wrongly bound members refuse the set.

`withPlannedReboundManagedResourceEvidence` takes the rebound resource kind and identity from its
`PlannedResource` and preserves the observed generation and observation version. Its receipt passes through
`rebindOwnershipReceipt`, whose runtime key and generation comparisons protect that cross-identity bridge.
A receipt recovered from a verified durable bundle can name another generation of the same planned resource
and must pass the same checks. Shared nominal identity fixes a resource's key; receipt-key refusal is
therefore exercised through the cross-identity public bridges, not a fabricated different key at the same
identity.

Every receipt producer rejects an empty operation at its ingress, including durable resource-record
rendering/parsing and persisted-journal verification. Receipt validation compares key and generation; it
does not repeat an unreachable empty-operation check. The planned rebinding bridge still has a generic
phase index; the [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the later phase-specific recovery restriction.

## Sessions, fences, and terminal acknowledgement

This page is the architectural home of the session, journal, fence, prepare, and terminal-acknowledgement
protocol that every lifecycle invocation runs; [Lifecycle.Session](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs)
implements it, and [harness workflow](harness_workflow.md) summarizes what the Harness path relies on.

| Term | Meaning |
|---|---|
| Broker generation | The `BrokerEpoch` of one root invocation's broker, allocated from the installed project's protected monotonic counter. A session record names the generation it was opened under, and recovery reopens a recorded generation only while it is still the allocated one (see [Recovery and migration](#recovery-and-migration)) |
| Fence epoch | A `FenceEpoch`, produced only by a durable `FenceObserved` record reached through `FenceIntentRecorded` and `FenceOutcomeUnknown`. A crash between records resumes the same proposed epoch; rotation proposes the next epoch only from the current observed one, and a permit issued under a superseded fence is refused |
| Project journal state | `OpenProject` admits sessions and plan-revision recovery; `ClosingProject` carries a positive Closing epoch and admits only the close of that epoch; `ClosedProject` admits nothing |
| Closing epoch | The positive value `beginClosingProject` writes when it moves the journal from Open to Closing against the caller's exact permit version. Resuming the same persisted epoch is idempotent; a different epoch is refused as a second close |

**Fence establishment and rotation.** The persisted protocol is
`FenceIntentRecorded` → `FenceOutcomeUnknown` → `FenceObserved`. Resuming either unsettled phase uses
its recorded epoch; a different positive caller proposal cannot replace it. Re-establishment over an
observed record returns that observed epoch. `currentFence` yields a token only from `FenceObserved`;
it returns `SessionFenceUnsettled` naming either unsettled phase, or `SessionFenceMissing` naming a plan
with no fence record.

Rotation advances the retained epoch and refuses its maximum `Word64` value with `SessionFenceInvalid`
instead of wrapping to zero, preserving the refused fence record. `fenceOldPermits` first completes an
unsettled establishment at its persisted epoch, then rotates it; another successful call rotates again.
A prepare presenting the superseded token returns `SessionFenceSuperseded` with the presented and live
epochs. An unsettled live fence refuses prepare before its operation record changes.

`FenceEpoch scope planId` and `OldPermitsFenced scope planId` have nominal scope and plan parameters
and private constructors. Neither a held token nor a held fence set can be re-indexed through `coerce`.
The generic `currentFence`, `establishInitialFence`, and `fenceOldPermits` still address caller-supplied
plan text and permit caller-selected result indices; those roles do not authenticate a canonical
runtime plan or make the indices generative. The fence set is not yet indexed by its protected entry.

`ProjectPermit`, `ClosingProjectPermit`, `ClosedProjectPermit`, `OperationSession` and
`OperationAdvance` have nominal scope and plan parameters. An already typed value cannot be re-indexed
with `coerce`. `OperationAdvance` keeps its result parameter representational, so a compatible newtype
payload coercion remains lawful.

This value boundary does not authenticate runtime plan identity. The generic `openProjectJournal`
accepts raw plan text and lets its caller instantiate the result's scope and plan parameters. Nominal
roles do not join that text to a canonical plan or make those parameters generative; higher admission
bridges retain their separate plan and authority checks. Durable version checks supply the independent
concurrency guarantee.

`VerifiedAllSessionsClosed scope planId` also has nominal scope and plan roles, so a held observation
cannot be re-indexed through `coerce`. Its generic `verifyAllSessionsClosed` producer still accepts raw
plan text with caller-selected result indices. The observation authenticates neither those indices nor
a store identity; consumers must still compare its plan text with their bound lease. The abstract
module export is held by the export inventory, separately from the dedicated constructor-forgery proof
owed by the [recovery-and-migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md).

**Session admission.** `openOperationSession` opens one session against the live broker generation only when
the journal is Open, the caller's `ProjectPermit` is the current journal version, and no older session for the
plan is still Open, including one that registered no operation. Opening and closing a session each advance the
shared project-journal version and return its sole successor permit, so a session open and a close of the
project contend on one record version and exactly one wins.

Session's private numeric reader accepts only canonical ASCII unsigned decimal within `Word64`: at most
20 digits, no sign, radix prefix, parentheses or whitespace, and no leading zero except `0`. It parses
through a bounded `Integer` and requires the `showWord` round trip, so overflow cannot wrap. Each caller
keeps its own positivity rule; a Closing epoch must be positive. The shared helper also reads existing
fence and gate fields; numeric admission is separate from their text transport.

Prepared and Session share tab-separated UTF-8 field transport, preserving exact field spelling without
trimming. Strict decoding returns `[]` for malformed UTF-8. The round-trip domain is a nonempty list of
delimiter-free fields: empty bytes cannot distinguish an empty list from one empty field. `encodeFields`
has no refusal channel and performs no generic separator validation. The low-level `recordDurableUnknown`
writer still accepts caller-supplied fields; this transport change does not close its admission gap.

Eligible prepare and recovery-abandon writes require a canonically decoded recorded fence and attempt.
Missing, invalid or noncanonical required fields return `SessionRecordCorrupt "operation record"`
before the operation transaction or callback. The exact registered initial shape
`["IntentRecorded", sid, "0"]` has an implicit attempt of `0`: it may prepare attempt `1` or be abandoned
in recovery. A later record missing its required attempt does not inherit that exception. These checks
admit the numeric fields; they do not replace the whole operation-payload codec.

**Intent registration.** `IntentOrigin` exposes only `NoHistory`, accepted when the operation record is
absent. `readReleasedIntentOrigin` derives the exact operation key from the retained operation session
and operation name, reads its `Released` phase, and retains the protected-store identity, key and physical
record version in a private variant. `AdoptionReleased` and other phases yield no such origin.

Registration re-reads that same location under the existing protected permit/session checks. A different
store or key, absence, changed phase or changed physical version returns `SessionIntentOriginRefused`
before intent/session-membership mutation. Success retains the existing atomic transaction, sorted
membership and successor permit. The observation authenticates neither a complete operation payload nor
backend history and grants no effect authority before registration revalidates it.

This is same-key admission, not an old-key-to-new-key rollover. An absent new target uses `NoHistory`'s
checked-absence path; a distinct acquisition key and root-owned absence protocol remain separate.
Chain continues to register with `NoHistory`; this boundary adds no root-side reacquisition consumer.

**Recorded phase classification.** A private closed `RecordedPhase` vocabulary covers the 43
`Reconcile.PersistedJournalPhase` names plus `StepObservedTerminal` and `RecoveryAbandoned`. Decoding
uses exact enum-derived names, without trimming or aliases, and classification handles every constructor.
The seven recognized unresolved outcomes explicitly yield `UnknownDisposition`:
`ReservationOutcomeUnknown`, `EffectOutcomeUnknown`, `TeardownOutcomeUnknown`, `AdoptionOutcomeUnknown`,
`AdoptionTeardownOutcomeUnknown`, `RepairEffectOutcomeUnknown` and `PhaseEffectOutcomeUnknown`.
Unrecognized text separately fails decoding and reaches the same public disposition. Recognition alone
therefore cannot turn an unresolved outcome into permission to continue or treat it as settled.

The six `Continuable` phases are `IntentRecorded`, `AdoptionIntentRecorded`, `RepairIntentRecorded`,
`PhaseIntentRecorded`, `ReservationRetryFenced` and `Reserved`. This means eligibility for current-fence
prepare checks before the next backend call; it does not claim that no earlier call occurred. The nine
`FencedRetryable` phases remain `ReservationAbsent`, `EffectAbsent`, `AdoptionObservedAbsent`,
`RepairObservedOriginal`, `PhaseObservedFrom`, `EffectRetryFenced`, `AdoptionRetryFenced`,
`RepairRetryFenced` and `PhaseRetryFenced`. Same-identity ordinary and adopted teardown observations
return to `Committed` and `AdoptionCommitted`, not a separate teardown-presence retry phase.

`ObservedManaged`, `AdoptionObservedManaged`, `RepairObservedTarget` and `PhaseObservedTo` classify as
`Settled`, alongside the committed and released phases. `RepairObservedAbsent`, `PhaseObservedAbsent`
and `AdoptionTeardownObservedForeign` classify as `TerminalDisposition`, alongside the existing terminal
branches. Neither disposition grants further effect authority. Classifying an observed success writes
no `Committed` state and mints no `PriorCommitProof` or ownership receipt.

**Prepare.** A prepare retains the session/epoch broker comparison and re-reads the journal under the
exclusive protected entry. After the shared project-journal permit check, it requires an Open session,
canonically decodes that record's durable broker marker, and compares it with the presented broker epoch.
Malformed marker text returns `SessionRecordCorrupt "session"`; disagreement returns
`SessionBrokerEpochMismatch durableMarker presentedEpoch`. It also revalidates project state, current
fence and recorded phase. A closed session with a live permit returns `SessionNotOpen`; a stale permit
retains its earlier refusal priority.

A valid maximum `Word64` attempt returns `SessionAttemptExhausted opKey` before addition, transaction or
callback. Its rendered diagnostic is `session: operation <op> has exhausted its attempt counter`.
The existing fresh-retry-fence check keeps priority: a retry without an older recorded fence still
returns `SessionRetryNeedsFreshFence` before exhaustion. Maximum-minus-one advances to maximum exactly.
Recovery abandonment does not increment the attempt and preserves a valid maximum value.

The requested pre-call phase must decode to exactly one of `ReservationOutcomeUnknown`,
`EffectOutcomeUnknown`, `AdoptionOutcomeUnknown`, `RepairEffectOutcomeUnknown`, `PhaseEffectOutcomeUnknown`,
`TeardownOutcomeUnknown` or `AdoptionTeardownOutcomeUnknown`. An arbitrary `UnknownDisposition` is not
enough, because undecodable text has that disposition too. This request check follows numeric,
retry-fence and exhaustion checks and precedes the transaction or callback. Success durably records
the requested unknown phase before the callback and consumes the journal version; that version cannot
authorize a second prepare or close. The gate comes from this journal admission (see
[Current Status](#current-status) for the separately owned public producer gap).

**Settlement.** `acknowledgeOutcome` retains its gate plan/session and durable record/version checks.
After the shared journal-permit check it requires an Open session and the live observed fence. A gate
from a superseded fence returns `SessionFenceSuperseded presentedFence liveFence`. The recorded phase
must be one of the seven recognized unknowns above; the presented outcome must classify as `Settled`,
`TerminalDisposition` or `FencedRetryable`. Another pair returns
`SessionOutcomePhaseRefused opKey recorded presented`, rendered as
`session: operation <op> refuses outcome phase <presented> from <recorded>`.

This is Session's phase-category admission policy, distinct from Reconcile's family-specific graph
edges. It refuses pre-call rewinds and unresolved target phases without claiming every cross-family
pair is a lawful Reconcile edge. A successful acknowledgement returns `OperationAdvance`, whose
eliminator yields the adapter's result only together with the sole successor permit. A delayed result
cannot settle a newer attempt.

**Terminal acknowledgement.** `closeOperationSession` proves every operation the session registered has
settled before it compare-and-swaps the session record to Closed. Prepare and close exclude each other
through the shared project-journal permit, not by both consuming the session record's version. Each
successful transition returns the sole successor permit. In the rooted path the root publishes the terminal receipt before it signs
`FrameComplete`, and returns `ReceiptRecorded` only after an idempotent `ReceiptConfirm` (see
[Cross-process authority handoff](#cross-process-authority-handoff)). A later teardown invocation receives a
fresh per-edge token and session.

A listed operation whose record is absent is not settled. Both `unsettledOperations` and the recovery
classifier `classifySessionOperations` return `SessionOperationUnregistered name`, so neither session
close nor `recoverAbandonedSessions` can silently discard that member. The listed session remains Open
on this refusal. Independent session/operation enumeration and exact membership remain in place; this
member check adds no rollback guarantee for unrelated recovery work.

## Typed lifecycle transitions

Forward and reverse execution use the same plan. Reverse projection validates the complete frame forest and
visits children before the resources containing them. A failed or incomplete traversal cannot produce
`DestroySettled`. Preserve-on-reverse nodes retain their declared policy; managed release consumes the exact
receipt and reverse identity of the acquiring node.

Visiting children before their container has a precondition on one node kind. A `down` stops a provider
frame and leaves everything inside it retained; the `destroy` that follows cannot unwind those children
through a frame that is no longer running. A provider node under `destroy` that still has children
therefore begins in a **pre-descent reachability** state, and the root reverse driver discharges it by
invoking that node's own declared reverse with `ReachFrame` — the same callback that stops and deletes the
provider is the one asked to open it, so no second declaration can disagree with the first. Only the root
holds the project's callbacks: a frame serving its own children's reverse refuses a reachability step
rather than reporting it released.

Each operation records its durable unknown state before an effect whose answer could be lost. The result
then settles that same operation, fence, generation, and journal version. A delayed result cannot settle a
newer attempt. Unknown outcomes remain recoverable rather than being guessed as success or absence.

Recovery enumerates session and operation records independently, then checks their exact membership.
An operation record's persisted session identity determines its encoded key prefix; the complete suffix
is decoded as the operation identity. ASCII case and literal underscores are escaped injectively, while
namespaces, dotted tokens, and relation paths retain their structure. Complete identity tuple fields use
`recordTupleSeparator` (`...`), absent from the identity codec's image, so one field's namespace or path
cannot become another field's boundary. Re-encoding must reproduce the observed key; payload/key or
noncanonical-suffix disagreement refuses recovery, including rows already marked closed.

Production transaction targets check that same canonical project encoding: the mode key names the
project, the lease joins its project and run with `recordTupleSeparator`, and the reverse-root intent
retains its fixed `.production` suffix. Exact expectations and payload checks still bind all targets to
one project generation; historical or mixed-identity keys cannot authorize completion.

Project/run-derived keys and project-wide liveness names share this codec. Durable run identities admit
only bounded ASCII letters, digits and hyphen. Invalid or expanded-overlong addresses refuse before
coordinator recovery or durable effects. Fixed lowercase keys, cryptographic digest components and
already serialized RecordKey fields are not encoded again. The protected store's `hbps2` identity
envelope admits the current key epoch before any records are read; incompatible historical rows stay
untouched rather than being probed under an ambiguous old-key fallback. The
[ownership invariant](ownership_invariant.md) owns the storage, encoding and flush contract.

Reverse-journal and cursor helpers retain the enclosing scope, plan, broker generation, and result type
across GADT branches. Explicit local result signatures make those index relationships compiler-independent.
The reverse-root intent codec likewise fixes its field-list, unsigned-integer, and reverse-verb guard result
types so compiler inference does not affect the canonical record format.
Reverse-entry refusal helpers explicitly retain their `IO` effect and the enclosing descent-work and result
indices before a branch refines the lifecycle verb.

The private root intent records Pending, Committed, and Terminal Down/Destroy states. Preparing a reverse
entry binds the exact source plan, snapshot, target epoch, and verb. Repeated entry resumes those coordinates;
it cannot create a second plan beside the recorded one. The intent row moves through these states:

- **First reverse verb.** A Down or a Destroy entered from the source lineage writes Pending, Committed, and
  Terminal at record versions 1, 2, and 3 of the row.
- **Down-to-Destroy continuation.** After settled Down, the exact terminal receipt may admit a following
  Destroy. The continuation verifies the current mode and lease, unchanged snapshot and source records, and
  closed sessions, then advances the same protected row from version 3 to Destroy Pending, Committed, and
  Terminal at versions 4, 5, and 6. It retains the original acquisition evidence and allocates a fresh Destroy
  broker generation without reopening a Down journal as Up.
- **Exact terminal retry.** A retry verifies the retained evidence and returns without effects. A Destroy
  retry additionally requires the closed lease, closed project journal, and absent Production mode.
- **Fresh Up.** After closure, a fresh Up rearms through the normal closed-lease path; it plays no part in
  Destroy retry. Its run-lease admission compare-and-deletes a version-3 or version-6 terminal row whose broker
  generation is strictly older than the new one, and refuses any other row as a reverse root in progress.
- **Reverse rearm.** A reverse verb that finds a terminal row still present after its new successful-Up
  evidence revalidates accepts only a version-3 terminal with matching project and store and a strictly newer
  broker generation, compare-and-deletes it, confirms absence by readback, and then writes the next Pending
  row. [Durable state](durable_state.md#the-reverse-root-terminal-row) holds the complete table.
- **Failed-Up unwind.** The unwind preserves the original failure while attempting the admitted reverse work
  and reporting any unsettled resources.

## Lifecycle profile authority

`ProductionMode` and `HarnessMode runId` are abstract empty type tags, with no term constructors.
The Harness run parameter is nominal. The private mode-wire sum carries the runtime branch; a successful
protected transition alone mints the opaque, three-role-nominal
`ProjectModeLease projectId mode brokerGeneration`. Its type retains the installed project, exact mode
and broker generation. A Harness acquisition generates a `RunId` inside a continuation; diagnostic run
text cannot reconstruct it. Root, mode, lease, snapshot, and profile evidence retain the exact installed
project, protected-store identity, and broker epoch.

The durable mode key is `mode.` followed by the encoded installed-project name. Production root
acquisition records `production<TAB><epoch>`, and a successful callback return does not itself release
that record. A second Production entry retains the mode and records its own observed broker epoch;
advancing the epoch and record version is legitimate. Harness acquisition contends on the same record,
including after the exclusive store entry has ended. Authorized lifecycle closure remains the separate
mode-release path.

A mode record that cannot be decoded is refused as `ModeMalformedRecord` naming its actual key.
Both public root openers refuse `not-a-mode` and a Harness wire whose run segment exceeds 48 characters
without entering their callbacks, preserving that mode record's bytes and version.

Run keys admit 1–48 ASCII letters, digits or hyphen; invocation close keys admit 1–64 ASCII letters,
digits, hyphen or dot. Diagnostic run text cannot mint a witness: the run parser and reifier remain
private. Durable field writers encode UTF-8, and readers decode it strictly without trimming the record
or any field. Invalid UTF-8 is a malformed record. Text allowed by a field's own grammar, including a
Unicode migration key, therefore reads back exactly rather than being narrowed through Char8.

Epochs and versions in these mode, lease, invocation and profile-slot fields accept only canonical
ASCII unsigned decimal within `Word64`. Empty text, more than 20 digits, signs, whitespace, parentheses,
hexadecimal forms, leading zeros other than `0`, and overflow are refused. The bounded integer parse
must reproduce the original field through `showWord`; each state retains its additional positivity
checks. Target-record refusal preserves that record's bytes and version.

On a settled store, Production root admission checks mode and lease eligibility after mandatory closure
recovery and operator verification, under the same exclusive protected entry. An absent mode or retained
Production mode is eligible; a live Harness mode is refused before lease classification. The lease may
be absent or exactly decoded as unbound. A closed lease is eligible only for Production Up; Down and
Destroy refuse it. Bound, frozen and migrated leases return their exact `ModeLeaseNotBindable` state,
and malformed bytes return `ModeMalformedRecord` naming the actual lease key.

These eligibility refusals precede fresh broker allocation, root/store binding and mode, lease or
profile writes. They enter no root callback and preserve the complete settled protected image,
including record versions and bytes. Preflight yields only a verdict; the admitted root continuation
still runs outside the entry. Mode eligibility is shared with mode acquisition, and the lease classifier
is shared with `recordUnboundLease`, retaining its exact compare-and-swap expectations.

Closed-Up admission keeps its existing mutation sequence: clear the invocation disposition and terminal
reverse-root intent, reopen the Production journal, then write the unbound lease and initialize its
profile slot. Mandatory recovery can itself write before preflight, and a failure during an admitted
rearm can follow earlier writes. The settled-store refusal guarantee supplies no rollback for either
path. Operator, mode and lease refusals keep that order; mode/lease faults now precede allocation or
authority-binding faults in a store with multiple corrupt records. This does not preserve every former
fault priority.

Fresh broker allocation advances the project's protected counter. Recovery instead reifies a recorded
positive generation only when it equals that existing allocation; it never advances or recreates the
counter. An absent or malformed counter refuses existing-bound recovery before either authority
continuation and preserves the protected records. The raw reifier remains private to the authority
kernel and its Mode recovery callers; neither public authority nor public Mode exports it.

Root admission checks an epoch's retained project and protected-store origin as well as its generation
word. Equal numbers from another store or another project in the same store do not match. Both root
kernels return `AuthorityEpochOriginMismatch` before the authority callback and preserve that store's
records on refusal.

`rootScopeAuthority` narrows an already admitted root to its established scope. Its retained project
name, store identity and epoch copy the corresponding root values; it neither selects another scope
nor allocates a generation. The project and store fields are both text, so their distinct mapping is
checked with real root/store values as well as the nominal-scope compile-fail proofs.

A project-wide `ProjectModeLease` is narrowed to one lifecycle scope before it authorizes anything. The
opaque, two-role-nominal `ActiveProjectMode scope brokerGeneration` retains the mode, project, store, and the
active `BrokerEpoch` (read back with `activeProjectModeEpoch`). Its only producers are `productionActiveMode`,
which accepts only a Production mode lease and yields `ActiveProjectMode (Production projectId)`, and
`harnessActiveMode`, which accepts only a Harness mode lease for one `runId` and yields
`ActiveProjectMode (Harness projectId runId)`. Neither changes the broker generation, so the narrowed
evidence names the same epoch as the lease it came from; profile admission checks its project, store, epoch,
and mode tag against the root scope and the unbound run lease.

`LifecycleProfile scope` is opaque and nominal in its scope, retaining the exact mode, project, store
and epoch of the consumed slot. Both profile openers compare the retained root, active-mode and unbound
origins before entering the store. Inside the exclusive entry, mandatory closure recovery precedes
ordinary reverse-root refusal. Store failures retain `AuthorityStoreFailure`; other ordinary refusals
retain their `modeErrorMessage` inside `AuthorityMalformedBinding`, including the specific durable
reverse-root-intent reason.

The shared consumer then reads the actual lease record. It must decode as unbound at the exact record
version retained by `UnboundRunLease`. A missing, malformed, bound, closed or re-versioned lease refuses
before reading or consuming the profile slot. This check has no absent-lease or Closed-Up allowance;
fresh-root admission has a different purpose.

Only then does the consumer check the available slot's epoch and lease version against the retained
evidence and compare-and-swap it to consumed. A second opener with the same still-unbound evidence receives
`AuthorityInvocationConsumed` and no second profile. The pure continuation is applied after the protected
entry; an IO action it returns is not executed by the opener. On a settled store, a lease refusal
preserves the original available-slot bytes and record version and the complete post-mutation image.
Mandatory recovery still precedes these checks and supplies no rollback guarantee.

Public snapshot persistence uses `persistCanonicalPlanSnapshot`. Its revision is explicit; the spec,
config and plan digests and canonical bytes come from the opaque `CanonicalPlanSnapshot` it consumes.
Persistence is byte-identically idempotent and refuses replacement. The protected record and
`VerifiedPlanSnapshot` retain config digest and canonical bytes as one optional material unit, so neither
can carry just one half. Public accessors preserve their existing projections and presentation.

The bounded magic-prefixed snapshot format has tags `0` for absent material and `1` for the complete pair.
Tag `0` remains readable for compatibility; tab-separated records are refused. Existing field and total
bounds, strict text decoding, positive revision, known tags and exact trailing-byte checks remain.
`inspectPlanSnapshot` returns a non-authorizing view, including both material projections. Generic
`verifyPlanSnapshot` scopes a decoded protected record; it does not independently authenticate an admitted
plan. Indexed snapshot admission performs the exact specification, config, bytes and plan-digest join.

Fresh lease binding compare-and-swaps one exact unbound version against its same-scope verified snapshot
and retains its digest indices and fresh-binding origin. Rebinding returns the exact bound-state conflict.
An unbound lease can already have a persisted snapshot while awaiting this transition. An existing bound
lease has a separate recovery admission; it does not enter the fresh-Up continuation.

Down projects `RetainResource` for the provider's `copy-source` node, so its durable share and guest
alias survive provider stop/restart. Destroy projects `ReleaseResource` for that node only after its
child subtree settles. Provider `StopFrame` and `DeleteFrame` remain the forest's frame-owner actions.

Production closure has two authorized branches:

- `authorizeProductionDestroy` joins the exact destroy root, matching bound lease, all-sessions-closed
  evidence, and complete `DestroySettled` proof into `ProductionClosureAuthorization`.
- `authorizeProductionPreEffect` verifies an exact unbound root whose run has no acquisition or effect
  record and whose sessions are closed. It cannot authorize release after an effect has begun.

`releaseProductionMode` consumes that authorization and independently rechecks the current store, project,
epoch, lease, mode, snapshot, journal, and sessions. Destroy finalization publishes the closed project journal,
terminal reverse intent, closed lease, and absent mode through one redo transaction. Pre-effect finalization
publishes the corresponding three-target transaction without inventing a reverse intent.

The mode deletion is last. Every target accepts only its exact predecessor or exact committed successor,
so interruption after any prefix is recoverable.

"One redo transaction" is logical, not physical, atomicity. The protected store publishes one record
atomically. [Lifecycle.Transaction](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs)
first publishes a `CoordinatorApplying` descriptor naming every target's expectation and successor, redoes
each target deterministically, then returns the coordinator to idle. Every authority-producing Session API
recovers an applying descriptor before it reads state, so a cooperating lifecycle caller never observes a
partial transition. A reader that bypasses that recovery — an inspector, an older binary, or a manual
repair — can observe the physical prefix an interruption left behind. Admission recovers pending finalization before granting new
authority. Exact terminal retry makes no additional version changes. A later fresh Up can reopen a closed
project journal through the guarded root kernel; stale closure evidence cannot release that new epoch.
The Production bracket attempts the verified pre-effect branch when its callback fails before binding.

**Plan-bound redo.** Before recovery writes a target, `ensureTransactionCoordinator` compares an
Applying descriptor's plan with the requested plan. Disagreement returns
`TransactionMalformed "a descriptor names another coordinator"`, projected by Session as
`SessionRecordCorrupt` with that reason. Target ownership and the closed transaction kind's role order
are also validated before applying the descriptor.

Redo accepts a target's recorded predecessor expectation or its committed successor: ordinary targets
retain the descriptor's stamp and desired payload, while raw Production targets retain their exact
version/byte checks. A third state returns `TransactionTargetConflict key n`, where `n` is the actual
descriptor sequence, including in `applyProductionTarget`. Invalid-target and target-conflict details
reach the caller through `SessionTransactionFailure`. Application remains ordered and stops at the
first refusal; already applied earlier targets are not rolled back.

**Transaction wire admission.** Coordinator scalar fields use strict UTF-8; their unsigned numbers use
canonical ASCII decimal bounded to `Word64` through `Integer`, without signs, alternate bases,
parentheses, whitespace, leading zeros or wrap. Canonical Idle `0` remains valid, and existing
positive-stamp/version rules remain. `transaction-v1` and `hbtx-target-v1` retain their wire versions.

An accepted coordinator must reproduce every original byte through `encodeCoordinator`, including
line layout, field delimiters and hexadecimal spelling. A recognized stamped envelope must likewise
reproduce `stampTarget`, including its required newline. Scalar checks alone do not establish either
property: a coordinator's trailing line feed or valid uppercase hex can decode to the same values while
differing from the encoder. Desired payloads and exact expectations retain their hex transport; stamped and
legitimate unstamped target payloads remain opaque bytes, including FF and NUL. Transaction's scalar
canonicalization and opaque-payload handling are separate from the shared Prepared field transport.

Invalid UTF-8 coordinator text returns `TransactionMalformed "transaction text is not UTF-8"`; a noncanonical coordinator
or stamped envelope returns `TransactionMalformed "the coordinator record is not canonical"` or
`TransactionMalformed "a stamped target is not canonical"`, respectively. Existing missing/invalid
stamp-id refusals remain. Session explicitly maps `TransactionMalformed reason` to
`SessionRecordCorrupt reason`, while retaining the store, stale-permit and other transaction diagnostics.
An ordinary journal entry refuses malformed coordinator bytes before changing its targets.

The pure `decodeCoordinator` observer is forwarded beside `encodeCoordinator` through the existing
`Session.Testing` value vocabulary. It returns descriptive data, with no permit producer or transaction
runner. A decoded Unicode descriptor field is not an admitted Protected identity: the public session
name grammar remains ASCII. The private `lifecycle-transaction-internal` unit exposes only
`Session.Testing`; `Lifecycle.Transaction` is hidden in its `other-modules`. The main library retains
its own hidden Transaction copy. The facade's value vocabulary exposes no permit producer or runner.

Harness closure is run-specific. Its lease remains live throughout execution and settlement; the abandoned-run
sweep checks liveness again after recovery callbacks, attempts every incomplete run, and releases Harness mode
only when the complete set is closed. It never treats the reserved Production lease as an abandoned Harness run.

## Cross-process authority handoff

The root constructs and persists one recursive `RootedPlanCatalog` from the exact finalized specification.
Each edge retains the target plan, digest binding, canonical child configuration, payload digest, and
one-layer route. Catalog selection rechecks the exact parent/child relationship and projected node keys.

The receiver authenticates the root scope capsule using the independently installed identity and verification
key before interpreting the child package. Ordinary and recovery offers retain distinct exact bindings.
Recovery transports the complete canonical `RecoveryChildPackage`; an adapter alone is insufficient.
Intermediate links relay bytes and hold no root signing, journal, cursor, or storage authority.

A recovery edge keeps its handoff token in a durable map, because a token is 32 random bytes from
`freshHandoffToken` and cannot be recomputed from its binding. `registerRecoverableAdmittedHandoffEdgeKernel`
accepts only a Down or Destroy broker, the teardown phase, a recovery-adapter payload, and an adapter whose
digest matches the binding input. It keys one protected row `recovery-open.<digest>` by the digest of the
canonical opening identity (project, scope, store, broker generation, verb, verification-key digest, binding
input, and adapter), and that row's version-1 `hostbootstrap/recovery-open-record` bytes carry the identity, the
rendered binding, and the token:

| Observed state | Action |
|---|---|
| Map row absent | Mint a token, publish the row at version 1, and write the planned-edge token record |
| Map row present, planned-edge token record exact at version 1 | Reuse the stored binding and token; write nothing |
| Map row present, token record absent | Rewrite only the planned-edge token record from the retained binding |
| Map row present, token record already `granted:` | Never reuse it: mint a fresh token, write its planned-edge record first, then advance the map by one version by compare-and-swap |
| Any other token record, map version, or map bytes | Refuse without opening another edge |

Every path ends with a strict readback of the map at its version and of the token record; a token record that
is `granted:` at readback refuses with `HandoffTokenConsumed`. The map owns no process, child store, executor,
lifecycle settlement, or terminal receipt.

`OpenFrame` carries its ancestry in a sealed external envelope. The root admits only a catalog edge and
returns a signed `Opened` response naming the canonical path and root-issued session, stage, and ordinal.
Post-open requests bind path, session, nonce, ordinal, and predecessor digest; the inner path must equal both
the envelope and retained session path. Response families echo the request identity and carry only the
successor permitted by that request.

A storeless `FrameExecutor` compares a verified `Prepared` package with its independently rebuilt local node,
dependencies, own gate, and projected gates. Only this exact comparison can reify the local prepared gate.
The child executes the local effect and returns an observation. The root owns settlement, completion reports,
and receipt confirmation. A `Descend`, `Refused`, or mismatched response cannot enter the prepared branch.

The process owner derives every provider crossing through the shared Lift fold. It isolates descriptors,
bounds handshake/control frames, handles cancellation and process-group cleanup, and reaps the child.
An admitted backend effect may take as long as its own operation permits; a handshake deadline is not an
unconditional deadline over provisioning. See [binary context](binary_context_config.md) for wire and
activation details.

## Recovery and migration

Recovery opens the exact recorded scope and plan. Abandoned Harness run recovery opens it under a fresh broker
generation. Production recovery of an existing bound run, and convergence of a committed reverse-root
transition, instead reopen the recorded generation through the package-private
`withReifiedAllocatedBrokerEpochKernel`, whose only caller is `Lifecycle.Mode`: it yields a fresh-phantom
`BrokerEpoch` only for a nonzero recorded value equal to the installed project's current protected allocation
counter, never advances that counter, and refuses a zero, older, or future value and an absent or malformed
counter. A recorded number therefore reopens only the generation that is still allocated. Stable snapshots and
resource records are strictly decoded and rebound through verified evidence; serialized receipts and old
broker handles are not live authority. Rehydration verifies every member while the same protected store is
entered and yields an all-or-nothing set with separate owned and released cases.

Migration first constructs a prospective new plan from the scope-correct codec, wire, validated configuration,
and hidden non-empty drafts. It persists the canonical candidate snapshot before freezing the old revision.
The barrier binds the complete verified resource set and both plan digests. Activation requires the complete
settled set and exact current lease/snapshot lineage. Partial publication remains frozen and recoverable;
conflicting candidate bytes or incomplete membership never activate a mixed revision.

Completed migration recovery reads the candidate selected by its stable key. Local reconstruction must
reproduce every canonical byte before it receives the recovered profile and binding. Missing, malformed,
wrong-origin, or edited candidates retain the committed lease without granting ordinary execution authority.
The exact exported migration and recovery operations live in `Lifecycle.Mode`; `Lifecycle.Session` and
`Lifecycle.Transaction` own their journal and redo mechanics. Migration is Production-only. These brackets are
library operations with no command caller, and [Current Status](#current-status) records what does not yet reach
them.

## Neutral execution packages

Persisted and transported packages are bounded canonical data, not generative handles. Their decoders reject
unknown versions, trailing or truncated bytes, malformed lengths, duplicate members, and noncanonical numeric
coordinates. Cryptographic verification binds exact package bytes to the admitted scope and edge; local
reconstruction then checks their semantic correspondence to the plan.

## Runtime dependency commitments

Provider and cluster producers publish a canonical dependency package only after exact prepared Ready
settlement. It binds plan, frame, resource, backend origin, managed generation, operation journal lineage,
and the separate commitments of the pending producer gate and settled Ready call. It contains no strong
backend closure or managed handle.

The invocation-local registry begins empty in each carrier. Its fixed reprobe service accepts only the exact
package and nonce-bound fresh observation request, rechecks lifetime and generation, and returns canonical
observation data. Consumers open the package from their own execution descriptor and retain exact dependencies
through preparation. A cached generation number is never substituted for a fresh backend probe.

A package is opened in one of three ways, and each is written once with the domain as its argument. The
**full opener** checks every field the producer sealed, including the journal and receipt commitments. The
**coordinate check** checks the subset a fixed successor can see, leaving the opaque commitments bound by
the package commitment. The **carried coordinate check** is the same for a package that arrived from
another frame: it does not equate the producer's plan with the successor's projected plan, and it hands
back the backend origin the package carries rather than asserting one. Provider, provider-share and
cluster are arguments to these three, so a requirement added to a check applies to every domain rather
than to whichever one it was written in.

A prepared gate exposes its six coordinates through ordinary reader functions. A holder can inspect
its plan, operation, session, fence, attempt, and journal version without gaining a record field that
can replace one of them. Constructor opacity and one typed record-update fixture per reader hold the
boundary; the local mint's session checks and the public producer's limitation are described above.

**A prepared gate has one commitment.** Its six fields — plan, operation, session, fence, attempt and
journal version — are projected once, beside the gate itself, and committed by length-framing each field
and digesting the result with SHA-256. Framing rather than separator-joining is deliberate: a separator
that can occur inside a field admits two different gates with the same commitment, and neither the
operation key nor the session name is constrained to exclude one. The provider and cluster backends both
commit through that one function. Commitments are invocation-scoped — they travel in authenticated
handoff packages within a run and are never written to the protected store — so the construction is not
a durable format.

## Validation

Run `cabal test all` from `core/`. The evidence is divided by the boundary exercised:

| Suite | Contract exercised |
|---|---|
| `ProjectPlanSpec`, `SpecIndexSpec` | Exact plan/specification joins, projection and snapshot origins, hidden constructors and import boundaries |
| `AuthoritySpec`, `SessionSpec` | Root admission, durable Production mode retention, settled mode/lease refusal with whole-record-image preservation, journals and fences, closure proofs, exact retry, and every Production finalization prefix |
| `LifecycleSpec` | Refused fresh Up preserves the existing Open bound run's exact snapshot and epoch, and its read-only admission still enters the Open continuation once |
| `HarnessSpec` | Four real process attempts yield one authoritative Harness acquisition and three stated refusals |
| `HandoffSpec`, `RecursiveLifecycleSpec` | Canonical wire refusal, authenticated local process descent, root-owned settlement, and child-first reverse execution |
| `RecoveryInterruptionSpec` | Interruption and restart under exact durable state and declared host capability |
| `OwnershipSpec`, `OwnershipShippedSpec`, provider and cluster suites | Kernel identity, exclusion, origin publication, substitution refusal, and conditional release |
| `CompileFailSpec` | Nominal indices, constructor opacity, verb distinctions, and the closed service effect row |
| `CoverageManifest`, `DocValidatorSpec`, `EffectSpec` | Fixed platform accounting, documentation/plan harmony, and single effect/frame/path boundaries |

Journal version controls present one permit to session-open and project-close in both deterministic
orders. The stale-permit control closes the earlier session first, so an older-open refusal cannot mask
the stale-version check. These ordered controls do not establish simultaneous contention; real
protected-entry exclusion is separate evidence. Ten public compiler fixtures use newtype aliases to
hold each carrier's scope and plan role independently, and a positive compiler control preserves
`OperationAdvance`'s result coercion.

`CoerceVerifiedAllSessionsClosedScope.hs` and `CoerceVerifiedAllSessionsClosedPlan.hs` use independent
newtype aliases to target the observation's two nominal roles. Its existing abstract export pin is
separate evidence; these role probes do not claim the later constructor-forgery proof or runtime
plan/scope/store authentication.

The three existing namespaced-operation recovery cases retain complete operation identities under
plain, namespaced/path and mixed-case session identities. The foreign-owner manifest case requires
`SessionRecordCorrupt` with exact detail
`"operation ownership at op." <> planKeyDigest <> ".session-a...op-1"`; the three dots are the actual
session/operation tuple separator. A corruption refusal at another record cannot satisfy this assertion.

Complete-membership controls genuinely register `op-1`, check its canonical listed membership, and
delete the operation record against its actual physical version. After mutation, close and recovery
each require `SessionOperationUnregistered "op-1"`, unchanged protected images, and the listed session's
durable Open bytes and version. They read that session record directly: manifest verification may
itself refuse the missing member. Preservation baselines follow the checked deletion and do not imply
batch rollback. The existing "an abandoned session is closed and its continuable work counted" and
"a sweep with nothing open reports no work" cases check their setup through `runEntry` or
`expect =<< inEntry` before observing counts, so a refused setup cannot masquerade as an empty store.

Stamped Closing-journal inputs pin exact malformed-number refusal and unchanged seeded records, with
controls for `7`, the maximum `Word64` and a refused zero epoch. These cases exercise Session's
numeric grammar through journal admission; they do not independently execute fence or gate admission.

Prepared-field codec controls independently pin U+0100's UTF-8 bytes C4 80, decode literal bytes and
re-encode them unchanged, preserve ASCII whitespace and empty fields in the declared nonempty-list
domain, and require the failure sentinel for malformed UTF-8. Separate prepare requests containing a
tab, newline or U+0100 require the existing exact `SessionOutcomePhaseRefused`, no callback and unchanged
operation bytes, version and protected image. Those requests exercise the seven-phase whitelist;
their refusals do not prove UTF-8 transport or generic field validation by the legacy writer.

Recorded-operation controls use the genuine three-field registered intent for first-prepare attempt `1`
and recovery abandonment. Malformed eligible later records exercise missing, invalid and noncanonical
fence/attempt refusals in both paths, with exact corruption errors, no callback or abandonment write,
and unchanged post-setup operation/session images. Recovery refusal baselines follow genuine
fencing/manifest setup and corruption; they establish no batch rollback guarantee. Attempt-boundary
controls distinguish maximum exhaustion from the existing same-fence retry refusal, verify
maximum-minus-one prepares at maximum, and read back maximum unchanged after abandonment.

Transaction wire controls separate three observations. A pure descriptor-plan data round trip pins
U+0441's independent UTF-8 bytes D1 81, actual encoder bytes, the decoder's exact `Text` and complete
re-encoding. A public session-name request containing that character instead pins the existing exact
ASCII refusal and unchanged post-setup image. A genuine ASCII `TxnOpenSession` publication supplies a
separate AfterApplying recovery fixture with an absent new target; ordinary journal entry must recover
the exact single session key, captured payload/stamp and canonical Idle successor. The Unicode data
case asserts neither identity admission nor redo authority.

Canonical Idle/Applying and stamped/unstamped opaque-byte controls accompany strict UTF-8 and bounded
number refusals. Independent trailing-LF and uppercase-hex mutations hold complete-record admission.
An Idle sequence of `18446744073709551616` and a target stamp of `18446744073709551617` must refuse
without wrapping; the latter uses a reader that actually reaches the target. Refusal baselines follow
checked mutation/readback and require exact mapped errors and preserved target images. These controls
do not establish every redo fixture's reconstruction or live process-kill/provider behavior.

Separate redo controls reconstruct the durable state from a real transition's keys, roles, desired
payloads and sequence, restoring its exact pre-transition directory and physical versions. Before the
first `TxnOpenProject` snapshot, public `readProjectJournalState` must return
`SessionProjectMissing plan` and leave canonical `CoordinatorIdle 0` metadata. The snapshot follows
that real coordinator precondition, without creating a project or manufacturing a permit. Rebuilding
through state-advancing Session APIs would not preserve those original expectations.

The shared fixture retains twenty-five prefix cases across eight kinds: seven single-target families
with three cases each, and four cases for two-target `TxnRegisterIntent`. The shared
`faithfulDescriptorCase` makes twenty-six checks. It reads Applying before recovery and compares its
sequence, kind, target expectation and desired bytes with the uninterrupted capture.
`openProjectRecoveryCase` observes Open through `readProjectJournalState` before opening the journal,
then requires the exact uninterrupted committed successor version. Target counts are checked before
publication, and `AfterTarget n` requires `0 <= n <= count`; an invalid take cannot impersonate the
full prefix. These one/two-target counts apply to this matrix, not every transaction family.

Five descriptor controls cover another requested coordinator, an out-of-plan target, an invalid role
order, an ordinary third state and a Production third state. They require exact mapped refusals and
unchanged post-setup images. The Production conflict case first materializes its valid earlier
project-target prefix, then changes the lease's physical version while retaining its original bytes;
its baseline follows that prefix and mutation. The conflict must report the real sequence, not zero.
This is conflict evidence, not batch rollback.

Production carries no injected stop or per-target crash counter. `PortabilitySpec` checks the named
crash-point identifiers across shipped modules. The well-typed
`ForgeTransactionPermitFromDescriptor.hs` controls require testing-unit-only DATA compilation and the
ordinary public-only hidden-package refusal; despite its historical name, it checks the DATA import
boundary, not permit construction. In the same testing-unit-only environment,
`ImportTransactionRunnerFromTestingUnit.hs` must refuse because Transaction is a hidden module;
a hidden-package refusal would instead mean that control's setup failed. `SessionSpec`'s named-stanza
guard requires private visibility, only Testing exposed, Transaction hidden there and the main
library's hidden copy retained. These controls establish no live provider or killed-at-every-write evidence.

Live-admission controls distinguish the retained-session broker comparison from a changed durable
marker while keeping the original session, epoch and current permit. Malformed marker text pins the
exact corruption refusal. All seven prepare names have positive controls; committed or unrecognized
requests and pre-call or unresolved acknowledgement targets refuse without mutation. Separate cases
pin live-permit closed-session refusal, a fence superseded after preparation, and genuine wrong-plan
or wrong-session gates. The prepare callback reads exact unknown fields through its held
`ProtectedSession`, without opening a nested entry, before returning.

Adapter-fixture address controls observe the actual protected store and compare its sole key with an
independent raw-plan UTF-8 SHA-256 digest and literal encoded session/operation coordinates, including
the triple-dot tuple separator. Five rows vary plan, session and operation, covering namespaces, dots,
paths, case and underscores. Fresh writes require physical version `1`; a same-session, same-key
successor keeps fence `3`, advances the caller-selected attempt from `4` to `5`, and requires a checked
physical version `1` to `2` CAS. Only that journal version comes from the store; the fixture supplies the
other gate coordinates. Canonical-address fidelity neither authenticates them nor closes the low-level
producer gap, and it supplies no live cleanup evidence.

The explicit zero-dependency controls require successful unchanged-operation and managed force-destroy
preparation, exact wrong-plan/operation and positive-attempt checks, and direct refusal of edge-bearing
descriptors without delivering the continuation. A genuine dependency-bearing managed phase first
succeeds through generic preparation, then the same descriptor must refuse through the zero-phase
entry. These are the zero-edge and capability-preservation validation targets; they do not establish
fresh admission for the generic retained-set paths or live backend behavior.

The recorded-phase acknowledgement control uses the existing public `Prepared.recordDurableUnknown`
producer to write a committed record and mint its matching physical-version gate. Its exact category
refusal therefore cannot be satisfied by an old gate's stale-version error. This adversarial fixture
adds no producer and does not close the [separate producer gap](#current-status). Unknown future phases
needed by recovery tests are seeded directly as stamped records instead of being acknowledged as lawful
outcomes.

Ordered permit controls leave a committed operation and an Open session after preparation and
acknowledgement return P2. Closing with retained P1 refuses its exact stale version without changing
that state; closing with P2 produces P3 and a Closed session. Preparing with retained P2 then refuses
its stale version before the closed-session check and leaves the operation unchanged. These controls
establish permit exclusion in the declared orders, not a simultaneous race.

The phase matrix gives every one of the 45 names a literal expected disposition, with separate
unknown-text, alias and whitespace controls. A strict declaration reader checks the 43 producer rows
against `Reconcile.PersistedJournalPhase` and all 45 against private `RecordedPhase`; comments, strings
or another declaration cannot supply missing constructors. Unsupported or ambiguous declaration shapes
refuse the inventory. Source review separately checks enum-derived decoding and the seven explicit
unresolved arms, because equal public `UnknownDisposition` results cannot prove which private path ran.
These classification controls introduce no authority producer or recovery seam.

Fence resume controls seed the actual Intent/Outcome bytes, reopen the store and observe the same epoch
settled, independently of the caller's new proposal. Separate controls pin missing/unsettled refusals,
maximum-epoch preservation, unsettled completion followed by rotation, and a delayed prepare after
`fenceOldPermits`. Their setup must succeed before record or fence-set assertions run. These are
constructed interruption states, not evidence of a process killed at each fence write.

The existing executed competitor takes a token, releases its protected entry while the parent rotates,
then presents it in a second entry. It independently observes delayed-prepare refusal or deduplication
of an initial-fence proposal to the observed epoch. The same probe succeeds on an uncrossed boundary.
Those cross-process observations complement the seeded resume matrix; neither establishes live
provider behavior or uses a production fault-injection branch.

`CoerceFenceEpochScope.hs` and `CoerceFenceEpochPlan.hs` target the two nominal axes with newtype aliases.
`CoerceOldPermitsFencedScope.hs` and `CoerceOldPermitsFencedPlan.hs` target those same axes on the fence
set. The existing `ForgeFenceEpoch.hs` targets its actual single-field constructor. These compiler
boundary controls are distinct from protocol execution and supply no additional runtime plan
authentication.

Released-origin controls observe genuine public prepare/acknowledge/advance records, distinguish ordinary
`Released` from `AdoptionReleased`, and check acceptance plus exact joined membership. Stale same-content
versions, missing or changed records, wrong keys and equal-key/equal-version records in another store
exercise registration refusal without changing the post-setup image. `ForgeReleasedIntentOrigin.hs`
targets the actual private constructor through a child import; no backend-history proof follows from it.

Profile controls mutate a genuine lease through binding, a valid closed record or same-content CAS,
then check both public openers' exact refusal, zero callbacks and unchanged available slot and store
image. Pending and matching Terminal reverse-intent frames independently distinguish recognized
ordinary refusal from allowed profile admission; they establish neither reverse-lifecycle authority
nor execution. Same-evidence opener cohorts establish one success and one consumed-slot refusal,
not a simultaneous race. Cross-process exclusion is exercised separately at the protected-entry boundary.
The constructor-child import and newtype-scope-alias coercion fixtures independently hold profile
privacy and its nominal scope role.

Local compiled process fixtures establish native protocol and root-store behavior. They do not establish live
VM, container, cluster, or accelerator acceptance. Unsupported platform rows assert the actual declared refusal;
they are not silently skipped. [Testing](../engineering/testing.md) distinguishes these gates, and the owning
acceptance phases record the live host and substrate evidence.

## Related

- [Readiness](readiness.md), [ownership invariant](ownership_invariant.md), and [ownership seam](ownership_seam.md)
- [Composition methodology](composition_methodology.md), [durable state](durable_state.md), and [harness workflow](harness_workflow.md)
- [Recovery and migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md)
