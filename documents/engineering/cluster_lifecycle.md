# Cluster Lifecycle

**Status**: Authoritative source
**Supersedes**: the claim that teardown is recursive, readiness gating is universal, and demo tests use the Test profile
**Referenced by**: [documents index](../README.md), [resource budgeting](resource_budgeting.md), [durable state](../architecture/durable_state.md), [readiness](../architecture/readiness.md), [testing](testing.md)

> **Purpose**: Describe the implemented kind/nvkind/Helm lifecycle and clearly separate its current
> guarantees from the typed lifecycle target.

## Current Status

The cluster actions live in `HostBootstrap.Cluster.Lifecycle` and are invoked from project chain steps.
The demo's workload segment is:

```text
deploy-kind or nvkind
  -> deploy-minio
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> accelerator-daemon placement where selected
```

`deploy-minio` is required before the registry because the registry uses the MinIO bucket as its S3
backend. Linux CPU/GPU append an in-cluster accelerator-daemon deployment; Apple Silicon and Windows GPU
start a host daemon after the web and private daemon ingress are reachable.

The current registry wait proves only Deployment readiness and can be followed by `/v2/` success while
blob `HEAD` redirects the host client to cluster-only MinIO. The target chain requires the exact
`ReadyBlobRoute` derived from the finalized registry plan before `push-image`; see
[network reachability](../architecture/network_reachability.md).

Cluster creation is fail-closed around command exit status. Existing named clusters are health-probed;
an unhealthy one is deleted before recreation. Kind creation is followed by a bounded node readiness
wait. Nvkind adds the NVIDIA runtime smoke, a control-plane/GPU-worker topology, per-node CPU/memory
cordons, and a device-plugin/allocatable-GPU gate.

The [cluster-lifecycle-and-cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
has an independent live linux-cpu gate, reached as a case behind the fixed `test` verb:
`hostbootstrap test run cluster-live`. It creates a fresh kind cluster, waits for node readiness, performs a
read-only node-status query, deletes the cluster and verifies its labelled node containers are absent, then
re-reads a durable-root sentinel outside the deletion boundary. The exclusive run, the lease, the
clause-holding cleanup, and the report card come from the harness rather than from anything the case
arranges itself. The case does not invoke the demo; demo lifecycle integration and end-to-end durable
readback remain owned by the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), not by this phase gate.

This does not yet satisfy universal typed readiness. `waitNodesReady` and several related waits return
`IO ()`, and downstream mutations do not all consume the opaque plan/resource-indexed readiness and
prepared-operation foundation. Those constructors are now private; the open work is live interpreter
integration, not witness sealing. See
[readiness](../architecture/readiness.md) and
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Current reconciliation semantics

The implementation behaves idempotently in several common cases, but most reconcilers return `IO ()`.
They do not return `Either ReconcileError ReconcileResult`, where a `ManagedResult` carries a
`Managed` handle, receipt, and changed/no-op outcome while a `ForeignResult` carries only a
non-authorizing `Unmanaged` handle. Consequently “idempotent” here means empirically converge-or-fail,
not the stronger typed contract.

The target result and ownership algebra is defined once in
[lifecycle state model](../architecture/lifecycle_state_model.md).

### The ownership backend

The
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)'s
typed exact consumer and clause-holding backend are implemented. Legacy command/demo lifecycle call sites
remain deliberately separate until their owning recursive and worked-demo phases adopt it. The source
boundary plus its focused, full-static, and linux-cpu live gates are closed; call-site adoption belongs to
the [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) and
the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

`HostBootstrap.Cluster.Reconcile` owns the total classification: an absent cluster created is
`Changed Created`. An **origin-verified** healthy cluster with a matching committed proof is `Unchanged`;
the same exact owned identity without a proof is post-effect/pre-commit recovery and settles as
`Changed Repaired`. A healthy same-named cluster with no exact origin is always `Foreign`, even if a caller
offers an unrelated prior proof, and grants no managed authority. An unhealthy owned cluster or unverifiable
same-named cluster is a structured `Conflict` that is **never** auto-deleted; a probe fault is a typed
`Failure`, never a false absence. The prepared journal generation remains the plan resource generation; the
immutable control-plane container ID is retained separately in an opaque `ManagedClusterHandle`.
Conditional cleanup, cordon, and readiness consume that handle rather than a caller-paired generic
handle/receipt.

`HostBootstrap.Cluster.Backend` supplies the IO that feeds it while holding the four
[ownership invariant](../architecture/ownership_invariant.md) clauses. The private production backend keeps the executor and
raw-result constructors in a Cabal-private component. Public production discovery detects the Linux
substrate, builds the typed `HostConfig`, resolves `Kind`, `Docker`, and `Kubectl` as closed `HostTool`
values, and passes only their canonical absolute paths to the private validator. That
validator admits root-owned, non-group/world-writable path chains and executable files, and derives child
`PATH` solely from those validated executable directories. Children run with a fixed root cwd, sanitized
engine/provider/config environment, private kubeconfig descriptor, and process-group
timeouts whose pipe readers and reap are bounded even when the leader exits before a grandchild.

A caller cannot mint a backend from chosen output, and the reason is structural rather than a matter of
who may reach a seam: the classification that turns a tool's result into a decision is a total function
over a closed sum, so it is reached by application and there is nothing to substitute for it. See
[testing](testing.md) for what that makes admissible as evidence.

The durable ownership protocol implements the ownership namespace. One exact no-follow directory walk creates and
parent-fsyncs the plan-derived state leaf, and the row the frame declares supplies exclusive entry — held
on a retained descriptor across observe/create/settle and released by the kernel if the holder dies (see
[ownership seam](../architecture/ownership_seam.md)). The lock, state
leaf, origin record, and complete node-name-to-container-ID map are kernel-identity-bound across calls.
Every canonical `prepared`, `executing`, or `managed` origin record also contains and validates its own
record inode, exact cluster name, owner, config binding, and nonce. Before Kind runs, `executing` durably
binds the exact config snapshot inode and SHA-256 plus
the private kubeconfig snapshot inode. Kind receives retained descriptor paths, never a mutable config
pathname or ambient kubeconfig. Fresh recovery accepts or conditionally removes only those exact objects;
a copied record, replacement snapshot, config drift, incomplete transition, or foreign stage fails closed.
The managed transition is published and directory-fsynced only after the created node IDs are re-observed.

Reconciliation and cordoning use that namespace for total reconciliation/status and the raw cordon,
readiness, and cleanup operations. Cordon re-observes the full retained node map and calls `docker update`
with immutable container IDs, never reusable node names. Readiness revalidates owner, record, lock, state
leaf, exact node set, API readiness, every node's Ready condition, and the same container IDs. Cleanup
independently inspects every retained node ID even when Kind omits the cluster, and removes the origin only
after exact node absence. Cordon/readiness/cleanup open only the already retained state and lock identities;
they cannot recreate a missing namespace and then claim idempotent success. A missing required tool or strong
primitive is `Unsupported` and mints no
capability; an observation or durable-record failure is never interpreted as absence.

The exact package layer exposes authority over that raw boundary. Preparation accepts only a
backend-minted Running-provider dependency and reruns that backend's real probe before offering the cluster
call. Production config bytes are bound by SHA-256 with the exact retained budget in the prepared call;
Harness has no config and emits no `--config`. After creation, the same lock and origin identity guard the
budget-backed node-container cordon. Only successful cordon plus a fresh real API/all-node Ready reprobe of
the exact owner/container identity can mint `ClusterReadiness`; a replacement identity is a `Conflict`, and
the successful phase-observation counter fails rather than wrapping at exhaustion. Constructors for raw
backend results, managed/cordon/readiness/cleanup authority, and the running dependency remain hidden and
nominally indexed. The earlier durable-root foundation supplies the prerequisite this path consumes.

Alongside it, `HostBootstrap.Cluster.Backend` makes a wildcard exposure unrepresentable: a
`LoopbackExposure` accepts ports only, always renders `127.0.0.1`, and settles a live binding that is
wider or different as a `Conflict`.

What remains is legacy wiring. `ensureCluster` still treats any healthy cluster with `clusterName plan` as
the desired cluster without checking a receipt, and still deletes and recreates an unhealthy same-name
cluster; `clusterDown`/`clusterDelete` still issue `kind delete cluster --name <name>` without proving
this plan created or adopted the resource. Replacing those call sites belongs to the recursive-plan
tranche, not to the backend.

## Current teardown

`project down` and `project destroy` are intended root-orchestrator commands, but the current gate checks
only the descriptive `HostOrchestratorCommand` class. Because `addRole` can add that class without
changing a leaf's primary kind or proving an empty parent chain, a widened leaf can currently pass; the
opaque root-authority target closes that gap. After the class gate, core checks whether the **current**
frame owns a `deploy-kind` step:

- an owning frame invokes `clusterDown`/`clusterDelete`;
- a non-owning frame skips core kind cleanup;
- the reverse each acquiring node declared then stops or deletes provider/direct resources.

The interpreter does **not** recursively dispatch the lifecycle verb through every child frame before
unwinding. On VM-backed paths, stopping or deleting the provider VM incidentally stops or removes the
nested cluster. On the direct Linux GPU path, the demo hook invokes the project image to delete nvkind.
Those are project-specific cleanup strategies, not recursive descent/ascent.

Independent cleanup actions are attempted and their failures are aggregated. `down` stops provider VMs;
`destroy` deletes them. A failed `project up` invokes best-effort root teardown, but a hard process kill can
still leave state for a later reconcile.

The prepared provider boundary does not reinterpret Direct as a VM. Direct settles only a plan-local
admission and canonical identity share; provider stop, delete, guest execution, and guest alias are
structured refusals with no physical-host mutation. Direct-lane cluster/container cleanup therefore
remains its own plan work rather than provider teardown.

The target is child-to-parent recursion: enter the reachable child while its parent is alive, run the same
verb there, retain typed results, and stop/delete the parent only on ascent.

## Data-path guarantee

The cluster teardown partition excludes the plan's data path from its filesystem removal set:

- `Down` removes no planned filesystem path;
- `Delete` removes derived paths but not the data path.

This is a narrow and unit-tested guarantee. Root admission now derives direct-host `.data` from one
opaque canonical project root, and the Docker handoff consumes a same-root typed host projection.
The core provider-guest alias route reconciles `/var/tmp/hostbootstrap-demo-data` through exact opaque
managed provider/share/alias authority and identity-conditional release, but the demo still uses its
compatibility pathname call site. The final plan still has to carry typed guest, container, kind/nvkind,
and pod projections, and the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that call-site adoption. Whether
those bytes survive the entire destroy/up cycle is still unvalidated. See
[durable state](../architecture/durable_state.md).

The status renderer's current wording is `(not removed by cluster teardown)`. It describes membership in
the removal partition; it is not a filesystem stat or an end-to-end persistence claim.

## Production and test profiles

The library represents:

| Profile | Data directory | Cluster identity |
|---|---|---|
| Production | `.data` | fixed project name |
| `HarnessRun runId` | `.test_data/<runId>` | run-scoped Harness name |

The Harness command admits an exact `ProjectPlan (Harness projectId runId) ...` and owns the generated
config and `.test_data/<runId>` root. Demo cluster/provider/mount/teardown consumers still receive
config-derived `RunProfile`/`ClusterProfile` and root terms independently. The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns replacing those terms with the
retained exact plan's profile/root projection; see [harness workflow](../architecture/harness_workflow.md).

The target uses an opaque, scope-indexed `LifecycleProfile`. The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
supplies backend-indexed opaque managed provider/share/alias authority inside an already admitted exact
plan; it cannot mint a lifecycle profile or command authority. Only the
[sessions-journal-and-fences phase](../../DEVELOPMENT_PLAN/phase-10-sessions-journal-and-fences.md)'s protected
mode/lease openers can combine that authority with the exact active Production or Harness mode. Fresh
plans require the still-unbound lease and produce `LifecycleProfile (Production projectId)` or
`LifecycleProfile (Harness projectId runId)`. Configful abandoned Production `ProjectUp` instead requires
the exact bound lease/snapshot/recovery tuple and yields only its indexed
`RecoveredProductionLifecycleProfile`; Harness/teardown cannot inhabit it. `withProjectPlan` consumes a
fresh profile and scope-matching config. The exact plan therefore retains the right scoped profile/root
identity, but the demo's `containerPlan` still accepts a separately config-derived `ClusterProfile` and
source root. The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) replaces those
independent consumer terms with projections from that exact plan. See
[lifecycle state model](../architecture/lifecycle_state_model.md#lifecycle-profile-authority).

## Resource limits

CPU and memory are divided across kind/nvkind nodes and applied with `docker update`. The implementation
sets `--memory-swap` to twice the memory limit, not equal to it. Bare Linux has no implemented storage
quota or image-garbage-collection cap; storage is only capacity-checked before bring-up. VM-backed lanes
receive provider storage walls when a new Lima/Incus VM or WSL distro is created, but existing VM/VHDX
sizes are not uniformly observed, resized, or refused when config changes. The complete workload set is
not yet derived or checked with `fitsBudget`;
the demo's static `demoPods` view contains only the web example and the web chart lacks corresponding
CPU/memory requests/limits. See [resource budgeting](resource_budgeting.md).

## Validation

From the repository root, the exact
[cluster-lifecycle-and-cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
gate is:

```sh
(cd core && cabal test all --ghc-options=-Werror) && hostbootstrap test run cluster-live
```

The static leg covers the exact plan-owned precondition, reconcile-result, ownership-receipt, same-name
foreign-cluster, readiness, status, and teardown cases declared by the phase. The independent live leg covers
fresh creation, bounded readiness, a read-only status observation, deletion, labelled-node absence, and
durable-sentinel survival on linux-cpu. It deliberately has no demo dependency.

Recursive child-to-parent lifecycle traversal, the run-scoped demo cluster, end-to-end pod/host durable
readback, GPU daemon placement, and substrate-specific storage-wall acceptance remain validation owned by
their respective later integration or acceptance phases. None is a prerequisite for the independent phase
gate above.

`DEVELOPMENT_PLAN/README.md` owns phase status and closure evidence.

## Related

- [durable state](../architecture/durable_state.md) — `.data`, the stable alias, and persistence gate.
- [harness workflow](../architecture/harness_workflow.md) — test DSL and profile defects.
- [resource budgeting](resource_budgeting.md) — applied and missing resource walls.
- [in-cluster registry](in_cluster_registry.md) — MinIO, registry, and image-push ordering.
- [accelerator daemon](accelerator_daemon.md) — substrate-selected daemon placement.
