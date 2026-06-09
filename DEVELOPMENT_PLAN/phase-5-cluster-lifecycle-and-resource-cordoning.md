# Phase 5: Cluster Lifecycle and Resource Cordoning

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Land kind/Helm cluster-lifecycle semantics, resource-budget verification and
> cordoning (per-project Colima VM on Apple, kind node limits on Linux), the never-delete-`.data`
> invariant, and the production-vs-test cluster profile.

## Phase Status

**Status**: Done

`HostBootstrap.Cluster.Cordon` derives the substrate-specific cordon (`colimaSizingArgs`,
`kindNodeCordonArgs`, `incusSizingArgs`) and `verifyBudget` checks spare capacity;
`HostBootstrap.Cluster.Lifecycle` provides `cluster up` / `down` / `delete` / `status` with the
never-delete-`.data` invariant (per-case test data is under `./.test_data/<case>/`) and the
production-versus-test profile distinction. The pure cores (`parseQuantity`, `verifyBudget`,
`resolvePlan`, `teardown`, `statusReport`) are unit-tested. The applied cordon and the wired
`verifyBudget` preflight **landed** (delivered in
[phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)): `cluster up` runs
the spare-capacity preflight and applies the Linux `docker update` kind-node cordon after `kind create`,
before Helm, fail-closed. The incus storage cordon landed in
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md). All reopened items are closed (see
[development_plan_standards.md § O](development_plan_standards.md)).

All reopened items have **landed**: the read-only `cluster status` verb (Sprint 5.3); the applied Linux
`docker update` kind-node cordon, the wired `verifyBudget` preflight, the pure `fitsBudget`, and the one
canonical `parseQuantity`/arg-builder (all in
[phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md); the dual Python
budget interpreter was already removed in Phase 6); and the incus VM storage cordon (`incusSizingArgs`,
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)). Live `docker`/`kind`/`incus`
execution is exercised in real runs.

## Phase Objective

Land the cluster-lifecycle and resource contracts in `hostbootstrap-core` (see
[development_plan_standards.md § O](development_plan_standards.md)). `hostbootstrap` verifies the host
has the spare budget declared in `resources` and cordons it — on Apple by sizing a dedicated
per-project Colima VM, on Linux by applying kind node resource limits — drives kind/Helm cluster
lifecycle, never deletes host `.data`, and distinguishes the production cluster profile (fixed name /
`.data` path) from the test profile (per-case isolated paths).

## Sprints

### Sprint 5.1: Resource budget verification + cordoning [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`
**Docs to update**: `documents/engineering/resource_budgeting.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Cluster.Cordon`: verify the host has the spare `resources` budget and cordon it
to the project.

#### Deliverables

- Budget verification reading `resources {cpu, memory, storage}` and checking spare host capacity.
- Apple cordoning: **derive** the sizing for a dedicated per-project Colima VM from the budget.
- Linux cordoning: **derive** kind node resource limits from the budget.

The pure cordon **derives** the args; **applying** them — the Colima/incus VM sizing and the
`docker update` kind-node cap — is wired in Phase 9 (see this phase's Remaining Work).

#### Validation

- `CordonSpec` asserts a budget exceeding spare capacity fails fast naming the over-committed
  dimension, and that `colimaSizingArgs` / `kindNodeCordonArgs` reflect the declared budget. `cabal test`
  passes.

#### Remaining Work

None for the pure cordon logic. Live host-capacity probing on each substrate is exercised during
Phase 6 bootstrapping.

### Sprint 5.2: Cluster lifecycle + profiles + never-delete-.data [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Cluster.Lifecycle`: kind/Helm `up`/`down`/`delete` semantics with the
never-delete-`.data` invariant and the production-vs-test profile distinction.

#### Command Surface

- `hostbootstrap cluster up` — bring the stack to running (idempotent), within the cordoned budget.
- `hostbootstrap cluster down` — tear the cluster down; preserve host `.data`.
- `hostbootstrap cluster delete` — thorough teardown of derived state; still never deletes `.data`.

#### Deliverables

- kind/Helm lifecycle driving cluster creation, Helm release management, and teardown.
- The never-delete-`.data` invariant enforced on both `down` and `delete`.
- A `ClusterProfile` distinguishing production (fixed name / `.data` path) from test (per-case
  isolated paths), so the harness-driven test profile never collides with a production cluster.

#### Validation

- `LifecycleSpec` asserts `teardown Down` / `teardown Delete` never place `.data` in the removal set
  (for both profiles), and that the production and test profiles resolve distinct cluster names and
  host paths. `cabal test` passes; `hostbootstrap cluster --help` lists `up`/`down`/`delete`.

#### Remaining Work

None.

### Sprint 5.3: Read-only `cluster status` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `system-components.md`

#### Objective

Add a read-only `cluster status` verb that reports whether the resolved cluster is live without
mutating any state, completing the Phase-5-owned command surface (the applied cordon and the
`verifyBudget`/one-parser work are Phase 9).

#### Command Surface

- `hostbootstrap cluster status` — probe `kind get clusters` and report the resolved cluster's
  liveness, the preserved `.data` path, and the derived paths. Never mutates state.

#### Deliverables

- The pure `statusReport :: ClusterPlan -> Bool -> String` renderer and the IO `clusterStatus` driver
  in `HostBootstrap.Cluster.Lifecycle`, with `cluster status` wired into the `cluster` command group.

#### Validation

- `LifecycleSpec` asserts the status report names the cluster, marks it running/absent, and always
  shows the preserved `.data` path. `cabal test` passes; `hostbootstrap cluster --help` lists
  `up`/`down`/`delete`/`status`.

#### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` - budget verification, Colima per-project VM sizing
  on Apple, kind cordoning on Linux.
- `documents/engineering/cluster_lifecycle.md` - kind/Helm semantics, the never-delete-`.data`
  invariant, the production-vs-test profile.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.*` rows and the resource-cordoning
  section.
