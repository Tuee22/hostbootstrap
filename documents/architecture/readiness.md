# Readiness Witnesses and Legible Failure

**Status**: Authoritative source
**Supersedes**: the claim that the current `Ready` constructor is sealed and every mutation is gated
**Referenced by**: [documents index](../README.md), [lifecycle state model](lifecycle_state_model.md), [durable state](durable_state.md), [cluster lifecycle](../engineering/cluster_lifecycle.md)

> **Purpose**: Record what the readiness layer enforces today and define the opaque-capability and
> total-probe contract it must reach.

## TL;DR

Readiness polling exists, but its constructor is publicly importable, some mutations are ungated, and a
witness is not tied to one resource instance. The target hides constructors, indexes handles and
capabilities by the same generative identity, and represents every expected observation or failure as a
typed result.

## Current Status

The implementation provides `Probe`, `ProbeResult`, named polling policies, `awaitReady`, and a phantom
`Ready tag`. Several paths use them, including VM, Docker, registry, MinIO, and durable-share waits.

That is useful infrastructure, but the stronger architectural claims are not true today:

- `HostBootstrap.Readiness.Internal` exports `MkReady` and is listed as an exposed Cabal module.
  Downstream production code can therefore import it and forge `Ready tag`.
- Hiding only `MkReady` would not close the forge path. `Probe` is currently a public function alias,
  `ProbeReady` is public, and the result `Ready tag` leaves `tag` independent of the supplied probe. A
  caller can therefore provide an always-ready probe and choose whatever phantom tag it wants.
- `Micros(..)` and `PollPolicy(..)` expose raw constructors, seconds/attempt counts use ordinary `Int`,
  and the retry helper accepts an unvalidated attempt count. Zero/negative attempts and delay or total
  duration overflow are representable even though the named policies intend bounded polling.
- Gating is not universal. Some waits return `IO ()`, and mutating cluster, chart, NVIDIA, provider,
  staging, and teardown operations do not all consume the readiness they assume.
- A `Ready` value is phantom and does not carry a resource identity. Even honestly minted witnesses can
  be passed to an operation on a different instance of the same tag.
- Probe composition is not uniformly total. The direct-host alias classifier performs
  `pathIsSymbolicLink` before checking existence, so the clean `AliasAbsent` state raises an exception
  instead of producing a verdict.
- Several error paths still collapse subprocess context into `die`/`ExitFailure`; structured
  `LifecycleFailure` is not a universal boundary contract.

No current test establishes that illegal ordering is unrepresentable. Historical live-run counts and
phase status are intentionally not repeated here; see
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
One probe performs one observation, such as `test -e`, `readlink`, `docker info`, or `kubectl get`.
Branching and retry live in Haskell.

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
