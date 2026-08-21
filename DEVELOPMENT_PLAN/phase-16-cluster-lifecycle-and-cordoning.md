# Phase 16 — Cluster lifecycle, budgets, and cordoning

**Status**: Active
**Current sprint**: Sprint 16.41 — The cluster ownership driver
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

## Static Validation Evidence

On 2026-08-10, the published
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` image at
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, running Linux
6.8.0-100-generic on aarch64 with GHC 9.12.4 and Cabal 3.16.1.0, passed a clean
`cabal test all --ghc-options=-Werror` from `core/`: all 1,835 tests passed in 154.12 seconds. A supporting
macOS arm64 run passed the same 1,835 tests in 346.23 seconds. The Linux result closes the static portion of
the phase gate; the exact composed static-plus-live result is recorded below.

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

### Sprint 16.41: The cluster ownership driver [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The cluster's clauses, held through the one seam.

#### Deliverables

- Reconcile, cordon, readiness, and cleanup hold their clauses through the seam's producers and the row
  the frame declares.
- The cluster-creating effect between the origin record and the identity binding travels as a described
  `HostCommand`, so the outcome-unknown window keeps its durable meaning and the driver keeps no way to
  run a string.
- The read-only status observation is a pure classification over a bounded run: the driver builds the
  argument vector, the runner runs it, and a total function turns the result into a decision.
- Identity is the control-plane node container's own, as it is today; what changes is where the
  comparison lives, not what it compares.
- The tools the driver reaches come from the frame table, so a tool it drives and a row that holds its
  clauses are declared in one place.

#### Validation

Every classification is covered by application over values, including each conflict and each refusal. The
clause-holding effects are exercised against the real kernel in a temporary directory. No case reaches a
substitution point, so none can pass against one (§ NN).

#### Remaining Work

All adoption, tests, guards, and documentation.

### Sprint 16.42: The direct-Colima ownership driver [Planned]

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

### Sprint 16.43: The live cluster gate as a harness case [Planned]

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

### Sprint 16.44: The enumeration names what the binary drives [Planned]

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
  binary's behalf, and Sprints 16.41 and 16.42 replace that with the binary's own typed operation over one
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

## Remaining Work

Every sprint through 16.40 is complete. What remains is the phase's shape under § KK, § LL, and § NN, in
four parts:

- **The cluster ownership driver** holds its clauses through the seam the
  [four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)
  supplies, over the row the frame declares. Its read-only status probe is already there: Sprint 16.40
  made it one bounded run of the driver's own listing and one total function over what came back, so what
  is left is the clause-holding transaction itself.
- **The direct-Colima ownership driver** does the same for its six durable stages, and its bounded-command
  supervision becomes a transaction shipped to this machine — the parent-death watch that kills the group
  when the owning process disappears has no in-process equivalent, so it stays a separate process rather
  than becoming an ordinary bounded run.
- **The cluster backend consumes the frame table** rather than resolving its own tools, so the tools it
  drives and the row that holds its clauses come from one place.
- **The live gate is a case behind the fixed `test` verb.** The bare binary already carries the test-suite
  seam, and the harness already owns the exclusive run, the lease, the clause-holding cleanup, and the
  report card that a gate otherwise hand-rolls.
- **The enumeration narrows.** Once the two drivers above stop resolving an interpreter and a locking front
  end, `Python3`, `Flock`, and `Lockf` name nothing the binary drives, and Sprint 16.44 removes them and
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
