# Readiness Witnesses and Legible Failure

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [lifecycle state model](lifecycle_state_model.md), [durable state](durable_state.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [hostbootstrap-core library](hostbootstrap_core_library.md), [testing](../engineering/testing.md), [WSL2](../engineering/wsl2.md), [Lima](../engineering/lima.md), [development plan standards](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Record what the readiness layer enforces today and distinguish the delivered
> [canonical quantities foundation](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
> from the prepared adapters and their live consumers.

## TL;DR

The readiness constructors are hidden by the export list of `HostBootstrap.Readiness`. The poll decision
is total over `ProbeResult` and bounded by an opaque `PollPolicy`; a probe that throws propagates its
exception (see [Probe discipline](#probe-discipline)). `Ready` is indexed by lifecycle scope, plan,
planned resource identity and family, and dependency, and retains generation, phase version, and
observation version as values. The provider boundary owns closed raw discovery and exact prepared
Incus/Direct readiness.

Readiness authority gates managed-resource effects: each passes through the prepared pair whose
preconditions the plan's dependency-snapshot traversal seals. Compatibility polling and `IO ()`
convenience actions are outside that boundary and mint no authority.

## Current Status

The [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
provides:

- opaque validated `Micros` and `PollPolicy` values, positive bounded attempt counts, overflow-safe total
  duration validation, named policies, and total `ProbeResult`/`PollError` polling;
- an opaque `Probe` and `Ready scope planId id resource dependency`, with no exposed
  `HostBootstrap.Readiness.Internal` module or test constructor;
- a closed `BackendProbeKey resource dependency` relation. Constructing a backend probe requires the
  exact `PlannedResource` from the finalized lifecycle plan; each `BackendReady` payload supplies
  generation, phase, and observation versions, which are checked before sealing readiness;
- resource families for provider, durable share, Docker, S3 store, registry, and cluster readiness;
- tests that obtain a real planned resource, drive the polling transition, reject invalid versions, and
  exercise compile-time opacity rather than injecting a forged witness; and
- `ObservedReady dependency` for compatibility call paths. This value is intentionally non-authorizing and is
  not accepted by plan-indexed reconciliation or budget-wall authority.

The lifecycle foundation also provides opaque planned resources and edges, exact operation/dependency
validation, matching prepared-operation/precondition pairs, phase-indexed handles, explicit adoption,
and a legal persisted-journal transition graph. This makes cross-plan and cross-resource use
unrepresentable at that boundary. Backend observation injection is Cabal-private; the public
dependency-probe wrapper remains a separate gap below.

The planned resource has one shared representation in the Cabal-private `plan-resource-internal` library;
`Lifecycle.Plan` retains validated-graph projection and the public facades retain the same opaque type.
The private readiness kernel shares that identity without depending on the main library or duplicating it. See
[plan and operation algebra](lifecycle_state_model.md#plan-and-operation-algebra) for the ownership boundary.

The [prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md) owns the
plan-owned dependency-snapshot traversal. An operation descriptor's edge set
is the exact ordered **resource-bearing** prefix of the validated plan — a step that owns no plan resource
has no managed handle to observe, so it contributes no edge. The sealed `OperationPreconditionSet` the
prepare consumes has two producers. `withOperationPreconditions` iterates that edge set, looks each member
up in the plan's `DependencySnapshot` of managed resources, and runs the member's registered
`DependencyProbe` at prepare time; its caller passes no observation list, so selecting, omitting, or
retaining a member is not expressible. `zeroDependencyPreconditions` is the second producer: it is public,
accepts only a descriptor whose edge list is empty, and refuses any descriptor that declares an edge.

The probe registered for a member is the `DependencyProbe` that the code calling
`withDependencySnapshotEntry` supplied. In production these are backend reprobes:
`runningProviderDependencyReprobe` for a running provider, `providerShareDependencyReprobe` and the
guest-alias share probe for a durable share, and `reprobeClusterReadiness` for a cluster. The
`Ready`-based path — `withBackendProbe`, `awaitPlanReady`, and `planDependencyProbe` — has no production
caller. `ReadinessSpec` exercises the complete indexed path, including dependency-snapshot traversal.
`awaitPlanReady` retains the versions from the backend's successful `BackendReady` payload and refuses a
zero generation, phase version, or observation version as `PollInvalidReady` with its specific
`ProbeVersionError`. `planDependencyProbe` compares that fresh report with the managed handle's generation
and observation version before sealing preconditions. `Ready` declares its identity indices nominal; the
public `Probe` synonym inherits its six nominal identity roles from the private kernel. `coerce` cannot
substitute another plan.

The exact boundary owned by the
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
implements that model: preparation accepts only an opaque backend-minted
`RunningProviderDependency`,
reruns its retained real provider probe inside `withOperationPreconditions`, and offers cluster readiness
only after identity-checked application of the plan-retained cordon. Its read-only backend probe checks the
exact durable owner and self-bound managed record, re-observes the complete retained node-name/container-ID
map, checks the cluster API, requires the Kubernetes node-name set to equal the exact declared set, and checks
every node's Ready condition. The opaque readiness value retains the backend-bound function that performs
that real probe again; it never turns a cached generation into a fresh observation. Only a successful
same-identity probe atomically advances the phase-observation version, and version exhaustion is a structural
failure rather than wraparound. A different control-plane or worker container identity is a `Conflict`, not
a retryable not-ready result; a same-identity API/node health failure remains retryable not-ready. Public
callers cannot construct the dependency, backend call results, managed cluster, prepared/applied cordon, or
readiness authorities, and the injected interpreter exists only in the Cabal-private test component. The
[cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) closes this source boundary plus its
focused, full-static, and independent linux-cpu gates. The recursive coordinator and worked demo consume
these boundaries for provider, share, cluster, chart, exposure, and alias work.

Compatibility polling and `IO ()` convenience actions remain descriptive: they do not produce a `Ready`,
managed receipt, or prepared-operation authority. The demo's `changed` wrapper reports successful return,
not an idempotence observation. Exact destructive operations still require their managed adapter's receipt.
`LifecycleFailure` carries one rendered reason string (`lifecycleFailureReason`). Its `Show` form prefixes
`lifecycleFailureMarker`, so a parent runner finds the reason in a child's stderr and re-raises it across
the self-reference subprocess boundary; the facts [Legible failure](#legible-failure) lists travel as text
in that reason, not as fields a caller can match on. The detached daemon launcher also retains both output
streams so a startup failure can quote its actual cause.

`withBackendProbe` and `observeBackendProbe` live in
[`Readiness.Kernel`](../../core/hostbootstrap-core/internal/readiness/HostBootstrap/Readiness/Kernel.hs),
inside the Cabal-private `readiness-internal` library. The main library and its test component can reach
that factory; downstream consumers cannot import the kernel or name the injector through the public
facade. Holding a `PlannedResource` and a constant `ProbeReady` therefore provides no public route to a
`Probe` or `Ready`.

The public `dependencyProbe` wrapper is a separate gap owned by the
[cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md): its callers live
in provider and cluster modules, and that phase owes backend-only construction and the exact readiness
kind required by each edge. Constructor opacity, nominal roles, and the three independently pinned
`RawReadiness` diagnostics already protect the boundaries they test.
Dated validation belongs in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Readiness contract

The canonical target algebra and validation gates live in
[lifecycle_state_model](lifecycle_state_model.md). For readiness specifically:

The owning module is
[`Readiness`](../../core/hostbootstrap-core/src/HostBootstrap/Readiness.hs). It is the signature
reference; this document describes its contracts without maintaining a second set of illustrative
signatures that can drift from the compiled API.

| Boundary | What it owns |
|---|---|
| `PollPolicy`, `PollPolicyError` | The opaque bounded retry policy. `mkPollPolicy :: Natural -> Micros -> Either PollPolicyError PollPolicy` refuses zero attempts (`ZeroAttempts`), more than 1,000,000 attempts (`AttemptsTooLarge`), a total duration that overflows (`TotalDurationOverflow`), and a total duration above 24 hours (`TotalDurationTooLarge`) before polling begins; `withAttempts` re-derives one from an existing policy |
| `pollAttempts`, `pollDelay`, `pollSchedule` | Read a policy back: its attempt count, its delay, and the list of delays between attempts (the provider share wait drives `pollSchedule` directly) |
| `Micros`, `seconds`, `microsValue` | The one delay quantity, so a bare number is never a duration; `seconds` refuses a negative (`NegativeDelay`) or overflowing (`DelayOverflow`) value |
| `rolloutPoll`, `pushPoll`, `reachPoll`, `vmBootPoll`, `networkPoll`, `dockerPoll`, `nodePoll` | The reviewed constant policies a caller selects instead of inventing constants; their construction has no partial error branch |
| `ProbeResult a` | The total observation: `ProbeReady a`, `NotReady` (a reason), `Unavailable` (a reason), `ProbeConflicted ProbeConflict`, `Failed ProbeFailure`. Only `ProbeReady` is readiness |
| `ProbeConflict`, `ProbeFailure` | Structured conflict (expected, observed, remedy) and terminal failure (operation, cause) |
| `PollError`, `renderPollError` | `PollTimeout`, `PollUnavailable`, `PollConflict`, `PollFailed`, and `PollInvalidReady` retain the poll label and cause; the last carries a typed invalid backend-version report |
| `Decision a`, `pollStep` | `Yield` / `Retry` / `GiveUp`; scripted tests drive the same `pollUntilReadyWith` loop as production |
| `pollUntilReady`, `pollUntilReadyWith` | The effectful loop over a `HostConfig -> IO (ProbeResult a)` probe |
| `ObservedReady`, `awaitObservedReady`, `awaitObservedReadyWith` | The non-authorizing compatibility observation, which mints no readiness evidence |
| `BackendProbeKey` | The closed resource/dependency relation: eight keys, each fixing which dependency evidence a probe of one resource family can mint. The key carries no plan index; the plan indices come from the `PlannedResource` given to `withBackendProbe` |
| `Probe`, `BackendReady`, `ProbeVersionError` | The public host-config-specialized probe type, raw backend report, and version refusals. `BackendReady` reports three observed versions and the backend payload. Awaiting refuses `ZeroProbeGeneration`, `ZeroProbePhaseVersion`, or `ZeroProbeObservationVersion` before constructing `Ready` |
| `withBackendProbe`, `observeBackendProbe` | Cabal-private kernel operations. The factory takes a key, the exact `PlannedResource`, and an observation function, then hands the `Probe` to a rank-2 continuation under a fresh probe index. The observer runs an existing probe with its supplied configuration |
| `Ready`, `readyGeneration`, `readyPhaseVersion`, `readyObservationVersion` | The plan-, resource-, and dependency-indexed readiness value and its three retained versions |
| `awaitPlanReady`, `awaitPlanReadyWith`, `planDependencyProbe` | Poll a `Probe` to a `Ready`, and wrap that poll as a `DependencyProbe` checked against a managed handle. No production code calls them (see [Current Status](#current-status)) |

`Ready`, version validation, and the one polling loop remain in `Readiness`. Its seven-parameter `Probe`
is a synonym for the private kernel's eight-parameter type, specialized to the existing `HostConfig`.
The kernel's six identity indices are nominal; its configuration and payload parameters are
representational. It stores the observation function without defining another configuration
representation or polling loop. The plan- and operation-indexed
types readiness feeds — `ResourceHandle`, `DependencyProbe`, `DependencySnapshot`,
`OperationDescriptor`, `OperationPreconditionSet`, `PreparedOperation`, and `PreparedPreconditions` — are
defined in [`Reconcile`](../../core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs); `PreparedGate`
comes from [`Lifecycle.Prepared`](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs),
and `OperationAdvance` from
[`Lifecycle.Session`](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs). Their opacity
contract is described in [lifecycle_state_model](lifecycle_state_model.md#opaque-capabilities).

- The `Ready`, `PollPolicy`, `Micros`, and `ObservedReady` constructors are hidden by the export list of
  `HostBootstrap.Readiness`. The public `Probe` synonym names the private kernel's abstract type; its
  constructor is hidden even from the kernel's consumers. Only the private factory introduces probes.
- Expected absence, a slow mount, and a stopped service are values. They do not escape through partial
  filesystem calls or a compound shell script.
- `NotReady` is bounded and retryable; `Unavailable`, `ProbeConflicted`, and `Failed` stop polling at
  once and remain distinct. `NotReady` and `Unavailable` carry one reason, `ProbeConflicted` carries the
  expected value, observed value, and remedy, and `Failed` carries the operation and cause. No constructor
  carries resource identity: the poll label that `pollStep` stores in every `PollError` names the
  resource, and the caller adds anything more.
- `PollPolicy` is opaque. `mkPollPolicy` requires 1 to 1,000,000 attempts and a validated `Micros` delay,
  computes the total duration (attempts minus one, times the delay) with overflow-safe arithmetic, and
  refuses a total above 24 hours before polling begins.
- `BackendProbeKey resource dependency` fixes which dependency evidence a probe of a resource family can
  mint, and `withBackendProbe` requires the exact `PlannedResource`, which fixes the plan indices; a
  caller cannot pick an unrelated dependency phantom for a key. The observation function is supplied by
  the backend or test component through the private factory. The separate public `dependencyProbe`
  wrapper still accepts a caller-supplied observation (see [Current Status](#current-status)). Only a
  managed dependency enters the authorizing path —
  `withDependencySnapshotEntry` requires a `Managed` handle — and a convenience probe of an unmanaged or
  foreign dependency yields only the non-authorizing `ObservedReady`.
- Every managed-resource effect declares its readiness requirements through an opaque
  `OperationDescriptor` that the admitted plan mints: `plannedProjectOperation` for an acquisition, and
  `plannedProjectPhaseOperation` for a later transition of a managed resource, after validating its
  ownership receipt and phase transition. The descriptor carries the plan digest, operation key, call
  digest, and the target's ordered resource-bearing dependency prefix read from the plan's own graph; no
  caller-supplied plan digest, frame, or dependency list enters it. Two classes are outside this rule and
  mint no authority: compatibility polling (`pollUntilReady`, `awaitObservedReady`) and `IO ()`
  convenience actions.
- `withOperationPreconditions` takes that descriptor and the plan's `DependencySnapshot`, runs each
  member's registered probe, and returns the `OperationPreconditionSet`. A member the snapshot lacks is a
  `Failure`, a member registered twice is a `Conflict`, and a probe's own error propagates. The caller
  cannot pass a retained witness, choose a member, or omit an edge. `zeroDependencyPreconditions` is the
  second, public producer and accepts only a descriptor with an empty edge list.
- `withPreparedOperation` consumes the descriptor, that set, and the `PreparedGate` that
  `recordDurableUnknown` produces after publishing the operation's unknown phase. It checks that the gate,
  set, and descriptor name the same plan, operation, and call digest, that the attempt and journal version
  are positive, that every sealed observation has a positive generation and phase version, and that the
  sealed dependency keys equal the descriptor's ordered list. Only then does it hand a rank-2
  continuation the matching `PreparedOperation`/`PreparedPreconditions` pair under fresh operation-key,
  call-digest, attempt, and journal-version indices. It is pure: the probes run once, in the traversal
  immediately before it. The backend adapter accepts that pair, not a separately retained `Ready`,
  handle, or prerequisite bundle; settlement of the effect is described in
  [lifecycle_state_model](lifecycle_state_model.md).
- A capability is tied to lifecycle scope, generative plan identity, and the identity/frame it proves,
  not merely to a phantom class of resources. Production and harness values—and two separate Production
  plans—cannot type-check together. The lifecycle capabilities hold this against `coerce` through nominal
  role annotations, and `Ready` and `Probe` retain the same protection on every identity index
  (see [Current Status](#current-status)).
- A sealed dependency observation records the managed handle's generation and the phase version its
  probe returned; it is a precondition-set input only. Freshness comes from running the probe inside the
  traversal at prepare time, not from comparing retained values. The cluster reprobe, for example, returns
  `Conflict` on a replaced container identity and a retryable failure on same-identity loss of readiness.
  Retaining an old Haskell value cannot bypass the traversal.

## Probe discipline

Guest probes remain simple observations. The Windows WSL route carries native argument vectors
through `--exec`; only an explicitly requested guest interpreter, such as `bash -lc`, parses command text.
One probe performs one observation, such as `test -e`, `docker info`, or `kubectl get`. Branching and
retry live in Haskell. A backend classifies expected observation failures as `ProbeResult` values. The poll loop catches
nothing: cancellation and programmer exceptions from either the observation or recovery propagate to
the caller. IO failures are classified at the backend boundary, as provider execution does.

Ownership is not a probe and does not travel this way. A clause is held by the row the frame declares, and
a transaction addressed to a frame is carried to a process of this same binary there — so exclusive entry
and identity binding are kernel calls made by that process, not commands whose output a caller parses (see
[ownership seam](ownership_seam.md)). That removes the question of which lock front end a guest happens to
have, and with it the possibility of two nominally supported front ends guarding one record with
non-interoperating locks.

A probe that reads a value out of a report admits only an exact report: extra lines, carriage returns,
unknown tags, and unexpected arity are failures rather than readiness evidence. A container identity, for
example, is admitted by `exactIdentityLine` only as one LF-terminated line of 64 lowercase hexadecimal
characters. A probe that reads no value is decided by exit status alone: provider discovery classifies each
of its probes by exit status, treats a zero exit as ready whatever the output, and reads text only to
classify a non-zero exit or a transport failure (see [Incus](../engineering/incus.md#provider-discovery) for the classification table).

Filesystem classifiers must establish existence before asking questions that are partial on absence.
`classifyAlias` is total over the `AliasFacts` a lane gathers (the symlink target, if any, and whether
the path exists):

```text
not present       -> AliasAbsent
symlink to target -> AliasLinkedCorrectly
symlink elsewhere -> AliasLinkedElsewhere observedTarget
other node        -> AliasOccupied AliasNodeKindUnknown
```

The classifier does not observe the kind of an occupying node, so it always reports
`AliasNodeKindUnknown`. A probe that cannot answer is not an alias state: the lane reports it as a
structured backend failure before any facts reach the classifier.

The direct and VM-shell lanes must return the same domain values even though their observation
mechanisms differ.

## Legible failure

The rendered cause of a lifecycle error must name:

- the operation and resource identity;
- whether the condition was transient, terminal, a conflict, or a timeout;
- captured child exit status and bounded output where applicable;
- the frame in which it occurred.

The self-reference handoff and test report card must carry and render that cause. `LifecycleFailure`
carries it as one reason string, so these facts are a rendering requirement on that text, not fields of a
type. A bare `ExitFailure 1` is an information-loss defect.

## Validation

Readiness is complete only when:

1. an external module cannot construct `Ready`, `PollPolicy`, `Micros`, or `Probe` directly;
   `CompileFailSpec` independently requires all three `RawReadiness` diagnostics and the explicit
   raw-probe construction rejection. A consumer cannot name `withBackendProbe` from the public
   facade or import its private kernel. Fresh probe identities cannot escape, a Docker key cannot
   select a cluster resource, and nominal roles reject plan re-indexing. Exact cluster preparation refuses a
   caller-built `DependencyProbe` (`CallerForgedClusterProbe`), and the guest alias refuses
   `ObservedReady` (`ObservedReadyGuestAlias`);
2. zero/negative attempts, delay/total-duration overflow, and over-limit policies fail construction;
3. every managed-resource effect requires the jointly produced, exact operation-key/call-digest/attempt/
   journal-indexed `PreparedOperation` and `PreparedPreconditions`; compatibility polling and `IO ()`
   convenience actions are exempt and mint no authority;
4. probe tables cover absence and unexpected IO errors without throwing;
5. wrong-resource, caller-selected-dependency, missing/wrong edge, stale retained `Ready`, wrong
   precondition-set/call digest/observation version, stale authority epoch, and cross-scope witnesses are
   rejected before a permit; dependency replacement between observation and prepare yields either a
   fresh prepared pair or no effect path;
6. live Windows and native-Linux gates report the original cause across handoff and teardown.

See [lifecycle_state_model](lifecycle_state_model.md) for the full ownership, reconciliation, and
recursive-teardown gates.
