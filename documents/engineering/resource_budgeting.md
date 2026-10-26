# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [schema](schema.md), [applied cordon](applied_cordon.md), [cluster lifecycle](cluster_lifecycle.md), [development plan standards](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Explain the project resource ceiling, exact plan/provider admission, workload partition,
> applied controls, and explicit limits of the supported storage policies.

## TL;DR

The project supplies one `resources` value. Core provides canonical quantities and exact admission, not a
runtime default. Inside the `Cluster.Budget` admission chain, plan-indexed budget, provider capability,
workload fit, partition, slice, reservation, and live wall evidence retain one lineage, and equal numbers
from another plan are not interchangeable authority. Within that chain a positive caller-supplied number
cannot reserve a wall, and a successful raw observation cannot mint live wall authority.

No production lifecycle path runs that chain yet. Production sizes provider walls from the project envelope
through the canonical renderers, caps cluster nodes from the cluster slice, and preflights host capacity.
[What runs today](#what-runs-today) is the canonical statement of which controls apply; the
[applied cordon guide](applied_cordon.md) describes the same controls at the operation boundary.

## Current Status

[Cluster.Cordon.Foundation](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs)
owns opaque canonical-unit `ResourceBudget`, `parseQuantity`, capacity reads, exact sizing renderers, and
storage policy. [Cluster.Cordon](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs) adapts
project configuration and supplies descriptive helpers such as `fitsBudget`.
[Cluster.Budget](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs) owns exact plan-indexed
admission. These are distinct layers: a static helper result is not the capability for applying a wall.

Three gaps separate the tree from the contract this page states:

- No production lifecycle path mints a validated budget or runs workload fit, partition, or journal-derived
  wall reservation; see [What runs today](#what-runs-today). Production adoption of that chain is owed by
  [the worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), as
  [standards § O](../../DEVELOPMENT_PLAN/development_plan_standards.md#o-resource-budget-and-cordoning) records.
- The owned-cluster kind backend applies the whole cluster slice to every node container, so an N-node
  cluster's aggregate cap is N times its slice. That defect is owed by
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- `storageCordonPolicy` is the target's single storage-wall vocabulary, but the prepared storage-wall call in
  `Cluster.Budget` carries its own second enumeration (`StorageWallMechanism`, `StorageWallUnsupported`)
  rather than taking its mechanism and unsupported reason from that policy. Consolidating them is owed by
  [the canonical quantities and reconcile results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md);
  see [Cordoning Per Substrate](#cordoning-per-substrate).

A canonical quantity or budget refuses with a **closed answer**, not a sentence. `QuantityError` has six
constructors in two groups:

| Group | Constructor | Refusal |
|---|---|---|
| quantity text | `QuantityNotANumber` | the text does not begin with a number |
| quantity text | `QuantityMalformedNumber` | the numeric part is not a decimal number |
| quantity text | `QuantityUnknownUnit` | the unit suffix is not an accepted one |
| quantity text | `QuantityNotWholeBytes` | the value scales to a fraction of a byte |
| budget dimension | `DimensionNotPositive` | the named `BudgetDimension` (cpu, memory, or storage) is zero or negative |
| budget dimension | `DimensionAboveBound` | the named `BudgetDimension` is above the supported bound |

`renderQuantityError` is the one place that
turns a refusal into the operator-facing sentence, so a caller can ask which dimension failed without
matching on rendered text and the diagnostic cannot drift from the answer. The cluster's plan-indexed
admission carries that value as `InvalidQuantity` rather than interpolating it into a string.

Core's `PlanOwnedClusterConfig`
([Cluster.Lifecycle](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs)) retains the
selected Kind/nvkind driver, canonical config bytes and digest, state/config paths, exposure intents, node
mapping, and declared workload. The demo builds it from its own cluster-config rendering through
`withExactPlanOwnedClusterConfig`; a derived project does not redefine the type. Cluster preparation consumes
that package, the matching Running provider dependency, and a prepared gate. It does not reconstruct a second
config file or accept an unrelated envelope.

## What runs today

This section is the canonical statement of the resource controls production applies;
[standards § O](../../DEVELOPMENT_PLAN/development_plan_standards.md#o-resource-budget-and-cordoning) states
the same boundary for the plan.

| Control | Where it runs | What it enforces |
|---|---|---|
| Metal host preflight | `preflightHostBudget`, called by the demo's lifecycle preflight on the metal frame | CPU, memory, and storage each fit host totals; memory additionally keeps the fixed `hostMemoryReserveBytes` (4 GiB) for the host OS, Docker, and the orchestrator. CPU and storage carry no reserve. On Windows the storage figure includes swap. |
| In-frame capacity preflight | `preflightBudget` over `verifyBudget`, called only by the compatibility `clusterCreate` path that the bare `cluster-live` gate drives | the same totals, with no reserve |
| Provider VM walls | the Lima provider backend and the demo's provider bring-up render the project envelope through `planProviderProvision` and the canonical sizing renderers when a Lima, Incus, or WSL2 provider is created | whole-gibibyte sizing; a value the renderer cannot express exactly is refused rather than rounded |
| WSL2 global wall | `HostBootstrap.Wsl2.GlobalWall` | the shared utility-VM CPU/memory wall under its ownership clauses (see [WSL2](wsl2.md#resource-wall-and-global-effect)) |
| Kind/nvkind node cap | the demo's cluster step attaches the cluster slice from its config projection with `withActionResourceSlice`; the owned-cluster backend's `cordonOwnedCluster` applies it | `docker update` CPU, memory, and memory-swap on each bound node container. The whole slice lands on every node (see [Current Status](#current-status)). |

`withActionResourceSlice` attaches an action-local budget to the executing planned resource under fresh
partition indices. It proves the slice belongs to that planned resource; it does not prove membership in a
partition or that concurrent slices fit one budget. The compatibility `clusterCreate` path divides its
slice per node with integer floors through `clusterNodeCordonArgs`; the owned-cluster backend does not.

Production applies none of `withValidatedBudget`, `admitProviderBudget`, `verifyPlannedWorkloadFit`,
`withBudgetPartition`, `withResourceSliceFor`, or `withProviderWallReservation`, and the direct-Colima consumer
that requires the full chain (`prepareColimaWallCall`) has no production caller. The core suites exercise them.

## The Budget Field

`resources` is project-owned configuration. Quantity syntax is decoded through the canonical parser;
private smart constructors validate the demo's resource floors, replica counts, ports, and timeouts.
Provider-exact admission rejects zero, unsupported precision, and values the selected backend cannot apply
exactly. Context carries no independent duplicate budget.

The demo assembler supplies its concrete lifecycle resources for both Production and Harness. Examples
and tests may use smaller values; those values are not a core default or evidence that the complete demo
fits them. Dated capacity and duration measurements belong in the owning development-plan records.

## The One Ceiling

This section states the target contract the `Cluster.Budget` kernels implement; no production path runs it
yet (see [What runs today](#what-runs-today)). The effective budget and its partition are produced from one
admitted plan:

1. Select the exact planned provider and matching topology/resource evidence.
2. Verify the requested quantities against that provider's supported units and capabilities.
3. Admit the complete declared concurrent workload and its minimum requirements.
4. Construct a partition whose positive slices plus explicit provider overhead fit the effective budget.
5. Derive the provider-wall reservation from the exact durable `PreparedGate`.
6. Apply through the owning backend and settle only its opaque exact observation.

Inside the chain a `ResourceSlice` comes from its partition through `withBudgetPartition` and
`withResourceSliceFor`; applying the full parent budget to several concurrent children would duplicate the
allowance and cannot be represented by that partition. The public `withActionResourceSlice` also mints a
`ResourceSlice`, from an action-local budget with no partition, so holding a slice does not by itself prove
partition membership. Workload declaration
must include service resources and overhead; a static web-only API example does not replace it.

## Verify Capacity

Host and cluster capacity checks classify unsupported information explicitly. The metal host check adds the
fixed `hostMemoryReserveBytes` (4 GiB) to the memory budget before comparing it with total host memory; CPU
and storage have no reserve, and the reserve is not configurable. Provider sizing then renders the exact
quantities. Capacity observation
alone does not establish ownership or authorize changing a running VM.

The Dhall `fitsWithin` and `split` functions operate on numeric artifact values and are pinned by evaluation
tests. Runtime project configs carry typed text quantities and no independent resolved pod set, so they do
not gain a universal fit proof by attaching that Dhall assertion. The authoritative workload/partition join
occurs in `Cluster.Budget`.

## Provider Identity Before Budget Admission

Provider identity is derived from the exact plan resource and topology, not a conventional step name or the
current frame alone. VM-backed topology identifies its declared provider frame; the Direct path retains a
plan-local reservation and canonical host-root share. Direct admission does not authorize physical-host
stop/delete or claim an outer VM wall.

Provider readiness is a fresh probe of the exact managed generation. Cluster preparation reruns that probe
through its complete operation preconditions. Wrong backend, plan, frame, resource, generation, or journal
lineage refuses before the backend effect.

## Cordoning Per Substrate

| Realization | Applied contract and limits |
|---|---|
| Incus | Exact VM creation sizing and managed provider/share identity; changing an existing disk is not implicit admission |
| Lima | Exact declared VM sizing and writable share observation retained by the provider backend |
| Direct Colima | Isolated managed profile/home/context; CPU and memory plus canonical 20-GiB root and `total-20`-GiB data disks; exact force cleanup |
| WSL2 | Owned global utility-VM CPU/memory wall plus the declared distro storage cap; conflicting concurrent global declarations refuse |
| Direct Linux | Plan-local provider admission and cluster-node CPU/memory controls; no claim of an outer provider wall |
| Kind/nvkind nodes | Identity-checked Docker updates using immutable container IDs; the owned-cluster backend applies the whole cluster slice to each node rather than a per-node share (see [Current Status](#current-status)) |

`storageCordonPolicy` in `Cluster.Cordon.Foundation` is the storage-wall vocabulary: it maps each
`StorageCordonTarget` to the wall mechanism a provider builder applies or to a typed unsupported reason.

| Target | Policy answer |
|---|---|
| `ColimaVmStorage` | `StorageCordonSupported ColimaDiskFlag` |
| `LimaVmStorage` | `StorageCordonSupported LimaDiskFlag` |
| `IncusVmStorage` | `StorageCordonSupported IncusRootDiskLimit` |
| `Wsl2DistroStorage` | `StorageCordonSupported Wsl2VhdSize` |
| `BareLinuxStorage` | `StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable` |

The answer grants no authority to apply a wall. In the target contract the prepared storage-wall call in
`Cluster.Budget` takes its mechanism and its unsupported reason from this policy; today it carries its own
enumeration (see [Current Status](#current-status)).

Bare Linux has no storage wall. Its storage accounting is not a runtime quota or image-GC controller, and
preflighted free space must not be described as an enforced storage ceiling. Docker's node-update interface does not enforce the declared storage share.
See [applied cordon](applied_cordon.md) for the same limit at the operation boundary.

## Validation

Run `cabal test all` from `core/`. Quantity, budget, provider, cluster, and compile-fail
cases cover exact parsing, complete partitions, rejected cross-plan evidence, raw-observation refusal,
prepared settlement, and identity substitution. The demo's cluster-config cases check that rendered driver,
node mapping, workload, and exposure data remain bound to the same package.

Static host tests establish those program contracts. The [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md),
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), and terminal substrate acceptance phases
record live provider and workload evidence. [Testing](testing.md) defines the distinction.
