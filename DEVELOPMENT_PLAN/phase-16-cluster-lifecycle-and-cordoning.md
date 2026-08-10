# Phase 16 — Cluster lifecycle, budgets, and cordoning

**Status**: Active
**Depends on**: Phase 12 (the generic plan-indexed budget boundary), Phase 15 (host providers and the
self-reference lift)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a fresh live cluster bring-up and teardown
on linux-cpu

> **Purpose**: Bring a cluster up inside a declared resource budget, cordon what the project may consume, and
> keep the durable host root outside everything the lifecycle may delete.

## Phase Objective

A cluster is the innermost frame most deployments end in. Three things must be true of it: it fits inside a
budget the project declared, its storage and compute are cordoned so a run cannot consume the host, and its
teardown cannot reach the durable state the project exists to keep. This phase adopts those mechanics at the
exact cluster and direct-Colima consumers. The provider-neutral capacity/sizing/cordon foundation comes from
Phase 6, the generic plan-indexed budget algebra comes from Phase 12, and the worked demo later supplies its
concrete workload, overhead, partition, and slice projection.

## Sprints

### Sprint 16.1: Plan-independent cluster lifecycle foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Supply the plan-independent backend observations and cluster lifecycle operations that the exact plan-owned
consumer later seals into prepared calls.

#### Deliverables

- `Cluster.Backend` owns the raw kind/nvkind command and observation vocabulary without assigning plan
  identity or mutation authority to a probe result.
- The lifecycle foundation observes an existing cluster before deciding create, unchanged, conflict, or
  teardown behavior; it does not infer ownership from a same-shaped name.
- Bring-up, status, readiness, and teardown have one backend seam, with status remaining read-only and
  failures represented structurally.
- The raw backend and lifecycle vocabulary accept canonical lower capacity/cordon values but no
  `ProjectPlan`, independently assembled configuration graph, or plan-derived authority.
- Exact plan/resource/topology admission is an additive consumer boundary in Sprint 16.2 rather than a
  second backend representation.

#### Validation

`ClusterBackendSpec` and `ClusterReconcileSpec` cover command/observation shapes, create versus unchanged and
conflict classification, readiness ordering, read-only status, and teardown behavior.

#### Remaining Work

None. The exact plan/resource/topology consumer is Sprint 16.2; the lower canonical capacity and cordon
foundation belongs to Phase 6.

### Sprint 16.2: Exact plan-owned cluster consumer [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Make cluster reconciliation consume the exact cluster resource and topology projected by one `ProjectPlan`.

#### Deliverables

- Cluster preparation accepts one `ProjectPlan`, its matching cluster `PlannedResource`, provider dependency,
  `DerivedTopology`, and the exact budget slice produced by the generic Phase-12 admission boundary.
- The consumer accepts no compatibility `Reconcile.LifecyclePlan`, caller-supplied plan digest or frame, raw
  `ClusterProfile`, independently resolved root, or separately assembled resource/topology graph.
- A raw `ClusterObservation` remains deliberately plan-independent backend data. The prepared operation,
  settled `ReconcileResult`, managed handle, cleanup authority, and readiness evidence retain the exact source
  plan indices.
- Bring-up reconciles observed state and refuses an unhealthy or unverifiable same-named cluster without
  deleting it. Readiness is observed before a dependent planned step is offered, and `cluster status` remains
  read-only.
- Cluster name, durable root, ports, placement, rendered configuration, and ownership identity are projected
  from that retained plan package; Harness and Production cannot be relabeled into one another.

#### Validation

`ClusterBackendSpec` and `ClusterReconcileSpec` cover exact plan/resource/topology/slice consumption, readiness
ordering, the read-only status path, ownership classification, and fail-closed refusal. Compile-fail fixtures
reject a cluster resource, provider dependency, topology, or slice from another plan.

#### Remaining Work

All exact-consumer deliverables, focused validation, and the fresh phase gate.

### Sprint 16.3: Structural durable-root exclusion [Done]

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

### Sprint 16.4: Exact plan-owned direct-Colima consumer [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Make the direct Apple Colima wall consume one exact plan-owned provider package rather than descriptive
compatibility context.

#### Deliverables

- Profile admission accepts one `ProjectPlan`, its matching provider `PlannedResource`, `DerivedTopology`, and
  the exact budget, workload-fit, partition, reservation, and wall evidence produced for that plan.
- The adapter accepts no compatibility `Reconcile.LifecyclePlan`, independent `BinaryContext`, caller-selected
  profile name, raw resource envelope, or separately derived root/profile term.
- Raw Colima list, call, and stable-machine observations remain plan-independent. The prepared call, settlement,
  live wall, Docker-context projection, and cleanup authority retain the exact plan indices.
- The adapter observes before mutation, refuses an incompatible same-name profile, never activates or mutates
  the shared `default` profile, and installs Colima only when it is absent.

#### Validation

`ColimaSpec` covers exact plan-owned profile derivation, install-if-absent, observe/prepare/settle behavior,
same-name conflict, stable-machine re-observation, and non-activation of the shared default profile. A
compile-fail fixture rejects a provider resource, topology, partition, or reservation from another plan.

#### Remaining Work

All exact-consumer deliverables and their validation.

## Remaining Work

Sprint 16.2 adopts the exact Phase-12 budget/resource/topology package at the cluster consumer. Sprint 16.4
does the same at the direct-Colima wall. After both are implemented, the complete phase gate and its declared
fresh live linux-cpu bring-up and teardown must pass.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` — the never-delete invariant and the preserve policy.
- `documents/architecture/lifecycle_state_model.md` — raw observations versus exact prepared and settled
  packages.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` — exact plan-owned bring-up, status, readiness, and teardown.
- `documents/engineering/applied_cordon.md` — the pure preflight and the applied constructive slice.
- `documents/engineering/resource_budgeting.md` — generic budget admission and exact cluster/Colima consumers.
- `documents/engineering/ensure_reconcilers.md` — why the direct Colima wall is not a config-free reconciler.

**Cross-references to add:**
- `development_plan_standards.md` § O names this phase as the owner of the applied cordon.
