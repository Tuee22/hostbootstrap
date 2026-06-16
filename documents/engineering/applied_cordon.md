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
  VM / kind-node / `docker run` caps).
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

- **WRONG**: the Python layer keeps its own quantity helper and builds the `colima` argv itself. This is
  wrong because two interpreters of one number can diverge, so the VM sizing and the Haskell-verified
  budget may disagree and the declared ceiling may not be the enforced ceiling.
- **RIGHT**: one canonical `parseQuantity` decodes every quantity, and one arg-builder family
  (`colimaSizingArgs`, `kindNodeCordonArgs`) emits the complete argv. The Python bootstrapper builds no
  sizing argv. The one declared number is the one enforced ceiling.

## The Three Rings

The single ceiling is held by three independent rings, so no one mechanism is the only line of
defense.

| Ring | Mechanism | Where |
|------|-----------|-------|
| Compile | A Dhall-time `assert : C.fitsWithin budget pods === True` (from `Core.dhall`) | Generated deploy config |
| Bring-up | The pure `verifyBudget` and `fitsBudget` preflight | `clusterUp`, before any spinup |
| Runtime | The applied VM / kind-node / `docker run` caps | The live substrate |

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
applied storage cordon is the real wall). The IO surface in `clusterUp` resolves capacity and runs
`preflightBudget` as a fail-fast preflight; the pure source mapping and live Apple `sysctl` read are
unit-tested. See [cluster lifecycle](cluster_lifecycle.md).

### Runtime Ring

The runtime ring is the cap actually applied to the live substrate.

On Linux, `kindNodeCordonArgs clusterName resources` emits
`docker update --cpus N --memory <bytes> --memory-swap <bytes> <clusterName>-control-plane`. It is
applied in `HostBootstrap.Cluster.Lifecycle`'s `clusterUp` AFTER `kind create` and BEFORE Helm,
fail-closed. `--memory-swap == --memory`, so an over-budget cluster self-limits instead of swapping
past its ceiling. `<clusterName>` is the resolved `ClusterPlan` name, so each per-case test cluster is
cordoned too.

On Apple, the pristine demo uses a Lima VM sized by `limaSizingArgs`; direct Docker workflows may use the
per-project Colima VM sized by `colimaSizingArgs`. In both cases the VM boundary is the first cordon, so
there is no host-side kind-node cap outside the VM.

## Per-Substrate Storage Cordon

Storage carries no `docker update` flag, so it is dropped from the `kindNodeCordonArgs` argv. It is
kept in `verifyBudget`, so the bring-up ring still checks the declared storage against spare capacity.
Each substrate cordons storage where it can:

| Substrate | Storage cordon |
|-----------|----------------|
| Apple | Lima or Colima `--disk` (the VM's sized disk) |
| incus VM | `root,size` on the incus instance (the incus builder is Phase 11) |
| Bare Linux | A quota'd hostPath plus image garbage collection |

The incus builder is a later phase and is named here in prose only.

## Current Status

The per-substrate `resolveHostCapacity` described in the bring-up ring is implemented and validated in
[phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md) (sprint 9.5). The retired
off-Linux fallbacks are recorded in
[legacy-tracking-for-deletion](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). The one canonical
parser, all three rings, and the per-substrate storage cordon are implemented and validated.

## See Also

- [resource budgeting](resource_budgeting.md) — the budget field and the verify-spare step.
- [cluster lifecycle](cluster_lifecycle.md) — where the runtime ring is applied.
- [schema](schema.md) — the project-local `resources` record.
- [phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md) — the development plan for
  this surface.
