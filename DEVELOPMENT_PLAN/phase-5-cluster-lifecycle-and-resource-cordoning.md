# Phase 5: Cluster Lifecycle and Resource Cordoning

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Land kind/Helm cluster-lifecycle semantics, resource-budget verification and
> cordoning (per-project Colima VM on Apple, kind node limits on Linux), the never-delete-`.data`
> invariant, and the production-vs-test cluster profile.

## Phase Status

**Status**: Active

`HostBootstrap.Cluster.Cordon` derives the substrate-specific cordon (`colimaSizingArgs`,
`kindNodeLimits`) and `verifyBudget` checks spare capacity; `HostBootstrap.Cluster.Lifecycle` provides
`cluster up` / `down` / `delete` with the never-delete-`.data` invariant (per-case test data is now
under `./.test_data/<case>/`) and the production-versus-test profile distinction. The pure cores
(`parseQuantity`, `verifyBudget`, `resolvePlan`, `teardown`) are unit-tested, and `cluster up` reports
the cordon and degrades gracefully when `kind`/`Helm` are absent. **The cordon is computed and
reported but not yet APPLIED**, and `verifyBudget` is not yet wired into the bring-up path — so the
declared budget ceiling is not actually enforced on Linux. This phase reopens against the
budget-as-ceiling contract (see [development_plan_standards.md § O](development_plan_standards.md)).

**Remaining Work** (reopened; the applied cordon is tracked in the net-new Phase 9):
- Wire the applied Linux cordon: `docker update --cpus/--memory <cluster>-control-plane` after
  `kind create`, before Helm, fail-closed (today `kindNodeLimits` is computed and only printed by
  `reportCordon`).
- Run `verifyBudget` (and the net-new pure `fitsBudget`) as a real pre-bring-up fail-fast gate.
- Collapse the dual budget interpreters (Haskell `colimaSizingArgs` vs Python `_gib` /
  `colima_start_command`) to one canonical quantity parser/arg-builder, with a golden test (covers
  the Python `_gib("8Gi")` mishandling).
- Add `cluster status` (read-only) and a per-substrate storage cordon.

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
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`
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
  dimension, and that `colimaSizingArgs` / `kindNodeLimits` reflect the declared budget. `cabal test`
  passes.

#### Remaining Work

None for the pure cordon logic. Live host-capacity probing on each substrate is exercised during
Phase 6 bootstrapping.

### Sprint 5.2: Cluster lifecycle + profiles + never-delete-.data [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`haskell/hostbootstrap-core/src/HostBootstrap/Command.hs`
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

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` - budget verification, Colima per-project VM sizing
  on Apple, kind cordoning on Linux.
- `documents/engineering/cluster_lifecycle.md` - kind/Helm semantics, the never-delete-`.data`
  invariant, the production-vs-test profile.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.*` rows and the resource-cordoning
  section.
