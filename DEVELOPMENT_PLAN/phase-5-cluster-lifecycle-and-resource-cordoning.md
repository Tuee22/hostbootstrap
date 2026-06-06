# Phase 5: Cluster Lifecycle and Resource Cordoning

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Land kind/Helm cluster-lifecycle semantics, resource-budget verification and
> cordoning (per-project Colima VM on Apple, kind node limits on Linux), the never-delete-`.data`
> invariant, and the production-vs-test cluster profile.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-4 (lifecycle reads the resource budget from the skeletal Dhall and exposes its
verbs through the command tree) and phase-3 (`ensure docker` / `ensure colima`).

No code in this phase is written. Cluster `up`/`down`/`delete` exist today only as Python Click
verbs (`hostbootstrap/cli.py`) that dispatch into the three execution models.

## Phase Objective

Land the cluster-lifecycle and resource contracts in `hostbootstrap-core` (see
[development_plan_standards.md § O](development_plan_standards.md)). `hostbootstrap` verifies the host
has the spare budget declared in `resources` and cordons it — on Apple by sizing a dedicated
per-project Colima VM, on Linux by applying kind node resource limits — drives kind/Helm cluster
lifecycle, never deletes host `.data`, and distinguishes the production cluster profile (fixed name /
`.data` path) from the test profile (per-case isolated paths).

## Sprints

### Sprint 5.1: Resource budget verification + cordoning [Blocked]

**Status**: Blocked
**Blocked by**: phase-4, sprint 4.1
**Docs to update**: `documents/engineering/resource_budgeting.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Cluster.Cordon`: verify the host has the spare `resources` budget and cordon it
to the project.

#### Deliverables

- Budget verification reading `resources {cpu, memory, storage}` and checking spare host capacity.
- Apple cordoning: size a dedicated per-project Colima VM to the budget (driven through
  `ensure colima`).
- Linux cordoning: apply kind node resource limits to the budget.

#### Validation

- A budget exceeding spare host capacity fails fast with a clear diagnostic.
- The Colima VM / kind node limits reflect the declared budget.

#### Remaining Work

- All of it; blocked on phase-4.

### Sprint 5.2: Cluster lifecycle + profiles + never-delete-.data [Blocked]

**Status**: Blocked
**Blocked by**: sprint 5.1, phase-3, sprint 3.2
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

- `cluster down` / `cluster delete` leave host `.data` intact.
- The production and test profiles resolve distinct cluster names and host paths.

#### Remaining Work

- All of it; blocked on sprint 5.1.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` - budget verification, Colima per-project VM sizing
  on Apple, kind cordoning on Linux.
- `documents/engineering/cluster_lifecycle.md` - kind/Helm semantics, the never-delete-`.data`
  invariant, the production-vs-test profile.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.*` rows and the resource-cordoning
  section.
