# Durable State

**Status**: Authoritative source
**Supersedes**: the claim that no production code creates `.data` or that durable carry is only planned
**Referenced by**: [readiness](readiness.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [WSL2](../engineering/wsl2.md), [Lima](../engineering/lima.md), [Incus](../engineering/incus.md), [documents index](../README.md)

> **Purpose**: Define canonical host-root authority and its typed durable-path projections, explain the
> current provider-guest alias, state what lives under the durable root and what teardown may remove, and
> name the gates that prove destroy/up/readback.

## TL;DR

- The durable root is `<project-root>/.data` for Production and `<project-root>/.test_data/<runId>` for a
  Harness run.
- Root-config admission resolves `sourceRoot` once into opaque `CanonicalProjectRoot scope rootId`
  authority. Direct-host Docker binds the matching typed canonical path.
- Provider lanes (Incus, Lima, WSL2) carry the durable root into the guest through a provider share and
  expose it at the guest-local alias `/var/tmp/hostbootstrap-demo-data`. The alias is a projection, not the
  store. kind/nvkind and the web pod mount that alias.
- The durable root holds the workload's bytes and also the provider, alias, and cluster ownership records
  (see [what lives under `.data`](#what-lives-under-data)).
- Cluster teardown never removes the durable root or its workload subtree. Cluster Delete removes only the
  plan-owned cluster state leaf beneath it.
- The root lifecycle `ProtectedStore`, catalog, journals, and receipts live outside the durable root and are
  defined in [lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff).

## Current Status

The current demo does create and carry durable state:

```text
host project root/.data
        │ provider share (drvfs, Incus disk device, or Lima mount)
        ▼
Linux environment's substrate-specific mounted path
        │ provider-local guest symlink
        ▼
/var/tmp/hostbootstrap-demo-data
        │ Docker/kind extraMount
        ▼
/var/lib/hostbootstrap-demo-data
        │ pod hostPath
        ▼
/var/lib/hostbootstrap-demo-data/web
```

`/var/tmp/hostbootstrap-demo-data` is not the canonical store or a portable host path. It is a
provider-guest projection used where the Docker daemon runs inside WSL2, Incus, or Lima. On direct
Linux, Docker must receive the canonical absolute host `.data` path; kind/nvkind then projects that
source into the node path. The web pod mounts the final `/web` directory from the kind node.

The canonical host directory is `<project-root>/.data`. Provider setup creates it, carries it into the
VM/container topology, waits for the share, and reconciles the guest alias. The direct Linux GPU lane
instead receives the canonical absolute host directory from root admission; it does not substitute the
guest alias.

Two gaps stand against the target contract in [root authority and alias target](#root-authority-and-alias-target)
and [production and test profiles](#production-and-test-profiles):

- The plan projects only the canonical host durable root. The guest alias, kind-node, and pod paths
  (`/var/tmp/hostbootstrap-demo-data`, `/var/lib/hostbootstrap-demo-data`) are fixed demo constants, not
  projections of the admitted plan.
- Demo cluster, provider, mount, and teardown consumers compute the profile as `clusterProfileOf` of the
  config and the durable root from the filesystem root (for example `runVmUp` and `runCopySource` call
  `ensureProfileDataPath` over the process working directory) rather than taking one exact plan projection.
  The digest check in `demoExactPlanSlices` binds the cluster config consumer's config to the retained plan's
  config digest, but it does not replace those independent derivations.

The [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns those consumers.

### What lives under `.data`

The durable root is not workload-only. The provider, alias, and cluster backends keep their ownership
records beneath it, so copying, restoring, pruning, or hand-editing the durable root also changes those
records. The same layout appears under `.test_data/<runId>` for a Harness run.

| Path under the durable root | Written by | Contents |
|---|---|---|
| `web/` | the web workload, through the pod hostPath | workload bytes; no lifecycle authority |
| `.provider-state/` | the demo's exact provider and share backends | provider and provider-share ownership records |
| `.hostbootstrap-alias-authority-v1` | the guest-alias ownership transaction, from inside the guest | the protected store holding the alias's ownership record; the directory remains after the alias is given back |
| `cluster/<driver>/state/` | the plan-owned cluster backend | cluster ownership, lock, and exposure records, and `cluster.kubeconfig` |
| `cluster/<driver>/config.yaml` | the plan-owned cluster backend | the canonical cluster config, bound by digest to the cluster records |

`<driver>` is `kind` or `nvkind`. The root lifecycle `ProtectedStore` (mode, leases, snapshots, journals,
the reverse-root intent row, and the recovery-open map rows) is not under the durable root: it lives at
`<project-root>/.hostbootstrap/authority/<project>`. The root prepares and settles durable frame operations
and sends only signed, bounded rooted responses; children return observations and receipt confirmations,
never raw record keys or versions. The share and alias carry workload bytes and the backend records above,
never that root store.

## What is implemented

- `HostPathShare`/`ShareReconcile` describe the provider-specific host-to-guest carry.
- A harness run's two owned host-local objects — its `.test_data/<runId>` generation and its generated
  sibling `<project>.dhall` — record their ownership as the **one canonical `OriginRecord`** in the
  protected store, under one record key each. The encoding is a single fixed line carrying the record
  version, the kind, the prior identity-or-absence, the intended payload digest for a file, and the bound
  identity, so a record either owner writes is readable by the other and a version tag means one thing.
  The record is published before the object exists and the identity binding is a second compare-and-swap
  against the exact version the publication left, so the window between them is a durable state recovery
  reads rather than a state it has to guess at.
- WSL2 uses the host drive exposed by drvfs, Incus attaches a disk device, and Lima declares a mount.
- `HostBootstrap.Substrate.Provider.Reconcile` settles provider shares into an opaque nominal
  `ManagedProviderShareHandle` that retains the exact managed provider origin. A share is an owned object
  of its own: the prepared Incus backend publishes its origin record through the protected store before
  the device is attached and binds the device's identity — a digest of exactly the kind, source, and
  target the declaration names — from what the provider reports afterwards, under the instance standing
  re-taken on both sides of that readback. Direct settles only the canonical already-local identity share.
- Durability at that boundary is inherited rather than restated: every durable byte a provider transaction
  publishes is the protected store's compare-and-swap, so the partial-write and partial-unlink windows are
  the store's own contract and the provider driver names no mutating filesystem primitive.
- `HostBootstrap.Substrate.Provider.Alias` consumes that managed share together with the exact opaque
  managed Running provider, and runs the alias's take and give-back as one shipped ownership transaction
  (`guestAliasOwnershipTransaction` over `HostBootstrap.Ownership.Shipped`) whose single durable record
  recovers every crash window without adopting an exact-looking pathname (see
  [root authority and alias target](#root-authority-and-alias-target)). The demo's `runExactVmShare` retains both managed authorities inside
  `withProviderShareSettlement`, derives a fresh provider capability, and narrows it through
  `discoverStrongAliasBackend` for `reconcileNodeGuestAlias` before registering the share's runtime
  dependency.
- The demo's `copy-source` action chooses its alias route by provider. Incus and Lima run only the managed
  route (`runExactVmShare`). WSL2 first runs the compatibility route (`reconcileShippedDurableAlias`, which
  waits for the share, probes it mounted and writable, and runs the shipped alias ownership transaction
  directly) and then the managed route. Both routes reach the alias through the same shipped ownership row
  and the same authority record; the per-backend view is canonical in
  [ownership invariant](ownership_invariant.md#per-backend-clause-matrix).
- Provider and direct-host paths create the host durable root. Provider guests establish
  `/var/tmp/hostbootstrap-demo-data`; the direct-host Docker handoff consumes the typed canonical path.
- Root lifecycle frame/teardown callbacks receive `CanonicalProjectRoot scope rootId` separately from
  `BinaryContext`, and the host-mount adapter accepts only a `CanonicalHostPath` carrying the same
  indices.
- `teardownPlan` consumes the exact `ProjectPlan` and its already admitted `CurrentFrame`, then projects
  that frame and its descendants deepest-first and in reverse forward order within each frame. Its
  `TeardownPlan scope planId frame verb` retains the plan's stable step identities, operation keys,
  reverse policies, and declared callbacks without running them.
- `openTeardownForest` consumes that projection alone. Its forest, progress, authorization branches,
  closed local/descent work, successors, completion, and settled-destroy proof retain the projection's
  nominal `frame` index. Only `LocalWork` exposes a declared reverse runner; existential `DescentWork`
  exposes only the exact immediate topology edge, and branch-specific attempts retain their origin forest.
  The forest itself authorizes nothing; effects are authorized by the root's rooted frame execution and
  receipt-bound release (see [lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff)).
- Project-container, kind/nvkind, and pod configurations carry the directory to the web workload.
- Cluster teardown never puts the durable root or a workload subtree in its filesystem removal set. Down
  removes nothing and preserves both the data path and the derived state path. Delete removes only the
  derived state path. For a plan-owned cluster that path is the state leaf
  `<durable root>/cluster/<driver>/state`, beneath the durable root; a plan resolved without plan ownership
  (`resolvePlanWithDriver`) uses `<project-root>/.cluster/<cluster name>`, outside it.
- The closed cluster backend keeps its ownership metadata in that plan-derived state leaf, inside the
  durable root, with `config.yaml` beside it. Component-wise no-follow traversal creates and parent-fsyncs
  only that exact leaf. Self-bound `prepared`/`executing`/`managed` origin records retain the state, lock,
  record, config/kube snapshot, and complete node-container identities needed for crash recovery and
  conditional cleanup. Cleanup (`releaseRetainedCluster` and the prepared cleanup call) opens only the store
  at that leaf, derived from the plan, and removes the managed origin only after independently proving every
  retained node container absent. A copied record, replaced namespace object, or uncertain deletion preserves
  origin state and cannot widen the removal set beyond the leaf. Because the leaf sits inside the durable
  root, editing or restoring the durable root edits the records `releaseRetainedCluster` reads.
- The same removable state leaf carries the cluster-adjacent exposure record. Its pending state precedes
  relay creation and binds the exact plan resource, cluster identity/generation, immutable image, semantic
  targets, owner digest, and fresh operation nonce. Its managed successor adds only the runtime-inspected
  relay identity and complete loopback mapping set. Recovery re-inspects those exact facts; release removes
  by identity, proves absence, and only then deletes the record. Cluster cleanup refuses while the exposure
  record exists, so the durable host root and the release order remain outside caller discretion.
- The implemented direct-Colima adapter likewise keeps control ownership outside the workload payload. Its
  self-bound origin and isolated `DOCKER_CONFIG` live under the exact plan root's `.hostbootstrap/colima`
  state leaf, while one 128-bit plan/lifecycle token names the isolated Colima/Lima/cache/temp home and
  reusable lock beneath the effective user's home. Before either named namespace is created, the origin
  records absence and a fresh nonce. Managed state retains both namespace identities, the 20-GiB-root plus
  `total-20`-GiB-data wall, stable machine/context, and the complete directory/artifact manifest. Separately
  journaled cleanup enters `releasing` before `colima delete --force --data` and may remove only the exact
  manifest-listed namespaces after proving profile/data/context absence. Outcome-unknown, replaced, or
  foreign state retains its evidence and cannot widen cleanup to `.data` or another project namespace. This
  source boundary and the [cluster-lifecycle, budgets, and cordoning
  phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) gates are closed. Recursive adoption
  remains in the [recursive-lifecycle-command
  phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md), while the
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns its concrete consumer.
- The one root `project up` entry persists the recursive plan catalog. After the acquisition journal
  revalidates the live global lease, protected snapshot, and plan digest, the entry admits the catalog and
  compare-and-swaps one bounded canonical manifest under a record identity naming the root plan's installed
  project, stable profile, and broker epoch. That identity is encoded through the store's own injective
  record-name encoding, so a Harness profile — which names its run — addresses its own record rather than an
  illegal key. The manifest length-frames every variable-width value, counts every list, refuses rather than
  truncates at both an admitted-edge and a byte ceiling, and carries digests instead of any raw configuration
  payload. An exact retry and a compare-and-swap loser both converge on the record already present because the
  decision comes from the strict readback; conflicting bytes refuse before the command reservation and before
  any lifecycle effect.
- One root-owned frame session row exists per admitted catalog frame, keyed by root lineage, catalog
  identity, and frame alone, so no part of a request can select which row is addressed. The opened row frames
  the root-selected requester path, opaque session token, fixed stage, and first nonzero ordinal, and carries
  no predecessor-response digest, because at that point nothing has been answered. Its attached successor
  nests the exact opened bytes with the admitted nonce and the lowercase SHA-256 digest of the complete signed
  `Opened` response, and the compare-and-swap consumes exactly the opened version the caller read back. An
  exact replay returns the attached version already present without a second mutation; anything that is
  neither the exact opened row nor the exact attached row refuses.
- A recoverable reverse edge keeps its handoff token in one root-store map row, because the token is fresh
  random bytes and cannot be recomputed from its binding. `registerRecoverableAdmittedHandoffEdgeKernel` keys
  the row `recovery-open.<digest>` by the digest of a framed `hostbootstrap/recovery-open-map` identity
  (project, scope, store, broker epoch, verb, verification-key digest, binding input, and adapter). The row's
  version-1 `hostbootstrap/recovery-open-record` bytes frame that identity, the rendered binding, and the
  token. The first registration mints the token once and publishes the row by an absent-only
  compare-and-swap (`ExpectAbsent`) with a readback at version 1; a later registration reuses the token from
  the row, and when the planned-edge token record is already `granted:` it rotates the row by
  compare-and-swap to a fresh token. The state table is canonical in
  [lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff).

Together these facts make `.data` host-carried state rather than frame-relative guest state.

### The reverse-root terminal row

The Production reverse-root intent row lives in the root lifecycle store, not under the durable root; it is
described here because its retained terminal form is what lets a durable Down be followed by a Destroy or a
fresh Up. The verb-level transitions are canonical in
[lifecycle state model](lifecycle_state_model.md#typed-lifecycle-transitions).

Pending publishes the exact successful-Up source coordinates; Committed adds the sole successor broker, mode,
and bound-lease bytes; Terminal preserves that complete descriptor after the exact root subtree and
independently enumerated frame sessions have all settled. Down requires the root `SubtreeSettled` proof.
Destroy additionally requires the unique-root `DestroySettled` proof. Committed-to-Terminal is one
compare-and-swap followed by an exact version-and-bytes readback, and an exact Terminal retry performs no
mutation. Ordinary admission recognizes Terminal as settled, but Pending and Committed remain exclusive
owners.

| Row versions | Written by | Next |
|---|---|---|
| 1, 2, 3 (Pending, Committed, Terminal) | the first reverse verb (Down or Destroy) from the source lineage | Destroy continuation (after a Down terminal), fresh Up, or reverse rearm |
| 4, 5, 6 (Destroy Pending, Committed, Terminal) | a Destroy continuing a settled Down: it verifies the version-3 Down terminal against the current mode, lease, snapshot, source rows, and closed sessions, allocates one fresh Destroy broker generation, and advances the same row | fresh Up |

Two paths delete a terminal row, and they accept different versions:

| Path | When it runs | Accepts | Readback |
|---|---|---|---|
| Fresh Up, in run-lease admission | an Up rebinds the closed Production lease; this is the ordinary path after any Down or Destroy | a terminal at version 3 (Down or Destroy) or version 6 (Destroy), whose broker generation is strictly older than the new one; anything else refuses as a reverse root in progress | compare-and-delete at the observed version, with no separate absence readback |
| Reverse rearm, in reverse admission | a reverse verb finds a terminal row still present after its new successful-Up lease, snapshot, acquisition row, teardown cursor, and closed session set are revalidated | only a version-3 terminal (Down or Destroy) with matching project and store coordinates and a strictly newer broker generation; a version-6 row refuses | compare-and-delete followed by a strict absence readback, then the next Pending row through the normal absent-only path |

A stale lease cannot rearm, and a crash after terminal consumption is safe because the independently durable
new Up source can recreate the absent Pending row.

## Durability boundaries

The carry and its same-run protocol are implemented:

- Production and Harness reverse traverse the admitted recursive plan child-first and settle exact teardown
  evidence before a terminal close can be authorized.
- The provider/share operation owns the guest mount, and the guest alias holds the four ownership clauses over
  the Docker-daemon-visible durable path. Down retains that exact alias and its ownership row across provider
  stop/restart; Destroy gives it back after child teardown. Kind/nvkind projects that alias into the node and pod.
- Chart and standalone service placements use signed immutable activation revisions whose durable directories
  are mounted into their exact runtime frames.
- Each Harness variant retains one exact plan and `.test_data/<runId>`. `AssertAcrossRestart` places the durable
  write/read pair around a settled destroy, protected fresh broker generation, exact snapshot rebind, and
  second forward; stable released resource members admit only a strictly newer owned generation.

Live confirmation remains substrate-specific evidence. The worked-demo phase records linux-cpu, while the
Apple, NVIDIA, and Windows acceptance phases record the same invariant through their declared providers.

## Root authority and alias target

Root-config admission resolves relative `sourceRoot` against the stable project-home anchor owned by the
selected root config—not caller `cwd` or the executable's sibling `.build` directory—then verifies and
canonicalizes it once. Its rank-2 `CanonicalProjectRoot scope rootId` retains the exact config/lifecycle
`scope` already in force and mints only the fresh `rootId`; it is the only source of direct-host durable
paths. `CanonicalHostPath` construction is private, and the host-bind adapter requires the root
and path to carry the same `scope`/`rootId`; raw `FilePath`, redirected roots, and cross-root projections
are rejected.

`ProjectPlan` admission retains the canonical root under the exact lifecycle scope, and its pure reverse
projection preserves the same plan and frame identities. The target contract derives every durable-path
boundary projection — guest alias, container, kind node, and pod — under that same identity; today only the
host durable root is projected (see [current status](#current-status)).

Alias reconciliation remains necessary only for provider guests. It is a typed projection operation,
not root discovery or authority.

[`HostBootstrap.Substrate.Provider`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs)
exports a total diagnostic classifier. `classifyAlias` maps the probed facts to an `AliasState`, and
`planAliasEnsure`/`planAliasRemove` turn that state into a pure ensure or removal view. None of the three
authorizes mutation or cleanup; they name the cases:

| `AliasState` | Ensure view | Removal view |
|---|---|---|
| `AliasAbsent` | create the link | keep (already absent) |
| `AliasLinkedCorrectly` | leave linked | unlink, subject to ownership proof |
| `AliasLinkedElsewhere` with the observed target | refuse | refuse |
| `AliasOccupied` with an `AliasNodeKind` | refuse | keep the occupant |

The production entry is `reconcileNodeGuestAlias` in
[`HostBootstrap.Substrate.Provider.Alias`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs).
It takes the step execution, the strong alias backend, the planned provider with its managed `Running`
handle, and the planned `DurableShareResource` with its managed `Provisioned` share handle, and refuses with
a `Conflict` when either handle's key differs from its planned resource. Through the plan, it traverses the
alias node's exact `PlannedEdge` to the durable share, uses the managed mounted-share handle, and runs the
share's readiness probe at prepare time. The caller cannot supply or omit the edge or substitute a retained
`Ready`. `withOperationPreconditions` seals that fresh observation into the alias operation's closed
`OperationPreconditionSet`. `withPreparedOperation` runs no second probe: it checks that the prepare gate,
the sealed set, and the operation descriptor name the same plan, operation, and call digest, that no sealed
observation is stale, and that the observed dependency keys are exactly the expected ones, and only then
returns the only `PreparedOperation`/`PreparedPreconditions` pair the alias backend adapter accepts.

The reconcile kernel (`completeReconcile`, or `completePreparedUnchanged` over a prior commit proof) takes
an `Unclassified` handle in the `Observed` phase and returns a `ReconcileResult` in the `Provisioned` phase
for the `DurableAliasResource`. `settlePreparedGuestAliasCall` maps the shipped transaction's answer onto it:
a link the call created settles `ManagedResult` with `Created`; a later call for the same alias path and
target that finds the exact link its record already bound settles `Unchanged` when the caller passes the
`PriorCommitProof` of an earlier settlement and `Repaired` without one; conflicts report the expected and
observed identity. `reconcileNodeGuestAlias` passes no prior proof, so a rerun of the node route over the
link it created settles `Repaired`. An exact-looking link with no record returns `ForeignResult` with an
`Unmanaged` handle, not mutation/deletion authority. `reconcileNodeGuestAlias` surfaces those outcomes as
`GuestAliasReconciled` with its `ChangeView` or `GuestAliasForeignRetained` with its `ForeignObservation`. Destructive cleanup requires the managed handle and matching opaque ownership
receipt; it never removes an alias merely because its pathname matches. An IO or probe failure is a
`Failure` in `ReconcileError`, not an alias state.
Alias reconciliation may mint a receipt only when the backend holds all four
[ownership invariant](ownership_invariant.md) clauses. The three provider guests are built from different
artifacts (an Incus image, a Lima template, a WSL2 distribution) but run the same Linux distribution
release, Ubuntu 24.04, and the same shipped project binary, so the same row serves WSL2, Lima, and Incus —
which is why the frame axis has three constructors and the ownership row set has two platforms plus one
transport, rather than one implementation per provider. Clause support still depends on the filesystem
behind each share (drvfs on WSL2, the Incus disk device, the Lima mount), which is why
[validation](#validation) runs the alias gate on every provider guest. Provider discovery executes closed requests, accepts only raw outcomes, and
privately parses exact one-line tool/marker/identity reports; its fresh capability is indexed to the exact
opaque managed provider resource/backend/generation. The alias backend narrows that capability without
accepting an independent executor and also requires the exact opaque managed share authority.

The alias's clauses are the row's, so which lock front end a particular guest happens to carry is not a
question the protocol asks: a transaction addressed to that frame is carried to a process of this same
binary there, and that process takes the kernel lock itself (see [ownership seam](ownership_seam.md)).
Establishing the binary in the guest is the precondition, and the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns it.

The transaction (`ShipTakeSymbolicLink` to take, `ShipGiveBackSymbolicLink` to give back, in
[`HostBootstrap.Ownership.Shipped`](../../core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs))
opens the protected store at `<target>/.hostbootstrap-alias-authority-v1` inside the host-backed share and
runs wholly inside that store's exclusive entry, which the project binary in the guest takes itself; that
entry is the alias's clause 1, and no guest `flock` or other lock front end participates. It addresses one record, keyed by a digest of the alias path
and its target, that claims the link target and records an absent origin:

- A first take, finding no record and no alias, publishes that unbound record, creates a staging symlink
  beside the alias path (named from the record key), binds the staging link's exact device/inode into the
  record, publishes the link at the alias path without replacement, and removes the staging name.
- A take that finds a record resumes it: an unbound record restarts the binding, a bound record whose alias
  is absent publishes the staged link, and a bound record whose alias is the exact bound link is retained.
  Any other occupant refuses as a conflict with expected and observed identity.
- Give-back re-observes the bound identity, removes only that exact link, and then forgets the record. A
  give-back that finds the alias already absent forgets the record; any other occupant refuses and the
  record stays. The store directory itself stays in the share.

No guest-local pathname sidecar or exact-looking path can mint ownership. A guest that cannot supply a clause returns `Unsupported` and mints no receipt. The
[ownership clauses and reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)
owns the protocol, and the
[host providers and self-reference lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the provider-guest backend and integration.

The broader capability and ownership contract is defined in
[lifecycle_state_model](lifecycle_state_model.md).

The service-runtime target derives durable-store use from the selected closed program's effect row and
packages it only with a matching `VerifiedServicePlacement` proof and opaque durable-placement authority. A
late handler-specific config reload cannot mint or widen that authority.

## Production and test profiles

The demo's descriptive `RunProfile` config field selects one of two profiles, and `clusterProfileOf`
projects it onto the core's `ClusterProfile`:

| `RunProfile` | `ClusterProfile` | Durable root | Cluster identity |
|---|---|---|---|
| `ProductionRun` | `Production` | `.data` | fixed project production name |
| `HarnessRun runName` | `TestCase runName` | `.test_data/<runName>` | run-scoped Harness name |

The Harness command admits an exact `ProjectPlan (Harness projectId runId) ...`, and generic harness
ownership helpers manage `.test_data/<runId>`. Demo cluster, provider, mount, and teardown consumers reread
`RunProfile`/`ClusterProfile` and filesystem-root terms independently rather than taking one exact plan
projection; [current status](#current-status) records that gap.

The authority foundation is the opaque, scope-indexed `LifecycleProfile` in
[lifecycle_state_model](lifecycle_state_model.md): the production gate can mint only Production
authority, and the harness can mint only `Harness projectId runId`. `withProjectPlan` consumes that profile
and a scope-matching config. The target contract makes the cluster identity and durable root one projection
of the resulting plan, so an independent config term cannot silently redirect a consumer.

## Teardown guarantee

The pure reverse surface makes preservation a plan-owned structural guarantee: a
`PreserveOnReverse` node is absent from both verb-indexed projections, and every projected node retains
the stable identity and operation key of its forward node. This says which work is scheduled; it neither
proves ownership nor authorizes a filesystem effect. The narrow live guarantee is that cluster teardown's
filesystem removal set never contains the plan's data path itself or any workload subtree; for a plan-owned
cluster, Delete does remove the `cluster/<driver>/state` leaf beneath the data path, so a workload must not
write there. Those guarantees do not by themselves prove:

- that the path is the host path;
- that every enclosing frame preserves the share;
- that a destroy/up cycle reattaches it correctly; or
- that the test harness avoids production state.

Those claims are proved by the validation gates below.

## Validation

Each gate names the phase whose declared gate exercises it; whether that gate has passed, and on which host,
is recorded in the phase file and summarized in [the development-plan index](../../DEVELOPMENT_PLAN/README.md),
not here.

| Gate | Owning phases |
|---|---|
| 1 | [host providers and the lift](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) for the suite; live on Incus in [the worked demo](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), on Lima in [Apple Silicon](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md), on WSL2 in [Windows and WSL2](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md) |
| 2 | [ownership clauses and reservations](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md) |
| 3 | [host tools and substrate detection](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md) |
| 4 | direct host in [NVIDIA GPU](../../DEVELOPMENT_PLAN/phase-27-nvidia-gpu-substrate.md); provider projections in [host providers and the lift](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) |
| 5 | [cluster lifecycle and cordoning](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md), for both the suite and the live sentinel gate |
| 6 | [the worked demo](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) on linux-cpu, and the [Apple Silicon](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md), [NVIDIA GPU](../../DEVELOPMENT_PLAN/phase-27-nvidia-gpu-substrate.md), and [Windows and WSL2](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md) acceptances |
| 7 | [test harness and run ownership](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) |
| 8 | [recursive lifecycle command](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) |

1. Each provider-guest clean-path test reaches `AliasAbsent`, creates the link (`Created`), and reruns over
   that link: with the first settlement's prior commit proof the rerun settles `ManagedResult` with
   `Unchanged`, and without one it settles `Repaired`. This runs on **every** provider guest —
   WSL2, Lima, and Incus — because one backend serves all three.
2. Wrong-link, occupied-node, permission, and unexpected IO failures are reported without partial
   filesystem exceptions. A run killed between the durable origin record and the link creation is
   recoverable, including the case where the alias path was originally **absent**: the next run
   restores absence rather than adopting what the killed run left behind. An alias replaced by a
   same-privilege process between observation and mutation is reported as `Conflict` with
   expected/observed identity, is not clobbered, and mints no receipt; release is refused on identity
   mismatch. See [ownership_invariant](ownership_invariant.md) § Validation for the full clause suite.
3. Root-resolution tests are independent of process `cwd`; missing, wrong-kind,
   escaping, and redirected roots fail before the callback, and compile-fail tests prevent raw or
   cross-root paths from entering direct-host bind operations.
4. Native direct-host Linux reaches Docker with the canonical absolute nonsymlink host `.data` path, and
   provider guest projections derive from the same admitted canonical root and exact share.
5. The independent exact-cluster suite creates only the plan-derived removable state leaf beneath the
   durable root, rejects symlink/copied/replaced state, lock, record, and snapshot objects, conditionally
   removes only exact owned node IDs, and proves cleanup never removes the durable root or anything outside
   that leaf. The separate linux-cpu live gate (`test run cluster-live`) keeps a sentinel in the run's
   durable root outside the cluster state leaf and re-reads it byte-identical after deletion.
6. Every supported native substrate writes a unique value through the pod-mounted `/web` path, destroys
   the stack, recreates it, and reads the value from both host and pod.
7. `test run all` proves its cluster name is test-scoped and that neither `.data` nor the production
   cluster is observed or mutated.
8. Recursive teardown visits the child cluster/container before stopping or deleting its provider frame.

## Related

- [lifecycle state model](lifecycle_state_model.md) — typed transitions, opaque readiness and ownership,
  total probes, and recursive teardown.
- [ownership invariant](ownership_invariant.md) — the four clauses the alias backend must hold before it
  may mint a cleanup receipt.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/Helm operations.
- [harness workflow](harness_workflow.md) — current test-profile and DSL mismatch.
- [gitignore guardrails](../engineering/gitignore_guardrails.md) — keeping `.data/` and `.test_data/`
  outside version control.
