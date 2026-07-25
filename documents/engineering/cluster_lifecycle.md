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
`IO ()`, and downstream mutations do not all consume an opaque `Ready ClusterApi`/GPU capability.
`Ready` is also publicly forgeable today. See
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

Cluster identity is currently name-only. `ensureCluster` treats any healthy cluster with
`clusterName plan` as the desired cluster without checking an ownership receipt. If that same-name
cluster is unhealthy, it deletes and recreates it. `clusterDown`/`clusterDelete` likewise issue
`kind delete cluster --name <name>` without first proving that this plan created or adopted the
resource. A foreign same-name cluster can therefore be adopted or destroyed. The target classifier
distinguishes absent, receipt-owned, compatible foreign, incompatible/conflicting, and unsupported
states; ordinary `project up` cannot turn a foreign observation into `Managed`, and teardown requires
the verified receipt (or an explicit separately journaled adoption operation).

## Current teardown

`project down` and `project destroy` are intended root-orchestrator commands, but the current gate checks
only the descriptive `HostOrchestratorCommand` class. Because `addRole` can add that class without
changing a leaf's primary kind or proving an empty parent chain, a widened leaf can currently pass; the
opaque root-authority target closes that gap. After the class gate, core checks whether the **current**
frame owns a `deploy-kind` step:

- an owning frame invokes `clusterDown`/`clusterDelete`;
- a non-owning frame skips core kind cleanup;
- the project teardown hook then stops or deletes provider/direct resources.

The interpreter does **not** recursively dispatch the lifecycle verb through every child frame before
unwinding. On VM-backed paths, stopping or deleting the provider VM incidentally stops or removes the
nested cluster. On the direct Linux GPU path, the demo hook invokes the project image to delete nvkind.
Those are project-specific cleanup strategies, not recursive descent/ascent.

Independent cleanup actions are attempted and their failures are aggregated. `down` stops provider VMs;
`destroy` deletes them. A failed `project up` invokes best-effort root teardown, but a hard process kill can
still leave state for a later reconcile.

The target is child-to-parent recursion: enter the reachable child while its parent is alive, run the same
verb there, retain typed results, and stop/delete the parent only on ascent.

## Data-path guarantee

The cluster teardown partition excludes the plan's data path from its filesystem removal set:

- `Down` removes no planned filesystem path;
- `Delete` removes derived paths but not the data path.

This is a narrow and unit-tested guarantee. The target derives `.data` from one opaque canonical project
root and carries typed projections through provider guest, Docker, kind/nvkind, and pod boundaries.
Provider guests may reconcile `/var/tmp/hostbootstrap-demo-data`; direct Linux must bind the canonical
absolute host path and currently does not. Whether those bytes survive the entire destroy/up cycle is
still unvalidated. See
[durable state](../architecture/durable_state.md).

The status renderer's current wording is `(not removed by cluster teardown)`. It describes membership in
the removal partition; it is not a filesystem stat or an end-to-end persistence claim.

## Production and test profiles

The library represents:

| Profile | Data directory | Cluster identity |
|---|---|---|
| Production | `.data` | fixed project name |
| `TestCase caseId` | `.test_data/<caseId>` | `<project>-test-<caseId>` |

The demo live test path currently hardcodes `Production` when it resolves the container plan. Therefore
the existence of a `TestCase` constructor and pure test-profile unit cases does not establish isolation:
`test run` currently reaches `.data` and the production cluster identity. This is an open safety defect,
documented in [harness workflow](../architecture/harness_workflow.md).

The target uses an opaque, scope-indexed `LifecycleProfile`. Phase 15's independent gate supplies the
matching opaque root scope/command authority, but cannot mint a profile. Only Phase 10's protected
mode/lease openers can combine that authority with the exact active Production or Harness mode. Fresh
plans require the still-unbound lease and produce `LifecycleProfile (Production projectId)` or
`LifecycleProfile (Harness projectId runId)`. Configful abandoned Production `ProjectUp` instead requires
the exact bound lease/snapshot/recovery tuple and yields only its indexed
`RecoveredProductionLifecycleProfile`; Harness/teardown cannot inhabit it. `withProjectPlan` consumes a
fresh profile and scope-matching config,
and `containerPlan` projects the cluster name/data root only from that exact plan, so a test cannot
type-check with `.data` or the production identity. See
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
