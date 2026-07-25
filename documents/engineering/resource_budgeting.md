# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [applied_cordon](applied_cordon.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define the intended per-project resource ceiling, distinguish it from the duplicate and
> partially applied values in the current implementation, and specify the closed target projection and
> enforcement contract.

## TL;DR

- The target admits one opaque `ValidatedBudget` only when the selected provider can represent every
  dimension exactly. Its user-visible byte values and the sole `EffectiveBudget` are equal, so no builder
  can silently round a hard ceiling upward. Every frame envelope is a projection of that value. Current
  demo config instead stores independently editable top-level `resources` and raw
  `context.resourceEnvelope`; lifecycle sizing reads the latter, validation does not require equality,
  and the current `context` inspection renderer displays neither value for comparison. Child-context
  helpers inherit that full raw envelope rather than a proved slice.
- On provider-backed lanes, the target effective wall is cordon #1. A `BudgetPartition` exists only after
  proving every positive cluster slice plus explicit provider/VM overhead fits within that wall and meets
  all provider/node minima. Lima and Incus use per-VM walls. **WSL2 has no per-distro CPU/memory wall**:
  its one shared utility-VM ceiling is protected by an exclusive, crash-recoverable global-state
  lease/CAS, while the VHDX is a separate per-distro slice; a foreign or incompatible concurrent
  declaration returns `Conflict` rather than overwriting `.wslconfig`. Current Lima/Incus sizing is
  creation-only, WSL rewrites global settings without resizing an existing VHDX, and provider builders
  round byte quantities up to whole GiB. The budget is never added to itself — see
  [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
  [wsl2](wsl2.md), and [applied_cordon](applied_cordon.md).
- A test config may override the budget. The demo projects that resource override into its generated
  config, but currently resolves a **Production** cluster plan; test-profile isolation is an open defect.
- The project binary verifies capacity before the relevant VM launch or cluster creation, then applies
  the available cordon—a dedicated VM (Lima for the Apple pristine demo, Incus on the Linux CPU lane,
  WSL2 on Windows) or a kind/nvkind-node cap. The only budget-capped one-shot container seam is
  definition/test-only and the production project-container lift supplies no CPU/memory limit. Direct
  Apple Colima currently starts an unsized default profile; direct Linux GPU performs uncapped outer
  host build/container work and caps only the later nvkind nodes. Phase 5.8 and Phase 9.10 own complete
  plan-effect coverage.
- A cluster with multiple node containers receives the cluster envelope **once**: lifecycle splits CPU,
  memory, and storage evenly (flooring each share) and applies the CPU/memory cap to every node. The
  `nvkind` direct GPU topology is one control-plane plus one GPU worker, so neither node receives the
  full envelope.
- Selected CPU, memory, replicas, ports, and timeouts have decode-time validation, but their constructors
  remain public and the lifecycle-consumed raw context envelope bypasses those refinements. Bare byte,
  zero, and below-provider-minimum quantities can still reach later failure. The intended resolved
  concurrent-pod gate is not wired into lifecycle bring-up: `fitsBudget` is unit-tested and used by a
  static demo API view whose `demoPods` lists only the web example. Storage has a real free-space
  preflight and provider VM walls, but
  **bare Linux has no runtime storage quota or image-GC cap**. Applied detail lives in
  [applied_cordon](applied_cordon.md).
- Downstream binaries do not read the host config directly; they consume an envelope in their own sibling
  `<project>.dhall`. Current projection copies the parent's full envelope; the target projects an exact
  plan/frame-indexed slice.

## Current Status

Under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the resource
budget/provider wall is a PROVIDER concern carried by a project's own `cfg`, not a core-universal field.
A secrets-strict, RKE2/EKS-sized consumer that deploys to an existing cluster carries no provider budget
at all. For a project that declares one, § O's sole admitted `EffectiveBudget` is the provider-effective
wall: per-VM on Lima/Incus, or an exclusively owned shared utility-VM wall plus a per-distro VHDX slice
on WSL2. See the [generic_project_model.md](../architecture/generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

Concretely, the former core default budget `4/8/20` (now only a test fixture) could not bootstrap the
demo — the demo's `deploy-VM` gate requires `6/10/80` (`demoFullLifecycleResources`) — so under phase-19
the default lives in the project-owned `psInit` and the demo's `psInit` returns its real budget. See
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md).

The Linux GPU path extends the runtime controls without changing this model. A normal kind plan
declares one `control-plane` node; the explicit `nvkind` plan declares `control-plane` and `worker`.
`clusterNodeCordonArgs` divides the one cluster slice across the declared node list and refuses a slice
whose CPU, memory, or storage cannot give every node a positive share. Native CPU/GPU runtime gates and
dated evidence belong in the development plan. Bare-Linux storage remains uncordoned at runtime.

That all-node split is not proof that the parent-to-cluster partition is valid. The current demo-local
`clusterSliceOfBudget` uses `max` floors; below the full-lifecycle root floor it can return CPU equal to
the parent and memory/storage larger than the parent. The ordinary root gate masks those inputs, but the
separately constructible raw child envelope can bypass it. The target exposes only a `ResourceSlice`
eliminated from a `BudgetPartition` proving positivity, provider/node minima, and
`sum concurrent slices + explicit overhead <= EffectiveBudget`.

On direct Apple Docker paths, `colimaSizingArgs` exists and is tested, but the current
`ensureColima` path still probes/starts the shared default profile without those CPU/memory/disk values.
The hard-wall claim for that lane is target behavior owned by Phase 5.8, not current enforcement.

The demo currently has two resource authorities. `ProjectConfig.resources` is refined and remains visible
in the config value and demo-only summary/test helper, while
`ProjectConfig.context.resourceEnvelope` is a separately decoded raw `Natural`/`Text`/`Text` record
consumed by VM and cluster sizing. The production `context inspect`/`show` renderer emits only composition
frames, so it does not expose either value or their disagreement. Editing one does not update or validate
the other. `childContextWith` copies the entire parent envelope, so cluster-service and daemon configs do
not receive the smaller cluster slice that the demo computes locally for `clusterCreate`. Phase 9.10's
target removes the duplicate: pure provider-capability admission either rejects an inexact declaration
or mints one `ProviderWallSpec` and equal `EffectiveBudget`, and a constructive `BudgetPartition` mints
exact per-plan, per-frame slices before any wall acquisition. Only a later journaled transition can mint
the same-spec live wall authority accepted by a backend argument builder; raw config text or an
independently recomputed floor is never an effect input.

## The Budget Field

The resource request is a `resources` record in the host-level project config described in
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
- `storage` — disk request/preflight quantity. It is a provider-disk wall on VM-backed lanes but is not
  yet a runtime cap on bare Linux.

The target project binary validates this field once and projects the appropriate envelope before crossing
a VM, container, daemon, or cluster-service boundary. Current demo lifecycle instead consumes the
separate raw context envelope, and child projection copies that envelope unchanged; the locally computed
cluster slice is not carried into cluster-service/daemon configs. The Python bootstrapper reads neither
field and builds no Lima/Incus/Colima sizing argv. See
[python_haskell_boundary](../architecture/python_haskell_boundary.md) and
[binary_context_config](../architecture/binary_context_config.md).

## The One Ceiling

The target is for one provider-exact admitted `resources` value to be the hard ceiling. Admission rejects
a declaration that would require a selected backend to round upward; the resulting `EffectiveBudget`
equals the user-visible `ValidatedBudget`, and capacity, workload, partition, and runtime checks all
consume it. `BudgetPartition` construction proves positive slices plus explicit overhead remain within
that value. Lima/Incus realize per-VM walls; WSL realizes one exclusively owned global utility-VM wall
plus a separate per-distro VHDX slice, refusing incompatible concurrent ownership.

Equality of numbers is not authority. The target opaque values carry one common lineage:

```text
ValidatedBudget scope planId budgetId
ProviderBudgetCapability scope planId provider capabilityId
ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId
EffectiveBudget scope planId budgetId provider capabilityId wallSpecId
PlannedWorkloadSet scope planId workloadSetId
VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId
BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId
ResourceSlice
  scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId
ProviderWallReservation scope planId provider wallSpecId reservationId fence
ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence
WslGlobalWallLease scope planId wallSpecId wallEpoch fence
```

Pure provider selection creates only a `ProviderBudgetCapability`. Admission consumes it with the
validated budget and jointly creates the exact `ProviderWallSpec`/`EffectiveBudget`; neither is
ownership or write authority. The workload-fit proof, partition, and every slice are constructed before
effects and can exist only with that exact scope/plan/budget/provider/capability/`wallSpecId` lineage.

After the partition exists, a journaled transition first creates the same-spec
`ProviderWallReservation`. The initial-wall adapter consumes that reservation with the wall spec and
partition, may reserve/create/apply or observe the provider wall, and returns
`ProviderWallAuthority ... wallSpecId wallEpoch fence` only after authoritative applied/unchanged
observation. It does not circularly require that post-effect authority for the call that mints it. An
unknown reservation/acquire/apply result exposes only recoverable same-spec state until exact reprobe
settles it.

Later reconcile and dependent mutation permits accept no raw quantities or same-shaped slice from another
lineage: they require both the exact same-`wallSpecId` partition projection and the live authority, and
revalidate its epoch/fence. On WSL the `ProviderWallReservation ... reservationId fence` retains the
platform-exclusive pre-call lock/CAS across the initial shared-wall operation. Observed completion
consumes that reservation and jointly returns the epoch-indexed `WslGlobalWallLease` inseparably with the
live authority; the capability, spec, partition, or `EffectiveBudget` by itself cannot edit or restore
`.wslconfig`.

Today
`HostBootstrap.Cluster.Cordon.parseQuantity` is shared by preflight and argument builders, but the
provider builders round parsed bytes up to whole GiB and the applied input may be the divergent raw
context envelope. The current defenses are:

- **Decode ring (partial)** — top-level demo `Quantity`, resource-floor, replica, port, and timeout
  refinements reject selected invalid fields during Dhall extraction. Their constructors remain public;
  `Quantity` accepts bare bytes and zero/sub-provider-minimum values; and the lifecycle-consumed
  `ResourceEnvelope` is raw. A config has text quantities and no pod set, so a Dhall `fitsWithin`
  assertion is neither possible nor a target.
- **Capacity ring** — the pure `verifyBudget` runs as a fail-fast preflight (budget versus resolved
  host capacity — total RAM on Apple/Windows, `MemAvailable` on Linux); it is reserve-free because it
  gates the in-VM cluster slice, which is already the reserved subset, while the METAL host preflight
  (`preflightHostBudget`/`verifyHostBudget`) applies the ~4 GiB host-OS reserve. The target workload ring
  derives the full non-empty concurrent set from the exact plan and requires `fitsBudget` before the
  first effect; that call is not present today.
- **Runtime ring (partial)** — creation-time Lima/Incus/WSL sizing and kind/nvkind-node CPU/memory caps.
  Existing resources are not uniformly re-cordoned; direct Linux GPU outer effects and direct Colima are
  uncapped; storage is incomplete on bare Linux.

The applied mechanics, canonical parser, and missing bare-Linux storage wall are documented in
[applied_cordon](applied_cordon.md).

## Verify Capacity

Before cordoning, the project binary checks that the active context's declared envelope can be satisfied
locally. If the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line diagnostic
naming the shortfall and exits non-zero. **The METAL host preflight now gates on `host RAM ≥ budget +
reserve` (a 4 GiB host-OS reserve)**, so a budget that fits under *total* host RAM but would leave the host
itself short (e.g. a 13 GiB budget on a 16 GiB host) is refused by `preflightHostBudget`/`verifyHostBudget`;
the in-VM cluster-slice preflight (`preflightBudget`/`verifyBudget`) stays reserve-free because the slice is
already the reserved subset, so the reserve is never double-counted. Historical Windows evidence covers
this cordon behavior only; current lifecycle closure belongs in the development plan.

`verifyBudget` is the pure core of this check; `preflightBudget resources hostCapacity` derives the
budget and runs `verifyBudget` against resolved host capacity (total physical RAM on Apple/Windows,
`MemAvailable` on Linux). `resolveHostCapacity` resolves
capacity **per substrate**, so the preflight is a real gate on every supported host:

| Substrate | CPU cores | Memory | Storage |
|-----------|-----------|--------|---------|
| `apple-silicon` | `sysctl -n hw.ncpu` (logical cores) | `sysctl -n hw.memsize` (total physical RAM) | free bytes from `df -P -k /` |
| `linux-cpu` / `linux-gpu` | `/proc/cpuinfo` processor count | `/proc/meminfo` `MemAvailable` | free bytes from `df -P -k /` |
| `windows-cpu` / `windows-gpu` | CIM `Win32_ComputerSystem.NumberOfLogicalProcessors` | CIM `Win32_ComputerSystem.TotalPhysicalMemory` (total physical RAM) | system-drive free space |

Memory is read as **total** physical RAM on Apple and Windows (a stable property of the machine) and as
`MemAvailable` on Linux. Storage is read from real free space on every substrate (`df` on Apple/Linux,
the system drive on Windows). This is a capacity preflight, not a bare-Linux quota. The Windows
total-memory predicate matters because WSL2 has no per-distro
memory cap (see Cordoning per Substrate): the preflight must fail fast on a too-small host rather than
pass on transient free RAM. On Apple, `sysctl` is invoked through the resolved `HostTool Sysctl`,
preserving the host-tool absolute-path rule. The cluster-slice preflight runs inside `clusterCreate`
before cluster creation, but only after the outer provider/container path and its prerequisite work have
already been reached. The separate metal preflight occurs before VM launch, not before provider
reconciliation or every lifecycle effect. See [applied_cordon](applied_cordon.md) for the capacity ring and
[cluster_lifecycle](cluster_lifecycle.md) for where it runs.

The demo has implemented a partial top-level decode ring: selected below-floor `Resources`, malformed-unit
`Quantity`, out-of-range port/timeout, or invalid replica values are rejected during Dhall extraction.
Public constructors, zero/sub-provider-minimum quantities, the raw applied envelope, and duplicate budget
authority remain. Pod-set fit cannot be encoded by those scalar types. The target lifecycle check is
`fitsBudget` over a topology-derived non-empty set; today no bring-up call provides that set. See
[applied_cordon](applied_cordon.md) and
[development_plan_standards.md § O](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Cordoning per Substrate

The target admitted `EffectiveBudget` is enforced across every plan effect so a project's workload
cannot exceed its declared share. Per-VM walls are used where the provider supports them; WSL's shared
global wall requires exclusive ownership and conflict refusal. Current cordons cover the substrate rows
below only in the stated places; the project binary applies them, never the Python bootstrapper.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | For the pristine demo environment, a newly created dedicated Lima VM is sized to whole-GiB-rounded `cpu` / `memory` / `storage`; an existing VM's sizing is not compared or reconciled. For direct Apple Docker workloads, the target Colima VM is a project-specific Docker-provider cordon; current `ensureColima` instead starts/probes the unsized default profile (Phase 5.8). |
| `linux-cpu` | A newly created Incus VM receives rounded CPU/memory/storage limits; existing VM sizing is not reconciled. The later kind-node CPU/memory cap is applied during cluster bring-up. Storage has no runtime cap if a path runs directly on bare Linux. |
| `linux-gpu` | The outer host-native build and project-container handoff are direct and uncapped. The later nvkind cluster envelope is split across `control-plane` and GPU `worker`, and `docker update --cpus --memory --memory-swap` is applied fail-closed to both nodes. Bare-Linux storage is not capped. |
| `windows-cpu` / `windows-gpu` | WSL2 memory/CPU use the **global** `%UserProfile%\.wslconfig` `[wsl2]` ceiling; storage is a per-distro VHDX cap applied only at registration. The file is reapplied on reconcile, but a running distro is not necessarily shut down and an existing VHDX is not resized. Original-file restoration is reliable only when an original file produced a backup; absent-original crash recovery lacks an absence receipt. See [wsl2](wsl2.md). |

On Apple the pristine demo cordon is the Lima VM, while direct Docker workflows may use the per-project
Colima VM; on Linux the cluster-side cordon is applied after kind/nvkind create and before workload
deployment, fail-closed. The lifecycle derives the concrete node names from `ClusterPlan`, splits the
slice across them, and applies every generated `docker update` argv. Storage participates in the split
and minimum-share check but has no `docker update` flag. A newly created Lima VM gets `--disk` and a
newly created Incus VM gets `root,size`; the current direct Colima path is unsized, and existing
Lima/Incus disks are not reconciled. Sized project-specific Colima, bare-Linux quota, and image GC are
targets, not implemented walls.
The cluster-side enforcement is part of the lifecycle semantics in
[cluster_lifecycle](cluster_lifecycle.md); the full applied detail — the argv, the storage drop from the
runtime flags, and the current `--memory-swap == 2 × --memory` headroom policy — is in
[applied_cordon](applied_cordon.md).
