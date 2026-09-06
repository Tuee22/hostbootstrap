# Applied Cordon

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [resource budgeting](resource_budgeting.md), [cluster lifecycle](cluster_lifecycle.md), [WSL2](wsl2.md)

> **Purpose**: Describe which resource controls the admitted provider and cluster operations apply,
> and distinguish an enforced limit from an observed capacity or unsupported storage policy.

## TL;DR

One project-owned budget is admitted against the exact plan and provider. A partition proves that concurrent
slices plus overhead fit that budget. Backend settlement, rather than numerical equality or a raw success
value, produces authority to use an applied wall. [Resource budgeting](resource_budgeting.md) owns admission.

CPU/memory controls are applied at the provider and/or cluster-node boundary supported by the realization.
Bare-Linux storage preflight is not a quota: unsupported runtime storage enforcement remains an explicit
`StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable` result.

## Current Status

The exact cluster package retains its plan, provider dependency, workload slice, driver, config bytes/digest,
node mapping, and state paths. Its backend retains the complete node-name/container-ID map and checks it
before cordon, readiness, and cleanup. A same-named replacement refuses rather than receiving the old limit.
Only applied cordon plus fresh exact cluster readiness can authorize the dependent workload consumer.

## Canonical Quantities and Provider Controls

`HostBootstrap.Cluster.Cordon.Foundation` owns `parseQuantity` and the exact-budget sizing renderers. The
configuration facade reexports them. Positive values that cannot be expressed exactly by the selected
provider are rejected rather than rounded into a different wall.

- Incus and Lima apply the declared VM sizing and retain their managed provider/share identity.
- Direct Colima uses an isolated home/profile/context and canonical CPU/memory arguments. Its storage total
  is the 20-GiB root disk plus the `total-20`-GiB data disk. The managed machine and artifact identities gate
  live Docker and separately journaled conditional `colima delete --force --data` cleanup.
- WSL2 CPU/memory limits belong to the shared utility VM. The global-wall transaction records the prior
  state and releases conditionally; incompatible concurrent declarations conflict. The distro's declared
  VHDX storage cap is separate from the global CPU/memory resource.
- A Direct provider is a plan-local admission, not ownership of the physical host or an outer VM wall.

No provider sizing declaration promises automatic resizing of a pre-existing foreign or differently sized VM.
The exact backend's inspection and ownership protocol determine whether it can proceed.

## Cluster Node Shares

Kind declares its control-plane node; the demo's nvkind plan declares control-plane and worker nodes. The
cluster slice is divided by the exact node count with integer floors. A dimension smaller than that count
refuses because it cannot supply positive shares. Combined node shares cannot exceed the retained slice.

The Docker update applies CPU, memory, and memory-swap to each immutable node container ID under the cluster
lock. The memory-swap total is twice the memory limit. Storage participates in the positive-share and fit
checks, but Docker update supplies no storage limit; that dimension is not an enforced node quota.

The cluster's declared node set must match observation. Its readiness probe checks the API and every node's
Ready condition after re-observing the complete managed identity map. A delayed result or a replaced worker
cannot authorize a newer generation.

## Capacity Is Not Enforcement

A free-space or allocatable-resource read is a precondition, not an ownership receipt or applied limit.
Likewise the descriptive `fitsBudget` helper and static generated artifacts cannot substitute for the
plan-indexed workload fit, partition, journal-derived reservation, and backend-produced wall authority.

Workload declarations and rendered chart requests must describe the same selected role resources. The exact
demo config binder retains its declared workload alongside the driver, node mapping, and exposure intents.
Live acceptance proves only the realization and workload actually exercised; it does not establish a missing
bare-Linux quota or a different provider's behavior.

## Validation

The core warnings-as-errors suite exercises canonical sizing, exact budget lineage, complete partition
admission, prepared provider/cluster settlement, identity substitution, and unsupported storage policy.
The [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) records its
static and live gate. The [worked demo](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) and terminal acceptance
phases record concrete provider and workload confirmation. See [testing](testing.md).
