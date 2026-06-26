# Applied Cordon

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [resource budgeting](resource_budgeting.md), [cluster lifecycle](cluster_lifecycle.md), [development plan](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Describe how the one declared resource budget becomes an enforced ceiling — one canonical quantity parser, three rings of defense (compile, bring-up, runtime), and a per-substrate storage cordon.

## TL;DR

- The host-level `<project>.dhall` `resources` budget is a hard ceiling, not advice. One declared number
  is read once per invocation and interpreted identically everywhere.
- One canonical parser, `parseQuantity` in `HostBootstrap.Cluster.Cordon`, decodes every quantity; one
  arg-builder family emits the complete argv for every substrate.
- The ceiling is held by three rings of defense in depth: the compile ring (a Dhall `assert`), the
  bring-up ring (the pure `verifyBudget` / `fitsBudget` preflight), and the runtime ring (the applied
  VM and kind-node caps).
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
`limaSizingArgs`, `kindNodeCordonArgs`, `incusSizingArgs`) emits the complete argv for every substrate.
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
  (`budgetFromResources`) and then runs `verifyBudget` (budget versus resolved spare host capacity),
  failing fast with a one-line diagnostic naming the first dimension that exceeds spare capacity.
- `fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()` proves the concurrent pod
  set fits the budget.

`resolveHostCapacity cfg` resolves spare capacity **per substrate**: on `apple-silicon` it reads
`hw.ncpu` and `hw.memsize` via the resolved `HostTool Sysctl`; on `linux-cpu` / `linux-gpu` it reads the
`/proc/cpuinfo` processor count and `/proc/meminfo` `MemAvailable`. Storage is reported generously (the
applied storage cordon is the real wall). The IO surface in `clusterCreate` resolves capacity and runs
`preflightBudget` as a fail-fast preflight; the pure source mapping and live Apple `sysctl` read are
unit-tested. See [cluster lifecycle](cluster_lifecycle.md).

### Runtime Ring

The runtime ring is the cap actually applied to the live substrate.

On Linux, `kindNodeCordonArgs clusterName resources` emits
`docker update --cpus N --memory <bytes> --memory-swap <bytes> <clusterName>-control-plane`.
`HostBootstrap.Cluster.Lifecycle`'s `applyLinuxCordon` applies it fail-closed AFTER `kind create` (and
the kubeconfig export) and BEFORE Helm. `--memory-swap == --memory`, so an over-budget cluster
self-limits instead of swapping past its ceiling. `<clusterName>` is the resolved `ClusterPlan` name, so
a test cluster (the harness's `project up` under the Test profile) is cordoned the same way — to its slice
within the VM wall.

On Apple, a Lima VM sized by `limaSizingArgs` is the cordon; the per-project Colima VM sized by
`colimaSizingArgs` is the cordon for direct Docker workflows. In both cases the VM boundary is the first
cordon, so there is no host-side kind-node cap outside the VM.

## Per-Substrate Storage Cordon

Storage carries no `docker update` flag, so it is dropped from the `kindNodeCordonArgs` argv. It is
kept in `verifyBudget`, so the bring-up ring still checks the declared storage against spare capacity.
Each substrate cordons storage where it can:

| Substrate | Storage cordon |
|-----------|----------------|
| Apple | Lima or Colima `--disk` (the VM's sized disk) |
| incus VM | `root,size` on the incus instance |
| WSL2 VM | The distro's vhdx at the VM wall, sized with `.wslconfig` plus the `wsl` CLI `--memory` / `--cpu`, all drawn from the one `parseQuantity` *(Target.)* |
| Bare Linux | A quota'd hostPath plus image garbage collection |

On Linux, `incusSizingArgs resources` emits the `limits.cpu`, `limits.memory`, and `root,size` config
arguments the VM-up step applies to the incus instance, so the incus VM wall cordons storage at the VM
boundary.

## Current Status

The per-substrate `resolveHostCapacity` described in the bring-up ring reads CPU and memory from the
substrate-specific sources. The one canonical parser, all three rings, and the per-substrate storage
cordon are implemented and validated. The development plan for this surface is
[phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md).

## See Also

- [resource budgeting](resource_budgeting.md) — the budget field and the verify-spare step.
- [cluster lifecycle](cluster_lifecycle.md) — where the runtime ring is applied.
- [schema](schema.md) — the project-local `resources` record.
- [phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md) — the development plan for
  this surface.
