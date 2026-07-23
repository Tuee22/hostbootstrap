# Durable State

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [readiness.md](readiness.md), [../engineering/cluster_lifecycle.md](../engineering/cluster_lifecycle.md), [../engineering/wsl2.md](../engineering/wsl2.md), [../engineering/lima.md](../engineering/lima.md), [../engineering/incus.md](../engineering/incus.md), [../engineering/gitignore_guardrails.md](../engineering/gitignore_guardrails.md), [../README.md](../README.md), [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Canonical home for what `.data` is, what the never-delete-`.data` invariant does and
> does not guarantee, and where durable state actually lives on each substrate.

## TL;DR

- **The one guarantee:** cluster teardown never places the plan's data path in its removal set. An
  existing `.data` directory is left on disk. This is real and unit-tested on disk.
- **That is the whole of it.** It is *not* host mirroring, *not* a promise the path exists, and *not*
  survival of frame deletion.
- `.data` is **frame-relative**: it resolves against the *owning frame's* source root. On a lifted
  topology that names a **guest** path, which `project destroy` deletes along with the guest.
- **No code creates `.data`.** Contrast `.test_data`, which the harness genuinely creates.
- **Host-durable project state is not yet validated on any substrate.** The per-substrate host-path share
  primitive — a host-side share reconcile plus a guest-side alias and mount-readiness — is the mechanism
  (§ DD); its host-side half is landed and the rest is reopened work, not a delivered guarantee. See
  [Current Status](#current-status).

## The one guarantee

Teardown partitions the plan's paths into a removal set and a preserve set
(`HostBootstrap.Cluster.Lifecycle`):

- `teardown Down` returns an **empty** removal set — `down` removes no filesystem path at all.
- `teardown Delete` returns **only** the derived paths; the data path is never among them.

`clusterTeardown` hands only the removal set to `removeAll`, so the data path is excluded by
construction. Both `project down` and `project destroy` therefore leave an existing `.data` directory
exactly where it was.

## What the invariant does not say

**It does not say `.data` is a host path.** The path is computed as `<source root>/.data`, where the
source root belongs to the frame that owns the cluster lifecycle step. In a nested chain
(host → VM → project container → cluster) that frame is the **project container**, so the path names a
location inside the container — not on the developer's machine.

**It does not say `.data` survives `project destroy`.** `destroy` deletes the provisioned frame *and
its disk*: `incus delete --force`, `limactl delete --force`, and on Windows `wsl --unregister`, which
removes the distro's vhdx. A guest-side `.data` goes with it. The invariant governs the cluster
teardown's removal set; it has no authority over frame deletion.

**It does not say anything creates `.data`.** No production code path materializes the directory. The
guarantee is vacuously satisfied when the path never existed. Compare `.test_data`, which the
standardized harness does create — the codebase materializes durable roots when it intends to.

## Frame relativity

This is the concept most easily lost. The same identifier means different things at different frames:

| Frame | Source root | `.data` resolves to |
|-------|-------------|---------------------|
| host orchestrator | the project root on the machine | a real host path |
| VM orchestrator | the staged tree inside the guest | a guest path |
| project container | `/workspace/<project>` | a container path |

Which frame owns the cluster step is a property of the **project's chain wiring**, not of
`hostbootstrap-core`. A project that binds its cluster step to the host frame gets a genuinely
host-rooted `.data`; a project that binds it inside a container does not. Neither is more correct —
but only the first is host-durable, and the chain is what decides.

## Host↔guest transfer per substrate

Every substrate stages **one way**, host → guest. No provider exposes a reverse transfer, and no
shared filesystem is configured for the project tree.

| Substrate | Host → guest | Guest → host | Shared filesystem |
|-----------|--------------|--------------|-------------------|
| WSL2 | tar staged and extracted into the distro's ext4 vhdx | none | drvfs exposes host drives at `/mnt/<letter>`, used only to *read* the staging archive in place |
| Incus | `incus file push` | none | no disk device is attached |
| Lima | `limactl copy` | none | no project mount is configured |

Consequently a write made inside a guest — including to `.data` — has no path back to the host.

## The direct-host lane

One topology is different and must not be swept into a blanket negative. The Linux GPU direct
`nvkind` lane provisions **no VM and no project container**; the cluster step runs on the metal host.
There `.data` genuinely *is* a host path and genuinely *does* outlive `project destroy`, because there
is no frame to delete. See [../engineering/cluster_lifecycle.md](../engineering/cluster_lifecycle.md).

## What actually persists today

| Thing | Where it lives | Survives pod restart | Survives `project destroy` |
|-------|----------------|----------------------|----------------------------|
| the demo's MinIO PVC | kind's default `local-path` provisioner, inside the kind node container | yes | no |
| `.test_data` | the **root** frame — genuinely host-side, created by the harness | n/a | created and removed by the harness per run |
| `.data` | wherever the owning frame's source root points | n/a | only on the direct-host lane |

The demo's registry-persistence case demonstrates the first row and only that row: it deletes the
registry pod, waits for rollout, and re-reads through the NodePort. It inspects no filesystem and no
host path.

## The Host-Path Share Primitive

A host directory reaches a guest through one per-substrate share primitive on `SubstrateProvider` /
`HostPathShare`, modeled as pure data and interpreted generically
([development plan standards § DD](../../DEVELOPMENT_PLAN/development_plan_standards.md)). It has three parts:

- **Host-side reconcile** (`ShareReconcile`, an optional field shaped like the cordon-reconcile). Incus
  attaches a disk device after create; Lima declares the mount at instance create; WSL2 needs none, because
  drvfs already exposes the drive and `windowsPathToWslMount` already rewrites the path. This half is landed
  on `SubstrateProvider` (`spShare`).
- **Guest-side alias reconcile.** The stable Docker-visible path (`/var/tmp/<project>-data`) is a symlink
  to the share, modeled as a pure `AliasState`
  (`AliasAbsent | AliasLinkedCorrectly | AliasLinkedElsewhere | AliasOccupied`) with a total classifier and
  a create/remove planner. The **same** classifier serves the VM-shell lane (trivial guest probes) and the
  direct Linux-GPU lane (`System.Directory`), so the alias state machine is written once, not per lane.
- **Mount-readiness.** The guest share is proven present and writable — a retrying `Ready` witness
  ([readiness](readiness.md)) — before the alias is minted, so the alias step cannot race the mount and a
  genuine collision surfaces as a message rather than a bare `ExitFailure 1`.

## Current Status

**Implemented:** the removal-set guarantee described above, on every substrate; and the **host-side** half
of the share primitive (`spShare` / `HostPathShare` / `ShareReconcile` on `SubstrateProvider`).

**Reopened — not yet validated:** host-durable project state. The **guest-side alias reconcile** and
**mount-readiness** above currently exist only as a defective demo-local `set -eu` shell step that raced and
collapsed (as a bare `ExitFailure 1`) on the Windows/WSL2 lifecycle gate; recasting them as the pure
`AliasState` primitive gated by a `Ready` witness is the reopened work. The durable root must then be
carried across the remaining boundaries, created on `up`, and gated by a real capability.

The shape of the remaining work, tracked as open sprints in
[../../DEVELOPMENT_PLAN/phase-5-cluster-lifecycle-and-resource-cordoning.md](../../DEVELOPMENT_PLAN/phase-5-cluster-lifecycle-and-resource-cordoning.md)
and
[../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md):

- the guest-side alias reconcile (pure `AliasState`) and mount-readiness recast as one primitive across the
  VM-shell and direct Linux-GPU lanes, readiness-gated and legible on failure (phase-11 Sprint 11.9); the
  host-side share reconcile it builds on is already landed;
- the durable root carried across the remaining boundaries a nested chain crosses — VM to project
  container, container to kind node, kind node to pod;
- a create-on-`up` path for the durable root;
- `DurableStore` promoted from a declared-but-unread context capability to one a command actually
  requires.

Until a real run writes state, runs `project destroy`, runs `project up`, and reads it back, no
governed document may describe host-durable `.data` as available. See
[../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)
§ J.

## Validation

The removal-set guarantee is proven by the `hostbootstrap-core` test suite, which runs through the
canonical code-check:

- `LifecycleSpec` asserts the pure teardown partition for both the production and test profiles — the
  data path is absent from every removal set and present in every preserve set.
- `LifecycleSpec` also proves it **on disk**: it creates a real `.data` directory and real derived
  directories in a temporary root, then runs the real drivers. After `clusterDown` **both** the data
  path and the derived paths still exist — `down`'s removal set is empty, so it removes nothing. After
  `clusterDelete` the data path still exists while the derived paths are gone.

No test asserts host visibility of `.data`, because no implementation provides it. When the work in
[Current Status](#current-status) lands, its gate is a real run across a destroy/up cycle, not a unit
test — a pure argv or partition test cannot establish that a host path observes guest writes.

## Related

- [../engineering/cluster_lifecycle.md](../engineering/cluster_lifecycle.md) — kind/Helm bring-up and
  teardown as chain steps; the invariant's engineering home.
- [composition_methodology.md](composition_methodology.md) — the chain-is-the-project model that
  decides which frame owns the cluster step.
- [../engineering/gitignore_guardrails.md](../engineering/gitignore_guardrails.md) — why `.data/` and
  `.test_data/` stay out of version control.
- [readiness.md](readiness.md) — the `Ready`-witness discipline that gates the share's mount and alias
  steps, and the legible-failure contract that keeps a share failure from collapsing to `ExitFailure 1`.
