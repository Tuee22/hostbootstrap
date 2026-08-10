# Readiness Witnesses and Legible Failure

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [lifecycle state model](lifecycle_state_model.md), [durable state](durable_state.md), [cluster lifecycle](../engineering/cluster_lifecycle.md)

> **Purpose**: Record what the readiness layer enforces today and distinguish the delivered
> [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
> foundation from the downstream adapter integration still required.

## TL;DR

Readiness constructors are private. Polling is total and bounded, and authoritative evidence is indexed
by a generative lifecycle plan, exact planned resource family and identity, dependency, generation,
phase, and observation version. The provider boundary now owns closed raw discovery and exact prepared
Incus/Direct readiness; its static gate is closed and its native Linux/x86_64 KVM/Incus gate remains open.
Other live effects still
consume deliberately non-authorizing compatibility observations; the dependent interpreter phases must
migrate those effects before readiness gates every mutation.

## Current Status

The [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
provides:

- opaque validated `Micros` and `PollPolicy` values, positive bounded attempt counts, overflow-safe total
  duration validation, named policies, and total `ProbeResult`/`PollError` polling;
- an opaque `Probe` and `Ready scope planId id resource dependency`, with no exposed
  `HostBootstrap.Readiness.Internal` module or test constructor;
- a closed `BackendProbeKey resource dependency` relation. Constructing a backend probe requires the
  exact `PlannedResource` from the finalized lifecycle plan and positive generation, phase, and
  observation versions;
- resource families for provider, durable share, Docker, MinIO, registry, and cluster readiness;
- tests that obtain a real planned resource, drive the polling transition, reject invalid versions, and
  exercise compile-time opacity rather than injecting a forged witness; and
- `ObservedReady dependency` for compatibility call paths. This value is intentionally non-authorizing and is
  not accepted by plan-indexed reconciliation or budget-wall authority.

The lifecycle foundation also provides opaque planned resources and edges, exact operation/dependency
validation, matching prepared-operation/precondition pairs, phase-indexed handles, explicit adoption,
and a legal persisted-journal transition graph. This makes forged readiness and cross-plan/resource use
unrepresentable at the new boundary.

The [prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md) owns the
plan-owned dependency-snapshot traversal. An operation descriptor's edge set
is the exact ordered **resource-bearing** prefix of the validated plan — a step that owns no plan resource
has no managed handle to observe, so it contributes no edge — and the sealed `OperationPreconditionSet`
the prepare consumes has one producer, `withOperationPreconditions`, which iterates that edge set, looks
each member up in the plan's `DependencySnapshot` of managed resources, and runs the member's registered
probe at prepare time. A caller supplies no observation, so selecting, omitting, or retaining one is not
expressible; `zeroDependencyPreconditions` serves only descriptors that declare no edges and refuses any
that do. `planDependencyProbe` registers a probe rather than binding a retained `Ready`, and rechecks the
freshly observed generation and observation version against the managed handle on every run.

The repository does not yet enforce that boundary end to end:

- several provider, staging, cluster, chart, NVIDIA, and teardown effects still use compatibility waits
  or return `IO ()` rather than consuming a prepared operation. A chain step's action does now have every
  input the traversal needs, delivered by the
  [step-algebra phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md): the plan-minted
  `StepExecution scope planId` descriptor names its own operation key, frame, plan digest, and ordered
  edge set (§ U); `stepExecutionPreparedGate` and `stepExecutionTakeProjectedGate` reach the
  `PreparedGate` the interpreter opened for the node's own operation and for each operation the plan
  validated as a projection of it; `withCarriedManagedResource` reads back a dependency's `Managed` handle
  the acquiring node carried in process; and `withNodeResourceOfKind` / `withNodeObservedResource` /
  `plannedNodeOperation` name the planned resources the node may act on without handing it the plan. What
  remains is adoption: each effect that still returns `IO ()` has to be rewritten to consume a prepared
  operation and return a `ReconcileResult`;
- the Incus/Direct provider adapter now has identity-bound prepared calls, backend-indexed managed
  provider/share authority, and four-clause Incus recovery. Its discovery accepts only raw outcomes,
  parses strict one-line tool/identity/marker reports, polls only `NotReady`, and preserves structured
  provider conflict across the bound transport. The
  [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
  carries that boundary's static and native Linux/x86_64 KVM/Incus closure evidence, while the
  demo route remains work for the
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md);
- structured `LifecycleFailure` is not yet the universal subprocess boundary; and
- a failure that cannot reach a stream is not legible, whatever its type. The host-resident accelerator
  daemon therefore launches through the sealed `HostBootstrap.Detached` boundary (see
  [unrepresentable_state](unrepresentable_state.md)), which points both output streams at one retained sink
  and hands the launcher a reader for it, so a daemon that dies before readiness quotes its own cause.

Those are assigned integration obligations in the dependent provider/interpreter phases, not missing
constructor sealing in the
[canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md).
Live-run counts and phase status are intentionally not
repeated here; see
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Target contract

The canonical target algebra and validation gates live in
[lifecycle_state_model](lifecycle_state_model.md). For readiness specifically:

```haskell
data ResourceHandle scope planId id resource ownership phase
data ResourceAtFrame scope planId frame id resource
data Ready scope planId id resource dependency -- constructor private to the defining package
data Probe resource dependency   -- constructor private to the defining package
data PollPolicy                   -- constructor private to the defining package
data PositiveAttempts             -- constructor private to the defining package
data BoundedPollDelay             -- constructor private to the defining package

positiveAttempts :: Natural -> Either PollPolicyError PositiveAttempts
boundedPollDelay :: Natural -> Either PollPolicyError BoundedPollDelay
pollPolicy
  :: PositiveAttempts
  -> BoundedPollDelay
  -> Either PollPolicyError PollPolicy

data ProbeResult a
  = ProbeAbsent
  | ProbeObserved a
  | ProbeNotReady RetryReason
  | ProbeUnsupported UnsupportedReason
  | ProbeConflict ConflictReason
  | ProbeFailed FailureContext

awaitReady
  :: PollPolicy
  -> Probe resource dependency
  -> ResourceHandle scope planId id resource Managed phase
  -> IO (Either PollError (Ready scope planId id resource dependency))

data ReconcileMutation
  scope planId frame authorityEpoch verb phase operation operationKey
  targetId target dependencyId dependencyResource dependency to
data PhaseMutation
  scope planId frame authorityEpoch verb phase operation operationKey
  targetId target dependencyId dependencyResource dependency from to
data OperationDependencySnapshot
  scope planId frame id resource operation operationKey dependencySnapshotId
data OperationPreconditionSet
  scope planDigest planId frame id resource generation operation operationKey
  preconditionSetId backendCallDigest
data PreparedPreconditions
  scope planDigest planId frame id resource generation operation operationKey
  preconditionSetId backendCallDigest attemptId journalVersion
data PreparedOperation
  scope planDigest planId frame brokerGeneration sessionId authorityEpoch verb phase
  id resource generation operation operationKey
  preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
data OperationAdvance
  scope planDigest planId brokerGeneration activeRevisionVersion
  previousJournalVersion result

withOperationAdvance
  :: OperationAdvance ... previousJournalVersion result
  -> (forall nextJournalVersion.
        result
        -> ProjectOperationState scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority ... nextJournalVersion
        -> a)
  -> a
```

The full non-elided signatures and their sole producers live in
[Lifecycle state model](lifecycle_state_model.md#opaque-capabilities). This document
deliberately does not maintain a second copy of the operation-prepare algebra.

- The constructor module is an `other-module`, never an exposed module.
- Expected absence, a slow mount, and a stopped service are values. They do not escape through partial
  filesystem calls or a compound shell script.
- `ProbeNotReady` is bounded and retryable. Unsupported operation, structured conflict, and terminal
  failure remain distinct and retain operation, resource, and cause.
- `PollPolicy` is opaque. Its smart constructors require a positive attempt count and non-negative,
  bounded delay, compute the total duration with overflow-safe arithmetic, and reject every value outside
  the documented maximum before polling begins.
- `Probe resource dependency` fixes the evidence kind a successful observation can mint; a caller cannot
  choose an arbitrary result phantom or provide its own successful verdict. Probes are produced only by
  plan/backend modules after binding the concrete dependency relation. Only a managed dependency can enter authorizing `awaitReady`;
  probing an unmanaged/foreign dependency yields a non-authorizing observation instead.
- Every mutation declares its exact readiness requirements through a named transition or opaque
  reconcile/phase descriptor minted by `ProjectPlan scope specDigest planId configId cfg`, constructed only with
  `ValidatedConfig scope specDigest configId (cfg scope)`. The descriptor binds the exact command/phase/frame,
  target placement/identity/type, and dependency identity/type; a generic caller cannot pair unrelated
  resources, use a parent-frame authority for a child resource, or supply a config from another scope.
  The plan first produces an opaque `OperationDependencySnapshot` by internally traversing the
  descriptor's complete ordered edge set, looking up each managed dependency in the exact rehydrated
  resource set, and running the plan-owned probes. The caller cannot pass a retained witness, choose a
  member, or omit an edge. The rank-2 joint producer then consumes that snapshot, target/bindings,
  verified journal record, and backend call definition to create `OperationPreconditionSet` and
  `VerifiedBackendCall` under fresh shared `preconditionSetId`/`backendCallDigest` indices. Neither proof
  is a prerequisite for constructing the other; the plan-unique operation key already binds both back to
  the earlier descriptor. Its zero-dependency branch is private.
- Prepare consumes that closed set, reruns all probes and target/dependency identity checks, and obtains
  any authoritative conditional backend versions immediately before its journal compare-and-swap. Only
  success jointly yields matching `PreparedOperation` and `PreparedPreconditions` at the same
  operation/call-digest/attempt/journal indices. The actual backend effect requires both plus the matching
  descriptor, operation binding, or teardown step; it accepts no separately retained `Ready`, handle, or
  prerequisite bundle. Possession of `CommandAuthority`, a witness, a descriptor, either half of the
  pair, or a pair for another target/edge set/version cannot call it. Terminal observation returns
  `OperationAdvance` on both success and typed failure; its eliminator yields the result only with the
  sole fresh Open-project state/revision-permit pair.
- A capability is tied to lifecycle scope, generative plan identity, and the identity/frame it proves,
  not merely to a phantom class of resources. Production and harness values—and two separate Production
  plans—cannot type-check together.
- The opaque readiness capability retains backend generation, resource phase, and observation version,
  but is only a precondition-set input. Operation prepare revalidates those facts immediately before any
  prepared operation/effect and returns fresh evidence; replacement is a conflict and same-identity loss of
  readiness requires reprobe. A backend unable to condition the effect on the prepared version returns
  `Unsupported`; a post-prepare mismatch becomes a typed unknown/failure for total recovery. Retaining an
  old Haskell value cannot bypass either gate.

## Probe discipline

Guest probes should remain simple because the Windows path crosses PowerShell, `wsl`, and `bash -lc`.
One probe performs one observation, such as `test -e`, `readlink`, GNU/BSD `stat`, `docker info`, or
`kubectl get`. Branching and retry live in Haskell. The ownership primitives the guest lane needs —
`flock` for exclusive entry and `stat` for identity binding, per
[ownership_invariant](ownership_invariant.md) — are single trivial commands and meet this bar without a
compound shell. `lockf` may be retained as a descriptive discovery result, but it is `Unsupported` for
provider-guest alias authority because its common Linux `fcntl` namespace does not interoperate with
`flock(2)`. A successful tool, marker, identity, or backend report is exactly one LF-terminated stdout
line with empty stderr; extra lines, carriage returns, unknown tags, and unexpected arity are failures
rather than readiness evidence.

Filesystem classifiers must establish existence before asking questions that are partial on absence:

```text
not present       -> AliasAbsent
symlink to target -> AliasLinkedCorrectly
symlink elsewhere -> AliasLinkedElsewhere observedTarget
other node        -> AliasOccupied nodeKind
IO failure        -> ProbeFailed operation/path/cause
```

The direct and VM-shell lanes must return the same domain values even though their observation
mechanisms differ.

## Legible failure

A lifecycle error must retain:

- the operation and resource identity;
- whether the condition was transient, terminal, a conflict, or a timeout;
- captured child exit status and bounded output where applicable;
- the frame in which it occurred.

The self-reference handoff and test report card must render that structured cause. A bare
`ExitFailure 1` is an information-loss defect.

## Validation

Readiness is complete only when:

1. an external-package compile test cannot import `MkReady`, construct a `Probe`, or choose the
   successful probe's result tag;
2. zero/negative attempts, delay/total-duration overflow, and over-limit policies fail construction;
3. all mutating lifecycle APIs require the jointly produced, exact target/operation/precondition-set/
   call-digest/attempt/journal-indexed `PreparedOperation` and `PreparedPreconditions` and return the
   successor journal state/permit pair on success or typed failure;
4. probe tables cover absence and unexpected IO errors without throwing;
5. wrong-resource, caller-selected-dependency, missing/wrong edge, stale retained `Ready`, wrong
   precondition-set/call digest/observation version, stale authority epoch, and cross-scope witnesses are
   rejected before a permit; dependency replacement between observation and prepare yields either a
   fresh prepared pair or no effect path;
6. live Windows and native-Linux gates report the original cause across handoff and teardown.

See [lifecycle_state_model](lifecycle_state_model.md) for the full ownership, reconciliation, and
recursive-teardown gates.
