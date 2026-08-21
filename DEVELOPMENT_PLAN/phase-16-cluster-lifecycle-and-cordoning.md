# Phase 16 — Cluster lifecycle, budgets, and cordoning

**Status**: Active
**Current sprint**: Sprint 16.45 — The readiness, cordon, and cleanup drivers
**Depends on**: Phase 12 (the generic plan-indexed budget boundary), Phase 14 (the four ownership clauses
and the ownership seam), Phase 15 (host providers and the self-reference lift)
**Substrates**: linux-cpu
**Gate**: `cd core && cabal test all --ghc-options=-Werror` host-native on every supported outer host
realization, composed with `hostbootstrap test run cluster-live` on linux-cpu

> **Purpose**: Bring a cluster up inside a declared resource budget, cordon what the project may consume, and
> keep the durable host root outside everything the lifecycle may delete.

## Phase Objective

A cluster is the innermost frame most deployments end in. Three things must be true of it: it fits inside a
budget the project declared, its compute slice is applied at the cluster while storage is enforced at a
supported provider wall or retained as an explicit unsupported runtime decision, and its teardown cannot
reach the durable state the project exists to keep. This phase adopts those mechanics at the exact cluster
and direct-Colima consumers. The provider-neutral capacity/sizing/cordon foundation comes from Phase 6, the
generic plan-indexed budget algebra comes from Phase 12, and the worked demo later supplies its concrete
workload, overhead, partition, and slice projection.

Two boundaries are worth naming because they sit close to this phase's own. Recursive and demo call-site
adoption of these consumers belongs to the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) and the
[worked-demo phase](phase-24-worked-demo.md), not here. And the direct-Colima driver's *static* coverage
closes on any POSIX gate host once its classification is pure, so no sprint here waits on Apple hardware;
only the live confirmation does, and the
[Apple-Silicon-substrate phase](phase-25-apple-silicon-substrate.md) lists it among what it confirms.

The Phase 16 whole-graph build also revalidates several already-owned generic boundaries after adjacent
exact-plan callbacks were generalized and rebuilt with GHC 9.12: Phase 12.2's Type-kinded `StepAction`,
Phase 12.30's existential budget-slice traversal,
Phase 12.15–12.18's `ProjectPlan.Snapshot` callbacks, the nine rank-2 lifecycle-mode callbacks owned by
completed Phase 9, Phase 12, and Phase 18.1–18.3 contracts,
Phase 12.25's existential protected-session capture, and Phase 19.1/19.3's Harness ownership callback. It
likewise widens only the existing Phase 7.5/22.2 `ServiceHandler`/`withSelectedServiceRequest` boundary. These
are mechanical integration repairs to `HostBootstrap.Step`, `HostBootstrap.Cluster.Budget`,
`HostBootstrap.ProjectPlan.Snapshot`, `HostBootstrap.Lifecycle.Mode`, `HostBootstrap.Lifecycle.Session`,
`HostBootstrap.Harness.Ownership.Internal`, and `HostBootstrap.Service`; they do not re-own those contracts,
advance a lower or later phase's status, or adopt Phase 22 service execution.

## Sprints

### Sprint 16.1: Closed cluster execution backend [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Make the executor that can mint cluster backend facts a closed, bounded capability.

#### Deliverables

- `StrongClusterBackend` and every executable interpreter constructor live in a Cabal-private component;
  downstream callers can open only the closed production resolver.
- Production discovery admits fixed or freshly resolved absolute cluster-driver, container-runtime, `kubectl`,
  util-linux `flock`, and Python executables only after validating the complete trusted path. Linux/POSIX
  `lockf` is not treated as an equivalent frontend.
- The retained backend fixes its working directory, environment, provider/Docker namespace, and executable
  search path; no caller-supplied executor, tool path, `HOME`, `DOCKER_CONFIG`, or ambient current directory
  can mint backend results.
- Every outer process call has a process-group-safe finite deadline, bounded pipe draining and reaping, and
  preserves asynchronous exceptions. A descendant that ignores TERM and retains pipes cannot hang the caller.
- Public call-result constructors remain opaque and nominal. Tests reach injected interpreters only by
  depending on the private component.

#### Validation

`ClusterBackendSpec` exercises trusted discovery, caller-injection refusal, closed namespace propagation,
process-group timeout/reap behavior, and injected private-component execution. Compile-fail coverage rejects
the private module and backend/result construction from a downstream component.

#### Remaining Work

None.

### Sprint 16.2: Durable cluster ownership namespace [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Establish clauses 1 and 2 of locked-origin ownership for the cluster state namespace.

#### Deliverables

- State-root traversal opens every existing component without following symbolic links, creates only the
  exact pristine owned leaf, validates ownership/mode and opened-versus-path identity, and synchronizes each
  required parent directory.
- One regular no-follow lock object is identity-checked before and after acquisition and retained across
  calls; util-linux `flock` holds that exact inherited descriptor for the whole backend transaction.
- The canonical prepared/executing/managed origin grammar self-binds its own record identity and binds the
  plan owner, cluster name, prior absence, config digest, fresh 256-bit nonce, and immutable backend identity.
- Initial publication uses a synchronized exclusive stage, no-replace publication, directory synchronization,
  and authoritative readback. Managed replacement and release retain the exact record object through the
  transition and synchronize/read back the result.
- Before cluster creation, the executing transition durably binds the exact config and private-kubeconfig
  snapshot objects. Recovery accepts only canonical state-specific stages belonging to the same owner, nonce,
  and recorded object identities. A foreign, symbolic, copied, replaced, incomplete, or ambiguous
  state/record/stage is a structured refusal rather than an adoption or absence.

#### Validation

`ClusterBackendSpec` covers pristine creation, intermediate and final symlink refusal, foreign owner/mode,
lock and state-directory replacement, byte-identical record replacement, origin-before-mutation, crash after
prepared publication, managed-transition recovery, fsync/readback failure, and serialized concurrent entry.

#### Remaining Work

None.

### Sprint 16.3: Identity-bound cluster reconcile and status [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/readiness.md`

#### Objective

Run creation and observation against exact retained bytes and immutable backend identities.

#### Deliverables

- Production config is opened by component-wise no-follow traversal, size-bounded, digest-checked under the
  ownership lock, and retained through execution by an immutable descriptor-backed snapshot. Harness omits
  the config flag entirely.
- Creation uses a private isolated kubeconfig rather than ambient `$HOME/.kube/config`; its exact object and
  namespace are owned by the same transaction.
- Driver-list, runtime identity, and Kubernetes probes classify exit failure, timeout, duplicate names,
  malformed stdout, any stderr, CR, and missing final newline explicitly; failure never collapses into absence.
- The created control-plane container ID is raw backend identity. The managed record also binds the complete
  declared node-name-to-container-ID map, and no caller-provided journal generation substitutes for it.
- The status route is read-only, uses the closed backend, and returns present, absent, or a structured probe
  failure without minting mutation authority.

#### Validation

`ClusterBackendSpec` executes the embedded protocol and covers Production/Harness config behavior, mutable
source drift, snapshot replacement, private kubeconfig use, first creation, healthy prior state, driver/probe
failures, strict report framing, immutable IDs, complete node-set binding, and read-only status.

#### Remaining Work

None.

### Sprint 16.4: Identity-conditional raw cluster operations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/applied_cordon.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Supply clause-3/4 cordon, readiness, and release operations over the retained cluster identity.

#### Deliverables

- Cordon re-enters the exact lock/record namespace, revalidates the retained control-plane and complete node
  IDs, and addresses Docker updates by immutable container ID rather than a reusable node name.
- Readiness revalidates that same identity, the Kubernetes API, and exactly the declared node set under finite
  bounds; an added, missing, unready, or replaced node cannot report Ready.
- Cleanup accepts only the exact retained record/state/lock identity, conditionally deletes the matching
  cluster, and independently proves every retained node container absent before releasing origin state.
- A replacement, partial deletion, driver-list failure, runtime-probe failure, or durable-unlink failure
  preserves the origin and returns structured conflict/failure.
- All raw reports are strict, plan-independent backend facts. They cannot be constructed or settled as exact
  plan authority by public callers.

#### Validation

`ClusterBackendSpec` covers identity-matched cordon/readiness/cleanup, replacement during each operation,
node-ID targeting, exact readiness membership, partial deletion, already-settled absence, strict probe/report
failure, origin retention, and operation serialization.

#### Remaining Work

None.

### Sprint 16.5: Exact plan-owned cluster consumer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Join the exact cluster package projected by one admitted `ProjectPlan`.

#### Deliverables

- `PlanOwnedCluster` consumes one `ProjectPlan`, its matching cluster and provider `PlannedResource`s, the
  exact retained `DerivedTopology`, and the matching cluster `ResourceSlice` from Phase 12.
- Shared nominal indices and term checks reject a foreign resource, topology, edge, frame, or slice. The
  consumer accepts no compatibility lifecycle plan, caller profile/root, or independently assembled graph.
- The package derives the Production or generative Harness cluster identity, removable state directory,
  durable root, placement, ownership binding, node names, and optional absolute driver-config path.
- This phase selects and binds an existing config path; it does not render the demo's concrete kind/nvkind
  YAML or choose its NodePort and host-port set. That concrete projection belongs to the worked demo.

#### Validation

`ClusterReconcileSpec` covers Production and Harness derivation, exact resource/topology/slice agreement, and
term-level mismatch refusal. `CrossPlanClusterConsumer.hs` and `CompatibilityClusterInputs.hs` reject foreign
plan members and the compatibility consumer shape.

#### Remaining Work

None.

### Sprint 16.6: Backend-minted Running-provider dependency [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Pair the exact managed Running provider with the fresh reprobe owned by the backend that minted it.

#### Deliverables

- `RunningProviderDependency` is constructed only by the strong provider backend from a successful Running
  transition and retains the exact provider origin plus its backend-owned fresh reprobe.
- Public consumers can neither supply a `DependencyProbe` nor recover the generic managed provider handle.
- A Provisioned, Stopped, foreign-plan, or role-coerced provider cannot inhabit the dependency package.
- Cluster preparation consumes this package and reruns its real probe instead of trusting a retained
  observation.

#### Validation

`ClusterReconcileSpec` covers backend minting and fresh reprobe. `CallerForgedClusterProbe.hs`,
`ProvisionedProviderClusterDependency.hs`, `ForgeClusterAuthorities.hs`, and
`CoerceClusterAuthorityRoles.hs` pin construction, phase, and nominal-role boundaries.

#### Remaining Work

None.

### Sprint 16.7: Prepared cluster reconcile transaction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Prepare one exact cluster reconcile call only after its plan package, provider dependency, and journal gate
agree.

#### Deliverables

- `PreparedClusterReconcile` retains the complete `PlanOwnedCluster`, exact observed cluster handle, prepared
  operation, preconditions, operation digest, attempt, and journal version.
- Preparation consumes `RunningProviderDependency` and builds the dependency precondition internally; there
  is no caller-built snapshot, probe, digest, frame, profile, or root.
- Production preparation reads the exact selected config bytes, records their SHA-256 with the call, and
  refuses a missing or symbolic path. Harness preparation retains no config and emits no config argument.
- The locked backend revalidates the same path and digest before mutation, so changed bytes cannot execute the
  already-prepared call.

#### Validation

Focused reconciliation/backend cases cover exact preparation, provider reprobe, Production versus Harness
config presence, missing/symbolic/changed config refusal, and stable operation/precondition lineage. Public
constructor and compatibility compile-fail fixtures remain registered.

#### Remaining Work

None.

### Sprint 16.8: Identity-bound cluster settlement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Settle raw cluster facts into managed authority without confusing journal generation with backend identity.

#### Deliverables

- `ManagedClusterHandle` retains the exact resource handle, ownership receipt, and immutable backend identity;
  the journal generation remains the separate version minted by reconciliation.
- `ClusterReconcileSettlement` exposes managed authority only through its owned branch and retains a foreign
  result without manufacturing a handle or receipt.
- Created and healthy observations settle only against the exact prepared call. Unhealthy, failed, and
  replacement observations remain typed refusal or failure with no adoption or automatic deletion.
- Constructors and plan indices remain hidden or nominal across the public library boundary.

#### Validation

`ClusterReconcileSpec` covers created/healthy settlement, backend-identity versus journal-generation
separation, foreign and unhealthy branches, and replacement refusal. Forge and role-coercion fixtures reject
public authority construction and cross-plan relabelling.

#### Remaining Work

None.

### Sprint 16.9: Applied cluster cordon [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/applied_cordon.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Apply the exact admitted cluster slice only to the exact managed cluster identity.

#### Deliverables

- `PreparedClusterCordon` is derived from the exact prepared package and matching managed cluster; callers
  cannot independently supply the budget, nodes, state path, or ownership identity.
- The backend re-observes immutable control-plane identity under the same ownership lock before applying the
  retained CPU and memory arguments. It also retains the typed bare-Linux/Docker-node unsupported-storage
  decision; storage remains a preflight/provider-wall constraint rather than a `docker update` argument.
- `AppliedClusterCordon` is minted only after exact application. A replaced identity, invalid slice, failed
  driver call, or malformed report yields no applied authority.
- The lower provider-neutral budget and cordon calculations remain Phase 6 concerns; this sprint is their
  exact cluster consumer.

#### Validation

`ClusterReconcileSpec` and `ClusterBackendSpec` cover exact CPU/memory slice and node argument projection, the
typed unsupported-storage branch, ordering after ownership settlement, successful application,
malformed/failing calls, and replacement conflict.

#### Remaining Work

None.

### Sprint 16.10: Identity-bound cluster readiness [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Offer cluster dependency readiness only after the exact cordon is applied and the same cluster is ready.

#### Deliverables

- `ClusterReadiness` can be settled only from the matching `AppliedClusterCordon` and a fresh read-only
  backend observation.
- The readiness call re-observes immutable cluster identity, verifies the Kubernetes API, and verifies every
  declared node Ready under finite bounds.
- A same-identity not-ready observation is a legible failure; a different identity is a `Conflict`; a probe
  failure never collapses into absence or readiness.
- The separate status call is read-only and reports present, absent, or structured probe failure without
  acquiring mutation authority.

#### Validation

Focused reconciliation/backend cases cover cordon-before-readiness ordering, API/all-node readiness,
same-identity not-ready failure, replacement conflict, bounded probe failure, and read-only status.

#### Remaining Work

None.

### Sprint 16.11: Conditional cluster cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/durable_state.md`

#### Objective

Delete only the exact managed cluster whose immutable backend identity still matches its origin.

#### Deliverables

- `PreparedClusterCleanup` is derived only from the exact prepared package and matching managed handle; its
  constructor and nominal indices are not public.
- Cleanup enters the same ownership lock, revalidates the exact origin and current control-plane identity,
  and invokes deletion only while they match.
- Exact absence settles cleanup and durably removes the matching origin state. A replacement, malformed
  record, failed deletion, or failed reprobe preserves the foreign or uncertain state.
- Cleanup never receives or enumerates the durable host root.

#### Validation

`ClusterReconcileSpec` and `ClusterBackendSpec` cover exact removal, already-settled absence, replacement
preservation, failed delete, malformed/probe failure, and origin retention. Constructor and role fixtures pin
the cleanup boundary.

#### Remaining Work

None.

### Sprint 16.12: Structural durable-root exclusion [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Make the never-delete-durable-state invariant structural.

#### Deliverables

- The cluster teardown partition never places its durable data path in the removal set.
- `down` may remove an ephemeral cluster but no durable root, provider frame, or provider disk; `destroy` may
  release project-owned provider state while the host-durable root remains outside that state.
- A durable-root plan node uses `PreserveOnReverse`, and the reverse projection excludes every such node rather
  than relying on a delete call site's path exception.
- This sprint proves exclusion and scheduling structure only. It does not claim that a live destroy followed
  by up reads the same bytes.

#### Validation

`ClusterBackendSpec` covers the per-verb teardown partition, and `TeardownSpec` covers structural
`PreserveOnReverse` exclusion from the reverse forest. The worked-demo phase owns same-run durable readback.

#### Remaining Work

None. The end-to-end destroy/up/read assertion remains Sprint 24.3.

### Sprint 16.13: Journal-bound provider-wall reservation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Make the pre-call provider-wall reservation evidence of one exact protected journal transition.

#### Deliverables

- The only public `ProviderWallReservation` producer jointly consumes one `ProjectPlan`, its matching provider
  `PlannedResource`, exact wall/partition lineage, and the opaque `PreparedGate` recorded for that operation.
- The reservation derives its fence, attempt, session, and journal version from the gate; no positive number,
  descriptive wall, or partition alone can mint it.
- Runtime checks bind the gate's plan digest and operation key to the retained plan/provider resource before a
  prepared wall call exists.
- Pure budget validation, capability, workload fit, partition, slice, and unsupported-storage algebra remains
  Phase 12.30's effect-free contract and gains no mutation authority here.
- Phase 16 revalidates, but does not re-own, Phase 12.2's Type-kinded `StepAction` integration and Phase 12.30's
  existential resource-slice traversal needed by the exact consumers.

#### Validation

`BudgetSpec` covers exact gate admission and wrong plan, operation, and fence refusal. Named compile-fail
diagnostics pin `CallerFenceProviderWallReservation.hs`, `CrossPartitionProviderWallReservation.hs`, the
hidden internal module, constructors, and nominal roles. The Phase 12.2/12.30 dependency repairs are included
in the same warnings-as-errors static gate without changing either lower sprint's status.

#### Remaining Work

None.

### Sprint 16.14: Exact prepared provider start [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile/ProviderStart/Internal.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Prepare the real provider start as one opaque journal-bound `Observed` to `Running` operation.

#### Deliverables

- `PreparedProviderStart` consumes the exact plan, planned provider, observed provider handle, call digest, and
  current `PreparedGate`; it retains the inseparable operation/preconditions pair.
- The plan graph must authorize the provider's direct `Observed` to `Running` transition and its exact zero-
  dependency precondition set.
- Public code cannot project the retained journal pair or manufacture the package-private owning backend
  result required to complete the start.
- Completion preserves the generic observed resource generation; a provider-specific machine epoch cannot
  replace it.
- The generalized completion kernel changes only the target phase and retains all existing prepared-operation
  mismatch and foreign-result checks.

#### Validation

`ReconcileSpec` and the owning Colima adapter cases cover exact preparation and completion. Named compile-fail
fixtures reject constructor use, nominal role coercion, the hidden projection/completion capability, and
direct import of the internal module.

#### Remaining Work

None.

### Sprint 16.15: Backend-produced provider-wall settlement permit [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Prevent a caller-shaped raw wall observation from minting plan-indexed live authority.

#### Deliverables

- Opaque `ProviderWallSettlementPermit` retains the provider-resource, reservation, fence, operation key,
  call digest, attempt, journal version, and exact successful backend observation it authorizes.
- The provider-neutral package-internal mint accepts only the exact prepared wall call, gate, operation, and
  preconditions; it has no dependency on Colima or any other owning backend.
- `settleProviderWallCall` consumes the permit itself and accepts no separately supplied raw observation.
- Applied and already-exact outcomes remain the sole producers of `LiveProviderWall` and
  `ProviderWallAuthority`; failure, conflict, unsupported, or uncertain outcomes produce no authority.
- Public clients can neither import the mint nor manufacture or role-coerce a permit across plan, operation,
  reservation, or fence indices.

#### Validation

`BudgetSpec` covers gate/prepared-call agreement and refusal branches; owning-adapter settlement is exercised
later by `ColimaSpec`. Named compile-fail diagnostics reject construction, hidden-module import, the former
raw-observation settle shape, and plan/operation role coercion.

#### Remaining Work

None.

### Sprint 16.16: Canonical Colima root/data storage-wall binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Bind Colima admission and storage preparation to one exact total writable-storage ceiling.

#### Deliverables

- Colima admission requires an exactly representable whole-GiB total strictly larger than its fixed 20 GiB
  writable root disk.
- The canonical call fixes `--root-disk 20` and renders `--disk TOTAL-20`; workload-visible data plus provider
  root therefore equals, rather than exceeds, the declared total wall.
- Provider-wall and storage-wall preparation both delegate to the same canonical argv builder and retain the
  total declared bytes as the settlement ceiling.
- The fixed non-activating/template/SSH/mount/Kubernetes/network flags remain part of the exact call digest.
- The renderer and quantity refusal remain Phase 6.1's provider-neutral cordon contract, and the pure indexed
  budget evidence remains Phase 12.30's contract; this sprint is only their direct-Colima adoption and
  revalidation.

#### Validation

`CordonSpec` and `BudgetSpec` pin the 20 GiB root, remainder data disk, exact argv order, `<=20 GiB` refusal,
and total settlement ceiling. The full Phase 16 static gate revalidates the Phase 6.1/12.30 implementation
without changing those completed lower-phase statuses.

#### Remaining Work

None.

### Sprint 16.17: Trusted resolver wire protocol [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Protocol.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Define one strict private report that can describe, but not itself authorize, a trusted Apple toolchain.

#### Deliverables

- The resolver protocol distinguishes ready, missing-Colima-with-trusted-Brew, and unsupported outcomes.
- Ready reports bind every executable and helper-search directory the direct backend will use, together with
  their canonical identity and toolchain fingerprint inputs.
- The decoder accepts one canonical bounded report and rejects missing fields, duplicates, extra output,
  malformed numbers/digests, CR, or non-canonical paths.
- Brew evidence exists only in the missing-Colima branch; a ready/live/cleanup toolchain is not coupled to
  unrelated later Brew drift.
- The protocol module is private and produces no public mutation or settlement authority.

#### Validation

`ColimaSpec` covers canonical round trips and malformed, duplicated, decorated, truncated, and cross-branch
reports under the host-static test gate. Cabal-private `Resolver.Testing` exposes descriptive protocol views
and a layout-matched decoder; its separately bracketed fixture-execution seam is owned by Sprint 16.20 and is
not a public authority producer.

#### Remaining Work

None.

### Sprint 16.18: Trusted resolver program [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Program.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Resolve the complete direct-Colima toolchain from a fixed Apple trust policy rather than ambient execution
state.

#### Deliverables

- A private embedded resolver examines only the closed Apple candidate table for Python, Colima, Docker,
  Lima, and the optional install-time Brew route.
- Every admitted executable is an absolute canonical non-symlink regular file with exact owner, mode, and
  opened-versus-path identity checks; helper directories are derived only from admitted paths.
- Homebrew's administrative anchor allowance is explicit while formula and binary directories retain the
  stricter ownership/mode policy.
- The resolver reads no ambient `PATH`, `HOME`, current directory, Docker context, or caller-provided tool.
- Missing, ambiguous, mutable, or untrusted candidates produce a strict unsupported report rather than a
  best-effort executable choice.

#### Validation

`ColimaSpec` uses the Cabal-private `Resolver.Testing` fixture-root renderer and decoder to cover canonical
candidates, symlink/replacement/mode/owner refusal, ambiguous installs, the Brew-only missing branch, and
hostile ambient environment values. Outside the bracketed private test seam, the facade executes only the
fixed `resolverProgram` candidate table.

#### Remaining Work

None.

### Sprint 16.19: Bounded direct-Colima runner and supervisor [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Supervisor.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Bound every private interpreter and tool process without leaking descendants or swallowing cancellation.

#### Deliverables

- Each outer interpreter and inner tool runs in a retained process group/session with an explicit finite
  deadline and parent-death supervision.
- Timeout and successful-leader-exit paths quiesce the complete retained group before identifiers may be
  reused, close or drain both pipes within bounds, and reap the leader without an unbounded wait.
- Interrupt, terminate, and kill escalation reaches the group, including a descendant that ignores TERM or
  keeps stdout/stderr open after the leader exits.
- Output retention is bounded and parser-visible truncation or pipe failure is a structured backend failure.
- Haskell asynchronous exceptions terminate/reap the group and propagate unchanged.

#### Validation

`ColimaSpec` exercises normal exit, timeout, cancellation, leader-exits-first, TERM-ignoring descendants,
pipe retention, bounded output, and reap behavior without invoking a real Colima installation. The
Cabal-private resolver fixture wraps bounded execution results for strict facade settlement; it exposes
neither a process runner nor a successful backend-result constructor.

#### Remaining Work

None.

### Sprint 16.20: Trusted resolver facade [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Authority.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Override.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Expose a private opaque toolchain only after strict resolver execution, parsing, and revalidation.

#### Deliverables

- The facade obtains the effective user's home from the OS account database and freshly admits only Apple
  silicon before running the closed resolver.
- `TrustedAppleToolchain` retains canonical executable/helper identities and one deterministic fingerprint;
  its constructors and revalidation details remain private.
- The facade preserves the distinct missing-Colima-with-trusted-Brew result for the later owning adapter; it
  does not itself install a package or turn Brew evidence into a ready toolchain.
- Ready acquisition, live Docker, and cleanup revalidate only their retained ready toolchain immediately
  before and after effects.
- Unsupported, malformed, missing, or drifted resolution yields no backend capability.
- Host-static integration uses a non-nestable, thread-local, bracket-cleared override from the Cabal-private
  test component. It supplies only fixture root/home/bootstrap identity and a fresh bounded resolver
  execution; every discovery and revalidation still runs the strict decoder and opaque settlement path.

#### Validation

`ColimaSpec` covers ready, missing, unsupported, effective-home refusal, fingerprint drift, and the scoped
public-adapter fixture flow host-statically through `Resolver.Testing`. The seam is unreachable from the
public library surface, exports no trusted-toolchain/backend-result constructor, and cannot bypass strict
resolver parsing or settlement. `ImportColimaResolverOverride.hs` and
`ImportColimaResolverTesting.hs` are named downstream import failures.

#### Remaining Work

None.

### Sprint 16.21: Descriptor-held filesystem and profile-lock primitives [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Filesystem.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Provide no-follow descriptor-relative primitives for the exact Colima ownership transaction.

#### Deliverables

- Component-wise traversal retains parent descriptors, refuses symbolic/foreign components, and validates
  ownership, mode, type, and opened-versus-path identity before use.
- Directory creation, regular-file open, no-replace publication, replacement, and unlink operate relative to
  validated descriptors rather than a re-resolved pathname.
- File and containing-directory synchronization plus authoritative readback close every publication and
  removal boundary.
- The reusable profile-global lock remains synchronization-only, is opened no-follow, and is held by its exact
  descriptor/inode across the complete transaction.
- Record and stage operations retain expected descriptors, identities, and bytes so an identical-byte inode
  replacement is a conflict rather than adoption.

#### Validation

`ColimaSpec` covers pristine creation, intermediate/final symlinks, rename substitution, foreign mode/owner,
no-replace collision, copied inode, fsync/readback failure, and exact lock-object exclusion.

#### Remaining Work

None.

### Sprint 16.22: Isolated Colima home/data namespace [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Namespace.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`

#### Objective

Bind every mutable Colima/Lima/cache/temp path to one short, isolated, identity-checked profile namespace.

#### Deliverables

- The profile hash derives a short isolated `COLIMA_HOME` plus exact Lima, cache, temporary, and data paths;
  Production, Harness, and concurrent runs cannot share one mutable namespace accidentally.
- The backend supplies a closed environment, helper `PATH`, effective passwd home, and fixed working directory;
  ambient `HOME`, `PATH`, `COLIMA_HOME`, `LIMA_HOME`, temp, Docker config, and cwd are ignored.
- Every namespace component is created/opened no-follow and represented by an ordered identity chain retained
  in the origin record and later live/cleanup authority.
- Socket-path length is checked before mutation, so an unsupported effective-home layout cannot partially
  create a profile.
- Foreign, missing-after-ownership, or identity-changed home/data components are conflicts and are not
  recreated during live use or cleanup.

#### Validation

`ColimaSpec` covers profile separation, short-path derivation, hostile environment/cwd, long-home refusal,
component symlinks/replacements, missing owned paths, and directory-chain identity drift.

#### Remaining Work

None.

### Sprint 16.23: Docker-context ownership and release manifest [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Context.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Own Colima's Docker-context side effect as an isolated named resource with a durable conditional-release
manifest.

#### Deliverables

- A reserved pre-context record proves the isolated `DOCKER_CONFIG` path and named context absent before the
  directory is created or Colima can mutate it.
- Acquisition fingerprints the exact Docker directory/context artifacts and publishes their identity/content
  manifest before the origin becomes managed.
- Managed-state log or metadata drift may rebuild the manifest only before cleanup durably enters releasing;
  releasing and later stages freeze the exact teardown proof.
- Cleanup models both lawful Colima behaviors: named-context deletion, or retention of the exact previously
  owned context; a foreign or replacement context is never removed.
- Exact context/config removal is descriptor-relative, identity-conditional, synchronized, and independently
  re-observed absent before origin release.

#### Validation

`ColimaSpec` covers pre-context crash boundaries, exact manifest publication/rebuild, releasing-stage freeze,
context deleted/retained outcomes, replacement preservation, and conditional namespace removal.

#### Remaining Work

None.

### Sprint 16.24: Durable direct-Colima origin transaction [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Common.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Define one self-bound, crash-recoverable origin state machine shared by acquisition, live use, and cleanup.

#### Deliverables

- Canonical reserved/home-staged/home-ready/context-staged/prepared/managed/releasing/context-released/released
  states bind owner, fresh nonce, profile, acquisition invocation, cleanup invocation where applicable, and
  each record's own identity.
- Prepared is the sole pre-call outcome-unknown state: it records prior profile/context/home/data absence and
  durably binds the exact call, wall, toolchain, namespace, and expected artifact transaction before
  `colima start`.
- Managed state binds stable machine epoch, named context, lock/record objects, full directory chain, complete
  artifact manifest, and root/data wall observations.
- Recovery accepts only the same owner/invocation and a canonical state-specific combination; ambiguous
  prepared-plus-present, copied records, partial stages, or mismatched artifacts fail closed.
- Cleanup stages bind the distinct teardown gate/session/attempt/journal digest and retain enough frozen state
  to resume only the same conditional release.
- The profile-global lock contains no owner tombstone; exact release completion lives in the origin state while
  the reusable lock remains synchronization-only.

#### Validation

`ColimaSpec` exercises every crash boundary and restart classification, self-inode substitution, acquisition
and cleanup replay mismatch, stage durability failures, exact released replay, and lock reuse by a later owner.

#### Remaining Work

None.

### Sprint 16.25: Locked direct-Colima acquisition program [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Acquire.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`

#### Objective

Execute one exact acquisition entirely inside the reusable profile lock and durable origin transaction.

#### Deliverables

- Acquisition opens the exact state/lock namespace, holds the retained profile lock, and strictly observes
  profile, context, home/data, wall, and origin before any mutation.
- Fresh acquisition publishes prior absence, creates/binds the isolated namespaces, enters prepared, runs the
  bounded non-activating start, and then re-observes all stable identities before managed publication.
- A prepared record with an unexpectedly present profile is outcome-unknown conflict, never evidence that the
  current profile belongs to this operation.
- Same-name unowned profiles are foreign; incompatible, malformed, changing, or partially observed state is a
  conflict or failure and is left untouched.
- Applied and exact success reports carry the stable epoch plus every lock/record/context/home/data/artifact
  identity needed by settlement and later exact calls.

#### Validation

`ColimaSpec` covers fresh/exact acquisition, foreign and incompatible profiles, start failure/timeout/crash,
prepared-plus-present uncertainty, strict observation failures, replacement races, and acquisition exclusion.

#### Remaining Work

None.

### Sprint 16.26: Opaque direct-Colima acquisition backend facade [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaBackendInternal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Expose acquisition to the owning adapter only as a typed private request and strict opaque result.

#### Deliverables

- `AcquireBackendRequest` carries the closed tool/namespace paths, exact owner and invocation, wall split,
  profile/state/record/lock locations, bounded deadline, and canonical start argv.
- Applied/exact results retain machine/context epoch, lock/record/Docker/Colima/data identities, complete
  directory-chain/artifact digest, and no public authority constructor.
- The facade launches only the compiled acquisition program through the bounded runner and accepts one strict
  canonical report; stderr, malformed output, duplicate lines, truncation, or impossible identities fail.
- Foreign, conflict, unsupported, and failed outcomes stay descriptive until the exact owning adapter matches
  them to its prepared package.
- The module remains a Cabal-private component; downstream code cannot inject an interpreter or construct a
  successful result.

#### Validation

`ColimaSpec` covers request validation, strict report parsing, complete identity projection, malformed reports,
and private injection. Compile-fail coverage rejects public import and result construction.

#### Remaining Work

None.

### Sprint 16.27: Exact project/lifecycle Colima profile identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Derive one collision-resistant direct-Colima namespace authority, plus its socket-safe local profile, from the
installed project and exact lifecycle profile.

#### Deliverables

- A stable 128-bit namespace key derives from `projectPlanProjectName`, `projectPlanProfileName`, the exact
  provider resource/frame, and canonical plan root; no caller-selected name enters that key.
- Production, distinct Harness run IDs, and concurrent Harness runs map to distinct isolated Colima homes and
  reusable global-lock authorities. The short six-hex Colima profile is local to that unique home, is never
  `default`, and is not treated as the collision-resistance boundary by itself.
- The 128-bit home/lock key, socket-safe local profile, origin record name, and owner seed are deterministic
  projections of the same full plan/lifecycle inputs, and the durable owner/record binds both derived names.
- Validation rejects empty, overlong, unsafe, or non-canonical profile components before any backend call.
- These projections remain descriptive until combined with the prepared gate and closed backend.

#### Validation

`ColimaSpec` covers production/harness separation, concurrent run IDs, deterministic derivation, authoritative
home/lock non-collapse even where short local labels are deliberately truncated, shared-default refusal, and
invalid names. Constructor/role fixtures preserve the plan/profile seal.

#### Remaining Work

None.

### Sprint 16.28: Exact plan-owned direct-Colima preparation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Prepare one exact Colima start from the plan-owned provider and inseparable budget/journal package.

#### Deliverables

- `PreparedColimaWallCall` consumes one `ProjectPlan`, matching provider resource and observed handle,
  `DerivedTopology`, validated budget/capability/wall/fit/partition/reservation, and current `PreparedGate`.
- Preparation creates the exact `PreparedProviderStart`, retaining its operation/preconditions pair and the
  journal-derived wall reservation fence in one opaque package.
- The call derives the profile, state root, origin path, owner seed, canonical root/data argv, and acquisition
  invocation digest. That digest binds the plan, gate, wall, and mutation inputs; the execution-bound owner
  separately binds the closed namespace and complete trusted-toolchain fingerprint, and the durable record and
  settlement jointly validate both values.
- No compatibility lifecycle plan, binary context, caller profile/root/envelope, independent reservation, or
  mutable argv enters the package.
- Public projections reveal only non-authorizing profile/diagnostic views; mutation arguments and constructors
  remain sealed.

#### Validation

`ColimaSpec` covers exact package construction, call digest and argv binding, cross-plan/gate/refusal cases,
and prepared-start lineage. Compile-fail fixtures reject cross-plan consumers, construction, role coercion,
and mutation-argument projection.

#### Remaining Work

None.

### Sprint 16.29: Closed resolver/backend adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Install.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaBackendInternal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Resolve and retain the sole private execution namespace used by every exact Colima effect.

#### Deliverables

- Public acquisition, live Docker, and cleanup accept no `HostConfig`, executable, interpreter, environment,
  current directory, or executor; only the private trusted resolver can supply them.
- Fresh Apple detection, effective passwd home, trusted toolchain resolution, optional bounded install, and
  full rediscovery occur before an owning backend exists.
- The private `Resolver.Install` kernel orders retained Brew revalidation, the bounded fixed Brew invocation,
  and a fresh complete resolver pass. Its structured result distinguishes changed Brew, install exit,
  timeout, execution failure, still-missing Colima, resolver refusal, and a newly ready toolchain; the public
  adapter cannot reorder or bypass those steps.
- The retained backend fixes Python, Colima, Docker, Lima, closed helper `PATH`, short Colima namespace,
  isolated Docker config, working directory, and one complete toolchain fingerprint.
- The owner token and invocation namespace bind those exact paths and fingerprints; revalidation occurs around
  every acquisition, live, and cleanup effect.
- Unsupported substrate, long namespace, resolver/install failure, or tool drift yields no owning observation.

#### Validation

`ColimaSpec` covers trusted ready/install routes, install revalidation/failure/timeout/still-missing branches,
fresh rediscovery, hostile ambient state, namespace/tool fingerprint drift, and no public executor escape.
The bracketed Cabal-private resolver fixture also drives the actual public acquire, settle, live-Docker, and
journaled cleanup adapters without exposing that fixture route downstream. The private-backend import fixture
and `ImportColimaResolverInstall.hs` remain named compile failures.

#### Remaining Work

None.

### Sprint 16.30: Clause-holding direct-Colima acquisition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Execute one prepared Colima call and retain only the exact closed-backend ownership result.

#### Deliverables

- The adapter derives the expected CPU, memory, root-disk, and data-disk wall from the immutable prepared argv
  and sends the complete request to the private acquisition facade.
- It revalidates the trusted toolchain before and after the backend call and rejects any changed execution
  route.
- An owned observation retains the exact invocation, namespace, profile, state/record/lock, machine/context,
  directory-chain, artifact, and root/data wall identities plus the opaque backend result.
- Unowned foreign/conflict/unsupported/failure outcomes remain descriptive and cannot enter settlement.
- Start failure, timeout, malformed output, identity drift, uncertain recovery, or backend mismatch mints no
  provider or wall authority.

#### Validation

`ColimaSpec` covers applied/exact/foreign/conflict/failure classification, full retained identity matching,
tool drift, malformed wall argv, uncertain recovery, and concurrent acquire calls. Compile-fail guards reject
raw-observation authority paths.

#### Remaining Work

None.

### Sprint 16.31: Backend-produced provider-start and wall settlement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Settlement/Internal.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Settle the generic provider start and provider wall inseparably from one exact successful backend invocation.

#### Deliverables

- The unexposed owning bridge is the only code that can inspect `AcquireApplied`/`AcquireExact`, project the
  exact prepared provider-start journal pair, and invoke the provider-neutral permit mint.
- Settlement checks the prepared call's owner, state/record/lock namespace, invocation digest, gate, operation,
  attempt, and journal version against the retained opaque result before producing authority.
- Applied maps to generic provider `Created`; exact replay maps to `Repaired`; both preserve the original
  observed provider generation and return its exact managed `Running` handle and receipt.
- `LiveColimaWall` is produced only after both wall and provider-start settlement succeed and retains their
  change views plus all backend identity needed by live and cleanup.
- Foreign, conflict, unsupported, failed, cross-call, or replay-mismatched results cannot settle either side.

#### Validation

`ColimaSpec` covers applied/exact settlement, provider/wall change views, stale opaque-observation refusal
across session/attempt/journal lineage, representative public unowned conflict/failure settlement refusal,
and the private backend's strict classification of the remaining non-owning reports. Named compile-fail
fixtures reject both hidden bridges, start/permit construction, old raw settlement, and nominal role
coercion.

#### Remaining Work

None.

### Sprint 16.32: Settled live Colima Docker route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Internal.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/LiveDocker.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/ensure_reconcilers.md`

#### Objective

Make the settled live wall the sole route to Docker in the exact Colima namespace.

#### Deliverables

- `runLiveColimaDocker` consumes only `LiveColimaWall`; it accepts no caller `HostConfig`, executable,
  environment, context root, or current directory.
- The private live request reacquires the same lock object and revalidates origin state, owner/invocation,
  machine/context epoch, full directory/artifact manifest, toolchain, and root/data wall before Docker runs.
- Docker always names `colima-<profile>` under the retained isolated `DOCKER_CONFIG`; it never relies on or
  mutates the process-global current context.
- The bounded runner returns one strict completed/conflict/unsupported/failure result and revalidates the
  trusted toolchain after the call.
- Neither the live wall's constructor nor an alternate raw Docker route is public.

#### Validation

`ColimaSpec` covers exact named-context argv, hostile ambient state, ownership/artifact/wall replacement,
timeout and malformed reports, and Docker access only through the settled wall. Authority forge/coercion
fixtures pin the public boundary.

#### Remaining Work

None.

### Sprint 16.33: Provider force-destroy transition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Represent `colima delete --force --data` as its real provider-only `Running` to `Destroyed` transition.

#### Deliverables

- `planProviderForceDestroy` accepts only the exact managed `Running` provider handle and names the explicit
  `destroyed-force` successor; it is not mislabeled as an ordinary stop.
- `plannedProjectPhaseOperation` binds the transition to the matching project plan, planned provider,
  ownership receipt, current generation, and cleanup call digest.
- The generic phase-transition preparation/completion kernel retains the exact source receipt and can advance
  only the prepared target phase.
- No `Observed` to `Provisioned` acquisition descriptor is reused to authorize deletion.

#### Validation

`ReconcileSpec` covers journal-prepared provider `Running` to `Destroyed`, completion at the retained
generation, and refusal of a wrong observed generation, empty call digest, replacement receipt, or wrong
resource/phase. Compile-fail fixtures reject forged or cross-phase advances.

#### Remaining Work

None.

### Sprint 16.34: Exact Colima cleanup authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Derive deletion authority only from the exact settled live wall and its managed provider receipt.

#### Deliverables

- `ColimaCleanupAuthority` has no public constructor and is produced only by eliminating an exact
  `LiveColimaWall`.
- It retains the plan/profile, managed `Running` provider handle and receipt, reservation fence, owner/nonce,
  machine/context epoch, lock/record identities, directory/artifact manifest, and root/data wall evidence.
- A descriptive profile observation, prepared acquisition, generic managed provider, or caller-supplied
  handle/receipt cannot mint cleanup authority.
- Nominal roles prevent cross-plan, profile, provider, epoch, or fence relabelling.

#### Validation

`ColimaSpec` covers authority projection from a settled live wall. Constructor, role, generic-handle, and
cross-plan compile-fail fixtures pin the deletion boundary.

#### Remaining Work

None.

### Sprint 16.35: Journal-prepared Colima cleanup call [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Prepare deletion under a distinct current teardown gate that cannot replay acquisition authority.

#### Deliverables

- `prepareColimaCleanupCall` consumes the exact plan/planned provider, current cleanup `PreparedGate`, and
  retained `ColimaCleanupAuthority`.
- The gate fence must match the live wall, while operation, session, attempt, and journal version are the
  teardown's own current values rather than acquisition's values.
- Preparation builds the exact provider force-destroy descriptor, zero-dependency preconditions, and opaque
  `PreparedPhaseTransition Running Destroyed`.
- The cleanup invocation digest binds the teardown gate lineage, managed generation/receipt, owner/nonce,
  machine/context, lock/record/directory/artifact identities, tool namespace, and wall evidence.
- A second gate, plan, provider, receipt, call digest, or acquisition package cannot enter the call.

#### Validation

`ColimaSpec` covers exact preparation and wrong plan/operation/fence/resource/receipt refusal. The distinct
current teardown session/attempt/journal values are accepted at preparation, durably bound before mutation,
and then covered by changed-invocation replay refusal in Sprint 16.36. Constructor, role, cross-gate, and
cross-phase fixtures retain the opaque boundary.

#### Remaining Work

None.

### Sprint 16.36: Conditional direct-Colima cleanup backend [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Internal.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Program/Cleanup.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Execute conditional release inside the private backend without exposing a deletion interpreter or successful
result constructor.

#### Deliverables

- The private request carries the exact existing state/lock namespace, acquisition and cleanup invocation
  digests, owner/nonce, machine/context epoch, complete directory/artifact identities, root/data wall, closed
  tools, and finite command deadline.
- Cleanup opens the existing state and reusable profile lock without recreation and holds that same lock
  identity through every check and effect.
- Before `colima delete --force --data`, it validates the managed origin, acquisition and cleanup invocation
  digests,
  owner/nonce, machine/context epoch, complete directory/artifact manifest, and root/data wall.
- The releasing record durably binds this teardown before mutation; only that same operation may resume an
  interrupted delete, context release, namespace removal, or origin release.
- Delete is bounded and followed by independent strict profile and named-context absence/exact-retention
  proofs; failure, uncertainty, or replacement leaves foreign state and origin intact.
- Exact owned context, Docker config, Colima/Lima/cache/temp/data artifacts, manifest, and origin are removed
  conditionally with descriptor identity checks, synchronized parents, and authoritative absence readback.
- Acquisition and cleanup share the profile lock, so no cooperating reacquisition enters the release interval.
- The strict private facade returns only deleted, released, conflict, unsupported, or failure; malformed,
  decorated, truncated, or stderr-bearing reports cannot become success.

#### Validation

`ColimaSpec` covers every releasing crash/recovery boundary, distinct cleanup invocation replay, failed/timeout
delete, machine/context/record/directory/artifact/wall replacement preservation, both lawful context outcomes,
durable removal failures, released replay, strict report parsing, and acquire-versus-cleanup exclusion.

#### Remaining Work

None.

### Sprint 16.37: Exact Colima cleanup execution and phase completion [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Adopt the private conditional cleanup result and advance the provider only after exact release succeeds.

#### Deliverables

- `runColimaCleanup` consumes only the opaque prepared cleanup call and freshly resolves the retained closed
  tool/namespace route; a caller cannot supply an executor, environment, handle, receipt, or backend result.
- The adapter requires the freshly resolved route to equal the live wall's retained toolchain and namespace,
  builds the complete private request, and revalidates the toolchain after the backend returns.
- Only `CleanupDeleted` or the exact idempotent `CleanupReleased` replay completes the retained prepared
  `Running` to `Destroyed` phase transition at the original managed resource generation.
- Conflict, unsupported, malformed, timeout, failure, or post-call tool drift returns a typed error and yields
  no `PhaseAdvance`.
- The public surface exposes neither the private cleanup request/result constructors nor a unit-returning
  deletion route that could bypass typed phase completion.

#### Validation

`ColimaSpec` covers public failed-delete refusal, changed teardown-invocation refusal, deleted/released
completion, and retained-generation phase advance. Private backend/facade cases strictly classify
unsupported, malformed, timeout, replacement, and post-call mismatch outcomes and prove that none becomes
success. Compile-fail fixtures reject cleanup construction, backend import, and forged/cross-phase advances.

#### Remaining Work

None.

### Sprint 16.38: Independent Linux cluster gate runner [Done]

**Status**: Done
**Implementation**: `scripts/run-live-cluster-gate.sh`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Provide the independent bounded runner used by the phase-level Linux acceptance gate.

#### Deliverables

- The executable POSIX runner refuses a non-Linux host or a host missing Docker, grep, kind, kubectl, or the
  process-level timeout utility before it creates infrastructure.
- Every run selects a fresh collision-resistant kind name, isolated kubeconfig, and durable-root sentinel,
  with a trap that deletes a cluster left by an interrupted or failed run.
- Creation and node readiness use explicit 180-second process bounds; daemon/status checks have shorter
  process bounds so an unresponsive backend cannot hang the gate.
- The post-readiness status observation is read-only: `kubectl get nodes --output=name` performs no mutation.
- Teardown deletes the fresh cluster and verifies that no node container carrying its kind-cluster label
  remains.
- The sentinel lives outside the cluster deletion boundary and must retain its exact contents after teardown.
- The phase gate composes the core warnings-as-errors suite with this runner from the repository root; it has
  no demo binary, demo configuration, or demo lifecycle dependency.

#### Validation

`sh -n scripts/run-live-cluster-gate.sh`, ShellCheck when available, and source/diff checks validate the runner
without creating infrastructure. Live execution belongs only to the phase-level baseline acceptance below.

#### Remaining Work

None.

### Sprint 16.39: Cluster suite host neutrality [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Assert this phase's cluster preparation, settlement, and readiness boundary from every supported outer
host realization.

#### Deliverables

- Every host `HostConfig` tool table in the phase's suites — the Python, Docker, kind, and kubectl
  entries the exact cluster package projects — builds its paths through the fixture-path constructor the
  [Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns.
- The runner dispatch that selects a fake backend response by executable compares that same constructed
  value, so the absolute-backend-path projection guard keeps asserting exactly what it asserts today.
- In-container and in-cluster paths stay POSIX. A kubeconfig path inside a node container, a mounted
  durable root, the injected kind/runtime/kubectl triple, and a guest command name files on a different
  machine, and only the host side moves.
- The POSIX-only backend cases the suites already separate — the real process-group, signal, and
  output-bound probes that drive `/bin/sh` — keep their existing platform conditions and are skipped
  rather than failed on an outer host that cannot run them. `ClusterReconcileSpec` splits on the same
  line: its package and projection cases are host-portable, while every case that admits a `ClusterSpec`
  is Linux-frame and carries the condition.
- The work is test-harness only: no production module, no named type, and no change to any cluster
  contract the phase already states.

#### The frame a cluster spec belongs to

A `ClusterSpec`'s state directory is the path the locked ownership program receives *inside* the realized
Linux substrate, which is why its absoluteness check is POSIX and why the production resolved backend is
itself Linux-only. When the cluster step runs, the machine the binary calls "host" is that Linux frame,
so the host `</>` that derives the directory from the canonical project root and the POSIX check that
admits it agree.

They only come apart on a native Windows outer host, where the fixture's canonical project root is a
Windows path because it is a real directory on the machine running the suite. That combination is not a
configuration the architecture has: a native Windows process establishes WSL2 and re-establishes the
binary inside it before any cluster work. Those cases are therefore Linux-frame cases and are skipped on
Windows rather than failed (§ JJ) — the contract is unchanged, and the gate that proves it is the
`linux-cpu` one.

#### Validation

`cabal test all --ghc-options=-Werror` from `core/`, run host-native and recorded against the outer host
that ran it (§ II), on a POSIX outer host and on Windows. The phase's existing static evidence below
records the POSIX side. The live cluster gate is unaffected: `scripts/run-live-cluster-gate.sh` refuses a
non-Linux host by design and keeps its own declared bound.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal test all --ghc-options=-Werror` from `core/` host-native at 1,877/1,877 in 211.76 seconds.
The eleven Linux-frame reconcile, readiness, and cleanup cases are absent from that count and present in
the POSIX one, which is the difference the split above describes — a declared difference, which is what
the [host-portability acceptance phase](phase-28-host-portability-acceptance.md) confirms across families
(§ JJ) rather than this sprint.

#### Remaining Work

None.

### Sprint 16.40: The read-only cluster status is a decision [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

The cluster's read-only status observation as one bounded run and one total function.

#### Objective boundary

This sprint takes the smallest of the phase's four interpreter programs, and takes it on its own because
§ G's budget makes a sprint one contract. It changes nothing about *what* the status path asks — the
driver's own listing, exactly as before — and nothing about the clause-holding driver beside it, which is
the next sprint's whole subject.

#### Deliverables

- The read-only status path issues the driver's own listing as an argument vector this module owns and
  runs it through the driver's row of the one bounded-run table, so no program is shipped to an
  interpreter for it (§ KK).
- What the listing means is `classifyClusterStatus`, a total function of the runner's own outcome:
  exported, so what a suite covers is the decision rather than an arrangement that produces its input.
- The refusals stay exactly as narrow as they were. A non-zero exit, anything on standard error, a body
  that does not end in exactly one newline, a carriage return, a byte outside ASCII, a name outside the
  portable alphabet, and a repeated name are each the driver contradicting itself — and each is a refusal
  rather than an absence, because absence authorizes creation and a refusal must not.

#### Validation

Every refusal and both admissions are reached by application over values, so none of them needs a process
arranged to produce the shape it is about and none can pass against a stand-in for one (§ NN). The two
cases whose subject is the effect — that the path creates nothing and that a failing driver is not read as
absence — keep driving a real program. Because the decision is now a function rather than a program's
output, its family runs on every gate host instead of only the POSIX ones (§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds; the same host
passed `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
at 231. § II makes this a gate-host record: this host does not run the phase's POSIX cluster family, whose
host-portability the next sprint's driver is what removes.

#### Remaining Work

None.

### Sprint 16.41: The described cluster commands [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Every cluster effect as a value in the one closed effect vocabulary.

#### Objective boundary

This sprint renders the argument vectors and nothing else. What an answer *means* is Sprint 16.42's, where
a transaction *stands* is Sprint 16.43's, and which clauses are held around them is Sprint 16.44's. The
split is § G's budget: a module that both rendered a vector and decided what came back would be one sprint
carrying two contracts, and the rendering is exactly the half a suite can compare by application.

#### Deliverables

- `HostBootstrap.Cluster.Command` renders every cluster effect as a `HostCommand`: the driver's listing,
  kubeconfig read, creation, and removal; the container runtime's node listing, identity readback, run-state
  readback, and cordon application; and the API server's readiness and node queries.
- Three tools answer, and which one a question belongs to is a property of the question. The driver owns
  the cluster as a named object, the container runtime owns the node containers clause 3's identity comes
  from, and the API server owns a readiness view that is not an ownership fact at all.
- A node container is matched on its exact whole name, anchored on both ends and untruncated, because a
  substring match makes "which container is this node" depend on what else exists and a shortened
  identifier is a prefix rather than an identity.
- A cordon addresses the container identity the durable record bound rather than the node's name, which is
  the distinction a replacement erases.
- The kubeconfig an API question needs travels on standard input and is named as `/dev/stdin`, so a live
  control-plane credential never appears in a process listing.

#### Validation

Every case is an equality between a rendered command and the vector it is supposed to be, which is only
possible because a renderer cannot run anything (§ NN). Three properties are asserted over the whole set
rather than case by case, because each is true of every command until one day it is not: every command
names one of exactly three tools, every command is interpreted by a process of the outer host, and the only
two commands carrying standard input are the two that must not put a credential in `argv`.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
eighteen cases of `ClusterCommandSpec`.

#### Remaining Work

None.

### Sprint 16.42: The cluster report classifiers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/test/ClusterReportSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

What each answer means, as a total function of the bytes that came back.

#### Objective boundary

This sprint classifies answers and holds no clause. Where a transaction *stands* given those answers is
Sprint 16.43's, and which clauses are held around them is Sprint 16.44's. The status path Sprint 16.40
already made a decision keeps its own classifier until Sprint 16.44 moves it onto this one, because § C
keeps the plan describing the boundary the repository actually has rather than the one it is about to.

#### Deliverables

- `HostBootstrap.Cluster.Report` carries one classifier per question Sprint 16.41 asks: the cluster
  listing, the container standing at a node's exact name, that container's own identifier read back, its
  run state, the kubeconfig body, the API server's readiness answer, and the node list it returns.
- The framing refusals are one computation rather than one per caller: a non-zero exit, anything on
  standard error, a body that does not end in exactly one newline, a carriage return, a byte outside
  ASCII, an empty row, and a line past the admitted bound are each the answering tool contradicting
  itself. Empty output is an empty listing rather than a malformed one, because a tool that names nothing
  writes nothing.
- Telling "the tool says this is not here" apart from "the tool did not answer" is the classifier's whole
  job, because the first authorizes a mutation and the second must not.
- Two answers deliberately do not refuse, and they are the two that are facts about the cluster rather than
  about the tool. An API server that will not answer its readiness endpoint is `ApiNotReady`, because a
  control plane that has not come up is what a readiness poll is polling for; and a well-formed node list
  naming a different node set is `NodesUnexpected`, because it is a true statement about a cluster this run
  is not looking at yet. A malformed node document is still a refusal.

#### Validation

Every classification and every refusal is reached by application over values, so none needs a process
arranged to produce the shape it is about (§ NN). The forty-eight cases of `ClusterReportSpec` run and are
counted on every gate host, because a function applied to a value needs no POSIX (§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
forty-eight cases of `ClusterReportSpec`.

#### Remaining Work

None.

### Sprint 16.43: The cluster resumption decisions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Where a cluster transaction stands, as a total function of three values.

#### Deliverables

- A closed standing vocabulary over the four prefixes of the one clause order: no record and nothing
  there, a record whose creating command has not taken effect, an object standing under this record with
  clause 3 unheld, and this record's own object with all three clauses held.
- **A cluster carries no claim, and the record's own existence is what stands in for one.** A provider
  stamps this run's owner tag onto the instance as it creates it; the cluster driver has nowhere to put
  such a tag, because what it creates is a name and a set of node containers and neither carries a byte
  this project chose. What answers instead is that a record is published only from `ClusterNothingDone` —
  the driver naming no cluster and the runtime naming no container — inside the store's exclusive entry, so
  a published record is proof that this transaction found the name free and took it.
- The two authorities must **agree** for that to be a standing. A driver that names the cluster while the
  runtime names no container, and a container that outlives the cluster the driver names, are each one
  authority contradicting the other, and each is `ClusterOutcomeUnknown` or its bound-record equivalent
  rather than a state a clause could be held over.
- Identity closes the window in the other direction. Clause 3 binds the node container's own identifier, so
  a cluster deleted and recreated out of band under the same name presents a different identifier and is a
  replacement rather than the same object.
- `nodeStanding` is the same decision with the driver's answer removed, for a node that is an owned object
  *inside* the cluster rather than the cluster itself.

#### Validation

Every standing and every conflict is reached by application over values, including the outcome-unknown
window between the durable record and the identity binding — the one interval a live run cannot be steered
into (§ NN). The record values are built through the ownership vocabulary's own constructors, so no case
asserts about a record shape the store could never hold.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
twenty-six cases of `ClusterResumeSpec`.

#### Remaining Work

None.

### Sprint 16.44: The owned cluster and its reconcile driver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

The cluster as an owned object, and the one transaction that creates it.

#### Objective boundary

This sprint lands the object, its observation, and the create transaction. Readiness, cordon, and cleanup
are Sprint 16.45's — three transactions over the same object, and § G's budget makes them their own
session rather than a second contract inside this one.

#### Deliverables

- `OwnedCluster` is the cluster a transaction owns: its declared name, the control-plane node whose
  container carries clause 3's identity, every other declared node, the configuration snapshot where the
  plan declares one, the file this run has opened for the credential, and this run's own owner binding.
- **Every node is an owned object.** Clause 3 binds exactly one identity per record, so the cluster's own
  record binds the control-plane container and each other node carries its own record beside it — exactly
  as a share is an object inside a provider instance. That is what lets a later cordon address a node by
  the identity this run bound rather than by the name a replacement inherits.
- **Every record is published before the creating command.** One `kind create cluster` brings every node
  container into existence at once, so there is no per-node moment at which a record could be written
  first; all of them are published over an explicit absence before the create runs and bound afterwards
  from what the runtime reports. Each publication is its own short-lived entry rather than a nest of them,
  because clause 2's publication is idempotent and re-entering to bind re-asserts the same fact.
- The observation asks the node's name **twice** — once of the listing and once of the inspection — rather
  than asking the listing and then re-asking the identifier it produced. Addressing the second question by
  the identifier would confirm only that the identifier still resolves; asking the name is what makes a
  container replaced between the two answer differently.
- The cluster-creating effect between the published records and the bound identities travels as a
  described `HostCommand`, so the outcome-unknown window keeps its durable meaning and the driver keeps no
  way to run a string.
- Reconcile answers with three end states an operator can tell apart: a first creation, a resumed entry
  whose cluster already existed under this record, and an entry that found all clauses held. The
  already-owned path still re-observes every worker, because the cluster's own identity says nothing about
  the other nodes.
- `FakeCluster` is the driver, container runtime, and API server as one real process — this suite's own
  executable, entered by an environment variable held for exactly the span of a fixture. One program
  serves all three tools because the argument vector says which one it is being asked as, and a vector it
  does not recognize is a refusal rather than a silent success.

#### Validation

Every decision is covered by application over values, and the clause-holding effects run against a real
protected store in a temporary directory and a real cluster client process, so no case reaches a
substitution point and none can pass against one (§ NN).

Three cases are the ones a fake could not have produced honestly. A client that really performs its create
and really dies before reporting it is recovered on the next entry **without creating again**, and the
mutation log proves the count. A cluster standing at the name under no record of this project's is refused
and leaves the mutation log empty. And a worker whose container is replaced under an otherwise owned
cluster is refused, which is the case the per-node records exist for.

The family runs and is counted on every gate host, because the client is this suite's own executable and
its durable state is ordinary files (§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
fifteen cases of `ClusterOwnershipSpec`.

#### Remaining Work

None.

### Sprint 16.45: The readiness, cordon, and cleanup drivers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The remaining cluster operations on the same face.

#### Objective boundary

Three transactions over the object Sprint 16.44 landed, and nothing else. The interpreter program the
cluster backend still ships is Sprint 16.46's, and this sprint neither removes nor reaches it.

#### Deliverables

- **One re-entry step, used by all three.** Each transaction begins by asking the driver whether the
  cluster is still named and then asking the runtime about every declared node under that node's own
  record, answering with the keys as well as the identities. A transaction that goes on to forget records
  forgets exactly the ones it re-observed, rather than deriving them a second time and having two answers
  to which key a node's record is under.
- Readiness re-enters from the durable record, asks the API server through the kubeconfig the driver hands
  back, and answers with the total node-readiness classification. A node replaced while the probe ran is a
  conflict rather than a readiness. None of its four answers is a fault: a control plane that has not come
  up, a node that has not joined, and a node set the plan does not declare are three different true
  statements about a live cluster, and a poll that treated any of them as a refusal could not wait.
- Cordon applies each declared limit to the container identity the durable record bound rather than to the
  node's name, and re-observes every node on both sides of the application. The wall itself is the one
  budget renderer's value: the argv-shaped renderer is now that list with the verb in front and the
  container behind it, so what a cluster budget caps is stated once and this driver only decides where it
  lands.
- Cleanup re-observes every owned node under the record, removes the cluster through the one interpreter,
  and forgets the records only over a reported absence. A same-named replacement is left standing, because
  clause 4 compares the identity rather than the name. Two standings short of ownership are releases rather
  than refusals — nothing at all is nothing to do, and a record published over a cluster that was never
  created is forgotten with no command issued — while a cluster created and never bound authorizes no
  removal at all, because no identity has been bound for clause 4 to compare.
- The tools the driver reaches come from the frame table, so a tool it drives and a row that holds its
  clauses are declared in one place. The declaration is exact in both directions: a tool named by a
  described command and missing from it, and a tool named in it that no command reaches, are each a
  failure rather than a silence.

#### Validation

Every conflict is reachable by application over values, and the clause-holding effects run against a real
protected store and a real cluster client process.

Three of the fifteen new cases are the ones a fake could not have produced honestly, and each is reached by
the client itself doing the thing rather than by a patch point (§ NN). A node replaced *while the readiness
probe ran* is reached by the API server putting a different container at the name after the node list it
answered — the window the transaction holds the store's exclusive entry across, which nothing outside it can
act inside. A node replaced *while the wall was applied* is reached the same way, after the first `update`
the runtime accepted. And a container that took a node's name *during the removal* is reached by the driver
performing the delete and the runtime then standing something else at the control plane's name; the case
asserts both that the replacement is left exactly as it was found and that no record was forgotten over it.

Two standings the earlier sprints could not reach are now reachable, and both by a client that really
refuses rather than by durable state written behind the driver's back: a create the driver refused without
performing leaves clause 2 durable and nothing else, which release forgets with no command issued; and a
create the client performed and then died reporting leaves a cluster created and never bound, which release
refuses.

Dated 2026-08-21 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,351/2,351 in 309.21 seconds, including the six
readiness, three cordon, and five release cases of `ClusterOwnershipSpec` and the exact tool declaration in
`ClusterCommandSpec`.

#### Remaining Work

None.

### Sprint 16.46: The cluster's interpreter program is gone [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The cluster boundary carries no program written in another language.

#### Objective boundary

The cluster's own. The Colima programs are Sprint 16.47's and the guest alias program is the
[worked-demo phase](phase-24-worked-demo.md)'s, and neither is touched here.

#### Deliverables

- The cluster backend resolves no interpreter and no locking front end, because every clause it holds is
  the seam's and every effect it performs is a described command. The 646-line embedded program, the
  protocol its reports were parsed back out of, and the eight-field kernel-object binding those reports
  carried are all gone; a binding is now the one thing clause 3 binds, which is the container identity.
- **The backend is a join rather than a driver.** What is left is deriving the owned object from the
  prepared plan-owned package, opening the protected store under the plan's own state directory, taking the
  exclusive entry once per transaction, and mapping the driver's answer onto the observation the reconciler
  classifies. The four calls are one transaction shape with four continuations, so no operation can come to
  hold a different notion of what its exclusive entry is.
- **A backend is a value the declaration decides**, exactly as the provider's is. Discovery takes the typed
  `HostConfig`, admits it when the three tools the cluster drives are resolved in it, and probes nothing:
  what a discovery once proved — a writable state directory, a locking front end, an interpreter — is the
  protected store's own to establish when the first transaction enters it.
- The private component's injected executor goes with it, and so does the component: a suite that wants the
  driver to have been answered a particular way supplies a program the one interpreter can launch, not a
  function it can call.
- **`ClusterUnhealthy` keeps a producer.** An owned cluster is asked one further question the creation path
  does not need — whether every node container the record bound is still running — because that is the
  container runtime's answer rather than the API server's, and an owned cluster whose containers are stopped
  is a conflict an operator resolves rather than something to recreate. `ownedClusterRunning` is that
  question, and it is what keeps the run-state command and its classifier from being a vocabulary nobody
  reaches.
- A source guard holds the absence, naming the [rationale](rationale.md) entry that says why a program in
  a string is refused.

#### Validation

The guard fires on a reintroduced program and stays quiet on the legitimate uses elsewhere in the tree. It
names the retired spellings exactly — the two host-tool constructors the program resolved, the one it
deliberately refused, the interpreter's own program flag, and the injected executor — and it asserts the
positive half too: a guard that only forbade the old names would stay quiet over a backend that had stopped
driving anything at all, so it also requires the described commands and the clause-holding driver to still
be reached, and that the retired private component is no longer in the tree.

The cluster family runs and is counted on every gate host now that the program only a POSIX host could
interpret is gone (§ JJ). Two consequences are worth stating. `ClusterBackendSpec`'s conditional row family
is deleted from `CoverageManifest` rather than shrunk, because its subject — a `flock(2)` namespace, an
inherited no-follow descriptor, and `/proc/self/fd` paths — no longer exists; and `ClusterReconcileSpec`'s
settlement, readiness, and cleanup cases are no longer compiled away on a Windows outer host, so the twelve
that a native Windows gate could not previously run now run there.

Every one of those cases reaches its standing by arranging what the tools report rather than by handing a
canned protocol line to an injected function (§ NN). A cluster nothing claims is a cluster the fixture's
runtime really holds; a driver contradicting its own listing really lists the same name twice; an owned
cluster that went unhealthy really has stopped containers; a replacement really takes a node's name between
two commands; and the standing an operator leaves by discarding this project's origin while its cluster
stays up is reached through the protected store's own compare-and-delete.

Dated 2026-08-21 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,328/2,328 in 318.16 seconds, and
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` passed at
231. The total is lower than the previous run's and that is the point: forty-six cases whose subject was the
retired program are gone, and twelve that a Windows gate host previously compiled away now run.

#### Remaining Work

None.

### Sprint 16.47: The direct-Colima ownership driver [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Internal.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

The six durable Colima stages as one Haskell state machine over the seam.

#### Deliverables

- Acquisition, cleanup, and live Docker hold their clauses through the seam, with the stage graph a pure
  total transition function from state and observation to the next state or a typed refusal.
- The bounded command the driver supervises is a transaction shipped to this machine, because its
  parent-death watch — the group kill that fires when the owning process disappears without running any
  handler — is not something the launcher's own bracket can promise.
- Every artifact identity, namespace binding, and directory-chain digest the stages record is expressed in
  the shared record vocabulary rather than a driver-local encoding.
- The tool candidates and their canonical bindings stay a fixed table in an unexposed component (§ K); the
  refactor changes what holds the clauses, not who may choose a candidate.

#### Validation

The stage graph, the argument vectors, and the classification of each tool result are pure and are covered
by application over values, so the suite needs no stand-in executable on `PATH` to reach them (§ NN). The
clause-holding effects run against the real kernel, which the static gate reaches on any POSIX gate host.
Live confirmation against real Colima is the
[Apple-Silicon-substrate phase](phase-25-apple-silicon-substrate.md)'s and is recorded as owed here. The
crash windows that a fault-injection argument reaches today are named as owed rather than counted.

#### Remaining Work

All adoption, tests, guards, and documentation.

### Sprint 16.48: The live cluster gate as a harness case [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/testing.md`

#### Objective

Make the live gate a verb an operator already knows.

#### Deliverables

- The bare binary carries a real test suite with one live cluster case, reached by `test run`. A gate is
  something the fixed command tree already expresses (§ P), so it needs no second surface.
- The case takes its exclusive run, its lease, its clause-holding cleanup, and its report from the harness
  rather than arranging each itself.
- The cluster identity the case brings up is the harness run's own, so a pre-existing cluster is a refusal
  the harness already makes rather than a check the case repeats.
- The durable root the case reads back is outside everything the case may delete, which is the property
  the gate exists to prove.

#### Validation

`hostbootstrap test run cluster-live` on a disposable linux-cpu host: a fresh cluster reaches node
readiness, answers a read-only observation, is deleted, leaves no labelled node container, and leaves the
durable-root sentinel byte-identical. Record the date, host, architecture, toolchain versions, duration,
and result with the phase acceptance below.

#### Remaining Work

All implementation, tests, and documentation.

### Sprint 16.49: The enumeration names what the binary drives [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Narrow the `HostTool` enumeration to the tools the binary still delegates to, and pin it there.

#### Deliverables

- `Python3`, `Flock`, and `Lockf` leave the enumeration. § K admits a tool the project genuinely
  **delegates** to; these three are how an interpreter and a locking front end performed ownership on the
  binary's behalf, and Sprints 16.44 and 16.47 replace that with the binary's own typed operation over one
  platform row. The names go with the last driver that needed them.
- `requiredClusterTools` loses `Flock` and `Python3`, which is the last host-side site. The alias driver's
  `Flock` is a local `ExclusionTool` and its Python and lock front ends are the guest's own, reached through
  one absolute host-provider command — § K's carve-out, on a different axis, unaffected by this sprint.
- `Lockf` leaves with them. It exists only as the discriminator that refuses a host offering `lockf` where
  `flock` is required, and a discriminator for a front end the binary no longer resolves has nothing to
  discriminate.
- `HostToolSpec` gains the **exact** membership pin — `allHostTools` compared against the complete list,
  not a subset check — so a tool the project does not delegate to cannot re-enter the set. That is the
  absence guard for the shape this sprint removes (§ I), which is why it ships here rather than with the
  boundary.

#### Validation

`HostToolSpec`'s exact membership assertion, proved non-vacuous by naming the complete set rather than a
lower bound; `ClusterBackendSpec` and `ProviderBackendSpec` over the narrowed discovery.

#### Remaining Work

All narrowing, the pin, and documentation.

## Static Validation Evidence

On 2026-08-10, the published
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` image at
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, running Linux
6.8.0-100-generic on aarch64 with GHC 9.12.4 and Cabal 3.16.1.0, passed a clean
`cabal test all --ghc-options=-Werror` from `core/`: all 1,835 tests passed in 154.12 seconds. A supporting
macOS arm64 run passed the same 1,835 tests in 346.23 seconds. The Linux result closes the static portion of
the phase gate; the exact composed static-plus-live result is recorded below.

On 2026-08-20, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 2,336 tests passed in 300.51 seconds, including
the described cluster commands, the cluster report classifiers, the cluster resumption decisions, and the
owned cluster's reconcile driver against a real protected store and a real cluster client process. The
same host passed `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231. § II makes this a gate-host record rather than a
substrate declaration, and it does not substitute for the composed live gate below.

On 2026-08-21, the same Windows host and toolchain passed `cabal test all --ghc-options=-Werror` from
`core/`: all 2,351 tests passed in 309.21 seconds, including the readiness, cordon, and release
transactions Sprint 16.45 adds — each against a real protected store and a real cluster client process,
with the three replacement windows reached by that client rather than by a patch point. The same host
passed `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
at 231. § II makes this a gate-host record rather than a substrate declaration, and it does not substitute
for the composed live gate below.

## Phase-Level Baseline Acceptance

After the implementation sprints pass their static checks, run the exact phase gate on a disposable
linux-cpu host:

```text
(cd core && cabal test all --ghc-options=-Werror) && hostbootstrap test run cluster-live
```

The run must create a fresh isolated Kind cluster, wait for all nodes Ready, perform a read-only status
observation, delete the cluster, prove its labelled node containers absent, and re-read the exact durable-root
sentinel outside the deletion boundary. Record the date, host/OS/architecture, GHC/Cabal/Kind/Kubernetes
versions, duration, and result here.

On 2026-08-10 the live half passed on its own in the published arm64 Linux CPU base environment against the
host Docker engine after creating and deleting a fresh Kind cluster. That independent result validates the
live mechanics separately from the composed result.

**2026-08-10 — passed.** The composed gate of that date ran in the published
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` image at
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, on Linux
6.8.0-100-generic aarch64 with GHC 9.12.4, Cabal 3.16.1.0, Kind v0.32.0, kubectl client v1.36.3, and
Kubernetes node v1.36.1. It exited 0 in 455 seconds. The static half passed all 1,835 tests, and the live
half created `hostbootstrap-phase16-19575488ca6342ebaeebffa2`, waited for its nodes to become Ready,
performed the required read-only node observation, deleted the cluster, proved its labelled node containers
absent, and re-read the durable-root sentinel with its exact original contents.

## Remaining Work

Every sprint through 16.46 is complete. The **cluster ownership driver** is built and adopted: Sprint 16.40
made the read-only status probe one bounded run and one total function, Sprint 16.41 made every cluster
effect a described command, Sprint 16.42 made what each answer means a total function of the bytes, Sprint
16.43 made where a transaction stands a total function of three values, Sprint 16.44 composed them into the
clause-holding create, Sprint 16.45 put readiness, cordon, and release on the same face, and Sprint 16.46
deleted the program they replace along with the private component its injected executor lived in. What
remains is the phase's shape under § KK, § LL, and § NN, in three parts:
- **The direct-Colima ownership driver** does the same for its six durable stages, and its bounded-command
  supervision becomes a transaction shipped to this machine — the parent-death watch that kills the group
  when the owning process disappears has no in-process equivalent, so it stays a separate process rather
  than becoming an ordinary bounded run.
- **The live gate is a case behind the fixed `test` verb.** The bare binary already carries the test-suite
  seam, and the harness already owns the exclusive run, the lease, the clause-holding cleanup, and the
  report card that a gate otherwise hand-rolls.
- **The enumeration narrows.** Once the two drivers above stop resolving an interpreter and a locking front
  end, `Python3`, `Flock`, and `Lockf` name nothing the binary drives, and Sprint 16.49 removes them and
  pins the set against re-entry.

Two consequences are worth stating rather than discovering. The crash windows that a patchable instruction
point reaches today are **named as owed** in the sprints that replace it rather than counted as covered
(§ NN). And the sprints that describe the mechanism their own boundaries hold today are restated in the same
change that moves them onto the seam — § A rewrites a phase in place, and § C keeps the plan describing the
current repository state rather than the intended one, so neither happens first.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — settled backend routes and their consumers.
- `documents/architecture/durable_state.md` — the never-delete invariant and the preserve policy.
- `documents/architecture/hostbootstrap_core_library.md` — exact cluster and direct-Colima library surfaces.
- `documents/architecture/lifecycle_state_model.md` — raw observations versus exact prepared and settled
  packages.
- `documents/architecture/ownership_invariant.md` — the cluster and Colima locked-origin clause holders.
- `documents/architecture/readiness.md` — backend-minted dependencies and identity-bound cluster readiness.
- `documents/architecture/unrepresentable_state.md` — provider-start, settlement, live, and cleanup authority
  boundaries and their named compile-fail evidence.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` — exact plan-owned bring-up, status, readiness, and teardown.
- `documents/engineering/applied_cordon.md` — the pure preflight and the applied constructive slice.
- `documents/engineering/resource_budgeting.md` — generic budget admission and exact cluster/Colima consumers.
- `documents/engineering/ensure_reconcilers.md` — why the direct Colima wall is not a config-free reconciler.

**Cross-references to add:**
- `development_plan_standards.md` § K records the fixed private direct-Colima resolver as a closed host-tool
  resolution form; § O names this phase as the owner of the applied cordon; §§ EE/HH bind ownership and
  bounded child lifetime to the exact consumer.
