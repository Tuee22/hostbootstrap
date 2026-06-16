# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [applied_cordon](applied_cordon.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define the per-project resource budget read from the project-local `<project>.dhall`,
> projected into child configs, and enforced as a ceiling cordoned per substrate.

## TL;DR

- The host-level `<project>.dhall` `resources` field is the one ceiling: one declared `cpu` / `memory` /
  `storage` number per project. Child configs receive a generated resource envelope or slice.
- The project binary verifies the active context has the spare budget available before proceeding, then
  applies the cordon — a dedicated VM (Lima for the Apple pristine demo, Incus on Linux, Colima for
  direct Apple Docker workloads), a kind-node cap, or a container cap.
- The ceiling is enforced by three rings (compile, bring-up, runtime). The applied detail lives in
  [applied_cordon](applied_cordon.md).
- Downstream binaries do not read the host config directly; they consume the budget projection in their
  own sibling `<project>.dhall`.

## The Budget Field

The resource budget is a `resources` record in the host-level project config described in
[schema](schema.md):

```dhall
{ project   = "app"
, resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
```

- `cpu` — whole cores reserved for the project's substrate.
- `memory` — memory ceiling for the project's substrate.
- `storage` — disk budget for the project's substrate (image layers, cluster data, build outputs).

The project binary reads this field from its active config, validates it, and passes the appropriate
envelope to nested configs before crossing a VM, container, daemon, or cluster-service boundary. The
Python bootstrapper does not read this field and does not size the Lima/Incus/Colima VM — it builds no sizing
argv at all. See
[python_haskell_boundary](../architecture/python_haskell_boundary.md) and
[binary_context_config](../architecture/binary_context_config.md).

## The One Ceiling

The declared `resources` number is a hard ceiling, not advice. One canonical quantity parser
(`parseQuantity` in `HostBootstrap.Cluster.Cordon`) decodes the declared quantities, so the one number
means the same thing at every spinup and in every generated config. A project's workload cannot exceed
its declared share because the ceiling is held by three independent rings of defense:

- **Compile ring** — the generated deploy config carries a Dhall-time `assert` that the budget fits the
  pods, so an over-budget config fails to type-check.
- **Bring-up ring** — the pure `verifyBudget` runs as a fail-fast preflight (budget versus resolved
  spare host capacity), and `fitsBudget` proves the concurrent pod set fits before bring-up.
- **Runtime ring** — the applied VM / kind-node / `docker run` caps on the live substrate.

The applied mechanics of all three rings, the canonical parser, and the per-substrate storage cordon
are documented in [applied_cordon](applied_cordon.md).

## Verify-Spare-Resources

Before cordoning, the project binary checks that the active context's declared envelope can be satisfied
locally. If the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line diagnostic
naming the shortfall and exits non-zero rather than over-committing the host.

`verifyBudget` is the pure core of this check; `preflightBudget resources hostCapacity` derives the
budget and runs `verifyBudget` against resolved spare host capacity. `resolveHostCapacity` resolves
capacity **per substrate**, so the preflight is a real gate on every supported host rather than a no-op
off Linux:

| Substrate | CPU cores | Memory | Storage |
|-----------|-----------|--------|---------|
| `apple-silicon` | `sysctl -n hw.ncpu` (logical cores) | `sysctl -n hw.memsize` (total physical RAM) | reported generously |
| `linux-cpu` / `linux-gpu` | `/proc/cpuinfo` processor count | `/proc/meminfo` `MemAvailable` | reported generously |

Storage is reported generously because the applied storage cordon (Lima/Colima `--disk`, incus `root,size`,
a quota'd hostPath) is the real storage wall, not the preflight. On Apple, `sysctl` is invoked through
the resolved `HostTool Sysctl`, preserving the host-tool absolute-path rule. The preflight runs inside
`clusterUp` before any substrate is touched. See [applied_cordon](applied_cordon.md) for the bring-up ring and
[cluster_lifecycle](cluster_lifecycle.md) for where it runs.

## Current Status

The substrate-aware spare-capacity resolution above is implemented and validated in
[phase 9, sprint 9.5](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md). The retired
off-Linux fallbacks are recorded in
[legacy-tracking-for-deletion](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). Every ring in
this document is implemented and validated.

## Cordoning per Substrate

The budget is enforced — cordoned — so a project's workload cannot exceed its declared share. The cordon
is applied by the project binary in the context where the workload is about to run, not by the Python
bootstrapper.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | For the pristine demo environment, a dedicated Lima VM sized to `cpu` / `memory` / `storage`. For direct Apple Docker workloads, the Colima VM remains the Docker-provider cordon. In both cases the VM boundary is the cordon, applied by the project binary, not by the Python bootstrapper. |
| `linux-cpu` / `linux-gpu` | A kind-node cap applied during cluster bring-up: `docker update --cpus --memory --memory-swap` on the control-plane container, capping the cluster's consumption to the declared budget. |

On Apple the pristine demo cordon is the Lima VM, while direct Docker workflows may use the per-project
Colima VM; on Linux it is the kind-node cap applied during cluster bring-up, after `kind create` and
before Helm, fail-closed. Storage is cordoned per substrate (Lima/Colima `--disk` on Apple, an incus `root,size` for an
incus VM, a quota'd hostPath plus image GC on bare Linux). The cluster-side enforcement is part of the
lifecycle semantics in [cluster_lifecycle](cluster_lifecycle.md); the full applied detail — the argv,
the storage drop from the `docker update` flags, and the self-limiting `--memory-swap == --memory` — is
in [applied_cordon](applied_cordon.md).
