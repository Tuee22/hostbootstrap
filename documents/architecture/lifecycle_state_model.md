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

`Ready` is plan/resource/dependency-indexed evidence from a closed backend probe. Polling is bounded and
classifies ready, retryable not-ready, failure, conflict, and unsupported behavior explicitly. A successful
probe must observe the exact managed generation and identity; a same-named replacement is a conflict.
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

Reverse-journal and cursor helpers retain the enclosing scope, plan, broker generation, and result type
across GADT branches. Explicit local result signatures make those index relationships compiler-independent.
The reverse-root intent codec likewise fixes its field-list, unsigned-integer, and reverse-verb guard result
types so compiler inference does not affect the canonical record format.
Reverse-entry refusal helpers explicitly retain their `IO` effect and the enclosing descent-work and result
indices before a branch refines the lifecycle verb.

The private root intent records Pending, Committed, and Terminal Down/Destroy states. Preparing a reverse
entry binds the exact source plan, snapshot, target epoch, and verb. Repeated entry resumes those coordinates;
it cannot create a second plan beside the recorded one. After settled Down, the exact terminal receipt may
admit a following Destroy. This continuation verifies the
current mode and lease, unchanged snapshot and source records, and closed sessions, then advances the same
protected row from version 3 to Destroy Pending/Committed/Terminal versions 4/5/6. It retains the original
acquisition evidence and allocates a fresh Destroy broker generation without reopening a Down journal as Up.
Exact terminal retries verify the retained evidence and return without effects. Destroy retry additionally
requires the closed lease, closed project journal, and absent Production mode; fresh Up uses the normal
closed-lease rearm path.
Failed-Up unwind preserves the original failure
while attempting the admitted reverse work and reporting any unsettled resources.

## Lifecycle profile authority

Production mode and Harness mode are distinct opaque tags. A Harness acquisition generates a `RunId` inside
a continuation; diagnostic run text cannot reconstruct it. Root, mode, lease, snapshot, and profile evidence
retain the exact installed project, protected-store identity, and broker epoch.

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
so interruption after any prefix is recoverable. Admission recovers pending finalization before granting new
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

Recovery opens the exact recorded scope and plan under a fresh broker generation. Stable snapshots and
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
`Lifecycle.Transaction` own their journal and redo mechanics.

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
