# Applied Cordon

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [resource budgeting](resource_budgeting.md), [cluster lifecycle](cluster_lifecycle.md),
[wsl2](wsl2.md),
[canonical quantities and reconcile results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md),
[Dhall configuration and generic project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)

> **Purpose**: Describe the applied resource controls, including the current bare-Linux storage gap,
> and the target in which every declared dimension is an enforced ceiling.

## TL;DR

- The host-level `<project>.dhall` `resources` value is intended to be a hard ceiling. Current
  CPU/memory application is partial: Lima/Incus/WSL limits are creation-time, direct Linux GPU outer
  effects are uncapped, the exact Colima adapter is not yet in the production recursive or demo command
  path, and
  bare-Linux storage is only preflighted. The prepared Direct provider is only a plan-local admission
  and identity share; it neither supplies an outer wall nor authorizes physical-host stop/delete.
- One canonical parser, `parseQuantity` in `HostBootstrap.Cluster.Cordon.Foundation`, decodes every
  quantity; one lower builder family produces each exact-budget sizing representation. The public
  `HostBootstrap.Cluster.Cordon` facade adapts the project `Resources`/`ResourceEnvelope` vocabulary and
  reexports that foundation rather than defining another parser.
- The top-level demo decode ring uses private, smart-constructed `Quantity`, resource-floor, replica,
  port, and timeout refinements. Lifecycle consumes that sole project-owned resource value; context has
  no duplicate budget. The current capacity ring checks host/cluster capacity and the runtime ring applies selected
  VM/kind-node CPU/memory caps. The target workload ring checks a plan-derived non-empty concurrent pod
  set, but lifecycle bring-up does not yet call `fitsBudget`.
- Target admission uses a pure budget-provider capability proof to create one provider-exact `ProviderWallSpec`
  and equal `EffectiveBudget`, then constructs a `BudgetPartition` proving every positive slice plus
  explicit overhead stays within it. Only afterward may a journaled same-spec reservation authorize the
  initial create/apply adapter, which mints live wall authority after authoritative observation; later
  builders require that authority. WSL's CPU/memory wall is an exclusively
  owned shared utility-VM resource; incompatible concurrent declarations are conflicts, not per-distro
  walls.
- Multi-node clusters consume the cluster envelope once. Lifecycle splits it across the declared node
  list and caps every node; the explicit `nvkind` topology is one control-plane plus one GPU worker.
- Storage carries no `docker update` flag. Provider VM disks receive creation-time sizing, but existing
  walls are not uniformly observed or reconciled. `storageCordonPolicy BareLinuxStorage` returns the
  typed result `StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable`; bare Linux has no
  implemented quota/garbage-collection wall.

## One Canonical Quantity Parser

`parseQuantity` is the shared quantity grammar in `HostBootstrap.Cluster.Cordon.Foundation`. It accepts binary
suffixes (`Ki`, `Mi`, `Gi`, `Ti`, each optionally followed by `B`) and decimal suffixes (`K`, `M`,
`G`, `T`); a bare number is bytes. It decodes fractional values exactly when they represent a whole
number of bytes (`0.5Ki` is 512 bytes) and rejects inexact byte fractions (`0.1B`). Grammar parsing is
separate from budget admission: a zero or otherwise invalid budget fails before capability construction.
Lima/Colima/Incus/WSL admission rejects memory or storage that is not exactly representable as whole GiB;
builders do not round a hard ceiling upward. The admitted `EffectiveBudget` equals the validated
declaration and is the sole numeric input to capacity checks and partitions.

The [step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
also implements the pure journal-before-call wall algebra: a matching wall spec, partition, and positive
fence create a reservation; only the prepared matching call exposes provider arguments; and
successful settlement mints live wall authority. WSL settlement returns its global lease inseparably
with that authority, while uncertain acquisition returns no authority. This budget capability is distinct
from `HostBootstrap.Substrate.Provider.ProviderCapability`, which is descriptive closed discovery for one
opaque managed Running provider and grants no mutation or wall authority. The baseline Incus lifecycle
backend has its own prepared provider/share origin and recovery protocol; live wall consumers and their
durable CAS/recovery implementations remain owned by the dependent budget/cluster phases. The pure
effective value alone is never mutation authority.

The Python bootstrapper builds no sizing argv. For an admitted Colima total above 20 GiB,
`colimaSizingArgsForBudget profile budget` emits the complete closed call:
`colima start --profile <profile> --runtime docker --activate=false --template=false --ssh-config=false
--mount none --kubernetes=false --network-address=false --mount-inotify=false --cpus N --memory <GiB>
--root-disk 20 --disk <total-20 GiB>`. The fixed root disk is provider overhead and the data disk is the
remaining workload-visible storage; their sum, not either flag alone, is the declared storage ceiling.
Haskell owns the complete argv; the Python bootstrapper does not size VMs. See
[build and run model](../architecture/build_and_run_model.md) for where the project binary owns sizing,
and [resource budgeting](resource_budgeting.md) for the budget field itself.

### Why One Parser

One canonical `parseQuantity` decodes every quantity, and one lower-foundation builder family (`colimaSizingArgs`,
`limaSizingArgs`, `kindNodeCordonArgsFor`, `incusSizingArgs`, `wsl2SizingArgs`) emits provider-specific
sizing components (argv for the VM/node providers and the global `.wslconfig` `[wsl2]` body for WSL2).
The selected WSL install argv separately carries the registration-time per-distro `--vhd-size` value.
`HostBootstrap.Cluster.Lifecycle.clusterNodeCordonArgs` composes the node builder over the concrete node
list after splitting the one cluster envelope.
`HostBootstrap.Cluster.Cordon` owns the configuration-facing conversion/wrappers and descriptive
`fitsBudget`; the lower Foundation imports no project config, plan, or provider realization module.
The Python bootstrapper builds no sizing argv. The shared parser keeps current Haskell sizing and
preflight interpretations aligned; it does not fill the missing compile assertion or bare-Linux storage
wall.

### Decode-Time Scalar Validity

The demo's top-level config decodes `memory`/`storage` through a transparent `Quantity` newtype backed by
`parseQuantity`; its `Resources` decoder enforces the CPU floor; and `HaReplicas`, service ports, and
timeouts use bounded decode-time newtypes. Their constructors are private, public smart constructors are
total, and they expose no `Num`/`IsString` bypass. `Resources` is the sole editable budget;
`BinaryContext` has no raw copy. Provider exactness and workload fit remain later plan checks rather than
properties one field newtype can express. Cross-field port distinctness remains runtime validation for
the same reason.

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
| Decode | Private smart-constructed demo quantity/resource/replica/port/timeout refinements; one project-owned budget | Dhall extraction |
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

That node-level split alone does not prove the parent-to-cluster slice is valid. The
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)'s
exact consumer accepts only a `ResourceSlice` eliminated from `BudgetPartition`, whose constructor proves
positivity, provider/node minima, and
`sum concurrent slices + explicit provider overhead <= EffectiveBudget`. The demo's concrete
workload/minimum/overhead declaration remains work in the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md); it cannot bypass the exact consumer with a
raw envelope.

For each concrete name, `kindNodeCordonArgsFor` emits
`docker update --cpus N --memory <bytes> --memory-swap <bytes> <node>`. `applyLinuxCordon` runs every argv
fail-closed after kind/nvkind create (and kubeconfig export) and before workload deployment.
`--memory-swap == 2 × --memory`, so the node has swap headroom equal to its RAM limit. Storage is
included in the split and positive-share gate but omitted from `docker update`, which has no storage
flag. The exact package derives Production or the generative Harness run profile from the retained plan,
retains the matching slice, and applies every node update under the cluster lock only after re-observing
the self-bound managed origin and complete retained node-name-to-container-ID map. The closed cluster backend
invokes Docker with those immutable IDs, not reusable Kind node names; a missing worker or any
same-name replacement is a conflict before mutation. A replacement or failed update mints no readiness.
The subsequent fresh probe requires the same durable owner/record and exact Kubernetes node set in addition
to API/all-node Ready, and advances its observation version only after success. The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns concrete demo adoption.

On Apple, the pristine path uses `limaSizingArgs` when creating a Lima VM; an already-existing VM is
started without comparing or updating its sizing. Direct Docker workflows use the separate exact Colima
adapter. One plan/provider/topology/budget/fit/partition package plus a journal-derived reservation and
provider start produces the only prepared call. A stable 128-bit plan/lifecycle token owns an isolated
`COLIMA_HOME`, reusable profile lock, and isolated `DOCKER_CONFIG`; a short local profile keeps Lima socket
paths within Darwin's limit without becoming the collision boundary. The private fixed Apple resolver binds
Python, Colima, Docker, Lima, and helper-directory identities, and the bounded runner closes environment,
cwd, output, and process-group lifetime.

Under the ownership row's descriptor-held kernel lock, self-bound
`reserved`/`home-staged`/`home-ready`/`context-staged`/`prepared`/`managed` records publish absence before
namespaces or `colima start`, then retain the exact invocation, machine/context identity, root/data wall,
directory chain, and complete Colima/Lima artifact manifest. A profile present from `prepared` without a
managed stage is outcome-unknown `Conflict`; it is never adopted. Only the hidden successful backend bridge
can jointly settle the provider start and wall, after which Docker runs through the retained named context.
Cleanup uses its own journal invocation, enters `releasing` before `colima delete --force --data`, and proves
profile, data, and context absence before conditionally removing only the bound namespaces and origin. A
replacement or partial foreign stage remains untouched as `Conflict`; an unavailable clause is
`Unsupported`. This source boundary remains Active in the
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
until its focused/full gates pass, and production recursive/demo call-site consumption remains open.

On Windows, the WSL2 wall is **honest about what WSL2 can enforce**. Unlike incus `limits.memory` and
Lima `--memory`, WSL2 has no per-distro memory/CPU cap — the only lever is the *global*, per-user
`%UserProfile%\.wslconfig` `[wsl2]` block that sizes the single shared utility VM hosting every distro.
So `wsl2SizingArgs` emits that `[wsl2]` body (`processors` / `memory` / `swap`, all derived from
`parseQuantity`; `swap` is sized to the memory budget for OOM headroom), and the WSL2 launch is a
*list* of effects: acquire the global wall (`ApplyGlobalWslWall`), `wsl --shutdown` to apply it, then
register the distro. The body also carries `[wsl2] vmIdleTimeout` plus `[general] instanceIdleTimeout`,
both set to the finite `managedWslIdleTimeoutMillis` (six hours) — the latter keeps the distro *instance*
(not just the shared utility VM) alive after `project up` returns, so
the in-VM kind cluster does not idle-stop; the byte-exact `GlobalWall.ConfigBytes` merge manages both
sections and preserves every unrelated byte, comment, and encoding. Because the file is global, teardown
releases the wall from a journalled origin record that names the original bytes **or** their absence, so
a crash after the first write restores absence rather than generated content. An existing distro still
skips registration/VHDX resize, and a running distro can avoid the shutdown that would apply a changed
global ceiling. This is a
weaker guarantee than a hard per-VM cap and the launch is a two-step write-then-shutdown rather than a
single sized argv — the unified `spLaunch` effect list (one pure lift per substrate) models exactly that
difference. The wall now holds all four
[ownership invariant](../architecture/ownership_invariant.md) clauses: it takes the OS-released
exclusive lock before mutation, records original-present bytes or original-absent durably before the
first write, binds every later operation to the file's object identity, and returns structured
`Conflict` for a foreign or incompatible
concurrent declaration.

`project down` returns the memory promptly: teardown releases the wall and then runs `wsl --shutdown`,
in that order, so the utility VM re-reads the restored file on its next cold boot and drops the balloon.
The [Windows-and-WSL2-substrate phase](../../DEVELOPMENT_PLAN/phase-27-windows-and-wsl2-substrate.md) owns
the finite managed idle timeout, so the host recovers memory on its own even when a run is interrupted
before teardown. Lima and Incus release on stop. See [wsl2](wsl2.md) § Wall release for the provider detail
and that ordering.

## The Storage Wall Backend Operation

`prepareStorageWallCall` is the operation that actually applies a declared storage ceiling. It consumes
only already-admitted inputs — the `ProviderWallSpec`, the proved `BudgetPartition`, and the journaled
`ProviderWallReservation` — so no caller can hand it a value admission would have refused.

| Provider | Result |
|----------|--------|
| Colima | `ColimaDiskArgument` — the canonical full start call binds `--root-disk 20` plus `--disk <total-20 GiB>`; admission rejects totals at or below 20 GiB |
| Lima | `LimaDiskArgument` — `--disk <GiB>` |
| Incus | `IncusRootSizeArgument` — `-d root,size=<GiB>GiB` |
| WSL2 | `Wsl2VhdSizeArgument` — `--vhd-size <GiB>GB` |
| kind node container | `Unsupported (DockerNodeHasNoStorageFlag)` — `docker update` has no storage flag |
| bare Linux | refused at admission; otherwise `Unsupported (BareLinuxHasNoStorageQuota)` |

`settleStorageWallCall` compares the ceiling the provider **observed** against the one that was
declared. They must be equal: a provider that reported success while rounding a hard ceiling upward
settles as a `Conflict`, not as applied. A zero wall epoch mints nothing. This is what makes "we did not
apply your storage ceiling" impossible to confuse with "applied".

## Per-Substrate Storage Cordon

Storage carries no `docker update` flag, so it is dropped from each `kindNodeCordonArgsFor` argv. It is
kept in `verifyBudget` and in the multi-node split/minimum-share check, so the bring-up ring still checks
the declared storage against the resolved capacity.
Each substrate cordons storage where it can:

| Substrate | Storage cordon |
|-----------|----------------|
| Apple | Lima `--disk` only on initial VM creation. The implemented exact direct-Colima adapter binds the plan-derived 20-GiB root plus `total-20`-GiB data disks, machine/context identity, and complete owned artifact manifest inside one descriptor-locked origin-before-start transaction. Its separately journaled conditional cleanup runs `colima delete --force --data`, proves exact profile/data/context absence, and removes only manifest-bound namespaces/origin. Production recursive and demo command integration remain downstream |
| incus VM | `root,size` on initial instance launch; existing sizing is not reconciled |
| WSL2 VM | The distro's VHDX, capped only at registration through `wsl --install --vhd-size`; existing VHDX sizing is not reconciled. Memory/CPU are global `.wslconfig` settings, not per-distro flags |
| Bare Linux | `StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable`: no hostPath quota or image-garbage-collection cap |

`storageCordonPolicy` represents these rows as a typed `StorageCordonResult`: provider-backed targets
return `StorageCordonSupported` with their concrete disk mechanism, while bare Linux returns the
explicit unsupported constructor above. This policy is not an ownership receipt or a substitute for
applying a provider wall.

On Linux CPU, `incusSizingArgs resources` emits `limits.cpu`, `limits.memory`, and `root,size` arguments
for initial instance launch. Direct Linux GPU has no Incus boundary. Neither path provides a bare-host
storage quota, and existing Incus sizing is not reconciled.

## Current Status

Capacity reads, the shared parser, and CPU/memory arg builders are implemented. Provider disk walls are
initial-create behavior for Lima/Incus/WSL2. Direct Colima's exact root/data wall, indexed live Docker route,
and identity-conditional cleanup are implemented. Its private backend has one pure durable-stage vocabulary
and total adjacent-transition decision; adoption by the effectful driver and the shared ownership seam remains
active in the [cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
Production recursive adoption remains with the [recursive-lifecycle-command
phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md), and demo adoption remains with the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). Bare Linux has no runtime storage cordon, and
direct Linux GPU outer effects are uncapped. Existing
resource sizing is not uniformly compared or reconciled. The prepared Incus/Direct lifecycle boundary
does not strengthen those wall claims: its four-clause ownership protocol protects provider identity and
mutation, while exact existing-wall reconciliation remains downstream. Its static gate and native
Linux/x86_64 KVM/Incus gate are closed in the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md).
WSL2's production global-wall backend has
current Windows evidence for its ownership adapter and the live restore-then-shutdown wall-release
observable. That evidence does not close universal prepared-authority consumption, running-distro wall
migration, existing-VHDX reconciliation, recursive teardown, durable readback, or test-profile closure.
Native-lane status and exact dated test evidence belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## See Also

- [resource budgeting](resource_budgeting.md) — the budget field and capacity preflight.
- [cluster lifecycle](cluster_lifecycle.md) — where the runtime ring is applied.
- [schema](schema.md) — the project-local `resources` record.
- [canonical quantities and reconcile results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md) — the development plan for
  this surface.
