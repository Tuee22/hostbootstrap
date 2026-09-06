# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [schema](schema.md), [applied cordon](applied_cordon.md), [cluster lifecycle](cluster_lifecycle.md)

> **Purpose**: Explain the project resource ceiling, exact plan/provider admission, workload partition,
> applied controls, and explicit limits of the supported storage policies.

## TL;DR

The project supplies one `resources` value. Core provides canonical quantities and exact admission, not a
runtime default. Plan-indexed budget, provider capability, workload fit, partition, slice, reservation, and
live wall evidence retain one lineage. Equal numbers from another plan are not interchangeable authority.

Provider and cluster adapters apply only the budget retained by their admitted package. A positive
caller-supplied number cannot reserve a wall, and a successful raw observation cannot mint live wall authority.
The [applied cordon guide](applied_cordon.md) describes the actual controls and unsupported dimensions.

## Current Status

[Cluster.Cordon.Foundation](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs)
owns opaque canonical-unit `ResourceBudget`, `parseQuantity`, capacity reads, exact sizing renderers, and
storage policy. [Cluster.Cordon](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs) adapts
project configuration and supplies descriptive helpers such as `fitsBudget`.
[Cluster.Budget](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs) owns exact plan-indexed
admission. These are distinct layers: a static helper result is not the capability for applying a wall.

The demo's `ClusterConfig` retains the selected Kind/nvkind driver, canonical config bytes and digest,
state/config paths, exposure intents, node mapping, and declared workload in `PlanOwnedClusterConfig`.
Cluster preparation consumes that package, the matching Running provider dependency, and a prepared gate.
It does not reconstruct a second config file or accept an unrelated envelope.

## The Budget Field

`resources` is project-owned configuration. Quantity syntax is decoded through the canonical parser;
private smart constructors validate the demo's resource floors, replica counts, ports, and timeouts.
Provider-exact admission rejects zero, unsupported precision, and values the selected backend cannot apply
exactly. Context carries no independent duplicate budget.

The demo assembler supplies its concrete lifecycle resources for both Production and Harness. Examples
and tests may use smaller values; those values are not a core default or evidence that the complete demo
fits them. Dated capacity and duration measurements belong in the owning development-plan records.

## The One Ceiling

The effective budget and its partition are produced from one admitted plan:

1. Select the exact planned provider and matching topology/resource evidence.
2. Verify the requested quantities against that provider's supported units and capabilities.
3. Admit the complete declared concurrent workload and its minimum requirements.
4. Construct a partition whose positive slices plus explicit provider overhead fit the effective budget.
5. Derive the provider-wall reservation from the exact durable `PreparedGate`.
6. Apply through the owning backend and settle only its opaque exact observation.

A `ResourceSlice` comes only from its partition. Applying the full parent budget to several concurrent
children would duplicate the allowance and cannot be represented by that partition. Workload declaration
must include service resources and overhead; a static web-only API example does not replace it.

## Verify Capacity

Host and cluster capacity checks classify unsupported information explicitly. The host check retains the
configured host-OS reserve; provider sizing then consumes exact admitted quantities. Capacity observation
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
| Kind/nvkind nodes | Positive per-node shares and identity-checked Docker updates using immutable container IDs |

Bare-Linux storage accounting is not a runtime quota or image-GC controller. The policy reports
`StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable`; preflighted free space must not be described
as an enforced storage ceiling. Docker's node-update interface does not enforce the declared storage share.
See [applied cordon](applied_cordon.md) for the same limit at the operation boundary.

## Validation

Run `cabal test all --ghc-options=-Werror` from `core/`. Quantity, budget, provider, cluster, and compile-fail
cases cover exact parsing, complete partitions, rejected cross-plan evidence, raw-observation refusal,
prepared settlement, and identity substitution. The demo's cluster-config cases check that rendered driver,
node mapping, workload, and exposure data remain bound to the same package.

Static host tests establish those program contracts. The [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md),
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), and terminal substrate acceptance phases
record live provider and workload evidence. [Testing](testing.md) defines the distinction.
