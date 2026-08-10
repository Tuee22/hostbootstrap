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

The typed replacement exists and is exercised, but the imperative path still runs.

`HostBootstrap.Cluster.Reconcile` owns the total classification: an absent cluster created is
`Changed Created`; a healthy same-named cluster with a matching committed proof is `Unchanged`, and
**without** proof is a `ForeignResult` that is never adopted; an unhealthy or unverifiable same-named
cluster is a structured `Conflict` that is **never** auto-deleted; a probe fault is a typed `Failure`,
never a false absence. Conditional cleanup requires a `Managed` handle plus a matching receipt.

`HostBootstrap.Cluster.Backend` supplies the IO that feeds it while holding the four
[ownership invariant](../architecture/ownership_invariant.md) clauses: an exclusive `flock(2)` across the
whole observe/create/settle bracket, an origin record naming the exact prior state before the first
mutation, identity bound to the control-plane node **container ID** rather than the cluster name, and
deletion conditioned on re-observing that identity. Discovery **probes the frame it will run in** for the
shell front end that takes that lock — `flock(1)` on a util-linux userland, `lockf(1)` on a BSD one — and
retains the answer on the capability, so the bracket cannot be built from a tool the frame was never shown
to have. A frame missing a lock front end, `grep`, the driver, or the container runtime is `Unsupported`
and mints no capability, as is one whose probe reports a tool the backend does not recognize. Its command
runner is injected, so the protocol is executed against a real filesystem under test rather than modelled
— including on macOS, where the clause suite first ran on 2026-08-02.

Alongside it, `HostBootstrap.Cluster.Backend` makes a wildcard exposure unrepresentable: a
`LoopbackExposure` accepts ports only, always renders `127.0.0.1`, and settles a live binding that is
wider or different as a `Conflict`.

What remains is the wiring. `ensureCluster` still treats any healthy cluster with `clusterName plan` as
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

Lifecycle closure requires:

1. a plan-owned closed precondition set consumed by every mutation, carrying exact resource-bound
   readiness evidence for each declared dependency and using the private zero-dependency branch only
   when the plan declares no dependency;
2. explicit reconcile results and ownership receipts, with conflict/refusal/unsupported/failure in the
   error sum, plus same-name foreign-cluster tests proving no adoption or deletion;
3. recursive child-to-parent `down` and `destroy`;
4. a demo test run proving the target `Harness projectId runId` scope, `.test_data`, and a run-scoped cluster;
5. native Linux CPU and GPU gates, including daemon placement;
6. the durable pod-write → destroy → up → host-and-pod-readback gate;
7. a bare-Linux storage wall or an explicit unsupported/refusal result.

`DEVELOPMENT_PLAN/README.md` owns phase status and closure evidence.

## Related

- [durable state](../architecture/durable_state.md) — `.data`, the stable alias, and persistence gate.
- [harness workflow](../architecture/harness_workflow.md) — test DSL and profile defects.
- [resource budgeting](resource_budgeting.md) — applied and missing resource walls.
- [in-cluster registry](in_cluster_registry.md) — MinIO, registry, and image-push ordering.
- [accelerator daemon](accelerator_daemon.md) — substrate-selected daemon placement.
