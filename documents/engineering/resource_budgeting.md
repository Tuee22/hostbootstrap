# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [applied_cordon](applied_cordon.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define the per-project resource budget read from the project-local `<project>.dhall`,
> projected into child configs, and enforced as a ceiling cordoned per substrate.

## TL;DR

- The host-level `<project>.dhall` `resources` field is the one ceiling: one declared `cpu` / `memory` /
  `storage` number per project, used **once**. Child configs receive a generated resource envelope or slice.
- The declared budget **is the VM wall**: the VM (cordon #1) is sized to the budget, and the in-VM cluster
  (cordon #2) is a **slice within it** that fits alongside the VM OS, Docker, and image builds. The budget
  is never added to itself — there is no budget-sized VM "headroom" that sizes the VM above the ceiling
  (that double-counts the one requirement; see
  [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)).
- A test config may override the budget (e.g. smaller resources); `test run` projects the override into the
  test `<project>.dhall` it writes, then drives the same sizing path as deploy.
- The project binary verifies the active context has the spare budget available before proceeding, then
  applies the cordon — a dedicated VM (Lima for the Apple pristine demo, Incus on Linux, WSL2 on
  Windows, Colima for direct Apple Docker workloads), a kind-node cap, or a container cap.
- The ceiling is enforced by three rings (compile, bring-up, runtime). The applied detail lives in
  [applied_cordon](applied_cordon.md).
- Downstream binaries do not read the host config directly; they consume the budget projection in their
  own sibling `<project>.dhall`.

## Current Status

Target (reopened, documentation-only): under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the resource
budget / VM cordon is a PROVIDER concern carried by a project's own `cfg`, not a core-universal field. A
secrets-strict, RKE2/EKS-sized consumer that deploys to an existing cluster carries no VM budget at all,
so § O's "one ceiling = the VM wall" rule applies only to projects whose `cfg` declares a VM budget. See
the [generic_project_model.md](../architecture/generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

Concretely, the core default budget `4/8/20` cannot bootstrap the demo — the demo's `deploy-VM` gate
requires `6/10/80` (`demoFullLifecycleResources`) — so under phase-19 the default moves into the
project-owned `psInit` and the demo's `psInit` returns its real budget. See
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md).

## The Budget Field

The resource budget is a `resources` record in the host-level project config described in
[schema](schema.md):

```dhall
{ project   = "app"
, resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
```

The `4/8/20` above is an **illustrative shape**, not a default: core ships no default budget. The demo's
own `psInit` default is `6/10/80` (its `deploy-VM` gate, `demoFullLifecycleResources`, requires it), and
each project's `psInit` supplies its own budget. See the [Current Status](#current-status) note and
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md).

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
capacity **per substrate**, so the preflight is a real gate on every supported host:

| Substrate | CPU cores | Memory | Storage |
|-----------|-----------|--------|---------|
| `apple-silicon` | `sysctl -n hw.ncpu` (logical cores) | `sysctl -n hw.memsize` (total physical RAM) | reported generously |
| `linux-cpu` / `linux-gpu` | `/proc/cpuinfo` processor count | `/proc/meminfo` `MemAvailable` | reported generously |

Storage is reported generously because the applied storage cordon (Lima/Colima `--disk`, incus `root,size`,
a quota'd hostPath) is the real storage wall, not the preflight. On Apple, `sysctl` is invoked through
the resolved `HostTool Sysctl`, preserving the host-tool absolute-path rule. The preflight runs inside
`clusterCreate` before any substrate is touched. See [applied_cordon](applied_cordon.md) for the bring-up
ring and [cluster_lifecycle](cluster_lifecycle.md) for where it runs.

## Cordoning per Substrate

The budget is enforced — cordoned — so a project's workload cannot exceed its declared share. The cordon
is applied by the project binary in the context where the workload is about to run, not by the Python
bootstrapper.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | For the pristine demo environment, a dedicated Lima VM sized to `cpu` / `memory` / `storage`. For direct Apple Docker workloads, the Colima VM is the Docker-provider cordon. In both cases the VM boundary is the cordon, applied by the project binary, not by the Python bootstrapper. |
| `linux-cpu` / `linux-gpu` | A kind-node cap applied during cluster bring-up: `docker update --cpus --memory --memory-swap` on the control-plane container, capping the cluster's consumption to the declared budget. |
| `windows-cpu` / `windows-gpu` | A dedicated WSL2 `Ubuntu-24.04` distro sized to `cpu` / `memory` / `storage` via the provider (the `wsl` CLI `--memory` / `--cpu` plus `.wslconfig`); the VM boundary is the cordon, applied by the project binary, not by the Python bootstrapper. Storage is cordoned at that VM boundary via the distro's vhdx. *(Target.)* |

On Apple the pristine demo cordon is the Lima VM, while direct Docker workflows may use the per-project
Colima VM; on Linux it is the kind-node cap applied during cluster bring-up, after `kind create` and
before Helm, fail-closed. Storage is cordoned per substrate (Lima/Colima `--disk` on Apple, an incus `root,size` for an
incus VM, a quota'd hostPath plus image GC on bare Linux). The cluster-side enforcement is part of the
lifecycle semantics in [cluster_lifecycle](cluster_lifecycle.md); the full applied detail — the argv,
the storage drop from the `docker update` flags, and the self-limiting `--memory-swap == --memory` — is
in [applied_cordon](applied_cordon.md).
