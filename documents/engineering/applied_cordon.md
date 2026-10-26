# Applied Cordon

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [resource budgeting](resource_budgeting.md), [cluster lifecycle](cluster_lifecycle.md), [WSL2](wsl2.md)

> **Purpose**: Describe which resource controls the admitted provider and cluster operations apply,
> and distinguish an enforced limit from an observed capacity or unsupported storage policy.

## TL;DR

The target contract admits one project-owned budget against the exact plan and provider, proves through a
partition that concurrent slices plus overhead fit it, and lets backend settlement, rather than numerical
equality or a raw success value, produce authority to use an applied wall. No production path runs that
admission chain yet; [what runs today](resource_budgeting.md#what-runs-today) in
[resource budgeting](resource_budgeting.md), which owns admission, is the canonical statement of the controls
production applies.

CPU/memory controls are applied at the provider and/or cluster-node boundary supported by the realization;
the cluster-node cap is the whole cluster slice on every node (see [Current Status](#current-status)).
Bare-Linux storage preflight is not a quota: unsupported runtime storage enforcement remains an explicit
`StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable` result.

## Current Status

The exact cluster package retains its plan, provider dependency, workload slice, driver, config bytes/digest,
node mapping, and state paths. Its backend retains the complete node-name/container-ID map and checks it
before cordon, readiness, and cleanup. A same-named replacement refuses rather than receiving the old limit.
Only applied cordon plus fresh exact cluster readiness can authorize the dependent workload consumer.

The owned-cluster backend applies the whole cluster slice to each node rather than a per-node share; see
[Cluster Node Shares](#cluster-node-shares) and [resource budgeting](resource_budgeting.md#current-status).

## Canonical Quantities and Provider Controls

`HostBootstrap.Cluster.Cordon.Foundation` owns `parseQuantity` and the exact-budget sizing renderers.
`HostBootstrap.Cluster.Cordon`, the configuration-adapter facade over it, reexports them. Positive values that
cannot be expressed exactly by the selected
provider are rejected rather than rounded into a different wall.

- Incus and Lima apply the declared VM sizing and retain their managed provider/share identity.
- Direct Colima uses an isolated home/profile/context and canonical CPU/memory arguments. Its storage total
  is the 20-GiB root disk plus the `total-20`-GiB data disk. The managed machine and artifact identities gate
  live Docker and separately journaled conditional `colima delete --force --data` cleanup.
- WSL2 CPU/memory limits belong to the shared utility VM. The managed `.wslconfig` body also sets swap equal
  to the memory amount and the two idle-timeout keys ([WSL2](wsl2.md#resource-wall-and-global-effect)). The
  global-wall transaction records the prior state and releases conditionally; incompatible concurrent
  declarations conflict. The distro's declared VHDX storage cap is separate from the global CPU/memory resource.
- A Direct provider is a plan-local admission, not ownership of the physical host or an outer VM wall.

No provider sizing declaration promises automatic resizing of a pre-existing foreign or differently sized VM.
The exact backend's inspection and ownership protocol determine whether it can proceed.

**Admission names every backend, and each backend's exactness rule carries its own reason.** This admission
belongs to the `Cluster.Budget` chain, which no production path calls yet; the provider renderers that
production does run apply the same whole-gibibyte exactness. The site that
admits a budget at the provider wall matches on the backend constructor with no wildcard, so `-Wall`
plus warnings-as-errors makes adding a backend a compile error there rather than a silent inheritance of
whichever rule the wildcard happened to hold. The rules and why each holds:

| Backend | Admission | Why |
|---|---|---|
| Bare Linux | unsupported | no quota or image-GC wall exists to size against |
| Docker node | any positive budget | the runtime caps CPU and memory in bytes; storage is admitted but not enforced (see [Cluster Node Shares](#cluster-node-shares)) |
| Colima | whole gibibytes, and its own renderer | it reserves a fixed writable root disk inside the ceiling |
| Lima | whole gibibytes | `--memory` and `--disk` take whole gibibytes and nothing finer |
| Incus | whole gibibytes | `limits.memory` and the root volume size render as `<n>GiB` |
| WSL2 | whole gibibytes | `.wslconfig` takes `memory=<n>GB`, and the VHDX install cap takes the same unit |

The budget suite asserts each of these six answers rather than the three the wildcard once covered.

## Cluster Node Shares

Kind declares its control-plane node; the demo's nvkind plan declares control-plane and worker nodes. The
target divides the cluster slice by the exact node count with integer floors, refuses a dimension smaller than
that count, and keeps combined node shares within the retained slice. Only the compatibility `clusterCreate`
path divides that way today (`clusterNodeCordonArgs`). The owned-cluster backend that `project up` drives
applies the whole slice to every node container, so an N-node cluster's aggregate cap is N times its slice;
[resource budgeting](resource_budgeting.md#current-status) states that gap and the phase that owes it.

The Docker update applies CPU, memory, and memory-swap to each immutable node container ID under the cluster
lock. The memory-swap total is twice the memory limit. Storage participates in budget admission and in the
compatibility path's positive-share check, but Docker update supplies no storage limit; that dimension is not
an enforced node quota.

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
