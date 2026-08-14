# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [applied_cordon](applied_cordon.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define the per-project resource ceiling, distinguish the delivered pure authority
> foundation from partially applied live provider walls, and specify the closed target projection and
> enforcement contract.

## TL;DR

- The [canonical-quantities-and-reconcile-results
  phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md) owns exposed,
  provider-neutral `HostBootstrap.Cluster.Cordon.Foundation`: opaque canonical-unit `ResourceBudget`,
  exact parsing/refusal, capacity reads/checks, exact-budget sizing renderers, and storage policy. That
  phase separately owns the generic readiness and reconcile vocabulary. The
  [Dhall-configuration-and-generic-project-model
  phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md) owns the public
  `HostBootstrap.Cluster.Cordon` facade that reexports the foundation and adapts
  `Config.Vocab.Resources`/`ResourceEnvelope`, its preflight wrappers, and descriptive `fitsBudget`. The
  [step-algebra-and-project-plan
  phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md) owns the exact generic Budget
  admission boundary: one `ProjectPlan`, matching provider/cluster `PlannedResource`s, and its
  `DerivedTopology`. It accepts no compatibility `Reconcile.LifecyclePlan`, caller-supplied plan digest,
  frame, resource identity, or topology graph.
- `ValidatedBudget`, provider capability, workload fit, partition, slice, reservation, prepared call, and
  live wall carry one nominal plan lineage. A provider-wall reservation now comes only from the exact
  plan/provider operation's durable `PreparedGate`; a positive caller number is not a reservation. Raw
  provider/cluster observations remain deliberately plan-independent data and cannot enter public wall
  settlement. A package-private owning adapter encloses a successful backend observation and the matching
  prepared operation/preconditions in an opaque settlement permit before live authority can exist.
  The [cluster-lifecycle-and-cordoning
  phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns the exact cluster consumer
  and the implemented, gate-closed exact direct-Colima consumer boundary. The [worked-demo
  phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the concrete demo workload, overhead, partition,
  and slices.
- On provider-backed lanes, the target effective wall is cordon #1. A `BudgetPartition` exists only after
  proving every positive slice plus explicit overhead fits within that wall and meets provider/node minima.
  Lima and Incus use per-VM walls. **WSL2 has no per-distro CPU/memory wall**: its one shared utility-VM
  ceiling is protected by the four [ownership invariant](../architecture/ownership_invariant.md) clauses,
  while the VHDX is a separate per-distro slice. An incompatible concurrent declaration returns `Conflict`
  rather than overwriting `.wslconfig`; `project down` restores the journalled origin and performs global
  shutdown. See [wsl2](wsl2.md) § Wall release.
- The demo has one project-owned `resources` value and `BinaryContext` has no duplicate envelope. Child-config
  projection currently copies the full scoped `ProjectConfig.resources`; the [worked-demo
  phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) replaces full-budget consumer forwarding with exact
  slices. A test config may override the budget and now selects a Harness cluster/root, but those consumers
  still derive an independent `ClusterProfile` from config. That phase replaces the duplicate profile/root
  input with the retained plan projection.
- The project binary verifies capacity before the relevant VM launch or cluster creation and applies the
  available provider or kind/nvkind-node cordon. Current Lima/Incus sizing is creation-only. Bare Linux has
  no runtime storage quota or image-GC cap. Direct Linux GPU outer host work is uncapped and only the later
  nvkind nodes receive CPU/memory walls.
- The implemented direct-Apple `HostBootstrap.Ensure.Colima` adapter prepares a wall only from one exact
  `ProjectPlan`, its matching provider `PlannedResource` and `DerivedTopology`, and the matching validated
  budget, capability, wall, workload-fit, partition, and reservation evidence. It accepts no compatibility
  lifecycle plan, independent binary context, caller-selected profile, raw resource envelope, or separately
  derived root/profile term. A stable 128-bit plan/lifecycle token determines the isolated Colima home and
  reusable global-lock identity; a socket-safe local profile is meaningful only inside that home. Total
  storage must exceed 20 GiB and is rendered as a fixed 20-GiB root disk plus a `total-20`-GiB data disk.
  Raw list/call/machine/context observations remain plan-independent. The prepared call, provider-start and
  wall settlement, live route, and cleanup retain the exact journal lineage and complete backend identity.
  The private fixed resolver admits and fingerprints only canonical Apple Python/Colima/Docker/Lima tools and
  helper directories. Under descriptor-held Python `fcntl.flock`, the durable protocol records absence before
  creating the isolated home or Docker config, then binds the exact invocation, root/data wall, machine,
  named context, record/namespace/disk objects, directory chain, and complete artifact manifest. A profile
  present from `prepared` without a managed stage is outcome-unknown `Conflict`. Live Docker reacquires that
  binding; separate teardown lineage enters `releasing` before `colima delete --force --data` and proves
  profile/data/context absence before conditional namespace/origin release. Missing clauses are
  `Unsupported`; mismatches are `Conflict`. The adapter never uses `default` or global context activation. The
  [cluster-lifecycle, budgets, and cordoning
  phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) focused/full gates are closed.
  Production recursive adoption remains in the
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md), while
  demo adoption remains in the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).
- A multi-node cluster receives the cluster envelope once; current lifecycle divides CPU, memory, and storage
  over its nodes and applies the CPU/memory cap to each. `fitsBudget` is tested, but no live bring-up yet
  supplies the demo's complete non-empty concurrent workload set. That concrete projection belongs to the
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

## Current Status

Under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the resource
budget/provider wall is a PROVIDER concern carried by a project's own `cfg`, not a core-universal field.
A secrets-strict, RKE2/EKS-sized consumer that deploys to an existing cluster carries no provider budget
at all. For a project that declares one, § O's sole admitted `EffectiveBudget` is the provider-effective
wall: per-VM on Lima/Incus, or an exclusively owned shared utility-VM wall plus a per-distro VHDX slice
on WSL2. See the [generic_project_model.md](../architecture/generic_project_model.md) design,
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

Core has no runtime default budget. The illustrative `4/8/20` value remains only in fixtures and cannot
bootstrap the demo: its `deploy-VM` gate requires `6/10/80` (`demoFullLifecycleResources`). The
project-owned `psAssemble` supplies that value for Production and Harness assembly. See
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md).

The Linux GPU path extends the runtime controls without changing this model. A normal kind plan
declares one `control-plane` node; the explicit `nvkind` plan declares `control-plane` and `worker`.
`clusterNodeCordonArgs` divides the one cluster slice across the declared node list and refuses a slice
whose CPU, memory, or storage cannot give every node a positive share. Native CPU/GPU runtime gates and
dated evidence belong in the development plan. Bare-Linux storage remains uncordoned at runtime.

That all-node split is not proof that the parent-to-cluster partition is valid. The current demo-local
`clusterSliceOfBudget` uses `max` floors; below the full-lifecycle root floor it can return CPU equal to
the parent and memory/storage larger than the parent. The ordinary root gate masks those inputs, and
opaque `Resources` now prevents bypass through direct construction, but the live path still does not
consume the exact generic `ResourceSlice`. That value can be eliminated only from a `BudgetPartition`
proving positivity, provider/node minima, and
`sum concurrent slices + explicit overhead <= EffectiveBudget`.

On direct Apple Docker paths, `HostBootstrap.Ensure.Colima` is deliberately not a config-free reconciler and
does not appear in `allReconcilers`. Its exact prepared boundary consumes the plan/provider/topology plus the
complete budget/fit/partition and journal-derived reservation/start package. The call fixes all side-effecting
defaults, disables global activation, and renders CPU, memory, 20-GiB root, and `total-20`-GiB data walls.
The plan-derived 128-bit namespace owns the isolated Colima home, Docker config, and reusable lock; the local
`h-<6hex>` profile and `colima-<profile>` context are not standalone authority. A private fixed resolver,
bounded group runner, self-bound multi-stage origin, stable machine/context observation, and complete
artifact/directory manifest close the effect. Public settlement accepts only the opaque owned observation
from that exact invocation, jointly completes provider `Observed` to managed `Running`, and mints the live
wall. Live Docker and distinct journal-prepared `Running` to `Destroyed` cleanup revalidate the same binding;
cleanup uses `--force --data` and conditionally removes only exact manifest-listed state. Cross-plan,
cross-attempt/session/journal, foreign, replacement, partial-stage, and outcome-unknown prepared-state cases
mint no authority. The [cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) closes this source boundary and its
focused/full gate evidence. Production recursive adoption remains in the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md), while
demo adoption remains in the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

The demo has one descriptive resource value: private `ProjectConfig.resources` constructors and total smart
constructors feed every VM and cluster sizing path. `BinaryContext` carries no resource envelope.
`childContextWith` preserves the full scoped parent config value, so cluster-service and daemon configs do
not yet receive the smaller exact slice that the demo computes locally for `clusterCreate`.

The generic pure algebra rejects an inexact declaration before jointly minting one `ProviderWallSpec` and
equal `EffectiveBudget`. Constructive `BudgetPartition` then mints per-plan, per-frame slices before any wall
acquisition. The [step-algebra-and-project-plan
phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md) owns closure and validation of the
exact `ProjectPlan`/resource/topology admission boundary.
A journal-before-call reservation and matching prepared call are required before provider arguments are
exposed. The reservation producer consumes the exact `ProjectPlan`, provider `PlannedResource`, wall,
partition, and durable gate, and derives the session/fence/attempt/journal version from that gate. A raw wall
observation remains plan-independent and is not a public settlement input. Only a package-private producer
that joins the exact prepared operation/preconditions with its closed backend result can mint the nominal
settlement permit consumed by public settlement; uncertain acquisition mints none. WSL supplies the durable
shared-wall journal/CAS backend.
The [cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) implements and validates both exact consumers.
Direct Colima derives its wall request from the matching plan evidence. Cluster reconciliation retains the
matching `ResourceSlice`, includes its canonical CPU/memory/storage values in the prepared call binding, and
applies those exact values to the owned node containers under the cluster identity lock before readiness can
be minted. The managed origin retains the complete declared node-name-to-container-ID map, and the cordon
re-observes that map under the same exact lock/state/record binding before issuing
`docker update` against immutable IDs rather than reusable node names. A missing/replaced worker,
control-plane replacement, config-snapshot drift, or failed update yields no readiness authority. Production
recursive and demo
call-site adoption remain open; the concrete demo partition remains with the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

## The Budget Field

The resource request is a `resources` record in the host-level project config described in
[schema](schema.md):

```dhall
{ resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
```

The `4/8/20` above is an **illustrative shape**, not a default: core ships no default budget. The demo's
own `psAssemble` default is `6/10/80` (its `deploy-VM` gate,
`demoFullLifecycleResources`, requires it), and each project's assembler supplies its own budget. See
the [Current Status](#current-status) note and
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md).

- `cpu` — whole cores reserved for the project's substrate.
- `memory` — memory ceiling for the project's substrate.
- `storage` — disk request/preflight quantity. It is a provider-disk wall on VM-backed lanes.
  `storageCordonPolicy BareLinuxStorage` returns the explicit typed
  `StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable` result because it is not yet a runtime
  cap on bare Linux.

The target project binary validates this field once under the exact project plan and projects the matching
slice before crossing a VM, container, daemon, or cluster-service boundary. Current demo lifecycle copies
the full `ProjectConfig.resources` value through child configuration and locally recomputes a cluster slice;
`BinaryContext` has no resource envelope. The smaller exact slice is not carried into cluster-service/daemon
consumers. The Python bootstrapper reads no project resource field and builds no Lima/Incus/Colima sizing
argv. See
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
ProviderWallReservation
  scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence
ProviderWallSettlementPermit
  scope planId providerResourceId budgetId provider capabilityId wallSpecId workloadSetId partitionId
  reservationId fence operationKey callDigest attempt journalVersion
ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence
WslGlobalWallLease scope planId wallSpecId wallEpoch fence
```

Pure provider selection creates only a `ProviderBudgetCapability`. Admission consumes it with the
validated budget and jointly creates the exact `ProviderWallSpec`/`EffectiveBudget`; neither is
ownership or write authority. The workload-fit proof, partition, and every slice are constructed before
effects and can exist only with that exact scope/plan/budget/provider/capability/`wallSpecId` lineage.

After the partition exists, the only reservation producer consumes the exact plan/provider resource, wall,
partition, and `PreparedGate` that durably recorded that provider operation. It checks the gate's plan digest
and operation key and copies its non-empty session plus positive fence, attempt, and journal version into the
same-spec `ProviderWallReservation`; the caller supplies none of those fields. The initial-wall adapter
consumes that reservation with the wall spec and partition, may reserve/create/apply or observe the provider
wall, and returns
`ProviderWallAuthority ... wallSpecId wallEpoch fence` only after authoritative applied/unchanged
observation. It does not circularly require that post-effect authority for the call that mints it. An
unknown reservation/acquire/apply result exposes only recoverable same-spec state until exact reprobe
settles it.

The observation crossing the backend boundary is intentionally not plan evidence. A raw
`WallAcquireObservation` or storage-wall observation contains only measured backend facts. Storage settlement
still validates its descriptive observation against its prepared storage call. Provider-wall settlement is
stricter: no public function accepts `WallAcquireObservation`. An unexposed provider-specific bridge first
inspects the closed backend result; only its owning applied/exact branches may enter the provider-neutral
package-private mint with the exact nominal `PreparedOperation`/`PreparedPreconditions` pair. That mint
encloses the authorized observation and prepared wall call in `ProviderWallSettlementPermit`, and only
`settleProviderWallCall prepared permit` can mint an indexed live value. The same hidden bridge completes the
opaque journal-bound provider start from the retained observed handle, so provider-specific machine identity
cannot masquerade as generic resource generation. Cluster observation follows its own closed backend-result
boundary. This keeps probes reusable without allowing a same-shaped observation to authorize another plan.

Later reconcile and dependent mutation permits accept no raw quantities or same-shaped slice from another
lineage: they require both the exact same-`wallSpecId` partition projection and the live authority, and
revalidate its epoch/fence. On WSL the exact owning adapter consumes the journal-derived reservation and
retains the OS-released exclusive lock across the initial shared-wall operation. Only its successful closed
backend result may produce the settlement permit that jointly returns the epoch-indexed
`WslGlobalWallLease` inseparably with the live authority; the reservation itself is journal lineage, not an OS
handle. The capability, spec, partition, or `EffectiveBudget` by itself cannot edit or restore `.wslconfig`.

`HostBootstrap.Cluster.Cordon.Foundation.parseQuantity` is shared by preflight and argument builders. It
preserves exact whole-byte values, and provider admission rejects memory/storage a selected whole-GiB
backend cannot represent exactly. The current defenses are:

- **Decode ring** — top-level demo `Quantity`, resource-floor, replica, port, and timeout refinements
  reject invalid fields during Dhall extraction and expose only total smart constructors. One
  project-owned `Resources` value reaches lifecycle sizing. A config has text quantities and no pod set, so a Dhall `fitsWithin`
  assertion is neither possible nor a target.
- **Capacity ring** — the pure `verifyBudget` runs as a fail-fast preflight (budget versus resolved
  host capacity — total RAM on Apple/Windows, `MemAvailable` on Linux); it is reserve-free because it
  gates the in-VM cluster slice, which is already the reserved subset, while the METAL host preflight
  (`preflightHostBudget`/`verifyHostBudget`) applies the ~4 GiB host-OS reserve. The target workload ring
  derives the full non-empty concurrent set from the exact plan and requires `fitsBudget` before the first
  effect. The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that currently absent
  call.
- **Runtime ring (partial)** — creation-time Lima/Incus/WSL sizing, an exact plan-owned direct-Colima wall
  adapter, and kind/nvkind-node CPU/memory caps. The Colima adapter's prepared-to-live and origin-bound cleanup
  package and owning phase's focused/full gates are closed. Production recursive and demo call-site adoption
  remain open in the [recursive-lifecycle-command
  phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) and
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), respectively. The
  [cluster-lifecycle, budgets, and cordoning
  phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns the exact cluster consumer.
  Existing resources are not uniformly re-cordoned, direct Linux GPU outer effects remain uncapped, and
  storage is incomplete on bare Linux.

The applied mechanics, canonical parser, and missing bare-Linux storage wall are documented in
[applied_cordon](applied_cordon.md).

## Verify Capacity

Before cordoning, the project binary checks that the scoped project configuration's declared budget can be
satisfied locally. If the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line
diagnostic
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
reconciliation or every lifecycle effect. Current Windows evidence closes the shared-wall release
observable only; broader lifecycle closure belongs in the development plan. See
[applied_cordon](applied_cordon.md) for the capacity ring and
[cluster_lifecycle](cluster_lifecycle.md) for where it runs.

The demo has implemented a top-level decode ring: below-floor `Resources`, malformed-unit `Quantity`,
out-of-range port/timeout, or invalid replica values are rejected during Dhall extraction, and public
construction uses the same total smart constructors. The [canonical-quantities-and-reconcile-results
phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)'s admission rejects
non-positive budgets, and provider admission rejects selected-provider inexact quantities. Pod-set fit cannot
be encoded by those scalar types. The target lifecycle check is `fitsBudget` over a topology-derived non-empty
set; the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the absent concrete call. See
[applied_cordon](applied_cordon.md) and
[development_plan_standards.md § O](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Cordoning per Substrate

The target admitted `EffectiveBudget` is enforced across every plan effect so a project's workload
cannot exceed its declared share. Per-VM walls are used where the provider supports them; WSL's shared
global wall requires exclusive ownership and conflict refusal. Current cordons cover the substrate rows
below only in the stated places; the project binary applies them, never the Python bootstrapper.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | For the pristine demo environment, a newly created dedicated Lima VM is sized only after exact whole-GiB admission; an existing VM's sizing is not compared or reconciled. The implemented exact direct-Colima adapter binds one 128-bit isolated-home/lock namespace, a local profile/context, canonical CPU/memory plus 20-GiB-root/`total-20`-GiB-data argv, fixed trusted tools, stable machine/context, and complete artifacts under descriptor-held Python `fcntl.flock`. Only backend-produced provider-start/wall settlement exposes live Docker; independently journaled conditional `--force --data` cleanup releases exact profile/data/context/namespaces. Production recursive and demo adoption remains open. |
| `linux-cpu` | A newly created Incus VM receives CPU/memory/storage limits only for exact admitted quantities; existing VM sizing is not reconciled. The later kind-node CPU/memory cap is applied during cluster bring-up. Storage has no runtime cap if a path runs directly on bare Linux. |
| `linux-gpu` | The outer host-native build and project-container handoff are direct and uncapped. The later nvkind cluster envelope is split across `control-plane` and GPU `worker`, and `docker update --cpus --memory --memory-swap` is applied fail-closed to both nodes. Bare-Linux storage is not capped. |
| `windows-cpu` / `windows-gpu` | WSL2 memory/CPU use the **global** `%UserProfile%\.wslconfig` `[wsl2]` ceiling; storage is a per-distro VHDX cap applied only at registration. The backend journal records exact original bytes or absence and refuses foreign replacement. `project down` restores that origin and then performs global `wsl --shutdown`, releasing the utility VM balloon; finite idle timeouts backstop an interrupted run. A running distro is not necessarily shut down during reconcile, and an existing VHDX is not resized. See [wsl2](wsl2.md). |

On Apple the pristine demo cordon is the Lima VM, while direct Docker workflows have the prepared
per-project Colima wall adapter; on Linux the cluster-side cordon is applied after kind/nvkind create and before workload
deployment, fail-closed. The lifecycle derives the concrete node names from `ClusterPlan`, splits the
slice across them, and applies every generated `docker update` argv. Storage participates in the split
and minimum-share check but has no `docker update` flag. A newly created Lima VM gets `--disk` and a
newly created Incus VM gets `root,size`; the Colima adapter compares the exact observed 20-GiB root plus
`total-20`-GiB data wall and its owned artifacts, while
existing Lima/Incus disks are not reconciled. Bare-Linux quota and image GC remain targets, not
implemented walls.
The cluster-side enforcement is part of the lifecycle semantics in
[cluster_lifecycle](cluster_lifecycle.md); the full applied detail — the argv, the storage drop from the
runtime flags, and the current `--memory-swap == 2 × --memory` headroom policy — is in
[applied_cordon](applied_cordon.md).
