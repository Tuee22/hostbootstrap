# Durable State

**Status**: Authoritative source
**Supersedes**: the claim that no production code creates `.data` or that durable carry is only planned
**Referenced by**: [readiness](readiness.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [WSL2](../engineering/wsl2.md), [Lima](../engineering/lima.md), [Incus](../engineering/incus.md), [documents index](../README.md)

> **Purpose**: Define canonical host-root authority and its typed durable-path projections, explain the
> current provider-guest alias, and record how far destroy/up/readback is proved.

## TL;DR

Root-config admission now resolves descriptive `sourceRoot` once into opaque
`CanonicalProjectRoot scope rootId` authority without rewriting the descriptive context. Direct-host
Docker binds the matching typed canonical `.data` projection; provider lanes continue to use
`/var/tmp/hostbootstrap-demo-data` only as a guest-local projection. The opaque `ProjectPlan` now derives
a pure, frame-indexed reverse projection from the exact admitted `CurrentFrame`; stable step identities,
operation keys, reverse policies, and declared callbacks come from that same plan, and preserved nodes
are omitted for both verbs. Production dispatch retains or reconstructs the exact plan/current-frame pair
and consumes this projection directly. It grants no receipt, journal, exact teardown command, or effect
authority. The core provider route now has opaque managed provider/share/alias authority and a
crash-recoverable four-clause guest-alias backend, but the demo still uses its compatibility pathname
call site. The plan still has to carry all guest, container, kind-node, and pod path projections.
The workload `.data` carry is distinct from lifecycle authority storage. In the target rooted runtime, one
root coordinator process owns
the only lifecycle `ProtectedStore`, global lease/snapshot/acquisition, recursive `RootedPlanCatalog`, and
per-frame journals. A child process is a storeless `FrameExecutor` that receives only an exact root-prepared
node grant. The root catalog structurally retains each target plan/config/current-frame relation and all store
authority; rooted `ReceiptConfirm`/`ReceiptRecorded` mutates Published/Received only at the root. The terminal
owner that joins them names no `ProtectedStore`: publishing the exact canonical report and advancing Published
to Received both arrive as continuations from the relay that already holds the hidden recovery signing
admission, and the exact digest of the complete signed `FrameComplete` bytes is the only thing a
`ReceiptConfirm` can name a terminal report with. The
reverse replay path is likewise read-only: it reauthorizes and rereads the exact version-two Bound descent
under its live teardown cursor, then requires the exact version-three parent Adopted row derived from the
same binding, report, and canonical acknowledgement. Only after both protected entries close does the shared
semantic proof producer run. Rehydration performs no compare-and-swap and reopens no token map, child process,
or local effect. The
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
owns the closed wire vocabulary and the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) consumes
it. The [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the live same-run
destroy/up/readback acceptance.

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

Neither path transports lifecycle authority. The root prepares and settles durable frame operations and sends
only signed, bounded rooted responses; children return observations and receipt confirmations, never raw
record keys or versions.

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
  managed Running provider. Its `prepared`, `managed`, and version-fenced `releasing` records recover
  origin publication, alias publication, and conditional release crash windows without adopting an
  exact-looking pathname.
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
  The forest remains non-authorizing; rooted frame execution and receipt-bound release remain later lifecycle
  work.
- Project-container, kind/nvkind, and pod configurations carry the directory to the web workload.
- Cluster teardown excludes its configured data path from its filesystem removal set.
- The closed cluster backend keeps ownership metadata in the plan-derived removable state leaf, never in or
  above the durable root. Component-wise no-follow traversal creates and parent-fsyncs only that exact leaf.
  Self-bound `prepared`/`executing`/`managed` origin records retain the state, lock, record, config/kube
  snapshot, and complete node-container identities needed for crash recovery and conditional cleanup.
  Cleanup receives no durable-root pathname and removes the managed origin only after independently proving
  every retained node container absent. A copied record, replaced namespace object, or uncertain deletion
  preserves origin state and cannot widen the removal set.
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
- The one root `project up` entry now persists the recursive plan catalog. After the acquisition journal
  revalidates the live global lease, protected snapshot, and plan digest, the entry admits the catalog and
  compare-and-swaps one bounded canonical manifest under a record identity naming the root plan's installed
  project, stable profile, and broker epoch. That identity is encoded through the store's own injective
  record-name encoding, so a Harness profile — which names its run — addresses its own record rather than an
  illegal key. The manifest length-frames every variable-width value, counts every list, refuses rather than
  truncates at both an admitted-edge and a byte ceiling, and carries digests instead of any raw configuration
  payload. An exact retry and a compare-and-swap loser both converge on the record already present because the
  decision comes from the strict readback; conflicting bytes refuse before the command reservation and before
  any lifecycle effect.
- One root-owned frame session row now exists per admitted catalog frame, keyed by root lineage, catalog
  identity, and frame alone, so no part of a request can select which row is addressed. The opened row frames
  the root-selected requester path, opaque session token, fixed stage, and first nonzero ordinal, and carries
  no predecessor-response digest, because at that point nothing has been answered. Its attached successor
  nests the exact opened bytes with the admitted nonce and the lowercase SHA-256 digest of the complete signed
  `Opened` response, and the compare-and-swap consumes exactly the opened version the caller read back. An
  exact replay returns the attached version already present without a second mutation; anything that is
  neither the exact opened row nor the exact attached row refuses.

Together these facts make `.data` host-carried state rather than frame-relative guest state.

The Production reverse-root row has a retained terminal form. Pending publishes the exact successful-Up
source coordinates; Committed adds the sole successor broker, mode, and bound-lease bytes; Terminal preserves
that complete descriptor after the exact root subtree and independently enumerated frame sessions have all
settled. Down requires the root `SubtreeSettled` proof. Destroy additionally requires the unique-root
`DestroySettled` proof. Committed-to-Terminal is one compare-and-swap followed by an exact version-and-bytes
readback, and an exact Terminal retry performs no mutation. Ordinary admission recognizes Terminal as settled,
but Pending and Committed remain exclusive owners.

A later reverse invocation may rearm the project only after its new successful-Up root lease, protected
snapshot, acquisition row, teardown cursor, and closed session set have all been revalidated. At that point the
fresh reverse admission accepts only the exact version-three Terminal row, proves its project/store coordinate
and that the new broker generation is strictly newer, compare-and-deletes that retained terminal with strict
absence readback, and publishes the next Pending row through the normal absent-only path. A stale lease cannot
rearm, and a crash after terminal consumption is safe because the independently durable new Up source can
recreate the absent Pending row.

## Durability boundaries

The carry and its same-run protocol are implemented:

- Production and Harness reverse traverse the admitted recursive plan child-first and settle exact teardown
  evidence before a terminal close can be authorized.
- The provider/share operation owns the guest mount, and the guest alias holds the four ownership clauses over
  the Docker-daemon-visible durable path. Kind/nvkind projects that alias into the node and pod.
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

Current `ProjectPlan` admission retains the canonical root under the exact lifecycle scope, and its pure
reverse projection preserves the same plan and frame identities. Deriving all remaining durable-path
boundary projections under that identity is still target work.

Alias reconciliation remains necessary only for provider guests. It is a typed projection operation,
not root discovery or authority.

The target classifier is total:

```haskell
data AliasState
  = AliasAbsent
  | AliasLinkedCorrectly
  | AliasLinkedElsewhere FilePath
  | AliasOccupied NodeKind
```

The plan's dependency-snapshot transition internally traverses the alias descriptor's exact
`PlannedEdge scope planId aliasId DurableAlias shareId DurableShare DurableShareMounted`, looks up the
managed mounted-share handle, and runs the plan-owned probe. The caller cannot supply or omit the edge or
substitute a retained `Ready`. The plan seals that fresh observation into the alias operation's closed
`OperationPreconditionSet`; prepare reruns the probe and identity/version checks and jointly returns the
only `PreparedOperation`/`PreparedPreconditions` pair the alias backend adapter accepts.
It returns `ReconcileResult scope planId aliasId DurableAlias Observed to`. The public entry accepts only an
unclassified handle in the `Observed` phase. It creates only `AliasAbsent`, returns
`ManagedResult Unchanged` only for a correctly linked alias with a verified receipt, and reports the
observed target/node on conflicts. A correctly linked foreign alias returns `ForeignResult` with an
`Unmanaged` handle, not mutation/deletion authority. Destructive cleanup requires the managed handle and
matching opaque ownership receipt; it never removes an alias merely because its pathname matches. IO
failure is `ProbeFailed`/`Failure` in the probe/reconcile error sum, not an alias state.
Alias reconciliation may mint a receipt only when the backend holds all four
[ownership invariant](ownership_invariant.md) clauses. Because all three provider guests run the same
Linux image, the same row satisfies them identically on WSL2, Lima, and Incus — which is why the frame
axis has three constructors and the ownership row set has two platforms plus one transport, rather than one
implementation per provider. Provider discovery executes closed requests, accepts only raw outcomes, and
privately parses exact one-line tool/marker/identity reports; its fresh capability is indexed to the exact
opaque managed provider resource/backend/generation. The alias backend narrows that capability without
accepting an independent executor and also requires the exact opaque managed share authority.

The alias's clauses are the row's, so which lock front end a particular guest happens to carry is not a
question the protocol asks: a transaction addressed to that frame is carried to a process of this same
binary there, and that process takes the kernel lock itself (see [ownership seam](ownership_seam.md)).
Establishing the binary in the guest is the precondition, and the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns it.

Under that retained lock, the backend publishes a fresh-nonce explicit-absence `prepared` record inside
the host-backed target, fsyncs and reads it back, atomically publishes a nonce staging symlink without
replacement, and binds the symlink's exact device/inode before publishing `managed`. Conditional release
first publishes a version-fenced `releasing` record, then re-observes the identity and retains the record
on conflict. Retries finish exact partial staging/publication, resume the recorded state, and durably prove
record/alias absence before success. No guest-local pathname sidecar or exact-looking path can mint
ownership. A guest that cannot supply a clause returns `Unsupported` and mints no receipt. The
[ownership clauses and reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)
owns the protocol, and the
[host providers and self-reference lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the provider-guest backend and integration.

The broader capability and ownership contract is defined in
[lifecycle_state_model](lifecycle_state_model.md).

The service-runtime target derives durable-store use from the selected closed program's effect row and
packages it only with a matching `ServiceSelection` proof and opaque durable-placement authority. A
late handler-specific config reload cannot mint or widen that authority.

## Production and test profiles

The demo's descriptive run profile can select:

| Profile | Durable root | Cluster identity |
|---|---|---|
| Production | `.data` | fixed project production name |
| `HarnessRun runId` | `.test_data/<runId>` | run-scoped Harness name |

The Harness command admits an exact `ProjectPlan (Harness projectId runId) ...`, and generic harness
ownership helpers manage `.test_data/<runId>`. Demo cluster, provider, mount, and teardown consumers still
reread `RunProfile`/`ClusterProfile` and filesystem-root terms independently rather than taking one exact
plan projection. The
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that remaining adoption.

The authority foundation is the opaque, scope-indexed `LifecycleProfile` in
[lifecycle_state_model](lifecycle_state_model.md): the production gate can mint only Production
authority, and the harness can mint only `Harness projectId runId`. `withProjectPlan` consumes that profile
and a scope-matching config. The worked-demo adoption makes the cluster identity and durable root one
projection of the resulting plan, so an independent config term cannot silently redirect a consumer.

## Teardown guarantee

The pure reverse surface now makes preservation a plan-owned structural guarantee: a
`PreserveOnReverse` node is absent from both verb-indexed projections, and every projected node retains
the stable identity and operation key of its forward node. This says which work is scheduled; it neither
proves ownership nor authorizes a filesystem effect. The narrow live guarantee remains that cluster
teardown does not include the plan's data path in its filesystem removal set. Those guarantees do not by
themselves prove:

- that the path is the host path;
- that every enclosing frame preserves the share;
- that a destroy/up cycle reattaches it correctly; or
- that the test harness avoids production state.

Those claims require the live validation gates below.

## Validation gates

1. Each provider-guest clean-path test reaches `AliasAbsent`, creates the link, and reruns to
   `ManagedResult Unchanged` with the same verified receipt. This runs on **every** provider guest —
   WSL2, Lima, and Incus — because one backend serves all three.
2. Wrong-link, occupied-node, permission, and unexpected IO failures are reported without partial
   filesystem exceptions. A run killed between the durable origin record and the link creation is
   recoverable, including the case where the alias path was originally **absent**: the next run
   restores absence rather than adopting what the killed run left behind. An alias replaced by a
   same-privilege process between observation and mutation is reported as `Conflict` with
   expected/observed identity, is not clobbered, and mints no receipt; release is refused on identity
   mismatch. See [ownership_invariant](ownership_invariant.md) § Validation for the full clause suite.
3. **Passed 2026-07-25:** root-resolution tests are independent of process `cwd`; missing, wrong-kind,
   escaping, and redirected roots fail before the callback, and compile-fail tests prevent raw or
   cross-root paths from entering direct-host bind operations.
4. **Direct half passed:** native Linux reached Docker with the canonical absolute nonsymlink host
   `.data` path. Final plan-indexed provider guest projections remain open.
5. The independent exact-cluster suite creates only the plan-derived removable state leaf, rejects
   symlink/copied/replaced state, lock, record, and snapshot objects, conditionally removes only exact owned
   node IDs, and proves the durable root is not an input to cleanup. The separate linux-cpu live gate keeps a
   sentinel outside cluster teardown and re-reads it after deletion.
6. Every supported native substrate writes a unique value through the pod-mounted `/web` path, destroys
   the stack, recreates it, and reads the value from both host and pod.
7. `test run all` proves its cluster name is test-scoped and that neither `.data` nor the production
   cluster is observed or mutated.
8. Recursive teardown visits the child cluster/container before stopping or deleting its provider frame.

Validation status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [lifecycle state model](lifecycle_state_model.md) — typed transitions, opaque readiness and ownership,
  total probes, and recursive teardown.
- [ownership invariant](ownership_invariant.md) — the four clauses the alias backend must hold before it
  may mint a cleanup receipt.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/Helm operations.
- [harness workflow](harness_workflow.md) — current test-profile and DSL mismatch.
- [gitignore guardrails](../engineering/gitignore_guardrails.md) — keeping `.data/` and `.test_data/`
  outside version control.
