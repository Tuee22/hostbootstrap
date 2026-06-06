# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md)

> **Purpose**: Define the per-project resource budget read from the skeletal `hostbootstrap.dhall`,
> the verify-spare-resources step, and how the budget is cordoned per substrate.

## TL;DR

- The skeletal `hostbootstrap.dhall` declares a per-project resource budget: `cpu`, `memory`,
  `storage`.
- `hostbootstrap` verifies the host has the spare budget available before proceeding.
- It cordons the budget per substrate: a dedicated per-project Colima VM on Apple, kind node resource
  limits on Linux.
- The budget is the one field both the Python bootstrapper and the project binary consume.

## The Budget Field

The resource budget is a `resources` record in the skeletal schema described in [schema](schema.md):

```dhall
{ project    = "daemon-substrate"
, dockerfile = "./Dockerfile"
, resources  = { cpu = 4, memory = "8Gi", storage = "40Gi" }
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

Before cordoning, `hostbootstrap` checks that the host actually has the requested budget spare. If
the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line diagnostic naming
the shortfall and exits non-zero rather than over-committing the host.

## Cordoning per Substrate

The budget is enforced — cordoned — so a project's workload cannot exceed its declared share.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | A dedicated per-project Colima VM sized to `cpu` / `memory` / `storage`. The VM boundary is the cordon: the project's Docker workload runs inside its own sized VM, isolated from the host and from other projects' VMs. |
| `linux-cpu` / `linux-gpu` | kind node resource limits applied to the project's cluster nodes, capping the cluster's consumption to the declared budget. |

On Apple the cordon is created during the Python bootstrap sequence (the per-project Colima VM must
exist before the build); on Linux it is applied as part of cluster bring-up. The cluster-side
enforcement is part of the lifecycle semantics in [cluster_lifecycle](cluster_lifecycle.md).
