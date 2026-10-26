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
- `HarnessAuthority projectId runId` and `HarnessConfigAuthority projectId runId` declare no role, so their
  indices are phantom and `coerce` re-indexes a Harness witness to another project or run. The
  [Dhall configuration and project model
  phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md) owns this gap;
  [unrepresentable state](unrepresentable_state.md#current-status) lists both.
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

The admitted `ProjectPlan` derives its non-empty forward order, topology, stable snapshot, and verb-indexed
reverse projection from one representation. It rejects duplicate or missing keys, inconsistent edges,
non-contiguous frame segments, and invalid descent structure before execution. `withCurrentFrame` joins the
plan-derived topology to the descriptive binary context and generates matching frame evidence. Decoded
context fields alone grant no lifecycle authority.

An executing step receives `StepExecution`, containing its own operation identity and validated dependency
prefix. Its own and projected prepared gates come from the interpreter's journal admission. A step cannot
choose an unrelated plan operation or replace its dependency set with caller-supplied observations.
`withOperationPreconditions` traverses the complete resource-bearing prefix and runs each registered fresh
probe. A zero-dependency entry refuses a descriptor that actually declares dependencies.

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
`Ready` path has no production caller, and its generation and versions are fixed when the `Probe` is built, so
it does not stand for a fresh observation; [readiness](readiness.md#current-status) states the gap.
`ObservedReady` is descriptive compatibility evidence and is not accepted as plan-indexed authority.

Managed provider, share, cluster, and guest-alias wrappers retain their backend origin. The prepared adapter
consumes the matching gate, current handle, and fresh dependencies; settlement verifies that the returned
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

The resource carrier keeps canonical settlement bytes and their expected predecessor beside in-process
managed evidence. The root writes the exact resource member before acknowledging its operation journal.
Fresh publication requires absence; exact post-write retry converges; a phase or release transition requires
the byte-identical predecessor at the next version. Release retains a tombstone rather than erasing the
stable membership that recovery needs.

`VerifiedResourceRecordBundle` verifies one canonical member's plan, frame, resource, generation, operation,
record version, phase, adapter revision, and disposition. Owned and released members have disjoint folds.
`VerifiedResourceRecordSet` independently reads the protected namespace and compares complete, duplicate-free
membership against the bound snapshot. Missing, extra, malformed, or wrongly bound members refuse the set.

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

**Session admission.** `openOperationSession` opens one session against the live broker generation only when
the journal is Open, the caller's `ProjectPermit` is the current journal version, and no older session for the
plan is still Open, including one that registered no operation. Opening and closing a session each advance the
shared project-journal version and return its sole successor permit, so a session open and a close of the
project contend on one record version and exactly one wins.

**Prepare.** A prepare re-reads the journal under the exclusive protected entry, revalidates the broker
generation, session, project state, current fence, and recorded phase, durably records the operation-specific
Unknown phase before returning, and consumes the journal version it observed; that version cannot authorize a
second prepare or a close. Its gate is the one the interpreter's journal admission minted (see
[Current Status](#current-status) for the public producer that falls short of this).

**Settlement.** A terminal observation returns `OperationAdvance`, whose eliminator yields the adapter's result
only together with the sole successor permit. A delayed result cannot settle a newer attempt.

**Terminal acknowledgement.** `closeOperationSession` proves every operation the session registered has
settled before it compare-and-swaps the session record to Closed, so a close and a concurrent prepare have
exactly one winner. In the rooted path the root publishes the terminal receipt before it signs
`FrameComplete`, and returns `ReceiptRecorded` only after an idempotent `ReceiptConfirm` (see
[Cross-process authority handoff](#cross-process-authority-handoff)). A later teardown invocation receives a
fresh per-edge token and session.

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
is decoded as the operation identity. Namespaces, dotted tokens, and relation paths remain intact, and
re-encoding must reproduce the observed key. A payload/key disagreement refuses recovery.

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

Production mode and Harness mode are distinct opaque tags. A Harness acquisition generates a `RunId` inside
a continuation; diagnostic run text cannot reconstruct it. Root, mode, lease, snapshot, and profile evidence
retain the exact installed project, protected-store identity, and broker epoch.

A project-wide `ProjectModeLease` is narrowed to one lifecycle scope before it authorizes anything. The
opaque, two-role-nominal `ActiveProjectMode scope brokerGeneration` retains the mode, project, store, and the
active `BrokerEpoch` (read back with `activeProjectModeEpoch`). Its only producers are `productionActiveMode`,
which accepts only a Production mode lease and yields `ActiveProjectMode (Production projectId)`, and
`harnessActiveMode`, which accepts only a Harness mode lease for one `runId` and yields
`ActiveProjectMode (Harness projectId runId)`. Neither changes the broker generation, so the narrowed
evidence names the same epoch as the lease it came from; profile admission checks its project, store, epoch,
and mode tag against the root scope and the unbound run lease.

Fresh lease binding compare-and-swaps one exact unbound version against its verified snapshot. An existing
bound lease has a separate recovery admission; it does not enter the fresh-Up continuation. Profile admission
consumes its durable slot once, so retaining an ordinary Haskell value does not permit a second opening.

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
| `AuthoritySpec`, `SessionSpec` | Root admission, journals and fences, closure proofs, exact retry, and every Production finalization prefix |
| `HandoffSpec`, `RecursiveLifecycleSpec` | Canonical wire refusal, authenticated local process descent, root-owned settlement, and child-first reverse execution |
| `RecoveryInterruptionSpec` | Interruption and restart under exact durable state and declared host capability |
| `OwnershipSpec`, `OwnershipShippedSpec`, provider and cluster suites | Kernel identity, exclusion, origin publication, substitution refusal, and conditional release |
| `CompileFailSpec` | Nominal indices, constructor opacity, verb distinctions, and the closed service effect row |
| `CoverageManifest`, `DocValidatorSpec`, `EffectSpec` | Fixed platform accounting, documentation/plan harmony, and single effect/frame/path boundaries |

Local compiled process fixtures establish native protocol and root-store behavior. They do not establish live
VM, container, cluster, or accelerator acceptance. Unsupported platform rows assert the actual declared refusal;
they are not silently skipped. [Testing](../engineering/testing.md) distinguishes these gates, and the owning
acceptance phases record the live host and substrate evidence.

## Related

- [Readiness](readiness.md), [ownership invariant](ownership_invariant.md), and [ownership seam](ownership_seam.md)
- [Composition methodology](composition_methodology.md), [durable state](durable_state.md), and [harness workflow](harness_workflow.md)
- [Recovery and migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md)
