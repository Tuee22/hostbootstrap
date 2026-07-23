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
  [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)). On Incus and
  Lima the wall is a hard per-VM cap; on **WSL2 the memory/CPU wall is the global `.wslconfig` utility-VM
  ceiling** (WSL2 has no per-distro cap), with storage a per-distro VHDX cap — see
  [wsl2](wsl2.md) and [applied_cordon](applied_cordon.md).
- A test config may override the budget (e.g. smaller resources); `test run` projects the override into the
  test `<project>.dhall` it writes, then drives the same sizing path as deploy.
- The project binary verifies the active context has the spare budget available before proceeding, then
  applies the cordon — a dedicated VM (Lima for the Apple pristine demo, Incus on the Linux CPU lane,
  WSL2 on Windows, Colima for direct Apple Docker workloads), a kind/nvkind-node cap, or a container cap.
- A cluster with multiple node containers receives the cluster envelope **once**: lifecycle splits CPU,
  memory, and storage evenly (flooring each share) and applies the CPU/memory cap to every node. The
  `nvkind` direct GPU topology is one control-plane plus one GPU worker, so neither node receives the
  full envelope.
- The ceiling is enforced by three rings (compile, bring-up, runtime). The applied detail lives in
  [applied_cordon](applied_cordon.md).
- Downstream binaries do not read the host config directly; they consume the budget projection in their
  own sibling `<project>.dhall`.

## Current Status

Under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the resource
budget / VM cordon is a PROVIDER concern carried by a project's own `cfg`, not a core-universal field. A
secrets-strict, RKE2/EKS-sized consumer that deploys to an existing cluster carries no VM budget at all,
so § O's "one ceiling = the VM wall" rule applies only to projects whose `cfg` declares a VM budget. See
the [generic_project_model.md](../architecture/generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

Concretely, the former core default budget `4/8/20` (now only a test fixture) could not bootstrap the
demo — the demo's `deploy-VM` gate requires `6/10/80` (`demoFullLifecycleResources`) — so under phase-19
the default lives in the project-owned `psInit` and the demo's `psInit` returns its real budget. See
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md).

The Phase-5 Linux GPU work extends the runtime ring without changing this model. A normal kind plan
declares one `control-plane` node; the explicit `nvkind` plan declares `control-plane` and `worker`.
`clusterNodeCordonArgs` divides the one cluster slice across the declared node list and refuses a slice
whose CPU, memory, or storage cannot give every node a positive share. The split planner is covered by
the current static baseline (364 core tests and 87 demo tests); Phase 5.5 remains Active until the native
Linux CPU and native Linux GPU `8/8` gates validate the applied caps.

## The Budget Field

The resource budget is a `resources` record in the host-level project config described in
[schema](schema.md):

```dhall
{ resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
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
  host capacity — total RAM on Apple/Windows, `MemAvailable` on Linux); it is reserve-free because it
  gates the in-VM cluster slice, which is already the reserved subset, while the METAL host preflight
  (`preflightHostBudget`/`verifyHostBudget`) applies the ~4 GiB host-OS reserve, and `fitsBudget` proves
  the concurrent pod set fits before bring-up.
- **Runtime ring** — the applied VM / kind-node / `docker run` caps on the live substrate.

The applied mechanics of all three rings, the canonical parser, and the per-substrate storage cordon
are documented in [applied_cordon](applied_cordon.md).

## Verify-Spare-Resources

Before cordoning, the project binary checks that the active context's declared envelope can be satisfied
locally. If the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line diagnostic
naming the shortfall and exits non-zero. **The METAL host preflight now gates on `host RAM ≥ budget +
reserve` (a ~4 GiB host-OS reserve)**, so a budget that fits under *total* host RAM but would leave the host
itself short (e.g. a 10 GiB budget on a 16 GiB host) is refused by `preflightHostBudget`/`verifyHostBudget`;
the in-VM cluster-slice preflight (`preflightBudget`/`verifyBudget`) stays reserve-free because the slice is
already the reserved subset, so the reserve is never double-counted. This split is real-run-validated
2026-07-05 by the decoupled Windows/WSL2 `test run all` reporting `test report: 6/6 passed`.

`verifyBudget` is the pure core of this check; `preflightBudget resources hostCapacity` derives the
budget and runs `verifyBudget` against resolved host capacity (total physical RAM on Apple/Windows,
`MemAvailable` on Linux). `resolveHostCapacity` resolves
capacity **per substrate**, so the preflight is a real gate on every supported host:

| Substrate | CPU cores | Memory | Storage |
|-----------|-----------|--------|---------|
| `apple-silicon` | `sysctl -n hw.ncpu` (logical cores) | `sysctl -n hw.memsize` (total physical RAM) | reported generously |
| `linux-cpu` / `linux-gpu` | `/proc/cpuinfo` processor count | `/proc/meminfo` `MemAvailable` | reported generously |
| `windows-cpu` / `windows-gpu` | CIM `Win32_ComputerSystem.NumberOfLogicalProcessors` | CIM `Win32_ComputerSystem.TotalPhysicalMemory` (total physical RAM) | system-drive free space |

Memory is read as **total** physical RAM on Apple and Windows (a stable property of the machine) and as
`MemAvailable` on Linux. Storage is reported generously on Apple and Linux because their applied storage
cordon (Lima/Colima `--disk`, incus `root,size`) is the real wall, but is read as real **system-drive
free space** on Windows so a WSL2 run does not begin a large VHDX-backed build on a disk that cannot hold
the declared storage budget. The Windows total-memory predicate matters because WSL2 has no per-distro
memory cap (see Cordoning per Substrate): the preflight must fail fast on a too-small host rather than
pass on transient free RAM. On Apple, `sysctl` is invoked through the resolved `HostTool Sysctl`,
preserving the host-tool absolute-path rule. The preflight runs inside `clusterCreate` before any
substrate is touched. See [applied_cordon](applied_cordon.md) for the bring-up ring and
[cluster_lifecycle](cluster_lifecycle.md) for where it runs.

As a **target** (reopened as phase-9 Sprint 9.9), the lifecycle resource floor becomes a
smart-constructor invariant — a below-floor `Resources` is *unrepresentable* rather than a runtime
reject — and `memory` / `storage` become a typed `Quantity` rejected at Dhall decode rather than a
parsed `Text`; the runtime preflight above is today's mechanism, not a type-level guarantee. See
[applied_cordon](applied_cordon.md) and
[development_plan_standards.md § O](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Cordoning per Substrate

The budget is enforced — cordoned — so a project's workload cannot exceed its declared share. The cordon
is applied by the project binary in the context where the workload is about to run, not by the Python
bootstrapper.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | For the pristine demo environment, a dedicated Lima VM sized to `cpu` / `memory` / `storage`. For direct Apple Docker workloads, the Colima VM is the Docker-provider cordon. In both cases the VM boundary is the cordon, applied by the project binary, not by the Python bootstrapper. |
| `linux-cpu` / `linux-gpu` | A kind/nvkind node cap applied during cluster bring-up. The one cluster envelope is split evenly across the plan's declared nodes (`control-plane` for kind; `control-plane` + GPU `worker` for the demo's nvkind topology), flooring each share so the sum cannot exceed the envelope. `docker update --cpus --memory --memory-swap` is then applied fail-closed to every node. |
| `windows-cpu` / `windows-gpu` | A project-owned WSL2 `Ubuntu-24.04` distro, cordoned by the project binary. WSL2 has **no** per-distro memory/CPU cap, so memory/CPU are the **global** `%UserProfile%\.wslconfig` `[wsl2]` ceiling (`processors` / `memory` / `swap`, written and applied with `wsl --shutdown` at launch, backed up and restored on teardown) that sizes the shared utility VM; storage is a per-distro VHDX cap applied at registration via `wsl --install --vhd-size`. There is no `wsl --memory`/`--cpu` flag. See [wsl2](wsl2.md). |

On Apple the pristine demo cordon is the Lima VM, while direct Docker workflows may use the per-project
Colima VM; on Linux the cluster-side cordon is applied after kind/nvkind create and before workload
deployment, fail-closed. The lifecycle derives the concrete node names from `ClusterPlan`, splits the
slice across them, and applies every generated `docker update` argv. Storage participates in the split
and minimum-share check but has no `docker update` flag; it is cordoned per substrate (Lima/Colima
`--disk` on Apple, an incus `root,size` for an incus VM, a quota'd hostPath plus image GC on bare Linux).
The cluster-side enforcement is part of the lifecycle semantics in
[cluster_lifecycle](cluster_lifecycle.md); the full applied detail — the argv, the storage drop from the
runtime flags, and the self-limiting `--memory-swap == --memory` — is in
[applied_cordon](applied_cordon.md).
