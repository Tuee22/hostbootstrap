# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md)

> **Purpose**: Define the per-project resource budget read from the skeletal `hostbootstrap.dhall`,
> the verify-spare-resources step, and how the budget is cordoned per substrate.

## TL;DR

- The skeletal `hostbootstrap.dhall` declares a per-project resource budget: `cpu`, `memory`,
  `storage`.
- Target: `hostbootstrap` verifies the host has the spare budget available before proceeding, and
  cordons the budget per substrate — a dedicated per-project Colima VM on Apple, kind node resource
  limits on Linux.
- Current state: the budget and cordon are computed and reported but not yet applied; `verifyBudget`
  is not yet wired into any IO path. The wiring is tracked in Phase 5 / Phase 9 (see below).
- The budget is the one field both the Python bootstrapper and the project binary consume.

## The Budget Field

The resource budget is a `resources` record in the skeletal schema described in [schema](schema.md):

```dhall
{ project    = "app"
, dockerfile = "docker/app.Dockerfile"
, resources  = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
```

- `cpu` — whole cores reserved for the project's substrate.
- `memory` — memory ceiling for the project's substrate.
- `storage` — disk budget for the project's substrate (image layers, cluster data, build outputs).

This is the only skeletal field consumed by both layers: the Python bootstrapper reads it to size the
Colima VM on Apple before the build, and the project binary reads it (via the same skeletal decoder
in `hostbootstrap-core`) when it stands up clusters. See
[python_haskell_boundary](../architecture/python_haskell_boundary.md).

## Verify-Spare-Resources

The target model: before cordoning, `hostbootstrap` checks that the host actually has the requested
budget spare. If the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line
diagnostic naming the shortfall and exits non-zero rather than over-committing the host.

The current state differs: `verifyBudget` is implemented and unit-tested but not yet wired into any
IO path, so no command resolves live host capacity or fails fast on a shortfall today. Wiring this
verification into cluster bring-up is a later-phase deliverable owned by
[phase-5-cluster-lifecycle-and-resource-cordoning](../../DEVELOPMENT_PLAN/phase-5-cluster-lifecycle-and-resource-cordoning.md)
and [phase-9-applied-cordon-and-one-parser](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md).

## Cordoning per Substrate

The budget is enforced — cordoned — so a project's workload cannot exceed its declared share.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | A dedicated per-project Colima VM sized to `cpu` / `memory` / `storage`. The VM boundary is the cordon: the project's Docker workload runs inside its own sized VM, isolated from the host and from other projects' VMs. |
| `linux-cpu` / `linux-gpu` | kind node resource limits applied to the project's cluster nodes, capping the cluster's consumption to the declared budget. |

In the target model, on Apple the cordon is created during the Python bootstrap sequence (the
per-project Colima VM must exist before the build); on Linux it is applied as part of cluster
bring-up. The cluster-side enforcement is part of the lifecycle semantics in
[cluster_lifecycle](cluster_lifecycle.md). Currently the cordon is computed and reported but not yet
applied: `cluster up` derives and prints the cordon without running colima sizing or applying kind
node limits. Applying the cordon is a later-phase deliverable tracked in
[phase-5-cluster-lifecycle-and-resource-cordoning](../../DEVELOPMENT_PLAN/phase-5-cluster-lifecycle-and-resource-cordoning.md)
and [phase-9-applied-cordon-and-one-parser](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md).

`HostBootstrap.Cluster.Cordon` implements this: `parseQuantity` decodes Kubernetes-style memory and
storage quantities to bytes, `verifyBudget` fails fast naming the first dimension that exceeds spare
host capacity, and `colimaSizingArgs` / `kindNodeLimits` derive the substrate-specific cordon from the
budget. These pure functions are unit-tested. In the target model the `cluster` command resolves live
host capacity and runs the sized tools; today it only computes and reports the cordon — `verifyBudget`
is not yet wired into any IO path, and `cluster up` does not yet apply kind node limits or run colima
sizing. That wiring is tracked in
[phase-5-cluster-lifecycle-and-resource-cordoning](../../DEVELOPMENT_PLAN/phase-5-cluster-lifecycle-and-resource-cordoning.md)
and [phase-9-applied-cordon-and-one-parser](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md).
