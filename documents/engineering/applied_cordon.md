# Applied Cordon

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [resource budgeting](resource_budgeting.md), [cluster lifecycle](cluster_lifecycle.md), [wsl2](wsl2.md), [development plan](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Describe how the one declared resource budget becomes an enforced ceiling — one canonical quantity parser, three rings of defense (compile, bring-up, runtime), and a per-substrate storage cordon.

## TL;DR

- The host-level `<project>.dhall` `resources` budget is a hard ceiling, not advice. One declared number
  is read once per invocation and interpreted identically everywhere.
- One canonical parser, `parseQuantity` in `HostBootstrap.Cluster.Cordon`, decodes every quantity; one
  arg-builder family emits the complete argv for every substrate.
- The ceiling is held by three rings of defense in depth: the compile ring (a Dhall `assert`), the
  bring-up ring (the pure `verifyBudget` / `fitsBudget` preflight), and the runtime ring (the applied
  VM and kind-node caps).
- Multi-node clusters consume the cluster envelope once. Lifecycle splits it across the declared node
  list and caps every node; the explicit `nvkind` topology is one control-plane plus one GPU worker.
- Storage is cordoned per substrate and carries no `docker update` flag, so it is omitted from the
  kind-node argv while remaining in `verifyBudget`.

## One Canonical Quantity Parser

`parseQuantity` is the single quantity grammar in `HostBootstrap.Cluster.Cordon`. It accepts binary
suffixes (`Ki`, `Mi`, `Gi`, `Ti`, each optionally followed by `B`) and decimal suffixes (`K`, `M`,
`G`, `T`); a bare number is bytes. It decodes the bare `"8Gi"` form correctly. Because every argument
builder calls `parseQuantity`, the one declared budget number is interpreted identically at every
spinup and in every generated config.

The Python bootstrapper builds no sizing argv. `colimaSizingArgs project resources` emits the complete
`colima start --profile <project> --cpu N --memory <GiB> --disk <GiB>` argv. Haskell owns the complete
argv; the Python bootstrapper does not size VMs. See
[build and run model](../architecture/build_and_run_model.md) for where the project binary owns sizing,
and [resource budgeting](resource_budgeting.md) for the budget field itself.

### Why One Parser

One canonical `parseQuantity` decodes every quantity, and one arg-builder family (`colimaSizingArgs`,
`limaSizingArgs`, `kindNodeCordonArgsFor`, `incusSizingArgs`, `wsl2SizingArgs`) emits the complete sizing
for every substrate (an argv for the VM/node providers; the `.wslconfig` `[wsl2]` body for WSL2).
`HostBootstrap.Cluster.Lifecycle.clusterNodeCordonArgs` composes the node builder over the concrete node
list after splitting the one cluster envelope.
The Python bootstrapper builds no sizing argv. Because every interpreter is the same parser, the VM
sizing and the Haskell-verified budget agree, and the one declared number is the one enforced ceiling.

## The Three Rings

The single ceiling is held by three independent rings, so no one mechanism is the only line of
defense.

| Ring | Mechanism | Where |
|------|-----------|-------|
| Compile | A Dhall-time `assert : C.fitsWithin budget pods === True` (from `Core.dhall`) | Generated deploy config |
| Bring-up | The pure `verifyBudget` and `fitsBudget` preflight | `clusterCreate`, before any spinup |
| Runtime | The applied VM / kind-node caps | The live substrate |

### Compile Ring

The generated deploy config carries a Dhall-time `assert : C.fitsWithin budget pods === True` (from
`Core.dhall`). An over-budget config fails to type-check, so a config that does not fit its own budget
never renders. See [dhall generation](../architecture/dhall_generation.md).

### Bring-up Ring

Two pure functions gate bring-up before any substrate is touched:

- `preflightBudget resources hostCapacity` is the pure preflight: it derives the budget
  (`budgetFromResources`) and then runs `verifyBudget` (budget versus resolved host capacity),
  failing fast with a one-line diagnostic naming the first dimension that exceeds capacity.
- `fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()` proves the concurrent pod
  set fits the budget.

`resolveHostCapacity cfg` resolves host capacity **per substrate** through the pure
`capacityReadPlan substrate` source mapping:

| Substrate | CPU source | Memory source | Storage source |
|-----------|-----------|---------------|----------------|
| `apple-silicon` | `sysctl hw.ncpu` | `sysctl hw.memsize` (**total**) | generous |
| `linux-cpu` / `linux-gpu` | `/proc/cpuinfo` | `/proc/meminfo` `MemAvailable` | generous |
| `windows-cpu` / `windows-gpu` | CIM `Win32_ComputerSystem.NumberOfLogicalProcessors` | CIM `Win32_ComputerSystem.TotalPhysicalMemory` (**total**) | system-drive free space |

Two substrates read **total** physical memory (Apple `hw.memsize`, Windows `TotalPhysicalMemory`) rather
than momentary free/available memory: total is a stable property of the machine, so the preflight is a
fact about whether the host *can* host a budget-sized VM, not a volatile point-in-time reading. This
matters most on Windows/WSL2, where there is no per-distro hard memory cap (see the runtime ring): a
host whose *total* RAM cannot fit the budget fails fast at this ring rather than passing on transient
post-reboot free RAM and dying inside the build. **This ring now checks `budget + ~4 GiB host-OS reserve ≤ total`**
via the metal host preflight (`preflightHostBudget` / `verifyHostBudget`), so a budget that fits under total
RAM but leaves the host short (e.g. 10 GiB on 16 GiB) fails fast at this ring rather than passing. The in-VM
cluster-slice preflight (`preflightBudget` / `verifyBudget`) is reserve-free — the slice is already the
reserved subset, so there is no double-count. This host-headroom split is real-run-validated 2026-07-05 by the
Windows/WSL2 `test run all` (`6/6`). Linux keeps `MemAvailable` (its applied incus cordon is
a hard per-VM wall, so the preflight need only be advisory). Storage is reported generously on Apple and
Linux (their applied VM cordons own the real wall) but read as real system-drive free space on Windows,
so WSL2 does not begin a large VHDX-backed build on a disk that cannot satisfy the declared storage
budget. The IO surface in `clusterCreate` resolves capacity and runs `preflightBudget` as a fail-fast
preflight; the pure source mapping and live Apple `sysctl` read are unit-tested. See
[cluster lifecycle](cluster_lifecycle.md).

### Runtime Ring

The runtime ring is the cap actually applied to the live substrate.

On Linux, `ClusterPlan` owns the explicit node suffixes. A kind plan has `control-plane`; the demo's
`NvkindDriver` plan has `control-plane` and `worker`, matching `nvkind-in-cluster.yaml`. Lifecycle's
`clusterNodeCordonArgs` parses the one cluster envelope, divides CPU, memory bytes, and storage bytes by
the node count with integer floors, and refuses the plan if any dimension is smaller than that count.
Flooring guarantees the combined node shares never exceed the declared slice; giving both nvkind nodes
the full slice would double-count it.

For each concrete name, `kindNodeCordonArgsFor` emits
`docker update --cpus N --memory <bytes> --memory-swap <bytes> <node>`. `applyLinuxCordon` runs every argv
fail-closed after kind/nvkind create (and kubeconfig export) and before workload deployment.
`--memory-swap == --memory`, so no node can swap past its share. Storage is included in the split and
positive-share gate but omitted from `docker update`, which has no storage flag. The resolved
`ClusterPlan` profile supplies the names, so the harness's Test cluster is split and capped by the same
path as Production.

On Apple, a Lima VM sized by `limaSizingArgs` is the cordon — the substrate lift sizes the Lima VM to
the budget, so the VM boundary, not a host-side kind-node cap, is the first cordon. The parallel
`colimaSizingArgs` builder emits a profiled `colima start` argv for direct Docker workflows but is not
yet wired: the Colima reconciler currently starts an unsized `colima start`, so no code path sizes a Colima VM
from the budget today.

On Windows, the WSL2 wall is **honest about what WSL2 can enforce**. Unlike incus `limits.memory` and
Lima `--memory`, WSL2 has no per-distro memory/CPU cap — the only lever is the *global*, per-user
`%UserProfile%\.wslconfig` `[wsl2]` block that sizes the single shared utility VM hosting every distro.
So `wsl2SizingArgs` emits that `[wsl2]` body (`processors` / `memory` / `swap`, all from the one
`parseQuantity`; `swap` is sized to the memory budget for OOM headroom), and the WSL2 launch is a
*list* of effects: write `.wslconfig` (backing up any existing file), `wsl --shutdown` to apply it, then
register the distro. The body also carries `[wsl2] vmIdleTimeout=-1` plus `[general] instanceIdleTimeout=-1` —
the latter keeps the distro *instance* (not just the shared utility VM) alive after `project up` returns, so
the in-VM kind cluster does not idle-stop; `mergeWslConfig` manages both sections. Because the file is global,
teardown restores the backed-up `.wslconfig`. This is a
weaker guarantee than a hard per-VM cap and the launch is a two-step write-then-shutdown rather than a
single sized argv — the unified `spLaunch` effect list (one pure lift per substrate) models exactly that
difference. See [wsl2](wsl2.md) for the provider detail.

## Per-Substrate Storage Cordon

Storage carries no `docker update` flag, so it is dropped from each `kindNodeCordonArgsFor` argv. It is
kept in `verifyBudget` and in the multi-node split/minimum-share check, so the bring-up ring still checks
the declared storage against the resolved capacity.
Each substrate cordons storage where it can:

| Substrate | Storage cordon |
|-----------|----------------|
| Apple | Lima or Colima `--disk` (the VM's sized disk) |
| incus VM | `root,size` on the incus instance |
| WSL2 VM | The distro's VHDX, capped per-distro at install via `wsl --install --vhd-size` (from the one `parseQuantity`). Memory/CPU are **not** per-distro on WSL2 — they are the global `.wslconfig` `[wsl2]` utility-VM ceiling (see the runtime ring), not a `wsl --memory`/`--cpu` flag |
| Bare Linux | A quota'd hostPath plus image garbage collection |

On Linux, `incusSizingArgs resources` emits the `limits.cpu`, `limits.memory`, and `root,size` config
arguments the VM-up step applies to the incus instance, so the incus VM wall cordons storage at the VM
boundary.

## Current Status

The per-substrate `resolveHostCapacity` described in the bring-up ring reads CPU and memory from the
substrate-specific sources. The one canonical parser, all three rings, and the per-substrate storage
cordon are implemented and validated on Apple/Lima and Linux/Incus. The Windows/WSL2 honest cordon — the
total-memory preflight predicate and the applied global `.wslconfig` ceiling written and shut down at
launch — is implemented, unit-tested, and real-run-closed by
[phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) (Sprint 11.7): a full `project up` →
`test run all` (`6/6`) → `project destroy` Windows lifecycle, closed 2026-07-01. The development plan
for the pure parser/builder surface and the capacity predicate is
[phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md).

The later explicit nvkind control-plane/worker topology and all-node envelope split are unit-validated
in the current static baseline (357 core tests and 83 demo tests). That evidence does not replace the
Phase-5 real-host gate: Phase 5.5 remains Active until pristine and warm Linux CPU/GPU runs prove the
caps are applied to the live node containers.

## See Also

- [resource budgeting](resource_budgeting.md) — the budget field and the verify-spare step.
- [cluster lifecycle](cluster_lifecycle.md) — where the runtime ring is applied.
- [schema](schema.md) — the project-local `resources` record.
- [phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md) — the development plan for
  this surface.
