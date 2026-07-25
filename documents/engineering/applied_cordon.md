# Applied Cordon

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [resource budgeting](resource_budgeting.md), [cluster lifecycle](cluster_lifecycle.md), [wsl2](wsl2.md), [development plan](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Describe the applied resource controls, including the current bare-Linux storage gap,
> and the target in which every declared dimension is an enforced ceiling.

## TL;DR

- The host-level `<project>.dhall` `resources` value is intended to be a hard ceiling. Current
  CPU/memory application is partial: VM limits are creation-time, direct Linux GPU outer effects and
  direct Colima are uncapped, and bare-Linux storage is only preflighted.
- One canonical parser, `parseQuantity` in `HostBootstrap.Cluster.Cordon`, decodes every quantity; one
  builder family produces each provider's sizing representation (argv where applicable and the
  `.wslconfig` body for WSL2).
- The top-level demo decode ring uses typed `Quantity`, resource-floor, replica, port, and timeout
  refinements, but constructors remain public and lifecycle consumes a separate raw context envelope.
  The current capacity ring checks host/cluster capacity and the runtime ring applies selected
  VM/kind-node CPU/memory caps. The target workload ring checks a plan-derived non-empty concurrent pod
  set, but lifecycle bring-up does not yet call `fitsBudget`.
- Target admission uses a pure provider-capability proof to create one provider-exact `ProviderWallSpec`
  and equal `EffectiveBudget`, then constructs a `BudgetPartition` proving every positive slice plus
  explicit overhead stays within it. Only afterward may a journaled same-spec reservation authorize the
  initial create/apply adapter, which mints live wall authority after authoritative observation; later
  builders require that authority. WSL's CPU/memory wall is an exclusively
  owned shared utility-VM resource; incompatible concurrent declarations are conflicts, not per-distro
  walls.
- Multi-node clusters consume the cluster envelope once. Lifecycle splits it across the declared node
  list and caps every node; the explicit `nvkind` topology is one control-plane plus one GPU worker.
- Storage carries no `docker update` flag. Provider VM disks receive creation-time sizing, but existing
  walls are not uniformly observed or reconciled; bare Linux has no implemented
  quota/garbage-collection wall.

## One Canonical Quantity Parser

`parseQuantity` is the shared quantity grammar in `HostBootstrap.Cluster.Cordon`. It accepts binary
suffixes (`Ki`, `Mi`, `Gi`, `Ti`, each optionally followed by `B`) and decimal suffixes (`K`, `M`,
`G`, `T`); a bare number is bytes. It decodes the `"8Gi"` form correctly, but also accepts zero and
sub-provider-minimum values. Preflight uses the parsed byte count while Lima/Colima/Incus/WSL builders
round memory/storage up to whole GiB, so fractional or decimal-SI values do not currently have one exact
meaning at every layer. Phase 9.10 admits an exact, positive, provider-valid quantity only when the
selected backend can represent it without upward rounding; the admitted `EffectiveBudget` equals the
validated declaration and is the sole numeric input to capacity checks and partitions. A builder also
requires authority from the post-partition journal: the initial create/apply adapter consumes the
same-`wallSpecId` reservation and mints `ProviderWallAuthority` only after observation, while later
builders consume that live authority. The pure effective value alone is not mutation authority.

The Python bootstrapper builds no sizing argv. `colimaSizingArgs project resources` emits the complete
`colima start --profile <project> --cpu N --memory <GiB> --disk <GiB>` argv. Haskell owns the complete
argv; the Python bootstrapper does not size VMs. See
[build and run model](../architecture/build_and_run_model.md) for where the project binary owns sizing,
and [resource budgeting](resource_budgeting.md) for the budget field itself.

### Why One Parser

One canonical `parseQuantity` decodes every quantity, and one builder family (`colimaSizingArgs`,
`limaSizingArgs`, `kindNodeCordonArgsFor`, `incusSizingArgs`, `wsl2SizingArgs`) emits provider-specific
sizing components (argv for the VM/node providers and the global `.wslconfig` `[wsl2]` body for WSL2).
The selected WSL install argv separately carries the registration-time per-distro `--vhd-size` value.
`HostBootstrap.Cluster.Lifecycle.clusterNodeCordonArgs` composes the node builder over the concrete node
list after splitting the one cluster envelope.
The Python bootstrapper builds no sizing argv. The shared parser keeps current Haskell sizing and
preflight interpretations aligned; it does not fill the missing compile assertion or bare-Linux storage
wall.

### Decode-Time Scalar Validity

The demo's top-level config decodes `memory`/`storage` through a transparent `Quantity` newtype backed by
`parseQuantity`; its `Resources` decoder enforces the CPU floor; and `HaReplicas`, service ports, and
timeouts use bounded decode-time newtypes. Those constructors and `Num`/`IsString` paths remain public,
and the separately decoded `Context.ResourceEnvelope` is raw `Natural`/`Text`/`Text`. Thus these are
decode-boundary checks, not proof that invalid applied resource states are unrepresentable. Cross-field
port distinctness remains runtime validation because one field newtype cannot express it.

A generated project config carries Kubernetes quantities as `Text` and contains no resolved pod set.
Consequently a Dhall `Budget/fitsWithin` assertion has neither numeric operands nor workloads to compare
and is deliberately **not** a target. `Core.dhall` retains the generic function and its evaluation tests;
the real project pod-set fit belongs before lifecycle effects, where `fitsBudget` has both parsed
quantities and the resolved pods. Today that wiring is absent: the demo API calls `fitsBudget` only over
`demoPods`, a static list containing the web example, and the web StatefulSet has no matching
CPU/memory requests or limits.

## Current Checks

| Ring | Mechanism | Where |
|------|-----------|-------|
| Decode (partial) | Top-level demo quantity/resource/replica/port/timeout refinements; raw applied envelope remains | Dhall extraction |
| Capacity | The pure `verifyBudget` preflight | `clusterCreate`, before cluster creation but after outer provider/container work |
| Workload (target) | `fitsBudget` over the exact plan's non-empty concurrent set | Before the first mutating plan operation; not wired today |
| Runtime | Applied VM / kind-node CPU and memory caps | The live substrate; storage incomplete on bare Linux |

### Capacity And Target Workload Rings

Two pure functions exist, but only the capacity function is wired into lifecycle bring-up:

- `preflightBudget resources hostCapacity` is the pure preflight: it derives the budget
  (`budgetFromResources`) and then runs `verifyBudget` (budget versus resolved host capacity),
  failing fast with a one-line diagnostic naming the first dimension that exceeds capacity.
- `fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()` can prove a supplied pod
  set fits the budget. Current lifecycle code does not call it, and its list type permits an empty or
  incomplete set. The target accepts a topology-derived `NonEmpty` workload set tied to the exact plan.

`resolveHostCapacity cfg` resolves host capacity **per substrate** through the pure
`capacityReadPlan substrate` source mapping:

| Substrate | CPU source | Memory source | Storage source |
|-----------|-----------|---------------|----------------|
| `apple-silicon` | `sysctl hw.ncpu` | `sysctl hw.memsize` (**total**) | `df -P -k /` available bytes |
| `linux-cpu` / `linux-gpu` | `/proc/cpuinfo` | `/proc/meminfo` `MemAvailable` | `df -P -k /` available bytes |
| `windows-cpu` / `windows-gpu` | CIM `Win32_ComputerSystem.NumberOfLogicalProcessors` | CIM `Win32_ComputerSystem.TotalPhysicalMemory` (**total**) | system-drive free space |

Two substrates read **total** physical memory (Apple `hw.memsize`, Windows `TotalPhysicalMemory`) rather
than momentary free/available memory: total is a stable property of the machine, so the preflight is a
fact about whether the host *can* host a budget-sized VM, not a volatile point-in-time reading. This
matters most on Windows/WSL2, where there is no per-distro hard memory cap (see the runtime ring): a
host whose *total* RAM cannot fit the budget fails fast at this ring rather than passing on transient
post-reboot free RAM and dying inside the build. **This ring checks `budget + 4 GiB host-OS reserve ≤ total`**
via the metal host preflight (`preflightHostBudget` / `verifyHostBudget`), so a budget that fits under total
RAM but leaves the host short (e.g. 13 GiB on 16 GiB) fails fast at this ring rather than passing. The in-VM
cluster-slice preflight (`preflightBudget` / `verifyBudget`) is reserve-free — the slice is already the
reserved subset, so there is no double-count. Linux uses `MemAvailable` as a fail-closed preflight, not an
advisory value. The CPU lane may later create an Incus VM; the direct GPU lane has no outer VM wall.
Storage is read as real free space on all substrates: `df -P -k /` on Apple/Linux and the system drive on
Windows. This is a capacity check,
not proof of a runtime quota. The IO surface in `clusterCreate` resolves capacity and runs
`preflightBudget` before creating the cluster. Provider reconciliation, VM launch/container handoff, and
other outer-frame effects may already have occurred, so this is not a global “before any substrate”
gate. The pure source mapping and live Apple `sysctl` read are unit-tested. See
[cluster lifecycle](cluster_lifecycle.md).

### Runtime Ring

The runtime ring is the cap actually applied to the live substrate.

On Linux, `ClusterPlan` owns the explicit node suffixes. A kind plan has `control-plane`; the demo's
`NvkindDriver` plan has `control-plane` and `worker`, matching `nvkind-in-cluster.yaml`. Lifecycle's
`clusterNodeCordonArgs` parses the one cluster envelope, divides CPU, memory bytes, and storage bytes by
the node count with integer floors, and refuses the plan if any dimension is smaller than that count.
Flooring guarantees the combined node shares never exceed the declared slice; giving both nvkind nodes
the full slice would double-count it.

That node-level split does not prove the parent-to-cluster slice is valid. The current demo-local
`clusterSliceOfBudget` can use its minimum floors to return a slice equal to or larger than a below-floor
parent envelope; the normal root floor masks that path, while the raw child envelope remains separately
constructible. The target exposes only slices eliminated from `BudgetPartition`, whose constructor proves
positivity, provider/node minima, and
`sum concurrent slices + explicit provider overhead <= EffectiveBudget`.

For each concrete name, `kindNodeCordonArgsFor` emits
`docker update --cpus N --memory <bytes> --memory-swap <bytes> <node>`. `applyLinuxCordon` runs every argv
fail-closed after kind/nvkind create (and kubeconfig export) and before workload deployment.
`--memory-swap == 2 × --memory`, so the node has swap headroom equal to its RAM limit. Storage is
included in the split and positive-share gate but omitted from `docker update`, which has no storage
flag. The cluster library can apply this path to either profile, but the demo harness currently
hardcodes the Production profile.

On Apple, the pristine path uses `limaSizingArgs` when creating a Lima VM; an already-existing VM is
started without comparing or updating its sizing. The parallel
`colimaSizingArgs` builder emits a profiled `colima start` argv for direct Docker workflows but is not
yet wired: the Colima reconciler currently starts an unsized `colima start`, so no code path sizes a Colima VM
from the budget today.

On Windows, the WSL2 wall is **honest about what WSL2 can enforce**. Unlike incus `limits.memory` and
Lima `--memory`, WSL2 has no per-distro memory/CPU cap — the only lever is the *global*, per-user
`%UserProfile%\.wslconfig` `[wsl2]` block that sizes the single shared utility VM hosting every distro.
So `wsl2SizingArgs` emits that `[wsl2]` body (`processors` / `memory` / `swap`, all derived from
`parseQuantity`; `swap` is sized to the memory budget for OOM headroom), and the WSL2 launch is a
*list* of effects: write `.wslconfig` (backing up any existing file), `wsl --shutdown` to apply it, then
register the distro. The body also carries `[wsl2] vmIdleTimeout=-1` plus `[general] instanceIdleTimeout=-1` —
the latter keeps the distro *instance* (not just the shared utility VM) alive after `project up` returns, so
the in-VM kind cluster does not idle-stop; `mergeWslConfig` manages both sections. Because the file is global,
teardown restores the backed-up `.wslconfig` when an original file produced that backup. If the original
was absent and the first run crashes after writing, no absence receipt exists; retry can back up the
generated file as if it were the original, so teardown restores generated content rather than absence.
An existing distro also skips registration/VHDX resize, and a running distro can avoid the shutdown that
would apply a changed global ceiling. This is a
weaker guarantee than a hard per-VM cap and the launch is a two-step write-then-shutdown rather than a
single sized argv — the unified `spLaunch` effect list (one pure lift per substrate) models exactly that
difference. Current code also has no platform-authoritative exclusive owner for this global wall, so
concurrent projects can race the file. The target acquires an exclusive, crash-recoverable global-state
lease/CAS before mutation, records original-present bytes or original-absent in the matching receipt, and
returns structured `Conflict` for a foreign or incompatible concurrent declaration. See
[wsl2](wsl2.md) for the provider detail.

## Per-Substrate Storage Cordon

Storage carries no `docker update` flag, so it is dropped from each `kindNodeCordonArgsFor` argv. It is
kept in `verifyBudget` and in the multi-node split/minimum-share check, so the bring-up ring still checks
the declared storage against the resolved capacity.
Each substrate cordons storage where it can:

| Substrate | Storage cordon |
|-----------|----------------|
| Apple | Lima `--disk` only on initial VM creation; the Colima builder exists but its sized profile is not wired |
| incus VM | `root,size` on initial instance launch; existing sizing is not reconciled |
| WSL2 VM | The distro's VHDX, capped only at registration through `wsl --install --vhd-size`; existing VHDX sizing is not reconciled. Memory/CPU are global `.wslconfig` settings, not per-distro flags |
| Bare Linux | **Not implemented**: no hostPath quota or image-garbage-collection cap |

On Linux CPU, `incusSizingArgs resources` emits `limits.cpu`, `limits.memory`, and `root,size` arguments
for initial instance launch. Direct Linux GPU has no Incus boundary. Neither path provides a bare-host
storage quota, and existing Incus sizing is not reconciled.

## Current Status

Capacity reads, the shared parser, and CPU/memory arg builders are implemented. Provider disk walls are
initial-create behavior for Lima/Incus/WSL2; bare Linux has no runtime storage cordon, Colima is unsized,
and direct Linux GPU outer effects are uncapped. Existing resource sizing is not uniformly compared or
reconciled. WSL2's global `.wslconfig` mechanism has historical runtime evidence only for its ordinary
cordon mechanics, not exclusive global ownership, absent-original crash recovery, immutable budget
identity, current durability, or test-profile closure. Native-lane status and exact dated test evidence
belong in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## See Also

- [resource budgeting](resource_budgeting.md) — the budget field and capacity preflight.
- [cluster lifecycle](cluster_lifecycle.md) — where the runtime ring is applied.
- [schema](schema.md) — the project-local `resources` record.
- [phase 9](../../DEVELOPMENT_PLAN/phase-9-applied-cordon-and-one-parser.md) — the development plan for
  this surface.
