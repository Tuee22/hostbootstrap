# Lifecycle State Model

**Status**: Authoritative source
**Supersedes**: lifecycle-state claims embedded in provider and demo narratives
**Referenced by**: [documents index](../README.md), [readiness](readiness.md), [durable state](durable_state.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [harness workflow](harness_workflow.md)

> **Purpose**: Define the target lifecycle algebra that prevents forged readiness and cross-resource
> capability use by construction, while making ownership, operational races, and destructive actions
> explicit and checked. This page distinguishes that target from the current implementation;
> `DEVELOPMENT_PLAN/README.md` remains the status authority.

## TL;DR

The Phase 9 foundation now prevents forged readiness and cross-plan/resource capability mixing at its
new API boundary. It supplies total probes, opaque planned resources and edges, exact prepared-operation
pairs, explicit reconcile/adoption results, phase-indexed handles, and a legal journal transition graph.
Most live interpreters have not yet adopted that boundary, so end-to-end ordering, ownership-driven
teardown, profile selection, and identity-bound compare-before-mutate effects remain assigned
to their dependent phases. The ownership clauses those effects must hold are defined in
[ownership_invariant](ownership_invariant.md).

## Navigation and split decision

This page intentionally keeps the mutually indexed target algebra in one canonical, module-shaped
contract despite the documentation suite's roughly-300-line split-review threshold. Readiness,
ownership, teardown, session recovery, migration, and terminal closure share scope, plan, broker,
operation, and journal-version indices; splitting their signatures across separately governed pages
would make incompatible fragments easier to publish. The focused architecture and engineering pages
remain the skimmable explanations and link here for the complete contract. Revisit this decision when
the target API is implemented as independently compilable modules whose exported boundaries can replace
cross-page prose as the consistency check.

Use these sections as the index:

- [Current Status](#current-status) separates implemented behavior from this target.
- [Target algebra](#target-algebra) defines observations, results, resource identity, and readiness.
- [Lifecycle profile authority](#lifecycle-profile-authority) defines Production/Harness exclusion,
  abandoned-run recovery, and run leases.
- [Cross-process authority handoff](#cross-process-authority-handoff) defines stable snapshots,
  operation sessions and fences, and revision migration.
- [Validation](#validation) is the acceptance matrix for the complete contract.

## Current Status

The repository now implements the Phase 9 type-and-pure-validation foundation, but live interpreters do
not yet enforce the complete model end to end:

- `HostBootstrap.Readiness.Internal` has been removed. Opaque
  `Ready scope planId id resource dependency` values are produced only by closed backend probes bound to
  exact planned resources and positive observation versions. Compatibility paths receive only
  non-authorizing `ObservedReady`.
- `LifecyclePlan` is derived from the finalized project codec and `StepPlan`. Opaque planned resources
  and edges validate exact keys and dependencies; operation preparation validates the complete declared
  dependency list and pairs an opaque `PreparedOperation` with matching `PreparedPreconditions`.
- Neither half of the prepared pair is reachable from caller-supplied values any more. The plan-owned
  dependency-snapshot traversal seals the exact ordered edge set and runs each member's probe itself,
  and the attempt and journal version come from an unforgeable `PreparedGate`
  (`HostBootstrap.Lifecycle.Prepared`) whose sole producer performs the compare-and-swap that publishes
  the operation's durable unknown phase. The gate carries the plan digest and operation key it was
  recorded under, and preparation refuses one recorded elsewhere. What remains open is driving that
  sequence from the live lifecycle call sites rather than from adapter fixtures.
- Reconcile outcomes distinguish created, repaired, adopted, unchanged, and foreign observations.
  Explicit verified-origin adoption is the only way a foreign resource becomes managed. Named phase
  transitions produce indexed handles, and the persisted journal admits only legal acquisition,
  adoption, repair, and phase-transition edges.
- Several waits and effects still return `IO ()` or use non-authorizing compatibility observations.
  The downstream interpreter must own complete dependency traversal, fresh observation, journal
  compare-and-swap, and the exact prepared adapter call.
- The direct-host Docker handoff consumes a canonical host-root projection rather than the provider
  compatibility alias, but guest alias reconciliation still lacks the complete target
  identity-bound prepared operation.
- Most live reconcilers have not yet been migrated to the new result algebra, so teardown is not yet
  driven solely by verified ownership receipts.
- `project down` and `project destroy` inspect the current frame and then call a project teardown hook.
  They do not recursively hand the lifecycle verb through every child frame before unwinding.
- The demo test path generates a test config but currently resolves the cluster with the `Production`
  profile. It therefore uses `.data` and the production cluster identity rather than the intended
  `.test_data` and test-scoped identity.

These are open defects, not acceptable variations of the target model. Phase ordering and closure
criteria belong in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Target algebra

The target separates observation, reconciliation, readiness, use, and teardown:

```haskell
data ProbeResult a
  = ProbeAbsent
  | ProbeObserved a
  | ProbeNotReady RetryReason
  | ProbeUnsupported UnsupportedReason
  | ProbeConflict ConflictReason
  | ProbeFailed FailureContext

data Unclassified
data Managed
data Unmanaged

data ResourceHandle scope planId id resource ownership phase -- constructor hidden
data ResourceAtFrame scope planId frame id resource           -- constructor hidden

data ReconcileChange
  = Created
  | Repaired RepairDetails
  | Adopted AdoptionDetails

data CreatedEvidence scope planId id resource from to -- constructor hidden
data RepairedEvidence scope planId id resource from to -- constructor hidden
data AdoptedEvidence scope planId id resource from to  -- constructor hidden
data PriorCommitted scope planId id resource phase -- constructor hidden

data ManagedOutcome scope planId id resource from to where
  CreatedOutcome
    :: CreatedEvidence scope planId id resource from to
    -> ManagedOutcome scope planId id resource from to
  RepairedOutcome
    :: RepairedEvidence scope planId id resource from to
    -> RepairDetails
    -> ManagedOutcome scope planId id resource from to
  AdoptedOutcome
    :: AdoptedEvidence scope planId id resource from to
    -> AdoptionDetails
    -> ManagedOutcome scope planId id resource from to
  UnchangedOutcome
    :: PriorCommitted scope planId id resource target
    -> ManagedOutcome scope planId id resource Observed target

data ManagedTransition scope planId id resource from to = ManagedTransition
  { nextHandle :: ResourceHandle scope planId id resource Managed to
  , receipt :: OwnershipReceipt scope planId id resource
  , outcome :: ManagedOutcome scope planId id resource from to
  }
  -- constructor hidden; only operation-specific smart constructors are exported

data ManagedOutcomeView
  = Changed ReconcileChange
  | Unchanged

viewManagedOutcome
  :: ManagedOutcome scope planId id resource from to
  -> ManagedOutcomeView

data PhaseTransition scope planId id resource from to = PhaseTransition
  { phaseHandle :: ResourceHandle scope planId id resource Managed to
  , phaseReceipt :: OwnershipReceipt scope planId id resource
  }
  -- constructor hidden

data VerifiedAtPhase scope planId id resource phase = VerifiedAtPhase
  { verifiedPhaseHandle :: ResourceHandle scope planId id resource Managed phase
  , verifiedPhaseReceipt :: OwnershipReceipt scope planId id resource
  }
  -- constructor hidden

data Observation scope planId id resource
  -- constructor hidden; seals the observed backend generation/fingerprint, resource phase,
  -- monotonic journal/observation version, and backend facts used for classification

data VerifiedForeignOrigin
  scope planId id resource generation observationVersion
  -- constructor hidden; one bundle containing the exact Unmanaged handle and matching
  -- foreign Observation from the ForeignResult eliminator

data ReconcileResult scope planId id resource from to where
  ManagedResult
    :: ManagedTransition scope planId id resource from to
    -> ReconcileResult scope planId id resource from to
  ForeignResult
    :: ResourceHandle scope planId id resource Unmanaged to
    -> Observation scope planId id resource
    -> ReconcileResult scope planId id resource from to

data ReconcileError
  = Conflict ConflictReason
  | SafetyRefusal RefusalReason
  | Unsupported UnsupportedReason
  | Failure FailureContext RecoveryDisposition

data Ready scope planId id resource dependency   -- constructor unavailable outside its defining module
data OwnershipReceipt scope planId id resource   -- constructor unavailable outside its defining module
data AdoptionAuthority
  scope planId id resource generation observationVersion operationKey
  -- constructor unavailable outside its policy module; issued only for the matching
  -- VerifiedForeignOrigin
```

Reports may render these indexed branches as `Changed Created`, `Changed Repaired`, `Changed Adopted`,
and `Unchanged`, but callers cannot freely pair those labels with arbitrary phases. `CreatedOutcome` and
`RepairedOutcome` require exact plan/resource-indexed evidence. The `ForeignResult` eliminator jointly
binds its unmanaged handle and observation into
`VerifiedForeignOrigin scope planId id resource generation observationVersion`; policy can issue only the
matching `AdoptionAuthority` at those indices and the new adoption operation key. Creating
`AdoptedEvidence` requires both inside the hidden
policy/adoption path, but omission of those ordinary Haskell values from the result is only API
narrowing, not a claim of linear consumption. The protected, versioned adoption-intent
compare-and-swap makes a second use fail. `UnchangedOutcome` is possible only
from an unclassified `Observed` input with verified prior committed ownership at the exact target phase.
`viewManagedOutcome` exposes only the non-authorizing report label/details.

An effectful transition has the following shape:

```text
ResourceHandle scope planId id r Unclassified Observed
    │ reconcile
    ▼
Either ReconcileError (ReconcileResult scope planId id r Observed to)
    │
    ├─ ManagedResult (Changed Created) receipt ──► ResourceHandle scope planId id r Managed to
    ├─ ManagedResult (Changed Repaired) receipt ─► ResourceHandle scope planId id r Managed to
    ├─ ManagedResult Unchanged receipt ──────────► ResourceHandle scope planId id r Managed to
    └─ ForeignResult observation ────────────────► ResourceHandle scope planId id r Unmanaged to
                                                        │
        matching VerifiedForeignOrigin + AdoptionAuthority│ explicit adopt
                                                        ▼
                              ManagedResult (Changed Adopted) receipt

ResourceHandle scope planId id r Managed state
    + Probe r dependency
    ── total probe ──► ProbeResult (Ready scope planId id r dependency)

ResourceHandle scope planId id r Unmanaged state
    + Probe r dependency
    ── total observation ──► UnmanagedProbeObservation
                              (never Ready and never mutation authority)

Opaque plan transition descriptor + exact rehydrated resource set
    ── internal complete-edge traversal/probes ──► OperationDependencySnapshot
    ── joint seal ──► OperationPreconditionSet + VerifiedBackendCall
    ── protected re-probe/conditional prepare ──► PreparedOperation + PreparedPreconditions
    ── matching descriptor/binding/teardown step ──► authorized conditional mutation
```

The important properties are:

- Every state is named. Absence, transient unreadiness, terminal failure, collision, adoption, creation,
  repair, and no-op convergence are distinct values.
- Every probe is total over expected operating-system states. “Path does not exist” is a domain
  observation, not an exception. Unsupported operation, conflict, and unexpected IO failure are separate
  typed outcomes retaining operation and resource context.
- A probe fixes the kind of evidence it can mint: `Probe resource dependency` cannot return a
  caller-selected dependency. A mutation requires an opaque transition descriptor that binds its target
  resource identity to the exact dependency identity and kind it relies on. The compiler therefore
  rejects a registry push without `Ready RegistryServing`, an alias mutation without the related
  `Ready DurableShareMounted`, or a workload mutation without the related `Ready ClusterApi`.
- Every handle, readiness capability, receipt, transition descriptor, and plan retains the same
  `scope`. A production value cannot type-check in a harness transition even when its stable resource
  name happens to match.
- Every command-gated mutation also requires the plan-minted
  `ResourceAtFrame scope planId frame id resource` matching both the command authority's `frame` and the
  handle's resource identity. A parent-frame authority therefore cannot operate on a child-frame handle
  merely because both belong to the same plan.
- A destructive action requires an ownership receipt minted by an owned transition, or a fresh
  in-process receipt minted only after a persisted record is reloaded and verified. A foreign observation
  is not silently promoted to owned state.
- Re-running a reconciler returns `ManagedResult` with `Unchanged` when the verified persisted receipt
  matches, preserving the managed handle and ability to destroy later. An unowned resource returns
  `ForeignResult`, whose `Unmanaged` handle cannot type-check at a mutating or destructive entry point.
- A non-release phase-changing operation is not mislabeled as reconciliation. It returns a
  `PhaseTransition` whose `from`/`to` indices state the one legal change. Verifying that a resource is
  already at its target returns `VerifiedAtPhase` at that exact phase. Removal uses the separate
  ownership-release algebra below, so neither result can be confused with `Created`, `Repaired`,
  `Adopted`, or `Unchanged`.
- Adoption is a separate transition requiring opaque
  `AdoptionAuthority scope planId id resource`; ordinary
  reconciliation cannot silently turn `ForeignResult` into `ManagedResult`.
- Conflict, safety refusal, unsupported strong semantics, and operational failure are explicit error
  values, not overloaded success constructors or bare exceptions.

## Opaque capabilities

Capability constructors must be unavailable to consumers:

- the implementation module belongs under `other-modules`, not `exposed-modules`;
- the public module exports the type name but not its constructor;
- there is no `unsafeReady`, generic coercion helper, `Read` instance, or serialization instance;
- capabilities are parameterized by a **generative** resource identity shared with an opaque,
  plan-, scope-, ownership-, and phase-indexed
  `ResourceHandle scope planId id resource ownership state`, so a witness or ownership claim for one
  lifecycle plan, VM, cluster, registry, mount, or frame cannot type check against another. In
  particular, two Production plans do not share `planId`.

One realizable API shape scopes the in-process generative identity with a rank-2 continuation. The
locator is itself minted by the plan, so looking up a resource cannot introduce an unrelated
existential identity:

```haskell
data PlannedResourceLocator scope planId frame resource -- constructor hidden
data PlannedResource scope planId frame id resource      -- constructor hidden

withResource
  :: ProjectPlan scope specDigest planId configId cfg
  -> PlannedResourceLocator scope planId frame resource
  -> (forall id. PlannedResource scope planId frame id resource -> IO a)
  -> IO a

plannedHandle
  :: PlannedResource scope planId frame id resource
  -> ResourceHandle scope planId id resource Unclassified Observed

plannedPlacement
  :: PlannedResource scope planId frame id resource
  -> ResourceAtFrame scope planId frame id resource

plannedEdgeBetween
  :: ProjectPlan scope specDigest planId configId cfg
  -> PlannedResource scope planId targetFrame targetId target
  -> PlannedResource
       scope planId dependencyFrame dependencyId dependencyResource
  -> DependencySelector target dependencyResource dependency
  -> Either
       PlanError
       (PlannedEdge
          scope planId
          targetId target dependencyId dependencyResource dependency)

data PollPolicy                         -- constructor hidden
data PositiveAttempts                  -- constructor hidden
data BoundedPollDelay                  -- constructor hidden
data Probe resource dependency         -- constructor hidden; result kind fixed by the probe

positiveAttempts :: Natural -> Either PollPolicyError PositiveAttempts
boundedPollDelay :: Natural -> Either PollPolicyError BoundedPollDelay
pollPolicy
  :: PositiveAttempts
  -> BoundedPollDelay
  -> Either PollPolicyError PollPolicy

awaitReady
  :: PollPolicy
  -> Probe resource dependency
  -> ResourceHandle scope planId id resource Managed state
  -> IO (Either PollError (Ready scope planId id resource dependency))

observeDependency
  :: Probe resource dependency
  -> ResourceHandle scope planId id resource ownership state
  -> IO (ProbeResult (Observation scope planId id resource))

data ReconcileMutation
  scope planId frame authorityEpoch verb phase operation operationKey
  targetId target dependencyId dependencyResource dependency to
  -- constructor hidden
data PhaseMutation
  scope planId frame authorityEpoch verb phase operation operationKey
  targetId target dependencyId dependencyResource dependency from to
  -- constructor hidden
data PlanOperationDescriptor
  scope planId frame id resource operation operationKey
  -- constructor hidden; closed wrapper around the exact plan-minted reconcile, phase, or teardown step
data BackendCallDefinition resource operation
  -- constructor hidden; canonical conditional backend call and stable digest input
data OperationDependencySnapshot
  scope planId frame id resource operation operationKey dependencySnapshotId
  -- constructor hidden; exact heterogeneous zero/one/many dependency set selected by the descriptor
data OperationPreconditionSet
  scope planDigest planId frame id resource generation operation operationKey
  preconditionSetId backendCallDigest
  -- constructor hidden; exact plan-owned closed set, including the private zero-dependency branch
data PreparedPreconditions
  scope planDigest planId frame id resource generation operation operationKey
  preconditionSetId backendCallDigest attemptId journalVersion
  -- constructor hidden; contains only prepare-time fresh/conditionally bound observations
data PreparedOperation
  scope planDigest planId frame brokerGeneration sessionId authorityEpoch verb phase
  id resource generation operation operationKey
  preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -- constructor hidden
data OperationAdvance
  scope planDigest planId brokerGeneration activeRevisionVersion
  previousJournalVersion result
  -- constructor hidden

withOperationDependencySnapshot
  :: ProjectPlan scope specDigest planId configId cfg
  -> PlanOperationDescriptor
       scope planId frame id resource operation operationKey
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> (forall dependencySnapshotId.
        OperationDependencySnapshot
          scope planId frame id resource operation operationKey dependencySnapshotId
        -> a)
  -> IO (Either ReconcileError a)

withOperationPreconditionSet
  :: ProjectPlan scope specDigest planId configId cfg
  -> PlanOperationDescriptor
       scope planId frame id resource operation operationKey
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> VerifiedJournalRecord
       scope planDigest frameKey resourceKey generation operation operationKey
       expectedRecordVersion expectedPhase
  -> OperationDependencySnapshot
       scope planId frame id resource operation operationKey dependencySnapshotId
  -> BackendCallDefinition resource operation
  -> (forall preconditionSetId backendCallDigest.
        OperationPreconditionSet
          scope planDigest planId frame id resource generation operation operationKey
          preconditionSetId backendCallDigest
        -> VerifiedBackendCall
             scope planDigest planId frame id resource operation operationKey
             preconditionSetId backendCallDigest
        -> a)
  -> Either PlanError a

withOperationAdvance
  :: OperationAdvance
       scope planDigest planId brokerGeneration activeRevisionVersion
       previousJournalVersion result
  -> (forall nextJournalVersion.
        result
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> a

runReconcileMutation
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch verb phase
       targetId target generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame targetId target generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ReconcileMutation
       scope planId frame authorityEpoch verb phase operation operationKey
       targetId target dependencyId dependencyResource dependency to
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ReconcileResult scope planId targetId target Observed to)))

runPhaseMutation
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch verb phase
       targetId target generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame targetId target generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> PhaseMutation
       scope planId frame authorityEpoch verb phase operation operationKey
       targetId target dependencyId dependencyResource dependency from to
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (PhaseTransition scope planId targetId target from to)))
```

Only the validated `ProjectPlan scope specDigest planId configId cfg`, constructed from
`ValidatedConfig scope specDigest configId (cfg scope)` for scope-indexed config family `cfg`, can mint either
descriptor after proving the authority epoch, command/phase/frame, stable operation key, target
placement, and topology edge between `targetId`
and `dependencyId`; callers cannot choose the plan or resource phantom identities, substitute another
frame, or supply a different readiness kind. `withResource` yields each handle and exact placement in one
opaque `PlannedResource`; callers keep the required bundles in nested continuations, and
`plannedEdgeBetween` can mint an edge only between those exact already-open identities when the plan
contains that relation. Repeated calls against one open dependency therefore retain the same
`dependencyId`—the API can express a workload's API and GPU-plugin edges to one cluster, or any other
shared DAG node, without unsafe equality. A separately looked-up stable name cannot be asserted to have
the existential identity expected by a mutation.

The plan's `withOperationDependencySnapshot` is the sole producer of the opaque heterogeneous dependency
snapshot. It internally traverses the descriptor's complete plan-owned edge set, looks up each exact
managed dependency in the rehydrated resource set, runs the plan-owned probes, and captures fresh
observations with their versions. Callers cannot choose members, skip an edge, substitute a retained
`Ready`, or manufacture the private zero-dependency branch.
The same plan's rank-2 `withOperationPreconditionSet` is then the sole **joint** producer of
`OperationPreconditionSet` and `VerifiedBackendCall`. Its signature above consumes that snapshot, the
exact mutation/phase/teardown descriptor, target identity and operation bindings, matching verified
journal record, and backend call definition, then generates and seals the ordered zero/one/many
requirements under fresh `preconditionSetId` and `backendCallDigest` indices shared by both outputs.
Neither value must exist before the other, so there is no precondition/call-proof construction cycle.
The descriptor's plan-minted unique `operationKey` is already an input/index of the snapshot, set, and
both outputs, so the adapter can require the original binding without making the descriptor depend on
later preparation identities.
`prepareOperation` consumes this set, reruns every
probe, revalidates target and dependency generations/phases/observation versions, and obtains the
backend's conditional version/lease in the same protected preparation protocol. It returns
`PreparedPreconditions` and the matching `PreparedOperation` jointly at one attempt/journal version.
The prepared pair, not any caller-retained `Ready`, handle, or prerequisite bundle, enters the backend
adapter. A backend that cannot condition the call on the prepared dependency/target version returns
`Unsupported`; a post-prepare conditional mismatch is a typed unknown/failure that enters total
recovery, never an assumed-ready effect.

Reconciliation can return managed or foreign state from an unclassified handle; a managed phase change
has no foreign/adoption result. Named public transitions may hide the descriptors and preparation set,
but must preserve the same indexed relation. `PreparedOperation` retains the exact local resource
identity and kind, backend generation, operation/key, precondition-set/call digest,
session/fence/attempt, and prepared journal version. It is produced only inside the exact
`prepareOperation` continuation after its durable unknown-state transition. Every named adapter also
requires the jointly produced `PreparedPreconditions` and either the matching plan-minted mutation
descriptor, `OperationBinding`, or operation-indexed teardown step; a prepared operation or
precondition set for another resource, operation, edge set, call digest, attempt, or journal version
therefore cannot type-check. The backend adapter has no exported effect entry point that accepts only
`CommandAuthority`, a descriptor, a handle, `Ready`, or either half of the prepared pair. Each terminal
observation returns an opaque `OperationAdvance`; its eliminator jointly yields the result and one fresh
matching Open-project state/revision-permit pair, including on a typed effect failure. Thus an exception
branch cannot discard the only current journal version. The same rule applies to
`OwnershipReceipt`. Tests obtain capabilities through injected successful probes and reconcilers, not
by importing a constructor that production callers could also use.

Only a `Managed` handle can enter the authorizing `awaitReady` path. A foreign/unmanaged resource may be
inspected through `observeDependency`, but that returns an observation and cannot mint `Ready`; a
same-named foreign registry, mount, or daemon therefore cannot authorize a downstream mutation.
The opaque `Ready scope planId id resource dependency` also retains the verified backend generation,
resource phase, and journal observation version. Because an ordinary Haskell value can still be
retained, neither callers nor the effect adapter may supply it to operation preparation. The
plan-owned dependency-snapshot traversal reruns the exact probes and seals only its fresh observations
into `OperationPreconditionSet`; the operation-prepare gate compares those embedded facts, reruns the
same plan-owned probes, and returns a fresh `PreparedPreconditions` only immediately before it records/permits
the effect. A replacement is `Conflict`; a same-identity dependency that is no longer ready is
`Failure ... ReprobeBeforeRetry`. Neither branch receives a prepared-operation authorization or pair.

Pattern matching on `ForeignResult` through its eliminator yields an opaque
`VerifiedForeignOrigin` that jointly retains the unmanaged handle and exact observation facts. The public
API has no coercion from `Unmanaged` to `Managed`; the sole conversion is an explicit adoption function
requiring that origin and an `AdoptionAuthority` indexed by its generation and observation version. Thus
observation of a same-named resource, or authority for an earlier observation, cannot accidentally
authorize mutation or deletion.

Generative identities do not survive a process restart. Persisted data is an untrusted
`PersistedReceiptRecord`, not a serialized capability. A rehydration transition opens a new generative
scope, locks the persisted record, and checks stable resource identity, generation/fingerprint, and
current ownership through the resource backend. It may mint a fresh
`ResourceHandle scope planId id resource Managed phase` and
`OwnershipReceipt scope planId id resource` only inside a freshly revalidated plan continuation. A
missing, stale, wrong-plan, or mismatched record yields `Unmanaged` or a typed conflict; a backend that
cannot bind and re-observe the object's stable kernel identity yields `Unsupported`, not a race-free
claim. Persisted bytes cannot be decoded directly into `Managed`.

Ordinary Haskell values are also not linear: a caller can retain and reuse a handle or receipt value.
Phase indices and hidden constructors prevent construction and wrong-resource mixing, but they do not by
themselves prove single use or exclude external races. The interpreter must additionally serialize
transitions and journal the current generation/state. Excluding a non-cooperating external actor also
requires the four **Locked-Origin Identity Ownership** clauses — an OS-released exclusive lock held
across the bracket, a durable origin record written before the first mutation, binding to the object's
stable kernel identity rather than its pathname, and release conditioned on re-observing that exact
identity. Plain exclusive create/rename prevents an initial collision but does not make a pathname safe
from later replacement; compare-then-unlink without identity binding is still a race. A local sidecar,
content hash, or immediate compare substitutes for none of the four clauses. A backend that cannot hold
all four reports `Unsupported` and mints no receipt.

What the clauses buy is stated exactly: they exclude crash/retry and concurrent cooperating runs, and
they detect rather than silently overwrite foreign mutation. They do not exclude a hostile
same-privilege process, and no substrate in scope does. The target therefore avoids claims of
compile-time exactly-once effects or universal race-freedom. The canonical statement of the clauses and
their per-substrate realization is [ownership_invariant](ownership_invariant.md).

## Typed lifecycle transitions

The lifecycle interpreter should expose transitions instead of a bag of `IO ()` callbacks:

| Transition | Required input | Result |
|---|---|---|
| `ensureProvider` | exact prepared pair and matching plan-minted provider acquisition binding | managed transition or non-authorizing foreign result |
| `awaitNetwork` | managed booted provider handle | same-provider `ReadyTransition ... NetworkReady` |
| `ensureDurableShare` | exact prepared pair and matching plan-minted share acquisition binding | managed transition or non-authorizing foreign result |
| `awaitShare` | managed mounted-share handle | same-share `ReadyTransition ... ShareMounted` |
| `ensureAlias` | exact prepared pair and matching plan-minted alias acquisition binding | managed transition or non-authorizing foreign result |
| `createCluster` | exact prepared pair and matching plan-minted cluster acquisition binding | managed transition or non-authorizing foreign result |
| `awaitClusterApi` | managed nodes-ready cluster handle | same-cluster `ReadyTransition ... ApiReady` |
| `deployGpuWork` | exact prepared pair and matching plan-minted workload acquisition binding | managed transition or non-authorizing foreign result |
| `down` | exact prepared pair and matching operation-indexed teardown step | typed stopped/ephemeral-release/already-stopped result retaining the next ownership state |
| `destroy` | exact prepared pair and matching operation-indexed teardown step in child-to-parent order | typed release/already-released result; unowned absence is not success |

The recursive frame topology is part of the state. `down` and `destroy` descend while the child is
reachable, invoke the same verb in the child, and only then stop or remove the parent frame. `down`
preserves every durable root and provider frame. It may remove an **ephemeral** runtime object that has no
stopped state—currently the Kind cluster—provided the matching ownership receipt authorizes that exact
object. That exception returns `EphemeralRemoved`; it does not authorize deleting a provider VM, mounted
host data, or any other durable resource. A root-only hook that deletes a VM containing unvisited state
does not satisfy this contract.

The resource handles are ownership- and phase-indexed, so later operations cannot accept either an
unmanaged resource or an earlier lifecycle state. A managed transition returns the next managed handle,
its verified receipt, and its explicit reconcile outcome; a readiness-only transition preserves the
ownership parameter and returns the next handle with the capability it observed:

```haskell
data ReadyTransition
  scope planId id resource ownership dependency from to = ReadyTransition
  { readyHandle :: ResourceHandle scope planId id resource ownership to
  , evidence :: Ready scope planId id resource dependency
  }
  -- constructor hidden

data PlannedEdge
  scope planId targetId target dependencyId dependencyResource dependency
  -- constructor hidden

data GpuClusterReady scope planId clusterId -- constructor hidden
data Startable resource from -- constructor hidden, plan-owned

ensureProvider
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ReconcilePhase id Provider generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id Provider generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame id Provider AcquireOperation operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ReconcileResult scope planId id Provider Observed Allocated)))

adoptProvider
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ReconcilePhase id Provider generation AdoptOperation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id Provider generation AdoptOperation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame id Provider AdoptOperation operationKey
  -> VerifiedForeignOrigin
       scope planId id Provider generation observationVersion
  -> AdoptionAuthority
       scope planId id Provider generation observationVersion operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ManagedTransition scope planId id Provider Allocated Allocated)))

bootProvider
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ActivationPhase id Provider generation
       (PhaseOperation Provider from Booted) operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id Provider generation
       (PhaseOperation Provider from Booted) operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame id Provider
       (PhaseOperation Provider from Booted) operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (PhaseTransition scope planId id Provider from Booted)))
awaitNetwork
  :: PollPolicy
  -> ResourceHandle scope planId id Provider Managed Booted
  -> IO
       (Either
          PollError
          (ReadyTransition
             scope planId id Provider Managed Network Booted NetworkReady))

ensureDurableShare
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ReconcilePhase shareId DurableShare generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame shareId DurableShare generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame shareId DurableShare AcquireOperation operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ReconcileResult scope planId shareId DurableShare Observed Mounted)))

awaitShare
  :: PollPolicy
  -> ResourceHandle scope planId shareId DurableShare Managed Mounted
  -> IO
       (Either
          PollError
          (ReadyTransition
             scope planId shareId DurableShare Managed DurableShareMounted Mounted ShareMounted))

ensureAlias
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ReconcilePhase aliasId DurableAlias generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame aliasId DurableAlias generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame aliasId DurableAlias AcquireOperation operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ReconcileResult scope planId aliasId DurableAlias Observed AliasReady)))

awaitAlias
  :: PollPolicy
  -> ResourceHandle scope planId aliasId DurableAlias Managed AliasReady
  -> IO
       (Either
          PollError
          (Ready scope planId aliasId DurableAlias DurableAliasReady))

createCluster
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ReconcilePhase clusterId Cluster generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame clusterId Cluster generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame clusterId Cluster AcquireOperation operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ReconcileResult scope planId clusterId Cluster Observed Created)))
awaitNodes
  :: PollPolicy
  -> ResourceHandle scope planId clusterId Cluster Managed Created
  -> IO
       (Either
          PollError
          (ReadyTransition
             scope planId clusterId Cluster Managed Nodes Created NodesReady))

awaitClusterApi
  :: PollPolicy
  -> ResourceHandle scope planId clusterId Cluster Managed NodesReady
  -> IO
       (Either
          PollError
          (ReadyTransition
             scope planId clusterId Cluster Managed ClusterApi NodesReady ApiReady))

awaitGpuPlugin
  :: PollPolicy
  -> ResourceHandle scope planId clusterId Cluster Managed ApiReady
  -> IO
       (Either
          PollError
          (GpuClusterReady scope planId clusterId))
deployGpuWork
  :: PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectUp ReconcilePhase workloadId Workload generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame workloadId Workload generation AcquireOperation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> OperationBinding
       scope planDigest planId frame workloadId Workload AcquireOperation operationKey
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (Either
             ReconcileError
             (ReconcileResult scope planId workloadId Workload Observed Running)))
```

`awaitGpuPlugin` advances the cluster to `PluginReady`, then reprobes the still-required API at that new
phase. Its opaque `GpuClusterReady` contains the `PluginReady` managed handle and both
`Ready ... ClusterApi` and `Ready ... GpuPlugin` witnesses observed at the same backend generation,
phase, and journal version. It therefore does not reuse the stale API witness minted at `ApiReady`.

The CPU workload descriptor declares the API/registry/storage edge set without the GPU-plugin edge; the
GPU descriptor also declares the plugin edge. Callers do not construct prerequisite bundles. The
plan-owned dependency-snapshot traversal enumerates the descriptor's complete edge set, obtains every
managed handle and fresh observation internally, and cannot omit storage, registry, or plugin evidence
or borrow a same-scope dependency from another plan. The named effect adapters shown above accept only
the jointly returned `PreparedOperation`/`PreparedPreconditions` pair, exact operation binding, and
successor state/permit. A caller must pattern-match `ManagedResult` before it can obtain the managed handle
needed by the next mutation; the `ForeignResult` branch has no type-correct path forward except explicit
adoption. Every cross-resource mutation receives a
`PlannedEdge scope planId targetId target dependencyId dependencyResource dependency` minted by the exact
plan. Merely
sharing a lifecycle scope is insufficient: a share is tied to its provider, an alias to its share, a
cluster to its alias, and a workload to its cluster. Each same-resource transition retains both
generative identities. The interpreter's acquisition journal plus the identity-bound reservation,
not ordinary Haskell value linearity, rejects stale replay after the transition has committed.

Every reconciler starts from one `Unclassified Observed` handle. Its private total classifier then
produces exact evidence for absent/create, present-owned/unchanged, repairable-owned, compatible foreign,
or conflict; no public caller manufactures an `Absent` handle. This lets each ensure operation express
both `CreatedOutcome` and `UnchangedOutcome` while making an unchanged result for the wrong committed
target phase impossible.

Provider activation uses a plan-owned `Startable Provider from` relation: both newly `Allocated` and
previously owned `Stopped` providers may transition to `Booted`, while arbitrary phases cannot.
`UnchangedOutcome` never relabels a stopped provider as allocated. This is the durable-resource
down→up path.

Teardown has its own ownership-preserving result algebra:

```haskell
data ReleasedOwnership scope planId id resource -- constructor hidden

data ReleaseTransition scope planId id resource from = ReleaseTransition
  { releasedNow :: ReleasedOwnership scope planId id resource
  }
  -- constructor hidden

data TeardownVerb verb where
  DownVerb :: TeardownVerb ProjectDown
  DestroyVerb :: TeardownVerb ProjectDestroy
data MayStop verb where
  DownMayStop :: MayStop ProjectDown
  DestroyMayStop :: MayStop ProjectDestroy

data SettledChildren
  scope planId verb parentFrame childSet -- constructor hidden
data TeardownCursor
  scope planId verb parentFrame childSet next -- constructor hidden
data TeardownDescentStep
  scope planId verb frame childSet id operation operationKey next
  -- constructor hidden; the only inhabitant is a plan-derived
  -- ProjectDestroy/Provider/Stopped -> TeardownReachable step
data TeardownAuthorizationPoint scope planId verb frame childSet next where
  OrdinaryTeardownPoint
    :: SettledChildren scope planId verb frame childSet
    -> TeardownCursor scope planId verb frame childSet next
    -> TeardownAuthorizationPoint scope planId verb frame childSet next
  PreDescentTeardownPoint
    :: TeardownDescentStep
         scope planId verb frame childSet id operation operationKey next
    -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -- constructors are module-private; only the forest eliminator returns the sum
data TeardownStep
  scope planId frame childSet verb id resource phase operation operationKey next
  -- constructor hidden
data SomeTeardownStep scope planId verb frame childSet next where
  SomeTeardownStep
    :: TeardownStep
         scope planId frame childSet verb id resource phase operation operationKey next
    -> SomeTeardownStep scope planId verb frame childSet next
data TeardownPlan scope planId verb -- constructor hidden, pure plan projection
data TeardownForest scope planId verb -- constructor hidden
data CompletedTeardownForest scope planId verb -- constructor hidden
data TeardownAttempt result
  = TeardownSucceeded result
  | TeardownFailed TeardownFailure
data TeardownAdvance scope planId verb result = TeardownAdvance
  { teardownAttempt :: TeardownAttempt result
  , successorForest :: TeardownForest scope planId verb
  }
  -- constructor hidden
data Stoppable resource from -- constructor hidden, plan-owned
teardownPlan
  :: TeardownVerb verb
  -> LifecycleGraph scope planId
  -> AcquisitionJournal scope planId
  -> TeardownPlan scope planId verb

openTeardownForest
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> TeardownPlan scope planId verb
  -> (TeardownForest scope planId verb -> a)
  -> IO (Either TeardownError a)

withNextTeardownWork
  :: TeardownForest scope planId verb
  -> (CompletedTeardownForest scope planId verb -> a)
  -> (forall frame childSet next.
        TeardownAuthorizationPoint scope planId verb frame childSet next
        -> a)
  -> IO (Either TeardownError a)

withTeardownAuthorizationPoint
  :: TeardownAuthorizationPoint scope planId verb frame childSet next
  -> (forall id operation operationKey.
        TeardownDescentStep
          scope planId verb frame childSet id operation operationKey next
        -> a)
  -> (SettledChildren scope planId verb frame childSet
      -> TeardownCursor scope planId verb frame childSet next
      -> a)
  -> a

nextTeardownStep
  :: TeardownCursor scope planId verb frame childSet next
  -> SettledChildren scope planId verb frame childSet
  -> Either
       TeardownError
       (SomeTeardownStep scope planId verb frame childSet next)

stopDurable
  :: TeardownStep
       scope planId frame childSet verb id resource from operation operationKey next
  -> MayStop verb
  -> PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       verb TeardownPhase id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> Stoppable resource from
  -> ResourceAtFrame scope planId frame id resource
  -> ResourceHandle scope planId id resource Managed from
  -> OwnershipReceipt scope planId id resource
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (TeardownAdvance
             scope planId verb
             (PhaseTransition scope planId id resource from Stopped)))

confirmStopped
  :: TeardownStep
       scope planId frame childSet verb id resource Stopped operation operationKey next
  -> MayStop verb
  -> PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       verb TeardownPhase id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ResourceAtFrame scope planId frame id resource
  -> ResourceHandle scope planId id resource Managed Stopped
  -> OwnershipReceipt scope planId id resource
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (TeardownAdvance
             scope planId verb
             (VerifiedAtPhase scope planId id resource Stopped)))

resumeForDestroy
  :: TeardownDescentStep
       scope planId ProjectDestroy frame childSet
       id operation operationKey next
  -> PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectDestroy TeardownPhase id Provider generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id Provider generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ResourceAtFrame scope planId frame id Provider
  -> ResourceHandle scope planId id Provider Managed Stopped
  -> OwnershipReceipt scope planId id Provider
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (TeardownAdvance
             scope planId ProjectDestroy
             (PhaseTransition
                scope planId id Provider Stopped TeardownReachable)))

releaseEphemeralForDown
  :: TeardownStep
       scope planId frame childSet ProjectDown
       id resource phase operation operationKey next
  -> PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectDown TeardownPhase id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> EphemeralResource resource
  -> ResourceAtFrame scope planId frame id resource
  -> ResourceHandle scope planId id resource Managed phase
  -> OwnershipReceipt scope planId id resource
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (TeardownAdvance
             scope planId ProjectDown
             (ReleaseTransition scope planId id resource phase)))

destroyOwned
  :: TeardownStep
       scope planId frame childSet ProjectDestroy
       id resource phase operation operationKey next
  -> PreparedOperation
       scope planDigest planId frame brokerGeneration sessionId authorityEpoch
       ProjectDestroy TeardownPhase id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId fenceEpoch journalVersion
  -> PreparedPreconditions
       scope planDigest planId frame id resource generation operation operationKey
       preconditionSetId backendCallDigest attemptId journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ResourceAtFrame scope planId frame id resource
  -> ResourceHandle scope planId id resource Managed phase
  -> OwnershipReceipt scope planId id resource
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (TeardownAdvance
             scope planId ProjectDestroy
             (ReleaseTransition scope planId id resource phase)))

confirmReleased
  :: TeardownVerb verb
  -> TeardownStep
       scope planId frame childSet verb
       id resource phase operation operationKey next
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ResourceAtFrame scope planId frame id resource
  -> VerifiedReleaseRecord
       scope planDigest frameKey resourceKey generation operation operationKey releaseOrigin
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> IO
       (OperationAdvance
          scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
          (TeardownAdvance
             scope planId verb
             (ReleasedOwnership scope planId id resource)))
```

`confirmReleased` can be called only with a protected, verified ordinary or adoption release record and
matching fresh plan/resource/operation bindings; observing an unowned absent pathname/provider object
cannot produce that input. It is an internal exact-version forest/journal settlement and receives no
`PreparedOperation`/`PreparedPreconditions` pair or backend-call authority.

The durable root is preserved by both ordinary project verbs. Harness cleanup has a separate terminal
projection so `project destroy` cannot accidentally erase Production data, yet `.test_data/<runId>` is
not leaked:

```haskell
data OpenProject
data ClosingProject
data ClosedProject
data ProjectOperationState
  scope planId journalVersion state                       -- constructor hidden
data DestroySettled scope planId journalVersion           -- constructor hidden
data VerifiedNoProjectResourcesAcquired
  scope planId journalVersion                             -- constructor hidden
data ProjectClosureEvidence scope planId journalVersion   -- constructor hidden
data RetainingProductionVerb verb
  -- constructor hidden; closed witness for ProjectUp | ProjectDown only
data ProductionInvocationCompleted
  projectId specDigest planDigest planId brokerGeneration verb
  activeRevisionVersion journalVersion
  requiredSessionSet requiredOperationSet requiredResourceSet
                                                            -- constructor hidden
data ProductionInvocationCloseAdvance
  projectId specDigest planDigest planId brokerGeneration verb
  activeRevisionVersion journalVersion
  requiredSessionSet requiredOperationSet requiredResourceSet
                                                            -- constructor hidden; closed sum
data ProductionInvocationCloseUnknown
  projectId specDigest planDigest planId brokerGeneration verb
  activeRevisionVersion journalVersion closeId closeRecordVersion
                                                            -- constructor hidden
data ProductionInvocationClosed
  projectId specDigest planDigest planId brokerGeneration verb
  activeRevisionVersion retainedJournalVersion
  requiredResourceSet closeId closedLeaseVersion
                                                            -- constructor hidden
data HarnessCloseRoot projectId runId brokerGeneration   -- constructor hidden
data HarnessCloseAuthority
  projectId runId planId brokerGeneration closeEpoch     -- constructor hidden
data HarnessClosePlan
  projectId runId planId brokerGeneration closeEpoch     -- constructor hidden
data HarnessCloseJournal
  projectId runId planId brokerGeneration closeEpoch closeJournalVersion
                                                            -- constructor hidden
data HarnessCloseOperationResult operationKey               -- constructor hidden
data PreparedHarnessCloseOperation
  projectId runId planId brokerGeneration closeEpoch
  operationKey attemptId fenceEpoch preparedCloseJournalVersion
                                                            -- constructor hidden
data HarnessCloseAdvance
  projectId runId planId brokerGeneration closeEpoch
  previousCloseJournalVersion result
                                                            -- constructor hidden
data HarnessCloseOutcomesSettled
  projectId runId planId brokerGeneration closeEpoch closeJournalVersion
                                                            -- constructor hidden
data HarnessModeReleased
  projectId runId planDigest planId brokerGeneration closeEpoch closedProjectVersion
                                                            -- constructor hidden
data ProductionModeReleased
  projectId planDigest planId brokerGeneration closeEpoch -- constructor hidden
data ProductionClosureAuthorization
  projectId planDigest planId brokerGeneration journalVersion -- constructor hidden

verifyDestroySettled
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> LifecycleGraph scope planId
  -> CompletedTeardownForest scope planId ProjectDestroy
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> IO
       (Either
          TeardownError
          (DestroySettled scope planId journalVersion))

verifyNoProjectResourcesAcquired
  :: BoundRunLease scope specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> IO
       (Either
          TeardownError
          (VerifiedNoProjectResourcesAcquired
             scope planId journalVersion))

closeCompletedProductionInvocation
  :: RetainingProductionVerb verb
  -> ProductionInvocationCompleted
       projectId specDigest planDigest planId brokerGeneration verb
       activeRevisionVersion journalVersion
       requiredSessionSet requiredOperationSet requiredResourceSet
  -> ProjectModeLease projectId ProductionMode brokerGeneration
  -> BoundRunLease
       (Production projectId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> PlanDigestBinding
       (Production projectId) specDigest planDigest planId
  -> ActivePlanRevision
       (Production projectId) brokerGeneration planDigest activeRevisionVersion
  -> AcquisitionJournal (Production projectId) planId
  -> RehydratedResourceSet
       (Production projectId) planDigest planId brokerGeneration requiredResourceSet
  -> ProjectOperationState
       (Production projectId) planId journalVersion OpenProject
  -> RevisionPermitAuthority
       (Production projectId) planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> IO
       (ProductionInvocationCloseAdvance
          projectId specDigest planDigest planId brokerGeneration verb
          activeRevisionVersion journalVersion
          requiredSessionSet requiredOperationSet requiredResourceSet)

withProductionInvocationCloseAdvance
  :: ProductionInvocationCloseAdvance
       projectId specDigest planDigest planId brokerGeneration verb
       activeRevisionVersion journalVersion
       requiredSessionSet requiredOperationSet requiredResourceSet
  -> (forall retainedJournalVersion closeId closedLeaseVersion.
        ProductionInvocationClosed
          projectId specDigest planDigest planId brokerGeneration verb
          activeRevisionVersion retainedJournalVersion
          requiredResourceSet closeId closedLeaseVersion
        -> ProjectModeLease projectId ProductionMode brokerGeneration
        -> BoundPlanSnapshot
             (Production projectId) specDigest planDigest planId
        -> PlanDigestBinding
             (Production projectId) specDigest planDigest planId
        -> ActivePlanRevision
             (Production projectId) brokerGeneration planDigest activeRevisionVersion
        -> AcquisitionJournal (Production projectId) planId
        -> RehydratedResourceSet
             (Production projectId) planDigest planId brokerGeneration requiredResourceSet
        -> ProjectOperationState
             (Production projectId) planId retainedJournalVersion OpenProject
        -> a)
  -> (forall closeId closeRecordVersion.
        ProductionInvocationCloseUnknown
          projectId specDigest planDigest planId brokerGeneration verb
          activeRevisionVersion journalVersion closeId closeRecordVersion
        -> a)
  -> a

closureAfterDestroy
  :: DestroySettled scope planId journalVersion
  -> ProjectClosureEvidence scope planId journalVersion

closureBeforeFirstEffect
  :: VerifiedNoProjectResourcesAcquired scope planId journalVersion
  -> ProjectClosureEvidence scope planId journalVersion

authorizeProductionClosureAfterDestroy
  :: RootInvocationAuthority
       (Production projectId) brokerGeneration ProjectDestroy
  -> BoundRunLease
       (Production projectId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> DestroySettled
       (Production projectId) planId journalVersion
  -> ProductionClosureAuthorization
       projectId planDigest planId brokerGeneration journalVersion

authorizeProductionClosureBeforeFirstEffect
  :: RootInvocationAuthority
       (Production projectId) brokerGeneration verb
  -> BoundRunLease
       (Production projectId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> VerifiedNoProjectResourcesAcquired
       (Production projectId) planId journalVersion
  -> ProductionClosureAuthorization
       projectId planDigest planId brokerGeneration journalVersion

authorizeHarnessClose
  :: HarnessCloseRoot projectId runId brokerGeneration
  -> ProjectModeLease
       projectId (HarnessMode runId) brokerGeneration
  -> BoundRunLease
       (Harness projectId runId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Harness projectId runId) specDigest planDigest planId
  -> ProjectOperationState
       (Harness projectId runId) planId journalVersion OpenProject
  -> ProjectClosureEvidence
       (Harness projectId runId) planId journalVersion
  -> (forall closeEpoch closeJournalVersion.
        ProjectOperationState
          (Harness projectId runId) planId closeEpoch ClosingProject
        -> HarnessCloseAuthority
             projectId runId planId brokerGeneration closeEpoch
        -> HarnessCloseJournal
             projectId runId planId brokerGeneration closeEpoch closeJournalVersion
        -> a)
  -> IO (Either TeardownError a)

harnessClosePlan
  :: HarnessCloseAuthority projectId runId planId brokerGeneration closeEpoch
  -> ProjectOperationState
       (Harness projectId runId) planId closeEpoch ClosingProject
  -> LifecycleGraph (Harness projectId runId) planId
  -> AcquisitionJournal (Harness projectId runId) planId
  -> HarnessClosePlan projectId runId planId brokerGeneration closeEpoch

withPreparedHarnessCloseOperation
  :: ProjectModeLease
       projectId (HarnessMode runId) brokerGeneration
  -> BoundRunLease
       (Harness projectId runId) specDigest planDigest brokerGeneration
  -> ProjectOperationState
       (Harness projectId runId) planId closeEpoch ClosingProject
  -> HarnessCloseAuthority projectId runId planId brokerGeneration closeEpoch
  -> HarnessCloseJournal
       projectId runId planId brokerGeneration closeEpoch closeJournalVersion
  -> HarnessClosePlan projectId runId planId brokerGeneration closeEpoch
  -> (forall operationKey attemptId fenceEpoch preparedCloseJournalVersion.
        PreparedHarnessCloseOperation
          projectId runId planId brokerGeneration closeEpoch
          operationKey attemptId fenceEpoch preparedCloseJournalVersion
        -> HarnessCloseJournal
             projectId runId planId brokerGeneration closeEpoch
             preparedCloseJournalVersion
        -> IO a)
  -> IO (Either TeardownError a)

runPreparedHarnessCloseOperation
  :: PreparedHarnessCloseOperation
       projectId runId planId brokerGeneration closeEpoch
       operationKey attemptId fenceEpoch preparedCloseJournalVersion
  -> HarnessCloseJournal
       projectId runId planId brokerGeneration closeEpoch
       preparedCloseJournalVersion
  -> IO
       (HarnessCloseAdvance
          projectId runId planId brokerGeneration closeEpoch
          preparedCloseJournalVersion
          (Either
             TeardownError
             (HarnessCloseOperationResult operationKey)))

withHarnessCloseAdvance
  :: HarnessCloseAdvance
       projectId runId planId brokerGeneration closeEpoch
       previousCloseJournalVersion result
  -> (forall nextCloseJournalVersion.
        result
        -> HarnessCloseJournal
             projectId runId planId brokerGeneration closeEpoch
             nextCloseJournalVersion
        -> a)
  -> a

settleHarnessClose
  :: ProjectOperationState
       (Harness projectId runId) planId closeEpoch ClosingProject
  -> HarnessCloseAuthority projectId runId planId brokerGeneration closeEpoch
  -> HarnessCloseJournal
       projectId runId planId brokerGeneration closeEpoch closeJournalVersion
  -> HarnessClosePlan projectId runId planId brokerGeneration closeEpoch
  -> IO
       (Either
          TeardownError
          (HarnessCloseOutcomesSettled
             projectId runId planId brokerGeneration closeEpoch closeJournalVersion))

finalizeHarnessClose
  :: ProjectModeLease
       projectId (HarnessMode runId) brokerGeneration
  -> BoundRunLease
       (Harness projectId runId) specDigest planDigest brokerGeneration
  -> ProjectOperationState
       (Harness projectId runId) planId closeEpoch ClosingProject
  -> HarnessCloseAuthority projectId runId planId brokerGeneration closeEpoch
  -> HarnessCloseOutcomesSettled
       projectId runId planId brokerGeneration closeEpoch closeJournalVersion
  -> (forall closedProjectVersion.
        ProjectOperationState
          (Harness projectId runId) planId closedProjectVersion ClosedProject
        -> HarnessModeReleased
             projectId runId planDigest planId brokerGeneration
             closeEpoch closedProjectVersion
        -> a)
  -> IO (Either TeardownError a)

releaseProductionMode
  :: ProductionClosureAuthorization
       projectId planDigest planId brokerGeneration journalVersion
  -> ProjectModeLease projectId ProductionMode brokerGeneration
  -> BoundRunLease
       (Production projectId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> PlanDigestBinding
       (Production projectId) specDigest planDigest planId
  -> ProjectOperationState
       (Production projectId) planId journalVersion OpenProject
  -> (forall closeEpoch.
        ProjectOperationState
          (Production projectId) planId closeEpoch ClosedProject
        -> ProductionModeReleased
             projectId planDigest planId brokerGeneration closeEpoch
        -> a)
  -> IO (Either TeardownError a)
```

`teardownPlan` is the pure reverse projection of the same lifecycle graph/journal.
`openTeardownForest` is the only initial-forest producer: it binds that projection to the exact protected
snapshot, active revision, Open-project state, and revision-permit version before returning any work
authorization point.
`withNextTeardownWork` is the sole producer and exhaustive outer eliminator: it yields either
`CompletedTeardownForest` or one closed `TeardownAuthorizationPoint`. The module-private sum contains
either a destroy-indexed stopped-provider reachability step or the ordinary plan-derived
`SettledChildren`/cursor pair. Only `withTeardownAuthorizationPoint` can expose those two branches; callers
cannot wrap a cursor or descent step themselves. The terminal branch appears only when no unresolved or
failed node remains. Every effect returns the successor forest, which is fed back to that eliminator.

`verifyDestroySettled` is the only producer of `DestroySettled`. It checks the completed plan-derived
forest against the complete lifecycle graph and protected journal at the exact state/permit version;
every node must have a terminal release observation, no prepared operation may remain live, and every
independently enumerated operation session—including a zero-operation session—must be Closed.
`verifyNoProjectResourcesAcquired` is the only producer of its
proof and accepts only the exact bound snapshot/revision/state tuple whose protected journal contains no
resource operation, permit, fence, receipt, or backend-effect record and whose registered operation
sessions are all Closed and empty. A terminal empty session is evidence of orderly refusal, not a
resource acquisition; an Open or non-empty session refuses. This is therefore a true pre-effect refusal,
not an empty caller-supplied list. `closureAfterDestroy` and `closureBeforeFirstEffect` are the only
eliminators into `ProjectClosureEvidence`. Unresolved partial ownership produces neither branch, and all
three proofs retain the exact current journal/forest version.

Successful ordinary Production invocation closure is a different transition from project closure.
The private recursive interpreter is the sole producer of
`ProductionInvocationCompleted`, and only for the closed
`RetainingProductionVerb` cases `ProjectUp` and `ProjectDown`. Before persisting that terminal
acknowledgment it derives the independently complete session and operation sets from the protected
invocation record, proves every session (including a zero-operation session) Closed, every operation
terminal, and no prepared operation or backend call outstanding, and atomically revokes that broker's session
admission. `closeCompletedProductionInvocation` revalidates those exact sets, the terminal journal
version, Production mode epoch, bound lease, snapshot/binding, active revision, resource-record set, and
Open-project state in one compare-and-swap. Its closed branch consumes the
`BoundRunLease`, broker admission, and revision-permit authority and records the lease/broker invocation
closed. It deliberately returns the same `ProjectModeLease ... ProductionMode`, bound snapshot/binding,
active revision, acquisition journal, complete rehydrated resource set, and a successor
`ProjectOperationState ... OpenProject`; it creates no `ClosedProject`, release proof, tombstone, or
resource-release authority. The returned old-generation values cannot authorize another effect because
there is no matching bound lease, admission, or permit authority. A later invocation must pass the root
gate and rehydrate them under a fresh broker generation.

The close key is stable over project, plan, broker generation, verb, terminal journal version, and the
complete-set digests. A transport/store acknowledgment loss yields only
`ProductionInvocationCloseUnknown`, never the live tuple or permission to repeat effects.
`withProductionInvocationRecovery` therefore has a distinct
`IncompleteProductionInvocationCloseRecovery` branch before ordinary revision recovery. It
authoritatively reprobes the same close key: an already committed close reconstructs the closed proof
and retained Production state; an acknowledged-but-still-open stale lease resumes only the idempotent
close compare-and-swap through `resumeProductionInvocationClose`. It cannot reopen a command session or
enter lifecycle work. A stale/mismatched completion record refuses. This covers a kill after terminal
acknowledgment, on either side of the lease-close CAS, and after commit but before caller acknowledgment
without treating normal successful `up`/`down` as abandoned operational work.

`authorizeHarnessClose` is an atomic compare-and-swap, not a pure conversion: it verifies that version
is still current, verifies that every ordinary operation session is Closed, changes
`ProjectOperationState ... OpenProject` to a fresh `ClosingProject` epoch, and
creates the first close-journal version in the same protected transition before returning close
authority. Operation prepare atomically revalidates the same Open state, so a concurrent prepare and
close CAS cannot both win. A retained proof from before destroy→up or a later retry has an old journal
version and cannot close fresh resources. The initial persisted-snapshot continuation already carries
its `BoundPlanSnapshot`, bound lease, and live journal, so terminal close does not acquire a second
lease.

A newly opened run derives `HarnessCloseRoot` from its `HarnessRootAuthority`; recovery of an abandoned
run derives the same narrow close capability from `AbandonedHarnessRecoveryAuthority`, never rehydrating
general harness or `ProjectUp` authority. The harness-only close plan is derived from the same graph and
receipts. `withPreparedHarnessCloseOperation` is its only effect interpreter: under the exact
`ClosingProject` epoch it uses the same durable session, unknown-state, total-reprobe, and authoritative
fence rotation protocol as ordinary operations, then returns a permit-bound
`PreparedHarnessCloseOperation` for exactly one generated-config or `.test_data/<runId>` backend call.
The adapter has no close-effect entry point without that value.
`runPreparedHarnessCloseOperation` performs the exact operation encapsulated by the opaque prepared
value, commits its terminal observation, and returns `HarnessCloseAdvance` even for a typed failure.
`withHarnessCloseAdvance` jointly exposes that result and the sole successor close-journal version, so a
failure cannot strand the caller with only the prepare-time version. A crash before or after any call
leaves the close journal in a recoverable intent/unknown/observed/released state; a delayed old close
permit is rejected or deduplicated before a retry. `settleHarnessClose` can produce
`HarnessCloseOutcomesSettled` only when every close operation and session is terminal and no permit is
outstanding. `finalizeHarnessClose` then atomically records the terminal `ClosedProject`, closes the
bound lease, and releases the project-wide Harness mode lease last, returning the closed-state and
mode-release proofs together. Production root authority cannot mint any of these values. Destroy→up
tests inside one variant therefore retain durable state, while terminal variant cleanup remains
receipt-bound and restartable rather than an out-of-band path deletion.

The same closure discipline governs the project-wide Production mode record, but its authorization keeps
the initiating verb instead of erasing it. `authorizeProductionClosureAfterDestroy` accepts only
`ProjectDestroy` root authority plus `DestroySettled`; the separate
`authorizeProductionClosureBeforeFirstEffect` accepts any exact Production invocation only with
`VerifiedNoProjectResourcesAcquired`. Those are the only producers of
`ProductionClosureAuthorization`, so a non-destroy invocation cannot relabel partial teardown as settled,
while an `up` refusal before its first effect is still closable. `project down` with acquired/stopped
resources retains `ProductionMode`. `releaseProductionMode` performs one protected compare-and-swap that
revalidates the exact authorization, Open state/journal version, snapshot, binding, lease, and complete
Closed-session set, then records `ClosedProject`, closes the bound invocation lease, and clears the exact
mode epoch together. Session opening advances and compares-and-swaps that same Open project-journal
version, so a retained admission/state pair and Production finalization have exactly one winner. The
finalizer exposes no durable intermediate `ClosingProject` or mode-cleared partial state. A Harness opener
therefore cannot overlap a stopped or partially destroyed Production stack, and an unresolved Production
failure retains the exclusion record.

Each ordinary stop/release/delete operation consumes the opaque next `TeardownStep` derived from the
plan's child-first reverse cursor and returns the opaque successor forest. `SettledChildren` is indexed
by the verb, exact parent frame, and plan-derived child set: `Down` accepts stopped durable children and
released ephemeral children, while `Destroy` accepts only released children. A parent stop/delete has
no public type-correct entry point while a child remains unresolved, and a proof for another frame
cannot be substituted. Reusing a step is rejected by the matching durable cursor
compare-and-transition. The step carries the same resource identity, operation, and operation key as
its `PreparedOperation`/`PreparedPreconditions` pair, so a prepared operation for another teardown node cannot
discharge it. Once a valid step
is consumed, the operation always returns `TeardownAdvance` inside `OperationAdvance`: success contains
the typed result; failure contains the resource's journal/recovery state, and both branches expose the
successor protected journal state/permit pair through `withOperationAdvance`. Its successor **forest**
keeps independent siblings schedulable while the failed node remains unresolved and therefore cannot
satisfy its parent's `SettledChildren`. Aggregation never loses the continuation, the current journal
version, or reconstructs a work queue from exceptions.
`Stoppable resource from` is minted by the plan for legal resource-specific source phases (for example a
provider may stop from `NetworkReady`), so the API does not pretend every durable resource is literally
in a generic `Running` phase. `MayStop` permits both reverse plans to use their own exact authority:
`Destroy` can perform its required stop phase without manufacturing a separate `ProjectDown` authority.
`stopDurable` always returns a still-owned `Stopped` handle and receipt,
while `confirmStopped` has no
running-to-stopped effect. `releaseEphemeralForDown` additionally requires plan-owned proof that this
resource kind has no stopped state; a durable resource cannot enter that function. A successful
ephemeral `down` or `destroyOwned` returns only `ReleasedOwnership`, which has no mutation/delete
operation. Recursive teardown aggregates per-resource successes and failures, but each failure retains
the last verified local journal phase, stable operation key, resource generation, and
`RecoveryDisposition`; aggregating errors never discards the state needed for safe recovery.

A later `destroy` after `down` may need temporary reachability into a stopped provider before retained
children can even be visited. The forest's closed authorization point therefore has a distinct
**pre-descent** branch: its private eliminator may expose only the exact operation-indexed
`TeardownDescentStep ... ProjectDestroy ... Provider Stopped -> TeardownReachable` for that frame,
child set, and continuation. `resumeForDestroy` consumes that step and returns a successor forest in
which the children are reachable; it does not consume or manufacture `SettledChildren`. Only after
those children are released can the ordinary child-settled cursor expose the provider's later
stop/delete `TeardownStep`. The reachability transition is not a normal running/up state, cannot run
workload steps or mint `ProjectUp`, and returns its successor forest even on typed failure. This
pre-descent/post-child split makes down→destroy type-correct without circularly requiring unreachable
children to be settled and without allowing parent deletion while child state is unresolved.

## Ownership and idempotence

An ownership receipt records enough immutable identity to prove what this invocation may later mutate or
delete: lifecycle scope, generative plan identity, project, resource kind, provider/frame, stable name,
and a content fingerprint or creation generation. Each supported backend holds the four
[ownership invariant](ownership_invariant.md) clauses: exclusive entry, a durable origin record written
before the first mutation, identity binding to the object's stable kernel identity, and release
conditioned on re-observing that identity. A backend that cannot hold all four returns `Unsupported`.
Plain exclusive pathname creation, a path-only sidecar, and compare-then-unlink satisfy none of them,
because a pathname is not evidence of object identity between two operations.

An external provider/filesystem/process effect cannot be atomically committed with a local file write.
The target therefore records a durable acquisition journal instead of pretending the two systems share a
transaction:

```haskell
data AttemptPhase
  = IntentRecorded
  | ReservationOutcomeUnknown
  | ReservationAbsent
  | Reserved
  | EffectOutcomeUnknown
  | EffectAbsent
  | ObservedManaged
  | ObservedForeign
  | Committed
  | TeardownOutcomeUnknown
  | Released

data AdoptionPhase
  = AdoptionIntentRecorded
  | AdoptionOutcomeUnknown
  | AdoptionObservedAbsent
  | AdoptionObservedManaged
  | AdoptionObservedForeign
  | AdoptionCommitted
  | AdoptionTeardownOutcomeUnknown
  | AdoptionReleased

data RepairPhase
  = RepairIntentRecorded
  | RepairEffectOutcomeUnknown
  | RepairObservedOriginal
  | RepairObservedTarget
  | RepairObservedAbsent
  | RepairObservedUnexpected
  | RepairObservedForeign
  | RepairCommitted

data ManagedPhaseEffectPhase
  = PhaseIntentRecorded
  | PhaseEffectOutcomeUnknown
  | PhaseObservedFrom
  | PhaseObservedTo
  | PhaseObservedAbsent
  | PhaseObservedUnexpected
  | PhaseObservedForeign
  | PhaseCommitted

data AcquireOperation
data AdoptOperation
data RepairOperation resource from to
data PhaseOperation resource from to

data OrdinaryRelease
data AdoptedRelease
data VerifiedReleaseRecord
  scope planDigest frameKey resourceKey generation operation operationKey releaseOrigin
  -- constructor hidden; built only from Released or AdoptionReleased
data VerifiedReleasedAbsence
  scope planDigest frameKey resourceKey resource generation absenceVersion
  -- constructor hidden; built only by the total protected backend-absence probe

data FreshGeneration
  scope planDigest planId frame frameKey resourceKey id resource
  oldOperation oldOperationKey oldGeneration newAcquireOperationKey newGeneration
  -- constructor hidden; retains the exact local identity/operation binding, release/absence store
  -- versions, new AcquireOperation, and monotonic successor generation for registration-time CAS
data FirstAcquisitionGeneration
  scope planDigest planId frame frameKey resourceKey id resource acquireOperationKey generation
  -- constructor hidden; retains the exact local identity/operation binding and snapshot version
  -- proving no prior journal generation

data PersistedJournalRecord -- stable, untrusted bytes; no generative phantom identities
data VerifiedJournalRecord
  scope planDigest frameKey resourceKey generation operation operationKey recordVersion phase
                                                                   -- constructor hidden
data PlanDigestBinding scope specDigest planDigest planId              -- constructor hidden
data ResourceIdentityBinding
  scope planDigest planId frame frameKey resourceKey id resource      -- constructor hidden
data OperationBinding
  scope planDigest planId frame id resource operation operationKey    -- constructor hidden
data JournalEntry
  scope planId frame id generation resource operation operationKey recordVersion phase
                                                                      -- constructor hidden
data ReceiptCommitProof
  scope planId frame id generation resource operation operationKey recordVersion
  where
    OrdinaryReceiptCommit
      :: JournalEntry
           scope planId frame id generation resource
           AcquireOperation operationKey recordVersion Committed
      -> ReceiptCommitProof
           scope planId frame id generation resource
           AcquireOperation operationKey recordVersion
    AdoptionReceiptCommit
      :: JournalEntry
           scope planId frame id generation resource
           AdoptOperation operationKey recordVersion AdoptionCommitted
      -> ReceiptCommitProof
           scope planId frame id generation resource
           AdoptOperation operationKey recordVersion

bindJournalEntry
  :: PlanDigestBinding scope specDigest planDigest planId
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> VerifiedJournalRecord
       scope planDigest frameKey resourceKey generation operation operationKey
       recordVersion phase
  -> Either JournalConflict
       (JournalEntry
          scope planId frame id generation resource operation operationKey
          recordVersion phase)

bindOwnershipReceipt
  :: PlanDigestBinding scope specDigest planDigest planId
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> VerifiedReceiptRecord
       scope planDigest frameKey resourceKey generation operation operationKey
  -> ReceiptCommitProof
       scope planId frame id generation resource operation operationKey recordVersion
  -> Either JournalConflict
       (OwnershipReceipt scope planId id resource)

data RecoveryDisposition
  = RetrySameGeneration
  | ReprobeBeforeRetry
  | RefuseForeignState
  | RequireOperatorResolution
```

The persisted record contains only restart-stable values: the encoded lifecycle scope/run, project
identity, protected `PlanDigest`, stable resource key and kind, backend generation/fingerprint, stable
operation key, broker generation, phase, and monotonic record version. It never serializes `planId`,
resource `id`, a handle, a receipt, or a readiness witness. After a restart, protected-store and backend
verification mint a record-version-indexed `VerifiedJournalRecord`; matching plan-digest,
frame/resource-identity, and exact operation-key bindings then produce the local, fully indexed
`JournalEntry`. The local entry can
therefore type-link a `Committed` acquisition to the exact frame and
`OwnershipReceipt scope planId id resource` without pretending a generative identity survives a process
or allowing a boot/delete entry for the same backend generation to stand in for that acquisition.
`ReceiptCommitProof` admits exactly the ordinary acquisition commit or the separately journaled adoption
commit; a foreign observation, phase transition, teardown entry, or merely matching generation cannot
seal a receipt.

The numbered rules below are the **ordinary acquisition** graph. Adoption, repair, managed phase
transitions, and adopted teardown use their separately typed graphs described immediately afterward;
none is coerced through ordinary `IntentRecorded`.

1. Before any ordinary acquisition backend call, `registerOperationIntent` requires an exact
   `InitialOperationPhase`. Its acquisition branch can be built only from
   `FirstAcquisitionGeneration` (the protected snapshot has no prior generation for that resource) or
   from `FreshGeneration` (the exact prior release tombstone, current protected absence, distinct
   acquisition key, and monotonic successor generation). The evidence and the resource/operation
   bindings share the same plan digest, frame/resource key, operation key, and generation indices; the
   caller cannot choose the callback's generation. The registration compare-and-swap revalidates and
   consumes the exact origin version while it atomically records the exact
   stable scope/project/plan digest/resource/generation/operation key as `IntentRecorded`, registers that
   operation as a member of the exact Open session, and advances both the session and project-journal
   versions. A retained, stale, reused, or wrong-resource origin loses that compare-and-swap. No intent
   record can exist outside the independently complete session/operation manifest, and no manifest
   member can exist without its initial record. The compare-and-swap jointly yields the verified intent,
   exact `VerifiedInitialFenceState ... NoInitialFence`, and sole successor session/state/permit values;
   none can be paired with a different local binding or session. The resulting intent is a valid explicit
   **no-initial-fence-yet** state. Only the resumable `withCurrentOperationFence` protocol may consume that
   closed state—or its exact persisted intent/unknown/observed successor after recovery—and yield a
   current fence. Intent alone cannot prepare or call a backend. It then records
   `ReservationOutcomeUnknown` **before** asking the resource's authoritative backend to reserve that
   identity. When the adapter runs in a child process, the per-operation prepare/prepared-call protocol below
   makes that durable transition before the child is authorized to issue the call. The journal write and
   backend reservation are deliberately not described as one transaction.
2. Only a probe that verifies the reservation's immutable identity may advance the entry to `Reserved`.
   A crash after the backend accepted the reservation but before that journal update therefore resumes
   from `ReservationOutcomeUnknown` and probes the same generation; it never creates a second
   reservation. If the backend cannot provide an identity-bearing reservation — clause 3 of the
   [ownership invariant](ownership_invariant.md) — the transition returns `Unsupported`; a sidecar that
   records only a pathname is not a reservation.
3. The root interpreter records `EffectOutcomeUnknown` **before** invoking or permitting the ordinary
   acquisition effect, using the same stable operation key/name. A root, relay, or child death can
   therefore leave an explicit uncertain state, never an implied absence or success.
4. Recovery from either unknown state must run the backend's total reservation/resource probe.
   Before any absence/same-old-state result may retry, `fenceUnknownOperation` rotates an authoritative
   backend fence/dedup epoch and yields `OldPermitsFenced` for the exact operation key and attempt.
   A delayed child carrying the earlier prepared operation is then rejected or deduplicated even if it wakes after
   recovery begins. Without an end-to-end fence, the strong operation returns `Unsupported` rather than
   retrying. With that proof, reservation absence becomes `ReservationAbsent` and can retry only the same
   reservation generation; effect absence becomes `EffectAbsent` and can retry only the same effect
   under the verified reservation. A matching immutable identity advances to `Reserved` or
   `ObservedManaged`; a mismatch
   records `ObservedForeign` and refuses mutation/deletion. No public path blindly repeats a
   non-idempotent create.
5. Only verification can move `ObservedManaged` to `Committed` and mint the managed handle/receipt.
   An operational failure carries a `RecoveryDisposition`; it does not erase the journal state.
6. Ordinary teardown records `TeardownOutcomeUnknown` before the external deletion, verifies the receipt and
   current generation immediately before that effect, and records `Released` only after absence is
   observed. An adopted resource follows the distinct
   `AdoptionCommitted → AdoptionTeardownOutcomeUnknown → AdoptionReleased` path under its adoption
   operation key. Recovery reprobes either teardown-unknown phase; it never assumes that an interrupted
   delete failed or repeats it against a replacement. Retrying a same-identity delete also requires the
   exact old-permit fence proof. Independent failures remain separately reportable.
7. `Released` or `AdoptionReleased` is a tombstone for one generation, not a permanent ban on planned recreation. After
   verified absence, the plan/backend may mint
   `FreshGeneration scope planDigest planId frame frameKey resourceKey id resource oldOperation
   oldOperationKey oldGeneration newAcquireOperationKey newGeneration`; only that proof of the exact old
   release plus a distinct new `AcquireOperation` key can be consumed by only `freshAcquisitionIntent` and the same
   `registerOperationIntent` compare-and-swap, which starts `IntentRecorded newGeneration` with a higher
   attempt/record version while retaining old history. No
   unknown/foreign phase can roll over, so an uncertain create is never disguised as a fresh attempt.

Ordinary `ObservedForeign` remains terminal. Explicit adoption is a separate stable operation and
operation key: consuming the jointly verified foreign origin and exact generation/observation-version/
operation-key-indexed `AdoptionAuthority` records `AdoptionIntentRecorded`, then
`AdoptionOutcomeUnknown` before the backend's authoritative transfer/claim. The same origin/authority
pair is required by the adoption adapter signature; the protected intent compare-and-swap prevents a
retained ordinary Haskell value from opening a second attempt. Verification advances to
`AdoptionObservedManaged -> AdoptionCommitted`, which alone mints `AdoptedEvidence`; mismatch advances
to terminal `AdoptionObservedForeign`, while authoritative absence advances to
`AdoptionObservedAbsent` and permits only an explicit same-key adoption retry after
`OldPermitsFenced` proves a delayed transfer cannot land (otherwise `Unsupported`/operator resolution).
A backend without an authoritative adoption primitive returns
`Unsupported`. The old foreign journal entry is never rewritten as managed. Eventual teardown retains
the adoption operation key and advances only through `AdoptionTeardownOutcomeUnknown` to
`AdoptionReleased`, so adopted ownership is both destructible and recoverable without pretending it was
an ordinary create.

Repair and non-release phase effects have their own stable operations; neither borrows the acquisition
graph. A repair first verifies the existing receipt/identity and records
`RepairIntentRecorded → RepairEffectOutcomeUnknown` before the backend call. Total reprobe advances to
`RepairObservedOriginal` (same identity at the old target; retry only the same operation key after
old-permit fencing),
`RepairObservedTarget → RepairCommitted`, terminal `RepairObservedAbsent`, terminal
`RepairObservedUnexpected` (same identity in a third phase), or terminal `RepairObservedForeign`.
`RepairedEvidence` is available only from `RepairCommitted`, and the original ownership receipt is
retained rather than reminted. Boot, stop, and destroy-reachability use
`PhaseOperation resource from to` and the analogous
`PhaseIntentRecorded → PhaseEffectOutcomeUnknown → PhaseObservedFrom | PhaseObservedTo |
PhaseObservedAbsent | PhaseObservedUnexpected | PhaseObservedForeign` graph; only
`PhaseObservedTo → PhaseCommitted` yields the indexed
`PhaseTransition from to`. These graphs have no edge to release, acquisition commit, adoption, or
`FreshGeneration`. A crash after any such backend effect therefore reprobes the exact generation/phase
and never blindly repeats a non-idempotent repair, boot, stop, or resume; a retry from the original phase
requires the same exact fence proof.

The journal constructors and transitions are private. Public interpreters expose only legal moves, so
“reserve before recording intent,” “retry an unknown create as a new operation,” “commit without
observing identity,” and “delete after a generation changed” are not representable API calls. A
filesystem backend may use atomic create/rename as one mechanism inside a protected, identity-bound
protocol, but that primitive alone mints no strong receipt. The journal/reprobe rule still applies to
filesystem, provider, process, network, and registry effects.

The transition graph is branched, not a union followed by a common commit:

```text
IntentRecorded
  -> ReservationOutcomeUnknown
       -> ReservationAbsent -> ReservationOutcomeUnknown      (same generation only)
       -> Reserved
       -> ObservedManaged                                     (reserve-is-create backend)
       -> ObservedForeign                                     (terminal refusal)

Reserved
  -> EffectOutcomeUnknown
       -> EffectAbsent -> EffectOutcomeUnknown                 (same generation only)
       -> ObservedManaged
       -> ObservedForeign                                     (terminal refusal)

ObservedManaged -> Committed                                  (the only commit edge)
Committed -> TeardownOutcomeUnknown
  -> Released                                                 (absence verified)
  -> Committed                                                (same identity remains; retry is explicit)
  -> ObservedForeign                                          (replacement; terminal refusal)

Released oldGeneration
  + verified absence
  + FreshGeneration scope planDigest planId frame frameKey resourceKey id resource
      oldOperation oldOperationKey oldGeneration newAcquireOperationKey newGeneration
  -> freshAcquisitionIntent
  -> registerOperationIntent
  -> IntentRecorded newGeneration under AcquireOperation/newAcquireOperationKey
                                                               (monotonic rollover only)

ObservedForeign                                              (ordinary path remains terminal)
AdoptionIntentRecorded
  -> AdoptionOutcomeUnknown
       -> AdoptionObservedAbsent                              (same-key retry only with OldPermitsFenced)
       -> AdoptionObservedManaged -> AdoptionCommitted
            -> AdoptionTeardownOutcomeUnknown
                 -> AdoptionReleased                         (absence verified)
                 -> AdoptionCommitted                        (same identity remains)
                 -> AdoptionObservedForeign                  (replacement; terminal refusal)
       -> AdoptionObservedForeign                            (terminal refusal)

AdoptionReleased oldGeneration
  + verified absence
  + FreshGeneration scope planDigest planId frame frameKey resourceKey id resource
      AdoptOperation oldOperationKey oldGeneration newAcquireOperationKey newGeneration
  -> freshAcquisitionIntent
  -> registerOperationIntent
  -> IntentRecorded newGeneration under AcquireOperation/newAcquireOperationKey
                                                               (normal recreation, not re-adoption)

RepairIntentRecorded
  -> RepairEffectOutcomeUnknown
       -> RepairObservedOriginal -> RepairEffectOutcomeUnknown  (same operation key only)
       -> RepairObservedTarget -> RepairCommitted
       -> RepairObservedAbsent                                  (lost; terminal/operator resolution)
       -> RepairObservedUnexpected                              (same identity, third phase; terminal)
       -> RepairObservedForeign                                 (terminal refusal)

PhaseIntentRecorded
  -> PhaseEffectOutcomeUnknown
       -> PhaseObservedFrom -> PhaseEffectOutcomeUnknown        (same operation key only)
       -> PhaseObservedTo -> PhaseCommitted
       -> PhaseObservedAbsent                                   (lost; terminal/operator resolution)
       -> PhaseObservedUnexpected                               (same identity, third phase; terminal)
       -> PhaseObservedForeign                                  (terminal refusal)
```

The record-version and phase parameters of
`JournalEntry scope planId frame id generation resource operation operationKey recordVersion phase` and
hidden transition constructors encode those arrows. There is no function from either absent phase or `ObservedForeign` to
`Committed`, no new-generation retry from an unknown phase, and no delete entry point without both the
matching ordinary/adoption commit proof and `OwnershipReceipt scope planId id resource`. The stable persisted record
uses `PlanDigest`/resource key; only its verified, freshly rebound local view contains `planId`/`id`.
Repair/phase commits preserve that receipt and cannot be supplied where an acquisition/adoption commit
or released tombstone is required.

Reconcile results drive policy:

- `ManagedResult` whose non-authorizing view is `Changed Created`, `Changed (Repaired details)`, or
  `Changed (Adopted details)` distinguishes the three managed change paths and carries the managed
  handle plus receipt registered for rollback and eventual destroy. Creation establishes ownership,
  adoption transfers it, and repair preserves the existing ownership receipt.
- `ManagedResult` whose view is `Unchanged` preserves a prior verified claim across idempotent reruns.
- `ForeignResult` carries only an `Unmanaged` handle and observation. It is never mutated or deleted as if
  created here; explicit adoption requires matching opaque authority and yields `Changed Adopted`.
- `Conflict`, `SafetyRefusal`, `Unsupported`, and `Failure` are terminal error branches with context.

This same contract applies to generated test config, `.test_data`, host-daemon PID/config state, provider
VMs, aliases, clusters, and temporary registry credentials.

## Lifecycle profile authority

Production and harness plans must not share an unscoped enum that any caller can choose. The target uses
opaque authority and a scope-indexed profile:

```haskell
data Production projectId
data Harness projectId runId
data ProductionMode
data HarnessMode runId

data ProjectUp
data ProjectDown
data ProjectDestroy
data TestRun
data ProjectVerb verb -- closed singleton

data RootInvocationAuthority scope brokerGeneration verb -- constructor hidden
data RootScopeAuthority scope            -- constructor hidden
data ProjectModeLease projectId mode brokerGeneration     -- constructor hidden
data ActiveProjectMode scope brokerGeneration              -- constructor hidden
data VerifiedHarnessPreconditions projectId preconditionVersion -- constructor hidden
data PlanMigrationRoot scope brokerGeneration             -- constructor hidden
data HarnessRootAuthority projectId runId brokerGeneration -- constructor hidden
data HarnessAuthority projectId runId                     -- constructor hidden; plan-only narrowing
data AbandonedHarnessRecoveryAuthority
  projectId oldRunId oldSpecDigest oldPlanDigest brokerGeneration
                                                              -- constructor hidden
data NewlyAcquiredMode
data ReopenedMode
data UnboundLeaseState brokerGeneration modeEpoch modeDisposition
data BoundLeaseState
  specDigest planDigest oldBrokerGeneration requiredSessionSet requiredOperationSet
data VerifiedIncompleteRunLease
  scope leaseState leaseRecordVersion                        -- constructor hidden
data VerifiedUnboundLeaseHasNoEffects
  scope brokerGeneration modeEpoch modeDisposition leaseRecordVersion
                                                               -- constructor hidden
data OldPermitFenceSet
  scope planDigest oldBrokerGeneration newBrokerGeneration
  requiredSessionSet requiredOperationSet
                                                               -- constructor hidden
data VerifiedSessionOperationManifest
  scope planDigest oldBrokerGeneration requiredSessionSet requiredOperationSet
                                                               -- constructor hidden
data BoundRevisionRecovery
  scope specDigest planDigest planId brokerGeneration          -- constructor hidden
data BoundInvocationRecovery
  scope specDigest planDigest planId brokerGeneration          -- constructor hidden
data IncompleteProductionInvocationCloseRecovery
  projectId specDigest planDigest planId brokerGeneration verb
  activeRevisionVersion completionJournalVersion
  requiredSessionSet requiredOperationSet requiredResourceSet closeRecordVersion
                                                               -- constructor hidden
data IncompleteHarnessCloseRecovery
  projectId runId specDigest planDigest planId brokerGeneration closeEpoch closeJournalVersion
                                                               -- constructor hidden
data ClosedAbandonedProductionRuns
  projectId recoverySweepVersion                             -- constructor hidden
data ClosedAbandonedHarnessRuns
  projectId recoverySweepVersion                             -- constructor hidden
data UnboundRunLease scope brokerGeneration      -- constructor hidden; exclusive by invariant
data BoundRunLease scope specDigest planDigest brokerGeneration -- constructor hidden
data AuthorityBroker scope brokerGeneration      -- constructor hidden
data HarnessChildVerb verb -- closed singleton: ProjectUp | ProjectDown | ProjectDestroy

-- Public composite bracket. Phase 15 owns the independent root/command-authority verifier;
-- Phase 10 owns the mode/lease/broker transaction in which that verifier is consumed.
withProductionRoot
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> ClosedAbandonedProductionRuns
       projectId recoverySweepVersion
  -> ProjectVerb verb
  -> (forall brokerGeneration.
        RootInvocationAuthority (Production projectId) brokerGeneration verb
        -> ProjectModeLease projectId ProductionMode brokerGeneration
        -> UnboundRunLease (Production projectId) brokerGeneration
        -> AuthorityBroker (Production projectId) brokerGeneration
        -> IO a)
  -> IO (Either AuthorityError a)

recoverAbandonedProductionRuns
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> ProjectVerb verb
  -> (forall brokerGeneration modeEpoch modeDisposition leaseRecordVersion.
        VerifiedIncompleteRunLease
          (Production projectId)
          (UnboundLeaseState brokerGeneration modeEpoch modeDisposition)
          leaseRecordVersion
        -> IO (Either AuthorityError ()))
  -> (forall oldSpecDigest oldPlanDigest oldBrokerGeneration
             requiredSessionSet requiredOperationSet
             leaseRecordVersion.
        VerifiedIncompleteRunLease
          (Production projectId)
          (BoundLeaseState
             oldSpecDigest oldPlanDigest oldBrokerGeneration
             requiredSessionSet requiredOperationSet)
          leaseRecordVersion
        -> IO (Either AuthorityError ()))
  -> (forall recoverySweepVersion.
        ClosedAbandonedProductionRuns
          projectId recoverySweepVersion
        -> IO a)
  -> IO (Either AuthorityError a)

verifyHarnessPreconditions
  :: InstalledProjectIdentity projectId
  -> (forall preconditionVersion.
        VerifiedHarnessPreconditions projectId preconditionVersion
        -> IO a)
  -> IO (Either AuthorityError a)

scopeAuthority
  :: RootInvocationAuthority scope brokerGeneration verb
  -> RootScopeAuthority scope

planMigrationRoot
  :: RootInvocationAuthority scope brokerGeneration ProjectUp
  -> PlanMigrationRoot scope brokerGeneration

productionActiveMode
  :: ProjectModeLease projectId ProductionMode brokerGeneration
  -> ActiveProjectMode (Production projectId) brokerGeneration

harnessActiveMode
  :: ProjectModeLease
       projectId (HarnessMode runId) brokerGeneration
  -> ActiveProjectMode (Harness projectId runId) brokerGeneration

withHarnessRoot
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> ClosedAbandonedHarnessRuns projectId recoverySweepVersion
  -> VerifiedHarnessPreconditions projectId preconditionVersion
  -> (forall runId brokerGeneration.
        RunId runId
        -> ProjectModeLease
             projectId (HarnessMode runId) brokerGeneration
        -> UnboundRunLease (Harness projectId runId) brokerGeneration
        -> HarnessRootAuthority projectId runId brokerGeneration
        -> AuthorityBroker (Harness projectId runId) brokerGeneration
        -> IO a)
  -> IO (Either AuthorityError a)

withAbandonedHarnessRun
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> VerifiedIncompleteRunLease
       (Harness projectId oldRunId)
       (BoundLeaseState
          oldSpecDigest oldPlanDigest oldBrokerGeneration
          requiredSessionSet requiredOperationSet)
       leaseRecordVersion
  -> (forall brokerGeneration planId.
        RunId oldRunId
        -> RootInvocationAuthority
             (Harness projectId oldRunId) brokerGeneration ProjectDestroy
        -> AbandonedHarnessRecoveryAuthority
             projectId oldRunId oldSpecDigest oldPlanDigest brokerGeneration
        -> BoundRunLease
             (Harness projectId oldRunId)
             oldSpecDigest oldPlanDigest brokerGeneration
        -> AuthorityBroker
             (Harness projectId oldRunId) brokerGeneration
        -> ProjectModeLease
             projectId (HarnessMode oldRunId) brokerGeneration
        -> OldPermitFenceSet
             (Harness projectId oldRunId)
             oldPlanDigest oldBrokerGeneration brokerGeneration
             requiredSessionSet requiredOperationSet
        -> VerifiedSessionOperationManifest
             (Harness projectId oldRunId) oldPlanDigest oldBrokerGeneration
             requiredSessionSet requiredOperationSet
        -> VerifiedPlanSnapshot
             (Harness projectId oldRunId) oldSpecDigest oldPlanDigest
        -> BoundPlanSnapshot
             (Harness projectId oldRunId) oldSpecDigest oldPlanDigest planId
        -> PlanDigestBinding
             (Harness projectId oldRunId) oldSpecDigest oldPlanDigest planId
        -> BoundInvocationRecovery
             (Harness projectId oldRunId)
             oldSpecDigest oldPlanDigest planId brokerGeneration
        -> IO a)
  -> IO (Either AuthorityError a)

withAbandonedProductionRun
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> ProjectVerb verb
  -> VerifiedIncompleteRunLease
       (Production projectId)
       (BoundLeaseState
          oldSpecDigest oldPlanDigest oldBrokerGeneration
          requiredSessionSet requiredOperationSet)
       leaseRecordVersion
  -> (forall brokerGeneration planId.
        RootInvocationAuthority
          (Production projectId) brokerGeneration verb
        -> BoundRunLease
             (Production projectId)
             oldSpecDigest oldPlanDigest brokerGeneration
        -> AuthorityBroker
             (Production projectId) brokerGeneration
        -> ProjectModeLease
             projectId ProductionMode brokerGeneration
        -> OldPermitFenceSet
             (Production projectId)
             oldPlanDigest oldBrokerGeneration brokerGeneration
             requiredSessionSet requiredOperationSet
        -> VerifiedSessionOperationManifest
             (Production projectId) oldPlanDigest oldBrokerGeneration
             requiredSessionSet requiredOperationSet
        -> VerifiedPlanSnapshot
             (Production projectId) oldSpecDigest oldPlanDigest
        -> BoundPlanSnapshot
             (Production projectId) oldSpecDigest oldPlanDigest planId
        -> PlanDigestBinding
             (Production projectId) oldSpecDigest oldPlanDigest planId
        -> BoundInvocationRecovery
             (Production projectId)
             oldSpecDigest oldPlanDigest planId brokerGeneration
        -> IO a)
  -> IO (Either AuthorityError a)

verifyUnboundLeaseHasNoEffects
  :: VerifiedIncompleteRunLease
       scope
       (UnboundLeaseState brokerGeneration modeEpoch modeDisposition)
       leaseRecordVersion
  -> IO
       (Either
          AuthorityError
          (VerifiedUnboundLeaseHasNoEffects
             scope brokerGeneration modeEpoch modeDisposition leaseRecordVersion))

closeAbandonedProductionUnboundLease
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> VerifiedIncompleteRunLease
       (Production projectId)
       (UnboundLeaseState brokerGeneration modeEpoch modeDisposition)
       leaseRecordVersion
  -> VerifiedUnboundLeaseHasNoEffects
       (Production projectId)
       brokerGeneration modeEpoch modeDisposition leaseRecordVersion
  -> IO (Either AuthorityError ())

closeAbandonedHarnessUnboundLease
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> VerifiedIncompleteRunLease
       (Harness projectId oldRunId)
       (UnboundLeaseState brokerGeneration modeEpoch modeDisposition)
       leaseRecordVersion
  -> VerifiedUnboundLeaseHasNoEffects
       (Harness projectId oldRunId)
       brokerGeneration modeEpoch modeDisposition leaseRecordVersion
  -> IO (Either AuthorityError ())

recoverAbandonedHarnessRuns
  :: InstalledProjectIdentity projectId
  -> VerifiedOsPrincipal
  -> (forall oldRunId brokerGeneration modeEpoch modeDisposition leaseRecordVersion.
        VerifiedIncompleteRunLease
          (Harness projectId oldRunId)
          (UnboundLeaseState brokerGeneration modeEpoch modeDisposition)
          leaseRecordVersion
        -> IO (Either AuthorityError ()))
  -> (forall oldRunId oldSpecDigest oldPlanDigest oldBrokerGeneration
             requiredSessionSet requiredOperationSet leaseRecordVersion.
        VerifiedIncompleteRunLease
          (Harness projectId oldRunId)
          (BoundLeaseState
             oldSpecDigest oldPlanDigest oldBrokerGeneration
             requiredSessionSet requiredOperationSet)
          leaseRecordVersion
        -> IO (Either AuthorityError ()))
  -> (forall recoverySweepVersion.
        ClosedAbandonedHarnessRuns projectId recoverySweepVersion
        -> IO a)
  -> IO (Either AuthorityError a)

harnessScopeAuthority
  :: HarnessRootAuthority projectId runId brokerGeneration
  -> RootScopeAuthority (Harness projectId runId)

harnessAuthority
  :: HarnessRootAuthority projectId runId brokerGeneration
  -> HarnessAuthority projectId runId

currentHarnessCloseRoot
  :: HarnessRootAuthority projectId runId brokerGeneration
  -> HarnessCloseRoot projectId runId brokerGeneration

abandonedHarnessCloseRoot
  :: AbandonedHarnessRecoveryAuthority
       projectId runId specDigest planDigest brokerGeneration
  -> HarnessCloseRoot projectId runId brokerGeneration

authorizeHarnessChild
  :: HarnessRootAuthority projectId runId brokerGeneration
  -> HarnessChildVerb verb
  -> IO
       (Either
          AuthorityError
          (RootInvocationAuthority
             (Harness projectId runId) brokerGeneration verb))

data LifecycleProfile scope -- constructor hidden; opened only by Phase 10's mode transaction
data RecoveredProductionLifecycleProfile
  projectId specDigest planDigest planId brokerGeneration
  -- constructor hidden; exact bound-lease ProjectUp recovery profile, never a fresh/open profile

withProductionLifecycleProfile
  :: RootScopeAuthority (Production projectId)
  -> ActiveProjectMode (Production projectId) brokerGeneration
  -> UnboundRunLease (Production projectId) brokerGeneration
  -> (LifecycleProfile (Production projectId) -> a)
  -> IO (Either AuthorityError a)

withHarnessLifecycleProfile
  :: RootScopeAuthority (Harness projectId runId)
  -> HarnessAuthority projectId runId
  -> RunId runId
  -> ActiveProjectMode (Harness projectId runId) brokerGeneration
  -> UnboundRunLease (Harness projectId runId) brokerGeneration
  -> (LifecycleProfile (Harness projectId runId) -> a)
  -> IO (Either AuthorityError a)

withRecoveredProductionLifecycleProfile
  :: RootInvocationAuthority
       (Production projectId) brokerGeneration ProjectUp
  -> ActiveProjectMode (Production projectId) brokerGeneration
  -> BoundRunLease
       (Production projectId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> PlanDigestBinding
       (Production projectId) specDigest planDigest planId
  -> BoundInvocationRecovery
       (Production projectId) specDigest planDigest planId brokerGeneration
  -> (RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration
      -> a)
  -> IO (Either AuthorityError a)

withRecoveredProductionProjectPlan
  :: RecoveredProductionLifecycleProfile
       projectId specDigest planDigest planId brokerGeneration
  -> VerifiedPlanSnapshot
       (Production projectId) specDigest planDigest
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> PlanDigestBinding
       (Production projectId) specDigest planDigest planId
  -> ValidatedConfig
       (Production projectId) specDigest configId (cfg (Production projectId))
  -> NonEmpty
       (PlanDraft
          (Production projectId) specDigest (cfg (Production projectId)))
  -> (ProjectPlan
        (Production projectId) specDigest planId configId cfg
      -> a)
  -> Either PlanError a

containerPlan
  :: ProjectPlan scope specDigest planId localConfigId cfg
  -> ClusterPlan scope planId localConfigId
```

In prose below, “Production” abbreviates `Production projectId` and “Harness runId” abbreviates
`Harness projectId runId`. `InstalledProjectIdentity projectId` is generative, so project identity is
present before `planId`: a root authority/profile/lease for one installed binary cannot type-check with
another project's plan construction.

The public root brackets are deliberately **composite APIs**, not evidence that one phase owns both
halves. Phase 15 Sprint 15.9 owns the non-config verifier and the opaque root/command authority: it checks
the independently installed project identity, local OS/operator authorization, protected
authority-store identity, executable identity, and exact requested verb without trusting
`BinaryContext`. Phase 10 Sprint 10.9 owns the shared mode compare-and-swap, run lease, broker/session
admission, and the fresh and bound-recovery lifecycle-profile openers. `withProductionRoot` and
`withHarnessRoot` invoke the
Phase 15 verifier *inside* the Phase 10 protected open transaction and return both components in one
rank-2 bracket. This split of implementation ownership does not split the atomic transaction or expose an
intermediate public state. Phase 17 Sprint 17.4 only requires the resulting command authority at the
parser route; it does not construct either root authority or profile.

The non-config root gate breaks an otherwise circular authority story. A production config or decoded
`BinaryContext` is descriptive and cannot mint authority. For Production, the composite gate
acquires/reopens the project-wide `ProductionMode` lease, refusing while a Harness mode is active, then
opens a fresh broker generation and exclusive unbound run lease in the same rank-2 continuation. Only
the Phase 15-owned verifier inside that transaction can create
`RootInvocationAuthority (Production projectId) brokerGeneration verb`; only
`withProductionLifecycleProfile` can combine its narrowed root scope with the exact active mode and
unbound lease to create `LifecycleProfile (Production projectId)`. That profile constructs the plan
whose verified snapshot then binds the same lease; requiring an already-bound lease here would create an
uninhabitable plan/profile cycle. The opener is an exact-version protected transition over the unbound
lease's one-use profile slot, so retaining the Haskell inputs cannot open a second or opposite-scope
profile; snapshot binding revalidates that the plan was built from the same opened profile.
This unbound opener is not misused for an abandoned bound invocation.
`withRecoveredProductionLifecycleProfile` is the separate protected `ProjectUp` recovery transition: it
requires the exact fresh root/broker authority, active Production mode, already-bound lease,
verified/bound snapshot, plan binding, and `BoundInvocationRecovery`. It returns only
`RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration`; Harness and teardown
verbs cannot inhabit it. Its protected one-use recovery-profile slot prevents retaining the ordinary
inputs from opening another recovery profile.

Both root openers bracket the pre-bind interval. A normal assembler/codec/plan failure before
`bindRunLease` can close the unbound lease only after a protected compare proves that no token, prepared attempt,
journal, or backend effect was ever recorded. A crash in that interval leaves an explicit
`VerifiedIncompleteRunLease scope (UnboundLeaseState brokerGeneration modeEpoch modeDisposition)`,
not a fictitious plan digest. The no-effect proof and close CAS retain both the exact lease record
version and project-mode epoch/disposition. They atomically close the unbound lease and undo only a mode
acquisition owned by that opener; a reentered pre-existing Production mode is retained.

Before opening a new Production lease, `recoverAbandonedProductionRuns` exhaustively classifies that
project's stale unbound and bound invocation records at one store version for the requested verb. Its
two rank-2 fold callbacks receive each exact existential `VerifiedIncompleteRunLease`: the unbound
handler can only verify/close that record, while the bound handler can enter
`withAbandonedProductionRun` for snapshot-driven recovery. The sweep rechecks that the callback actually
closed or terminally settled the enumerated record before advancing; returning `Right ()` without doing
so cannot skip it. It closes each unbound record only through
`closeAbandonedProductionUnboundLease` plus `VerifiedUnboundLeaseHasNoEffects`. The opaque proof has one
producer, `verifyUnboundLeaseHasNoEffects`, which checks the exact protected lease record and rejects any
token, prepared-attempt, journal, receipt, fence, or backend-effect-shaped record; callers cannot assert the empty
set. Its protected empty-set
compare-and-swap yields `ClosedAbandonedProductionRuns`, which `withProductionRoot` consumes atomically
while opening the fresh broker generation. A bound member is processed only through
`withAbandonedProductionRun`; there is no hidden lease value callers must somehow manufacture and no
fresh-open branch while stale bound recovery remains. A successfully completed Production `ProjectUp`
or `ProjectDown` closes its ephemeral broker lease only after terminal acknowledgment while preserving
the active plan snapshot and protected records. If it crashes first,
`withAbandonedProductionRun` verifies the exact stale bound
record, proves/forces the old broker epoch unusable at every adapter, atomically rotates to a fresh
broker generation, and jointly yields the verified/bound snapshot, plan binding,
`BoundInvocationRecovery`, `OldPermitFenceSet`, and the verified manifest pairing the exact recorded
session set—including zero-operation Open sessions—with its exact operation set. The recovery sum must
be eliminated before any local journal exists; its open branch then classifies
normal/incomplete/completed revision state, while a
Harness-only closing branch cannot inhabit Production scope. The recovered verb cannot act until that fence set proves every delayed old prepared operation
will be rejected or deduplicated by the authoritative backend; a substrate without such fencing returns
`Unsupported`. If normal revision recovery finds an Open operation session,
`activateRecoveredNormalBoundRevision` must rebind and close the exact recorded session set before it
yields `CurrentBrokerSessionAdmission`. The same activation verifies the snapshot's complete committed/
released resource-record set and yields only a fresh generative `RehydratedResourceSet`; raw persisted
receipt bytes never become handles directly. Ordinary session opening and recovered teardown cannot
bypass that gate. Thus both unbound and bound crashes have typed recovery paths and neither is silently
discarded.
For the `ProjectUp` branch only, those exact bound values can also open the recovery profile described
above. `withRecoveredProductionProjectPlan` reconstructs a configful plan only when its validated config
and draft reproduce the same verified bound snapshot; incomplete and completed migration use their
separately typed recovered plan builders. No fresh/unbound profile is required or constructible while
the stale bound invocation is being recovered.

`recoverAbandonedHarnessRuns` first enumerates both unbound and bound incomplete leases in the protected
namespace at one store version. Its separate rank-2 unbound and bound fold callbacks receive every exact
existential `VerifiedIncompleteRunLease`, including the hidden old `runId`/plan digest where applicable;
the sweep rechecks terminal closure after each callback and cannot advance on a no-op handler. An unbound
member can be closed only through
`closeAbandonedHarnessUnboundLease`, which requires exact-version
`VerifiedUnboundLeaseHasNoEffects`; any effect-shaped record is a conflict/operator-resolution result.
Every bound member is opened only through `withAbandonedHarnessRun`, which verifies the protected record
and jointly rebinds its stable identities to a fresh local `planId`, yielding the exact old
verified/bound snapshot, plan-digest binding, `BoundInvocationRecovery`, already-bound lease, plus
`ProjectDestroy`, an `OldPermitFenceSet`, the exact session/operation manifest, and narrow
recovery/close authority inside a rank-2
continuation. It never reuses the
unbound-to-bound lease transition. It cannot mint `ProjectUp`, general
`HarnessAuthority projectId oldRunId`, or a fresh run identity. The interpreter classifies and settles
every unknown, continuable pre-call/intermediate, already-observed retryable, observed-success, and
terminal operation through the exact recorded-session activation fold. It then eliminates each recovered
resource as either exact owned evidence or the exact verified release-record tombstone through the bound
snapshot plus complete rehydrated set. A released resource becomes verified absence only after the
separate protected absence probe used for generation rollover. The interpreter performs receipt-bound
child-first teardown of owned work, closes the old run, and repeats until a
protected compare-and-swap proves the enumerated set is empty and yields
`ClosedAbandonedHarnessRuns projectId recoverySweepVersion`. A stray effect under an unbound lease,
foreign state, an unknown snapshot, or an unresolved partial result yields operator resolution and no
proof.

`withHarnessRoot` consumes that closure proof and atomically checks the same namespace version while it
generates the unpredictable stable run identifier.
`verifyHarnessPreconditions` is the sole producer of its generative, versioned observation. It derives
the canonical total probe internally from the installed project identity and protected project
namespace; callers cannot supply an always-successful probe. The opener consumes that evidence, reruns the
probe at acquisition, and acquires the project-wide
`ProjectModeLease projectId (HarnessMode runId) brokerGeneration` only while no Production mode is
active. Production openers consult the same record, so Production cannot start between the precheck and
Harness ownership. Non-cooperating external actors remain subject to each resource's authoritative
reservation/fence rather than this project-local mutex. A concurrent abandoned/fresh lease or
precondition change invalidates the proof instead of creating a race. The opener keeps both the `runId` phantom
and fresh broker generation inside the rank-2 continuation; only then does it yield
`HarnessRootAuthority`. A caller cannot choose or reuse either phantom before acquisition. That value
produces the harness root scope and can authorize only the closed child lifecycle verbs needed by
`test run`; it cannot produce a profile by itself. Only `withHarnessLifecycleProfile` can combine its
narrowed scope/authority and exact `RunId` with the matching active Harness mode and unbound lease to
open the profile. It cannot produce Production authority, and
ordinary Production openers cannot produce `TestRun`/harness authority. A lifecycle profile comes from
the Phase 10 opener combining the corresponding root authority with its exact active mode and unbound
lease, and the later
verb/frame/phase-specific command gate consumes the same invocation plus the validated plan/context.
Lifecycle transitions therefore do not have to mint the authority needed to begin lifecycle validation.

`withProjectPlan` consumes a fresh profile, the scope-matching config, the matching opaque
`CanonicalProjectRoot scope rootId`, and a validated plan draft. `sourceRoot` remains a descriptive
config field: root-config admission resolves it once against the stable project-home/config-ownership
anchor, verifies and canonicalizes it, and binds the result to `rootId`. Neither `withProjectPlan` nor a
frame interpreter may reinterpret `"."`, consult `cwd`, or reconstruct host authority from a guest
alias. Bound Production
recovery instead consumes only the exact
`RecoveredProductionLifecycleProfile` through `withRecoveredProductionProjectPlan` or a recovered
migration-plan builder.
`containerPlan` is then only a projection of the resulting
`ProjectPlan scope specDigest planId localConfigId cfg`; it has no independent profile/name/path arguments. The plan
derives the cluster identity and data root together:

```text
ProductionProfile -> fixed production cluster + .data
HarnessProfile id  -> run-scoped cluster id + .test_data/<id>
```

There is no separate profile/name/path argument that can disagree, and a `ClusterPlan` from one
Production plan cannot type-check in another. The scoped plan and its capabilities retain the same
`scope`, generative `planId`, and local config identity through provider, cluster, storage, and teardown
operations inside that process. Across a frame boundary only the stable plan revision and authenticated
child config digest cross; the child verifies its distinct bytes and creates fresh local
`planId`/`configId` values.

A recovered bound run never receives an acquisition journal before its durable operation and revision
states are classified. `withProductionInvocationRecovery` first distinguishes an Open operational
revision from an exact terminal `up`/`down` acknowledgment whose invocation lease close is incomplete or
unknown. The latter exposes only `IncompleteProductionInvocationCloseRecovery` and can resume/reprobe
the same lease-close key; it cannot expose a revision journal, session admission, or operation
authority. Production **mode release** still has no persisted intermediate close state: ordinary
invocation close retains Production mode, while `releaseProductionMode` remains the separate terminal
project/mode transition.
`withHarnessInvocationRecovery` instead has exactly two branches: Open revision state or the exact
persisted `ClosingProject` epoch. The latter can continue only through
`resumeIncompleteHarnessClose`, which rehydrates its close authority, journal, and plan without minting
normal lifecycle authority. The Open branch then enters `withBoundRevisionRecovery`, an exhaustive
rank-2 eliminator with exactly three revision branches: normal active, incomplete migration while old
remains active/frozen, or completed migration whose new revision is active but not yet locally
activated. For a clean normal-active record, only `activateNormalBoundRevision` yields the
active-revision proof plus normal journal,
complete freshly verified `RehydratedResourceSet`, Open-state/permit-authority tuple, and
`CurrentBrokerSessionAdmission` **after** atomically proving that every recorded session from an older
broker generation is Closed, including zero-operation sessions. If the normal revision contains a recorded Open session from the abandoned
generation, that gate refuses with `SessionRecoveryRequired`;
`activateRecoveredNormalBoundRevision` requires the exact `OldPermitFenceSet` and session/operation
manifest, rebinds and settles those sessions, verifies/rebinds the complete resource-record set, and
yields the same resource/state/permit/admission bundle only after the independent session set closes and
its complete operation set settles. The incomplete branch must resume or cancel through its exact gate;
the completed branch must run completed activation/recovery. No generic branch can bypass those
transitions or turn Closing back into Open.

## Cross-process authority handoff

An in-process root or `HarnessAuthority projectId runId` is deliberately non-serializable. The
self-reference lift therefore cannot put authority in Dhall, `argv`, or an environment variable, and it
cannot treat possession of a generated config path as authority. The target cross-process handoff uses
an invocation-root coordinator and per-edge objects:

```haskell
data PlanLineageDigest
data SpecDigest
data PlanDigest
data ConfigDigest
data StablePlanSnapshot                                      -- stable bytes, no capabilities
data VerifiedPlanSnapshot scope specDigest planDigest        -- constructor hidden
data BoundPlanSnapshot scope specDigest planDigest planId     -- constructor hidden
data ProspectivePlanSnapshot
  scope candidateId specDigest planDigest planId              -- constructor hidden; not persisted
data ProspectivePlanBinding
  scope candidateId specDigest planDigest planId              -- constructor hidden; no effect authority
data ProjectUpMigrationProfile
  scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
                                                               -- constructor hidden; live/recovered ProjectUp only
data ProspectivePlanMigration
  scope brokerGeneration candidateId
  oldSpecDigest oldPlanDigest oldPlanId
  newSpecDigest newPlanDigest newPlanId                       -- constructor hidden
data PersistedProspectivePlanSnapshot
  scope stableMigrationKey specDigest planDigest              -- constructor hidden
data FrozenMigrationRunLease
  scope brokerGeneration stableMigrationKey migrationId
  oldSpecDigest oldPlanDigest frozenRevisionVersion           -- constructor hidden
data OwnedDisposition
data ReleasedDisposition
data PlanMigrationAuthority
  scope brokerGeneration migrationId oldPlanDigest newPlanDigest
  frameKey resourceKey resource generation ownershipOperation ownershipOperationKey
  ownershipDisposition identityPolicyDigest recordSetDigest frozenRevisionVersion
                                                              -- constructor hidden
data VerifiedResourceRecordBundle
  scope planDigest frameKey resourceKey resource generation
  ownershipOperation ownershipOperationKey ownershipDisposition recordSetDigest
                                                              -- constructor hidden
data VerifiedResourceRecordSet
  scope planDigest requiredResourceSet                        -- constructor hidden
data MigratedResource
  scope brokerGeneration migrationId oldPlanDigest newPlanDigest
  resourceKey ownershipDisposition recordSetDigest
                                                               -- constructor hidden
data MigrationManifest
  scope brokerGeneration migrationId oldPlanDigest newPlanDigest
  requiredResourceSet frozenRevisionVersion
                                                               -- constructor hidden
data MigratedResourceSet
  scope brokerGeneration migrationId oldPlanDigest newPlanDigest requiredResourceSet
                                                               -- constructor hidden
data OldRevisionSettled
  scope brokerGeneration migrationId oldPlanDigest frozenRevisionVersion
                                                               -- constructor hidden
data ActivePlanRevision
  scope brokerGeneration planDigest activeRevisionVersion      -- constructor hidden
data PlanMigrationSession
  scope brokerGeneration stableMigrationKey migrationId
  oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
  requiredResourceSet frozenRevisionVersion
                                                               -- constructor hidden
data PlanMigrationAuthorities
  scope brokerGeneration migrationId oldPlanDigest newPlanDigest
  requiredResourceSet frozenRevisionVersion
                                                               -- constructor hidden
data NormalActiveRecovery
  scope specDigest planDigest planId brokerGeneration         -- constructor hidden
data IncompleteMigrationRecovery
  scope oldSpecDigest oldPlanDigest planId brokerGeneration stableMigrationKey
  newSpecDigest newPlanDigest requiredResourceSet frozenRevisionVersion
                                                               -- constructor hidden
data CompletedMigrationRecovery
  scope newSpecDigest newPlanDigest planId brokerGeneration stableMigrationKey
  oldSpecDigest oldPlanDigest requiredResourceSet activeRevisionVersion
                                                               -- constructor hidden
data PlanMigrationBarrier
  scope brokerGeneration migrationId oldPlanDigest newPlanDigest activeRevisionVersion
                                                               -- constructor hidden
data RehydratedResourceSet
  scope planDigest planId brokerGeneration requiredResourceSet -- constructor hidden
data RecoveredProjectFrame
  scope planId frame                                           -- constructor hidden
data RecoveredTeardownStepResource
  scope planDigest planId brokerGeneration frame id resource phase operation operationKey
  -- constructor hidden; closed sum of an owned managed member or a released tombstone member
data RevisionPermitAuthority
  scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
                                                               -- constructor hidden
data ProjectionBinding
  scope parentPlanId parentConfigId parentFrame childFrame childConfigDigest
                                                              -- constructor hidden
data RecoveryWireDigest
data VerifiedRecoveryWire
  scope planDigest frame recoveryWireDigest recoveryWireId    -- constructor hidden
data RecoveryProjectionBinding
  scope planDigest parentFrame childFrame recoveryWireDigest  -- constructor hidden
data ConfigHandoff
data RecoveryHandoff
data HandoffToken
  scope planDigest brokerGeneration parentFrame childFrame
  payloadKind payloadDigest verb phase                       -- constructor hidden
data HandoffGrant
  scope planDigest brokerGeneration parentFrame childFrame
  payloadKind payloadDigest verb phase                       -- constructor hidden
data VerifiedConfigWire scope childConfigDigest childConfigId -- constructor hidden
data VerifiedHandoff
  scope planDigest brokerGeneration parentFrame childFrame
  payloadKind payloadId verb phase                           -- constructor hidden
data ChildPlanAuthority
  scope specDigest planDigest brokerGeneration parentFrame childFrame
  planId configId verb phase                                 -- constructor hidden
data PermitFenceEpoch
data FenceRotationPhase
  = FenceIntentRecorded
  | FenceOutcomeUnknown
  | FenceObserved
data InitialFenceRecord
  scope planDigest resourceKey operationKey sessionId proposedFenceEpoch
  recordVersion fencePhase
                                                               -- constructor hidden
data InitialFenceRecoveryState
  = NoInitialFence
  | InitialFenceIntent
  | InitialFenceUnknown
  | InitialFenceReady
data VerifiedInitialFenceState
  scope planDigest frameKey resourceKey generation operation operationKey sessionId
  intentRecordVersion intentPhase initialFenceState
  -- constructor hidden; closed verified sum over absent, intent-recorded, outcome-unknown, or observed
  -- initial-fence state; non-absent cases retain the one stable proposed epoch and record version
data OpenOperationSession
  scope planDigest planId frame brokerGeneration sessionId verb phase sessionVersion
                                                               -- constructor hidden
data ClosedOperationSession
  scope planDigest planId frame brokerGeneration sessionId verb phase closedSessionVersion
                                                               -- constructor hidden
data CurrentBrokerSessionAdmission
  scope planDigest planId brokerGeneration                     -- constructor hidden
data RecoveredOperationSessions
  scope planDigest planId oldBrokerGeneration brokerGeneration
  requiredSessionSet requiredOperationSet
                                                               -- constructor hidden
data SessionOutcomesSettled
  scope planDigest planId frame brokerGeneration sessionId verb phase sessionVersion
                                                               -- constructor hidden
data OperationFence
  scope planDigest resourceKey operationKey sessionId fenceEpoch fenceRecordVersion
                                                               -- constructor hidden
data FenceRotationRecord
  scope planDigest resourceKey operationKey
  oldSessionId oldFenceEpoch newSessionId newFenceEpoch rotationRecordVersion rotationPhase
                                                               -- constructor hidden
data VerifiedUnknownOperation
  scope planDigest frameKey resourceKey generation operation operationKey
  oldSessionId oldFenceEpoch unknownRecordVersion unknownPhase
                                                               -- constructor hidden
data ContinuableRecoveryPhase phase where
  ContinueAcquisitionIntent
    :: ContinuableRecoveryPhase 'IntentRecorded
  ContinueReservedAcquisition
    :: ContinuableRecoveryPhase 'Reserved
  ContinueAdoptionIntent
    :: ContinuableRecoveryPhase 'AdoptionIntentRecorded
  ContinueRepairIntent
    :: ContinuableRecoveryPhase 'RepairIntentRecorded
  ContinueManagedPhaseIntent
    :: ContinuableRecoveryPhase 'PhaseIntentRecorded
  -- constructors are module-private; these phases precede their backend-call unknown state
data VerifiedContinuableOperation
  scope planDigest frameKey resourceKey generation operation operationKey
  continuableRecordVersion continuablePhase                   -- constructor hidden
data RetryableRecoveryPhase phase where
  RetryReservationAbsent
    :: RetryableRecoveryPhase 'ReservationAbsent
  RetryEffectAbsent
    :: RetryableRecoveryPhase 'EffectAbsent
  RetryOrdinaryTeardownPresent
    :: RetryableRecoveryPhase 'Committed
  RetryAdoptionAbsent
    :: RetryableRecoveryPhase 'AdoptionObservedAbsent
  RetryAdoptedTeardownPresent
    :: RetryableRecoveryPhase 'AdoptionCommitted
  RetryRepairOriginal
    :: RetryableRecoveryPhase 'RepairObservedOriginal
  RetryManagedPhaseFrom
    :: RetryableRecoveryPhase 'PhaseObservedFrom
  -- constructors are module-private; this is the complete retry whitelist
data VerifiedRetryableOperation
  scope planDigest frameKey resourceKey generation operation operationKey
  retryRecordVersion retryPhase                              -- constructor hidden
data VerifiedSuccessfulOperation
  scope planDigest frameKey resourceKey generation operation operationKey
  successRecordVersion successPhase                          -- constructor hidden
data VerifiedTerminalOperation
  scope planDigest frameKey resourceKey generation operation operationKey
  terminalRecordVersion terminalPhase                        -- constructor hidden
data SomeRecoveredOperationWork
  scope planDigest planId frame brokerGeneration activeRevisionVersion
  sessionId verb phase sessionVersion journalVersion
  -- constructor hidden; closed sum of Unknown, Continuable, Retryable, Successful, or Terminal;
  -- every branch retains the exact current Open session/state/revision-permit triple
data OldPermitsFenced
  scope planDigest resourceKey operationKey unknownRecordVersion
  oldSessionId oldFenceEpoch newSessionId newFenceEpoch
                                                               -- constructor hidden
data OperationRequest
  scope planDigest planId frame brokerGeneration sessionId
  authorityEpoch verb phase frameKey resourceKey generation operation operationKey
  expectedRecordVersion expectedPhase preconditionSetId backendCallDigest
                                                               -- constructor hidden
data VerifiedBackendCall
  scope planDigest planId frame id resource operation operationKey
  preconditionSetId backendCallDigest
                                                               -- constructor hidden
data PersistedReceiptRecord                                  -- stable bytes, no capabilities
data FenceableBackend resource                               -- constructor hidden
data VerifiedReceiptRecord
  scope planDigest frameKey resourceKey generation operation operationKey -- constructor hidden
data AdoptionGenerationStart
  scope planDigest frameKey resourceKey resource generation operationKey
                                                               -- constructor hidden
data RepairGenerationStart
  scope planDigest frameKey resourceKey resource generation from to operationKey
                                                               -- constructor hidden
data ManagedPhaseGenerationStart
  scope planDigest frameKey resourceKey resource generation from to operationKey
                                                               -- constructor hidden
data InitialOperationPhase
  scope planDigest planId frame frameKey resourceKey id resource
  generation operation operationKey initialPhase where
  InitialFirstAcquire
    :: FirstAcquisitionGeneration
         scope planDigest planId frame frameKey resourceKey id resource operationKey generation
    -> InitialOperationPhase
         scope planDigest planId frame frameKey resourceKey id resource
         generation AcquireOperation operationKey IntentRecorded
  InitialFreshAcquire
    :: FreshGeneration
         scope planDigest planId frame frameKey resourceKey id resource
         oldOperation oldOperationKey oldGeneration operationKey generation
    -> InitialOperationPhase
         scope planDigest planId frame frameKey resourceKey id resource
         generation AcquireOperation operationKey IntentRecorded
  InitialAdoption
    :: AdoptionGenerationStart
         scope planDigest frameKey resourceKey resource generation operationKey
    -> InitialOperationPhase
         scope planDigest planId frame frameKey resourceKey id resource
         generation AdoptOperation operationKey AdoptionIntentRecorded
  InitialRepair
    :: RepairGenerationStart
         scope planDigest frameKey resourceKey resource generation from to operationKey
    -> InitialOperationPhase
         scope planDigest planId frame frameKey resourceKey id resource
         generation (RepairOperation resource from to) operationKey RepairIntentRecorded
  InitialManagedPhase
    :: ManagedPhaseGenerationStart
         scope planDigest frameKey resourceKey resource generation from to operationKey
    -> InitialOperationPhase
         scope planDigest planId frame frameKey resourceKey id resource
         generation (PhaseOperation resource from to) operationKey PhaseIntentRecorded
  -- constructors are module-private. Adoption/repair/phase evidence comes only from the matching
  -- verified observation or managed handle/receipt; ordinary/adopted release continues its operation.

withFirstAcquisitionGeneration
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource AcquireOperation operationKey
  -> (forall generation.
        FirstAcquisitionGeneration
          scope planDigest planId frame frameKey resourceKey id resource operationKey generation
        -> a)
  -> Either JournalConflict a

firstAcquisitionIntent
  :: FirstAcquisitionGeneration
       scope planDigest planId frame frameKey resourceKey id resource operationKey generation
  -> InitialOperationPhase
       scope planDigest planId frame frameKey resourceKey id resource
       generation AcquireOperation operationKey IntentRecorded

freshAcquisitionIntent
  :: FreshGeneration
       scope planDigest planId frame frameKey resourceKey id resource
       oldOperation oldOperationKey oldGeneration operationKey generation
  -> InitialOperationPhase
       scope planDigest planId frame frameKey resourceKey id resource
       generation AcquireOperation operationKey IntentRecorded

registerOperationIntent
  :: ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> CurrentBrokerSessionAdmission
       scope planDigest planId brokerGeneration
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> InitialOperationPhase
       scope planDigest planId frame frameKey resourceKey id resource
       generation operation operationKey initialPhase
  -> (forall nextSessionVersion nextJournalVersion.
        VerifiedJournalRecord
          scope planDigest frameKey resourceKey generation operation operationKey
          nextJournalVersion initialPhase
        -> VerifiedInitialFenceState
             scope planDigest frameKey resourceKey generation operation operationKey sessionId
             nextJournalVersion initialPhase NoInitialFence
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase nextSessionVersion
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

operationRequest
  :: CommandAuthority
       scope planId frame (BrokerEpoch brokerGeneration) verb phase
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> VerifiedJournalRecord
       scope planDigest frameKey resourceKey generation operation operationKey
       expectedRecordVersion expectedPhase
  -> VerifiedBackendCall
       scope planDigest planId frame id resource operation operationKey
       preconditionSetId backendCallDigest
  -> OperationPreconditionSet
       scope planDigest planId frame id resource generation operation operationKey
       preconditionSetId backendCallDigest
  -> OperationRequest
       scope planDigest planId frame brokerGeneration sessionId
       (BrokerEpoch brokerGeneration) verb phase frameKey resourceKey generation
       operation operationKey expectedRecordVersion expectedPhase
       preconditionSetId backendCallDigest

withOpenOperationSession
  :: ActiveProjectMode scope brokerGeneration
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> CurrentBrokerSessionAdmission
       scope planDigest planId brokerGeneration
  -> CommandAuthority
       scope planId frame (BrokerEpoch brokerGeneration) verb phase
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState
       scope planId journalVersion OpenProject
  -> (forall sessionId sessionVersion nextJournalVersion.
        OpenOperationSession
          scope planDigest planId frame brokerGeneration
          sessionId verb phase sessionVersion
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

verifySessionOutcomesSettled
  :: RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> (SessionOutcomesSettled
        scope planDigest planId frame brokerGeneration
        sessionId verb phase sessionVersion
      -> a)
  -> IO (Either ReconcileError a)

closeOperationSession
  :: OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> SessionOutcomesSettled
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> (forall closedSessionVersion nextJournalVersion.
        ClosedOperationSession
          scope planDigest planId frame brokerGeneration
          sessionId verb phase closedSessionVersion
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

withCurrentOperationFence
  :: ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> FenceableBackend resource
  -> OperationRequest
       scope planDigest planId frame brokerGeneration sessionId
       (BrokerEpoch brokerGeneration) verb phase frameKey resourceKey
       generation operation operationKey expectedRecordVersion expectedPhase
       preconditionSetId backendCallDigest
  -> VerifiedInitialFenceState
       scope planDigest frameKey resourceKey generation operation operationKey sessionId
       expectedRecordVersion expectedPhase initialFenceState
  -> (forall fenceEpoch fenceRecordVersion nextSessionVersion nextJournalVersion.
        InitialFenceRecord
          scope planDigest resourceKey operationKey sessionId fenceEpoch
          fenceRecordVersion FenceObserved
        -> OperationFence
          scope planDigest resourceKey operationKey
          sessionId fenceEpoch fenceRecordVersion
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase nextSessionVersion
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

fenceUnknownOperation
  :: ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       newSessionId verb phase newSessionVersion
  -> FenceableBackend resource
  -> VerifiedUnknownOperation
       scope planDigest frameKey resourceKey generation operation operationKey
       oldSessionId oldFenceEpoch unknownRecordVersion unknownPhase
  -> (forall newFenceEpoch rotationRecordVersion newFenceRecordVersion
             nextSessionVersion nextJournalVersion.
        FenceRotationRecord
          scope planDigest resourceKey operationKey
          oldSessionId oldFenceEpoch newSessionId newFenceEpoch
          rotationRecordVersion FenceObserved
        -> OldPermitsFenced
          scope planDigest resourceKey operationKey
          unknownRecordVersion
          oldSessionId oldFenceEpoch newSessionId newFenceEpoch
        -> OperationFence
          scope planDigest resourceKey operationKey
          newSessionId newFenceEpoch newFenceRecordVersion
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             newSessionId verb phase nextSessionVersion
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

prepareOperation
  :: ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> ProjectOperationState
       scope planId journalVersion OpenProject
  -> CommandAuthority
       scope planId frame (BrokerEpoch brokerGeneration) verb phase
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> OperationFence
       scope planDigest resourceKey operationKey
       sessionId fenceEpoch fenceRecordVersion
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource operation operationKey
  -> OperationRequest
       scope planDigest planId frame brokerGeneration sessionId
       (BrokerEpoch brokerGeneration) verb phase frameKey resourceKey generation
       operation operationKey expectedRecordVersion expectedPhase
       preconditionSetId backendCallDigest
  -> OperationPreconditionSet
       scope planDigest planId frame id resource generation operation operationKey
       preconditionSetId backendCallDigest
  -> (forall attemptId nextSessionVersion nextJournalVersion.
        PreparedOperation
             scope planDigest planId frame brokerGeneration sessionId
             (BrokerEpoch brokerGeneration) verb phase
             id resource generation operation operationKey
             preconditionSetId backendCallDigest attemptId fenceEpoch nextJournalVersion
        -> PreparedPreconditions
             scope planDigest planId frame id resource generation operation operationKey
             preconditionSetId backendCallDigest attemptId nextJournalVersion
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase nextSessionVersion
        -> ProjectOperationState
             scope planId nextJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion nextJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

withChildProjectPlan
  :: ProjectVerb verb
  -> VerifiedHandoff
       scope planDigest brokerGeneration parentFrame childFrame
       ConfigHandoff configId verb phase
  -> VerifiedConfigWire scope childConfigDigest configId
  -> ValidatedConfig scope specDigest configId (cfg scope)
  -> NonEmpty (PlanDraft scope specDigest (cfg scope))
  -> (forall planId.
        ChildPlanAuthority
          scope specDigest planDigest brokerGeneration parentFrame childFrame
          planId configId verb phase
        -> ProjectPlan scope specDigest planId configId cfg
        -> PlanDigestBinding scope specDigest planDigest planId
        -> a)
  -> Either AuthorityError a

bindRunLease
  :: UnboundRunLease scope brokerGeneration
  -> VerifiedPlanSnapshot scope specDigest planDigest
  -> (BoundRunLease scope specDigest planDigest brokerGeneration -> IO a)
  -> IO (Either LeaseConflict a)

withPersistedPlanSnapshot
  :: RootInvocationAuthority scope brokerGeneration ProjectUp
  -> UnboundRunLease scope brokerGeneration
  -> ProjectPlan scope specDigest planId configId cfg
  -> (forall planDigest.
        VerifiedPlanSnapshot scope specDigest planDigest
        -> BoundPlanSnapshot scope specDigest planDigest planId
        -> PlanDigestBinding scope specDigest planDigest planId
        -> BoundRunLease scope specDigest planDigest brokerGeneration
        -> NormalActiveRecovery
             scope specDigest planDigest planId brokerGeneration
        -> IO a)
  -> IO (Either SnapshotError a)

withBoundPlanSnapshot
  :: RootInvocationAuthority scope brokerGeneration verb
  -> UnboundRunLease scope brokerGeneration
  -> VerifiedPlanSnapshot scope specDigest planDigest
  -> (forall planId.
        BoundPlanSnapshot scope specDigest planDigest planId
        -> PlanDigestBinding scope specDigest planDigest planId
        -> BoundRunLease scope specDigest planDigest brokerGeneration
        -> BoundInvocationRecovery
             scope specDigest planDigest planId brokerGeneration
        -> IO a)
  -> IO (Either SnapshotError a)

withProductionInvocationRecovery
  :: BoundInvocationRecovery
       (Production projectId) specDigest planDigest planId brokerGeneration
  -> (BoundRevisionRecovery
        (Production projectId) specDigest planDigest planId brokerGeneration
      -> IO a)
  -> (forall verb activeRevisionVersion completionJournalVersion
             requiredSessionSet requiredOperationSet requiredResourceSet closeRecordVersion.
        IncompleteProductionInvocationCloseRecovery
          projectId specDigest planDigest planId brokerGeneration verb
          activeRevisionVersion completionJournalVersion
          requiredSessionSet requiredOperationSet requiredResourceSet closeRecordVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

resumeProductionInvocationClose
  :: IncompleteProductionInvocationCloseRecovery
       projectId specDigest planDigest planId brokerGeneration verb
       activeRevisionVersion completionJournalVersion
       requiredSessionSet requiredOperationSet requiredResourceSet closeRecordVersion
  -> ProjectModeLease projectId ProductionMode brokerGeneration
  -> BoundRunLease
       (Production projectId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) specDigest planDigest planId
  -> PlanDigestBinding
       (Production projectId) specDigest planDigest planId
  -> IO
       (ProductionInvocationCloseAdvance
          projectId specDigest planDigest planId brokerGeneration verb
          activeRevisionVersion completionJournalVersion
          requiredSessionSet requiredOperationSet requiredResourceSet)

withHarnessInvocationRecovery
  :: BoundInvocationRecovery
       (Harness projectId runId) specDigest planDigest planId brokerGeneration
  -> (BoundRevisionRecovery
        (Harness projectId runId) specDigest planDigest planId brokerGeneration
      -> IO a)
  -> (forall closeEpoch closeJournalVersion.
        IncompleteHarnessCloseRecovery
          projectId runId specDigest planDigest planId brokerGeneration
          closeEpoch closeJournalVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

resumeIncompleteHarnessClose
  :: AbandonedHarnessRecoveryAuthority
       projectId runId specDigest planDigest brokerGeneration
  -> IncompleteHarnessCloseRecovery
       projectId runId specDigest planDigest planId brokerGeneration
       closeEpoch closeJournalVersion
  -> ProjectModeLease
       projectId (HarnessMode runId) brokerGeneration
  -> BoundRunLease
       (Harness projectId runId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Harness projectId runId) specDigest planDigest planId
  -> PlanDigestBinding
       (Harness projectId runId) specDigest planDigest planId
  -> ( ProjectOperationState
         (Harness projectId runId) planId closeEpoch ClosingProject
     -> HarnessCloseAuthority
          projectId runId planId brokerGeneration closeEpoch
     -> HarnessCloseJournal
          projectId runId planId brokerGeneration closeEpoch closeJournalVersion
     -> HarnessClosePlan projectId runId planId brokerGeneration closeEpoch
     -> IO a
     )
  -> IO (Either TeardownError a)

withBoundRevisionRecovery
  :: BoundRevisionRecovery
       scope specDigest planDigest planId brokerGeneration
  -> (NormalActiveRecovery
        scope specDigest planDigest planId brokerGeneration
      -> IO a)
  -> (forall stableMigrationKey newSpecDigest newPlanDigest
             requiredResourceSet frozenRevisionVersion.
        IncompleteMigrationRecovery
          scope specDigest planDigest planId brokerGeneration stableMigrationKey
          newSpecDigest newPlanDigest requiredResourceSet frozenRevisionVersion
        -> IO a)
  -> (forall stableMigrationKey oldSpecDigest oldPlanDigest
             requiredResourceSet activeRevisionVersion.
        CompletedMigrationRecovery
          scope specDigest planDigest planId brokerGeneration stableMigrationKey
          oldSpecDigest oldPlanDigest requiredResourceSet activeRevisionVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

activateNormalBoundRevision
  :: NormalActiveRecovery
       scope specDigest planDigest planId brokerGeneration
  -> (forall activeRevisionVersion journalVersion requiredResourceSet.
        ActivePlanRevision
          scope brokerGeneration planDigest activeRevisionVersion
        -> AcquisitionJournal scope planId
        -> RehydratedResourceSet
             scope planDigest planId brokerGeneration requiredResourceSet
        -> ProjectOperationState scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> CurrentBrokerSessionAdmission
             scope planDigest planId brokerGeneration
        -> a)
  -> IO (Either PlanMigrationError a)

withVerifiedOperationForRecovery
  :: ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> OpenOperationSession
       scope planDigest planId frame brokerGeneration
       sessionId verb phase sessionVersion
  -> ProjectOperationState
       scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> PersistedJournalRecord
  -> (forall recoveredSessionVersion recoveredJournalVersion.
        SomeRecoveredOperationWork
          scope planDigest planId frame brokerGeneration activeRevisionVersion
          sessionId verb phase recoveredSessionVersion recoveredJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

withRecoveredOperationWork
  :: SomeRecoveredOperationWork
       scope planDigest planId frame brokerGeneration activeRevisionVersion
       sessionId verb phase sessionVersion journalVersion
  -> (forall frameKey resourceKey id resource generation operation operationKey
             oldSessionId oldFenceEpoch unknownRecordVersion unknownPhase
             preconditionSetId backendCallDigest.
        VerifiedUnknownOperation
          scope planDigest frameKey resourceKey generation operation operationKey
          oldSessionId oldFenceEpoch unknownRecordVersion unknownPhase
        -> ResourceIdentityBinding
             scope planDigest planId frame frameKey resourceKey id resource
        -> OperationBinding
             scope planDigest planId frame id resource operation operationKey
        -> VerifiedJournalRecord
             scope planDigest frameKey resourceKey generation operation operationKey
             unknownRecordVersion unknownPhase
        -> VerifiedBackendCall
             scope planDigest planId frame id resource operation operationKey
             preconditionSetId backendCallDigest
        -> OperationPreconditionSet
             scope planDigest planId frame id resource generation operation operationKey
             preconditionSetId backendCallDigest
        -> FenceableBackend resource
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase sessionVersion
        -> ProjectOperationState
             scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) verb phase
        -> a)
  -> (forall frameKey resourceKey id resource generation operation operationKey
             continuableRecordVersion continuablePhase
             preconditionSetId backendCallDigest
             fenceEpoch fenceRecordVersion.
        ContinuableRecoveryPhase continuablePhase
        -> VerifiedContinuableOperation
             scope planDigest frameKey resourceKey generation operation operationKey
             continuableRecordVersion continuablePhase
        -> ResourceIdentityBinding
             scope planDigest planId frame frameKey resourceKey id resource
        -> OperationBinding
             scope planDigest planId frame id resource operation operationKey
        -> VerifiedJournalRecord
             scope planDigest frameKey resourceKey generation operation operationKey
             continuableRecordVersion continuablePhase
        -> VerifiedBackendCall
             scope planDigest planId frame id resource operation operationKey
             preconditionSetId backendCallDigest
        -> OperationPreconditionSet
             scope planDigest planId frame id resource generation operation operationKey
             preconditionSetId backendCallDigest
        -> FenceableBackend resource
        -> OperationFence
             scope planDigest resourceKey operationKey
             sessionId fenceEpoch fenceRecordVersion
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase sessionVersion
        -> ProjectOperationState
             scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) verb phase
        -> a)
  -> (forall frameKey resourceKey id resource generation operation operationKey
             retryRecordVersion retryPhase preconditionSetId backendCallDigest
             fenceEpoch fenceRecordVersion.
        RetryableRecoveryPhase retryPhase
        -> VerifiedRetryableOperation
             scope planDigest frameKey resourceKey generation operation operationKey
             retryRecordVersion retryPhase
        -> ResourceIdentityBinding
             scope planDigest planId frame frameKey resourceKey id resource
        -> OperationBinding
             scope planDigest planId frame id resource operation operationKey
        -> VerifiedJournalRecord
             scope planDigest frameKey resourceKey generation operation operationKey
             retryRecordVersion retryPhase
        -> VerifiedBackendCall
             scope planDigest planId frame id resource operation operationKey
             preconditionSetId backendCallDigest
        -> OperationPreconditionSet
             scope planDigest planId frame id resource generation operation operationKey
             preconditionSetId backendCallDigest
        -> FenceableBackend resource
        -> OperationFence
             scope planDigest resourceKey operationKey
             sessionId fenceEpoch fenceRecordVersion
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase sessionVersion
        -> ProjectOperationState
             scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) verb phase
        -> a)
  -> (forall frameKey resourceKey generation operation operationKey
             successRecordVersion successPhase.
        VerifiedSuccessfulOperation
          scope planDigest frameKey resourceKey generation operation operationKey
          successRecordVersion successPhase
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase sessionVersion
        -> ProjectOperationState
             scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> a)
  -> (forall frameKey resourceKey generation operation operationKey
             terminalRecordVersion terminalPhase.
        VerifiedTerminalOperation
          scope planDigest frameKey resourceKey generation operation operationKey
          terminalRecordVersion terminalPhase
        -> OpenOperationSession
             scope planDigest planId frame brokerGeneration
             sessionId verb phase sessionVersion
        -> ProjectOperationState
             scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> a)
  -> a
  -- both functions are private to activateRecoveredNormalBoundRevision; the classifier is exhaustive

activateRecoveredNormalBoundRevision
  :: NormalActiveRecovery
       scope specDigest planDigest planId brokerGeneration
  -> OldPermitFenceSet
       scope planDigest oldBrokerGeneration brokerGeneration
       requiredSessionSet requiredOperationSet
  -> VerifiedSessionOperationManifest
       scope planDigest oldBrokerGeneration requiredSessionSet requiredOperationSet
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> (forall activeRevisionVersion finalJournalVersion requiredResourceSet.
        ActivePlanRevision
          scope brokerGeneration planDigest activeRevisionVersion
        -> AcquisitionJournal scope planId
        -> RehydratedResourceSet
             scope planDigest planId brokerGeneration requiredResourceSet
        -> RecoveredOperationSessions
             scope planDigest planId oldBrokerGeneration brokerGeneration
             requiredSessionSet requiredOperationSet
        -> CurrentBrokerSessionAdmission
             scope planDigest planId brokerGeneration
        -> ProjectOperationState
             scope planId finalJournalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion finalJournalVersion
        -> a)
  -> IO (Either ReconcileError a)

withRecoveredProjectFrame
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> (RecoveredProjectFrame scope planId frame -> a)
  -> Either TeardownError a

withRecoveredDescentResource
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> TeardownDescentStep
       scope planId ProjectDestroy frame childSet id operation operationKey next
  -> (forall frameKey resourceKey generation.
        RecoveredProjectFrame scope planId frame
        -> ResourceAtFrame scope planId frame id Provider
        -> ResourceHandle scope planId id Provider Managed Stopped
        -> OwnershipReceipt scope planId id Provider
        -> ResourceIdentityBinding
             scope planDigest planId frame frameKey resourceKey id Provider
        -> OperationBinding
             scope planDigest planId frame id Provider operation operationKey
        -> a)
  -> Either TeardownError a

withRecoveredTeardownStepResource
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> TeardownStep
       scope planId frame childSet verb
       id resource phase operation operationKey next
  -> (RecoveredTeardownStepResource
        scope planDigest planId brokerGeneration frame
        id resource phase operation operationKey
      -> a)
  -> Either TeardownError a

withRecoveredTeardownStepDisposition
  :: RecoveredTeardownStepResource
       scope planDigest planId brokerGeneration frame
       id resource phase operation operationKey
  -> (forall frameKey resourceKey generation.
        RecoveredProjectFrame scope planId frame
        -> ResourceAtFrame scope planId frame id resource
        -> ResourceHandle scope planId id resource Managed phase
        -> OwnershipReceipt scope planId id resource
        -> ResourceIdentityBinding
             scope planDigest planId frame frameKey resourceKey id resource
        -> OperationBinding
             scope planDigest planId frame id resource operation operationKey
        -> a)
  -> (forall frameKey resourceKey generation releaseOrigin.
        RecoveredProjectFrame scope planId frame
        -> ResourceAtFrame scope planId frame id resource
        -> VerifiedReleaseRecord
             scope planDigest frameKey resourceKey generation
             operation operationKey releaseOrigin
        -> ResourceIdentityBinding
             scope planDigest planId frame frameKey resourceKey id resource
        -> OperationBinding
             scope planDigest planId frame id resource operation operationKey
        -> a)
  -> a

withFreshGenerationAfterRelease
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> ResourceIdentityBinding
       scope planDigest planId frame frameKey resourceKey id resource
  -> OperationBinding
       scope planDigest planId frame id resource oldOperation oldOperationKey
  -> VerifiedReleaseRecord
       scope planDigest frameKey resourceKey oldGeneration
       oldOperation oldOperationKey releaseOrigin
  -> OperationBinding
       scope planDigest planId frame id resource AcquireOperation newAcquireOperationKey
  -> (forall absenceVersion newGeneration.
        VerifiedReleasedAbsence
          scope planDigest frameKey resourceKey resource oldGeneration absenceVersion
        -> FreshGeneration
             scope planDigest planId frame frameKey resourceKey id resource
             oldOperation oldOperationKey oldGeneration
             newAcquireOperationKey newGeneration
        -> a)
  -> IO (Either ReconcileError a)

-- FreshGeneration is eligibility evidence, not intent/effect authority. The only exported consumer is
-- freshAcquisitionIntent, and registerOperationIntent revalidates/consumes its exact protected
-- release/absence versions in the atomic intent+session-membership compare-and-swap.

withProjectUpMigrationProfile
  :: PlanMigrationRoot scope brokerGeneration
  -> ActiveProjectMode scope brokerGeneration
  -> BoundRunLease scope oldSpecDigest oldPlanDigest brokerGeneration
  -> BoundPlanSnapshot scope oldSpecDigest oldPlanDigest oldPlanId
  -> PlanDigestBinding scope oldSpecDigest oldPlanDigest oldPlanId
  -> NormalActiveRecovery
       scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
  -> (ProjectUpMigrationProfile
        scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
      -> BoundRunLease scope oldSpecDigest oldPlanDigest brokerGeneration
      -> BoundPlanSnapshot scope oldSpecDigest oldPlanDigest oldPlanId
      -> PlanDigestBinding scope oldSpecDigest oldPlanDigest oldPlanId
      -> NormalActiveRecovery
           scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
      -> IO a)
  -> IO (Either PlanMigrationError a)

withProspectiveMigrationPlan
  :: ProjectUpMigrationProfile
       scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
  -> BoundRunLease scope oldSpecDigest oldPlanDigest brokerGeneration
  -> BoundPlanSnapshot scope oldSpecDigest oldPlanDigest oldPlanId
  -> PlanDigestBinding scope oldSpecDigest oldPlanDigest oldPlanId
  -> NormalActiveRecovery
       scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
  -> ValidatedConfig scope newSpecDigest configId (cfg scope)
  -> NonEmpty (PlanDraft scope newSpecDigest (cfg scope))
  -> (forall candidateId newPlanDigest newPlanId.
        ProspectivePlanMigration
          scope brokerGeneration candidateId
          oldSpecDigest oldPlanDigest oldPlanId
          newSpecDigest newPlanDigest newPlanId
        -> ProjectPlan scope newSpecDigest newPlanId configId cfg
        -> ProspectivePlanSnapshot
             scope candidateId newSpecDigest newPlanDigest newPlanId
        -> ProspectivePlanBinding
             scope candidateId newSpecDigest newPlanDigest newPlanId
        -> IO a)
  -> IO (Either PlanMigrationError a)

withPlanMigration
  :: ProspectivePlanMigration
       scope brokerGeneration candidateId
       oldSpecDigest oldPlanDigest oldPlanId
       newSpecDigest newPlanDigest newPlanId
  -> ProjectPlan scope newSpecDigest newPlanId configId cfg
  -> ProspectivePlanSnapshot
       scope candidateId newSpecDigest newPlanDigest newPlanId
  -> ProspectivePlanBinding
       scope candidateId newSpecDigest newPlanDigest newPlanId
  -> (forall stableMigrationKey migrationId requiredResourceSet frozenRevisionVersion.
        ProjectPlan scope newSpecDigest newPlanId configId cfg
        -> ProspectivePlanBinding
             scope candidateId newSpecDigest newPlanDigest newPlanId
        -> VerifiedPlanSnapshot scope newSpecDigest newPlanDigest
        -> PersistedProspectivePlanSnapshot
             scope stableMigrationKey newSpecDigest newPlanDigest
        -> FrozenMigrationRunLease
             scope brokerGeneration stableMigrationKey migrationId
             oldSpecDigest oldPlanDigest frozenRevisionVersion
        -> OldRevisionSettled
             scope brokerGeneration migrationId oldPlanDigest frozenRevisionVersion
        -> MigrationManifest
             scope brokerGeneration migrationId
             oldPlanDigest newPlanDigest requiredResourceSet frozenRevisionVersion
        -> PlanMigrationAuthorities
             scope brokerGeneration migrationId
             oldPlanDigest newPlanDigest requiredResourceSet frozenRevisionVersion
        -> VerifiedResourceRecordSet
             scope oldPlanDigest requiredResourceSet
        -> PlanMigrationSession
             scope brokerGeneration stableMigrationKey migrationId
             oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
             requiredResourceSet frozenRevisionVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

withIncompletePlanMigration
  :: PlanMigrationRoot scope newBrokerGeneration
  -> IncompleteMigrationRecovery
       scope oldSpecDigest oldPlanDigest oldPlanId newBrokerGeneration stableMigrationKey
       newSpecDigest newPlanDigest requiredResourceSet frozenRevisionVersion
  -> (forall migrationId.
        VerifiedPlanSnapshot scope newSpecDigest newPlanDigest
        -> PersistedProspectivePlanSnapshot
             scope stableMigrationKey newSpecDigest newPlanDigest
        -> FrozenMigrationRunLease
             scope newBrokerGeneration stableMigrationKey migrationId
             oldSpecDigest oldPlanDigest frozenRevisionVersion
        -> OldRevisionSettled
          scope newBrokerGeneration migrationId oldPlanDigest frozenRevisionVersion
        -> MigrationManifest
          scope newBrokerGeneration migrationId
          oldPlanDigest newPlanDigest requiredResourceSet frozenRevisionVersion
        -> PlanMigrationAuthorities
          scope newBrokerGeneration migrationId
          oldPlanDigest newPlanDigest requiredResourceSet frozenRevisionVersion
        -> VerifiedResourceRecordSet
          scope oldPlanDigest requiredResourceSet
        -> PlanMigrationSession
          scope newBrokerGeneration stableMigrationKey migrationId
          oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
          requiredResourceSet frozenRevisionVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

bindLiveMigrationPlanSnapshot
  :: PlanMigrationSession
       scope brokerGeneration stableMigrationKey migrationId
       oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
       requiredResourceSet frozenRevisionVersion
  -> ProjectPlan scope newSpecDigest newPlanId configId cfg
  -> ProspectivePlanBinding
       scope candidateId newSpecDigest newPlanDigest newPlanId
  -> VerifiedPlanSnapshot scope newSpecDigest newPlanDigest
  -> PersistedProspectivePlanSnapshot
       scope stableMigrationKey newSpecDigest newPlanDigest
  -> (BoundPlanSnapshot scope newSpecDigest newPlanDigest newPlanId
        -> PlanDigestBinding scope newSpecDigest newPlanDigest newPlanId
        -> a)
  -> Either PlanMigrationError a

withRecoveredMigrationPlanSnapshot
  :: PlanMigrationSession
       (Production projectId) brokerGeneration stableMigrationKey migrationId
       oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
       requiredResourceSet frozenRevisionVersion
  -> RecoveredProductionLifecycleProfile
       projectId oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
  -> BoundPlanSnapshot
       (Production projectId) oldSpecDigest oldPlanDigest oldPlanId
  -> PlanDigestBinding
       (Production projectId) oldSpecDigest oldPlanDigest oldPlanId
  -> VerifiedPlanSnapshot
       (Production projectId) newSpecDigest newPlanDigest
  -> PersistedProspectivePlanSnapshot
       (Production projectId) stableMigrationKey newSpecDigest newPlanDigest
  -> ValidatedConfig
       (Production projectId) newSpecDigest configId (cfg (Production projectId))
  -> NonEmpty
       (PlanDraft
          (Production projectId) newSpecDigest (cfg (Production projectId)))
  -> (forall newPlanId.
        ProjectPlan
          (Production projectId) newSpecDigest newPlanId configId cfg
        -> BoundPlanSnapshot
             (Production projectId) newSpecDigest newPlanDigest newPlanId
        -> PlanDigestBinding
             (Production projectId) newSpecDigest newPlanDigest newPlanId
        -> a)
  -> Either PlanMigrationError a

migrateResourceBundle
  :: PlanMigrationAuthority
       scope brokerGeneration migrationId oldPlanDigest newPlanDigest
       frameKey resourceKey resource
       generation ownershipOperation ownershipOperationKey
       ownershipDisposition identityPolicyDigest recordSetDigest frozenRevisionVersion
  -> PlanMigrationSession
       scope brokerGeneration stableMigrationKey migrationId
       oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
       requiredResourceSet frozenRevisionVersion
  -> BoundPlanSnapshot scope newSpecDigest newPlanDigest newPlanId
  -> VerifiedResourceRecordBundle
       scope oldPlanDigest frameKey resourceKey resource generation
       ownershipOperation ownershipOperationKey ownershipDisposition recordSetDigest
  -> IO
       (Either
          PlanMigrationError
          ( VerifiedResourceRecordBundle
              scope newPlanDigest frameKey resourceKey resource generation
              ownershipOperation ownershipOperationKey ownershipDisposition recordSetDigest
          , MigratedResource
              scope brokerGeneration migrationId oldPlanDigest newPlanDigest
              resourceKey ownershipDisposition recordSetDigest
          ))

migrateRequiredResourceSet
  :: PlanMigrationAuthorities
       scope brokerGeneration migrationId
       oldPlanDigest newPlanDigest requiredResourceSet frozenRevisionVersion
  -> PlanMigrationSession
       scope brokerGeneration stableMigrationKey migrationId
       oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
       requiredResourceSet frozenRevisionVersion
  -> BoundPlanSnapshot scope newSpecDigest newPlanDigest newPlanId
  -> VerifiedResourceRecordSet
       scope oldPlanDigest requiredResourceSet
  -> IO
       (Either
          PlanMigrationError
          ( VerifiedResourceRecordSet
              scope newPlanDigest requiredResourceSet
          , MigratedResourceSet
              scope brokerGeneration migrationId
              oldPlanDigest newPlanDigest requiredResourceSet
          ))

rebindRunLeaseForMigration
  :: FrozenMigrationRunLease
       scope brokerGeneration stableMigrationKey migrationId
       oldSpecDigest oldPlanDigest frozenRevisionVersion
  -> PlanMigrationSession
       scope brokerGeneration stableMigrationKey migrationId
       oldSpecDigest oldPlanDigest newSpecDigest newPlanDigest
       requiredResourceSet frozenRevisionVersion
  -> MigratedResourceSet
       scope brokerGeneration migrationId oldPlanDigest newPlanDigest requiredResourceSet
  -> (forall newActiveRevisionVersion.
        BoundRunLease scope newSpecDigest newPlanDigest brokerGeneration
        -> ActivePlanRevision
             scope brokerGeneration newPlanDigest newActiveRevisionVersion
        -> PlanMigrationBarrier
             scope brokerGeneration migrationId oldPlanDigest newPlanDigest
             newActiveRevisionVersion
        -> a)
  -> IO (Either PlanMigrationError a)

activateMigratedPlan
  :: BoundRunLease scope newSpecDigest newPlanDigest brokerGeneration
  -> ActivePlanRevision
       scope brokerGeneration newPlanDigest activeRevisionVersion
  -> PlanMigrationBarrier
       scope brokerGeneration migrationId oldPlanDigest newPlanDigest
       activeRevisionVersion
  -> BoundPlanSnapshot scope newSpecDigest newPlanDigest newPlanId
  -> PlanDigestBinding scope newSpecDigest newPlanDigest newPlanId
  -> MigratedResourceSet
       scope brokerGeneration migrationId oldPlanDigest newPlanDigest requiredResourceSet
  -> (forall journalVersion.
        AcquisitionJournal scope newPlanId
        -> RehydratedResourceSet
             scope newPlanDigest newPlanId brokerGeneration requiredResourceSet
        -> CurrentBrokerSessionAdmission
             scope newPlanDigest newPlanId brokerGeneration
        -> ProjectOperationState scope newPlanId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope newPlanDigest newPlanId brokerGeneration
             activeRevisionVersion journalVersion
        -> a)
  -> IO (Either PlanMigrationError a)

withCompletedMigrationPlan
  :: PlanMigrationRoot (Production projectId) newBrokerGeneration
  -> CompletedMigrationRecovery
       (Production projectId)
       newSpecDigest newPlanDigest recoveredPlanId newBrokerGeneration stableMigrationKey
       oldSpecDigest oldPlanDigest requiredResourceSet activeRevisionVersion
  -> RecoveredProductionLifecycleProfile
       projectId newSpecDigest newPlanDigest recoveredPlanId newBrokerGeneration
  -> ValidatedConfig
       (Production projectId) newSpecDigest configId (cfg (Production projectId))
  -> NonEmpty
       (PlanDraft
          (Production projectId) newSpecDigest (cfg (Production projectId)))
  -> (forall migrationId newPlanId.
        VerifiedPlanSnapshot
          (Production projectId) newSpecDigest newPlanDigest
        -> PersistedProspectivePlanSnapshot
             (Production projectId) stableMigrationKey newSpecDigest newPlanDigest
        -> BoundRunLease
          (Production projectId) newSpecDigest newPlanDigest newBrokerGeneration
        -> ActivePlanRevision
             (Production projectId) newBrokerGeneration newPlanDigest activeRevisionVersion
        -> ProjectPlan
             (Production projectId) newSpecDigest newPlanId configId cfg
        -> BoundPlanSnapshot
             (Production projectId) newSpecDigest newPlanDigest newPlanId
        -> PlanDigestBinding
             (Production projectId) newSpecDigest newPlanDigest newPlanId
        -> MigratedResourceSet
             (Production projectId) newBrokerGeneration migrationId
             oldPlanDigest newPlanDigest requiredResourceSet
        -> PlanMigrationBarrier
             (Production projectId) newBrokerGeneration migrationId
             oldPlanDigest newPlanDigest activeRevisionVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

withCompletedMigrationRecovery
  :: TeardownVerb verb
  -> RootInvocationAuthority scope newBrokerGeneration verb
  -> CompletedMigrationRecovery
       scope newSpecDigest newPlanDigest recoveredPlanId
       newBrokerGeneration stableMigrationKey
       oldSpecDigest oldPlanDigest requiredResourceSet activeRevisionVersion
  -> (forall migrationId journalVersion.
        VerifiedPlanSnapshot scope newSpecDigest newPlanDigest
        -> PersistedProspectivePlanSnapshot
             scope stableMigrationKey newSpecDigest newPlanDigest
        -> BoundRunLease
          scope newSpecDigest newPlanDigest newBrokerGeneration
        -> ActivePlanRevision
             scope newBrokerGeneration newPlanDigest activeRevisionVersion
        -> BoundPlanSnapshot
             scope newSpecDigest newPlanDigest recoveredPlanId
        -> PlanDigestBinding
             scope newSpecDigest newPlanDigest recoveredPlanId
        -> PlanMigrationBarrier
             scope newBrokerGeneration migrationId
             oldPlanDigest newPlanDigest activeRevisionVersion
        -> AcquisitionJournal scope recoveredPlanId
        -> RehydratedResourceSet
             scope newPlanDigest recoveredPlanId newBrokerGeneration requiredResourceSet
        -> CurrentBrokerSessionAdmission
             scope newPlanDigest recoveredPlanId newBrokerGeneration
        -> ProjectOperationState
             scope recoveredPlanId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope newPlanDigest recoveredPlanId newBrokerGeneration
             activeRevisionVersion journalVersion
        -> IO a)
  -> IO (Either PlanMigrationError a)

cancelIncompletePlanMigrationForTeardown
  :: TeardownVerb verb
  -> RootInvocationAuthority scope brokerGeneration verb
  -> IncompleteMigrationRecovery
       scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration stableMigrationKey
       newSpecDigest newPlanDigest requiredResourceSet frozenRevisionVersion
  -> IO
       (Either
          PlanMigrationError
          ( BoundRunLease scope oldSpecDigest oldPlanDigest brokerGeneration
          , NormalActiveRecovery
              scope oldSpecDigest oldPlanDigest oldPlanId brokerGeneration
          ))
```

- The trust root is the **root invocation's** `AuthorityBroker scope brokerGeneration`. Its
  profile-specific private signing key lives in a platform-protected local authority store; the child has
  the matching project public verification key installed independently of Dhall. Production and Harness
  use disjoint signing capabilities/namespaces, so a harness broker cannot sign a Production grant.
- Before launching a child, the root broker atomically acquires or verifies an identity-bearing
  `UnboundRunLease` containing lifecycle scope, project identity, run id where applicable, and broker
  generation. `bindRunLease` is an effectful protected compare-and-swap, not a pure conversion: it checks
  the verified snapshot and atomically extends the one exact unbound record with the plan-lineage,
  finalized-spec, and revision digests. The public `withPersistedPlanSnapshot` and
  `withBoundPlanSnapshot` brackets jointly
  return the resulting `BoundRunLease`, snapshot/binding, and respectively `NormalActiveRecovery` or the
  exhaustive `BoundInvocationRecovery`; no caller receives a journal before choosing the latter's legal
  branch. No `PreparedOperation` exists before binding. Per-edge records then add the current frame, expected child frame, exact narrowed-config
  digest/stable key, and a salted digest of a cryptographically random one-time nonce—not the bearer
  token itself.
  “Atomic” here covers the broker's protected lease record only; it does not pretend to lock an external
  provider resource.
- Before the first external mutation, the root stores a protected, versioned `StablePlanSnapshot`
  containing the non-secret canonical frame/resource graph, stable resource and operation keys,
  child-first teardown order/policies, plan-lineage, finalized-spec, and revision digests, and the
  config/code/schema/snapshot-interpreter digests that produced it. It contains neither config secret values nor
  capabilities. Verification yields `VerifiedPlanSnapshot`; binding its exact revision to a freshly
  reconstructed local plan yields
  `BoundPlanSnapshot scope specDigest planDigest planId`.
  A later `down`/`destroy` interprets this snapshot rather than a possibly edited, missing sibling config
  or the current binary's newly inferred topology. An unknown snapshot version or incompatible
  code/schema/interpreter digest requires a supported, audited migration or returns
  `RequireOperatorResolution` without mutating resources.
- `PlanLineageDigest` identifies the protected project/ownership namespace; `SpecDigest` identifies the
  exact finalized non-secret runtime specification that produced the plan; `PlanDigest` identifies one
  exact plan revision under that specification; and each `ConfigDigest` identifies exact root or
  narrowed frame bytes. Every plan, verified/bound snapshot, digest binding, and bound lease carries
  both `specDigest` and `planDigest`; neither index can be forgotten and later recombined. A
  compatible configuration update may retain owned resources only after a validator compares the old
  and new snapshots and mints
  `PlanMigrationAuthority scope brokerGeneration migrationId oldPlanDigest newPlanDigest frameKey
  resourceKey resource generation ownershipOperation ownershipOperationKey ownershipDisposition
  identityPolicyDigest recordSetDigest frozenRevisionVersion` only for each unchanged resource identity,
  frame, generation, ownership operation, settled disposition, policy, complete record set, and exact
  frozen old-revision version. One shared digest index makes changed policy or omitted history
  unrepresentable;
  the proof for one key cannot migrate another.

  A `VerifiedResourceRecordBundle` is the complete durable record set for one resource generation:
  its ownership journal and, when owned, receipt, plus every non-receipt repair, managed phase,
  adoption/adopted-teardown, ordinary teardown, release tombstone, and current settled-phase record
  required to interpret that generation, all protected by `recordSetDigest`. Its hidden
  `ownershipDisposition` is either owned or released. Owned activation can rehydrate a managed
  handle/receipt; released activation can rebind only the tombstone and exact `FreshGeneration`
  eligibility. Unknown/foreign disposition is not migratable. The bundle is not merely a journal/receipt
  pair, and an omitted or unknown operation phase cannot be represented as a migratable bundle.

  Initial migration has an explicit pre-freeze construction stage.
  `withProjectUpMigrationProfile` is the sole producer of `ProjectUpMigrationProfile`. It consumes the
  exact `ProjectUp`-derived `PlanMigrationRoot`, active project mode, old-bound lease/snapshot/binding,
  and `NormalActiveRecovery` and revalidates them at one protected active-revision version without
  needing a new config, draft, candidate, or prospective snapshot. Its rank-2 callback returns that
  narrow profile only with the same old-bound package. A teardown root, fresh/unbound profile, wrong
  mode, different broker generation, or already-frozen revision cannot inhabit it.

  `withProspectiveMigrationPlan` consumes that indexed profile, the callback's old-bound package,
  scope-correct new `ValidatedConfig`, and non-empty plan drafts. In one rank-2 scope it constructs a fresh candidate `ProjectPlan`
  together with its pure canonical `ProspectivePlanSnapshot`, `ProspectivePlanBinding`, and a narrow
  `ProspectivePlanMigration` that privately owns the old-bound lease lineage. None is persisted or
  capable of opening a session or authorizing an effect. The candidate therefore exists before any
  freeze, and its stable `newPlanDigest` is not inferred after authority has been revoked.

  `withPlanMigration` is the only consumer of that exact candidate package and retained old-bound lease
  lineage. It first verifies
  topology/identity/policy compatibility and persists/fsyncs the candidate snapshot under a fresh
  protected `stableMigrationKey`. Only an authoritative read-back of those exact bytes yields the
  matching `VerifiedPlanSnapshot` and `PersistedProspectivePlanSnapshot`; a write failure or unknown
  outcome is reprobed under the same key and cannot freeze the old revision. A crash after persistence
  but before freeze leaves only a non-authorizing unreferenced prospective record, which may be removed
  only after a protected no-migration-reference proof. It never creates an incomplete migration or
  changes admission.

  After that durable snapshot exists, the gate derives—not from a caller-supplied set—and verifies the
  complete exact `VerifiedResourceRecordSet` for the active old revision and proves that all required
  old-revision operations are settled. Its single freeze compare-and-swap records the same
  `stableMigrationKey` and exact `(newSpecDigest, newPlanDigest)`, then changes the active-old
  revision from permit-open to migration-frozen, revokes current-broker session admission, drains or
  authoritatively fences every issued prepared operation, and fixes the exact journal/record-set version. Session
  opening and operation prepare both compare-and-swap that same permit-open revision/admission and
  project-journal version, so neither can race late work into the copy interval. If session opening wins
  first, the freeze cannot settle until that exact session—including a zero-operation session—is Closed;
  if freeze wins first, a retained admission/state pair is stale and opening refuses. The gate creates fresh
  generative `migrationId` and `frozenRevisionVersion` phantoms and jointly
  yields `OldRevisionSettled` only after every registered operation and every independently enumerated
  session is settled/Closed, plus the exact candidate plan/binding, verified persisted prospective
  snapshot, a `FrozenMigrationRunLease` replacing access to the old `BoundRunLease`, complete manifest,
  its exact per-resource authority set, and a
  `PlanMigrationSession` indexed by that same `stableMigrationKey`. Callers cannot supply those hidden
  values or select only a convenient subset. The same exclusive broker generation remains old-bound;
  there is no second binding of a reusable `UnboundRunLease`. No candidate, verified prospective
  snapshot, frozen session, or staged resource grants operation-effect authority before activation.

  Because broker generations and local migration capabilities are not serialized,
  `withIncompletePlanMigration` is the pre-final-CAS restart path. A fresh root invocation first verifies
  that the old digest remains the active lineage revision and binds its new exclusive broker generation
  to that old revision. Before reconstructing any local new plan, it loads the prospective snapshot
  named by the recovery record's exact `stableMigrationKey`, verifies its protected bytes and exact
  `(newSpecDigest, newPlanDigest)`, and yields that `VerifiedPlanSnapshot` only together with the matching
  `PersistedProspectivePlanSnapshot`. It then verifies the protected incomplete manifest and every
  staged `recordSetDigest`, creates a fresh generative `migrationId`, verifies/rebinds the protected
  frozen revision version, and yields `OldRevisionSettled`, the exact frozen-lease capability, manifest,
  exact authority set, and a session carrying the same stable key inside one rank-2 continuation. It
  never derives a snapshot or digest
  from the current config. A missing/replaced prospective record, changed active revision, missing/extra
  staged bundle, unresolved old operation, or manifest mismatch yields conflict/operator resolution
  rather than migration authority.

  A delayed `ProjectDown` or `ProjectDestroy` need not possess the new config needed to resume an
  incomplete migration.
  While the old revision is still active,
  `cancelIncompletePlanMigrationForTeardown` consumes the same-generation teardown root authority and
  exact `IncompleteMigrationRecovery`. One protected
compare-and-swap archives only the inactive staged new-digest records and returns the same old-bound
lease with `NormalActiveRecovery` while atomically unfreezing old teardown preparation; only
`activateNormalBoundRevision` can then prove the migration-drained revision has no older Open session
and produce the journal/rehydrated-resource/Open-state/permit/admission bundle, after which normal
snapshot-driven old-revision teardown can continue. If the
  active revision is already new, cancellation refuses and the completed-migration recovery path is
  required. Cancellation can neither delete resource records nor roll the lineage backward.

  `bindLiveMigrationPlanSnapshot` is the normal in-process binding gate while the lease remains
  old-bound. It does not rebuild the plan after freeze: it consumes the already-constructed candidate
  `ProjectPlan`/prospective binding returned by `withPlanMigration`, the exact stable-key-indexed
  persisted proof and verified snapshot, and the matching migration session. It yields only the local
  `BoundPlanSnapshot` and `PlanDigestBinding` for that existing `newPlanId`. After an abandoned
  Production `ProjectUp`, `withRecoveredMigrationPlanSnapshot` instead requires the exact old-plan
  `RecoveredProductionLifecycleProfile`, bound old snapshot/binding, stable-key-indexed session,
  persisted prospective proof, and the already-loaded verified prospective snapshot before it accepts
  a scope-correct config and drafts. It may reconstruct a fresh local plan only when their rendering
  equals those persisted bytes and digests; current config can validate/reconstruct that exact candidate
  but cannot select or infer the migration target. Both gates yield migration-local binding values that
  can validate/stage record bundles but cannot authorize effects before the active-revision
  compare-and-swap and activation barrier.

  The per-resource authority set has no public “pick a key” eliminator.
  `migrateRequiredResourceSet` owns the plan-ordered fold over the manifest, pairs every authority with
  its exact bundle, invokes the internal `migrateResourceBundle`, and rejects missing, duplicate, or
  extra keys/dispositions/digests. It jointly returns the verified new record set and the sole
  `MigratedResourceSet` constructor for that manifest.
  Internally, `migrateResourceBundle` consumes the exact per-resource authority, session,
  migration-bound new local
  plan, and
  old verified record bundle. It stages and verifies the complete new-digest bundle and returns one
  `MigratedResource`; staged records remain inactive and cannot authorize effects. The manifest's exact
  set of those members forms one `MigratedResourceSet`. Only
  `rebindRunLeaseForMigration` can finish: in one protected compare-and-swap it verifies that complete
  set, consumes/rechecks the session and `FrozenMigrationRunLease` at their exact stable key and frozen
  revision/record-set version, changes the lineage's active revision from old to new, archives the old
  active records, and transforms that sole frozen old-bound lease into the new-bound lease. It jointly
  returns the new
  `ActivePlanRevision` and one
  `PlanMigrationBarrier ... oldPlanDigest newPlanDigest`. Future old-digest lease binding and preparation
  then fail; the consumed frozen capability cannot coexist with or remint an old-bound
  lease, and rollback is a separately authorized reverse migration, never reuse of the old records.
  `activateMigratedPlan` then consumes that exact new-bound lease, active-revision proof,
  barrier, migration-bound local snapshot/binding, and complete migrated set. Only this gate rebinds the
  new plan's `AcquisitionJournal` and heterogeneous `RehydratedResourceSet` for the same `newPlanId`:
  owned members carry handles/receipts, while released members carry only rebound tombstones and
  fresh-generation eligibility. Missing/extra resources, a disposition mismatch, or a value from
  another migration cannot continue. The activation atomically rechecks that the migration's
  session-closed barrier and freeze/settlement remain current and jointly yields a fresh
  `CurrentBrokerSessionAdmission`; new-revision operation
  prepare/session opening requires those rehydrated values, that admission, the active-revision proof,
  and the barrier.

  A crash before the active-revision compare-and-swap resumes the staged incomplete set through
  `withIncompletePlanMigration` under a fresh broker generation but the same protected stable migration
  key, exact persisted prospective snapshot, and old active revision; it never deserializes the prior
  local `migrationId` or session. A crash
  during finalization observes either the old active revision or the atomically committed new one, never
  both. If the new revision committed before the process lost its local barrier,
  `withBoundRevisionRecovery` selects the completed branch. When the exact new config is available,
  `withCompletedMigrationPlan` requires the exact new-bound
  `RecoveredProductionLifecycleProfile` and first loads/verifies the prospective snapshot named by the
  completion record's `stableMigrationKey`; only the resulting exact `VerifiedPlanSnapshot` plus
  `PersistedProspectivePlanSnapshot` may be used to reconstruct and bind the configful local plan. It
  then verifies the durable completion record, active-new revision, new-bound lease, and complete
  migrated set under a fresh broker generation. It creates fresh local `migrationId`/`planId` values and
  jointly rehydrates the lease, active-revision proof, barrier, plan/binding, and migrated set for
  `activateMigratedPlan`; it neither infers the target from current config nor reopens old authority.
  When `ProjectDown`/`ProjectDestroy` lacks that config, `withCompletedMigrationRecovery` likewise loads
  the same exact stable-keyed prospective snapshot before deriving the new-revision bound snapshot and
  non-secret recovery adapter set from protected completion records, then verifies the complete
  rehydrated resource set and yields the same active-revision/barrier,
  current-broker session admission, and normal Open-state permit bundle for teardown only.
  No partial bundle set receives prepared authorization, and no `PreparedOperation` exists in the committed-new window
  before one of these activation gates succeeds. Only after activation may ordinary new-plan operations
  use rehydrated ownership/tombstones. An unknown phase must recover under the old revision first. A
  topology-changing or unrelated revision receives no such
  authority and must explicitly replace/adopt resources under normal ownership rules. Handoff always
  binds the exact new revision and exact child wire digest, so migration does not weaken config
  authentication.
- The immediate process provisions/launches the child, but it does **not** become a signing broker. It
  retains a private duplex relay to the root coordinator for the entire recursive invocation. The root
  sends a length-delimited offer containing the exact typed `HandoffToken` plus the narrowed config wire
  payload through that relay. Plan projection mints
  `ProjectionBinding scope parentPlanId parentConfigId parentFrame childFrame childConfigDigest`: it
  preserves the scope and plan revision while binding the plan's exact parent-to-child edge and
  assigning different narrowed bytes their own digest. The child binary's
  internal handoff receiver—not a shell `cat`
  wrapper—parses the frame, verifies its local project/frame/runtime facts, creates a fresh random
  challenge, and returns the challenge to the root. Tokens never appear in Dhall, command arguments,
  environment variables, or durable config files.
- The broker checks lease ownership, project/run/scope/generation/edge, config hash, token digest, and
  nonce freshness, then atomically consumes the nonce in its authoritative store. It returns a
  `HandoffGrant` authenticated over the child's fresh challenge and every indexed field shown above.
  The child verifies the grant against its pinned project public verification key and verifies the wire
  bytes against `childConfigDigest`; that creates a fresh local `childConfigId` and
  `VerifiedConfigWire`, not the parent's config identity. Combining them yields
  `VerifiedHandoff scope planDigest brokerGeneration parent child ConfigHandoff childConfigId verb
  phase`, the only
  value accepted by `withChildProjectPlan`. That rank-2 gate consumes the exact verified config/handoff
  and project plan draft, verifies the stable revision, and jointly yields a fresh local plan/binding plus
  `ChildPlanAuthority`; it never yields root, harness-root, Production-from-Harness, or signing
  authority. The command gate then consumes that exact child-plan authority. The child writes only
  authenticated config bytes and mints new in-process handles. Replay,
  wrong verb/phase/frame, stale broker generation, wrong config digest, or partial framing cannot produce
  that value. Broker loss before a grant or prepared operation is issued refuses before the corresponding
  effect.
- If that child must launch another frame, it requests the next edge from the same root broker over the
  retained relay. The root validates the derived topology and issues a fresh child-specific
  challenge/grant; no child receives a private signing key or a delegable bearer capability.
- Recovery of a nested frame does not require the old project config to exist. The bound snapshot
  produces a signed, non-secret recovery adapter wire containing only the versioned backend coordinates
  and teardown policy already committed for that child edge. Verification yields
  `VerifiedRecoveryWire` plus the exact `RecoveryProjectionBinding`; a fresh teardown-only
  `VerifiedHandoff ... RecoveryHandoff recoveryWireId verb TeardownPhase` binds that payload to the
  recorded parent and child frames. The `RecoveryHandoff` tag belongs to
  [the authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md),
  which owns every v1 protocol tag and pins each one's field shape and negative paths; a nested teardown
  and a nested recovery are one edge and share it rather than each minting a private tag. `withRecoveredProjectFrame` can mint the required local frame proof
  only from that bound snapshot, its plan binding, the complete `RehydratedResourceSet`, and the exact
  closed `TeardownAuthorizationPoint` returned by the forest.
  `withRecoveredDescentResource` returns only the exact owned stopped-provider frame/resource binding,
  managed handle, receipt, and operation binding matching the pre-descent work.
  `withRecoveredTeardownStepResource` instead returns a closed owned-or-released sum for the ordinary
  step. Its eliminator yields either that exact managed handle/receipt bundle or the exact
  `VerifiedReleaseRecord` tombstone and bindings—never both. The released branch receives no prepared
  backend-call authority; `confirmReleased` settles it internally. Only
  `withFreshGenerationAfterRelease` can combine that tombstone, the same snapshot/rehydrated set and
  bindings, a distinct new acquisition key, and an authoritative protected absence observation to mint
  `VerifiedReleasedAbsence` plus monotonic `FreshGeneration`. Missing/foreign/replaced receipt or
  tombstone records yield no evidence. That token grants only rollover eligibility:
  `freshAcquisitionIntent` is its sole exported consumer, and the next
  `registerOperationIntent` must revalidate/consume the exact release/absence version while atomically
  writing the new-generation intent and session membership. The child gate accepts those values only
  with the bound lease and recovery handoff. The point contains either the private child-settled cursor
  pair or the destroy-only pre-descent step. It
  cannot construct a normal config, `ProjectUp`, service, or build authority. Thus an edited or missing
  sibling config does not make recursive cleanup impossible, and snapshot possession alone cannot
  relabel a recovery payload for another edge.
- Each `CommandAuthority` carries a hidden, one-use invocation identity in addition to its
  scope/plan/frame/authority-epoch/verb/phase indices. `withOpenOperationSession` requires the exact
  current broker's `CurrentBrokerSessionAdmission`, then atomically consumes that identity while opening
  exactly one durable session and advancing the shared project-journal version/permit pair; calling it
  again cannot create a second session. `closeOperationSession` likewise returns the sole successor
  project state/permit pair. Session open rechecks that the active revision is permit-open and not
  migration-frozen in the same protected compare-and-swap used by migration freeze and terminal project
  close. A retained admission or state value can therefore lose that race but cannot open after either
  barrier. A consumed child-handoff nonce supplies the edge invocation identity, while a root-local
  command gets its identity from the root broker.

  Clean activation mints admission only after proving that no older-generation session remains Open.
  Abandoned-run recovery instead uses `activateRecoveredNormalBoundRevision`, whose protected,
  exact-set fold is the sole recovered-session producer. It verifies the bound snapshot, old-permit
  fence set, and manifest pairing the complete session set with its complete operation set. The session
  set is independent, so an Open session with zero operations cannot disappear behind an empty operation
  set. The fold CAS-rebinds each **existing stable session record** to the fresh broker generation and a
  fresh rank-2 local `sessionId`.

  Recovery work is internal to that protected fold, not a caller callback.
  `withVerifiedOperationForRecovery` is its private total classifier for an operation record, and
  `withRecoveredOperationWork` eliminates exactly five closed branches. An unknown branch carries the
  exact verified record/bindings/backend and narrow recovered `CommandAuthority` needed to rotate the
  fence and reprobe. A continuable branch covers only `IntentRecorded`, `Reserved`,
  `AdoptionIntentRecorded`, `RepairIntentRecorded`, or `PhaseIntentRecorded`: those records and their
  session membership were committed atomically before any corresponding backend-call unknown state.
  An initial intent is allowed to have no fence record. The classifier produces the exact closed
  `VerifiedInitialFenceState`: no fence, fence intent recorded, fence outcome unknown, or fence observed.
  Before exposing the continuable branch it reconstructs the exact request/precondition set from the
  bound plan and invokes the sole resumable
  `withCurrentOperationFence` producer under the same active mode, bound lease, session, and
  state/permit pair. That protocol durably advances one stable proposed epoch through
  `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved`, or reuses the already observed current
  fence, and threads its sole successor session/state/permit values into recovered work. `Reserved` and
  later continuable phases must already have the verified current fence. Thus the public continuable
  branch always carries a real current fence and same-key authority, without assuming that one existed
  at the intent crash boundary.
  A retryable branch exists only for
  `ReservationAbsent`, `EffectAbsent`, ordinary/adopted same-identity teardown, adoption absence,
  repair-original, or managed-phase-from; it additionally carries the already verified current-session
  fence and the same-key authority needed to call `operationRequest`/`prepareOperation`. Thus a crash
  after recording a retryable observation but before retry does not become unrecoverable. Continuable
  and retryable work still passes through `operationRequest`/`prepareOperation`; neither calls a backend
  directly. Observed-success and terminal branches carry no backend-call authority: the classifier
  commits/settles them directly.
  No constructor exists for retry from absent-loss, unexpected-third-phase, foreign, or another
  operation key.
  The fold threads every `OperationAdvance` successor state/permit pair, proves all outcomes settled, and
  closes the exact session. It rechecks protected closure before advancing and has no exported skip/no-op
  branch. Missing/duplicate session or operation records, wrong membership, wrong frame/verb/phase, or
  recovery failure prevents completion. Only both complete sets yield
  `RecoveredOperationSessions`, `CurrentBrokerSessionAdmission`, and the final state/permit pair. Thus
  recovery reopens the recorded logical session rather than allocating a second stable session or
  admitting new command sessions while an old one is unresolved.
- Before **each** external lifecycle effect, the child sends a prepare request naming that exact Open
  session, authority epoch, verb/phase, frame/resource/generation/operation key, expected journal
  version/phase, precondition-set identity, and backend-call digest. `operationRequest` is the sole
  producer: it requires the exact
  command/session, plan-digest and local resource/operation bindings, record-version-indexed verified
  journal entry, plan-owned verified backend call, and matching closed precondition set. A caller cannot
  write a stable key, omit a dependency, or choose a call digest that relabels another local resource.
  `withCurrentOperationFence` is the sole initial-fence producer for an operation with no unknown
  predecessor. It persists and idempotently resumes the same proposed epoch, contends with session/
  migration/project close, and returns the current fence only with the sole successor session,
  Open-project state, and revision-permit pair. For an unknown predecessor, `fenceUnknownOperation`
  durably advances
  `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved` using one stable proposed new fence.
  After a crash it reprobes or repeats only the idempotent set-if-newer/dedup update for that same fence;
  it never invents another retry epoch. A backend without authoritative set-if-newer or equivalent
  deduplication returns `Unsupported`.
- `prepareOperation` performs one protected compare-and-swap which revalidates every otherwise reusable
  value: the exact project-mode epoch, bound lease/broker generation, active plan revision and absence of
  a migration freeze, revision permit authority, Open project journal version, one-use command
  authority, Open session version, current fence, operation record version/phase, request digest, and
  exact plan-owned zero/one/many `OperationPreconditionSet`. It reruns every recorded probe and obtains
  the conditional backend versions before the compare-and-swap; replacement or not-ready returns without
  a prepared authorization. It advances the operation to the appropriate durable unknown phase
  **before** any backend call, advances the session record version, and jointly returns the
  attempt/fence/precondition/journal-indexed `PreparedOperation`, matching freshly verified
  `PreparedPreconditions`, and successor Open-session value together with the successor Open-project
  operation state and matching revision-permit authority at one fresh journal version. No later prepare,
  settlement proof, or project close accepts the consumed journal version. The backend adapter exposes
  no effect entry point without both prepared values, accepts no retained `Ready` or prerequisite bundle,
  consumes the pair for exactly one conditional call, durably commits the terminal observation, and returns
  `OperationAdvance` on both success and typed failure. `withOperationAdvance` exposes the result only
  with the fresh successor Open-project state and matching revision-permit authority, so later prepare,
  settlement, and close always have an inhabitable current version. The adapter rejects/deduplicates an
  older session or fence epoch even if a delayed child wakes after broker recovery. Loss before the call
  or before its observation arrives therefore leaves an explicit unknown state and forces total
  reprobe; absence/original-state recovery cannot retry until the durable fence rotation yields
  `OldPermitsFenced`.
- A terminal acknowledgment is not the first durable record of effects.
  `verifySessionOutcomesSettled` can mint version-indexed `SessionOutcomesSettled` only after every
  registered operation has a terminal persisted observation and no prepared backend call can still arrive.
  `closeOperationSession` then compare-and-swaps that exact Open-session version to Closed. A concurrent
  prepare advances the version and invalidates the retained settled proof; a concurrent close wins
  instead and makes prepare fail. The project Open→Closing CAS contends with the same prepare record, so
  close and a new operation cannot both win. A delayed request after acknowledgment, a prior broker
  generation, or a stale session/fence is rejected before effects. The root seals raw
  `PersistedReceiptRecord` bytes only from a verified commit. Store and backend verification produce
  `VerifiedReceiptRecord`, and the matching plan/frame/resource/operation bindings mint a fresh local
  `OwnershipReceipt`. The root never serializes a `ResourceHandle`, `Ready`, `JournalEntry`, or
  `OwnershipReceipt`. No child must mount or trust the root lease filesystem.
- After the successful recursive `ProjectUp` or `ProjectDown` interpreter has closed every command
  session, its terminal acknowledgment mints `ProductionInvocationCompleted` and revokes current-broker
  session admission in the same protected transition. `closeCompletedProductionInvocation` then closes
  only that bound run lease/broker invocation. Its exhaustive advance returns either the closed proof
  with the exact retained Production mode, bound snapshot/binding, active revision, journal/resource
  records, rehydrated set, and still-Open project state, or an opaque unknown-close token with no effect
  authority. Recovery classifies a persisted terminal acknowledgment separately and can only reprobe or
  resume that stable close key. `ProjectDestroy` and a true pre-effect refusal do not use this path:
  their distinct `ProductionClosureAuthorization` may call `releaseProductionMode`, which closes the
  project and clears mode.
- A handoff token/grant is consumed for **one edge invocation only**. A harness normally keeps its root
  coordinator live through bring-up, assertion, and destroy. Ordinary production `project up` may exit;
  a later `project down` or `project destroy` therefore re-runs the independent production root gate,
  verifies the protected plan snapshot/lease/journal/receipt records and current backend identities, and
  opens a **new broker generation**. It then issues fresh per-edge grants. It never relies on the old CLI
  process or reuses a consumed token. A missing terminal acknowledgment recovers from already durable
  operation records; an unknown operation is always reprobed.
- `test run` can establish only `UnboundRunLease (Harness projectId runId) brokerGeneration`, bind it to
  that run's verified snapshot, and mint only harness
  handoffs. The self-invoked real `project up` obtains only the exact `ChildPlanAuthority` and
  child-local config authority from the consumed handoff; it does not rehydrate root
  `HarnessAuthority projectId runId` or infer authority from the generated `<project>.dhall`. Before allocating a new run
  id, `test run` enumerates protected incomplete leases for this project. It reopens each exact old
  `Harness oldRunId` under non-forgeable recovery authority, binds that run's snapshot and records,
  reprobes unknown operations, and completes child-first teardown. Only a closed old lease permits a new
  run. Unknown snapshot versions, foreign replacements, or unverifiable records return a structured
  operator-resolution result; they are not bypassed by deleting the sibling config or choosing a fresh
  run id.
- An ordinary production lifecycle invocation can obtain only its exact
  `RootInvocationAuthority (Production projectId) brokerGeneration verb`, through the non-config root
  gate and an independently
  verified production lease. A harness config, lease, token, or stable resource name can never mint
  production authority.

Controller-managed service/daemon restarts and Dockerfile-time build checks are different authority
classes; they do not pretend that the original CLI broker remains live. After full plan validation and
role-wire rendering, the root broker is the sole signer of a manifest binding the exact scope, parent
`planDigest`, finalized `specDigest`, measured `binaryDigest`, frame, immutable rollout/template
`revision`, `configDigest`, `secretDigest`, selected service, `rolePlanDigest`, and permitted-effect
ceiling. The signed manifest does **not** claim to contain a Kubernetes pod UID: that per-process
identity does not exist when the pod template is signed.

Installation is one provider-specific revision protocol, not a fictional multi-object atomic write.
Kubernetes uses immutable digest-addressed ConfigMap, Secret, and signed-manifest objects referenced by
one pod-template revision. The Secret is the sole secret-bearing runtime object; secret bytes never
enter the ConfigMap, pod template, signed manifest, logs, or diagnostics. Startup hashes the actually
mounted role wire and private bundle and verifies the actual image plus the Downward-API workload
identity; any old/new mixture refuses. A host daemon
uses one same-filesystem revision directory, flushes its members, and atomically switches a current
pointer before launch. Verification uses an independently installed pinned project key; rotation and
revocation are explicit protected transitions, never fields accepted from the wire.

The platform verifier combines that signed `revision` with a separately measured immutable
`instanceId`: Kubernetes uses at least the pod UID plus authenticated container restart count, while a
host service uses a fresh OS invocation nonce. Thus two replicas of one revision and two process
incarnations in one pod are distinct. Only their conjunction yields the inseparable
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. Its hidden activation authority and
signed role-plan projection cannot be separated or cross-paired.

Secret verification has no authority cycle. The trusted platform adapter opens the private channel
identified by the activation revision/instance and supplies its actual bytes directly to the runtime
bundle verifier. Production admits only the canonical empty bundle because its non-secret role wire
already carries pointer coordinates. Harness role wires carry typed handles; the verifier matches those
handles one-for-one against the activation-bound private bundle and rejects missing, extra, duplicate,
wrong-run, or wrong-digest entries. A caller does not construct that input with a
`HarnessConfigAuthority`, and runtime verification never mints one. That authority belongs only to root
assembly and normal parent-to-child handoff; it is never a precondition for reading the private bundle
or an output of runtime promotion.

The exact narrowed role-wire bytes are then verified through
`RoleCodec scope specDigest fields` from the matching finalized runtime spec. Verification jointly
creates a fresh local `configId`, `VerifiedConfigWire scope configDigest configId`, the verified secret
bundle, and
`ValidatedServiceRequest specDigest configId secretDigest fields service`; no full
`ValidatedConfig` crosses this boundary. The signed non-secret role projection binds `specDigest`,
`binaryDigest`, `rolePlanDigest`, `configDigest`, and `secretDigest` to the parent `planDigest`. The
child rebuilds only that narrowed role plan and jointly obtains
`RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId` and
`VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects`
under a fresh local `planId`; it neither receives nor pretends to recompute the full lifecycle graph.

Before role-plan construction, the initial Prereq cursor, prerequisite checks, bind, spawn, or any other
acquisition effect, `verifyRolePlanDraft` first checks the non-empty draft and signed `rolePlanDigest`
without durable mutation. `withRoleLifecycleAdmission` then performs the sole protected
compare-and-swap that reserves one role-lifecycle invocation and mints fresh local
`planId`/`invocationId` identities for that verified draft and exact verified
`configId`/revision/`instanceId`/service. Its one-use
`RoleLifecycleAdmission scope planDigest specDigest binaryDigest planId configId frame revision
instanceId configDigest secretDigest service rolePlanDigest permittedEffects invocationId
admissionKey admissionVersion` is a required linear input to `withRuntimeRolePlan`. The activation-bound
stable key moves only Reserved→Consumed. Lost reservation acknowledgment yields
`RoleLifecycleAdmissionUnknown`; the same exact opener or `resumeRoleLifecycleAdmissionUnknown`
rehydrates the stored `planId`/`invocationId` rather than allocating another, and the current live
instance's own Reserved row is not predecessor recovery. Plan construction CAS-consumes the Reserved
version, so duplicate rehydrated tokens have one winner. That consumer is fixed to the admission's
`planId`, consumes the same `VerifiedRolePlanDraft`, and cannot independently reserve, fail on a raw
draft digest, or mint another plan/cursor. Commit-before-delivery yields only
`RolePlanOpenUnknown`; `resumeRuntimeRolePlanOpen` rehydrates the same consumed
admission/`planId`/`invocationId` and sole initial cursor. The exact opener recognizes that same-live-
activation Consumed row rather than treating it as a non-live predecessor. A duplicate
or concurrent opener therefore refuses before resource acquisition; the later Serve reservation is not
misrepresented as the first one-use gate. Acquisition and recovery use the durable role journal, so a
crash after an external call cannot be retried from names alone.

The admission CAS also independently enumerates the complete predecessor set for one stable role
placement. Its protected manifest retains every member's full **old**
plan/spec/binary/config/secret/role-plan/effect-ceiling and local
plan/config/revision/instance/invocation/journal/resource lineage rather than relabelling it with new
rollout indices. A non-empty set yields only `RoleLifecycleRecoveryRequired` plus
`VerifiedOldRoleInstanceManifest ... requiredOldInstanceSet oldRecordSetDigest`, not a new admission.
`recoverRoleLifecycle` performs the protected exact-set journal/receipt/effect fold, rejects omitted,
duplicate, extra, or substituted predecessors, and yields either an opaque unknown or
one `SettledRoleLifecycleRecovery` containing a same-new-lineage `RecoveredRoleInstanceSet` and closed
`RoleRecoveryClearance`. The unknown likewise retains the full new plan/spec/binary/config/secret/
service/role-plan/effect lineage and has exactly one `resumeRoleLifecycleRecoveryUnknown` reprobe
consumer, so neither branch can be paired with another service activation. Every manifest member carries
`VerifiedRoleInstanceNonLive` from an authoritative controller/OS observation, revalidated by the final
CAS. Non-exclusive live overlap is excluded from recovery and remains legal; only authoritatively
non-live incomplete/unclean members are settled. A live exclusive predecessor yields Busy/Conflict or
liveness Unknown without recovery authority, and an exclusive successor waits for all non-live
predecessors. The no-exclusive case requires `VerifiedNoServiceLeaseTransfer` for the whole set; the
exclusive case requires an actual
`ServiceLeaseTransferBarrier ... predecessorFenceSet newFence transferVersion` produced after
backend-atomic fencing or retained-lock settlement of every old prepared/in-flight attempt.
`resumeRoleLifecycleAdmission` consumes the single settled recovery package while atomically
revalidating every non-live witness, closing every recovered invocation, and reserving the new first
journal version. Crash/lost-ack recovery reuses
that stable transfer key. No plan, cursor, successor lease, or effect authority exists before this
transition.

The phase CPS and its live cursors, managed handles, receipts, and leases are core-internal. The only
public execution operation is the core-owned masked/bracketed `runVerifiedRuntimeRole`; project code
contributes the finalized closed service program but never receives an arbitrary `IO` callback at an
intermediate transition. The runner owns Prereq → Acquire → Ready → Serve → Drain → Exit, converts every
catchable exception or typed failure to its required successor, attempts every independent drain
operation, and exposes the report only after Exit. Uncatchable process death is recovered by the next
instance from the durable role journal and receipts.

`RetainedRoleResources` inseparably carries all owned/unknown receipts and exactly one member of a
closed lease-state sum derived before Acquire from the signed placement's `permittedEffects` ceiling:
either a proof that the ceiling permits no exclusive or mutating service effect, or a live
`ServiceGenerationLease scope specDigest planId frame revision instanceId service fence`. That lease
remains inside the retained resources through Serve and Drain. The closed interpreter seals each
mutating target and argument set as
`SealedServiceEffectCall ... targetId operationKey callDigest`; the adapter receives no separate raw
request. A
`PreparedServiceEffect ... revision instanceId ... targetId operationKey callDigest fence attempt
journalVersion` can be minted only by a protected prepare that consumes that call, the prior exact
`ServiceEffectReady` session, and whole retained package. A known prepare rejection or uncertain journal
commit yields only an indexed `ServiceEffectPrepareFailed`/`ServiceEffectPrepareUnknown` session plus the
whole retained package directly into Drain/recovery; neither can normally prepare, and no failure before
the prepared value can discard cleanup authority.

The backend consumes the prepared value carrying the sealed call and returns an advance whose eliminator yields the result only with the fresh successor journal
session under the same effect row/phase and the reconstituted whole retained package; it never yields a
bare lease detached from receipts. Observed outcomes yield a `ServiceEffectReady` session; an unknown
outcome yields only
`ServiceEffectUnknown effect targetId operationKey callDigest fence attempt`, which no normal prepare
accepts. Exact same-key/fence reprobe
must resolve it or mint
`VerifiedSameKeyRetry ... configId secretDigest ... service effects phase effect invocationId sessionId
targetId operationKey callDigest fence previousAttempt nextAttempt unknownJournalVersion
retryJournalVersion` before another attempt. Private `resumeVerifiedSameKeyRetry` jointly consumes that
exact Unknown session, retained package, and proof and returns the Ready successor plus reconstructed
sealed call only inside the same runner. That preserves the complete consumed unknown-session lineage;
same-shaped state from another target/call, config, secret bundle, row, phase, invocation, session, or
journal version cannot cross-pair. The
no-exclusive branch has no such constructor. Serve accepts only an exact registry row proved within the same placement
ceiling, so a mutating program cannot be selected on the no-lease branch. Lease transfer has an
end-to-end linearization point: the backend atomically conditions mutation on the fence token, or the
core holds a nontransferable lock/lease across the call and waits for every prepared/in-flight old
attempt to settle or become authoritatively fenced. A backend supporting neither contract is
`Unsupported`. Only the resulting typed `ServiceLeaseTransferBarrier`, wrapped by the consumed recovery
clearance, can publish the successor lease; after that every later old-instance prepare refuses.

Readiness binds exact stable managed identities. For the accelerator, the identity may be a stable
supervisor handle rather than the replaceable child PID. A child-worker restart is a core-owned
journaled/prepared supervisor transition: it invalidates the failed child, starts a successor, probes
that successor, and returns a new ready supervisor state before another request can use it. The handler
gets neither spawn/rebind authority nor an unprobed successor handle.

Inside the runner, `selectAndRunService` consumes the exact Serve cursor, role plan/binding, verified
request, ready handles, retained resources/lease state, activation, placement, and finalized registry.
Registry lookup fixes the handler's exact `effects` row. A private
`EffectAuthorization` is available only when the verified placement admits that row, and
`DurableStore` additionally requires opaque `DurablePlacementAuthority`. The gate atomically reserves
and transfers
`ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
ServePhase service effects` into an internal
`SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
fields`; no public constructor, projection, callback, or repeated eliminator exposes that package.
Selection rejection, normal completion, typed failure, caught interruption, and shutdown all become
the same mandatory Serve → Drain transition inside the runner.

An image build/check accepts only an ephemeral
`BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`
delivered through the build engine's secret/session channel and acknowledged to the root build
coordinator. Its signed grant binds the installed project, finalized spec, authenticated Production
config digest, exact `buildId`, exact source/context digest, coordinator binary identity, and exact
builder binary/image identity. Verification jointly yields
`ImageBuildFrame projectId specDigest configId frame` and the build authority only after the
scope-correct Production `ProjectCodec` has created the fresh local config identity. It is single-use;
the resulting image digest is recorded afterward. A baked `ImageBuildContainer` config is descriptive
and cannot mint it. Backends without those identity, private-channel, and replay/epoch checks return
`Unsupported`.

The current lift streams only the context-adjusted full config record, and its container path uses a
shell writer before `exec`; it does not implement the broker/challenge/grant protocol. Until the active harness, context, and
lifecycle phases land it, driving the real command preserves one forward chain but does **not** prove
cross-process production/harness isolation.

## Validation

The target is not complete until all of these gates pass:

1. Public-package tests prove that `MkReady`, caller-constructed always-ready `Probe` values, and ownership
   constructors cannot be imported. `Probe resource dependency` fixes the result kind, and opaque
   `PollPolicy` construction rejects zero attempts, negative-equivalent inputs, delay/total-duration
   overflow, and values outside the documented bound.
2. Every mutating lifecycle entry point requires the jointly produced exact target/generation/operation/
   precondition-set/call-digest/session/fence/attempt/journal-indexed `PreparedOperation` and
   `PreparedPreconditions`, or the close-journal-indexed
   `PreparedHarnessCloseOperation`; an audit test enumerates the entry points and proves that authority,
   descriptors, handles, retained `Ready`, raw prerequisite sets/authority, either half of the pair, or a
   prepared pair matched with another resource, operation binding, edge/digest/version, or teardown step
   cannot call a backend effect. Every ordinary terminal observation must
   return `OperationAdvance` on success or typed failure, and every close observation must return
   `HarnessCloseAdvance`; compile fixtures prove the result cannot be eliminated without the matching
   sole successor journal state.
3. Probe tables cover absent, present-correct, present-wrong, occupied, permission-denied, and unexpected
   IO-error states without partial filesystem calls.
4. A second reconciliation in the same plan continuation reports `ManagedResult Unchanged` and preserves
   the local generative handle/receipt. A later invocation instead preserves the stable plan lineage,
   resource generation, and operation key while total reprobe mints fresh `planId`/resource identities,
   handles, and receipts. Either path returns `ForeignResult` for a resource it does not own.
5. Fault injection after every create step rolls back only resources carrying matching ownership
   receipts.
6. Recursive `down` and `destroy` visit every child frame before the provider frame is stopped or deleted,
   and aggregate independent failures. After `down`, destroy-time provider reachability consumes the
   forest's exact closed authorization point and its private pre-descent `TeardownDescentStep`; only its
   successor forest exposes retained children, and only their later ordinary authorization point exposes
   the `SettledChildren`/cursor pair for provider stop/delete. Constructors outside the forest are
7. The demo test gate proves a test-scoped cluster and `.test_data` are used; it refuses any observation of
   the production cluster or `.data`.
8. The durable-state gate writes through the pod-visible path, destroys the whole stack, brings it up
   again, and reads the same bytes from both the host and workload.
9. Compile-fail tests prove an `Unmanaged` handle cannot be passed to mutate, stop, or destroy; an
   adoption test proves the only conversion to `Managed` requires the matching opaque
   `VerifiedForeignOrigin` and generation/observation-version/operation-key-indexed
   `AdoptionAuthority`.
10. Compile-fail tests prove production/harness handles, receipts, plans, secret configs, and transition
    descriptors cannot be mixed, even when stable names match. A root authority/profile/lease carrying
    one generative `projectId` cannot enter another installed project's pre-plan constructor.
11. Cross-process tests prove a valid handoff works once and that replayed, stale-generation,
    wrong-project, wrong-verb/phase/frame, wrong-config-digest, truncated, recorded-transcript,
    harness-to-production, and argv/environment/Dhall token attempts are refused before side effects.
    Broker loss before prepare refuses; loss after a prepared backend call leaves the exact durable unknown state.
    One command/handoff invocation cannot open two operation sessions, and teardown uses a fresh token
    rather than the consumed bring-up token.
12. Process-kill injection covers `IntentRecorded`, `ReservationOutcomeUnknown`,
    `ReservationAbsent`, `Reserved`, `EffectOutcomeUnknown`, `EffectAbsent`, `ObservedManaged`,
    `ObservedForeign`, `Committed`, `TeardownOutcomeUnknown`, and `Released`, including both sides of each
    permitted backend call. Recovery reprobes the same generation, never duplicates an uncertain create,
    never mints a receipt for foreign state, and retries only a verified same-identity teardown. The same
    matrix covers every repair and managed phase-effect state: kill after repair, boot, stop, and
    destroy-reachability calls must classify original/from, target/to, absent, unexpected-third-phase,
    and foreign observations under the same operation key, retain the original receipt, allow only
    fenced same-key original/from retry, and never enter acquisition/release rollover. The same kill matrix
    covers the kill immediately after the atomic intent/session-membership write but before any initial
    fence record, then every initial-fence durable phase and
    `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved`; the pre-record restart starts/persists
    the sole epoch, while a later restart resumes that persisted epoch. Both thread the sole successor
    session/state/permit pair, and a delayed old-session prepared operation after a new
    broker begins is rejected or deduplicated. Intent without a fence cannot prepare or call.
13. Compile-fail tests prove two `Production` plans with different generative `planId`s cannot exchange
    handles, local journals, receipts, or `PlannedEdge`s; a cross-resource transition accepts only the
    exact target/dependency edge minted by its plan. Wrong-frame placement and wrong-operation-key
    journal bindings fail independently. A positive compile fixture eliminates the actual
    provider → durable-share → stable-alias chain through `PlannedResource` bundles, proving the API can
    assemble a real dependency path without unsafe equality or existential escape. A second positive
    fixture builds the full GPU prerequisites and proves its cluster API and plugin witnesses are both
    refreshed at `PluginReady`, while a stale `ApiReady` witness is rejected. Retaining a same-resource
    `Ready` does not help: prepare reruns the exact plan probe, and wrong edge/precondition-set/call
    digest/observation version or a dependency replacement race yields no prepared pair. A
    positive fixture proves the adapter receives only the jointly fresh prepared pair.
14. Command-gate tests prove
    `CommandAuthority scope planId frame authorityEpoch verb phase` cannot authorize another authority
    epoch, verb, phase, frame, or plan, and that the independently established
    `RootInvocationAuthority` breaks the config/lifecycle bootstrap cycle without making descriptive
    config authoritative.
15. Config promotion tests prove raw child wire cannot be promoted in Production or Harness. Only
    `VerifiedConfigWire scope childConfigDigest childConfigId`, produced by verification of the exact
    grant and bytes, can construct the child
    `ValidatedConfig scope specDigest childConfigId childConfig`; the parent config
    identity cannot be reused for narrowed child bytes. Harness verification additionally retains its
    exact `runId`. Compile-fail fixtures prove a validated config, plan draft, project plan, child-plan
    authority, snapshot, binding, or bound lease indexed by another finalized spec cannot be substituted,
    even when its config shape and stable names are identical.
16. A nested two-edge process test proves each child verifies with independently installed public
    identity, relays challenges to the root broker without receiving a signing key, and obtains an
    prepared operation only after the root has durably recorded the exact unknown state. Kill/race tests
    cover session open, prepare, outcome commit/successor-state elimination, settlement, and the
    Open-session-version close CAS. Success and typed-failure outcomes each return the only current
    Open-project state/revision-permit pair. Prepare versus session close and prepare versus project
    Open→Closing each have exactly one winner; a retained settled proof, delayed request after
    acknowledgment, or stale closure proof after destroy→up cannot authorize an effect. Recovery tests
    prove clean activation refuses an older Open session, the exact-set recovery fold rebinds that
    existing logical session once, and a zero-operation Open session remains a required member.
    Kill after each of the five continuable pre-call phases—including immediately after initial intent
    and before initial-fence creation—and after recording each retryable observation
    proves the total recovery classifier re-enters prepare only through the matching continuable branch
    or one of the seven observed-state retry cases; success/terminal branches never receive backend-call
    authority. Intent registration and session membership are one atomic version transition, so neither an
    orphan intent nor an operation-less manifest member can be hidden. Missing/duplicate session or operation manifest
    members, a wrong membership edge, or an unresolved internal recovery step cannot yield
    `CurrentBrokerSessionAdmission` or start a new command session.
    Successful Production `up`/`down` fixtures additionally require terminal
    `ProductionInvocationCompleted` and race its lease-close CAS against stale session open; exactly one
    wins. Kill points before close, after commit, and before acknowledgment prove recovery resumes the
    same stable key or observes it already closed. The closed proof carries no bound lease, admission, or
    permit authority, while Production mode, snapshot, active revision, Open-project state, and the exact
    resource/receipt set remain. Neither retaining verb can construct
    `ProductionClosureAuthorization` or clear mode.
17. Delayed Production `down`/`destroy` tests run after the original `up` process has exited with the
    sibling config unchanged, edited, and missing, and with a changed installed binary. They prove a new
    root gate/broker binds the protected versioned snapshot and records rather than inferring teardown
    from current inputs; unknown/incompatible versions refuse without effects and a supported migration
    is explicit. A two-child nested case proves each delayed boundary uses a signed snapshot-derived
    recovery wire and teardown-only handoff without reconstructing the old project config. Compile/runtime
    fixtures prove `RecoveredProjectFrame`, a managed phase handle, receipt, and resource/operation
    bindings arise only from the matching bound snapshot, complete rehydrated set, and forest work;
    missing/foreign/replaced records cannot authorize either pre-descent or ordinary teardown.
18. Restart/build tests prove only the root broker can sign the exact rollout manifest. The signature
    binds scope, parent-plan/spec/binary digests, frame, rollout revision, config/secret digests, service,
    role-plan digest, and effect ceiling, but not a not-yet-created pod UID. Kubernetes tests create two
    pods of one revision and restart a container in one pod; the measured `(pod UID, restart count)`
    produces three distinct `instanceId`s. Host tests use distinct OS invocation nonces. Cross-instance,
    cross-revision, cross-spec, cross-binary, stale-restart-count, unpinned-key, and revoked-key attempts
    refuse.

    Provider fault injection publishes every old/new/absent combination of immutable ConfigMap, Secret,
    signed manifest, and pod-template reference. Startup either verifies the one complete revision and
    actual mounted bytes or refuses; no test assumes a multi-object atomic Kubernetes write. The host
    equivalent kills before/after member flush and current-pointer replacement and admits only one
    complete revision. Private-channel tests prove Production accepts only the canonical empty bundle,
    Harness handles match the exact activation-bound bundle one-for-one, and wrong-run, wrong-digest,
    missing, extra, or duplicate entries refuse. No test requires a pre-existing
    `HarnessConfigAuthority` to read that channel, and runtime verification never mints one.

    The restart verifies the actual narrowed bytes through
    `RoleCodec scope specDigest fields` into a fresh
    `ValidatedServiceRequest specDigest configId secretDigest fields service`, then verifies
    `RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId` before role execution. A
    projection bound to another parent/spec/binary/config/secret/role digest refuses. A two-opener race
    for one revision/instance/service has one role-lifecycle-admission winner before plan construction or
    acquisition; the loser cannot bind, spawn, or create a receipt. Kill-after-call-before-ack tests
    recover that acquisition through the durable role journal instead of starting a second resource.

    Public-package compile fixtures prove intermediate phase eliminators, live cursors, handles,
    receipts, leases, and `SelectedService` are not exported. The sole public role runner returns no
    observable result before Exit. Prerequisite failure with a verified empty set, every partial/unknown
    acquire, readiness failure, selection rejection, handler success/failure, shutdown, caught
    interruption, and an exception at every internal transition all reach exactly one Drain/Exit path;
    Drain attempts all independent releases and aggregates failures. Hard-kill tests instead require
    receipt/journal recovery by the next measured instance.

    Lease tests prove retained resources carry either the closed proof that the placement ceiling permits
    no exclusive/mutating effect or the exact live `ServiceGenerationLease` through Drain. Registry
    selection outside that same ceiling refuses. Only the live-lease branch can mint
    `PreparedServiceEffect` under its current fence and sealed target/call digest; wrong/no lease, old
    fence, wrong instance, target, arguments, session, or journal version cannot call or blindly repeat
    the backend. Prepare-rejection/unknown fault tests retain the sole session/package and admit only
    Drain/recovery. Crash-after-call-before-ack yields the exact parameterized Unknown state; only the
    joint full-lineage retry eliminator can resume it. Transfer tests prove a
    successor lease is withheld until the backend's atomic fence condition has excluded old mutation or
    every old prepared/in-flight attempt under a retained lock has settled or been authoritatively
    fenced; unsupported backends refuse. Non-exclusive overlapping revisions remain legal.
    Supervisor tests bind readiness to the stable supervisor identity, kill its child worker, and prove
    the core-owned prepared restart reprobes the successor before use; neither the handler nor a retained
    stale child handle can spawn, rebind, or serve.

    Selection tests prove only internal `selectAndRunService` can combine the exact Serve state,
    activation, request, placement, ready handles, retained lease state, registry handler, and effect
    row. Activation alone, non-Serve state, unauthorized effects, missing durable-placement authority,
    consumed invocation, or a second selected-package use cannot start a handler.

    A Dockerfile gate requires
    `BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`
    and rejects wrong project/spec/config/build/source/coordinator/builder identities, including
    identical config/source bytes verified for another installed project or builder. A positive fixture
    jointly constructs the Production-validated config,
    `ImageBuildFrame projectId specDigest configId frame`, and build authority. A baked config, runtime
    activation, or build authority cannot mutate lifecycle resources outside its exact class.
19. Ownership-invariant tests prove the four clauses on **every** substrate, not only the one whose
    native backend motivated them. A uniform contract requires a uniform gate, so this suite is not
    `os(windows)`-gated.
    - Filesystem adversary tests replace a reserved object from a same-privilege process between
      observation and mutation. The backend reports `Conflict` with structured expected/observed
      identity, leaves the object untouched, and mints no receipt. It must not report `Unchanged`, and
      must not clobber (clause 3).
    - Release is refused when the observed identity does not match the receipt's (clause 4).
    - A second entry attempt is excluded while the lock is held, and succeeds after the holding process
      is killed rather than unlocked — proving the lock is OS-released, not library-released (clause 1).
    - A kill between the durable origin record and the first write leaves recoverable state. The
      **absent-original** case is covered explicitly: the next run restores absence rather than treating
      generated content as the original (clause 2).
    - A clean-path run reaches absence, creates the object, and reruns to `Unchanged` with the same
      verified receipt.
    - A host that cannot satisfy a clause — no stable object identity, no available lock, no writable
      state directory — returns `Unsupported` carrying the attempted operation and reason, and mints no
      receipt.
20. Harness kill/restart tests terminate `test run` after every prepared operation and before cleanup.
    The next invocation verifies the protected incomplete-lease record and uses
    `withAbandonedHarnessRun` to reopen the exact abandoned `Harness projectId oldRunId` with only
    destroy/recovery/close authority. It first eliminates `BoundInvocationRecovery`, then the exact
    normal/incomplete/completed revision branch; it never receives a generic journal first. It
    recovers/tears that run down and closes its lease; only a
    protected empty-set compare-and-swap yields `ClosedAbandonedHarnessRuns`, which
    `withHarnessRoot` must consume before allocating a new run. Choosing a fresh run id cannot bypass
    unresolved ownership, and a concurrent lease change invalidates the proof. Cross-profile races prove
    the shared project-mode compare-and-swap prevents Production and Harness overlap, rechecks Harness
    preconditions during acquisition, retains Production mode across `down`, and releases the exact mode
    only with a settled close. Production closure fixtures prove a non-destroy verb can authorize release
    only through the exact no-resource proof, while the settled-destroy branch requires
    `ProjectDestroy`; partial teardown under `up`/`down` cannot be relabeled. A session-open versus
    Production-finalizer race has exactly one winner, and kill/restart around the atomic
    `ClosedProject`/bound-lease/mode-release transition observes either the complete old Open tuple or the
    complete closed tuple, never a partial release. Unbound recovery can obtain
    `VerifiedUnboundLeaseHasNoEffects` only
    through the exact protected-record verifier; a caller-supplied empty collection is rejected.
21. Plan-update tests distinguish a compatible config-only revision, a topology/resource-identity
    change, and unrelated project state. The new config/drafts first produce one rank-2
    pre-freeze candidate plan and non-authorizing prospective snapshot/binding. Compile fixtures prove
    `withPlanMigration` cannot be called without that exact candidate package and
    `bindLiveMigrationPlanSnapshot` cannot reconstruct or substitute a post-freeze plan. Snapshot
    persistence/unknown tests prove the old revision is not frozen until exact stable-keyed bytes have
    been fsynced and authoritatively read back; a pre-freeze crash leaves only a removable,
    non-authorizing prospective record. Additional negative fixtures prove candidate construction
    requires the exact old-bound lease/snapshot/binding and `ProjectUpMigrationProfile`; freeze replaces
    that lease with one stable-keyed `FrozenMigrationRunLease`, and only the final CAS may consume it to
    return the new-bound lease. Retaining or substituting an old lease, using a fresh/unbound profile, or
    attempting to obtain both old- and new-bound authority refuses. Only the compatible comparison then mints
    `PlanMigrationAuthority` and stages each exact complete
    `VerifiedResourceRecordBundle`/`recordSetDigest` named by the manifest so the new local plan can
    actually rebind and retain that resource. Frame, policy, generation, resource kind,
    operation/key, incomplete record bundle, unknown phase, candidate ID, stable migration key, and
    old/new spec/snapshot substitutions refuse; the migration session carries the exact stable key plus
    both `(specDigest, planDigest)` pairs, so crossing any of them cannot rebind the lease or activate the
    revision;
    the other revisions
    replace/adopt explicitly or require operator resolution. Kill injection after each resource
    migration resumes the same protected manifest under the old-bound lease. The initial freeze races
    operation prepare and session opening and must win before copying; every prior prepared operation is drained or
    authoritatively fenced, session admission is revoked, and every independently enumerated session,
    including zero-operation sessions, is Closed. The plan-owned exact-set fold rejects missing,
    duplicate, extra, or disposition-mismatched
    records, and a released tombstone remains released. Finalization atomically switches the active
    lineage revision, archives old records, rebinds that same lease, and returns one old/new-indexed
    `PlanMigrationBarrier`. Kill injection between that CAS and local activation selects completed
    recovery. Both incomplete and completed recovery must load and verify the exact persisted
    prospective snapshot named by `stableMigrationKey` before constructing any local plan; changed
    current config cannot infer or select a replacement digest. Configful `up` activates forward only
    when its reconstruction equals that snapshot, while configless `down`/`destroy` activates only
    snapshot-derived teardown. Incomplete migration may be cancelled for either teardown verb while old
    remains active. Both activation paths recheck that no old session remains Open and jointly yield the
    new revision's `CurrentBrokerSessionAdmission`; a new operation session cannot open before that
    proof. New-plan permits are impossible before activation, and old-plan binding/permits are impossible
    after the CAS; the old digest cannot reopen.
22. Teardown type/runtime tests prove a durable stop retains a `Stopped` managed handle and receipt,
    ephemeral removal and destroy yield only `ReleasedOwnership`, verified prior release requires the
    protected ordinary/adoption released record, and aggregate failures retain each resource's recovery
    state. Recovered teardown-step elimination is total over owned and released dispositions: only the
    owned branch yields a managed handle/receipt, only the released branch yields the exact
    `VerifiedReleaseRecord`, and neither missing nor mismatched data yields either. Destroy→up can mint
    `FreshGeneration` only after the sole protected absence verifier binds that release record to the
    same resource and a distinct new acquisition key. That token is only eligibility: a stale, reused,
    wrong-resource, or wrong-version token loses the atomic origin/intent/session-membership
    compare-and-swap.
23. Lifecycle-sequence tests cover `down → up`, `down → destroy`, and `destroy → up`. Durable resources
    use their typed stopped/start/reachability paths; ephemeral recreation requires a verified,
    exact-resource-and-operation
    `Released oldGeneration → FreshGeneration scope planDigest planId frame frameKey resourceKey id
    resource oldOperation oldOperationKey oldGeneration newAcquireOperationKey newGeneration →
    freshAcquisitionIntent → registerOperationIntent → IntentRecorded newGeneration` under the new
    acquisition key. First acquisition instead requires the sole no-prior-generation proof. Kill
    injection after absence proof/before registration and on both sides of registration cannot duplicate
    an uncertain generation.
24. Adoption tests kill/replay around intent, unknown, backend transfer, observation, and commit. Only
    `AdoptionCommitted` mints `AdoptedEvidence`; the original foreign entry remains terminal, and a
    backend without authoritative transfer returns `Unsupported`. Further kill/replay tests cover
    `AdoptionTeardownOutcomeUnknown → AdoptionReleased`, receipt-bound destroy, and fresh-generation
    recreation after adopted release.
25. Harness terminal-close tests prove ordinary `ProjectDown`/`ProjectDestroy` preserve the durable
    root, destroy→up within one variant reads the same bytes, and only the exact
    `HarnessCloseAuthority` releases that run's owned generated config and `.test_data/<runId>` before
    closing its bound lease. Kill injection covers the Open→Closing CAS, every close-journal
    intent/unknown/observed/released transition, success/failure `HarnessCloseAdvance`, lease close, and
    final mode release. A persisted `ClosingProject` reopens only through
    `resumeIncompleteHarnessClose`; it never remints Open or general Harness authority, and a delayed
    close permit is fenced. Production finalization atomically records `ClosedProject`, closes its
    invocation lease, and releases its mode, so it has no mode-cleared Closing intermediate. All recovery
    finishes under the old run before any new run identity is allocated. `verifyDestroySettled` refuses
    an incomplete/failed forest or live prepared operation; `verifyNoProjectResourcesAcquired` refuses any resource
    operation, prepare, fence, receipt, effect, Open session, or non-empty session while accepting only
    terminal empty sessions. Only their exact-version proofs can mint closure evidence; unresolved
    partial ownership cannot close, and Production or another run cannot construct the Harness close
    plan.

Unit tests for argv builders or pure partitions support these gates but cannot replace the required live
destroy/up/readback and native-substrate runs.

## Related

- [ownership invariant](ownership_invariant.md) — the four clauses a backend must hold before this
  model's transitions may mint a receipt, and their per-substrate realization.
- [readiness](readiness.md) — current readiness implementation and the opaque-witness target.
- [durable state](durable_state.md) — current durable carry, the stable Docker-visible alias, and its live
  validation gap.
- [harness workflow](harness_workflow.md) — current test DSL/profile mismatch and the ownership target.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/Helm behavior.
