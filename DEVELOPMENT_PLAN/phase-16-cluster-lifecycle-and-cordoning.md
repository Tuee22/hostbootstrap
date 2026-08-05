# Phase 16 — Cluster lifecycle, budgets, and cordoning

**Status**: Done
**Depends on**: Phase 15 (host providers and the self-reference lift)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a live cluster bring-up and teardown on
linux-cpu

> **Purpose**: Bring a cluster up inside a declared resource budget, cordon what the project may consume, and
> keep the durable host root outside everything the lifecycle may delete.

## Phase Objective

A cluster is the innermost frame most deployments end in. Three things must be true of it: it fits inside a
budget the project declared, its storage and compute are cordoned so a run cannot consume the host, and its
teardown cannot reach the durable state the project exists to keep.

## Sprints

### Sprint 16.1: Budget verification and cordoning [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/applied_cordon.md`

#### Objective

Refuse a cluster that does not fit, before anything is created.

#### Deliverables

- `verifyBudget` is the cluster-capacity preflight: the resolved capacity plus the metal reserve must admit the
  declared workload set, and the refusal names the shortfall.
- Cordoning derives the project's slice constructively from the budget partition, so a slice is a proof rather
  than a calculation a call site could redo differently.
- A removal set is explicit: `guardTestDelete` refuses a delete whose target is not in the set, so a cleanup
  cannot widen itself.
- The durable host root is never in any removal set.

#### Validation

`CordonSpec` and `BudgetSpec` cover the preflight refusal, the constructive partition, and the guarded delete.

#### Remaining Work

None.

### Sprint 16.2: Cluster plans and backends [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

One finalized cluster plan whose identity comes from the project plan.

#### Deliverables

- A cluster plan derives its name, data root, ports, and ownership identity together from the project plan, so a
  harness run and a production run cannot collide on any of them.
- Bring-up is a reconcile against observed state, and readiness is ordered at the cluster boundary — a dependent
  step is not offered until the cluster's own readiness is observed.
- `cluster status` is read-only and mutates nothing.
- Bring-up is fail-closed: a cluster that cannot be verified is not proceeded past.
- A placement-specific cluster configuration is rendered as output rather than assembled by string edits, so the
  configuration a backend receives is the plan's.

#### Validation

`ClusterBackendSpec` and `ClusterReconcileSpec` cover plan derivation, the readiness ordering, the read-only
status path, and the fail-closed refusal. Dated live evidence: cluster bring-up and teardown reported `10/10` on
native linux-cpu.

#### Remaining Work

None.

### Sprint 16.3: Durable roots across down and destroy [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Make the never-delete-durable-state invariant structural.

#### Deliverables

- `down` may delete an ephemeral cluster, because that cluster has no reliable stop contract, but it deletes no
  durable root and no provider frame or disk.
- `destroy` may delete owned provider frames and disks, while the host-durable root stays outside them.
- The durable root participates in the one plan as a `PreserveOnReverse` node, so its exclusion is a declared
  policy rather than a call-site exception.
- A destroy followed by an up reads the same bytes back.

#### Validation

`ClusterBackendSpec` covers the per-verb effects, and the durable read-back is confirmed on the live linux-cpu
lane.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` — the never-delete invariant and the preserve policy.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` — bring-up, stop-without-delete, and teardown as plan nodes.
- `documents/engineering/applied_cordon.md` — the preflight and the constructive slice.

**Cross-references to add:**
- `development_plan_standards.md` § O names this phase as the owner of the applied cordon.
